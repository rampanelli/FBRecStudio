program TestFBVersion;

{ Testes unitarios de uFBVersionInfo (F1-T1): parse de strings de
  versao ('-z'/'-?'), familia por nome de caminho, intervalo de ODS
  (tabela 4.1.2) e leitura do recurso VS_VERSION_INFO. Console;
  exit = n. de falhas. Compilado tambem com FPC (-Mdelphi). }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils,
  uFBVersionInfo in '..\src\firebird\uFBVersionInfo.pas';

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

var
  V: TVersion;
  S: string;
  B: Boolean;
begin
  Fails := 0;
  Checks := 0;

  // ---------- ParseVersaoTexto: vetores conhecidos ----------
  B := ParseVersaoTexto('gbak version LI-V2.5.9.27110 Firebird 2.5', V);
  Check('parse gbak 2.5 ok', B);
  Check('parse gbak 2.5 familia fb', V.Familia = bfFirebird);
  Check('parse gbak 2.5 numero', (V.Maior = 2) and (V.Menor = 5) and
        (V.Revisao = 9) and (V.Build = 27110));
  Check('parse gbak 2.5 usa o grupo de 4 partes (nao o 2.5 do fim)',
        V.Maior = 2);
  Check('ods fb 2.5 = 10.0 a 11.2', V.TemOds and
        (V.OdsMinMaior = 10) and (V.OdsMinMenor = 0) and
        (V.OdsMaxMaior = 11) and (V.OdsMaxMenor = 2));

  B := ParseVersaoTexto('LI-V3.0.7.33355 Firebird 3.0', V);
  Check('parse fb 3.0 ok', B and (V.Familia = bfFirebird));
  Check('parse fb 3.0 numero', (V.Maior = 3) and (V.Menor = 0) and
        (V.Revisao = 7) and (V.Build = 33355));
  Check('ods fb 3.0 max 12.0', (V.OdsMaxMaior = 12) and (V.OdsMaxMenor = 0));

  B := ParseVersaoTexto('Firebird 2.5', V);
  Check('parse texto curto fb 2.5', B and (V.Maior = 2) and (V.Menor = 5));

  B := ParseVersaoTexto('InterBase 6.0', V);
  Check('parse interbase 6.0', B and (V.Familia = bfInterBase) and
        (V.Maior = 6) and (V.Menor = 0));
  Check('ods ib 6 = 10.0 a 10.0', V.TemOds and
        (V.OdsMinMaior = 10) and (V.OdsMaxMenor = 0));

  B := ParseVersaoTexto('LI-V4.0.1.2696 Firebird 4.0', V);
  Check('parse fb 4.0 (familia do texto)', B and (V.Familia = bfFirebird)
        and (V.Maior = 4));

  B := ParseVersaoTexto('V2.1.4.18343', V);
  Check('parse so numero com V prefixo', B and (V.Maior = 2) and
        (V.Menor = 1) and (V.Revisao = 4));
  Check('familia desconhecida sem palavra-chave', V.Familia = bfDesconhecida);

  B := ParseVersaoTexto('qualquer coisa sem numero', V);
  Check('texto sem numero -> false', not B and not V.Valida);
  B := ParseVersaoTexto('', V);
  Check('vazio -> false', not B);
  B := ParseVersaoTexto('2', V);
  Check('so um numero -> false (exige A.B)', not B);

  // ---------- FamiliaPorNome (heuristica de caminho) ----------
  Check('familia por Firebird_2_5', FamiliaPorNome(
    'C:\Program Files\Firebird\Firebird_2_5\bin') = bfFirebird);
  Check('familia por Embarcadero\InterBase', FamiliaPorNome(
    'C:\Program Files\Embarcadero\InterBase\bin') = bfInterBase);
  Check('familia por Borland', FamiliaPorNome(
    'D:\ib\Borland\InterBase') = bfInterBase);
  Check('familia por nome generico', FamiliaPorNome(
    'C:\tools\fb-bin') = bfDesconhecida);

  // ---------- PreencherIntervaloOds ----------
  ZerarVersion(V);
  V.Valida := True;
  V.Familia := bfFirebird;
  V.Maior := 1;
  V.Menor := 0;
  Check('ods fb 1.0 = 10.0', PreencherIntervaloOds(V) and
        (V.OdsMaxMaior = 10) and (V.OdsMaxMenor = 0));
  V.Familia := bfFirebird;
  V.Maior := 2;
  V.Menor := 1;
  Check('ods fb 2.1 = 10.0 a 11.1', PreencherIntervaloOds(V) and
        (V.OdsMaxMaior = 11) and (V.OdsMaxMenor = 1));
  V.Familia := bfInterBase;
  V.Maior := 5;
  V.Menor := 0;
  Check('ods ib 5 = 9.0', PreencherIntervaloOds(V) and
        (V.OdsMaxMaior = 9) and (V.OdsMaxMenor = 0));
  V.Familia := bfFirebird;
  V.Maior := 9;
  V.Menor := 0;
  Check('versao fora da tabela -> false', not PreencherIntervaloOds(V));

  // ---------- VersaoParaTexto ----------
  ParseVersaoTexto('gbak version LI-V2.5.9.27110 Firebird 2.5', V);
  S := VersaoParaTexto(V);
  Check('para texto contem Firebird 2.5.9',
        (Pos('Firebird 2.5.9', S) > 0) and (Pos('build 27110', S) > 0));
  ZerarVersion(V);
  Check('para texto invalido -> versao desconhecida',
        VersaoParaTexto(V) = 'versao desconhecida');

  // ---------- VersaoDoArquivo (recurso VS_VERSION_INFO) ----------
  // Sem bins reais: um .exe vazio nao tem recurso -> False sem crash.
  Check('versao de arquivo inexistente -> false',
        not VersaoDoArquivo('Z:\nao_existe_x\gbak.exe', V));
  Check('arquivo inexistente nao preenche valida', not V.Valida);

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.