program TestSafeCopy;

{ Testes de uSafeCopy (F2-T3): copia forense byte a byte com progresso
  e cancelamento. Console; exit = n. de falhas.

  1) copia REAL de arquivo >= 1 MB em %TEMP% (igualdade byte a byte e
     tamanho final validado pela engine);
  2) cancelamento por flag apaga o parcial (nenhum lixo como "sucesso");
  3) origem == destino falha sem tocar no arquivo;
  4) cria a pasta do destino quando nao existe;
  5) origem inexistente e arquivo vazio (caso limite). }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Classes, Windows,
  uSafeCopy in '..\src\engines\uSafeCopy.pas';

const
  K_MB = 1024 * 1024;
  K_TAM_ORIGEM = 1536 * K_MB div 1024;  // 1,5 MB (>= 1 MB exigido)
  K_BLOCO_TESTE = 64 * 1024;

type
  // Observador de progresso (metodo 'of object' + flag de cancelamento).
  TCopyObserver = class
  public
    Calls: Integer;
    LastCopied: Int64;
    TotalSeen: Int64;
    CancelAfterFirst: Boolean;
    Cancela: Boolean;              // flag lida pela engine a cada bloco
    procedure OnProgress(ABytesCopiados, ABytesTotais: Int64);
  end;

var
  Fails, Checks: Integer;
  DirBase: string;

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

// Tamanho de um arquivo (Int64) ou -1 em falha/ausencia.
function TamArquivo(const APath: string): Int64;
var
  FS: TFileStream;
begin
  Result := -1;
  if not FileExists(APath) then
    Exit;
  try
    FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      Result := FS.Size;
    finally
      FS.Free;
    end;
  except
    Result := -1;
  end;
end;
procedure TCopyObserver.OnProgress(ABytesCopiados, ABytesTotais: Int64);
begin
  Inc(Calls);
  LastCopied := ABytesCopiados;
  TotalSeen := ABytesTotais;
  if CancelAfterFirst then
    Cancela := True;
end;

// Gera arquivo com conteudo deterministico (padrao por posicao).
function GerarArquivo(const APath: string; ASize: Integer): Boolean;
var
  FS: TFileStream;
  Buf: array of Byte;
  I: Integer;
begin
  Result := False;
  try
    SetLength(Buf, ASize);
    for I := 0 to ASize - 1 do
      Buf[I] := Byte(I mod 251);   // 0..250 -> byte valido e deterministico
    FS := TFileStream.Create(APath, fmCreate or fmShareDenyNone);
    try
      if ASize > 0 then
        FS.WriteBuffer(Buf[0], ASize);
    finally
      FS.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

// Compara dois arquivos byte a byte (blocos de 64 KB).
function ArquivosIguais(const A, B: string): Boolean;
var
  FA, FB: TFileStream;
  BufA, BufB: array[0..65535] of Byte;
  NA, NB, I: Integer;
begin
  Result := False;
  try
    FA := TFileStream.Create(A, fmOpenRead or fmShareDenyNone);
    FB := TFileStream.Create(B, fmOpenRead or fmShareDenyNone);
    try
      if FA.Size <> FB.Size then
        Exit;
      while FA.Position < FA.Size do
      begin
        NA := FA.Read(BufA, SizeOf(BufA));
        NB := FB.Read(BufB, SizeOf(BufB));
        if NA <> NB then
          Exit;
        for I := 0 to NA - 1 do
          if BufA[I] <> BufB[I] then
            Exit;
      end;
      Result := True;
    finally
      FA.Free;
      FB.Free;
    end;
  except
    Result := False;
  end;
end;

procedure LimparDir;
begin
  if DirBase <> '' then
  begin
    SysUtils.DeleteFile(DirBase + 'copia.bin');
    SysUtils.DeleteFile(DirBase + 'origem.bin');
    SysUtils.DeleteFile(DirBase + 'origem2.bin');
    SysUtils.DeleteFile(DirBase + 'vazio.bin');
    RemoveDir(DirBase);
  end;
end;

var
  Origem, Destino: string;
  Obs: TCopyObserver;
  Status: TSafeCopyStatus;
  Bytes: Int64;
  MsgErro: string;
begin
  Fails := 0;
  Checks := 0;
  Obs := TCopyObserver.Create;
  try
    DirBase := TempDir + 'FBRTestSafeCopy' + IntToStr(GetCurrentProcessId);
    if DirectoryExists(DirBase) then
      LimparDir;
    if not ForceDirectories(DirBase) then
    begin
      WriteLn('FALHA: nao criou a pasta temporaria de teste');
      Halt(1);
    end;
    Origem := DirBase + 'origem.bin';

    // ============ 1) copia real >= 1 MB, byte a byte ============
    Check('gerou origem >= 1 MB', GerarArquivo(Origem, K_TAM_ORIGEM));
    Destino := DirBase + 'sub\pasta\nova\copia.bin';   // pasta inexistente
    Obs.Calls := 0;
    Obs.LastCopied := 0;
    Obs.TotalSeen := 0;
    Obs.CancelAfterFirst := False;
    Obs.Cancela := False;
    Status := CopiarArquivoSeguro(Origem, Destino, Obs.OnProgress,
                                  @Obs.Cancela, 0, Bytes);
    Check('copia status sucesso', Status = scSucesso);
    Check('copia criou a pasta do destino', FileExists(Destino));
    Check('copia tamanho final igual', TamArquivo(Destino) = TamArquivo(Origem));
    Check('copia byte a byte identica', ArquivosIguais(Origem, Destino));
    Check('bytes reportados = tamanho da origem',
          Bytes = Int64(K_TAM_ORIGEM));
    Check('progresso informado (>=1 chamada)', Obs.Calls >= 1);
    Check('progresso total = tamanho da origem', Obs.TotalSeen = K_TAM_ORIGEM);
    Check('ultimo progresso = arquivo inteiro', Obs.LastCopied = Bytes);

    // ============ 2) cancelamento apaga o parcial ============
    Destino := DirBase + 'parcial.bin';
    Obs.CancelAfterFirst := True;
    Obs.Cancela := False;
    Obs.Calls := 0;
    Status := CopiarArquivoSeguro(Origem, Destino, Obs.OnProgress,
                                  @Obs.Cancela, K_BLOCO_TESTE, Bytes);
    Check('cancelamento retornou scCancelado', Status = scCancelado);
    Check('cancelamento apagou o parcial', not FileExists(Destino));
    Check('cancelamento copiou apenas um trecho (Bytes < total)',
          (Bytes > 0) and (Bytes < Int64(K_TAM_ORIGEM)));
    Check('origem intacta apos cancelamento', FileExists(Origem));

    // ============ 3) origem == destino falha ============
    Status := CopiarArquivoSeguro(Origem, Origem, nil, nil, 0, Bytes);
    Check('origem==destino falha', Status = scOrigemIgualDestino);
    Check('origem==destino nao danificou o arquivo', TamArquivo(Origem) = K_TAM_ORIGEM);

    // ============ 4) origem inexistente ============
    MsgErro := '';
    Status := CopiarArquivoSeguro(DirBase + 'nao_existe.bin',
                                  DirBase + 'x.bin', nil, nil, 0, Bytes);
    Check('origem inexistente falha amigavel', Status = scOrigemInexistente);
    Check('status tem texto pt-BR', SafeCopyStatusParaTexto(Status) <> '');

    // ============ 5) arquivo vazio (caso limite) ============
    Check('gerou origem vazia', GerarArquivo(DirBase + 'vazio.bin', 0));
    Destino := DirBase + 'vazio_copia.bin';
    Status := CopiarArquivoSeguro(DirBase + 'vazio.bin', Destino, nil, nil,
                                  0, Bytes);
    Check('vazio copia com sucesso', Status = scSucesso);
    Check('vazio destino existe com 0 bytes', TamArquivo(Destino) = 0);
    Check('vazio bytes reportados = 0', Bytes = 0);
  finally
    Obs.Free;
    LimparDir;
  end;

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.
