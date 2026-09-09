{
  TestAutoRecuperar.dpr  -  FBRecStudio
  ------------------------------------------------------------------
  Teste/porta de comando da RECUPERACAO AUTOMATICA (uMotorAutoRec):
  roda o pipeline completo (diagnostico -> escolha -> tecnicas
  combinadas -> relatorio) contra um arquivo REAL, com engines reais.

  Uso:
    TestAutoRecuperar.exe <arquivo> [<pasta_com_gbak>] [<pasta_trabalho>]

  - <arquivo>          backup .fbk/.gbk ou banco .fdb/.gdb danificado;
  - <pasta_com_gbak>   pasta com gbak/gfix/isql + fbclient (embedded);
                       vazia/omitida = usa so a auto-deteccao;
  - <pasta_trabalho>   onde criar artefatos (default: recuperacao_<base>
                       ao lado do arquivo). Pode ser repetida para rodar
                       o teste varias vezes sem colidir.

  Exit: 0 = recuperacao COMPLETA (banco restaurado+validado+contado);
        1 = PARCIAL (algo recuperado, com limitacao);
        2 = nada/sem engine/pre-condicoes; 3 = excecao.
  ------------------------------------------------------------------
}
{$APPTYPE CONSOLE}
program TestAutoRecuperar;

uses
  SysUtils, Classes, Windows,
  uLogger, uKernelExec, uEngineBase, uFBAutoDetect, uMotorAutoRec;

var
  Entrada: TRecAutoEntrada;
  Motor: TMotorAutoRec;
  Extras: TStringList;
  N: Integer;
  Resultado: TRecAutoResultado;
  RelPath: string;
  CancelFlag: Boolean;
  I: Integer;

begin
  try
    if ParamCount < 1 then
    begin
      WriteLn('uso: TestAutoRecuperar.exe <arquivo> ' +
              '[<pasta_com_gbak>] [<pasta_trabalho>]');
      Halt(2);
    end;
    if not FileExists(ParamStr(1)) then
    begin
      WriteLn('arquivo nao encontrado: ' + ParamStr(1));
      Halt(2);
    end;

    // Auto-deteccao + pasta extra (engine embarcado de teste).
    Extras := TStringList.Create;
    try
      if (ParamCount >= 2) and (ParamStr(2) <> '') then
        Extras.Add(ParamStr(2));
      FillChar(Entrada, SizeOf(Entrada), 0);
      Entrada.Origem := ParamStr(1);
      if ParamCount >= 3 then
        Entrada.PastaTrabalho := ParamStr(3)
      else
        Entrada.PastaTrabalho := ''; // default ao lado do arquivo
      if ParamCount >= 4 then
        Entrada.Destino := ParamStr(4);
      Entrada.Usuario := 'sysdba';
      Entrada.Senha := 'masterkey';
      Entrada.TimeoutMs := 0;        // default interno (30 min)
      Entrada.PermitirReparoMend := True;
      N := AutoDetectar(Extras, Entrada.Bins);
      WriteLn('Engines detectados: ' + IntToStr(N));
      for I := 0 to N - 1 do
        WriteLn('  [' + IntToStr(I) + '] ' + Entrada.Bins[I].CaminhoBin +
                ' (gbak=' + BoolToStr(Entrada.Bins[I].TemGbak, True) +
                ' gfix=' + BoolToStr(Entrada.Bins[I].TemGfix, True) +
                ' isql=' + BoolToStr(Entrada.Bins[I].TemIsql, True) + ')');
      if N = 0 then
      begin
        WriteLn('SEM engines: informe a pasta com gbak/gfix/isql.');
        Halt(2);
      end;

      Motor := TMotorAutoRec.Create(Entrada, nil);
      try
        CancelFlag := False;
        Motor.AtribuirCancelamento(@CancelFlag);
        Resultado := Motor.Executar;

        WriteLn('');
        WriteLn('================ RELATORIO ================');
        for I := 0 to Motor.Relatorio.Count - 1 do
          WriteLn(Motor.Relatorio[I]);
        WriteLn('===========================================');

        RelPath := Entrada.PastaTrabalho;
        if (RelPath <> '') and (RelPath[Length(RelPath)] <> '\') then
          RelPath := RelPath + '\';
        RelPath := RelPath + 'relatorio_recuperacao.txt';
        if Motor.SalvarRelatorio(RelPath) then
          WriteLn('Relatorio salvo em: ' + RelPath);

        WriteLn('VEREDITO: ' + RecAutoResultadoParaTexto(Resultado));
        if Motor.ArquivoFinal <> '' then
          WriteLn('Banco recuperado: ' + Motor.ArquivoFinal);

        case Resultado of
          raCompleta: Halt(0);
          raParcial:  Halt(1);
        else
          Halt(2);
        end;
      finally
        Motor.Free;
      end;
    finally
      Extras.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn('EXCECAO: ' + E.ClassName + ' - ' + E.Message);
      Halt(3);
    end;
  end;
end.
