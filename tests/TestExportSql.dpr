{
  TestExportSql.dpr - F5: exportador SQL/DDL (feSql) + captura de stdout.
  ---------------------------------------------------------
  Estrategia (padrao TestEngineGbak): fakes isql compilados com o
  proprio FPC em %TEMP%. SEM bins reais nesta maquina.

  Cobrem: MontarArgvIsqlExtract (catalogo; -extract/-user/-password/
  -charset; banco por ultimo), validacoes do Preparar, E2E fake isql
  exit 0 (arquivo .sql fiel ao stdout capturado; manifesto por saida),
  E2E exit 7 (sem arquivo parcial), CapturarStdoutParaArquivo com
  runner interno e com teto de bytes (cancelamento) e o codec de
  charset de saida (UTF8 via CodificarSaida, independente do ACP).
}
program TestExportSql;

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
  uExportSQL in '..\src\export\uExportSQL.pas';

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
  Result := IncludeTrailingPathDelimiter(Temp) + 'fbrtest_sql_' +
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

function ContarLinhas(const ATexto: string): Int64;
var
  I: Integer;
begin
  Result := 0;
  if ATexto = '' then
    Exit;
  Result := 1;
  for I := 1 to Length(ATexto) do
    if ATexto[I] = #10 then
      Inc(Result);
  if ATexto[Length(ATexto)] = #10 then
    Dec(Result);
end;

// ------------------------------------------------------------------
// Fakes isql: ecoam '<exe>.ddl.txt' no stdout (ok); erro no stderr
// (fail); 5000 linhas (many). Nada de redirecionamento '>' de shell.
// ------------------------------------------------------------------
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
    '  WriteLn(ErrOutput, ''There was an error'');' + #13#10 +
    '  Halt(7);' + #13#10 +
    'end.' + #13#10;

  K_FAKE_MANY = 'program fakeisql_many;' + #13#10 +
    'uses SysUtils;' + #13#10 +
    'var i: Integer;' + #13#10 +
    'begin' + #13#10 +
    '  for i := 1 to 5000 do' + #13#10 +
    '    WriteLn(''linha de teste - xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'');' +
    #13#10 +
    '  Halt(0);' + #13#10 +
    'end.' + #13#10;

  // Fixture DDL: conteudo ecoado pelo isql fake (metadata/DDL).
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
  Ex: TExportadorSQL;
  M: TManifestoExport;
  Msg: string;
  OK: Boolean;
  R: IProcessRunner;
  Argv: TStringArray;
  I: Integer;
  J: Integer;
  Todo: string;
  Cat: ISwitchCatalog;
  Ver: TVersion;
  Opt: TCapturaOptions;
  Capt: TResultadoCaptura;
  Conteudo: AnsiString;
  Esperado: string;
  LinhasEsperadas: Int64;
  BytesAltos: Integer;
begin
  Checks := 0;
  Fails := 0;
  Raiz := TempRaiz;
  D1 := Raiz + '\fakes';
  ForceDirectories(D1);

  Cat := CriarCatalogPadrao;
  Ver.Valida := True;
  Ver.Familia := bfFirebird;
  Ver.Maior := 2;
  Ver.Menor := 5;
  Ver.Revisao := 9;
  Ver.Build := 0;

  // ========== Grupo A: MontarArgvIsqlExtract (catalogo) ============
  MontarArgvIsqlExtract('', '', '', Raiz + '\banco.fdb', nil, Ver,
                        Argv, Msg);
  Check('A1 catalogo nil falha com Msg', (Msg <> '') and (Length(Argv) = 0),
        Msg);

  MontarArgvIsqlExtract('', '', '', '', Cat, Ver, Argv, Msg);
  Check('A2 origem vazia falha com Msg', (Msg <> '') and (Length(Argv) = 0),
        Msg);

  MontarArgvIsqlExtract('', '', '', Raiz + '\banco.fdb', Cat, Ver,
                        Argv, Msg);
  Check('A3 sem credenciais/charset', (Msg = '') and (Length(Argv) = 2) and
        (Argv[0] = '-extract') and (Pos('banco.fdb', Argv[1]) > 0),
        'len=' + IntToStr(Length(Argv)));

  MontarArgvIsqlExtract('sysdba', 's3cr', '', Raiz + '\banco.fdb', Cat, Ver,
                        Argv, Msg);
  Check('A4 com credenciais', (Length(Argv) = 6) and
        (Argv[0] = '-extract') and (Argv[1] = '-user') and
        (Argv[2] = 'sysdba') and (Argv[3] = '-password') and
        (Argv[4] = 's3cr') and (Argv[5] = Raiz + '\banco.fdb'), Msg);

  MontarArgvIsqlExtract('', '', 'UTF8', Raiz + '\banco.fdb', Cat, Ver,
                        Argv, Msg);
  Check('A5 charset UTF8 vira -charset UTF8',
        (Length(Argv) = 4) and (Argv[1] = '-charset') and (Argv[2] = 'UTF8'),
        'len=' + IntToStr(Length(Argv)));

  MontarArgvIsqlExtract('', '', 'SEM-CHARSET-X', Raiz + '\banco.fdb', Cat,
                        Ver, Argv, Msg);
  Todo := '';
  for I := 0 to Length(Argv) - 1 do
    Todo := Todo + '|' + Argv[I];
  Check('A6 charset desconhecido omitido', Pos('-charset', Todo) = 0, Todo);

  MontarArgvIsqlExtract('sysdba', 's3cr', 'WIN1252', Raiz + '\b.fdb', Cat,
                        Ver, Argv, Msg);
  Check('A7 ordem completa (extract,user,password,charset,banco)',
        (Length(Argv) = 8) and (Argv[0] = '-extract') and
        (Argv[1] = '-user') and (Argv[2] = 'sysdba') and
        (Argv[3] = '-password') and (Argv[4] = 's3cr') and
        (Argv[5] = '-charset') and (Argv[6] = 'WIN1252') and
        (Argv[7] = Raiz + '\b.fdb'), Msg);

  // ========== Grupo B: validacoes do Preparar ======================
  Ex := TExportadorSQL.Create;
  try
    P := TExportParams.Create;
    P.Origem := Raiz + '\banco.fdb';
    P.PastaDestino := Raiz + '\out';
    P.ArquivoBase := 'dump';
    P.VersaoBin := Ver;
    P.Sobrescrever := False;
    P.TimeoutMs := 60000;
    CriarArquivo(P.Origem, 'DB');

    P.IsqlExe := '';
    OK := Ex.Preparar(P, Msg);
    Check('B1 preparar sem IsqlExe falha', (not OK) and (Msg <> ''), Msg);

    P.IsqlExe := Raiz + '\nao_existe_isql.exe';
    OK := Ex.Preparar(P, Msg);
    Check('B2 preparar com IsqlExe inexistente falha', (not OK) and
          (Msg <> ''), Msg);

    P.IsqlExe := 'x';
    P.Origem := Raiz + '\nao_existe.fdb';
    OK := Ex.Preparar(P, Msg);
    Check('B3 preparar com origem inexistente falha', (not OK) and
          (Msg <> ''), Msg);
  finally
    Ex.Free;
  end;

  // ========== Grupo C: E2E fake isql exit 0 ========================
  EscreverTexto(D1 + '\fakeisql_ok.pas', K_FAKE_OK);
  EscreverTexto(D1 + '\fakeisql_fail.pas', K_FAKE_FAIL);
  EscreverTexto(D1 + '\fakeisql_many.pas', K_FAKE_MANY);
  Check('C0 fakes compilados',
        CompilarFake(D1 + '\fakeisql_ok.pas') and
        CompilarFake(D1 + '\fakeisql_fail.pas') and
        CompilarFake(D1 + '\fakeisql_many.pas'), ObterFpc);

  if FileExists(D1 + '\fakeisql_ok.exe') then
  begin
    // Fixture lida pelo fake e ecoada no stdout (capturado, sem '>').
    CriarArquivo(D1 + '\fakeisql_ok.exe.ddl.txt', K_FIXTURE);
    LinhasEsperadas := ContarLinhas(K_FIXTURE);

    Ex := TExportadorSQL.Create;
    try
      P := TExportParams.Create;
      P.Origem := Raiz + '\banco.fdb';
      P.PastaDestino := Raiz + '\out';
      P.ArquivoBase := 'dump';
      P.IsqlExe := D1 + '\fakeisql_ok.exe';
      P.VersaoBin := Ver;
      P.Sobrescrever := True;
      P.IncluirDados := True;
      P.TimeoutMs := 60000;
      OK := Ex.Preparar(P, Msg);
      Check('C1 preparar ok', OK and Ex.Preparado, Msg);
      Check('C2 destino .sql', (CompareText(ExtractFileName(Ex.Destino),
            'dump.sql') = 0), Ex.Destino);

      M := TManifestoExport.Create;
      R := TProcessRunner.Create;
      try
        OK := Ex.Executar(R, nil, M);
        Check('C3 Executar exit0 True', OK, '');
        Check('C4 manifesto 1 item ok',
              (M.Count = 1) and (M.TudoOk) and (not M.TemFalha),
              M.ResumoParaTexto);
        Check('C5 item feSql/linhas/status',
              (M.Itens[0].Formato = feSql) and
              (M.Itens[0].Linhas > 0) and (M.Itens[0].Status = xeOk),
              M.Itens[0].Detalhe);
        Check('C6 arquivo .sql criado', FileExists(Ex.Destino), Ex.Destino);
        Conteudo := LerArquivoStr(Ex.Destino);
        Esperado := K_FIXTURE;
        // Remove o CRLF final do esperado: o exportador grava CRLF apos
        // a ultima linha capturada (comparacao tolerante ao terminator).
        if Copy(Esperado, Length(Esperado), 1) = #10 then
          Delete(Esperado, Length(Esperado), 1);
        if Copy(Esperado, Length(Esperado), 1) = #13 then
          Delete(Esperado, Length(Esperado), 1);
        Check('C7 conteudo do .sql fiel ao stdout capturado',
              (Conteudo = Esperado) or
              (Trim(Conteudo) = Trim(Esperado)) or
              (TrimRight(Conteudo) = TrimRight(Esperado)),
              'bytes=' + IntToStr(Length(Conteudo)));
        Check('C8 manifesto linhas = linhas do extract',
              (M.Itens[0].Linhas = LinhasEsperadas) or
              (M.Itens[0].Linhas = LinhasEsperadas + 1),
              IntToStr(M.Itens[0].Linhas) + ' x ' +
              IntToStr(LinhasEsperadas));
        Check('C9 nota de incluir dados registrada no detalhe',
              Pos('driver', LowerCase(M.Itens[0].Detalhe)) > 0,
              M.Itens[0].Detalhe);
      finally
        M.Free;
        R := nil;
      end;
    finally
      Ex.Free;
    end;
  end
  else
    Check('C1-C9 (E2E exit0) SKIPPED - fake nao compilou', False, ObterFpc);

  // ========== Grupo D: E2E fake isql exit 7 ========================
  if FileExists(D1 + '\fakeisql_fail.exe') then
  begin
    Ex := TExportadorSQL.Create;
    try
      P := TExportParams.Create;
      P.Origem := Raiz + '\banco.fdb';
      P.PastaDestino := Raiz + '\out';
      P.ArquivoBase := 'vai_falhar';
      P.IsqlExe := D1 + '\fakeisql_fail.exe';
      P.VersaoBin := Ver;
      P.Sobrescrever := True;
      P.TimeoutMs := 60000;
      OK := Ex.Preparar(P, Msg);
      Check('D1 preparar ok (E2E fail)', OK, Msg);
      M := TManifestoExport.Create;
      R := TProcessRunner.Create;
      try
        OK := Ex.Executar(R, nil, M);
        Check('D2 Executar exit7 False', not OK, '');
        Check('D3 manifesto 1 falha', (M.Count = 1) and M.TemFalha,
              M.ResumoParaTexto);
        Check('D4 detalhe com erro do isql', M.Itens[0].Detalhe <> '',
              M.Itens[0].Detalhe);
        Check('D5 arquivo .sql parcial NAO existe', not FileExists(Ex.Destino),
              Ex.Destino);
      finally
        M.Free;
        R := nil;
      end;
    finally
      Ex.Free;
    end;
  end
  else
    Check('D1-D5 (E2E exit7) SKIPPED - fake nao compilou', False, ObterFpc);

  // ========== Grupo E: CapturarStdoutParaArquivo (runner interno) ==
  if FileExists(D1 + '\fakeisql_many.exe') then
  begin
    FillChar(Opt, SizeOf(Opt), 0);
    Opt.Executavel := D1 + '\fakeisql_many.exe';
    Opt.WorkDir := '';
    Opt.Destino := Raiz + '\captura_cheia.txt';
    Opt.Charset := 'ANSI';
    Opt.TetoBytes := 0;              // sem teto
    Opt.TimeoutMs := 60000;
    Opt.KillTree := True;
    Opt.ConsoleCodePage := 0;
    Capt := CapturarStdoutParaArquivo(nil, Opt, nil, nil);
    Check('E1 captura cheia Ok', Capt.Ok and (Capt.Erro = ''), Capt.Erro);
    Check('E2 5000 linhas capturadas sem teto',
          (not Capt.EstourouTeto) and (Capt.Linhas = 5000),
          'linhas=' + IntToStr(Capt.Linhas));
    Check('E3 arquivo da captura existe', FileExists(Opt.Destino),
          Opt.Destino);

    // Teto pequeno: estoura, cancela o processo e descreve o erro.
    FillChar(Opt, SizeOf(Opt), 0);
    Opt.Executavel := D1 + '\fakeisql_many.exe';
    Opt.Destino := Raiz + '\captura_teto.txt';
    Opt.Charset := 'ANSI';
    Opt.TetoBytes := 4096;
    Opt.TimeoutMs := 60000;
    Opt.KillTree := True;
    Opt.ConsoleCodePage := 0;
    Capt := CapturarStdoutParaArquivo(nil, Opt, nil, nil);
    Check('E4 teto estoura (Ok False)', (not Capt.Ok) and Capt.EstourouTeto,
          Capt.Erro);
    Check('E5 erro de teto descrito', Capt.Erro <> '', Capt.Erro);
    Check('E6 arquivo parcial da captura existe (incompleto)',
          FileExists(Opt.Destino), Opt.Destino);
    if FileExists(Opt.Destino) then
      SysUtils.DeleteFile(Opt.Destino);
    if FileExists(Raiz + '\captura_cheia.txt') then
      SysUtils.DeleteFile(Raiz + '\captura_cheia.txt');
  end
  else
    Check('E1-E6 (captura) SKIPPED - fake nao compilou', False, ObterFpc);

  // ========== Grupo F: codec de charset (CodificarSaida, base) =====
  // Um caractere ACP acima de 127 vira >= 2 bytes UTF-8 (>= $80),
  // independentemente do ACP da maquina de teste.
  Conteudo := CodificarSaida('a' + Char($E7) + 'b', 'UTF8');
  BytesAltos := 0;
  for J := 1 to Length(Conteudo) do
    if Byte(Conteudo[J]) >= $80 then
      Inc(BytesAltos);
  Check('F1 UTF8: acento vira bytes multibyte (>=2 bytes >= $80)',
        (Length(Conteudo) >= 4) and (BytesAltos >= 2),
        'len=' + IntToStr(Length(Conteudo)) + ' altos=' +
        IntToStr(BytesAltos));
  Conteudo := CodificarSaida('ABC', 'UTF8');
  Check('F2 ASCII preservado no UTF8', Conteudo = 'ABC', '');
  Conteudo := CodificarSaida('ABC', 'ANSI');
  Check('F3 ANSI = bytes ACP diretos', Conteudo = 'ABC', '');
  Conteudo := CodificarSaida('', 'UTF8');
  Check('F4 texto vazio -> bytes vazios', Conteudo = '', '');
  Conteudo := CodificarSaida('a;b"c', 'ANSI');
  Check('F5 sinais e aspas preservados no ANSI', Conteudo = 'a;b"c', '');

  WriteLn;
  WriteLn('Checks: ' + IntToStr(Checks) + '  Fails: ' + IntToStr(Fails));
  Halt(Fails);
end.