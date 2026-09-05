program FBRecStudio;

{ FBRecStudio (FB Recovery Studio) - aplicacao GUI Delphi 7.
  Aplicacao funcional v1: abre arquivo
  por linha de comando/duplo clique, single-instance (mutex) com
  repasse via WM_COPYDATA, auto-deteccao de utilitarios Firebird/
  InterBase, diagnostico e restauracao/backup gbak em worker thread.

  - Comentarios pt-BR sem diacriticos (ASCII) - D7.
  - Nenhuma unidade de negocios depende de Forms (secc. 6.1). }
uses
  SysUtils, Windows, Messages, Forms,
  uLogger in '..\core\uLogger.pas',
  uAppConfig in '..\persist\uAppConfig.pas',
  uFrmMain in '..\ui\uFrmMain.pas' {frmMain};

{$R *.res}

const
  MUTEX_NAME = 'FBRecStudio_SingleInstance';

// Repassa o arquivo recebido na linha de comando para a janela da
// instancia ja em execucao (WM_COPYDATA). True = aceito.
function ForwardFileToRunning(const AFileName: string; AWindow: THandle): Boolean;
var
  Cds: TCopyDataStruct;
  S: string;
begin
  Result := False;
  if (AWindow = 0) or (AFileName = '') then
    Exit;
  S := AFileName;
  Cds.dwData := 1;
  Cds.cbData := Length(S);
  Cds.lpData := PChar(S);
  Result := SendMessage(AWindow, WM_COPYDATA, 0, Integer(@Cds)) = 1;
end;

var
  LConfig: TAppConfig;
  HMutex: THandle;
  HWnd: THandle;

begin
  Application.Initialize;
  // Single-instance: se ja existe outra, repassa o arquivo e encerra.
  HMutex := CreateMutex(nil, False, MUTEX_NAME);
  if (HMutex <> 0) and (GetLastError = ERROR_ALREADY_EXISTS) then
  begin
    if ParamCount > 0 then
    begin
      HWnd := FindWindow('TfrmMain', nil);
      if HWnd <> 0 then
      begin
        ShowWindow(HWnd, SW_RESTORE);
        SetForegroundWindow(HWnd);
        ForwardFileToRunning(ParamStr(1), HWnd);
      end;
    end;
    Halt(0);
  end;

  // Log e configuracao em %APPDATA%\FBRecStudio (uAppConfig).
  LConfig := TAppConfig.Create('');
  try
    if AppLogger = nil then
    begin
      AppLogger := TLogger.Create;
      AppLogger.Open(IncludeTrailingPathDelimiter(GetAppLogsDir) + 'fbrecstudio.log');
      AppLogger.Info('main', 'Iniciando aplicacao 0.2.0 (v1 funcional).');
    end;
    // Grava defaults (pasta destino, timeout, charset, tema, ...) nas
    // chaves inexistentes do config.ini - primeira execucao (uAppConfig).
    LConfig.EnsureDefaultValues;
    Application.Title := 'FBRecStudio';
    Application.CreateForm(TfrmMain, frmMain);
    frmMain.SetConfig(LConfig);
    Application.Run;
  finally
    if AppLogger <> nil then
    begin
      AppLogger.Info('main', 'Encerrando aplicacao.');
      AppLogger.Close;
      AppLogger := nil;
    end;
    LConfig.Free;
    if HMutex <> 0 then
      CloseHandle(HMutex);
  end;
end.
