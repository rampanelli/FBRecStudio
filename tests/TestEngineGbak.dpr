program TestEngineGbak;

{ Testes de uEngineGbak/uEngineBase (F2-A/F2-T1). Console; exit =
  n. de falhas. Sem binarios Firebird reais: usa o catalogo de
  switches (F1) e um FAKE gbak compilado com o proprio FPC em %TEMP%.

  1) BuildArgs por cenario:
       c + fix_fss (FB 2.5)    -> -c -v -g -user/-pass + -FIX_FSS_*;
       FB 3.0                  -> omite -FIX_FSS_* (catalogo vazio);
       r sobrescrever (FB 2.5) -> -r; FB 4 -> -recreate overwrite;
       lista negra de extras  -> -pass/-password/>/<|& rejeitados;
       operandos Origem/Destino sempre por ultimo.
  2) Pre-checks (ValidarAmbiente): origem inexistente; destino existe
     sem Sobrescrever falha amigavel; cria pasta do destino; gbak
     inexistente; versao invalida.
  3) Parser de saida com fixtures de texto (gbak: ERROR / Exiting
     before completion / finished / exit <> 0).
  4) Ponta a ponta: fake gbak compilado com FPC imita exit 7 +
     'gbak: ERROR' no stderr e exit 0; roda via uKernelExec
     (BuildAndRun/TProcessRunner) e confere tratamento de falha,
     sucesso e log com senha mascarada. }

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
  uEngineGbak in '..\src\engines\uEngineGbak.pas';

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

// Monta uma TVersion valida a partir de uma linha '-z' conhecida.
function Ver(const ATexto: string): TVersion;
begin
  ZerarVersion(Result);
  if not ParseVersaoTexto(ATexto, Result) then
    Result.Valida := False;
end;

function NovoPlano(const AExe, AOrigem, ADestino: string;
  AModo: TModoGbak; const ATextoVersao: string): TPlanoGbak;
begin
  Result := TPlanoGbak.Create;
  Result.GbakExe := AExe;
  Result.Origem := AOrigem;
  Result.Destino := ADestino;
  Result.Modo := AModo;
  Result.VersaoGbak := Ver(ATextoVersao);
end;

// Indice da 1a ocorrencia de AValor no argv (ou -1).
function AcharArg(const A: TStringArray; const AValor: string): Integer;
begin
  for Result := 0 to Length(A) - 1 do
    if A[Result] = AValor then
      Exit;
  Result := -1;
end;

// Valor que segue um switch (AIdx + 1); '' se fora dos limites.
function ValorDepois(const A: TStringArray; AIdx: Integer): string;
begin
  if (AIdx >= 0) and (AIdx + 1 < Length(A)) then
    Result := A[AIdx + 1]
  else
    Result := '';
end;

type
  // Captura de log do motor (ILogPasso fake em memoria).
  TLogCap = class(TInterfacedObject, ILogPasso)
  public
    Linhas: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Log(const ACanal: string; const AMensagem: string);
  end;

  // Sink externo que coleta linhas/eventos (mesmo padrao do
  // TestKernelExec).
  TCapSink = class(TInterfacedObject, IOutputSink)
  public
    OutLines: TStringList;
    ErrLines: TStringList;
    Events: TStringList;
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
  Events := TStringList.Create;
end;

destructor TCapSink.Destroy;
begin
  OutLines.Free;
  ErrLines.Free;
  Events.Free;
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
  Events.Add(IntToStr(Ord(AEvent)) + ':' + AInfo);
end;

// Cria arquivo (conteudo irrelevante) ou False em falha.
function CriarArquivo(const APath: string): Boolean;
var
  FS: TFileStream;
begin
  Result := False;
  try
    FS := TFileStream.Create(APath, fmCreate or fmShareDenyNone);
    try
      FS.WriteBuffer('fake gbak payload' + #13#10, 20);
    finally
      FS.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

// Grava texto ASCII em arquivo (usado para gerar o fonte do fake gbak).
function EscreverTexto(const APath, ATexto: string): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  try
    F := TFileStream.Create(APath, fmCreate or fmShareDenyNone);
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
  K_FAKE_OK =
    'program FakeGbak;' + #13#10 +
    '{$APPTYPE CONSOLE}' + #13#10 +
    '{$H+}' + #13#10 +
    'begin' + #13#10 +
    '{$IFDEF GBAK_OK}' + #13#10 +
    '  WriteLn(''gbak: finished, backup file restored'');' + #13#10 +
    '  Halt(0);' + #13#10 +
    '{$ELSE}' + #13#10 +
    '  WriteLn(ErrOutput, ''gbak: ERROR: simulated failure'');' + #13#10 +
    '  WriteLn(ErrOutput, ''gbak: Exiting before completion.'');' + #13#10 +
    '  Halt(7);' + #13#10 +
    '{$ENDIF}' + #13#10 +
    'end.' + #13#10;

// ------------------------------------------------------------------
// Teste ponta a ponta com fake gbak (compilado com FPC em %TEMP%).
// Sem FPC disponivel o teste e ignorado (nao conta como falha).
// ------------------------------------------------------------------
procedure TesteE2E(const FpcPath, ADir: string);
var
  Src, ExeOk, ExeFail, Origem: string;
  Opt: TProcessOptions;
  OutL, ErrL: TStringList;
  Res: TProcessResult;
  Plano: TPlanoGbak;
  Log: TLogCap;
  LogIntf: ILogPasso;
  Motor: TMotorGbak;
  Runner: IProcessRunner;
  Sink: TCapSink;
  SinkIntf: IOutputSink;
  Msg: string;
  OkExe, FailExe: Boolean;
begin
  Src := ADir + 'fakegbak.pas';
  ExeOk := ADir + 'fakegbak_ok.exe';
  ExeFail := ADir + 'fakegbak_fail.exe';
  Origem := ADir + 'backup.fbk';
  EscreverTexto(Src, K_FAKE_OK);
  CriarArquivo(Origem);
  OutL := TStringList.Create;
  ErrL := TStringList.Create;
  try
    // ---------- compila o fake 2x (ok e falha) ----------
    FillChar(Opt, SizeOf(Opt), 0);
    Opt.Executable := FpcPath;
    Opt.WorkDir := ADir;
    Opt.TimeoutMs := 60000;
    Opt.KillTreeOnCancel := True;
    Opt.ConsoleCodePage := 0;
    SetLength(Opt.Args, 4);
    Opt.Args[0] := '-Mdelphi';
    Opt.Args[1] := '-dGBAK_OK';
    Opt.Args[2] := '-o' + ExeOk;
    Opt.Args[3] := Src;
    OutL.Clear;
    ErrL.Clear;
    Res := BuildAndRun(Opt, OutL, ErrL);
    Check('fake OK recompilado com GBAK_OK', Res.Ok);
    OkExe := FileExists(ExeOk);

    SetLength(Opt.Args, 3);
    Opt.Args[0] := '-Mdelphi';
    Opt.Args[1] := '-o' + ExeFail;
    Opt.Args[2] := Src;
    OutL.Clear;
    ErrL.Clear;
    Res := BuildAndRun(Opt, OutL, ErrL);
    Check('fake FAIL compilou (exit 0)', Res.Ok);
    FailExe := FileExists(ExeFail);

    if not (OkExe and FailExe) then
    begin
      WriteLn('  (detalhe do fpc: ' + Trim(OutL.Text + ErrL.Text) + ')');
      Exit;
    end;

    // ---------- cenario A: sucesso (exit 0) ----------
    Plano := NovoPlano(ExeOk, Origem, ADir + 'restaurado.fdb',
                       mgRestoreCriar, 'LI-V2.5.9.27110 Firebird 2.5');
    Plano.Usuario := 'sysdba';
    Plano.Senha := 'masterkey';
    Plano.Verboso := True;
    Plano.TimeoutMs := 30000;
    Log := TLogCap.Create;
    LogIntf := Log;
    Motor := TMotorGbak.Create(LogIntf);
    Motor.AtribuirPlano(Plano);
    Runner := TProcessRunner.Create;
    Sink := TCapSink.Create;
    SinkIntf := Sink;
    Msg := '';
    Check('e2e ok: ValidarAmbiente', Motor.ValidarAmbiente(Msg));
    Res := Motor.Executar(Runner, SinkIntf);
    Check('e2e ok: processo Ok (exit 0)', Res.Ok);
    Check('e2e ok: exit code 0', Res.ExitCode = 0);
    Check('e2e ok: Resumo.Ok', Motor.Resumo.Ok);
    Check('e2e ok: Resumo.Terminou (finished)', Motor.Resumo.Terminou);
    Check('e2e ok: estado sucesso',
          Motor.Estado = ssSucesso);
    Check('e2e ok: stdout repassado ao sink',
          Sink.OutLines.Text <> '');
    Check('e2e ok: linha finished no sink',
          Pos('finished', Sink.OutLines.Text) > 0);
    Check('e2e ok: log nao contem a senha em claro',
          Pos('masterkey', Log.Linhas.Text) = 0);
    Check('e2e ok: log mascarou -pass (******)',
          Pos('******', Log.Linhas.Text) > 0);
    // Liberacao: sink/log sao de posse das interfaces (auto-free ao
    // zerar a ultima referencia); motor e plano sao do dono (Free).
    Motor.Free;
    Plano.Free;
    SinkIntf := nil;
    LogIntf := nil;
    Runner := nil;

    // ---------- cenario B: falha (exit 7 + gbak: ERROR) ----------
    Plano := NovoPlano(ExeFail, Origem, ADir + 'restaurado2.fdb',
                       mgRestoreCriar, 'LI-V2.5.9.27110 Firebird 2.5');
    Plano.Usuario := 'sysdba';
    Plano.Senha := 'x';
    Plano.TimeoutMs := 30000;
    Log := TLogCap.Create;
    LogIntf := Log;
    Motor := TMotorGbak.Create(LogIntf);
    Motor.AtribuirPlano(Plano);
    Runner := TProcessRunner.Create;
    Sink := TCapSink.Create;
    SinkIntf := Sink;
    Res := Motor.Executar(Runner, SinkIntf);
    Check('e2e falha: processo nao Ok (exit 7)', not Res.Ok);
    Check('e2e falha: exit code 7', Res.ExitCode = 7);
    Check('e2e falha: Resumo.Ok false', not Motor.Resumo.Ok);
    Check('e2e falha: Resumo.Erro (frase vista)', Motor.Resumo.Erro);
    Check('e2e falha: MensagemErro com gbak: ERROR',
          Pos('gbak: ERROR', Motor.Resumo.MensagemErro) > 0);
    Check('e2e falha: estado falha', Motor.Estado = ssFalha);
    Check('e2e falha: stderr com gbak: ERROR no sink',
          Pos('gbak: ERROR', Sink.ErrLines.Text) > 0);
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
  Motor: TMotorGbak;
  Plano: TPlanoGbak;
  Msg: string;
  L: TStringList;
  R: TResumoGbak;
  I: Integer;
  BaseDir, FpcPath: string;
  D1: string;
begin
  Fails := 0;
  Checks := 0;

  // ================= 1) BuildArgs: c + fix_fss FB 2.5 =================
  Plano := NovoPlano(BaseDir + 'gbak.exe', 'C:\dados\bk.fbk',
                     'C:\dados\rest.fdb', mgRestoreCriar,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Plano.Usuario := 'sysdba';
  Plano.Senha := 'masterkey';
  Plano.Verboso := True;
  Plano.NoGC := True;
  Plano.FixFssMetadata := 'ISO8859_1';
  Plano.FixFssData := 'NONE';
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('c2.5: BuildArgs ok', Motor.BuildArgs);
  Check('c2.5: contem -c', AcharArg(Motor.Argv, '-c') >= 0);
  Check('c2.5: contem -v (verboso)', AcharArg(Motor.Argv, '-v') >= 0);
  Check('c2.5: contem -g (no gc)', AcharArg(Motor.Argv, '-g') >= 0);
  I := AcharArg(Motor.Argv, '-user');
  Check('c2.5: -user sysdba', (I >= 0) and (ValorDepois(Motor.Argv, I) = 'sysdba'));
  I := AcharArg(Motor.Argv, '-pass');
  Check('c2.5: -pass com valor', (I >= 0) and
        (ValorDepois(Motor.Argv, I) = 'masterkey'));
  I := AcharArg(Motor.Argv, '-FIX_FSS_METADATA');
  Check('c2.5: -FIX_FSS_METADATA ISO8859_1',
        (I >= 0) and (ValorDepois(Motor.Argv, I) = 'ISO8859_1'));
  I := AcharArg(Motor.Argv, '-FIX_FSS_DATA');
  Check('c2.5: -FIX_FSS_DATA NONE',
        (I >= 0) and (ValorDepois(Motor.Argv, I) = 'NONE'));
  Check('c2.5: sem avisos (fix_fss suportado)', Motor.Avisos.Count = 0);
  Check('c2.5: Origem e Destino por ultimo',
        (Length(Motor.Argv) >= 2) and
        (Motor.Argv[Length(Motor.Argv) - 2] = 'C:\dados\bk.fbk') and
        (Motor.Argv[Length(Motor.Argv) - 1] = 'C:\dados\rest.fdb'));
  Motor.Free;
  Plano.Free;

  // ============ 2) BuildArgs: FB 3.0 omite fix_fss ============
  Plano := NovoPlano(BaseDir + 'gbak.exe', 'C:\dados\bk.fbk',
                     'C:\dados\rest.fdb', mgRestoreCriar,
                     'LI-V3.0.7.33355 Firebird 3.0');
  Plano.FixFssMetadata := 'ISO8859_1';
  Plano.FixFssData := 'NONE';
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('fb3: BuildArgs ok', Motor.BuildArgs);
  Check('fb3: sem -FIX_FSS_METADATA', AcharArg(Motor.Argv, '-FIX_FSS_METADATA') = -1);
  Check('fb3: sem -FIX_FSS_DATA', AcharArg(Motor.Argv, '-FIX_FSS_DATA') = -1);
  Check('fb3: dois avisos de fix_fss ignorado', Motor.Avisos.Count = 2);
  Check('fb3: ainda tem -c e operandos',
        (AcharArg(Motor.Argv, '-c') >= 0) and
        (Motor.Argv[Length(Motor.Argv) - 1] = 'C:\dados\rest.fdb'));
  Motor.Free;
  Plano.Free;

  // ============ 3) r sobrescrever: FB 2.5 e FB 4 ============
  Plano := NovoPlano(BaseDir + 'gbak.exe', 'C:\dados\bk.fbk',
                     'C:\dados\existe.fdb', mgRestoreSubstituir,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('r2.5: BuildArgs ok', Motor.BuildArgs);
  Check('r2.5: contem -r (catalogo 2.5)', AcharArg(Motor.Argv, '-r') >= 0);
  Check('r2.5: sem -c', AcharArg(Motor.Argv, '-c') = -1);
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano(BaseDir + 'gbak.exe', 'C:\dados\bk.fbk',
                     'C:\dados\existe.fdb', mgRestoreSubstituir,
                     'LI-V4.0.1.2696 Firebird 4.0');
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  Check('r4: BuildArgs ok', Motor.BuildArgs);
  Check('r4: contem -recreate (catalogo 4+)',
        AcharArg(Motor.Argv, '-recreate') >= 0);
  Check('r4: engine acrescenta overwrite',
        AcharArg(Motor.Argv, 'overwrite') >= 0);
  Check('r4: sem -r', AcharArg(Motor.Argv, '-r') = -1);
  Motor.Free;
  Plano.Free;

  // ============ 4) lista negra de argumentos extras ============
  Plano := NovoPlano(BaseDir + 'gbak.exe', 'C:\dados\bk.fbk',
                     'C:\dados\rest.fdb', mgRestoreCriar,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  SetLength(Plano.ArgsExtras, 2);
  Plano.ArgsExtras[0] := '-pass';
  Plano.ArgsExtras[1] := 'outra';
  Msg := '';
  Check('lista negra: -pass rejeitado', not ValidarArgsExtras(Plano.ArgsExtras, Msg));
  Check('lista negra: motivo amigavel', Msg <> '');
  Check('lista negra: BuildArgs recusa', not Motor.BuildArgs);
  Check('lista negra: ErroAmbiente preenchido',
        Pos('proibido', Motor.ErroAmbiente) > 0);
  SetLength(Plano.ArgsExtras, 1);
  Plano.ArgsExtras[0] := '2>&1';
  Check('lista negra: redirecionamento 2>&1 rejeitado',
        not ValidarArgsExtras(Plano.ArgsExtras, Msg));
  Plano.ArgsExtras[0] := '-password';
  Check('lista negra: -password rejeitado',
        not ValidarArgsExtras(Plano.ArgsExtras, Msg));
  Plano.ArgsExtras[0] := '-pass=segredo';
  Check('lista negra: -pass=valor rejeitado',
        not ValidarArgsExtras(Plano.ArgsExtras, Msg));
  Plano.ArgsExtras[0] := '>';
  Check('lista negra: > rejeitado', not ValidarArgsExtras(Plano.ArgsExtras, Msg));
  Plano.ArgsExtras[0] := '&';
  Check('lista negra: & rejeitado', not ValidarArgsExtras(Plano.ArgsExtras, Msg));
  Plano.ArgsExtras[0] := '|';
  Check('lista negra: | rejeitado', not ValidarArgsExtras(Plano.ArgsExtras, Msg));
  Plano.ArgsExtras[0] := '-ig';
  Check('lista negra: extra benigno aceito', ValidarArgsExtras(Plano.ArgsExtras, Msg));
  SetLength(Plano.ArgsExtras, 1);
  Plano.ArgsExtras[0] := '-ig';
  Check('lista negra: BuildArgs aceita extra benigno', Motor.BuildArgs);
  Motor.Free;
  Plano.Free;

  // ================= 5) parser com fixtures de texto =================
  L := TStringList.Create;
  L.Add('gbak: finished, some database was restored');
  L.Add('gbak: closing file, committing...');
  R := InterpretarSaidaGbak(0, L, 'gbak: finished, some database was restored');
  Check('parse: exit 0 sem erro = Ok', R.Ok);
  Check('parse: terminou (finished)', R.Terminou);
  Check('parse: sem erro', not R.Erro);
  L.Clear;
  L.Add('gbak: ERROR: could not open backup file');
  L.Add('gbak: Exiting before completion.');
  R := InterpretarSaidaGbak(1, L, 'gbak: ERROR');
  Check('parse: exit 1 com gbak: ERROR = falha', not R.Ok);
  Check('parse: Erro detectado', R.Erro);
  Check('parse: MensagemErro e a linha de erro',
        Pos('gbak: ERROR', R.MensagemErro) > 0);
  Check('parse: ExitCode preservado', R.ExitCode = 1);
  L.Clear;
  L.Add('gbak: ERROR: something went wrong');
  R := InterpretarSaidaGbak(0, L, '');
  Check('parse: frase de erro com exit 0 ainda e falha (defensivo)',
        not R.Ok);
  L.Clear;
  R := InterpretarSaidaGbak(7, L, '');
  Check('parse: exit 7 sem frases = falha', not R.Ok);
  Check('parse: motivo generico com codigo 7',
        Pos('codigo 7', R.MensagemErro) > 0);
  L.Clear;
  L.Add('gbak: restored table FOO');
  R := InterpretarSaidaGbak(0, L, 'gbak: restored table FOO');
  Check('parse: exit 0 sem finished = Ok', R.Ok);
  Check('parse: Terminou so com finished', not R.Terminou);
  L.Clear;
  L.Add('GBAK: ERROR: mixed case is caught too');
  R := InterpretarSaidaGbak(0, L, '');
  Check('parse: case-insensitive (GBAK: ERROR)', not R.Ok);
  L.Free;

  // ============ 6) pre-checks de ambiente ============
  BaseDir := TempDir + 'FBRTestGbak' + IntToStr(GetCurrentProcessId);
  if DirectoryExists(BaseDir) then
  begin
    SysUtils.DeleteFile(BaseDir + 'existe.fdb');
    SysUtils.DeleteFile(BaseDir + 'origem.fbk');
    RemoveDir(BaseDir);
  end;
  ForceDirectories(BaseDir);
  // gbak "dummy" (qualquer arquivo): ValidarAmbiente so checa FileExists
  // para o executavel; os cenarios positivos precisam passa-lo.
  CriarArquivo(BaseDir + 'gbak.exe');
  CriarArquivo(BaseDir + 'origem.fbk');
  CriarArquivo(BaseDir + 'existe.fdb');

  // 6a) destino existe sem Sobrescrever -> falha amigavel
  Plano := NovoPlano(BaseDir + 'gbak.exe', BaseDir + 'origem.fbk',
                     BaseDir + 'existe.fdb', mgRestoreCriar,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  Msg := '';
  Check('pre: destino existe sem Sobrescrever falha',
        not Motor.ValidarAmbiente(Msg));
  Check('pre: mensagem amigavel cita Sobrescrever',
        Pos('Sobrescrever', Msg) > 0);
  Motor.Free;
  Plano.Free;

  // 6b) modo criar + destino existe (mesmo com flag) -> orienta usar -r
  Plano := NovoPlano(BaseDir + 'gbak.exe', BaseDir + 'origem.fbk',
                     BaseDir + 'existe.fdb', mgRestoreCriar,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Plano.Sobrescrever := True;
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  Msg := '';
  Check('pre: modo -c nao sobrescreve (orienta substituir)',
        not Motor.ValidarAmbiente(Msg));
  Check('pre: mensagem cita substituir', Pos('substituir', Msg) > 0);
  Motor.Free;
  Plano.Free;

  // 6c) modo r + Sobrescrever -> ambiente OK e risco destructive
  Plano := NovoPlano(BaseDir + 'gbak.exe', BaseDir + 'origem.fbk',
                     BaseDir + 'existe.fdb', mgRestoreSubstituir,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Plano.Sobrescrever := True;
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  Msg := '';
  Check('pre: r + Sobrescrever ambiente OK', Motor.ValidarAmbiente(Msg));
  Check('pre: risco destructive no substituir', Motor.Risco = rlDestructive);
  Motor.Free;
  Plano.Free;

  // 6d) origem inexistente
  Plano := NovoPlano(BaseDir + 'gbak.exe', BaseDir + 'nao_ha.fbk',
                     BaseDir + 'novo.fdb', mgRestoreCriar,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  Msg := '';
  Check('pre: origem inexistente falha', not Motor.ValidarAmbiente(Msg));
  Check('pre: mensagem cita a origem', Pos('Origem', Msg) > 0);
  Motor.Free;
  Plano.Free;

  // 6e) gbak inexistente e versao invalida
  Plano := NovoPlano(BaseDir + 'sem_gbak.exe', BaseDir + 'origem.fbk',
                     BaseDir + 'novo.fdb', mgRestoreCriar,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  Msg := '';
  Check('pre: gbak inexistente falha', not Motor.ValidarAmbiente(Msg));
  Check('pre: mensagem cita gbak', Pos('gbak', Msg) > 0);
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano(BaseDir + 'gbak.exe', BaseDir + 'origem.fbk',
                     BaseDir + 'novo.fdb', mgRestoreCriar, 'texto sem numero');
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  Msg := '';
  Check('pre: versao invalida falha', not Motor.ValidarAmbiente(Msg));
  Motor.Free;
  Plano.Free;

  // 6f) cria pasta do destino + backup e read-only (risco)
  D1 := BaseDir + 'subnaoexiste';
  Plano := NovoPlano(BaseDir + 'gbak.exe', BaseDir + 'origem.fbk',
                     D1 + '\novo.fdb', mgRestoreCriar,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  Msg := '';
  Check('pre: cria pasta do destino', Motor.ValidarAmbiente(Msg) and
        DirectoryExists(D1));
  Check('pre: risco write no criar novo', Motor.Risco = rlWrite);
  Motor.Free;
  Plano.Free;

  Plano := NovoPlano(BaseDir + 'gbak.exe', BaseDir + 'origem.fbk',
                     BaseDir + 'bk2.fbk', mgBackup,
                     'LI-V2.5.9.27110 Firebird 2.5');
  Motor := TMotorGbak.Create(nil);
  Motor.AtribuirPlano(Plano);
  Msg := '';
  Check('pre: backup com origem existente OK', Motor.ValidarAmbiente(Msg));
  Check('pre: risco read-only no backup', Motor.Risco = rlReadOnly);
  Check('backup: BuildArgs contem -b', Motor.BuildArgs and
        (AcharArg(Motor.Argv, '-b') >= 0));
  Motor.Free;
  Plano.Free;

  SysUtils.DeleteFile(BaseDir + 'gbak.exe');
  SysUtils.DeleteFile(BaseDir + 'existe.fdb');
  SysUtils.DeleteFile(BaseDir + 'origem.fbk');
  RemoveDir(BaseDir);

  // ============ 7) ponta a ponta com fake gbak (FPC) ============
  FpcPath := SysUtils.GetEnvironmentVariable('FB_FPC');
  if (FpcPath = '') or (not FileExists(FpcPath)) then
    FpcPath := SysUtils.GetEnvironmentVariable('FB_FPC');
  if FileExists(FpcPath) then
  begin
    D1 := TempDir + 'FBRTestFakeGbak' + IntToStr(GetCurrentProcessId);
    if DirectoryExists(D1) then
      RemoveDir(D1);
    ForceDirectories(D1);
    TesteE2E(FpcPath, IncludeTrailingPathDelimiter(D1));
    SysUtils.DeleteFile(D1 + '\fakegbak.pas');
    SysUtils.DeleteFile(D1 + '\fakegbak_ok.exe');
    SysUtils.DeleteFile(D1 + '\fakegbak_fail.exe');
    SysUtils.DeleteFile(D1 + '\backup.fbk');
    SysUtils.DeleteFile(D1 + '\restaurado.fdb');
    SysUtils.DeleteFile(D1 + '\restaurado2.fdb');
    RemoveDir(D1);
  end
  else
    WriteLn('SKIP: fake gbak nao compilado (FPC nao encontrado; defina FB_FPC)');

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.
