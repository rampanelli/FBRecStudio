program TestDiagProbe;

{ Testes unitarios de uDiagParser/uDiagFileProbe/uDiagReport (F1-T4/T5):
  classificacao de arquivo com BUFFERS SINTETICOS em memoria
  (cabecalhos plausiveis de banco ODS 11.2 e 12.0, backup gbak com e
  sem assinatura) + leitura em disco via %TEMP%. Nenhum binario real e
  executado. Console; exit = n. de falhas. }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Windows,
  uDiagParser in '..\src\diag\uDiagParser.pas',
  uDiagFileProbe in '..\src\diag\uDiagFileProbe.pas',
  uDiagReport in '..\src\diag\uDiagReport.pas';

var
  Fails, Checks: Integer;

procedure Check(const AName: string; ACond: Boolean);
begin
  Inc(Checks);
  if ACond then
    WriteLn('PASS: ' + AName)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL: ' + AName);
  end;
end;

// %TEMP% com terminador (D7 nao tem GetTempDir do FPC).
function TempDir: string;
var
  Buf: array[0..MAX_PATH - 1] of Char;
  N: Integer;
begin
  N := GetTempPath(SizeOf(Buf), PChar(@Buf[0]));
  Result := '';
  if N > 0 then
    Result := StrPas(PChar(@Buf[0]));
end;

type
  TBuf1K = array[0..1023] of Byte;

// Grava u16 em little-endian no offset.
procedure SetU16LE(var Buf: TBuf1K; AOff: Integer; AVal: Word);
begin
  Buf[AOff] := Byte(AVal and $FF);
  Buf[AOff + 1] := Byte((AVal shr 8) and $FF);
end;

// Cabecalho plausivel de banco ODS 11.2 (Firebird 2.5):
// pag_type=1 @0; page size @16; hdr_ods_version @18 (0x80B2);
// hdr_flags @42 (dialeto 3 = 0x0100; shutdown 0x0080 opcional).
procedure MontarODS112(var Buf: TBuf1K; AComShutdown: Boolean);
begin
  FillChar(Buf, SizeOf(Buf), 0);
  Buf[0] := 1;                       // pag_header
  SetU16LE(Buf, 16, 8192);           // hdr_page_size
  SetU16LE(Buf, 18, $80B2);          // ODS 11.2 + marca Firebird
  if AComShutdown then
    SetU16LE(Buf, 42, $0180)         // dialeto 3 + shutdown (multi)
  else
    SetU16LE(Buf, 42, $0100);        // dialeto 3
end;

// Cabecalho plausivel ODS 12.0 (Firebird 3.0): dialeto 1 (flags 0).
procedure MontarODS120(var Buf: TBuf1K);
begin
  FillChar(Buf, SizeOf(Buf), 0);
  Buf[0] := 1;
  SetU16LE(Buf, 16, 4096);
  SetU16LE(Buf, 18, $80C0);          // ODS 12.0 + marca Firebird
  SetU16LE(Buf, 42, 0);
end;

// Inicio de stream de backup: rec_physical_db (0x0E) + atributo.
procedure MontarBackup(var Buf: TBuf1K);
begin
  FillChar(Buf, SizeOf(Buf), 0);
  Buf[0] := $0E;
  Buf[1] := 4;                       // atributo (pagina de backup)
end;

// Inicio de backup multivolume: tag textual.
procedure MontarBackupTexto(var Buf: TBuf1K);
const
  TAG: string = 'InterBase/gbak,   1234567890';
var
  I: Integer;
begin
  FillChar(Buf, SizeOf(Buf), 0);
  for I := 1 to Length(TAG) do
    Buf[I - 1] := Byte(TAG[I]);
end;

var
  Buf, Buf2: TBuf1K;
  BufC: array[0..29] of Byte;
  R: TDiagResult;
  S: string;
  Caminho: string;
  H: Integer;
  V16: Word;
  V32: Longword;
  P: Integer;
begin
  Fails := 0;
  Checks := 0;

  // ============ uDiagParser (leitura segura) ============
  MontarODS112(Buf, False);
  Check('parser u16le offset 16 = 8192',
        LerU16LE(Buf, 16, V16) and (V16 = 8192));
  Check('parser u16le offset 18 = $80B2',
        LerU16LE(Buf, 18, V16) and (V16 = $80B2));
  Check('parser u16be fora com zeros = 0',
        LerU16BE(Buf, 60, V16) and (V16 = 0));
  Buf[60] := $12;
  Buf[61] := $34;
  Check('parser u16be = $1234', LerU16BE(Buf, 60, V16) and (V16 = $1234));
  Check('parser u16le de $1234 = $3412', LerU16LE(Buf, 60, V16) and
        (V16 = $3412));
  Buf[100] := $DE;
  Buf[101] := $AD;
  Buf[102] := $BE;
  Buf[103] := $EF;
  Check('parser u32le = $EFBEADDE', LerU32LE(Buf, 100, V32) and
        (V32 = $EFBEADDE));
  Check('parser u32be = $DEADBEEF', LerU32BE(Buf, 100, V32) and
        (V32 = $DEADBEEF));
  Check('parser fora do buffer -> false',
        (not LerU16LE(Buf, 1023, V16)) and (not LerU32LE(Buf, 1021, V32)));
  MontarBackupTexto(Buf2);
  Check('procurar ascii em backup (case-insensitive)',
        ProcurarAscii(Buf2, 'INTERBASE/GB', 0, P) and (P = 0));

  // ============ banco ODS 11.2 (dialeto 3, sem shutdown) ============
  MontarODS112(Buf, False);
  AnalisarBuffer(Buf, 1024, '.fdb', 1024, R);
  Check('ods112 classificado como banco', R.FileKind = kDatabase);
  Check('ods112 classe por cabecalho pagina 0',
        Pos('pagina 0', R.ClassificadoPor) > 0);
  Check('ods112 ODS 11.2', (R.OdsMaior = 11) and (R.OdsMenor = 2));
  Check('ods112 page size 8192', R.PageSize = 8192);
  Check('ods112 dialeto 3', R.Dialect = 3);
  Check('ods112 sem shutdown', not R.Shutdown);
  Check('ods112 sem fss suspeito (heuristica ausente na F1)',
        not R.SuspiciousFss);
  Check('ods112 tecnica T3 validar', Pos('T3', R.RecommendedTech) > 0);

  // ============ banco ODS 11.2 com shutdown ============
  MontarODS112(Buf, True);
  AnalisarBuffer(Buf, 1024, '.fdb', 1024, R);
  Check('ods112 shutdown detectado', R.Shutdown);
  Check('ods112 shutdown sugere activate',
        Pos('activate', R.RecommendedTech) > 0);

  // ============ banco ODS 12.0 (dialeto 1, page 4096) ============
  MontarODS120(Buf);
  AnalisarBuffer(Buf, 1024, '.fdb', 1024, R);
  Check('ods120 ODS 12.0', (R.OdsMaior = 12) and (R.OdsMenor = 0));
  Check('ods120 page size 4096', R.PageSize = 4096);
  Check('ods120 dialeto 1 (sem flag)', R.Dialect = 1);

  // ============ backup gbak com assinatura ============
  MontarBackup(Buf);
  AnalisarBuffer(Buf, 1024, '.fbk', 4096, R);   // 4096 multiplo de 512
  Check('backup assinatura -> kBackup', R.FileKind = kBackup);
  Check('backup classe por assinatura',
        Pos('assinatura do stream', R.ClassificadoPor) > 0);
  Check('backup recomenda T1', Pos('T1', R.RecommendedTech) > 0);

  // assinatura vence extensao: .fdb com conteudo de backup
  MontarBackup(Buf);
  AnalisarBuffer(Buf, 1024, '.fdb', 4096, R);
  Check('conteudo backup > extensao .fdb', R.FileKind = kBackup);
  Check('nota de divergencia de extensao',
        Pos('extensao de banco', R.Notes) > 0);

  // backup textual (multivolume)
  MontarBackupTexto(Buf2);
  AnalisarBuffer(Buf2, 1024, '.fbk', 2048, R);
  Check('backup textual -> kBackup', R.FileKind = kBackup);

  // backup SEM assinatura (fallback: extensao .fbk)
  FillChar(Buf, SizeOf(Buf), 0);
  AnalisarBuffer(Buf, 1024, '.fbk', 512, R);
  Check('sem assinatura .fbk -> kBackup (proval)',
        (R.FileKind = kBackup) and
        (Pos('sem assinatura', R.ClassificadoPor) > 0));
  Check('backup proval tem nota', Pos('backup provavel', R.Notes) > 0);

  // ============ nao reconhecido / extensao sozinha ============
  FillChar(Buf, SizeOf(Buf), 0);
  AnalisarBuffer(Buf, 1024, '.bin', 100, R);
  Check('conteudo qualquer .bin -> desconhecido', R.FileKind = kUnknown);
  Check('desconhecido sem tecnica', R.RecommendedTech = '');

  Buf[0] := 0;
  AnalisarBuffer(Buf, 1024, '.fdb', 100, R);
  Check('extensao .fdb sem cabecalho -> banco proval',
        (R.FileKind = kDatabase) and
        (Pos('cabecalho nao reconhecido', R.ClassificadoPor) > 0));

  // buffer REALMENTE curto (30 bytes): flags em 42 fora do alcance
  FillChar(BufC, SizeOf(BufC), 0);
  BufC[0] := 1;
  BufC[16] := 0;                     // page size 8192 = $2000 (LE)
  BufC[17] := $20;
  BufC[18] := $B2;                   // ODS 11.2 + marca Firebird
  BufC[19] := $80;
  AnalisarBuffer(BufC, 30, '.fdb', 30, R);
  Check('buffer curto mantem banco (parcial)',
        (R.FileKind = kDatabase) and (Pos('curto', R.Notes) > 0) and
        (R.Dialect = 0));

  AnalisarBuffer(Buf, 0, '.fbk', 0, R);
  Check('arquivo vazio .fbk -> backup proval', R.FileKind = kBackup);

  // ============ DiagnosticarArquivo em disco (%TEMP%) ============
  Caminho := ExcludeTrailingPathDelimiter(TempDir) + '\fbrec_f1_' +
             FormatDateTime('hhnnsszzz', Now) + '.fdb';
  H := FileCreate(Caminho);
  if H >= 0 then
  begin
    MontarODS112(Buf, False);
    FileWrite(H, Buf, 1024);
    FileClose(H);
    Check('diagnostico em disco abre', DiagnosticarArquivo(Caminho, R));
    if R.FileKind = kDatabase then
    begin
      Check('disco: ODS 11.2', (R.OdsMaior = 11) and (R.OdsMenor = 2));
      Check('disco: tamanho gravado', R.FileSize = 1024);
    end
    else
      Check('disco: falhou classificacao', False);
    SysUtils.DeleteFile(Caminho);
  end
  else
    Check('criacao do arquivo temporario', False);

  Check('arquivo inexistente -> false + nota',
        (not DiagnosticarArquivo('Z:\x\nao_existe_1.fdb', R)) and
        (Pos('nao encontrado', R.Notes) > 0));

  // ============ uDiagReport ============
  MontarODS112(Buf, True);
  AnalisarBuffer(Buf, 1024, '.fdb', 1024, R);
  S := RelatorioDoArquivo('C:\x\exemplo.fdb', R);
  Check('relatorio tem classificacao',
        Pos('Classificacao', S) > 0);
  Check('relatorio tem ODS 11.2', Pos('11.2', S) > 0);
  Check('relatorio mostra shutdown', Pos('shutdown', S) > 0);
  S := ResumoDoDiagnostico(R);
  Check('resumo compacto contem ODS',
        (Pos('ODS', S) > 0) and (Pos('T3', S) > 0));

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.