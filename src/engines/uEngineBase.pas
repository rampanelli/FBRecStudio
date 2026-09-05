{
  uEngineBase.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F2-A (PLANO.md 4.2/4.4/6.2): contrato-base das "engines" (tecnicas
  de recuperacao) e o passo de execucao. Nesta pasta NENHUM Forms:
  tudo testavel por console/FPC.

    * IRecoveryStep: uma etapa (passo) de uma tecnica:
        Descrever        - texto curto pt-BR do passo (UI/log);
        ValidarAmbiente  - pre-checks (bin/servidor/arquivos/perms):
                           False + Msg amigavel em falha;
        BuildArgs        - monta o argv tipado (chaves via catalogo de
                           switches, quoting via uQuoting) SEM executar;
        Executar         - roda o processo via IProcessRunner e devolve
                           o TProcessResult cru (uKernelExec); o passo
                           guarda estado/resumo internos.
    * TStepState: estado de vida do passo (PLANO 4.4 item 1):
      pendente/rodando/sucesso/falha/cancelada/timeout - base da fila
      de etapas do pipeline (a fila/UI chega na F2-B/F6).
    * TRiskLevel: perigo da acao (PLANO 4.2: readOnly/write/destructive).
      A UI nunca executa 'destructive' sem confirmacao explicita.
    * TMotorePasso: base concreta com log (ILogPasso), estado, risco e
      descricao; as engines herdam e sobrescrevem os metodos do passo.
    * ILogPasso + TLogPassoArquivo: saida de log INJETADA (interface,
      sem depender de Forms nem de arquivo fixo) - os testes usam um
      fake em memoria; a aplicacao usa o adaptador TLogPassoArquivo
      sobre o uLogger (formato canonico do plano 6.8).

  Decisao de contrato (F2-A): IRecoveryStep carrega o plano atribuido
  antes (ex.: TMotorGbak.AtribuirPlano); o TRecoveryPlan/IRecoveryEngine
  do PLANO 6.2 entram com a UI (F2-B/F6) - o motor nao monta plano.

  Regras do repositorio: Delphi 7 puro (sem generics/anonymous/for..in),
  comentarios pt-BR ASCII, unidades <= 31 chars.
  ------------------------------------------------------------------
}
unit uEngineBase;

{$H+}

interface

uses
  SysUtils, Classes, uLogger, uKernelExec;

type
  // Nivel de risco da acao executada pelo passo (PLANO 4.2 'perigo').
  TRiskLevel = (rlReadOnly, rlWrite, rlDestructive);

  // Estado de vida do passo (PLANO 4.4 item 1).
  TStepState = (ssPendente, ssRodando, ssSucesso, ssFalha, ssCancelado,
                ssTimeout);


  // ------------------------------------------------------------------
  // Log do passo: canais do uLogger (LC_APP/LC_STDOUT/LC_STDERR) + msg.
  // Injetado por interface (nil = motor mudo, permitido em testes).
  // ------------------------------------------------------------------
  ILogPasso = interface
    ['{D4A3C711-2E5A-4B0F-9A83-6C1B2E4D5F60}']
    procedure Log(const ACanal: string; const AMensagem: string);
  end;

  // ------------------------------------------------------------------
  // Contrato do passo de uma tecnica (PLANO 6.2; nomes do F2-A).
  // ------------------------------------------------------------------
  IRecoveryStep = interface
    ['{3F0E8D14-7B2C-4A55-8E9D-1C40F6A9B273}']
    // Descricao curta e legivel ("restore via gbak (Firebird 2.5)").
    function Descrever: string;
    // Pre-checks do ambiente; em falha Msg traz o motivo amigavel.
    function ValidarAmbiente(var Msg: string): Boolean;
    // Monta o argv tipado (catalogo + uQuoting). True = argv pronto.
    function BuildArgs: Boolean;
    // Executa (sincrono - chamar de worker thread na UI). Devolve o
    // resultado cru do processo; o passo registra estado/resumo.
    function Executar(Runner: IProcessRunner; Sink: IOutputSink): TProcessResult;
  end;

  // ------------------------------------------------------------------
  // Base concreta dos motores (passos). Nao e abstrata de proposito
  // (estado/log sao uteis sozinhos); as engines sobrescrevem os 4
  // metodos. Estado inicial = ssPendente.
  // ------------------------------------------------------------------
  TMotorePasso = class(TInterfacedObject, IRecoveryStep)
  private
    FLogPasso: ILogPasso;      // pode ser nil (motor mudo)
  protected
    // protected (nao private): engines em OUTRAS units (uEngineGbak)
    // atualizam risco/estado/descricao (D7: private e por unit).
    FEstado: TStepState;
    FRisco: TRiskLevel;
    FDescricao: string;
    // Loga no ILogPasso (se houver) com o canal pedido (LC_* do uLogger).
    procedure Registrar(const ACanal, AMensagem: string);
    procedure RegistrarInfo(const AMensagem: string);
    procedure RegistrarErro(const AMensagem: string);
    procedure DefinirEstado(ANovo: TStepState);
    procedure DefinirDescricao(const ADescricao: string);
  public
    constructor Create(ARisco: TRiskLevel; ALogPasso: ILogPasso); virtual;

    // IUnknown neutro: o motor pertence ao seu dono (libera com Free,
    // nunca pela interface). Emprestar Self como interface (ex.: passar
    // o motor como IOutputSink ao runner) NAO auto-destroi o objeto
    // quando a ultima referencia sai - evita free no meio de Executar.
    function _AddRef: Integer; stdcall;
    function _Release: Integer; stdcall;

    // --- IRecoveryStep (sobrescrever nas engines) ---
    function Descrever: string; virtual;
    function ValidarAmbiente(var Msg: string): Boolean; virtual;
    function BuildArgs: Boolean; virtual;
    function Executar(Runner: IProcessRunner;
                      Sink: IOutputSink): TProcessResult; virtual;

    property Estado: TStepState read FEstado;
    property Risco: TRiskLevel read FRisco;
  end;

  // ------------------------------------------------------------------
  // Adaptador do uLogger (TLogger) para ILogPasso (etapa fixa/motor).
  // Nao abre nem fecha o arquivo: apenas roteia com a etapa do plano.
  // ------------------------------------------------------------------
  TLogPassoArquivo = class(TInterfacedObject, ILogPasso)
  private
    FLogger: TLogger;
    FEtapa: string;
  public
    constructor Create(ALogger: TLogger; const AEtapa: string);
    procedure Log(const ACanal: string; const AMensagem: string);
  end;

// Texto pt-BR de estado/risco (logs, relatorios e UI). Declaradas fora
// do bloco type (funcoes livres nao podem viver dentro de type no D7).
function StepStateParaTexto(AEstado: TStepState): string;
function RiskLevelParaTexto(ARisco: TRiskLevel): string;

implementation

// ------------------------------------------------------------------
// StepStateParaTexto / RiskLevelParaTexto
// ------------------------------------------------------------------
function StepStateParaTexto(AEstado: TStepState): string;
begin
  case AEstado of
    ssPendente:  Result := 'pendente';
    ssRodando:   Result := 'rodando';
    ssSucesso:   Result := 'sucesso';
    ssFalha:     Result := 'falha';
    ssCancelado: Result := 'cancelada';
    ssTimeout:   Result := 'timeout';
  else
    Result := 'desconhecido';
  end;
end;

function RiskLevelParaTexto(ARisco: TRiskLevel): string;
begin
  case ARisco of
    rlReadOnly:    Result := 'read-only';
    rlWrite:       Result := 'write';
    rlDestructive: Result := 'destructive';
  else
    Result := 'desconhecido';
  end;
end;

// ------------------------------------------------------------------
// TMotorePasso
// ------------------------------------------------------------------
// Refcount neutro: _AddRef/_Release nunca destroem (ver declaracao).
function TMotorePasso._AddRef: Integer;
begin
  Result := -1;
end;

function TMotorePasso._Release: Integer;
begin
  Result := -1;
end;
constructor TMotorePasso.Create(ARisco: TRiskLevel; ALogPasso: ILogPasso);
begin
  inherited Create;
  FRisco := ARisco;
  FLogPasso := ALogPasso;
  FEstado := ssPendente;
  FDescricao := '';
end;

procedure TMotorePasso.Registrar(const ACanal, AMensagem: string);
begin
  if FLogPasso <> nil then
    FLogPasso.Log(ACanal, AMensagem);
end;

procedure TMotorePasso.RegistrarInfo(const AMensagem: string);
begin
  Registrar(LC_APP, AMensagem);
end;

procedure TMotorePasso.RegistrarErro(const AMensagem: string);
begin
  Registrar(LC_APP, 'ERRO: ' + AMensagem);
end;

procedure TMotorePasso.DefinirEstado(ANovo: TStepState);
begin
  if ANovo <> FEstado then
  begin
    Registrar(LC_APP, 'estado -> ' + StepStateParaTexto(ANovo));
    FEstado := ANovo;
  end;
end;

procedure TMotorePasso.DefinirDescricao(const ADescricao: string);
begin
  FDescricao := ADescricao;
end;

function TMotorePasso.Descrever: string;
begin
  Result := FDescricao;
  if Result = '' then
    Result := 'passo de recuperacao';
end;

function TMotorePasso.ValidarAmbiente(var Msg: string): Boolean;
begin
  // Genericamente nao ha ambiente a validar; engines sobrescrevem.
  Result := True;
  Msg := '';
end;

function TMotorePasso.BuildArgs: Boolean;
begin
  // Engines sobrescrevem; base sem plano nao monta argv.
  Result := True;
end;

function TMotorePasso.Executar(Runner: IProcessRunner;
  Sink: IOutputSink): TProcessResult;
begin
  // Engines sobrescrevem. Default seguro: falha explicita, sem processo.
  FillChar(Result, SizeOf(Result), 0);
  Result.Ok := False;
  Result.ErrorText := 'Executar nao implementado neste passo.';
  DefinirEstado(ssFalha);
  RegistrarErro(Result.ErrorText);
end;

// ------------------------------------------------------------------
// TLogPassoArquivo
// ------------------------------------------------------------------
constructor TLogPassoArquivo.Create(ALogger: TLogger; const AEtapa: string);
begin
  inherited Create;
  FLogger := ALogger;
  FEtapa := AEtapa;
end;

procedure TLogPassoArquivo.Log(const ACanal: string; const AMensagem: string);
begin
  if FLogger <> nil then
    FLogger.Log(FEtapa, ACanal, AMensagem);
end;

end.
