{
  uFBSwitchCatalog.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F1-T2 (PLANO.md 4.2/6.2): catalogo de switches dos utilitarios
  Firebird/InterBase por (binario, versao, semantica). A UI/engine
  NUNCA monta a chave por conta propria: cada opcao semantica e
  mapeada aqui para a chave real (ou '' quando a versao nao suporta).

  Fontes desta F1 (nao ha bins reais nesta maquina):
    * gbak 2.5/3.0: tabela real de switches (src/burp/burpswi.h) do
      Firebird (tags R2_5_9 e v3.0.14 no GitHub) e mensagens de help.
    * gfix/isql: switches documentados nos manuais Firebird/InterBase.
  Divergencias e itens nao confirmados estao marcados 'a validar com
  bins reais' em docs/CATALOGO-SWITCHES.md (F7: help real via runtime
  probe - a estrutura de tabela permite substituir por linha).

  Regra de negocio (PLANO 4.2): -FIX_FSS_* so em gbak da familia
  1.5-2.5 (e IB6); o catalogo retorna '' para Firebird 3+.
  OBSERVACAO (documentada): o fonte do gbak v3.0.14 ainda define
  FIX_FSS (msgs 302/303) - a regra de negocio acima e mantida nesta
  F1; a F7 com bins reais decide (runtime probe).

  Delphi 7 puro: sem generics/anonymous/for..in. Identificadores em
  ingles salvo contrato de fase (TVersionMinimaParaOds,
  FamiliaProvavelParaOds).
  ------------------------------------------------------------------
}
unit uFBSwitchCatalog;

{$H+}

interface

uses
  uFBVersionInfo;

type
  // Utilitarios cujos switches o catalogo conhece.
  TBinKind = (bkGbak, bkGfix, bkIsql);

  // Opcao SEMANTICA pedida pela engine/UI. O catalogo devolve a chave
  // REAL do utilitario na versao informada (ou '' se nao suportado).
  // Valor do switch quando necessario (charset, read_only, arquivo,
  // SUPPRESS etc.) e anexado pela engine conforme a semantica - ver
  // docs/CATALOGO-SWITCHES.md.
  TSemanticSwitch = (
    // gbak
    ssRestoreCriar,        // restore em banco NOVO                (-c)
    ssRestoreSubstituir,   // restore SUBSTITUINDO banco existente (-r / -recreate)
    ssBackupNativo,        // backup completo                      (-b)
    ssBackupMetadados,     // backup somente metadados             (-m)
    ssVerboso,             // saida verbosa                        (-v)
    ssNoGc,                // inibe garbage collection no backup   (-g)
    ssFixFssMetadata,      // corrigir charset do metadata         (-FIX_FSS_METADATA)
    ssFixFssData,          // corrigir charset dos dados           (-FIX_FSS_DATA)
    ssKill,                // no gbak: restore sem criar sombras   (-k)
    ssModeReadOnly,        // modo read_only no banco restaurado   (-mode read_only)
    ssModeReadWrite,       // modo read_write no banco             (-mode read_write)
    ssService,             // usar services manager                (-se)
    ssUser,                // usuario                              (-user)
    ssPassword,            // senha                                (-pass/-password)
    ssErroSaida,           // redirecionar saida/erros a arquivo   (-y <arquivo>)
    ssSuppressSaida,       // suprimir saida de status/erros       (-y SUPPRESS)
    ssVersao,              // imprimir versao                      (-z)
    // gfix
    ssValidate,            // validar banco                        (-v)
    ssValidateFull,        // validacao completa                   (-full)
    ssMend,                // consertar banco                      (-mend)
    ssActivate,            // reativar banco em shutdown           (-activate)
    ssSweep,               // executar/ajustar sweep               (-sweep)
    ssHousekeepingOn,      // housekeeping ligado                  (-housekeeping on)
    ssHousekeepingOff,     // housekeeping desligado               (-housekeeping off)
    ssIcuOn,               // ICU habilitado                       (-icu on)
    ssIcuOff,              // ICU desabilitado                     (-icu off)
    // isql
    ssExtract,             // exportar DDL/dados                   (-extract)
    ssCharset              // charset de conexao                   (-charset)
  );

  // Contrato do catalogo (PLANO 6.2): resolve (binario, versao,
  // semantica) -> chave real ou ''. '' tambem quando a versao nao e
  // valida/conhecida (decisao conservadora: engine nao monta chave
  // sem versao confirmada).
  ISwitchCatalog = interface
    ['{8E7A1B20-4C31-4F1D-9E55-6C2A0B77D3F1}']
    function ObterSwitch(ABin: TBinKind; const AVer: TVersion;
      ASem: TSemanticSwitch): string;
  end;

// ------------------------------------------------------------------
// Funcoes publicas (tabela ODS x versao - PLANO 4.1.2 / F1-T4)
// ------------------------------------------------------------------

// Familia PROVAVEL que criou um banco com esta ODS (ods.h do Firebird:
// 8=IB4, 9=IB5, 10.0=IB6/FB1.0, 10.1=FB1.5, 11.x=FB2.x, 12=FB3,
// 13=FB4/5). Retorna False para ODS fora da tabela. Sempre confirmar
// com probe real (PLANO 4.1.3) - heuristica, validar na F7.
function FamiliaProvavelParaOds(AOdsMaior, AOdsMenor: Word;
  var AFamilia: TBFamilia): Boolean;

// Menor versao de servidor capaz de LER uma base com a ODS dada.
// Preenche AFamilia + AVer (Maior/Menor). Retorna False fora da tabela.
function TVersionMinimaParaOds(AOdsMaior, AOdsMenor: Word;
  var AFamilia: TBFamilia; var AVer: TVersion): Boolean;

// Nome legivel da semantica (relatorios/logs).
function SemanticaParaTexto(ASem: TSemanticSwitch): string;

// gbak desta versao suporta -FIX_FSS_*? (regra 4.2; usada pela
// auto-deteccao p/ preencher TBinSet.SuportaFixFss).
function GbakSuportaFixFss(const AVer: TVersion): Boolean;

// ------------------------------------------------------------------
// Implementacao default (tabela interna); mesma logica da interface.
// ------------------------------------------------------------------
function SwitchPadrao(ABin: TBinKind; const AVer: TVersion;
  ASem: TSemanticSwitch): string;

// Fabrica da implementacao default.
function CriarCatalogPadrao: ISwitchCatalog;

implementation

type
  // Familia da regra: bfDesconhecida = 'qualquer familia'.
  // Limites de versao inclusivos; Menor = -1 significa 'qualquer menor'
  // a partir do Maior; MaxMaior = -1 significa 'sem limite superior'.
  TRowSwitch = record
    Bin: TBinKind;
    Sem: TSemanticSwitch;
    Familia: TBFamilia;
    MinMaior: Integer;
    MinMenor: Integer;
    MaxMaior: Integer;
    MaxMenor: Integer;
    Token: string;
  end;

  // Linha da tabela ODS x versao. OdsMenor =  aceita qualquer
  // menor daquele maior.
  TRowOds = record
    OdsMaior: Word;
    OdsMenor: Word;
    Familia: TBFamilia;
    VMaior: Integer;
    VMenor: Integer;
  end;

const
  K_NENHUM = -1;

  // ------------------------------------------------------------------
  // Tabela v1. Ordem importa: regra mais especifica vem primeiro
  // (ex.: substitucao em FB3+ vs FB<=3; FIX_FSS por familia).
  // Chaves em caixa exata dos utilitarios (tokens aceitos em caixa
  // baixa/alta pelos utilitarios; a engine usa o que o catalogo devolve).
  // ------------------------------------------------------------------
  KTabela: array[0..41] of TRowSwitch = (
    // ============================== gbak ==============================
    (Bin: bkGbak; Sem: ssRestoreCriar;      Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-c'),
    (Bin: bkGbak; Sem: ssRestoreSubstituir; Familia: bfFirebird;
     MinMaior: 1; MinMenor: 0; MaxMaior: 3; MaxMenor: K_NENHUM; Token: '-r'),
    (Bin: bkGbak; Sem: ssRestoreSubstituir; Familia: bfFirebird;
     MinMaior: 4; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-recreate'),
    (Bin: bkGbak; Sem: ssRestoreSubstituir; Familia: bfInterBase;
     MinMaior: 4; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-r'),
    (Bin: bkGbak; Sem: ssBackupNativo;      Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-b'),
    (Bin: bkGbak; Sem: ssBackupMetadados;   Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-m'),
    (Bin: bkGbak; Sem: ssVerboso;           Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-v'),
    (Bin: bkGbak; Sem: ssNoGc;              Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-g'),
    // Regra de negocio 4.2: FIX_FSS so FB 1.5..2.5 e IB6 (FB3+ = '').
    (Bin: bkGbak; Sem: ssFixFssMetadata;    Familia: bfFirebird;
     MinMaior: 1; MinMenor: 5; MaxMaior: 2; MaxMenor: K_NENHUM; Token: '-FIX_FSS_METADATA'),
    (Bin: bkGbak; Sem: ssFixFssData;        Familia: bfFirebird;
     MinMaior: 1; MinMenor: 5; MaxMaior: 2; MaxMenor: K_NENHUM; Token: '-FIX_FSS_DATA'),
    (Bin: bkGbak; Sem: ssFixFssMetadata;    Familia: bfInterBase;
     MinMaior: 6; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-FIX_FSS_METADATA'),
    (Bin: bkGbak; Sem: ssFixFssData;        Familia: bfInterBase;
     MinMaior: 6; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-FIX_FSS_DATA'),
    (Bin: bkGbak; Sem: ssKill;              Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-k'),
    (Bin: bkGbak; Sem: ssModeReadOnly;      Familia: bfFirebird;
     MinMaior: 2; MinMenor: 5; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-mode'),
    (Bin: bkGbak; Sem: ssModeReadWrite;     Familia: bfFirebird;
     MinMaior: 2; MinMenor: 5; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-mode'),
    (Bin: bkGbak; Sem: ssService;           Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-se'),
    (Bin: bkGbak; Sem: ssUser;              Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-user'),
    (Bin: bkGbak; Sem: ssPassword;          Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-pass'),
    // gbak 1.5-2.5/3.0 redireciona/suprime com '-y' (msg 109 burp):
    (Bin: bkGbak; Sem: ssErroSaida;         Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 5; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-y'),
    (Bin: bkGbak; Sem: ssSuppressSaida;     Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 5; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-y'),
    (Bin: bkGbak; Sem: ssVersao;            Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-z'),
    // ============================== gfix ==============================
    (Bin: bkGfix; Sem: ssValidate;          Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-v'),
    (Bin: bkGfix; Sem: ssValidateFull;      Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-full'),
    (Bin: bkGfix; Sem: ssMend;              Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-mend'),
    (Bin: bkGfix; Sem: ssActivate;          Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-activate'),
    (Bin: bkGfix; Sem: ssSweep;             Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-sweep'),
    (Bin: bkGfix; Sem: ssHousekeepingOn;    Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-housekeeping'),
    (Bin: bkGfix; Sem: ssHousekeepingOff;   Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-housekeeping'),
    (Bin: bkGfix; Sem: ssModeReadOnly;      Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-mode'),
    (Bin: bkGfix; Sem: ssModeReadWrite;     Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-mode'),
    (Bin: bkGfix; Sem: ssKill;              Familia: bfFirebird;
     MinMaior: 3; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-kill'),
    (Bin: bkGfix; Sem: ssIcuOn;             Familia: bfFirebird;
     MinMaior: 2; MinMenor: 5; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-icu'),
    (Bin: bkGfix; Sem: ssIcuOff;            Familia: bfFirebird;
     MinMaior: 2; MinMenor: 5; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-icu'),
    (Bin: bkGfix; Sem: ssUser;              Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-user'),
    (Bin: bkGfix; Sem: ssPassword;          Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-pass'),
    (Bin: bkGfix; Sem: ssVersao;            Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-z'),
    // ============================== isql ==============================
    (Bin: bkIsql; Sem: ssExtract;           Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-extract'),
    (Bin: bkIsql; Sem: ssCharset;           Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-charset'),
    (Bin: bkIsql; Sem: ssUser;              Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-user'),
    (Bin: bkIsql; Sem: ssPassword;          Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-password'),
    (Bin: bkIsql; Sem: ssVersao;            Familia: bfDesconhecida;
     MinMaior: 1; MinMenor: 0; MaxMaior: K_NENHUM; MaxMenor: K_NENHUM; Token: '-z'),
    // ---- fim da tabela (guarda; nunca consultada) ----
    (Bin: bkGbak; Sem: ssRestoreCriar;      Familia: bfDesconhecida;
     MinMaior: 0; MinMenor: 0; MaxMaior: 0; MaxMenor: 0; Token: '')
  );

    KOds: array[0..8] of TRowOds = (
    (OdsMaior: 8;  OdsMenor: $FFFF; Familia: bfInterBase; VMaior: 4; VMenor: 0),
    (OdsMaior: 9;  OdsMenor: $FFFF; Familia: bfInterBase; VMaior: 5; VMenor: 0),
    (OdsMaior: 10; OdsMenor: 0;     Familia: bfInterBase; VMaior: 6; VMenor: 0),
    (OdsMaior: 10; OdsMenor: 1;     Familia: bfFirebird;  VMaior: 1; VMenor: 5),
    (OdsMaior: 11; OdsMenor: 0;     Familia: bfFirebird;  VMaior: 2; VMenor: 0),
    (OdsMaior: 11; OdsMenor: 1;     Familia: bfFirebird;  VMaior: 2; VMenor: 1),
    (OdsMaior: 11; OdsMenor: 2;     Familia: bfFirebird;  VMaior: 2; VMenor: 5),
    (OdsMaior: 12; OdsMenor: 0;     Familia: bfFirebird;  VMaior: 3; VMenor: 0),
    (OdsMaior: 13; OdsMenor: $FFFF; Familia: bfFirebird;  VMaior: 4; VMenor: 0)
  );

// ------------------------------------------------------------------
// VersaoDentro: a versao do utilitario esta na faixa da regra?
// ------------------------------------------------------------------
function VersaoDentro(const AVer: TVersion; ARow: TRowSwitch): Boolean;
begin
  Result := False;
  if not AVer.Valida then
    Exit;
  // Faixa de MAIOR
  if AVer.Maior < ARow.MinMaior then
    Exit;
  if ARow.MaxMaior <> K_NENHUM then
    if AVer.Maior > ARow.MaxMaior then
      Exit;
  // Faixa de MENOR (dentro do mesmo maior)
  if AVer.Maior = ARow.MinMaior then
    if (ARow.MinMenor <> K_NENHUM) and (AVer.Menor < ARow.MinMenor) then
      Exit;
  if (ARow.MaxMaior <> K_NENHUM) and (AVer.Maior = ARow.MaxMaior) then
    if (ARow.MaxMenor <> K_NENHUM) and (AVer.Menor > ARow.MaxMenor) then
      Exit;
  Result := True;
end;

// ------------------------------------------------------------------
// SemanticaParaTexto
// ------------------------------------------------------------------
function SemanticaParaTexto(ASem: TSemanticSwitch): string;
begin
  case ASem of
    ssRestoreCriar:      Result := 'restore criar novo';
    ssRestoreSubstituir: Result := 'restore substituir';
    ssBackupNativo:      Result := 'backup nativo';
    ssBackupMetadados:   Result := 'backup metadados';
    ssVerboso:           Result := 'verboso';
    ssNoGc:              Result := 'sem garbage collection';
    ssFixFssMetadata:    Result := 'fix fss metadata';
    ssFixFssData:        Result := 'fix fss data';
    ssKill:              Result := 'kill (sem sombras)';
    ssModeReadOnly:      Result := 'modo read_only';
    ssModeReadWrite:     Result := 'modo read_write';
    ssService:           Result := 'service manager';
    ssUser:              Result := 'usuario';
    ssPassword:          Result := 'senha';
    ssErroSaida:         Result := 'saida para arquivo';
    ssSuppressSaida:     Result := 'suprimir saida';
    ssVersao:            Result := 'versao';
    ssValidate:          Result := 'validar';
    ssValidateFull:      Result := 'validar completo';
    ssMend:              Result := 'mend';
    ssActivate:          Result := 'activate';
    ssSweep:             Result := 'sweep';
    ssHousekeepingOn:    Result := 'housekeeping on';
    ssHousekeepingOff:   Result := 'housekeeping off';
    ssIcuOn:             Result := 'icu on';
    ssIcuOff:            Result := 'icu off';
    ssExtract:           Result := 'extract';
    ssCharset:           Result := 'charset';
  else
    Result := 'desconhecida';
  end;
end;

// ------------------------------------------------------------------
// SwitchPadrao - busca na tabela KTabela (implementacao unica).
// ------------------------------------------------------------------
function SwitchPadrao(ABin: TBinKind; const AVer: TVersion;
  ASem: TSemanticSwitch): string;
var
  I: Integer;
begin
  Result := '';
  if not AVer.Valida then
    Exit; // sem versao confirmada o catalogo nao emite chave
  for I := Low(KTabela) to High(KTabela) - 1 do
    if (KTabela[I].Bin = ABin) and (KTabela[I].Sem = ASem) then
      if (KTabela[I].Familia = bfDesconhecida) or
         (KTabela[I].Familia = AVer.Familia) then
        if VersaoDentro(AVer, KTabela[I]) then
        begin
          Result := KTabela[I].Token;
          Exit;
        end;
end;

// ------------------------------------------------------------------
// GbakSuportaFixFss - mesma regra da tabela (FIX_FSS no gbak).
// ------------------------------------------------------------------
function GbakSuportaFixFss(const AVer: TVersion): Boolean;
begin
  Result := SwitchPadrao(bkGbak, AVer, ssFixFssMetadata) <> '';
end;

// ------------------------------------------------------------------
// Fabrica + implementacao da interface
// ------------------------------------------------------------------
type
  TCatalogPadrao = class(TInterfacedObject, ISwitchCatalog)
  public
    function ObterSwitch(ABin: TBinKind; const AVer: TVersion;
      ASem: TSemanticSwitch): string;
  end;

function TCatalogPadrao.ObterSwitch(ABin: TBinKind; const AVer: TVersion;
  ASem: TSemanticSwitch): string;
begin
  Result := SwitchPadrao(ABin, AVer, ASem);
end;

function CriarCatalogPadrao: ISwitchCatalog;
begin
  Result := TCatalogPadrao.Create;
end;

// ------------------------------------------------------------------
// FamiliaProvavelParaOds / TVersionMinimaParaOds
// ------------------------------------------------------------------
function LocalizarOds(AOdsMaior, AOdsMenor: Word; var ARow: TRowOds): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(KOds) to High(KOds) do
    if KOds[I].OdsMaior = AOdsMaior then
      if (KOds[I].OdsMenor = $FFFF) or (KOds[I].OdsMenor = AOdsMenor) then
      begin
        ARow := KOds[I];
        Result := True;
        Exit;
      end;
end;

function FamiliaProvavelParaOds(AOdsMaior, AOdsMenor: Word;
  var AFamilia: TBFamilia): Boolean;
var
  R: TRowOds;
begin
  Result := LocalizarOds(AOdsMaior, AOdsMenor, R);
  if Result then
    AFamilia := R.Familia;
end;

function TVersionMinimaParaOds(AOdsMaior, AOdsMenor: Word;
  var AFamilia: TBFamilia; var AVer: TVersion): Boolean;
var
  R: TRowOds;
begin
  Result := False;
  if LocalizarOds(AOdsMaior, AOdsMenor, R) then
  begin
    ZerarVersion(AVer);
    AVer.Familia := R.Familia;
    AVer.Maior := R.VMaior;
    AVer.Menor := R.VMenor;
    AVer.Valida := True;
    PreencherIntervaloOds(AVer);
    AFamilia := R.Familia;
    Result := True;
  end;
end;

end.