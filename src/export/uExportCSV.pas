{
  uExportCSV.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F5 / F5-T3+T4 (PLANO.md 4.3, decisao 9.3 - driver): exportacao
  CSV/TSV por tabela consumindo uma interface de DRIVER (catalogo de
  tabelas/colunas + leitura de linhas). Sem Forms.

    * IDriverCatalogo/ILeitorLinhas: contrato minimo de acesso por
      driver. A implementacao REAL exigira a fbclient.dll 32-bit
      (decisao 9.3, fora do escopo desta fase sem driver); a interface
      e totalmente testavel com um "driver fake" em memoria (fixtures
      de catalogo/linhas nos testes).
    * TExportadorCSV gera '<base>.<TABELA>.csv' (ou '.tsv' quando o
      delimitador e TAB) + manifesto por tabela/linhas/arquivo.
    * Decisoes de contrato (documentadas aqui e nos testes):
        NULL  -> campo VAZIO (mesma representacao de string vazia;
                 distinguir so pelo manifesto/catalogo - decisao F5);
        aspas/delimitador/CR/LF dentro do valor -> RFC-4180 (valor
                 entre aspas e aspa interna dobrada); CRLF interno e
                 preservado dentro do campo entre aspas;
        BLOB  -> politica TExportParams.BlobComo:
                   beOmitir/IncluirBlob=False: campo vazio;
                   beHex: hex MAIUSCULO dos bytes (autossuficiente);
                   beArquivo: grava '<base>_blobs\<TABELA>_<linha>_<col>
                   .blob' e a celula guarda o nome do arquivo.
        Sem BOM; charset via NormalizarCharsetExport/CodificarSaida.
    * Comportamento resiliente (padrao F4 datapump): tabela que falha
      vira item xeFalha no manifesto e as demais seguem; Executar
      devolve False quando houve 1+ falha.

  Regras do repositorio: Delphi 7 puro (sem generics/anonymous/for..in),
  comentarios pt-BR ASCII, sem Forms, unidades <= 31 chars.
  ------------------------------------------------------------------
}
unit uExportCSV;

{$H+}

interface

uses
  SysUtils, Classes, uExportBase, uKernelExec;

type
  // ------------------------------------------------------------------
  // Catalogo de uma coluna (driver fornece; F5-T3 futuro via fbclient).
  // ------------------------------------------------------------------
  TColunaCatalogo = record
    Nome: string;      // nome da coluna
    Tipo: string;      // tipo textual (driver); '' = desconhecido
    Tamanho: Integer;  // tamanho declarado (0 = nao se aplica)
    Nula: Boolean;     // aceita NULL
    EhBlob: Boolean;   // coluna BLOB (a politica BlobComo se aplica)
  end;
  TListaColunas = array of TColunaCatalogo;

  // ------------------------------------------------------------------
  // Uma celula de uma linha (contrato do leitor do driver).
  //   Nulo  - SQL NULL;
  //   Texto - valor textual (campos comuns; ou blob textual quando o
  //           driver o entrega assim);
  //   Bytes - bytes crus quando o driver materializa BLOB binario;
  //   EhBlob- marca celula de coluna BLOB.
  // Regra do exportador: BLOB com Bytes usa Bytes; BLOB textual sem
  // Bytes usa os bytes ACP do Texto (hex/arquivo) ou o proprio texto
  // quando omitido/IncluirBlob=False.
  // Bytes crus (alias D7: arrays dinamicos exigem identidade de tipo
  // para atribuicao - FPC e tolerante, D7 nao; usar sempre o alias).
  TBytesCSV = array of Byte;

  TValorCelula = record
    Nulo: Boolean;
    EhBlob: Boolean;
    Texto: string;
    Bytes: TBytesCSV;
  end;
  TCamposLinha = array of TValorCelula;

  // Leitor de linhas de uma tabela (cursor posicionado antes da 1a).
  ILeitorLinhas = interface
    ['{8B41D29C-6C03-4A2A-8F1E-5D1AA92B4E63}']
    // Avanca: True = ha linha (Valores preenchido); False = fim do
    // resultado. Erro de leitura -> False + Msg <> ''.
    function ProximaLinha(var Valores: TCamposLinha; var Msg: string): Boolean;
  end;

  // ------------------------------------------------------------------
  // Driver de catalogo/leitura (decisao 9.3). Implementacao real:
  // fbclient.dll 32-bit (futuro). Testes: driver fake em memoria.
  // ------------------------------------------------------------------
  IDriverCatalogo = interface
    ['{5C7D21B4-9E60-4D13-8C2B-4AF96B7E3D15}']
    function NomeDriver: string;
    // Lista as tabelas de usuario (sem RDB$*). True em sucesso.
    function ListarTabelas(var Tabelas: TStringList; var Msg: string): Boolean;
    // Colunas na ordem de leitura.
    function ListarColunas(const ATabela: string;
      var Colunas: TListaColunas; var Msg: string): Boolean;
    // Abre a leitura de todas as colunas da tabela.
    function AbrirLeitura(const ATabela: string; out Leitor: ILeitorLinhas;
      var Msg: string): Boolean;
  end;

  // ------------------------------------------------------------------
  // Exportador CSV/TSV por tabela (F5-T4). Consome IDriverCatalogo.
  // ------------------------------------------------------------------
  TExportadorCSV = class(TExportadorBase)
  private
    FDriver: IDriverCatalogo;
    function ExtensaoCsv: string;   // 'tsv' (TAB) ou 'csv'
  protected
    // Escapa um campo para o CSV/TSV (RFC-4180).
    function EscaparCampo(const ATexto: string): string;
    // Aplica a politica BLOB e devolve o conteudo do campo.
    function CampoBlob(const ACel: TValorCelula; ALinha, ACol: Integer;
      const ATabela: string): string;
  public
    constructor Create; overload;
    constructor CreateComDriver(ADriver: IDriverCatalogo); overload;

    function FormatoAlvo: TFormatoExport; override;
    function Preparar(const AParams: TExportParams;
      var Msg: string): Boolean; override;
    function Executar(Runner: IProcessRunner; Sink: IOutputSink;
      var Manifesto: TManifestoExport): Boolean; override;

    property Driver: IDriverCatalogo read FDriver write FDriver;
  end;

// ------------------------------------------------------------------
// Funcoes livres (testes de escape sem rodar exportacao)
// ------------------------------------------------------------------
// True quando o campo precisa de aspas (delimitador, aspas, CR/LF).
function CampoCSVRequerAspas(const ATexto: string; ADelimitador: Char): Boolean;
// Escapa um campo (RFC-4180: aspas dobradas dentro do campo entre
// aspas). Campo vazio (e NULL) permanece vazio sem aspas.
function EscaparCampoCsv(const ATexto: string; ADelimitador: Char): string;
// Hex MAIUSCULO dos bytes (politica beHex de BLOB).
function BytesParaHex(const ABytes: array of Byte): string;
// Hex MAIUSCULO dos bytes de um AnsiString (BLOB textual sem Bytes).
function BytesParaHexAnsi(const ATexto: AnsiString): string;
// Sanitiza um nome para uso como arquivo (so A-Za-z0-9._-).
function SanitizarNomeArquivo(const ANome: string): string;

implementation

const
  K_CAMINHO_LONGO = 230;

// ------------------------------------------------------------------
// EscaparCampoCsv / CampoCSVRequerAspas / BytesParaHex / Sanitizar
// ------------------------------------------------------------------
function CampoCSVRequerAspas(const ATexto: string;
  ADelimitador: Char): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Length(ATexto) do
    case ATexto[I] of
      '"', #13, #10:
        begin
          Result := True;
          Exit;
        end;
    else
      if ATexto[I] = ADelimitador then
      begin
        Result := True;
        Exit;
      end;
    end;
end;

function EscaparCampoCsv(const ATexto: string;
  ADelimitador: Char): string;
var
  I: Integer;
begin
  if not CampoCSVRequerAspas(ATexto, ADelimitador) then
  begin
    Result := ATexto;
    Exit;
  end;
  Result := '"';
  for I := 1 to Length(ATexto) do
  begin
    if ATexto[I] = '"' then
      Result := Result + '""'
    else
      Result := Result + ATexto[I];
  end;
  Result := Result + '"';
end;

function BytesParaHex(const ABytes: array of Byte): string;
const
  Dig: array[0..15] of Char = '0123456789ABCDEF';
var
  I: Integer;
begin
  Result := '';
  for I := Low(ABytes) to High(ABytes) do
    Result := Result + Dig[ABytes[I] shr 4] + Dig[ABytes[I] and $0F];
end;

function BytesParaHexAnsi(const ATexto: AnsiString): string;
const
  Dig2: array[0..15] of Char = '0123456789ABCDEF';
var
  I: Integer;
  B: Byte;
begin
  Result := '';
  for I := 1 to Length(ATexto) do
  begin
    B := Byte(ATexto[I]);
    Result := Result + Dig2[B shr 4] + Dig2[B and $0F];
  end;
end;

function SanitizarNomeArquivo(const ANome: string): string;
var
  I: Integer;
  Ch: Char;
begin
  Result := '';
  for I := 1 to Length(ANome) do
  begin
    Ch := ANome[I];
    if ((Ch >= 'A') and (Ch <= 'Z')) or
       ((Ch >= 'a') and (Ch <= 'z')) or
       ((Ch >= '0') and (Ch <= '9')) or
       (Ch = '.') or (Ch = '_') or (Ch = '-') then
      Result := Result + Ch
    else
      Result := Result + '_';
  end;
  if Result = '' then
    Result := 'tabela';
end;

// ------------------------------------------------------------------
// TExportadorCSV
// ------------------------------------------------------------------
constructor TExportadorCSV.Create;
begin
  inherited Create;
  FDriver := nil;
end;

constructor TExportadorCSV.CreateComDriver(ADriver: IDriverCatalogo);
begin
  Create;
  FDriver := ADriver;
end;

function TExportadorCSV.FormatoAlvo: TFormatoExport;
begin
  Result := feCsv;
end;

function TExportadorCSV.ExtensaoCsv: string;
begin
  if FParams.Delimitador = #9 then
    Result := 'tsv'
  else
    Result := 'csv';
end;

function TExportadorCSV.EscaparCampo(const ATexto: string): string;
begin
  Result := EscaparCampoCsv(ATexto, FParams.Delimitador);
end;

// ------------------------------------------------------------------
// CampoBlob: aplica a politica BlobComo a uma celula de BLOB.
// beArquivo grava '<base>_blobs\<TABELA>_<linha>_<col>.blob' (bytes) e
// a celula guarda o nome do arquivo.
// ------------------------------------------------------------------
function TExportadorCSV.CampoBlob(const ACel: TValorCelula;
  ALinha, ACol: Integer; const ATabela: string): string;
var
  Buf: AnsiString;
  DirBlob: string;
  NomeArq: string;
  Fs: TFileStream;
  I: Integer;
begin
  Result := '';
  if (not FParams.IncluirBlob) or (FParams.BlobComo = beOmitir) then
    Exit;                                   // campo vazio (registrado)
  // Normaliza o conteudo do BLOB em bytes: Bytes crus do driver ou os
  // bytes ACP do Texto quando o driver entrega blob textual.
  Buf := '';
  if Length(ACel.Bytes) > 0 then
  begin
    SetLength(Buf, Length(ACel.Bytes));
    for I := 0 to Length(ACel.Bytes) - 1 do
      Buf[I + 1] := AnsiChar(ACel.Bytes[I]);
  end
  else
    Buf := ACel.Texto;
  if FParams.BlobComo = beHex then
  begin
    Result := BytesParaHexAnsi(Buf);
    Exit;
  end;
  DirBlob := IncludeTrailingPathDelimiter(FParams.PastaDestino) +
             NomeBase + '_blobs';
  ForceDirectories(DirBlob);
  if not DirectoryExists(DirBlob) then
    Exit;                                   // celula vazia + aviso abaixo
  NomeArq := SanitizarNomeArquivo(ATabela) + '_' +
             Format('%.5d', [ALinha]) + '_' + IntToStr(ACol) + '.blob';
  Fs := TFileStream.Create(IncludeTrailingPathDelimiter(DirBlob) + NomeArq,
                           fmCreate or fmShareDenyWrite);
  try
    if Buf <> '' then
      Fs.WriteBuffer(Buf[1], Length(Buf));
  finally
    Fs.Free;
  end;
  Result := NomeArq;
end;

// ------------------------------------------------------------------
// Preparar: valida driver/pasta/charset/tabelas-alvo SEM exportar.
// ------------------------------------------------------------------
function TExportadorCSV.Preparar(const AParams: TExportParams;
  var Msg: string): Boolean;
var
  DirDest: string;
  Tabelas: TStringList;
  Colunas: TListaColunas;
  Aux: string;
  I: Integer;
  Falta: string;
  MsgDriver: string;
begin
  ZerarEstado;
  FParams := AParams;
  Result := ValidarParamsBasico(Msg);
  if not Result then
    Exit;

  if FDriver = nil then
  begin
    Msg := 'Nenhum driver de catalogo informado. A exportacao CSV real ' +
           'exige o driver fbclient.dll 32-bit (decisao 9.3); use um ' +
           'driver fake/em memoria nos testes e no modo sem servidor.';
    FErroPreparacao := Msg;
    Result := False;
    Exit;
  end;
  if (FParams.Delimitador = #13) or (FParams.Delimitador = #10) or
     (FParams.Delimitador = #0) then
  begin
    Msg := 'Delimitador invalido para CSV/TSV.';
    FErroPreparacao := Msg;
    Result := False;
    Exit;
  end;

  DirDest := IncludeTrailingPathDelimiter(FParams.PastaDestino);
  if DirDest <> '' then
    ForceDirectories(DirDest);
  if not DirectoryExists(DirDest) then
  begin
    Msg := 'Nao foi possivel criar a pasta de destino: ' + DirDest +
           ' (verifique permissao de escrita).';
    FErroPreparacao := Msg;
    Result := False;
    Exit;
  end;

  // Preflight leve via driver: lista as tabelas e confere os alvos.
  Tabelas := TStringList.Create;
  try
    if not FDriver.ListarTabelas(Tabelas, MsgDriver) then
    begin
      Msg := 'Driver indisponivel ao listar tabelas: ' + MsgDriver;
      FErroPreparacao := Msg;
      Result := False;
      Exit;
    end;
    Falta := '';
    if FParams.TemAlvo then
      for I := 0 to Length(FParams.TabelasAlvo) - 1 do
        if Tabelas.IndexOf(FParams.TabelasAlvo[I]) < 0 then
        begin
          if Falta <> '' then
            Falta := Falta + ', ';
          Falta := Falta + FParams.TabelasAlvo[I];
        end;
    if Falta <> '' then
    begin
      Msg := 'Tabela(s)-alvo nao encontrada(s) no catalogo: ' + Falta;
      FErroPreparacao := Msg;
      Result := False;
      Exit;
    end;
    // Confere colunas/sobrescrever por tabela selecionada.
    for I := 0 to Tabelas.Count - 1 do
      if FParams.AlvoContem(Tabelas[I]) then
      begin
        if not FDriver.ListarColunas(Tabelas[I], Colunas, MsgDriver) then
        begin
          Msg := 'Nao foi possivel ler as colunas de ' + Tabelas[I] +
                 ': ' + MsgDriver;
          FErroPreparacao := Msg;
          Result := False;
          Exit;
        end;
        Aux := DestinoTabela(ExtensaoCsv, Tabelas[I]);
        if not CheckSobrescrever(Aux, Msg) then
        begin
          Result := False;
          Exit;
        end;
        TemAvisoCaminhoLongo(ExpandFileName(Aux));
      end;
  finally
    Tabelas.Free;
  end;

  Result := True;
  FPreparado := True;
end;

// ------------------------------------------------------------------
// Executar: exporta uma tabela por arquivo CSV/TSV + manifesto.
// Resiliente: falha de uma tabela nao aborta as demais (padrao F4).
// ------------------------------------------------------------------
function TExportadorCSV.Executar(Runner: IProcessRunner; Sink: IOutputSink;
  var Manifesto: TManifestoExport): Boolean;
var
  Tabelas: TStringList;
  MsgDriver, Msg2: string;
  I, J, Linha: Integer;
  Colunas: TListaColunas;
  Leitor: ILeitorLinhas;
  Valores: TCamposLinha;
  Arquivo: string;
  Fs: TFileStream;
  TextoLinha: string;
  CelTexto: string;
  Cel: TValorCelula;
  ErroLeitura: string;
  BytesOut: AnsiString;
  Falhas: Integer;
begin
  Result := False;
  if Manifesto = nil then
    Exit;
  if (not FPreparado) or (FParams = nil) then
  begin
    Manifesto.AddItem('', feCsv, '', -1, xeFalha,
      'Chame Preparar (com sucesso) antes de Executar.');
    Exit;
  end;

  Tabelas := TStringList.Create;
  Falhas := 0;
  try
    if not FDriver.ListarTabelas(Tabelas, MsgDriver) then
    begin
      Manifesto.AddItem('', feCsv, '', -1, xeFalha,
        'Driver indisponivel ao listar tabelas: ' + MsgDriver);
      Exit;
    end;

    for I := 0 to Tabelas.Count - 1 do
    begin
      if not FParams.AlvoContem(Tabelas[I]) then
        Continue;
      Arquivo := DestinoTabela(ExtensaoCsv, Tabelas[I]);
      if (not FParams.Sobrescrever) and FileExists(Arquivo) then
      begin
        Inc(Falhas);
        Manifesto.AddItem(Arquivo, feCsv, Tabelas[I], -1, xeFalha,
          'O arquivo de destino ja existe (marque Sobrescrever).');
        Continue;
      end;

      if not FDriver.ListarColunas(Tabelas[I], Colunas, MsgDriver) then
      begin
        Inc(Falhas);
        Manifesto.AddItem(Arquivo, feCsv, Tabelas[I], -1, xeFalha,
          'Falha ao ler colunas: ' + MsgDriver);
        Continue;
      end;
      if not FDriver.AbrirLeitura(Tabelas[I], Leitor, MsgDriver) then
      begin
        Inc(Falhas);
        Manifesto.AddItem(Arquivo, feCsv, Tabelas[I], -1, xeFalha,
          'Falha ao abrir leitura: ' + MsgDriver);
        Continue;
      end;

      Fs := TFileStream.Create(Arquivo, fmCreate or fmShareDenyWrite);
      ErroLeitura := '';
      try
        // Cabecalho (nome das colunas escapado).
        TextoLinha := '';
        for J := 0 to Length(Colunas) - 1 do
        begin
          if J > 0 then
            TextoLinha := TextoLinha + FParams.Delimitador;
          TextoLinha := TextoLinha + EscaparCampo(Colunas[J].Nome);
        end;
        TextoLinha := TextoLinha + #13#10;
        BytesOut := CodificarSaida(TextoLinha, NormalizarCharsetExport(
          FParams.CharsetSaida));
        if BytesOut <> '' then
          Fs.WriteBuffer(BytesOut[1], Length(BytesOut));

        // Linhas de dados.
        Linha := 0;
        while Leitor.ProximaLinha(Valores, Msg2) do
        begin
          Inc(Linha);
          TextoLinha := '';
          for J := 0 to Length(Colunas) - 1 do
          begin
            if J > 0 then
              TextoLinha := TextoLinha + FParams.Delimitador;
            CelTexto := '';
            if J < Length(Valores) then
            begin
              Cel := Valores[J];
              if not Cel.Nulo then
              begin
                if Cel.EhBlob then
                  CelTexto := CampoBlob(Cel, Linha, J + 1, Tabelas[I])
                else
                  CelTexto := Cel.Texto;
              end;
              // NULL permanece campo vazio (decisao de contrato F5).
            end;
            TextoLinha := TextoLinha + EscaparCampo(CelTexto);
          end;
          TextoLinha := TextoLinha + #13#10;
          BytesOut := CodificarSaida(TextoLinha, NormalizarCharsetExport(
            FParams.CharsetSaida));
          if BytesOut <> '' then
            Fs.WriteBuffer(BytesOut[1], Length(BytesOut));
        end;
        ErroLeitura := Msg2;
      finally
        Fs.Free;
      end;
      if ErroLeitura <> '' then
      begin
        Inc(Falhas);
        Manifesto.AddItem(Arquivo, feCsv, Tabelas[I], -1, xeFalha,
          'Erro lendo linhas: ' + ErroLeitura);
        SysUtils.DeleteFile(Arquivo);  // nada de arquivo parcial sujo
        Continue;
      end;
      Manifesto.AddItem(Arquivo, feCsv, Tabelas[I], Linha, xeOk,
        'csv gerado; linhas=' + IntToStr(Linha));
    end;
  finally
    Tabelas.Free;
  end;

  Result := Falhas = 0;
end;

end.