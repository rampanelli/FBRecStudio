{
  uAppConfig.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  Configuracao em INI ANSI em %APPDATA%\FBRecStudio\config.ini
  (PLANO.md 6.6 / 4.5). Nenhuma credencial e gravada aqui - a politica
  de salvamento fica em [Security] e o COFRE em si fica no uCredStore
  (DPAPI). Comentarios pt-BR sem diacriticos (ASCII) - D7.

  Defaults embutidos (F0):
    [General]  DefaultOutDir    = pasta 'Documentos' do usuario
               TimeoutMs        = 0        (0 = sem timeout)
               ConsoleCodePage  = 0        (0 = GetOEMCP / automatico)
               DefaultCharset   = WIN1252
               Theme            = light
    [Security] SaveCredentials  = False    (cofre real fica no uCredStore)
    [Paths]    FbBinDir         = ''       (auto-deteccao em F1)
  O usuario Firebird padrao ('sysdba') NAO e senha sao apenas constantes
  de default da UI (DefaultFirebirdUser/DefaultFirebirdPassword); a senha
  nunca e gravada em config.ini.
  ------------------------------------------------------------------
}
unit uAppConfig;

{$H+}

interface

uses
  SysUtils, Classes, IniFiles;

const
  APP_DIR_NAME   = 'FBRecStudio';
  CONFIG_FILE    = 'config.ini';
  LOGS_DIR_NAME  = 'logs';

  // Defaults de credenciais exibidos na UI (a senha nunca e persistida
  // aqui; ver uCredStore/DPAPI e plano 4.5/9-item5).
  DEFAULT_FB_USER = 'sysdba';

// Caminho base do app: %APPDATA%\FBRecStudio (nao cria pastas).
function GetAppDataDir: string;
// Garante raiz + subpasta de logs; retorna a raiz.
function EnsureAppDataDirs: string;
// Caminho da pasta de logs (cria se preciso).
function GetAppLogsDir: string;
// Caminho completo do config.ini.
function GetConfigFilePath: string;
// Pasta 'Meus Documentos' do usuario (fallback: diretorio corrente).
function DefaultDestDir: string;
// Usuario padrao do Firebird/InterBase para os dialogs de credenciais.
function DefaultFirebirdUser: string;
// Senha padrao (vazia): sem credencial predefinida; a politica de
// salvamento fica com o usuario.
function DefaultFirebirdPassword: string;

type
  TAppConfig = class
  private
    FIni: TIniFile;
    FPath: string;
    function ReadInt(const ASection, AKey: string; ADefault: Integer): Integer;
    function ReadBool(const ASection, AKey: string; ADefault: Boolean): Boolean;
    function ReadStr(const ASection, AKey, ADefault: string): string;
    procedure WriteInt(const ASection, AKey: string; AValue: Integer);
    procedure WriteBool(const ASection, AKey: string; AValue: Boolean);
    procedure WriteStr(const ASection, AKey, AValue: string);
  public
    // AConfigFile vazio => usa GetConfigFilePath (cria a pasta antes).
    constructor Create(const AConfigFile: string);
    destructor Destroy; override;
    property Path: string read FPath;

    // Grava os defaults somente nas chaves ainda inexistentes (primeira
    // execucao); nao sobrescreve opcoes ja definidas pelo usuario.
    procedure EnsureDefaultValues;

    // --- [General] ---
    function GetTimeoutMs: Integer;        // 0 = sem timeout
    procedure SetTimeoutMs(AValue: Integer);
    function GetConsoleCodePage: Integer;  // 0 = GetOEMCP
    procedure SetConsoleCodePage(AValue: Integer);
    function GetDefaultCharset: string;    // ex.: WIN1252
    procedure SetDefaultCharset(const AValue: string);
    // Pasta destino padrao ('' => DefaultDestDir 'Documentos').
    function GetDefaultOutDir: string;
    procedure SetDefaultOutDir(const AValue: string);
    function GetTheme: string;             // 'light' | 'dark'
    procedure SetTheme(const AValue: string);

    // --- [Security] ---
    function GetSaveCredentials: Boolean;  // politica; cofre no uCredStore
    procedure SetSaveCredentials(AValue: Boolean);

    // --- [Paths] ---
    function GetFbBinDir: string;          // pasta dos utilitarios FB/IB
    procedure SetFbBinDir(const AValue: string);
  end;

implementation

uses
  Windows;   // HWND/THandle/DWORD/MAX_PATH (DefaultDestDir / SHGetFolderPathW)

const
  CSIDL_PERSONAL = $0005;   // 'Meus Documentos'
  SHGFP_TYPE_CURRENT = 0;

// SHGetFolderPathW existe no XP; D7 pode nao declarar; binding local.
function ApiSHGetFolderPathW(hwndOwner: HWND; nFolder: Integer;
  hToken: THandle; dwFlags: DWORD; pszPath: PWideChar): Longint; stdcall;
  external 'shell32.dll' name 'SHGetFolderPathW';

// ------------------------------------------------------------------
function GetAppDataDir: string;
var
  Base: string;
begin
  Base := SysUtils.GetEnvironmentVariable('APPDATA');
  if Base = '' then
    Base := SysUtils.GetEnvironmentVariable('USERPROFILE') + '\Application Data';
  if Base = '' then
    Base := GetCurrentDir;
  Result := IncludeTrailingPathDelimiter(Base) + APP_DIR_NAME;
end;

function EnsureAppDataDirs: string;
begin
  Result := GetAppDataDir;
  ForceDirectories(Result);
  ForceDirectories(IncludeTrailingPathDelimiter(Result) + LOGS_DIR_NAME);
end;

function GetAppLogsDir: string;
begin
  Result := IncludeTrailingPathDelimiter(GetAppDataDir) + LOGS_DIR_NAME;
  ForceDirectories(Result);
end;

function GetConfigFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetAppDataDir) + CONFIG_FILE;
end;

function DefaultFirebirdUser: string;
begin
  Result := DEFAULT_FB_USER;
end;

function DefaultFirebirdPassword: string;
begin
  Result := '';
end;

// ------------------------------------------------------------------
function DefaultDestDir: string;
var
  Buf: array[0..MAX_PATH] of WideChar;
  W: WideString;
begin
  Result := '';
  FillChar(Buf, SizeOf(Buf), 0);
  if ApiSHGetFolderPathW(0, CSIDL_PERSONAL, 0, SHGFP_TYPE_CURRENT,
                         @Buf[0]) = 0 then
  begin
    W := PWideChar(@Buf[0]);
    // D7 converte WideString -> string (ACP) implicitamente; o FPC emite
    // aviso (possivel perda) - o cast explicito tem o mesmo efeito (ACP).
    {$IFDEF FPC}
    Result := AnsiString(W);
    {$ELSE}
    Result := W;
    {$ENDIF}
  end;
  if Result = '' then
    Result := GetCurrentDir;
end;

// ------------------------------------------------------------------
constructor TAppConfig.Create(const AConfigFile: string);
begin
  inherited Create;
  if AConfigFile <> '' then
    FPath := AConfigFile
  else
    FPath := GetConfigFilePath;
  // Garante que a pasta exista antes de criar/ler o INI.
  ForceDirectories(ExtractFilePath(FPath));
  FIni := TIniFile.Create(FPath);
end;

destructor TAppConfig.Destroy;
begin
  FIni.Free;
  inherited Destroy;
end;

// ------------------------------------------------------------------
procedure TAppConfig.EnsureDefaultValues;
begin
  // [General]
  if not FIni.ValueExists('General', 'DefaultOutDir') then
    WriteStr('General', 'DefaultOutDir', DefaultDestDir);
  if not FIni.ValueExists('General', 'TimeoutMs') then
    WriteInt('General', 'TimeoutMs', 0);              // 0 = sem timeout
  if not FIni.ValueExists('General', 'ConsoleCodePage') then
    WriteInt('General', 'ConsoleCodePage', 0);        // 0 = GetOEMCP
  if not FIni.ValueExists('General', 'DefaultCharset') then
    WriteStr('General', 'DefaultCharset', 'WIN1252');
  if not FIni.ValueExists('General', 'Theme') then
    WriteStr('General', 'Theme', 'light');
  // [Security]
  if not FIni.ValueExists('Security', 'SaveCredentials') then
    WriteBool('Security', 'SaveCredentials', False);
  // [Paths]
  if not FIni.ValueExists('Paths', 'FbBinDir') then
    WriteStr('Paths', 'FbBinDir', '');
end;

// ------------------------------------------------------------------
function TAppConfig.ReadInt(const ASection, AKey: string;
  ADefault: Integer): Integer;
begin
  Result := FIni.ReadInteger(ASection, AKey, ADefault);
end;

function TAppConfig.ReadBool(const ASection, AKey: string;
  ADefault: Boolean): Boolean;
begin
  Result := FIni.ReadBool(ASection, AKey, ADefault);
end;

function TAppConfig.ReadStr(const ASection, AKey, ADefault: string): string;
begin
  Result := FIni.ReadString(ASection, AKey, ADefault);
end;

procedure TAppConfig.WriteInt(const ASection, AKey: string; AValue: Integer);
begin
  FIni.WriteInteger(ASection, AKey, AValue);
end;

procedure TAppConfig.WriteBool(const ASection, AKey: string; AValue: Boolean);
begin
  FIni.WriteBool(ASection, AKey, AValue);
end;

procedure TAppConfig.WriteStr(const ASection, AKey, AValue: string);
begin
  FIni.WriteString(ASection, AKey, AValue);
end;

// ------------------------------------------------------------------
function TAppConfig.GetTimeoutMs: Integer;
begin
  Result := ReadInt('General', 'TimeoutMs', 0);
end;

procedure TAppConfig.SetTimeoutMs(AValue: Integer);
begin
  if AValue < 0 then
    AValue := 0;
  WriteInt('General', 'TimeoutMs', AValue);
end;

function TAppConfig.GetConsoleCodePage: Integer;
begin
  Result := ReadInt('General', 'ConsoleCodePage', 0);
end;

procedure TAppConfig.SetConsoleCodePage(AValue: Integer);
begin
  if AValue < 0 then
    AValue := 0;
  WriteInt('General', 'ConsoleCodePage', AValue);
end;

function TAppConfig.GetDefaultCharset: string;
begin
  Result := ReadStr('General', 'DefaultCharset', 'WIN1252');
end;

procedure TAppConfig.SetDefaultCharset(const AValue: string);
begin
  WriteStr('General', 'DefaultCharset', AValue);
end;

function TAppConfig.GetDefaultOutDir: string;
begin
  Result := ReadStr('General', 'DefaultOutDir', '');
end;

procedure TAppConfig.SetDefaultOutDir(const AValue: string);
begin
  WriteStr('General', 'DefaultOutDir', AValue);
end;

function TAppConfig.GetTheme: string;
begin
  Result := ReadStr('General', 'Theme', 'light');
end;

procedure TAppConfig.SetTheme(const AValue: string);
begin
  WriteStr('General', 'Theme', AValue);
end;

function TAppConfig.GetSaveCredentials: Boolean;
begin
  Result := ReadBool('Security', 'SaveCredentials', False);
end;

procedure TAppConfig.SetSaveCredentials(AValue: Boolean);
begin
  WriteBool('Security', 'SaveCredentials', AValue);
end;

function TAppConfig.GetFbBinDir: string;
begin
  Result := ReadStr('Paths', 'FbBinDir', '');
end;

procedure TAppConfig.SetFbBinDir(const AValue: string);
begin
  WriteStr('Paths', 'FbBinDir', AValue);
end;

end.
