program TestCodec;

{ Testes unitarios de uTextCodec (F0-T3). Console; exit code = n. de falhas.
  Assercoes independentes da codepage ACP da maquina (comparacoes de
  estabilidade + bytes UTF-8 fixos). Fonte ASCII (sem acentos). }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils,
  uTextCodec in '..\src\core\uTextCodec.pas';

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

const
  C_ACP = #$E7; // 'c' cedilha no ACP corrente (comparacoes por estabilidade)

var
  RawU, RawOem, T, U: string;
  B: Byte;
begin
  Fails := 0;
  Checks := 0;

  // --- ASCII puro ---
  Check('IsAsciiOnly aceita ascii', IsAsciiOnly('FBRecStudio 123'));
  Check('IsAsciiOnly rejeita byte alto', not IsAsciiOnly('a' + C_ACP + 'o'));
  Check('ConvertToUtf8 ascii passa reto',
        ConvertToUtf8('FBRecStudio', 1252) = 'FBRecStudio');

  // --- roundtrip ACP -> UTF-8 -> ACP (independente da ACP) ---
  T := 'caf' + C_ACP + #$E9; // "cafe" no ACP da maquina
  Check('roundtrip ansi->utf8->ansi', Utf8ToAnsi(AnsiToUtf8(T)) = T);

  // --- OEM cp850 deterministico: byte 0x87 = c cedilha, 0xC6 = a til ---
  // (0x84 em cp850 e 'a' com trema/umlaut U+00E4, NAO 'a' com til; a
  // tabela cp850 e fixa no Windows - validado em runtime)
  U := OemToUtf8(#$87 + #$C6 + 'o', 850);
  Check('OemToUtf8 cp850 ccedilha-util',
        (Length(U) = 5) and (U[1] = #$C3) and (U[2] = #$A7) and
        (U[3] = #$C3) and (U[4] = #$A3) and (U[5] = 'o'));

  // --- OemToAnsi (cp850) seguido de AnsiToUtf8 deve voltar ao UTF-8 ---
  Check('OemToAnsi cp850 estavel',
        AnsiToUtf8(OemToAnsi(#$87 + #$C6 + 'o', 850)) =
        #$C3 + #$A7 + #$C3 + #$A3 + 'o');

  // --- DecodeConsoleBytes: heuristico UTF-8 ---
  RawU := AnsiToUtf8('caf' + C_ACP + #$E9);
  Check('DecodeConsoleBytes via utf8',
        DecodeConsoleBytes(RawU, 0) = 'caf' + C_ACP + #$E9);

  // --- DecodeConsoleBytes: fallback OEM (override 850) ---
  RawOem := #$87 + #$C6 + 'o'; // "cao" em cp850
  Check('DecodeConsoleBytes via oem/850',
        AnsiToUtf8(DecodeConsoleBytes(RawOem, 850)) =
        #$C3 + #$A7 + #$C3 + #$A3 + 'o');

  // --- BytesToAnsi trivial ---
  B := $41; // 'A'
  Check('BytesToAnsi 1 byte', BytesToAnsi(@B, 1) = 'A');

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.
