{
  TestExportReport.dpr - F5-T5: relatorio legivel do DDL (feDdl).
  ---------------------------------------------------------
  Usa o MESMO fake isql da uExportSQL (eco do stdout, sem '>').
  Cobrem: contadores (quebras de linha, frases CI sobre bytes),
  E2E exit 0 (arquivo '<base>_ddl.txt' com cabecalho + contagem +
  conteudo; temporario apagado) e E2E exit 7 (sem relatorio).
}
program TestExportReport;

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Classes, Windows,
  uKernelExec in '..\src\core\uKernelExec.pas',
  uQuoting in '..\src\core\uQuoting.pas',
  uTextCodec in '..\src\core\uTextCodec.pas',
  uLogger in '..\src\core\uLogger.pas',
  uEngineBase in '..\src\engines\uEngineBase.pas',
  uFBVersionInfo in '..\src\firebird\uFBVersionInfo.pas',
  uFBSwitchCatalog in '..\src\firebird\uFBSwitchCatalog.pas',
  uExportBase in '..\src\export\uExportBase.pas',
  uExportSQL in '..\src\export\uExportSQL.pas',
  uExportReport in '..\src\export\uExportReport.pas';

var
  Fails: Integer;
  Checks: Integer;

procedure Check(const Nome: string; Cond: Boolean; const Detalhe: string);
begin
  Inc(Checks);
  if Cond then
    WriteLn('PASS: ' + Nome)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL: ' + Nome + '  [' + Detalhe + ']');
  end;
end;

function TempRaiz: string;
var
  Buf: array[0..MAX_PATH] of Char;
  N: DWORD;
  Temp: string;
begin
  N := GetTempPath(SizeOf(Buf), PChar(@Buf[0]));
  Temp := '.\';
  if N > 0 then
    SetString(Temp, PChar(@Buf[0]), Integer(N));
  if Temp = '' then
    Temp := '.\';
  Result := IncludeTrailingPathDelimiter(Temp) + 'fbrtest_ddl_' +
            IntToStr(GetCurrentProcessId);
end;

function ObterFpc: string;
begin
  Result := SysUtils.GetEnvironmentVariable('FB_FPC');
  if Result = '' then
    Result := SysUtils.GetEnvironmentVariable('FB_FPC');
end;

function CompilarFake(const AArquivo: string): Boolean;
var
  Opt: TProcessOptions;
  R: TProcessResult;
  Exe: string;
begin
  Exe := ChangeFileExt(AArquivo, '') + '.exe';
  SysUtils.DeleteFile(Exe);
  FillChar(Opt, SizeOf(Opt), 0);
  Opt.Executable := ObterFpc;
  Opt.WorkDir := ExtractFilePath(AArquivo);
  Opt.TimeoutMs := 120000;
  Opt.KillTreeOnCancel := True;
  Opt.ConsoleCodePage := 0;
  SetLength(Opt.Args, 3);
  Opt.Args[0] := '-Mdelphi';
  Opt.Args[1] := '-o' + Exe;
  Opt.Args[2] := AArquivo;
  R := BuildAndRun(Opt, nil, nil);
  Result := R.Ok and FileExists(Exe);
end;

procedure EscreverTexto(const AArquivo, ATexto: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := ATexto;
    L.SaveToFile(AArquivo);
  finally
    L.Free;
  end;
end;

procedure CriarArquivo(const AArquivo: string; const ABytes: AnsiString);
var
  Fs: TFileStream;
begin
  Fs := TFileStream.Create(AArquivo, fmCreate or fmShareDenyNone);
  try
    if ABytes <> '' then
      Fs.WriteBuffer(ABytes[1], Length(ABytes));
  finally
    Fs.Free;
  end;
end;

function LerArquivoStr(const AArquivo: string): AnsiString;
var
  Fs: TFileStream;
begin
  Result := '';
  if not FileExists(AArquivo) then
    Exit;
  Fs := TFileStream.Create(AArquivo, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Fs.Size);
    if Fs.Size > 0 then
      Fs.ReadBuffer(Result[1], Fs.Size);
  finally
    Fs.Free;
  end;
end;

const
  K_FAKE_OK = 'program fakeisql_ok;' + #13#10 +
    'uses SysUtils;' + #13#10 +
    'var f: Text; s: string;' + #13#10 +
    'begin' + #13#10 +
    '  Assign(f, ParamStr(0) + ''.ddl.txt'');' + #13#10 +
    '  {$I-} Reset(f); {$I+}' + #13#10 +
    '  if IOResult = 0 then' + #13#10 +
    '  begin' + #13#10 +
    '    while not Eof(f) do' + #13#10 +
    '    begin' + #13#10 +
    '      ReadLn(f, s);' + #13#10 +
    '      WriteLn(s);' + #13#10 +
    '    end;' + #13#10 +
    '    Close(f);' + #13#10 +
    '  end;' + #13#10 +
    '  Halt(0);' + #13#10 +
    'end.' + #13#10;

  K_FAKE_FAIL = 'program fakeisql_fail;' + #13#10 +
    'uses SysUtils;' + #13#10 +
    'begin' + #13#10 +
    '  WriteLn(ErrOutput, ''Statement failed, SQLCODE = -607'');' + #13#10 +
    '  Halt(7);' + #13#10 +
    'end.' + #13#10;

  K_FIXTURE =
    'SET TERM ^ ;' + #13#10 +
    'CREATE TABLE CLIENTES (' + #13#10 +
    '    ID INTEGER NOT NULL,' + #13#10 +
    '    NOME VARCHAR(80)' + #13#10 +
    ');' + #13#10 +
    'CREATE TABLE PEDIDOS (' + #13#10 +
    '    ID INTEGER NOT NULL' + #13#10 +
    ');' + #13#10 +
    'COMMIT;' + #13#10;

var
  Raiz, D1: string;
  P: TExportParams;
  Ex: TExportadorReport;
  M: TManifestoExport;
  Msg: string;
  OK: Boolean;
  R: IProcessRunner;
  Ver: TVersion;
  C: TContagemDdl;
  Txt: string;
  ArqDdl: string;
  S: TSearchRec;
  AchouTmp: Boolean;
begin
  Checks := 0;
  Fails := 0;
  Raiz := TempRaiz;
  D1 := Raiz + '\fakes';
  ForceDirectories(D1);
  CriarArquivo(Raiz + '\banco.fdb', 'DB');
  Ver.Valida := True;
  Ver.Familia := bfFirebird;
  Ver.Maior := 2;
  Ver.Menor := 5;
  Ver.Revisao := 9;
  Ver.Build := 0;

  // ========== Grupo A: contadores sobre bytes ======================
  Check('A1 CRLF conta 1 quebra por linha',
        ContarQuebrasDeLinha('a' + #13#10 + 'b' + #13#10) = 2, '');
  Check('A2 LF solto conta quebras', ContarQuebrasDeLinha('x' + #10 + 'y') = 1, '');
  Check('A3 CR solto conta quebra', ContarQuebrasDeLinha('x' + #13 + 'y') = 1, '');
  Check('A4 vazio = 0 quebras', ContarQuebrasDeLinha('') = 0, '');
  Check('A5 busca CI de frase', ContarSubstringCI('a create TABLE b Create table c',
        'create table') = 2, '');
  CriarArquivo(Raiz + '\ddl_fixture.txt', K_FIXTURE);
  OK := ContarDdlNoArquivo(Raiz + '\ddl_fixture.txt', C);
  Check('A6 contagem de arquivo (fixture)', OK and (C.CreateTable = 2) and
        (C.Create >= 2) and (C.Linhas >= 8) and (C.SetTerm = 1),
        'create=' + IntToStr(C.Create) + ' linhas=' + IntToStr(C.Linhas));

  // ========== Grupo B: E2E relatorio exit 0 ========================
  EscreverTexto(D1 + '\r_fake_ok.pas', K_FAKE_OK);
  EscreverTexto(D1 + '\r_fake_fail.pas', K_FAKE_FAIL);
  Check('B0 fakes compilados',
        CompilarFake(D1 + '\r_fake_ok.pas') and
        CompilarFake(D1 + '\r_fake_fail.pas'), ObterFpc);

  if FileExists(D1 + '\r_fake_ok.exe') then
  begin
    CriarArquivo(D1 + '\r_fake_ok.exe.ddl.txt', K_FIXTURE);
    Ex := TExportadorReport.Create;
    try
      P := TExportParams.Create;
      P.Origem := Raiz + '\banco.fdb';
      P.PastaDestino := Raiz + '\out';
      P.ArquivoBase := 'meta';
      P.IsqlExe := D1 + '\r_fake_ok.exe';
      P.VersaoBin := Ver;
      P.Sobrescrever := True;
      P.TimeoutMs := 60000;
      OK := Ex.Preparar(P, Msg);
      Check('B1 preparar ok', OK and Ex.Preparado, Msg);
      ArqDdl := Ex.Destino;
      Check('B2 destino <base>_ddl.txt',
            (CompareText(ExtractFileName(ArqDdl), 'meta_ddl.txt') = 0),
            ArqDdl);
      M := TManifestoExport.Create;
      R := TProcessRunner.Create;
      try
        OK := Ex.Executar(R, nil, M);
        Check('B3 Executar True', OK, '');
        Check('B4 manifesto 1 item ok (feDdl)',
              (M.Count = 1) and (M.TudoOk) and
              (M.Itens[0].Formato = feDdl), M.ResumoParaTexto);
        Check('B5 arquivo do relatorio existe', FileExists(ArqDdl), ArqDdl);
        Txt := string(LerArquivoStr(ArqDdl));
        Check('B6 cabecalho com titulo/origem',
              (Pos('Relatorio de DDL', Txt) > 0) and
              (Pos('Origem : ', Txt) > 0), Txt);
        Check('B7 contagem aproximada no cabecalho',
              (Pos('create table', LowerCase(Txt)) > 0) and
              (Pos('aprox', LowerCase(Txt)) > 0), Txt);
        Check('B8 conteudo do extract presente no relatorio',
              (Pos('CREATE TABLE CLIENTES', Txt) > 0) and
              (Pos('COMMIT;', Txt) > 0), '');
        // nenhum temporario _ddl_*.tmp deve sobrar na pasta
        AchouTmp := False;
        if FindFirst(Raiz + '\out\*_ddl_*.tmp', faAnyFile, S) = 0 then
        begin
          AchouTmp := True;
          SysUtils.FindClose(S);
        end;
        Check('B9 temporario da captura foi apagado', not AchouTmp, '');
      finally
        M.Free;
        R := nil;
      end;
    finally
      Ex.Free;
    end;
  end
  else
    Check('B1-B9 (E2E exit0) SKIPPED - fake nao compilou', False, ObterFpc);

  // ========== Grupo C: E2E relatorio exit 7 ========================
  if FileExists(D1 + '\r_fake_fail.exe') then
  begin
    Ex := TExportadorReport.Create;
    try
      P := TExportParams.Create;
      P.Origem := Raiz + '\banco.fdb';
      P.PastaDestino := Raiz + '\out';
      P.ArquivoBase := 'meta_falha';
      P.IsqlExe := D1 + '\r_fake_fail.exe';
      P.VersaoBin := Ver;
      P.Sobrescrever := True;
      P.TimeoutMs := 60000;
      OK := Ex.Preparar(P, Msg);
      Check('C1 preparar ok (fail)', OK, Msg);
      M := TManifestoExport.Create;
      R := TProcessRunner.Create;
      try
        OK := Ex.Executar(R, nil, M);
        Check('C2 Executar False', not OK, '');
        Check('C3 manifesto 1 falha', (M.Count = 1) and M.TemFalha,
              M.ResumoParaTexto);
        Check('C4 relatorio nao fica parcial',
              not FileExists(Ex.Destino), Ex.Destino);
      finally
        M.Free;
        R := nil;
      end;
    finally
      Ex.Free;
    end;
  end
  else
    Check('C1-C4 (E2E exit7) SKIPPED - fake nao compilou', False, ObterFpc);

  WriteLn;
  WriteLn('Checks: ' + IntToStr(Checks) + '  Fails: ' + IntToStr(Fails));
  Halt(Fails);
end.