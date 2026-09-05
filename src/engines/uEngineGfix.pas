{
  uEngineGfix.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F3-T1 (PLANO.md 4.2 Tecnica 3, 6.2/6.3): reparo e validacao com gfix.

    * TGfixAcao: acoes do gfix. Validar (-v) e ValidarFull (-v -full)
      sao READ-ONLY (nunca exigem confirmacao nem copia); as demais
      (mend, activate, sweep, housekeeping, mode, kill, icu) ESCREVEM
      no banco e ficam sob a guarda (uGuardaSeguranca): exigem copia
      de seguranca (uSafeCopy) e banco fora de uso.
    * TPlanoGfix: dados de entrada. CopiaSegurancaFeita precisa ser
      True quando a acao escreve; a engine recusa sem isso.
    * Regra de chaves: a engine NUNCA monta switch sozinha - usa
      ISwitchCatalog.ObterSwitch(bkGfix, Versao, semantica) e anexa o
      VALOR quando a semantica leva valor (housekeeping on/off,
      -mode read_only/read_write, -icu on/off). Chave vazia na versao
      (ex.: -kill so FB3+) => aviso e omissao; quando a acao inteira
      nao tem chave (ex.: -mend indisponivel) BuildArgs falha.
    * Um TMotorGfix = UMA acao (uma invocacao do gfix). A "ordem
      segura" (PLANO 4.2 Tecnica 3) e produzida por
      GerarOrdemSeguraGfix (sequencia recomendada de acoes); a UI
      (F3-T3/F6) cria um motor por acao e deixa o usuario confirmar
      cada uma. Validacao e sempre primeiro (read-only); escrita so
      apos copia.
    * Parse de saida (InterpretarSaidaGfix): exit 0 sem frase de erro
      = sucesso; frases 'gfix:ERROR', 'database shutdown',
      'please connect' = falha/dica. gfix -v em banco bom costuma nao
      imprimir nada (exit 0) - coberto pelo contrato de exit.

  Regras do repositorio: Delphi 7 puro, sem Forms, sem generics/
  anonymous/for..in, comentarios pt-BR ASCII, units <= 31 chars.
  ------------------------------------------------------------------
}
unit uEngineGfix;

{$H+}

interface

uses
  SysUtils, Classes, Windows, uLogger, uKernelExec, uQuoting,
  uEngineBase, uGuardaSeguranca, uFBVersionInfo, uFBSwitchCatalog;

type
  // Acao do gfix (uma invocacao por motor). agValidar agrupa as duas
  // formas de validacao em acoes separadas p/ controle fino da UI.
  TGfixAcao = (
    gaValidar,         // -v            (read-only)
    gaValidarFull,     // -v -full      (read-only, caro)
    gaMend,            // -mend         (write: conserta estrutura)
    gaActivate,        // -activate     (write: banco em shutdown)
    gaSweep,           // -sweep        (write: ajustar/executar sweep)
    gaHousekeepingOn,  // -housekeeping on   (write)
    gaHousekeepingOff, // -housekeeping off  (write)
    gaModeReadOnly,    // -mode read_only    (write)
    gaModeReadWrite,   // -mode read_write   (write)
    gaKill,            // -kill (FB3+)       (write: transacoes limbo)
    gaIcuOn,           // -icu on            (write)
    gaIcuOff           // -icu off           (write)
  );

  // Flag p/ recomendar a ordem segura (heuristica; o diagnostico F1
  // preenche; a UI confirma cada acao antes de rodar).
  TGfixFlags = record
    EmShutdown: Boolean;       // gfix -activate recomendado
    SuspeitaCorrupcao: Boolean;// gfix -mend na sequencia
    ComLimbo: Boolean;         // gfix -kill na sequencia (se suportado)
  end;


  // ------------------------------------------------------------------
  // Plano do passo gfix (dados; sem logica).
  // ------------------------------------------------------------------
  TPlanoGfix = class
  public
    GfixExe: string;
    VersaoGfix: TVersion;
    Banco: string;
    Usuario: string;          // -user (opcional)
    Senha: string;            // -pass (opcional; nunca em claro no log)
    Acao: TGfixAcao;
    CopiaSegurancaFeita: Boolean;  // exigida p/ acoes write (guarda)
    PermitirEscrita: Boolean;      // confirmacao explicita da UI p/ write
    ArgsExtras: TStringArray;
    TimeoutMs: DWORD;         // 0 = sem timeout

    constructor Create;
    function PlanoParaTexto: string;
  end;

  // ------------------------------------------------------------------
  // Resumo da execucao (parse + estado do processo).
  // ------------------------------------------------------------------
  TResumoGfix = record
    Ok: Boolean;
    ExitCode: DWORD;
    Cancelado: Boolean;
    Timeout: Boolean;
    Erro: Boolean;            // frase de erro/dica vista
    MensagemErro: string;
    LinhaFinal: string;
  end;

  // ------------------------------------------------------------------
  // Motor do passo gfix (uma acao). Herda TMotorePasso.
  // ------------------------------------------------------------------
  TMotorGfix = class(TMotorePasso, IOutputSink)
  private
    FPlano: TPlanoGfix;
    FCatalogo: ISwitchCatalog;
    FArgv: TStringArray;
    FAvisos: TStringList;
    FErroAmbiente: string;
    FSaida: TStringList;
    FExtSink: IOutputSink;
    FMsgErroViva: string;
    FResumo: TResumoGfix;
    procedure ResetExec;
    function ComandoMascarado: string;
  public
    constructor Create(ALog: ILogPasso); overload;
    constructor CreateComCatalogo(ALog: ILogPasso;
      ACatalogo: ISwitchCatalog); overload;
    destructor Destroy; override;

    procedure AtribuirPlano(APlano: TPlanoGfix);

    // IRecoveryStep (overrides)
    function Descrever: string; override;
    function ValidarAmbiente(var Msg: string): Boolean; override;
    function BuildArgs: Boolean; override;
    function Executar(Runner: IProcessRunner;
                      Sink: IOutputSink): TProcessResult; override;

    // IOutputSink (uso interno)
    procedure OnLine(AStream: TStreamId; const ALine: string);
    procedure OnProcessEvent(AEvent: TProcEvent; const AInfo: string);

    property Argv: TStringArray read FArgv;
    property Resumo: TResumoGfix read FResumo;
    property Avisos: TStringList read FAvisos;
    property ErroAmbiente: string read FErroAmbiente;
  end;

// Funcoes livres.
function GfixAcaoParaTexto(AAcao: TGfixAcao): string;
// True quando a acao ESCREVE no banco (sujeita a guarda/copia).
function GfixAcaoExigeEscrita(AAcao: TGfixAcao): Boolean;
// Interpreta a saida do gfix (fixtures de texto nos testes).
function InterpretarSaidaGfix(const AExitCode: DWORD; ASaida: TStrings;
  const ASummaryProc: string): TResumoGfix;
// Lista negra de extras (mesma politica do gbak; reusa ValidarArgsExtras?).
// Regras de extras: NENHUM redirecionamento/injecao nem -pass duplicado.
function ValidarArgsExtrasGfix(const AArgs: TStringArray;
  out AMsg: string): Boolean;
// Ordem segura recomendada (PLANO 4.2 Tecnica 3): validar 1o (read-only),
// depois escrita conforme flags, validacao completa no fim.
// Devolve numero de acoes em AAcoes (array alocada pelo chamador? nao:
// funcao aloca e devolve em var array).
function GerarOrdemSeguraGfix(AFlags: TGfixFlags;
  var AAcoes: array of TGfixAcao): Integer;

implementation

const
  K_CAP_SAIDA = 4000;
  K_CAMINHO_LONGO = 230;

// ------------------------------------------------------------------
// GfixAcaoParaTexto / GfixAcaoExigeEscrita
// ------------------------------------------------------------------
function GfixAcaoParaTexto(AAcao: TGfixAcao): string;
begin
  case AAcao of
    gaValidar:         Result := 'validar (-v)';
    gaValidarFull:     Result := 'validacao completa (-v -full)';
    gaMend:            Result := 'reparo estrutural (-mend)';
    gaActivate:        Result := 'reativar banco em shutdown (-activate)';
    gaSweep:           Result := 'sweep';
    gaHousekeepingOn:  Result := 'housekeeping on';
    gaHousekeepingOff: Result := 'housekeeping off';
    gaModeReadOnly:    Result := 'modo read_only';
    gaModeReadWrite:   Result := 'modo read_write';
    gaKill:            Result := 'encerrar transacoes em limbo (-kill)';
    gaIcuOn:           Result := 'icu on';
    gaIcuOff:          Result := 'icu off';
  else
    Result := 'acao desconhecida';
  end;
end;

function GfixAcaoExigeEscrita(AAcao: TGfixAcao): Boolean;
begin
  // Somente validar sao read-only; todo o resto escreve no banco.
  Result := (AAcao <> gaValidar) and (AAcao <> gaValidarFull);
end;

// ------------------------------------------------------------------
// ValidarArgsExtrasGfix (mesma lista negra do gbak: 6.3).
// ------------------------------------------------------------------
function ValidarArgsExtrasGfix(const AArgs: TStringArray;
  out AMsg: string): Boolean;
var
  I, J: Integer;
  Up: string;
begin
  Result := True;
  AMsg := '';
  for I := 0 to Length(AArgs) - 1 do
  begin
    Up := UpperCase(AArgs[I]);
    if (Up = '-PASS') or (Up = '-PASSWORD') or (Up = '--PASSWORD') or
       (Copy(Up, 1, 6) = '-PASS=') or (Copy(Up, 1, 10) = '-PASSWORD=') or
       (Copy(Up, 1, 11) = '--PASSWORD=') then
    begin
      AMsg := 'argumento extra proibido: ' + AArgs[I] +
              ' (usar os campos Usuario/Senha do plano)';
      Result := False;
      Exit;
    end;
    for J := 1 to Length(AArgs[I]) do
      if (AArgs[I][J] = '>') or (AArgs[I][J] = '<') or
         (AArgs[I][J] = '|') or (AArgs[I][J] = '&') then
      begin
        AMsg := 'argumento extra proibido (redirecionamento/injecao): ' +
                AArgs[I];
        Result := False;
        Exit;
      end;
  end;
end;

// ------------------------------------------------------------------
// InterpretarSaidaGfix
// ------------------------------------------------------------------
function InterpretarSaidaGfix(const AExitCode: DWORD; ASaida: TStrings;
  const ASummaryProc: string): TResumoGfix;
var
  I: Integer;
  S: string;
begin
  Result.Ok := False;
  Result.ExitCode := AExitCode;
  Result.Cancelado := False;
  Result.Timeout := False;
  Result.Erro := False;
  Result.MensagemErro := '';
  Result.LinhaFinal := Trim(ASummaryProc);
  if ASaida <> nil then
    for I := 0 to ASaida.Count - 1 do
    begin
      S := LowerCase(ASaida[I]);
      if (Pos('gfix:error', S) > 0) or
         (Pos('database shutdown', S) > 0) or
         (Pos('please connect', S) > 0) or
         (Pos('invalid database handle', S) > 0) then
      begin
        Result.Erro := True;
        if Result.MensagemErro = '' then
          Result.MensagemErro := ASaida[I];
      end;
    end;
  Result.Ok := (AExitCode = 0) and (not Result.Erro);
  if (not Result.Ok) and (Result.MensagemErro = '') then
    Result.MensagemErro := 'gfix terminou com codigo ' +
      IntToStr(Integer(AExitCode)) + '.';
end;

// ------------------------------------------------------------------
// GerarOrdemSeguraGfix - sequencia recomendada (read-only 1o; escrita
// depois; validacao completa no fim). Retorna o n. de acoes gravadas.
// ------------------------------------------------------------------
function GerarOrdemSeguraGfix(AFlags: TGfixFlags;
  var AAcoes: array of TGfixAcao): Integer;
var
  Contador: Integer;

  procedure Emitir(AAcao: TGfixAcao);
  begin
    if Contador < Length(AAcoes) then
      AAcoes[Contador] := AAcao;
    Inc(Contador);
  end;

begin
  Contador := 0;
  // 1) validacao read-only primeiro (nunca escrever sem diagnosticar).
  Emitir(gaValidar);
  // 2) shutdown: reativar antes de tocar em estrutura.
  if AFlags.EmShutdown then
    Emitir(gaActivate);
  // 3) corrupcao estrutural: mend (write, sob copia).
  if AFlags.SuspeitaCorrupcao then
    Emitir(gaMend);
  // 4) limbo: kill quando suportado (catalogo omite em FB<3).
  if AFlags.ComLimbo then
    Emitir(gaKill);
  // 5) fechar com validacao completa (read-only).
  Emitir(gaValidarFull);
  Result := Contador;
end;

// ------------------------------------------------------------------
// TPlanoGfix
// ------------------------------------------------------------------
constructor TPlanoGfix.Create;
begin
  inherited Create;
  Acao := gaValidar;
  CopiaSegurancaFeita := False;
  PermitirEscrita := False;
  TimeoutMs := 0;
  ZerarVersion(VersaoGfix);
end;

function TPlanoGfix.PlanoParaTexto: string;
begin
  Result := 'gfix ' + GfixAcaoParaTexto(Acao);
  if VersaoGfix.Valida then
    Result := Result + ' (' + FamiliaParaTexto(VersaoGfix.Familia) + ' ' +
              IntToStr(VersaoGfix.Maior) + '.' +
              IntToStr(VersaoGfix.Menor) + ')';
  Result := Result + ': ' + Banco;
end;

// ------------------------------------------------------------------
// TMotorGfix
// ------------------------------------------------------------------
constructor TMotorGfix.Create(ALog: ILogPasso);
begin
  inherited Create(rlReadOnly, ALog);
  FCatalogo := CriarCatalogPadrao;
  FAvisos := TStringList.Create;
  FSaida := TStringList.Create;
end;

constructor TMotorGfix.CreateComCatalogo(ALog: ILogPasso;
  ACatalogo: ISwitchCatalog);
begin
  Create(ALog);
  if ACatalogo <> nil then
    FCatalogo := ACatalogo;
end;

destructor TMotorGfix.Destroy;
begin
  FExtSink := nil;
  FAvisos.Free;
  FSaida.Free;
  inherited Destroy;
end;

procedure TMotorGfix.AtribuirPlano(APlano: TPlanoGfix);
begin
  FPlano := APlano;
  if FPlano <> nil then
  begin
    // Risco do passo reflete a natureza da acao (write sob guarda).
    if GfixAcaoExigeEscrita(FPlano.Acao) then
      FRisco := rlWrite
    else
      FRisco := rlReadOnly;
    DefinirDescricao(Descrever);
  end;
end;

function TMotorGfix.Descrever: string;
begin
  if FPlano <> nil then
  begin
    Result := 'gfix: ' + GfixAcaoParaTexto(FPlano.Acao);
    if FPlano.VersaoGfix.Valida then
      Result := Result + ' (' +
                IntToStr(FPlano.VersaoGfix.Maior) + '.' +
                IntToStr(FPlano.VersaoGfix.Menor) + ')';
    Result := Result + ' em ' + ExtractFileName(FPlano.Banco);
  end
  else
    Result := 'passo gfix (sem plano)';
end;

procedure TMotorGfix.ResetExec;
begin
  FSaida.Clear;
  FMsgErroViva := '';
  FExtSink := nil;
  FResumo.Ok := False;
  FResumo.ExitCode := 0;
  FResumo.Cancelado := False;
  FResumo.Timeout := False;
  FResumo.Erro := False;
  FResumo.MensagemErro := '';
  FResumo.LinhaFinal := '';
end;

function TMotorGfix.ComandoMascarado: string;
var
  N, I: Integer;
  Full: array of string;
begin
  if FPlano = nil then
  begin
    Result := '';
    Exit;
  end;
  N := Length(FArgv);
  SetLength(Full, N + 1);
  Full[0] := FPlano.GfixExe;
  for I := 0 to N - 1 do
    Full[I + 1] := FArgv[I];
  Result := uQuoting.MakeDisplayCommandLine(Full);
end;

// ------------------------------------------------------------------
// ValidarAmbiente (pre-checks + guarda de seguranca)
// ------------------------------------------------------------------
function TMotorGfix.ValidarAmbiente(var Msg: string): Boolean;
var
  GfMsg: string;
  Escrita: Boolean;
  Acesso: TGfAcesso;
  Erro: DWORD;
begin
  Msg := '';
  FErroAmbiente := '';
  FAvisos.Clear;
  if FPlano = nil then
  begin
    FErroAmbiente := 'Plano gfix nao atribuido ao motor.';
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;

  if FPlano.GfixExe = '' then
  begin
    FErroAmbiente := 'Informe o caminho do executavel gfix.';
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;
  if not FileExists(FPlano.GfixExe) then
  begin
    FErroAmbiente := 'gfix nao encontrado: ' + FPlano.GfixExe;
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;
  if not FPlano.VersaoGfix.Valida then
  begin
    FErroAmbiente := 'Versao do gfix nao reconhecida - impossivel ' +
                     'montar as chaves pelo catalogo de switches.';
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;
  if FPlano.Banco = '' then
  begin
    FErroAmbiente := 'Informe o banco alvo (arquivo .fdb/.gdb).';
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;
  if not FileExists(FPlano.Banco) then
  begin
    FErroAmbiente := 'Banco nao encontrado: ' + FPlano.Banco;
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;
  if Length(ExpandFileName(FPlano.Banco)) > K_CAMINHO_LONGO then
    FAvisos.Add('Caminho do banco > ' + IntToStr(K_CAMINHO_LONGO) +
                ' chars: risco de limite dos utilitarios (MAX_PATH).');

  // Guarda de seguranca (uGuardaSeguranca): politica de escrita.
  Escrita := GfixAcaoExigeEscrita(FPlano.Acao);
  if Escrita and (not FPlano.PermitirEscrita) then
  begin
    FErroAmbiente := 'Acao ' + GfixAcaoParaTexto(FPlano.Acao) +
      ' ESCREVE no banco e requer confirmacao explicita ' +
      '(PermitirEscrita).';
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;
  if not GuardaAntesDeEscrita(FPlano.Banco, Escrita,
       FPlano.CopiaSegurancaFeita, False, GfMsg) then
  begin
    FErroAmbiente := GfMsg;
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;

  // Aviso (nao bloqueio): banco em uso numa operacao read-only tambem
  // costuma falhar no attach - avisar cedo e melhor que errar depois.
  Acesso := TestarAcessoBanco(FPlano.Banco, Erro);
  if Acesso = gaEmUso then
    FAvisos.Add('Banco parece em uso: a operacao pode falhar no ' +
                'attach. Feche as conexoes para garantir.');
  if Acesso = gaInexistente then
  begin
    FErroAmbiente := 'Banco nao encontrado: ' + FPlano.Banco;
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;

  Result := True;
end;

// ------------------------------------------------------------------
// BuildArgs (argv tipado; chaves SOMENTE via ISwitchCatalog)
// ------------------------------------------------------------------
function TMotorGfix.BuildArgs: Boolean;
var
  Tok: string;
  Msg: string;
  I: Integer;
  Falhou: Boolean;

  procedure AddArg(const AArg: string);
  var
    N: Integer;
  begin
    N := Length(FArgv);
    SetLength(FArgv, N + 1);
    FArgv[N] := AArg;
  end;

  // Token do catalogo. AExigido = True: token essencial p/ a acao
  // (ausencia = falha); False: opcional (ausencia = aviso e omissao).
  function ObterToken(ASem: TSemanticSwitch; AExigido: Boolean): string;
  begin
    Result := FCatalogo.ObterSwitch(bkGfix, FPlano.VersaoGfix, ASem);
    if Result = '' then
      if AExigido then
      begin
        FErroAmbiente := 'O gfix desta versao nao suporta a acao ' +
                         GfixAcaoParaTexto(FPlano.Acao) +
                         ' (catalogo de switches vazio).';
        Falhou := True;
      end
      else
        FAvisos.Add('Switch nao suportado nesta versao e foi ' +
                    'ignorado (' + SemanticaParaTexto(ASem) + ').');
  end;

begin
  Result := False;
  FArgv := nil;
  Falhou := False;
  FErroAmbiente := '';
  if FPlano = nil then
  begin
    FErroAmbiente := 'Plano gfix nao atribuido ao motor.';
    Exit;
  end;
  if FPlano.Banco = '' then
  begin
    FErroAmbiente := 'Informe o banco alvo.';
    Exit;
  end;

  case FPlano.Acao of
    gaValidar:
      begin
        Tok := ObterToken(ssValidate, True);
        if Falhou then Exit;
        AddArg(Tok);
      end;
    gaValidarFull:
      begin
        Tok := ObterToken(ssValidate, True);
        if Falhou then Exit;
        AddArg(Tok);
        Tok := ObterToken(ssValidateFull, True);
        if Falhou then Exit;
        AddArg(Tok);
      end;
    gaMend:
      begin
        Tok := ObterToken(ssMend, True);
        if Falhou then Exit;
        AddArg(Tok);
      end;
    gaActivate:
      begin
        Tok := ObterToken(ssActivate, True);
        if Falhou then Exit;
        AddArg(Tok);
      end;
    gaSweep:
      begin
        Tok := ObterToken(ssSweep, True);
        if Falhou then Exit;
        AddArg(Tok);
      end;
    gaHousekeepingOn:
      begin
        Tok := ObterToken(ssHousekeepingOn, False);
        if Tok <> '' then
        begin
          AddArg(Tok);
          AddArg('on');
        end;
      end;
    gaHousekeepingOff:
      begin
        Tok := ObterToken(ssHousekeepingOff, False);
        if Tok <> '' then
        begin
          AddArg(Tok);
          AddArg('off');
        end;
      end;
    gaModeReadOnly:
      begin
        Tok := ObterToken(ssModeReadOnly, False);
        if Tok <> '' then
        begin
          AddArg(Tok);
          AddArg('read_only');
        end;
      end;
    gaModeReadWrite:
      begin
        Tok := ObterToken(ssModeReadWrite, False);
        if Tok <> '' then
        begin
          AddArg(Tok);
          AddArg('read_write');
        end;
      end;
    gaKill:
      begin
        Tok := ObterToken(ssKill, False);
        if Tok <> '' then
          AddArg(Tok);
      end;
    gaIcuOn:
      begin
        Tok := ObterToken(ssIcuOn, False);
        if Tok <> '' then
        begin
          AddArg(Tok);
          AddArg('on');
        end;
      end;
    gaIcuOff:
      begin
        Tok := ObterToken(ssIcuOff, False);
        if Tok <> '' then
        begin
          AddArg(Tok);
          AddArg('off');
        end;
      end;
  else
    FErroAmbiente := 'Acao gfix desconhecida.';
    Falhou := True;
    Exit;
  end;
  if Falhou then
  begin
    Result := False;
    Exit;
  end;

  // Usuario/senha (credenciais como argumentos proprios - nunca
  // concatenados; o log mascarado via uQuoting).
  if FPlano.Usuario <> '' then
  begin
    AddArg('-user');
    AddArg(FPlano.Usuario);
  end;
  if FPlano.Senha <> '' then
  begin
    AddArg('-pass');
    AddArg(FPlano.Senha);
  end;

  // Extras livres - lista negra antes de aceitar.
  if not ValidarArgsExtrasGfix(FPlano.ArgsExtras, Msg) then
  begin
    FErroAmbiente := Msg;
    FArgv := nil;
    Exit;
  end;
  for I := 0 to Length(FPlano.ArgsExtras) - 1 do
    AddArg(FPlano.ArgsExtras[I]);

  // Operando do banco SEMPRE por ultimo.
  AddArg(FPlano.Banco);

  Result := True;
end;

// ------------------------------------------------------------------
// IOutputSink (captura + forward + log)
// ------------------------------------------------------------------
procedure TMotorGfix.OnLine(AStream: TStreamId; const ALine: string);
var
  S: string;
  I: Integer;
begin
  if AStream = stOut then
    Registrar(LC_STDOUT, ALine)
  else
    Registrar(LC_STDERR, ALine);

  if ALine <> '' then
  begin
    S := LowerCase(ALine);
    if (FMsgErroViva = '') and
       ((Pos('gfix:error', S) > 0) or (Pos('database shutdown', S) > 0) or
        (Pos('please connect', S) > 0)) then
      FMsgErroViva := ALine;
    FSaida.Add(ALine);
    if FSaida.Count > K_CAP_SAIDA then
    begin
      I := FSaida.Count - K_CAP_SAIDA;
      if I > 256 then
        I := 256;
      while I > 0 do
      begin
        FSaida.Delete(0);
        Dec(I);
      end;
    end;
  end;

  if FExtSink <> nil then
    FExtSink.OnLine(AStream, ALine);
end;

procedure TMotorGfix.OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
begin
  if FExtSink <> nil then
    FExtSink.OnProcessEvent(AEvent, AInfo);
end;

// ------------------------------------------------------------------
// Executar (uma invocacao do gfix)
// ------------------------------------------------------------------
function TMotorGfix.Executar(Runner: IProcessRunner;
  Sink: IOutputSink): TProcessResult;
var
  Msg: string;
  Opt: TProcessOptions;
begin
  Result.Ok := False;
  Result.ExitCode := 0;
  Result.Canceled := False;
  Result.TimedOut := False;
  Result.Summary := '';
  Result.ErrorText := '';
  Result.Started := Now;
  Result.Finished := Now;
  ResetExec;

  if Runner = nil then
  begin
    Result.ErrorText := 'IProcessRunner nao informado.';
    RegistrarErro(Result.ErrorText);
    DefinirEstado(ssFalha);
    Exit;
  end;

  DefinirEstado(ssRodando);
  if not ValidarAmbiente(Msg) then
  begin
    Result.ErrorText := Msg;
    RegistrarErro(Msg);
    DefinirEstado(ssFalha);
    Exit;
  end;
  if not BuildArgs then
  begin
    Result.ErrorText := FErroAmbiente;
    RegistrarErro(FErroAmbiente);
    DefinirEstado(ssFalha);
    Exit;
  end;

  Registrar(LC_APP, 'Comando: ' + ComandoMascarado);
  FExtSink := Sink;

  Opt.Executable := FPlano.GfixExe;
  Opt.WorkDir := '';
  Opt.Args := FArgv;
  Opt.TimeoutMs := FPlano.TimeoutMs;
  Opt.KillTreeOnCancel := True;
  Opt.ConsoleCodePage := 0;

  try
    Result := Runner.Run(Opt, Self);
  finally
    FExtSink := nil;
    Opt.Args := nil;
  end;

  FResumo := InterpretarSaidaGfix(Result.ExitCode, FSaida, Result.Summary);
  FResumo.Cancelado := Result.Canceled;
  FResumo.Timeout := Result.TimedOut;
  if (FResumo.MensagemErro = '') and (FMsgErroViva <> '') then
    FResumo.MensagemErro := FMsgErroViva;

  if Result.Canceled then
  begin
    FResumo.Ok := False;
    if FResumo.MensagemErro = '' then
      FResumo.MensagemErro := 'Cancelado pelo usuario.';
    DefinirEstado(ssCancelado);
  end
  else if Result.TimedOut then
  begin
    FResumo.Ok := False;
    if FResumo.MensagemErro = '' then
      FResumo.MensagemErro := 'Tempo limite excedido (timeout).';
    DefinirEstado(ssTimeout);
  end
  else if FResumo.Ok then
  begin
    Registrar(LC_APP, 'gfix concluido com sucesso (exit 0).');
    DefinirEstado(ssSucesso);
  end
  else
  begin
    RegistrarErro(FResumo.MensagemErro);
    DefinirEstado(ssFalha);
  end;

  if not Result.Ok then
    Result.ErrorText := FResumo.MensagemErro;
  Result.Summary := FResumo.LinhaFinal;
  if Result.Summary = '' then
    Result.Summary := FResumo.MensagemErro;
end;

end.
