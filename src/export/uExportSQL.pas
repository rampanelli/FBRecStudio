{
  uExportSQL.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F5 / F5-T2 (PLANO.md 4.3 Exportacao): SQL/DDL via 'isql -extract'.

    * Sintaxe confirmada na doc. oficial Firebird (isql 1.5-5.0):
        isql -extract -user X -password Y [-charset C] <banco>
      imprime o script (metadata/DDL) no STDOUT; '-e(x)tract' extrai
      metadata. Inclusao de DADOS no script varia por versao/flags e
      exige o driver da decisao 9.3 (F5-T3); PLANO 4.3 previa
      "comportamento DDL/dados varia por versao - validar na F5"
      (F7: bins reais). Registrado no manifesto quando IncluirDados.
    * SEM redirecionamento '>' em linha de comando (regra do plano):
      CapturarStdoutParaArquivo roda o subprocesso via IProcessRunner
      (uKernelExec) e GRAVA as linhas do stdout capturado num arquivo
      destino, com teto de bytes e codigo de saida. Nunca concatena
      '>' nem usa shell.
    * MontarArgvIsqlExtract monta o argv tipado com chaves SOMENTE via
      ISwitchCatalog (mesma regra das engines; '-extract'/'-user'/
      '-password'/'-charset' por versao).
    * Senha nunca em claro: o log/UI exibem o comando via
      uQuoting.MakeDisplayCommandLine (o uKernelExec ja entrega eventos
      com o comando mascarado).
    * TExportadorSQL: feSql -> arquivo '<base>.sql' com o extract;
      arquivo parcial e apagado quando o processo falha (nada de
      "sucesso sujo").

  Regras do repositorio: Delphi 7 puro (sem generics/anonymous/for..in),
  comentarios pt-BR ASCII, sem Forms, unidades <= 31 chars.
  ------------------------------------------------------------------
}
unit uExportSQL;

{$H+}

interface

uses
  SysUtils, Classes, Windows, uExportBase, uKernelExec, uQuoting,
  uFBSwitchCatalog, uFBVersionInfo;

type
  // ------------------------------------------------------------------
  // Opcoes da captura de stdout para arquivo (usada por feSql e pelo
  // relatorio feDdl da uExportReport).
  // ------------------------------------------------------------------
  TCapturaOptions = record
    Executavel: string;        // caminho completo do executavel
    WorkDir: string;           // '' = herda do pai
    Args: TStringArray;        // argv tipado (sem argv0)
    Destino: string;           // arquivo que recebe o stdout capturado
    Charset: string;           // canonico p/ gravar ('' = ANSI/ACP)
    TetoBytes: Int64;          // 0 = sem teto; >0 interrompe a gravacao
                               // ao estourar (processo e cancelado)
    TimeoutMs: DWORD;          // 0 = sem timeout
    KillTree: Boolean;         // cancelar/timeout mata a arvore (Job)
    ConsoleCodePage: Integer;  // 0 = OEM automatico (uTextCodec)
  end;

  // Resultado da captura (contrato do modulo de exportacao).
  TResultadoCaptura = record
    Ok: Boolean;               // exit 0, sem cancelado/timeout/teto
    Iniciou: Boolean;          // processo criado com sucesso
    ExitCode: DWORD;
    Cancelado: Boolean;
    Timeout: Boolean;
    EstourouTeto: Boolean;     // teto de bytes atingido (arquivo
                               // incompleto; processo cancelado)
    Linhas: Int64;             // linhas gravadas no arquivo
    Bytes: Int64;              // bytes gravados
    Erro: string;              // motivo (nao iniciou/timeout/teto)
  end;

  // ------------------------------------------------------------------
  // Exportador SQL/DDL: isql -extract capturado para '<base>.sql'.
  // Sem driver: roda com o subprocesso isql (fake bins nos testes).
  // ------------------------------------------------------------------
  TExportadorSQL = class(TExportadorBase)
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
// Funcoes livres
// ------------------------------------------------------------------
// Monta o argv do 'isql -extract' (chaves via catalogo). Devolve False
// + Msg quando a versao nao suporta -extract ou o catalogo falta.
procedure MontarArgvIsqlExtract(const AUsuario, ASenha, ACharsetSaida,
  AOrigem: string; ACatalogo: ISwitchCatalog; const AVer: TVersion;
  out Argv: TStringArray; out Msg: string);

// Roda 'Executavel Args' capturando o stdout para 'Destino' (sem
// redirecionamento de shell). Runner nil = TProcessRunner interno.
// Erros do stderr (decodificados) vao para Erros (se nao nil) e o
// resultado devolve codigo/teto/linhas/bytes.
function CapturarStdoutParaArquivo(Runner: IProcessRunner;
  const Opt: TCapturaOptions; Sink: IOutputSink;
  Erros: TStrings): TResultadoCaptura;

implementation

const
  K_CAP_ERROS = 400;   // teto de linhas de erro retidas (memoria finita)
  K_CAMINHO_LONGO = 230;

type
  // Sink interno da captura: grava stdout (decodificado) no arquivo de
  // destino no charset pedido e retem/roteia stderr. Aplicacao de teto
  // de bytes com cancelamento do processo (evita disco infinito).
  TCapturaSink = class(TInterfacedObject, IOutputSink)
  private
    FStream: TFileStream;
    FCharset: string;
    FErros: TStrings;
    FExt: IOutputSink;
    FRunner: IProcessRunner;
    FTeto: Int64;
    FBytes: Int64;
    FLinhas: Int64;
    FEstourou: Boolean;
  public
    constructor Create(AStream: TFileStream; const ACharset: string;
      ATeto: Int64; Runner: IProcessRunner; Sink: IOutputSink;
      Erros: TStrings);
    procedure OnLine(AStreamId: TStreamId; const ALine: string);
    procedure OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
    property Bytes: Int64 read FBytes;
    property Linhas: Int64 read FLinhas;
    property Estourou: Boolean read FEstourou;
  end;

// ------------------------------------------------------------------
// MontarArgvIsqlExtract
// ------------------------------------------------------------------
procedure MontarArgvIsqlExtract(const AUsuario, ASenha, ACharsetSaida,
  AOrigem: string; ACatalogo: ISwitchCatalog; const AVer: TVersion;
  out Argv: TStringArray; out Msg: string);
var
  Tok, ChFb: string;

  procedure AddArg(const AArg: string);
  var
    N: Integer;
  begin
    N := Length(Argv);
    SetLength(Argv, N + 1);
    Argv[N] := AArg;
  end;

begin
  Argv := nil;
  Msg := '';
  if ACatalogo = nil then
  begin
    Msg := 'Catalogo de switches nao informado.';
    Exit;
  end;
  if AOrigem = '' then
  begin
    Msg := 'Informe a origem (banco a exportar).';
    Exit;
  end;

  Tok := ACatalogo.ObterSwitch(bkIsql, AVer, ssExtract);
  if Tok = '' then
  begin
    Msg := 'A versao do isql nao suporta -extract (catalogo).';
    Exit;
  end;
  AddArg(Tok);                       // '-extract'

  if AUsuario <> '' then
  begin
    Tok := ACatalogo.ObterSwitch(bkIsql, AVer, ssUser);
    if Tok <> '' then
    begin
      AddArg(Tok);
      AddArg(AUsuario);
    end;
  end;
  if ASenha <> '' then
  begin
    Tok := ACatalogo.ObterSwitch(bkIsql, AVer, ssPassword);
    if Tok <> '' then
    begin
      AddArg(Tok);
      AddArg(ASenha);    // nunca em claro em log (MakeDisplayCommandLine)
    end;
  end;
  // Charset de conexao so quando o FB conhece o nome (UTF8/WIN1252/...).
  ChFb := CharsetFbParaIsql(NormalizarCharsetExport(ACharsetSaida));
  if ChFb <> '' then
  begin
    Tok := ACatalogo.ObterSwitch(bkIsql, AVer, ssCharset);
    if Tok <> '' then
    begin
      AddArg(Tok);
      AddArg(ChFb);
    end;
  end;

  AddArg(AOrigem);                   // operando do banco por ultimo
end;

// ------------------------------------------------------------------
// TCapturaSink
// ------------------------------------------------------------------
constructor TCapturaSink.Create(AStream: TFileStream;
  const ACharset: string; ATeto: Int64; Runner: IProcessRunner;
  Sink: IOutputSink; Erros: TStrings);
begin
  inherited Create;
  FStream := AStream;
  FCharset := ACharset;
  FTeto := ATeto;
  FRunner := Runner;
  FExt := Sink;
  FErros := Erros;
  FBytes := 0;
  FLinhas := 0;
  FEstourou := False;
end;

procedure TCapturaSink.OnLine(AStreamId: TStreamId; const ALine: string);
var
  BytesOut: AnsiString;
begin
  if AStreamId = stOut then
  begin
    if FEstourou then
      Exit;                       // teto estourado: para de gravar
    BytesOut := CodificarSaida(ALine + #13#10, FCharset);
    if (FTeto > 0) and (FBytes + Int64(Length(BytesOut)) > FTeto) then
    begin
      FEstourou := True;
      if FRunner <> nil then
        FRunner.Cancel;           // para o processo (nao encher o disco)
      Exit;
    end;
    if (BytesOut <> '') and (FStream <> nil) then
      FStream.WriteBuffer(BytesOut[1], Length(BytesOut));
    Inc(FBytes, Int64(Length(BytesOut)));
    Inc(FLinhas);
  end
  else
  begin
    // stderr: retem (com teto) e roteia para o sink externo.
    if FErros <> nil then
      if FErros.Count < K_CAP_ERROS then
        FErros.Add(ALine);
    if FExt <> nil then
      FExt.OnLine(stErr, ALine);
  end;
end;

procedure TCapturaSink.OnProcessEvent(AEvent: TProcEvent;
  const AInfo: string);
begin
  if FExt <> nil then
    FExt.OnProcessEvent(AEvent, AInfo);
end;

// ------------------------------------------------------------------
// CapturarStdoutParaArquivo
// ------------------------------------------------------------------
function CapturarStdoutParaArquivo(Runner: IProcessRunner;
  const Opt: TCapturaOptions; Sink: IOutputSink;
  Erros: TStrings): TResultadoCaptura;
var
  R: IProcessRunner;
  ProcOpt: TProcessOptions;
  Res: TProcessResult;
  Stream: TFileStream;
  SinkObj: TCapturaSink;
  Intf: IOutputSink;
  CharsetCan: string;
begin
  Result.Ok := False;
  Result.Iniciou := False;
  Result.ExitCode := 0;
  Result.Cancelado := False;
  Result.Timeout := False;
  Result.EstourouTeto := False;
  Result.Linhas := 0;
  Result.Bytes := 0;
  Result.Erro := '';
  CharsetCan := NormalizarCharsetExport(Opt.Charset);
  if CharsetCan = '' then
    CharsetCan := 'ANSI';

  if Opt.Destino = '' then
  begin
    Result.Erro := 'Informe o arquivo de destino da captura.';
    Exit;
  end;
  if Opt.Executavel = '' then
  begin
    Result.Erro := 'Informe o executavel do subprocesso.';
    Exit;
  end;
  if not FileExists(Opt.Executavel) then
  begin
    Result.Erro := 'Executavel nao encontrado: ' + Opt.Executavel;
    Exit;
  end;

  if Runner <> nil then
    R := Runner
  else
    R := TProcessRunner.Create;
  Stream := nil;
  SinkObj := nil;
  try
    Stream := TFileStream.Create(Opt.Destino, fmCreate or fmShareDenyWrite);
    SinkObj := TCapturaSink.Create(Stream, CharsetCan, Opt.TetoBytes,
                                   R, Sink, Erros);
    ProcOpt.Executable := Opt.Executavel;
    ProcOpt.WorkDir := Opt.WorkDir;
    ProcOpt.Args := Opt.Args;
    ProcOpt.TimeoutMs := Opt.TimeoutMs;
    ProcOpt.KillTreeOnCancel := Opt.KillTree;
    ProcOpt.ConsoleCodePage := Opt.ConsoleCodePage;

    Intf := SinkObj;
    Res := R.Run(ProcOpt, Intf);
    // Le os dados do sink ENQUANTO a interface ainda o mantem vivo.
    Result.EstourouTeto := SinkObj.Estourou;
    Result.Linhas := SinkObj.Linhas;
    Result.Bytes := SinkObj.Bytes;
    Intf := nil;   // refcount 0: destrutor automatico do sink

    Result.Iniciou := Res.ErrorText = '';
    Result.ExitCode := Res.ExitCode;
    Result.Cancelado := Res.Canceled;
    Result.Timeout := Res.TimedOut;
    Result.Ok := Res.Ok and (not Result.EstourouTeto);
    if Result.Timeout then
      Result.Erro := 'Tempo limite excedido (timeout).'
    else if Result.EstourouTeto then
      Result.Erro := 'Teto de captura atingido; arquivo incompleto.'
    else if Res.ErrorText <> '' then
    begin
      Result.Erro := Res.ErrorText;
      Result.Iniciou := False;
    end;
  finally
    // SinkObj NAO recebe Free: e TInterfacedObject liberado quando a
    // interface Intf zera o refcount (Free duplo causaria Access
    // Violation). O stream e fechado depois do sink (uso terminou).
    Stream.Free;
  end;
end;

// ------------------------------------------------------------------
// TExportadorSQL
// ------------------------------------------------------------------
constructor TExportadorSQL.Create;
begin
  inherited Create;
  FCatalogo := nil;    // catalogo padrao da engine F1
end;

constructor TExportadorSQL.CreateComCatalogo(ACatalogo: ISwitchCatalog);
begin
  Create;
  if ACatalogo <> nil then
    FCatalogo := ACatalogo;
end;

function TExportadorSQL.FormatoAlvo: TFormatoExport;
begin
  Result := feSql;
end;

// ------------------------------------------------------------------
// Preparar: valida sem executar (4.3).
// ------------------------------------------------------------------
function TExportadorSQL.Preparar(const AParams: TExportParams;
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

  FDestino := DestinoUnico('sql');

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
// Executar: isql -extract com stdout capturado para o .sql.
// ------------------------------------------------------------------
function TExportadorSQL.Executar(Runner: IProcessRunner; Sink: IOutputSink;
  var Manifesto: TManifestoExport): Boolean;
var
  Catalogo: ISwitchCatalog;
  Argv: TStringArray;
  Msg: string;
  Opt: TCapturaOptions;
  Capt: TResultadoCaptura;
  Erros: TStringList;
  PreExistia: Boolean;
  Detalhe: string;
  NotaDados: string;
begin
  Result := False;
  if Manifesto = nil then
    Exit;
  if (not FPreparado) or (FParams = nil) then
  begin
    Manifesto.AddItem('', feSql, '', -1, xeFalha,
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
    Manifesto.AddItem('', feSql, '', -1, xeFalha, Msg);
    Exit;
  end;

  Erros := TStringList.Create;
  try
    Opt.Executavel := FParams.IsqlExe;
    Opt.WorkDir := '';
    Opt.Args := Argv;
    Opt.Destino := FDestino;
    Opt.Charset := FParams.CharsetSaida;
    Opt.TetoBytes := 0;            // extract legitimo pode ser grande
    Opt.TimeoutMs := FParams.TimeoutMs;
    Opt.KillTree := True;
    Opt.ConsoleCodePage := 0;

    PreExistia := FileExists(FDestino);
    Capt := CapturarStdoutParaArquivo(Runner, Opt, Sink, Erros);

    if Capt.Ok then
    begin
      NotaDados := '';
      if FParams.IncluirDados then
        NotaDados := '; incluir dados pedido - o -extract entrega DDL ' +
          '(dados exigem driver F5-T3; validar na F7)';
      Detalhe := 'isql -extract concluido (exit 0); linhas=' +
                 IntToStr(Capt.Linhas) + '; bytes=' + IntToStr(Capt.Bytes) +
                 NotaDados;
      Manifesto.AddItem(FDestino, feSql, '', Capt.Linhas, xeOk, Detalhe);
    end
    else
    begin
      if Erros.Count > 0 then
        Detalhe := Erros[0]
      else if Capt.Erro <> '' then
        Detalhe := Capt.Erro
      else
        Detalhe := 'isql terminou com codigo ' +
                   IntToStr(Integer(Capt.ExitCode)) + '.';
      Manifesto.AddItem(FDestino, feSql, '', -1, xeFalha, Detalhe);
      if (not PreExistia) and FileExists(FDestino) then
        SysUtils.DeleteFile(FDestino);   // sem arquivo parcial sujo
    end;
    Result := Capt.Ok;
  finally
    Erros.Free;
  end;
end;

end.