# FB Recovery Studio (FBRecStudio)

> Estúdio de recuperação de bancos **Firebird** e **InterBase** — aplicativo
> **32-bit** em **Delphi 7 puro** (RTL/VCL + WinAPI disponível no Windows XP SP3).

Ferramenta para **diagnosticar, restaurar, reparar e exportar** bancos Firebird e
InterBase. O app **não embute** o servidor: detecta e usa os utilitários
instalados (`gbak`, `gfix`, `isql`), funcionando de Windows XP SP3 a Windows 11.

[Documentação](#documentação) · [Como compilar](#como-compilar) ·
[Guia de uso](#guia-de-uso) · [Estado do projeto](#estado-do-projeto) ·
[Licença](#licença)

---

## Funcionalidades

- **Diagnóstico** de `.fbk/.gbk/.fdb/.gdb`: tipo, ODS×versão, tamanho, estado,
  técnica recomendada e notas (heurística de header; sempre confirmar com o
  servidor real).
- **Restauração** de backups via `gbak -c/-r -v -g` em thread, com
  **cancelamento**, **log ao vivo** e **progresso em tempo real**.
- **Recuperação automática**: diagnóstico → escolha → combinação em cascata
  (restore limpo/tolerante, copia forense + `gfix`, salvage) → validação real
  (contagem via `isql`) → **relatório em 5 seções** salvo em
  `recuperacao\relatorio_recuperacao.txt`.
- **Datapump L2** tabela a tabela via `fbclient` (`uDriverFBClient`) — exporta
  cada tabela para CSV pulando as corrompidas — e **reconstrução L2b** de um
  banco novo a partir desses dados (DDL `isql -extract` + INSERTs).
- **Backup nativo** `.fbk` de um banco (`gbak -b`).
- **Reparo/validação** estilo `gfix` (validate/-full, mend, activate, sweep,
  housekeeping, mode, kill, icu) com **guarda de segurança** (escrita exige
  cópia + banco fora de uso).
- **Salvage** em camadas (L0 cópia forense → validação → backup do que abre →
  extrator de texto das páginas) com relatório honesto do que sobrou.
- **Exportação** SQL/DDL via `isql -extract` (captura do stdout, sem
  redirecionamento de shell); CSV/TSV na engine (RFC-4180, NULL/BLOB) com
  driver real `uDriverFBClient` já ligado no datapump L2.
- **Histórico** de operações em CSV; **associação `.fbk/.gbk`** por usuário
  (HKCU, sem UAC); **single-instance** com repasse por `WM_COPYDATA` e abertura
  por duplo clique / linha de comando.
- **Segurança**: senha nunca em claro (DPAPI disponível), `-pass` mascarado no
  log, lista negra de argumentos extras, catálogo de switches por versão
  (nunca monta chave "chutada").

## Visão geral da interface

Cabeçalho em gradiente com a paleta do produto (`docs/`), cartão de ações
(Abrir/Diagnosticar/Restaurar/Backup/Exportar SQL/Histórico/Associar/Ajuda),
faixa de **progresso da operação** e painel de log ao vivo.

## Como compilar

### Requisitos
- **Delphi 7** (`dcc32.exe` + `brcc32.exe`), ex.:
  `C:\Program Files (x86)\Borland\Delphi7`.
- (Opcional) **Free Pascal 3.2.2** win32 para a validação adicional do núcleo.

### App completo (GUI)
```
src\app\build.bat
```
O script localiza `dcc32` automaticamente (argumento → `FB_DCC32` →
`DELPHI_ROOT` → caminhos comuns). Saída: `bin\FBRecStudio.exe` (e
`bin\AJUDA-MASTERDEV.md`). DCUs intermediárias em `build\` (ignoradas).

### Testes de console (18 programas; exit 0 = ok)
```
# com Delphi 7:
dcc32 -Q -B -N"..\build\tdcu\Teste" -U"..\src\core;..\src\persist;..\src\firebird;..\src\diag;..\src\engines;..\src\export;..\src\fw;..\src\ui" tests\Teste.dpr
# com Free Pascal (núcleo):
fpc -Mdelphi tests\Teste.dpr
```
Todos os testes compilam e passam no **Delphi 7 (dcc32)**; os não-GUI seguem
verdes no **FPC `-Mdelphi`**.

## Guia de uso

Um manual operacional completo para extrair o melhor de cada situação está em
[`docs/AJUDA-MASTERDEV.md`](docs/AJUDA-MASTERDEV.md) — fluxos por sintoma
(backup, banco em shutdown/corrompido, sem backup, ODS novo), leitura do
diagnóstico, limites e boas práticas. O botão **Ajuda** na interface abre o
mesmo arquivo.

## Documentação

| Documento | Conteúdo |
|---|---|
| [`docs/ESTADO-DO-PROJETO.md`](docs/ESTADO-DO-PROJETO.md) | Estado consolidado (fases, validação, pendências) |
| [`docs/AJUDA-MASTERDEV.md`](docs/AJUDA-MASTERDEV.md) | Guia de uso completo |
| [`docs/ROADMAP-STATUS.md`](docs/ROADMAP-STATUS.md) | Acompanhamento por tarefa (F0–F8) |
| [`docs/ESTRUTURA.md`](docs/ESTRUTURA.md) | Estrutura e convenções |
| [`docs/CATALOGO-SWITCHES.md`](docs/CATALOGO-SWITCHES.md) | Catálogo de switches por binário/versão |
| [`docs/VALIDACAO-FPC.md`](docs/VALIDACAO-FPC.md) | Validação do núcleo com Free Pascal |

## Estado do projeto

| Fase | Situação |
|---|---|
| Núcleo F0 + persistência | Concluído e testado (D7 + FPC) |
| F1 Detecção/catálogo/diagnóstico | Concluído e testado |
| F2–F5 Engines (gbak, gfix, salvage, export) | Concluído e testado |
| GUI funcional v1 | Concluído (visual, restore/backup, diag, histórico, export SQL, associação, single-instance, progresso ao vivo, recuperação automática com relatório em 5 seções) |
| F6 visual completo / CSV avulso na GUI / F7 corpora / F8 instalador | Pendente (ver docs) |

## Convenções de código

- Identificadores em inglês; comentários em pt-BR **sem diacríticos (ASCII)**,
  pois o Delphi 7 lê fontes ANSI (ver `docs/ESTRUTURA.md`).
- Núcleo/engines **sem dependência de `Forms`** (testáveis por console).
- Delphi 7 puro: sem generics/anonymous/`for..in` no código comum; `{$IFDEF FPC}`
  apenas nas divergências reais.
- Consulte [`CONTRIBUTING.md`](CONTRIBUTING.md) antes de contribuir.

## Licença

Distribuído sob a [Licença MIT](LICENSE).
