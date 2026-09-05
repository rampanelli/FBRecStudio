{
  uExportReport.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F5 / F5-T5 (PLANO.md 4.3/4.6): relatorio legivel do DDL.

    * feDdl gera '<base>_ddl.txt': cabecalho (origem, isql, versao,
      data/hora, charset), contagem APROXIMADA do extract (busca de
      texto: linhas, 'create table', 'create ', 'alter ', 'set term'),
      nota metodologica e o conteudo do extract copiado do subprocesso.
    * O extract e obtido pela MESMA captura de stdout da uExportSQL
      (isql -extract; nunca redirecionamento '>' de shell) e gravado
      num arquivo temporario de nome unico (pid) na pasta de destino;
      apos montar o relatorio o temporario e apagado.
    * Contagem aproximada: sem driver (decisao 9.3) nao ha catalogo
      real - a heuristica conta frases ASCII sobre os bytes do extract
      (independe do charset da origem).
    * Senha nunca em claro; arquivo final parcial e apagado em falha.

  Regras do repositorio: Delphi 7 puro (sem generics/anonymous/for..in),
  comentarios pt-BR ASCII, sem Forms, unidades <= 31 chars.
  ------------------------------------------------------------------
}
unit uExportReport;

{$H+}

interface

uses
  Windows, SysUtils, Classes, uExportBase, uExportSQL, uKernelExec,
  uQuoting, uFBSwitchCatalog, uFBVersionInfo;

type
  // Contagens aproximadas do relatorio (heuristica sobre o texto).
  TContagemDdl = record
    Linhas: Int64;         // quebras de linha do extract
    CreateTable: Int64;    // linhas/trechos 'create table'
    Create: Int64;         // 'create ' (inclui create table)
    Alter: Int64;          // 'alter '
    SetTerm: Int64;        // 'set term'
  end;

  // ------------------------------------------------------------------
  // Exportador feDdl: relatorio legivel do DDL (F5-T5, sem Forms).
  // ------------------------------------------------------------------
  TExportadorReport = class(TExportadorBase)
  private
    FCatalogo: ISwitchCatalog;
  public
    constructor Create; overload;
    constructor CreateComCatalogo(ACatalogo: ISwitchCatalog); overload;

    function FormatoAlvo: TFormatoExport; override;
    function Preparar(const AParams: TExportParams;
      var Msg: string): Boolean; override;
    function Executar(Runner: IProcessRunner; Sink: IOutputSink;
      var Manifesto: TManifestoExport): Boolean; override;
  end;

// ------------------------------------------------------------------
// Funcoes livres (uteis aos testes e a montagem do relatorio)
// ------------------------------------------------------------------
function ContarSubstringCI(const AHaystack, ANeedle: AnsiString): Int64;
function ContarQuebrasDeLinha(const ABytes: AnsiString): Int64;
function LerArquivoBytes(const ACaminho: string;
  out Bytes: AnsiString): Boolean;
// Conta o DDL lendo o arquivo (bytes) e preenchendo TContagemDdl.
function ContarDdlNoArquivo(const AArquivo: string;
  out C: TContagemDdl): Boolean;

implementation

const
  K_TEMP_EXT = 'tmp';

// ------------------------------------------------------------------
// ContarSubstringCI / ContarQuebrasDeLinha / LerArquivoBytes
// ------------------------------------------------------------------
function ContarSubstringCI(const AHaystack, ANeedle: AnsiString): Int64;
var
  H, N: Integer;
  I, J: Integer;
  Hc, Nc: Byte;
begin
  Result := 0;
  H := Length(AHaystack);
  N := Length(ANeedle);
  if (N = 0) or (H < N) then
    Exit;
  for I := 1 to H - N + 1 do
  begin
    for J := 0 to N - 1 do
    begin
      Hc := Byte(AHaystack[I + J]);
      Nc := Byte(ANeedle[J + 1]);
      if (Hc >= $61) and (Hc <= $7A) then
        Dec(Hc, $20);          // so ASCII: charset da origem nao importa
      if (Nc >= $61) and (Nc <= $7A) then
        Dec(Nc, $20);
      if Hc <> Nc then
        Break;
      if J = N - 1 then
        Inc(Result);
    end;
  end;
end;

function ContarQuebrasDeLinha(const ABytes: AnsiString): Int64;
var
  I, L: Integer;
begin
  Result := 0;
  L := Length(ABytes);
  if L = 0 then
    Exit;
  // Conta quebras: CRLF = uma so; LF solto ou CR solto = uma cada.
  I := 1;
  while I <= L do
    if ABytes[I] = #13 then
    begin
      Inc(Result);
      Inc(I);
      if (I <= L) and (ABytes[I] = #10) then
        Inc(I);      // CRLF: pula o #10 que segue o #13
    end
    else if ABytes[I] = #10 then
    begin
      Inc(Result);
      Inc(I);
    end
    else
      Inc(I);
end;

function LerArquivoBytes(const ACaminho: string;
  out Bytes: AnsiString): Boolean;
var
  Fs: TFileStream;
begin
  Result := False;
  Bytes := '';
  if not FileExists(ACaminho) then
    Exit;
  Fs := TFileStream.Create(ACaminho, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Bytes, Fs.Size);
    if Fs.Size > 0 then
      Fs.ReadBuffer(Bytes[1], Fs.Size);
    Result := True;
  finally
    Fs.Free;
  end;
end;

function ContarDdlNoArquivo(const AArquivo: string;
  out C: TContagemDdl): Boolean;
var
  Bytes: AnsiString;
begin
  C.Linhas := 0;
  C.CreateTable := 0;
  C.Create := 0;
  C.Alter := 0;
  C.SetTerm := 0;
  Result := LerArquivoBytes(AArquivo, Bytes);
  if not Result then
    Exit;
  C.Linhas := ContarQuebrasDeLinha(Bytes);
  C.CreateTable := ContarSubstringCI(Bytes, 'CREATE TABLE');
  C.Create := ContarSubstringCI(Bytes, 'CREATE ');
  C.Alter := ContarSubstringCI(Bytes, 'ALTER ');
  C.SetTerm := ContarSubstringCI(Bytes, 'SET TERM');
end;

// ------------------------------------------------------------------
// TExportadorReport
// ------------------------------------------------------------------
constructor TExportadorReport.Create;
begin
  inherited Create;
  FCatalogo := nil;    // catalogo padrao da engine F1
end;

constructor TExportadorReport.CreateComCatalogo(ACatalogo: ISwitchCatalog);
begin
  Create;
  if ACatalogo <> nil then
    FCatalogo := ACatalogo;
end;

function TExportadorReport.FormatoAlvo: TFormatoExport;
begin
  Result := feDdl;
end;

// ------------------------------------------------------------------
// Preparar: igual ao feSql, mas o arquivo final e '<base>_ddl.txt'.
// ------------------------------------------------------------------
function TExportadorReport.Preparar(const AParams: TExportParams;
  var Msg: string): Boolean;
var
  DirDest: string;
begin
  ZerarEstado;
  FParams := AParams;
  Result := ValidarParamsBasico(Msg);
  if not Result then
    Exit;

  if FParams.IsqlExe = '' then
  begin
    Msg := 'Informe o caminho do executavel isql.';
    Result := False;
    FErroPreparacao := Msg;
    Exit;
  end;
  if not FileExists(FParams.IsqlExe) then
  begin
    Msg := 'isql nao encontrado: ' + FParams.IsqlExe;
    Result := False;
    FErroPreparacao := Msg;
    Exit;
  end;

  DirDest := IncludeTrailingPathDelimiter(FParams.PastaDestino);
  if DirDest <> '' then
    ForceDirectories(DirDest);
  if not DirectoryExists(DirDest) then
  begin
    Msg := 'Nao foi possivel criar a pasta de destino: ' + DirDest +
           ' (verifique permissao de escrita).';
    Result := False;
    FErroPreparacao := Msg;
    Exit;
  end;

  FDestino := IncludeTrailingPathDelimiter(FParams.PastaDestino) +
              ForcarExtensao(NomeBase + '_ddl', 'txt');

  if not CheckSobrescrever(FDestino, Msg) then
  begin
    Result := False;
    Exit;
  end;
  TemAvisoCaminhoLongo(ExpandFileName(FDestino));

  Result := True;
  FPreparado := True;
end;

// ------------------------------------------------------------------
// Executar: captura o extract num temporario, conta e monta o .txt.
// ------------------------------------------------------------------
function TExportadorReport.Executar(Runner: IProcessRunner;
  Sink: IOutputSink; var Manifesto: TManifestoExport): Boolean;
var
  Catalogo: ISwitchCatalog;
  Argv: TStringArray;
  Msg: string;
  Opt: TCapturaOptions;
  Capt: TResultadoCaptura;
  Erros: TStringList;
  TempFile: string;
  Cont: TContagemDdl;
  Bytes: AnsiString;
  CharsetCan: string;
  FinalEx: TFileStream;
  Linha: string;
  Ok: Boolean;
  Detalhe: string;
  VersaoTxt: string;
begin
  Result := False;
  if Manifesto = nil then
    Exit;
  if (not FPreparado) or (FParams = nil) then
  begin
    Manifesto.AddItem('', feDdl, '', -1, xeFalha,
      'Chame Preparar (com sucesso) antes de Executar.');
    Exit;
  end;

  Catalogo := FCatalogo;
  if Catalogo = nil then
    Catalogo := CriarCatalogPadrao;
  MontarArgvIsqlExtract(FParams.Usuario, FParams.Senha,
    FParams.CharsetSaida, FParams.Origem, Catalogo, FParams.VersaoBin,
    Argv, Msg);
  if Msg <> '' then
  begin
    Manifesto.AddItem('', feDdl, '', -1, xeFalha, Msg);
    Exit;
  end;

  CharsetCan := NormalizarCharsetExport(FParams.CharsetSaida);
  if CharsetCan = '' then
    CharsetCan := 'ANSI';
  TempFile := IncludeTrailingPathDelimiter(FParams.PastaDestino) +
              NomeBase + '_ddl_' + IntToStr(GetCurrentProcessId) + '.' +
              K_TEMP_EXT;
  if FileExists(TempFile) then
    SysUtils.DeleteFile(TempFile);

  Erros := TStringList.Create;
  Ok := False;
  try
    Opt.Executavel := FParams.IsqlExe;
    Opt.WorkDir := '';
    Opt.Args := Argv;
    Opt.Destino := TempFile;
    Opt.Charset := FParams.CharsetSaida;
    Opt.TetoBytes := 0;
    Opt.TimeoutMs := FParams.TimeoutMs;
    Opt.KillTree := True;
    Opt.ConsoleCodePage := 0;

    Capt := CapturarStdoutParaArquivo(Runner, Opt, Sink, Erros);
    if not Capt.Ok then
    begin
      if Erros.Count > 0 then
        Detalhe := Erros[0]
      else if Capt.Erro <> '' then
        Detalhe := Capt.Erro
      else
        Detalhe := 'isql terminou com codigo ' +
                   IntToStr(Integer(Capt.ExitCode)) + '.';
      Manifesto.AddItem(FDestino, feDdl, '', -1, xeFalha, Detalhe);
      if FileExists(FDestino) then
        SysUtils.DeleteFile(FDestino);   // nao deixa parcial da tentativa
      Exit;
    end;

    // Contagem aproximada + leitura do conteudo (bytes crus).
    if not ContarDdlNoArquivo(TempFile, Cont) then
    begin
      Manifesto.AddItem(FDestino, feDdl, '', -1, xeFalha,
        'Nao foi possivel ler o extract temporario para o relatorio.');
      Exit;
    end;
    if not LerArquivoBytes(TempFile, Bytes) then
    begin
      Manifesto.AddItem(FDestino, feDdl, '', -1, xeFalha,
        'Nao foi possivel ler o extract temporario para o relatorio.');
      Exit;
    end;

    // Monta o arquivo final: cabecalho + conteudo + rodape.
    FinalEx := TFileStream.Create(FDestino, fmCreate or fmShareDenyWrite);
    try
      if FParams.VersaoBin.Valida then
        VersaoTxt := VersaoParaTexto(FParams.VersaoBin)
      else
        VersaoTxt := 'nao reconhecida';

      Linha := 'FBRecStudio - Relatorio de DDL (isql -extract)' + #13#10 +
        '=================================================' + #13#10 +
        'Origem : ' + FParams.Origem + #13#10 +
        'isql   : ' + FParams.IsqlExe + #13#10 +
        'Versao : ' + VersaoTxt + #13#10 +
        'Data   : ' + DateTimeToStr(Now) + #13#10 +
        'Charset: ' + CharsetCan + #13#10 +
        'Contagem aproximada (heuristica de texto sobre o extract):' +
        #13#10 +
        '  linhas do extract : ' + IntToStr(Cont.Linhas) + #13#10 +
        '  ocorrencias create table: ' + IntToStr(Cont.CreateTable) +
        #13#10 +
        '  ocorrencias create : ' + IntToStr(Cont.Create) + #13#10 +
        '  ocorrencias alter  : ' + IntToStr(Cont.Alter) + #13#10 +
        '  ocorrencias set term: ' + IntToStr(Cont.SetTerm) + #13#10 +
        'Nota: contagens aproximadas (sem driver nao ha catalogo real;' +
        ' servem como indicacao).' + #13#10 +
        '-------------------------------------------------------------' +
        '---' + #13#10 +
        'Conteudo (extract do isql):' + #13#10;
      Linha := CodificarSaida(Linha, CharsetCan);
      if Linha <> '' then
        FinalEx.WriteBuffer(Linha[1], Length(Linha));

      // Copia o conteudo capturado byte a byte (ja no charset alvo).
      if Bytes <> '' then
        FinalEx.WriteBuffer(Bytes[1], Length(Bytes));

      Linha := #13#10 +
        '-------------------------------------------------------------' +
        '---' + #13#10 +
        'Fim do relatorio FBRecStudio (' + DateTimeToStr(Now) + ').' +
        #13#10;
      Linha := CodificarSaida(Linha, CharsetCan);
      if Linha <> '' then
        FinalEx.WriteBuffer(Linha[1], Length(Linha));
    finally
      FinalEx.Free;
    end;

    Detalhe := 'relatorio ddl gerado (exit 0); linhas do extract=' +
               IntToStr(Cont.Linhas) + '; create table aprox=' +
               IntToStr(Cont.CreateTable);
    Manifesto.AddItem(FDestino, feDdl, '', Cont.Linhas, xeOk, Detalhe);
    Ok := True;
  finally
    if FileExists(TempFile) then
      SysUtils.DeleteFile(TempFile);
    Erros.Free;
  end;
  Result := Ok;
end;

end.