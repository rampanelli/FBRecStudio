program RunCoreTests;

{ Teste unico que exercita TODAS as units de src\core e src\persist (F0)
  compilando com Free Pascal (-Mdelphi) OU Delphi 7 puro (dcc32):

    core:    uTextCodec, uQuoting, uLogger, uHash, uKernelExec
    persist: uAppConfig, uCredStore (DPAPI real), uHistoryStore

  Cada verificacao imprime PASS/FAIL; exit code = n. de falhas (0 = ok).

  IMPORTANTE (nao poluir dados reais): toda a execucao usa UMA pasta
  temporaria unica criada em %TEMP% (nada de %APPDATA% do usuario).

  uCredStore roda DPAPI de verdade (CryptProtectData do usuario da
  sessao); uKernelExec roda cmd.exe de verdade (exit 0/7, timeout e
  cancelamento com kill da arvore).

  Fonte ASCII puro (sem acentos) - regra do repositorio (D7 le ANSI). }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Classes, Windows,
  uTextCodec in '..\src\core\uTextCodec.pas',
  uQuoting in '..\src\core\uQuoting.pas',
  uLogger in '..\src\core\uLogger.pas',
  uHash in '..\src\core\uHash.pas',
  uKernelExec in '..\src\core\uKernelExec.pas',
  uAppConfig in '..\src\persist\uAppConfig.pas',
  uCredStore in '..\src\persist\uCredStore.pas',
  uHistoryStore in '..\src\persist\uHistoryStore.pas';

var
  Fails, Checks: Integer;
  BaseDir: string;

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

// ------------------------------------------------------------------
// Pasta %TEMP% via Windows API (GetTempPath exige 2 parametros).
// ------------------------------------------------------------------
function TempDir: string;
var
  Buf: array[0..MAX_PATH] of Char;
  N: DWORD;
begin
  N := GetTempPath(SizeOf(Buf), PChar(@Buf[0]));
  if N = 0 then
    Result := '.'
  else
    SetString(Result, PChar(@Buf[0]), Integer(N));
end;

// Le arquivo inteiro como bytes (string).
function ReadAllText(const APath: string): string;
var
  FS: TFileStream;
begin
  Result := '';
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Result[1], FS.Size);
  finally
    FS.Free;
  end;
end;

function Stamp: string;
begin
  Result := FormatDateTime('yyyymmddhhnnsszzz', Now);
end;

// ==================================================================
// uTextCodec (resumo; TestCodec.dpr tem a suite completa)
// ==================================================================
procedure TestTextCodec;
var
  T: string;
begin
  Check('codec IsAsciiOnly true', IsAsciiOnly('FBRecStudio 123'));
  T := 'caf' + #$E9; // bytes ACP puros; roundtrip de estabilidade
  Check('codec roundtrip ansi->utf8->ansi', Utf8ToAnsi(AnsiToUtf8(T)) = T);
  Check('codec LooksLikeUtf8 falso p/ byte alto unico', not LooksLikeUtf8(#$E9));
end;

// ==================================================================
// uQuoting (resumo; TestQuoting.dpr tem a suite completa)
// ==================================================================
procedure TestQuoting;
var
  Cmd, Parsed0: string;
  Parsed: TStringArray;
begin
  Cmd := QuoteCmdLine(['C:\Program Files\Firebird\isql.exe', '-u', 'sysdba']);
  Check('quoting espaco envolvido em aspas',
        Pos('"C:\Program Files\Firebird\isql.exe"', Cmd) = 1);
  Check('quoting vazio vira aspas', QuoteArg('') = '""');
  if ParseCommandLine(Cmd, Parsed) = 3 then
    Parsed0 := Parsed[0]
  else
    Parsed0 := '';
  Check('quoting parser roundtrip argv0', Parsed0 = 'C:\Program Files\Firebird\isql.exe');
  Check('quoting mascara -pass',
        Pos('segredo', MakeDisplayCommandLine(['gbak', '-pass', 'segredo'])) = 0);
end;

// ==================================================================
// uLogger (arquivo unico em %TEMP%)
// ==================================================================
procedure TestLogger;
var
  LogPath: string;
  L: TLogger;
  Content: string;
  Buf: array[0..2] of Byte;
  FS: TFileStream;
begin
  LogPath := BaseDir + 'log_core.log';
  L := TLogger.Create;
  try
    Check('logger abre arquivo novo', L.Open(LogPath));
    L.Info('run', 'linha de teste');
    L.Log('run', LC_STDOUT, 'stdout decodificado');
    L.Close;
  finally
    L.Free;
  end;
  Content := ReadAllText(LogPath);
  Check('logger gravou canal app', Pos('[app]', Content) > 0);
  Check('logger gravou etapa', Pos('[run]', Content) > 0);
  Check('logger gravou stdout', Pos('stdout decodificado', Content) > 0);
  FS := TFileStream.Create(LogPath, fmOpenRead or fmShareDenyNone);
  try
    FillChar(Buf, SizeOf(Buf), 0);
    FS.ReadBuffer(Buf, 3);
  finally
    FS.Free;
  end;
  Check('logger BOM EF BB BF', (Buf[0] = $EF) and (Buf[1] = $BB) and (Buf[2] = $BF));
  // logar antes de abrir nao pode quebrar nada
  L := TLogger.Create;
  try
    L.Info('run', 'nao deve gravar');
    Check('logger fechado nao grava', not L.IsOpen);
  finally
    L.Free;
  end;
end;

// ==================================================================
// uHash (vetores MD5/SHA-1 conhecidos - CryptoAPI real)
// ==================================================================
procedure TestHash;
begin
  Check('hash md5 vazio', HashStringHex('', haMd5) = 'd41d8cd98f00b204e9800998ecf8427e');
  Check('hash md5 abc', HashStringHex('abc', haMd5) = '900150983cd24fb0d6963f7d28e17f72');
  Check('hash sha1 vazio',
        HashStringHex('', haSha1) = 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
  Check('hash sha1 abc',
        HashStringHex('abc', haSha1) = 'a9993e364706816aba3e25717850c26c9cd0d89d');
  Check('hash comprimento 32 hex (md5)', Length(HashStringHex('abc', haMd5)) = 32);
  Check('hash comprimento 40 hex (sha1)', Length(HashStringHex('abc', haSha1)) = 40);
end;

// ==================================================================
// uKernelExec - BuildAndRun e cancelamento (processos REAIS)
// ==================================================================
procedure TestKernelExecCore;
var
  Opt: TProcessOptions;
  Res: TProcessResult;
  Comspec: string;
begin
  Comspec := SysUtils.GetEnvironmentVariable('COMSPEC');
  if Comspec = '' then
    Comspec := 'cmd.exe';
  if not FileExists(Comspec) then
  begin
    WriteLn('cmd.exe nao encontrado - testes de execucao ignorados');
    Exit;
  end;

  // --- exit 0 ---
  Opt.Executable := Comspec;
  SetLength(Opt.Args, 2);
  Opt.Args[0] := '/c';
  Opt.Args[1] := 'exit 0';
  Opt.WorkDir := '';
  Opt.TimeoutMs := 15000;
  Opt.KillTreeOnCancel := True;
  Opt.ConsoleCodePage := 0;
  Res := BuildAndRun(Opt, nil, nil);
  Check('exec exit 0 -> Ok', Res.Ok);
  Check('exec exit 0 -> ExitCode 0', Res.ExitCode = 0);

  // --- exit 7 ---
  Opt.Args[1] := 'exit 7';
  Res := BuildAndRun(Opt, nil, nil);
  Check('exec exit 7 -> ExitCode 7', Res.ExitCode = 7);
  Check('exec exit 7 -> nao Ok', not Res.Ok);

  // --- timeout (processo que dorme; kill da arvore) ---
  Opt.Args[1] := 'ping -n 30 127.0.0.1 >nul';
  Opt.TimeoutMs := 1000;
  Res := BuildAndRun(Opt, nil, nil);
  Check('exec timeout detectado', Res.TimedOut);
  Check('exec timeout nao Ok', not Res.Ok);
  Check('exec timeout rapido (<15s)', (Res.Finished - Res.Started) * 86400 < 15);
end;

type
  // Cancela o runner apos um atraso (roda em outro thread).
  TCancelThread = class(TThread)
  private
    FRunner: IProcessRunner;
    FDelayMs: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(ARunner: IProcessRunner; ADelayMs: Integer);
  end;

constructor TCancelThread.Create(ARunner: IProcessRunner; ADelayMs: Integer);
begin
  inherited Create(True); // comeca suspensa; o teste da Start/Resume
  FRunner := ARunner;
  FDelayMs := ADelayMs;
end;

procedure TCancelThread.Execute;
begin
  Sleep(FDelayMs);
  if FRunner <> nil then
    FRunner.Cancel;
end;

procedure TestKernelExecCancel;
var
  Runner: TProcessRunner;
  RunnerIntf: IProcessRunner;
  CancelT: TCancelThread;
  Opt: TProcessOptions;
  Res: TProcessResult;
  Comspec: string;
begin
  Comspec := SysUtils.GetEnvironmentVariable('COMSPEC');
  if Comspec = '' then
    Comspec := 'cmd.exe';
  if not FileExists(Comspec) then
    Exit;
  Runner := TProcessRunner.Create;
  RunnerIntf := Runner;
  CancelT := TCancelThread.Create(RunnerIntf, 400);
  try
    Opt.Executable := Comspec;
    SetLength(Opt.Args, 2);
    Opt.Args[0] := '/c';
    Opt.Args[1] := 'ping -n 30 127.0.0.1 >nul';
    Opt.WorkDir := '';
    Opt.TimeoutMs := 0;           // sem timeout: so o cancel manual para
    Opt.KillTreeOnCancel := True; // kill da arvore (Job Object)
    Opt.ConsoleCodePage := 0;
    // inicia o cancelador e roda o processo no thread corrente
    {$IFDEF FPC}
    CancelT.Start;
    {$ELSE}
    CancelT.Resume;
    {$ENDIF}
    Res := RunnerIntf.Run(Opt, nil);
    Check('exec cancel detectado', Res.Canceled);
    Check('exec cancel nao Ok', not Res.Ok);
    Check('exec cancel nao e timeout', not Res.TimedOut);
    CancelT.WaitFor;
  finally
    CancelT.Free;
    RunnerIntf := nil; // libera o TProcessRunner
  end;
end;

// ==================================================================
// uAppConfig - load/save/EnsureDefaultValues em pasta temporaria
// ==================================================================
procedure TestAppConfig;
var
  Path: string;
  Cfg: TAppConfig;
begin
  Path := BaseDir + 'config.ini';
  Cfg := TAppConfig.Create(Path);
  try
    Cfg.EnsureDefaultValues;
    Check('config defaults TimeoutMs=0', Cfg.GetTimeoutMs = 0);
    Check('config defaults ConsoleCodePage=0', Cfg.GetConsoleCodePage = 0);
    Check('config defaults Charset WIN1252', Cfg.GetDefaultCharset = 'WIN1252');
    Check('config defaults Theme light', Cfg.GetTheme = 'light');
    Check('config defaults SaveCredentials false', not Cfg.GetSaveCredentials);
    Check('config defaults FbBinDir vazio', Cfg.GetFbBinDir = '');
    Check('config DefaultOutDir nao vazio', Cfg.GetDefaultOutDir <> '');
    // altera e fecha
    Cfg.SetTimeoutMs(4321);
    Cfg.SetTheme('dark');
    Cfg.SetFbBinDir('C:\fake\firebird');
  finally
    Cfg.Free;
  end;
  // releitura: valores persistiram
  Cfg := TAppConfig.Create(Path);
  try
    Check('config reload TimeoutMs=4321', Cfg.GetTimeoutMs = 4321);
    Check('config reload Theme dark', Cfg.GetTheme = 'dark');
    Check('config reload FbBinDir', Cfg.GetFbBinDir = 'C:\fake\firebird');
    // EnsureDefaultValues NAO sobrescreve chaves existentes
    Cfg.EnsureDefaultValues;
    Check('config ensure nao sobrescreve theme', Cfg.GetTheme = 'dark');
    Check('config ensure nao sobrescreve timeout', Cfg.GetTimeoutMs = 4321);
  finally
    Cfg.Free;
  end;
  Check('config arquivo criado', FileExists(Path));
end;

// ==================================================================
// uCredStore - DPAPI REAL (Save/Load/Erase em arquivo temporario)
// ==================================================================
procedure TestCredStore;
var
  Path: string;
  Cred: TCredStore;
  U, P: string;
  OkSave: Boolean;
begin
  Path := BaseDir + 'credentials.bin';
  Cred := TCredStore.Create(Path);
  try
    OkSave := Cred.Save('sysdba', 'masterkey-123');
    Check('credstore DPAPI save', OkSave);
    if OkSave then
    begin
      Check('credstore DPAPI Load ok', Cred.Load(U, P));
      if (U = 'sysdba') and (P = 'masterkey-123') then
        Check('credstore usuario/senha roundtrip', True)
      else
        Check('credstore usuario/senha roundtrip', False);
      Cred.Erase;
      Check('credstore arquivo removido', not FileExists(Path));
      Check('credstore Load apos erase falha', not Cred.Load(U, P));
    end
    else
      WriteLn('NOTA: DPAPI indisponivel na sessao (CryptProtectData) - save falhou; verificar contexto.');
  finally
    Cred.Free;
  end;
end;

// ==================================================================
// uHistoryStore - append CSV + campos (arquivo temporario)
// ==================================================================
procedure TestHistoryStore;
var
  Path: string;
  H: THistoryStore;
  E1, E2: THistoryEntry;
  Content: string;
begin
  Path := BaseDir + 'history.csv';
  H := THistoryStore.Create(Path);
  try
    FillChar(E1, SizeOf(E1), 0);
    E1.Id := NewOperationId;
    E1.Data := IsoNow;
    E1.ArquivoOrigem := 'C:\origem\banco.fdb';
    E1.Tipo := 'FB';
    E1.BinarioVersao := 'Firebird 2.5.9';
    E1.Tecnica := 'gbak';
    E1.ParametrosMascarados := 'gbak -b -pass ******';
    E1.ExitCode := '0';
    E1.DuracaoMs := 1234;
    E1.Destino := 'C:\destino\banco.fbk';
    E1.TamanhoBytes := 5678;
    E1.Status := 'ok';
    E1.Resumo := 'backup concluido';
    E1.Hash := HashStringHex('banco.fdb', haMd5);
    E1.CaminhoLog := 'log1.log';

    FillChar(E2, SizeOf(E2), 0);
    E2.Id := NewOperationId;
    E2.Data := IsoNow;
    E2.ArquivoOrigem := 'C:\origem\outro.fdb';
    E2.Tipo := 'IB';
    E2.BinarioVersao := 'InterBase 2020';
    E2.Tecnica := 'gbak';
    E2.ParametrosMascarados := '-pass ******';
    E2.ExitCode := '7';
    E2.DuracaoMs := 42;
    E2.Destino := 'C:\destino\outro.fbk';
    E2.TamanhoBytes := 99;
    E2.Status := 'erro';
    E2.Resumo := 'falha; campo com "aspas" e separador; fim'; // escape CSV
    E2.Hash := '';
    E2.CaminhoLog := '';

    H.AppendEntry(E1);
    Check('history EntryCount=1 apos 1a gravacao', H.EntryCount = 1);
    H.AppendEntry(E2);
    Check('history EntryCount=2 apos 2a gravacao', H.EntryCount = 2);
  finally
    H.Free;
  end;
  Content := ReadAllText(Path);
  Check('history cabecalho gravado', Pos('arquivo_origem', Content) > 0);
  Check('history linha 1 com dados', Pos('banco.fdb', Content) > 0);
  Check('history hash md5 presente',
        Pos(HashStringHex('banco.fdb', haMd5), Content) > 0);
  Check('history aspas escapadas (campo com ; e "")',
        Pos('"falha; campo com ""aspas"" e separador; fim"', Content) > 0);
  Check('history status ok', Pos(';ok;', Content) > 0);
  Check('history separador ; presente', Pos(';', Content) > 0);
end;

// ==================================================================
// Programa principal
// ==================================================================
begin
  Fails := 0;
  Checks := 0;
  BaseDir := IncludeTrailingPathDelimiter(TempDir) +
             'FBRecStudio_RunCoreTests_' + Stamp + '_' +
             IntToStr(GetCurrentProcessId) + PathDelim;
  ForceDirectories(BaseDir);

  WriteLn('=== uTextCodec ===');
  TestTextCodec;
  WriteLn('=== uQuoting ===');
  TestQuoting;
  WriteLn('=== uLogger ===');
  TestLogger;
  WriteLn('=== uHash ===');
  TestHash;
  WriteLn('=== uKernelExec (BuildAndRun) ===');
  TestKernelExecCore;
  WriteLn('=== uKernelExec (cancel) ===');
  TestKernelExecCancel;
  WriteLn('=== uAppConfig ===');
  TestAppConfig;
  WriteLn('=== uCredStore (DPAPI) ===');
  TestCredStore;
  WriteLn('=== uHistoryStore ===');
  TestHistoryStore;

  // limpeza best-effort da pasta temporaria (nao falha o teste)
  SysUtils.DeleteFile(BaseDir + 'log_core.log');
  SysUtils.DeleteFile(BaseDir + 'config.ini');
  SysUtils.DeleteFile(BaseDir + 'credentials.bin');
  SysUtils.DeleteFile(BaseDir + 'history.csv');
  RemoveDir(BaseDir);

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.
