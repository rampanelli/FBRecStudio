{
  uHistoryStore.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  Historico de recuperacoes em CSV anexo (PLANO.md 4.6 e 6.6).

    * Arquivo: %APPDATA%\FBRecStudio\history.csv (criado com cabecalho
      na primeira gravacao; linha por gravacao, formato append).
    * Separador ';' e regra de escape CSV (aspas duplas quando o campo
      contiver ';' '"' CR ou LF).
    * Codificacao ANSI (Windows ACP). Nenhum dado binario.
    * A coluna hash e preenchida pelo chamador com uHash (MD5/SHA-1 do
      arquivo de origem); aqui so se formata/grava.

  Comentarios pt-BR sem diacriticos (ASCII) - compatibilidade Delphi 7.
  ------------------------------------------------------------------
}
unit uHistoryStore;

{$H+}

interface

uses
  SysUtils, Classes;

const
  HISTORY_FILE_NAME = 'history.csv';
  HISTORY_SEPARATOR = ';';

type
  // Uma linha do historico (mesma ordem das colunas do cabecalho).
  THistoryEntry = record
    Id: string;               // GUID da operacao
    Data: string;             // ISO aaaa-mm-dd hh:nn:ss (local)
    ArquivoOrigem: string;    // .fdb/.fb/.gdb de origem
    Tipo: string;             // ex.: FB, IB, desconhecido
    BinarioVersao: string;    // ex.: Firebird 2.5.9
    Tecnica: string;          // ex.: nbackup, gbak, arvore
    ParametrosMascarados: string; // comando exibido (-pass mascarado)
    ExitCode: string;         // codigo de saida (texto; '' se nao aplica)
    DuracaoMs: Int64;         // duracao da operacao
    Destino: string;          // arquivo gerado / destino
    TamanhoBytes: Int64;      // tamanho do destino
    Status: string;           // ok | erro | cancelado | timeout
    Resumo: string;           // ultima linha relevante da ferramenta
    Hash: string;             // hash do arquivo de origem (uHash)
    CaminhoLog: string;       // log da operacao (se houver)
  end;

// Escapa UM campo CSV (regra do formato).
function CsvEscape(const AValue: string): string;

// Cabecalho do historico (gravado uma unica vez).
function HistoryHeader: string;

// Converte o registro em uma linha CSV (sem quebra final).
function HistoryEntryToCsv(const E: THistoryEntry): string;

// Novo identificador de operacao (GUID sem chaves; ex. para a coluna 'id'
// e para o nome do log por operacao).
function NewOperationId: string;

// Data ISO local 'aaaa-mm-dd hh:nn:ss' para a coluna 'data'.
function IsoNow: string;

type
  THistoryStore = class
  private
    FFileName: string;
  public
    // AFileName vazio => %APPDATA%\FBRecStudio\history.csv
    constructor Create(const AFileName: string);

    // Anexa uma linha; cria arquivo + cabecalho na primeira vez.
    procedure AppendEntry(const E: THistoryEntry);

    // Quantidade de operacoes gravadas (linhas sem o cabecalho).
    function EntryCount: Integer;

    property FileName: string read FFileName;
  end;

implementation

uses
  uAppConfig;

// ------------------------------------------------------------------
function CsvEscape(const AValue: string): string;
var
  NeedQuotes: Boolean;
  I: Integer;
  Ch: Char;
begin
  NeedQuotes := False;
  for I := 1 to Length(AValue) do
  begin
    Ch := AValue[I];
    if (Ch = HISTORY_SEPARATOR) or (Ch = '"') or (Ch = #13) or (Ch = #10) then
    begin
      NeedQuotes := True;
      Break;
    end;
  end;
  if not NeedQuotes then
    Result := AValue
  else
  begin
    Result := '"';
    for I := 1 to Length(AValue) do
    begin
      Ch := AValue[I];
      if Ch = '"' then
        Result := Result + '""'
      else if (Ch <> #13) and (Ch <> #10) then
        Result := Result + Ch
      else
        Result := Result + ' '; // quebras dentro do campo viram espaco
    end;
    Result := Result + '"';
  end;
end;

function HistoryHeader: string;
begin
  Result := 'id' + HISTORY_SEPARATOR +
            'data' + HISTORY_SEPARATOR +
            'arquivo_origem' + HISTORY_SEPARATOR +
            'tipo' + HISTORY_SEPARATOR +
            'binario_versao' + HISTORY_SEPARATOR +
            'tecnica' + HISTORY_SEPARATOR +
            'parametros_mascarados' + HISTORY_SEPARATOR +
            'exit_code' + HISTORY_SEPARATOR +
            'duracao_ms' + HISTORY_SEPARATOR +
            'destino' + HISTORY_SEPARATOR +
            'tamanho_bytes' + HISTORY_SEPARATOR +
            'status' + HISTORY_SEPARATOR +
            'resumo' + HISTORY_SEPARATOR +
            'hash' + HISTORY_SEPARATOR +
            'caminho_log';
end;

function HistoryEntryToCsv(const E: THistoryEntry): string;
begin
  Result := CsvEscape(E.Id) + HISTORY_SEPARATOR +
            CsvEscape(E.Data) + HISTORY_SEPARATOR +
            CsvEscape(E.ArquivoOrigem) + HISTORY_SEPARATOR +
            CsvEscape(E.Tipo) + HISTORY_SEPARATOR +
            CsvEscape(E.BinarioVersao) + HISTORY_SEPARATOR +
            CsvEscape(E.Tecnica) + HISTORY_SEPARATOR +
            CsvEscape(E.ParametrosMascarados) + HISTORY_SEPARATOR +
            CsvEscape(E.ExitCode) + HISTORY_SEPARATOR +
            IntToStr(E.DuracaoMs) + HISTORY_SEPARATOR +
            CsvEscape(E.Destino) + HISTORY_SEPARATOR +
            IntToStr(E.TamanhoBytes) + HISTORY_SEPARATOR +
            CsvEscape(E.Status) + HISTORY_SEPARATOR +
            CsvEscape(E.Resumo) + HISTORY_SEPARATOR +
            CsvEscape(E.Hash) + HISTORY_SEPARATOR +
            CsvEscape(E.CaminhoLog);
end;

// ------------------------------------------------------------------
function NewOperationId: string;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := GUIDToString(G);
  // remove as chaves { }
  Result := Copy(Result, 2, Length(Result) - 2);
end;

// ------------------------------------------------------------------
function IsoNow: string;
begin
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
end;

// ------------------------------------------------------------------
function DefaultHistoryPath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetAppDataDir) + HISTORY_FILE_NAME;
end;

constructor THistoryStore.Create(const AFileName: string);
begin
  inherited Create;
  if AFileName <> '' then
    FFileName := AFileName
  else
    FFileName := DefaultHistoryPath;
end;

// ------------------------------------------------------------------
procedure THistoryStore.AppendEntry(const E: THistoryEntry);
var
  FS: TFileStream;
  Line: string;
  Existing: Boolean;
begin
  ForceDirectories(ExtractFilePath(FFileName));
  Line := HistoryEntryToCsv(E) + #13#10;
  Existing := FileExists(FFileName);
  // fmCreate SOZINHO trunca o arquivo; quando o arquivo ja existe
  // abrimos sem fmCreate (append preserva o historico anterior).
  if Existing then
    FS := TFileStream.Create(FFileName, fmOpenWrite or fmShareDenyWrite)
  else
    FS := TFileStream.Create(FFileName, fmCreate);
  try
    if Existing then
      FS.Seek(0, soFromEnd)
    else
    begin
      Line := HistoryHeader + #13#10 + Line; // cabecalho na 1a gravacao
      FS.Seek(0, soBeginning);
    end;
    FS.WriteBuffer(Line[1], Length(Line));
  finally
    FS.Free;
  end;
end;

// ------------------------------------------------------------------
function THistoryStore.EntryCount: Integer;
var
  SL: TStringList;
begin
  Result := 0;
  if not FileExists(FFileName) then
    Exit;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FFileName); // leitura em ACP (ANSI)
    if SL.Count > 0 then
      Result := SL.Count - 1; // desconsidera o cabecalho
  finally
    SL.Free;
  end;
end;

end.
