{
  uExportBase.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F5 (PLANO.md 4.3 Exportacao, 4.6 Historico/Relatorios, 6.2, 6.3):
  contratos comuns do modulo de exportacao. Sem Forms: tudo testavel
  por console/FPC.

    * TFormatoExport: formatos de saida da seccao 4.3
      (feFbk, feFdb, feSql, feCsv, feDdl). feFdb e o proprio arquivo
      restaurado/limpo (sem geracao nova nesta fase). Os exportadores
      reais desta fase cobrem feFbk (uExportFBK), feSql (uExportSQL),
      feCsv (uExportCSV) e feDdl (uExportReport).
    * TManifestoExport: lista de saidas (arquivo, formato, tabela,
      linhas, status, detalhe) - a "contra-capa" de toda exportacao
      (regra transversal da 4.3: gerar manifesto e registrar historico).
    * TExportParams: entrada do usuario (4.3) como dados puros:
      charset de saida, delimitador (CSV/TSV), incluir dados/BLOB,
      sobrescrever, pasta destino e tabelas-alvo. A senha NUNCA entra
      em ResumoParaTexto (log/UI seguros).
    * IExportador: contrato unico de um exportador (4.3/6.2):
        Preparar(params, Msg) - valida pasta/caminhos/sobrescrever/
                                 charset/bins SEM executar;
        Executar(runner, sink, Manifesto) - roda a exportacao e
                                 preenche o manifesto por saida.
    * Codec de saida: NormalizarCharsetExport/CodificarSaida convertem
      texto ACP -> bytes no charset pedido (ANSI/UTF8/WIN1252/
      ISO8859_1/NONE). Sem redirecionamento '>' em linha de comando:
      exportadores de subprocesso capturam stdout e gravam arquivo
      (uExportSQL.CapturarStdoutParaArquivo).

  Decisoes de contrato desta fase (registradas; validar com bins reais
  na F7 - PLANO 4.3 ja previa "validar na F5"):
    * CSV/TSV: campo NULL vira campo VAZIO (indistinguivel de string
      vazia; documentado no cabecalho do .csv); BLOB segue BlobComo
      (omitir/hex/arquivo-lateral); escape RFC-4180 (aspas, delimitador,
      CR/LF).
    * isql -extract (doc. oficial FB 1.5-5.0) emite METADATA/DDL no
      stdout; dados no script variam por versao/flags e exigem o driver
      da decisao 9.3 (F5-T3).
    * Nomes de arquivo: NomeBase = ArquivoBase ou nome da origem sem
      extensao; uExportFBK garante '.fbk'; uExportSQL '.sql';
      uExportReport '<base>_ddl.txt'; uExportCSV '<base>.<TABELA>.csv'
      ('.tsv' quando o delimitador e TAB).

  Regras do repositorio: Delphi 7 puro (sem generics/anonymous/for..in),
  comentarios pt-BR ASCII, sem Forms, unidades <= 31 chars.
  ------------------------------------------------------------------
}
unit uExportBase;

{$H+}

interface

uses
  SysUtils, Classes, Windows, uKernelExec, uFBVersionInfo, uTextCodec;

type
  // ------------------------------------------------------------------
  // Formatos de saida da exportacao (PLANO 4.3). feFdb e o proprio
  // arquivo restaurado/limpo (a UI o oferece como "salvar como").
  // ------------------------------------------------------------------
  TFormatoExport = (feFbk, feFdb, feSql, feCsv, feDdl);

  // Status de UMA saida do manifesto.
  TStatusItemExport = (xeOk, xeFalha, xePulada, xeAviso);

  // Politica para colunas BLOB na saida CSV/TSV (4.3/decisao 9.3):
  //   beOmitir  - celula vazia (registrado no manifesto);
  //   beHex     - bytes em hexadecimal (autossuficiente);
  //   beArquivo - grava arquivo lateral '<base>_blobs\' e a celula
  //               guarda somente o nome do arquivo.
  TBlobExport = (beOmitir, beHex, beArquivo);

  // ------------------------------------------------------------------
  // Um item do manifesto: uma saida produzida (ou falhada).
  // ------------------------------------------------------------------
  TItemManifesto = class
  public
    Formato: TFormatoExport;
    Arquivo: string;      // caminho completo da saida ('' = falha de
                          // preparacao, ex.: driver indisponivel)
    Tabela: string;       // tabela origem ('' quando nao se aplica)
    Linhas: Int64;        // registros/linhas da saida; -1 = nao mensurado
                          // (ex.: .fbk)
    Status: TStatusItemExport;
    Detalhe: string;      // motivo em falha/aviso; resumo em sucesso
  end;

  // ------------------------------------------------------------------
  // Manifesto de exportacao (4.3): lista de saidas preenchida pelo
  // exportador durante Executar.
  // ------------------------------------------------------------------
  TManifestoExport = class
  private
    FItens: TList;        // lista de TItemManifesto (dona dos itens)
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TItemManifesto;
  public
    constructor Create;
    destructor Destroy; override;
    // Adiciona uma saida; devolve o indice do item criado.
    function AddItem(const AArquivo: string; AFormato: TFormatoExport;
      const ATabela: string; ALinhas: Int64; AStatus: TStatusItemExport;
      const ADetalhe: string): Integer;
    property Count: Integer read GetCount;
    property Itens[AIndex: Integer]: TItemManifesto read GetItem;
    function TemFalha: Boolean;  // alguma saida em xeFalha?
    function TudoOk: Boolean;    // todas as saidas xeOk?
    // Uma linha por item, para log/relatorio/historico (sem senhas).
    function ResumoParaTexto: string;
  end;

  // ------------------------------------------------------------------
  // Entrada do usuario (4.3) + dados de execucao de um exportador.
  // Campos publicos (dados puros; padrao TPlanoGbak das engines).
  // ------------------------------------------------------------------
  TExportParams = class
  public
    Formato: TFormatoExport;   // formato desta exportacao
    Origem: string;            // banco/arquivo de origem (existente)
    PastaDestino: string;      // pasta de saida (criada quando possivel)
    ArquivoBase: string;       // nome base (sem pasta; '' = nome da
                               // origem sem extensao)
    GbakExe: string;           // gbak (feFbk)
    IsqlExe: string;           // isql (feSql/feDdl)
    VersaoBin: TVersion;       // versao do binario (catalogo de switches)
    Usuario: string;           // -user (opcional)
    Senha: string;             // senha (nunca em claro em log)
    CharsetSaida: string;      // ''/'ANSI' (ACP), 'UTF8', 'WIN1252',
                               // 'ISO8859_1' ou 'NONE' (bytes crus)
    Delimitador: Char;         // CSV/TSV (default ';'; TAB = .tsv)
    IncluirDados: Boolean;     // feSql: pedido de dados no extract
                               // (isql -extract e DDL; dados exigem
                               // driver/F5-T3 - nota na uExportSQL)
    IncluirBlob: Boolean;      // feCsv: aplicar politica BlobComo
    BlobComo: TBlobExport;     // feCsv: politica BLOB
    Sobrescrever: Boolean;     // permite substituir saidas existentes
    TabelasAlvo: array of string; // feCsv: tabelas desejadas (vazio =
                               // todas as tabelas de usuario)
    TimeoutMs: DWORD;          // por subprocesso (0 = sem timeout)
    Verboso: Boolean;          // feFbk: gbak -v
    NoGC: Boolean;             // feFbk: gbak -g

    constructor Create;
    function TemAlvo: Boolean;   // ha alguma tabela-alvo?
    function AlvoContem(const ANomeTabela: string): Boolean; // ci
    // Resumo seguro p/ log/UI (SEM senha em claro).
    function ResumoParaTexto: string;
  end;

  // ------------------------------------------------------------------
  // Contrato unico de exportacao (PLANO 4.3/6.2). Cada formato tem um
  // exportador; a UI conversa apenas com esta interface (sem Forms).
  // ------------------------------------------------------------------
  IExportador = interface
    ['{3C0E8F21-9A54-4B17-8D20-7E1FA65C9B42}']
    function FormatoAlvo: TFormatoExport;
    // Valida pasta/caminhos/sobrescrever/charset/bins. Em falha Msg
    // traz o motivo amigavel. Chamar antes de Executar.
    function Preparar(const AParams: TExportParams;
      var Msg: string): Boolean;
    // Executa e preenche o Manifesto (por saida). Runner nil = usa
    // TProcessRunner interno; Sink nil = sem saida ao vivo. Devolve
    // False quando alguma saida falhou (Manifesto detalha por item).
    function Executar(Runner: IProcessRunner; Sink: IOutputSink;
      var Manifesto: TManifestoExport): Boolean;
  end;

  // ------------------------------------------------------------------
  // Base comum dos exportadores: estado + helpers de resolucao de
  // caminhos, validacoes e codec de charset.
  // ------------------------------------------------------------------
  TExportadorBase = class(TInterfacedObject, IExportador)
  protected
    FParams: TExportParams;
    FPreparado: Boolean;     // Preparar ok (com estes params)
    FErroPreparacao: string;
    FAvisos: TStringList;    // avisos nao fatais (caminho longo etc.)
    FDestino: string;        // arquivo de saida unico resolvido

    // --- resolucao de caminhos (4.3/6.3) ---
    function NomeBase: string;   // base sem pasta/extensao
    function DestinoUnico(const AExt: string): string; // pasta+base.ext
    function DestinoTabela(const AExt: string;
      const ATabela: string): string; // pasta+base+'.'+tabela+ext
    // Garante a extensao pedida (troca qualquer extensao existente).
    function ForcarExtensao(const ANome, AExt: string): string;

    // --- validacoes compartilhadas ---
    function ValidarParamsBasico(var Msg: string): Boolean; // params/
      // origem/pasta/charset
    function CheckSobrescrever(const AArquivo: string;
      var Msg: string): Boolean;
    function TemAvisoCaminhoLongo(const ACaminho: string): Boolean; // 230+

    // --- codec de saida ---
    // Converte texto ACP em bytes no charset canonico (para o arquivo).
    function Codificar(const ATexto, ACharsetCanonico: string): AnsiString;

    procedure RegistrarAviso(const AAviso: string);
    procedure ZerarEstado;
  public
    constructor Create;
    destructor Destroy; override;

    // IExportador (sobrescrever FormatoAlvo/Preparar/Executar).
    function FormatoAlvo: TFormatoExport; virtual;
    function Preparar(const AParams: TExportParams;
      var Msg: string): Boolean; virtual;
    function Executar(Runner: IProcessRunner; Sink: IOutputSink;
      var Manifesto: TManifestoExport): Boolean; virtual;

    property Avisos: TStringList read FAvisos;
    property ErroPreparacao: string read FErroPreparacao;
    property Destino: string read FDestino;
    property Preparado: Boolean read FPreparado;
  end;

// ------------------------------------------------------------------
// Funcoes livres
// ------------------------------------------------------------------
function FormatoExportParaTexto(AFormato: TFormatoExport): string;
function FormatoParaExtensao(AFormato: TFormatoExport): string; // refer.
function StatusExportParaTexto(AStatus: TStatusItemExport): string;
function BlobExportParaTexto(ABlob: TBlobExport): string;
// Normaliza o nome do charset para o canonico desta fase:
// '' (invalido), 'ANSI' (ACP), 'UTF8', 'WIN1252', 'ISO8859_1', 'NONE'.
function NormalizarCharsetExport(const ACharset: string): string;
// Nome FB para -charset do isql quando o charset canonico e conhecido
// do Firebird (UTF8/WIN1252/ISO8859_1); '' = nao passar -charset.
function CharsetFbParaIsql(const ACharsetCanonico: string): string;
// Converte texto ACP em bytes no charset canonico (p/ gravar arquivo).
// Funcao livre: usada pelo codec do subprocesso (uExportSQL) e pela
// base (TExportadorBase.Codificar delega aqui).
function CodificarSaida(const ATexto, ACharsetCanonico: string): AnsiString;

implementation

const
  K_CAMINHO_LONGO = 230;   // mesmo criterio das engines (MAX_PATH real)

// ------------------------------------------------------------------
// Textos
// ------------------------------------------------------------------
function FormatoExportParaTexto(AFormato: TFormatoExport): string;
begin
  case AFormato of
    feFbk: Result := 'fbk';
    feFdb: Result := 'fdb';
    feSql: Result := 'sql';
    feCsv: Result := 'csv';
    feDdl: Result := 'ddl';
  else
    Result := 'desconhecido';
  end;
end;

function FormatoParaExtensao(AFormato: TFormatoExport): string;
begin
  case AFormato of
    feFbk: Result := 'fbk';
    feFdb: Result := 'fdb';
    feSql: Result := 'sql';
    feCsv: Result := 'csv';
    feDdl: Result := 'txt';
  else
    Result := 'dat';
  end;
end;

function StatusExportParaTexto(AStatus: TStatusItemExport): string;
begin
  case AStatus of
    xeOk:     Result := 'ok';
    xeFalha:  Result := 'falha';
    xePulada: Result := 'pulada';
    xeAviso:  Result := 'aviso';
  else
    Result := 'desconhecido';
  end;
end;

function BlobExportParaTexto(ABlob: TBlobExport): string;
begin
  case ABlob of
    beOmitir:  Result := 'omitir';
    beHex:     Result := 'hex';
    beArquivo: Result := 'arquivo';
  else
    Result := 'desconhecido';
  end;
end;

function NormalizarCharsetExport(const ACharset: string): string;
var
  S: string;
begin
  Result := '';
  S := UpperCase(Trim(ACharset));
  if S = '' then
  begin
    Result := 'ANSI';
    Exit;
  end;
  if (S = 'ANSI') or (S = 'ACP') then
    Result := 'ANSI'
  else if (S = 'UTF8') or (S = 'UTF-8') then
    Result := 'UTF8'
  else if (S = 'WIN1252') or (S = '1252') or (S = 'CP1252') then
    Result := 'WIN1252'
  else if (S = 'ISO8859_1') or (S = 'ISO-8859-1') or (S = 'LATIN1') or
          (S = '28591') then
    Result := 'ISO8859_1'
  else if S = 'NONE' then
    Result := 'NONE';
end;

function CharsetFbParaIsql(const ACharsetCanonico: string): string;
begin
  if ACharsetCanonico = 'UTF8' then
    Result := 'UTF8'
  else if ACharsetCanonico = 'WIN1252' then
    Result := 'WIN1252'
  else if ACharsetCanonico = 'ISO8859_1' then
    Result := 'ISO8859_1'
  else
    Result := '';
end;

// ------------------------------------------------------------------
// TManifestoExport
// ------------------------------------------------------------------
constructor TManifestoExport.Create;
begin
  inherited Create;
  FItens := TList.Create;
end;

destructor TManifestoExport.Destroy;
var
  I: Integer;
begin
  for I := 0 to FItens.Count - 1 do
    TObject(FItens[I]).Free;
  FItens.Free;
  inherited Destroy;
end;

function TManifestoExport.GetCount: Integer;
begin
  Result := FItens.Count;
end;

function TManifestoExport.GetItem(AIndex: Integer): TItemManifesto;
begin
  Result := nil;
  if (AIndex >= 0) and (AIndex < FItens.Count) then
    Result := TItemManifesto(FItens[AIndex]);
end;

function TManifestoExport.AddItem(const AArquivo: string;
  AFormato: TFormatoExport; const ATabela: string; ALinhas: Int64;
  AStatus: TStatusItemExport; const ADetalhe: string): Integer;
var
  Item: TItemManifesto;
begin
  Item := TItemManifesto.Create;
  Item.Arquivo := AArquivo;
  Item.Formato := AFormato;
  Item.Tabela := ATabela;
  Item.Linhas := ALinhas;
  Item.Status := AStatus;
  Item.Detalhe := ADetalhe;
  Result := FItens.Add(Item);
end;

function TManifestoExport.TemFalha: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FItens.Count - 1 do
    if TItemManifesto(FItens[I]).Status = xeFalha then
    begin
      Result := True;
      Exit;
    end;
end;

function TManifestoExport.TudoOk: Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 0 to FItens.Count - 1 do
    if TItemManifesto(FItens[I]).Status <> xeOk then
    begin
      Result := False;
      Exit;
    end;
end;

function TManifestoExport.ResumoParaTexto: string;
var
  I: Integer;
  Item: TItemManifesto;
begin
  Result := '';
  for I := 0 to FItens.Count - 1 do
  begin
    Item := TItemManifesto(FItens[I]);
    if Result <> '' then
      Result := Result + #13#10;
    Result := Result + '[' + StatusExportParaTexto(Item.Status) + '] ' +
      'formato=' + FormatoExportParaTexto(Item.Formato);
    if Item.Tabela <> '' then
      Result := Result + ' tabela=' + Item.Tabela;
    Result := Result + ' arquivo=' + Item.Arquivo;
    if Item.Linhas >= 0 then
      Result := Result + ' linhas=' + IntToStr(Item.Linhas);
    if Item.Detalhe <> '' then
      Result := Result + ' (' + Item.Detalhe + ')';
  end;
end;

// ------------------------------------------------------------------
// TExportParams
// ------------------------------------------------------------------
constructor TExportParams.Create;
begin
  inherited Create;
  Formato := feFbk;
  Delimitador := ';';        // default Excel BR (4.3)
  IncluirDados := True;
  IncluirBlob := True;
  BlobComo := beHex;
  Sobrescrever := False;
  TimeoutMs := 0;
  Verboso := False;
  NoGC := True;              // padrao de backup nativo: gbak -b -v -g
  ZerarVersion(VersaoBin);
end;

function TExportParams.TemAlvo: Boolean;
begin
  Result := Length(TabelasAlvo) > 0;
end;

function TExportParams.AlvoContem(const ANomeTabela: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if not TemAlvo then
  begin
    Result := True;          // sem alvo = todas as tabelas
    Exit;
  end;
  for I := 0 to Length(TabelasAlvo) - 1 do
    if AnsiCompareText(TabelasAlvo[I], ANomeTabela) = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

function SimNao(AValor: Boolean): string;
begin
  if AValor then
    Result := 'sim'
  else
    Result := 'nao';
end;

function TExportParams.ResumoParaTexto: string;
begin
  Result := 'exportacao ' + FormatoExportParaTexto(Formato) + ': ' +
            Origem + ' -> ' + PastaDestino;
  if ArquivoBase <> '' then
    Result := Result + ' (base ' + ArquivoBase + ')';
  Result := Result + '; charset=' + NormalizarCharsetExport(CharsetSaida) +
            '; sobrescrever=' + SimNao(Sobrescrever);
end;

// ------------------------------------------------------------------
// TExportadorBase
// ------------------------------------------------------------------
constructor TExportadorBase.Create;
begin
  inherited Create;
  FAvisos := TStringList.Create;
  ZerarEstado;
end;

destructor TExportadorBase.Destroy;
begin
  FAvisos.Free;
  inherited Destroy;
end;

procedure TExportadorBase.ZerarEstado;
begin
  FParams := nil;
  FPreparado := False;
  FErroPreparacao := '';
  FDestino := '';
  FAvisos.Clear;
end;

function TExportadorBase.FormatoAlvo: TFormatoExport;
begin
  Result := feFbk;   // base; exportadores sobrescrevem
end;

procedure TExportadorBase.RegistrarAviso(const AAviso: string);
begin
  FAvisos.Add(AAviso);
end;

function TExportadorBase.TemAvisoCaminhoLongo(const ACaminho: string): Boolean;
begin
  Result := Length(ACaminho) > K_CAMINHO_LONGO;
  if Result then
    RegistrarAviso('Caminho tem ' + IntToStr(Length(ACaminho)) +
      ' caracteres (>' + IntToStr(K_CAMINHO_LONGO) +
      '): risco de limite MAX_PATH dos utilitarios Firebird.');
end;

// ------------------------------------------------------------------
// NomeBase / Destino* / ForcarExtensao
// ------------------------------------------------------------------
function TExportadorBase.NomeBase: string;
begin
  Result := '';
  if FParams = nil then
    Exit;
  if FParams.ArquivoBase <> '' then
    Result := ExtractFileName(FParams.ArquivoBase)
  else
    Result := ChangeFileExt(ExtractFileName(FParams.Origem), '');
  if Result = '' then
    Result := 'exportacao';
end;

function TExportadorBase.ForcarExtensao(const ANome, AExt: string): string;
begin
  if AnsiCompareText(ExtractFileExt(ANome), '.' + AExt) = 0 then
    Result := ANome
  else
    Result := ChangeFileExt(ANome, '') + '.' + AExt;
end;

function TExportadorBase.DestinoUnico(const AExt: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FParams.PastaDestino) +
            ForcarExtensao(NomeBase, AExt);
end;

function TExportadorBase.DestinoTabela(const AExt: string;
  const ATabela: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FParams.PastaDestino) +
            NomeBase + '.' + ATabela + '.' + AExt;
end;

// ------------------------------------------------------------------
// Validacoes compartilhadas
// ------------------------------------------------------------------
function TExportadorBase.ValidarParamsBasico(var Msg: string): Boolean;
begin
  Result := False;
  Msg := '';
  if FParams = nil then
  begin
    Msg := 'Parametros de exportacao nao atribuidos (Preparar).';
    FErroPreparacao := Msg;
    Exit;
  end;
  if FParams.Origem = '' then
  begin
    Msg := 'Informe a origem (banco recuperado a exportar).';
    FErroPreparacao := Msg;
    Exit;
  end;
  if not FileExists(FParams.Origem) then
  begin
    Msg := 'Origem nao encontrada: ' + FParams.Origem;
    FErroPreparacao := Msg;
    Exit;
  end;
  if Trim(FParams.PastaDestino) = '' then
  begin
    Msg := 'Informe a pasta de destino.';
    FErroPreparacao := Msg;
    Exit;
  end;
  if NormalizarCharsetExport(FParams.CharsetSaida) = '' then
  begin
    Msg := 'Charset de saida nao suportado: ' + FParams.CharsetSaida +
           ' (use ANSI, UTF8, WIN1252, ISO8859_1 ou NONE).';
    FErroPreparacao := Msg;
    Exit;
  end;
  Result := True;
end;

function TExportadorBase.CheckSobrescrever(const AArquivo: string;
  var Msg: string): Boolean;
begin
  Result := False;
  Msg := '';
  if FileExists(AArquivo) and (not FParams.Sobrescrever) then
  begin
    Msg := 'O arquivo de destino ja existe: ' + AArquivo +
           '. Marque "Sobrescrever" ou escolha outra pasta/nome.';
    FErroPreparacao := Msg;
    Exit;
  end;
  Result := True;
end;

// ------------------------------------------------------------------
// Codec de charset de saida (4.3; CSV em ACP para Excel BR)
// ------------------------------------------------------------------
function CodificarSaida(const ATexto,
  ACharsetCanonico: string): AnsiString;
var
  W: WideString;
  Need, OutLen: Integer;
  Cp: UINT;
begin
  Result := '';
  if ACharsetCanonico = 'UTF8' then
  begin
    Result := AnsiToUtf8(ATexto);
    Exit;
  end;
  if (ACharsetCanonico = 'ANSI') or (ACharsetCanonico = 'NONE') then
  begin
    Result := ATexto;   // ACP direto; NONE = bytes crus sem conversao
    Exit;
  end;
  if ACharsetCanonico = 'WIN1252' then
    Cp := 1252
  else
    Cp := 28591;        // ISO8859_1
  Need := MultiByteToWideChar(CP_ACP, 0, PChar(ATexto), Length(ATexto),
                              nil, 0);
  if Need <= 0 then
    Exit;
  SetLength(W, Need);
  MultiByteToWideChar(CP_ACP, 0, PChar(ATexto), Length(ATexto),
                      PWideChar(W), Need);
  OutLen := WideCharToMultiByte(Cp, 0, PWideChar(W), Need, nil, 0,
                                nil, nil);
  if OutLen <= 0 then
    Exit;
  SetLength(Result, OutLen);
  WideCharToMultiByte(Cp, 0, PWideChar(W), Need, PChar(Result), OutLen,
                      nil, nil);
end;

function TExportadorBase.Codificar(const ATexto,
  ACharsetCanonico: string): AnsiString;
begin
  Result := CodificarSaida(ATexto, ACharsetCanonico);
end;

// ------------------------------------------------------------------
// IExportador: defaults da base (Preparar generico / Executar falha)
// ------------------------------------------------------------------
function TExportadorBase.Preparar(const AParams: TExportParams;
  var Msg: string): Boolean;
begin
  ZerarEstado;
  FParams := AParams;
  Result := ValidarParamsBasico(Msg);
  FPreparado := Result;
end;

function TExportadorBase.Executar(Runner: IProcessRunner; Sink: IOutputSink;
  var Manifesto: TManifestoExport): Boolean;
begin
  Result := False;
  if Manifesto = nil then
    Exit;
  Manifesto.AddItem('', FormatoAlvo, '', -1, xeFalha,
    'Executar nao implementado neste exportador.');
end;

end.