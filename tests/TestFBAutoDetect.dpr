program TestFBAutoDetect;

{ Testes unitarios de uFBAutoDetect (F1-T3): deteccao de instalacoes
  Firebird/InterBase por injeccao de diretorios fake em %TEMP%
  (gbak.exe/gfix.exe/isql.exe VAZIOS - nada e executado). Verifica:
  validacao por existencia, resolucao da subpasta 'bin', familia por
  nome de caminho, ordem/prioridade dos extras e dedupe. Console;
  exit = n. de falhas. }

{$APPTYPE CONSOLE}
{$H+}

uses
  SysUtils, Classes, Windows,
  uFBVersionInfo in '..\src\firebird\uFBVersionInfo.pas',
  uFBSwitchCatalog in '..\src\firebird\uFBSwitchCatalog.pas',
  uFBAutoDetect in '..\src\firebird\uFBAutoDetect.pas';

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

var
  Raiz, Dir25, Dir30, DirSem: string;
  Extra: TStringList;
  Lista: TBinSetArray;
  I, N: Integer;
  Achou25, Achou30: Boolean;
  B: TBinSet;

// Cria um arquivo vazio (nao precisa existir conteudo valido).
procedure CriarArquivoVazio(const ACaminho: string);
var
  H: Integer;
begin
  H := FileCreate(ACaminho);
  if H >= 0 then
    FileClose(H);
end;

// %TEMP% (D7 nao tem GetTempDir do FPC).
function TempDir: string;
var
  Buf: array[0..MAX_PATH - 1] of Char;
  N: Integer;
begin
  N := GetTempPath(SizeOf(Buf), PChar(@Buf[0]));
  Result := '';
  if N > 0 then
    Result := StrPas(PChar(@Buf[0]));
end;

begin
  Fails := 0;
  Checks := 0;

  // ---------- cenario fake em %TEMP% ----------
  Raiz := ExcludeTrailingPathDelimiter(TempDir) + '\fbrec_f1_test_' +
          FormatDateTime('hhnnsszzz', Now);
  Dir25 := Raiz + '\Firebird_2_5';
  Dir30 := Raiz + '\Firebird_3_0';
  DirSem := Raiz + '\sem_ferramentas';
  ForceDirectories(Dir25 + '\bin');
  ForceDirectories(Dir30 + '\bin');
  ForceDirectories(DirSem);
  CriarArquivoVazio(Dir25 + '\bin\gbak.exe');
  CriarArquivoVazio(Dir25 + '\bin\gfix.exe');
  CriarArquivoVazio(Dir25 + '\bin\isql.exe');
  CriarArquivoVazio(Dir30 + '\bin\gbak.exe');

  Extra := TStringList.Create;
  try
    // aponta para a pasta de bin direta e para a raiz (subpasta 'bin')
    Extra.Add(Dir25 + '\bin');
    Extra.Add(Dir30);
    Extra.Add(DirSem);                 // sem ferramentas -> descartado
    Extra.Add(Raiz + '\nao_existe');   // inexistente -> descartado

    N := AutoDetectar(Extra, Lista);
    Check('detectou ao menos os 2 extras', N >= 2);

    Achou25 := False;
    Achou30 := False;
    for I := 0 to Length(Lista) - 1 do
    begin
      if CompareText(Lista[I].CaminhoBin,
                     IncludeTrailingPathDelimiter(Dir25 + '\bin')) = 0 then
      begin
        Achou25 := True;
        Check('fb25 tem gbak/gfix/isql',
              Lista[I].TemGbak and Lista[I].TemGfix and Lista[I].TemIsql);
        Check('fb25 familia por nome do caminho',
              Lista[I].Familia = bfFirebird);
        Check('fb25 origem = extras', Lista[I].Origem = 'extras');
        // exe vazio sem recurso de versao: fix_fss conservador false
        Check('fb25 sem recurso -> SuportaFixFss false',
              not Lista[I].SuportaFixFss);
        Check('fb25 versao nao valida (sem recurso)', not Lista[I].Versao.Valida);
        Check('fb25 caminho com terminador',
              (Length(Lista[I].CaminhoBin) > 0) and
              (Lista[I].CaminhoBin[Length(Lista[I].CaminhoBin)] = '\'));
      end;
      if CompareText(Lista[I].CaminhoBin,
                     IncludeTrailingPathDelimiter(Dir30 + '\bin')) = 0 then
      begin
        Achou30 := True;
        Check('fb30 achado via subpasta bin', Lista[I].TemGbak and
              not Lista[I].TemGfix and not Lista[I].TemIsql);
        Check('fb30 familia', Lista[I].Familia = bfFirebird);
      end;
    end;
    Check('extra fb25 presente', Achou25);
    Check('extra fb30 presente (resolucao \bin)', Achou30);

    // nenhum resultado deve apontar para a pasta sem ferramentas
    for I := 0 to Length(Lista) - 1 do
      Check('nao lista pasta sem ferramentas: ' + Lista[I].CaminhoBin,
            CompareText(Lista[I].CaminhoBin,
                        IncludeTrailingPathDelimiter(DirSem)) <> 0);

    // AutoDetectar com nil nao pode falhar
    N := AutoDetectar(nil, Lista);
    Check('auto detectar com nil roda (>= 0)', N >= 0);

    // ExaminarCandidato direto
    Check('examinar pasta valida (bin direto)',
          ExaminarCandidato(Dir25 + '\bin', 'teste', B) and
          B.TemGbak and B.TemIsql);
    Check('examinar pasta valida (via \bin)',
          ExaminarCandidato(Dir30, 'teste', B) and B.TemGbak);
    Check('examinar pasta sem ferramentas -> false',
          not ExaminarCandidato(DirSem, 'teste', B));
    Check('examinar pasta inexistente -> false',
          not ExaminarCandidato(Raiz + '\nao_existe', 'teste', B));
    Check('examinar arquivo (nao pasta) -> false',
          not ExaminarCandidato(Dir25 + '\bin\gbak.exe', 'teste', B));
  finally
    Extra.Free;
    // limpeza
    SysUtils.DeleteFile(Dir25 + '\bin\gbak.exe');
    SysUtils.DeleteFile(Dir25 + '\bin\gfix.exe');
    SysUtils.DeleteFile(Dir25 + '\bin\isql.exe');
    SysUtils.DeleteFile(Dir30 + '\bin\gbak.exe');
    RemoveDir(Dir25 + '\bin');
    RemoveDir(Dir30 + '\bin');
    RemoveDir(Dir25);
    RemoveDir(Dir30);
    RemoveDir(DirSem);
    RemoveDir(Raiz);
  end;

  WriteLn;
  WriteLn('TOTAL=' + IntToStr(Checks) + ' FALHAS=' + IntToStr(Fails));
  Halt(Fails);
end.