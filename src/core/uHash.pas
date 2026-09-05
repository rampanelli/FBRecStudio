{
  uHash.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  Hash via CryptoAPI classica (PLANO.md 6.6 / 4.6): CryptCreateHash
  com CALG_MD5 / CALG_SHA1 - disponivel no Windows XP, sem dependencia
  de terceiros. Usado pelo uHistoryStore para o campo "hash".

  Retorno: string hex minuscula ('' em falha/arquivo inexistente).

  Comentarios pt-BR sem diacriticos (ASCII) - compatibilidade D7.
  ------------------------------------------------------------------
}
unit uHash;

{$H+}

interface

uses
  SysUtils, Classes, Windows;

type
  THashAlgorithm = (haMd5, haSha1);

// Hash de um buffer em memoria.
function HashDataHex(ABuffer: Pointer; ALen: Integer; AAlg: THashAlgorithm): string;

// Hash dos bytes de uma string (texto/bytes crus).
function HashStringHex(const S: string; AAlg: THashAlgorithm): string;

// Hash de arquivo (leitura em blocos, streaming).
function HashFileHex(const AFileName: string; AAlg: THashAlgorithm): string;

implementation

const
  K_PROV_RSA_FULL        = 1;
  K_CRYPT_VERIFYCONTEXT  = $F0000000;
  K_CALG_MD5             = $00008003;
  K_CALG_SHA1            = $00008004;
  K_HP_HASHVAL           = $00000002;
  K_FILE_CHUNK           = 65536;

// Nomes de identificadores unicos para nao colidir com o Windows.pas do D7
// (advapi32 - CryptoAPI classica).
function ApiCryptAcquireContextW(var phProv: THandle; pszContainer: PWideChar;
  pszProvider: PWideChar; dwProvType: DWORD; dwFlags: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptAcquireContextW';

function ApiCryptCreateHash(hProv: THandle; AlgId: DWORD; hKey: THandle;
  dwFlags: DWORD; var phHash: THandle): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptCreateHash';

function ApiCryptHashData(hHash: THandle; pbData: PByte;
  dwDataLen: DWORD; dwFlags: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptHashData';

function ApiCryptGetHashParam(hHash: THandle; dwParam: DWORD;
  pbData: PByte; var pdwDataLen: DWORD; dwFlags: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptGetHashParam';

function ApiCryptDestroyHash(hHash: THandle): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptDestroyHash';

function ApiCryptReleaseContext(hProv: THandle; dwFlags: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'CryptReleaseContext';

// ------------------------------------------------------------------
function HashDataHex(ABuffer: Pointer; ALen: Integer; AAlg: THashAlgorithm): string;
var
  hProv, hHash: THandle;
  AlgId, DigestLen: DWORD;
  Digest: array[0..63] of Byte;
  I: Integer;
begin
  Result := '';
  hProv := 0;
  hHash := 0;
  if (ALen < 0) or ((ALen > 0) and (ABuffer = nil)) then
    Exit;
  if AAlg = haMd5 then
    AlgId := K_CALG_MD5
  else
    AlgId := K_CALG_SHA1;
  if not ApiCryptAcquireContextW(hProv, nil, nil, K_PROV_RSA_FULL,
                                 K_CRYPT_VERIFYCONTEXT) then
    Exit;
  try
    if not ApiCryptCreateHash(hProv, AlgId, 0, 0, hHash) then
      Exit;
    try
      if (ALen > 0) then
        if not ApiCryptHashData(hHash, PByte(ABuffer), DWORD(ALen), 0) then
          Exit;
      DigestLen := SizeOf(Digest);
      if not ApiCryptGetHashParam(hHash, K_HP_HASHVAL, @Digest[0],
                                  DigestLen, 0) then
        Exit;
      Result := '';
      for I := 0 to Integer(DigestLen) - 1 do
        Result := Result + IntToHex(Digest[I], 2);
      Result := LowerCase(Result);
    finally
      if hHash <> 0 then
        ApiCryptDestroyHash(hHash);
    end;
  finally
    if hProv <> 0 then
      ApiCryptReleaseContext(hProv, 0);
  end;
end;

// ------------------------------------------------------------------
function HashStringHex(const S: string; AAlg: THashAlgorithm): string;
begin
  if Length(S) = 0 then
    Result := HashDataHex(nil, 0, AAlg)
  else
    Result := HashDataHex(PChar(S), Length(S), AAlg);
end;

// ------------------------------------------------------------------
function HashFileHex(const AFileName: string; AAlg: THashAlgorithm): string;
var
  FS: TFileStream;
  Buf: array[0..K_FILE_CHUNK - 1] of Byte;
  ReadN: Integer;
  hProv, hHash: THandle;
  AlgId, DigestLen: DWORD;
  Digest: array[0..63] of Byte;
  I: Integer;
begin
  Result := '';
  if not FileExists(AFileName) then
    Exit;
  if AAlg = haMd5 then
    AlgId := K_CALG_MD5
  else
    AlgId := K_CALG_SHA1;
  if not ApiCryptAcquireContextW(hProv, nil, nil, K_PROV_RSA_FULL,
                                 K_CRYPT_VERIFYCONTEXT) then
    Exit;
  hHash := 0;
  FS := nil;
  try
    if not ApiCryptCreateHash(hProv, AlgId, 0, 0, hHash) then
      Exit;
    FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
    repeat
      ReadN := FS.Read(Buf, SizeOf(Buf));
      if ReadN <= 0 then
        Break;
      if not ApiCryptHashData(hHash, @Buf[0], DWORD(ReadN), 0) then
        Exit;
    until ReadN < SizeOf(Buf);
    DigestLen := SizeOf(Digest);
    if not ApiCryptGetHashParam(hHash, K_HP_HASHVAL, @Digest[0],
                                DigestLen, 0) then
      Exit;
    Result := '';
    for I := 0 to Integer(DigestLen) - 1 do
      Result := Result + IntToHex(Digest[I], 2);
    Result := LowerCase(Result);
  finally
    FS.Free;
    if hHash <> 0 then
      ApiCryptDestroyHash(hHash);
    ApiCryptReleaseContext(hProv, 0);
  end;
end;

end.
