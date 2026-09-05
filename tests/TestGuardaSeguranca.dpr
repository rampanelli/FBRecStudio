program TestGuardaSeguranca;

{ Testes de uGuardaSeguranca (F3-T2). Console; exit = n. de falhas.
  Exercita no Windows real a heuristica de "banco em uso" (abre um
  arquivo com exclusao via TFileStream e confere a deteccao) e a
  politica GuardaAntesDeEscrita (read-only livre; write exige copia e
  banco livre). }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Classes, Windows,
  uGuardaSeguranca in '..\src\engines\uGuardaSeguranca.pas';

var
  Fails, Checks: Integer;

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

// Cria arquivo vazio (True em sucesso).
function CriarArquivo(const APath: string): Boolean;
var
  FS: TFileStream;
begin
  Result := False;
  try
    FS := TFileStream.Create(APath, fmCreate);
    FS.Free;
    Result := True;
  except
    Result := False;
  end;
end;

var
  BaseDir, Arq: string;
  Msg: string;
  Erro: DWORD;
  H: THandle;
  Acesso: TGfAcesso;
  FS: TFileStream;
begin
  Fails := 0;
  Checks := 0;

  BaseDir := TempDir + 'FBRGuard' + IntToStr(GetCurrentProcessId);
  if DirectoryExists(BaseDir) then
    RemoveDir(BaseDir);
  ForceDirectories(BaseDir);
  Arq := BaseDir + '\banco.fdb';

  // ---------- 1) TestarAcessoBanco em arquivo livre ----------
  CriarArquivo(Arq);
  Acesso := TestarAcessoBanco(Arq, Erro);
  Check('acesso: arquivo livre = gaOk', Acesso = gaOk);
  Check('acesso: arquivo livre sem erro', Erro = 0);
  Check('acesso: BancoEmUso false em arquivo livre',
        not BancoEmUso(Arq));

  // ---------- 2) TestarAcessoBanco em arquivo LOCKED ----------
  // Abre com exclusao total (TFileStream share default = exclusivo).
  FS := TFileStream.Create(Arq, fmOpenReadWrite);
  try
    Acesso := TestarAcessoBanco(Arq, Erro);
    Check('acesso: arquivo travado = gaEmUso', Acesso = gaEmUso);
    Check('acesso: erro 32/33 (share/lock)',
          (Erro = ERROR_SHARING_VIOLATION) or
          (Erro = ERROR_LOCK_VIOLATION));
    Check('acesso: BancoEmUso true quando travado', BancoEmUso(Arq));

    // ---------- 3) politica com banco travado ----------
    Msg := '';
    Check('guarda: write sem copia bloqueia (msg copia)',
          (not GuardaAntesDeEscrita(Arq, True, False, False, Msg)) and
          (Pos('copia', Msg) > 0));
    Msg := '';
    Check('guarda: write com copia mas banco EM USO bloqueia',
          (not GuardaAntesDeEscrita(Arq, True, True, False, Msg)) and
          (Pos('EM USO', Msg) > 0));
    Msg := '';
    Check('guarda: APermiteEmUso libera o bloqueio',
          GuardaAntesDeEscrita(Arq, True, True, True, Msg));
    Msg := '';
    Check('guarda: read-only nunca bloqueia (mesmo travado)',
          GuardaAntesDeEscrita(Arq, False, False, False, Msg));
  finally
    FS.Free;
  end;

  // ---------- 4) politica com arquivo livre ----------
  Msg := '';
  Check('guarda: write sem copia bloqueia (mesmo livre)',
        not GuardaAntesDeEscrita(Arq, True, False, False, Msg));
  Msg := '';
  Check('guarda: write + copia + livre = libera',
        GuardaAntesDeEscrita(Arq, True, True, False, Msg));

  // ---------- 5) arquivo inexistente ----------
  Acesso := TestarAcessoBanco(BaseDir + '\nao_ha.fdb', Erro);
  Check('acesso: inexistente = gaInexistente', Acesso = gaInexistente);
  Msg := '';
  Check('guarda: inexistente bloqueia write com msg de banco',
        (not GuardaAntesDeEscrita(BaseDir + '\nao_ha.fdb',
          True, True, False, Msg)) and (Pos('nao encontrado', Msg) > 0));

  // ---------- 6) GfAcessoParaTexto (relatorio/log) ----------
  Check('texto: gaOk legivel', GfAcessoParaTexto(gaOk) <> '');
  Check('texto: gaEmUso legivel', GfAcessoParaTexto(gaEmUso) <> '');

  // ---------- 7) arquivo aberto com permissao de compartilhar ------
  // Abre com FILE_SHARE_READ: outro leitor com share0 ainda e negado.
  H := CreateFileW(PWideChar(WideString(Arq)), GENERIC_READ,
       FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if H <> INVALID_HANDLE_VALUE then
  begin
    Acesso := TestarAcessoBanco(Arq, Erro);
    Check('acesso: share read ainda nega leitor exclusivo (share0)',
          Acesso = gaEmUso);
    CloseHandle(H);
  end
  else
    Check('acesso: (premissa) conseguiu abrir com share read', False);

  // limpeza
  SysUtils.DeleteFile(Arq);
  RemoveDir(BaseDir);

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.
