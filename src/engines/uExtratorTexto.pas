{
  uExtratorTexto.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F4-T2 / F4 (PLANO.md 4.2 Tecnica 4, nivel L4 "limitado"): varredura
  de bytes de um arquivo procurando "runs" de texto legivel (ASCII
  imprimivel + extensao ANSI do ACP) e gravando cada run em uma linha
  da saida com o OFFSET absoluto do arquivo. Nunca toca no arquivo
  (somente leitura); o arquivo de saida e um dump de texto auxiliar.

    * ByteContaComoTexto / EhRunLegivel: decisoes PURAS (testaveis).
        - ByteContaComoTexto: ASCII 32..126 + extensao ANSI 160..255
          (bytes 127..159 = DEL/C1 tratados como lixo binario; limite
          documentado - textos com aspas tipograficas cp1252 nesses
          bytes quebram o run em 2).
        - EhRunLegivel: a partir de AInicio num buffer, mede o run
          contiguo e responde se tem >= AComprimentoMinimo bytes.
    * ExtrairRunsDeTexto: leitura por BLOCOS via CreateFileW/ReadFile
      (bloco configuravel; default 64 KiB) com:
        - TetoBytes > 0: cap de bytes escaneados p/ arquivo grande
          (status etTetoAtingido ao parar no teto; o que foi achado
          ate la e mantido na saida);
        - callback de progresso a cada bloco (bytes lidos x total);
        - cancelamento por flag (PBoolean; pausa entre blocos e entre
          runs): a saida parcial e APAGADA (nunca deixa dump "pela
          metade" como se completo);
        - runs menores que o minimo sao IGNORADOS (nao gravados);
        - um run muito longo (acima de K_RUN_TEXTO_MAX) e gravado em
          SEGMENTOS de ate K_RUN_TEXTO_MAX bytes, cada um com seu
          OFFSET (memoria limitada, nada se perde no meio);
        - linhas:  'OFFSET=<decimal> <bytes do run>'  + CRLF; os bytes
          sao gravados CRUS (o texto ja e ACP: ASCII/ANSI) - nada de
          conversao nem de texto fora do ACP.
      Runs que atravessam a fronteira entre blocos sao mantidos em
      memoria de um bloco para o outro (estado continuo), por isso o
      offset de cada byte e sempre absoluto e exato.

  Regras do repositorio: Delphi 7 puro (sem generics/anonymous/for..in),
  comentarios pt-BR ASCII, sem Forms, units <= 31 chars.
  ------------------------------------------------------------------
}
unit uExtratorTexto;

{$H+}

interface

uses
  SysUtils, Windows;

type
  // Resultado/estado da extracao (contrato publico).
  TExtracaoStatus = (
    etSucesso,           // terminou de varrer (sem teto ou arquivo < teto)
    etTetoAtingido,      // parou no TetoBytes (saida valida ate o teto)
    etArquivoVazio,      // caminho de origem nao informado
    etSaidaVazia,        // caminho de saida nao informado
    etOrigemInexistente, // arquivo de origem nao encontrado
    etFalhaAbrirOrigem,  // CreateFileW/GENERIC_READ falhou
    etFalhaCriarSaida,   // nao criou a saida p/ escrita
    etFalhaLer,          // erro de leitura no meio da varredura
    etFalhaEscrever,     // erro ao gravar a saida
    etCancelado          // flag de cancelamento acionado (saida apagada)
  );

  // Opcoes da extracao. ComprimentoMinimo <= 0 = default (6).
  // BlocoBytes = 0 = default (64 KiB).
  TExtracaoTextoOpcoes = record
    ArquivoOrigem: string;      // arquivo a varrer (so leitura; nunca muda)
    ArquivoSaida: string;       // dump de texto (criado/sobrescrito)
    ComprimentoMinimo: Integer; // tamanho minimo do run p/ gravar
    TetoBytes: Int64;           // 0 = sem teto; >0 = cap de bytes lidos
    BlocoBytes: DWORD;          // 0 = default (64 KiB)
  end;

  // Callback de progresso (por bloco, no thread da extracao).
  TProgressoExtracao = procedure(ABytesLidos, ABytesTotais: Int64)
    of object;

// ------------------------------------------------------------------
// Decisao PURA (testavel): o byte conta como texto legivel no ACP?
//   ASCII 32..126 (imprimivel) ou extensao ANSI 160..255.
// ------------------------------------------------------------------
function ByteContaComoTexto(AByte: Byte): Boolean;

// ------------------------------------------------------------------
// Decisao PURA (testavel): a partir de AInicio no buffer, ha um run de
// texto legivel com >= AComprimentoMinimo bytes? Devolve em
// AComprimento o tamanho do run contiguo (ate o fim do buffer).
// ------------------------------------------------------------------
function EhRunLegivel(const ABytes: array of Byte; AInicio: Integer;
  AComprimentoMinimo: Integer; out AComprimento: Integer): Boolean;

// ------------------------------------------------------------------
// Executa a varredura (funcao principal; ver cabecalho da unit).
// Devolve: ARunsGravados (linhas gravadas) e ABytesLidos (bytes
// escaneados ate o fim/teto). Em etCancelado/etFalha* a saida parcial
// e apagada (nunca sobra dump incompleto).
// ------------------------------------------------------------------
function ExtrairRunsDeTexto(const AOpcoes: TExtracaoTextoOpcoes;
  AProgresso: TProgressoExtracao; ACancelar: PBoolean;
  out ARunsGravados: Integer; out ABytesLidos: Int64): TExtracaoStatus;

// Texto pt-BR do status (logs e relatorios).
function ExtracaoStatusParaTexto(AStatus: TExtracaoStatus): string;
implementation

const
  K_COMPRIMENTO_MINIMO_DEFAULT = 6;   // default da config
  K_BLOCO_PADRAO               = 65536; // 64 KiB por leitura
  K_RUN_TEXTO_MAX              = 1048576; // 1 MiB por segmento de run

// GetFileSizeEx nao e seguro entre D7/FPC: binding proprio (padrao do
// repositorio: prefixo da unit + kernel32).
function XtGetFileSizeEx(hFile: THandle;
  var lpFileSize: Int64): BOOL; stdcall;
  external 'kernel32.dll' name 'GetFileSizeEx';

function ExtracaoStatusParaTexto(AStatus: TExtracaoStatus): string;
begin
  case AStatus of
    etSucesso:           Result := 'extracao concluida';
    etTetoAtingido:      Result := 'teto de bytes atingido (parada limpa)';
    etArquivoVazio:      Result := 'arquivo de origem nao informado';
    etSaidaVazia:        Result := 'arquivo de saida nao informado';
    etOrigemInexistente: Result := 'arquivo de origem nao encontrado';
    etFalhaAbrirOrigem:  Result := 'falha ao abrir a origem para leitura';
    etFalhaCriarSaida:   Result := 'falha ao criar a saida para escrita';
    etFalhaLer:          Result := 'erro de leitura durante a varredura';
    etFalhaEscrever:     Result := 'erro de escrita do dump';
    etCancelado:         Result := 'extracao cancelada';
  else
    Result := 'status desconhecido';
  end;
end;

function ByteContaComoTexto(AByte: Byte): Boolean;
begin
  Result := (AByte >= 32) and (AByte <= 126);  // ASCII imprimivel
  if not Result then
    Result := AByte >= 160;                    // extensao ANSI do ACP
end;

function EhRunLegivel(const ABytes: array of Byte; AInicio: Integer;
  AComprimentoMinimo: Integer; out AComprimento: Integer): Boolean;
var
  N, Min, I: Integer;
begin
  AComprimento := 0;
  Result := False;
  N := Length(ABytes);
  if (AInicio < 0) or (AInicio >= N) then
    Exit;
  Min := AComprimentoMinimo;
  if Min < 1 then
    Min := K_COMPRIMENTO_MINIMO_DEFAULT;
  I := AInicio;
  while (I < N) and ByteContaComoTexto(ABytes[I]) do
    Inc(I);
  AComprimento := I - AInicio;
  Result := AComprimento >= Min;
end;
// ------------------------------------------------------------------
// ExtrairRunsDeTexto (funcao principal; ver cabecalho da unit)
// ------------------------------------------------------------------
function ExtrairRunsDeTexto(const AOpcoes: TExtracaoTextoOpcoes;
  AProgresso: TProgressoExtracao; ACancelar: PBoolean;
  out ARunsGravados: Integer; out ABytesLidos: Int64): TExtracaoStatus;
var
  OrigemFull, SaidaFull: string;
  hOrigem, hSaida: THandle;
  Total, Limite, BytesLidos: Int64;
  Bloco, TamLer, nRead, nWr: DWORD;
  Minimo: Integer;
  Buf: array of Byte;
  // Estado do run corrente (atravessa a fronteira dos blocos).
  RunBuf: array of Byte;
  RunCount, RunCap: Integer;
  RunAtivo: Boolean;
  RunInicioAbs: Int64;
  RunJaGravou: Boolean;   // este run fisico ja gravou >= 1 segmento
  Status: TExtracaoStatus;
  I: Integer;
  B: Byte;

  // Int64 decimal sem depender de overload do IntToStr (D7 x FPC).
  function Int64Str(AValor: Int64): string;
  const
    K_DIGITOS = '0123456789';
  var
    BufDig: array [0..24] of Char;
    Qtd, J: Integer;
    V: Int64;
    Neg: Boolean;
    C: Char;
  begin
    Neg := AValor < 0;
    V := AValor;
    if Neg then
      V := -V;
    Qtd := 0;
    if V = 0 then
    begin
      Result := '0';
      Exit;
    end;
    while V > 0 do
    begin
      BufDig[Qtd] := K_DIGITOS[Integer(V mod 10) + 1];
      Inc(Qtd);
      V := V div 10;
    end;
    if Neg then
    begin
      BufDig[Qtd] := '-';
      Inc(Qtd);
    end;
    // inverte (os digitos sairam do menos significativo p/ o mais)
    SetLength(Result, Qtd);
    for J := 0 to Qtd - 1 do
    begin
      C := BufDig[Qtd - 1 - J];
      Result[J + 1] := C;
    end;
  end;

  // Garante capacidade do buffer do run (dobra, sem realocacao a cada
  // byte - evita custo quadratico em runs grandes).
  procedure GarantirCap(ANecessario: Integer);
  var
    Novo: Integer;
  begin
    if ANecessario > RunCap then
    begin
      Novo := RunCap;
      if Novo < 256 then
        Novo := 256;
      while Novo < ANecessario do
        Novo := Novo * 2;
      SetLength(RunBuf, Novo);
      RunCap := Novo;
    end;
  end;

  // Grava UMA linha do dump: 'OFFSET=<inicio> ' + bytes do run + CRLF.
  // Incrementa ARunsGravados. False = falha de escrita.
  function GravarLinhaRun(AInicio: Int64): Boolean;
  var
    Pref, Fim: string;
  begin
    Result := False;
    Pref := 'OFFSET=' + Int64Str(AInicio) + ' ';
    Fim := #13#10;
    nWr := 0;
    if not WriteFile(hSaida, Pref[1], Length(Pref), nWr, nil) then
      Exit;
    if RunCount > 0 then
    begin
      nWr := 0;
      if not WriteFile(hSaida, RunBuf[0], RunCount, nWr, nil) then
        Exit;
    end;
    nWr := 0;
    if not WriteFile(hSaida, Fim[1], Length(Fim), nWr, nil) then
      Exit;
    Result := True;
    Inc(ARunsGravados);
  end;
begin
  ARunsGravados := 0;
  ABytesLidos := 0;
  Status := etSucesso;
  RunAtivo := False;
  RunCount := 0;
  RunCap := 0;
  RunInicioAbs := 0;
  RunJaGravou := False;

  if AOpcoes.ArquivoOrigem = '' then
  begin
    Result := etArquivoVazio;
    Exit;
  end;
  if AOpcoes.ArquivoSaida = '' then
  begin
    Result := etSaidaVazia;
    Exit;
  end;

  OrigemFull := ExpandFileName(AOpcoes.ArquivoOrigem);
  SaidaFull := ExpandFileName(AOpcoes.ArquivoSaida);
  if not FileExists(OrigemFull) then
  begin
    Result := etOrigemInexistente;
    Exit;
  end;
  // Seguranca: o dump nunca pode cair sobre o proprio arquivo varrido
  // (a origem e SO LEITURA; nem a saida pode altera-la).
  if CompareText(OrigemFull, SaidaFull) = 0 then
  begin
    Result := etFalhaCriarSaida;
    Exit;
  end;

  hOrigem := CreateFileW(PWideChar(WideString(OrigemFull)), GENERIC_READ,
             FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
             FILE_ATTRIBUTE_NORMAL, 0);
  if hOrigem = INVALID_HANDLE_VALUE then
  begin
    Result := etFalhaAbrirOrigem;
    Exit;
  end;
  if not XtGetFileSizeEx(hOrigem, Total) then
  begin
    CloseHandle(hOrigem);
    Result := etFalhaAbrirOrigem;
    Exit;
  end;

  hSaida := CreateFileW(PWideChar(WideString(SaidaFull)), GENERIC_WRITE,
             0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if hSaida = INVALID_HANDLE_VALUE then
  begin
    CloseHandle(hOrigem);
    Result := etFalhaCriarSaida;
    Exit;
  end;

  Minimo := AOpcoes.ComprimentoMinimo;
  if Minimo < 1 then
    Minimo := K_COMPRIMENTO_MINIMO_DEFAULT;
  Bloco := AOpcoes.BlocoBytes;
  if Bloco = 0 then
    Bloco := K_BLOCO_PADRAO;
  Limite := Total;
  if (AOpcoes.TetoBytes > 0) and (AOpcoes.TetoBytes < Limite) then
    Limite := AOpcoes.TetoBytes;
  SetLength(Buf, Bloco);
  BytesLidos := 0;

  try
    while BytesLidos < Limite do
    begin
      if (ACancelar <> nil) and ACancelar^ then
      begin
        Status := etCancelado;
        Break;
      end;
      TamLer := Bloco;
      if (Limite - BytesLidos) < Int64(TamLer) then
        TamLer := DWORD(Limite - BytesLidos);
      nRead := 0;
      if not ReadFile(hOrigem, Buf[0], TamLer, nRead, nil) then
      begin
        Status := etFalhaLer;
        Break;
      end;
      if nRead = 0 then
        Break;   // fim do arquivo (ou arquivo encolheu entre size e leitura)
      // Varre o bloco byte a byte. Offset absoluto do byte = BytesLidos
      // (bytes ja consumidos) + indice dentro do bloco.
      for I := 0 to Integer(nRead) - 1 do
      begin
        B := Buf[I];
        if not ByteContaComoTexto(B) then
        begin
          // Fim de run: grava se qualificado (>= minimo) ou se ja havia
          // segmento gravado deste run fisico (nao perder a cauda).
          if RunAtivo then
          begin
            if (RunCount >= Minimo) or RunJaGravou then
              if not GravarLinhaRun(RunInicioAbs) then
              begin
                Status := etFalhaEscrever;
                Break;
              end;
            RunAtivo := False;
            RunCount := 0;
            RunJaGravou := False;
          end;
        end
        else
        begin
          if not RunAtivo then
          begin
            RunAtivo := True;
            RunInicioAbs := BytesLidos + Int64(I);
            RunCount := 0;
            RunJaGravou := False;
          end;
          if RunCount >= K_RUN_TEXTO_MAX then
          begin
            // Segmento cheio: grava e comeca o proximo segmento AQUI.
            if not GravarLinhaRun(RunInicioAbs) then
            begin
              Status := etFalhaEscrever;
              Break;
            end;
            RunJaGravou := True;
            RunInicioAbs := BytesLidos + Int64(I);
            RunCount := 0;
          end;
          GarantirCap(RunCount + 1);
          RunBuf[RunCount] := B;
          Inc(RunCount);
        end;
      end;
      if Status <> etSucesso then
        Break;
      BytesLidos := BytesLidos + Int64(nRead);
      if Assigned(AProgresso) then
        AProgresso(BytesLidos, Total);
    end;
    // Run ativo no fim do arquivo/teto: fecha com a mesma regra.
    // (AQUI, antes dos CloseHandle: o ultimo run ainda escreve no handle.)
    if ((Status = etSucesso) or (Status = etTetoAtingido)) and RunAtivo then
    begin
      if (RunCount >= Minimo) or RunJaGravou then
        if not GravarLinhaRun(RunInicioAbs) then
          Status := etFalhaEscrever;
      RunAtivo := False;
    end;
  finally
    Buf := nil;
    RunBuf := nil;
    CloseHandle(hSaida);
    CloseHandle(hOrigem);
  end;

  ABytesLidos := BytesLidos;
  if (Status = etSucesso) and (Limite < Total) then
    Status := etTetoAtingido;

  // Falha/cancelamento: apaga a saida parcial (nunca sobra dump que
  // pareca completo). etTetoAtingido e parada limpa: saida mantida.
  if (Status <> etSucesso) and (Status <> etTetoAtingido) then
    SysUtils.DeleteFile(SaidaFull);

  Result := Status;
end;

end.
