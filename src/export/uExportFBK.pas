{
  uExportFBK.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F5 / F5-T1 (PLANO.md 4.3 Exportacao, 4.2 Tecnica 2/backup nativo):
  exportacao para .fbk nativo reutilizando a engine uEngineGbak.

    * NAO duplica nem altera engines existentes: o exportador prepara
      um TPlanoGbak no modo mgBackup com os campos JA existentes
      (Origem/Destino/Sobrescrever/Usuario/Senha/Verboso/NoGC/TimeoutMs)
      e entrega ao TMotorGbak (catalogo de switches decide '-b'/'-v'/'-g'
      e '-user'/'-pass'; credenciais nunca em claro no log).
    * Garante a extensao '.fbk' do destino (regra de nomenclatura F5).
    * Sobrescrever: destino existente exige params.Sobrescrever = True
      (mesmo criterio de seguranca das engines; validado no Preparar E
      revalidado pelo motor no Executar).
    * Preparar valida pasta/caminhos/sobrescrever/gbak/versao SEM
      executar; Executar roda o motor e registra a saida no
      TManifestoExport (arquivo .fbk; linhas nao mensuraveis = -1).
    * Falha no processo: arquivo parcial criado pelo gbak e apagado
      (quando o destino nao existia antes) - nada de "sucesso sujo".

  Regras do repositorio: Delphi 7 puro (sem generics/anonymous/for..in),
  comentarios pt-BR ASCII, sem Forms, unidades <= 31 chars.
  ------------------------------------------------------------------
}
unit uExportFBK;

{$H+}

interface

uses
  SysUtils, Classes, uExportBase, uEngineBase, uEngineGbak, uKernelExec,
  uFBSwitchCatalog, uFBVersionInfo;

type
  // ------------------------------------------------------------------
  // Exportador .fbk nativo: gbak -b do banco recuperado (F5-T1).
  // Sem driver: roda com o subprocesso gbak (fake bins nos testes).
  // ------------------------------------------------------------------
  TExportadorFBK = class(TExportadorBase)
  private
    FCatalogo: ISwitchCatalog;
  public
    constructor Create; overload;
    // Catalogo explicito (testes) ou nil = catalogo padrao (F1).
    constructor CreateComCatalogo(ACatalogo: ISwitchCatalog); overload;

    function FormatoAlvo: TFormatoExport; override;
    function Preparar(const AParams: TExportParams;
      var Msg: string): Boolean; override;
    function Executar(Runner: IProcessRunner; Sink: IOutputSink;
      var Manifesto: TManifestoExport): Boolean; override;

    property Catalogo: ISwitchCatalog read FCatalogo;
  end;

implementation

// ------------------------------------------------------------------
// TExportadorFBK
// ------------------------------------------------------------------
constructor TExportadorFBK.Create;
begin
  inherited Create;
  FCatalogo := nil;   // motor usa o catalogo padrao (engine F1)
end;

constructor TExportadorFBK.CreateComCatalogo(ACatalogo: ISwitchCatalog);
begin
  Create;
  if ACatalogo <> nil then
    FCatalogo := ACatalogo;
end;

function TExportadorFBK.FormatoAlvo: TFormatoExport;
begin
  Result := feFbk;
end;

// ------------------------------------------------------------------
// Preparar: valida sem executar (4.3: pasta/caminhos/sobrescrever).
// ------------------------------------------------------------------
function TExportadorFBK.Preparar(const AParams: TExportParams;
  var Msg: string): Boolean;
var
  DirDest: string;
begin
  ZerarEstado;
  FParams := AParams;
  Result := ValidarParamsBasico(Msg);
  if not Result then
    Exit;

  // Binario e versao exigidos (catalogo de switches monta as chaves).
  if FParams.GbakExe = '' then
  begin
    Msg := 'Informe o caminho do executavel gbak.';
    Result := False;
    FErroPreparacao := Msg;
    Exit;
  end;
  if not FileExists(FParams.GbakExe) then
  begin
    Msg := 'gbak nao encontrado: ' + FParams.GbakExe;
    Result := False;
    FErroPreparacao := Msg;
    Exit;
  end;
  if not FParams.VersaoBin.Valida then
  begin
    Msg := 'Versao do gbak nao reconhecida - impossivel montar as ' +
           'chaves pelo catalogo de switches.';
    Result := False;
    FErroPreparacao := Msg;
    Exit;
  end;

  // Pasta destino: criar quando possivel (mesma regra das engines).
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

  // Destino unico com extensao '.fbk' garantida.
  FDestino := DestinoUnico('fbk');

  // Origem e destino nunca podem ser o mesmo arquivo.
  if CompareText(ExpandFileName(FParams.Origem),
                 ExpandFileName(FDestino)) = 0 then
  begin
    Msg := 'Origem e destino sao o mesmo arquivo: ' + ExpandFileName(FDestino) +
           '. Escolha outra pasta/nome para o .fbk.';
    Result := False;
    FErroPreparacao := Msg;
    Exit;
  end;

  // Sobrescrever explicito quando o destino ja existe.
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
// Executar: roda gbak -b via TMotorGbak e preenche o manifesto.
// ------------------------------------------------------------------
function TExportadorFBK.Executar(Runner: IProcessRunner; Sink: IOutputSink;
  var Manifesto: TManifestoExport): Boolean;
var
  Motor: TMotorGbak;
  Plano: TPlanoGbak;
  R: IProcessRunner;
  MsgAmb: string;
  Ok: Boolean;
  PreExistia: Boolean;
  Detalhe: string;
begin
  Result := False;
  if Manifesto = nil then
    Exit;
  if (not FPreparado) or (FParams = nil) then
  begin
    Manifesto.AddItem('', feFbk, '', -1, xeFalha,
      'Chame Preparar (com sucesso) antes de Executar.');
    Exit;
  end;

  Plano := TPlanoGbak.Create;
  Motor := nil;
  try
    Plano.GbakExe := FParams.GbakExe;
    Plano.VersaoGbak := FParams.VersaoBin;
    Plano.Origem := FParams.Origem;
    Plano.Destino := FDestino;
    Plano.Modo := mgBackup;              // '-b' (chave via catalogo)
    Plano.Sobrescrever := FParams.Sobrescrever;
    Plano.Usuario := FParams.Usuario;
    Plano.Senha := FParams.Senha;        // nunca logada em claro
    Plano.Verboso := FParams.Verboso;    // '-v'
    Plano.NoGC := FParams.NoGC;          // '-g'
    Plano.TimeoutMs := FParams.TimeoutMs;

    Motor := TMotorGbak.CreateComCatalogo(nil, FCatalogo);
    Motor.AtribuirPlano(Plano);

    // Pre-checks do motor (binario/versao/origem/destino existente).
    if not Motor.ValidarAmbiente(MsgAmb) then
    begin
      Manifesto.AddItem(FDestino, feFbk, '', -1, xeFalha,
        'pre-checks: ' + MsgAmb);
      Exit;
    end;
    if not Motor.BuildArgs then
    begin
      Manifesto.AddItem(FDestino, feFbk, '', -1, xeFalha,
        'montagem do argv falhou: ' + Motor.ErroAmbiente);
      Exit;
    end;

    // Runner nil = cria TProcessRunner interno (uso console/teste).
    if Runner <> nil then
      R := Runner
    else
      R := TProcessRunner.Create;

    PreExistia := FileExists(FDestino);
    Motor.Executar(R, Sink);

    Ok := Motor.Resumo.Ok and FileExists(FDestino);
    if Ok then
    begin
      // Avisos nao fatais do motor entram no detalhe do item.
      if Motor.Avisos.Count > 0 then
        Detalhe := 'gbak -b concluido; avisos: ' + Motor.Avisos[0]
      else
        Detalhe := 'gbak -b concluido (exit 0).';
      Manifesto.AddItem(FDestino, feFbk, '', -1, xeOk, Detalhe);
    end
    else
    begin
      if Motor.Resumo.MensagemErro <> '' then
        Detalhe := Motor.Resumo.MensagemErro
      else if not FileExists(FDestino) then
        Detalhe := 'gbak terminou mas o arquivo .fbk nao foi criado.'
      else
        Detalhe := 'gbak terminou com codigo ' +
                   IntToStr(Integer(Motor.Resumo.ExitCode)) + '.';
      Manifesto.AddItem(FDestino, feFbk, '', -1, xeFalha, Detalhe);
      // Sem arquivo parcial sujo: apaga so o que o processo criou.
      if (not PreExistia) and FileExists(FDestino) then
        SysUtils.DeleteFile(FDestino);
    end;
    Result := Ok;
  finally
    Motor.Free;
    Plano.Free;
  end;
end;

end.