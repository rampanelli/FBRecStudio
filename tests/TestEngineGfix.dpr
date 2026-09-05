program TestEngineGfix;

{ Testes de uEngineGfix/uGuardaSeguranca (F3). Console; exit = n. de
  falhas. Sem gfix real: usa o catalogo de switches (F1), fixtures de
  texto e um FAKE gfix compilado com o proprio FPC (ponta a ponta).

  1) BuildArgs por acao x versao (gaValidar/Full, mend, activate,
     kill FB3+, housekeeping on/off, mode, icu off FB2.5 vs FB2.0);
     extras com lista negra; banco sempre por ultimo; user/pass.
  2) ValidarAmbiente + guarda: write exige PermitirEscrita, copia de
     seguranca e banco livre; banco travado bloqueia write e vira
     aviso no read-only; risco read-only/write correto.
  3) InterpretarSaidaGfix com fixtures (gfix:ERROR, database shutdown,
     please connect, exit <> 0, gfix silencioso exit 0).
  4) GerarOrdemSeguraGfix: read-only primeiro, escrita depois,
     validacao completa no fim.
  5) Ponta a ponta com fake gfix (FPC): exit 0 (sucesso) e exit 7 +
     'gfix:ERROR' no stderr (falha); senha nunca em claro no log. }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Classes, Windows,
  uKernelExec in '..\src\core\uKernelExec.pas',
  uQuoting in '..\src\core\uQuoting.pas',
  uTextCodec in '..\src\core\uTextCodec.pas',
  uLogger in '..\src\core\uLogger.pas',
  uEngineBase in '..\src\engines\uEngineBase.pas',
  uGuardaSeguranca in '..\src\engines\uGuardaSeguranca.pas',
  uFBVersionInfo in '..\src\firebird\uFBVersionInfo.pas',
  uFBSwitchCatalog in '..\src\firebird\uFBSwitchCatalog.pas',
  uEngineGfix in '..\src\engines\uEngineGfix.pas';

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

function TempDir: string;
var
  Buf: array[0..MAX_PATH - 1] of Char;
  N: Integer;
begin
  N := GetTempPath(SizeOf(Buf), PChar(@Buf[0]));
  Result := '';
  if N > 0 then
    Result := IncludeTrailingPathDelimiter(StrPas(PChar(@Buf[0])));
end;

// Monta TVersion valida a partir de linha '-z' conhecida.
function Ver(const ATexto: string): TVersion;
begin
  ZerarVersion(Result);
  if not ParseVersaoTexto(ATexto, Result) then
    Result.Valida := False;
end;

function NovoPlano(const AExe, ABanco: string; AAcao: TGfixAcao;
  const ATextoVersao: string): TPlanoGfix;
begin
  Result := TPlanoGfix.Create;
  Result.GfixExe := AExe;
  Result.Banco := ABanco;
  Result.Acao := AAcao;
  Result.VersaoGfix := Ver(ATextoVersao);
end;

function AcharArg(const A: TStringArray; const AValor: string): Integer;
begin
  for Result := 0 to Length(A) - 1 do
    if A[Result] = AValor then
      Exit;
  Result := -1;
end;

function ValorDepois(const A: TStringArray; AIdx: Integer): string;
begin
  if (AIdx >= 0) and (AIdx + 1 < Length(A)) then
    Result := A[AIdx + 1]
  else
    Result := '';
end;

type
  TLogCap = class(TInterfacedObject, ILogPasso)
  public
    Linhas: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Log(const ACanal: string; const AMensagem: string);
  end;

  TCapSink = class(TInterfacedObject, IOutputSink)
  public
    OutLines: TStringList;
    ErrLines: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure OnLine(AStream: TStreamId; const ALine: string);
    procedure OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
  end;

constructor TLogCap.Create;
begin
  inherited Create;
  Linhas := TStringList.Create;
end;

destructor TLogCap.Destroy;
begin
  Linhas.Free;
  inherited Destroy;
end;

procedure TLogCap.Log(const ACanal: string; const AMensagem: string);
begin
  Linhas.Add('[' + ACanal + '] ' + AMensagem);
end;

constructor TCapSink.Create;
begin
  inherited Create;
  OutLines := TStringList.Create;
  ErrLines := TStringList.Create;
end;

destructor TCapSink.Destroy;
begin
  OutLines.Free;
  ErrLines.Free;
  inherited Destroy;
end;

procedure TCapSink.OnLine(AStream: TStreamId; const ALine: string);
begin
  if AStream = stOut then
    OutLines.Add(ALine)
  else
    ErrLines.Add(ALine);
end;

procedure TCapSink.OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
begin
end;

function CriarArquivo(const APath: string): Boolean;
var
  FS: TFileStream;
begin
  Result := False;
  try
    FS := TFileStream.Create(APath, fmCreate);
    FS.Free;
    Result := True;
  except
    Result := False;
  end;
end;

function EscreverTexto(const APath, ATexto: string): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  try
    F := TFileStream.Create(APath, fmCreate);
    try
      if ATexto <> '' then
        F.WriteBuffer(ATexto[1], Length(ATexto));
    finally
      F.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

const
  K_FAKE_GFIX =
    'program FakeGfix;' + #13#10 +
    '{$APPTYPE CONSOLE}' + #13#10 +
    '{$H+}' + #13#10 +
    'begin' + #13#10 +
    '{$IFDEF GFIX_OK}' + #13#10 +
    '  WriteLn(''gfix: validation succeeded'');' + #13#10 +
    '  Halt(0);' + #13#10 +
    '{$ELSE}' + #13#10 +
    '  WriteLn(ErrOutput, ''gfix:ERROR: simulated validation error'');' + #13#10 +
    '  Halt(7);' + #13#10 +
    '{$ENDIF}' + #13#10 +
    'end.' + #13#10;

// Ponta a ponta com fake gfix compilado com FPC em %TEMP%.
procedure TesteE2E(const FpcPath, ADir: string);
var
  Src, ExeOk, ExeFail, Banco: string;
  Opt: TProcessOptions;
  OutL, ErrL: TStringList;
  Res: TProcessResult;
  Plano: TPlanoGfix;
  Log: TLogCap;
  LogIntf: ILogPasso;
  Motor: TMotorGfix;
  Runner: IProcessRunner;
  Sink: TCapSink;
  SinkIntf: IOutputSink;
  Msg: string;
  OkExe, FailExe: Boolean;
begin
  Src := ADir + 'fakegfix.pas';
  ExeOk := ADir + 'fakegfix_ok.exe';
  ExeFail := ADir + 'fakegfix_fail.exe';
  Banco := ADir + 'alvo.fdb';
  EscreverTexto(Src, K_FAKE_GFIX);
  CriarArquivo(Banco);
  OutL := TStringList.Create;
  ErrL := TStringList.Create;
  try
    FillChar(Opt, SizeOf(Opt), 0);
    Opt.Executable := FpcPath;
    Opt.WorkDir := ADir;
    Opt.TimeoutMs := 60000;
    Opt.KillTreeOnCancel := True;
    Opt.ConsoleCodePage := 0;
    SetLength(Opt.Args, 4);
    Opt.Args[0] := '-Mdelphi';
    Opt.Args[1] := '-dGFIX_OK';
    Opt.Args[2] := '-o' + ExeOk;
    Opt.Args[3] := Src;
    OutL.Clear;
    ErrL.Clear;
    Res := BuildAndRun(Opt, OutL, ErrL);
    Check('e2e: fake ok compilou', Res.Ok);
    OkExe := FileExists(ExeOk);

    SetLength(Opt.Args, 3);
    Opt.Args[0] := '-Mdelphi';
    Opt.Args[1] := '-o' + ExeFail;
    Opt.Args[2] := Src;
    OutL.Clear;
    ErrL.Clear;
    Res := BuildAndRun(Opt, OutL, ErrL);
    Check('e2e: fake fail compilou', Res.Ok);
    FailExe := FileExists(ExeFail);

    if not (OkExe and FailExe) then
    begin
      WriteLn('  (detalhe do fpc: ' + Trim(OutL.Text + ErrL.Text) + ')');
      Exit;
    end;

    // ---------- cenario A: validacao read-only, sucesso ----------
    Plano := NovoPlano(ExeOk, Banco, gaValidar,
                       'LI-V2.5.9.27110 Firebird 2.5');
    Plano.Usuario := 'sysdba';
    Plano.Senha := 'masterkey';
    Plano.TimeoutMs := 30000;
    Log := TLogCap.Create;
    LogIntf := Log;
    Motor := TMotorGfix.Create(LogIntf);
    Motor.AtribuirPlano(Plano);
    Runner := TProcessRunner.Create;
    Sink := TCapSink.Create;
    SinkIntf := Sink;
    Msg := '';
    Check('e2e ok: ValidarAmbiente (read-only, sem copia)',
          Motor.ValidarAmbiente(Msg));
    Check('e2e ok: risco read-only', Motor.Risco = rlReadOnly);
    Res := Motor.Executar(Runner, SinkIntf);
    Check('e2e ok: processo Ok (exit 0)', Res.Ok);
    Check('e2e ok: Resumo.Ok', Motor.Resumo.Ok);
    Check('e2e ok: estado sucesso', Motor.Estado = ssSucesso);
    Check('e2e ok: stdout repassado', Pos('validation', Sink.OutLines.Text) > 0);
    Check('e2e ok: log sem senha em claro',
          Pos('masterkey', Log.Linhas.Text) = 0);
    Check('e2e ok: log com senha mascarada (******)',
          Pos('******', Log.Linhas.Text) > 0);
    Motor.Free;
    Plano.Free;
    SinkIntf := nil;
    LogIntf := nil;
    Runner := nil;

    // ---------- cenario B: falha (exit 7 + gfix:ERROR) ----------
    Plano := NovoPlano(ExeFail, Banco, gaValidarFull,
                       'LI-V2.5.9.27110 Firebird 2.5');
    Plano.TimeoutMs := 30000;
    Log := TLogCap.Create;
    LogIntf := Log;
    Motor := TMotorGfix.Create(LogIntf);
    Motor.AtribuirPlano(Plano);
    Runner := TProcessRunner.Create;
    Sink := TCapSink.Create;
    SinkIntf := Sink;
    Res := Motor.Executar(Runner, SinkIntf);
    Check('e2e falha: processo nao Ok (exit 7)', not Res.Ok);
    Check('e2e falha: exit code 7', Res.ExitCode = 7);
    Check('e2e falha: Resumo.Ok false', not Motor.Resumo.Ok);
    Check('e2e falha: Resumo.Erro true', Motor.Resumo.Erro);
    Check('e2e falha: MensagemErro com gfix:ERROR',
          Pos('gfix:ERROR', Motor.Resumo.MensagemErro) > 0);
    Check('e2e falha: estado falha', Motor.Estado = ssFalha);
    Check('e2e falha: stderr no sink',
          Pos('gfix:ERROR', Sink.ErrLines.Text) > 0);
    Motor.Free;
    Plano.Free;
    SinkIntf := nil;
    LogIntf := nil;
    Runner := nil;
  finally
    OutL.Free;
    ErrL.Free;
  end;
end;

var
  Motor: TMotorGfix;
  Plano: TPlanoGfix;
  Msg: string;
  L: TStringList;
  R: TResumoGfix;
  I: Integer;
  BaseDir, D1, FpcPath: string;
  Flags: TGfixFlags;
  Seq: array[0..7] of TGfixAcao;
  N: Integer;
  FTexto: string;
begin
  Fails := 0;
  Checks := 0;

  // ============ 1) BuildArgs por acao x versao ============
  Plano := NovoPlano('C:\fb\gfix.exe', 'C:\dados\alvo.fdb', gaValidar,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('validar: BuildArgs ok', Motor.BuildArgs);
  Check('validar: contem -v', AcharArg(Motor.Argv, '-v') >= 0);
  Check('validar: banco por ultimo',
        (Length(Motor.Argv) >= 1) and
        (Motor.Argv[Length(Motor.Argv) - 1] = 'C:\dados\alvo.fdb'));
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano('C:\fb\gfix.exe', 'C:\dados\alvo.fdb', gaValidarFull,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('validarFull: BuildArgs ok', Motor.BuildArgs);
  Check('validarFull: contem -v e -full',
        (AcharArg(Motor.Argv, '-v') >= 0) and
        (AcharArg(Motor.Argv, '-full') >= 0));
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano('C:\fb\gfix.exe', 'C:\dados\alvo.fdb', gaMend,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('mend: BuildArgs ok', Motor.BuildArgs);
  Check('mend: contem -mend', AcharArg(Motor.Argv, '-mend') >= 0);
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano('C:\fb\gfix.exe', 'C:\dados\alvo.fdb', gaActivate,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('activate: contem -activate', Motor.BuildArgs and
        (AcharArg(Motor.Argv, '-activate') >= 0));
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano('C:\fb\gfix.exe', 'C:\dados\alvo.fdb', gaKill,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('kill 2.5: BuildArgs ok (catalogo vazio -> omite)', Motor.BuildArgs);
  Check('kill 2.5: sem -kill (so FB3+)', AcharArg(Motor.Argv, '-kill') = -1);
  Check('kill 2.5: aviso emitido', Motor.Avisos.Count >= 1);
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano('C:\fb\gfix.exe', 'C:\dados\alvo.fdb', gaKill,
                     'LI-V3.0.7.33355 Firebird 3.0');
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('kill 3.0: contem -kill', Motor.BuildArgs and
        (AcharArg(Motor.Argv, '-kill') >= 0));
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano('C:\fb\gfix.exe', 'C:\dados\alvo.fdb',
                     gaHousekeepingOn, 'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('hk on: BuildArgs ok', Motor.BuildArgs);
  I := AcharArg(Motor.Argv, '-housekeeping');
  Check('hk on: -housekeeping on', (I >= 0) and
        (ValorDepois(Motor.Argv, I) = 'on'));
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano('C:\fb\gfix.exe', 'C:\dados\alvo.fdb',
                     gaModeReadWrite, 'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('mode: BuildArgs ok', Motor.BuildArgs);
  I := AcharArg(Motor.Argv, '-mode');
  Check('mode: -mode read_write', (I >= 0) and
        (ValorDepois(Motor.Argv, I) = 'read_write'));
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano('C:\fb\gfix.exe', 'C:\dados\alvo.fdb', gaIcuOff,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('icu 2.5: BuildArgs ok', Motor.BuildArgs);
  I := AcharArg(Motor.Argv, '-icu');
  Check('icu 2.5: -icu off', (I >= 0) and
        (ValorDepois(Motor.Argv, I) = 'off'));
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano('C:\fb\gfix.exe', 'C:\dados\alvo.fdb', gaIcuOff,
                     'LI-V2.0.4.13121 Firebird 2.0');
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('icu 2.0: BuildArgs ok (catalogo vazio p/ 2.0 -> omite)',
        Motor.BuildArgs);
  Check('icu 2.0: sem -icu', AcharArg(Motor.Argv, '-icu') = -1);
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano('C:\fb\gfix.exe', 'C:\dados\alvo.fdb', gaMend,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Plano.Usuario := 'sysdba';
  Plano.Senha := 'masterkey';
  SetLength(Plano.ArgsExtras, 1);
  Plano.ArgsExtras[0] := '-ig';
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('user/pass/extras: BuildArgs ok', Motor.BuildArgs);
  I := AcharArg(Motor.Argv, '-user');
  Check('user/pass/extras: -user sysdba', (I >= 0) and
        (ValorDepois(Motor.Argv, I) = 'sysdba'));
  I := AcharArg(Motor.Argv, '-pass');
  Check('user/pass/extras: -pass presente', (I >= 0) and
        (ValorDepois(Motor.Argv, I) = 'masterkey'));
  Check('user/pass/extras: extra -ig aceito', AcharArg(Motor.Argv, '-ig') >= 0);
  Check('user/pass/extras: banco por ultimo',
        Motor.Argv[Length(Motor.Argv) - 1] = 'C:\dados\alvo.fdb');
  SetLength(Plano.ArgsExtras, 1);
  Plano.ArgsExtras[0] := '-pass';
  Msg := '';
  Check('extras: lista negra -pass', not ValidarArgsExtrasGfix(Plano.ArgsExtras, Msg));
  Plano.ArgsExtras[0] := '>log.txt';
  Check('extras: redirecionamento bloqueado',
        not ValidarArgsExtrasGfix(Plano.ArgsExtras, Msg));
  Check('extras: BuildArgs recusa com lista negra', not Motor.BuildArgs);
  Motor.Free;
  Plano.Free;

  // ============ 2) parser com fixtures ============
  L := TStringList.Create;
  L.Add('gfix: validation succeeded');
  R := InterpretarSaidaGfix(0, L, 'gfix: validation succeeded');
  Check('parse: exit 0 sem erro = Ok', R.Ok);
  Check('parse: sem erro', not R.Erro);
  L.Clear;
  L.Add('gfix:ERROR: database file is not a valid database');
  R := InterpretarSaidaGfix(1, L, '');
  Check('parse: exit 1 com gfix:ERROR = falha', not R.Ok);
  Check('parse: Erro detectado', R.Erro);
  Check('parse: MensagemErro preenchida',
        Pos('gfix:ERROR', R.MensagemErro) > 0);
  L.Clear;
  L.Add('database shutdown');
  R := InterpretarSaidaGfix(0, L, '');
  Check('parse: database shutdown com exit 0 ainda falha (defensivo)',
        not R.Ok);
  L.Clear;
  L.Add('please connect to the database');
  R := InterpretarSaidaGfix(2, L, '');
  Check('parse: please connect = erro/dica', (not R.Ok) and R.Erro);
  L.Clear;
  R := InterpretarSaidaGfix(0, L, '');
  Check('parse: gfix silencioso exit 0 = Ok', R.Ok);
  L.Clear;
  R := InterpretarSaidaGfix(7, L, '');
  Check('parse: exit 7 sem frase = falha', not R.Ok);
  Check('parse: motivo generico com codigo 7',
        Pos('codigo 7', R.MensagemErro) > 0);
  L.Free;

  // ============ 3) ordem segura ============
  FillChar(Flags, SizeOf(Flags), 0);
  N := GerarOrdemSeguraGfix(Flags, Seq);
  Check('ordem: sem flags = [validar, validarFull]', N = 2);
  Check('ordem: 1o read-only (validar)', Seq[0] = gaValidar);
  Check('ordem: ultimo validarFull', Seq[N - 1] = gaValidarFull);
  Flags.EmShutdown := True;
  Flags.SuspeitaCorrupcao := True;
  Flags.ComLimbo := True;
  N := GerarOrdemSeguraGfix(Flags, Seq);
  Check('ordem: flags totais geram 5 passos', N = 5);
  Check('ordem: começa com validar (read-only)', Seq[0] = gaValidar);
  Check('ordem: activate apos validar', Seq[1] = gaActivate);
  Check('ordem: mend depois do activate', Seq[2] = gaMend);
  Check('ordem: kill no meio', Seq[3] = gaKill);
  Check('ordem: termina com validarFull (read-only)', Seq[N - 1] = gaValidarFull);

  // ============ 4) ValidarAmbiente + guarda (arquivos reais) ============
  BaseDir := TempDir + 'FBRGfix' + IntToStr(GetCurrentProcessId);
  if DirectoryExists(BaseDir) then
  begin
    SysUtils.DeleteFile(BaseDir + '\gfix.exe');
    SysUtils.DeleteFile(BaseDir + '\alvo.fdb');
    RemoveDir(BaseDir);
  end;
  ForceDirectories(BaseDir);
  CriarArquivo(BaseDir + '\gfix.exe');
  CriarArquivo(BaseDir + '\alvo.fdb');

  // 4a) write sem PermitirEscrita -> bloqueia
  Plano := NovoPlano(BaseDir + '\gfix.exe', BaseDir + '\alvo.fdb', gaMend,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Msg := '';
  Check('guarda: mend sem PermitirEscrita bloqueia',
        not Motor.ValidarAmbiente(Msg));
  Check('guarda: msg cita confirmacao', Pos('confirmacao', Msg) > 0);
  Motor.Free;
  Plano.Free;

  // 4b) write + PermitirEscrita mas SEM copia -> bloqueia
  Plano := NovoPlano(BaseDir + '\gfix.exe', BaseDir + '\alvo.fdb', gaMend,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Plano.PermitirEscrita := True;
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Msg := '';
  Check('guarda: mend exige copia de seguranca',
        not Motor.ValidarAmbiente(Msg));
  Check('guarda: msg cita copia', Pos('copia', Msg) > 0);
  Motor.Free;
  Plano.Free;

  // 4c) write + PermitirEscrita + copia + banco livre -> OK, risco write
  Plano := NovoPlano(BaseDir + '\gfix.exe', BaseDir + '\alvo.fdb', gaMend,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Plano.PermitirEscrita := True;
  Plano.CopiaSegurancaFeita := True;
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Msg := '';
  Check('guarda: mend com copia e banco livre OK',
        Motor.ValidarAmbiente(Msg));
  Check('guarda: risco write no mend', Motor.Risco = rlWrite);
  Motor.Free;
  Plano.Free;

  // 4d) read-only nunca exige copia (mesmo banco livre) + risco RO
  Plano := NovoPlano(BaseDir + '\gfix.exe', BaseDir + '\alvo.fdb',
                     gaValidarFull, 'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGfix.Create(nil);
  Motor.AtribuirPlano(Plano);
  Msg := '';
  Check('guarda: validarFull (read-only) nao exige copia',
        Motor.ValidarAmbiente(Msg));
  Check('guarda: risco read-only no validar', Motor.Risco = rlReadOnly);
  Motor.Free;
  Plano.Free;

  // 4e) banco TRAVADO: write bloqueia (mesmo com copia); RO passa c/ aviso
  FTexto := BaseDir + '\alvo.fdb';
  with TFileStream.Create(FTexto, fmOpenReadWrite) do
  try
    Plano := NovoPlano(BaseDir + '\gfix.exe', BaseDir + '\alvo.fdb',
                       gaMend, 'LI-V2.5.9.27110 Firebird 2.5');
    Plano.PermitirEscrita := True;
    Plano.CopiaSegurancaFeita := True;
    Motor := TMotorGfix.Create(nil);
    Motor.AtribuirPlano(Plano);
    Msg := '';
    Check('guarda: banco travado bloqueia write (com copia)',
          not Motor.ValidarAmbiente(Msg));
    Check('guarda: msg cita EM USO', Pos('EM USO', Msg) > 0);
    Motor.Free;
    Plano.Free;

    Plano := NovoPlano(BaseDir + '\gfix.exe', BaseDir + '\alvo.fdb',
                       gaValidar, 'LI-V2.5.9.27110 Firebird 2.5');
    Motor := TMotorGfix.Create(nil);
    Motor.AtribuirPlano(Plano);
    Msg := '';
    Check('guarda: banco travado + read-only passa (sem copia)',
          Motor.ValidarAmbiente(Msg));
    Check('guarda: read-only com banco travado gera aviso',
          Motor.Avisos.Count >= 1);
    Motor.Free;
    Plano.Free;
  finally
    // (FS liberado implicitamente pelo with/finally)
  end;

  // limpeza antes do E2E (o E2E recria o banco em outra pasta)
  SysUtils.DeleteFile(BaseDir + '\gfix.exe');
  SysUtils.DeleteFile(BaseDir + '\alvo.fdb');
  RemoveDir(BaseDir);

  // ============ 5) ponta a ponta com fake gfix (FPC) ============
  FpcPath := SysUtils.GetEnvironmentVariable('FB_FPC');
  if (FpcPath = '') or (not FileExists(FpcPath)) then
    FpcPath := SysUtils.GetEnvironmentVariable('FB_FPC');
  if FileExists(FpcPath) then
  begin
    D1 := TempDir + 'FBRTestFakeGfix' + IntToStr(GetCurrentProcessId);
    if DirectoryExists(D1) then
      RemoveDir(D1);
    ForceDirectories(D1);
    TesteE2E(FpcPath, IncludeTrailingPathDelimiter(D1));
    SysUtils.DeleteFile(D1 + '\fakegfix.pas');
    SysUtils.DeleteFile(D1 + '\fakegfix_ok.exe');
    SysUtils.DeleteFile(D1 + '\fakegfix_fail.exe');
    SysUtils.DeleteFile(D1 + '\alvo.fdb');
    RemoveDir(D1);
  end
  else
    WriteLn('SKIP: fake gfix nao compilado (FPC nao encontrado; defina FB_FPC)');

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.
