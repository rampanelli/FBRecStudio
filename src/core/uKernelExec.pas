{
  uKernelExec.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  Nucleo de execucao robusta de processos (PLANO.md 6.2/6.4). Pontos
  de projeto desta implementacao:

    * CreateProcessW + STARTF_USESTDHANDLES; janela oculta (SW_HIDE) e
      CREATE_NO_WINDOW; stdout e stderr em pipes SEPARADOS com
      SECURITY_ATTRIBUTES.bInheritHandle = True (write end) e read end
      nao-hereditario (SetHandleInformation).
    * Dois threads de leitura (um por pipe) anexam bytes crus a buffers;
      o thread de Run drena, decodifica e entrega LINHAS ao sink
      (IOutputSink.OnLine) - a UI nunca bloqueia (chamar Run em worker).
    * Timeout configuravel e cancelamento por evento (Cancel); ao
      cancelar/timeout mata a ARVORE de processos:
        - Job Object com JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE (XP ok);
        - fallback Toolhelp32 (CreateToolhelp32Snapshot) para filhos;
        - TerminateProcess como ultima instancia.
    * GetExitCodeProcess; fechamento de handles em finally; SEM arquivo
      temporario de nome fixo (pipes em memoria).
    * Linha de comando montada por uQuoting (argv tipado).

  Extensoes sobre o esboco do plano (documentadas):
    * TProcessOptions.ConsoleCodePage: 0 = GetOEMCP (secc. 6.5).
    * TProcessResult.ErrorText: mensagem quando o processo nao inicia.

  Contrato de threads: os callbacks do sink acontecem no thread que
  chamou Run. Use PostMessage na UI (nunca Synchronize direto de fora).

  Comentarios pt-BR sem diacriticos (ASCII) - compatibilidade Delphi 7.
  ------------------------------------------------------------------
}
unit uKernelExec;

{$H+}

interface

uses
  Windows, SysUtils, Classes, SyncObjs, uQuoting;

type
  // ------------------------------------------------------------------
  // Identificacao dos fluxos de saida
  // ------------------------------------------------------------------
  TStreamId = (stOut, stErr);

  // Eventos de ciclo de vida notificados via IOutputSink.OnProcessEvent
  TProcEvent = (peStarting, peStarted, peFailedToStart,
                peCanceled, peTimedOut, peFinished);

  // ------------------------------------------------------------------
  // Contrato: opcoes de execucao (PLANO.md 6.2)
  // ------------------------------------------------------------------
  TProcessOptions = record
    Executable: string;        // caminho completo do executavel (ANSI)
    WorkDir: string;           // diretorio de trabalho ('' = herda do pai)
    Args: TStringArray;        // argumentos tipados (SEM argv0)
    TimeoutMs: DWORD;          // 0 = sem timeout
    KillTreeOnCancel: Boolean; // Job Object + fallback Toolhelp
    ConsoleCodePage: Integer;  // 0 = GetOEMCP; >0 = override (secc. 6.5)
  end;

  // ------------------------------------------------------------------
  // Contrato: resultado da execucao (PLANO.md 6.2)
  // ------------------------------------------------------------------
  TProcessResult = record
    ExitCode: DWORD;
    Ok: Boolean;               // exit 0 e nao cancelado/timeout
    Started: TDateTime;
    Finished: TDateTime;
    Canceled: Boolean;
    TimedOut: Boolean;
    Summary: string;           // ultima linha relevante (out; fallback err)
    ErrorText: string;         // extensao: motivo quando nao iniciou
  end;

  // ------------------------------------------------------------------
  // Contrato: consumidor da saida (PLANO.md 6.2)
  // ------------------------------------------------------------------
  IOutputSink = interface
    // Uma linha decodificada (6.5): bytes OEM/UTF-8 -> texto ACP.
    procedure OnLine(AStream: TStreamId; const ALine: string);
    // Evento de ciclo de vida; AInfo traz detalhe textual (ex.: comando).
    procedure OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
  end;

  // ------------------------------------------------------------------
  // Contrato: executor (PLANO.md 6.2). Run e sincrono no thread chamador;
  // chamar de worker thread para nao travar a UI. Cancel pode ser chamado
  // de outro thread a qualquer momento.
  // ------------------------------------------------------------------
  IProcessRunner = interface
    function Run(const Opt: TProcessOptions; Sink: IOutputSink): TProcessResult;
    procedure Cancel;
  end;

  // ------------------------------------------------------------------
  // Execucao sincrona SIMPLES (auxiliar para as engines a partir da F0):
  // roda o processo descrito em Opt e entrega cada linha decodificada em
  // OutLines/ErrLines (nil = descartar). BLOQUEANTE - usar em worker
  // thread, nunca direto na thread da UI sem timer/evento.
  // ------------------------------------------------------------------
  function BuildAndRun(const Opt: TProcessOptions;
    OutLines, ErrLines: TStrings): TProcessResult;

type
  // ------------------------------------------------------------------
  // Thread que le UM pipe (stdout ou stderr) e anexa bytes crus.
  // Declarada ANTES de TProcessRunner (que a referencia em FReaderThread).
  // Para evitar dependencia circular de tipos (sem 'forward class' - nao
  // confiavel em D7 puro), o dono e passado como TObject e convertido na
  // implementacao (mesma unit: private e visivel na unit).
  // ------------------------------------------------------------------
  TPipeReaderThread = class(TThread)
  private
    FOwner: TObject;   // TProcessRunner (convertido no Execute)
    FStream: TStreamId;
    FPipe: THandle;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TObject; AStream: TStreamId; APipe: THandle);
  end;

  // Buffer de bytes crus anexados pela thread leitora de um pipe.
  TByteBuffer = record
    Bytes: array of Byte;
    Count: Integer;
  end;

  // ------------------------------------------------------------------
  // Implementacao concreta do executor.
  // ------------------------------------------------------------------
  TProcessRunner = class(TInterfacedObject, IProcessRunner)
  private
    FOptions: TProcessOptions;
    FSink: IOutputSink;
    FConsoleCp: Integer;

    FProcessHandle: THandle;
    FProcessId: DWORD;
    FJobHandle: THandle;
    FJobAssigned: Boolean;

    FReadPipe: array[TStreamId] of THandle;
    FReaderThread: array[TStreamId] of TPipeReaderThread;

    FStreamLock: TCriticalSection;   // protege os buffers FBuf
    FBuf: array[TStreamId] of TByteBuffer;
    FPartial: array[TStreamId] of string;  // resto de linha sem EOL (bytes)
    FLastLine: array[TStreamId] of string; // ultima linha decodificada

    FCancelEvent: THandle;
    FCanceled: Boolean;
    FTimedOut: Boolean;

    procedure ResetState;
    procedure ClearHandle(var H: THandle);
    function CreatePipes(var hOutRead, hErrRead, hOutWrite,
                         hErrWrite: THandle): Boolean;
    procedure AppendRaw(AStream: TStreamId; const ABuf: Pointer; ALen: Integer);
    function StartReader(AStream: TStreamId; hPipe: THandle): Boolean;
    procedure StopReadersAndDrain;
    procedure DrainStreams;
    procedure ProcessChunk(AStream: TStreamId; const Raw: string);
    procedure FlushPartial(AStream: TStreamId);
    procedure EmitLine(AStream: TStreamId; const RawLine: string);
    function CreateJobFor(hProcess: THandle): Boolean;
    procedure DoKill;
    procedure TerminateTree;
    procedure KillDescendants(ARootPid: DWORD);
  public
    constructor Create;
    destructor Destroy; override;
    function Run(const Opt: TProcessOptions; Sink: IOutputSink): TProcessResult;
    procedure Cancel;
  end;

implementation

uses
  uTextCodec;

// =====================================================================
// Constantes e estruturas locais (identificadores com prefixo KB_ para
// nao colidir com o Windows.pas do Delphi 7; todas as APIs existem no
// Windows XP SP3).
// =====================================================================
const
  KB_CREATE_NO_WINDOW        = $08000000;
  KB_STARTF_USESTDHANDLES    = $00000100;
  KB_STARTF_USESHOWWINDOW    = $00000001;
  KB_SW_HIDE                 = 0;
  KB_HANDLE_FLAG_INHERIT     = 1;
  KB_PROCESS_TERMINATE       = $0001;
  KB_TH32CS_SNAPPROCESS      = $00000002;
  KB_JOB_LIMIT_KILL_ON_JOB_CLOSE = $00002000;
  KB_JOB_BASIC_LIMIT_INFO    = 2; // JobObjectBasicLimitInformation

  KB_WAIT_SLICE_MS           = 50;   // fatia do WaitForMultipleObjects
  KB_WAIT_THREAD_MS          = 4000; // espera das threads leitoras
  KB_READ_CHUNK              = 8192; // bytes por leitura de pipe

type
  // STARTUPINFOW (layout 32-bit, alinhamento natural; packed e seguro aqui)
  KbStartupInfoW = packed record
    cb: DWORD;
    lpReserved: PWideChar;
    lpDesktop: PWideChar;
    lpTitle: PWideChar;
    dwX: DWORD;
    dwY: DWORD;
    dwXSize: DWORD;
    dwYSize: DWORD;
    dwXCountChars: DWORD;
    dwYCountChars: DWORD;
    dwFillAttribute: DWORD;
    dwFlags: DWORD;
    wShowWindow: WORD;
    cbReserved2: WORD;
    lpReserved2: PByte;
    hStdInput: THandle;
    hStdOutput: THandle;
    hStdError: THandle;
  end;

  KbProcessInformation = packed record
    hProcess: THandle;
    hThread: THandle;
    dwProcessId: DWORD;
    dwThreadId: DWORD;
  end;

  // JOBOBJECT_BASIC_LIMIT_INFORMATION (32-bit)
  KbJobBasicLimitInformation = packed record
    PerProcessUserTimeLimit: Int64;
    PerJobUserTimeLimit: Int64;
    LimitFlags: DWORD;
    MinimumWorkingSetSize: DWORD;
    MaximumWorkingSetSize: DWORD;
    ActiveProcessLimit: DWORD;
    Affinity: DWORD;          // ULONG_PTR em 32-bit
    PriorityClass: DWORD;
    SchedulingClass: DWORD;
  end;

  // PROCESSENTRY32W (Toolhelp32) - szExeFile tem MAX_PATH WideChars
  KbProcessEntry32W = packed record
    dwSize: DWORD;
    cntUsage: DWORD;
    th32ProcessID: DWORD;
    th32DefaultHeapID: DWORD;
    th32ModuleID: DWORD;
    cntThreads: DWORD;
    th32ParentProcessID: DWORD;
    pcPriClassBase: LongInt;
    dwFlags: DWORD;
    szExeFile: array[0..259] of WideChar;
  end;

// ---------------------------------------------------------------------
// Bindings com nome unico (kernel32). Criados sob medida para a F0.
// ---------------------------------------------------------------------
function KbCreatePipe(var hReadPipe, hWritePipe: THandle;
  lpPipeAttributes: PSecurityAttributes; nSize: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'CreatePipe';

function KbSetHandleInformation(hObject: THandle; dwMask: DWORD;
  dwFlags: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'SetHandleInformation';

function KbCreateProcessW(lpApplicationName: PWideChar;
  lpCommandLine: PWideChar; lpProcessAttributes: PSecurityAttributes;
  lpThreadAttributes: PSecurityAttributes; bInheritHandles: BOOL;
  dwCreationFlags: DWORD; lpEnvironment: Pointer;
  lpCurrentDirectory: PWideChar; const lpStartupInfo: KbStartupInfoW;
  var lpProcessInformation: KbProcessInformation): BOOL; stdcall;
  external 'kernel32.dll' name 'CreateProcessW';

function KbGetExitCodeProcess(hProcess: THandle;
  var lpExitCode: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'GetExitCodeProcess';

function KbCreateJobObjectW(lpJobAttributes: PSecurityAttributes;
  lpName: PWideChar): THandle; stdcall;
  external 'kernel32.dll' name 'CreateJobObjectW';

function KbSetInformationJobObject(hJob: THandle;
  JobObjectInformationClass: Integer; lpJobObjectInformation: Pointer;
  cbJobObjectInformationLength: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'SetInformationJobObject';

function KbAssignProcessToJobObject(hJob: THandle;
  hProcess: THandle): BOOL; stdcall;
  external 'kernel32.dll' name 'AssignProcessToJobObject';

function KbTerminateJobObject(hJob: THandle; uExitCode: UINT): BOOL; stdcall;
  external 'kernel32.dll' name 'TerminateJobObject';

function KbTerminateProcess(hProcess: THandle; uExitCode: UINT): BOOL; stdcall;
  external 'kernel32.dll' name 'TerminateProcess';

function KbOpenProcess(dwDesiredAccess: DWORD; bInheritHandle: BOOL;
  dwProcessId: DWORD): THandle; stdcall;
  external 'kernel32.dll' name 'OpenProcess';

function KbCreateToolhelp32Snapshot(dwFlags: DWORD;
  th32ProcessID: DWORD): THandle; stdcall;
  external 'kernel32.dll' name 'CreateToolhelp32Snapshot';

function KbProcess32FirstW(hSnapshot: THandle;
  var lppe: KbProcessEntry32W): BOOL; stdcall;
  external 'kernel32.dll' name 'Process32FirstW';

function KbProcess32NextW(hSnapshot: THandle;
  var lppe: KbProcessEntry32W): BOOL; stdcall;
  external 'kernel32.dll' name 'Process32NextW';

function KbCreateEventW(lpEventAttributes: PSecurityAttributes;
  bManualReset: BOOL; bInitialState: BOOL; lpName: PWideChar): THandle; stdcall;
  external 'kernel32.dll' name 'CreateEventW';

// GetTickCount existe no XP (requisito do plano) mas o FPC a deprecia em
// favor de GetTickCount64 (Vista+). Binding com nome proprio (mesmo
// padrao Kb* da unit) evita o aviso sem quebrar XP/D7.
function KbGetTickCount: DWORD; stdcall;
  external 'kernel32.dll' name 'GetTickCount';

// ---------------------------------------------------------------------
// Auxiliar de lista (unidade, nao membro da classe).
// ---------------------------------------------------------------------
function IsPidInList(const AList: array of DWORD; APid: DWORD): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(AList) to High(AList) do
    if AList[I] = APid then
    begin
      Result := True;
      Exit;
    end;
end;

// =====================================================================
// TPipeReaderThread
// =====================================================================
constructor TPipeReaderThread.Create(AOwner: TObject;
  AStream: TStreamId; APipe: THandle);
begin
  inherited Create(True); // suspensa ate o Runner dar Start/Resume
  FOwner := AOwner;
  FStream := AStream;
  FPipe := APipe;
end;

procedure TPipeReaderThread.Execute;
var
  Buf: array[0..KB_READ_CHUNK - 1] of Byte;
  n: DWORD;
begin
  while True do
  begin
    n := 0;
    // lpBuffer e um parametro 'var' sem tipo (D7 e FPC): passar o
    // ELEMENTO (endereco via lvalue); '@Buf[0]' (expressao) nao compila.
    if not ReadFile(FPipe, Buf[0], SizeOf(Buf), n, nil) then
      Break; // pipe fechado (processo terminou) ou erro -> fim
    if n = 0 then
      Break;
    // Cast seguro: FOwner foi criado por TProcessRunner (mesma unit).
    TProcessRunner(FOwner).AppendRaw(FStream, @Buf[0], Integer(n));
  end;
end;

// =====================================================================
// TProcessRunner - construcao / estado
// =====================================================================
constructor TProcessRunner.Create;
begin
  inherited Create;
  FStreamLock := TCriticalSection.Create;
  FCancelEvent := KbCreateEventW(nil, True, False, nil); // manual-reset
  ResetState;
end;

destructor TProcessRunner.Destroy;
begin
  if FCancelEvent <> 0 then
    CloseHandle(FCancelEvent);
  FStreamLock.Free;
  inherited Destroy;
end;

procedure TProcessRunner.ResetState;
var
  I: Integer;
  S: TStreamId;
begin
  FProcessHandle := 0;
  FProcessId := 0;
  FJobHandle := 0;
  FJobAssigned := False;
  FCanceled := False;
  FTimedOut := False;
  FConsoleCp := 0;
  for I := Ord(stOut) to Ord(stErr) do
  begin
    S := TStreamId(I);
    FReadPipe[S] := 0;
    FReaderThread[S] := nil;
    FBuf[S].Count := 0;
    FBuf[S].Bytes := nil;
    FPartial[S] := '';
    FLastLine[S] := '';
  end;
end;

procedure TProcessRunner.ClearHandle(var H: THandle);
begin
  if H <> 0 then
  begin
    CloseHandle(H);
    H := 0;
  end;
end;

// =====================================================================
// Pipes, leitura e linhas
// =====================================================================
function TProcessRunner.CreatePipes(var hOutRead, hErrRead, hOutWrite,
  hErrWrite: THandle): Boolean;
var
  SA: SECURITY_ATTRIBUTES;
begin
  Result := False;
  hOutRead := 0;
  hErrRead := 0;
  hOutWrite := 0;
  hErrWrite := 0;
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True; // write ends serao herdados pelo filho
  if not KbCreatePipe(hOutRead, hOutWrite, @SA, 0) then
    Exit;
  if not KbCreatePipe(hErrRead, hErrWrite, @SA, 0) then
  begin
    ClearHandle(hOutRead);
    ClearHandle(hOutWrite);
    ClearHandle(hErrRead);
    ClearHandle(hErrWrite);
    Exit;
  end;
  // Read ends NAO podem ser herdados (senao o pipe nunca "quebra" no fim).
  KbSetHandleInformation(hOutRead, KB_HANDLE_FLAG_INHERIT, 0);
  KbSetHandleInformation(hErrRead, KB_HANDLE_FLAG_INHERIT, 0);
  Result := True;
end;

procedure TProcessRunner.AppendRaw(AStream: TStreamId;
  const ABuf: Pointer; ALen: Integer);
var
  Needed: Integer;
begin
  if (ALen <= 0) or (ABuf = nil) then
    Exit;
  FStreamLock.Enter;
  try
    with FBuf[AStream] do
    begin
      Needed := Count + ALen;
      if Needed > Length(Bytes) then
        SetLength(Bytes, Needed + KB_READ_CHUNK);
      Move(ABuf^, Bytes[Count], ALen);
      Count := Needed;
    end;
  finally
    FStreamLock.Leave;
  end;
end;

function TProcessRunner.StartReader(AStream: TStreamId;
  hPipe: THandle): Boolean;
var
  T: TPipeReaderThread;
begin
  Result := False;
  try
    T := TPipeReaderThread.Create(Self, AStream, hPipe);
    FReaderThread[AStream] := T;
    // Resume e do Delphi 7; o FPC prefere Start (Resume esta deprecated).
    {$IFDEF FPC}
    T.Start;
    {$ELSE}
    T.Resume;
    {$ENDIF}
    Result := True;
  except
    Result := False; // falha rara; segue sem leitura deste pipe
  end;
end;

procedure TProcessRunner.DrainStreams;
var
  I: Integer;
  S: TStreamId;
  Raw: string;
  N: Integer;
begin
  for I := Ord(stOut) to Ord(stErr) do
  begin
    S := TStreamId(I);
    Raw := '';
    N := 0;
    FStreamLock.Enter;
    try
      N := FBuf[S].Count;
      if N > 0 then
      begin
        SetLength(Raw, N);
        Move(FBuf[S].Bytes[0], Raw[1], N);
        FBuf[S].Count := 0;
      end;
    finally
      FStreamLock.Leave;
    end;
    if N > 0 then
      ProcessChunk(S, Raw);
  end;
end;

procedure TProcessRunner.ProcessChunk(AStream: TStreamId; const Raw: string);
var
  S: string;
  P, J, K: Integer;
  Line: string;
begin
  S := FPartial[AStream] + Raw;
  P := 1;
  while P <= Length(S) do
  begin
    J := P;
    while (J <= Length(S)) and not (S[J] in [#13, #10]) do
      Inc(J);
    if J > Length(S) then
      Break; // linha incompleta: fica no FPartial
    Line := Copy(S, P, J - P);
    K := J;
    if (S[K] = #13) and (K < Length(S)) and (S[K + 1] = #10) then
      Inc(K); // CRLF
    Inc(K);
    EmitLine(AStream, Line);
    P := K;
  end;
  FPartial[AStream] := Copy(S, P, MaxInt);
end;

procedure TProcessRunner.FlushPartial(AStream: TStreamId);
begin
  if FPartial[AStream] <> '' then
  begin
    EmitLine(AStream, FPartial[AStream]);
    FPartial[AStream] := '';
  end;
end;

procedure TProcessRunner.EmitLine(AStream: TStreamId; const RawLine: string);
var
  Display: string;
begin
  // Decodifica bytes do console: heuristico UTF-8 senao OEM (secc. 6.5).
  Display := uTextCodec.DecodeConsoleBytes(RawLine, FConsoleCp);
  if Display <> '' then
    FLastLine[AStream] := Display;
  if FSink <> nil then
    FSink.OnLine(AStream, Display);
end;

procedure TProcessRunner.StopReadersAndDrain;
var
  I: Integer;
  S: TStreamId;
  T: TPipeReaderThread;
begin
  for I := Ord(stOut) to Ord(stErr) do
  begin
    S := TStreamId(I);
    T := FReaderThread[S];
    if T = nil then
      Continue;
    if WaitForSingleObject(T.Handle, KB_WAIT_THREAD_MS) = WAIT_TIMEOUT then
    begin
      // Destrava um eventual ReadFile pendente fechando o read end.
      if FReadPipe[S] <> 0 then
        ClearHandle(FReadPipe[S]);
      WaitForSingleObject(T.Handle, 3000);
    end;
    // Libera somente depois de a thread encerrar.
    if WaitForSingleObject(T.Handle, 2000) = WAIT_OBJECT_0 then
    begin
      T.Free;
      FReaderThread[S] := nil;
    end;
    // else: situacao anomala; a thread encerra com o processo (raro).
  end;
  DrainStreams;   // coleta o que chegou antes do fim
  FlushPartial(stOut);
  FlushPartial(stErr);
end;

// =====================================================================
// Cancelamento e morte da arvore de processos
// =====================================================================
procedure TProcessRunner.Cancel;
begin
  SetEvent(FCancelEvent);
end;

function TProcessRunner.CreateJobFor(hProcess: THandle): Boolean;
var
  JI: KbJobBasicLimitInformation;
begin
  Result := False;
  FJobHandle := KbCreateJobObjectW(nil, nil);
  if FJobHandle = 0 then
    Exit;
  FillChar(JI, SizeOf(JI), 0);
  JI.LimitFlags := KB_JOB_LIMIT_KILL_ON_JOB_CLOSE;
  if not KbSetInformationJobObject(FJobHandle, KB_JOB_BASIC_LIMIT_INFO,
                                   @JI, SizeOf(JI)) then
  begin
    ClearHandle(FJobHandle);
    Exit;
  end;
  if not KbAssignProcessToJobObject(FJobHandle, hProcess) then
  begin
    // Processo ja pertence a outro job (possivel no Vista+): sem job.
    // O kill usara o fallback Toolhelp sobre a arvore.
    ClearHandle(FJobHandle);
    FJobAssigned := False;
    Exit;
  end;
  FJobAssigned := True;
  Result := True;
end;

procedure TProcessRunner.KillDescendants(ARootPid: DWORD);
var
  Snapshot, hProc: THandle;
  Pe: KbProcessEntry32W;
  AllPids, AllParents, Pending: array of DWORD;
  I, Total: Integer;
  SelfPid: DWORD;
  Found: Boolean;
begin
  if ARootPid = 0 then
    Exit;
  Snapshot := KbCreateToolhelp32Snapshot(KB_TH32CS_SNAPPROCESS, 0);
  if Snapshot = THandle($FFFFFFFF) then
    Exit; // nao foi possivel enumerar; TerminateProcess dara conta da raiz
  SelfPid := GetCurrentProcessId;
  Total := 0;
  try
    FillChar(Pe, SizeOf(Pe), 0);
    Pe.dwSize := SizeOf(Pe);
    SetLength(AllPids, 0);
    SetLength(AllParents, 0);
    if KbProcess32FirstW(Snapshot, Pe) then
      repeat
        Inc(Total);
        SetLength(AllPids, Total);
        SetLength(AllParents, Total);
        AllPids[Total - 1] := Pe.th32ProcessID;
        AllParents[Total - 1] := Pe.th32ParentProcessID;
      until not KbProcess32NextW(Snapshot, Pe);

    // BFS: acumula raiz e todos os descendentes (qualquer profundidade).
    // IsPidInList(AList, APid): lista primeiro, pid depois.
    SetLength(Pending, 1);
    Pending[0] := ARootPid;
    repeat
      Found := False;
      for I := 0 to Total - 1 do
        if IsPidInList(Pending, AllParents[I]) and
           (not IsPidInList(Pending, AllPids[I])) then
        begin
          SetLength(Pending, Length(Pending) + 1);
          Pending[Length(Pending) - 1] := AllPids[I];
          Found := True;
        end;
    until not Found;

    // Termina dos mais profundos para a raiz (ordem inversa de adicao).
    for I := Length(Pending) - 1 downto 0 do
    begin
      if Pending[I] = SelfPid then
        Continue; // nunca mata o proprio processo
      hProc := KbOpenProcess(KB_PROCESS_TERMINATE, False, Pending[I]);
      if hProc <> 0 then
      begin
        KbTerminateProcess(hProc, 1);
        CloseHandle(hProc);
      end;
    end;
  finally
    CloseHandle(Snapshot);
  end;
end;

procedure TProcessRunner.TerminateTree;
begin
  KillDescendants(FProcessId);
  if FProcessHandle <> 0 then
    KbTerminateProcess(FProcessHandle, 1);
end;

procedure TProcessRunner.DoKill;
begin
  if FOptions.KillTreeOnCancel then
  begin
    // Preferencia: o Job Object termina a arvore inteira de uma so vez.
    if FJobAssigned and (FJobHandle <> 0) then
    begin
      if not KbTerminateJobObject(FJobHandle, 1) then
        TerminateTree;
    end
    else
      TerminateTree;
  end
  else if FProcessHandle <> 0 then
    KbTerminateProcess(FProcessHandle, 1); // somente o processo principal
  // Garante a saida do processo principal.
  if FProcessHandle <> 0 then
    WaitForSingleObject(FProcessHandle, 5000);
end;

// =====================================================================
// TProcessRunner.Run - fluxo principal
// =====================================================================
function TProcessRunner.Run(const Opt: TProcessOptions;
  Sink: IOutputSink): TProcessResult;
var
  hOutRead, hErrRead, hOutWrite, hErrWrite: THandle;
  hStdInNul: THandle;
  SI: KbStartupInfoW;
  PI: KbProcessInformation;
  FullArgs: array of string;
  CmdLine: string;
  ExeW, CmdLineW, DirW, NulName: WideString;
  WorkDirPtr: PWideChar;
  WaitHandles: array[0..1] of THandle;
  WaitRes, Deadline: DWORD;
  I, NArgs: Integer;
  ProcCreated: Boolean;
  SAIn: SECURITY_ATTRIBUTES;
begin
  Result.Ok := False;
  Result.ExitCode := 0;
  Result.Canceled := False;
  Result.TimedOut := False;
  Result.Summary := '';
  Result.ErrorText := '';
  Result.Started := Now;
  Result.Finished := Result.Started;

  ResetState;
  FOptions := Opt;
  FSink := Sink;
  FConsoleCp := Opt.ConsoleCodePage;

  if FSink <> nil then
    FSink.OnProcessEvent(peStarting, Opt.Executable);

  // Limpa o evento de cancelamento de uma eventual execucao anterior.
  if FCancelEvent <> 0 then
    ResetEvent(FCancelEvent);

  if Opt.Executable = '' then
  begin
    Result.ErrorText := 'Executavel nao informado (Executable vazio).';
    Result.Finished := Now;
    if FSink <> nil then
      FSink.OnProcessEvent(peFailedToStart, Result.ErrorText);
    Exit;
  end;

  if not FileExists(Opt.Executable) then
  begin
    Result.ErrorText := 'Executavel nao encontrado: ' + Opt.Executable;
    Result.Finished := Now;
    if FSink <> nil then
      FSink.OnProcessEvent(peFailedToStart, Result.ErrorText);
    Exit;
  end;

  hOutRead := 0;
  hErrRead := 0;
  hOutWrite := 0;
  hErrWrite := 0;
  hStdInNul := 0;
  ProcCreated := False;
  if not CreatePipes(hOutRead, hErrRead, hOutWrite, hErrWrite) then
  begin
    Result.ErrorText := 'Falha ao criar pipes: ' +
                        SysErrorMessage(GetLastError);
    Result.Finished := Now;
    if FSink <> nil then
      FSink.OnProcessEvent(peFailedToStart, Result.ErrorText);
    Exit;
  end;

  try
    // argv tipado -> linha de comando (uQuoting); nunca concatenacao crua.
    NArgs := Length(Opt.Args);
    SetLength(FullArgs, NArgs + 1);
    FullArgs[0] := Opt.Executable;
    for I := 0 to NArgs - 1 do
      FullArgs[I + 1] := Opt.Args[I];
    CmdLine := QuoteCmdLine(FullArgs);

    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := KB_STARTF_USESTDHANDLES or KB_STARTF_USESHOWWINDOW;
    SI.wShowWindow := KB_SW_HIDE;
    SI.hStdOutput := hOutWrite;
    SI.hStdError := hErrWrite;
    // stdin: com STARTF_USESTDHANDLES o filho precisa de um handle
    // valido/hereditario (handle NULL pode falhar). Abre o dispositivo
    // NUL somente-leitura; a copia do pai e fechada apos o CreateProcess.
    FillChar(SAIn, SizeOf(SAIn), 0);
    SAIn.nLength := SizeOf(SAIn);
    SAIn.bInheritHandle := True;
    NulName := 'NUL';
    hStdInNul := Windows.CreateFileW(PWideChar(NulName), GENERIC_READ,
                   FILE_SHARE_READ or FILE_SHARE_WRITE, @SAIn,
                   OPEN_EXISTING, 0, 0);
    SI.hStdInput := hStdInNul;

    if Opt.WorkDir <> '' then
    begin
      DirW := WideString(Opt.WorkDir);
      WorkDirPtr := PWideChar(DirW);
    end
    else
      WorkDirPtr := nil;
    ExeW := WideString(Opt.Executable);
    CmdLineW := WideString(CmdLine);

    FillChar(PI, SizeOf(PI), 0);
    if not KbCreateProcessW(PWideChar(ExeW), PWideChar(CmdLineW), nil, nil,
                            True, KB_CREATE_NO_WINDOW, nil, WorkDirPtr,
                            SI, PI) then
    begin
      Result.ErrorText := 'Falha ao iniciar ' + Opt.Executable + ': ' +
                          SysErrorMessage(GetLastError);
      Result.Finished := Now;
      if FSink <> nil then
        FSink.OnProcessEvent(peFailedToStart, Result.ErrorText);
      Exit;
    end;
    ProcCreated := True;

    // O pai fecha os write ends (o filho detem as copias herdadas).
    CloseHandle(hOutWrite);
    hOutWrite := 0;
    CloseHandle(hErrWrite);
    hErrWrite := 0;
    if hStdInNul <> 0 then
    begin
      CloseHandle(hStdInNul);
      hStdInNul := 0;   // o filho detem a copia herdada do NUL
    end;
    CloseHandle(PI.hThread);
    FProcessHandle := PI.hProcess;
    FProcessId := PI.dwProcessId;

    // Read ends passam a ser de propriedade dos campos (fonte unica).
    FReadPipe[stOut] := hOutRead;
    FReadPipe[stErr] := hErrRead;
    hOutRead := 0;
    hErrRead := 0;

    if Opt.KillTreeOnCancel then
      CreateJobFor(FProcessHandle);

    StartReader(stOut, FReadPipe[stOut]);
    StartReader(stErr, FReadPipe[stErr]);
    // Sem leitores nao ha como drenar os pipes: encerra (evita o filho
    // bloquear com o buffer do pipe cheio).
    if (FReaderThread[stOut] = nil) or (FReaderThread[stErr] = nil) then
    begin
      Result.ErrorText := 'Falha ao criar thread leitora de saida.';
      DoKill;
    end;

    Result.Started := Now;
    if FSink <> nil then
      FSink.OnProcessEvent(peStarted,
                           uQuoting.MakeDisplayCommandLine(FullArgs));

    // ------------------ laco principal de espera ------------------
    WaitHandles[0] := FProcessHandle;
    WaitHandles[1] := FCancelEvent;
    Deadline := 0;
    if Opt.TimeoutMs > 0 then
      Deadline := KbGetTickCount + Opt.TimeoutMs;

    repeat
      WaitRes := WaitForMultipleObjects(2, @WaitHandles[0], False,
                                        KB_WAIT_SLICE_MS);
      DrainStreams;
      if WaitRes = WAIT_OBJECT_0 then
        Break                       // processo terminou sozinho
      else if WaitRes = (WAIT_OBJECT_0 + 1) then
      begin
        FCanceled := True;          // cancelamento solicitado
        DoKill;
        Break;
      end
      else if WaitRes = WAIT_TIMEOUT then
      begin
        if (Deadline <> 0) and (KbGetTickCount >= Deadline) then
        begin
          FTimedOut := True;
          DoKill;
          Break;
        end;
      end
      else
      begin
        // WAIT_FAILED (raro): registra o motivo e encerra o laco.
        if Result.ErrorText = '' then
          Result.ErrorText := 'Falha na espera do processo: ' +
                              SysErrorMessage(GetLastError);
        DoKill;
        Break;
      end;
    until False;
  finally
    if ProcCreated then
    begin
      // Encerra as threads leitoras e drena o que restou no pipe.
      StopReadersAndDrain;
      Result.ExitCode := 0;
      if not KbGetExitCodeProcess(FProcessHandle, Result.ExitCode) then
        if Result.ErrorText = '' then
          Result.ErrorText := 'Falha ao ler exit code: ' +
                              SysErrorMessage(GetLastError);
      if FLastLine[stOut] <> '' then
        Result.Summary := FLastLine[stOut]
      else
        Result.Summary := FLastLine[stErr];
      Result.Canceled := FCanceled;
      Result.TimedOut := FTimedOut;
      Result.Ok := (Result.ExitCode = 0) and (not FCanceled) and
                   (not FTimedOut) and (Result.ErrorText = '');
      Result.Finished := Now;
      if FCanceled then
      begin
        if FSink <> nil then
          FSink.OnProcessEvent(peCanceled, Result.Summary);
      end
      else if FTimedOut then
      begin
        if FSink <> nil then
          FSink.OnProcessEvent(peTimedOut, Result.Summary);
      end;
      if FSink <> nil then
        FSink.OnProcessEvent(peFinished,
          'exit=' + IntToStr(Integer(Result.ExitCode)) +
          ' resumo=' + Result.Summary);
    end;

    // Fechamento de handles em finally - nunca vaza.
    if hStdInNul <> 0 then
      ClearHandle(hStdInNul);
    if hOutRead <> 0 then
      ClearHandle(hOutRead);
    if hErrRead <> 0 then
      ClearHandle(hErrRead);
    if FReadPipe[stOut] <> 0 then
      ClearHandle(FReadPipe[stOut]);
    if FReadPipe[stErr] <> 0 then
      ClearHandle(FReadPipe[stErr]);
    if FJobHandle <> 0 then
      ClearHandle(FJobHandle);
    if FProcessHandle <> 0 then
      ClearHandle(FProcessHandle);
    FSink := nil;
    FOptions.Args := nil;
    FullArgs := nil;
  end;
end;

// =====================================================================
// BuildAndRun - execucao sincrona simples (auxiliar das engines)
// =====================================================================
type
  // Sink que coleta as linhas decodificadas em TStrings do chamador.
  // Nao acumula eventos: o estado completo volta no TProcessResult.
  TCollectingSink = class(TInterfacedObject, IOutputSink)
  private
    FOut: TStrings;
    FErr: TStrings;
  public
    constructor Create(OutLines, ErrLines: TStrings);
    procedure OnLine(AStream: TStreamId; const ALine: string);
    procedure OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
  end;

constructor TCollectingSink.Create(OutLines, ErrLines: TStrings);
begin
  inherited Create;
  FOut := OutLines; // podem ser nil => descartar as linhas
  FErr := ErrLines;
end;

procedure TCollectingSink.OnLine(AStream: TStreamId; const ALine: string);
begin
  if AStream = stOut then
  begin
    if FOut <> nil then
      FOut.Add(ALine);
  end
  else if FErr <> nil then
    FErr.Add(ALine);
end;

procedure TCollectingSink.OnProcessEvent(AEvent: TProcEvent;
  const AInfo: string);
begin
  // Nada a fazer no modo sincrono simples; o resultado vem em
  // TProcessResult (Ok/Canceled/TimedOut/ExitCode/Summary).
end;

function BuildAndRun(const Opt: TProcessOptions;
  OutLines, ErrLines: TStrings): TProcessResult;
var
  Runner: TProcessRunner;
  Sink: TCollectingSink;
  Intf: IOutputSink;
begin
  Runner := TProcessRunner.Create;
  try
    Sink := TCollectingSink.Create(OutLines, ErrLines);
    Intf := Sink; // a interface gerencia o ciclo de vida do sink
    Result := Runner.Run(Opt, Intf);
    Intf := nil;  // refcount 0 => libera o sink no final do Run
  finally
    Runner.Free;
  end;
end;

end.
