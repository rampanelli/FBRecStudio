{
  uEngineGbak.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F2-A / F2-T1 (PLANO.md 4.2 Tecnica 1, 6.2/6.3/6.4): restore/backup
  via gbak, robusto e preparado para a UI do assistente (F2-B).

    * TPlanoGbak: plano (dados de entrada) do passo:
        GbakExe        - caminho completo do gbak;
        VersaoGbak     - TVersion do gbak (uFBVersionInfo) - o catalogo
                         de switches decide as chaves por versao;
        Origem/Destino - restore: backup.fbk -> banco; backup: banco -> .fbk;
        Modo           - mgRestoreCriar ('c') / mgRestoreSubstituir ('r')
                         / mgBackup ('b');
        Sobrescrever   - exigido quando Destino ja existe (seguranca);
        Usuario/Senha  - credenciais (-user/-pass, nunca em claro no log);
        Verboso(-v), NoGC(-g), Kill(-k), ModeRO(-mode read_only),
        FixFssMetadata/FixFssData (charset ou ''),
        ServiceName(-se), ArquivoErros(-y), ArgsExtras (livres,
        validados por lista negra), TimeoutMs (0 = sem timeout).
    * Regra de chaves: a engine NUNCA monta chave sozinha - usa
      ISwitchCatalog.ObterSwitch(bkGbak, Versao, semantica). O
      -FIX_FSS_* so entra quando o catalogo devolve a chave (FB
      1.5-2.5/IB6; FB3+ = '' -> ignorado com aviso, regra 4.2).
    * Lista negra de args extras (PLANO 6.3): -pass/-password/--password
      e redirecionamento > < | & (injecao) sao rejeitados.
    * Pre-checks (ValidarAmbiente): gbak existe, versao valida, origem
      existe, cria a pasta do destino, destino existente exige
      Sobrescrever (modo 'c' com destino existente falha amigavel),
      aviso de caminho longo (> 230 chars - limite MAX_PATH do gbak).
    * Execucao via IProcessRunner (uKernelExec); comando logado com
      senha mascarada (uQuoting.MakeDisplayCommandLine); o motor
      implementa IOutputSink interno: forwarda cada linha ao sink
      externo E registra no log (canais stdout/stderr) e captura para
      o parse (buffer com teto, sem memoria infinita).
    * Parse de saida (InterpretarSaidaGbak): exit 0 = ok salvo frase de
      erro; 'gbak: ERROR' / 'Exiting before completion' = falha;
      'finished' = terminou; TProcessResult.Summary vira LinhaFinal.
    * Extensao F3: IPassoValidacaoPos - plug para agendar a validacao
      pos-restore com gfix (engine F3); sem o plug o motor segue sem
      passo extra (nil-safe).

  Regras do repositorio: Delphi 7 puro, comentarios pt-BR ASCII,
  sem Forms, unidades <= 31 chars.
  ------------------------------------------------------------------
}
unit uEngineGbak;

{$H+}

interface

uses
  SysUtils, Classes, Windows, uLogger, uKernelExec, uQuoting,
  uEngineBase, uFBVersionInfo, uFBSwitchCatalog;

type
  // Modo de operacao do gbak (tarefa F2-A: c|r; 'b' = backup nativo
  // usado tambem pela Tecnica 2/exportacao na F5).
  TModoGbak = (mgRestoreCriar, mgRestoreSubstituir, mgBackup);


  // ------------------------------------------------------------------
  // Plano do passo gbak (dados de entrada; sem logica de negocio).
  // ------------------------------------------------------------------
  TPlanoGbak = class
  public
    GbakExe: string;          // caminho completo do gbak
    VersaoGbak: TVersion;     // versao do gbak (catalogo de switches)
    Origem: string;           // restore: arquivo .fbk/.gbk; backup: banco
    Destino: string;          // restore: banco; backup: arquivo .fbk
    Modo: TModoGbak;          // criar novo / substituir / backup
    Sobrescrever: Boolean;    // exigido quando Destino ja existe
    Usuario: string;          // -user (opcional)
    Senha: string;            // -pass (opcional; nunca logada em claro)
    Verboso: Boolean;         // -v
    NoGC: Boolean;            // -g (sem garbage collection)
    // -ig: restore/backup tolerante (ignora checksums ruins). Usado
    // pela recuperacao automatica quando o restore limpo falha.
    IgnorarChecksum: Boolean;
    FixFssMetadata: string;   // charset p/ -FIX_FSS_METADATA ('' = off)
    FixFssData: string;       // charset p/ -FIX_FSS_DATA ('' = off)
    Kill: Boolean;            // -k (restore sem sombras)
    ModeRO: Boolean;          // -mode read_only (restore)
    ServiceName: string;      // -se <servico> ('' = local)
    ArquivoErros: string;     // -y <arquivo> ('' = sem redirecionamento)
    ArgsExtras: TStringArray; // argumentos livres (lista negra aplicada)
    TimeoutMs: DWORD;         // 0 = sem timeout

    constructor Create;
    // Resumo seguro do plano p/ log/UI (SEM senha em claro).
    function PlanoParaTexto: string;
  end;

  // ------------------------------------------------------------------
  // Resumo da execucao do gbak (parse da saida + resultado do processo).
  // ------------------------------------------------------------------
  TResumoGbak = record
    Ok: Boolean;           // sucesso (exit 0 e sem frase de erro)
    ExitCode: DWORD;
    Cancelado: Boolean;
    Timeout: Boolean;
    Erro: Boolean;         // frase de erro vista ('gbak: ERROR'/exiting)
    Terminou: Boolean;     // 'finished' visto
    MensagemErro: string;  // 1a linha de erro (ou motivo generico)
    LinhaFinal: string;    // Summary do processo (ultima linha relevante)
  end;


  // ------------------------------------------------------------------
  // Plug da F3: produtor do passo de validacao pos-restore (gfix -v).
  // A engine F3 implementa e entrega um passo IRecoveryStep; sem o
  // plug o motor roda sem validacao automatica (nil-safe).
  // ------------------------------------------------------------------
  IPassoValidacaoPos = interface
    ['{B7E2C910-5D34-4F86-AA1B-9E0D4C7A8F31}']
    // Devolve o passo de validacao (gfix -v) ou nil quando nao ha.
    function CriarPassoValidacaoPos(const APlano: TPlanoGbak;
      const AResumo: TResumoGbak): IRecoveryStep;
  end;

  // ------------------------------------------------------------------
  // Motor do passo gbak (restore/backup). Herda TMotorePasso (estado/
  // risco/log) e implementa IOutputSink para capturar/rotear a saida.
  // ------------------------------------------------------------------
  TMotorGbak = class(TMotorePasso, IOutputSink)
  private
    FPlano: TPlanoGbak;
    FCatalogo: ISwitchCatalog;
    FArgv: TStringArray;
    FAvisos: TStringList;
    FErroAmbiente: string;
    FSaida: TStringList;       // linhas capturadas (com teto)
    FExtSink: IOutputSink;     // sink externo (forward)
    FMsgErroViva: string;      // 1a linha de erro (independente do teto)
    FTerminouVivo: Boolean;    // 'finished' visto em tempo real
    FResumo: TResumoGbak;
    FValidacaoPos: IPassoValidacaoPos;
    procedure ResetExec;
    function ComandoMascarado: string;
  public
    constructor Create(ALog: ILogPasso); overload;
    constructor CreateComCatalogo(ALog: ILogPasso;
      ACatalogo: ISwitchCatalog); overload;
    destructor Destroy; override;

    procedure AtribuirPlano(APlano: TPlanoGbak);

    // IRecoveryStep (overrides)
    function Descrever: string; override;
    function ValidarAmbiente(var Msg: string): Boolean; override;
    function BuildArgs: Boolean; override;
    function Executar(Runner: IProcessRunner;
                      Sink: IOutputSink): TProcessResult; override;

    // IOutputSink (uso interno; nao chamar diretamente)
    procedure OnLine(AStream: TStreamId; const ALine: string);
    procedure OnProcessEvent(AEvent: TProcEvent; const AInfo: string);

    property Argv: TStringArray read FArgv;
    property Resumo: TResumoGbak read FResumo;
    property Avisos: TStringList read FAvisos;
    property ErroAmbiente: string read FErroAmbiente;
    property PassoValidacaoPos: IPassoValidacaoPos read FValidacaoPos
      write FValidacaoPos;
  end;

// Funcoes livres (fora do bloco type - D7 nao permite funcao livre
// dentro de type).
function ModoParaChar(AModo: TModoGbak): Char;
function ModoParaTexto(AModo: TModoGbak): string;
function InterpretarSaidaGbak(const AExitCode: DWORD; ASaida: TStrings;
  const ASummaryProc: string): TResumoGbak;
function ValidarArgsExtras(const AArgs: TStringArray;
  out AMsg: string): Boolean;

implementation

const
  // Teto do buffer de saida capturado (evita memoria infinita com
  // restores verbose gigantes; a deteccao de frases e tempo real).
  K_CAP_SAIDA = 8000;
  // Aviso de caminho longo (gbak/utilitarios FB operam em ANSI com
  // limite MAX_PATH; gatinho de seguranca antes do limite duro).
  K_CAMINHO_LONGO = 230;

// ------------------------------------------------------------------
// ModoParaChar / ModoParaTexto
// ------------------------------------------------------------------
function ModoParaChar(AModo: TModoGbak): Char;
begin
  case AModo of
    mgRestoreCriar:      Result := 'c';
    mgRestoreSubstituir: Result := 'r';
    mgBackup:            Result := 'b';
  else
    Result := '?';
  end;
end;

function ModoParaTexto(AModo: TModoGbak): string;
begin
  case AModo of
    mgRestoreCriar:      Result := 'restore criar novo';
    mgRestoreSubstituir: Result := 'restore substituir';
    mgBackup:            Result := 'backup';
  else
    Result := 'desconhecido';
  end;
end;

// ------------------------------------------------------------------
// TPlanoGbak
// ------------------------------------------------------------------
constructor TPlanoGbak.Create;
begin
  inherited Create;
  Modo := mgRestoreCriar;
  Sobrescrever := False;
  TimeoutMs := 0;
  ZerarVersion(VersaoGbak);
end;

function TPlanoGbak.PlanoParaTexto: string;
begin
  Result := 'gbak (' + ModoParaTexto(Modo);
  if VersaoGbak.Valida then
    Result := Result + ' - ' + VersaoParaTexto(VersaoGbak);
  Result := Result + '): ' + Origem + ' -> ' + Destino;
end;

// ------------------------------------------------------------------
// ValidarArgsExtras (lista negra do PLANO 6.3)
// ------------------------------------------------------------------
function ValidarArgsExtras(const AArgs: TStringArray;
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
    // Keywords de senha (exatas ou com '=valor' - nunca permitir
    // credencial duplicada/injecao pela porta dos extras).
    if (Up = '-PASS') or (Up = '-PASSWORD') or (Up = '--PASSWORD') or
       (Copy(Up, 1, 6) = '-PASS=') or (Copy(Up, 1, 10) = '-PASSWORD=') or
       (Copy(Up, 1, 11) = '--PASSWORD=') then
    begin
      AMsg := 'argumento extra proibido: ' + AArgs[I] +
              ' (usar os campos Usuario/Senha do plano)';
      Result := False;
      Exit;
    end;
    // Redirecionamento / pipe / injecao (PLANO 6.3: > < | &).
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
// InterpretarSaidaGbak
// ------------------------------------------------------------------
function InterpretarSaidaGbak(const AExitCode: DWORD; ASaida: TStrings;
  const ASummaryProc: string): TResumoGbak;
var
  I: Integer;
  S: string;
begin
  Result.Ok := False;
  Result.ExitCode := AExitCode;
  Result.Cancelado := False;
  Result.Timeout := False;
  Result.Erro := False;
  Result.Terminou := False;
  Result.MensagemErro := '';
  Result.LinhaFinal := Trim(ASummaryProc);
  if ASaida <> nil then
    for I := 0 to ASaida.Count - 1 do
    begin
      S := LowerCase(ASaida[I]);
      if (Pos('gbak: error', S) > 0) or
         (Pos('exiting before completion', S) > 0) then
      begin
        Result.Erro := True;
        if Result.MensagemErro = '' then
          Result.MensagemErro := ASaida[I];
      end;
      if Pos('finished', S) > 0 then
        Result.Terminou := True;
    end;
  Result.Ok := (AExitCode = 0) and (not Result.Erro);
  if (not Result.Ok) and (Result.MensagemErro = '') then
    Result.MensagemErro := 'gbak terminou com codigo ' +
      IntToStr(Integer(AExitCode)) + '.';
end;

// ------------------------------------------------------------------
// TMotorGbak
// ------------------------------------------------------------------
constructor TMotorGbak.Create(ALog: ILogPasso);
begin
  // Risco default write; AtribuirPlano recalcula (destructive no
  // substituir, read-only no backup).
  inherited Create(rlWrite, ALog);
  FCatalogo := CriarCatalogPadrao;
  FAvisos := TStringList.Create;
  FSaida := TStringList.Create;
end;

constructor TMotorGbak.CreateComCatalogo(ALog: ILogPasso;
  ACatalogo: ISwitchCatalog);
begin
  Create(ALog);
  if ACatalogo <> nil then
    FCatalogo := ACatalogo;
end;

destructor TMotorGbak.Destroy;
begin
  FValidacaoPos := nil;
  FExtSink := nil;
  FAvisos.Free;
  FSaida.Free;
  inherited Destroy;
end;

procedure TMotorGbak.AtribuirPlano(APlano: TPlanoGbak);
begin
  FPlano := APlano;
  if FPlano <> nil then
  begin
    case FPlano.Modo of
      mgRestoreSubstituir: FRisco := rlDestructive;
      mgBackup:            FRisco := rlReadOnly;
    else
      FRisco := rlWrite;
    end;
    DefinirDescricao(Descrever);
  end;
end;

function TMotorGbak.Descrever: string;
begin
  if FPlano <> nil then
  begin
    Result := 'gbak: ' + ModoParaTexto(FPlano.Modo);
    if FPlano.VersaoGbak.Valida then
      Result := Result + ' (' + FamiliaParaTexto(FPlano.VersaoGbak.Familia) +
                ' ' + IntToStr(FPlano.VersaoGbak.Maior) + '.' +
                IntToStr(FPlano.VersaoGbak.Menor) + ')';
    Result := Result + ' de ' + ExtractFileName(FPlano.Origem) + ' -> ' +
              ExtractFileName(FPlano.Destino);
  end
  else
    Result := 'passo gbak (sem plano)';
end;

procedure TMotorGbak.ResetExec;
begin
  FSaida.Clear;
  FMsgErroViva := '';
  FTerminouVivo := False;
  FExtSink := nil;
  FResumo.Ok := False;
  FResumo.ExitCode := 0;
  FResumo.Cancelado := False;
  FResumo.Timeout := False;
  FResumo.Erro := False;
  FResumo.Terminou := False;
  FResumo.MensagemErro := '';
  FResumo.LinhaFinal := '';
end;

function TMotorGbak.ComandoMascarado: string;
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
  Full[0] := FPlano.GbakExe;
  for I := 0 to N - 1 do
    Full[I + 1] := FArgv[I];
  Result := uQuoting.MakeDisplayCommandLine(Full);
end;

// ------------------------------------------------------------------
// ValidarAmbiente (pre-checks da Tecnica 1)
// ------------------------------------------------------------------
function TMotorGbak.ValidarAmbiente(var Msg: string): Boolean;
var
  DirDest: string;
  OrigemFull, DestinoFull: string;
begin
  Msg := '';
  FErroAmbiente := '';
  FAvisos.Clear;
  if FPlano = nil then
  begin
    FErroAmbiente := 'Plano gbak nao atribuido ao motor.';
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;

  if FPlano.GbakExe = '' then
  begin
    FErroAmbiente := 'Informe o caminho do executavel gbak.';
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;
  if not FileExists(FPlano.GbakExe) then
  begin
    FErroAmbiente := 'gbak nao encontrado: ' + FPlano.GbakExe;
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;
  if not FPlano.VersaoGbak.Valida then
  begin
    FErroAmbiente := 'Versao do gbak nao reconhecida - impossivel ' +
                     'montar as chaves pelo catalogo de switches.';
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;

  if FPlano.Origem = '' then
  begin
    FErroAmbiente := 'Informe a origem (arquivo de backup ou banco).';
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;
  if not FileExists(FPlano.Origem) then
  begin
    FErroAmbiente := 'Origem nao encontrada: ' + FPlano.Origem;
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;
  if FPlano.Destino = '' then
  begin
    FErroAmbiente := 'Informe o destino (banco novo ou arquivo de backup).';
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;

  // Origem e Destino nunca podem ser o mesmo arquivo.
  OrigemFull := ExpandFileName(FPlano.Origem);
  DestinoFull := ExpandFileName(FPlano.Destino);
  if CompareText(OrigemFull, DestinoFull) = 0 then
  begin
    FErroAmbiente := 'Origem e destino sao o mesmo arquivo: ' + OrigemFull;
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;

  // Cria a pasta do destino quando necessario (permissao de escrita e
  // o pitfall classico do restore - PLANO 4.2 Tecnica 1).
  DirDest := ExtractFilePath(DestinoFull);
  if DirDest <> '' then
    ForceDirectories(DirDest);
  if (DirDest <> '') and (not DirectoryExists(DirDest)) then
  begin
    FErroAmbiente := 'Nao foi possivel criar a pasta do destino: ' +
                     DirDest + ' (verifique permissao de escrita).';
    Msg := FErroAmbiente;
    Result := False;
    Exit;
  end;

  // Aviso de caminho longo (nao bloqueia).
  if Length(OrigemFull) > K_CAMINHO_LONGO then
    FAvisos.Add('Caminho da origem tem ' + IntToStr(Length(OrigemFull)) +
                ' caracteres (>' + IntToStr(K_CAMINHO_LONGO) +
                '): risco de limite do gbak (MAX_PATH).');
  if Length(DestinoFull) > K_CAMINHO_LONGO then
    FAvisos.Add('Caminho do destino tem ' + IntToStr(Length(DestinoFull)) +
                ' caracteres (>' + IntToStr(K_CAMINHO_LONGO) +
                '): risco de limite do gbak (MAX_PATH).');

  // Destino ja existe: exige Sobrescrever explicito; modo criar novo
  // (-c) nao sobrescreve banco - orientar o usuario.
  if FileExists(FPlano.Destino) then
  begin
    if not FPlano.Sobrescrever then
    begin
      FErroAmbiente := 'O destino ja existe: ' + FPlano.Destino +
        '. Marque "Sobrescrever" (ou escolha outro nome de destino).';
      Msg := FErroAmbiente;
      Result := False;
      Exit;
    end;
    if FPlano.Modo = mgRestoreCriar then
    begin
      FErroAmbiente := 'O destino ja existe e o modo e "criar novo" ' +
        '(-c). Use o modo "substituir" (-r/-recreate) ou apague o ' +
        'arquivo de destino.';
      Msg := FErroAmbiente;
      Result := False;
      Exit;
    end;
  end;

  Result := True;
end;

// ------------------------------------------------------------------
// BuildArgs (argv tipado; chaves SOMENTE via ISwitchCatalog)
// ------------------------------------------------------------------
function TMotorGbak.BuildArgs: Boolean;
var
  Tok, Msg: string;
  ModoRestore: Boolean;
  I: Integer;

  procedure AddArg(const AArg: string);
  var
    N: Integer;
  begin
    N := Length(FArgv);
    SetLength(FArgv, N + 1);
    FArgv[N] := AArg;
  end;

begin
  Result := False;
  FArgv := nil;
  FErroAmbiente := '';
  if FPlano = nil then
  begin
    FErroAmbiente := 'Plano gbak nao atribuido ao motor.';
    Exit;
  end;
  if FPlano.Origem = '' then
  begin
    FErroAmbiente := 'Informe a origem.';
    Exit;
  end;
  if FPlano.Destino = '' then
  begin
    FErroAmbiente := 'Informe o destino.';
    Exit;
  end;

  ModoRestore := FPlano.Modo <> mgBackup;

  // 1) Token do modo via catalogo (nunca chave montada na engine).
  case FPlano.Modo of
    mgRestoreCriar:      Tok := FCatalogo.ObterSwitch(bkGbak,
                           FPlano.VersaoGbak, ssRestoreCriar);
    mgRestoreSubstituir: Tok := FCatalogo.ObterSwitch(bkGbak,
                           FPlano.VersaoGbak, ssRestoreSubstituir);
    mgBackup:            Tok := FCatalogo.ObterSwitch(bkGbak,
                           FPlano.VersaoGbak, ssBackupNativo);
  else
    Tok := '';
  end;
  if Tok = '' then
  begin
    FErroAmbiente := 'O gbak desta versao nao suporta o modo ' +
                     ModoParaTexto(FPlano.Modo) +
                     ' (catalogo de switches vazio).';
    Exit;
  end;
  AddArg(Tok);
  // FB 4+: catalogo devolve -recreate; o gbak exige o modificador
  // 'overwrite' quando substitui (docs/CATALOGO-SWITCHES.md linha 57).
  if Tok = '-recreate' then
    AddArg('overwrite');

  // 2) Opcoes comuns.
  if FPlano.Verboso then
    AddArg('-v');
  if FPlano.NoGC then
    AddArg('-g');
  // Restore/backup tolerante (-ig): recupera o maximo mesmo com
  // checksums ruins (chave via catalogo; aviso quando nao suportada).
  if FPlano.IgnorarChecksum then
  begin
    Tok := FCatalogo.ObterSwitch(bkGbak, FPlano.VersaoGbak,
           ssIgnorarChecksum);
    if Tok <> '' then
      AddArg(Tok)
    else
      FAvisos.Add('-ig (ignorar checksums) nao disponivel no catalogo ' +
                  'para o gbak ' + VersaoParaTexto(FPlano.VersaoGbak) +
                  '; executando sem tolerancia a checksum.');
  end;
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
  if FPlano.ServiceName <> '' then
  begin
    AddArg('-se');
    AddArg(FPlano.ServiceName);
  end;

  // 3) Opcoes exclusivas do restore (fix_fss, kill, mode).
  if ModoRestore then
  begin
    if FPlano.FixFssMetadata <> '' then
    begin
      Tok := FCatalogo.ObterSwitch(bkGbak, FPlano.VersaoGbak,
             ssFixFssMetadata);
      if Tok <> '' then
      begin
        AddArg(Tok);
        AddArg(FPlano.FixFssMetadata);
      end
      else
        FAvisos.Add('FIX_FSS_METADATA ignorado: o catalogo e vazio p/ ' +
                    'esta versao (' + VersaoParaTexto(FPlano.VersaoGbak) +
                    ').');
    end;
    if FPlano.FixFssData <> '' then
    begin
      Tok := FCatalogo.ObterSwitch(bkGbak, FPlano.VersaoGbak,
             ssFixFssData);
      if Tok <> '' then
      begin
        AddArg(Tok);
        AddArg(FPlano.FixFssData);
      end
      else
        FAvisos.Add('FIX_FSS_DATA ignorado: o catalogo e vazio p/ ' +
                    'esta versao (' + VersaoParaTexto(FPlano.VersaoGbak) +
                    ').');
    end;
    if FPlano.Kill then
    begin
      Tok := FCatalogo.ObterSwitch(bkGbak, FPlano.VersaoGbak, ssKill);
      if Tok <> '' then
        AddArg(Tok);
    end;
    if FPlano.ModeRO then
    begin
      Tok := FCatalogo.ObterSwitch(bkGbak, FPlano.VersaoGbak,
             ssModeReadOnly);
      if Tok <> '' then
      begin
        AddArg(Tok);
        AddArg('read_only');
      end;
    end;
  end
  else
  begin
    // Backup: opcoes de restore nao se aplicam - avisar (nao falhar).
    if FPlano.FixFssMetadata <> '' then
      FAvisos.Add('FIX_FSS_* aplica-se so ao restore; ignorado no backup.');
    if FPlano.FixFssData <> '' then
      FAvisos.Add('FIX_FSS_* aplica-se so ao restore; ignorado no backup.');
    if FPlano.Kill then
      FAvisos.Add('-k aplica-se so ao restore; ignorado no backup.');
    if FPlano.ModeRO then
      FAvisos.Add('-mode aplica-se so ao restore; ignorado no backup.');
  end;

  // 4) Arquivo de erros/saida (-y).
  if FPlano.ArquivoErros <> '' then
  begin
    Tok := FCatalogo.ObterSwitch(bkGbak, FPlano.VersaoGbak, ssErroSaida);
    if Tok <> '' then
    begin
      AddArg(Tok);
      AddArg(FPlano.ArquivoErros);
    end
    else
      FAvisos.Add('Arquivo de erros ignorado: catalogo vazio p/ esta ' +
                  'versao.');
  end;

  // 5) Argumentos extras livres - lista negra antes de aceitar.
  if not ValidarArgsExtras(FPlano.ArgsExtras, Msg) then
  begin
    FErroAmbiente := Msg;
    FArgv := nil;
    Exit;
  end;
  for I := 0 to Length(FPlano.ArgsExtras) - 1 do
    AddArg(FPlano.ArgsExtras[I]);

  // 6) Operandos posicionais SEMPRE por ultimo: Origem e Destino.
  AddArg(FPlano.Origem);
  AddArg(FPlano.Destino);

  Result := True;
end;

// ------------------------------------------------------------------
// IOutputSink (captura + forward + log)
// ------------------------------------------------------------------
procedure TMotorGbak.OnLine(AStream: TStreamId; const ALine: string);
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
    // Deteccao em tempo real (independe do teto do buffer).
    S := LowerCase(ALine);
    if (FMsgErroViva = '') and
       ((Pos('gbak: error', S) > 0) or
        (Pos('exiting before completion', S) > 0)) then
      FMsgErroViva := ALine;
    if Pos('finished', S) > 0 then
      FTerminouVivo := True;
    // Buffer com teto (parse pos-execucao usa as linhas retidas).
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

procedure TMotorGbak.OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
begin
  // Forward dos eventos de ciclo de vida ao sink externo (UI/relatorio).
  if FExtSink <> nil then
    FExtSink.OnProcessEvent(AEvent, AInfo);
end;

// ------------------------------------------------------------------
// Executar (rodar via IProcessRunner + parse)
// ------------------------------------------------------------------
function TMotorGbak.Executar(Runner: IProcessRunner;
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

  Opt.Executable := FPlano.GbakExe;
  Opt.WorkDir := '';
  Opt.Args := FArgv;
  Opt.TimeoutMs := FPlano.TimeoutMs;
  Opt.KillTreeOnCancel := True;   // cancelar/timeout mata a arvore (6.4)
  Opt.ConsoleCodePage := 0;       // OEM default (heuristica UTF-8 no sink)

  try
    Result := Runner.Run(Opt, Self);
  finally
    FExtSink := nil;
    Opt.Args := nil;
  end;
  // Parse + resumo (Summary do processo vira LinhaFinal).
  FResumo := InterpretarSaidaGbak(Result.ExitCode, FSaida, Result.Summary);
  FResumo.Cancelado := Result.Canceled;
  FResumo.Timeout := Result.TimedOut;
  // Deteccao em tempo real tem precedencia sobre o teto do buffer.
  if (FResumo.MensagemErro = '') and (FMsgErroViva <> '') then
    FResumo.MensagemErro := FMsgErroViva;
  if FTerminouVivo then
    FResumo.Terminou := True;

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
    Registrar(LC_APP, 'gbak concluido com sucesso (exit 0).');
    DefinirEstado(ssSucesso);
  end
  else
  begin
    RegistrarErro(FResumo.MensagemErro);
    DefinirEstado(ssFalha);
  end;

  // Contrato 6.2: ErrorText carrega o detalhe quando Ok = False.
  if not Result.Ok then
    Result.ErrorText := FResumo.MensagemErro;
  Result.Summary := FResumo.LinhaFinal;
  if Result.Summary = '' then
    Result.Summary := FResumo.MensagemErro;

  // Plug da F3: a engine de validacao gfix registra-se aqui (futuro).
  if FValidacaoPos <> nil then
    FValidacaoPos.CriarPassoValidacaoPos(FPlano, FResumo);
end;

end.
