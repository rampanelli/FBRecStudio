# FB Recovery Studio

**O estúdio de recuperação de bancos Firebird e InterBase.**
Diagnosticar → proteger → restaurar → reparar → salvar → exportar — tudo em uma
ferramenta 32-bit leve, escrita em **Delphi 7 puro** (roda de Windows XP SP3 a
Windows 11), que **usa os utilitários oficiais** Firebird/InterBase que você já
tem instalado.

---

## Sumário da apresentação

1. [O problema](#1-o-problema)
2. [A ferramenta em uma frase](#2-a-ferramenta-em-uma-frase)
3. [Pilares de capacidade](#3-pilares-de-capacidade)
4. [Capacidades em detalhe](#4-capacidades-em-detalhe)
5. [Fluxos de trabalho completos](#5-fluxos-de-trabalho-completos)
6. [Transparência: progresso e log ao vivo](#6-transparência-progresso-e-log-ao-vivo)
7. [Arquitetura técnica](#7-arquitetura-técnica)
8. [Segurança e robustez](#8-segurança-e-robustez)
9. [O que a ferramenta não faz (honestidade)](#9-o-que-a-ferramenta-não-faz-honestidade)
10. [Validação e prova](#10-validação-e-prova)
11. [Antes e depois](#11-antes-e-depois)
12. [Limitações atuais e próximos passos](#12-limitações-atuais-e-próximos-passos)
13. [Primeiros passos](#13-primeiros-passos)
14. [Perguntas frequentes](#14-perguntas-frequentes)

---

## 1. O problema

Bancos **Firebird** e **InterBase** quebram. Quando quebram:

- O **cliente para** (ou o sistema perde dias de trabalho);
- **Backups bons** podem não existir, estar velhos ou estarem **eles próprios
  corrompidos**;
- Os utilitários oficiais (`gbak`, `gfix`, `isql`) resolvem muito — mas são
  **linha de comando fria**, sem diagnóstico, sem orientação e **perigosos** se
  usados na ordem errada;
- Uma ação errada (ex.: `-mend` num banco em uso, restore por cima do único
  arquivo) **piora** o que ainda era recuperável.

O problema clássico dessas tentativas: executar um restore "às cegas" (por
cima do único arquivo), sem diagnóstico, sem progresso, sem cancelamento e com
credenciais em texto claro no Registro — cada um desses pontos é endereçado
por esta ferramenta (seções 4 e 8).

---

## 2. A ferramenta em uma frase

> **FBRecStudio** é um **guia + executor de recuperação** para bancos
> Firebird/InterBase: ele primeiro **descobre o que é o arquivo e o que há de
> errado** (diagnóstico), depois **recomenda e executa a técnica certa** com a
> versão certa do utilitário, **protegendo** o arquivo com cópias de segurança,
> mostrando **progresso e log em tempo real** — e registrando tudo num
> histórico auditável.

Sem instalar servidor, sem embutir nada, sem .NET, sem runtime moderno:
só WinAPI + os utilitários oficiais da sua instalação Firebird/InterBase.

---

## 3. Pilares de capacidade

| Pilar | Resumo | Estado |
|---|---|---|
| 🔎 **Diagnosticar** | Classifica `.fbk/.gbk/.fdb/.gdb`; lê header/ODS/página; estima técnica e risco | Implementado |
| 🛡️ **Proteger** | Cópia forense byte a byte antes de tocar em qualquer arquivo; guarda de escrita | Implementado |
| ♻️ **Restaurar** | Restore `gbak -c/-r -v -g` robusto, com destino/sobrescrever/credenciais e cancelamento | Implementado |
| 🔧 **Reparar** | Sequência segura de `gfix` (validate/-full, mend, activate, sweep, kill, housekeeping, mode, icu) por versão | Engine pronta |
| 🆘 **Salvar** | Salvage em camadas (L0→L4) para banco sem backup bom, com relatório honesto | Implementado (L0/L1/L3/L4) |
| 📤 **Exportar/Migrar** | `.fbk`, SQL/DDL (`isql -extract`), relatório DDL; CSV/TSV contratado | Implementado (CSV real aguarda driver) |
| 📊 **Acompanhar** | Progresso em % e log ao vivo durante a operação; cancelamento a qualquer momento | Implementado |
| 🧾 **Registrar/Auditar** | Histórico em CSV; logs com timestamps UTF-8; senha sempre mascarada | Implementado |
| 🖱️ **Integrar** | Duplo clique/associação `.fbk/.gbk`, single-instance, linha de comando | Implementado |

---

## 4. Capacidades em detalhe

### 4.1 Diagnóstico (antes de agir)

Ao abrir um arquivo e clicar em **Diagnosticar**, a ferramenta:

1. **Classifica o tipo** por heurística de header + extensão:
   - `Backup nativo (gbak)` — `.fbk/.gbk`;
   - `Banco Firebird/InterBase` — `.fdb/.gdb`.
2. **Lê a página de header** (banco) para extrair **ODS maior.menor**, page
   size e dialeto — e responde **qual família de servidor consegue ler** o
   arquivo (ODS 11.2 → FB 2.5; ODS 12 → FB 3; ODS 13 → FB 4/5).
3. Informa **tamanho**, estado suspeito e **técnica recomendada** (T1…T6).
4. Exibe **notas** (o que a heurística concluiu e as ressalvas).

> Exemplo de saída:
> ```
> Arquivo: NOME.FBK
> Tipo: backup nativo (gbak)
> ODS de origem: 11.2 -> Firebird 2.5   Page size: 8 KB
> Técnica recomendada: restore -c -v -g (criar novo) [+ fix_fss se aplicável]
> Notas: backup provável; validação final no restore real.
> ```

### 4.2 Proteção (nunca trabalhar no original)

- **Cópia forense** byte a byte com progresso e cancelamento (`uSafeCopy`):
  apaga o parcial se cancelar, recusa origem == destino, valida o tamanho final.
- **Guarda de segurança** (`uGuardaSeguranca`): qualquer ação que **escreve**
  no banco exige (a) cópia concluída e (b) banco **fora de uso** — a detecção de
  "banco em uso" é feita tentando abrir com modo exclusivo (share-mode 0).

### 4.3 Restauração robusta (`gbak`)

- Modos **criar novo / sobrescrever / backup**, com **pergunta de confirmação**
  e proteção de destino existente.
- Chaves **sempre** resolvidas no **catálogo de switches por versão**
  (`uFBSwitchCatalog`): ex., substituir em FB 4+ usa `-recreate overwrite` e não
  `-r`; `-FIX_FSS_METADATA` só aparece quando o binário suporta (FB 1.5–2.5/IB6).
- **Credenciais** como argumentos próprios (`-user`/`-pass` com quoting
  correto); comando exibido/logado com `-pass` mascarado (`******`).
- **Lista negra** de "argumentos adicionais" (`-pass`, `>`, `<`, `|`, `&`).
- Execução com pipes separados stdout/stderr, threads de leitura, **timeout e
  cancelamento** com kill da árvore (Job Object; fallback Toolhelp).
- Parse da saída: exit 0 + frases (`gbak: ERROR`, `Exiting before completion`,
  `finished`) — **falha parcial é detectada**, não só "exit != 0".

### 4.4 Reparo (`gfix`) — ordem segura

Cada ação é uma unidade com risco conhecido e **só é executada sob a guarda**:

1. `gfix -v` — validação **read-only** (nunca exige confirmação/cópia);
2. banco em shutdown → `gfix -activate`;
3. corrupção estrutural leve → `gfix -mend` (escreve → exige cópia);
4. limbo → `gfix -kill` (quando a versão suporta) e/ou `-sweep`;
5. fechar com `gfix -v -full` (read-only).

O catálogo omite chaves que a versão não tem (ex.: `-kill` do gfix é FB3+;
`-icu` é FB 2.5+) — a ferramenta **nunca inventa switch**.

### 4.5 Salvage — recuperação de banco corrompido **sem backup bom**

Estratégia em camadas, da menos à mais invasiva:

| Camada | Ação | Ferramenta | Estado |
|---|---|---|---|
| L0 | Cópia forense byte a byte (nunca no original) | própria (`uSafeCopy`) | ✅ |
| L1 | Anexar + validar/reparar na cópia (`gfix -v -full`/`-mend`) | `gfix` | ✅ |
| L2 | Extração **tabela a tabela** pulando as corrompidas | driver (`fbclient`) | 🔜 (aguarda driver) |
| L3 | Backup do que **abre** (`gbak -b`) + restore noutro banco | `gbak` | ✅ |
| L4 | Varredura de páginas legíveis (runs de texto) | própria (`uExtratorTexto`) | ✅ básico |

Resultado: **relatório honesto** — por camada (tentada/ok/falha/ignorada) e
resumo do que sobrou. A ferramenta nunca promete "recuperou 100%": mostra o que
foi possível e orienta para ferramentas especializadas quando a corrupção exige
engine low-level.

### 4.6 Exportação / migração

| Formato | Como | Observação |
|---|---|---|
| `.fbk` | `gbak -b -v -g` | Backup nativo íntegro |
| SQL/DDL | `isql -extract` (captura do **stdout**, sem `>` de shell) | Base p/ reconstrução/migração |
| Relatório DDL | contagem aproximada sobre o extract | Legível p/ auditoria |
| CSV/TSV | engine pronta (RFC-4180, NULL=vazio, BLOB omitir/hex/arquivo) | Requer driver real p/ leitura de dados |

### 4.7 Acompanhamento em tempo real

- **Faixa de progresso (barra + %)** atualizada a cada ~350 ms: como os
  utilitários não emitem percentual, o % é derivado do **crescimento do arquivo
  de destino** sobre o tamanho de origem — fica em 99% até a validação final
  (100% só no sucesso). Dá visão imediata se a operação "anda" ou travou.
- **Log ao vivo**: as linhas de stdout/stderr são drenadas para o painel
  enquanto a operação roda.
- **Cancelar** a qualquer momento: processo (árvore) encerrado, sem temporários
  órfãos.

### 4.8 Registro e integração

- Histórico CSV em `%APPDATA%\FBRecStudio\history.csv` (resultado, duração,
  arquivo, técnica, hash opcional, caminho do log).
- Logs UTF-8 com timestamps `[aaaa-mm-dd hh:nn:ss.zzz] [etapa] [canal]`.
- Associação `.fbk/.gbk` **por usuário** (HKCU, sem UAC); duplo clique abre o
  arquivo; single-instance repassa para a janela ativa.

---

## 5. Fluxos de trabalho completos

### História 1 — "Tenho o backup do cliente, quero devolver o banco"
```
1. Abrir NOME.FBK (ou duplo clique)     -> arquivo carregado
2. Diagnosticar                         -> "backup, ODS 11.2 (FB 2.5)"
3. Destino: NOME.FDB (criar novo)
4. Restaurar  -> confirma -> gbak -c -v -g em thread
5. Progresso ao vivo + log; ao concluir: 100% + resultado
6. (Opcional) validar: gfix -v -full no banco restaurado
```

### História 2 — "O banco está em shutdown / não abre com erro leve"
```
1. Abrir BANCO.FDB -> Diagnosticar
2. (Antes de qualquer escrita) garantir cópia -> proteção exige
3. gfix -v           -> read-only, ver o que há
4. gfix -activate    -> sair do shutdown
5. gfix -mend        -> (write; só com cópia + banco fora de uso)
6. gfix -v -full     -> revalidar
```

### História 3 — "Não tenho backup bom; o banco abre só às vezes"
```
1. Copiar forense (L0)                 -> nunca no original
2. gfix -v -full na cópia (L1)
3. gbak -b da cópia do que abre (L3)   -> restore noutro banco
4. Extrator de texto (L4) para resgatar conteúdo legível
5. Relatório: o que sobrou, camada por camada
```

### História 4 — "ODS novo (FB 4/5) e só tenho servidor antigo"
```
1. Diagnosticar -> "ODS 13 exige Firebird 4+"
2. Orientação: restaurar no servidor novo e migrar via SQL
   (sem downgrade de arquivo/backup; exportar/importar)
```

---

## 6. Transparência: progresso e log ao vivo

| Momento | O que o operador vê |
|---|---|
| Antes | Arquivo carregado + diagnóstico com técnica recomendada |
| Durante | Barra de progresso + % + linhas do utilitário chegando ao vivo |
| A qualquer momento | Botão **Cancelar** (kill da árvore, sem órfãos) |
| Fim | Resultado (sucesso/falha, exit code, mensagem), log completo e registro no histórico |

---

## 7. Arquitetura técnica

### Camadas
```
+--------------------------------------------------------------+
| src/ui    uFrmMain (VCL) - janela, progresso, botões         |
+--------------------------------------------------------------+
| src/fw    (reservado) framework visual futuro                |
+--------------------------------------------------------------+
| serviços: engines/exportação/diagnóstico (SEM Forms)         |
| src/engines   uEngineGbak | uEngineGfix | uMotorSalvage      |
|               uSafeCopy  | uGuardaSeguranca | uExtratorTexto |
| src/export    uExportFBK | uExportSQL | uExportReport | uExportCSV |
| src/diag      uDiagFileProbe | uDiagParser | uDiagReport     |
| src/firebird  uFBAutoDetect | uFBSwitchCatalog | uFBVersionInfo |
+--------------------------------------------------------------+
| núcleo + persistência (SEM Forms, testável)                  |
| src/core     uKernelExec | uQuoting | uTextCodec | uLogger | uHash |
| src/persist  uAppConfig | uCredStore (DPAPI) | uHistoryStore |
+--------------------------------------------------------------+
```

### Decisões que sustentam a qualidade
- **Catálogo de switches por (binário, versão, semântica)**: a UI/engine nunca
  monta chave por conta própria — decisão por versão, `''` = não suportado.
- **argv tipado + quoting CRT** (`uQuoting`): sem concatenação de caminhos
  crus (evita quebra de caminhos com espaços/aspas).
- **Execução robusta** (`uKernelExec`): pipes separados, threads de leitura,
  timeout, cancelamento com Job Object + fallback Toolhelp, handles fechados em
  `finally`, sem arquivo temporário de nome fixo.
- **Encoding centralizado** (`uTextCodec`): console OEM/UTF-8 → ACP; logs UTF-8.
- **Núcleo/engines sem `Forms`** → testável por console e portável.
- **Delphi 7 puro** (sem generics/anonymous/`for..in` no código comum);
  `{$IFDEF FPC}` apenas nas divergências reais (FPC valida o núcleo também).

---

## 8. Segurança e robustez

- Senha nunca em texto claro (DPAPI disponível); `-pass` mascarado no log.
- Lista negra de argumentos extras (anti-injeção/redirecionamento).
- Guarda de escrita: cópia + banco fora de uso antes de qualquer write.
- Caminhos longos (> ~230 chars) geram aviso (limite real dos utilitários).
- Técnica destrutiva nunca sem confirmação explícita.
- Sem .NET, sem runtime moderno; apenas WinAPI presente no XP SP3+.
- 32-bit; manifesto `asInvoker`; associação HKCU sem elevação.

---

## 9. O que a ferramenta não faz (honestidade)

1. **Não substitui páginas** comparando um banco bom anterior com o corrompido
   ("transplante de páginas"): as páginas Firebird carregam TIP/SCN/offsets
   válidos apenas para aquele arquivo — substituição cega **piora** o banco.
   O caminho apoiado com uma cópia boa é **reconstruir a partir dela**
   (DDL de fonte confiável → recriar → importar dados).
2. **Não faz downgrade de ODS** — arquivo/backup de ODS novo exige servidor novo
   (a ferramenta orienta e migra via SQL).
3. **CSV por tabela e salvage L2** (extração seletiva via driver) aguardam a
   decisão/implementação do driver `fbclient` (32-bit).
4. **Não roda o servidor** — usa os utilitários instalados; no XP operará com
   bins antigos e orientará o uso em máquina com servidor adequado.
5. **Sem edição de dados, sem comparação de bancos, sem plugins**.

---

## 10. Validação e prova

- **18 programas de teste** compilam e rodam com **exit 0 no Delphi 7
  (`dcc32`)**; os não-GUI seguem verdes no **Free Pascal `-Mdelphi`**.
- Cobertura: codec/quoting/logger/hash, kernel de execução (pipes, timeout,
  cancelamento com kill da árvore — testado com `cmd` + `ping` filho), cópia
  forense (byte a byte, cancelamento), engine gbak/gfix (parsing, lista negra,
  ordem segura, senha mascarada), guarda (banco travado detectado por
  share-mode), salvage (E2E com fakes compilados), exportação (fakes isql/gbak)
  e diagnóstico (buffers sintéticos ODS 11.2/12.0).
- **Smoke test real**: a auto-detecção localizou um **InterBase 6.5** instalado
  e o aplicativo roda a GUI completa sem erros.

---

## 11. Antes e depois

| Aspecto | Abordagem frágil comum | FBRecStudio |
|---|---|---|
| Fluxo | 1 ação às cegas (`gbak -r -c -v -g`) | Diagnóstico → técnica certa → validação → exportação |
| Extensão `.fbk` | Tratada como texto (casava errado) | Corrigido (classificação real do arquivo) |
| Execução | Janela bloqueada, sem timeout/cancelar | Thread + cancelamento + progresso + log ao vivo |
| Credenciais | Texto claro em Registro | DPAPI / não salvar; senha mascarada |
| Argumentos extras | Concatenados (quebrava caminhos) | argv tipado + quoting CRT + lista negra |
| Switches | Fixos p/ uma versão | Catálogo por (binário, versão) |
| Registro | Escrita sem elevação (falhava no Vista+) | HKCU por usuário, sem UAC |
| Saída | Bytes ANSI (acentos corrompidos) | Decodificação OEM/UTF-8 → log UTF-8 |

---

## 12. Limitações atuais e próximos passos

**Hoje:** GUI funcional v1 (visual com paleta, restore/backup, diagnóstico,
histórico, associação, export SQL, single-instance, progresso ao vivo).

**Próximos passos planejados:**
1. F6 — framework visual completo (`fw/uCtrl*`) e assistente em passos.
2. Expor `-FIX_FSS_METADATA` na GUI (quando o binário suportar).
3. Driver de dados `fbclient` → CSV por tabela e salvage L2.
4. Corpora de teste com Firebird real (F7).
5. Instalador (Inno Setup) + assinatura (F8) — **adiado**.

---

## 13. Primeiros passos

```bash
# Requisitos: Delphi 7 (dcc32)
src\app\build.bat          # -> bin\FBRecStudio.exe + AJUDA-MASTERDEV.md
# Testes (exit 0 = ok) — exemplo:
dcc32 -Q -B -N"..\build\tdcu\Teste" -U"..\src\core;..\src\persist;..\src\firebird;..\src\diag;..\src\engines;..\src\export;..\src\fw;..\src\ui" tests\Teste.dpr
```

1. Abra o app → a barra "Binário detectado" mostra qual Firebird/InterBase foi
   encontrado.
2. Abra um `.fbk/.gbk/.fdb/.gdb` → **Diagnosticar**.
3. Siga a técnica recomendada: **Restaurar**, **Backup (.fbk)**, **Exportar SQL**.
4. Acompanhe o progresso e o log; **Cancelar** se necessário.
5. Confira o histórico e o log em `%APPDATA%\FBRecStudio\`.

---

## 14. Perguntas frequentes

**Preciso instalar o Firebird?** Não — a ferramenta usa a instalação existente
(detecta `gbak`/`gfix`/`isql` em Registro/pastas/PATH). Para restaurar, o
servidor da versão compatível precisa estar rodando e com permissão de escrita
no destino.

**Ele roda no Windows XP?** Sim — 32-bit, Delphi 7, apenas WinAPI presente no
XP SP3. No XP operará com bins FB 1.5–2.5/IB6.

**A ferramenta salva senha?** Não em texto claro. Há opção DPAPI e a GUI pede a
senha a cada operação.

**O % mostrado é exato?** Não — é uma aproximação de andamento físico (destino
÷ origem), pois os utilitários não emitem percentual. O 100% só aparece após a
validação final com sucesso.

**Consigo recuperar comparando com um banco bom anterior?** Sim — mas da forma
**correta e segura**: usar o banco bom como fonte de DDL/metadados, recriar a
estrutura e importar os dados do corrompido. A ferramenta não faz transplante
físico de páginas (ver seção 9).

---

*Documento de apresentação — FBRecStudio. Detalhes de implementação em
`docs/ESTADO-DO-PROJETO.md` e `docs/AJUDA-MASTERDEV.md`.*
