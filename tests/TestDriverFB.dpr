{
  TestDriverFB.dpr - FBRecStudio (FB Recovery Studio)
  ---------------------------------------------------------
  F5-T3+T4 (decisao 9.3): prova de ponta a ponta do DRIVER REAL
  via fbclient.dll (Firebird 2.5 EMBARCADO) rodando o TExportadorCSV
  do uExportCSV de verdade contra um banco .gdb local.

  Uso:
    TestDriverFB.exe [banco] [pasta_dll] [pasta_saida]
      banco       - caminho local do .gdb (default D:\SCANFILES\fbz1\SMALLBUS.GDB)
      pasta_dll   - pasta (ou caminho cheio) da fbclient.dll
                    (default D:\SCANFILES\fbin\eng)
      pasta_saida - pasta dos .csv gerados
                    (default D:\SCANFILES\fbz1\drvout)

  Fluxo:
    (a) lista as tabelas de usuario (rdb$relations sem views) e imprime
        o total;
    (b) escolhe ate 5 tabelas COM registros (via contagem) e exporta
        cada uma em .csv pelo caminho real do uExportCSV com o driver;
    (c) imprime por tabela: nome, linhas gravadas, bytes do .csv;
    (d) verifica que os .csv existem e tem > 0 bytes.
    Exit 0 = tudo ok; imprime 'TOTAL_TABELAS=..' e 'CSV_OK=..' no final.

  NAO roda servidor: o fbclient embarcado abre o banco como arquivo
  local (usuario/senha ignorados). Rodar o exe com workdir na pasta da
  dll ajuda o fbclient a achar firebird.conf.
}
program TestDriverFB;

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Classes, Windows,
  uKernelExec in '..\src\core\uKernelExec.pas',
  uQuoting in '..\src\core\uQuoting.pas',
  uTextCodec in '..\src\core\uTextCodec.pas',
  uLogger in '..\src\core\uLogger.pas',
  uFBVersionInfo in '..\src\firebird\uFBVersionInfo.pas',
  uFBSwitchCatalog in '..\src\firebird\uFBSwitchCatalog.pas',
  uExportBase in '..\src\export\uExportBase.pas',
  uExportCSV in '..\src\export\uExportCSV.pas',
  uDriverFBClient in '..\src\export\uDriverFBClient.pas';

const
  K_MAX_TABELAS = 5;

var
  Banco, DllDir, Saida: string;
  Drv: IDriverFBConsulta;
  Msg: string;
  Tabelas: TStringList;
  Escolhidas: array of string;
  I: Integer;
  Total: Int64;
  Ex: TExportadorCSV;
  P: TExportParams;
  M: TManifestoExport;
  OK: Boolean;
  CsvOk: Integer;
  BytesArq: Int64;
  Fs: TFileStream;
  Arq: string;
  Item: TItemManifesto;
  EscolhidasCount: Integer;

function BytesDoArquivo(const AArquivo: string): Int64;
var
  F: TFileStream;
begin
  Result := -1;
  if not FileExists(AArquivo) then
    Exit;
  F := TFileStream.Create(AArquivo, fmOpenRead or fmShareDenyNone);
  try
    Result := F.Size;
  finally
    F.Free;
  end;
end;

begin
  Banco := ParamStr(1);
  if Banco = '' then
    Banco := 'D:\SCANFILES\fbz1\SMALLBUS.GDB';
  DllDir := ParamStr(2);
  if DllDir = '' then
    DllDir := 'D:\SCANFILES\fbin\eng';
  Saida := ParamStr(3);
  if Saida = '' then
    Saida := 'D:\SCANFILES\fbz1\drvout';

  WriteLn('TestDriverFB - driver real fbclient.dll (embarcado)');
  WriteLn('banco      : ' + Banco);
  WriteLn('pasta dll  : ' + DllDir);
  WriteLn('pasta saida: ' + Saida);
  WriteLn('');

  // (0) Fabrica do driver (LoadLibrary dinamico; nil + AMsg se faltar).
  Drv := CriarDriverFBClient(DllDir, Banco, Msg);
  if Drv = nil then
  begin
    WriteLn('ERRO_DRIVER: ' + Msg);
    ExitCode := 2;
    Exit;
  end;
  WriteLn('DRIVER=' + Drv.NomeDriver);

  // (a) Lista as tabelas de usuario (sem views, sem RDB$*).
  Tabelas := TStringList.Create;
  try
    if not Drv.ListarTabelas(Tabelas, Msg) then
    begin
      WriteLn('ERRO_LISTAR: ' + Msg);
      ExitCode := 3;
      Exit;
    end;
    WriteLn('TABELAS_LISTADAS=' + IntToStr(Tabelas.Count));

    // (b) Escolhe ate 5 tabelas COM registros (via contagem).
    EscolhidasCount := 0;
    for I := 0 to Tabelas.Count - 1 do
    begin
      if EscolhidasCount >= K_MAX_TABELAS then
        Break;
      if not Drv.ContarRegistros(Tabelas[I], Total, Msg) then
      begin
        WriteLn('AVISO_CONTAGEM ' + Tabelas[I] + ': ' + Msg);
        Continue;
      end;
      if Total > 0 then
      begin
        SetLength(Escolhidas, EscolhidasCount + 1);
        Escolhidas[EscolhidasCount] := Tabelas[I];
        Inc(EscolhidasCount);
        WriteLn('SELECIONADA ' + Tabelas[I] + ' (registros=' +
                IntToStr(Total) + ')');
      end;
    end;
    WriteLn('');
    if EscolhidasCount = 0 then
    begin
      WriteLn('ERRO: nenhuma tabela com registros encontrada.');
      ExitCode := 4;
      Exit;
    end;

    // (c) Exporta as escolhidas com o TExportadorCSV REAL (uExportCSV).
    ForceDirectories(Saida);
    Ex := TExportadorCSV.CreateComDriver(Drv);
    try
      P := TExportParams.Create;
      try
        P.Origem := Banco;
        P.PastaDestino := Saida;
        P.ArquivoBase := 'smallbus';
        P.Sobrescrever := True;
        P.CharsetSaida := 'ANSI';
        P.Delimitador := ';';
        P.IncluirBlob := True;
        P.BlobComo := beHex;
        SetLength(P.TabelasAlvo, EscolhidasCount);
        for I := 0 to EscolhidasCount - 1 do
          P.TabelasAlvo[I] := Escolhidas[I];

        OK := Ex.Preparar(P, Msg);
        if not OK then
        begin
          WriteLn('ERRO_PREPARAR: ' + Msg);
          ExitCode := 5;
          Exit;
        end;

        M := TManifestoExport.Create;
        try
          OK := Ex.Executar(nil, nil, M);

          // (c) por tabela: nome, linhas gravadas, bytes do .csv
          CsvOk := 0;
          for I := 0 to M.Count - 1 do
          begin
            Item := M.Itens[I];
            if Item.Status <> xeOk then
            begin
              WriteLn('FALHA_TABELA ' + Item.Tabela + ': ' + Item.Detalhe);
              Continue;
            end;
            Arq := Item.Arquivo;
            BytesArq := BytesDoArquivo(Arq);
            if BytesArq > 0 then
              Inc(CsvOk);
            WriteLn('TABELA=' + Item.Tabela + ' LINHAS=' +
                    IntToStr(Item.Linhas) + ' BYTES=' + IntToStr(BytesArq));
          end;

          WriteLn('');
          WriteLn('TOTAL_TABELAS=' + IntToStr(Tabelas.Count));
          WriteLn('CSV_OK=' + IntToStr(CsvOk));
          if (not OK) or (CsvOk <> M.Count) then
          begin
            WriteLn('FALHA: algum .csv nao foi gerado ou esta vazio.');
            ExitCode := 6;
            Exit;
          end;
        finally
          M.Free;
        end;
      finally
        P.Free;
      end;
    finally
      Ex.Free;
    end;
  finally
    Tabelas.Free;
  end;

  WriteLn('FIM_OK');
  ExitCode := 0;
end.
