{
  uMotorAutoRec.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  Recuperacao AUTOMATICA (diagnostico -> escolha -> tecnicas
  combinadas -> relatorio). Construida sobre as engines existentes:

    * Passo 0 - DIAGNOSTICO estatico do arquivo (uDiagFileProbe):
      tipo (backup x banco), ODS, shutdown, formato do stream de
      backup. E a base da escolha da tecnica (nunca chutar).
    * Passo 1 - SONDAGEM dos engines detectados (gbak -z com timeout
      curto): so entra no plano um engine que RESPONDE. Engine
      incompativel com o formato (ex.: gbak InterBase antigo x backup
      Firebird formato 9) e descartado com aviso e instrucao.
    * Passo 2 - ESCOLHA + COMBINACAO de tecnicas (cascata, da menos
      para a mais agressiva; cada tecnica so roda se a anterior nao
      entregou um banco valido):
        backup (.fbk/.gbk):
          T1 restore limpo (-c -v)      -> valida (gfix -v)
          T2 restore tolerante (-c -ig) -> valida (gfix -v)
          T4 extrator de texto (L4)     -> ultima barreira (dump txt)
        banco (.fdb/.gdb):
          TMotorSalvage (L0 copia forense -> L1 gfix validar/mend ->
          L3 gbak do que abre -> L4 extrator) + contagem pos via isql
    * Passo 3 - VERIFICACAO do resultado: gfix -v no banco produzido e
      contagem real de tabelas/registros via isql (isql script
      temporario; nome unico; apagado ao final).
    * Passo 4 - RELATORIO detalhado (Problema/Solucao/Recuperado) com
      instrucoes do que fazer quando faltar algo (engine ausente/
      incompativel, driver de extracao L2, etc.). Salvo em arquivo .txt
      na pasta de trabalho.

  Regras herdadas: nunca tocar o ORIGINAL em acao de escrita (toda
  escrita ocorre em artefato/banco NOVO ou na copia forense - uSafeCopy
  via TMotorSalvage); chaves de utilitarios SOMENTE via catalogo
  (uFBSwitchCatalog); senha nunca em claro (uQuoting); processos com
  timeout e kill de arvore (uKernelExec); Delphi 7 puro, comentarios
  pt-BR ASCII, sem Forms.
  ------------------------------------------------------------------
}
unit uMotorAutoRec;

{$H+}

interface

uses
  SysUtils, Classes, Windows, uKernelExec, uEngineBase, uDiagFileProbe,
  uFBVersionInfo, uFBAutoDetect, uSalvagePlan;

type
  // Veredito global da recuperacao (honesto).
  TRecAutoResultado = (
    raNaoIniciada,     // pre-condicoes ausentes (origem/pasta)
    raCompleta,        // banco restaurado/validado com contagens
    raParcial,         // algo recuperado, mas com limitacao registrada
    raNada,            // nenhuma tecnica entregou dados aproveitaveis
    raSemEngine,       // nenhum engine funcional/compativel encontrado
    raCancelado        // cancelado pelo usuario
  );

  // Entrada do motor de recuperacao automatica.
  TRecAutoEntrada = record
    Origem: string;            // arquivo danificado (backup ou banco)
    Destino: string;           // caminho/nome FINAL do banco recuperado
                               // ('' = default <pasta>\recuperacao\...)
    PastaTrabalho: string;     // artefatos + relatorio (criada se falta)
    Usuario: string;           // -user opcional ('' = sem)
    Senha: string;             // -pass opcional (nunca em claro no log)
    TimeoutMs: DWORD;          // 0 = default interno (30 min)
    PermitirReparoMend: Boolean; // autoriza -mend NA COPIA (salvage)
    Bins: TBinSetArray;        // engines detectados (uFBAutoDetect)
    ExtratorMinimo: Integer;   // run minimo do extrator (0 = default)
  end;

  // Registro de um passo executado (tecnica + veredito + detalhe).
  TRecPasso = record
    Titulo: string;            // ex.: 'T1 - restore limpo (gbak -c -v)'
    Ok: Boolean;               // veredito do passo
    Detalhe: string;           // artefato/motivo
  end;

  // ------------------------------------------------------------------
  // Motor da recuperacao automatica. Uso:
  //   1. preencher TRecAutoEntrada (Bins via AutoDetectar);
  //   2. Executar -> veredito global (Passos/Relatorio preenchidos);
  //   3. SalvarRelatorio(ADestino) para gravar o .txt.
  // Nao usa Forms; rodar em worker thread (os subprocessos bloqueiam).
  // ------------------------------------------------------------------
  TMotorAutoRec = class
  private
    FEntrada: TRecAutoEntrada;
    FLog: ILogPasso;           // pode ser nil
    FCancelar: PBoolean;       // flag de outra thread (nil = sem)
    FRelatorio: TStringList;
    FPassos: array of TRecPasso;
    FArquivoFinal: string;     // banco recuperado ('' = nenhum)
    FResultado: TRecAutoResultado;
    FTimeoutPadrao: DWORD;     // resolveu do 0 da entrada

    procedure Logar(const ACanal, AMensagem: string);
    procedure LogarInfo(const AMensagem: string);
    procedure LogarErro(const AMensagem: string);
    function Cancelado: Boolean;
    function NomeBaseOrigem: string;
    function CaminhoArtefato(const AMeio, AExt: string): string;
    procedure Rel(const ALine: string);          // linha do relatorio
    procedure RelSecao(const ATitulo: string);
    procedure RegistrarPasso(const ATitulo, ADetalhe: string; AOk: Boolean);

    // Passo 0: diagnostico estatico (primeiro passo da escolha).
    function DiagnosticoEstatico(var R: TDiagResult): Boolean;
    // Passo 1: escolhe engine que responde ao probe gbak -z.
    function SondarEngine(var B: TBinSet; out AInfo: string): Boolean;
    // Passo 2: execucao das tecnicas por tipo de arquivo.
    procedure FluxoBackup(const D: TDiagResult);
    procedure FluxoBanco(const D: TDiagResult);
    // Tecnicas do fluxo backup.
    function TentarRestore(const AOrigemBackup, ADestinoBanco: string;
      ATolerante: Boolean; out AMsg: string): Boolean;
    function ValidarBanco(const ABanco: string; out AMsg: string): Boolean;
    function ContarBanco(const ABanco: string; out ATabelas: Integer;
      out ARegistros: Int64; out AMsg: string): Boolean;
    // Tecnica L4 (ultima barreira; leitura pura).
    procedure TecnicaExtratorTexto(const AAlvo: string);
    // Tecnica L2: datapump tabela a tabela via driver fbclient (extrai
    // o que der, pulando tabelas corrompidas). True = ao menos uma
    // tabela exportada (habilita a reconstrucao).
    function TecnicaDatapump(const ABanco: string): Boolean;
    // Tecnica L2b: reconstroi um banco NOVO a partir dos CSVs do
    // datapump (DDL real via isql -extract + INSERTs dos dados).
    procedure TecnicaReconstruir(const AOrigemDados: string);
    // Utilitario para rodar isql (script temporario).
    function RodarIsql(const AScript: TStrings; out ASaida: TStringList;
      out AMsg: string): Boolean;
    // Variante com captura de STDERR (erros do isql; nil = descartar).
    function RodarIsqlComErros(const AScript: TStrings; ADialeto: Integer;
      out ASaida, AErros: TStringList; out AMsg: string): Boolean;
    // Detecta o SQL dialect do banco (1 ou 3) via SHOW DATABASE.
    function DetectarDialeto(const ABanco: string): Integer;
    procedure EscreverSecaoOQueFaltou;
  public
    constructor Create(const AEntrada: TRecAutoEntrada; ALog: ILogPasso);
    destructor Destroy; override;

    procedure AtribuirCancelamento(ACancelar: PBoolean);
    function Executar: TRecAutoResultado;
    // Grava o relatorio em ADestino (True = sucesso).
    function SalvarRelatorio(const ADestino: string): Boolean;

    property Relatorio: TStringList read FRelatorio;
    // Passos executados (tecnica + veredito) - acessados por indice
    // (D7: propriedade nao pode ser array dinâmico).
    function NumPassos: Integer;
    function Passo(AIndex: Integer): TRecPasso;
    property ArquivoFinal: string read FArquivoFinal;
    property Resultado: TRecAutoResultado read FResultado;
  end;

// Texto pt-BR do veredito (relatorio/UI).
function RecAutoResultadoParaTexto(A: TRecAutoResultado): string;

implementation

uses
  uLogger, uQuoting, uTextCodec, uEngineGbak, uEngineGfix,
  uMotorSalvage, uExtratorTexto, uFBSwitchCatalog,
  uExportBase, uExportCSV, uDriverFBClient, uExportSQL;

// ------------------------------------------------------------------
// Constantes locais
// ------------------------------------------------------------------
const
  K_PROBE_TIMEOUT_MS = 10000;     // gbak -z (sonar o engine)
  K_TIMEOUT_DEFAULT_MS = 1800000; // 30 min por subprocesso quando 0
  K_EXT_DB = '.fdb';
  K_EXT_REL = '.txt';
  K_MAX_TABELAS_CONTAGEM = 600;   // teto defensivo de queries por isql

// Tamanho em bytes de um arquivo (0 em erro/ausente). Local para nao
// depender da GUI (uFrmMain tem o mesmo helper, em outra unit).
function FileSizeBytes(const ACaminho: string): Int64;
var
  H: Integer;
  Ok: Boolean;
begin
  Result := 0;
  H := FileOpen(ACaminho, fmOpenRead or fmShareDenyNone);
  if H < 0 then
    Exit;
  try
    Ok := FileSeek(H, 0, 2) >= 0;
    if Ok then
      Result := FileSeek(H, 0, 1);
  finally
    FileClose(H);
  end;
end;

// ------------------------------------------------------------------
// Sink ponte p/ cancelamento ao vivo: durante um subprocesso, cada
// linha de saida confere a flag e, acionada, chama Runner.Cancel
// (uKernelExec mata a arvore). Tambem coleta linhas quando FOut/FFErr
// sao informados (nil = descartar).
// ------------------------------------------------------------------
type
  TSinkPonteRec = class(TInterfacedObject, IOutputSink)
  private
    FFlagCancelar: PBoolean;
    FRunner: IProcessRunner;
    FOut, FErr: TStringList;
  public
    constructor Create(AFlag: PBoolean; ARunner: IProcessRunner;
      AOut, AErr: TStringList);
    procedure OnLine(AStream: TStreamId; const ALine: string);
    procedure OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
  end;

constructor TSinkPonteRec.Create(AFlag: PBoolean; ARunner: IProcessRunner;
  AOut, AErr: TStringList);
begin
  inherited Create;
  FFlagCancelar := AFlag;
  FRunner := ARunner;
  FOut := AOut;
  FErr := AErr;
end;

procedure TSinkPonteRec.OnLine(AStream: TStreamId; const ALine: string);
begin
  if (FFlagCancelar <> nil) and FFlagCancelar^ and (FRunner <> nil) then
    FRunner.Cancel;
  if AStream = stOut then
  begin
    if FOut <> nil then
      FOut.Add(ALine);
  end
  else if FErr <> nil then
    FErr.Add(ALine);
end;

procedure TSinkPonteRec.OnProcessEvent(AEvent: TProcEvent;
  const AInfo: string);
begin
  if (FFlagCancelar <> nil) and FFlagCancelar^ and (FRunner <> nil) then
    FRunner.Cancel;
end;

// ------------------------------------------------------------------
// RecAutoResultadoParaTexto
// ------------------------------------------------------------------
function RecAutoResultadoParaTexto(A: TRecAutoResultado): string;
begin
  case A of
    raNaoIniciada: Result := 'nao iniciada (faltam dados de entrada)';
    raCompleta:    Result := 'RECUPERACAO COMPLETA';
    raParcial:     Result := 'RECUPERACAO PARCIAL';
    raNada:        Result := 'nada foi recuperado';
    raSemEngine:   Result := 'sem engine de recuperacao disponivel';
    raCancelado:   Result := 'cancelada pelo usuario';
  else
    Result := 'desconhecido';
  end;
end;

// ------------------------------------------------------------------
// TMotorAutoRec - infra
// ------------------------------------------------------------------
constructor TMotorAutoRec.Create(const AEntrada: TRecAutoEntrada;
  ALog: ILogPasso);
begin
  inherited Create;
  FEntrada := AEntrada;
  FLog := ALog;
  FRelatorio := TStringList.Create;
  FPassos := nil;
  FArquivoFinal := '';
  FResultado := raNaoIniciada;
  FCancelar := nil;
  if FEntrada.TimeoutMs = 0 then
    FTimeoutPadrao := K_TIMEOUT_DEFAULT_MS
  else
    FTimeoutPadrao := FEntrada.TimeoutMs;
end;

destructor TMotorAutoRec.Destroy;
begin
  FLog := nil;
  FRelatorio.Free;
  FPassos := nil;
  inherited Destroy;
end;

procedure TMotorAutoRec.AtribuirCancelamento(ACancelar: PBoolean);
begin
  FCancelar := ACancelar;
end;

procedure TMotorAutoRec.Logar(const ACanal, AMensagem: string);
begin
  if FLog <> nil then
    FLog.Log(ACanal, AMensagem);
end;

procedure TMotorAutoRec.LogarInfo(const AMensagem: string);
begin
  Logar(LC_APP, AMensagem);
end;

procedure TMotorAutoRec.LogarErro(const AMensagem: string);
begin
  Logar(LC_APP, 'ERRO: ' + AMensagem);
end;

function TMotorAutoRec.Cancelado: Boolean;
begin
  Result := (FCancelar <> nil) and FCancelar^;
end;

function TMotorAutoRec.NomeBaseOrigem: string;
begin
  Result := ChangeFileExt(ExtractFileName(FEntrada.Origem), '');
end;

function TMotorAutoRec.CaminhoArtefato(const AMeio, AExt: string): string;
begin
  Result := FEntrada.PastaTrabalho;
  if Result = '' then
    Exit;
  if Result[Length(Result)] <> '\' then
    Result := Result + '\';
  Result := Result + NomeBaseOrigem + AMeio + AExt;
end;

procedure TMotorAutoRec.Rel(const ALine: string);
begin
  if ALine = '' then
  begin
    FRelatorio.Add('');
    Exit;
  end;
  // Anti-duplicata: nao repete a linha anterior identica.
  if (FRelatorio.Count > 0) and (FRelatorio[FRelatorio.Count - 1] = ALine) then
    Exit;
  // Trunca linhas de log muito longas (ex.: saida do gbak -v) para o
  // relatorio nao inchar - 120 chars bastam para leitura.
  if Length(ALine) > 120 then
    FRelatorio.Add(Copy(ALine, 1, 120) + '...')
  else
    FRelatorio.Add(ALine);
end;

procedure TMotorAutoRec.RelSecao(const ATitulo: string);
begin
  Rel('');
  Rel('================================================================');
  Rel(ATitulo);
  Rel('================================================================');
end;

procedure TMotorAutoRec.RegistrarPasso(const ATitulo, ADetalhe: string;
  AOk: Boolean);
var
  N: Integer;
  S: string;
begin
  N := Length(FPassos);
  SetLength(FPassos, N + 1);
  FPassos[N].Titulo := ATitulo;
  FPassos[N].Ok := AOk;
  FPassos[N].Detalhe := ADetalhe;
  // Timestamp de cada etapa (horario de fim).
  S := FormatDateTime('hh:nn:ss', Now);
  if AOk then
    Rel('  [' + S + '] [OK]     ' + ATitulo)
  else
    Rel('  [' + S + '] [FALHA]  ' + ATitulo);
  if ADetalhe <> '' then
    Rel('           ' + ADetalhe);
end;

function TMotorAutoRec.NumPassos: Integer;
begin
  Result := Length(FPassos);
end;

function TMotorAutoRec.Passo(AIndex: Integer): TRecPasso;
begin
  FillChar(Result, SizeOf(Result), 0);
  if (AIndex >= 0) and (AIndex < Length(FPassos)) then
    Result := FPassos[AIndex];
end;

// ------------------------------------------------------------------
// Passo 0 - diagnostico estatico (uDiagFileProbe)
// ------------------------------------------------------------------
function TMotorAutoRec.DiagnosticoEstatico(var R: TDiagResult): Boolean;
begin
  Result := False;
  FillChar(R, SizeOf(R), 0);
  Result := DiagnosticarArquivo(FEntrada.Origem, R);
  // Sempre registra no relatorio (mesmo quando DiagnosticarArquivo
  // devolve False - o motivo esta em R.Notes).
  Rel('Arquivo: ' + FEntrada.Origem);
  if R.FileSize > 0 then
    Rel('Tamanho: ' + Format('%d', [R.FileSize]) + ' bytes');
  Rel('Classificacao: ' + DiagKindParaTexto(R.FileKind) +
      ' (' + R.ClassificadoPor + ')');
  if R.FileKind = kDatabase then
  begin
    Rel('ODS: ' + IntToStr(R.OdsMaior) + '.' + IntToStr(R.OdsMenor) +
        ' | page size: ' + IntToStr(R.PageSize));
    if R.Shutdown then
      Rel('Estado: banco em SHUTDOWN (exige gfix -activate)');
  end
  else if R.FileKind = kBackup then
    if R.BackupFormatVer > 0 then
      Rel('Formato do backup: ' + IntToStr(R.BackupFormatVer) +
          ' (1..3 legado InterBase/FB1; >= 8 Firebird moderno)');
  if R.RecommendedTech <> '' then
    Rel('Tecnica sugerida pelo diagnostico: ' + R.RecommendedTech);
  if R.Notes <> '' then
    Rel('Notas do diagnostico:' + #13#10 + R.Notes);
end;

// ------------------------------------------------------------------
// Passo 1 - sondar um engine candidato (gbak -z com timeout curto).
// Um gbak que nao responde (dll ausente, servidor pendurado, binario
// quebrado) nunca entra no plano - e a causa da "trava" historica.
// ------------------------------------------------------------------
function TMotorAutoRec.SondarEngine(var B: TBinSet;
  out AInfo: string): Boolean;
var
  Opt: TProcessOptions;
  OutL, ErrL: TStringList;
  Res: TProcessResult;
  I: Integer;
  S: string;
  TemVersao: Boolean;
begin
  Result := False;
  AInfo := '';
  if not B.TemGbak then
  begin
    AInfo := 'conjunto sem gbak.exe';
    Exit;
  end;
  if not FileExists(B.CaminhoBin + 'gbak.exe') then
  begin
    AInfo := 'gbak.exe nao encontrado em ' + B.CaminhoBin;
    Exit;
  end;

  OutL := TStringList.Create;
  ErrL := TStringList.Create;
  try
    Opt.Executable := B.CaminhoBin + 'gbak.exe';
    Opt.WorkDir := '';
    Opt.Args := nil;
    Opt.TimeoutMs := K_PROBE_TIMEOUT_MS;
    Opt.KillTreeOnCancel := True;
    Opt.ConsoleCodePage := 0;
    Res := BuildAndRun(Opt, OutL, ErrL);
    // gbak -z imprime a versao e sai com codigo != 0 por falta de
    // operandos; o criterio e a SAIDA conter a versao (nao o exit).
    TemVersao := False;
    for I := 0 to OutL.Count - 1 do
    begin
      S := LowerCase(OutL[I]);
      if Pos('version', S) > 0 then
      begin
        TemVersao := True;
        // Prefere a linha da versao real (ex.: 'gbak:gbak version
        // WI-V2.5.9...') a linha de ajuda ('-Z print version number').
        if Pos('wi-v', S) > 0 then
          AInfo := Trim(OutL[I])
        else if AInfo = '' then
          AInfo := Trim(OutL[I]);
      end;
    end;
    for I := 0 to ErrL.Count - 1 do
    begin
      S := LowerCase(ErrL[I]);
      if Pos('version', S) > 0 then
      begin
        TemVersao := True;
        if Pos('wi-v', S) > 0 then
          AInfo := Trim(ErrL[I])
        else if AInfo = '' then
          AInfo := Trim(ErrL[I]);
      end;
    end;
    if TemVersao then
    begin
      Result := True;
      Exit;
    end;
    if Res.TimedOut then
      AInfo := 'gbak -z nao respondeu em ' +
               IntToStr(K_PROBE_TIMEOUT_MS div 1000) +
               's (engine pendurado/indisponivel)'
    else if Res.ErrorText <> '' then
      AInfo := Res.ErrorText
    else
    begin
      AInfo := 'gbak -z sem resposta util (saida sem versao)';
      if ErrL.Count > 0 then
        AInfo := AInfo + ': ' + Trim(ErrL[ErrL.Count - 1]);
    end;
  finally
    OutL.Free;
    ErrL.Free;
  end;
end;

// ------------------------------------------------------------------
// Tecnicas do fluxo backup
// ------------------------------------------------------------------

// Restore via gbak: ATolerante liga o -ig (ignora checksums ruins).
function TMotorAutoRec.TentarRestore(const AOrigemBackup,
  ADestinoBanco: string; ATolerante: Boolean; out AMsg: string): Boolean;
var
  Plano: TPlanoGbak;
  Motor: TMotorGbak;
  Runner: IProcessRunner;
  Ponte: TSinkPonteRec;
  Sink: IOutputSink;
  Res: TProcessResult;
  I: Integer;
begin
  AMsg := '';
  Result := False;
  // Artefato proprio (pasta recuperacao_<base>): descarta restos de
  // execucao anterior para o modo -c recriar limpo (o motor gbak
  // recusa destino existente em mgRestoreCriar).
  if FileExists(ADestinoBanco) then
    SysUtils.DeleteFile(ADestinoBanco);
  Runner := TProcessRunner.Create;
  try
    Plano := TPlanoGbak.Create;
    Motor := TMotorGbak.Create(FLog);
    try
      Plano.GbakExe := FEntrada.Bins[0].CaminhoBin + 'gbak.exe';
      Plano.VersaoGbak := FEntrada.Bins[0].Versao;
      Plano.Origem := AOrigemBackup;
      Plano.Destino := ADestinoBanco;
      Plano.Modo := mgRestoreCriar;
      Plano.Sobrescrever := False; // destino sempre novo (nome unico)
      Plano.Usuario := FEntrada.Usuario;
      Plano.Senha := FEntrada.Senha;
      Plano.Verboso := True;
      Plano.NoGC := True;
      Plano.IgnorarChecksum := ATolerante;
      Plano.TimeoutMs := FTimeoutPadrao;
      Motor.AtribuirPlano(Plano);
      Ponte := TSinkPonteRec.Create(FCancelar, Runner, nil, nil);
      Sink := Ponte;
      Res := Motor.Executar(Runner, Sink);
      Sink := nil;
      if Res.Ok and FileExists(ADestinoBanco) then
      begin
        Result := True;
        AMsg := 'banco criado: ' + ADestinoBanco + ' (' +
                Format('%d', [FileSizeBytes(ADestinoBanco)]) + ' bytes)';
      end
      else
      begin
        AMsg := Motor.Resumo.MensagemErro;
        if AMsg = '' then
          AMsg := Res.ErrorText;
        // Sem meio-restore: apaga o parcial que o gbak deixou.
        if FileExists(ADestinoBanco) then
          SysUtils.DeleteFile(ADestinoBanco);
        // Guarda ate 3 linhas de saida do gbak para o relatorio.
        for I := 0 to Motor.Avisos.Count - 1 do
          LogarInfo('gbak aviso: ' + Motor.Avisos[I]);
      end;
    finally
      Motor.Free;
      Plano.Free;
    end;
  finally
    Runner := nil;
  end;
end;

function TMotorAutoRec.ValidarBanco(const ABanco: string;
  out AMsg: string): Boolean;
var
  Plano: TPlanoGfix;
  Motor: TMotorGfix;
  Runner: IProcessRunner;
  Ponte: TSinkPonteRec;
  Sink: IOutputSink;
  Res: TProcessResult;
begin
  AMsg := '';
  Result := False;
  Runner := TProcessRunner.Create;
  try
    Plano := TPlanoGfix.Create;
    Motor := TMotorGfix.Create(FLog);
    try
      Plano.GfixExe := FEntrada.Bins[0].CaminhoBin + 'gfix.exe';
      Plano.VersaoGfix := FEntrada.Bins[0].Versao;
      Plano.Banco := ABanco;
      Plano.Acao := gaValidar; // read-only
      Plano.Usuario := FEntrada.Usuario;
      Plano.Senha := FEntrada.Senha;
      Plano.TimeoutMs := FTimeoutPadrao;
      Motor.AtribuirPlano(Plano);
      Ponte := TSinkPonteRec.Create(FCancelar, Runner, nil, nil);
      Sink := Ponte;
      Res := Motor.Executar(Runner, Sink);
      Sink := nil;
      if Res.Ok then
      begin
        Result := True;
        AMsg := 'gfix -v concluido (exit 0)';
      end
      else
      begin
        AMsg := Motor.Resumo.MensagemErro;
        if AMsg = '' then
          AMsg := Res.ErrorText;
      end;
    finally
      Motor.Free;
      Plano.Free;
    end;
  finally
    Runner := nil;
  end;
end;

// Conta tabelas e registros do banco via isql (script temporario).
function TMotorAutoRec.RodarIsql(const AScript: TStrings;
  out ASaida: TStringList; out AMsg: string): Boolean;
var
  Err: TStringList;
begin
  Err := nil;
  Result := RodarIsqlComErros(AScript, 3, ASaida, Err, AMsg);
  Err.Free;
end;

function TMotorAutoRec.DetectarDialeto(const ABanco: string): Integer;
var
  Script, Saida, Er: TStringList;
  Msg: string;
  I: Integer;
begin
  Result := 3;
  Script := TStringList.Create;
  Saida := nil;
  Er := nil;
  try
    Script.Add('CONNECT ''' +
      StringReplace(ABanco, '''', '''''', [rfReplaceAll]) +
      ''' USER ''SYSDBA'' PASSWORD ''x'';');
    Script.Add('SHOW DATABASE;');
    Script.Add('EXIT;');
    if RodarIsqlComErros(Script, 3, Saida, Er, Msg) and (Saida <> nil) then
      for I := 0 to Saida.Count - 1 do
        if Pos('dialect 1', LowerCase(Saida[I])) > 0 then
        begin
          Result := 1;
          Break;
        end;
  finally
    Er.Free;
    Saida.Free;
    Script.Free;
  end;
end;

function TMotorAutoRec.RodarIsqlComErros(const AScript: TStrings;
  ADialeto: Integer; out ASaida, AErros: TStringList;
  out AMsg: string): Boolean;
var
  Opt: TProcessOptions;
  Res: TProcessResult;
  ArquivoScript: string;
  I, K: Integer;
  Args: array[0..9] of string;
begin
  Result := False;
  AMsg := '';
  ASaida := nil;
  AErros := nil;
  if (Length(FEntrada.Bins) = 0) or (not FEntrada.Bins[0].TemIsql) then
  begin
    AMsg := 'engine selecionado sem isql.exe';
    Exit;
  end;
  if not FileExists(FEntrada.Bins[0].CaminhoBin + 'isql.exe') then
  begin
    AMsg := 'isql.exe nao encontrado em ' + FEntrada.Bins[0].CaminhoBin;
    Exit;
  end;
  if FEntrada.PastaTrabalho = '' then
  begin
    AMsg := 'pasta de trabalho vazia (impossivel criar script isql)';
    Exit;
  end;

  ArquivoScript := CaminhoArtefato('.isql', '.sql');
  try
    AScript.SaveToFile(ArquivoScript);
  except
    on E: Exception do
    begin
      AMsg := 'nao foi possivel gravar o script isql: ' + E.Message;
      Exit;
    end;
  end;

  K := 0;
  if FEntrada.Usuario <> '' then
  begin
    Args[K] := '-user'; Inc(K);
    Args[K] := FEntrada.Usuario; Inc(K);
  end;
  if FEntrada.Senha <> '' then
  begin
    Args[K] := '-pass'; Inc(K);
    Args[K] := FEntrada.Senha; Inc(K);
  end;
  // Dialeto do banco: o isql -extract gera DDL fiel ao dialeto do
  // ORIGINAL (bancos legados sao dialeto 1 - concatenacao com '+',
  // que falha em banco dialeto 3). Criar/aplicar com o MESMO dialeto.
  if (ADialeto = 1) or (ADialeto = 3) then
  begin
    Args[K] := '-s'; Inc(K);
    Args[K] := IntToStr(ADialeto); Inc(K);
  end;
  Args[K] := '-i'; Inc(K);
  Args[K] := ArquivoScript; Inc(K);

  Opt.Executable := FEntrada.Bins[0].CaminhoBin + 'isql.exe';
  Opt.WorkDir := '';
  SetLength(Opt.Args, K);
  for I := 0 to K - 1 do
    Opt.Args[I] := Args[I];
  Opt.TimeoutMs := FTimeoutPadrao;
  Opt.KillTreeOnCancel := True;
  Opt.ConsoleCodePage := 0;

  ASaida := TStringList.Create;
  AErros := TStringList.Create;
  try
    Res := BuildAndRun(Opt, ASaida, AErros);
    if Res.Ok then
      Result := True
    else
    begin
      AMsg := 'isql terminou com codigo ' +
              IntToStr(Integer(Res.ExitCode)) + '.';
      if Res.TimedOut then
        AMsg := 'isql excedeu o tempo limite.';
      if Res.ErrorText <> '' then
        AMsg := AMsg + ' ' + Res.ErrorText;
    end;
  finally
    // Script mantido na pasta de trabalho como artefato de auditoria
    // (nome fixo por origem; sobrescrito na proxima execucao).
    LogarInfo('script isql: ' + ArquivoScript);
  end;
end;

function TMotorAutoRec.ContarBanco(const ABanco: string;
  out ATabelas: Integer; out ARegistros: Int64;
  out AMsg: string): Boolean;
var
  Script: TStringList;
  Saida: TStringList;
  Linha, Token: string;
  Nomes: array of string;
  I, J, P: Integer;
  S: string;
  Up: Char;
  NomeOk: Boolean;
  Vez: Integer;
begin
  ATabelas := 0;
  ARegistros := 0;
  Result := False;
  Script := TStringList.Create;
  Saida := nil;
  try
    // 1) lista as tabelas (sem views) via rdb$relations.
    Script.Add('CONNECT ''' + StringReplace(ABanco, '''', '''''', [rfReplaceAll]) +
               ''' USER ''SYSDBA'' PASSWORD ''x'';');
    Script.Add('SET LIST ON;');
    Script.Add('SELECT RDB$RELATION_NAME FROM RDB$RELATIONS WHERE ' +
               'RDB$SYSTEM_FLAG = 0 AND RDB$VIEW_BLR IS NULL;');
    Script.Add('EXIT;');
    if not RodarIsql(Script, Saida, AMsg) then
    begin
      if AMsg = '' then
        AMsg := 'falha ao listar tabelas';
      Exit;
    end;
    SetLength(Nomes, 0);
    for I := 0 to Saida.Count - 1 do
    begin
      Linha := Trim(Saida[I]);
      P := Pos('RDB$RELATION_NAME', UpperCase(Linha));
      if P <= 0 then
        Continue;
      Token := Trim(Copy(Linha, P + 17, MaxInt)); // 'RDB$RELATION_NAME'=17
      if Token = '' then
        Continue;
      // Aceita somente identificadores simples (defensivo).
      NomeOk := True;
      for J := 1 to Length(Token) do
      begin
        Up := UpCase(Token[J]);
        if not (Up in ['A'..'Z', '0'..'9', '_', '$']) then
        begin
          NomeOk := False;
          Break;
        end;
      end;
      if NomeOk and (Length(Token) > 0) and
         (Length(Nomes) < K_MAX_TABELAS_CONTAGEM) then
      begin
        SetLength(Nomes, Length(Nomes) + 1);
        Nomes[Length(Nomes) - 1] := Token;
      end;
    end;
    if Length(Nomes) = 0 then
    begin
      // Diagnostico: mostra o que o isql devolveu (parse nao casou).
      for I := 0 to Saida.Count - 1 do
        if I < 15 then
          Rel('  [isql] ' + Saida[I]);
      AMsg := 'nenhuma tabela listada pelo isql (banco abriu, mas sem ' +
              'tabelas de usuario?)';
      Exit;
    end;

    // 2) conta os registros de cada tabela em um unico script.
    Script.Clear;
    Script.Add('CONNECT ''' + StringReplace(ABanco, '''', '''''', [rfReplaceAll]) +
               ''' USER ''SYSDBA'' PASSWORD ''x'';');
    Script.Add('SET LIST ON;');
    for I := 0 to Length(Nomes) - 1 do
      Script.Add('SELECT COUNT(*) FROM ' + Nomes[I] + ';');
    Script.Add('EXIT;');
    Saida.Free;
    Saida := nil;
    if not RodarIsql(Script, Saida, AMsg) then
    begin
      if AMsg = '' then
        AMsg := 'falha ao contar registros';
      Exit;
    end;
    Vez := 0;
    for I := 0 to Saida.Count - 1 do
    begin
      Linha := Trim(Saida[I]);
      if Pos('COUNT', UpperCase(Linha)) <> 1 then
        Continue;
      Token := Trim(Copy(Linha, 6, MaxInt));
      if Token = '' then
        Continue;
      S := '';
      for J := 1 to Length(Token) do
        if Token[J] in ['0'..'9'] then
          S := S + Token[J];
      if S = '' then
        Continue;
      if Vez < Length(Nomes) then
        Inc(ATabelas);
      ARegistros := ARegistros + StrToInt64Def(S, 0);
      Inc(Vez);
    end;
    if ATabelas > 0 then
      Result := True
    else
      AMsg := 'nenhuma contagem obtida (saida do isql inesperada)';
  finally
    Saida.Free;
    Script.Free;
  end;
end;

// ------------------------------------------------------------------
// Tecnica L4 - extrator de texto (ultima barreira; leitura pura).
// ------------------------------------------------------------------
procedure TMotorAutoRec.TecnicaExtratorTexto(const AAlvo: string);
var
  Opcoes: TExtracaoTextoOpcoes;
  Status: TExtracaoStatus;
  Runs: Integer;
  BytesLidos: Int64;
  Dump: string;
begin
  Dump := CaminhoArtefato('.texto', '.txt');
  FillChar(Opcoes, SizeOf(Opcoes), 0);
  Opcoes.ArquivoOrigem := AAlvo;
  Opcoes.ArquivoSaida := Dump;
  Opcoes.ComprimentoMinimo := FEntrada.ExtratorMinimo;
  Opcoes.TetoBytes := 0;
  Opcoes.BlocoBytes := 0;
  Rel('Tecnica L4 - extrator de texto (read-only) sobre: ' + AAlvo);
  Status := ExtrairRunsDeTexto(Opcoes, nil, FCancelar, Runs, BytesLidos);
  if (Status = etSucesso) or (Status = etTetoAtingido) then
  begin
    Rel('  [OK]     extrator de texto');
    Rel('           runs: ' + IntToStr(Runs) + '; bytes lidos: ' +
        Format('%d', [BytesLidos]) + '; dump: ' + Dump);
    RegistrarPasso('T4 - extrator de texto (L4)',
      'dump em ' + Dump + ' (' + IntToStr(Runs) + ' runs)', True);
  end
  else
  begin
    RegistrarPasso('T4 - extrator de texto (L4)',
      ExtracaoStatusParaTexto(Status), False);
  end;
end;

// ------------------------------------------------------------------
// Tecnica L2 - datapump tabela a tabela (driver fbclient): abre o
// banco com o driver real e exporta cada tabela para .csv, pulando as
// que falharem. Usa o TExportadorCSV + uDriverFBClient (validados no
// TestDriverFB). Retorna True quando ao menos uma tabela foi
// exportada (habilita a reconstrucao L2b).
// ------------------------------------------------------------------
function TMotorAutoRec.TecnicaDatapump(const ABanco: string): Boolean;
var
  DllDir: string;
  Drv: IDriverFBConsulta;
  Msg: string;
  Tabelas: TStringList;
  I: Integer;
  Ex: TExportadorCSV;
  P: TExportParams;
  M: TManifestoExport;
  Item: TItemManifesto;
  OkT, OkComDados, Falhas: Integer;
  SomaLinhas: Int64;
  Resumo: string;
begin
  Result := False;
  Rel('Tecnica L2 - datapump tabela a tabela (driver fbclient) sobre: ' +
      ABanco);
  if Length(FEntrada.Bins) = 0 then
  begin
    RegistrarPasso('L2 - datapump tabela a tabela', 'sem engine', False);
    Exit;
  end;
  DllDir := FEntrada.Bins[0].CaminhoBin;
  if not FileExists(DllDir + 'fbclient.dll') then
  begin
    RegistrarPasso('L2 - datapump tabela a tabela',
      'fbclient.dll nao encontrado em ' + DllDir +
      ' (instale o motor embarcado ou Firebird)', False);
    Exit;
  end;
  Drv := CriarDriverFBClient(DllDir, ABanco, Msg);
  if Drv = nil then
  begin
    RegistrarPasso('L2 - datapump tabela a tabela', Msg, False);
    Exit;
  end;

  Tabelas := TStringList.Create;
  M := TManifestoExport.Create;
  Ex := nil;
  P := nil;
  try
    if not Drv.ListarTabelas(Tabelas, Msg) then
    begin
      RegistrarPasso('L2 - datapump tabela a tabela',
        'falha ao listar tabelas: ' + Msg, False);
      Exit;
    end;
    Ex := TExportadorCSV.CreateComDriver(Drv);
    P := TExportParams.Create;
    P.Origem := ABanco;
    P.PastaDestino := FEntrada.PastaTrabalho;
    P.ArquivoBase := NomeBaseOrigem;
    P.Sobrescrever := True;
    P.CharsetSaida := 'ANSI';
    P.Delimitador := ';';
    P.IncluirBlob := True;
    P.BlobComo := beHex;
    SetLength(P.TabelasAlvo, Tabelas.Count);
    for I := 0 to Tabelas.Count - 1 do
      P.TabelasAlvo[I] := Tabelas[I];
    if not Ex.Preparar(P, Msg) then
    begin
      RegistrarPasso('L2 - datapump tabela a tabela',
        'falha ao preparar exportacao: ' + Msg, False);
      Exit;
    end;
    if not Ex.Executar(nil, nil, M) then
      Rel('  [INFO]   houve falhas parciais na extracao (detalhes abaixo).');

    OkT := 0;
    OkComDados := 0;
    Falhas := 0;
    SomaLinhas := 0;
    for I := 0 to M.Count - 1 do
    begin
      Item := M.Itens[I];
      if Item.Status = xeOk then
      begin
        Inc(OkT);
        if Item.Linhas > 0 then
          Inc(OkComDados);
        SomaLinhas := SomaLinhas + Item.Linhas;
      end
      else
      begin
        Inc(Falhas);
        if Falhas <= 10 then
          Rel('  [FALHA]  tabela ' + Item.Tabela + ': ' + Item.Detalhe);
      end;
    end;
    Resumo := IntToStr(OkT) + ' de ' + IntToStr(M.Count) +
              ' tabelas exportadas (' + Format('%d', [SomaLinhas]) +
              ' registros; CSVs em ' + FEntrada.PastaTrabalho + ')';
    if Falhas > 0 then
      Resumo := Resumo + '; ' + IntToStr(Falhas) +
                ' tabela(s) pulada(s) (corrompidas/ilegiveis)';
    RegistrarPasso('L2 - datapump tabela a tabela (driver fbclient)',
      Resumo, OkT > 0);
    Result := OkT > 0;
  finally
    P.Free;
    Ex.Free;
    M.Free;
    Tabelas.Free;
  end;
end;

// ------------------------------------------------------------------
// Tecnica L2b - reconstrucao do banco a partir dos dados exportados:
//  1) DDL REAL do banco original via isql -extract (uExportSQL);
//  2) banco novo vazio (isql CREATE DATABASE);
//  3) aplica o DDL no banco novo;
//  4) importa os CSVs do datapump como INSERTs (isql);
//  5) valida o banco reconstruido (gfix/isql: tabelas e registros).
// Limites honestos (v1): campo vazio no CSV vira NULL; BLOBs entram
// como texto (hex); valide o resultado antes de uso em producao.
// ------------------------------------------------------------------
procedure TMotorAutoRec.TecnicaReconstruir(const AOrigemDados: string);
var
  NovoBanco, DdlArq, Pasta, Msg, Linha, Nome, V, Col: string;
  Script, Saida, Erros, ErrosIsql, Linhas: TStringList;
  Catalogo: ISwitchCatalog;
  Argv: TStringArray;
  Opt: TCapturaOptions;
  Res: TResultadoCaptura;
  Runner: IProcessRunner;
  I, J, N, TabelasNovo, TotalIns, Flush: Integer;
  RegNovo: Int64;
  OkCria, OkDdl, OkIns, OkVal: Boolean;
  Achou: Boolean;
  Dialeto: Integer;
  SR: TSearchRec;
  Base, NomeTab, ExtArq: string;
  Campos, Valores: TStringList;
  LinhaIns: string;

  // Quebra uma linha CSV (delimitador ';', aspas RFC-4180 com "").
  procedure QuebrarCsv(const S: string; ADest: TStringList);
  var
    P, Inicio: Integer;
    EntreAspas: Boolean;
    C: Char;
  begin
    ADest.Clear;
    P := 1;
    Inicio := 1;
    EntreAspas := False;
    while P <= Length(S) do
    begin
      C := S[P];
      if EntreAspas then
      begin
        if C = '"' then
          if (P < Length(S)) and (S[P + 1] = '"') then
            Inc(P)   // aspas duplicadas = aspa literal
          else
            EntreAspas := False
      end
      else if C = '"' then
        EntreAspas := True
      else if C = ';' then
      begin
        ADest.Add(Copy(S, Inicio, P - Inicio));
        Inicio := P + 1;
      end;
      Inc(P);
    end;
    ADest.Add(Copy(S, Inicio, MaxInt));
  end;

  // Valor do CSV -> literal SQL.
  function ValorParaInsert(const AV: string): string;
  var
    K: Integer;
    Num: Boolean;
  begin
    if AV = '' then
    begin
      Result := 'NULL';
      Exit;
    end;
    Num := True;
    K := 1;
    if (AV[1] = '-') or (AV[1] = '+') then
      K := 2;
    for K := K to Length(AV) do
      if not (AV[K] in ['0'..'9', '.']) then
      begin
        Num := False;
        Break;
      end;
    if Num then
      Result := AV
    else
    begin
      Result := '''' + StringReplace(AV, '''', '''''', [rfReplaceAll]) + '''';
    end;
  end;

begin
  NovoBanco := CaminhoArtefato('_reconstruido', K_EXT_DB);
  if FEntrada.Destino <> '' then
    NovoBanco := ChangeFileExt(FEntrada.Destino, '') + '_reconstruido.fdb';
  Rel('Tecnica L2b - reconstruindo banco novo a partir dos dados exportados');
  Rel('Banco reconstruido: ' + NovoBanco);
  // O banco novo precisa do MESMO dialeto do original (DDL fiel).
  Dialeto := DetectarDialeto(AOrigemDados);
  Rel('Dialeto do banco original: ' + IntToStr(Dialeto));
  if FileExists(NovoBanco) then
    SysUtils.DeleteFile(NovoBanco);

  // (1) DDL real do original (isql -extract).
  DdlArq := CaminhoArtefato('_ddl', '.sql');
  Erros := TStringList.Create;
  Runner := TProcessRunner.Create;
  try
    Catalogo := CriarCatalogPadrao;
    MontarArgvIsqlExtract(FEntrada.Usuario, FEntrada.Senha, '',
      AOrigemDados, Catalogo, FEntrada.Bins[0].Versao, Argv, Msg);
    if Msg = '' then
    begin
      Opt.Executavel := FEntrada.Bins[0].CaminhoBin + 'isql.exe';
      Opt.WorkDir := '';
      Opt.Args := Argv;
      Opt.Destino := DdlArq;
      Opt.Charset := '';
      Opt.TetoBytes := 0;
      Opt.TimeoutMs := FTimeoutPadrao;
      Opt.KillTree := True;
      Opt.ConsoleCodePage := 0;
      Res := CapturarStdoutParaArquivo(Runner, Opt, nil, Erros);
      if not (Res.Ok and FileExists(DdlArq)) then
      begin
        RegistrarPasso('L2b - reconstrucao (DDL isql -extract)',
          'falhou ao extrair o DDL: ' + Res.Erro, False);
        Exit;
      end;
    end
    else
    begin
      RegistrarPasso('L2b - reconstrucao (DDL isql -extract)',
        'falha ao montar o isql: ' + Msg, False);
      Exit;
    end;
  finally
    Runner := nil;
    Erros.Free;
  end;

  // (2) Cria o banco novo vazio.
  Script := TStringList.Create;
  Saida := nil;
  ErrosIsql := nil;
  try
    Script.Add('CREATE DATABASE ''' +
      StringReplace(NovoBanco, '''', '''''', [rfReplaceAll]) +
      ''' USER ''SYSDBA'' PASSWORD ''x'';');
    Script.Add('EXIT;');
    OkCria := RodarIsqlComErros(Script, Dialeto, Saida, ErrosIsql, Msg);
    ErrosIsql.Free;
    ErrosIsql := nil;
    Saida.Free;
    Saida := nil;
    if not (OkCria and FileExists(NovoBanco)) then
    begin
      RegistrarPasso('L2b - criacao do banco novo', Msg, False);
      Exit;
    end;
    Rel('  [OK]     banco novo criado: ' + NovoBanco);

    // (3) Aplica o DDL no banco novo.
    Script.Clear;
    if FileExists(DdlArq) then
      Script.LoadFromFile(DdlArq);
    // O isql -extract comeca com cabecalho (SET NAMES/CONNECT do banco
    // ORIGINAL). Remove o cabecalho e aplica o nosso: dialeto 3 +
    // CONNECT para o banco NOVO (senao o DDL roda contra o original
    // ou com dialeto 1, e o isql novo dos INSERTs fica desconectado).
    OkDdl := False;
    I := 0;
    while I < Script.Count do
    begin
      if Copy(Trim(UpperCase(Script[I])), 1, 9) = 'SET NAMES' then
        Script.Delete(I)
      else if Copy(Trim(UpperCase(Script[I])), 1, 16) = 'SET SQL DIALECT' then
        Script.Delete(I)
      else if Copy(Trim(UpperCase(Script[I])), 1, 8) = 'CONNECT ' then
        Script.Delete(I)
      else if Copy(Trim(UpperCase(Script[I])), 1, 11) = 'SET AUTODDL' then
        Script.Delete(I)
      else if Trim(UpperCase(Script[I])) = 'COMMIT WORK;' then
        Script.Delete(I)
      else
        Inc(I);
    end;
    Script.Insert(0, 'COMMIT WORK;');
    Script.Insert(0, 'SET AUTODDL ON;');
    Script.Insert(0, 'CONNECT ''' +
      StringReplace(NovoBanco, '''', '''''', [rfReplaceAll]) +
      ''' USER ''SYSDBA'' PASSWORD ''x'';');
    Script.Insert(0, 'SET SQL DIALECT ' + IntToStr(Dialeto) + ';');
    Script.Insert(0, 'SET NAMES WIN1252;');
    // REPARO do DDL (isql -extract): numeros largos em CHECK saem
    // corrompidos ('+999****9999.99' - sintaxe invalida). Remove o
    // CHECK do dominio afetado, mantendo o tipo (dominio valido).
    I := 0;
    while I < Script.Count do
    begin
      if Copy(Trim(UpperCase(Script[I])), 1, 13) = 'CREATE DOMAIN' then
      begin
        J := I;
        Achou := False;
        while J < Script.Count do
        begin
          if Pos('****', Script[J]) > 0 then
          begin
            Achou := True;
            Break;
          end;
          if (Pos(';', Script[J]) > 0) and (J > I) then
            Break;   // dominio normal terminou sem asterisco
          Inc(J);
        end;
        if Achou then
        begin
          // Reconstrói: "CREATE DOMAIN <nome> AS <tipo>;"
          Linha := Script[I];
          V := Copy(Linha, 14, MaxInt);   // <nome> AS <tipo>...
          Nome := Trim(Copy(V, 1, Pos(' AS ', V) - 1));
          Col := Trim(Copy(V, Pos(' AS ', V) + 4, MaxInt));
          // Remove eventual 'CHECK' e o que segue.
          if Pos('CHECK', Col) > 0 then
            Col := Trim(Copy(Col, 1, Pos('CHECK', Col) - 1));
          if Col = '' then
            Col := 'VARCHAR(100)';   // fallback defensivo
          LinhaIns := 'CREATE DOMAIN ' + Nome + ' AS ' + Col + ';';
          while J >= I do
          begin
            Script.Delete(J);
            Dec(J);
          end;
          Script.Insert(I, LinhaIns);
        end;
      end;
      Inc(I);
    end;
    if Script.Count > 0 then
    begin
      OkDdl := RodarIsqlComErros(Script, Dialeto, Saida, ErrosIsql, Msg);
      if not OkDdl then
      begin
        Rel('  [AVISO]  DDL com erros parciais (o banco novo nao tem ' +
            'usuarios/papeis do original, ex.: GRANT):');
        if Saida <> nil then
          for I := 0 to Saida.Count - 1 do
            if I < 8 then
              Rel('           [isql] ' + Saida[I])
            else
              Break;
        if ErrosIsql <> nil then
          for I := 0 to ErrosIsql.Count - 1 do
            if I < 10 then
              Rel('           [erro] ' + ErrosIsql[I])
            else
              Break;
      end;
      ErrosIsql.Free;
      ErrosIsql := nil;
      Saida.Free;
      Saida := nil;
    end;
    if OkDdl then
      Rel('  [OK]     DDL aplicado (estrutura recriada).')
    else
      Rel('  [INFO]   DDL aplicado com avisos; a validacao ao final decide.');

    // (4) Importa os CSVs do datapump como INSERTs (isql em lote).
    Linhas := TStringList.Create;
    Campos := TStringList.Create;
    Valores := TStringList.Create;
    TotalIns := 0;
    Flush := 0;
    // Conexao do script de INSERTs: dialeto 3 + banco novo.
    Linhas.Add('SET NAMES WIN1252;');
    Linhas.Add('SET SQL DIALECT ' + IntToStr(Dialeto) + ';');
    Linhas.Add('CONNECT ''' +
      StringReplace(NovoBanco, '''', '''''', [rfReplaceAll]) +
      ''' USER ''SYSDBA'' PASSWORD ''x'';');
    Linhas.Add('COMMIT WORK;');
    Pasta := FEntrada.PastaTrabalho;
    Base := NomeBaseOrigem + '.';
    try
      if FindFirst(Pasta + '\*.csv', faAnyFile, SR) = 0 then
      try
        repeat
          ExtArq := ExtractFileName(SR.Name);
          if Copy(ExtArq, 1, Length(Base)) <> Base then
            Continue;
          NomeTab := Copy(ExtArq, Length(Base) + 1,
                         Length(ExtArq) - Length(Base) - 4);
          if NomeTab = '' then
            Continue;
          Script.Clear;
          Script.LoadFromFile(Pasta + '\' + ExtArq);
          if Script.Count < 2 then
            Continue;   // so cabecalho (tabela vazia)
          QuebrarCsv(Script[0], Campos);   // nomes das colunas
          // Lista de colunas: em dialeto 1 aspas duplas sao STRING
          // (nao identificador) - usar nomes puros; em dialeto 3 usa
          // aspas duplas.
          Col := '';
          for J := 0 to Campos.Count - 1 do
          begin
            if Col <> '' then
              Col := Col + ', ';
            if Dialeto = 1 then
              Col := Col + Campos[J]
            else
              Col := Col + '"' + StringReplace(Campos[J], '"', '""',
                    [rfReplaceAll]) + '"';
          end;
          for I := 1 to Script.Count - 1 do
          begin
            if Trim(Script[I]) = '' then
              Continue;
            QuebrarCsv(Script[I], Valores);
            V := '';
            for J := 0 to Valores.Count - 1 do
            begin
              if V <> '' then
                V := V + ', ';
              V := V + ValorParaInsert(Valores[J]);
            end;
            if Dialeto = 1 then
              LinhaIns := 'INSERT INTO ' + NomeTab + ' (' +
                Col + ') VALUES (' + V + ');'
            else
              LinhaIns := 'INSERT INTO "' +
                StringReplace(NomeTab, '"', '""', [rfReplaceAll]) + '" (' +
                Col + ') VALUES (' + V + ');';
            Linhas.Add(LinhaIns);
            Inc(TotalIns);
            Inc(Flush);
            if Flush >= 400 then
            begin
              Linhas.Add('COMMIT;');
              Flush := 0;
            end;
          end;
        until FindNext(SR) <> 0;
      finally
        SysUtils.FindClose(SR);
      end;

      if TotalIns > 0 then
      begin
        Linhas.Add('COMMIT;');
        Linhas.Add('EXIT;');
        OkIns := RodarIsqlComErros(Linhas, Dialeto, Saida, ErrosIsql, Msg);
        Saida.Free;
        Saida := nil;
        if not OkIns then
        begin
          Rel('  [AVISO]  importacao com erros parciais (os dados ficam ' +
              'preservados nos CSVs do datapump):');
          if Saida <> nil then
            for I := 0 to Saida.Count - 1 do
              if I < 8 then
                Rel('           [isql] ' + Saida[I])
              else
                Break;
          if ErrosIsql <> nil then
            for I := 0 to ErrosIsql.Count - 1 do
              if I < 10 then
                Rel('           [erro] ' + ErrosIsql[I])
              else
                Break;
        end;
        ErrosIsql.Free;
        ErrosIsql := nil;
      end
      else
        OkIns := True;
      Rel('  [OK]     dados importados: ' + IntToStr(TotalIns) +
          ' registros em INSERTs.');

      // (5) Valida o banco reconstruido (tabelas e registros).
      OkVal := ContarBanco(NovoBanco, TabelasNovo, RegNovo, Msg);
      if OkVal then
      begin
        FArquivoFinal := NovoBanco;
        if FResultado = raNada then
          FResultado := raParcial;
        RegistrarPasso('L2b - reconstrucao do banco',
          'banco reconstruido: ' + NovoBanco + ' (' +
          IntToStr(TabelasNovo) + ' tabelas, ' +
          Format('%d', [RegNovo]) + ' registros)', True);
      end
      else
      begin
        RegistrarPasso('L2b - reconstrucao do banco',
          'banco criado, mas a validacao falhou: ' + Msg, False);
      end;
    finally
      Valores.Free;
      Campos.Free;
      Linhas.Free;
    end;
  finally
    Script.Free;
  end;
end;

// ------------------------------------------------------------------
// Fluxo backup (.fbk/.gbk): restore limpo -> tolerante -> extrator.
// ------------------------------------------------------------------
procedure TMotorAutoRec.FluxoBackup(const D: TDiagResult);
var
  Destino: string;
  Msg, MsgVal, MsgCont: string;
  Tabelas: Integer;
  Registros: Int64;
  RestoreOk: Boolean;
  EngineOk, EngineInfo: string;
  Tolerante: string;
  I, EngineIdx: Integer;
  B: TBinSet;
begin
  RelSecao('2) TECNICAS ESCOLHIDAS E ORDEM (combinacao em cascata)');
  Rel('  T1. restore limpo (gbak -c -v) - tenta a via normal primeiro');
  Rel('  T2. restore tolerante (gbak -c -v -ig) - se T1 falhar, ignora');
  Rel('      checksums ruins e recupera o maximo de registros');
  Rel('  T4. extrator de texto - ultima barreira se o backup nao abrir');
  RelSecao('3) EXECUCAO PASSO A PASSO');

  // Escolhe o engine que responde (Firebird primeiro p/ formato moderno).
  EngineIdx := -1;
  EngineOk := '';
  for I := 0 to Length(FEntrada.Bins) - 1 do
  begin
    if FEntrada.Bins[I].TemGbak then
    begin
      if SondarEngine(FEntrada.Bins[I], EngineInfo) then
      begin
        EngineIdx := I;
        EngineOk := EngineInfo;
        Break;
      end;
      Rel('Engine ' + FEntrada.Bins[I].CaminhoBin +
          ': descartado - ' + EngineInfo);
    end;
  end;
  if EngineIdx < 0 then
  begin
    FResultado := raSemEngine;
    Rel('NENHUM gbak respondeu ao teste. Nada foi executado.');
    Rel('Como resolver: instale Firebird 2.5+ (ou use a pasta de ');
    Rel('ferramentas que acompanha o aplicativo, ex.: bin\\ferramentas,');
    Rel('e aponte/a deteccao automatica a encontrara).');
    Exit;
  end;
  // Reordena: engine escolhido passa a ser o [0] (os passos usam [0]).
  if EngineIdx > 0 then
  begin
    B := FEntrada.Bins[0];
    FEntrada.Bins[0] := FEntrada.Bins[EngineIdx];
    FEntrada.Bins[EngineIdx] := B;
  end;
  Rel('Engine em uso: ' + FEntrada.Bins[0].CaminhoBin + 'gbak.exe' +
      ' (' + EngineOk + ')');

  Destino := FEntrada.Destino;
  if Destino = '' then
    Destino := CaminhoArtefato('_recuperado', K_EXT_DB);
  Rel('Destino do banco recuperado: ' + Destino);
  LogarInfo('T1: restore limpo -> ' + Destino);
  RestoreOk := TentarRestore(FEntrada.Origem, Destino, False, Msg);
  if RestoreOk then
  begin
    RegistrarPasso('T1 - restore limpo (gbak -c -v)', Msg, True);
    if ValidarBanco(Destino, MsgVal) then
    begin
      RegistrarPasso('Validacao pos-restore (gfix -v)', MsgVal, True);
      if ContarBanco(Destino, Tabelas, Registros, MsgCont) then
      begin
        FArquivoFinal := Destino;
        FResultado := raCompleta;
        Rel('  [OK]     contagem via isql: ' + IntToStr(Tabelas) +
            ' tabelas, ' + Format('%d', [Registros]) + ' registros.');
      end
      else
      begin
        FArquivoFinal := Destino;
        FResultado := raParcial;
        Rel('  [INFO]   banco valido, porem a contagem via isql falhou: ' +
            MsgCont);
      end;
    end
    else
    begin
      // Restaurou mas nao validou: tenta o tolerante em outro destino.
      FResultado := raParcial;
      FArquivoFinal := Destino;
      RegistrarPasso('Validacao pos-restore (gfix -v)',
        'falhou: ' + MsgVal, False);
    end;
    Exit;
  end;
  RegistrarPasso('T1 - restore limpo (gbak -c -v)', 'falhou: ' + Msg,
    False);

  // T2 - restore tolerante (-ig) para um arquivo intermediario; ao
  // final, o resultado vai para o Destino informado (quando ha).
  Tolerante := CaminhoArtefato('_recuperado_tolerante', K_EXT_DB);
  LogarInfo('T2: restore tolerante (-ig) -> ' + Tolerante);
  RestoreOk := TentarRestore(FEntrada.Origem, Tolerante, True, Msg);
  if RestoreOk then
  begin
    RegistrarPasso('T2 - restore tolerante (gbak -c -v -ig)', Msg, True);
    if not SameText(Tolerante, Destino) then
    begin
      if CopyFile(PChar(Tolerante), PChar(Destino), False) then
        Rel('  [OK]     resultado copiado para o destino: ' + Destino)
      else
        Rel('  [FALHA]  nao foi possivel copiar para o destino: ' +
            Destino + ' (erro ' + IntToStr(GetLastError) + ')');
    end;
    if ValidarBanco(Destino, MsgVal) then
    begin
      RegistrarPasso('Validacao pos-restore (gfix -v)', MsgVal, True);
      if ContarBanco(Destino, Tabelas, Registros, MsgCont) then
      begin
        FArquivoFinal := Destino;
        FResultado := raParcial;
        Rel('  [OK]     contagem via isql: ' + IntToStr(Tabelas) +
            ' tabelas, ' + Format('%d', [Registros]) + ' registros.');
      end
      else
      begin
        FArquivoFinal := Destino;
        FResultado := raParcial;
        Rel('  [INFO]   banco tolerante valido; contagem falhou: ' +
            MsgCont);
      end;
    end
    else
    begin
      RegistrarPasso('Validacao pos-restore (gfix -v)',
        'falhou: ' + MsgVal, False);
      FResultado := raParcial;
      FArquivoFinal := Destino;
    end;
    Exit;
  end;
  RegistrarPasso('T2 - restore tolerante (gbak -c -v -ig)',
    'falhou: ' + Msg, False);

  // Ultima barreira: extrator de texto sobre o proprio backup.
  TecnicaExtratorTexto(FEntrada.Origem);
  FResultado := raParcial;
  FArquivoFinal := '';
end;

// ------------------------------------------------------------------
// Fluxo banco (.fdb/.gdb): delega ao TMotorSalvage (L0..L4) e depois
// conta o que abriu. Toda escrita ocorre na copia forense.
// ------------------------------------------------------------------
procedure TMotorAutoRec.FluxoBanco(const D: TDiagResult);
var
  Entrada: TSalvageEntrada;
  Motor: TMotorSalvage;
  Msg, MsgCont: string;
  Tabelas: Integer;
  Registros: Int64;
  EngineInfo: string;
  I, EngineIdx: Integer;
  B: TBinSet;
  Alvo: string;
begin
  RelSecao('2) TECNICAS ESCOLHIDAS E ORDEM (combinacao em cascata)');
  Rel('  L0. copia forense byte a byte (nunca opera no original)');
  Rel('  L1. validar/reparar a copia com gfix (-v; -mend se autorizado;');
  Rel('      -activate quando o diagnostico acusar shutdown)');
  Rel('  L3. backup nativo (gbak -b) do que abrir');
  Rel('  L4. extrator de texto - se nada abrir');
  RelSecao('3) EXECUCAO PASSO A PASSO');

  EngineIdx := -1;
  for I := 0 to Length(FEntrada.Bins) - 1 do
  begin
    if FEntrada.Bins[I].TemGbak and FEntrada.Bins[I].TemGfix then
    begin
      if SondarEngine(FEntrada.Bins[I], EngineInfo) then
      begin
        EngineIdx := I;
        Break;
      end;
      Rel('Engine ' + FEntrada.Bins[I].CaminhoBin +
          ': descartado - ' + EngineInfo);
    end;
  end;
  if EngineIdx < 0 then
  begin
    FResultado := raSemEngine;
    Rel('NENHUM engine (gbak+gfix) respondeu. Nada foi executado.');
    Rel('Como resolver: instale Firebird/InterBase ou use a pasta de ');
    Rel('ferramentas que acompanha o aplicativo (bin\\ferramentas).');
    Exit;
  end;
  if EngineIdx > 0 then
  begin
    B := FEntrada.Bins[0];
    FEntrada.Bins[0] := FEntrada.Bins[EngineIdx];
    FEntrada.Bins[EngineIdx] := B;
  end;
  Rel('Engine em uso: ' + FEntrada.Bins[0].CaminhoBin + 'gbak.exe' +
      ' (' + EngineInfo + ')');

  FillChar(Entrada, SizeOf(Entrada), 0);
  Entrada.Origem := FEntrada.Origem;
  Entrada.PastaTrabalho := FEntrada.PastaTrabalho;
  Entrada.GfixExe := FEntrada.Bins[0].CaminhoBin + 'gfix.exe';
  Entrada.VersaoGfix := FEntrada.Bins[0].Versao;
  Entrada.GbakExe := FEntrada.Bins[0].CaminhoBin + 'gbak.exe';
  Entrada.VersaoGbak := FEntrada.Bins[0].Versao;
  Entrada.Usuario := FEntrada.Usuario;
  Entrada.Senha := FEntrada.Senha;
  Entrada.TimeoutMs := FTimeoutPadrao;
  Entrada.PermitirReparoMend := FEntrada.PermitirReparoMend;
  Entrada.ExtratorMinimo := FEntrada.ExtratorMinimo;
  Entrada.ExtratorTeto := 0;

  Motor := TMotorSalvage.Create(Entrada, FLog);
  try
    Motor.AtribuirCancelamento(FCancelar);
    if not Motor.ExecutarFluxo then
    begin
      FResultado := raNaoIniciada;
      Rel('Salvage nao iniciado (pre-condicoes ausentes).');
      Exit;
    end;
    // Anexa o resumo honesto do salvage ao relatorio.
    Rel('Camadas do salvage (uMotorSalvage):');
    Rel(Motor.Relatorio.ResumoHonesto);

    if Cancelado then
    begin
      FResultado := raCancelado;
      Exit;
    end;

    // O que abriu? Prioridade: backup L3 > copia forense L1.
    Alvo := '';
    if (Motor.BackupFbk <> '') and FileExists(Motor.BackupFbk) then
      Alvo := Motor.BackupFbk
    else if (Motor.CopiaForense <> '') and
            FileExists(Motor.CopiaForense) then
      Alvo := Motor.CopiaForense;

    if Alvo <> '' then
    begin
      // Conta sobre o artefato que abre. Para o .fbk a contagem exige
      // restore; conta sobre a copia forense (mesmo conteudo) quando o
      // backup foi gerado; caso contrario conta direto na copia.
      if (Motor.BackupFbk <> '') and FileExists(Motor.BackupFbk) and
         (Motor.CopiaForense <> '') and FileExists(Motor.CopiaForense) then
        Alvo := Motor.CopiaForense;
      // Destino informado: entrega o melhor artefato nesse caminho
      // (respeita o caminho/nome digitado pelo usuario).
      if (FEntrada.Destino <> '') and
         (not SameText(Alvo, FEntrada.Destino)) then
      begin
        if CopyFile(PChar(Alvo), PChar(FEntrada.Destino), False) then
        begin
          Rel('  [OK]     artefato copiado para o destino: ' +
              FEntrada.Destino);
          Alvo := FEntrada.Destino;
        end
        else
          Rel('  [INFO]   nao foi possivel copiar para o destino: ' +
              FEntrada.Destino + ' (erro ' +
              IntToStr(GetLastError) + ')');
      end;
      // L2 - datapump tabela a tabela: extrai o que der (driver real).
      // Se exportou ao menos uma tabela, reconstroi um banco novo.
      if TecnicaDatapump(Alvo) then
        TecnicaReconstruir(Alvo);
      if ContarBanco(Alvo, Tabelas, Registros, MsgCont) then
      begin
        FArquivoFinal := Alvo;
        FResultado := raParcial; // pode ser elevado abaixo
        Rel('  [OK]     contagem via isql sobre ' + Alvo + ': ' +
            IntToStr(Tabelas) + ' tabelas, ' +
            Format('%d', [Registros]) + ' registros.');
        // Salvage com copia validada + contagem = parcial saudavel.
      end
      else
      begin
        FArquivoFinal := Alvo;
        FResultado := raParcial;
        Rel('  [INFO]   artefato existe, mas a contagem via isql ' +
            'falhou: ' + MsgCont);
      end;
    end
    else
    begin
      // Nada abriu: o L4 do salvage ja tentou; se mesmo assim nao
      // produziu dump, registra nada recuperado.
      if Motor.DumpTexto = '' then
        FResultado := raNada
      else
        FResultado := raParcial;
    end;
  finally
    Motor.Free;
  end;
end;

// ------------------------------------------------------------------
// Executar: pipeline completo da recuperacao automatica.
// ------------------------------------------------------------------
function TMotorAutoRec.Executar: TRecAutoResultado;
var
  D: TDiagResult;
  Pasta: string;
  T0, T1: TDateTime;
  Duracao: Double;
  H, M, S, Ds: Integer;
  DuracaoTexto: string;
begin
  FRelatorio.Clear;
  FPassos := nil;
  FArquivoFinal := '';
  FResultado := raNaoIniciada;
  T0 := Now;

  RelSecao('RELATORIO DE RECUPERACAO AUTOMATICA');
  Rel('Gerado em ' + DateTimeToStr(Now));

  // Pre-condicoes.
  if (FEntrada.Origem = '') or (not FileExists(FEntrada.Origem)) then
  begin
    Rel('Arquivo de origem nao encontrado: ' + FEntrada.Origem);
    Result := raNaoIniciada;
    FResultado := Result;
    Exit;
  end;
  Pasta := FEntrada.PastaTrabalho;
  if Pasta = '' then
    Pasta := ExtractFilePath(FEntrada.Origem);
  if Pasta <> '' then
  begin
    if Pasta[Length(Pasta)] <> '\' then
      Pasta := Pasta + '\';
    // Pasta fixa e simples (nao usa o nome do arquivo - evitava que
    // o usuario achasse a saida). Sobrescreve artefatos de execucoes
    // anteriores da MESMA origem; origem diferente gera outra pasta.
    Pasta := Pasta + 'recuperacao';
  end;
  FEntrada.PastaTrabalho := Pasta;
  if not ForceDirectories(FEntrada.PastaTrabalho) then
  begin
    Rel('Nao foi possivel criar a pasta de trabalho: ' +
        FEntrada.PastaTrabalho);
    Result := raNaoIniciada;
    FResultado := Result;
    Exit;
  end;
  Rel('Pasta de trabalho: ' + FEntrada.PastaTrabalho);

  if Cancelado then
  begin
    FResultado := raCancelado;
    Result := FResultado;
    Exit;
  end;

  RelSecao('1) PROBLEMA IDENTIFICADO (diagnostico)');
  if not DiagnosticoEstatico(D) then
    LogarInfo('diagnostico estatico retornou False; notas acima');

  if Cancelado then
  begin
    FResultado := raCancelado;
    Result := FResultado;
    Exit;
  end;

  // Escolha do fluxo pela classificacao (primeiro passo de decisao).
  if D.FileKind = kBackup then
    FluxoBackup(D)
  else if D.FileKind = kDatabase then
    FluxoBanco(D)
  else
  begin
    // Desconhecido: tenta como banco (gfix decide); se o engine nao
    // reconhecer, a cascata de backup e tentada em seguida via relato.
    Rel('Classificacao desconhecida - tentando fluxo de banco; se o ');
    Rel('engine nao reconhecer a estrutura, tente restaurar como backup.');
    FluxoBanco(D);
  end;

  // Se um banco final existe, garante veredito minimo coerente.
  if (FResultado = raNaoIniciada) and (FArquivoFinal <> '') then
    FResultado := raParcial;

  RelSecao('4) RESULTADO: O QUE FOI RECUPERADO');
  Rel('Veredito: ' + RecAutoResultadoParaTexto(FResultado));
  if FArquivoFinal <> '' then
  begin
    Rel('Banco recuperado: ' + FArquivoFinal);
    Rel('Tamanho: ' + Format('%d', [FileSizeBytes(FArquivoFinal)]) +
        ' bytes');
  end
  else if (FResultado = raSemEngine) or (FResultado = raNada) then
    Rel('Nenhum banco valido foi produzido.');

  EscreverSecaoOQueFaltou;

  if Cancelado then
  begin
    FResultado := raCancelado;
    Result := FResultado;
    Exit;
  end;
  T1 := Now;
  Duracao := (T1 - T0) * 86400;   // segundos
  Ds := Round(Duracao);
  H := Ds div 3600;
  M := (Ds mod 3600) div 60;
  S := Ds mod 60;
  DuracaoTexto := IntToStr(S) + 's';
  if (M > 0) or (H > 0) then
    DuracaoTexto := IntToStr(M) + 'm ' + DuracaoTexto;
  if H > 0 then
    DuracaoTexto := IntToStr(H) + 'h ' + DuracaoTexto;
  Rel('');
  Rel('Tempo total da recuperacao: ' + DuracaoTexto);
  Result := FResultado;
end;

// ------------------------------------------------------------------
// Secao 5 do relatorio: quando algo faltou, como resolver cada passo.
// ------------------------------------------------------------------
procedure TMotorAutoRec.EscreverSecaoOQueFaltou;
var
  FaltouEngine, FaltouCompat: Boolean;
  I: Integer;
begin
  FaltouEngine := Length(FEntrada.Bins) = 0;
  FaltouCompat := False;
  for I := 0 to Length(FEntrada.Bins) - 1 do
    if (not FEntrada.Bins[I].TemGbak) and
       (not FEntrada.Bins[I].TemGfix) then
      FaltouCompat := True;

  RelSecao('5) SE FALTOU ALGO - COMO RESOLVER CADA PASSO');
  if FaltouEngine then
  begin
    Rel('* Nenhuma instalacao Firebird/InterBase foi detectada.');
    Rel('  1. Use a pasta de ferramentas que acompanha o aplicativo');
    Rel('     (bin\\ferramentas) - a deteccao automatica a encontra;');
    Rel('  2. Ou instale o Firebird 2.5 ou superior (firebirdsql.org);');
    Rel('  3. Ou aponte a pasta do gbak em config.ini ([Paths] FbBinDir).');
  end;
  if FResultado = raSemEngine then
  begin
    Rel('* Os engines encontrados nao responderam ao teste (gbak -z).');
    Rel('  Verifique: o binario precisa do fbclient.dll/fbembed.dll ao');
    Rel('  lado (modo embarcado) ou de um servidor no ar para conectar.');
  end;
  if FResultado = raNada then
  begin
    Rel('* Nenhuma tecnica entregou dados aproveitaveis.');
    Rel('  - Confirme se o arquivo e um backup gbak valido ou um banco;');
    Rel('  - Se o backup esta truncado, refaca-o a partir do servidor;');
    Rel('  - O dump de texto (L4) permite recuperacao manual parcial;');
    Rel('  - Ferramentas avancadas: gfix -v -full, restore com -ig.');
  end;
  if FResultado = raParcial then
  begin
    Rel('* Recuperacao parcial: o banco produzido deve ser validado no');
    Rel('  servidor real (Firebird/InterBase) antes do uso em producao.');
    Rel('  Exporte o DDL com isql -extract e compare com o esperado.');
  end;
  if FaltouCompat then
  begin
    Rel('* Algum engine detectado pode ser incompativel com o formato');
    Rel('  do arquivo (ex.: gbak InterBase antigo x backup Firebird).');
  end;
end;

// ------------------------------------------------------------------
// SalvarRelatorio
// ------------------------------------------------------------------
function TMotorAutoRec.SalvarRelatorio(const ADestino: string): Boolean;
begin
  Result := False;
  if ADestino = '' then
    Exit;
  try
    FRelatorio.SaveToFile(ADestino);
    Result := True;
  except
    on E: Exception do
      LogarErro('nao foi possivel salvar o relatorio: ' + E.Message);
  end;
end;

end.
