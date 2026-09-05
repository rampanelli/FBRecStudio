{
  uFBVersionInfo.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F1-T1 (PLANO.md 6.2/4.1): representa a versao de um binario/servidor
  Firebird/InterBase.

    * TVersion: Familia (fb/ib), Maior/Menor/Revisao/Build e o intervalo
      de ODS (on-disk structure) suportado pelo servidor/binario.
    * ParseVersaoTexto: le strings conhecidas de saida de '-z'/'-?' dos
      utilitarios, ex.:
        'gbak version LI-V2.5.9.27110 Firebird 2.5'
        'LI-V3.0.7.33355 Firebird 3.0'
        'InterBase 6.0' / 'LI-V6.0.1.6 InterBase'
      (estrutura pronta para receber o help real em runtime; ver
      docs/CATALOGO-SWITCHES.md - 'a validar com bins reais' na F7).
    * VersaoDoArquivo: GetFileVersionInfoW/VerQueryValueW no recurso
      VS_VERSION_INFO de um .exe (gbak/isql/gfix reais tem esse recurso).
    * PreencherIntervaloOds: tabela "versao de servidor -> intervalo de
      ODS" (base: PLANO.md 4.1.2 e ods.h do Firebird; heuristica
      documentada, validacao com bins/corpus reais na F7).

  Regras do repositorio: Delphi 7 puro (sem generics/anonymous/for..in),
  comentarios pt-BR ASCII, identificadores em ingles salvo quando o
  contrato da fase nomeia o campo em portugues (Maior/Menor/Familia).
  ------------------------------------------------------------------
}
unit uFBVersionInfo;

{$H+}

interface

uses
  SysUtils, Windows;

type
  // Familia do produto. bfDesconhecida quando o texto/arquivo nao
  // permite decidir (numero de versao existe, mas sem palavra-chave).
  TBFamilia = (bfDesconhecida, bfFirebird, bfInterBase);

  // Versao de um binario/servidor FB/IB (contrato F1-T1).
  // Campos Maior/Menor/Revisao/Build = 0 quando o componente nao foi
  // informado pela fonte. Valida=False quando nada foi reconhecido.
  TVersion = record
    Familia: TBFamilia;
    Maior: Integer;
    Menor: Integer;
    Revisao: Integer;
    Build: Integer;
    // Intervalo de ODS que o servidor/binario le (10.0 = IB6/FB1.0...).
    TemOds: Boolean;
    OdsMinMaior: Word;
    OdsMinMenor: Word;
    OdsMaxMaior: Word;
    OdsMaxMenor: Word;
    Valida: Boolean;       // true apos parse/leitura com sucesso
    FonteTexto: string;    // texto bruto reconhecido ('' = via recurso)
  end;

// Nome curto da familia ('Firebird' / 'InterBase' / 'Desconhecida').
function FamiliaParaTexto(AFamilia: TBFamilia): string;

// Zera o registro (estado inicial seguro).
procedure ZerarVersion(var V: TVersion);

// Interpreta uma linha de saida de '-z'/'-?' (ou texto avulso com o
// numero). Reconhece 'LI-V2.5.9.27110', 'Firebird 2.5', 'InterBase 6.0',
// 'V3.0.7.33355' etc. Retorna False se nenhum numero surgir.
function ParseVersaoTexto(const ATexto: string; var V: TVersion): Boolean;

// Le o recurso VS_VERSION_INFO do executavel (GetFileVersionInfoW).
// Familia resolvida pelas strings ProductName/CompanyName do recurso
// quando presentes (fallback: bfDesconhecida).
function VersaoDoArquivo(const ACaminhoExe: string; var V: TVersion): Boolean;

// Heuristica de familia a partir do nome do caminho/pasta:
// 'Firebird' -> fb; 'InterBase'/'Borland'/'Embarcadero' -> ib.
function FamiliaPorNome(const ACaminho: string): TBFamilia;

// Preenche OdsMin/OdsMax a partir de Familia/Maior/Menor (tabela 4.1.2).
// Retorna False quando a familia/versao nao esta na tabela.
function PreencherIntervaloOds(var V: TVersion): Boolean;

// 'Firebird 2.5.9 (build 27110)' / 'InterBase 6.0' / 'versao desconhecida'.
function VersaoParaTexto(const V: TVersion): string;

implementation

const
  K_FB_MARCA  = 'firebird';
  K_IB_MARCA1 = 'interbase';
  K_IB_MARCA2 = 'borland';
  K_IB_MARCA3 = 'embarcadero';

// ------------------------------------------------------------------
// ZerarVersion / FamiliaParaTexto
// ------------------------------------------------------------------
procedure ZerarVersion(var V: TVersion);
begin
  V.Familia := bfDesconhecida;
  V.Maior := 0;
  V.Menor := 0;
  V.Revisao := 0;
  V.Build := 0;
  V.TemOds := False;
  V.OdsMinMaior := 0;
  V.OdsMinMenor := 0;
  V.OdsMaxMaior := 0;
  V.OdsMaxMenor := 0;
  V.Valida := False;
  V.FonteTexto := '';
end;

function FamiliaParaTexto(AFamilia: TBFamilia): string;
begin
  case AFamilia of
    bfFirebird:  Result := 'Firebird';
    bfInterBase: Result := 'InterBase';
  else
    Result := 'Desconhecida';
  end;
end;

// ------------------------------------------------------------------
// FamiliaPorNome (heuristica de caminho/pasta)
// ------------------------------------------------------------------
function FamiliaPorNome(const ACaminho: string): TBFamilia;
var
  S: string;
begin
  Result := bfDesconhecida;
  S := LowerCase(ACaminho);
  if S = '' then
    Exit;
  if (Pos(K_IB_MARCA1, S) > 0) or (Pos(K_IB_MARCA2, S) > 0) or
     (Pos(K_IB_MARCA3, S) > 0) then
  begin
    // 'InterBase' nunca ocorre dentro de 'Firebird'; ordem segura.
    Result := bfInterBase;
    Exit;
  end;
  if Pos(K_FB_MARCA, S) > 0 then
    Result := bfFirebird;
end;

// ------------------------------------------------------------------
// ParseVersaoTexto
// ------------------------------------------------------------------
// Estrategia: (1) familia por palavra-chave; (2) varre o texto atras de
// grupos numericos 'A.B[.C[.D]]' separados por ponto; escolhe o grupo
// com mais componentes (4 > 3 > 2); usa o primeiro em caso de empate.
// Assim 'LI-V2.5.9.27110 Firebird 2.5' -> 2.5.9.27110 (nao 2.5).
function ParseVersaoTexto(const ATexto: string; var V: TVersion): Boolean;
var
  S: string;
  I, N, Dig: Integer;
  MaxPartes: Integer;
  Partes: Integer;
  Num: array[0..3] of Integer;
  Melhor: array[0..3] of Integer;
begin
  Result := False;
  ZerarVersion(V);
  V.FonteTexto := ATexto;
  S := Trim(ATexto);
  if S = '' then
    Exit;

  V.Familia := FamiliaPorNome(S);

  MaxPartes := 0;
  I := 1;
  N := Length(S);
  while I <= N do
  begin
    if (S[I] >= '0') and (S[I] <= '9') then
    begin
      Dig := 0;
      while (I <= N) and (S[I] >= '0') and (S[I] <= '9') do
      begin
        Dig := Dig * 10 + (Ord(S[I]) - Ord('0'));
        if Dig > 99999999 then
          Dig := 99999999;
        Inc(I);
      end;
      Partes := 1;
      Num[0] := Dig;
      while (Partes < 4) and (I <= N) and (S[I] = '.') do
      begin
        Inc(I);
        if (I <= N) and (S[I] >= '0') and (S[I] <= '9') then
        begin
          Dig := 0;
          while (I <= N) and (S[I] >= '0') and (S[I] <= '9') do
          begin
            Dig := Dig * 10 + (Ord(S[I]) - Ord('0'));
            if Dig > 99999999 then
              Dig := 99999999;
            Inc(I);
          end;
          Num[Partes] := Dig;
          Inc(Partes);
        end
        else
          Break;
      end;
      if Partes > MaxPartes then
      begin
        MaxPartes := Partes;
        for Dig := 0 to Partes - 1 do
          Melhor[Dig] := Num[Dig];
      end;
      while (I <= N) and not ((S[I] >= '0') and (S[I] <= '9')) do
        Inc(I);
    end
    else
      Inc(I);
  end;

  if MaxPartes < 2 then
    Exit;

  V.Maior := Melhor[0];
  V.Menor := Melhor[1];
  if MaxPartes >= 3 then
    V.Revisao := Melhor[2];
  if MaxPartes >= 4 then
    V.Build := Melhor[3];
  V.Valida := True;

  PreencherIntervaloOds(V);
  Result := True;
end;

// ------------------------------------------------------------------
// Bindings de version.dll (nao declarados no Windows.pas D7/FPC).
// ------------------------------------------------------------------
function ApiGetFileVersionInfoSizeW(lptstrFilename: PWideChar;
  var dwHandle: DWORD): DWORD; stdcall;
  external 'version.dll' name 'GetFileVersionInfoSizeW';

function ApiGetFileVersionInfoW(lptstrFilename: PWideChar;
  dwHandle, dwLen: DWORD; lpData: Pointer): BOOL; stdcall;
  external 'version.dll' name 'GetFileVersionInfoW';

function ApiVerQueryValueW(pBlock: Pointer; lpSubBlock: PWideChar;
  var lplpBuffer: Pointer; var puLen: DWORD): BOOL; stdcall;
  external 'version.dll' name 'VerQueryValueW';

// Le strings do recurso e procura a marca de familia.
function FamiliaDoRecurso(AInfo: Pointer): TBFamilia;
const
  K_FB_MARCA  = 'Firebird';
  K_IB_MARCA1 = 'InterBase';
  K_IB_MARCA2 = 'Borland';
  K_IB_MARCA3 = 'Embarcadero';
var
  Buf: Pointer;
  Len: DWORD;
  S: WideString;
begin
  Result := bfDesconhecida;
  if ApiVerQueryValueW(AInfo,
                       PWideChar(WideString('\StringFileInfo\040904B0\ProductName')),
                       Buf, Len) then
  begin
    S := WideString(PWideChar(Buf));
    if Pos(K_IB_MARCA1, S) > 0 then
      Result := bfInterBase
    else if Pos(K_FB_MARCA, S) > 0 then
      Result := bfFirebird;
  end;
  if Result <> bfDesconhecida then
    Exit;
  if ApiVerQueryValueW(AInfo,
                       PWideChar(WideString('\StringFileInfo\040904B0\CompanyName')),
                       Buf, Len) then
  begin
    S := WideString(PWideChar(Buf));
    if (Pos(K_IB_MARCA2, S) > 0) or (Pos(K_IB_MARCA1, S) > 0) or
       (Pos(K_IB_MARCA3, S) > 0) then
      Result := bfInterBase
    else if Pos(K_FB_MARCA, S) > 0 then
      Result := bfFirebird;
  end;
end;

function VersaoDoArquivo(const ACaminhoExe: string; var V: TVersion): Boolean;
var
  W: WideString;
  Handle, Tam: DWORD;
  Info: Pointer;
  Buf: Pointer;
  Len: DWORD;
  Ffi: PVSFixedFileInfo;
begin
  Result := False;
  ZerarVersion(V);
  if not FileExists(ACaminhoExe) then
    Exit;
  W := WideString(ACaminhoExe);
  Tam := ApiGetFileVersionInfoSizeW(PWideChar(W), Handle);
  if Tam = 0 then
    Exit;
  GetMem(Info, Tam);
  try
    if not ApiGetFileVersionInfoW(PWideChar(W), Handle, Tam, Info) then
      Exit;
    if not ApiVerQueryValueW(Info, PWideChar(WideString('\')), Buf, Len) then
      Exit;
    if Len < SizeOf(TVSFixedFileInfo) then
      Exit;
    Ffi := PVSFixedFileInfo(Buf);
    V.Valida := True;
    V.Maior := HiWord(Ffi.dwFileVersionMS);
    V.Menor := LoWord(Ffi.dwFileVersionMS);
    V.Revisao := HiWord(Ffi.dwFileVersionLS);
    V.Build := LoWord(Ffi.dwFileVersionLS);
    V.Familia := FamiliaDoRecurso(Info);
    V.FonteTexto := '';
    PreencherIntervaloOds(V);
    Result := True;
  finally
    FreeMem(Info);
  end;
end;

// ------------------------------------------------------------------
// Tabela versao de servidor/binario -> intervalo de ODS lido.
// Base: PLANO.md 4.1.2 (referencia inicial) + ods.h do Firebird 2.5
// (ODS 8=IB4, 9=IB5, 10.0=IB6/FB1.0, 10.1=FB1.5, 11.0=FB2, 11.1=FB2.1,
// 11.2=FB2.5) e heuristica para FB3/4/5 (12/13). Intervalo 'minimo que
// o servidor abre' ate 'ODS nativa' - heuristica, validar na F7.
// ------------------------------------------------------------------
function PreencherIntervaloOds(var V: TVersion): Boolean;
begin
  Result := False;
  V.TemOds := False;
  V.OdsMinMaior := 0;
  V.OdsMinMenor := 0;
  V.OdsMaxMaior := 0;
  V.OdsMaxMenor := 0;
  if not V.Valida then
    Exit;
  case V.Familia of
    bfFirebird:
      case V.Maior of
        1: begin
             if V.Menor <= 0 then
             begin
               V.OdsMinMaior := 10; V.OdsMinMenor := 0;
               V.OdsMaxMaior := 10; V.OdsMaxMenor := 0;
             end
             else
             begin
               V.OdsMinMaior := 10; V.OdsMinMenor := 0;
               V.OdsMaxMaior := 10; V.OdsMaxMenor := 1;
             end;
             Result := True;
           end;
        2: begin
             // FB 2.0=11.0, 2.1=11.1, 2.5=11.2 (menor da versao !=
             // menor do ODS; a tabela so conhece 0/1/5 na pratica)
             V.OdsMinMaior := 10; V.OdsMinMenor := 0;
             V.OdsMaxMaior := 11;
             if V.Menor <= 0 then
               V.OdsMaxMenor := 0
             else if V.Menor = 1 then
               V.OdsMaxMenor := 1
             else
               V.OdsMaxMenor := 2;
             Result := True;
           end;
        3: begin
             V.OdsMinMaior := 11; V.OdsMinMenor := 0;
             V.OdsMaxMaior := 12; V.OdsMaxMenor := 0;
             Result := True;
           end;
        4, 5: begin
             V.OdsMinMaior := 11; V.OdsMinMenor := 2;
             V.OdsMaxMaior := 13; V.OdsMaxMenor := 0;
             Result := True;
           end;
      end;
    bfInterBase:
      case V.Maior of
        4: begin
             V.OdsMinMaior := 8; V.OdsMinMenor := 0;
             V.OdsMaxMaior := 8; V.OdsMaxMenor := 0;
             Result := True;
           end;
        5: begin
             V.OdsMinMaior := 9; V.OdsMinMenor := 0;
             V.OdsMaxMaior := 9; V.OdsMaxMenor := 0;
             Result := True;
           end;
        6: begin
             V.OdsMinMaior := 10; V.OdsMinMenor := 0;
             V.OdsMaxMaior := 10; V.OdsMaxMenor := 0;
             Result := True;
           end;
      end;
  end;
  if Result then
    V.TemOds := True;
end;

// ------------------------------------------------------------------
// VersaoParaTexto
// ------------------------------------------------------------------
function VersaoParaTexto(const V: TVersion): string;
var
  S: string;
begin
  if not V.Valida then
  begin
    Result := 'versao desconhecida';
    Exit;
  end;
  S := FamiliaParaTexto(V.Familia);
  if (V.Maior > 0) then
  begin
    S := S + ' ' + IntToStr(V.Maior) + '.' + IntToStr(V.Menor);
    if V.Revisao > 0 then
      S := S + '.' + IntToStr(V.Revisao);
    if V.Build > 0 then
      S := S + ' (build ' + IntToStr(V.Build) + ')';
  end;
  if V.TemOds then
    S := S + ' [ODS ' + IntToStr(V.OdsMinMaior) + '.' +
         IntToStr(V.OdsMinMenor) + '-' + IntToStr(V.OdsMaxMaior) + '.' +
         IntToStr(V.OdsMaxMenor) + ']';
  Result := S;
end;

end.