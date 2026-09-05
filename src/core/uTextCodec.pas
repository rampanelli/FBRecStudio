{
  uTextCodec.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  Conversao centralizada de encoding (PLANO.md, secoes 6.5 e 5.6):

  * gbak/gfix/isql escrevem na codepage do console (OEM, ex.: cp850 no
    pt-BR) ou byte puro; nao confiar em "ja e UTF-8".
  * Esta unit concentra TODA conversao:
      - bytes OEM  -> texto de exibicao (ACP)
      - bytes UTF-8-> texto de exibicao (ACP)
      - texto ACP  -> bytes UTF-8 (para logs com BOM)
  * Heuristica: se os bytes "parecem UTF-8 valido" (e nao sao so ASCII),
    decodificar como UTF-8; caso contrario, tratar como OEM do console.

  Regras do repositorio:
    - Delphi 7 puro (sem generics/anonymous), compilavel em D7.
    - Comentarios em portugues-BR sem diacriticos (ASCII puro) para o
      Delphi 7 ler o fonte ANSI/UTF-8 sem corromper.
    - Identificadores em ingles.
  ------------------------------------------------------------------
}
unit uTextCodec;

{$H+}   // long strings (AnsiString) - padrao do Delphi 7

interface

uses
  Windows, SysUtils;

// Codepage efetiva do console: usa o override quando > 0; senao GetOEMCP.
function GuessConsoleCp(AOverride: Integer): Integer;

// ==================================================================
// Conversoes byte-orientadas (S carrega bytes crus, nao "texto")
// ==================================================================

// Converte bytes em 'S' (codificados em ACodePage) para bytes UTF-8.
function ConvertToUtf8(const S: AnsiString; ACodePage: UINT): AnsiString;

// Converte texto ACP (codepage do sistema) para bytes UTF-8.
function AnsiToUtf8(const S: AnsiString): AnsiString;

// Converte bytes OEM (codepage do console, override 0 = automatico) p/ UTF-8.
function OemToUtf8(const S: AnsiString; AOverrideCp: Integer): AnsiString;

// Converte bytes UTF-8 para texto ACP (exibicao na UI).
function Utf8ToAnsi(const S: AnsiString): AnsiString;

// Converte bytes OEM (codepage ACodePage) para texto ACP (exibicao).
function OemToAnsi(const S: AnsiString; ACodePage: Integer): AnsiString;

// ==================================================================
// Deteccao / heuristica
// ==================================================================

// True se todos os bytes < $80 (ASCII puro; idem em qualquer codepage).
function IsAsciiOnly(const S: AnsiString): Boolean;

// Heuristica: True quando os bytes formam UTF-8 estruturalmente valido
// (rejeita overlong, surrogates e sequencias truncadas).
function LooksLikeUtf8(const S: AnsiString): Boolean;

// Decodifica bytes crus do console para texto ACP:
//   * se parecem UTF-8 (e nao so ASCII) -> UTF-8 -> ACP
//   * senao -> OEM (override > 0 usa AOverrideCp; 0 usa GetOEMCP) -> ACP
function DecodeConsoleBytes(const Raw: AnsiString; AOverrideCp: Integer): AnsiString;

// ==================================================================
// Auxiliares
// ==================================================================

// Copia ALen bytes de ABuf para uma AnsiString (bytes crus).
function BytesToAnsi(const ABuf: Pointer; ALen: Integer): AnsiString;

implementation

const
  // CP_UTF8 pode nao existir no Windows.pas do Delphi 7; usar constante local.
  CP_UTF8_LOCAL = 65001;
  // Flag usada na conversao para o ACP de exibicao
  WC_DEFAULT = 0;

// ------------------------------------------------------------------
function GuessConsoleCp(AOverride: Integer): Integer;
begin
  if AOverride > 0 then
    Result := AOverride
  else
    Result := Integer(GetOEMCP);
  if Result <= 0 then
    Result := 437; // ultimo recurso: cp437 (americano)
end;

// ------------------------------------------------------------------
function BytesToAnsi(const ABuf: Pointer; ALen: Integer): AnsiString;
begin
  SetLength(Result, ALen);
  if ALen > 0 then
    Move(ABuf^, Result[1], ALen);
end;

// ------------------------------------------------------------------
function ConvertToUtf8(const S: AnsiString; ACodePage: UINT): AnsiString;
var
  W: WideString;
  Needed, OutLen: Integer;
begin
  Result := '';
  if Length(S) = 0 then
    Exit;
  // ACP/OEM -> WideString (buffer intermediario)
  Needed := MultiByteToWideChar(ACodePage, 0, PChar(S), Length(S), nil, 0);
  if Needed <= 0 then
    Exit;
  SetLength(W, Needed);
  MultiByteToWideChar(ACodePage, 0, PChar(S), Length(S), PWideChar(W), Needed);
  // WideString -> UTF-8 (bytes)
  OutLen := WideCharToMultiByte(CP_UTF8_LOCAL, 0, PWideChar(W), Needed, nil, 0, nil, nil);
  if OutLen <= 0 then
    Exit;
  SetLength(Result, OutLen);
  WideCharToMultiByte(CP_UTF8_LOCAL, 0, PWideChar(W), Needed, PChar(Result), OutLen, nil, nil);
end;

// ------------------------------------------------------------------
function AnsiToUtf8(const S: AnsiString): AnsiString;
begin
  Result := ConvertToUtf8(S, CP_ACP);
end;

// ------------------------------------------------------------------
function OemToUtf8(const S: AnsiString; AOverrideCp: Integer): AnsiString;
var
  Cp: UINT;
begin
  Cp := UINT(GuessConsoleCp(AOverrideCp));
  Result := ConvertToUtf8(S, Cp);
end;

// ------------------------------------------------------------------
// Converte WideString (W, com Len WideChars) para texto ACP.
function WideToAnsiCp(const W: WideString; Len: Integer): AnsiString;
var
  OutLen: Integer;
begin
  Result := '';
  if Len <= 0 then
    Exit;
  OutLen := WideCharToMultiByte(CP_ACP, WC_DEFAULT, PWideChar(W), Len, nil, 0, nil, nil);
  if OutLen <= 0 then
    Exit;
  SetLength(Result, OutLen);
  WideCharToMultiByte(CP_ACP, WC_DEFAULT, PWideChar(W), Len, PChar(Result), OutLen, nil, nil);
end;

// ------------------------------------------------------------------
function Utf8ToAnsi(const S: AnsiString): AnsiString;
var
  W: WideString;
  Needed: Integer;
begin
  Result := '';
  if Length(S) = 0 then
    Exit;
  Needed := MultiByteToWideChar(CP_UTF8_LOCAL, 0, PChar(S), Length(S), nil, 0);
  if Needed <= 0 then
    Exit;
  SetLength(W, Needed);
  MultiByteToWideChar(CP_UTF8_LOCAL, 0, PChar(S), Length(S), PWideChar(W), Needed);
  Result := WideToAnsiCp(W, Needed);
end;

// ------------------------------------------------------------------
function OemToAnsi(const S: AnsiString; ACodePage: Integer): AnsiString;
var
  W: WideString;
  Needed: Integer;
  Cp: UINT;
begin
  Result := '';
  if Length(S) = 0 then
    Exit;
  Cp := UINT(GuessConsoleCp(ACodePage));
  Needed := MultiByteToWideChar(Cp, 0, PChar(S), Length(S), nil, 0);
  if Needed <= 0 then
    Exit;
  SetLength(W, Needed);
  MultiByteToWideChar(Cp, 0, PChar(S), Length(S), PWideChar(W), Needed);
  Result := WideToAnsiCp(W, Needed);
end;

// ------------------------------------------------------------------
function IsAsciiOnly(const S: AnsiString): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 1 to Length(S) do
    if Byte(S[I]) >= $80 then
    begin
      Result := False;
      Exit;
    end;
end;

// ------------------------------------------------------------------
function LooksLikeUtf8(const S: AnsiString): Boolean;
var
  I, L, Extra, J: Integer;
  B: Byte;
begin
  Result := False;
  L := Length(S);
  I := 1;
  while I <= L do
  begin
    B := Byte(S[I]);
    if B < $80 then
    begin
      Inc(I);
      Continue;
    end;
    // Bytes de continuacao avulsos ou leads invalidos -> nao e UTF-8
    if (B >= $C2) and (B <= $DF) then
      Extra := 1
    else if (B >= $E0) and (B <= $EF) then
      Extra := 2
    else if (B >= $F0) and (B <= $F4) then
      Extra := 3
    else
      Exit; // $80..$C1, $F5..$FF -> invalido
    if (I + Extra) > L then
      Exit; // sequencia truncada no fim
    // Verificacoes de overlong / surrogates / faixa maxima
    if Extra = 2 then
    begin
      if (B = $E0) and (Byte(S[I + 1]) < $A0) then Exit;
      if (B = $ED) and (Byte(S[I + 1]) > $9F) then Exit; // surrogates
    end
    else if Extra = 3 then
    begin
      if (B = $F0) and (Byte(S[I + 1]) < $90) then Exit;
      if (B = $F4) and (Byte(S[I + 1]) > $8F) then Exit;
    end;
    for J := 1 to Extra do
      if (Byte(S[I + J]) and $C0) <> $80 then
        Exit; // faltou byte de continuacao
    Inc(I, Extra + 1);
  end;
  Result := True;
end;

// ------------------------------------------------------------------
function DecodeConsoleBytes(const Raw: AnsiString; AOverrideCp: Integer): AnsiString;
begin
  if Length(Raw) = 0 then
  begin
    Result := '';
    Exit;
  end;
  if LooksLikeUtf8(Raw) and (not IsAsciiOnly(Raw)) then
    Result := Utf8ToAnsi(Raw)
  else
    Result := OemToAnsi(Raw, AOverrideCp);
end;

end.
