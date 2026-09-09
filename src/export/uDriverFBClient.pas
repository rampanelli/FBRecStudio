{
  uDriverFBClient.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  Driver REAL de leitura via fbclient.dll (Firebird 2.5, modo
  embarcado) para o contrato IDriverCatalogo/ILeitorLinhas do
  uExportCSV (decisao 9.3 / F5-T3+T4).

    * fbclient.dll carregada DINAMICAMENTE (LoadLibrary + GetProcAddress,
      todos os tipos stdcall) - NUNCA static link. Se a dll nao existir,
      a fabrica devolve nil com AMsg amigavel
      ('fbclient nao encontrado em <caminho>') sem crash.
    * Conexao EMBARCADA: caminho local do banco (sem host); usuario e
      senha sao ignorados pelo motor embarcado (passa 'sysdba' e
      'masterkey' no DPB mesmo assim, como o cliente espera).
    * API ISC usada: isc_attach_database / isc_start_transaction /
      isc_dsql_allocate_statement / isc_dsql_prepare / isc_dsql_describe /
      isc_dsql_execute / isc_dsql_fetch / isc_dsql_free_statement /
      isc_commit_transaction / isc_detach_database / isc_interprete
      (mensagens de erro) e BLOB: isc_open_blob2 / isc_get_segment /
      isc_close_blob.
    * XSQLDA/XSQLVAR como packed records; XSQLDA_LENGTH(n) =
      SizeOf(cabecalho) + (n-1)*SizeOf(XSQLVAR); bloco unico via
      GetMem + FillChar.
    * Tipos: SQL_VARYING=448 / SQL_TEXT=452 / SQL_SHORT=500 /
      SQL_LONG=496 / SQL_FLOAT=482 / SQL_DOUBLE=480 /
      SQL_TIMESTAMP=510 / SQL_BLOB=520 / SQL_ARRAY=540 /
      SQL_QUAD=550 / SQL_TYPE_TIME=560 / SQL_TYPE_DATE=570 /
      SQL_INT64=580. Escala negativa em SHORT/LONG/INT64 =
      NUMERIC/DECIMAL (formata o ponto decimal). ISC_DATE = dias
      desde 17-Nov-1858; ISC_TIME = 1/10000 s desde meia-noite.
      CHAR sem espacos a direita; VARCHAR com length explicita.
      NULL: sqlind negativo -> Nulo=True. BLOB: le o blob_id
      (ISC_QUAD) do sqldata e abre com isc_open_blob2; acumula os
      segmentos; EhBlob=True e Bytes preenchidos. ARRAY/QUAD sao
      marcados como nao suportados (celula Nulo=True).
    * Fabrica publica: CriarDriverFBClient(ADllPath, ABanco, AMsg)
      devolve IDriverFBConsulta (descendente de IDriverCatalogo com
      ContarRegistros extra, usada pelo teste de console).

  Regras do repositorio: Delphi 7 puro (sem generics/anonymous/for..in),
  comentarios pt-BR ASCII, unidades <= 31 chars.
  ------------------------------------------------------------------
}
unit uDriverFBClient;

{$H+}

interface

uses
  Windows, SysUtils, Classes, uExportCSV;

type
  // Contrato do driver (IDriverCatalogo) + conveniencia de contagem
  // para o teste de console (nao faz parte do contrato do uExportCSV).
  IDriverFBConsulta = interface(IDriverCatalogo)
    ['{D5F2A8C1-3B7E-4D9F-8A2C-6E1B4D7F90A3}']
    // Conta os registros de uma tabela de usuario (SELECT COUNT(*)).
    function ContarRegistros(const ATabela: string; out Total: Int64;
      var Msg: string): Boolean;
  end;

// Fabrica: carrega fbclient.dll de ADllPath (pasta OU caminho cheio da
// dll; vazio = 'fbclient.dll'), conecta EMBARCADO em ABanco (caminho
// local, sem host) e devolve o driver pronto. Em falha devolve nil e
// preenche AMsg com motivo amigavel (nunca levanta excecao).
function CriarDriverFBClient(const ADllPath, ABanco: string;
  var AMsg: string): IDriverFBConsulta;

implementation

const
  // Versao do XSQLDA e opcoes
  SQLDA_VERSION = 1;
  DSQL_DROP = 1;            // isc_dsql_free_statement: encerra o stmt

  // Tipos SQL (Firebird / ibase.h)
  SQL_VARYING   = 448;
  SQL_TEXT      = 452;
  SQL_DOUBLE    = 480;
  SQL_FLOAT     = 482;
  SQL_LONG      = 496;
  SQL_SHORT     = 500;
  SQL_TIMESTAMP = 510;
  SQL_BLOB      = 520;
  SQL_ARRAY     = 540;
  SQL_QUAD      = 550;
  SQL_TYPE_TIME = 560;
  SQL_TYPE_DATE = 570;
  SQL_INT64     = 580;

  // isc_get_segment: retornos especiais no status[1] (GDS codes do
  // iberror.h - NAO sao os SQLCODE 100/101):
  //   isc_segment   = 335544366: pedaco de segmento lido (ha mais do
  //                   MESMO segmento quando o buffer e menor que ele);
  //   isc_segstr_eof= 335544367: fim do blob (nenhum dado novo).
  K_ISC_SEGMENT   = 335544366;
  K_ISC_SEGSTR_EOF = 335544367;

  // DPB (database parameter buffer)
  K_DPB_VERSION1  = 1;
  K_DPB_USER_NAME = 28;
  K_DPB_PASSWORD  = 29;

  // Dialeto SQL do cliente (Firebird nativo)
  K_DIALETO = 3;

  // Dias entre 17-Nov-1858 (epoca ISC_DATE) e 30-Dez-1899 (TDateTime 0)
  K_DIAS_EPOCA = 15018;

  // Limite de colunas do primeiro describe (realoca se passar)
  K_SQLN_INICIAL = 20;

type
  TISCStatus = Longint;
  TStatusVector = array[0..19] of TISCStatus;

  // ------------------------------------------------------------------
  // XSQLVAR (packed, 152 bytes no cliente 32-bit) e XSQLDA (cabecalho
  // de 6 bytes + 1 XSQLVAR). Alinhamento igual ao C (sem padding).
  // ------------------------------------------------------------------
  PSQLVAR = ^TSQLVAR;
  TSQLVAR = packed record
    sqltype: Smallint;
    sqlscale: Smallint;
    sqlsubtype: Smallint;
    sqllen: Smallint;
    sqldata: Pointer;
    sqlind: PSmallint;
    sqlname_length: Smallint;
    sqlname: array[0..31] of AnsiChar;
    relname_length: Smallint;
    relname: array[0..31] of AnsiChar;
    ownname_length: Smallint;
    ownname: array[0..31] of AnsiChar;
    aliasname_length: Smallint;
    aliasname: array[0..31] of AnsiChar;
  end;

  PXSQLDA = ^TXSQLDA;
  // Cabecalho do XSQLDA EXTENDIDO (sqlda_pub.h do Firebird 2.5):
  // version(2) + sqldaid[8] + sqldabc(4, alinhado) + sqln(2) + sqld(2)
  // = 20 bytes antes de sqlvar; SizeOf = 20 + SizeOf(TSQLVAR) = 172 no
  // cliente 32-bit (o record NAO e packed para o Longint ganhar o mesmo
  // alinhamento de 4 bytes do C; sem isso o fetch falha com -804).
  TXSQLDA = record
    version: Smallint;
    sqldaid: array[0..7] of AnsiChar;
    sqldabc: Longint;
    sqln: Smallint;
    sqld: Smallint;
    sqlvar: array[0..0] of TSQLVAR;
  end;

  // ISC_QUAD: blob_id (8 bytes no sqldata de colunas BLOB)
  TISCQuad = packed record
    GdsHigh: Longint;
    GdsLow: Longint;
  end;

  // ------------------------------------------------------------------
  // Tipos de procedimento (TODOS stdcall - API C do Firebird)
  // ------------------------------------------------------------------
  TAttachDatabase = function(var Status: TStatusVector; ANameLen: Word;
    const AName: PAnsiChar; var ADb: Longint; AParLen: Word;
    APar: Pointer): TISCStatus; stdcall;

  TStartTransaction = function(var Status: TStatusVector; var ATr: Longint;
    ACount: Word; var ADb: Longint; ATpbLen: Word;
    ATpb: Pointer): TISCStatus; stdcall;

  TCommitTransaction = function(var Status: TStatusVector;
    var ATr: Longint): TISCStatus; stdcall;

  TDetachDatabase = function(var Status: TStatusVector;
    var ADb: Longint): TISCStatus; stdcall;

  TDsqlAllocate = function(var Status: TStatusVector; var ADb: Longint;
    var AStmt: Longint): TISCStatus; stdcall;

  TDsqlPrepare = function(var Status: TStatusVector; var ATr: Longint;
    var AStmt: Longint; ALen: Word; const ASql: PAnsiChar; ADialect: Word;
    ASqlda: Pointer): TISCStatus; stdcall;

  TDsqlDescribe = function(var Status: TStatusVector; var AStmt: Longint;
    AVersion: Word; ASqlda: Pointer): TISCStatus; stdcall;

  TDsqlExecute = function(var Status: TStatusVector; var ATr: Longint;
    var AStmt: Longint; AVersion: Word; AInSqlda: Pointer): TISCStatus; stdcall;

  TDsqlFetch = function(var Status: TStatusVector; var AStmt: Longint;
    AVersion: Word; AOutSqlda: Pointer): TISCStatus; stdcall;

  TDsqlFreeStmt = function(var Status: TStatusVector; var AStmt: Longint;
    AOption: Word): TISCStatus; stdcall;

  TInterprete = function(ABuf: PAnsiChar;
    var ALocal: PAnsiChar): TISCStatus; stdcall;

  TOpenBlob2 = function(var Status: TStatusVector; var ADb: Longint;
    var ATr: Longint; var ABlob: Longint; const ABlobId: Pointer;
    ABpbLen: Word; ABpb: Pointer): TISCStatus; stdcall;

  TGetSegment = function(var Status: TStatusVector; var ABlob: Longint;
    var ASegLen: Word; ABufLen: Word; ABuf: Pointer): TISCStatus; stdcall;

  TCloseBlob = function(var Status: TStatusVector;
    var ABlob: Longint): TISCStatus; stdcall;

  // ------------------------------------------------------------------
  // TFBStatement: um statement DSQL preparado/descrito + buffers de
  // saida alocados. Usado pelo cursor e pelas consultas internas.
  // ------------------------------------------------------------------
  TFBDatabase = class;

  TFBStatement = class
  private
    FDrv: TFBDatabase;     // dono das procs (nao e dono do objeto)
    FStmt: Longint;        // handle do statement (0 = liberado)
    FSqlda: PXSQLDA;       // area de descricao + buffers
    FBufs: array of Pointer;
    FInds: array of PSmallint;
    FNCols: Integer;
    function GetColuna(AIndex: Integer): PSQLVAR;
    function LerBlob(const ABlobId: Pointer; var Bytes: TBytesCSV;
      var AMsg: string): Boolean;
  public
    constructor Create(ADrv: TFBDatabase);
    destructor Destroy; override;
    // Prepara + descreve + aloca buffers. True em sucesso.
    function Preparar(const ASql: string; var AMsg: string): Boolean;
    // Executa o statement (obrigatorio antes do primeiro LerLinha).
    function Executar(var AMsg: string): Boolean;
    // True = linha lida (Valores preenchido, Length = NCols);
    // False = fim do resultado (Msg='') ou erro (Msg<>'').
    function LerLinha(var Valores: TCamposLinha; var Msg: string): Boolean;
    // Libera handle + buffers (idempotente; chamado no Destroy).
    procedure Liberar;
    property Stmt: Longint read FStmt;
    property NCols: Integer read FNCols;
    property Sqlda: PXSQLDA read FSqlda;
    property Coluna[AIndex: Integer]: PSQLVAR read GetColuna;
  end;

  // ------------------------------------------------------------------
  // TFBCursorLeitor: cursor de leitura de uma tabela (ILeitorLinhas).
  // ------------------------------------------------------------------
  TFBCursorLeitor = class(TInterfacedObject, ILeitorLinhas)
  private
    FDrv: TFBDatabase;
    FStmt: TFBStatement;
    FFechado: Boolean;
  public
    constructor Create(ADrv: TFBDatabase; AStmt: TFBStatement);
    destructor Destroy; override;
    // Chamado pelo driver no encerramento (libera o statement).
    procedure EncerrarPeloDriver;
    function ProximaLinha(var Valores: TCamposLinha;
      var Msg: string): Boolean;
  end;

  // ------------------------------------------------------------------
  // TFBDatabase: a conexao embarcada + contrato IDriverCatalogo.
  // ------------------------------------------------------------------
  TFBDatabase = class(TInterfacedObject, IDriverCatalogo, IDriverFBConsulta)
  private
    FDll: THandle;
    FDllPath: string;
    FAttach: TAttachDatabase;
    FStart: TStartTransaction;
    FCommit: TCommitTransaction;
    FDetach: TDetachDatabase;
    FAllocate: TDsqlAllocate;
    FPrepare: TDsqlPrepare;
    FDescribe: TDsqlDescribe;
    FExecute: TDsqlExecute;
    FFetch: TDsqlFetch;
    FFreeStmt: TDsqlFreeStmt;
    FInterprete: TInterprete;
    FOpenBlob2: TOpenBlob2;
    FGetSegment: TGetSegment;
    FCloseBlob: TCloseBlob;
    FDb: Longint;
    FTr: Longint;
    FFechado: Boolean;
    FErroInit: string;
    FLeitores: TList;
    FDecSep: Char;
    function CarregarFuncoes(var AMsg: string): Boolean;
    function MsgStatus(const St: TStatusVector;
      const AContexto: string): string;
    function InterpreteTexto(const St: TStatusVector): string;
    procedure RemoverLeitor(ACursor: TObject);
    procedure EncerrarCursor(ACursor: TObject);
  public
    constructor Create(const ADllPath, ABanco: string; var AMsg: string);
    destructor Destroy; override;
    // IDriverCatalogo
    function NomeDriver: string;
    function ListarTabelas(var Tabelas: TStringList;
      var Msg: string): Boolean;
    function ListarColunas(const ATabela: string;
      var Colunas: TListaColunas; var Msg: string): Boolean;
    function AbrirLeitura(const ATabela: string; out Leitor: ILeitorLinhas;
      var Msg: string): Boolean;
    // IDriverFBConsulta
    function ContarRegistros(const ATabela: string; out Total: Int64;
      var Msg: string): Boolean;
    property Fechado: Boolean read FFechado;
    property ErroInit: string read FErroInit;
  end;

// ==================================================================
// Helpers
// ==================================================================
function XSQLDA_LENGTH(AN: Integer): Integer;
begin
  Result := SizeOf(TXSQLDA) + (AN - 1) * SizeOf(TSQLVAR);
end;

function BytesAnsi(const ABuf: Pointer; ALen: Integer): AnsiString;
begin
  Result := '';
  if (ABuf = nil) or (ALen <= 0) then
    Exit;
  SetLength(Result, ALen);
  Move(ABuf^, Result[1], ALen);
end;

// Nome de tabela em SQL: usa o nome puro quando so tem A-Za-z0-9_$ e nao
// comeca com digito (compativel com bancos dialeto 1); senao cita com
// aspas duplas (identificadores criados entre aspas no dialeto 3).
function NomeTabelaSQL(const ANome: string): string;
var
  I: Integer;
  Precisa: Boolean;
begin
  Precisa := False;
  if ANome = '' then
    Precisa := True
  else if not ((ANome[1] in ['A'..'Z', 'a'..'z']) or (ANome[1] = '_')) then
    Precisa := True
  else
    for I := 2 to Length(ANome) do
      if not (ANome[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '$']) then
      begin
        Precisa := True;
        Break;
      end;
  if not Precisa then
  begin
    Result := ANome;
    Exit;
  end;
  Result := '"' + StringReplace(ANome, '"', '""', [rfReplaceAll]) + '"';
end;

// Formata um inteiro com escala negativa (NUMERIC/DECIMAL):
// ARaw = 12345, AScale = -2 -> '123.45'; ARaw = -5, AScale = -2 -> '-0.05'.
function ValorEscalado(const ARaw: Int64; AScale: Smallint): string;
var
  P, V, F: Int64;
  S: string;
  I: Integer;
  Neg: Boolean;
begin
  if AScale >= 0 then
  begin
    Result := IntToStr(ARaw);
    Exit;
  end;
  P := 1;
  for I := 1 to -AScale do
    P := P * 10;
  V := ARaw div P;
  F := ARaw mod P;
  if F < 0 then
    F := -F;
  S := IntToStr(F);
  while Length(S) < -AScale do
    S := '0' + S;
  Neg := ARaw < 0;
  if V = 0 then
  begin
    Result := '0.' + S;
    if Neg then
      Result := '-' + Result;
  end
  else
    Result := IntToStr(V) + '.' + S;
end;

// ISC_DATE (dias desde 17-Nov-1858) -> 'aaaa-mm-dd'.
function TextoData(ADias: Longint): string;
begin
  Result := FormatDateTime('yyyy-mm-dd', ADias - K_DIAS_EPOCA);
end;

// ISC_TIME (1/10000 s desde meia-noite) -> 'hh:nn:ss.zzzz'.
function TextoTempo(ATicks: Longint): string;
var
  Seg, Frac, Hh, Mm, Ss: Longint;
begin
  if ATicks < 0 then
    ATicks := 0;
  Seg := ATicks div 10000;
  Frac := ATicks mod 10000;
  Hh := Seg div 3600;
  Mm := (Seg mod 3600) div 60;
  Ss := Seg mod 60;
  Result := Format('%2.2d:%2.2d:%2.2d.%4.4d', [Hh, Mm, Ss, Frac]);
end;

// TIMESTAMP = ISC_DATE + ISC_TIME (8 bytes no sqldata).
function TextoTimestamp(const AData: Pointer): string;
var
  Dias, Ticks: Longint;
begin
  Dias := PLongint(AData)^;
  Ticks := PLongint(PAnsiChar(AData) + 4)^;
  Result := TextoData(Dias) + ' ' + TextoTempo(Ticks);
end;

// Nome da coluna conforme o XSQLVAR (sqlname, sem padding).
function NomeColuna(const V: PSQLVAR): string;
var
  L: Integer;
  S: AnsiString;
begin
  L := V.sqlname_length;
  if L > 32 then
    L := 32;
  S := BytesAnsi(@V.sqlname[0], L);
  Result := S;
end;

// Tipo textual da coluna (descricao para o catalogo).
function TipoColuna(const V: PSQLVAR): string;
var
  Base, Esc: Integer;
begin
  Base := V.sqltype and $FFFE;
  Esc := V.sqlscale;
  case Base of
    SQL_VARYING:   Result := 'VARCHAR(' + IntToStr(V.sqllen) + ')';
    SQL_TEXT:      Result := 'CHAR(' + IntToStr(V.sqllen) + ')';
    SQL_SHORT:     Result := 'SMALLINT';
    SQL_LONG:      Result := 'INTEGER';
    SQL_INT64:     Result := 'BIGINT';
    SQL_FLOAT:     Result := 'FLOAT';
    SQL_DOUBLE:    Result := 'DOUBLE PRECISION';
    SQL_TIMESTAMP: Result := 'TIMESTAMP';
    SQL_TYPE_DATE: Result := 'DATE';
    SQL_TYPE_TIME: Result := 'TIME';
    SQL_BLOB:
      begin
        if V.sqlsubtype = 1 then
          Result := 'BLOB SUB_TYPE TEXT'
        else
          Result := 'BLOB SUB_TYPE ' + IntToStr(V.sqlsubtype);
      end;
    SQL_ARRAY:     Result := 'ARRAY (nao suportado pelo driver)';
    SQL_QUAD:      Result := 'QUAD (nao suportado pelo driver)';
  else
    Result := 'TIPO_' + IntToStr(Base);
  end;
  if (Esc < 0) and ((Base = SQL_SHORT) or (Base = SQL_LONG) or
                    (Base = SQL_INT64)) then
    Result := Result + ' NUMERIC/DECIMAL (escala ' + IntToStr(Esc) + ')';
end;

// ==================================================================
// TFBStatement
// ==================================================================
constructor TFBStatement.Create(ADrv: TFBDatabase);
begin
  inherited Create;
  FDrv := ADrv;
  FStmt := 0;
  FSqlda := nil;
  FNCols := 0;
end;

destructor TFBStatement.Destroy;
begin
  Liberar;
  inherited Destroy;
end;

function TFBStatement.GetColuna(AIndex: Integer): PSQLVAR;
begin
  Result := nil;
  if (AIndex >= 0) and (AIndex < FNCols) and (FSqlda <> nil) then
    Result := @FSqlda.sqlvar[AIndex];
end;

procedure TFBStatement.Liberar;
var
  I: Integer;
  St: TStatusVector;
begin
  if FStmt <> 0 then
  begin
    if (FDrv <> nil) and (FDrv.FDll <> 0) then
    begin
      FillChar(St, SizeOf(St), 0);
      FDrv.FFreeStmt(St, FStmt, DSQL_DROP);
    end;
    FStmt := 0;
  end;
  for I := 0 to Length(FBufs) - 1 do
  begin
    if FBufs[I] <> nil then
      FreeMem(FBufs[I]);
    if FInds[I] <> nil then
      FreeMem(FInds[I]);
  end;
  SetLength(FBufs, 0);
  SetLength(FInds, 0);
  if FSqlda <> nil then
  begin
    FreeMem(FSqlda);
    FSqlda := nil;
  end;
  FNCols := 0;
end;

function TFBStatement.Preparar(const ASql: string; var AMsg: string): Boolean;
var
  rc: TISCStatus;
  St: TStatusVector;
  Larg: Integer;
  I: Integer;
  V: PSQLVAR;
  Need: Integer;
begin
  Result := False;
  AMsg := '';
  Liberar;
  if (FDrv = nil) or FDrv.FFechado then
  begin
    AMsg := 'driver fechado';
    Exit;
  end;
  FillChar(St, SizeOf(St), 0);
  rc := FDrv.FAllocate(St, FDrv.FDb, FStmt);
  if (rc <> 0) or (St[1] <> 0) then
  begin
    AMsg := FDrv.MsgStatus(St, 'isc_dsql_allocate_statement');
    Exit;
  end;
  FillChar(St, SizeOf(St), 0);
  rc := FDrv.FPrepare(St, FDrv.FTr, FStmt, Length(ASql), PAnsiChar(ASql),
                      K_DIALETO, nil);
  if (rc <> 0) or (St[1] <> 0) then
  begin
    AMsg := FDrv.MsgStatus(St, 'isc_dsql_prepare');
    Exit;
  end;
  // Describe em 2 fases (realoca quando ha mais colunas que o previsto).
  GetMem(FSqlda, XSQLDA_LENGTH(K_SQLN_INICIAL));
  FillChar(FSqlda^, XSQLDA_LENGTH(K_SQLN_INICIAL), 0);
  FSqlda.version := SQLDA_VERSION;
  FSqlda.sqln := K_SQLN_INICIAL;
  FillChar(St, SizeOf(St), 0);
  rc := FDrv.FDescribe(St, FStmt, SQLDA_VERSION, FSqlda);
  if (rc <> 0) or (St[1] <> 0) then
  begin
    AMsg := FDrv.MsgStatus(St, 'isc_dsql_describe');
    Exit;
  end;
  if FSqlda.sqld > FSqlda.sqln then
  begin
    Larg := FSqlda.sqld;
    FreeMem(FSqlda);
    FSqlda := nil;
    GetMem(FSqlda, XSQLDA_LENGTH(Larg));
    FillChar(FSqlda^, XSQLDA_LENGTH(Larg), 0);
    FSqlda.version := SQLDA_VERSION;
    FSqlda.sqln := Larg;
    FillChar(St, SizeOf(St), 0);
    rc := FDrv.FDescribe(St, FStmt, SQLDA_VERSION, FSqlda);
    if (rc <> 0) or (St[1] <> 0) then
    begin
      AMsg := FDrv.MsgStatus(St, 'isc_dsql_describe');
      Exit;
    end;
  end;
  FNCols := FSqlda.sqld;
  if FNCols < 0 then
    FNCols := 0;
  // Aloca os buffers de dados e de indicador de NULL por coluna.
  SetLength(FBufs, FNCols);
  SetLength(FInds, FNCols);
  for I := 0 to FNCols - 1 do
  begin
    V := @FSqlda.sqlvar[I];
    Need := V.sqllen;
    if (V.sqltype and $FFFE) = SQL_VARYING then
      Inc(Need, 2);            // prefixo de 2 bytes de length
    if Need < 8 then
      Need := 8;               // blob_id / int64 / timestamp
    GetMem(FBufs[I], Need);
    FillChar(FBufs[I]^, Need, 0);
    GetMem(FInds[I], SizeOf(Smallint));
    FillChar(FInds[I]^, SizeOf(Smallint), 0);
    V.sqldata := FBufs[I];
    V.sqlind := FInds[I];
  end;
  Result := True;
end;

function TFBStatement.Executar(var AMsg: string): Boolean;
var
  rc: TISCStatus;
  St: TStatusVector;
begin
  Result := False;
  AMsg := '';
  if (FDrv = nil) or (FStmt = 0) then
  begin
    AMsg := 'statement nao preparado';
    Exit;
  end;
  FillChar(St, SizeOf(St), 0);
  rc := FDrv.FExecute(St, FDrv.FTr, FStmt, SQLDA_VERSION, nil);
  if (rc <> 0) or (St[1] <> 0) then
  begin
    AMsg := FDrv.MsgStatus(St, 'isc_dsql_execute');
    Exit;
  end;
  Result := True;
end;

// Le um BLOB inteiro por segmentos (segmento maximo ~32 KB; buffer de
// 16 KB faz isc_get_segment devolver isc_segment=100 quando o segmento
// e maior, e a chamada seguinte continua o MESMO segmento).
function TFBStatement.LerBlob(const ABlobId: Pointer; var Bytes: TBytesCSV;
  var AMsg: string): Boolean;
const
  BUF_TAM = 16384;
var
  St: TStatusVector;
  Quad: TISCQuad;
  BlobH: Longint;
  rc: TISCStatus;
  Buf: array[0..BUF_TAM - 1] of Byte;
  SegLen: Word;
  Terminou, Erro: Boolean;
  Old: Integer;
begin
  Result := False;
  AMsg := '';
  BlobH := 0;
  Move(ABlobId^, Quad, SizeOf(Quad));
  FillChar(St, SizeOf(St), 0);
  rc := FDrv.FOpenBlob2(St, FDrv.FDb, FDrv.FTr, BlobH, @Quad, 0, nil);
  if (rc <> 0) or (St[1] <> 0) then
  begin
    AMsg := FDrv.MsgStatus(St, 'isc_open_blob2');
    Exit;
  end;
  SetLength(Bytes, 0);
  Terminou := False;
  Erro := False;
  repeat
    FillChar(St, SizeOf(St), 0);
    rc := FDrv.FGetSegment(St, BlobH, SegLen, SizeOf(Buf), @Buf);
    if (rc = K_ISC_SEGSTR_EOF) or (St[1] = K_ISC_SEGSTR_EOF) or
       (rc = 101) or (St[1] = 101) then
      Terminou := True                              // fim limpo do blob
    else if (rc = 0) or (St[1] = K_ISC_SEGMENT) then
    begin
      // segmento (ou pedaco de segmento) com SegLen bytes
      if SegLen > 0 then
      begin
        Old := Length(Bytes);
        SetLength(Bytes, Old + SegLen);
        Move(Buf, Bytes[Old], SegLen);
      end;
    end
    else
    begin
      Erro := True;
      AMsg := FDrv.MsgStatus(St, 'isc_get_segment');
    end;
  until Terminou or Erro;
  FillChar(St, SizeOf(St), 0);
  FDrv.FCloseBlob(St, BlobH);
  Result := not Erro;
end;

function TFBStatement.LerLinha(var Valores: TCamposLinha;
  var Msg: string): Boolean;
var
  rc: TISCStatus;
  St: TStatusVector;
  I: Integer;
  V: PSQLVAR;
  Cel: TValorCelula;
  Buf: AnsiString;
  Len: Integer;
  Base: Integer;
begin
  Result := False;
  Msg := '';
  if (FDrv = nil) or (FStmt = 0) or (FSqlda = nil) then
  begin
    Msg := 'statement nao preparado';
    Exit;
  end;
  FillChar(St, SizeOf(St), 0);
  rc := FDrv.FFetch(St, FStmt, SQLDA_VERSION, FSqlda);
  if rc = 100 then
    Exit;                                  // fim do resultado, Msg vazio
  if rc <> 0 then
  begin
    Msg := FDrv.MsgStatus(St, 'isc_dsql_fetch');
    Exit;
  end;
  SetLength(Valores, FNCols);
  for I := 0 to FNCols - 1 do
  begin
    V := @FSqlda.sqlvar[I];
    Cel.Nulo := False;
    Cel.EhBlob := False;
    Cel.Texto := '';
    Cel.Bytes := nil;
    if (V.sqlind <> nil) and (V.sqlind^ < 0) then
      Cel.Nulo := True                       // SQL NULL
    else
    begin
      Base := V.sqltype and $FFFE;
      case Base of
        SQL_VARYING:
          begin
            Len := PSmallint(V.sqldata)^;    // length explicita (2 bytes)
            if Len < 0 then
              Len := 0;
            if Len > V.sqllen then
              Len := V.sqllen;
            Buf := BytesAnsi(PAnsiChar(V.sqldata) + 2, Len);
            Cel.Texto := Buf;
          end;
        SQL_TEXT:
          begin
            Buf := BytesAnsi(V.sqldata, V.sqllen);
            while (Length(Buf) > 0) and (Buf[Length(Buf)] = ' ') do
              SetLength(Buf, Length(Buf) - 1);   // sem espacos a direita
            Cel.Texto := Buf;
          end;
        SQL_SHORT:
          Cel.Texto := ValorEscalado(PSmallint(V.sqldata)^, V.sqlscale);
        SQL_LONG:
          Cel.Texto := ValorEscalado(PLongint(V.sqldata)^, V.sqlscale);
        SQL_INT64:
          Cel.Texto := ValorEscalado(PInt64(V.sqldata)^, V.sqlscale);
        SQL_FLOAT:
          Cel.Texto := FloatToStr(PSingle(V.sqldata)^);
        SQL_DOUBLE:
          Cel.Texto := FloatToStr(PDouble(V.sqldata)^);
        SQL_TIMESTAMP:
          Cel.Texto := TextoTimestamp(V.sqldata);
        SQL_TYPE_DATE:
          Cel.Texto := TextoData(PLongint(V.sqldata)^);
        SQL_TYPE_TIME:
          Cel.Texto := TextoTempo(PLongint(V.sqldata)^);
        SQL_BLOB:
          begin
            Cel.EhBlob := True;
            if not LerBlob(V.sqldata, Cel.Bytes, Msg) then
            begin
              Result := False;               // erro de leitura do blob
              Exit;
            end;
          end;
        SQL_ARRAY, SQL_QUAD:
          begin
            // tipos nao suportados pelo driver: celula tratada como Nulo
            Cel.Nulo := True;
          end;
      else
        begin
          // tipo desconhecido: bytes crus como texto (defensivo)
          Buf := BytesAnsi(V.sqldata, V.sqllen);
          Cel.Texto := Buf;
        end;
      end;
    end;
    Valores[I] := Cel;
  end;
  Result := True;
end;

// ==================================================================
// TFBCursorLeitor
// ==================================================================
constructor TFBCursorLeitor.Create(ADrv: TFBDatabase; AStmt: TFBStatement);
begin
  inherited Create;
  FDrv := ADrv;
  FStmt := AStmt;
  FFechado := False;
end;

destructor TFBCursorLeitor.Destroy;
begin
  if FStmt <> nil then
  begin
    if (FDrv <> nil) and (not FDrv.FFechado) then
      FDrv.RemoverLeitor(Self);
    FStmt.Free;
    FStmt := nil;
  end;
  inherited Destroy;
end;

procedure TFBCursorLeitor.EncerrarPeloDriver;
begin
  if FStmt <> nil then
  begin
    FStmt.Free;
    FStmt := nil;
  end;
  FDrv := nil;
  FFechado := True;
end;

function TFBCursorLeitor.ProximaLinha(var Valores: TCamposLinha;
  var Msg: string): Boolean;
begin
  Msg := '';
  if FFechado or (FStmt = nil) then
  begin
    Msg := 'cursor encerrado';
    Result := False;
    Exit;
  end;
  Result := FStmt.LerLinha(Valores, Msg);
end;

// ==================================================================
// TFBDatabase
// ==================================================================
function TFBDatabase.CarregarFuncoes(var AMsg: string): Boolean;
begin
  Result := False;
  @FAttach := GetProcAddress(FDll, 'isc_attach_database');
  if not Assigned(FAttach) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_attach_database';
    Exit;
  end;
  @FStart := GetProcAddress(FDll, 'isc_start_transaction');
  if not Assigned(FStart) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_start_transaction';
    Exit;
  end;
  @FCommit := GetProcAddress(FDll, 'isc_commit_transaction');
  if not Assigned(FCommit) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_commit_transaction';
    Exit;
  end;
  @FDetach := GetProcAddress(FDll, 'isc_detach_database');
  if not Assigned(FDetach) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_detach_database';
    Exit;
  end;
  @FAllocate := GetProcAddress(FDll, 'isc_dsql_allocate_statement');
  if not Assigned(FAllocate) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_dsql_allocate_statement';
    Exit;
  end;
  @FPrepare := GetProcAddress(FDll, 'isc_dsql_prepare');
  if not Assigned(FPrepare) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_dsql_prepare';
    Exit;
  end;
  @FDescribe := GetProcAddress(FDll, 'isc_dsql_describe');
  if not Assigned(FDescribe) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_dsql_describe';
    Exit;
  end;
  @FExecute := GetProcAddress(FDll, 'isc_dsql_execute');
  if not Assigned(FExecute) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_dsql_execute';
    Exit;
  end;
  @FFetch := GetProcAddress(FDll, 'isc_dsql_fetch');
  if not Assigned(FFetch) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_dsql_fetch';
    Exit;
  end;
  @FFreeStmt := GetProcAddress(FDll, 'isc_dsql_free_statement');
  if not Assigned(FFreeStmt) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_dsql_free_statement';
    Exit;
  end;
  @FInterprete := GetProcAddress(FDll, 'isc_interprete');
  if not Assigned(FInterprete) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_interprete';
    Exit;
  end;
  @FOpenBlob2 := GetProcAddress(FDll, 'isc_open_blob2');
  if not Assigned(FOpenBlob2) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_open_blob2';
    Exit;
  end;
  @FGetSegment := GetProcAddress(FDll, 'isc_get_segment');
  if not Assigned(FGetSegment) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_get_segment';
    Exit;
  end;
  @FCloseBlob := GetProcAddress(FDll, 'isc_close_blob');
  if not Assigned(FCloseBlob) then
  begin
    AMsg := 'fbclient: funcao ausente na dll: isc_close_blob';
    Exit;
  end;
  Result := True;
end;

// Traduz o status vector em texto via isc_interprete (firebird.msg).
function TFBDatabase.InterpreteTexto(const St: TStatusVector): string;
var
  Local: PAnsiChar;
  Buf: array[0..1023] of AnsiChar;
  Msg: string;
  It: Integer;
  Len: Integer;
begin
  Result := '';
  Local := PAnsiChar(@St[0]);
  It := 0;
  while It < 20 do
  begin
    FillChar(Buf, SizeOf(Buf), 0);
    Len := FInterprete(@Buf[0], Local);
    if Len <= 0 then
      Break;
    Msg := Buf;            // array AnsiChar -> string (ate o nulo)
    if Msg <> '' then
    begin
      if Result <> '' then
        Result := Result + ' | ';
      Result := Result + Trim(Msg);
    end;
    Inc(It);
  end;
  if Result = '' then
    Result := 'erro de status ' + IntToStr(St[1]);
end;

function TFBDatabase.MsgStatus(const St: TStatusVector;
  const AContexto: string): string;
begin
  Result := 'fbclient: ' + AContexto + ': ' + InterpreteTexto(St);
end;

constructor TFBDatabase.Create(const ADllPath, ABanco: string;
  var AMsg: string);
var
  Caminho: string;
  NomeBanco: AnsiString;
  Dpb: array[0..31] of Byte;
  DLen: Word;
  St: TStatusVector;
  rc: TISCStatus;
begin
  inherited Create;
  FLeitores := TList.Create;
  FDecSep := DecimalSeparator;
  DecimalSeparator := '.';        // numeros com ponto, independente de locale
  FErroInit := '';
  FFechado := True;               // so fica aberto se tudo abaixo passar
  AMsg := '';

  Caminho := Trim(ADllPath);
  if Caminho = '' then
    Caminho := 'fbclient.dll'
  else if ExtractFileExt(Caminho) = '' then
    Caminho := IncludeTrailingPathDelimiter(Caminho) + 'fbclient.dll';
  FDllPath := Caminho;
  if not FileExists(Caminho) then
  begin
    FErroInit := 'fbclient nao encontrado em ' + Caminho;
    AMsg := FErroInit;
    Exit;
  end;

  FDll := LoadLibrary(PChar(Caminho));
  if FDll = 0 then
  begin
    FErroInit := 'falha ao carregar ' + Caminho + ' (LoadLibrary)';
    AMsg := FErroInit;
    Exit;
  end;

  // Ajuda o fbclient embarcado a achar firebird.conf/firebird.msg e
  // intl ao lado da dll (somente quando FIREBIRD ja nao estiver definido).
  if GetEnvironmentVariable('FIREBIRD') = '' then
    SetEnvironmentVariable('FIREBIRD',
      PChar(ExtractFilePath(ExpandFileName(Caminho))));

  if not CarregarFuncoes(FErroInit) then
  begin
    AMsg := FErroInit;
    FreeLibrary(FDll);
    FDll := 0;
    Exit;
  end;

  // DPB: versao 1 + usuario 'sysdba' + senha 'masterkey' (o motor
  // embarcado ignora, mas o cliente espera os campos quando presentes).
  NomeBanco := ExpandFileName(ABanco);
  FillChar(Dpb, SizeOf(Dpb), 0);
  DLen := 0;
  Dpb[DLen] := K_DPB_VERSION1;
  Inc(DLen);
  Dpb[DLen] := K_DPB_USER_NAME;
  Inc(DLen);
  Dpb[DLen] := 6;                                  // 'sysdba'
  Inc(DLen);
  Move(PAnsiChar('sysdba')^, Dpb[DLen], 6);
  Inc(DLen, 6);
  Dpb[DLen] := K_DPB_PASSWORD;
  Inc(DLen);
  Dpb[DLen] := 9;                                  // 'masterkey'
  Inc(DLen);
  Move(PAnsiChar('masterkey')^, Dpb[DLen], 9);
  Inc(DLen, 9);

  FillChar(St, SizeOf(St), 0);
  rc := FAttach(St, 0, PAnsiChar(NomeBanco), FDb, DLen, @Dpb[0]);
  if (rc <> 0) or (St[1] <> 0) then
  begin
    FErroInit := MsgStatus(St, 'isc_attach_database (' + ABanco + ')');
    AMsg := FErroInit;
    Exit;
  end;
  FillChar(St, SizeOf(St), 0);
  rc := FStart(St, FTr, 1, FDb, 0, nil);
  if (rc <> 0) or (St[1] <> 0) then
  begin
    FErroInit := MsgStatus(St, 'isc_start_transaction');
    AMsg := FErroInit;
    Exit;
  end;
  FFechado := False;
end;

destructor TFBDatabase.Destroy;
var
  I: Integer;
  St: TStatusVector;
begin
  FFechado := True;
  for I := 0 to FLeitores.Count - 1 do
    EncerrarCursor(FLeitores[I]);
  FLeitores.Free;
  FLeitores := nil;
  if FTr <> 0 then
  begin
    FillChar(St, SizeOf(St), 0);
    FCommit(St, FTr);
    FTr := 0;
  end;
  if FDb <> 0 then
  begin
    FillChar(St, SizeOf(St), 0);
    FDetach(St, FDb);
    FDb := 0;
  end;
  if FDll <> 0 then
  begin
    FreeLibrary(FDll);
    FDll := 0;
  end;
  DecimalSeparator := FDecSep;
  inherited Destroy;
end;

function TFBDatabase.NomeDriver: string;
begin
  Result := 'fbclient.dll (Firebird 2.5 embarcado) - ' + FDllPath;
end;

procedure TFBDatabase.RemoverLeitor(ACursor: TObject);
begin
  if FLeitores <> nil then
    FLeitores.Remove(ACursor);
end;

procedure TFBDatabase.EncerrarCursor(ACursor: TObject);
begin
  if ACursor <> nil then
    TFBCursorLeitor(ACursor).EncerrarPeloDriver;
end;

function TFBDatabase.ListarTabelas(var Tabelas: TStringList;
  var Msg: string): Boolean;
var
  Stmt: TFBStatement;
  Valores: TCamposLinha;
begin
  Result := False;
  Msg := '';
  if FFechado then
  begin
    Msg := 'driver fechado';
    Exit;
  end;
  if Tabelas = nil then
  begin
    Msg := 'lista de tabelas nula';
    Exit;
  end;
  Tabelas.Clear;
  Stmt := TFBStatement.Create(Self);
  try
    if not Stmt.Preparar('SELECT RDB$RELATION_NAME FROM RDB$RELATIONS ' +
      'WHERE (RDB$SYSTEM_FLAG = 0) AND (RDB$VIEW_BLR IS NULL) ' +
      'ORDER BY 1', Msg) then
      Exit;
    if not Stmt.Executar(Msg) then
      Exit;
    while Stmt.LerLinha(Valores, Msg) do
    begin
      if Length(Valores) >= 1 then
        Tabelas.Add(Trim(Valores[0].Texto));
    end;
    if Msg <> '' then
      Exit;                              // erro no meio da leitura
    Result := True;
  finally
    Stmt.Free;
  end;
end;

function TFBDatabase.ListarColunas(const ATabela: string;
  var Colunas: TListaColunas; var Msg: string): Boolean;
var
  Stmt: TFBStatement;
  I: Integer;
  V: PSQLVAR;
  C: TColunaCatalogo;
begin
  Result := False;
  Msg := '';
  SetLength(Colunas, 0);
  if FFechado then
  begin
    Msg := 'driver fechado';
    Exit;
  end;
  Stmt := TFBStatement.Create(Self);
  try
    if not Stmt.Preparar('SELECT * FROM ' + NomeTabelaSQL(ATabela), Msg) then
      Exit;
    SetLength(Colunas, Stmt.NCols);
    for I := 0 to Stmt.NCols - 1 do
    begin
      V := Stmt.Coluna[I];
      C.Nome := NomeColuna(V);
      C.Tipo := TipoColuna(V);
      C.Tamanho := V.sqllen;
      C.Nula := (V.sqltype and 1) <> 0;
      C.EhBlob := (V.sqltype and $FFFE) = SQL_BLOB;
      Colunas[I] := C;
    end;
    Result := True;
  finally
    Stmt.Free;
  end;
end;

function TFBDatabase.AbrirLeitura(const ATabela: string;
  out Leitor: ILeitorLinhas; var Msg: string): Boolean;
var
  Stmt: TFBStatement;
  Cur: TFBCursorLeitor;
begin
  Result := False;
  Leitor := nil;
  Msg := '';
  if FFechado then
  begin
    Msg := 'driver fechado';
    Exit;
  end;
  Stmt := TFBStatement.Create(Self);
  try
    if not Stmt.Preparar('SELECT * FROM ' + NomeTabelaSQL(ATabela), Msg) then
      Exit;
    if not Stmt.Executar(Msg) then
      Exit;
    Cur := TFBCursorLeitor.Create(Self, Stmt);
    Stmt := nil;                       // posse transferida ao cursor
    FLeitores.Add(Cur);
    Leitor := Cur;
    Result := True;
  finally
    Stmt.Free;                         // so libera se nao transferido
  end;
end;

function TFBDatabase.ContarRegistros(const ATabela: string;
  out Total: Int64; var Msg: string): Boolean;
var
  Stmt: TFBStatement;
  Valores: TCamposLinha;
begin
  Result := False;
  Total := 0;
  Msg := '';
  if FFechado then
  begin
    Msg := 'driver fechado';
    Exit;
  end;
  Stmt := TFBStatement.Create(Self);
  try
    if not Stmt.Preparar('SELECT COUNT(*) FROM ' + NomeTabelaSQL(ATabela),
                         Msg) then
      Exit;
    if not Stmt.Executar(Msg) then
      Exit;
    if not Stmt.LerLinha(Valores, Msg) then
      Exit;
    if Length(Valores) < 1 then
    begin
      Msg := 'COUNT(*) sem colunas no resultado';
      Exit;
    end;
    Total := StrToInt64(Valores[0].Texto);
    Result := True;
  finally
    Stmt.Free;
  end;
end;

// ==================================================================
// Fabrica publica
// ==================================================================
function CriarDriverFBClient(const ADllPath, ABanco: string;
  var AMsg: string): IDriverFBConsulta;
var
  D: TFBDatabase;
begin
  Result := nil;
  AMsg := '';
  D := TFBDatabase.Create(ADllPath, ABanco, AMsg);
  if D.Fechado then
  begin
    if AMsg = '' then
      AMsg := D.ErroInit;
    D.Free;
    Result := nil;
    Exit;
  end;
  Result := D;
end;

end.
