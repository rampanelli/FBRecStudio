@echo off
rem ====================================================================
rem  build.bat - compila FBRecStudio (F0) com Delphi 7 / brcc32.
rem
rem  Uso:  build.bat [caminho\para\dcc32.exe]
rem  Ordem de resolucao do dcc32:
rem    1. argumento da linha de comando
rem    2. variavel de ambiente FB_DCC32
rem    3. %DELPHI_ROOT%\Bin\dcc32.exe   (DELPHI_ROOT definido abaixo)
rem    4. caminhos comuns de instalacao do Delphi 7
rem
rem  Efeito: gera o .res (brcc32), o exe em ..\..\bin\FBRecStudio.exe e
rem  deixa os DCUs intermediarios em ..\..\build\dcu (gitignored).
rem
rem  IMPORTANTE (F0): esta maquina de desenvolvimento NAO tem dcc32
rem  instalado - o build e documentado e validado por leitura, a ser
rem  executado quando houver Delphi 7 (ver ROADMAP-STATUS.md).
rem ====================================================================
setlocal

rem ---- DELPHI_ROOT: ajuste para a instalacao local do Delphi 7 ----
set "DELPHI_ROOT=C:\Borland\Delphi7"

set DCC=%~1
if "%DCC%"=="" set "DCC=%FB_DCC32%"
if "%DCC%"=="" if exist "%DELPHI_ROOT%\Bin\dcc32.exe" set "DCC=%DELPHI_ROOT%\Bin\dcc32.exe"
if "%DCC%"=="" if exist "C:\Program Files (x86)\Borland\Delphi7\Bin\dcc32.exe" set "DCC=C:\Program Files (x86)\Borland\Delphi7\Bin\dcc32.exe"
if "%DCC%"=="" if exist "C:\Program Files\Borland\Delphi7\Bin\dcc32.exe" set "DCC=C:\Program Files\Borland\Delphi7\Bin\dcc32.exe"
if "%DCC%"=="" if exist "C:\Arquivos de Programas\Borland\Delphi7\Bin\dcc32.exe" set "DCC=C:\Arquivos de Programas\Borland\Delphi7\Bin\dcc32.exe"

if not exist "%DCC%" (
  echo [erro] dcc32.exe nao encontrado.
  echo         Informe o caminho como argumento, defina FB_DCC32 ou
  echo         ajuste DELPHI_ROOT no topo deste arquivo.
  exit /b 2
)

rem ---- brcc32 fica no mesmo diretorio do dcc32 ----
for %%F in ("%DCC%") do set "DCCDIR=%%~dpF"
if "%DCCDIR:~-1%"=="\" set "DCCDIR=%DCCDIR:~0,-1%"
if exist "%DCCDIR%\brcc32.exe" (
  set "BRCC=%DCCDIR%\brcc32.exe"
) else if exist "%DCCDIR%\..\brcc32.exe" (
  set "BRCC=%DCCDIR%\..\brcc32.exe"
) else (
  echo [erro] brcc32.exe nao encontrado ao lado do dcc32.exe.
  exit /b 2
)

rem ---- saidas: exe em ..\..\bin ; dcu em ..\..\build\dcu ----
pushd "%~dp0"
if not exist "..\..\bin" mkdir "..\..\bin"
if errorlevel 1 goto :falha_pasta
if not exist "..\..\build\dcu" mkdir "..\..\build\dcu"
if errorlevel 1 goto :falha_pasta

echo [1/2] brcc32 FBRecStudio.rc ...
"%BRCC%" FBRecStudio.rc
if errorlevel 1 goto :falha_brcc

echo [2/2] dcc32 FBRecStudio.dpr ...
"%DCC%" -Q -B -M -I"..\.." -U"..\core;..\persist;..\firebird;..\diag;..\engines;..\export;..\ui" -E"..\..\bin" -N"..\..\build\dcu" FBRecStudio.dpr
set RC=%ERRORLEVEL%
if "%RC%"=="0" goto :dcc_ok
echo [erro] dcc32 falhou (errorlevel %RC%).
popd
exit /b 1

:dcc_ok
if exist "..\..\bin\FBRecStudio.exe" goto :ok
echo [aviso] compile sem erros aparentes, mas bin\FBRecStudio.exe nao foi
echo         localizado (confira a saida do dcc32 acima).
popd
exit /b 0

:ok
echo [ok] bin\FBRecStudio.exe gerado.
if exist "..\..\docs\AJUDA-MASTERDEV.md" copy /y "..\..\docs\AJUDA-MASTERDEV.md" "..\..\bin\AJUDA-MASTERDEV.md" >nul
popd
exit /b 0

:falha_pasta
echo [erro] nao foi possivel criar as pastas de saida (..\..\bin ou ..\..\build\dcu).
popd
exit /b 2

:falha_brcc
echo [erro] brcc32 falhou ao gerar FBRecStudio.res
popd
exit /b 1
