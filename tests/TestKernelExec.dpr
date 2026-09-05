program TestKernelExec;

{ Testes de uKernelExec (F0-T4). Console; exit = n. de falhas.
  1) execucao normal de "%COMSPEC% /c ver" coletando saida por IOutputSink;
  2) timeout forcado com kill da arvore (Job Object / Toolhelp).
  Requer cmd.exe (presente em todo Windows).

  Nota de vida util: o sink e passado como INTERFACE; o teste mantem
  tambem uma referencia tipada (SinkObj) para ler as listas depois do
  Run (senao o refcount do TInterfacedObject o liberaria ao final). }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Classes,
  uKernelExec in '..\src\core\uKernelExec.pas',
  uQuoting in '..\src\core\uQuoting.pas',
  uTextCodec in '..\src\core\uTextCodec.pas';

type
  // Sink simples: coleta linhas/eventos (Run e sincrono no mesmo thread
  // do teste, entao nao precisa de trava).
  TCollectSink = class(TInterfacedObject, IOutputSink)
  public
    OutLines: TStringList;
    ErrLines: TStringList;
    Events: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure OnLine(AStream: TStreamId; const ALine: string);
    procedure OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
  end;

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

constructor TCollectSink.Create;
begin
  inherited Create;
  OutLines := TStringList.Create;
  ErrLines := TStringList.Create;
  Events := TStringList.Create;
end;

destructor TCollectSink.Destroy;
begin
  OutLines.Free;
  ErrLines.Free;
  Events.Free;
  inherited Destroy;
end;

procedure TCollectSink.OnLine(AStream: TStreamId; const ALine: string);
begin
  if AStream = stOut then
    OutLines.Add(ALine)
  else
    ErrLines.Add(ALine);
end;

procedure TCollectSink.OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
begin
  Events.Add(IntToStr(Ord(AEvent)) + ':' + AInfo);
end;

procedure BuildVerOpt(var Opt: TProcessOptions);
begin
  Opt.Executable := SysUtils.GetEnvironmentVariable('COMSPEC');
  if Opt.Executable = '' then
    Opt.Executable := 'cmd.exe';
  SetLength(Opt.Args, 2);
  Opt.Args[0] := '/c';
  Opt.Args[1] := 'ver';
  Opt.WorkDir := '';
  Opt.TimeoutMs := 15000;
  Opt.KillTreeOnCancel := True;
  Opt.ConsoleCodePage := 0;
end;

procedure ReleaseSink(var ASink: IOutputSink);
begin
  // TInterfacedObject se auto-libera quando a ultima referencia
  // de interface sai (refcount zera); NAO chamar Free depois.
  ASink := nil;
end;

var
  Runner: IProcessRunner;
  Sink: IOutputSink;
  SinkObj: TCollectSink;
  Opt: TProcessOptions;
  Res: TProcessResult;
  Comspec: string;
begin
  Fails := 0;
  Checks := 0;
  Comspec := SysUtils.GetEnvironmentVariable('COMSPEC');
  if Comspec = '' then
    Comspec := 'cmd.exe';
  if not FileExists(Comspec) then
  begin
    WriteLn('cmd.exe nao encontrado - testes de execucao ignorados');
    Halt(0);
  end;

  // ============ 1) execucao normal ============
  Runner := TProcessRunner.Create;
  SinkObj := TCollectSink.Create;
  Sink := SinkObj; // interface mantem o objeto vivo durante o Run
  BuildVerOpt(Opt);
  Res := Runner.Run(Opt, Sink);

  Check('ver Ok', Res.Ok);
  Check('ver exit=0', Res.ExitCode = 0);
  Check('ver nao cancelado', not Res.Canceled);
  Check('ver sem timeout', not Res.TimedOut);
  Check('ver coletou saida', SinkObj.OutLines.Count > 0);
  Check('ver comecou antes de terminar', Res.Finished >= Res.Started);
  // O cmd real emite uma linha em branco inicial (0D 0A) antes do texto
  // (validado em runtime); procurar 'Microsoft' em QUALQUER linha.
  if SinkObj.OutLines.Count > 0 then
    Check('ver linha tipica (Microsoft Windows)',
          Pos('Microsoft', SinkObj.OutLines.Text) > 0);
  ReleaseSink(Sink);
  SinkObj := nil; // ponteiro tipado obsoleto apos a liberacao
  Runner := nil;

  // ============ 2) timeout forcado (processo que demora) ============
  Runner := TProcessRunner.Create;
  SinkObj := TCollectSink.Create;
  Sink := SinkObj;
  BuildVerOpt(Opt);
  SetLength(Opt.Args, 2);
  Opt.Args[0] := '/c';
  Opt.Args[1] := 'ping -n 30 127.0.0.1 >nul';
  Opt.TimeoutMs := 800;
  Res := Runner.Run(Opt, Sink);

  Check('timeout detectado', Res.TimedOut);
  Check('timeout nao Ok', not Res.Ok);
  Check('timeout nao e cancelamento manual', not Res.Canceled);
  Check('timeout encerrou rapido (< 15s)',
        (Res.Finished - Res.Started) * 86400 < 15);
  ReleaseSink(Sink);
  SinkObj := nil; // ponteiro tipado obsoleto apos a liberacao
  Runner := nil;

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.
