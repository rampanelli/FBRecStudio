program TestLogger;

{ Testes unitarios de uLogger (F0-T3). Console; exit = n. de falhas.
  Usa nome de arquivo UNICO em %TEMP% (nunca nome fixo - regra do plano). }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Classes, Windows,
  uLogger in '..\src\core\uLogger.pas',
  uTextCodec in '..\src\core\uTextCodec.pas';

var
  Fails, Checks: Integer;
  LogPath: string;
  L: TLogger;

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

function ReadAllText(const APath: string): string;
var
  FS: TFileStream;
begin
  Result := '';
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Result[1], FS.Size);
  finally
    FS.Free;
  end;
end;

// Pasta %TEMP% via Windows API (GetTempPath exige 2 parametros; nao ha
// overload sem argumentos no Windows.pas do D7 nem no FPC).
function TempDir: string;
var
  Buf: array[0..MAX_PATH] of Char;
  N: DWORD;
begin
  N := GetTempPath(SizeOf(Buf), PChar(@Buf[0]));
  if N = 0 then
    Result := '.'
  else
    SetString(Result, PChar(@Buf[0]), Integer(N));
end;

var
  Content: string;
  Buf: array[0..2] of Byte;
  FS: TFileStream;
begin
  Fails := 0;
  Checks := 0;

  // Nome unico no %TEMP% (sem nome fixo)
  LogPath := IncludeTrailingPathDelimiter(TempDir) +
             'FBRecStudio_TestLogger_' +
             FormatDateTime('yyyymmddhhnnsszzz', Now) + '_' +
             IntToStr(GetCurrentProcessId) + '.log';

  L := TLogger.Create;
  Check('abre novo arquivo', L.Open(LogPath));
  L.Info('Teste', 'linha um');
  L.Log('Teste', LC_STDOUT, 'linha dois');
  L.Warn('Teste', 'linha tres');
  L.Close;
  L.Free;

  // 1) arquivo existe com conteudo
  Content := ReadAllText(LogPath);
  Check('gravou linhas', Pos('linha um', Content) > 0);
  Check('gravou canal app', Pos('[app]', Content) > 0);
  Check('gravou etapa Teste', Pos('[Teste]', Content) > 0);
  Check('gravou aviso (Warn)', Pos('linha tres', Content) > 0);

  // 2) BOM UTF-8 no primeiro uso (EF BB BF)
  FS := TFileStream.Create(LogPath, fmOpenRead or fmShareDenyNone);
  try
    FillChar(Buf, SizeOf(Buf), 0);
    if FS.Size >= 3 then
      FS.ReadBuffer(Buf, 3);
  finally
    FS.Free;
  end;
  Check('BOM EF BB BF presente',
        (Buf[0] = $EF) and (Buf[1] = $BB) and (Buf[2] = $BF));

  // 3) logar antes de abrir nao quebra nada
  L := TLogger.Create;
  L.Info('Teste', 'nao deve aparecer');
  Check('sem arquivo nao grava', not L.IsOpen);
  L.Free;

  SysUtils.DeleteFile(LogPath);
  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.
