{
  uDiagParser.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F1-T5 (PLANO.md 6.2): utilitarios de leitura de bytes para o
  diagnostico de arquivos Firebird/InterBase (cabecalho de pagina 0,
  stream de backup). Somente leituras SEGURAS: toda funcao confere os
  limites do buffer e retorna False (sem levantar excecao) quando o
  offset/tamanho excede o buffer ou o arquivo e curto demais.

  Convencao de offsets: 0-based. Endianess dos arquivos Firebird
  (x86/Windows): little-endian; funcoes BE existem para o formato de
  backup (XDR) e uso futuro.

  Delphi 7 puro (array of Byte como parametro aberto).
  ------------------------------------------------------------------
}
unit uDiagParser;

{$H+}

interface

// Le um byte em AOff (0-based). False se fora dos limites.
function LerU8(const ABuf: array of Byte; AOff: Integer; var V: Byte): Boolean;

// Le u16/u32 em little-endian / big-endian. False fora dos limites.
// Em falha os parametros de saida recebem 0.
function LerU16LE(const ABuf: array of Byte; AOff: Integer;
  var V: Word): Boolean;
function LerU16BE(const ABuf: array of Byte; AOff: Integer;
  var V: Word): Boolean;
function LerU32LE(const ABuf: array of Byte; AOff: Integer;
  var V: Longword): Boolean;
function LerU32BE(const ABuf: array of Byte; AOff: Integer;
  var V: Longword): Boolean;

// Procura uma string ASCII (case-insensitive) dentro do buffer a partir
// de AInicio; devolve a posicao 0-based em APos quando encontrada.
function ProcurarAscii(const ABuf: array of Byte; const ATexto: string;
  AInicio: Integer; var APos: Integer): Boolean;

implementation

function LerU8(const ABuf: array of Byte; AOff: Integer; var V: Byte): Boolean;
begin
  Result := False;
  V := 0;
  if (AOff < 0) or (AOff >= Length(ABuf)) then
    Exit;
  V := ABuf[AOff];
  Result := True;
end;

function LerU16LE(const ABuf: array of Byte; AOff: Integer;
  var V: Word): Boolean;
begin
  Result := False;
  V := 0;
  if (AOff < 0) or (AOff + 1 >= Length(ABuf)) then
    Exit;
  V := Word(ABuf[AOff]) or (Word(ABuf[AOff + 1]) shl 8);
  Result := True;
end;

function LerU16BE(const ABuf: array of Byte; AOff: Integer;
  var V: Word): Boolean;
begin
  Result := False;
  V := 0;
  if (AOff < 0) or (AOff + 1 >= Length(ABuf)) then
    Exit;
  V := (Word(ABuf[AOff]) shl 8) or Word(ABuf[AOff + 1]);
  Result := True;
end;

function LerU32LE(const ABuf: array of Byte; AOff: Integer;
  var V: Longword): Boolean;
begin
  Result := False;
  V := 0;
  if (AOff < 0) or (AOff + 3 >= Length(ABuf)) then
    Exit;
  V := Longword(ABuf[AOff]) or (Longword(ABuf[AOff + 1]) shl 8) or
       (Longword(ABuf[AOff + 2]) shl 16) or
       (Longword(ABuf[AOff + 3]) shl 24);
  Result := True;
end;

function LerU32BE(const ABuf: array of Byte; AOff: Integer;
  var V: Longword): Boolean;
begin
  Result := False;
  V := 0;
  if (AOff < 0) or (AOff + 3 >= Length(ABuf)) then
    Exit;
  V := (Longword(ABuf[AOff]) shl 24) or
       (Longword(ABuf[AOff + 1]) shl 16) or
       (Longword(ABuf[AOff + 2]) shl 8) or
       Longword(ABuf[AOff + 3]);
  Result := True;
end;

function ProcurarAscii(const ABuf: array of Byte; const ATexto: string;
  AInicio: Integer; var APos: Integer): Boolean;
var
  I, J, N, TL: Integer;
begin
  Result := False;
  APos := -1;
  TL := Length(ATexto);
  N := Length(ABuf);
  if (TL = 0) or (AInicio < 0) then
    Exit;
  for I := AInicio to N - TL do
  begin
    J := 0;
    while J < TL do
    begin
      // comparacao case-insensitive apenas para A-Z/a-z
      if UpCase(Char(ABuf[I + J])) <> UpCase(ATexto[J + 1]) then
        Break;
      Inc(J);
    end;
    if J = TL then
    begin
      APos := I;
      Result := True;
      Exit;
    end;
  end;
end;

end.