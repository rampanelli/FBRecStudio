{
  uSalvagePlan.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F4 (PLANO.md 4.2 Tecnica 4 "Salvage / extracao de dados de banco
  corrompido", secoes 6.1-6.4): as camadas do salvage e a regra de
  orquestracao. Sem Forms e sem dependencias de executaveis: apenas a
  "planta" que a UI (F4-T3/F6) e o motor (uMotorSalvage) seguem.

    * TGeraLayers: cada camada do plano. A ORDEM do enum ja e o fluxo
      default proposto p/ a UI (da menos para a mais invasiva):
        glCopia          - L0: copia forense byte a byte (uSafeCopy);
                           SEMPRE antes de tocar no original;
        glValidaGfix     - L1: validar a copia com gfix (read-only;
                           -mend opcional sob confirmacao);
        glBackupOQueAbre - L3: gbak -b do que abre (na copia reparada);
        glDatapumpTabelas- L2: extracao tabela a tabela pulando as
                           corrompidas (requer driver/FB real - aqui o
                           motor apenas reporta como "requer modulo de
                           exportacao F5/driver");
        glExtratorTexto  - L4 limitado: varredura de runs de texto
                           legivel (uExtratorTexto; nunca toca arquivo).
      Obs.: a numeracao L* segue a tabela do PLANO (L1 validar/mend,
      L2 datapump, L3 backup); o fluxo de execucao do salvage coloca o
      backup (L3) ANTES do datapump (L2), pois so faz sentido tentar a
      extracao fina depois de isolar o que abre num backup proprio.
    * TEstadoCamadaSalvage: registro honesto POR CAMADA do relatorio:
      nao tentada / tentada (rodando ou interrompida sem veredito) /
      ok / falha / ignorada (pulada por decisao do fluxo, ex.: datapump
      sem driver). O TSalvageRelatorio guarda um registro por camada e
      gera o texto "o que sobrou" (nada de sucesso implicito: o que nao
      rodou aparece como falha/ignorada).
    * Decisoes de fluxo (funcoes puras, testaveis por console):
        FluxoDefaultSalvage - todas as camadas, na ordem do enum; a
           regra L0-copia-sempre-primeiro e garantida aqui (nada e
           emitido antes de glCopia);
        CamadasParaEstado   - fluxo sugerido conforme o estado do
           banco: corrupcao leve (sem extrator de texto por padrao:
           valida/repara e faz backup do que abre) vs. sem backup bom
           (salvage completo ate o extrator de texto).

  Regras do repositorio: Delphi 7 puro (sem generics/anonymous/for..in),
  comentarios pt-BR ASCII, sem Forms, units <= 31 chars.
  ------------------------------------------------------------------
}
unit uSalvagePlan;

{$H+}

interface

type
  // Camada do salvage (ordem = fluxo default; numeracao L* no PLANO).
  TGeraLayers = (
    glCopia,            // L0 - copia forense (sempre 1a; uSafeCopy)
    glValidaGfix,       // L1 - validar/reparar a copia (gfix)
    glBackupOQueAbre,   // L3 - backup nativo do que abre (gbak -b)
    glDatapumpTabelas,  // L2 - extracao tabela a tabela (driver/F5)
    glExtratorTexto     // L4 - varredura de texto legivel (uExtratorTexto)
  );

  // Estado do banco p/ sugerir o fluxo (heuristica do diagnostico F1;
  // a UI/F4-T3 pode ajustar camada a camada).
  TSalvageEstado = (
    seCorrompidoLeve,   // corrupcao leve: gfix valida/repara e backup
                        // do que abre costumam bastar (sem L4 por padrao)
    seSemBackup,        // sem backup bom / corrupcao severa: salvage
                        // completo ate o extrator de texto
    seDesconhecido      // sem diagnostico: fluxo default completo
  );

  // Estado de vida de uma camada no relatorio (registro honesto).
  TEstadoCamadaSalvage = (
    csNaoTentada,       // ainda nao chegou a vez (ou plano recem-criado)
    csTentada,          // iniciada, sem veredito (rodando/interrompida)
    csOk,               // concluida com sucesso
    csFalha,            // tentada e falhou (motivo em Detalhe)
    csIgnorada          // pulada por decisao do fluxo (motivo em Detalhe)
  );

  // Um registro do relatorio: camada + estado + detalhe honesto.
  TRegistroCamada = record
    Camada: TGeraLayers;
    Estado: TEstadoCamadaSalvage;
    Detalhe: string;
  end;
  // ------------------------------------------------------------------
  // Relatorio do salvage: um registro POR CAMADA (nao um vetor solto),
  // com texto final honesto ("o que sobrou"). Criado ja preenchido com
  // todas as camadas como csNaoTentada.
  // ------------------------------------------------------------------
  TSalvageRelatorio = class
  private
    FRegistros: array of TRegistroCamada;
    function IndiceDaCamada(ACamada: TGeraLayers): Integer;
  public
    constructor Create;
    destructor Destroy; override;

    // Zera tudo (todas as camadas voltam a csNaoTentada).
    procedure Reset;

    // Registra o resultado de uma camada (substitui o registro atual).
    procedure Marcar(ACamada: TGeraLayers;
      AEstado: TEstadoCamadaSalvage; const ADetalhe: string);

    function EstadoDe(ACamada: TGeraLayers): TEstadoCamadaSalvage;
    function DetalheDe(ACamada: TGeraLayers): string;

    // Conveniencias de leitura (p/ testes e UI).
    function TemFalha: Boolean;      // alguma camada em csFalha?
    function TodasConcluidas: Boolean; // sem camada em tentada/nao tentada

    // Texto honesto: uma linha por camada (L<num> nome: estado - detalhe).
    function ResumoHonesto: string;
    // Texto curto da camada que MAIS sobrou (1a falha, senao a camada
    // mais util ainda por rodar). Auxiliar da UI (F4-T3).
    function CamadaMaisCritica: TGeraLayers;
    function CamadaMaisCriticaParaTexto: string;
  end;

// Rotulo "L0".."L4" da camada (numeracao do PLANO 4.2 Tecnica 4).
function RotuloNivel(ACamada: TGeraLayers): string;

// Nome curto pt-BR da camada ("copia forense (L0)", "validar gfix"...).
function CamadaParaTexto(ACamada: TGeraLayers): string;

// Estado da camada em texto pt-BR curto.
function EstadoCamadaParaTexto(AEstado: TEstadoCamadaSalvage): string;

// Estado do banco em texto pt-BR curto.
function SalvageEstadoParaTexto(AEstado: TSalvageEstado): string;

// ------------------------------------------------------------------
// Fluxo default do salvage: TODAS as camadas na ordem do enum
// (glCopia sempre primeiro - regra da fase). Devolve o numero de
// camadas gravadas em ACamadas (vetor alocado pelo chamador).
// ------------------------------------------------------------------
function FluxoDefaultSalvage(var ACamadas: array of TGeraLayers): Integer;

// ------------------------------------------------------------------
// Fluxo sugerido conforme o estado do banco (decisao por estado):
//   seCorrompidoLeve  -> copia, validar gfix, backup do que abre
//                        (sem datapump/extrator por padrao);
//   seSemBackup       -> todas as 5 camadas (salvage completo);
//   seDesconhecido    -> fluxo default completo.
// A regra L0-copia-sempre-primeiro vale em TODOS os estados (a 1a
// camada emitida e sempre glCopia). Devolve o numero gravado.
// ------------------------------------------------------------------
function CamadasParaEstado(AEstado: TSalvageEstado;
  var ACamadas: array of TGeraLayers): Integer;

// Fluxo em texto (uma camada por linha), p/ log e UI.
function FluxoParaTexto(const ACamadas: array of TGeraLayers;
  AQuantas: Integer): string;

// True quando a camada opera sobre a COPIA forense (nunca no original).
// L0 cria a copia; L1/L3 trabalham na copia; L4 apenas le.
function CamadaUsaCopia(ACamada: TGeraLayers): Boolean;

// True quando a camada e obrigatoria p/ o veredito do fluxo completo
// (as demais podem ser puladas sem invalidar o "o que sobrou").
function CamadaEssencial(ACamada: TGeraLayers): Boolean;

implementation

uses
  SysUtils;
const
  K_CAMADA_NOME: array [TGeraLayers] of string = (
    'copia forense (L0)',
    'validar/reparar gfix (L1)',
    'backup do que abre - gbak (L3)',
    'datapump tabela a tabela (L2)',
    'extrator de texto (L4)'
  );

  K_ROTULO_NIVEL: array [TGeraLayers] of string = (
    'L0', 'L1', 'L3', 'L2', 'L4'
  );

// ------------------------------------------------------------------
// TSalvageRelatorio
// ------------------------------------------------------------------
constructor TSalvageRelatorio.Create;
var
  C: TGeraLayers;
  N: Integer;
begin
  inherited Create;
  N := Ord(High(TGeraLayers)) + 1;
  SetLength(FRegistros, N);
  for C := Low(TGeraLayers) to High(TGeraLayers) do
  begin
    FRegistros[Ord(C)].Camada := C;
    FRegistros[Ord(C)].Estado := csNaoTentada;
    FRegistros[Ord(C)].Detalhe := '';
  end;
end;

destructor TSalvageRelatorio.Destroy;
begin
  FRegistros := nil;
  inherited Destroy;
end;

function TSalvageRelatorio.IndiceDaCamada(ACamada: TGeraLayers): Integer;
begin
  Result := Ord(ACamada);
  if (Result < 0) or (Result > Ord(High(TGeraLayers))) then
    Result := -1;
end;

procedure TSalvageRelatorio.Reset;
var
  C: TGeraLayers;
begin
  for C := Low(TGeraLayers) to High(TGeraLayers) do
  begin
    FRegistros[Ord(C)].Estado := csNaoTentada;
    FRegistros[Ord(C)].Detalhe := '';
  end;
end;

procedure TSalvageRelatorio.Marcar(ACamada: TGeraLayers;
  AEstado: TEstadoCamadaSalvage; const ADetalhe: string);
var
  I: Integer;
begin
  I := IndiceDaCamada(ACamada);
  if I < 0 then
    Exit;
  FRegistros[I].Estado := AEstado;
  FRegistros[I].Detalhe := ADetalhe;
end;
function TSalvageRelatorio.EstadoDe(ACamada: TGeraLayers): TEstadoCamadaSalvage;
var
  I: Integer;
begin
  I := IndiceDaCamada(ACamada);
  if I < 0 then
    Result := csNaoTentada
  else
    Result := FRegistros[I].Estado;
end;

function TSalvageRelatorio.DetalheDe(ACamada: TGeraLayers): string;
var
  I: Integer;
begin
  I := IndiceDaCamada(ACamada);
  if I < 0 then
    Result := ''
  else
    Result := FRegistros[I].Detalhe;
end;

function TSalvageRelatorio.TemFalha: Boolean;
var
  C: TGeraLayers;
begin
  Result := False;
  for C := Low(TGeraLayers) to High(TGeraLayers) do
    if FRegistros[Ord(C)].Estado = csFalha then
    begin
      Result := True;
      Exit;
    end;
end;

function TSalvageRelatorio.TodasConcluidas: Boolean;
var
  C: TGeraLayers;
begin
  Result := True;
  for C := Low(TGeraLayers) to High(TGeraLayers) do
    if (FRegistros[Ord(C)].Estado = csNaoTentada) or
       (FRegistros[Ord(C)].Estado = csTentada) then
    begin
      Result := False;
      Exit;
    end;
end;

function TSalvageRelatorio.ResumoHonesto: string;
var
  C: TGeraLayers;
  S: string;
begin
  Result := '';
  for C := Low(TGeraLayers) to High(TGeraLayers) do
  begin
    S := RotuloNivel(C) + ' ' + CamadaParaTexto(C) + ': ' +
         EstadoCamadaParaTexto(FRegistros[Ord(C)].Estado);
    if FRegistros[Ord(C)].Detalhe <> '' then
      S := S + ' - ' + FRegistros[Ord(C)].Detalhe;
    if Result <> '' then
      Result := Result + #13#10;
    Result := Result + S;
  end;
end;
function TSalvageRelatorio.CamadaMaisCritica: TGeraLayers;
var
  C: TGeraLayers;
begin
  Result := High(TGeraLayers);
  // 1a falha (tentou e nao conseguiu) tem prioridade no relatorio.
  for C := Low(TGeraLayers) to High(TGeraLayers) do
    if FRegistros[Ord(C)].Estado = csFalha then
    begin
      Result := C;
      Exit;
    end;
  // Senao, a 1a camada que ficou por rodar (nao tentada).
  for C := Low(TGeraLayers) to High(TGeraLayers) do
    if FRegistros[Ord(C)].Estado = csNaoTentada then
    begin
      Result := C;
      Exit;
    end;
end;

function TSalvageRelatorio.CamadaMaisCriticaParaTexto: string;
begin
  Result := RotuloNivel(CamadaMaisCritica) + ' ' +
            CamadaParaTexto(CamadaMaisCritica);
end;

// ------------------------------------------------------------------
// Funcoes livres
// ------------------------------------------------------------------
function RotuloNivel(ACamada: TGeraLayers): string;
begin
  Result := K_ROTULO_NIVEL[ACamada];
end;

function CamadaParaTexto(ACamada: TGeraLayers): string;
begin
  Result := K_CAMADA_NOME[ACamada];
end;

function EstadoCamadaParaTexto(AEstado: TEstadoCamadaSalvage): string;
begin
  case AEstado of
    csNaoTentada: Result := 'nao tentada';
    csTentada:    Result := 'tentada';
    csOk:         Result := 'ok';
    csFalha:      Result := 'falha';
    csIgnorada:   Result := 'ignorada';
  else
    Result := 'desconhecido';
  end;
end;

function SalvageEstadoParaTexto(AEstado: TSalvageEstado): string;
begin
  case AEstado of
    seCorrompidoLeve: Result := 'corrupcao leve';
    seSemBackup:      Result := 'sem backup bom / corrupcao severa';
    seDesconhecido:   Result := 'desconhecido';
  else
    Result := 'desconhecido';
  end;
end;
function FluxoDefaultSalvage(var ACamadas: array of TGeraLayers): Integer;
var
  C: TGeraLayers;
  I: Integer;
begin
  I := 0;
  // Regra da fase: a copia forense e SEMPRE a 1a camada. Nenhuma outra
  // camada (nem o L4, read-only) e emitida antes dela: o fluxo inteiro
  // roda sobre a copia e o original so e lido apos existir um snapshot.
  for C := Low(TGeraLayers) to High(TGeraLayers) do
    if I < Length(ACamadas) then
    begin
      ACamadas[I] := C;
      Inc(I);
    end;
  Result := I;
end;

function CamadasParaEstado(AEstado: TSalvageEstado;
  var ACamadas: array of TGeraLayers): Integer;
var
  I: Integer;

  procedure Emitir(ACamada: TGeraLayers);
  begin
    if I < Length(ACamadas) then
      ACamadas[I] := ACamada;
    Inc(I);
  end;

begin
  I := 0;
  // Em QUALQUER estado a 1a camada e a copia forense (L0).
  Emitir(glCopia);
  case AEstado of
    seCorrompidoLeve:
      begin
        // Reparo/validacao da copia + backup do que abrir: sem L4 por
        // padrao (os dados devem sair pelo backup/datapump normal).
        Emitir(glValidaGfix);
        Emitir(glBackupOQueAbre);
      end;
    seSemBackup:
      begin
        // Salvage completo: tudo, inclusive o extrator de texto.
        Emitir(glValidaGfix);
        Emitir(glBackupOQueAbre);
        Emitir(glDatapumpTabelas);
        Emitir(glExtratorTexto);
      end;
  else
    // seDesconhecido: fluxo default completo (todas as camadas).
    Emitir(glValidaGfix);
    Emitir(glBackupOQueAbre);
    Emitir(glDatapumpTabelas);
    Emitir(glExtratorTexto);
  end;
  Result := I;
end;

function FluxoParaTexto(const ACamadas: array of TGeraLayers;
  AQuantas: Integer): string;
var
  I: Integer;
begin
  Result := '';
  if AQuantas > Length(ACamadas) then
    AQuantas := Length(ACamadas);
  for I := 0 to AQuantas - 1 do
  begin
    if Result <> '' then
      Result := Result + #13#10;
    Result := Result + IntToStr(I + 1) + '. ' + RotuloNivel(ACamadas[I]) +
              ' ' + CamadaParaTexto(ACamadas[I]);
  end;
end;

function CamadaUsaCopia(ACamada: TGeraLayers): Boolean;
begin
  // L0 cria a copia; L1/L3 trabalham sobre ela. O L4 (leitura bruta)
  // pode ler qualquer um dos dois (o motor decide); nao "usa a copia"
  // como alvo de escrita.
  Result := (ACamada = glValidaGfix) or (ACamada = glBackupOQueAbre);
end;

function CamadaEssencial(ACamada: TGeraLayers): Boolean;
begin
  // A copia forense e inegociavel; as demais sao esforco de melhor
  // esforco (o relatorio honesto mostra o que faltou).
  Result := ACamada = glCopia;
end;

end.
