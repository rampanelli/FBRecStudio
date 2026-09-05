{
  uQuoting.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  Montagem segura da linha de comando (PLANO.md, secao 6.3).

  Implementa a serializacao argv -> linha de comando segundo as regras
  do C runtime do Windows (MSDN "Parsing C command-line arguments"),
  compativeis com CommandLineToArgvW:

    * argumento vazio vira  ""
    * argumentos com espaco/tab/aspa (ou, defensivo vs cmd.exe,
      & % ^) sao envolvidos em aspas duplas;
    * aspa interna vira  \"   (regra (2n)+1 barras antes de aspa);
    * barra invertida antes de aspa e dobrada;
    * barras no fim do argumento sao dobradas antes da aspa de
      fechamento (regra 2n), para a aspa nao ser "escapada".

  Evita concatenacao crua de caminhos (regras de quoting do CRT).
  Nunca logar o comando real com senha: usar MakeDisplayCommandLine,
  que mascara o valor de -pass/-password.

  Comentarios pt-BR sem diacriticos (ASCII puro) - compatibilidade D7.
  ------------------------------------------------------------------
}
unit uQuoting;

{$H+}

interface

uses
  SysUtils;

type
  TStringArray = array of string;

// True quando o argumento precisa de aspas (regras acima). Vazio => True.
function ArgNeedsQuotes(const Arg: string): Boolean;

// Serializa um unico argumento (com aspas quando necessario).
function QuoteArg(const Arg: string): string;

// Monta a linha de comando: argv0 + demais argumentos separados por espaco.
// Uso tipico:  QuoteCmdLine([Executable, Arg1, Arg2, ...])  e o resultado
// e passado como lpCommandLine do CreateProcessW.
function QuoteCmdLine(const Args: array of string): string;

// Como QuoteCmdLine, porem substitui o valor do argumento seguinte a
// -pass / -password por '******' (exibicao em UI e log; corrige B7/B8).
function MakeDisplayCommandLine(const Args: array of string): string;

// Parser de REFERENCIA com as mesmas regras do C runtime do Windows
// (usado nos testes de ida-e-volta e em ferramentas auxiliares).
// Retorna o numero de argumentos; preenche Args.
function ParseCommandLine(const CmdLine: string; var Args: TStringArray): Integer;

implementation

// ------------------------------------------------------------------
function ArgNeedsQuotes(const Arg: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Arg = '' then
  begin
    Result := True;
    Exit;
  end;
  for I := 1 to Length(Arg) do
    case Arg[I] of
      ' ', #9, '"', '&', '%', '^':
        begin
          Result := True;
          Exit;
        end;
    end;
end;

// ------------------------------------------------------------------
function QuoteArg(const Arg: string): string;
var
  I, Run: Integer;
  Ch: Char;
begin
  if not ArgNeedsQuotes(Arg) then
  begin
    Result := Arg;
    Exit;
  end;
  Result := '"';
  Run := 0;              // barras consecutivas desde o ultimo char normal
  I := 1;
  while I <= Length(Arg) do
  begin
    Ch := Arg[I];
    if Ch = '\' then
      Inc(Run)
    else if Ch = '"' then
    begin
      // (2*Run)+1 barras + aspa => Run barras + aspa literal (sem alternar)
      Result := Result + StringOfChar('\', Run * 2 + 1) + '"';
      Run := 0;
    end
    else
    begin
      if Run > 0 then
      begin
        Result := Result + StringOfChar('\', Run);
        Run := 0;
      end;
      Result := Result + Ch;
    end;
    Inc(I);
  end;
  // Barras no fim: dobrar para a aspa de fechamento nao ser escapada.
  if Run > 0 then
    Result := Result + StringOfChar('\', Run * 2);
  Result := Result + '"';
end;

// ------------------------------------------------------------------
function QuoteCmdLine(const Args: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := Low(Args) to High(Args) do
  begin
    if I > Low(Args) then
      Result := Result + ' ';
    Result := Result + QuoteArg(Args[I]);
  end;
end;

// ------------------------------------------------------------------
function MakeDisplayCommandLine(const Args: array of string): string;
var
  I, N: Integer;
  Masked: TStringArray;
begin
  N := Length(Args);
  SetLength(Masked, N);
  for I := 0 to N - 1 do
    Masked[I] := Args[I];
  for I := 0 to N - 1 do
    if (Masked[I] = '-pass') or (Masked[I] = '-password') or
       (Masked[I] = '--password') then
      if I + 1 < N then
        Masked[I + 1] := '******';
  Result := QuoteCmdLine(Masked);
end;

// ------------------------------------------------------------------
function ParseCommandLine(const CmdLine: string; var Args: TStringArray): Integer;
var
  I, L, Run, Count, Cap: Integer;
  Ch: Char;
  InQuotes: Boolean;
  HadQuotes: Boolean;
  Cur: string;

  procedure AppendCur;
  begin
    if (Cur <> '') or HadQuotes then
    begin
      if Count = Cap then
      begin
        if Cap = 0 then
          Cap := 8
        else
          Cap := Cap * 2;
        SetLength(Args, Cap);
      end;
      Args[Count] := Cur;
      Inc(Count);
    end;
    Cur := '';
    HadQuotes := False;
  end;

begin
  Args := nil;
  Count := 0;
  Cap := 0;
  Cur := '';
  HadQuotes := False;
  InQuotes := False;
  I := 1;
  L := Length(CmdLine);
  while I <= L do
  begin
    Ch := CmdLine[I];
    if Ch = '\' then
    begin
      Run := 0;
      while (I <= L) and (CmdLine[I] = '\') do
      begin
        Inc(Run);
        Inc(I);
      end;
      if (I <= L) and (CmdLine[I] = '"') then
      begin
        if Odd(Run) then
        begin
          // (2n)+1 barras + aspa: n barras + aspa LITERAL (sem alternar)
          Cur := Cur + StringOfChar('\', Run div 2) + '"';
          Inc(I);
        end
        else
        begin
          // 2n barras + aspa: n barras + aspa alterna o modo quoting
          Cur := Cur + StringOfChar('\', Run div 2);
          InQuotes := not InQuotes;
          HadQuotes := True;
          Inc(I);
        end;
      end
      else
        Cur := Cur + StringOfChar('\', Run);
    end
    else if Ch = '"' then
    begin
      if InQuotes and (I < L) and (CmdLine[I + 1] = '"') then
      begin
        // Par de aspas DENTRO de string entre aspas = aspa literal (CRT)
        Cur := Cur + '"';
        Inc(I, 2);
      end
      else
      begin
        InQuotes := not InQuotes;
        HadQuotes := True;
        Inc(I);
      end;
    end
    else if (not InQuotes) and ((Ch = ' ') or (Ch = #9)) then
    begin
      AppendCur;
      Inc(I);
    end
    else
    begin
      Cur := Cur + Ch;
      Inc(I);
    end;
  end;
  // Fim da linha: descarrega o token atual (mesmo sem quebra de linha).
  AppendCur;
  SetLength(Args, Count);
  Result := Count;
end;

end.
