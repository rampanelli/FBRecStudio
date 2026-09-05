{
  uSafeCopy.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F2-A / F2-T3 (PLANO.md 4.2 Tecnica 1 "backup de seguranca" e
  Tecnica 4 nivel L0): copia forense byte a byte de um arquivo antes
  de qualquer escrita destrutiva (restore -r, gfix -mend etc.).

    * Blocos via CreateFileW/ReadFile/WriteFile (Win32, XP-safe),
      contagem em Int64 e progresso por callback (TProgressoCopy);
    * Cancelamento por FLAG (PBoolean, pode ser de outra thread):
      ao cancelar o destino parcial e APAGADO (nunca deixa meio
      arquivo como se fosse copia valida);
    * Origem == Destino falha (scOrigemIgualDestino) sem tocar nada;
    * Cria a pasta do destino quando necessario;
    * Valida o tamanho final (GetFileSizeEx origem == destino); em
      qualquer desvio o destino parcial e removido e o status e de
      falha (nunca 'sucesso' com arquivo errado).

  Sem Forms e sem dependencias de outras units do projeto: pode ser
  usada pelas engines e pelos testes de console/FPC.
  ------------------------------------------------------------------
}
unit uSafeCopy;

{$H+}

interface

uses
  SysUtils, Windows;

type
  TSafeCopyStatus = (
    scSucesso,             // copia completa e validada (byte a byte)
    scOrigemVazia,         // origem nao informada
    scDestinoVazio,        // destino nao informado
    scOrigemInexistente,   // arquivo de origem nao existe
    scOrigemIgualDestino,  // mesmo arquivo (falha por seguranca)
    scFalhaCriarPasta,     // nao criou a pasta do destino
    scFalhaAbrirOrigem,    // CreateFileW/GENERIC_READ falhou
    scFalhaCriarDestino,   // CreateFileW/GENERIC_WRITE falhou
    scFalhaLer,            // erro de leitura no meio da copia
    scFalhaEscrever,       // erro de escrita no meio da copia
    scCancelado,           // flag de cancelamento acionado (parcial apagado)
    scTamanhoInvalido      // tamanho final divergiu (parcial apagado)
  );

  // Callback de progresso (executado a cada bloco, no thread da copia).
  // ABytesTotais = tamanho da origem (Int64).
  TProgressoCopy = procedure(ABytesCopiados, ABytesTotais: Int64)
    of object;

  // Copia byte a byte AOrigem -> ADestino. ACancelar (nil = sem
  // cancelamento): se ACancelar^ = True entre blocos, aborta e apaga
  // o destino parcial. ABlocoBytes: 0 = default (256 KiB). Devolve em
  // ABytesCopiados quantos bytes foram gravados ate o fim (ou o
  // cancelamento/falha).
  function CopiarArquivoSeguro(const AOrigem, ADestino: string;
    AProgresso: TProgressoCopy; ACancelar: PBoolean;
    ABlocoBytes: DWORD; out ABytesCopiados: Int64): TSafeCopyStatus;

  // Texto pt-BR do status (logs e relatorios).
  function SafeCopyStatusParaTexto(AStatus: TSafeCopyStatus): string;

implementation

// GetFileSizeEx nao e seguro entre D7/FPC: binding proprio (padrao do
// repositorio: Kb*/Api* + kernel32).
function ApiGetFileSizeEx(hFile: THandle;
  var lpFileSize: Int64): BOOL; stdcall;
  external 'kernel32.dll' name 'GetFileSizeEx';

function SafeCopyStatusParaTexto(AStatus: TSafeCopyStatus): string;
begin
  case AStatus of
    scSucesso:            Result := 'copia concluida';
    scOrigemVazia:        Result := 'origem nao informada';
    scDestinoVazio:       Result := 'destino nao informado';
    scOrigemInexistente:  Result := 'arquivo de origem nao encontrado';
    scOrigemIgualDestino: Result := 'origem e destino sao o mesmo arquivo';
    scFalhaCriarPasta:    Result := 'falha ao criar a pasta do destino';
    scFalhaAbrirOrigem:   Result := 'falha ao abrir a origem para leitura';
    scFalhaCriarDestino:  Result := 'falha ao criar o destino para escrita';
    scFalhaLer:           Result := 'erro de leitura durante a copia';
    scFalhaEscrever:      Result := 'erro de escrita durante a copia';
    scCancelado:          Result := 'copia cancelada (parcial removido)';
    scTamanhoInvalido:    Result := 'tamanho final divergente (parcial removido)';
  else
    Result := 'status desconhecido';
  end;
end;

function CopiarArquivoSeguro(const AOrigem, ADestino: string;
  AProgresso: TProgressoCopy; ACancelar: PBoolean;
  ABlocoBytes: DWORD; out ABytesCopiados: Int64): TSafeCopyStatus;
const
  K_BLOCO_DEFAULT = 262144;   // 256 KiB
var
  OrigemFull, DestinoFull, DirDest: string;
  hSrc, hDst: THandle;
  Bloco, nRead, nWr: DWORD;
  Buf: array of Byte;
  Total, Copiado: Int64;
  TamanhoOk: Boolean;
begin
  ABytesCopiados := 0;
  Result := scSucesso;

  if AOrigem = '' then
  begin
    Result := scOrigemVazia;
    Exit;
  end;
  if ADestino = '' then
  begin
    Result := scDestinoVazio;
    Exit;
  end;

  OrigemFull := ExpandFileName(AOrigem);
  DestinoFull := ExpandFileName(ADestino);

  // Falha por seguranca: nunca copiar um arquivo sobre si mesmo.
  if CompareText(OrigemFull, DestinoFull) = 0 then
  begin
    Result := scOrigemIgualDestino;
    Exit;
  end;

  if not FileExists(OrigemFull) then
  begin
    Result := scOrigemInexistente;
    Exit;
  end;

  // Cria a pasta do destino quando necessario (permissao de escrita).
  DirDest := ExtractFilePath(DestinoFull);
  if DirDest <> '' then
    ForceDirectories(DirDest);
  if (DirDest <> '') and (not DirectoryExists(DirDest)) then
  begin
    Result := scFalhaCriarPasta;
    Exit;
  end;

  hSrc := CreateFileW(PWideChar(WideString(OrigemFull)), GENERIC_READ,
          FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
          FILE_ATTRIBUTE_NORMAL, 0);
  if hSrc = INVALID_HANDLE_VALUE then
  begin
    Result := scFalhaAbrirOrigem;
    Exit;
  end;

  hDst := CreateFileW(PWideChar(WideString(DestinoFull)), GENERIC_WRITE,
         0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if hDst = INVALID_HANDLE_VALUE then
  begin
    CloseHandle(hSrc);
    Result := scFalhaCriarDestino;
    Exit;
  end;

  // Tamanho da origem p/ progresso e validacao final.
  if not ApiGetFileSizeEx(hSrc, Total) then
  begin
    CloseHandle(hDst);
    CloseHandle(hSrc);
    SysUtils.DeleteFile(DestinoFull);   // dest pode ter sido criado vazio
    Result := scFalhaAbrirOrigem;
    Exit;
  end;

  Bloco := ABlocoBytes;
  if Bloco = 0 then
    Bloco := K_BLOCO_DEFAULT;
  SetLength(Buf, Bloco);

  Copiado := 0;
  try
    while True do
    begin
      // Flag de cancelamento (pode vir de outra thread).
      if (ACancelar <> nil) and ACancelar^ then
      begin
        Result := scCancelado;
        Break;
      end;
      nRead := 0;
      if not ReadFile(hSrc, Buf[0], Bloco, nRead, nil) then
      begin
        Result := scFalhaLer;
        Break;
      end;
      if nRead = 0 then
        Break;                          // fim do arquivo
      nWr := 0;
      if (not WriteFile(hDst, Buf[0], nRead, nWr, nil)) or
         (nWr <> nRead) then
      begin
        Result := scFalhaEscrever;
        Break;
      end;
      Inc(Copiado, Int64(nRead));
      ABytesCopiados := Copiado;
      if Assigned(AProgresso) then
        AProgresso(Copiado, Total);
    end;
  finally
    Buf := nil;                          // libera o heap do buffer
  end;

  if Result = scSucesso then
  begin
    // Valida o tamanho final do destino (nunca confiar so no EOF).
    CloseHandle(hDst);
    hDst := INVALID_HANDLE_VALUE;
    hDst := CreateFileW(PWideChar(WideString(DestinoFull)), GENERIC_READ,
            FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    TamanhoOk := False;
    if hDst <> INVALID_HANDLE_VALUE then
    begin
      TamanhoOk := ApiGetFileSizeEx(hDst, Copiado) and (Copiado = Total);
      CloseHandle(hDst);
    end;
    ABytesCopiados := Copiado;
    if not TamanhoOk then
    begin
      SysUtils.DeleteFile(DestinoFull);
      Result := scTamanhoInvalido;
    end;
  end
  else
  begin
    // Cancelado ou falha: apaga o parcial (nunca deixa meio arquivo).
    CloseHandle(hDst);
    SysUtils.DeleteFile(DestinoFull);
  end;

  CloseHandle(hSrc);
end;

end.
