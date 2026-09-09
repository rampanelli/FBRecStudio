{
  uDiagFileProbe.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F1-T4 (PLANO.md 4.1.1/4.1.3/6.2): diagnostico estatico de arquivo
  Firebird/InterBase (.fbk/.gbk backup; .fdb/.gdb banco). NAO abre o
  banco: le somente o primeiro KB de forma segura e aplica heuristicas
  documentadas.

  Heuristicas v1 (base: formato real do gbak e ods.h do Firebird):
    * Backup gbak: stream de registros; primeira pagina de um backup
      comeca com rec_physical_db (byte 0x0E) e todo backup e multiplo
      de 512 bytes (BURP_BLOCK). Backups divididos/multivolume comecam
      com o texto 'InterBase/gbak,   ' ou 'InterBase/gsplit, '.
      Sem assinatura: extensao .fbk/.gbk -> 'backup provavel'.
    * Banco (pagina 0 = header page, tipo pag_header=1; layout ODS 10+,
      16 bytes de cabecalho de pagina):
        offset  0 : pag_type  (1 = header page)
        offset 16 : hdr_page_size      (u16 LE)
        offset 18 : hdr_ods_version    (u16 LE; major=(v and 7FF0)>>4,
                    minor=(v and 000F); bit 8000 = marca Firebird)
        offset 42 : hdr_flags (u16 LE; bit 0100 = SQL dialect 3;
                    bits de shutdown: heuristica mascara 1080)
      Campos heuristica 'a validar no corpus na F7' - nunca fonte unica.
    * FSS suspeito: nenhuma heuristica confiavel nesta fase (corpus na
      F7); campo SuspiciousFss sai False com nota.

  Delphi 7 puro; leituras defensivas (arquivo ausente/vazio/curto);
  sem Forms; comentarios pt-BR ASCII.
  ------------------------------------------------------------------
}
unit uDiagFileProbe;

{$H+}

interface

uses
  uDiagParser;

type
  // Classificacao macro do arquivo (nomes do PLANO 6.2).
  TDiagKind = (kUnknown, kBackup, kDatabase);

  // Resultado do diagnostico (contrato F1-T4; Notes como string
  // multilinha em vez de TStrings - simplificacao D7, ver docs).
  TDiagResult = record
    Arquivo: string;          // caminho analisado ('' em AnalisarBuffer)
    FileKind: TDiagKind;
    ClassificadoPor: string;  // heuristica que decidiu a classe
    OdsMaior: Word;           // 0 = nao determinado
    OdsMenor: Word;
    PageSize: Word;           // 0 = nao determinado
    Dialect: Byte;            // 0 = n/d, 1 ou 3
    Shutdown: Boolean;
    // Formato do stream de backup (heuristico, F7): -1 = nao se
    // aplica/nao analisado; 0 = nao parece backup; 1..15 = versao do
    // formato lida do cabecalho (1..3 = legado InterBase/Firebird 1;
    // >= 8 = Firebird moderno). Base empirica: backups reais FB 2.5
    // comecam com os bytes 00 02 04 <ver>.
    BackupFormatVer: Integer;
    SuspiciousFss: Boolean;
    FileSize: Int64;
    CompatibleServer: string; // '' nesta fase (sem servidor detectado)
    RecommendedTech: string;  // tecnica recomendada (heuristica T1..T6)
    Notes: string;            // linhas separadas por #13#10
  end;

// Diagnostica o arquivo no disco (leitura segura do primeiro KB).
// Retorna False se o arquivo nao pode ser aberto/lido; mesmo assim
// preenche R (FileKind = kUnknown e nota com o motivo).
function DiagnosticarArquivo(const ACaminho: string;
  var R: TDiagResult): Boolean;

// Diagnostica um buffer ja em memoria (usado pelos testes sinteticos).
// AExtensao: extensao do arquivo ('' se nao houver), ex.: '.fdb'.
// AFileSize: tamanho REAL do arquivo (o buffer pode ser so o primeiro KB).
procedure AnalisarBuffer(const ABuf: array of Byte; ALen: Integer;
  const AExtensao: string; AFileSize: Int64; var R: TDiagResult);

// Escolhe a tecnica recomendada (heuristica; preenche R.RecommendedTech
// e devolve o mesmo texto). Separada para testes.
function RecomendarTecnica(var R: TDiagResult): string;

// Nome legivel do tipo (para relatorio/UI).
function DiagKindParaTexto(AKind: TDiagKind): string;

implementation

uses
  SysUtils, Windows;

function ApiGetFileSizeEx(hFile: THandle;
  var lpFileSize: Int64): BOOL; stdcall;
  external 'kernel32.dll' name 'GetFileSizeEx';

const
  // limites do layout ODS 10+ (offsets 0-based, pagina 0)
  C_PAG_HEADER = 1;            // pag_type do header page
  C_OFF_PAGE_SIZE = 16;
  C_OFF_ODS = 18;
  C_OFF_FLAGS = 42;
  C_FLAG_DIALECT3 = $0100;     // hdr_SQL_dialect_3
  C_FLAG_SHUTDOWN_MASK = $1080; // bits de shutdown (heuristica, F7)
  C_MARCA_FIREBIRD = $8000;    // bit Firebird no hdr_ods_version

  C_REC_PHYSICAL_DB = $0E;     // rec_physical_db (stream do gbak)
  C_BURP_BLOCK = 512;
  // Cabecalho do stream de backup em formato moderno (empirico em
  // backups reais FB 2.5): bytes 00 02 04 <versao>; versoes 1..3 sao
  // legado (InterBase 6/FB1) e >= 8 sao Firebird moderno. O gbak IB6
  // rejeita backups modernos com "Expected backup version 1,2,3.
  // Found <ver>" - e a base da decisao de engine no diagnostico.
  C_BAK_HDR0 = $00;
  C_BAK_HDR1 = $02;
  C_BAK_HDR2 = $04;
  C_BAK_VER_LEGADO_MAX = 3;    // formato <= 3: legado
  C_BAK_VER_MODERNO_MIN = 8;   // formato >= 8: Firebird moderno

// Adiciona uma nota (linha) ao resultado.
procedure Nota(var R: TDiagResult; const AMsg: string);
begin
  if R.Notes = '' then
    R.Notes := AMsg
  else
    R.Notes := R.Notes + #13#10 + AMsg;
end;

function DiagKindParaTexto(AKind: TDiagKind): string;
begin
  case AKind of
    kBackup:   Result := 'backup gbak';
    kDatabase: Result := 'banco de dados';
  else
    Result := 'desconhecido';
  end;
end;

// ------------------------------------------------------------------
// Deteccao do formato do stream de backup (cabecalho moderno).
// Preenche R.BackupFormatVer (-1 = n/d; 0 = nao parece backup;
// >0 = versao). True quando o padrao 00 02 04 <ver> foi reconhecido.
// ------------------------------------------------------------------
function DetectarFormatoBackup(const ABuf: array of Byte; ALen: Integer;
  var R: TDiagResult): Boolean;
var
  V0, V1, V2, V3: Byte;
begin
  Result := False;
  R.BackupFormatVer := -1;
  if ALen < 4 then
    Exit;
  if not LerU8(ABuf, 0, V0) then Exit;
  if not LerU8(ABuf, 1, V1) then Exit;
  if not LerU8(ABuf, 2, V2) then Exit;
  if not LerU8(ABuf, 3, V3) then Exit;
  if (V0 = C_BAK_HDR0) and (V1 = C_BAK_HDR1) and (V2 = C_BAK_HDR2) and
     (V3 >= 1) and (V3 <= 15) then
  begin
    R.BackupFormatVer := V3;
    Result := True;
  end;
end;

// ------------------------------------------------------------------
// Deteccao de assinatura de backup (stream do gbak).
// ------------------------------------------------------------------
function TemAssinaturaBackup(const ABuf: array of Byte; ALen: Integer;
  AFileSize: Int64): Boolean;
var
  V: Byte;
  P: Integer;
begin
  Result := False;
  if ALen <= 0 then
    Exit;
  // 1) backup dividido/multivolume comeca com 'InterBase/g'
  if ProcurarAscii(ABuf, 'InterBase/g', 0, P) then
    if P = 0 then
    begin
      Result := True;
      Exit;
    end;
  // 2) backup normal: rec_physical_db no byte 0 e tamanho multiplo de
  //    512; segundo byte com cara de atributo (1..64)
  if not LerU8(ABuf, 0, V) then
    Exit;
  if V = C_REC_PHYSICAL_DB then
    if (AFileSize mod C_BURP_BLOCK) = 0 then
      if LerU8(ABuf, 1, V) then
        if (V >= 1) and (V <= 64) then
          Result := True;
end;

// ------------------------------------------------------------------
// Leitura do cabecalho de banco (pagina 0) - heuristica ODS 10+.
// ------------------------------------------------------------------
procedure InterpretarCabecalhoBanco(const ABuf: array of Byte; ALen: Integer;
  var R: TDiagResult);
var
  RawOds, Flags, PageSize, Tmp: Word;
  V: Byte;
  OdsMaior, OdsMenor: Word;
begin
  // bytes 0 e 1 devem existir para caracterizar pagina
  if not LerU8(ABuf, 0, V) then
  begin
    Nota(R, 'arquivo curto demais para cabecalho de banco');
    Exit;
  end;
  if V <> C_PAG_HEADER then
  begin
    Nota(R, 'primeiro byte nao e pag_header (1); cabecalho invalido');
    Exit;
  end;

  // hdr_ods_version (offset 18)
  if not LerU16LE(ABuf, C_OFF_ODS, RawOds) then
  begin
    Nota(R, 'buffer curto: nao foi possivel ler hdr_ods_version');
    Exit;
  end;
  OdsMaior := (RawOds and $7FF0) shr 4;
  OdsMenor := RawOds and $000F;
  if (RawOds and C_MARCA_FIREBIRD) <> 0 then
    Nota(R, 'hdr_ods_version com marca Firebird (bit 8000)');
  if (OdsMaior < 4) or (OdsMaior > 13) then
  begin
    Nota(R, 'ODS ' + IntToStr(OdsMaior) + '.' + IntToStr(OdsMenor) +
            ' fora da faixa conhecida (4..13); layout pode diferir');
    // ainda registra o que leu (para exibicao) e tenta o resto
  end;
  R.OdsMaior := OdsMaior;
  R.OdsMenor := OdsMenor;

  // hdr_page_size (offset 16): potencia de 2 entre 512 e 65536
  if LerU16LE(ABuf, C_OFF_PAGE_SIZE, PageSize) then
  begin
    Tmp := PageSize;
    if (Tmp >= 512) and ((Tmp and (Tmp - 1)) = 0) then
      R.PageSize := PageSize
    else
    begin
      Nota(R, 'page size ' + IntToStr(PageSize) +
              ' nao parece valido (potencia de 2 entre 512 e 65536)');
      R.PageSize := 0;
    end;
  end
  else
    Nota(R, 'buffer curto: nao foi possivel ler hdr_page_size');

  // hdr_flags (offset 42): dialect e shutdown (somente ODS 10+)
  if OdsMaior >= 10 then
  begin
    if LerU16LE(ABuf, C_OFF_FLAGS, Flags) then
    begin
      if (Flags and C_FLAG_DIALECT3) <> 0 then
        R.Dialect := 3
      else
        R.Dialect := 1;
      if (Flags and C_FLAG_SHUTDOWN_MASK) <> 0 then
      begin
        R.Shutdown := True;
        Nota(R, 'flags de shutdown ativos (hdr_flags=' +
                IntToHex(Flags, 4) + ') - validar com gfix');
      end;
    end
    else
      Nota(R, 'buffer curto: nao foi possivel ler hdr_flags');
  end
  else
    Nota(R, 'ODS anterior a 10: campos de flags/dialeto nao lidos ' +
            '(layout antigo, F7/corpus)');
end;

// ------------------------------------------------------------------
// AnalisarBuffer
// ------------------------------------------------------------------
procedure AnalisarBuffer(const ABuf: array of Byte; ALen: Integer;
  const AExtensao: string; AFileSize: Int64; var R: TDiagResult);
var
  Ext: string;
  EBackup, EBanco: Boolean;
  V: Byte;
  PrimeiroEhHeader: Boolean;
begin
  R.FileKind := kUnknown;
  R.ClassificadoPor := '';
  R.OdsMaior := 0;
  R.OdsMenor := 0;
  R.PageSize := 0;
  R.Dialect := 0;
  R.Shutdown := False;
  R.BackupFormatVer := -1;
  R.SuspiciousFss := False;
  R.FileSize := AFileSize;
  R.CompatibleServer := '';
  R.RecommendedTech := '';
  R.Notes := '';

  Ext := LowerCase(Trim(AExtensao));
  EBackup := (Ext = '.fbk') or (Ext = '.gbk');
  EBanco := (Ext = '.fdb') or (Ext = '.gdb');

  if ALen <= 0 then
  begin
    Nota(R, 'arquivo vazio ou ilegivel');
    if EBackup then
    begin
      R.FileKind := kBackup;
      R.ClassificadoPor := 'extensao (backup provavel)';
    end;
    Exit;
  end;

  // 1) assinatura de backup (conteudo manda sobre a extensao)
  DetectarFormatoBackup(ABuf, ALen, R); // preenche BackupFormatVer
  if TemAssinaturaBackup(ABuf, ALen, AFileSize) then
  begin
    R.FileKind := kBackup;
    R.ClassificadoPor := 'assinatura do stream gbak';
    if EBanco then
      Nota(R, 'conteudo de backup mas extensao de banco (.fdb/.gdb)');
    RecomendarTecnica(R);
    Exit;
  end;

  // 2) cabecalho de banco (pagina 0) ou extensao de banco
  PrimeiroEhHeader := False;
  if LerU8(ABuf, 0, V) then
    PrimeiroEhHeader := (V = C_PAG_HEADER);

  if PrimeiroEhHeader then
  begin
    R.FileKind := kDatabase;
    R.ClassificadoPor := 'cabecalho da pagina 0';
    InterpretarCabecalhoBanco(ABuf, ALen, R);
    if EBackup then
      Nota(R, 'conteudo de banco mas extensao de backup (.fbk/.gbk)');
    RecomendarTecnica(R);
    Exit;
  end;

  if EBanco then
  begin
    R.FileKind := kDatabase;
    R.ClassificadoPor := 'extensao (cabecalho nao reconhecido)';
    Nota(R, 'primeiro byte <> pag_header; conteudo pode ser banco ' +
            'corrompido, ODS antigo ou outro formato');
    RecomendarTecnica(R);
    Exit;
  end;

  // 3) extensao de backup sem assinatura -> 'backup provavel'
  if EBackup then
  begin
    R.FileKind := kBackup;
    R.ClassificadoPor := 'extensao (sem assinatura)';
    if R.BackupFormatVer > 0 then
    begin
      R.ClassificadoPor := 'assinatura do stream gbak (formato ' +
                           IntToStr(R.BackupFormatVer) + ')';
      if R.BackupFormatVer <= C_BAK_VER_LEGADO_MAX then
        Nota(R, 'backup em formato legado (' +
                IntToStr(R.BackupFormatVer) + '): criado por ' +
                'InterBase 6/Firebird 1 - exige gbak dessa familia')
      else if R.BackupFormatVer >= C_BAK_VER_MODERNO_MIN then
        Nota(R, 'backup em formato Firebird moderno (' +
                IntToStr(R.BackupFormatVer) + '): exige gbak ' +
                'Firebird (2.5 ou superior) - gbak InterBase antigo ' +
                'NAO le este formato')
      else
        Nota(R, 'formato de backup ' + IntToStr(R.BackupFormatVer) +
                ' (faixa intermediaria, validar com gbak real)');
    end
    else
      Nota(R, 'assinatura do stream nao reconhecida; backup provavel ' +
              '(validar com gbak na F7)');
    RecomendarTecnica(R);
    Exit;
  end;

  // 4) nada reconhecido
  R.FileKind := kUnknown;
  R.ClassificadoPor := 'conteudo nao reconhecido';
  Nota(R, 'nenhuma assinatura/estrutura reconhecida no primeiro KB; ' +
          'classificar manualmente ou com bins reais (F7)');
end;

// ------------------------------------------------------------------
// RecomendarTecnica (heuristica; codigo da tecnica do PLANO F3/F4)
// ------------------------------------------------------------------
function RecomendarTecnica(var R: TDiagResult): string;
begin
  Result := '';
  case R.FileKind of
    kBackup:
      if R.OdsMaior >= 12 then
        Result := 'T1 - restore via gbak (backup de ODS ' +
                  IntToStr(R.OdsMaior) + '.' + IntToStr(R.OdsMenor) +
                  '; exige servidor Firebird 3+)'
      else
        Result := 'T1 - restore via gbak para banco novo (-c)';

    kDatabase:
      if R.OdsMaior = 0 then
        Result := 'T3 - validar com gfix (cabecalho nao lido)'
      else if R.Shutdown then
        Result := 'T3 - gfix activate e validar (banco em shutdown)'
      else if R.SuspiciousFss then
        Result := 'T2 - restore limpo via backup (avaliar fix_fss ' +
                  'conforme catalogo)'
      else
        Result := 'T3 - validar banco com gfix';
  end;
  R.RecommendedTech := Result;
end;

// ------------------------------------------------------------------
// DiagnosticarArquivo (leitura segura em disco)
// ------------------------------------------------------------------
type
  TBufPrimeiroKB = array[0..1023] of Byte;

function DiagnosticarArquivo(const ACaminho: string;
  var R: TDiagResult): Boolean;
var
  W: WideString;
  H: THandle;
  NRead: DWORD;
  Tam: Int64;
  Buf: TBufPrimeiroKB;
  Ext: string;
begin
  R.Arquivo := ACaminho;
  R.FileKind := kUnknown;
  R.ClassificadoPor := '';
  R.OdsMaior := 0;
  R.OdsMenor := 0;
  R.PageSize := 0;
  R.Dialect := 0;
  R.Shutdown := False;
  R.BackupFormatVer := -1;
  R.SuspiciousFss := False;
  R.FileSize := 0;
  R.CompatibleServer := '';
  R.RecommendedTech := '';
  R.Notes := '';

  Result := False;
  if not FileExists(ACaminho) then
  begin
    Nota(R, 'arquivo nao encontrado: ' + ACaminho);
    Exit;
  end;

  W := WideString(ACaminho);
  H := CreateFileW(PWideChar(W), GENERIC_READ,
                   FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
                   nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then
  begin
    Nota(R, 'nao foi possivel abrir o arquivo (erro ' +
            IntToStr(GetLastError) + ')');
    Exit;
  end;
  try
    // tamanho real
    Tam := 0;
    if not ApiGetFileSizeEx(H, Tam) then
    begin
      Nota(R, 'falha ao obter o tamanho (erro ' + IntToStr(GetLastError) + ')');
      Tam := 0;
    end;
    R.FileSize := Tam;

    NRead := 0;
    if not ReadFile(H, Buf, SizeOf(Buf), NRead, nil) then
    begin
      Nota(R, 'falha de leitura (erro ' + IntToStr(GetLastError) + ')');
      // continua com o que foi lido (NRead=0)
    end;

    Ext := ExtractFileExt(ACaminho);
    Result := True;
  finally
    CloseHandle(H);
  end;
  AnalisarBuffer(Buf, Integer(NRead), Ext, R.FileSize, R);
end;

end.