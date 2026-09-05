# FBRecStudio — Guia de Uso Completo (Masterdev)

Manual operacional do **FB Recovery Studio** (`bin\FBRecStudio.exe`, 32-bit,
Delphi 7) para recuperação de bancos **Firebird/InterBase**. O objetivo deste
guia é que um operador avançado consiga **extrair o melhor resultado possível**
de cada situação de banco com defeito, entendendo o que a ferramenta faz, o que
não faz e por quê.

Versão do documento correspondente ao app 0.2.x. Complementos:
- Estado do projeto: `docs\ESTADO-DO-PROJETO.md`
- Apresentação da ferramenta: `docs\APRESENTACAO.md`

---

## 1. Conceitos e premissas

- A ferramenta **não embute** Firebird/InterBase: usa os utilitários instalados
  (`gbak`, `gfix`, `isql`) detectados automaticamente no Registro/pastas/PATH.
  Para restaurar um backup é preciso um servidor da versão compatível **rodando**
  e com **permissão de escrita** na pasta de destino (o processo do servidor
  escreve o arquivo — não o app).
- Arquivo 32-bit: o **servidor** pode estar em outra máquina; o app apenas orquestra
  os utilitários locais. Em Windows antigos (XP SP3) use bins FB 1.5–2.5/IB6.
- **Regra de ouro:** antes de qualquer operação de **escrita** no arquivo do banco
  (`gfix -mend`, restore `-r`, etc.), a ferramenta exige **cópia de segurança**
  e banco **fora de uso**. Nunca trabalhe sobre a única cópia existente.

---

## 2. Formas de iniciar a ferramenta

1. **Janela principal** — botões e campos descritos na seção 3.
2. **Duplo clique / linha de comando** — se o arquivo `.fbk/.gbk/.fdb/.gdb` for
   passado como argumento, ele é aberto automaticamente:
   ```
   FBRecStudio.exe "C:\dados\meu_backup.fbk"
   ```
   Com a associação `.fbk/.gbk` registrada (botão **Associar .fbk/.gbk**),
   basta dar dois cliques no arquivo.
3. **Single-instance** — abrir um segundo arquivo com o app já em execução apenas
   **repassa** o arquivo para a janela aberta (a segunda instância encerra).

---

## 3. A interface, campo a campo

| Área | O quê faz / como usar |
|---|---|
| **Abrir arquivo…** | Seleciona o alvo. Para **restaurar**: abra o **backup** `.fbk/.gbk`. Para **diagnosticar/reparar/backup/exportar**: abra o **banco** `.fdb/.gdb`. |
| **Destino (.fdb novo)** | Onde o banco restaurado será criado (padrão: mesmo nome + `.fdb`). O restore **nunca sobrescreve** um arquivo existente no modo "criar novo" — escolha outro nome ou apague o destino. |
| **Usuário / Senha** | Credenciais passadas a `gbak/gfix/isql` (`-user/-pass`). O usuário fica salvo em `ui.ini`; a **senha nunca é salva** (pedida a cada uso). |
| **Binário detectado** | Instalação de utilitários escolhida automaticamente (prioridade: primeiro `gbak` com versão válida). |
| **Diagnosticar** | Lê os primeiros KB do arquivo e responde: tipo (backup/banco), ODS (maior.menor), tamanho, técnica recomendada e notas. **Sempre diagnostique antes de agir.** |
| **Restaurar** (azul) | Restore `gbak -c -v -g` do backup aberto para o destino. Pergunta e executa em thread com **cancelamento** e **progresso ao vivo** (seção 6). |
| **Backup (.fbk)** | `gbak -b -v -g` do **banco** aberto → `.fbk` (produz uma cópia nativa íntegra; útil antes de mexer no banco). |
| **Exportar SQL** | `isql -extract` do **banco** aberto → `<base>.sql` (DDL [+ dados, conforme a versão]). É a porta de entrada para reconstruções e migrações. |
| **Histórico** | Mostra as últimas operações gravadas em `%APPDATA%\FBRecStudio\history.csv`. |
| **Associar .fbk/.gbk** | Registra a associação **por usuário** em HKCU (sem UAC). |
| **Ajuda** | Abre este guia. |
| **Cancelar** | Encerra o processo em andamento (mata a árvore do utilitário) — seguro a qualquer momento. |

---

## 4. Diagnóstico: como ler o resultado

Ao abrir um arquivo e clicar em **Diagnosticar**, o app informa:

- **Tipo** — `Backup nativo (gbak)` vs `Banco Firebird/InterBase`. Classificação
  por heurística de header + extensão; na dúvida, a prova final é o teste real.
- **ODS x.y** — ex.: ODS 11.2 ⇒ Firebird 2.5; ODS 12 ⇒ FB 3; ODS 13 ⇒ FB 4/5.
  Use a tabela abaixo para decidir qual servidor/utilitário consegue **ler** o arquivo.
- **Técnica recomendada** — heurística que aponta o caminho (restore, validação,
  reconstrução, orientação de servidor, etc.).

| ODS | Família provável | Observação |
|---|---|---|
| 8–9 | InterBase 4/5 | Utilitários antigos |
| 10.0 | InterBase 6 / Firebird 1.0 | Mesma ODS |
| 10.1 | Firebird 1.5 | |
| 11.0 / 11.1 | Firebird 2.0 / 2.1 | |
| 11.2 | Firebird 2.5 | Última que roda no XP |
| 12.x | Firebird 3.0 | |
| 13.x | Firebird 4.0/5.0 | Confirmar menor |

> Heurísticas: valide sempre com o servidor real. Não há **downgrade** direto de
> ODS; arquivo de ODS novo **exige** servidor novo (restaure lá e migre via SQL).

---

## 5. Decisão: qual ação usar (guia por sintoma)

### 5.1 Você tem um backup `.fbk/.gbk` (bom ou suspeito)
- **Objetivo:** reconstruir o banco.
- **Ação:** abrir o backup → **Diagnosticar** → **Restaurar** (criar novo).
- Dicas de melhor resultado:
  - Antes, **Backup (.fbk)** do banco atual (se existir) para não perder nada.
  - Prefira **criar novo** (`-c`) e depois validar; só use sobrescrever com o
    arquivo antigo já resguardado.
  - Se o banco restaurado apresentar charset de metadados errado (FSS), o caminho
    correto é restore com **`-FIX_FSS_METADATA <charset>`** — suportado pelas
    engines **apenas** quando o utilitário é da série FB 1.5–2.5/IB6. A GUI v1
    não expõe essa opção; para esses casos use os utilitários diretamente
    seguindo o mesmo comando (veja `docs\CATALOGO-SWITCHES.md`).
- **Validação final:** rode `gfix -v -full` no banco restaurado (via utilitários;
  a validação read-only também é suportada pela engine gfix).

### 5.2 O banco existe mas "não abre", está em shutdown ou com erro leve
- Ordem segura (sempre com cópia; a guarda exige isso para escrita):
  1. `gfix -v` (read-only) — diagnóstico;
  2. banco em shutdown → `gfix -activate`;
  3. corrupção estrutural leve → `gfix -mend` (escreve);
  4. transações em limbo → `gfix -kill` (FB3+) e/ou `-sweep`;
  5. revalidar com `gfix -v -full`.
- A engine `uEngineGfix` implementa cada ação com o **catálogo de switches por
  versão** (nada de chave "chutada") e a **guarda** (write exige cópia + banco
  fora de uso). A sequência completa na GUI fica na evolução F6; hoje as ações
  individuais estão prontas nas units e nos testes.

### 5.3 Banco corrompido **sem** backup bom (salvage)
- Fluxo em camadas (a ferramenta implementa L0/L1/L3 + L4-básico):
  - **L0** cópia forense byte a byte (`uSafeCopy`) — sempre antes de qualquer coisa;
  - **L1** validar/reparar com gfix na cópia;
  - **L3** `gbak -b` do que **abre** → restore em outro banco (isola a corrupção);
  - **L4** extrator de "runs" de texto legível das páginas (`uExtratorTexto`) —
    útil para resgatar texto quando nada mais abre; resultado honesto do que sobrou;
  - **L2** extração tabela a tabela pulando as corrompidas: **requer driver de
    dados (`fbclient`)**, adiado (decisão §9.3); hoje o caminho é via `isql`.
- **Não faz (e por quê):** substituição física de páginas comparando um banco
  bom anterior com o corrompido — inviável/arriscada sem engine low-level por ODS
  (páginas têm referências de TIP/SCN/offsets válidas só para aquele arquivo).
  O caminho suportado com uma cópia boa é **reconstruir a partir dela**
  (extrair DDL → recriar → importar dados), não transplantar páginas.

### 5.4 ODS mais novo que o servidor instalado
- **Ação da ferramenta:** orientação (diagnóstico) — instale/aponte para o
  servidor compatível ou faça a migração na máquina com o servidor correto e
  exporte/importe via SQL. Não há downgrade de arquivo/backup.

### 5.5 Exportações (banco recuperado → formatos)
- **`.fbk`** — `Backup (.fbk)` (gbak -b) ⇒ nativo, íntegro;
- **SQL** — `Exportar SQL` (`isql -extract`) ⇒ estrutura [+dados], base para
  reconstrução/migração;
- **CSV/TSV por tabela** — pronto na engine (`uExportCSV`, RFC-4180, NULL/BLOB)
  e validado com driver de teste; a implementação real depende da decisão do
  driver `fbclient` (adiado);
- **Relatório DDL** — disponível na engine (`uExportReport`).

---

## 6. Progresso em tempo real (como ler)

A faixa **"Progresso: xx%"** acima do log mostra o andamento **durante** a
operação e o log exibe as linhas do utilitário **ao vivo**:

- **Como o % é calculado:** como `gbak`/`gfix`/`isql` não emitem percentual, o app
  acompanha o **crescimento do arquivo de destino** em relação ao **tamanho de
  origem** (ex.: no restore, `.fdb` crescendo sobre o tamanho do `.fbk`). É uma
  **aproximação visual**: o valor fica limitado a 99% até a operação terminar e
  a validação ser concluída (o "100%" só aparece ao concluir com sucesso).
- Para restores grandes o progresso é útil para saber se a operação "anda" ou
  travou; combine com o log ao vivo e use **Cancelar** se necessário.
- **Cancelamento:** a qualquer momento; o processo (árvore) é encerrado e o
  estado fica consistente (sem arquivos temporários de nome fixo).

---

## 7. Onde ficam os dados gerados

`%APPDATA%\FBRecStudio\`
- `config.ini` — defaults da aplicação (pasta destino, charset, tema, …);
- `ui.ini` — usuário e último arquivo da interface;
- `credentials.bin` — (opcional) credenciais criptografadas via **DPAPI** — nunca
  em claro;
- `history.csv` — histórico de operações;
- `logs\fbrecstudio.log` — log estruturado UTF-8 com timestamps (comandos com
  senha mascarada como `******`).

---

## 8. Limites e comportamento de segurança (resumo)

- Senha nunca persistida em claro; `-pass` mascarado em logs/comando exibido.
- Argumentos adicionais livres bloqueados por lista negra (`-pass`, `>`, `<`, `|`, `&`).
- Escrita em banco exige cópia + banco fora de uso (`uGuardaSeguranca`).
- Caminhos > ~230 caracteres geram aviso (limite dos utilitários FB/MAX_PATH).
- Técnica destrutiva nunca é aplicada sem confirmação explícita.
- Nenhuma unidade de negócio depende de `Forms`; a GUI só orquestra services.

---

## 9. Extensões esperadas (para o que procurar nas próximas versões)

- Framework visual completo F6 (`fw/uCtrl*`) e assistente em passos;
- Opção `-FIX_FSS_METADATA` exposta na GUI (quando o binário suportar);
- Driver de dados `fbclient` (CSV por tabela e salvage L2);
- Instalador (Inno Setup) — **adiado**;
- Corpora de teste com Firebird real (F7) e empacotamento/assinatura (F8).

---

*Fim do guia.*
