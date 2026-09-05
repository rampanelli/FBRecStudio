@echo off
rem ====================================================================
rem  build_tests.bat - compila e executa os testes unitarios da F0.
rem  Uso: build_tests.bat [caminho\para\dcc32.exe]
rem  Resolucao: argumento > env FB_DCC32 > %DELPHI_ROOT%\Bin > comum.
rem ====================================================================
setlocal EnableDelayedExpansion

rem ---- DELPHI_ROOT: ajuste para a instalacao local do Delphi 7 ----
set "DELPHI_ROOT=C:\Borland\Delphi7"

set DCC=%~1
if "%DCC%"=="" set "DCC=%FB_DCC32%"
if "%DCC%"=="" if exist "%DELPHI_ROOT%\Bin\dcc32.exe" set "DCC=%DELPHI_ROOT%\Bin\dcc32.exe"
if "%DCC%"=="" if exist "C:\Program Files (x86)\Borland\Delphi7\Bin\dcc32.exe" set DCC=C:\Program Files (x86)\Borland\Delphi7\Bin\dcc32.exe
if "%DCC%"=="" if exist "C:\Program Files\Borland\Delphi7\Bin\dcc32.exe" set DCC=C:\Program Files\Borland\Delphi7\Bin\dcc32.exe
if "%DCC%"=="" if exist "C:\Arquivos de Programas\Borland\Delphi7\Bin\dcc32.exe" set DCC=C:\Arquivos de Programas\Borland\Delphi7\Bin\dcc32.exe

if not exist "%DCC%" (
  echo [erro] dcc32.exe nao encontrado.
  echo         Informe o caminho como argumento, defina FB_DCC32 ou
  echo         ajuste DELPHI_ROOT no topo deste arquivo.
  exit /b 2
)

pushd "%~dp0"

set TOTAL=0
for %%P in (TestCodec TestQuoting TestLogger TestKernelExec) do (
  echo.
  echo === Compilando %%P.dpr ===
  "%DCC%" -Q -B -U"..\src\core" -U"..\src\persist" %%P.dpr
  if not exist "%%P.exe" (
    echo [erro] falha ao compilar %%P
    popd
    exit /b 1
  )
  echo === Executando %%P.exe ===
  "%%P.exe"
  set RC=!ERRORLEVEL!
  set /a TOTAL=TOTAL+RC
)

popd
echo.
if "%TOTAL%"=="0" (
  echo [ok] todos os testes passaram.
) else (
  echo [erro] total de falhas: %TOTAL%.
)
exit /b %TOTAL%
