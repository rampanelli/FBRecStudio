{
  uMotorSalvage.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F4-T1 / F4 (PLANO.md 4.2 Tecnica 4, 6.2-6.4): orquestrador das
  camadas do salvage (uSalvagePlan). Sem Forms e sem driver: o que roda
  aqui e L0 (copia forense), L1 (validar/reparar a copia com gfix) e L3
  (backup nativo do que abre); a L2 (datapump por driver) NAO e tentada
  e fica registrada como ignorada com a observacao de que "requer
  modulo de exportacao F5/driver"; a L4 (uExtratorTexto) roda no final.

  Contrato (decisoes desta fase, sem Firebird nem arquivos reais):
    * L0-copia-sempre-primeiro: o motor executa SEMPRE a camada
      glCopia (uSafeCopy, byte a byte) antes de qualquer outra; as
      camadas L1/L3 operam EXCLUSIVAMENTE sobre a copia forense - o
      arquivo original nunca e passado ao gfix/gbak. Se a copia falha,
      L1/L3 viram "ignorada" (nao se toca o original); o L4 (extrator,
      somente leitura) ainda tenta sobre o original.
    * Camada por camada o resultado vai para o TSalvageRelatorio
      (estado + detalhe honesto), ex.: gfix ausente = csFalha com o
      motivo; datapump = csIgnorada (F5/driver); extrator = csOk com o
      n. de runs e o caminho do dump.
    * Bins e versoes chegam prontos (uFBAutoDetect + uFBVersionInfo);
      credenciais opcionais (Usuario/Senha) sao repassadas e NUNCA
      logadas em claro (as engines mascaram via uQuoting).
    * Cancelamento por FLAG (PBoolean): checado entre camadas e, para
      as camadas de processo, um sink ponte chama Runner.Cancel ao ver
      a flag acionada (uKernelExec mata a arvore). Com a flag ligada,
      as camadas ainda nao iniciadas viram "ignorada".
    * O motor reusa: uSafeCopy (L0), TMotorGfix (L1), TMotorGbak (L3),
      uExtratorTexto (L4), TSalvageRelatorio (uSalvagePlan), ILogPasso
      (uEngineBase) e uLogger.

  Regras do repositorio: Delphi 7 puro (sem generics/anonymous/for..in),
  comentarios pt-BR ASCII, sem Forms, units <= 31 chars.
  ------------------------------------------------------------------
}
unit uMotorSalvage;

{$H+}

interface

uses
  SysUtils, Windows, uKernelExec, uEngineBase, uFBVersionInfo,
  uSalvagePlan;

type
  // ------------------------------------------------------------------
  // Entrada (dados) do motor. Caminhos, bins detectados e versoes.
  // PastaTrabalho recebe a copia forense, o backup .fbk e o dump.
  // ------------------------------------------------------------------
  TSalvageEntrada = record
    Origem: string;              // arquivo do banco corrompido (original)
    PastaTrabalho: string;       // pasta da copia forense/backups/dump
    GfixExe: string;             // caminho do gfix ('' = ausente)
    VersaoGfix: TVersion;        // valida quando GfixExe existe
    GbakExe: string;             // caminho do gbak ('' = ausente)
    VersaoGbak: TVersion;        // valida quando GbakExe existe
    Usuario: string;             // -user opcional
    Senha: string;               // -pass opcional (nunca em claro no log)
    TimeoutMs: DWORD;            // por processo filho (0 = sem timeout)
    PermitirReparoMend: Boolean; // autoriza -mend NA COPIA quando a
                                 // validacao acusar problema (write)
    ExtratorMinimo: Integer;     // run minimo do L4 (0 = default 6)
    ExtratorTeto: Int64;         // teto de bytes do L4 (0 = sem teto)
  end;

  // ------------------------------------------------------------------
  // Motor do salvage (uma execucao = um fluxo completo de camadas).
  // ------------------------------------------------------------------
  TMotorSalvage = class
  private
    FEntrada: TSalvageEntrada;
    FLog: ILogPasso;             // pode ser nil (motor mudo)
    FRelatorio: TSalvageRelatorio;
    FCancelar: PBoolean;         // flag de cancelamento (outra thread ok)
    FCopiaForense: string;       // artefato da L0 (caminho criado)
    FBackupFbk: string;          // artefato da L3 (caminho esperado)
    FDumpTexto: string;          // artefato da L4 (caminho esperado)
    FRodou: Boolean;             // True: o fluxo visitou as camadas

    procedure Logar(const ACanal: string; const AMensagem: string);
    procedure LogarInfo(const AMensagem: string);
    procedure LogarErro(const AMensagem: string);
    function Cancelado: Boolean;
    function GerarNome(const AMeio, AExt: string): string;

    // L0: copia forense (uSafeCopy). True = arquivo de copia criado.
    function ExecutarCamadaCopia: Boolean;
    // L1: validar (e mend opcional) a copia com TMotorGfix.
    procedure ExecutarCamadaValidar(AComCopia: Boolean);
    // L3: backup do que abre com TMotorGbak (mgBackup da copia).
    procedure ExecutarCamadaBackup(AComCopia: Boolean);
    // L4: extrator de texto (uExtratorTexto).
    procedure ExecutarCamadaExtrator(AComCopia: Boolean);

    // Executa um passo gfix e devolve o veredito + mensagem honesta.
    function RodarGfixValidacao(const ABanco: string;
      out AMsg: string): Boolean;
    function RodarGfixMend(const ABanco: string;
      out AMsg: string): Boolean;
    // Executa o gbak -b; True somente quando o .fbk surgiu no destino.
    function RodarGbakBackup(const AOrigem, ADestino: string;
      out AMsg: string): Boolean;
  public
    constructor Create(const AEntrada: TSalvageEntrada; ALog: ILogPasso);
    destructor Destroy; override;

    // Flag de cancelamento (nil = sem cancelamento). Checada entre
    // camadas; durante os subprocessos o sink ponte cancela o runner.
    procedure AtribuirCancelamento(ACancelar: PBoolean);

    // Roda o fluxo default (todas as camadas; glCopia sempre 1a).
    // False = nao comecou (cancelamento inicial ou pre-condicao de
    // entrada ausente); o veredito real esta no Relatorio.
    function ExecutarFluxo: Boolean;

    property Relatorio: TSalvageRelatorio read FRelatorio;
    property CopiaForense: string read FCopiaForense;
    property BackupFbk: string read FBackupFbk;
    property DumpTexto: string read FDumpTexto;
  end;
implementation

uses
  Classes, uLogger, uSafeCopy, uExtratorTexto, uEngineGfix,
  uEngineGbak;

// ------------------------------------------------------------------
// Sink ponte p/ cancelamento: quando a flag de cancelamento aciona
// durante um subprocesso, chama Runner.Cancel (uKernelExec mata a
// arvore e o passo encerra como cancelado).
// ------------------------------------------------------------------
type
  TSinkPonteSalvage = class(TInterfacedObject, IOutputSink)
  private
    FFlagCancelar: PBoolean;
    FRunner: IProcessRunner;
  public
    constructor Create(AFlag: PBoolean; ARunner: IProcessRunner);
    procedure OnLine(AStream: TStreamId; const ALine: string);
    procedure OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
  end;

constructor TSinkPonteSalvage.Create(AFlag: PBoolean;
  ARunner: IProcessRunner);
begin
  inherited Create;
  FFlagCancelar := AFlag;
  FRunner := ARunner;
end;

procedure TSinkPonteSalvage.OnLine(AStream: TStreamId; const ALine: string);
begin
  if (FFlagCancelar <> nil) and FFlagCancelar^ and (FRunner <> nil) then
    FRunner.Cancel;
end;

procedure TSinkPonteSalvage.OnProcessEvent(AEvent: TProcEvent;
  const AInfo: string);
begin
  if (FFlagCancelar <> nil) and FFlagCancelar^ and (FRunner <> nil) then
    FRunner.Cancel;
end;

// Int64 decimal (D7 nao tem overload de IntToStr p/ Int64).
function Int64ParaTexto(AValor: Int64): string;
begin
  Result := Format('%d', [AValor]);
end;

// ------------------------------------------------------------------
// TMotorSalvage (infra)
// ------------------------------------------------------------------
constructor TMotorSalvage.Create(const AEntrada: TSalvageEntrada;
  ALog: ILogPasso);
begin
  inherited Create;
  FEntrada := AEntrada;
  FLog := ALog;
  FRelatorio := TSalvageRelatorio.Create;
  FCancelar := nil;
  FCopiaForense := '';
  FBackupFbk := '';
  FDumpTexto := '';
  FRodou := False;
end;

destructor TMotorSalvage.Destroy;
begin
  FLog := nil;
  FRelatorio.Free;
  inherited Destroy;
end;

procedure TMotorSalvage.AtribuirCancelamento(ACancelar: PBoolean);
begin
  FCancelar := ACancelar;
end;

procedure TMotorSalvage.Logar(const ACanal: string;
  const AMensagem: string);
begin
  if FLog <> nil then
    FLog.Log(ACanal, AMensagem);
end;

procedure TMotorSalvage.LogarInfo(const AMensagem: string);
begin
  Logar(LC_APP, AMensagem);
end;

procedure TMotorSalvage.LogarErro(const AMensagem: string);
begin
  Logar(LC_APP, 'ERRO: ' + AMensagem);
end;

function TMotorSalvage.Cancelado: Boolean;
begin
  Result := (FCancelar <> nil) and FCancelar^;
end;

// Nome de artefato na pasta de trabalho: <base_origem><meio><ext>.
function TMotorSalvage.GerarNome(const AMeio, AExt: string): string;
var
  Base: string;
begin
  Result := FEntrada.PastaTrabalho;
  if Result = '' then
    Exit;
  if Result[Length(Result)] <> '\' then
    Result := Result + '\';
  Base := ChangeFileExt(ExtractFileName(FEntrada.Origem), '');
  Result := Result + Base + AMeio + AExt;
end;
// ------------------------------------------------------------------
// ExecutarFluxo: roda o fluxo default (uSalvagePlan). A L0 copia
// forense e SEMPRE a 1a camada; L1/L3 operam na copia; L4 no fim.
// ------------------------------------------------------------------
function TMotorSalvage.ExecutarFluxo: Boolean;
var
  Camadas: array [0..4] of TGeraLayers;
  N, I: Integer;
  CopiaOk: Boolean;
begin
  Result := False;
  FRodou := False;
  FRelatorio.Reset;
  FCopiaForense := '';
  FBackupFbk := '';
  FDumpTexto := '';

  // Pre-condicoes de entrada (honestas no relatorio).
  if (FEntrada.Origem = '') or (not FileExists(FEntrada.Origem)) then
  begin
    FRelatorio.Marcar(glCopia, csFalha,
      'arquivo de origem nao encontrado: ' + FEntrada.Origem);
    for I := 1 to High(Camadas) do
      FRelatorio.Marcar(TGeraLayers(I), csIgnorada,
        'sem arquivo de origem para o salvage');
    Exit;
  end;
  if FEntrada.PastaTrabalho = '' then
  begin
    FRelatorio.Marcar(glCopia, csFalha,
      'pasta de trabalho nao informada');
    for I := 1 to High(Camadas) do
      FRelatorio.Marcar(TGeraLayers(I), csIgnorada,
        'sem pasta de trabalho para os artefatos');
    Exit;
  end;
  if not ForceDirectories(FEntrada.PastaTrabalho) then
  begin
    FRelatorio.Marcar(glCopia, csFalha,
      'nao foi possivel criar a pasta de trabalho: ' +
      FEntrada.PastaTrabalho);
    for I := 1 to High(Camadas) do
      FRelatorio.Marcar(TGeraLayers(I), csIgnorada,
        'pasta de trabalho indisponivel');
    Exit;
  end;

  N := FluxoDefaultSalvage(Camadas);
  CopiaOk := False;

  // Cancelamento ja acionado antes de comecar: nada roda e o relatorio
  // registra todas as camadas como ignorada (nada foi tocado).
  if Cancelado then
  begin
    for I := 0 to N - 1 do
      FRelatorio.Marcar(Camadas[I], csIgnorada,
        'cancelado pelo usuario (fluxo nao iniciado)');
    Exit;
  end;

  // Fluxo: percorre as camadas na ordem do plano; um cancelamento no
  // meio marca as restantes como ignorada (D7: sem alterar var de FOR,
  // por isso o laco e um WHILE).
  I := 0;
  while I < N do
  begin
    // Cancelamento entre camadas: as restantes viram ignorada.
    if Cancelado then
    begin
      while I < N do
      begin
        FRelatorio.Marcar(Camadas[I], csIgnorada,
          'cancelado pelo usuario (camada nao iniciada)');
        Inc(I);
      end;
      Break;
    end;

    case Camadas[I] of
      glCopia:
        CopiaOk := ExecutarCamadaCopia;
      glValidaGfix:
        ExecutarCamadaValidar(CopiaOk);
      glBackupOQueAbre:
        ExecutarCamadaBackup(CopiaOk);
      glDatapumpTabelas:
        begin
          // L2 nao tenta driver aqui: registro honesto + observacao.
          LogarInfo('L2 datapump tabela a tabela: nao tentado ' +
            '(requer modulo de exportacao F5/driver com Firebird real).');
          FRelatorio.Marcar(glDatapumpTabelas, csIgnorada,
            'requer modulo de exportacao F5/driver (nao tentado)');
        end;
      glExtratorTexto:
        ExecutarCamadaExtrator(CopiaOk);
    end;
    Inc(I);
  end;

  FRodou := True;
  // True = o fluxo chegou ao fim (as camadas decidiveis foram
  // visitadas; o que falhou/sobrou esta no Relatorio). False = nao
  // comecou (cancelamento inicial ou pre-condicao ausente).
  Result := True;
end;
// ------------------------------------------------------------------
// L0 - copia forense byte a byte (uSafeCopy). Nunca toca o original;
// cria a copia na pasta de trabalho. False = falha/cancelada.
// ------------------------------------------------------------------
function TMotorSalvage.ExecutarCamadaCopia: Boolean;
var
  Bytes: Int64;
  St: TSafeCopyStatus;
begin
  FCopiaForense := GerarNome('.forense', ExtractFileExt(FEntrada.Origem));
  LogarInfo('L0 copia forense: ' + FEntrada.Origem + ' -> ' +
    FCopiaForense);
  St := CopiarArquivoSeguro(FEntrada.Origem, FCopiaForense, nil,
    FCancelar, 0, Bytes);
  if St = scSucesso then
  begin
    LogarInfo('L0 ok: copia forense com ' + Int64ParaTexto(Bytes) +
      ' bytes.');
    FRelatorio.Marcar(glCopia, csOk, 'copia forense criada: ' +
      FCopiaForense + ' (' + Int64ParaTexto(Bytes) + ' bytes)');
    Result := True;
  end
  else
  begin
    LogarErro('L0 falhou: ' + SafeCopyStatusParaTexto(St));
    FRelatorio.Marcar(glCopia, csFalha,
      SafeCopyStatusParaTexto(St) + ' (destino: ' + FCopiaForense + ')');
    FCopiaForense := '';
    Result := False;
  end;
end;

// ------------------------------------------------------------------
// L1 - validar (e mend opcional) a copia com gfix. Opera SOMENTE na
// copia forense; o original jamais entra no gfix.
// ------------------------------------------------------------------
procedure TMotorSalvage.ExecutarCamadaValidar(AComCopia: Boolean);
var
  MsgValidar, MsgMend, MsgFinal: string;
  Ok: Boolean;
begin
  if not AComCopia then
  begin
    FRelatorio.Marcar(glValidaGfix, csIgnorada,
      'sem copia forense (camada L0 falhou): gfix nao opera no original');
    Exit;
  end;
  if FEntrada.GfixExe = '' then
  begin
    LogarErro('L1: binario gfix nao informado.');
    FRelatorio.Marcar(glValidaGfix, csFalha,
      'binario gfix nao informado (deteccao F1 nao encontrou)');
    Exit;
  end;
  if not FileExists(FEntrada.GfixExe) then
  begin
    LogarErro('L1: binario gfix nao encontrado: ' + FEntrada.GfixExe);
    FRelatorio.Marcar(glValidaGfix, csFalha,
      'binario gfix nao encontrado: ' + FEntrada.GfixExe);
    Exit;
  end;
  if not FEntrada.VersaoGfix.Valida then
  begin
    LogarErro('L1: versao do gfix nao reconhecida.');
    FRelatorio.Marcar(glValidaGfix, csFalha,
      'versao do gfix nao reconhecida (catalogo de switches indisponivel)');
    Exit;
  end;

  LogarInfo('L1 validacao gfix (read-only) da copia forense...');
  Ok := RodarGfixValidacao(FCopiaForense, MsgValidar);
  if Ok then
  begin
    LogarInfo('L1 ok: gfix -v na copia sem erros de ferramenta.');
    FRelatorio.Marcar(glValidaGfix, csOk,
      'gfix -v na copia concluido (exit 0)');
    Exit;
  end;

  // Validacao acusou problema: mend e write e so roda NA COPIA com
  // autorizacao explicita (PermitirReparoMend) - guarda satisfeita
  // (copia L0 feita; a engine ainda testa o banco livre).
  if FEntrada.PermitirReparoMend then
  begin
    LogarInfo('L1: validacao acusou problema; tentando -mend na copia.');
    if RodarGfixMend(FCopiaForense, MsgMend) then
    begin
      if RodarGfixValidacao(FCopiaForense, MsgFinal) then
      begin
        LogarInfo('L1 ok: -mend na copia corrigiu (validacao final ok).');
        FRelatorio.Marcar(glValidaGfix, csOk,
          '-mend na copia corrigiu a estrutura (validacao final ok)');
        Exit;
      end;
      FRelatorio.Marcar(glValidaGfix, csFalha,
        '-mend executou na copia, mas a validacao final ainda acusa: ' +
        MsgFinal);
      Exit;
    end;
    FRelatorio.Marcar(glValidaGfix, csFalha,
      'validacao acusou problema e o -mend falhou na copia: ' + MsgMend);
    Exit;
  end;

  LogarErro('L1: validacao acusou problema (reparo nao autorizado).');
  FRelatorio.Marcar(glValidaGfix, csFalha,
    'gfix -v acusou problema na copia: ' + MsgValidar +
    ' (reparo -mend requer autorizacao: PermitirReparoMend)');
end;

// ------------------------------------------------------------------
// RodarGfixValidacao: executa 'gfix -v' (read-only) e devolve True
// quando o processo conclui sem erro de ferramenta. AMsg traz o motivo
// honesto quando falha.
// ------------------------------------------------------------------
function TMotorSalvage.RodarGfixValidacao(const ABanco: string;
  out AMsg: string): Boolean;
var
  Plano: TPlanoGfix;
  Motor: TMotorGfix;
  Runner: IProcessRunner;
  Sink: TSinkPonteSalvage;
  Res: TProcessResult;
begin
  AMsg := '';
  Result := False;
  Plano := nil;
  Motor := nil;
  Runner := nil;
  Sink := nil;
  try
    Plano := TPlanoGfix.Create;
    Motor := TMotorGfix.Create(FLog);
    Runner := TProcessRunner.Create;
    Sink := TSinkPonteSalvage.Create(FCancelar, Runner);

    Plano.GfixExe := FEntrada.GfixExe;
    Plano.VersaoGfix := FEntrada.VersaoGfix;
    Plano.Banco := ABanco;
    Plano.Acao := gaValidar;
    Plano.Usuario := FEntrada.Usuario;
    Plano.Senha := FEntrada.Senha;
    Plano.TimeoutMs := FEntrada.TimeoutMs;

    Motor.AtribuirPlano(Plano);
    Res := Motor.Executar(Runner, Sink);
    if Res.Ok then
      Result := True
    else
      AMsg := Motor.Resumo.MensagemErro;
    if AMsg = '' then
      AMsg := Res.ErrorText;
  finally
    Plano.Free;
    Motor.Free;
  end;
end;

// ------------------------------------------------------------------
// RodarGfixMend: executa 'gfix -mend' NA COPIA (write sob a guarda:
// copia ja feita pela L0; a engine exige banco livre e PermitirEscrita).
// ------------------------------------------------------------------
function TMotorSalvage.RodarGfixMend(const ABanco: string;
  out AMsg: string): Boolean;
var
  Plano: TPlanoGfix;
  Motor: TMotorGfix;
  Runner: IProcessRunner;
  Sink: TSinkPonteSalvage;
  Res: TProcessResult;
begin
  AMsg := '';
  Result := False;
  Plano := nil;
  Motor := nil;
  Runner := nil;
  Sink := nil;
  try
    Plano := TPlanoGfix.Create;
    Motor := TMotorGfix.Create(FLog);
    Runner := TProcessRunner.Create;
    Sink := TSinkPonteSalvage.Create(FCancelar, Runner);

    Plano.GfixExe := FEntrada.GfixExe;
    Plano.VersaoGfix := FEntrada.VersaoGfix;
    Plano.Banco := ABanco;
    Plano.Acao := gaMend;
    Plano.Usuario := FEntrada.Usuario;
    Plano.Senha := FEntrada.Senha;
    Plano.TimeoutMs := FEntrada.TimeoutMs;
    // Guarda: a L0 ja criou a copia e o motor esta autorizado a
    // escrever NA COPIA (nunca no original).
    Plano.CopiaSegurancaFeita := True;
    Plano.PermitirEscrita := True;

    Motor.AtribuirPlano(Plano);
    Res := Motor.Executar(Runner, Sink);
    if Res.Ok then
      Result := True
    else
      AMsg := Motor.Resumo.MensagemErro;
    if AMsg = '' then
      AMsg := Res.ErrorText;
  finally
    Plano.Free;
    Motor.Free;
  end;
end;
// ------------------------------------------------------------------
// L3 - backup nativo do que abre: gbak -b da COPIA forense (reparada
// pela L1 quando possivel) para um .fbk novo na pasta de trabalho.
// ------------------------------------------------------------------
procedure TMotorSalvage.ExecutarCamadaBackup(AComCopia: Boolean);
var
  Msg: string;
begin
  if not AComCopia then
  begin
    FRelatorio.Marcar(glBackupOQueAbre, csIgnorada,
      'sem copia forense (camada L0 falhou): gbak nao opera no original');
    Exit;
  end;
  if FEntrada.GbakExe = '' then
  begin
    LogarErro('L3: binario gbak nao informado.');
    FRelatorio.Marcar(glBackupOQueAbre, csFalha,
      'binario gbak nao informado (deteccao F1 nao encontrou)');
    Exit;
  end;
  if not FileExists(FEntrada.GbakExe) then
  begin
    LogarErro('L3: binario gbak nao encontrado: ' + FEntrada.GbakExe);
    FRelatorio.Marcar(glBackupOQueAbre, csFalha,
      'binario gbak nao encontrado: ' + FEntrada.GbakExe);
    Exit;
  end;
  if not FEntrada.VersaoGbak.Valida then
  begin
    LogarErro('L3: versao do gbak nao reconhecida.');
    FRelatorio.Marcar(glBackupOQueAbre, csFalha,
      'versao do gbak nao reconhecida (catalogo de switches indisponivel)');
    Exit;
  end;

  FBackupFbk := GerarNome('.salvage', '.fbk');
  LogarInfo('L3 backup do que abre: ' + FCopiaForense + ' -> ' +
    FBackupFbk);
  if RodarGbakBackup(FCopiaForense, FBackupFbk, Msg) then
  begin
    LogarInfo('L3 ok: backup criado em ' + FBackupFbk);
    FRelatorio.Marcar(glBackupOQueAbre, csOk,
      'backup do que abre criado: ' + FBackupFbk);
  end
  else
  begin
    LogarErro('L3 falhou: ' + Msg);
    FRelatorio.Marcar(glBackupOQueAbre, csFalha, Msg);
    FBackupFbk := '';
  end;
end;

// ------------------------------------------------------------------
// RodarGbakBackup: 'gbak -b <origem> <destino>'. True somente quando
// o processo termina ok E o arquivo .fbk existe no destino (sem
// artefato o backup nao vale - registro honesto).
// ------------------------------------------------------------------
function TMotorSalvage.RodarGbakBackup(const AOrigem, ADestino: string;
  out AMsg: string): Boolean;
var
  Plano: TPlanoGbak;
  Motor: TMotorGbak;
  Runner: IProcessRunner;
  Sink: TSinkPonteSalvage;
  Res: TProcessResult;
begin
  AMsg := '';
  Result := False;
  Plano := nil;
  Motor := nil;
  Runner := nil;
  Sink := nil;
  try
    Plano := TPlanoGbak.Create;
    Motor := TMotorGbak.Create(FLog);
    Runner := TProcessRunner.Create;
    Sink := TSinkPonteSalvage.Create(FCancelar, Runner);

    Plano.GbakExe := FEntrada.GbakExe;
    Plano.VersaoGbak := FEntrada.VersaoGbak;
    Plano.Origem := AOrigem;
    Plano.Destino := ADestino;
    Plano.Modo := mgBackup;
    Plano.Sobrescrever := FileExists(ADestino);
    Plano.Usuario := FEntrada.Usuario;
    Plano.Senha := FEntrada.Senha;
    Plano.TimeoutMs := FEntrada.TimeoutMs;

    Motor.AtribuirPlano(Plano);
    Res := Motor.Executar(Runner, Sink);
    if Res.Ok and FileExists(ADestino) then
      Result := True
    else
    begin
      if Res.Ok then
        AMsg := 'gbak terminou ok mas o arquivo de backup nao foi ' +
                'criado: ' + ADestino
      else
        AMsg := Motor.Resumo.MensagemErro;
      if AMsg = '' then
        AMsg := Res.ErrorText;
    end;
  finally
    Plano.Free;
    Motor.Free;
  end;
end;

// ------------------------------------------------------------------
// L4 - extrator de texto (uExtratorTexto), somente leitura. Roda sobre
// a copia forense quando ela existe; sem copia, ainda tenta no ORIGINAL
// (leitura nao altera nada) para nao perder o que der para extrair.
// ------------------------------------------------------------------
procedure TMotorSalvage.ExecutarCamadaExtrator(AComCopia: Boolean);
var
  Opcoes: TExtracaoTextoOpcoes;
  Alvo: string;
  Status: TExtracaoStatus;
  Runs: Integer;
  BytesLidos: Int64;
  Detalhe: string;
begin
  if AComCopia then
    Alvo := FCopiaForense
  else
  begin
    // Sem copia: leitura direto do original continua segura (read-only);
    // o relatorio registra a origem usada.
    Alvo := FEntrada.Origem;
    LogarInfo('L4: copia indisponivel; varredura read-only do original.');
  end;

  FDumpTexto := GerarNome('.texto', '.txt');
  FillChar(Opcoes, SizeOf(Opcoes), 0);
  Opcoes.ArquivoOrigem := Alvo;
  Opcoes.ArquivoSaida := FDumpTexto;
  Opcoes.ComprimentoMinimo := FEntrada.ExtratorMinimo;
  Opcoes.TetoBytes := FEntrada.ExtratorTeto;
  Opcoes.BlocoBytes := 0;   // default (64 KiB)

  LogarInfo('L4 extrator de texto: ' + Alvo + ' -> ' + FDumpTexto);
  Status := ExtrairRunsDeTexto(Opcoes, nil, FCancelar, Runs, BytesLidos);
  case Status of
    etSucesso, etTetoAtingido:
      begin
        Detalhe := 'runs gravados: ' + IntToStr(Runs) + '; bytes ' +
          'lidos: ' + Int64ParaTexto(BytesLidos) + '; dump: ' + FDumpTexto;
        if Status = etTetoAtingido then
          Detalhe := Detalhe + ' (teto de bytes atingido)';
        LogarInfo('L4 ok: ' + Detalhe);
        FRelatorio.Marcar(glExtratorTexto, csOk, Detalhe);
      end;
    etCancelado:
      begin
        LogarErro('L4 cancelado.');
        FRelatorio.Marcar(glExtratorTexto, csFalha,
          'extrator cancelado pelo usuario');
        FDumpTexto := '';
      end;
  else
    LogarErro('L4 falhou: ' + ExtracaoStatusParaTexto(Status));
    FRelatorio.Marcar(glExtratorTexto, csFalha,
      ExtracaoStatusParaTexto(Status));
    FDumpTexto := '';
  end;
end;

end.
