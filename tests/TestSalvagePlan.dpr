program TestSalvagePlan;

{ Testes de uSalvagePlan + uMotorSalvage (F4-T1). Console; exit = n. de
  falhas. Sem Firebird real: regras/fluxos testados direto, e o motor
  e exercitado com bins FALSOS (gfix/gbak) compilados com o proprio
  FPC em %TEMP% (ponta a ponta: L0 + L1 + L3 + L4 rodam de verdade).

  1) Regras de camadas (uSalvagePlan):
     - rotulo L0..L4 por camada; ordem do enum = fluxo default;
     - L0-copia-SEMPRE-primeiro em TODOS os fluxos (default e por
       estado) e CamadaUsaCopia (L1/L3 operam na copia; L4 nao);
     - CamadaEssencial = glCopia;
     - decisao por estado (CamadasParaEstado): seCorrompidoLeve nao
       emite L4; seSemBackup/seDesconhecido emitem tudo (ate L4).
  2) Relatorio honesto (TSalvageRelatorio): estado inicial, Marcar/
     EstadoDe/DetalheDe, Reset, TemFalha, TodasConcluidas,
     CamadaMaisCritica (1a falha > 1a nao tentada) e ResumoHonesto.
  3) Motor com gfix E gbak AUSENTES (honesto): copia ok; validar gfix
     = falha citando gfix; backup = falha citando gbak; datapump =
     ignorada (requer F5/driver); extrator ainda roda e grava o dump;
     ExecutarFluxo chega ao fim (falhas ficam no relatorio).
  4) Cancelamento por flag ANTES do fluxo: nada roda, relatorio todo
     ignorada e nenhum artefato e criado.
  5) Origem inexistente: copia = falha honesta e demais ignoradas.
  6) Ponta a ponta com fake gfix/gbak (FPC): L1 ok, L3 ok com .fbk
     criado pelo fake, L4 ok com o texto varrido, original intocado. }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Classes, Windows,
  uKernelExec in '..\src\core\uKernelExec.pas',
  uQuoting in '..\src\core\uQuoting.pas',
  uTextCodec in '..\src\core\uTextCodec.pas',
  uLogger in '..\src\core\uLogger.pas',
  uEngineBase in '..\src\engines\uEngineBase.pas',
  uGuardaSeguranca in '..\src\engines\uGuardaSeguranca.pas',
  uFBVersionInfo in '..\src\firebird\uFBVersionInfo.pas',
  uFBSwitchCatalog in '..\src\firebird\uFBSwitchCatalog.pas',
  uSafeCopy in '..\src\engines\uSafeCopy.pas',
  uExtratorTexto in '..\src\engines\uExtratorTexto.pas',
  uEngineGfix in '..\src\engines\uEngineGfix.pas',
  uEngineGbak in '..\src\engines\uEngineGbak.pas',
  uSalvagePlan in '..\src\engines\uSalvagePlan.pas',
  uMotorSalvage in '..\src\engines\uMotorSalvage.pas';

var
  Fails, Checks: Integer;

type
  TByteArray = array of Byte;

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

function TempDir: string;
var
  Buf: array[0..MAX_PATH - 1] of Char;
  N: Integer;
begin
  N := GetTempPath(SizeOf(Buf), PChar(@Buf[0]));
  Result := '';
  if N > 0 then
    Result := IncludeTrailingPathDelimiter(StrPas(PChar(@Buf[0])));
end;

// Monta TVersion valida a partir de linha '-z' conhecida.
function Ver(const ATexto: string): TVersion;
begin
  ZerarVersion(Result);
  if not ParseVersaoTexto(ATexto, Result) then
    Result.Valida := False;
end;

procedure ApendGarbage(var D: TByteArray; AQtd: Integer);
const
  LIXO: array [0..5] of Byte = (0, 1, 2, 127, 128, 3);
var
  O, I: Integer;
begin
  O := Length(D);
  SetLength(D, O + AQtd);
  for I := 0 to AQtd - 1 do
    D[O + I] := LIXO[I mod 6];
end;

procedure ApendTexto(var D: TByteArray; const S: string);
var
  O, N: Integer;
begin
  O := Length(D);
  N := Length(S);
  SetLength(D, O + N);
  if N > 0 then
    Move(S[1], D[O], N);
end;

procedure EscreverArquivo(const APath: string; const D: TByteArray);
var
  F: TFileStream;
  N: Integer;
begin
  F := TFileStream.Create(APath, fmCreate);
  try
    N := Length(D);
    if N > 0 then
      F.WriteBuffer(D[0], N);
  finally
    F.Free;
  end;
end;

// Banco sintetico: alguns bytes de lixo + um run de texto conhecido
// (o L4 do motor precisa encontrar ao menos 1 run legivel).
procedure MontarBancoFake(const APath: string);
var
  D: TByteArray;
begin
  D := nil;
  ApendTexto(D, 'REGISTRO_ABC123_FONE_998877');
  ApendGarbage(D, 7);
  ApendTexto(D, 'SEGUNDO_CAMPO_TEXTO');
  ApendGarbage(D, 9);
  EscreverArquivo(APath, D);
end;

// Le o dump inteiro como texto ASCII (os fixtures sao ASCII puro).
function LerTextoArquivo(const APath: string): string;
var
  F: TFileStream;
  N: Int64;
begin
  Result := '';
  F := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    N := F.Size;
    if N > 0 then
    begin
      SetLength(Result, N);
      F.ReadBuffer(Result[1], N);
    end;
  finally
    F.Free;
  end;
end;

// Monta a TSalvageEntrada padrao do motor p/ os cenarios.
function NovaEntrada(const AOrigem, APasta, AGfix, AGbak: string): TSalvageEntrada;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Origem := AOrigem;
  Result.PastaTrabalho := APasta;
  Result.GfixExe := AGfix;
  Result.GbakExe := AGbak;
  Result.VersaoGfix := Ver('LI-V2.5.9.27110 Firebird 2.5');
  Result.VersaoGbak := Ver('LI-V2.5.9.27110 Firebird 2.5');
  Result.Usuario := 'sysdba';
  Result.Senha := 'masterkey';
  Result.TimeoutMs := 60000;
  Result.PermitirReparoMend := False;
  Result.ExtratorMinimo := 0;   // default (6)
  Result.ExtratorTeto := 0;     // sem teto
end;
// ------------------------------------------------------------------
// 1) Regras de camadas e fluxos (uSalvagePlan)
// ------------------------------------------------------------------
procedure TesteRegrasDePlano;
var
  Cam: array [0..9] of TGeraLayers;
  N: Integer;
begin
  // Rotulo L* conforme a numeracao da Tecnica 4 do PLANO.
  Check('rotulo: copia = L0', RotuloNivel(glCopia) = 'L0');
  Check('rotulo: validar gfix = L1', RotuloNivel(glValidaGfix) = 'L1');
  Check('rotulo: backup gbak = L3', RotuloNivel(glBackupOQueAbre) = 'L3');
  Check('rotulo: datapump = L2', RotuloNivel(glDatapumpTabelas) = 'L2');
  Check('rotulo: extrator = L4', RotuloNivel(glExtratorTexto) = 'L4');

  // Fluxo default: todas as camadas, na ordem do enum, copia em 1o.
  FillChar(Cam, SizeOf(Cam), 0);
  N := FluxoDefaultSalvage(Cam);
  Check('default: 5 camadas', N = 5);
  Check('default: L0-copia primeiro', Cam[0] = glCopia);
  Check('default: 2a = validar gfix', Cam[1] = glValidaGfix);
  Check('default: 3a = backup gbak', Cam[2] = glBackupOQueAbre);
  Check('default: 4a = datapump', Cam[3] = glDatapumpTabelas);
  Check('default: extrator por ultimo', Cam[4] = glExtratorTexto);

  // Quem opera na copia? L1/L3 (nunca no original); L4 apenas le.
  Check('usa copia: validar gfix', CamadaUsaCopia(glValidaGfix));
  Check('usa copia: backup gbak', CamadaUsaCopia(glBackupOQueAbre));
  Check('usa copia: datapump nao', not CamadaUsaCopia(glDatapumpTabelas));
  Check('usa copia: extrator nao', not CamadaUsaCopia(glExtratorTexto));

  // Essencial = a copia forense (inegociavel); o resto e melhor esforco.
  Check('essencial: copia', CamadaEssencial(glCopia));
  Check('essencial: gfix nao', not CamadaEssencial(glValidaGfix));
  Check('essencial: extrator nao', not CamadaEssencial(glExtratorTexto));

  // Decisao por estado: leve nao emite L4 (dados saem pelo backup).
  FillChar(Cam, SizeOf(Cam), 0);
  N := CamadasParaEstado(seCorrompidoLeve, Cam);
  Check('leve: 3 camadas', N = 3);
  Check('leve: 1a = copia', Cam[0] = glCopia);
  Check('leve: 2a = validar gfix', Cam[1] = glValidaGfix);
  Check('leve: 3a = backup', Cam[2] = glBackupOQueAbre);

  // Sem backup bom: fluxo completo, com o extrator de texto no fim.
  FillChar(Cam, SizeOf(Cam), 0);
  N := CamadasParaEstado(seSemBackup, Cam);
  Check('sem backup: 5 camadas', N = 5);
  Check('sem backup: copia em 1o', Cam[0] = glCopia);
  Check('sem backup: extrator incluso', Cam[4] = glExtratorTexto);

  // Desconhecido: igualmente completo.
  FillChar(Cam, SizeOf(Cam), 0);
  N := CamadasParaEstado(seDesconhecido, Cam);
  Check('desconhecido: 5 camadas', N = 5);
  Check('desconhecido: copia em 1o', Cam[0] = glCopia);

  // Texto do fluxo menciona a 1a camada com o rotulo.
  N := FluxoDefaultSalvage(Cam);
  Check('fluxo texto: cita L0', Pos('L0', FluxoParaTexto(Cam, N)) > 0);
end;

// ------------------------------------------------------------------
// 2) Relatorio honesto (TSalvageRelatorio)
// ------------------------------------------------------------------
procedure TesteRelatorio;
var
  R: TSalvageRelatorio;
  Resumo: string;
begin
  R := TSalvageRelatorio.Create;
  try
    Check('rel: estado inicial = nao tentada em tudo',
          (R.EstadoDe(glCopia) = csNaoTentada) and
          (R.EstadoDe(glExtratorTexto) = csNaoTentada));
    Check('rel: recem-criado nao tem falha', not R.TemFalha);
    Check('rel: recem-criado nao concluido', not R.TodasConcluidas);
    Check('rel: critica recem-criado = copia (1a por rodar)',
          R.CamadaMaisCritica = glCopia);

    R.Marcar(glCopia, csOk, 'copia feita');
    R.Marcar(glValidaGfix, csFalha, 'gfix ausente');
    Check('rel: marcar/ler estado', R.EstadoDe(glCopia) = csOk);
    Check('rel: detalhe guardado',
          R.DetalheDe(glValidaGfix) = 'gfix ausente');
    Check('rel: tem falha apos falha', R.TemFalha);
    Check('rel: ainda nao concluido (tem nao tentada)',
          not R.TodasConcluidas);
    Check('rel: critica prioriza a 1a falha', R.CamadaMaisCritica = glValidaGfix);

    Resumo := R.ResumoHonesto;
    Check('rel: resumo cita falha', Pos('falha', Resumo) > 0);
    Check('rel: resumo cita a camada gfix', Pos('gfix', Resumo) > 0);

    R.Reset;
    Check('rel: reset volta a nao tentada',
          R.EstadoDe(glCopia) = csNaoTentada);
    Check('rel: reset limpa detalhe', R.DetalheDe(glValidaGfix) = '');
    Check('rel: reset sem falha', not R.TemFalha);
  finally
    R.Free;
  end;
end;
// ------------------------------------------------------------------
// Cria pasta de cenario limpa em %TEMP% e devolve o caminho.
// ------------------------------------------------------------------
// Conta arquivos (nao diretorios) dentro de APasta.
function ContarArquivosNaPasta(const APasta: string): Integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(APasta + '\*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and
         ((SR.Attr and faDirectory) = 0) then
        Inc(Result);
    until FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
end;

// ------------------------------------------------------------------
// Cria pasta de cenario limpa em %TEMP% e devolve o caminho.
// ------------------------------------------------------------------
function NovaPastaCenario(const ASufixo: string): string;
begin
  Result := TempDir + ASufixo + IntToStr(GetCurrentProcessId);
  if DirectoryExists(Result) then
  begin
    SysUtils.DeleteFile(Result + '\origem.fdb');
    SysUtils.DeleteFile(Result + '\origem.fdb.forense.fdb');
    SysUtils.DeleteFile(Result + '\origem.fdb.texto.txt');
    SysUtils.DeleteFile(Result + '\origem.salvage.fbk');
    RemoveDir(Result);
  end;
  ForceDirectories(Result);
end;

// ------------------------------------------------------------------
// 3) Motor sem gfix/gbak (honesto): copia ok; validar/backup = falha
//    (detalhe cita o binario); datapump ignorada (F5/driver); o
//    extrator AINDA roda (varre o original quando nao ha copia? nao:
//    aqui a copia existe, entao varre a copia) e grava o dump.
// ------------------------------------------------------------------
procedure TesteMotorSemBins;
var
  Dir, Origem: string;
  Ent: TSalvageEntrada;
  Motor: TMotorSalvage;
  Dump: string;
begin
  Dir := NovaPastaCenario('FBRTestSalvSemBins');
  Origem := Dir + '\origem.fdb';
  MontarBancoFake(Origem);

  Ent := NovaEntrada(Origem, Dir + '\trabalho', '', '');
  Motor := TMotorSalvage.Create(Ent, nil);
  try
    Check('sem bins: ExecutarFluxo chega ao fim (True)',
          Motor.ExecutarFluxo);
    Check('sem bins: L0 copia ok', Motor.Relatorio.EstadoDe(glCopia) = csOk);
    Check('sem bins: copia criada em disco', FileExists(Motor.CopiaForense));
    Check('sem bins: L1 falha honesta (gfix ausente)',
          Motor.Relatorio.EstadoDe(glValidaGfix) = csFalha);
    Check('sem bins: detalhe L1 cita gfix',
          Pos('gfix', Motor.Relatorio.DetalheDe(glValidaGfix)) > 0);
    Check('sem bins: L3 falha honesta (gbak ausente)',
          Motor.Relatorio.EstadoDe(glBackupOQueAbre) = csFalha);
    Check('sem bins: detalhe L3 cita gbak',
          Pos('gbak', Motor.Relatorio.DetalheDe(glBackupOQueAbre)) > 0);
    Check('sem bins: L2 datapump ignorada (F5/driver)',
          Motor.Relatorio.EstadoDe(glDatapumpTabelas) = csIgnorada);
    Check('sem bins: detalhe L2 cita F5/driver',
          Pos('F5', Motor.Relatorio.DetalheDe(glDatapumpTabelas)) > 0);
    Check('sem bins: L4 extrator ainda roda (copia)',
          Motor.Relatorio.EstadoDe(glExtratorTexto) = csOk);
    Check('sem bins: dump criado em disco', FileExists(Motor.DumpTexto));
    Dump := LerTextoArquivo(Motor.DumpTexto);
    Check('sem bins: dump contem o run varrido',
          Pos('REGISTRO_ABC123_FONE_998877', Dump) > 0);
    Check('sem bins: relatorio tem falha', Motor.Relatorio.TemFalha);
    Check('sem bins: resumo honesto cita as falhas',
          Pos('falha', Motor.Relatorio.ResumoHonesto) > 0);
    // Original jamais vira alvo: L3 sem backup nao apaga nada.
    Check('sem bins: original continua no lugar', FileExists(Origem));
  finally
    Motor.Free;
  end;
  RemoveDir(Dir + '\trabalho');
  SysUtils.DeleteFile(Origem);
  RemoveDir(Dir);
end;

// ------------------------------------------------------------------
// 4) Cancelamento por flag antes do fluxo: nada roda; relatorio todo
//    ignorada; nenhum artefato e criado.
// ------------------------------------------------------------------
procedure TesteCancelamentoInicial;
var
  Dir, Origem, Trab: string;
  Ent: TSalvageEntrada;
  Motor: TMotorSalvage;
  Flag: Boolean;
  C: TGeraLayers;
  TodosIgnorados: Boolean;
begin
  Dir := NovaPastaCenario('FBRTestSalvCanc');
  Origem := Dir + '\origem.fdb';
  Trab := Dir + '\trabalho';
  MontarBancoFake(Origem);

  Ent := NovaEntrada(Origem, Trab, 'C:\nao_existe\gfix.exe',
                     'C:\nao_existe\gbak.exe');
  Motor := TMotorSalvage.Create(Ent, nil);
  try
    Flag := True;
    Motor.AtribuirCancelamento(@Flag);
    Check('cancel: ExecutarFluxo = False (nada rodou)',
          not Motor.ExecutarFluxo);
    TodosIgnorados := True;
    for C := Low(TGeraLayers) to High(TGeraLayers) do
      if Motor.Relatorio.EstadoDe(C) <> csIgnorada then
        TodosIgnorados := False;
    Check('cancel: todas as camadas ignorada', TodosIgnorados);
    Check('cancel: sem copia', Motor.CopiaForense = '');
    Check('cancel: sem backup', Motor.BackupFbk = '');
    Check('cancel: sem dump', Motor.DumpTexto = '');
    Check('cancel: pasta de trabalho vazia (sem artefatos)',
          (not DirectoryExists(Trab)) or
          (ContarArquivosNaPasta(Trab) = 0));
  finally
    Motor.Free;
  end;
  SysUtils.DeleteFile(Origem);
  if DirectoryExists(Trab) then
    RemoveDir(Trab);
  RemoveDir(Dir);
end;

// ------------------------------------------------------------------
// 5) Origem inexistente: copia = falha honesta; resto ignorada.
// ------------------------------------------------------------------
procedure TesteOrigemInexistente;
var
  Dir: string;
  Ent: TSalvageEntrada;
  Motor: TMotorSalvage;
begin
  Dir := NovaPastaCenario('FBRTestSalvFalta');
  Ent := NovaEntrada(Dir + '\nao_existe.fdb', Dir + '\trabalho',
                     '', '');
  Motor := TMotorSalvage.Create(Ent, nil);
  try
    Check('falta: ExecutarFluxo = False (pre-condicao)',
          not Motor.ExecutarFluxo);
    Check('falta: L0 falha honesta',
          Motor.Relatorio.EstadoDe(glCopia) = csFalha);
    Check('falta: L1 ignorada (sem origem)',
          Motor.Relatorio.EstadoDe(glValidaGfix) = csIgnorada);
    Check('falta: L4 ignorada (sem origem)',
          Motor.Relatorio.EstadoDe(glExtratorTexto) = csIgnorada);
    Check('falta: detalhe cita o caminho',
          Pos('nao_existe', Motor.Relatorio.DetalheDe(glCopia)) > 0);
  finally
    Motor.Free;
  end;
  if DirectoryExists(Dir + '\trabalho') then
    RemoveDir(Dir + '\trabalho');
  RemoveDir(Dir);
end;
// Escreve um arquivo de texto ASCII (fontes dos fakes e afins).
procedure EscreverTexto(const APath, ATexto: string);
var
  F: TFileStream;
  N: Integer;
begin
  F := TFileStream.Create(APath, fmCreate);
  try
    N := Length(ATexto);
    if N > 0 then
      F.WriteBuffer(ATexto[1], N);
  finally
    F.Free;
  end;
end;

function TamanhoArquivo(const APath: string): Int64;
var
  F: TFileStream;
begin
  Result := -1;
  if not FileExists(APath) then
    Exit;
  F := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := F.Size;
  finally
    F.Free;
  end;
end;

const
  // Fake gfix: ignora os argumentos e termina 0 com a frase de sucesso
  // que a engine reconhece (o -v roda sobre a copia do motor).
  K_FAKE_GFIX =
    'program F4FakeGfix;' + #13#10 +
    '{$APPTYPE CONSOLE}' + #13#10 +
    '{$H+}' + #13#10 +
    'begin' + #13#10 +
    '  WriteLn(''gfix: validation succeeded'');' + #13#10 +
    '  Halt(0);' + #13#10 +
    'end.' + #13#10;

  // Fake gbak: cria o arquivo do ULTIMO argumento (o destino do -b)
  // para o motor confirmar que o .fbk surgiu no disco.
  K_FAKE_GBAK =
    'program F4FakeGbak;' + #13#10 +
    '{$APPTYPE CONSOLE}' + #13#10 +
    '{$H+}' + #13#10 +
    'uses SysUtils, Classes;' + #13#10 +
    'var' + #13#10 +
    '  D: string;' + #13#10 +
    '  F: TFileStream;' + #13#10 +
    'begin' + #13#10 +
    '  D := ParamStr(ParamCount);' + #13#10 +
    '  F := TFileStream.Create(D, fmCreate);' + #13#10 +
    '  try' + #13#10 +
    '    F.WriteBuffer(''F4BACKUP_OK''#13#10, 13);' + #13#10 +
    '  finally' + #13#10 +
    '    F.Free;' + #13#10 +
    '  end;' + #13#10 +
    '  WriteLn(''gbak: backup concluido (fake)'');' + #13#10 +
    '  Halt(0);' + #13#10 +
    'end.' + #13#10;

// ------------------------------------------------------------------
// 6) Ponta a ponta: motor com fake gfix/gbak compilados (FPC)
// ------------------------------------------------------------------
procedure TesteE2E(const FpcPath, ADir: string);
var
  SrcG, ExeG, SrcB, ExeB, Origem, Trab, Dump: string;
  Opt: TProcessOptions;
  OutL, ErrL: TStringList;
  Res: TProcessResult;
  Ent: TSalvageEntrada;
  Motor: TMotorSalvage;
  TamOrigem: Int64;
begin
  SrcG := ADir + 'fake_gfix.pas';
  ExeG := ADir + 'fake_gfix.exe';
  SrcB := ADir + 'fake_gbak.pas';
  ExeB := ADir + 'fake_gbak.exe';
  Origem := ADir + 'origem.fdb';
  Trab := ADir + 'trabalho';

  EscreverTexto(SrcG, K_FAKE_GFIX);
  EscreverTexto(SrcB, K_FAKE_GBAK);
  MontarBancoFake(Origem);
  TamOrigem := TamanhoArquivo(Origem);

  OutL := TStringList.Create;
  ErrL := TStringList.Create;
  try
    // Compila os dois fakes com o proprio FPC.
    FillChar(Opt, SizeOf(Opt), 0);
    Opt.Executable := FpcPath;
    Opt.WorkDir := ADir;
    Opt.TimeoutMs := 60000;
    Opt.KillTreeOnCancel := True;
    Opt.ConsoleCodePage := 0;
    SetLength(Opt.Args, 3);
    Opt.Args[0] := '-Mdelphi';
    Opt.Args[1] := '-o' + ExeG;
    Opt.Args[2] := SrcG;
    OutL.Clear;
    ErrL.Clear;
    Res := BuildAndRun(Opt, OutL, ErrL);
    Check('e2e: fake gfix compilou', Res.Ok and FileExists(ExeG));
    if not Res.Ok then
      WriteLn('  (fpc gfix: ' + Trim(OutL.Text + ErrL.Text) + ')');

    SetLength(Opt.Args, 3);
    Opt.Args[1] := '-o' + ExeB;
    Opt.Args[2] := SrcB;
    OutL.Clear;
    ErrL.Clear;
    Res := BuildAndRun(Opt, OutL, ErrL);
    Check('e2e: fake gbak compilou', Res.Ok and FileExists(ExeB));
    if not Res.Ok then
      WriteLn('  (fpc gbak: ' + Trim(OutL.Text + ErrL.Text) + ')');

    if FileExists(ExeG) and FileExists(ExeB) then
    begin
      Ent := NovaEntrada(Origem, Trab, ExeG, ExeB);
      Motor := TMotorSalvage.Create(Ent, nil);
      try
        Check('e2e: ExecutarFluxo chegou ao fim (True)',
              Motor.ExecutarFluxo);
        Check('e2e: L0 copia ok',
              Motor.Relatorio.EstadoDe(glCopia) = csOk);
        Check('e2e: copia existe em disco', FileExists(Motor.CopiaForense));
        Check('e2e: copia != original',
              Motor.CopiaForense <> Origem);
        Check('e2e: L1 validar gfix ok',
              Motor.Relatorio.EstadoDe(glValidaGfix) = csOk);
        Check('e2e: L3 backup gbak ok',
              Motor.Relatorio.EstadoDe(glBackupOQueAbre) = csOk);
        Check('e2e: .fbk criado pelo fake',
              FileExists(Motor.BackupFbk));
        Check('e2e: L2 datapump ignorada',
              Motor.Relatorio.EstadoDe(glDatapumpTabelas) = csIgnorada);
        Check('e2e: L4 extrator ok',
              Motor.Relatorio.EstadoDe(glExtratorTexto) = csOk);
        Check('e2e: dump existe', FileExists(Motor.DumpTexto));
        Dump := LerTextoArquivo(Motor.DumpTexto);
        Check('e2e: dump contem o texto varrido',
              Pos('SEGUNDO_CAMPO_TEXTO', Dump) > 0);
        Check('e2e: original intocado (tamanho igual)',
              TamanhoArquivo(Origem) = TamOrigem);
      finally
        Motor.Free;
      end;
    end;
  finally
    OutL.Free;
    ErrL.Free;
  end;
end;
// ------------------------------------------------------------------
// Principal
// ------------------------------------------------------------------
var
  FpcPath, D1: string;
  SR: TSearchRec;
begin
  Fails := 0;
  Checks := 0;

  TesteRegrasDePlano;
  TesteRelatorio;
  TesteMotorSemBins;
  TesteCancelamentoInicial;
  TesteOrigemInexistente;

  // Ponta a ponta com fakes compilados (exige FPC).
  FpcPath := SysUtils.GetEnvironmentVariable('FB_FPC');
  if (FpcPath = '') or (not FileExists(FpcPath)) then
    FpcPath := SysUtils.GetEnvironmentVariable('FB_FPC');
  if FileExists(FpcPath) then
  begin
    D1 := TempDir + 'FBRTestSalvFake' + IntToStr(GetCurrentProcessId);
    if DirectoryExists(D1) then
    begin
      SysUtils.DeleteFile(D1 + '\fake_gfix.pas');
      SysUtils.DeleteFile(D1 + '\fake_gfix.exe');
      SysUtils.DeleteFile(D1 + '\fake_gbak.pas');
      SysUtils.DeleteFile(D1 + '\fake_gbak.exe');
      SysUtils.DeleteFile(D1 + '\origem.fdb');
      RemoveDir(D1 + '\trabalho');
      RemoveDir(D1);
    end;
    ForceDirectories(D1);
    TesteE2E(FpcPath, IncludeTrailingPathDelimiter(D1));

    // Limpeza do cenario de fakes.
    SysUtils.DeleteFile(D1 + '\fake_gfix.pas');
    SysUtils.DeleteFile(D1 + '\fake_gfix.exe');
    SysUtils.DeleteFile(D1 + '\fake_gbak.pas');
    SysUtils.DeleteFile(D1 + '\fake_gbak.exe');
    SysUtils.DeleteFile(D1 + '\origem.fdb');
    SysUtils.DeleteFile(D1 + '\origem.fdb.forense.fdb');
    SysUtils.DeleteFile(D1 + '\origem.salvage.fbk');
    SysUtils.DeleteFile(D1 + '\origem.fdb.texto.txt');
    if DirectoryExists(D1 + '\trabalho') then
    begin
      if FindFirst(D1 + '\trabalho\*', faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Name <> '.') and (SR.Name <> '..') and
             ((SR.Attr and faDirectory) = 0) then
            SysUtils.DeleteFile(D1 + '\trabalho\' + SR.Name);
        until FindNext(SR) <> 0;
      finally
        SysUtils.FindClose(SR);
      end;
      RemoveDir(D1 + '\trabalho');
    end;
    RemoveDir(D1);
  end
  else
    WriteLn('SKIP: fakes nao compilados (FPC nao encontrado; defina FB_FPC)');

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.
