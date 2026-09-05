# Roadmap e status — FBRecStudio

> **Documento consolidado e atualizado:** ver `docs\ESTADO-DO-PROJETO.md`
> (fases entregues, validação Delphi 7/FPC, funcionalidades da GUI, pendências
> — inclui o instalador, **adiado**).

Acompanhamento por fase (F0..F8) do planejamento do produto. Convenção de
status usada aqui: **Feito / Parcial / Não feito**.

## Status da F0 (F0-T1..F0-T7 do PLANO, seção 7)

| Tarefa | Escopo | Status | Observação |
|---|---|---|---|
| F0-T1 | Esqueleto do repositório (árvore 6.1), git, README raiz, docs | Feito | Repositório iniciado em `master`; árvore com `.gitkeep` nas pastas reservadas |
| F0-T2 | `.dpr` + casca GUI + `.rc`/manifesto + `build.bat` | Parcial | Fontes e script prontos; **não compilados** (sem dcc32). Form 100% em código, **sem .dfm** (justificativa abaixo). Ícone placeholder já incluído no `.rc` |
| F0-T3 | uTextCodec + uLogger + testes simples | Feito | uTextCodec e uLogger completos; TestCodec/TestLogger **validados via FPC** (ver Validação FPC) |
| F0-T4 | uQuoting + uKernelExec v1 (pipes, threads, timeout, cancel, Job Object) | Feito | Corrige B3/B4/B11. Inclui auxiliar síncrono `BuildAndRun` (engines). TestQuoting/TestKernelExec **validados via FPC** |
| F0-T5 | uAppConfig (INI ANSI) + uCredStore (DPAPI) | Feito | `%APPDATA%\FBRecStudio\config.ini`; defaults gravados na 1ª execução. Senha **nunca** em claro. **uCredStore rodou DPAPI real** (RunCoreTests) |
| F0-T6 | uHistoryStore (CSV anexo, seção 4.6) + uHash | Feito | `history.csv` ';' + cabeçalho fixo; uHash MD5/SHA-1 (CryptoAPI) com vetores conhecidos **PASS** (RunCoreTests) |
| F0-T7 | Identidade visual: res/ + ícone + README de assets | Parcial | Paleta/tipografia/geometria documentadas (IDENTIDADE.md); **placeholder 16×16 gerado** em `res/icons/FBRecStudio.ico` (conceito PLANO 2.1: squircle azul + cilindro + seta ↻); design final multi-tamanho e decisões de marca (PLANO §9) ficam para a F1 |

Arquivos criados: ver docs/ESTRUTURA.md e o relatório final de entrega.

## Status da F1 (F1-T1..F1-T6 do PLANO, seção 7)

| Tarefa | Escopo | Status | Observação |
|---|---|---|---|
| F1-T1 | `uFBVersionInfo` — versão/família/ODS de binários FB/IB (parse de saída `-z`/`-?`, recurso VS_VERSION_INFO) | Feito | Validado via FPC (TestFBVersion: 29 checks) |
| F1-T2 | `uFBSwitchCatalog` — catálogo (binário×versão×semântica)→chave; regra `-FIX_FSS_*` (FB 1.5-2.5/IB6; FB3+ = vazio); tabela ODS×versão | Feito | Validado via FPC (TestSwitchCatalog: 70 checks); tabelas e divergência FB3 **a validar com bins reais na F7** (docs/CATALOGO-SWITCHES.md) |
| F1-T3 | `uFBAutoDetect` — registro HKLM (Firebird/InterBase, vistas 32/64), serviços (ImagePath), pastas padrão, PATH; valida por existência de gbak/gfix/isql + versão | Feito | Validado via FPC com diretórios fake em %TEMP% (TestFBAutoDetect: 19 checks); chaves de registro **a validar com bins reais na F7** |
| F1-T4 | `uDiagFileProbe` + `uDiagParser` — classificação .fbk/.gbk/.fdb/.gdb por assinatura/conteúdo; cabeçalho ODS 10+ (page size, ODS, dialeto, shutdown); técnica recomendada | Feito | Heurísticas documentadas + buffers sintéticos ODS 11.2/12.0 e backup c/ e s/ assinatura (TestDiagProbe: 43 checks); **offsets do cabeçalho a validar no corpus real na F7** |
| F1-T5 | `uDiagReport` — relatório textual legível + parser de bytes LE/BE | Feito | Testado junto do F1-T4 |
| F1-T6 | Diagnóstico na GUI (exibição do resultado/técnica sugerida) | **Bloqueada** | Requer VCL/Delphi 7 (dcc32) — GUI não compilável pelo FPC; ver Limitações da F0 |

**Validação FPC da F1:** as 6 units novas (`src\firebird`: uFBVersionInfo,
uFBSwitchCatalog, uFBAutoDetect; `src\diag`: uDiagParser, uDiagFileProbe,
uDiagReport) compilam sem erros e os 4 programas de console novos rodam
**161 verificações, 0 falhas** (29+70+19+43). Nenhum binário FB/IB real foi
executado (não há servidor instalado); as estruturas estão prontas para o
probe de runtime da F7.

## Status da F2-A (F2-T1..F2-T6 do PLANO, seccao 7)

| Tarefa | Escopo | Status | Observacao |
|---|---|---|---|
| F2-T1 | `uEngineGbak` - restore/backup gbak (modos c/r/b, pre-checks de ambiente, argv montado SOMENTE via ISwitchCatalog, lista negra de extras, execucao robusta via IProcessRunner, parse de saida e resumo) | Feito | Validado via FPC (TestEngineGbak: 82 checks), inclusive fake gbak compilado pelo proprio FPC em diretorio temporario (exit 0 e exit 7 com 'gbak: ERROR' no stderr) rodado ponta a ponta |
| F2-T2 | Fluxo de restore/backup na GUI | Aguardando UI | Requer dcc32 (ver limitacoes da F0); o motor esta pronto para ser chamado |
| F2-T3 | `uSafeCopy` - copia segura byte a byte com contagem/progresso e cancelamento (apaga o parcial; valida o tamanho final) | Feito | Validado via FPC (TestSafeCopy: 21 checks) com arquivo real >= 1 MB em diretorio temporario |
| F2-T4 | Log/progresso/cancelamento ao vivo | Parcial | O motor expoe IOutputSink/eventos e o cancelamento via IProcessRunner; falta apenas a tela (dcc32) |
| F2-T5 | fix_fss condicionado a versao + validacao pos-restore (gfix) | Aguardando UI | Chaves -FIX_FSS_* ja condicionadas pelo catalogo (FB 1.5-2.5/IB6; FB3+ omite com aviso) e plug IPassoValidacaoPos pronto; a engine gfix e a UI ficam na F3 |
| F2-T6 | Assistente de confirmacao (overwrite/credenciais) na GUI | Aguardando UI | Requer dcc32 |

**Validacao FPC da F2-A:** as 3 units novas (`src\engines`: uEngineBase,
uEngineGbak, uSafeCopy) compilam sem erros em `-Mdelphi` e os 2 programas de
console novos rodam **103 verificacoes, 0 falhas** (21 + 82), exit 0. O
teste de gbak compila um **fake gbak com o proprio FPC** e o executa via
uKernelExec de ponta a ponta: sucesso (exit 0 + 'finished'), falha (exit 7
+ 'gbak: ERROR'/'Exiting before completion' no stderr), comando logado com
a senha **mascarada** (******) e saida roteada ao sink externo. Nenhum
binario Firebird real foi executado (nao ha servidor instalado); a
validacao com bins reais fica para a F7.


## Form em código, sem .dfm (justificativa — F0-T2)

A missão da F0 pede a casca GUI **sem arquivo .dfm**, construída
programaticamente. Motivos registrados:

1. **Sem IDE nesta máquina**: não há Delphi 7/dcc32 nem IDE para gerar ou
   manter um `.dfm`; um `.dfm` "escrito à mão" é fonte clássica de
   inconsistência (classe/eventos/recursos divergentes do `.pas`,
   `EResNotFound` em runtime, encoding do texto no DFM).
2. **Compilação futura indolor**: `TfrmMain.Create` usa
   `inherited CreateNew(AOwner)` — o VCL monta o form sem procurar
   recurso de formulário; os controles são criados em `BuildUi`
   (TPanel/TLabel + TMemo), todos nativos D7.
3. **Self-test do núcleo na abertura** (missão F0): ao abrir, o memo
   executa asserções de **uQuoting, uTextCodec e uHash** (inclui vetores
   MD5/SHA-1 conhecidos) — prova que o esqueleto referência/linka as
   units `core` sem depender de Forms e dá sinal visual imediato de
   sanidade (a GUI real e as engines chegam na F1+).

## Limitações conhecidas da F0

1. **Sem Delphi 7/dcc32 na máquina**: o GUI (`src\app\FBRecStudio.dpr`,
   VCL Forms/`uFrmMain`) **só compila em Delphi 7 real** — o FPC não tem VCL
   (é LCL). O núcleo `core`/`persist` e os testes de console **foram
   validados com Free Pascal 3.2.2 em `-Mdelphi`** (ver seção Validação FPC
   abaixo e `docs/VALIDACAO-FPC.md`); o GUI permanece intocado e aguarda o
   dcc32.
2. Testes unitários **executados e verdes via FPC** (96 verificações, 0
   falhas — ver Validação FPC); faltam os `.exe` gerados pelo dcc32 para
   garantir 100% do alvo D7.
3. O ícone `res/icons/FBRecStudio.ico` é um **placeholder 16×16 32bpp**
   válido (XP+), gerado para o `.rc` compilar; o pacote vetorial
   multi-tamanho (16/24/32/48/256) e o design final são da F1-T7.
4. A casca GUI da F0 roda só o self-test do núcleo; a execução/cancelamento
   reais ficam para a F1 (a GUI chamará `BuildAndRun`/`IProcessRunner` em
   worker thread). A integração atual está coberta pelo TestKernelExec
   (console).

## Validação FPC (F0) — núcleo compilado e executado de verdade

Sem dcc32 na máquina, o núcleo não-GUI foi **compilado e executado** com
**Free Pascal 3.2.2 (i386-win32) em `-Mdelphi`** (subconjunto Delphi 7 puro;
FPC apenas como compilador de validação — nada de LCL/VCL). Relatório
completo: `docs/VALIDACAO-FPC.md`.

- **Compilação**: as 8 units (`src\core` + `src\persist`) compilam **sem
  erros nem warnings**; 5 programas de console em `tests\` (inclui o novo
  `RunCoreTests.dpr`, que cobre **todas** as units).
- **Execução (Windows real)**: **96 verificações, 0 falhas, exit 0** —
  inclui DPAPI **real** (uCredStore Save→Load→Erase), `cmd /c exit 0` **e**
  `exit 7`, timeout e **cancelamento reais com kill da árvore** (Job Object
  matou `cmd` + `ping` filho), vetores MD5/SHA-1 conhecidos, config
  load/save/`EnsureDefaultValues` em `%TEMP%`, histórico CSV com escape.
- **Correções de portabilidade aplicadas** (mantendo D7 puro): bloco `type`
  reaberto após `BuildAndRun`; `ReadFile` com lvalue (`Buf[0]`, não
  `@Buf[0]`); ordem dos argumentos do `IsPidInList` (BFS de descendentes);
  sem *forward class* (`TPipeReaderThread` antes de `TProcessRunner`, dono
  como `TObject`); `{$IFDEF FPC}` em `T.Start` vs `T.Resume`; binding próprio
  `KbGetTickCount` (XP-safe, evita deprecation do FPC); cast explícito
  `AnsiString(W)` no uAppConfig. Testes F0 com vetor cp850 errado e
  `GetTempPath` sem argumentos também corrigidos.
- **Limite**: o GUI (`src\app\FBRecStudio.dpr` + VCL Forms/`uFrmMain`)
  **não é compilado pelo FPC** (FPC não tem VCL) — só Delphi 7 real. FPC
  valida **apenas core/persist**; o GUI permanece intocado.

## Decisões em aberto (PLANO §9, anotadas — não resolvidas nesta F0)

- **§9 nome/marca**: "FBRecStudio" é nome de trabalho; validar com o
  cliente (e restrição de marca — não usar logotipos Firebird/InterBase
  da Firebird Foundation/Embarcadero).
- **§9 ícone**: conceito (cilindro + seta ↻ + check) validado no
  placeholder; assinatura do design final com o cliente na F1.
- **§9 credenciais**: F0 default `sysdba`/senha vazia e `SaveCredentials`
  desligado; política de armazenamento (DPAPI já pronto) a confirmar.
- **§9 escopo/config**: config.ini ANSI (uAppConfig) vs. JSON;
  Windows XP como requisito rígido (já adotado); retorno de progresso
  das engines (callback vs. polling) — ver PLANO §9.

## Próximos passos sugeridos (ordem)

1. Instalar Delphi 7 (ou VM) e rodar `tests\build_tests.bat` e
   `src\app\build.bat` — gerar os `.exe` com o dcc32 alvo (núcleo/core e F1
   já validados via FPC; confirmar GUI + self-test e destravar F1-T6);
2. F1-T6: diagnosticar o arquivo escolhido na GUI usando
   `uDiagFileProbe`/`uDiagReport` + tela de configuração das pastas de
   utilitários (uFBAutoDetect);
3. F1-T7 (design/marca) quando disponível: tema + ícone final;
4. F7: com bins reais, validar catálogo de switches e heurísticas do
   diagnóstico (docs/CATALOGO-SWITCHES.md) e então as engines
   (gbak/nbackup/gfix) com histórico via BuildAndRun + uHistoryStore.

## Status consolidado por fase do plano

| Fase | Descrição | Status |
|---|---|---|
| F0 | Casca + núcleo | Concluída — núcleo e testes **verdes via FPC** (96 checks); GUI aguarda dcc32 |
| F1 | Configuração + detecção + diagnóstico | Parcial — F1-T1..T5 **entregues e verdes via FPC** (161 checks); F1-T6 (GUI) **bloqueada** sem dcc32; catálogo/heurísticas **a validar com bins/corpus reais na F7** |
| F2-A | Engines de recuperacao: base (uEngineBase) + gbak restore/backup (uEngineGbak) + copia segura (uSafeCopy) | Parcial | F2-T1/T3 Feito e verdes via FPC (103 checks); F2-T4 Parcial (falta a UI); F2-T2/T5/T6 aguardam a UI (dcc32) |
| F3 | Reparo/validacao gfix + guarda de seguranca | Parcial — F3-T1/T2 **Feitos e verdes via FPC** (uEngineGfix 76 + uGuardaSeguranca 17 = 93 checks): motor por acao (validar/validarFull/mend/activate/sweep/housekeeping/mode/kill/icu), chaves so via catalogo (kill so FB3+; icu 2.5+), ordem segura (GerarOrdemSeguraGfix), guarda (write exige copia + banco livre; banco travado detectado por share-mode 0); E2E com fake gfix (FPC) validando sucesso/falha e senha mascarada. F3-T3 (fluxo na UI) **aguarda a UI** (dcc32) |
| F4 | Salvage/recuperação de banco corrompido (camadas L0-L5 + extrator de texto) | Parcial — F4-T1 **parcial**: L0 cópia forense (uSafeCopy) + L1 validar/reparar gfix + L3 backup do que abre + orquestração (uSalvagePlan/uMotorSalvage) **entregues e verdes via FPC** (TestSalvagePlan: 82 checks, inclui E2E com fake gfix/gbak FPC); L2 datapump por driver e L4 estendido **deixados** p/ quando houver driver/FB real (datapump registrado como ignorada no relatório: requer driver de dados; a interface de driver de leitura do exportador CSV (F5) já existe em src\export\uExportCSV, só falta a implementação sobre fbclient); F4-T2 extrator de texto básico **ok** (uExtratorTexto, TestExtratorTexto: 59 checks); F4-T3 (fluxo na UI) **aguarda a UI** (dcc32) |
| F5 | Exportacao (PLANO 4.3/4.6/6.2: FBK, SQL/DDL, CSV/TSV e relatorio; regras transversais de formatos/nomenclatura) | Parcial — base (uExportBase), FBK (uExportFBK: gbak -b via subprocesso), SQL/DDL (uExportSQL: isql -extract com **captura do stdout**, sem redirecionamento '>' de shell, charset de saida aplicado), relatorio legivel do DDL (uExportReport: `<base>_ddl.txt` com contagem aproximada sobre os bytes) e CSV/TSV (uExportCSV: RFC-4180, NULL como campo vazio, BLOB por politica omitir/hex/arquivo lateral) **entregues e verdes via FPC** (TestExportFbk 32 + TestExportSql 36 + TestExportCsv 50 + TestExportReport 20 = 138 checks, com E2E via fakes compilados pelo FPC e driver de leitura fake em memoria); **driver real de dados (ler tabelas via fbclient.dll 32-bit) adiado — decisao 9.3 pendente** (sem fbclient nesta maquina); fluxo de exportacao na UI **aguarda a UI** (dcc32) |
| F2-B, F6..F8 | Restante das engines, diagnostico na GUI, instalador etc. | Nao iniciadas |
| D7 (dcc32) | Validacao com Delphi 7 real instalado | **Feito (30103e9 + proximo)** — 18 programas de teste compilam e rodam com exit 0 no dcc32; correcoes de portabilidade D7 (aliases de array dinamico, bindings PWideChar(WideString(...)), leitura segura/limitada de registro em uFBAutoDetect). **GUI v1 funcional integrada** (uFrmMain): abre .fbk/.gbk/.fdb, auto-deteccao de bins (detectou InterBase 6.5 real do Delphi 7), restaura via gbak em worker thread com cancelar e resultado no memo; FBRecStudio.exe 0.2.0 compila e roda. Faltam: F6 (framework visual estilo macOS), exportacao/assistente completos na GUI, F7 (corpora com Firebird real) e F8 (instalador/assinatura) |
