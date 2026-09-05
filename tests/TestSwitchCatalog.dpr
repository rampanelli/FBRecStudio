program TestSwitchCatalog;

{ Testes unitarios de uFBSwitchCatalog (F1-T2): catalogo de switches
  por (binario, versao, semantica) + tabela ODS x versao (F1-T4).
  Regra de negocio: -FIX_FSS_* so gbak FB 1.5-2.5 / IB6 (FB3+ = '').
  Console; exit = n. de falhas. }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils,
  uFBVersionInfo in '..\src\firebird\uFBVersionInfo.pas',
  uFBSwitchCatalog in '..\src\firebird\uFBSwitchCatalog.pas';

var
  Fails, Checks: Integer;

procedure Check(const AName: string; ACond: Boolean);
begin
  Inc(Checks);
  if ACond then
    WriteLn('PASS: ' + AName)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL: ' + AName);
  end;
end;

// Monta uma TVersion valida a partir de uma linha '-z' conhecida.
function Ver(const ATexto: string): TVersion;
begin
  ZerarVersion(Result);
  if not ParseVersaoTexto(ATexto, Result) then
    Result.Valida := False;
end;

// Conferencia curta: SwitchPadrao(bin, versao, sem) = esperado.
procedure Espera(ABin: TBinKind; const AVer: TVersion; ASem: TSemanticSwitch;
  const AEsperado: string; const AName: string);
begin
  Check(AName + ' -> ' + AEsperado,
        SwitchPadrao(ABin, AVer, ASem) = AEsperado);
end;

var
  V15, V25, V30, V40, IB6, IB5: TVersion;
  VInv: TVersion;
  F: TBFamilia;
  VMin: TVersion;
  Cat: ISwitchCatalog;
begin
  Fails := 0;
  Checks := 0;

  V15 := Ver('LI-V1.5.6.5026 Firebird 1.5');
  V25 := Ver('gbak version LI-V2.5.9.27110 Firebird 2.5');
  V30 := Ver('LI-V3.0.7.33355 Firebird 3.0');
  V40 := Ver('LI-V4.0.1.2696 Firebird 4.0');
  IB6 := Ver('LI-V6.0.1.6 InterBase');
  IB5 := Ver('InterBase 5.0');
  Check('vetores base validos', V15.Valida and V25.Valida and V30.Valida and
        V40.Valida and IB6.Valida and IB5.Valida);

  // ======================= gbak =======================
  Espera(bkGbak, V25, ssRestoreCriar, '-c', 'gbak 2.5 restore criar');
  Espera(bkGbak, V25, ssRestoreSubstituir, '-r', 'gbak 2.5 substituir');
  Espera(bkGbak, V25, ssBackupNativo, '-b', 'gbak 2.5 backup');
  Espera(bkGbak, V25, ssBackupMetadados, '-m', 'gbak 2.5 backup md');
  Espera(bkGbak, V25, ssVerboso, '-v', 'gbak 2.5 verboso');
  Espera(bkGbak, V25, ssNoGc, '-g', 'gbak 2.5 no gc');
  Espera(bkGbak, V25, ssKill, '-k', 'gbak 2.5 kill');
  Espera(bkGbak, V25, ssModeReadOnly, '-mode', 'gbak 2.5 mode ro');
  Espera(bkGbak, V25, ssModeReadWrite, '-mode', 'gbak 2.5 mode rw');
  Espera(bkGbak, V25, ssService, '-se', 'gbak 2.5 -se');
  Espera(bkGbak, V25, ssUser, '-user', 'gbak 2.5 user');
  Espera(bkGbak, V25, ssPassword, '-pass', 'gbak 2.5 pass');
  Espera(bkGbak, V25, ssErroSaida, '-y', 'gbak 2.5 saida arquivo');
  Espera(bkGbak, V25, ssSuppressSaida, '-y', 'gbak 2.5 suppress');
  Espera(bkGbak, V25, ssVersao, '-z', 'gbak 2.5 -z');

  // regra de negocio 4.2: FIX_FSS so 1.5-2.5 (fb) e IB6
  Espera(bkGbak, V25, ssFixFssMetadata, '-FIX_FSS_METADATA',
         'gbak 2.5 fix fss metadata');
  Espera(bkGbak, V25, ssFixFssData, '-FIX_FSS_DATA', 'gbak 2.5 fix fss data');
  Espera(bkGbak, V15, ssFixFssMetadata, '-FIX_FSS_METADATA',
         'gbak 1.5 fix fss metadata');
  Espera(bkGbak, IB6, ssFixFssMetadata, '-FIX_FSS_METADATA',
         'gbak IB6 fix fss metadata');
  Espera(bkGbak, V30, ssFixFssMetadata, '', 'gbak 3.0 fix fss = vazio');
  Espera(bkGbak, V30, ssFixFssData, '', 'gbak 3.0 fix fss data = vazio');
  Espera(bkGbak, V40, ssFixFssMetadata, '', 'gbak 4.0 fix fss = vazio');
  Espera(bkGbak, IB5, ssFixFssMetadata, '', 'gbak IB5 fix fss = vazio');

  // substituicao em FB4+ vira -recreate
  Espera(bkGbak, V30, ssRestoreSubstituir, '-r', 'gbak 3.0 substituir -r');
  Espera(bkGbak, V40, ssRestoreSubstituir, '-recreate',
         'gbak 4.0 substituir -recreate');
  Espera(bkGbak, IB6, ssRestoreSubstituir, '-r', 'gbak IB6 substituir -r');

  // gbak IB nao tem -mode (regra so fb >= 2.5)
  Espera(bkGbak, IB6, ssModeReadWrite, '', 'gbak IB6 mode = vazio');
  // versao antiga (1.0) sem -mode
  VMin := Ver('Firebird 1.0');
  Espera(bkGbak, VMin, ssModeReadWrite, '', 'gbak 1.0 mode = vazio');

  // ======================= gfix =======================
  Espera(bkGfix, V25, ssValidate, '-v', 'gfix 2.5 validate');
  Espera(bkGfix, V25, ssValidateFull, '-full', 'gfix 2.5 full');
  Espera(bkGfix, V25, ssMend, '-mend', 'gfix 2.5 mend');
  Espera(bkGfix, V25, ssActivate, '-activate', 'gfix 2.5 activate');
  Espera(bkGfix, V25, ssSweep, '-sweep', 'gfix 2.5 sweep');
  Espera(bkGfix, V25, ssHousekeepingOn, '-housekeeping', 'gfix 2.5 hk on');
  Espera(bkGfix, V25, ssHousekeepingOff, '-housekeeping', 'gfix 2.5 hk off');
  Espera(bkGfix, V25, ssModeReadWrite, '-mode', 'gfix 2.5 mode');
  Espera(bkGfix, V25, ssIcuOn, '-icu', 'gfix 2.5 icu on');
  Espera(bkGfix, V25, ssUser, '-user', 'gfix 2.5 user');
  Espera(bkGfix, V25, ssPassword, '-pass', 'gfix 2.5 pass');
  Espera(bkGfix, V25, ssVersao, '-z', 'gfix 2.5 -z');
  // kill do gfix so existe em FB 3+ (heuristica desta F1)
  Espera(bkGfix, V25, ssKill, '', 'gfix 2.5 kill = vazio');
  Espera(bkGfix, V30, ssKill, '-kill', 'gfix 3.0 kill');
  // gfix de gbak nao herda: -extract nao existe no gfix
  Espera(bkGfix, V25, ssExtract, '', 'gfix nao tem extract');
  // ib: gfix basico existe, icu nao
  Espera(bkGfix, IB6, ssValidate, '-v', 'gfix IB6 validate');
  Espera(bkGfix, IB6, ssIcuOn, '', 'gfix IB6 icu = vazio');

  // ======================= isql =======================
  Espera(bkIsql, V25, ssExtract, '-extract', 'isql 2.5 extract');
  Espera(bkIsql, V25, ssCharset, '-charset', 'isql 2.5 charset');
  Espera(bkIsql, V25, ssUser, '-user', 'isql 2.5 user');
  Espera(bkIsql, V25, ssPassword, '-password', 'isql 2.5 password');
  Espera(bkIsql, V25, ssVersao, '-z', 'isql 2.5 -z');
  Espera(bkIsql, V25, ssBackupNativo, '', 'isql nao tem -b');

  // versao invalida/desconhecida -> '' (decisao conservadora)
  ZerarVersion(VInv);
  Espera(bkGbak, VInv, ssRestoreCriar, '', 'versao invalida -> vazio');
  Espera(bkGfix, VInv, ssValidate, '', 'versao invalida gfix -> vazio');

  // ============ interface + GbakSuportaFixFss ============
  Cat := CriarCatalogPadrao;
  Check('interface restore criar gbak 2.5',
        Cat.ObterSwitch(bkGbak, V25, ssRestoreCriar) = '-c');
  Check('GbakSuportaFixFss fb2.5', GbakSuportaFixFss(V25));
  Check('GbakSuportaFixFss fb1.5', GbakSuportaFixFss(V15));
  Check('GbakSuportaFixFss ib6', GbakSuportaFixFss(IB6));
  Check('GbakSuportaFixFss fb3.0 = false', not GbakSuportaFixFss(V30));
  Check('GbakSuportaFixFss invalida = false',
        not GbakSuportaFixFss(VInv));

  // ============ tabela ODS x versao (PLANO 4.1.2) ============
  Check('ODS 9.x -> ib', FamiliaProvavelParaOds(9, 0, F) and
        (F = bfInterBase));
  Check('ODS 10.0 -> ib (primeiro)', FamiliaProvavelParaOds(10, 0, F) and
        (F = bfInterBase));
  Check('ODS 10.1 -> fb', FamiliaProvavelParaOds(10, 1, F) and
        (F = bfFirebird));
  Check('ODS 11.2 -> fb', FamiliaProvavelParaOds(11, 2, F) and
        (F = bfFirebird));
  Check('ODS 13.x -> fb', FamiliaProvavelParaOds(13, 1, F) and
        (F = bfFirebird));
  Check('ODS 7 fora da tabela', not FamiliaProvavelParaOds(7, 0, F));

  Check('min versao ODS 10.0 = IB 6.0',
        TVersionMinimaParaOds(10, 0, F, VMin) and (F = bfInterBase) and
        (VMin.Maior = 6) and (VMin.Menor = 0));
  Check('min versao ODS 11.2 = FB 2.5',
        TVersionMinimaParaOds(11, 2, F, VMin) and (F = bfFirebird) and
        (VMin.Maior = 2) and (VMin.Menor = 5));
  Check('min versao ODS 12.0 = FB 3.0',
        TVersionMinimaParaOds(12, 0, F, VMin) and (VMin.Maior = 3));
  Check('ODS 99 fora -> false',
        not TVersionMinimaParaOds(99, 0, F, VMin));

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.