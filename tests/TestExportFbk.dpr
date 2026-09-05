{
  TestExportFbk.dpr - F5: exportador FBK (feFbk) - testes.
  ---------------------------------------------------------
  Estrategia (padrao TestEngineGbak): fakes compilados com o proprio
  FPC em %TEMP%; sem isql/gbak/fbclient reais nesta maquina.

  Cobrem: validacoes do Preparar (origem/pasta/charset/binario/
  sobrescrever/extensao .fbk), argv via TMotorGbak+ISwitchCatalog e
  E2E com fake gbak exit 0 / exit 7 (manifesto, arquivo, parcial).
}
program TestExportFbk;

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
  uEngineGbak in '..\src\engines\uEngineGbak.pas',
  uExportBase in '..\src\export\uExportBase.pas',
  uExportFBK in '..\src\export\uExportFBK.pas';

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
  Result := IncludeTrailingPathDelimiter(Temp) + 'fbrtest_fbk_' +
            IntToStr(GetCurrentProcessId);
end;

function ExisteArquivo(const A: string): Boolean;
begin
  Result := FileExists(A);
end;

// ------------------------------------------------------------------
// FPC (mesmo compilador dos fakes): env FB_FPC ou caminho fixo.
// ------------------------------------------------------------------
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

// ------------------------------------------------------------------
// Sink que registra eventos (nunca deve vazar a senha em claro).
// ------------------------------------------------------------------
type
  TCapEventos = class(TInterfacedObject, IOutputSink)
  public
    Eventos: TStringList;
    constructor Create;
    procedure OnLine(AStreamId: TStreamId; const ALine: string);
    procedure OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
  end;

constructor TCapEventos.Create;
begin
  inherited Create;
  Eventos := TStringList.Create;
end;

procedure TCapEventos.OnLine(AStreamId: TStreamId; const ALine: string);
begin
  // stdout do gbak fake e irrelevante para o teste de vazamento.
end;

procedure TCapEventos.OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
begin
  Eventos.Add(AInfo);
end;

// ------------------------------------------------------------------
// Gera os fontes dos fakes (ASCII) e os compila em D1.
// ------------------------------------------------------------------
function EscreverFakeOk(const AArquivo: string): Boolean;
const
  S = 'program fakegbak_ok;' + #13#10 +
      'uses SysUtils;' + #13#10 +
      'var i: Integer; f: Text; ArgsFile, Dest: string;' + #13#10 +
      'begin' + #13#10 +
      '  ArgsFile := ParamStr(0) + ''.args.txt'';' + #13#10 +
      '  Assign(f, ArgsFile); Rewrite(f);' + #13#10 +
      '  for i := 1 to ParamCount do WriteLn(f, ParamStr(i));' + #13#10 +
      '  Close(f);' + #13#10 +
      '  Dest := ParamStr(ParamCount);' + #13#10 +
      '  Assign(f, Dest); Rewrite(f);' + #13#10 +
      '  WriteLn(f, ''fake backup content'');' + #13#10 +
      '  Close(f);' + #13#10 +
      '  Halt(0);' + #13#10 +
      'end.' + #13#10;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := S;
    L.SaveToFile(AArquivo);
    Result := CompilarFake(AArquivo);
  finally
    L.Free;
  end;
end;

function EscreverFakeFail(const AArquivo: string): Boolean;
const
  S = 'program fakegbak_fail;' + #13#10 +
      'uses SysUtils;' + #13#10 +
      'begin' + #13#10 +
      '  WriteLn(ErrOutput, ''gbak: ERROR falha simulada de backup'');' + #13#10 +
      '  Halt(7);' + #13#10 +
      'end.' + #13#10;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := S;
    L.SaveToFile(AArquivo);
    Result := CompilarFake(AArquivo);
  finally
    L.Free;
  end;
end;

procedure EscreverBancoFake(const AArquivo: string);
var
  Fs: TFileStream;
begin
  Fs := TFileStream.Create(AArquivo, fmCreate or fmShareDenyNone);
  try
    Fs.WriteBuffer('FB TEST DATABASE'[1], 16);
  finally
    Fs.Free;
  end;
end;

function NovosParams: TExportParams;
var
  P: TExportParams;
begin
  P := TExportParams.Create;
  P.Origem := TempRaiz + '\banco.fdb';
  P.PastaDestino := TempRaiz + '\out';
  P.ArquivoBase := 'backup';
  P.Sobrescrever := False;
  P.TimeoutMs := 60000;
  P.Verboso := True;
  P.NoGC := True;
  P.Usuario := 'sysdba';
  P.Senha := 'segredo';
  P.VersaoBin.Valida := True;
  P.VersaoBin.Maior := 2;
  P.VersaoBin.Menor := 5;
  P.VersaoBin.Revisao := 9;
  Result := P;
end;

var
  Raiz, D1, Origem, ArgsOk, ArgsFail: string;
  P: TExportParams;
  PlanoB: TPlanoGbak;
  MotorB: TMotorGbak;
  MsgAmb: string;
  Ex: TExportadorFBK;
  M: TManifestoExport;
  CapIntf: IOutputSink;
  Msg: string;
  OK: Boolean;
  Cap: TCapEventos;
  R: IProcessRunner;
  Args: TStringList;
  Todo: string;
  I: Integer;
begin
  Checks := 0;
  Fails := 0;
  Raiz := TempRaiz;
  D1 := Raiz + '\fakes';
  ForceDirectories(D1);
  Origem := Raiz + '\banco.fdb';
  ArgsOk := D1 + '\fakegbak_ok.exe';
  ArgsFail := D1 + '\fakegbak_fail.exe';

  EscreverBancoFake(Origem);

  // Compila os fakes UMA vez (antes dos grupos que usam o gbak fake).
  Check('C0 fakes compilados',
        EscreverFakeOk(D1 + '\fakegbak_ok.pas') and
        EscreverFakeFail(D1 + '\fakegbak_fail.pas'), ObterFpc);

  // ========== Grupo A: Preparar - validacoes (sem processo) =========
  Ex := TExportadorFBK.Create;
  try
    P := NovosParams;

    // A1: exe vazio
    P.IsqlExe := '';
    P.GbakExe := '';
    OK := Ex.Preparar(P, Msg);
    Check('A1 preparar sem GbakExe falha', (not OK) and (Msg <> ''), Msg);

    // A2: exe inexistente
    P := NovosParams;
    P.GbakExe := Raiz + '\nao_existe_gbak.exe';
    OK := Ex.Preparar(P, Msg);
    Check('A2 preparar com GbakExe inexistente falha', (not OK) and (Msg <> ''),
          Msg);

    // A3: origem inexistente
    P := NovosParams;
    P.GbakExe := ArgsOk;
    P.Origem := Raiz + '\nao_existe.fdb';
    OK := Ex.Preparar(P, Msg);
    Check('A3 preparar com origem inexistente falha', (not OK) and (Msg <> ''),
          Msg);

    // A4: pasta destino vazia
    P := NovosParams;
    P.GbakExe := ArgsOk;
    P.PastaDestino := '';
    OK := Ex.Preparar(P, Msg);
    Check('A4 preparar sem pasta destino falha', (not OK) and (Msg <> ''), Msg);

    // A5: charset invalido
    P := NovosParams;
    P.GbakExe := ArgsOk;
    P.CharsetSaida := 'SEM-CHARSET-X';
    OK := Ex.Preparar(P, Msg);
    Check('A5 preparar com charset invalido falha', (not OK) and (Msg <> ''),
          Msg);

    // A6: destino ja existe sem Sobrescrever
    P := NovosParams;
    P.GbakExe := ArgsOk;
    P.Sobrescrever := False;
    ForceDirectories(P.PastaDestino);
    with TStringList.Create do
    begin
      Text := 'velho';
      SaveToFile(P.PastaDestino + '\backup.fbk');
      Free;
    end;
    OK := Ex.Preparar(P, Msg);
    Check('A6 destino existente sem sobrescrever falha', (not OK),
          Msg + ' / ' + Ex.Destino);
    Check('A6b Destino aponta .fbk', Ex.Destino <> '', Ex.Destino);

    // A7: mesmo destino com Sobrescrever ok
    P.Sobrescrever := True;
    OK := Ex.Preparar(P, Msg);
    Check('A7 destino existente com sobrescrever passa', OK, Msg);

    // A8: extensao .fbk garantida (ArquivoBase com outra extensao)
    P := NovosParams;
    P.GbakExe := ArgsOk;
    P.ArquivoBase := 'x.foo';
    OK := Ex.Preparar(P, Msg);
    Check('A8 arquivo base x.foo vira x.fbk', OK and
          (CompareText(ExtractFileName(Ex.Destino), 'x.fbk') = 0),
          Ex.Destino + ' / ' + Msg);

    // A9: arquivo base ja .fbk permanece
    P.ArquivoBase := 'backup.fbk';
    P.Sobrescrever := True;
    OK := Ex.Preparar(P, Msg);
    Check('A9 arquivo base .fbk permanece .fbk', OK and
          (CompareText(ExtractFileName(Ex.Destino), 'backup.fbk') = 0),
          Ex.Destino);

    // A10: versao invalida impede (catalogo gbak por versao)
    P := NovosParams;
    P.GbakExe := ArgsOk;
    P.VersaoBin.Valida := False;
    OK := Ex.Preparar(P, Msg);
    Check('A10 versao invalida falha no preparar', (not OK) and (Msg <> ''),
          Msg);
  finally
    Ex.Free;
  end;

  // ========== Grupo B: argv montado pelo TMotorGbak (catalogo) =====
  PlanoB := TPlanoGbak.Create;
  MotorB := nil;
  try
    PlanoB.GbakExe := ArgsOk;
    PlanoB.VersaoGbak.Valida := True;
    PlanoB.VersaoGbak.Familia := bfFirebird;
    PlanoB.VersaoGbak.Maior := 2;
    PlanoB.VersaoGbak.Menor := 5;
    PlanoB.VersaoGbak.Revisao := 9;
    PlanoB.Origem := Raiz + '\banco.fdb';
    PlanoB.Destino := Raiz + '\out\b_argv.fbk';
    PlanoB.Modo := mgBackup;
    PlanoB.Sobrescrever := True;
    PlanoB.Usuario := 'sysdba';
    PlanoB.Senha := 'segredo';
    PlanoB.Verboso := True;
    PlanoB.NoGC := True;
    MotorB := TMotorGbak.Create(nil);
    MotorB.AtribuirPlano(PlanoB);
    MsgAmb := '';
    Check('B1 ValidarAmbiente ok', MotorB.ValidarAmbiente(MsgAmb), MsgAmb);
    Check('B1b BuildArgs ok', MotorB.BuildArgs, MotorB.ErroAmbiente);
    Check('B2 Argv montado', Length(MotorB.Argv) > 0, 'argv vazio');
    Todo := '';
    for I := 0 to Length(MotorB.Argv) - 1 do
    begin
      if I > 0 then
        Todo := Todo + '|';
      Todo := Todo + MotorB.Argv[I];
    end;
    Check('B3 contem -b (backup)', Pos('-b', Todo) > 0, Todo);
    Check('B4 contem -v (verboso)', Pos('-v', Todo) > 0, Todo);
    Check('B5 contem -g (no gc)', Pos('-g', Todo) > 0, Todo);
    Check('B6 origem/destino sao os 2 ultimos operandos',
          (Length(MotorB.Argv) >= 2) and
          (CompareText(MotorB.Argv[Length(MotorB.Argv) - 2],
                       Raiz + '\banco.fdb') = 0) and
          (CompareText(MotorB.Argv[Length(MotorB.Argv) - 1],
                       Raiz + '\out\b_argv.fbk') = 0),
          Todo);
  finally
    MotorB.Free;
    PlanoB.Free;
  end;

  // ========== Grupo C: E2E fake gbak exit 0 =========================
  if FileExists(ArgsOk) then
  begin
    Ex := TExportadorFBK.Create;
    try
      P := NovosParams;
      P.GbakExe := ArgsOk;
      P.Sobrescrever := True;
      OK := Ex.Preparar(P, Msg);
      Check('C1 preparar ok (E2E)', OK and Ex.Preparado, Msg);

      M := TManifestoExport.Create;
      Cap := TCapEventos.Create;
      CapIntf := Cap;      // vida pela interface (refcount), nao Free
      R := TProcessRunner.Create;
      try
        OK := Ex.Executar(R, CapIntf, M);
        Check('C2 Executar exit0 retorna True', OK, '');
        Check('C3 manifesto com 1 item ok', (M.Count = 1) and
              (M.TudoOk) and (not M.TemFalha), M.ResumoParaTexto);
        Check('C4 destino .fbk criado', FileExists(Ex.Destino), Ex.Destino);
        Check('C5 manifesto marca formato feFbk e linhas -1',
              (M.Itens[0].Formato = feFbk) and
              (M.Itens[0].Linhas = -1) and
              (M.Itens[0].Status = xeOk),
              M.Itens[0].Detalhe);

        // argv que o gbak fake registrou
        Args := TStringList.Create;
        try
          if FileExists(ArgsOk + '.args.txt') then
            Args.LoadFromFile(ArgsOk + '.args.txt')
          else
            Args.Add('');
          Todo := '';
          for I := 0 to Args.Count - 1 do
          begin
            if I > 0 then
              Todo := Todo + '|';
            Todo := Todo + Args[I];
          end;
          Check('C6 argv registrado contem -b', Pos('-b', Todo) > 0, Todo);
          Check('C7 argv registrado termina com banco e .fbk',
                (Args.Count >= 2) and
                (Pos('banco.fdb', Args[Args.Count - 2]) > 0) and
                (Pos('backup.fbk', Args[Args.Count - 1]) > 0), Todo);
          Check('C8 senha nao vaza nos eventos do sink',
                (Cap.Eventos.Text = '') or
                (Pos('segredo', Cap.Eventos.Text) = 0),
                Cap.Eventos.Text);
        finally
          Args.Free;
        end;
      finally
        M.Free;          // classe pura: libera manualmente
        R := nil;
        CapIntf := nil;  // libera Cap via interface (refcount)
      end;
    finally
      Ex.Free;
    end;
  end
  else
    Check('C1-C8 (E2E exit0) SKIPPED - fake nao compilou', False, ObterFpc);

  // ========== Grupo D: E2E fake gbak exit 7 =========================
  if FileExists(ArgsFail) then
  begin
    Ex := TExportadorFBK.Create;
    try
      P := NovosParams;
      P.GbakExe := ArgsFail;
      P.Sobrescrever := True;
      P.ArquivoBase := 'vai_falhar';
      OK := Ex.Preparar(P, Msg);
      Check('D1 preparar ok (E2E fail)', OK, Msg);
      M := TManifestoExport.Create;
      R := TProcessRunner.Create;
      try
        OK := Ex.Executar(R, nil, M);
        Check('D2 Executar exit7 retorna False', not OK, '');
        Check('D3 manifesto tem 1 item de falha',
              (M.Count = 1) and M.TemFalha and (not M.TudoOk),
              M.ResumoParaTexto);
        Check('D4 falha registra detalhe', M.Itens[0].Detalhe
              <> '', M.Itens[0].Detalhe);
        Check('D5 arquivo .fbk parcial NAO existe', not FileExists(Ex.Destino),
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

  WriteLn;
  WriteLn('Checks: ' + IntToStr(Checks) + '  Fails: ' + IntToStr(Fails));
  Halt(Fails);
end.