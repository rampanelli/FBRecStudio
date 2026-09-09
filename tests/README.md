# tests/ - Testes unitarios (F0 e F1)

Projetos de console Delphi 7 (sem dependencias de terceiros). Cada um
imprime `PASS/FAIL` por verificacao e termina com exit code = n. de
falhas (0 = sucesso).

| Projeto         | Unidades sob teste               | Cobre                                  |
|-----------------|----------------------------------|----------------------------------------|
| TestCodec.dpr   | src\core\uTextCodec.pas          | UTF-8/OEM/ACP, heuristica de decodificacao |
| TestQuoting.dpr | src\core\uQuoting.pas            | quoting CRT, parser de referencia, mascaramento de -pass |
| TestLogger.dpr  | src\core\uLogger.pas             | BOM UTF-8, linha canonica [data] [etapa] [canal], arquivo em %TEMP% unico |
| TestKernelExec.dpr | src\core\uKernelExec.pas      | execucao real (cmd /c ver), timeout e kill da arvore |
| RunCoreTests.dpr | TODAS (core + persist)          | uTextCodec/uQuoting/uLogger/uHash/uKernelExec/uAppConfig/uCredStore(DPAPI)/uHistoryStore |
| TestFBVersion.dpr | src\firebird\uFBVersionInfo.pas | versao/familia/ODS (parse de '-z', VS_VERSION_INFO, tabela ODS) — F1-T1 |
| TestSwitchCatalog.dpr | src\firebird\uFBVersionInfo.pas, uFBSwitchCatalog.pas | catalogo (binario x versao x semantica), regra -FIX_FSS_*, ODS x versao — F1-T2/T4 |
| TestFBAutoDetect.dpr | src\firebird\uFBAutoDetect.pas (+catalog) | deteccao com diretorios fake em %TEMP% — F1-T3 |
| TestDiagProbe.dpr | src\diag\uDiagParser.pas, uDiagFileProbe.pas, uDiagReport.pas | buffers sinteticos de banco/backup, leitura em disco — F1-T4/T5 |
| TestAutoRecuperar.dpr | src\engines\uMotorAutoRec.pas (+engines) | recuperacao automatica contra arquivo REAL (uso: TestAutoRecuperar.exe <arquivo> [<pasta_gbak>] [<pasta_trabalho>]) — v0.3 |

Compilacao e execucao: `tests\build_tests.bat [caminho\do\dcc32.exe]`
(variaveis de ambiente `FB_DCC32` ou `DELPHI_ROOT` tambem sao aceitas —
mesma resolucao do `src\app\build.bat`).

Sem Delphi 7 na maquina, os mesmos .dpr compilam e rodam com Free Pascal
3.2.2 em modo Delphi (nucleo nao-GUI; ver `docs/VALIDACAO-FPC.md`):

```
fpc.exe -Mdelphi -Fu..\src\core -Fu..\src\persist -FU..\build\fpc-out ^
        -o..\build\fpc-out\<Teste>.exe <Teste>.dpr
```

## corpora/

Arquivos de exemplo (bancos pequenos, binarios, saídas de ferramentas)
entram aqui a partir da F1. Regra: apenas arquivos pequenos e sem dados
sensiveis; ver .gitignore (o conteudo de corpora nao e versionado).

## Convencoes

- Fontes de teste seguem as mesmas regras dos fontes de producao:
  ASCII puro nos comentarios, identificadores em ingles, Delphi 7 puro.
- Nunca usam nomes fixos de arquivo temporario.
