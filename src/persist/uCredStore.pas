{
  uCredStore.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  Cofre de credenciais com DPAPI (PLANO.md 6.6 / 4.5). Credenciais
  nunca em texto claro (sem o risco de registro em claro):

    * CryptProtectData / CryptUnprotectData (crypt32.dll, presente no
      Windows XP SP3) - protecao por usuario + maquina.
    * O blob criptografado e persistido em %APPDATA%\FBRecStudio\
      credentials.bin como BASE64 (CryptBinaryToStringW).
    * NUNCA grava texto claro. Se o DPAPI nao estiver disponivel/falhar,
      Save retorna False e NADA e gravado (fallback: manter so em
      memoria durante a sessao).
    * Formato interno do blob: [lenUser:WORD][bytes user][lenPass:WORD]
      [bytes pass] - sem separadores ambiguos.

  Comentarios pt-BR sem diacriticos (ASCII) - compatibilidade D7.
  ------------------------------------------------------------------
}
unit uCredStore;

{$H+}

interface

uses
  SysUtils, Classes;

const
  CRED_FILE_NAME = 'credentials.bin';

type
  TCredStore = class
  private
    FFileName: string;
  public
    // AFileName vazio => %APPDATA%\FBRecStudio\credentials.bin.
    constructor Create(const AFileName: string);

    // Criptografa e grava. Retorna False (e NAO grava nada) em falha.
    function Save(const AUser, APassword: string): Boolean;

    // Carrega e descriptografa. Retorna False se ausente/invalido.
    function Load(var AUser, APassword: string): Boolean;

    // Apaga o arquivo do cofre.
    procedure Erase;

    property FileName: string read FFileName;
  end;

implementation

uses
  Windows, uAppConfig;

const
  KC_CRYPT_STRING_BASE64 = $00000001;
  KC_CRYPT_STRING_NOCRLF = $40000000;
  KC_CRYPTPROTECT_UI_FORBIDDEN = $00000001;

type
  // DATA_BLOB do CryptProtectData (32-bit). O ponteiro e declarado ANTES
  // do record (referencia a tipo declarado adiante no mesmo bloco) para o
  // Delphi 7 compilar as assinaturas das funcoes externas abaixo.
  PKcDataBlob = ^KcDataBlob;

  KcDataBlob = packed record
    cbData: DWORD;
    pbData: PByte;
  end;

// Bindings com nome unico (crypt32 / kernel32).
function KcCryptProtectData(pDataIn: PKcDataBlob; szDataDescr: PWideChar;
  pOptionalEntropy: PKcDataBlob; pvReserved: Pointer; pPromptStruct: Pointer;
  dwFlags: DWORD; pDataOut: PKcDataBlob): BOOL; stdcall;
  external 'crypt32.dll' name 'CryptProtectData';

function KcCryptUnprotectData(pDataIn: PKcDataBlob; ppszDataDescr: PWideChar;
  pOptionalEntropy: PKcDataBlob; pvReserved: Pointer; pPromptStruct: Pointer;
  dwFlags: DWORD; pDataOut: PKcDataBlob): BOOL; stdcall;
  external 'crypt32.dll' name 'CryptUnprotectData';

function KcCryptBinaryToStringW(pbBinary: PByte; cbBinary: DWORD;
  dwFlags: DWORD; pszString: PWideChar; var pcchString: DWORD): BOOL; stdcall;
  external 'crypt32.dll' name 'CryptBinaryToStringW';

function KcCryptStringToBinaryW(pszString: PWideChar; cchString: DWORD;
  dwFlags: DWORD; pbBinary: PByte; var pcbBinary: DWORD;
  pdwSkip: PDWORD; pdwFlags: PDWORD): BOOL; stdcall;
  external 'crypt32.dll' name 'CryptStringToBinaryW';

function KcLocalFree(hMem: THandle): THandle; stdcall;
  external 'kernel32.dll' name 'LocalFree';

// ------------------------------------------------------------------
// Formato interno do blob: [lenU:WORD][user][lenP:WORD][pass]
// ------------------------------------------------------------------
function ComposeCredentials(const AUser, APassword: string): string;
var
  L, P: Integer;
begin
  L := 2 + Length(AUser) + 2 + Length(APassword);
  SetLength(Result, L);
  P := 1;
  Result[P] := Char(Length(AUser) and $FF);
  Result[P + 1] := Char((Length(AUser) shr 8) and $FF);
  Inc(P, 2);
  if Length(AUser) > 0 then
    Move(AUser[1], Result[P], Length(AUser));
  Inc(P, Length(AUser));
  Result[P] := Char(Length(APassword) and $FF);
  Result[P + 1] := Char((Length(APassword) shr 8) and $FF);
  Inc(P, 2);
  if Length(APassword) > 0 then
    Move(APassword[1], Result[P], Length(APassword));
end;

function SplitCredentials(const ARaw: string;
  var AUser, APassword: string): Boolean;
var
  LenU, LenP, P, Total: Integer;
begin
  Result := False;
  AUser := '';
  APassword := '';
  if Length(ARaw) < 4 then
    Exit;
  LenU := Ord(ARaw[1]) or (Ord(ARaw[2]) shl 8);
  LenP := 0;
  Total := 2 + LenU;
  if Total + 2 > Length(ARaw) then
    Exit;
  LenP := Ord(ARaw[Total + 1]) or (Ord(ARaw[Total + 2]) shl 8);
  if Total + 2 + LenP <> Length(ARaw) then
    Exit;
  P := 3;
  if LenU > 0 then
  begin
    SetLength(AUser, LenU);
    Move(ARaw[P], AUser[1], LenU);
    Inc(P, LenU);
  end;
  Inc(P, 2); // pula o comprimento da senha
  if LenP > 0 then
  begin
    SetLength(APassword, LenP);
    Move(ARaw[P], APassword[1], LenP);
  end;
  Result := True;
end;

// ------------------------------------------------------------------
function BlobToBase64(ABytes: PByte; ALen: DWORD): string;
var
  OutLen: DWORD;
  W: WideString;
  I: Integer;
begin
  Result := '';
  OutLen := 0;
  if ABytes = nil then
    Exit;
  if not KcCryptBinaryToStringW(ABytes, ALen,
       KC_CRYPT_STRING_BASE64 or KC_CRYPT_STRING_NOCRLF, nil, OutLen) then
    Exit;
  if OutLen = 0 then
    Exit;
  SetLength(W, OutLen); // OutLen inclui o terminador nulo
  if not KcCryptBinaryToStringW(ABytes, ALen,
       KC_CRYPT_STRING_BASE64 or KC_CRYPT_STRING_NOCRLF,
       PWideChar(W), OutLen) then
    Exit;
  // Converte Wide (so ASCII no base64) para AnsiString, cortando no nulo.
  Result := '';
  for I := 1 to Length(W) do
  begin
    if W[I] = #0 then
      Break;
    Result := Result + AnsiChar(W[I]);
  end;
end;

function Base64ToBytes(const AB64: string;
  var ABytes: array of Byte; var ACount: Integer): Boolean;
var
  W: WideString;
  OutLen, Len: DWORD;
begin
  Result := False;
  ACount := 0;
  if AB64 = '' then
    Exit;
  W := WideString(AB64);
  Len := DWORD(Length(W));
  OutLen := Len + 8; // base64 >= tamanho original; folga segura
  if Length(ABytes) < Integer(OutLen) then
    Exit;
  if not KcCryptStringToBinaryW(PWideChar(W), Len,
       KC_CRYPT_STRING_BASE64, @ABytes[0], OutLen, nil, nil) then
    Exit;
  ACount := Integer(OutLen);
  Result := True;
end;

// ------------------------------------------------------------------
function DefaultCredFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetAppDataDir) + CRED_FILE_NAME;
end;

constructor TCredStore.Create(const AFileName: string);
begin
  inherited Create;
  if AFileName <> '' then
    FFileName := AFileName
  else
    FFileName := DefaultCredFilePath;
end;

// ------------------------------------------------------------------
function TCredStore.Save(const AUser, APassword: string): Boolean;
var
  Raw: string;
  BI, BO: KcDataBlob;
  B64: string;
  FS: TFileStream;
begin
  Result := False;
  if AUser = '' then
    Exit;
  // Garante a pasta do cofre antes de tentar gravar (1a execucao).
  if not DirectoryExists(ExtractFilePath(FFileName)) then
    if not ForceDirectories(ExtractFilePath(FFileName)) then
      Exit;
  Raw := ComposeCredentials(AUser, APassword);
  FillChar(BI, SizeOf(BI), 0);
  BI.cbData := DWORD(Length(Raw));
  BI.pbData := PByte(PChar(Raw));
  FillChar(BO, SizeOf(BO), 0);
  // Protege com a identidade do usuario atual (sem prompt de UI).
  if not KcCryptProtectData(@BI, nil, nil, nil, nil,
                            KC_CRYPTPROTECT_UI_FORBIDDEN, @BO) then
    Exit;
  try
    B64 := BlobToBase64(BO.pbData, BO.cbData);
    if B64 = '' then
      Exit;
    // Sobrescreve o arquivo por completo (fmCreate trunca); em caso de
    // falha o cofre antigo permanece intacto porque nada foi gravado.
    try
      FS := TFileStream.Create(FFileName, fmCreate);
      try
        FS.WriteBuffer(B64[1], Length(B64));
        FS.WriteBuffer(#13#10, 2);
      finally
        FS.Free;
      end;
    except
      Exit;
    end;
    Result := True;
  finally
    if BO.pbData <> nil then
      KcLocalFree(THandle(BO.pbData));
  end;
end;

// ------------------------------------------------------------------
function TCredStore.Load(var AUser, APassword: string): Boolean;
var
  B64: string;
  Buf: array of Byte;
  BufLen: Integer;
  BI, BO: KcDataBlob;
  Raw: string;
  FS: TFileStream;
begin
  Result := False;
  AUser := '';
  APassword := '';
  if not FileExists(FFileName) then
    Exit;
  FS := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(B64, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(B64[1], FS.Size);
  finally
    FS.Free;
  end;
  B64 := Trim(B64);
  if B64 = '' then
    Exit;
  // 1) Base64 -> blob criptografado (bytes)
  SetLength(Buf, Length(B64) + 16);
  if not Base64ToBytes(B64, Buf, BufLen) then
    Exit;
  // 2) DPAPI: blob criptografado -> blob claro (somente em memoria)
  FillChar(BI, SizeOf(BI), 0);
  BI.cbData := DWORD(BufLen);
  BI.pbData := @Buf[0];
  FillChar(BO, SizeOf(BO), 0);
  if not KcCryptUnprotectData(@BI, nil, nil, nil, nil,
                              KC_CRYPTPROTECT_UI_FORBIDDEN, @BO) then
    Exit;
  try
    if (BO.pbData = nil) or (BO.cbData = 0) then
      Exit;
    SetLength(Raw, BO.cbData);
    Move(BO.pbData^, Raw[1], BO.cbData);
    // 3) Separa usuario/senha pelo layout binario interno
    Result := SplitCredentials(Raw, AUser, APassword);
  finally
    if BO.pbData <> nil then
      KcLocalFree(THandle(BO.pbData));
  end;
end;

// ------------------------------------------------------------------
procedure TCredStore.Erase;
begin
  if FileExists(FFileName) then
    SysUtils.DeleteFile(FFileName);
end;

end.
