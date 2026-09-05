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

**Versão atual:** 0.2.0 (tag `v0.2.0`).
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
- `uExtratorTexto` — varredura de "runs" de texto legível das páginas.

### Exportação (`src/export`)
- `uExportBase` — contratos de formato/manifesto/parâmetros.
- `uExportFBK` — backup nativo `.fbk`.
- `uExportSQL` — SQL/DDL via `isql -extract`, capturando o stdout (sem
  redirecionamento de shell).
- `uExportReport` — relatório legível do DDL.
- `uExportCSV` — CSV/TSV (RFC-4180, NULL, BLOB), com contrato de driver de
  leitura (implementação real pendente de driver de dados).

### Interface (GUI) (`src/ui`)
Janela principal em VCL (controles criados em código):
- Abertura por duplo clique/linha de comando; single-instance com repasse por
  `WM_COPYDATA`.
- Auto-deteção de utilitários; **Diagnosticar**; **Restaurar** e **Backup (.fbk)**
  em thread com cancelamento; **Exportar SQL**; **Histórico**; **Associar
  .fbk/.gbk** (HKCU, sem UAC).
- Visual com paleta própria, cabeçalho em gradiente e botões flat.
- **Progresso ao vivo** (barra + %) derivado do crescimento do arquivo de
  destino e **log em tempo real** no painel.
- Persistência de usuário/último arquivo em `ui.ini`.

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

- **CSV por tabela e salvage L2** (extração seletiva por driver) aguardam o
  driver de dados (`fbclient` 32-bit).
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
│  │              uSafeCopy, uSalvagePlan, uMotorSalvage, uExtratorTexto
│  ├─ export/     uExportBase, uExportFBK, uExportSQL, uExportReport, uExportCSV
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
