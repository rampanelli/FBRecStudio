# Changelog

Todas as mudanças relevantes do FBRecStudio são registradas aqui.

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
Versionamento segue [SemVer](https://semver.org/lang/pt-BR/) (o app ainda está
em 0.x — API não estável).

## [0.2.0] — 2026-09

Aplicação funcional integrada (Delphi 7 real, `dcc32`). A GUI deixa de ser
apenas casca e passa a executar recuperações de verdade.

### Adicionado
- **Núcleo (F0)** validado nos dois compiladores: `uTextCodec`, `uQuoting`,
  `uLogger`, `uHash`, `uKernelExec` (pipes separados, threads, timeout, cancel
  com Job Object, `BuildAndRun`), `uAppConfig`, `uCredStore` (DPAPI),
  `uHistoryStore`.
- **F1** — auto-detecção de bins (`uFBAutoDetect`), catálogo de switches por
  versão (`uFBSwitchCatalog`), diagnóstico de arquivo (`uDiagFileProbe`).
- **F2-A** — engines base/restore gbak (`uEngineGbak`) e cópia forense
  (`uSafeCopy`).
- **F3** — engine gfix + guarda de segurança (escrita exige cópia e banco fora
  de uso; detecção de "banco em uso").
- **F4** — salvage em camadas (`uSalvagePlan`/`uMotorSalvage`) e extrator de
  texto das páginas (`uExtratorTexto`).
- **F5** — exportação FBK/SQL/DDL/CSV (`uExportFBK`, `uExportSQL`,
  `uExportReport`, `uExportCSV` com contrato de driver).
- **GUI funcional** — janela com paleta e controles flat; diagnóstico real;
  restauração/backup em worker thread com cancelamento; histórico; associação
  `.fbk/.gbk` (HKCU); exportação SQL/DDL; single-instance + duplo clique/
  `ParamStr(1)`; persistência de usuário em `ui.ini`; **progresso e log ao
  vivo**; botão Ajuda.
- **Validação**: 18 programas de teste compilam e rodam com exit 0 no
  `dcc32`; os não-GUI seguem verdes no FPC `-Mdelphi`.

### Corrigido
- Compatibilidade Delphi 7 real (dcc32): aliases de arrays dinâmicos, bindings
  `PWideChar(WideString(...))`, leitura segura/limitada da enumeração de
  registro (`uFBAutoDetect`), `DeleteFile`/`GetTempDir` nos testes.
- `build.bat` sem blocos parentizados (robustez do `cmd`).

### Alterado
- Nome/versão interna: `FBRecStudio.exe` 0.2.0.
- Docs consolidados (`docs/ESTADO-DO-PROJETO.md`, `docs/AJUDA-MASTERDEV.md`).

## [0.1.0] — 2026 (F0)

- Esqueleto do app (manifesto, versão, `build.bat`) e núcleo testável;
  GUI apenas com auto-teste. (Histórico de commits `efbb732`–`702b0ad`.)

## [Não publicado]

- F6 completo (framework visual, assistente, telas ricas), driver de dados
  `fbclient` (CSV/salvage L2), corpora com Firebird real (F7) e instalador/
  assinatura (F8 — adiado).
