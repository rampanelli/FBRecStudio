# FBRecStudio — Progresso e Estado do Projeto

**Documento de consulta** — registra o progresso até aqui e o estado atual do
repositório, para consultas futuras. Complementos:
- Apresentação: `docs/APRESENTACAO.md`
- Guia de uso completo: `docs/AJUDA-MASTERDEV.md`
- Estrutura: `docs/ESTRUTURA.md`

---

## 1. Resumo

**FBRecStudio** é um estúdio de recuperação de bancos **Firebird/InterBase** —
aplicativo 32-bit em **Delphi 7 puro** (VCL + WinAPI disponível no Windows
XP SP3 → Windows 11). Ele usa os utilitários oficiais instalados
(`gbak`, `gfix`, `isql`) — não embute servidor nem dependências externas.

**Versão atual:** 0.3.0 (desenvolvimento; a tag `v0.2.0` marca a v1 funcional).
**Estado:** recuperação automática completa (restore, copia forense + gfix,
salvage, **datapump L2 com driver real** e **reconstrução L2b**) com relatório
em 5 seções e GUI funcional.
**Repositório:** histórico único e neutro (um commit inicial); a release contém
somente código-fonte e documentação (sem binário).

---

## 2. O que já está pronto

### Núcleo e persistência (`src/core`, `src/persist`)
- `uTextCodec` — conversão OEM ↔ ACP ↔ UTF-8 e heurística de detecção UTF-8.
- `uQuoting` — serialização argv → linha de comando pelas regras do CRT
  (aspas/escape), com máscara de `-pass` para exibição/log.
- `uLogger` — log estruturado com timestamps, em UTF-8 (BOM).
- `uHash` — MD5/SHA-1 via CryptoAPI.
- `uKernelExec` — execução robusta: pipes separados stdout/stderr, threads de
  leitura, timeout, cancelamento com kill da árvore (Job Object + Toolhelp),
  `BuildAndRun`; sem arquivos temporários de nome fixo.
- `uAppConfig` — INI em `%APPDATA%\FBRecStudio\config.ini`.
- `uCredStore` — credenciais via DPAPI (nunca em texto claro).
- `uHistoryStore` — histórico CSV das operações.

### Detecção e diagnóstico (`src/firebird`, `src/diag`)
- `uFBAutoDetect` — localiza instalações Firebird/InterBase (Registro, serviços,
  pastas padrão, PATH) e identifica `gbak/gfix/isql` com a versão.
- `uFBSwitchCatalog` — catálogo de switches por (binário, versão, semântica);
  tabela ODS × versão.
- `uDiagParser/uDiagFileProbe/uDiagReport` — classificação de `.fbk/.gbk`
  (backup) × `.fdb/.gdb` (banco), leitura do header/ODS e recomendação de
  técnica.

### Engines de recuperação (`src/engines`)
- `uEngineBase` — contrato de passos (descrição, ambiente, args, execução),
  risco e estado.
- `uEngineGbak` — restore/backup `gbak` (`-c/-r/-b/-v/-g`), chaves via catálogo,
  lista negra de extras, pré-checks e parse da saída (falha parcial detectada).
- `uSafeCopy` — cópia forense byte a byte com progresso e cancelamento.
- `uEngineGfix` — validação/reparo por versão e ordem segura (validate/-full,
  mend, activate, sweep, housekeeping, mode, kill, icu).
- `uGuardaSeguranca` — regra de escrita: exige cópia de segurança e banco fora
  de uso (deteção por modo exclusivo).
- `uSalvagePlan/uMotorSalvage` — orquestração em camadas (L0 cópia → L1
  validação/reparo → L3 backup do que abre → L4 extrator) com relatório.
- `uMotorAutoRec` — recuperação automática de ponta a ponta: diagnóstico →
  escolha → combinação em cascata (T1/T2/T4 para backup; L0-L4 para banco),
  **datapump L2 tabela a tabela via `uDriverFBClient`** (CSV pulando as
  corrompidas) e **reconstrução L2b** (DDL `isql -extract` + INSERTs em banco
  novo); relatório em 5 seções com veredito e orientação do que faltou.
- `uExtratorTexto` — varredura de "runs" de texto legível das páginas.

### Exportação (`src/export`)
- `uExportBase` — contratos de formato/manifesto/parâmetros.
- `uExportFBK` — backup nativo `.fbk`.
- `uExportSQL` — SQL/DDL via `isql -extract`, capturando o stdout (sem
  redirecionamento de shell).
- `uExportReport` — relatório legível do DDL.
- `uExportCSV` — CSV/TSV (RFC-4180, NULL, BLOB), com contrato de driver de
  leitura (implementação real via `uDriverFBClient`).
- `uDriverFBClient` — driver real de leitura via `fbclient.dll` 32-bit
  (Firebird 2.5 embarcado; `LOAD_WITH_ALTERED_SEARCH_PATH`); base do datapump
  L2 e da exportação por tabela.

### GUI funcional (v1) e recuperação automática (v0.3)
Janela principal em VCL (controles criados em código):
- Abertura por duplo clique/linha de comando; single-instance com repasse por
  `WM_COPYDATA`.
- Auto-deteção de utilitários (inclui a pasta portátil `bin\ferramentas`);
  **Diagnosticar**; **Recuperar** (automático: diagnóstico → escolha → técnicas
  combinadas → validação → relatório com Problema/Solução/Recuperado);
  **Backup (.fbk)** e **Exportar SQL** em thread com cancelamento; **Histórico**;
  **Associar .fbk/.gbk** (HKCU, sem UAC).
- Visual com paleta própria, cabeçalho em gradiente e botões flat.
- **Progresso ao vivo** (barra + %) derivado do crescimento do arquivo de
  destino e **log em tempo real** no painel (janela deslizante, últimas 100
  linhas); **contador de tempo** por etapa e total; botão **Copiar relatório**.
- **Relatório de recuperação** em 5 seções, cada informação uma única vez,
  salvo em `recuperacao\relatorio_recuperacao.txt` ao lado da origem.
- Timeout padrão de 30 min por subprocesso (sem mais espera infinita).
- Persistência de usuário/último arquivo em `ui.ini` + **lembrete de sessão**
  (última origem/destino/tipo reaberta realmente ao abrir) e credenciais
  por tipo no cofre DPAPI.

---

## 3. Validação

- **Testes de console** (`tests\*.dpr`): 18 programas que **compilam e rodam com
  exit 0 no Delphi 7** (`dcc32`). Cobertura: codec/quoting/logger/hash, execução
  de processos (pipes, timeout, cancelamento), cópia segura, engines gbak/gfix,
  guarda de segurança, salvage, exportação e diagnóstico.
- **Núcleo (não-GUI)** também validado com **Free Pascal 3.2.2** em modo Delphi
  (`-Mdelphi`), garantindo portabilidade do código comum.
- Smoke test da GUI: abre sem erros e detecta os utilitários instalados.

---

## 4. Comportamento e segurança

- Senha nunca em texto claro; DPAPI disponível; `-pass` mascarado no log.
- Lista negra de argumentos extras (`-pass`, `>`, `<`, `|`, `&`).
- Escrita em banco exige cópia + banco fora de uso.
- Caminhos longos (> ~230 chars) geram aviso.
- Operações destrutivas exigem confirmação explícita.
- Sem .NET/runtime moderno; apenas WinAPI presente no XP SP3+.

---

## 5. Limites conhecidos / pendências

- **Datapump L2/L2b entregues** com driver real; falta a exportação CSV por
  tabela como fluxo autônomo na GUI (hoje o L2 roda dentro da recuperação
  automática).
- **Instalador/empacotamento**: ainda não implementado (app roda "portátil").
- **Testes com Firebird real** (corpora de bancos bons/corrompidos) — requer
  servidores/ambientes de teste.
- Não faz downgrade de ODS; arquivos de ODS novo exigem servidor compatível
  (a ferramenta orienta e suporta migração via SQL).
- Não substitui páginas comparando um banco anterior com o corrompido (caminho
  recomendado: reconstruir estrutura + importar dados).

---

## 6. Como compilar, testar e executar

### Requisitos
- **Delphi 7** (`dcc32.exe` + `brcc32.exe`).
- (Opcional) **Free Pascal 3.2.2** para a validação adicional do núcleo.

### Build do app
```
src\app\build.bat
```
Saída: `bin\FBRecStudio.exe` e `bin\AJUDA-MASTERDEV.md`.
O script localiza o `dcc32` automaticamente (argumento → `FB_DCC32` →
`DELPHI_ROOT` → caminhos comuns).

### Testes
```
# exemplo com um programa de teste (exit 0 = ok):
dcc32 -Q -B -N"..\build\tdcu\Teste" -U"..\src\core;..\src\persist;..\src\firebird;..\src\diag;..\src\engines;..\src\export;..\src\fw;..\src\ui" tests\Teste.dpr
tests\Teste.exe
```

### Execução
```
bin\FBRecStudio.exe ["arquivo.fbk/.gbk/.fdb/.gdb"]
```

---

## 7. Estrutura do repositório

```
FBRecStudio/
├─ src/
│  ├─ app/        FBRecStudio.dpr, FBRecStudio.rc, build.bat
│  ├─ core/       uTextCodec, uQuoting, uLogger, uHash, uKernelExec
│  ├─ persist/    uAppConfig, uCredStore, uHistoryStore
│  ├─ firebird/   uFBVersionInfo, uFBSwitchCatalog, uFBAutoDetect
│  ├─ diag/       uDiagParser, uDiagFileProbe, uDiagReport
│  ├─ engines/    uEngineBase, uEngineGbak, uEngineGfix, uGuardaSeguranca,
│  │              uSafeCopy, uSalvagePlan, uMotorSalvage, uMotorAutoRec,
│  │              uExtratorTexto
│  ├─ export/     uExportBase, uExportFBK, uExportSQL, uExportReport,
│  │              uExportCSV, uDriverFBClient
│  ├─ fw/         (reservado)
│  └─ ui/         uFrmMain
├─ res/           manifesto, ícone, identidade
├─ docs/          apresentação, guia, estado, estrutura, catálogo de switches
└─ tests/         Test*.dpr + corpora/
```

---

## 8. Como este documento deve ser mantido

Ao evoluir o projeto, atualize este arquivo nos pontos afetados: seção 2
(pronto), seção 3 (validação), seção 5 (pendências) e, se mudar o comportamento
visível, também `docs/AJUDA-MASTERDEV.md` e `docs/APRESENTACAO.md`.
