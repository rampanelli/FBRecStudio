{
  uLogger.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  Log estruturado (PLANO.md, secao 4.4 item 3 e 6.8). Formato canonico
  de CADA linha:

      [aaaa-mm-dd hh:nn:ss.zzz] [etapa] [stdout|stderr|app] mensagem

  * 'etapa'   = fase/unidade que produziu a linha (ex.: 'main', 'gbak',
                'restore', 'selftest'). Sempre presente (nao vazio).
  * 'canal'   = origem da mensagem: LC_STDOUT, LC_STDERR (linhas cruas
                decodificadas de pipes) ou LC_APP (mensagens do proprio
                aplicativo). Usar uTextCodec.DecodeConsoleBytes antes de
                logar bytes vindos de processo filho (secc. 6.5).
  * Arquivo em UTF-8 COM BOM: o BOM e gravado somente quando o arquivo e
    criado; em append o BOM nao se repete.
  * Thread-safe (TCriticalSection) - pipelines rodam em worker thread.
  * NUNCA logar senha em claro: para comandos montados por argv use
    uQuoting.MakeDisplayCommandLine; para textos avulsos que contenham
    '-pass <valor>' use MaskCommandPassword antes de gravar.

  Comentarios pt-BR sem diacriticos (ASCII) por compatibilidade D7.
  ------------------------------------------------------------------
}
unit uLogger;

{$H+}

interface

uses
  SysUtils, Classes, SyncObjs;

const
  // Canais validos do campo [stdout|stderr|app]
  LC_APP    = 'app';
  LC_STDOUT = 'stdout';
  LC_STDERR = 'stderr';

  // Sufixo/tipo do log geral de operacao: <dir>\YYYYMMDD_HHNNSS_<id>.log
  // (PLANO.md 6.6). A pasta fica em %APPDATA%\FBRecStudio\logs\.
  LOG_FILE_MASK = 'yyyymmdd_hhnnss';

type
  TLogger = class
  private
    FStream: TFileStream;
    FLock: TCriticalSection;
    FFileName: string;
    FOpened: Boolean;
    procedure DoClose;
  public
    constructor Create;
    destructor Destroy; override;

    // Abre o arquivo para append (cria a pasta se preciso). Quando o
    // arquivo nao existe, cria com BOM UTF-8; quando existe, posiciona
    // no fim sem repetir o BOM. Retorna False em falha.
    function Open(const AFileName: string): Boolean;
    procedure Close;
    function IsOpen: Boolean;

    // Escreve uma linha no formato canonico (canal explicito).
    procedure Log(const AStage, AChannel: string; const AMessage: string);

    // Atalhos com canal 'app' (mensagens do proprio aplicativo).
    procedure Info(const AStage, AMessage: string);
    procedure Warn(const AStage, AMessage: string);
    procedure Error(const AStage, AMessage: string);

    property FileName: string read FFileName;
  end;

// Timestamp "aaaa-mm-dd hh:nn:ss.zzz" (sem colchetes).
function NowStamp: string;

// Gera um nome de arquivo de log por operacao:
//   YYYYMMDD_HHNNSS_<AOperationId>.log  (caracteres invalidos viram '_').
// ADir deve terminar com separador de diretorio (ex.: logs do app).
function BuildLogFileName(const ADir, AOperationId: string): string;

// Mascara senhas em uma linha de comando JA (ja) renderizada como texto:
// substitui o valor que segue -pass/-password/--pass/--password//pass
// (com '=' ou separado por espaco, inclusive valor entre aspas) por
// '******'. Preferir uQuoting.MakeDisplayCommandLine quando se tem o
// argv tipado; esta funcao cobre textos avulsos/colados em logs.
function MaskCommandPassword(const ACmd: string): string;

// Registrador global de conveniencia, criado/carregado no dpr (F0).
var
  AppLogger: TLogger = nil;

implementation

uses
  uTextCodec;

// ------------------------------------------------------------------
function NowStamp: string;
begin
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now);
end;

// ------------------------------------------------------------------
function BuildLogFileName(const ADir, AOperationId: string): string;
var
  Base, Id: string;
  I: Integer;
begin
  Id := AOperationId;
  for I := 1 to Length(Id) do
    if not (Id[I] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '_']) then
      Id[I] := '_';
  Base := FormatDateTime(LOG_FILE_MASK, Now);
  Result := ADir;
  if (Result <> '') and (Result[Length(Result)] <> '\') then
    Result := Result + '\';
  Result := Result + Base + '_' + Id + '.log';
end;

// ------------------------------------------------------------------
function MaskCommandPassword(const ACmd: string): string;
const
  Kw: array[0..5] of string =
    ('-pass', '-password', '--pass', '--password', '/pass', '/password');
var
  Up, W: string;
  I, J, P, K, L: Integer;
  InQuotes: Boolean;
  Matched: Boolean;
begin
  Result := '';
  L := Length(ACmd);
  if L = 0 then
    Exit;
  Up := UpperCase(ACmd);
  J := 1;      // inicio do trecho ainda nao copiado
  I := 1;
  while I <= L do
  begin
    Matched := False;
    // A keyword so casa no inicio de um token (ou depois de '=').
    if (I = 1) or (ACmd[I - 1] in [' ', #9, '=']) then
    begin
      for K := 0 to High(Kw) do
      begin
        W := UpperCase(Kw[K]);
        if (I + Length(W) - 1 <= L) and
           (Copy(Up, I, Length(W)) = W) then
        begin
          P := I + Length(W);
          if (P > L) or (ACmd[P] in [' ', #9, '=']) then
          begin
            // copia texto anterior + a propria keyword
            Result := Result + Copy(ACmd, J, I - J) + Kw[K];
            Matched := True;
            if P <= L then
            begin
              if ACmd[P] = '=' then
              begin
                Result := Result + '=';
                Inc(P);
              end
              else
              begin
                // mantem os separadores e pula para o inicio do valor
                while (P <= L) and (ACmd[P] in [' ', #9]) do
                begin
                  Result := Result + ACmd[P];
                  Inc(P);
                end;
              end;
              // consome o valor (entre aspas ou ate o proximo espaco)
              InQuotes := False;
              while P <= L do
              begin
                if ACmd[P] = '"' then
                  InQuotes := not InQuotes
                else if (not InQuotes) and (ACmd[P] in [' ', #9]) then
                  Break;
                Inc(P);
              end;
              Result := Result + '******';
            end;
            I := P;   // P pode ser L + 1 (fim da string)
            J := I;
            Break;    // sai do for de keywords
          end;
        end;
      end;
    end;
    if not Matched then
      Inc(I);
  end;
  // trecho final nao copiado
  if J <= L then
    Result := Result + Copy(ACmd, J, L - J + 1);
end;

// ------------------------------------------------------------------
constructor TLogger.Create;
begin
  inherited Create;
  FOpened := False;
  FFileName := '';
  FStream := nil;
  FLock := TCriticalSection.Create;
end;

destructor TLogger.Destroy;
begin
  Close;
  FLock.Free;
  inherited Destroy;
end;

// ------------------------------------------------------------------
procedure TLogger.DoClose;
begin
  if FOpened then
  begin
    FStream.Free;
    FStream := nil;
    FOpened := False;
    FFileName := '';
  end;
end;

procedure TLogger.Close;
begin
  FLock.Enter;
  try
    DoClose;
  finally
    FLock.Leave;
  end;
end;

function TLogger.IsOpen: Boolean;
begin
  Result := FOpened;
end;

// ------------------------------------------------------------------
function TLogger.Open(const AFileName: string): Boolean;
var
  Dir: string;
  Bom: array[0..2] of Byte;
begin
  Result := False;
  if AFileName = '' then
    Exit;
  FLock.Enter;
  try
    DoClose;
    Dir := ExtractFilePath(AFileName);
    if Dir <> '' then
      ForceDirectories(Dir);
    if FileExists(AFileName) then
    begin
      FStream := TFileStream.Create(AFileName, fmOpenReadWrite or fmShareDenyNone);
      FStream.Seek(0, soEnd);
    end
    else
    begin
      FStream := TFileStream.Create(AFileName, fmCreate or fmShareDenyNone);
      Bom[0] := $EF;   // BOM UTF-8 (so na criacao)
      Bom[1] := $BB;
      Bom[2] := $BF;
      FStream.WriteBuffer(Bom, SizeOf(Bom));
    end;
    FFileName := AFileName;
    FOpened := True;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

// ------------------------------------------------------------------
procedure TLogger.Log(const AStage, AChannel: string; const AMessage: string);
var
  Line, Utf8: AnsiString;
begin
  if not FOpened then
    Exit;
  Line := '[' + NowStamp + '] [' + AStage + '] [' + AChannel + '] ' +
          AMessage;
  Utf8 := uTextCodec.AnsiToUtf8(Line) + #13#10;
  FLock.Enter;
  try
    if FOpened and (Length(Utf8) > 0) then
      FStream.WriteBuffer(Utf8[1], Length(Utf8));
  except
    // Log nunca deve derrubar o aplicativo; falha de escrita e ignorada.
  end;
  FLock.Leave;
end;

procedure TLogger.Info(const AStage, AMessage: string);
begin
  Log(AStage, LC_APP, AMessage);
end;

procedure TLogger.Warn(const AStage, AMessage: string);
begin
  Log(AStage, LC_APP, AMessage);
end;

procedure TLogger.Error(const AStage, AMessage: string);
begin
  Log(AStage, LC_APP, AMessage);
end;

end.
