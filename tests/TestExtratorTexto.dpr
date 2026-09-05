program TestExtratorTexto;

{ Testes de uExtratorTexto (F4-T2). Console; exit = n. de falhas.
  Varredura pura de bytes (nao depende de Firebird/driver). Cenarios:

   1) Decisoes PURAS: ByteContaComoTexto (ASCII 32..126, ANSI >= 160)
      e EhRunLegivel (run contiguo >= minimo; fim/fora do buffer).
   2) Extracao basica: arquivo sintetico em %TEMP% com 3 runs >= 6
      (offsets conhecidos, gravados de forma programatica), runs curtos
      entre eles que NAO podem aparecer; saida 'OFFSET=<off> <bytes>'.
   3) Arquivo so com runs curtos -> 0 linhas, saida vazia (sem lixo).
   4) Origem inexistente -> status amigavel etOrigemInexistente (e o
      dump NAO e criado).
   5) Progresso: callback por bloco chamado (blocos pequenos) com o
      ultimo ABytesLidos = tamanho total.
   6) TetoBytes: parada limpa em etTetoAtingido (linha cortada no meio
      de um run vira a parte lida; run alem do teto NAO aparece).
   7) Cancelamento: flag ligada -> etCancelado e o dump parcial e
      APAGADO (nunca sobra saida que pareca completa).
   8) Run gigante (> 1 MiB, o limite por segmento da unit): a varredura
      segmenta sem perder bytes (offsets e tamanhos conferem). }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Classes, Windows,
  uExtratorTexto in '..\src\engines\uExtratorTexto.pas';

var
  Fails, Checks: Integer;

type
  TByteArray = array of Byte;

  TLinhaEsperada = record
    Off: Int64;      // offset absoluto do run
    Texto: string;   // bytes do run (ASCII nos fixtures)
  end;

  TLinhasEsperadas = array of TLinhaEsperada;

  // Callback de progresso (method pointer de uExtratorTexto).
  TContadorProgresso = class
  public
    Chamadas: Integer;
    UltimosBytes: Int64;
    procedure AoProgresso(ABytesLidos, ABytesTotais: Int64);
  end;

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

function TempDir: string;
var
  Buf: array[0..MAX_PATH - 1] of Char;
  N: Integer;
begin
  N := GetTempPath(SizeOf(Buf), PChar(@Buf[0]));
  Result := '';
  if N > 0 then
    Result := IncludeTrailingPathDelimiter(StrPas(PChar(@Buf[0])));
end;

procedure TContadorProgresso.AoProgresso(ABytesLidos, ABytesTotais: Int64);
begin
  Inc(Chamadas);
  UltimosBytes := ABytesLidos;
end;

// ------------------------------------------------------------------
// Construtores de arquivo sintetico (bytes ASCII; lixo = < 160 e <> 
// ASCII imprimivel, para nunca virar texto falso).
// ------------------------------------------------------------------
procedure ApendGarbage(var D: TByteArray; AQtd: Integer);
const
  LIXO: array [0..5] of Byte = (0, 1, 2, 127, 128, 3);
var
  O, I: Integer;
begin
  O := Length(D);
  SetLength(D, O + AQtd);
  for I := 0 to AQtd - 1 do
    D[O + I] := LIXO[I mod 6];
end;

procedure ApendTexto(var D: TByteArray; const S: string);
var
  O, N: Integer;
begin
  O := Length(D);
  N := Length(S);
  SetLength(D, O + N);
  if N > 0 then
    Move(S[1], D[O], N);
end;

procedure Registrar(var E: TLinhasEsperadas; AOff: Int64; const ATexto: string);
begin
  SetLength(E, Length(E) + 1);
  E[Length(E) - 1].Off := AOff;
  E[Length(E) - 1].Texto := ATexto;
end;

procedure EscreverArquivo(const APath: string; const D: TByteArray);
var
  F: TFileStream;
  N: Integer;
begin
  F := TFileStream.Create(APath, fmCreate);
  try
    N := Length(D);
    if N > 0 then
      F.WriteBuffer(D[0], N);
  finally
    F.Free;
  end;
end;

function LerBytesArquivo(const APath: string): TByteArray;
var
  F: TFileStream;
  N: Int64;
begin
  Result := nil;
  F := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    N := F.Size;
    if N > 0 then
    begin
      SetLength(Result, N);
      F.ReadBuffer(Result[0], N);
    end;
  finally
    F.Free;
  end;
end;

// Converte bytes (valores < 256) de volta p/ texto ASCII do fixture.
function BytesParaTexto(const D: TByteArray): string;
var
  N, I: Integer;
begin
  N := Length(D);
  SetLength(Result, N);
  for I := 0 to N - 1 do
    Result[I + 1] := Chr(D[I]);
end;

// Le o dump e devolve as linhas (sem vazias) em ASaida.
procedure LerLinhasDump(const APath: string; ASaida: TStrings);
var
  D: TByteArray;
  Txt, Linha: string;
  I, J, N: Integer;
begin
  ASaida.Clear;
  D := LerBytesArquivo(APath);
  Txt := BytesParaTexto(D);
  Linha := '';
  N := Length(Txt);
  I := 1;
  while I <= N do
  begin
    if (Txt[I] = #13) and (I < N) and (Txt[I + 1] = #10) then
    begin
      if Linha <> '' then
        ASaida.Add(Linha);
      Linha := '';
      Inc(I, 2);
    end
    else
    begin
      Linha := Linha + Txt[I];
      Inc(I);
    end;
  end;
  if Linha <> '' then
    ASaida.Add(Linha);
end;
// ------------------------------------------------------------------
// Compara o dump com as linhas esperadas (ordem e conteudo).
// ------------------------------------------------------------------
procedure ConferirDump(const ANome: string; const APath: string;
  const Esperadas: TLinhasEsperadas; ATotalBytes: Int64);
var
  Linhas: TStringList;
  I: Integer;
  Off: Int64;
  Texto: string;
  P: Integer;
  OK: Boolean;
begin
  Linhas := TStringList.Create;
  try
    LerLinhasDump(APath, Linhas);
    Check(ANome + ': n. de linhas no dump', Linhas.Count = Length(Esperadas));
    if Linhas.Count = Length(Esperadas) then
    begin
      OK := True;
      for I := 0 to Linhas.Count - 1 do
      begin
        // linha: 'OFFSET=<digitos> ' + bytes do run
        Off := 0;
        Texto := '';
        if Copy(Linhas[I], 1, 7) = 'OFFSET=' then
        begin
          P := Pos(' ', Linhas[I]);
          if P > 8 then
          begin
            Off := StrToInt64(Copy(Linhas[I], 8, P - 8));
            Texto := Copy(Linhas[I], P + 1, MaxInt);
          end;
        end;
        if (Off <> Esperadas[I].Off) or (Texto <> Esperadas[I].Texto) then
          OK := False;
      end;
      Check(ANome + ': offsets e conteudos conferem', OK);
    end;
  finally
    Linhas.Free;
  end;
end;

// ------------------------------------------------------------------
// Monta o arquivo sintetico principal (veja o cabecalho): 3 runs de
// texto com >= 6 bytes (esperados) separados por lixo e por 2 runs
// CURTOS ('abc', 'XYZ') que NAO podem aparecer no dump.
// ------------------------------------------------------------------
procedure MontarAmostra(out Bytes: TByteArray;
  out Esperadas: TLinhasEsperadas);
var
  Off: Integer;
begin
  Bytes := nil;
  Esperadas := nil;

  // run 1 (17 bytes) no offset 0
  Off := Length(Bytes);
  ApendTexto(Bytes, 'LOTE_01_CLIENTES');
  Registrar(Esperadas, Off, 'LOTE_01_CLIENTES');

  ApendGarbage(Bytes, 5);
  // run 2 (15 bytes) apos o lixo
  Off := Length(Bytes);
  ApendTexto(Bytes, 'NOTA_FISCAL_1002');
  Registrar(Esperadas, Off, 'NOTA_FISCAL_1002');

  ApendGarbage(Bytes, 4);
  ApendTexto(Bytes, 'abc');   // curto (3): nunca grava com minimo 6
  ApendGarbage(Bytes, 3);
  ApendTexto(Bytes, 'XYZ');   // curto (3): nunca grava com minimo 6
  ApendGarbage(Bytes, 1);

  // run 3 (21 bytes) apos todo o lixo e os runs curtos
  Off := Length(Bytes);
  ApendTexto(Bytes, 'FIM_DO_ARQUIVO_TESTE');
  Registrar(Esperadas, Off, 'FIM_DO_ARQUIVO_TESTE');
end;

// ------------------------------------------------------------------
// 1) Decisoes puras
// ------------------------------------------------------------------
procedure TesteDecisoesPuras;
var
  B: TByteArray;
  Comp: Integer;
begin
  Check('byte: A(65) conta', ByteContaComoTexto(65));
  Check('byte: espaco(32) conta', ByteContaComoTexto(32));
  Check('byte: ~(126) conta', ByteContaComoTexto(126));
  Check('byte: TAB(9) nao conta', not ByteContaComoTexto(9));
  Check('byte: CR(13) nao conta', not ByteContaComoTexto(13));
  Check('byte: LF(10) nao conta', not ByteContaComoTexto(10));
  Check('byte: 31 nao conta', not ByteContaComoTexto(31));
  Check('byte: DEL(127) nao conta', not ByteContaComoTexto(127));
  Check('byte: 128 nao conta (C1)', not ByteContaComoTexto(128));
  Check('byte: 159 nao conta', not ByteContaComoTexto(159));
  Check('byte: 160 conta (ANSI)', ByteContaComoTexto(160));
  Check('byte: 255 conta (ANSI)', ByteContaComoTexto(255));

  SetLength(B, 10);
  FillChar(B[0], 10, Byte('A'));
  Comp := 0;
  Check('run: 10 As c/ minimo 6 = ok', EhRunLegivel(B, 0, 6, Comp));
  Check('run: comprimento = 10', Comp = 10);
  Comp := 0;
  Check('run: minimo 12 nao atende', not EhRunLegivel(B, 0, 12, Comp));
  Check('run: comprimento devolvido = 10', Comp = 10);
  Comp := 0;
  Check('run: inicio fora do buffer = false',
        not EhRunLegivel(B, 10, 6, Comp));

  SetLength(B, 3);
  B[0] := Byte('A'); B[1] := Byte('B'); B[2] := Byte('C');
  Comp := 0;
  Check('run: 3 bytes nao atende minimo 6', not EhRunLegivel(B, 0, 6, Comp));
  Check('run: comprimento = 3', Comp = 3);

  SetLength(B, 9);
  B[0] := Byte('A'); B[1] := Byte('B');
  B[2] := 0; // lixo
  B[3] := Byte('C'); B[4] := Byte('D'); B[5] := Byte('E');
  B[6] := Byte('F'); B[7] := Byte('G'); B[8] := Byte('H');
  Comp := 0;
  Check('run: lixo quebra o run (2 < minimo)',
        not EhRunLegivel(B, 0, 6, Comp));
  Comp := 0;
  Check('run: apos lixo 6 bytes = ok', EhRunLegivel(B, 3, 6, Comp));
  Check('run: comprimento apos lixo = 6', Comp = 6);
end;
// ------------------------------------------------------------------
// 2) Extracao basica (arquivo sintetico real em %TEMP%)
// ------------------------------------------------------------------
procedure TesteExtracaoBasica;
var
  Dir, Orig, Said: string;
  Bytes: TByteArray;
  Esperadas: TLinhasEsperadas;
  Opcoes: TExtracaoTextoOpcoes;
  Runs: Integer;
  Lidos: Int64;
  St: TExtracaoStatus;
begin
  Dir := TempDir + 'FBRTestExt' + IntToStr(GetCurrentProcessId);
  if DirectoryExists(Dir) then
  begin
    SysUtils.DeleteFile(Dir + '\amostra.bin');
    SysUtils.DeleteFile(Dir + '\dump.txt');
    RemoveDir(Dir);
  end;
  ForceDirectories(Dir);
  Orig := Dir + '\amostra.bin';
  Said := Dir + '\dump.txt';

  MontarAmostra(Bytes, Esperadas);
  EscreverArquivo(Orig, Bytes);

  FillChar(Opcoes, SizeOf(Opcoes), 0);
  Opcoes.ArquivoOrigem := Orig;
  Opcoes.ArquivoSaida := Said;
  // ComprimentoMinimo 0 = default (6); BlocoBytes 0 = default.
  Runs := -1;
  Lidos := 0;
  St := ExtrairRunsDeTexto(Opcoes, nil, nil, Runs, Lidos);

  Check('basica: status sucesso', St = etSucesso);
  Check('basica: runs gravados = 3', Runs = Length(Esperadas));
  Check('basica: bytes lidos = tamanho do arquivo',
        Lidos = Int64(Length(Bytes)));
  Check('basica: dump existe', FileExists(Said));
  ConferirDump('basica', Said, Esperadas, Int64(Length(Bytes)));

  // Conteudo ainda intacto? (origem nunca muda)
  Check('basica: origem nao foi alterada',
        Length(LerBytesArquivo(Orig)) = Length(Bytes));

  SysUtils.DeleteFile(Orig);
  SysUtils.DeleteFile(Said);
  RemoveDir(Dir);
end;

// ------------------------------------------------------------------
// 3) Arquivo so com runs curtos: 0 linhas e dump vazio (sem lixo)
// ------------------------------------------------------------------
procedure TesteSomenteRunsCurtos;
var
  Dir, Orig, Said: string;
  Bytes: TByteArray;
  Opcoes: TExtracaoTextoOpcoes;
  Runs: Integer;
  Lidos: Int64;
  St: TExtracaoStatus;
begin
  Dir := TempDir + 'FBRTestExtCurto' + IntToStr(GetCurrentProcessId);
  if DirectoryExists(Dir) then
  begin
    SysUtils.DeleteFile(Dir + '\curto.bin');
    SysUtils.DeleteFile(Dir + '\dump.txt');
    RemoveDir(Dir);
  end;
  ForceDirectories(Dir);
  Orig := Dir + '\curto.bin';
  Said := Dir + '\dump.txt';

  Bytes := nil;
  ApendTexto(Bytes, 'aa');
  ApendGarbage(Bytes, 2);
  ApendTexto(Bytes, 'bb');
  ApendGarbage(Bytes, 2);
  ApendTexto(Bytes, 'c');
  EscreverArquivo(Orig, Bytes);

  FillChar(Opcoes, SizeOf(Opcoes), 0);
  Opcoes.ArquivoOrigem := Orig;
  Opcoes.ArquivoSaida := Said;
  Runs := -1;
  Lidos := 0;
  St := ExtrairRunsDeTexto(Opcoes, nil, nil, Runs, Lidos);

  Check('curto: status sucesso', St = etSucesso);
  Check('curto: 0 runs gravados', Runs = 0);
  Check('curto: dump criado (vazio)', FileExists(Said));
  Check('curto: dump vazio (0 bytes)', Length(LerBytesArquivo(Said)) = 0);

  SysUtils.DeleteFile(Orig);
  SysUtils.DeleteFile(Said);
  RemoveDir(Dir);
end;

// ------------------------------------------------------------------
// 4) Origem inexistente: falha amigavel, sem criar o dump
// ------------------------------------------------------------------
procedure TesteOrigemInexistente;
var
  Dir, Orig, Said: string;
  Opcoes: TExtracaoTextoOpcoes;
  Runs: Integer;
  Lidos: Int64;
  St: TExtracaoStatus;
begin
  Dir := TempDir + 'FBRTestExtFalta' + IntToStr(GetCurrentProcessId);
  if DirectoryExists(Dir) then
  begin
    SysUtils.DeleteFile(Dir + '\dump.txt');
    RemoveDir(Dir);
  end;
  ForceDirectories(Dir);
  Orig := Dir + '\nao_existe_este_arquivo.fdb';
  Said := Dir + '\dump.txt';

  FillChar(Opcoes, SizeOf(Opcoes), 0);
  Opcoes.ArquivoOrigem := Orig;
  Opcoes.ArquivoSaida := Said;
  Runs := -1;
  Lidos := 0;
  St := ExtrairRunsDeTexto(Opcoes, nil, nil, Runs, Lidos);

  Check('falta: status = etOrigemInexistente', St = etOrigemInexistente);
  Check('falta: nenhum run gravado', Runs = 0);
  Check('falta: dump NAO foi criado', not FileExists(Said));
  Check('falta: texto do status cita origem',
        Pos('origem', ExtracaoStatusParaTexto(St)) > 0);

  SysUtils.DeleteFile(Said);
  RemoveDir(Dir);
end;
// ------------------------------------------------------------------
// Parceia 'OFFSET=<digitos> <bytes>' de uma linha do dump.
// ------------------------------------------------------------------
function ExtrairCamposDeLinha(const ALinha: string;
  out AOff: Int64; out ATexto: string): Boolean;
var
  P: Integer;
begin
  Result := False;
  AOff := 0;
  ATexto := '';
  if Copy(ALinha, 1, 7) <> 'OFFSET=' then
    Exit;
  P := Pos(' ', ALinha);
  if P <= 8 then
    Exit;
  AOff := StrToInt64(Copy(ALinha, 8, P - 8));
  ATexto := Copy(ALinha, P + 1, MaxInt);
  Result := True;
end;

// ------------------------------------------------------------------
// 5) Progresso por bloco (BlocoBytes pequeno forcando varios blocos)
// ------------------------------------------------------------------
procedure TesteProgresso;
var
  Dir, Orig, Said: string;
  Bytes: TByteArray;
  Esperadas: TLinhasEsperadas;
  Opcoes: TExtracaoTextoOpcoes;
  Contador: TContadorProgresso;
  Runs: Integer;
  Lidos: Int64;
  St: TExtracaoStatus;
begin
  Dir := TempDir + 'FBRTestExtProg' + IntToStr(GetCurrentProcessId);
  if DirectoryExists(Dir) then
  begin
    SysUtils.DeleteFile(Dir + '\prog.bin');
    SysUtils.DeleteFile(Dir + '\dump.txt');
    RemoveDir(Dir);
  end;
  ForceDirectories(Dir);
  Orig := Dir + '\prog.bin';
  Said := Dir + '\dump.txt';

  MontarAmostra(Bytes, Esperadas);
  EscreverArquivo(Orig, Bytes);

  FillChar(Opcoes, SizeOf(Opcoes), 0);
  Opcoes.ArquivoOrigem := Orig;
  Opcoes.ArquivoSaida := Said;
  Opcoes.BlocoBytes := 7;   // blocos pequenos -> varias chamadas
  Contador := TContadorProgresso.Create;
  try
    Runs := -1;
    Lidos := 0;
    St := ExtrairRunsDeTexto(Opcoes, Contador.AoProgresso, nil,
                             Runs, Lidos);
    // Verifica ANTES de liberar o objeto do callback.
    Check('progresso: status sucesso', St = etSucesso);
    Check('progresso: callback chamado 2+ vezes', Contador.Chamadas >= 2);
    Check('progresso: ultimo byte lido = total',
          Contador.UltimosBytes = Int64(Length(Bytes)));
  finally
    Contador.Free;
  end;

  SysUtils.DeleteFile(Orig);
  SysUtils.DeleteFile(Said);
  RemoveDir(Dir);
end;

// ------------------------------------------------------------------
// 6) TetoBytes: parada limpa (etTetoAtingido) dentro de run e no lixo
// ------------------------------------------------------------------
procedure TesteTeto;
var
  Dir, Orig, Said: string;
  Bytes: TByteArray;
  Opcoes: TExtracaoTextoOpcoes;
  Runs: Integer;
  Lidos: Int64;
  St: TExtracaoStatus;
  Linhas: TStringList;
  Off: Int64;
  Txt: string;
begin
  Dir := TempDir + 'FBRTestExtTeto' + IntToStr(GetCurrentProcessId);
  if DirectoryExists(Dir) then
  begin
    SysUtils.DeleteFile(Dir + '\teto1.bin');
    SysUtils.DeleteFile(Dir + '\teto2.bin');
    SysUtils.DeleteFile(Dir + '\d1.txt');
    SysUtils.DeleteFile(Dir + '\d2.txt');
    RemoveDir(Dir);
  end;
  ForceDirectories(Dir);

  // a) teto cai no LIXO apos o 1o run: so o run inteiro aparece.
  Orig := Dir + '\teto1.bin';
  Said := Dir + '\d1.txt';
  Bytes := nil;
  ApendTexto(Bytes, 'ABCDEFGHIJ');
  ApendGarbage(Bytes, 5);
  ApendTexto(Bytes, 'KLMNOPQRST');   // alem do teto: nao pode aparecer
  EscreverArquivo(Orig, Bytes);

  FillChar(Opcoes, SizeOf(Opcoes), 0);
  Opcoes.ArquivoOrigem := Orig;
  Opcoes.ArquivoSaida := Said;
  Opcoes.TetoBytes := 15;
  Runs := -1;
  Lidos := 0;
  St := ExtrairRunsDeTexto(Opcoes, nil, nil, Runs, Lidos);
  Check('teto/lixo: status etTetoAtingido', St = etTetoAtingido);
  Check('teto/lixo: bytes lidos = teto (15)', Lidos = 15);
  Check('teto/lixo: 1 run (alem do teto fora)', Runs = 1);
  Linhas := TStringList.Create;
  LerLinhasDump(Said, Linhas);
  Off := -1;
  Txt := '';
  Check('teto/lixo: dump so com o 1o run inteiro',
        (Linhas.Count = 1) and ExtrairCamposDeLinha(Linhas[0], Off, Txt) and
        (Off = 0) and (Txt = 'ABCDEFGHIJ'));
  Linhas.Free;

  // b) teto corta o run no meio: a parte lida vira linha, sem lixo.
  Orig := Dir + '\teto2.bin';
  Said := Dir + '\d2.txt';
  Bytes := nil;
  ApendTexto(Bytes, 'ABCDEFGHIJKLMNOPQRST');  // 20 bytes, sem lixo
  EscreverArquivo(Orig, Bytes);

  FillChar(Opcoes, SizeOf(Opcoes), 0);
  Opcoes.ArquivoOrigem := Orig;
  Opcoes.ArquivoSaida := Said;
  Opcoes.TetoBytes := 12;
  Runs := -1;
  Lidos := 0;
  St := ExtrairRunsDeTexto(Opcoes, nil, nil, Runs, Lidos);
  Check('teto/meio: status etTetoAtingido', St = etTetoAtingido);
  Check('teto/meio: bytes lidos = 12', Lidos = 12);
  Check('teto/meio: 1 run parcial', Runs = 1);
  Linhas := TStringList.Create;
  LerLinhasDump(Said, Linhas);
  Off := 0;
  Txt := '';
  Check('teto/meio: 1 linha com offset 0 e 12 bytes',
        (Linhas.Count = 1) and ExtrairCamposDeLinha(Linhas[0], Off, Txt) and
        (Off = 0) and (Txt = 'ABCDEFGHIJKL'));
  Linhas.Free;

  SysUtils.DeleteFile(Dir + '\teto1.bin');
  SysUtils.DeleteFile(Dir + '\teto2.bin');
  SysUtils.DeleteFile(Dir + '\d1.txt');
  SysUtils.DeleteFile(Dir + '\d2.txt');
  RemoveDir(Dir);
end;
// ------------------------------------------------------------------
// 7) Cancelamento: flag ligada -> etCancelado e dump parcial APAGADO
// ------------------------------------------------------------------
procedure TesteCancelamento;
var
  Dir, Orig, Said: string;
  Bytes: TByteArray;
  Esperadas: TLinhasEsperadas;
  Opcoes: TExtracaoTextoOpcoes;
  Flag: Boolean;
  Runs: Integer;
  Lidos: Int64;
  St: TExtracaoStatus;
begin
  Dir := TempDir + 'FBRTestExtCanc' + IntToStr(GetCurrentProcessId);
  if DirectoryExists(Dir) then
  begin
    SysUtils.DeleteFile(Dir + '\canc.bin');
    SysUtils.DeleteFile(Dir + '\dump.txt');
    RemoveDir(Dir);
  end;
  ForceDirectories(Dir);
  Orig := Dir + '\canc.bin';
  Said := Dir + '\dump.txt';

  MontarAmostra(Bytes, Esperadas);
  EscreverArquivo(Orig, Bytes);

  FillChar(Opcoes, SizeOf(Opcoes), 0);
  Opcoes.ArquivoOrigem := Orig;
  Opcoes.ArquivoSaida := Said;
  Flag := True;   // cancelamento ja acionado antes de comecar
  Runs := -1;
  Lidos := 0;
  St := ExtrairRunsDeTexto(Opcoes, nil, @Flag, Runs, Lidos);

  Check('cancel: status etCancelado', St = etCancelado);
  Check('cancel: nenhum run gravado', Runs = 0);
  Check('cancel: dump parcial foi apagado', not FileExists(Said));
  Check('cancel: texto do status cita cancelamento',
        Pos('cancelada', ExtracaoStatusParaTexto(St)) > 0);

  SysUtils.DeleteFile(Orig);
  SysUtils.DeleteFile(Said);
  RemoveDir(Dir);
end;

// ------------------------------------------------------------------
// 8) Run gigante (> limite de 1 MiB por segmento): varredura segmenta
//    sem perder bytes (offsets 0 e 1 MiB; soma dos tamanhos confere).
// ------------------------------------------------------------------
procedure TesteRunGigante;
const
  K_UM_MIB = 1048576;   // mesmo valor do limite interno da unit
  K_EXTRA  = 5000;
var
  Dir, Orig, Said: string;
  Bytes: TByteArray;
  Opcoes: TExtracaoTextoOpcoes;
  Runs: Integer;
  Lidos: Int64;
  St: TExtracaoStatus;
  Linhas: TStringList;
  Off: Int64;
  Txt: string;
  Soma: Int64;
  I: Integer;
begin
  Dir := TempDir + 'FBRTestExtGig' + IntToStr(GetCurrentProcessId);
  if DirectoryExists(Dir) then
  begin
    SysUtils.DeleteFile(Dir + '\gig.bin');
    SysUtils.DeleteFile(Dir + '\dump.txt');
    RemoveDir(Dir);
  end;
  ForceDirectories(Dir);
  Orig := Dir + '\gig.bin';
  Said := Dir + '\dump.txt';

  SetLength(Bytes, K_UM_MIB + K_EXTRA);
  for I := 0 to Length(Bytes) - 1 do
    Bytes[I] := Byte('A');
  EscreverArquivo(Orig, Bytes);

  FillChar(Opcoes, SizeOf(Opcoes), 0);
  Opcoes.ArquivoOrigem := Orig;
  Opcoes.ArquivoSaida := Said;
  Runs := -1;
  Lidos := 0;
  St := ExtrairRunsDeTexto(Opcoes, nil, nil, Runs, Lidos);

  Check('gigante: status sucesso', St = etSucesso);
  Check('gigante: bytes lidos = arquivo todo',
        Lidos = Int64(K_UM_MIB + K_EXTRA));
  Check('gigante: 2 segmentos gravados', Runs = 2);

  Linhas := TStringList.Create;
  LerLinhasDump(Said, Linhas);
  Check('gigante: 2 linhas no dump', Linhas.Count = 2);
  Soma := 0;
  if Linhas.Count = 2 then
  begin
    Off := -1;
    Txt := '';
    Check('gigante: 1o segmento offset 0 com 1 MiB',
          ExtrairCamposDeLinha(Linhas[0], Off, Txt) and (Off = 0) and
          (Length(Txt) = K_UM_MIB));
    Soma := Soma + Length(Txt);
    Off := -1;
    Txt := '';
    Check('gigante: 2o segmento offset 1 MiB com o resto',
          ExtrairCamposDeLinha(Linhas[1], Off, Txt) and
          (Off = Int64(K_UM_MIB)) and (Length(Txt) = K_EXTRA));
    Soma := Soma + Length(Txt);
    Check('gigante: nenhum byte do run se perdeu (soma confere)',
          Soma = Int64(K_UM_MIB + K_EXTRA));
  end;
  Linhas.Free;

  SysUtils.DeleteFile(Orig);
  SysUtils.DeleteFile(Said);
  RemoveDir(Dir);
end;

// ------------------------------------------------------------------
// Principal
// ------------------------------------------------------------------
begin
  Fails := 0;
  Checks := 0;

  TesteDecisoesPuras;
  TesteExtracaoBasica;
  TesteSomenteRunsCurtos;
  TesteOrigemInexistente;
  TesteProgresso;
  TesteTeto;
  TesteCancelamento;
  TesteRunGigante;

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.
