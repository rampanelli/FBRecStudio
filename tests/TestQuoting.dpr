program TestQuoting;

{ Testes unitarios de uQuoting (F0-T3): encoder CRT + parser de
  referencia + mascaramento de senha. Console; exit = n. de falhas. }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils,
  uQuoting in '..\src\core\uQuoting.pas';

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

// Verifica: QuoteCmdLine(lista) -> ParseCommandLine devolve os MESMOS
// argumentos (roundtrip do par encoder/parser).
procedure Roundtrip(const AArgs: array of string);
var
  Cmd: string;
  Parsed: TStringArray;
  N, I: Integer;
  Ok: Boolean;
begin
  Cmd := QuoteCmdLine(AArgs);
  N := ParseCommandLine(Cmd, Parsed);
  Ok := (N = Length(AArgs));
  if Ok then
    for I := 0 to Length(AArgs) - 1 do
      if Parsed[I] <> AArgs[I] then
      begin
        Ok := False;
        Break;
      end;
  Check('roundtrip: ' + Cmd, Ok);
end;

var
  Args: array of string;
  Masked: string;
begin
  Fails := 0;
  Checks := 0;

  // --- casos simples ---
  Check('ArgNeedsQuotes simples', not ArgNeedsQuotes('abc'));
  Check('ArgNeedsQuotes com espaco', ArgNeedsQuotes('a b'));
  Check('QuoteArg sem espaco', QuoteArg('abc') = 'abc');
  Check('QuoteArg com espaco', QuoteArg('a b') = '"a b"');
  Check('QuoteArg vazio vira aspas', QuoteArg('') = '""');

  // --- roundtrips (a gramatica exata e validada pelo parser) ---
  Roundtrip(['C:\Program Files\Firebird\isql.exe', '-u', 'sysdba']);
  Roundtrip(['tool', '-k', '']);
  Roundtrip(['tool', 'aspas " dentro', 'fim']);
  Roundtrip(['tool', 'barra \ final', 'fim']);
  Roundtrip(['tool', 'back \\ e "quote"', 'fim']);
  Roundtrip(['tool', 'espacos   multiplos', 'fim']);
  Roundtrip(['tool', '-p', 'a"b\c', 'x']);

  // --- mascara de senha (corrige B7/B8: nada de -pass em claro) ---
  SetLength(Args, 5);
  Args[0] := 'gbak.exe';
  Args[1] := '-user';
  Args[2] := 'sysdba';
  Args[3] := '-pass';
  Args[4] := 'segredo123';
  Masked := MakeDisplayCommandLine(Args);
  Check('mascara esconde valor do -pass',
        (Pos('segredo123', Masked) = 0) and (Pos('******', Masked) > 0));
  Check('mascara mantem demais args', Pos('-user', Masked) > 0);

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.
