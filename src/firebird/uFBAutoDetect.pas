{
  uFBAutoDetect.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F1-T3 (PLANO.md 4.1.3/6.7): auto-deteccao de instalacoes
  Firebird/InterBase. NAO executa nenhum binario nesta fase (nao ha
  bins reais na maquina de desenvolvimento; validacao F7 roda
  gbak -z/-? para confirmar e enriquecer o catalogo).

  Fontes de candidatos, em ordem de prioridade:
    1) AExtras          - caminhos fornecidos pela chamada (testes/UI)
    2) Registro HKLM    - Firebird Project\Firebird, Borland/
                          Embarcadero\InterBase (vistas 32 e 64 bits,
                          inclusive WOW6432Node implicito) e servicos
                          com ImagePath (fbguard/fbserver/interbase)
    3) Pastas padrao    - %ProgramFiles%\(x86)\Firebird,
                          ...\Embarcadero\InterBase, ...\Borland\InterBase
    4) PATH do ambiente

  Validacao do candidato: a pasta (ou sua subpasta 'bin') precisa ter
  pelo menos um de gbak.exe/gfix.exe/isql.exe; versao/familia vem do
  recurso VS_VERSION_INFO do executavel (uFBVersionInfo) e, quando
  indisponivel, de heuristica do nome do caminho.

  Regras do repositorio: Delphi 7 puro, comentarios pt-BR ASCII,
  sem Forms, sem execucao de processos, leituras defensivas.
  ------------------------------------------------------------------
}
unit uFBAutoDetect;

{$H+}

interface

uses
  SysUtils, Classes, Windows, uFBVersionInfo, uFBSwitchCatalog;

type
  // Um conjunto de utilitarios detectado em uma mesma pasta de bin.
  TBinSet = record
    CaminhoBin: string;     // pasta com terminador (ex.: C:\FB\bin\)
    Versao: TVersion;       // do gbak (ou gfix/isql se gbak sem recurso)
    Familia: TBFamilia;     // Versao.Familia ou heuristica do caminho
    TemGbak: Boolean;
    TemGfix: Boolean;
    TemIsql: Boolean;
    SuportaFixFss: Boolean; // regra do catalogo (so gbak 1.5-2.5/IB6)
    Origem: string;         // 'extras'|'registro'|'pasta padrao'|'PATH'
  end;

  TBinSetArray = array of TBinSet;

// Detecta instalacoes e devolve a lista validada (ordem: extras,
// registro, pastas padrao, PATH). AExtras pode ser nil. Retorna o
// numero de conjuntos validados (tamanho de ALista).
function AutoDetectar(AExtras: TStrings; var ALista: TBinSetArray): Integer;

// Valida uma pasta candidata (direta ou com subpasta 'bin') e preenche
// TBinSet. Exportada para testes (injeccao de diretorios fake).
function ExaminarCandidato(const ADir: string; const AOrigem: string;
  var B: TBinSet): Boolean;

// Nome legivel do binario para relatorios/logs.
function BinParaTexto(ABin: TBinKind; const AB: TBinSet): string;

implementation

type
  TCandidato = record
    Dir: string;
    Origem: string;
    Familia: TBFamilia;   // dica da fonte; pode ser refinada na validacao
  end;

  TCandidatoArray = array of TCandidato;

const
  // Nomes de valores que costumam carregar a pasta de instalacao/bin.
  CNomesValoresDir: array[0..5] of string = (
    'RootDirectory', 'InstallRoot', 'RootDir', 'ServerRootDirectory',
    'DefaultInstance', 'Location');

  // Chaves raiz do registro (familia por chave).
  CChavesRegistro: array[0..4] of string = (
    'Software\Firebird Project\Firebird',
    'Software\Borland\InterBase\CurrentVersion',
    'Software\Borland\InterBase',
    'Software\Embarcadero\InterBase\CurrentVersion',
    'Software\Embarcadero\InterBase');

  CNomeGbak = 'gbak.exe';
  CNomeGfix = 'gfix.exe';
  CNomeIsql = 'isql.exe';

// ------------------------------------------------------------------
// Bindings de advapi32/kernel32 (nomes unicos - padrao Api* do repo).
// ------------------------------------------------------------------
type
  THReg = THandle;

const
  C_HKLM = $80000002;         // HKEY_LOCAL_MACHINE
  C_KEY_READ = $20019;        // STANDARD_RIGHTS_READ or QUERY_VALUE
                              //   or ENUMERATE_SUB_KEYS
  C_WOW64_64KEY = $00000100;
  C_WOW64_32KEY = $00000200;
  C_ERR_NO_MORE = 259;        // ERROR_NO_MORE_ITEMS
  C_REG_SZ = 1;
  C_REG_EXPAND_SZ = 2;

function ApiRegOpenKeyExW(hKey: THReg; lpSubKey: PWideChar;
  ulOptions, samDesired: DWORD; var phkResult: THReg): Longint; stdcall;
  external 'advapi32.dll' name 'RegOpenKeyExW';

function ApiRegCloseKey(hKey: THReg): Longint; stdcall;
  external 'advapi32.dll' name 'RegCloseKey';

function ApiRegEnumKeyW(hKey: THReg; dwIndex: DWORD;
  lpName: PWideChar; cchName: DWORD): Longint; stdcall;
  external 'advapi32.dll' name 'RegEnumKeyW';

function ApiRegEnumValueW(hKey: THReg; dwIndex: DWORD;
  lpValueName: PWideChar; var lpcchValueName: DWORD;
  lpReserved: Pointer; var lpType: DWORD;
  lpData: PByte; var lpcbData: DWORD): Longint; stdcall;
  external 'advapi32.dll' name 'RegEnumValueW';

function ApiRegQueryValueExW(hKey: THReg; lpValueName: PWideChar;
  lpReserved: Pointer; var lpType: DWORD;
  lpData: PByte; var lpcbData: DWORD): Longint; stdcall;
  external 'advapi32.dll' name 'RegQueryValueExW';

function ApiExpandEnvironmentStringsW(lpSrc: PWideChar;
  lpDst: PWideChar; nSize: DWORD): DWORD; stdcall;
  external 'kernel32.dll' name 'ExpandEnvironmentStringsW';

function ApiGetEnvironmentVariableW(lpName: PWideChar;
  lpBuffer: PWideChar; nSize: DWORD): DWORD; stdcall;
  external 'kernel32.dll' name 'GetEnvironmentVariableW';

// ------------------------------------------------------------------
// Helpers de lista de candidatos
// ------------------------------------------------------------------
procedure AdicionarCandidato(var Arr: TCandidatoArray; const ADir,
  AOrigem: string; AFamilia: TBFamilia);
var
  N: Integer;
  D: string;
begin
  D := Trim(ADir);
  if D = '' then
    Exit;
  D := ExcludeTrailingPathDelimiter(D);
  if D = '' then
    Exit;
  N := Length(Arr);
  SetLength(Arr, N + 1);
  Arr[N].Dir := D;
  Arr[N].Origem := AOrigem;
  Arr[N].Familia := AFamilia;
end;

// Diretorio ja presente na lista? (evita repeticao de candidatos).
function JaExiste(const Arr: TCandidatoArray; const ADir: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to Length(Arr) - 1 do
    if CompareText(ExcludeTrailingPathDelimiter(Arr[I].Dir),
                   ExcludeTrailingPathDelimiter(ADir)) = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

// ------------------------------------------------------------------
// Leitura segura de um valor REG_SZ/EXPAND_SZ com cara de diretorio.
// ------------------------------------------------------------------
function LerValorDir(hKey: THReg; const ANomeValor: WideString;
  var ADir: string): Boolean;
var
  Tipo, Tam: DWORD;
  Buf: array[0..2047] of Byte;
  R: Longint;
  W: WideString;
begin
  Result := False;
  Tam := SizeOf(Buf);
  R := ApiRegQueryValueExW(hKey, PWideChar(ANomeValor), nil, Tipo,
                           @Buf[0], Tam);
  if (R <> 0) or (Tam < 2) then
    Exit;
  if (Tipo <> C_REG_SZ) and (Tipo <> C_REG_EXPAND_SZ) then
    Exit;
  W := PWideChar(@Buf[0]);
  if W = '' then
    Exit;
  ADir := Trim(string(W));
  if ADir = '' then
    Exit;
  // expande variaveis de ambiente quando presente
  if Pos('%', ADir) > 0 then
  begin
    SetLength(W, 4096);
    if ApiExpandEnvironmentStringsW(PWideChar(WideString(ADir)),
                                    PWideChar(W), 4096) > 0 then
      ADir := Trim(string(PWideChar(W)));
  end;
  if ADir <> '' then
    Result := True;
end;

// Converte buffer WIDE COM LIMITE para string. A enumeracao do registro
// nao garante terminador dentro do buffer em toda condicao; nunca ler
// sem teto (evita AV em D7/FPC com lixo de stack).
function WParaTexto(const ABuf: PWideChar; AMax: Integer): string;
var
  N: Integer;
  W: WideString;
begin
  N := 0;
  while (N < AMax) and (ABuf[N] <> #0) do
    Inc(N);
  SetLength(W, N);
  if N > 0 then
    Move(ABuf[0], W[1], N * SizeOf(WideChar));
  Result := string(W);
end;

// Le todos os valores com "cara de diretorio" de uma chave.
procedure ColetarValoresDaChave(hKey: THReg; const AOrigem: string;
  AFamilia: TBFamilia; var Arr: TCandidatoArray);
var
  I, J: DWORD;
  R: Longint;
  NomeVal: array[0..255] of WideChar;
  NomeLen, DataLen: DWORD;
  Tipo: DWORD;
  Dir: string;
  NomeStr: string;
begin
  // varre os valores (nome x tipo) e confere os nomes conhecidos
  I := 0;
  while True do
  begin
    NomeLen := 256;
    DataLen := 0;
    Tipo := 0;
    FillChar(NomeVal, SizeOf(NomeVal), 0);
    R := ApiRegEnumValueW(hKey, I, @NomeVal[0], NomeLen, nil, Tipo,
                          nil, DataLen);
    if R <> 0 then
      Break;
    NomeStr := WParaTexto(@NomeVal[0], High(NomeVal) + 1);
    for J := 0 to High(CNomesValoresDir) do
      if CompareText(NomeStr, CNomesValoresDir[J]) = 0 then
      begin
        if LerValorDir(hKey, NomeStr, Dir) then
          if not JaExiste(Arr, Dir) then
            AdicionarCandidato(Arr, Dir, AOrigem, AFamilia);
        Break;
      end;
    Inc(I);
  end;
end;

// Encontra as chaves-filha (nomes) de hKey.
procedure ColetarSubchaves(hKey: THReg; AFamilia: TBFamilia;
  const AOrigem: string; var Arr: TCandidatoArray);
var
  I: DWORD;
  Nome: array[0..255] of WideChar;
  hSub: THReg;
begin
  I := 0;
  while True do
  begin
    FillChar(Nome, SizeOf(Nome), 0);
    if ApiRegEnumKeyW(hKey, I, @Nome[0], High(Nome) + 1) <> 0 then
      Break;
    // cada subchave pode guardar RootDirectory (ex.: versoes FB)
    if ApiRegOpenKeyExW(hKey, @Nome[0], 0, C_KEY_READ, hSub) = 0 then
    begin
      try
        ColetarValoresDaChave(hSub, AOrigem, AFamilia, Arr);
      finally
        ApiRegCloseKey(hSub);
      end;
    end;
    Inc(I);
  end;
end;

// ------------------------------------------------------------------
// Coleta via registro (Firebird Project / InterBase + servicos)
// ------------------------------------------------------------------
procedure ColetarRegistro(var Arr: TCandidatoArray);
const
  C_SERVICOS = 'SYSTEM\CurrentControlSet\Services';
var
  I, V: Integer;
  hKey, hSub: THReg;
  R: Longint;
  Dir: string;
  Familia: TBFamilia;
  Nome: array[0..255] of WideChar;
  Vista: array[0..1] of DWORD;
  SvcNome: string;
begin
  Vista[0] := 0;             // vista nativa do processo (32/64)
  Vista[1] := C_WOW64_64KEY; // e a vista 64 (cobre WOW6432Node)
  for V := 0 to 1 do
  begin
    for I := 0 to High(CChavesRegistro) do
    begin
      if Pos('InterBase', CChavesRegistro[I]) > 0 then
        Familia := bfInterBase
      else
        Familia := bfFirebird;
      if ApiRegOpenKeyExW(C_HKLM, PWideChar(WideString(CChavesRegistro[I])),
                          0, C_KEY_READ or Vista[V], hKey) = 0 then
      begin
        try
          ColetarValoresDaChave(hKey, 'registro', Familia, Arr);
          ColetarSubchaves(hKey, Familia, 'registro', Arr);
        finally
          ApiRegCloseKey(hKey);
        end;
      end;
    end;

    // servicos com ImagePath apontando para pasta de bin
    if ApiRegOpenKeyExW(C_HKLM, PWideChar(WideString(C_SERVICOS)), 0,
                        C_KEY_READ or Vista[V], hKey) = 0 then
    begin
      try
        R := 0;
        while True do
        begin
          FillChar(Nome, SizeOf(Nome), 0);
          if ApiRegEnumKeyW(hKey, R, @Nome[0], High(Nome) + 1) <> 0 then
            Break;
          SvcNome := WParaTexto(@Nome[0], High(Nome) + 1);
          if (Pos('firebird', LowerCase(SvcNome)) > 0) or
             (Pos('interbase', LowerCase(SvcNome)) > 0) or
             (Pos('ibguard', LowerCase(SvcNome)) > 0) or
             (Pos('gibraltar', LowerCase(SvcNome)) > 0) then
          begin
            if ApiRegOpenKeyExW(hKey, @Nome[0], 0, C_KEY_READ, hSub) = 0 then
            begin
              try
                if LerValorDir(hSub, 'ImagePath', Dir) then
                begin
                  // ImagePath: '"C:\...\fbguard.exe" -a' -> pasta do exe
                  Dir := Trim(Dir);
                  if (Length(Dir) > 0) and (Dir[1] = '"') then
                  begin
                    Delete(Dir, 1, 1);
                    I := Pos('"', Dir);
                    if I > 0 then
                      Dir := Copy(Dir, 1, I - 1);
                  end
                  else
                  begin
                    I := Pos(' ', Dir);
                    if I > 0 then
                      Dir := Copy(Dir, 1, I - 1);
                  end;
                  Dir := ExtractFilePath(Dir);
                  if (Dir <> '') and not JaExiste(Arr, Dir) then
                    AdicionarCandidato(Arr, Dir, 'registro (servico)',
                      FamiliaPorNome(SvcNome));
                end;
              finally
                ApiRegCloseKey(hSub);
              end;
            end;
          end;
          Inc(R);
        end;
      finally
        ApiRegCloseKey(hKey);
      end;
    end;
  end;
end;

// ------------------------------------------------------------------
// Coleta de pastas padrao (%ProgramFiles% etc.) e subpastas
// ------------------------------------------------------------------
function VariavelAmbiente(const ANome: string): string;
var
  Nome, W: WideString;
begin
  Nome := WideString(ANome);
  SetLength(W, 4096);
  if ApiGetEnvironmentVariableW(PWideChar(Nome), PWideChar(W), 4096) > 0 then
    Result := Trim(string(PWideChar(W)))
  else
    Result := '';
end;

// Adiciona um diretorio e seus filhos diretos (instalacoes lado a lado,
// ex.: Firebird_2_5 dentro de 'Program Files\Firebird'). Usa as APIs
// Win32 FindFirstFileW/FindNextFileW (portaveis D7/FPC; a SysUtils do
// FPC difere da do D7 nesta rotina).
procedure ColetarRaizComFilhos(const ARaiz, AOrigem: string;
  AFamilia: TBFamilia; var Arr: TCandidatoArray);
var
  Padrao, Filho: WideString;
  FD: TWIN32FindDataW;
  H: THandle;
  Nome: string;
begin
  if ARaiz = '' then
    Exit;
  if not DirectoryExists(ARaiz) then
    Exit;
  if not JaExiste(Arr, ARaiz) then
    AdicionarCandidato(Arr, ARaiz, AOrigem, AFamilia);
  Padrao := WideString(ARaiz + '\*');
  H := FindFirstFileW(PWideChar(Padrao), FD);
  if H <> INVALID_HANDLE_VALUE then
  begin
    try
      repeat
        Nome := string(WideString(PWideChar(@FD.cFileName[0])));
        if (Nome <> '.') and (Nome <> '..') then
          if (FD.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
          begin
            Filho := WideString(ARaiz + '\' + Nome);
            if not JaExiste(Arr, string(Filho)) then
              AdicionarCandidato(Arr, string(Filho), AOrigem, AFamilia);
          end;
      until not FindNextFileW(H, FD);
    finally
      FindClose(H);
    end;
  end;
end;

procedure ColetarPastasPadrao(var Arr: TCandidatoArray);
var
  PF, PFx, PFw: string;
begin
  PF := VariavelAmbiente('ProgramFiles');
  PFx := VariavelAmbiente('ProgramFiles(x86)');
  PFw := VariavelAmbiente('ProgramW6432');
  ColetarRaizComFilhos(PF + '\Firebird', 'pasta padrao', bfFirebird, Arr);
  if PFx <> PF then
    ColetarRaizComFilhos(PFx + '\Firebird', 'pasta padrao', bfFirebird, Arr);
  if PFw <> PF then
    ColetarRaizComFilhos(PFw + '\Firebird', 'pasta padrao', bfFirebird, Arr);
  // InterBase/Embarcadero (raiz e subpastas com 'InterBase')
  ColetarRaizComFilhos(PF + '\Borland\InterBase', 'pasta padrao', bfInterBase, Arr);
  ColetarRaizComFilhos(PF + '\Embarcadero\InterBase', 'pasta padrao', bfInterBase, Arr);
  if PFx <> '' then
  begin
    ColetarRaizComFilhos(PFx + '\Borland\InterBase', 'pasta padrao', bfInterBase, Arr);
    ColetarRaizComFilhos(PFx + '\Embarcadero\InterBase', 'pasta padrao', bfInterBase, Arr);
  end;
end;

// ------------------------------------------------------------------
// Coleta do PATH
// ------------------------------------------------------------------
procedure ColetarPath(var Arr: TCandidatoArray);
var
  Path, Item: string;
  P: Integer;
begin
  Path := VariavelAmbiente('PATH');
  while Path <> '' do
  begin
    P := Pos(';', Path);
    if P > 0 then
    begin
      Item := Trim(Copy(Path, 1, P - 1));
      Delete(Path, 1, P);
    end
    else
    begin
      Item := Trim(Path);
      Path := '';
    end;
    if Item = '' then
      Continue;
    if (Length(Item) > 1) and (Item[1] = '"') and (Item[Length(Item)] = '"') then
      Item := Copy(Item, 2, Length(Item) - 2);
    if not JaExiste(Arr, Item) then
      AdicionarCandidato(Arr, Item, 'PATH', bfDesconhecida);
  end;
end;

// ------------------------------------------------------------------
// Validacao: pasta (ou pasta\bin) com pelo menos um utilitario.
// ------------------------------------------------------------------
function DirTemFerramenta(const ADir: string; out TemGbak, TemGfix,
  TemIsql: Boolean): Boolean;
begin
  TemGbak := FileExists(ADir + '\' + CNomeGbak);
  TemGfix := FileExists(ADir + '\' + CNomeGfix);
  TemIsql := FileExists(ADir + '\' + CNomeIsql);
  Result := TemGbak or TemGfix or TemIsql;
end;

// Determina a familia final: versao > heuristica do caminho > fonte.
function ResolverFamilia(const AB: TBinSet): TBFamilia;
begin
  Result := AB.Familia;
  if AB.Versao.Valida and (AB.Versao.Familia <> bfDesconhecida) then
    Result := AB.Versao.Familia;
end;

function ExaminarCandidato(const ADir: string; const AOrigem: string;
  var B: TBinSet): Boolean;
var
  D, D2: string;
  tg, tf, ti: Boolean;
  OrigemFamilia: TBFamilia;
begin
  Result := False;
  D := ExcludeTrailingPathDelimiter(Trim(ADir));
  if D = '' then
    Exit;
  OrigemFamilia := FamiliaPorNome(D);

  // tenta a pasta informada; em seguida a subpasta 'bin'
  if DirTemFerramenta(D, tg, tf, ti) then
    D2 := D
  else if DirTemFerramenta(D + '\bin', tg, tf, ti) then
    D2 := D + '\bin'
  else
    Exit;

  B.CaminhoBin := IncludeTrailingPathDelimiter(D2);
  B.Origem := AOrigem;
  B.Familia := OrigemFamilia;
  B.TemGbak := tg;
  B.TemGfix := tf;
  B.TemIsql := ti;

  // versao: recurso do gbak; se falhar, gfix; depois isql
  ZerarVersion(B.Versao);
  if tg then
    VersaoDoArquivo(D2 + '\' + CNomeGbak, B.Versao);
  if not B.Versao.Valida then
    if tf then
      VersaoDoArquivo(D2 + '\' + CNomeGfix, B.Versao);
  if not B.Versao.Valida then
    if ti then
      VersaoDoArquivo(D2 + '\' + CNomeIsql, B.Versao);

  B.Familia := ResolverFamilia(B);
  // suporta fix_fss somente quando a versao do gbak e conhecida e
  // atende a regra do catalogo; caso contrario, conservador False.
  B.SuportaFixFss := tg and B.Versao.Valida and
                     GbakSuportaFixFss(B.Versao);
  Result := True;
end;

// ------------------------------------------------------------------
// AutoDetectar
// ------------------------------------------------------------------
function AutoDetectar(AExtras: TStrings; var ALista: TBinSetArray): Integer;
var
  Cands: TCandidatoArray;
  I, N: Integer;
  B: TBinSet;
begin
  SetLength(ALista, 0);
  SetLength(Cands, 0);

  // 1) extras (maior prioridade; tambem e o gancho de teste)
  if AExtras <> nil then
    for I := 0 to AExtras.Count - 1 do
      AdicionarCandidato(Cands, AExtras[I], 'extras', bfDesconhecida);

  // 2) registro
  ColetarRegistro(Cands);

  // 3) pastas padrao
  ColetarPastasPadrao(Cands);

  // 4) PATH
  ColetarPath(Cands);

  // validacao com dedupe (mantem a primeira ocorrencia; extras ficam
  // na frente por construcao)
  for I := 0 to Length(Cands) - 1 do
  begin
    if ExaminarCandidato(Cands[I].Dir, Cands[I].Origem, B) then
    begin
      N := Length(ALista);
      SetLength(ALista, N + 1);
      ALista[N] := B;
    end;
  end;
  Result := Length(ALista);
end;

// ------------------------------------------------------------------
// BinParaTexto
// ------------------------------------------------------------------
function BinParaTexto(ABin: TBinKind; const AB: TBinSet): string;
begin
  case ABin of
    bkGbak: Result := 'gbak';
    bkGfix: Result := 'gfix';
  else
    Result := 'isql';
  end;
end;

end.