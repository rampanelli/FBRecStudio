# FBRecStudio — Estado do Desenvolvimento e Documentação

**Documento de consolidação** — reflete o estado atual do repositório
após as fases F0 a F5 e a integração de GUI (Delphi 7 real, compilado e
testado com `dcc32`; núcleo também validado com Free Pascal 3.2.2
`-Mdelphi`).

---

## 1. O que é

Utilitário **32-bit** em **Delphi 7 puro** (VCL/WinAPI) para diagnóstico,
restauração, reparo e exportação de bancos **Firebird/InterBase**
(Windows XP SP3 → Windows 11). O app **não embute** o Firebird/InterBase —
detecta e usa os utilitários instalados (`gbak`/`gfix`/`isql`).

**Executável compilado:** `bin\FBRecStudio.exe` (Delphi 7, `dcc32`).

---

## 2. Como compilar e testar

### Requisitos de build
- **Delphi 7** (`dcc32.exe` + `brcc32.exe`), ex.: `C:\Program Files (x86)\Borland\Delphi7`.
- (Opcional, validação extra) **Free Pascal 3.2.2** win32.

### GUI (app completo)
```
src\app\build.bat            rem detecta dcc32/brcc32 automaticamente
```
Saídas: `bin\FBRecStudio.exe`; DCUs intermediárias em `build\dcu`.
Ajuste `DELPHI_ROOT` no topo do `build.bat` se o Delphi estiver noutro caminho
(ou defina `FB_DCC32`).

### Testes de console (18 programas — todos passam no Delphi 7 e/ou FPC)
```
tests\build_tests.bat        rem (se existir) ou compile cada Test*.dpr:
dcc32 -Q -B -N"..\build\tdcu\Teste" -U"..\src\core;..\src\persist;..\src\firebird;..\src\diag;..\src\engines;..\src\export;..\src\fw;..\src\ui" Teste.dpr
Teste.exe                    rem exit 0 = sucesso
```
Lista: `TestCodec`, `TestQuoting`, `TestLogger`, `TestHash`(não existe; hash via
`RunCoreTests`/TestKernelExec), `TestKernelExec`, `TestSafeCopy`, `TestEngineGbak`,
`TestEngineGfix`, `TestGuardaSeguranca`, `TestSalvagePlan`, `TestExtratorTexto`,
`TestExportFbk`, `TestExportSql`, `TestExportReport`, `TestExportCsv`,
`TestFBVersion`, `TestFBAutoDetect`, `TestSwitchCatalog`, `TestDiagProbe`.
(Alguns programas agregadores citados no ROADMAP podem ter nomes ligeiramente
diferentes; confira `tests\*.dpr`.)

---

## 3. Estrutura do repositório (resumo)

```
FBRecStudio/
├─ src/
│  ├─ app/        FBRecStudio.dpr, FBRecStudio.rc, build.bat (manifesto, versão)
│  ├─ core/       uTextCodec, uQuoting, uLogger, uHash, uKernelExec
│  ├─ persist/    uAppConfig, uCredStore (DPAPI), uHistoryStore
│  ├─ firebird/   uFBVersionInfo, uFBSwitchCatalog, uFBAutoDetect
│  ├─ diag/       uDiagParser, uDiagFileProbe, uDiagReport
│  ├─ engines/    uEngineBase, uEngineGbak, uEngineGfix, uGuardaSeguranca,
│  │              uSafeCopy, uSalvagePlan, uMotorSalvage, uExtratorTexto
│  ├─ export/     uExportBase, uExportFBK, uExportSQL, uExportReport, uExportCSV
│  ├─ fw/         (reservado p/ framework visual — não utilizado ainda)
│  └─ ui/         uFrmMain (janela principal funcional)
├─ res/           manifesto, ícone, README de identidade
├─ docs/          este documento, ROADMAP-STATUS.md, ESTRUTURA.md,
│                 VALIDACAO-FPC.md, CATALOGO-SWITCHES.md
└─ tests/         Test*.dpr + corpora/ (leiautes)
```

---

## 4. Fases entregues (F0 → F5 + GUI)

| Fase | O que foi entregue | Validação |
|---|---|---|
| **F0** | Núcleo: `uTextCodec` (OEM↔ACP↔UTF-8), `uQuoting` (argv→cmdline regras CRT, `-pass` mascarado), `uLogger` (timestamps, UTF-8 BOM), `uHash` (CryptoAPI MD5/SHA-1), `uKernelExec` (pipes separados, threads, timeout, cancel/job-tree, `BuildAndRun`), `uAppConfig`, `uCredStore` (DPAPI, sem texto claro), `uHistoryStore` (CSV) | FPC + D7 |
| **F1** | `uFBAutoDetect` (registro/pastas/PATH + probe de versão), `uFBSwitchCatalog` (gbak/gfix/isql por versão; `-FIX_FSS_*` só FB 1.5–2.5/IB6; tabela ODS×versão), `uDiagParser/FileProbe/Report` (classificação fbk/gdb por heurística de header) | FPC + D7 |
| **F2-A** | `uEngineBase` (IRecoveryStep, risco/estado), `uEngineGbak` (restore/backup `-c/-r/-b/-v/-g`, chaves só via catálogo, lista negra de extras, pré-checks, parse, senha mascarada), `uSafeCopy` (cópia byte a byte com progresso/cancel) | FPC + D7 |
| **F3** | `uEngineGfix` (validar/-full/mend/activate/sweep/housekeeping/mode/kill/icu por catálogo; ordem segura), `uGuardaSeguranca` (write exige cópia + banco livre; detecção de “banco em uso” por share-mode) | FPC + D7 |
| **F4** | `uSalvagePlan` (camadas L0–L4 + relatório honesto), `uMotorSalvage` (orquestra: cópia forense → gfix → gbak do que abre → datapump **ignorado sem driver** → extrator), `uExtratorTexto` (varredura de runs de texto) | FPC + D7 |
| **F5** | `uExportBase` (contratos/formato/manifesto), `uExportFBK` (`gbak -b`), `uExportSQL` (isql -extract **captura do stdout**), `uExportReport` (relatório DDL), `uExportCSV` (RFC-4180, NULL/BLOB; driver fake testado; implementação real depende de `fbclient.dll` — decisão 9.3) | FPC + D7 |
| **GUI** | `uFrmMain`: visual reformulado (paleta §5.3, cabeçalho gradiente, botões flat), auto-deteção, **diagnóstico**, **restauração/backup** gbak em worker thread com cancelar, **histórico**, **associação `.fbk/.gbk` (HKCU)**, **exportação SQL/DDL**, **single-instance** + abertura por `ParamStr(1)`/duplo clique, persistência de usuário/último arquivo em `ui.ini` | dcc32 |

**Validação consolidada:** 18 programas de teste compilam e rodam com
**exit 0 no Delphi 7 (dcc32)**; os mesmos seguem verdes no **FPC -Mdelphi**
(unidades não-GUI). No smoke test a auto-deteção localizou um **InterBase 6.5**
real instalado junto ao Delphi 7.

---

## 5. O que a interface faz hoje (guia rápido)

1. **Abrir arquivo…** — seleciona `.fbk/.gbk/.fdb/.gdb` (ou abre por duplo
   clique/linha de comando; single-instance repassa o arquivo p/ janela ativa).
2. **Diagnosticar** — mostra tipo (backup/banco), ODS, tamanho, técnica
   recomendada e notas (`uDiagFileProbe`).
3. **Restaurar** (botão azul) — `gbak -c -v -g` em thread; exige binário
   detectado; pergunta usuário/senha; permite **Cancelar**; resultado no log.
4. **Backup (.fbk)** — `gbak -b` do banco `.fdb/.gdb` aberto.
5. **Exportar SQL** — `isql -extract` → `<base>.sql` (captura do stdout).
6. **Histórico** — mostra as últimas operações registradas em `history.csv`.
7. **Associar .fbk/.gbk** — registra associação do usuário em **HKCU** (sem UAC).

Persistência: `%APPDATA%\FBRecStudio\` — `config.ini` (defaults), `ui.ini`
(usuário/último arquivo), `credentials.bin` (DPAPI, opcional), `history.csv`,
`logs\fbrecstudio.log` (UTF-8).

---

## 6. Segurança (comportamento adotado)

- **Senha nunca é salva** em claro (DPAPI `uCredStore` disponível; a GUI atual
  pede a senha a cada operação; `-pass` aparece mascarado como `******` no
  comando exibido/logado).
- Argumentos adicionais livres passam por **lista negra** (`-pass`, `>`, `<`,
  `|`, `&`) — evita injeção/redirecionamento.
- Nenhuma unidade de negócio depende de `Forms` (testável por console).
- Operações de **escrita** em banco exigem cópia de segurança + banco fora de
  uso (`uGuardaSeguranca`) nas engines.

---

## 7. Pendente / adiado

- **Instalador (Inno Setup)** — **ADIADO** (opção mantida para depois). O app
  segue rodando “portátil” (`bin\FBRecStudio.exe`). Quando for feito:
  associação opcional, elevação correta, versão/ícone, assinatura.
- **Driver de dados real** (`fbclient.dll` 32-bit) p/ CSV/TSV por tabela e
  datapump (decisão §9.3 do PLANO). Sem ele, CSV fica validado só com driver
  fake e a exportação de dados por tabela usa `isql`/script limitado.
- **F7 — corpora/testes com Firebird real** (bancos bons/corrompidos de
  FB 1.5→5.0/IB6, roteiros XP→Win11). Necessita infra (servidores/VMs).
- **F8 — empacotamento**: instalador (adiado), assinatura de código,
  documentação de usuário final.
- **F6 visual completo**: framework `fw/uCtrl*` (sidebar/cards custom) —
  a GUI atual usa controles flat próprios já com a paleta do plano; o framework
  completo pode evoluir a partir destes (ex.: `TGradBar`/`TSwBtn` em `uFrmMain`).

---

## 8. Linha do tempo (commits)

| Commit | Conteúdo |
|---|---|
| `efbb732` | F0 — esqueleto + núcleo |
| `702b0ad` | Portabilidade/validação FPC |
| `e4c6be4` | F1 — detecção, catálogo, diagnóstico |
| `e15d605` | F2-A — engines base/gbak + safe copy |
| `4908299` | F3 — engine gfix + guarda |
| `0c0fa35` | F4 — salvage + extrator |
| `a023558` | F5 — exportação fbk/sql/csv/ddl |
| `30103e9` | Fix D7: suíte 18 testes exit 0 |
| `aa289f0` | GUI v1 funcional (restore/backup em thread) |
| `fabce7f` | GUI: diagnóstico, histórico, associação, backup |
| `fd73ed5` | GUI visual v2 (paleta, gradiente, botões flat) |
| `8c070e9` | Single-instance + duplo clique + `ui.ini` |
| `d1db1f3` | Exportação SQL/DDL na GUI |

---

## 9. Decisões em aberto (do PLANO §9, anotadas)

1. **Nome/marca** — “FBRecStudio” é nome de trabalho; validar com o cliente.
2. **Driver para CSV/datapump** — API direta `fbclient` (recomendada) vs IBX vs
   sem driver (limita CSV). Decisão adiada.
3. **Autenticação FB3+/SRP** e suporte a FB/IB “muito antigos”.
4. **Formato de config** — INI (adotado) vs JSON/XML.
5. **Single-instance** — adotado (mutex + `WM_COPYDATA`).
6. **Associação por usuário (HKCU)** — adotado como padrão (sem UAC).
7. **Instalador/assinatura** — adiado (seção 7).
8. **Tema** — claro adotado; escuro pode ser adicionado (paleta já definida).
9. **XP SP3** como requisito rígido — mantém Delphi 7/32-bit (adotado).

---

*Fim do documento.*
