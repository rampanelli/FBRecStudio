{
  TestExportCsv.dpr - F5: exportador CSV/TSV (feCsv) + driver fake.
  ---------------------------------------------------------
  Estrategia: IDriverCatalogo/ILeitorLinhas com "driver fake" 100%
  em memoria (fixture de catalogo/linhas), sem fbclient.dll
  (decisao 9.3 adiada; implementacao real exige a dll 32-bit).

  Cobrem: escape RFC-4180 (delimitador/aspas/CR/LF), preparar sem
  driver (mensagem cita fbclient/9.3), filtro por tabelas-alvo,
  TSV (delimitador TAB), NULL como campo vazio, BLOB nas 3 politicas
  (omitir/hex/arquivo lateral com bytes), sobrescrever e resiliencia
  (tabela que falha vira item xeFalha e as demais seguem).
}
program TestExportCsv;

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Classes, Windows,
  uKernelExec in '..\src\core\uKernelExec.pas',
  uQuoting in '..\src\core\uQuoting.pas',
  uTextCodec in '..\src\core\uTextCodec.pas',
  uLogger in '..\src\core\uLogger.pas',
  uFBVersionInfo in '..\src\firebird\uFBVersionInfo.pas',
  uFBSwitchCatalog in '..\src\firebird\uFBSwitchCatalog.pas',
  uExportBase in '..\src\export\uExportBase.pas',
  uExportCSV in '..\src\export\uExportCSV.pas';

var
  Fails: Integer;
  Checks: Integer;

procedure Check(const Nome: string; Cond: Boolean; const Detalhe: string);
begin
  Inc(Checks);
  if Cond then
    WriteLn('PASS: ' + Nome)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL: ' + Nome + '  [' + Detalhe + ']');
  end;
end;

function TempRaiz: string;
var
  Buf: array[0..MAX_PATH] of Char;
  N: DWORD;
  Temp: string;
begin
  N := GetTempPath(SizeOf(Buf), PChar(@Buf[0]));
  Temp := '.\';
  if N > 0 then
    SetString(Temp, PChar(@Buf[0]), Integer(N));
  if Temp = '' then
    Temp := '.\';
  Result := IncludeTrailingPathDelimiter(Temp) + 'fbrtest_csv_' +
            IntToStr(GetCurrentProcessId);
end;

procedure CriarArquivo(const AArquivo: string; const ABytes: AnsiString);
var
  Fs: TFileStream;
begin
  Fs := TFileStream.Create(AArquivo, fmCreate or fmShareDenyNone);
  try
    if ABytes <> '' then
      Fs.WriteBuffer(ABytes[1], Length(ABytes));
  finally
    Fs.Free;
  end;
end;

function LerArquivoStr(const AArquivo: string): AnsiString;
var
  Fs: TFileStream;
begin
  Result := '';
  if not FileExists(AArquivo) then
    Exit;
  Fs := TFileStream.Create(AArquivo, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Fs.Size);
    if Fs.Size > 0 then
      Fs.ReadBuffer(Result[1], Fs.Size);
  finally
    Fs.Free;
  end;
end;

function BytesLerArquivo(const AArquivo: string): string;
begin
  // devolve o arquivo como AnsiString convertida a string (bytes ACP)
  Result := string(LerArquivoStr(AArquivo));
end;

// ------------------------------------------------------------------
// Fixture em memoria: celula / linha / leitor / driver fake.
// ------------------------------------------------------------------
type
  TCelFake = record
    Nulo: Boolean;
    EhBlob: Boolean;
    Texto: string;
    Bytes: TBytesCSV;
  end;
  TLinhaFake = array of TCelFake;
  TLinhasFake = array of TLinhaFake;

  TFakeLeitor = class(TInterfacedObject, ILeitorLinhas)
  private
    FData: TLinhasFake;
    FIdx: Integer;
    FFailMeio: Boolean;   // falha simulada apos a 1a linha
  public
    constructor Create(AData: TLinhasFake; AFailMeio: Boolean);
    function ProximaLinha(var Valores: TCamposLinha;
      var Msg: string): Boolean;
  end;

  TFakeDriver = class(TInterfacedObject, IDriverCatalogo)
  private
    FFailListar: Boolean;
    FFailMeioT2: Boolean;
  public
    DataT1: TLinhasFake;
    DataT2: TLinhasFake;
    constructor Create(AFailListar, AFailMeioT2: Boolean);
    function NomeDriver: string;
    function ListarTabelas(var Tabelas: TStringList; var Msg: string): Boolean;
    function ListarColunas(const ATabela: string;
      var Colunas: TListaColunas; var Msg: string): Boolean;
    function AbrirLeitura(const ATabela: string; out Leitor: ILeitorLinhas;
      var Msg: string): Boolean;
  end;

constructor TFakeLeitor.Create(AData: TLinhasFake;
  AFailMeio: Boolean);
var
  I, J: Integer;
begin
  inherited Create;
  FFailMeio := AFailMeio;
  FIdx := 0;
  SetLength(FData, Length(AData));
  for I := 0 to Length(AData) - 1 do
  begin
    SetLength(FData[I], Length(AData[I]));
    for J := 0 to Length(AData[I]) - 1 do
      FData[I][J] := AData[I][J];
  end;
end;

function TFakeLeitor.ProximaLinha(var Valores: TCamposLinha;
  var Msg: string): Boolean;
var
  I: Integer;
begin
  Msg := '';
  if FFailMeio and (FIdx = 1) then
  begin
    Msg := 'erro simulado no meio da leitura de T2';
    Result := False;
    Exit;
  end;
  if FIdx >= Length(FData) then
  begin
    Result := False;   // fim do resultado
    Exit;
  end;
  // Conversao campo a campo (TCelFake do teste -> TValorCelula).
  SetLength(Valores, Length(FData[FIdx]));
  for I := 0 to Length(FData[FIdx]) - 1 do
  begin
    Valores[I].Nulo := FData[FIdx][I].Nulo;
    Valores[I].EhBlob := FData[FIdx][I].EhBlob;
    Valores[I].Texto := FData[FIdx][I].Texto;
    Valores[I].Bytes := FData[FIdx][I].Bytes;
  end;
  Inc(FIdx);
  Result := True;
end;

constructor TFakeDriver.Create(AFailListar, AFailMeioT2: Boolean);
begin
  inherited Create;
  FFailListar := AFailListar;
  FFailMeioT2 := AFailMeioT2;
end;

function TFakeDriver.NomeDriver: string;
begin
  Result := 'driver fake em memoria';
end;

function TFakeDriver.ListarTabelas(var Tabelas: TStringList;
  var Msg: string): Boolean;
begin
  Msg := '';
  Result := False;
  if FFailListar then
  begin
    Msg := 'falha simulada ao listar tabelas';
    Exit;
  end;
  Tabelas.Clear;
  Tabelas.Add('T1');
  Tabelas.Add('T2');
  Result := True;
end;

function TFakeDriver.ListarColunas(const ATabela: string;
  var Colunas: TListaColunas; var Msg: string): Boolean;
begin
  Msg := '';
  Result := True;
  SetLength(Colunas, 0);
  if ATabela = 'T1' then
  begin
    SetLength(Colunas, 2);
    Colunas[0].Nome := 'COD';
    Colunas[0].Tipo := 'INTEGER';
    Colunas[0].Tamanho := 0;
    Colunas[0].Nula := False;
    Colunas[0].EhBlob := False;
    Colunas[1].Nome := 'NOME';
    Colunas[1].Tipo := 'VARCHAR';
    Colunas[1].Tamanho := 80;
    Colunas[1].Nula := True;
    Colunas[1].EhBlob := False;
  end
  else if ATabela = 'T2' then
  begin
    SetLength(Colunas, 3);
    Colunas[0].Nome := 'NOME';
    Colunas[0].Tipo := 'VARCHAR';
    Colunas[0].Tamanho := 200;
    Colunas[0].Nula := True;
    Colunas[0].EhBlob := False;
    Colunas[1].Nome := 'OBS';
    Colunas[1].Tipo := 'VARCHAR';
    Colunas[1].Tamanho := 50;
    Colunas[1].Nula := True;
    Colunas[1].EhBlob := False;
    Colunas[2].Nome := 'ARQ';
    Colunas[2].Tipo := 'BLOB SUB_TYPE 0';
    Colunas[2].Tamanho := 0;
    Colunas[2].Nula := True;
    Colunas[2].EhBlob := True;
  end
  else
  begin
    Msg := 'tabela desconhecida: ' + ATabela;
    Result := False;
  end;
end;

function TFakeDriver.AbrirLeitura(const ATabela: string;
  out Leitor: ILeitorLinhas; var Msg: string): Boolean;
var
  L: TFakeLeitor;
begin
  Msg := '';
  Leitor := nil;
  if ATabela = 'T1' then
  begin
    L := TFakeLeitor.Create(DataT1, False);
    Leitor := L;
    Result := True;
  end
  else if ATabela = 'T2' then
  begin
    L := TFakeLeitor.Create(DataT2, FFailMeioT2);
    Leitor := L;
    Result := True;
  end
  else
  begin
    Msg := 'tabela desconhecida: ' + ATabela;
    Result := False;
  end;
end;

// ------------------------------------------------------------------
// Monta a fixture de dados (T1 3 linhas; T2 1 linha com NULL e BLOB).
// ------------------------------------------------------------------
function MontarDadosT1: TLinhasFake;
var
  R: TLinhasFake;
begin
  SetLength(R, 3);

  SetLength(R[0], 2);
  R[0][0].Nulo := False;
  R[0][0].Texto := '1';
  R[0][1].Nulo := False;
  R[0][1].Texto := 'Maria';

  SetLength(R[1], 2);
  R[1][0].Nulo := False;
  R[1][0].Texto := '2';
  // Campo com 2 aspas internas: RFC-4180 dobra cada aspa -> 4 no CSV.
  R[1][1].Nulo := False;
  R[1][1].Texto := 'O "chefe"';

  SetLength(R[2], 2);
  R[2][0].Nulo := False;
  R[2][0].Texto := '3';
  R[2][1].Nulo := False;
  R[2][1].Texto := 'a;b';

  Result := R;
end;

function MontarDadosT2: TLinhasFake;
var
  R: TLinhasFake;
begin
  SetLength(R, 1);
  SetLength(R[0], 3);
  // NOME com quebra de linha interna (fica entre aspas no CSV)
  R[0][0].Nulo := False;
  R[0][0].Texto := 'texto com quebra' + #13#10 + 'segunda';
  // OBS = SQL NULL -> campo vazio
  R[0][1].Nulo := True;
  // ARQ = BLOB binario (politica BlobComo define a saida)
  R[0][2].Nulo := False;
  R[0][2].EhBlob := True;
  SetLength(R[0][2].Bytes, 3);
  R[0][2].Bytes[0] := $01;
  R[0][2].Bytes[1] := $02;
  R[0][2].Bytes[2] := $FF;
  Result := R;
end;

function NovosParams(const ADriver: IDriverCatalogo): TExportParams;
var
  P: TExportParams;
begin
  P := TExportParams.Create;
  P.Origem := TempRaiz + '\banco.fdb';
  P.PastaDestino := TempRaiz + '\out';
  P.ArquivoBase := 'meubanco';
  P.Sobrescrever := True;
  P.CharsetSaida := 'ANSI';
  P.Delimitador := ';';
  P.IncluirBlob := True;
  P.BlobComo := beHex;
  // driver fake entregue via TExportadorCSV.CreateComDriver
  Result := P;
end;

function ContarItensOk(const M: TManifestoExport): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to M.Count - 1 do
    if M.Itens[I].Status = xeOk then
      Inc(Result);
end;

var
  Raiz: string;
  P: TExportParams;
  Ex: TExportadorCSV;
  M: TManifestoExport;
  Msg: string;
  OK: Boolean;
  Driver: TFakeDriver;
  DriverIntf: IDriverCatalogo;
  Conteudo, Esperado: string;
  Colunas: TListaColunas;
  Vazia: string;
  I: Integer;
begin
  Checks := 0;
  Fails := 0;
  Raiz := TempRaiz;
  ForceDirectories(Raiz + '\out');
  CriarArquivo(Raiz + '\banco.fdb', 'DB');

  // ========== Grupo A: escape CSV/TSV (RFC-4180) ===================
  Check('A1 texto simples sem aspas', EscaparCampoCsv('abc', ';') = 'abc', '');
  Check('A2 delimitador exige aspas', EscaparCampoCsv('a;b', ';') = '"a;b"', '');
  Check('A3 aspa interna dobrada',
        EscaparCampoCsv('di "aspa"', ';') = '"di ""aspa"""', '');
  Check('A4 CR exige aspas', CampoCSVRequerAspas('x' + #13 + 'y', ';'), '');
  Check('A5 LF exige aspas', CampoCSVRequerAspas('x' + #10 + 'y', ';'), '');
  Check('A6 TAB nao exige aspas p/ delim ";"',
        not CampoCSVRequerAspas('x' + #9 + 'y', ';'), '');
  Check('A7 campo vazio sem aspas', EscaparCampoCsv('', ';') = '', '');
  Check('A8 delimitador diferente', EscaparCampoCsv('a;b', ',') = 'a;b', '');
  Check('A9 hex de bytes', BytesParaHexAnsi('ABC') = '414243',
        BytesParaHexAnsi('ABC'));

  // ========== Grupo B: preparar sem driver =========================
  Ex := TExportadorCSV.Create;
  try
    P := NovosParams(nil);
    OK := Ex.Preparar(P, Msg);
    Check('B1 preparar sem driver falha', (not OK) and (Msg <> ''), Msg);
    Check('B2 mensagem cita fbclient/decisao 9.3',
          (Pos('fbclient', Msg) > 0) and (Pos('9.3', Msg) > 0), Msg);
  finally
    Ex.Free;
  end;

  // ========== Grupo C: exportacao E2E com driver fake ==============
  Driver := TFakeDriver.Create(False, False);
  DriverIntf := Driver;
  Driver.DataT1 := MontarDadosT1;
  Driver.DataT2 := MontarDadosT2;

  Ex := TExportadorCSV.CreateComDriver(DriverIntf);
  try
    P := NovosParams(DriverIntf);
    OK := Ex.Preparar(P, Msg);
    Check('C1 preparar ok com driver', OK and Ex.Preparado, Msg);

    M := TManifestoExport.Create;
    try
      OK := Ex.Executar(nil, nil, M);
      Check('C2 Executar True (2 tabelas ok)', OK, M.ResumoParaTexto);
      Check('C3 manifesto 2 itens ok', (M.Count = 2) and
            (ContarItensOk(M) = 2) and M.TudoOk, M.ResumoParaTexto);
      Check('C4 arquivo T1.csv existe', FileExists(Raiz + '\out\meubanco.T1.csv'),
            Raiz + '\out\meubanco.T1.csv');
      Check('C5 arquivo T2.csv existe', FileExists(Raiz + '\out\meubanco.T2.csv'),
            Raiz + '\out\meubanco.T2.csv');

      Esperado := 'COD;NOME' + #13#10 +
                  '1;Maria' + #13#10 +
                  '2;"O ""chefe"""' + #13#10 +
                  '3;"a;b"' + #13#10;
      Conteudo := BytesLerArquivo(Raiz + '\out\meubanco.T1.csv');
      Check('C6 conteudo T1.csv exato (escape/aspas)', Conteudo = Esperado,
            'esperado=' + Esperado + ' | obtido=' + Conteudo);

      Esperado := 'NOME;OBS;ARQ' + #13#10 +
                  '"texto com quebra' + #13#10 +
                  'segunda";;0102FF' + #13#10;
      Conteudo := BytesLerArquivo(Raiz + '\out\meubanco.T2.csv');
      Check('C7 conteudo T2.csv exato (NULL vazio, BLOB hex, CRLF)',
            Conteudo = Esperado,
            'esperado=' + Esperado + ' | obtido=' + Conteudo);

      Check('C8 manifesto T1 linhas=3', (M.Itens[0].Tabela = 'T1') and
            (M.Itens[0].Linhas = 3), M.Itens[0].Detalhe);
      Check('C9 manifesto T2 linhas=1 e formato feCsv',
            (M.Itens[1].Tabela = 'T2') and (M.Itens[1].Linhas = 1) and
            (M.Itens[1].Formato = feCsv), M.Itens[1].Detalhe);
    finally
      M.Free;
    end;
  finally
    Ex.Free;
  end;

  // ========== Grupo D: filtro por tabelas-alvo =====================
  // Remove leftovers dos grupos anteriores para a prova de ausencia.
  if FileExists(Raiz + '\out\meubanco.T2.csv') then
    SysUtils.DeleteFile(Raiz + '\out\meubanco.T2.csv');
  if FileExists(Raiz + '\out\meubanco.T1.csv') then
    SysUtils.DeleteFile(Raiz + '\out\meubanco.T1.csv');
  Ex := TExportadorCSV.CreateComDriver(DriverIntf);
  try
    P := NovosParams(DriverIntf);
    SetLength(P.TabelasAlvo, 1);
    P.TabelasAlvo[0] := 'T1';
    OK := Ex.Preparar(P, Msg);
    Check('D1 preparar com alvo T1 ok', OK, Msg);
    M := TManifestoExport.Create;
    try
      OK := Ex.Executar(nil, nil, M);
      Check('D2 Executar True', OK, '');
      Check('D3 so 1 item (T1)', (M.Count = 1) and (M.Itens[0].Tabela = 'T1'),
            M.ResumoParaTexto);
      // Remove o csv de T1 gerado antes para a prova ficar limpa:
      // (arquivo .T1.csv ja existia -> sobrescreveu; T2.csv nao deve existir)
      Check('D4 T2.csv nao foi gerado',
            not FileExists(Raiz + '\out\meubanco.T2.csv'),
            'T2.csv inesperado');
    finally
      M.Free;
    end;
  finally
    Ex.Free;
  end;

  // ========== Grupo E: TSV (delimitador TAB) =======================
  Ex := TExportadorCSV.CreateComDriver(DriverIntf);
  try
    P := NovosParams(DriverIntf);
    P.Delimitador := #9;
    SetLength(P.TabelasAlvo, 1);
    P.TabelasAlvo[0] := 'T1';
    OK := Ex.Preparar(P, Msg);
    Check('E1 preparar TSV ok', OK, Msg);
    M := TManifestoExport.Create;
    try
      OK := Ex.Executar(nil, nil, M);
      Check('E2 Executar TSV True', OK, '');
      Check('E3 arquivo .tsv criado', FileExists(Raiz + '\out\meubanco.T1.tsv'),
            '');
      Esperado := 'COD' + #9 + 'NOME' + #13#10 +
                  '1' + #9 + 'Maria' + #13#10 +
                  '2' + #9 + '"O ""chefe"""' + #13#10 +
                  '3' + #9 + 'a;b' + #13#10;
      Conteudo := BytesLerArquivo(Raiz + '\out\meubanco.T1.tsv');
      Check('E4 conteudo TSV exato (ponto-e-virgula nao escapa no TSV)',
            Conteudo = Esperado, 'esperado=' + Esperado +
            ' | obtido=' + Conteudo);
    finally
      M.Free;
    end;
  finally
    Ex.Free;
  end;

  // ========== Grupo F: BLOB omitido (beOmitir) =====================
  Ex := TExportadorCSV.CreateComDriver(DriverIntf);
  try
    P := NovosParams(DriverIntf);
    P.BlobComo := beOmitir;
    SetLength(P.TabelasAlvo, 1);
    P.TabelasAlvo[0] := 'T2';
    OK := Ex.Preparar(P, Msg);
    Check('F1 preparar ok', OK, Msg);
    M := TManifestoExport.Create;
    try
      OK := Ex.Executar(nil, nil, M);
      Check('F2 Executar True', OK, '');
      Esperado := 'NOME;OBS;ARQ' + #13#10 +
                  '"texto com quebra' + #13#10 +
                  'segunda";;' + #13#10;
      Conteudo := BytesLerArquivo(Raiz + '\out\meubanco.T2.csv');
      Check('F3 BLOB omitido vira campo vazio', Conteudo = Esperado,
            'obtido=' + Conteudo);
    finally
      M.Free;
    end;
  finally
    Ex.Free;
  end;

  // ========== Grupo G: BLOB como arquivo lateral ===================
  Ex := TExportadorCSV.CreateComDriver(DriverIntf);
  try
    P := NovosParams(DriverIntf);
    P.BlobComo := beArquivo;
    SetLength(P.TabelasAlvo, 1);
    P.TabelasAlvo[0] := 'T2';
    OK := Ex.Preparar(P, Msg);
    Check('G1 preparar ok', OK, Msg);
    M := TManifestoExport.Create;
    try
      OK := Ex.Executar(nil, nil, M);
      Check('G2 Executar True', OK, '');
      Esperado := 'NOME;OBS;ARQ' + #13#10 +
                  '"texto com quebra' + #13#10 +
                  'segunda";;T2_00001_3.blob' + #13#10;
      Conteudo := BytesLerArquivo(Raiz + '\out\meubanco.T2.csv');
      Check('G3 celula guarda o nome do arquivo lateral', Conteudo = Esperado,
            'obtido=' + Conteudo);
      Check('G4 arquivo lateral existe com os bytes do BLOB',
            FileExists(Raiz + '\out\meubanco_blobs\T2_00001_3.blob'),
            Raiz + '\out\meubanco_blobs\T2_00001_3.blob');
      Conteudo := BytesLerArquivo(Raiz +
                  '\out\meubanco_blobs\T2_00001_3.blob');
      Check('G5 bytes do blob = 01 02 FF', Conteudo = Char($01) + Char($02) +
            Char($FF), '');
    finally
      M.Free;
    end;
  finally
    Ex.Free;
  end;

  // ========== Grupo H: sobrescrever ================================
  Ex := TExportadorCSV.CreateComDriver(DriverIntf);
  try
    // Arquivo alvo pre-existente sem Sobrescrever -> Preparar falha.
    CriarArquivo(Raiz + '\out\meubanco.T1.csv', 'ocupado');
    P := NovosParams(DriverIntf);
    P.Sobrescrever := False;
    SetLength(P.TabelasAlvo, 1);
    P.TabelasAlvo[0] := 'T1';
    OK := Ex.Preparar(P, Msg);
    Check('H1 destino existente sem sobrescrever falha', (not OK) and
          (Msg <> ''), Msg);
    // Com Sobrescrever passa e substitui o conteudo.
    P.Sobrescrever := True;
    OK := Ex.Preparar(P, Msg);
    Check('H2 destino existente com sobrescrever passa', OK, Msg);
    M := TManifestoExport.Create;
    try
      OK := Ex.Executar(nil, nil, M);
      Conteudo := BytesLerArquivo(Raiz + '\out\meubanco.T1.csv');
      Check('H3 conteudo substituido (cabecalho presente)',
            Pos('COD;NOME', Conteudo) = 1, Conteudo);
      Check('H4 Executar True', OK, '');
    finally
      M.Free;
    end;
  finally
    Ex.Free;
  end;

  // ========== Grupo I: driver que falha ao listar ==================
  DriverIntf := nil;   // libera o driver fake anterior (refcount)
  Driver := TFakeDriver.Create(True, False);  // falha em ListarTabelas
  DriverIntf := Driver;
  Ex := TExportadorCSV.CreateComDriver(DriverIntf);
  try
    P := NovosParams(DriverIntf);
    OK := Ex.Preparar(P, Msg);
    Check('I1 falha do driver ao listar vira preparar False', (not OK) and
          (Msg <> ''), Msg);
    M := TManifestoExport.Create;
    try
      OK := Ex.Executar(nil, nil, M);
      Check('I2 Executar False com item de falha',
            (not OK) and (M.Count = 1) and M.TemFalha, M.ResumoParaTexto);
    finally
      M.Free;
    end;
  finally
    Ex.Free;
  end;

  // ========== Grupo J: resiliencia (T2 falha no meio, T1 segue) ====
  DriverIntf := nil;   // libera o driver anterior (refcount)
  Driver := TFakeDriver.Create(False, True);  // T2 falha apos 1a linha
  DriverIntf := Driver;
  Driver.DataT1 := MontarDadosT1;
  Driver.DataT2 := MontarDadosT2;

  Ex := TExportadorCSV.CreateComDriver(DriverIntf);
  try
    P := NovosParams(DriverIntf);
    OK := Ex.Preparar(P, Msg);
    Check('J1 preparar ok', OK, Msg);
    M := TManifestoExport.Create;
    try
      OK := Ex.Executar(nil, nil, M);
      Check('J2 Executar False (houve falha em T2)', not OK, '');
      Check('J3 manifesto com 2 itens: T1 ok e T2 falha',
            (M.Count = 2) and (ContarItensOk(M) = 1) and M.TemFalha,
            M.ResumoParaTexto);
      Check('J4 T2.csv parcial apagado', not FileExists(Raiz + '\out\meubanco.T2.csv'),
            '');
      Check('J5 T1.csv continua valido', FileExists(Raiz + '\out\meubanco.T1.csv'),
            '');
    finally
      M.Free;
    end;
  finally
    Ex.Free;
  end;

  // ========== Grupo K: catalogo/colunas (unidade) ==================
  Vazia := '';
  Check('K1 ListarColunas T1 (2 colunas)',
        Driver.ListarColunas('T1', Colunas, Vazia) and
        (Length(Colunas) = 2) and (Colunas[0].Nome = 'COD') and
        (Colunas[1].Nome = 'NOME'), '');
  Check('K2 ListarColunas T2 marca BLOB',
        Driver.ListarColunas('T2', Colunas, Vazia) and
        (Length(Colunas) = 3) and (Colunas[2].EhBlob), '');
  Check('K3 NomeDriver informativo', Driver.NomeDriver <> '', '');

  // Limpeza simples dos arquivos criados
  for I := 0 to 2 do
  begin
    if FileExists(Raiz + '\out\meubanco.T1.csv') then
      SysUtils.DeleteFile(Raiz + '\out\meubanco.T1.csv');
    if FileExists(Raiz + '\out\meubanco.T2.csv') then
      SysUtils.DeleteFile(Raiz + '\out\meubanco.T2.csv');
    if FileExists(Raiz + '\out\meubanco.T1.tsv') then
      SysUtils.DeleteFile(Raiz + '\out\meubanco.T1.tsv');
  end;
  DriverIntf := nil;   // higiene: solta o driver fake ao final

  WriteLn;
  WriteLn('Checks: ' + IntToStr(Checks) + '  Fails: ' + IntToStr(Fails));
  Halt(Fails);
end.