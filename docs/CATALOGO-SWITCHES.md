# Catalogo de switches dos utilitarios Firebird/InterBase

Documento de apoio de **F1-T2** (`uFBSwitchCatalog.pas`). Mapeia a
**semantica** pedida pela engine/UI para a **chave real** do utilitario,
condicionado a (binario, familia, versao).

> **Status das fontes (importante):** na maquina de desenvolvimento nao
> ha bins reais (sem Firebird/InterBase instalados) e nao foi possivel
> rodar `gbak -?`/`gfix -?`/`isql -?`. A base abaixo mistura:
>
> * **confirmado no fonte** do Firebird (gbak 2.5 = tag `R2_5_9` e
>   gbak 3.0 = tag `v3.0.14`, GitHub): `src/burp/burpswi.h` e mensagens
>   de help (`msg 109` etc.) - linhas marcadas **[fonte]**
> * **documentado** em manuais Firebird/InterBase - linhas marcadas
>   **[doc]**
>
> Tudo que nao foi confirmado com bin real esta marcado **"a validar com
> bins reais"**. A validacao acontece na **F7** (probe de runtime com
> `gbak -z`/`-?`); a estrutura do catalogo e uma tabela de linhas - cada
> linha e corrigida individualmente sem tocar nas engines.

## 1. Regras gerais do catalogo

1. A engine **nunca monta a chave sozinha**: chama
   `ISwitchCatalog.ObterSwitch(bin, versao, semantica)` e recebe a chave
   real (ou `''`).
2. `''` significa **nao suportado** para (bin, versao, semantica) - ou
   versao desconhecida (decisao conservadora desta fase).
3. **Valores** que acompanham a chave (charset, `read_only`,
   `SUPPRESS`, arquivo de saida, nome de banco, `on|off` etc.) sao
   anexados pela engine conforme a semantica; o catalogo devolve so a
   chave.
4. Chaves aceitas em qualquer caixa pelos utilitarios (o catalogo
   devolve a forma curta canonica). `PA(SSWORD)` significa que tanto
   `-pa...` quanto o nome cheio sao aceitos; esta F1 emite `-pass`
   (gbak/gfix) e `-password` (isql) - **a validar**.

## 2. Regra de negocio: `-FIX_FSS_*`

Segundo o PLANO (4.2), `-FIX_FSS_METADATA`/`-FIX_FSS_DATA` so existem
no gbak da familia **1.5-2.5 e InterBase 6**; o catalogo devolve `''`
para **Firebird 3+** (regra implementada e testada em
`TestSwitchCatalog`).

> **Divergencia documentada:** o fonte do gbak v3.0.14 ainda define
> `IN_SW_BURP_FIX_FSS_METADATA`/`FIX_FSS_DATA` (msgs 302/303). Pode ser
> heranca de definicao sem exposicao na linha de comando final. A regra
> de negocio do plano e mantida nesta F1; **a F7 (bins reais) decide** -
> a correcao, se necessaria, e de uma linha na tabela.

## 3. gbak (backup/restore)

| Semantica | Chave | Vigencia | Fonte |
|---|---|---|---|
| restore criar novo | `-c` | todas (1.0+; IB4+) | [fonte] burpswi `CREATE_DATABASE` |
| restore substituir | `-r` | FB 1.0-3.0; IB | [fonte] burpswi `REPLACE_DATABASE` |
| restore substituir (FB4+) | `-recreate` (+ engine acrescenta `overwrite`) | FB 4.0+ | [doc] a validar com bins |
| backup nativo | `-b` | todas | [fonte] `BACKUP_DATABASE` |
| backup so metadados | `-m` | todas | [fonte] `META_DATA` |
| saida verbosa | `-v` | todas | [fonte] `VERBOSE` |
| inibir garbage collection | `-g` | todas | [fonte] `GARBAGE_COLLECT` |
| corrigir charset metadata | `-FIX_FSS_METADATA` | FB 1.5-2.5; IB6 | [doc] regra 4.2 (FB3+ = vazio) |
| corrigir charset dados | `-FIX_FSS_DATA` | FB 1.5-2.5; IB6 | [doc] regra 4.2 (FB3+ = vazio) |
| sem criar sombras no restore | `-k` | todas | [fonte] `KILL` |
| modo read_only do banco | `-mode` (valor `read_only`) | FB 2.5+ | [doc] a validar p/ 2.0-2.1 |
| modo read_write do banco | `-mode` (valor `read_write`) | FB 2.5+ | [doc] a validar |
| service manager | `-se` | todas | [fonte] `SERVICE` |
| usuario | `-user` | todas | [fonte] `USER` |
| senha | `-pass` | todas | [fonte] `PASSWORD` (PA...) |
| saida/erros para arquivo | `-y` + caminho | FB 1.5+ | [fonte] msg 109 burp (`Y`) |
| suprimir saida | `-y` + `SUPPRESS` | FB 1.5+ | [fonte] msg 109 + constante `output_suppress` |
| versao | `-z` | todas | [fonte] `Z` |

Observacoes:

* `-fe`/`-fo`/`-mo` (citados na especificacao da fase como exemplos
  historicos) **nao existem** no gbak Firebird: o redirecionamento de
  saida/erros e unico via `-y` (msg 109: "redirect/suppress output -
  file path or OUTPUT_SUPPRESS"). **a validar** com gbak real; se algum
  gbak antigo/IB aceitar `-fe`, a linha da tabela muda.
* IB6 e demais InterBase: assume-se o mesmo conjunto de chaves legacy
  do gbak 2.5 (a familia InterBase usa a mesma genealogia); **a validar
  com bins reais** (incl. InterBase 2007/2009).

## 4. gfix (manutencao)

| Semantica | Chave | Vigencia | Fonte |
|---|---|---|---|
| validar banco | `-v` (abrev. de `-validate`) | todas | [doc] |
| validacao completa | `-full` | todas | [doc] |
| consertar banco | `-mend` | todas | [doc] |
| reativar banco em shutdown | `-activate` | todas | [doc] |
| executar/ajustar sweep | `-sweep` | todas | [doc] |
| housekeeping ligado | `-housekeeping on` | todas | [doc] |
| housekeeping desligado | `-housekeeping off` | todas | [doc] |
| modo read_only | `-mode read_only` | todas | [doc] |
| modo read_write | `-mode read_write` | todas | [doc] |
| derrubar attachments | `-kill` | FB 3.0+ (ausente 1.5/2.x) | [doc] a validar (pode existir em 2.5) |
| ICU habilitado | `-icu on` | FB 2.5+ | [doc] a validar (pode ser so 3.0+) |
| ICU desabilitado | `-icu off` | FB 2.5+ | [doc] a validar |
| usuario | `-user` | todas | [doc] |
| senha | `-pass` | todas | [doc] |
| versao | `-z` | todas | [doc] |

Observacoes:

* gfix 2.5/3.0 usa o mesmo motor de chaves prefixado dos utilitarios
  (aceita abreviacoes e nome cheio); as chaves acima sao as curtas
  documentadas.
* `-kill` e `-icu` sao os itens de menor confianca desta F1 (nao
  confirmados em fonte nesta fase) - ver marca **a validar**.

## 5. isql (interativo/extract)

| Semantica | Chave | Vigencia | Fonte |
|---|---|---|---|
| exportar DDL/dados | `-extract` | todas | [doc] |
| charset de conexao | `-charset` + valor | todas | [doc] |
| usuario | `-user` | todas | [doc] |
| senha | `-password` | todas | [doc] a validar (`-pass`/`-p` tambem citados) |
| versao | `-z` | todas | [doc] |

## 6. Tabela ODS x versao (referencia para o diagnostico)

F1-T4 (`TVersionMinimaParaOds` / `FamiliaProvavelParaOds`). Base:
PLANO.md 4.1.2 cruzado com `ods.h` do Firebird 2.5 (tag `R2_5_9`) e
`OdsDetection.h` do Firebird 3.

| ODS | Familia provavel | Menor servidor que le | obs |
|---|---|---|---|
| 8.x | InterBase | IB 4.0 | [fonte] ods.h |
| 9.x | InterBase | IB 5.0 | [fonte] ods.h |
| 10.0 | InterBase (e Firebird 1.0) | IB 6.0 | [fonte] ods.h |
| 10.1 | Firebird | FB 1.5 | [fonte] ods.h |
| 11.0 | Firebird | FB 2.0 | [fonte] ods.h |
| 11.1 | Firebird | FB 2.1 | [fonte] ods.h |
| 11.2 | Firebird | FB 2.5 | [fonte] ods.h |
| 12.0 | Firebird | FB 3.0 | [doc] a validar |
| 13.x | Firebird | FB 4.0 (5.0 le) | [doc] a validar |

Intervalo de ODS que um servidor *abre* (usado em `TVersion.TemOds`):
heuristica conservadora desta F1 (FB 2.5 abre 10.0-11.2; FB 3 abre
11.0-12.0; etc.) - **a validar no corpus da F7**.

## 7. Pendencias para F7 (infra real)

1. Rodar `gbak -?`, `gfix -?`, `isql -?` (e `-z`) dos bins reais e
   conferir linha a linha as tabelas 3-5; corrigir as linhas marcadas
   **a validar** (uma alteracao por linha na tabela do catalogo).
2. Confirmar a divergencia `-FIX_FSS_*` no gbak 3.0+ e decidir a regra
   de negocio definitiva.
3. Confirmar `-mode` no gbak 2.0-2.1; `-kill`/`-icu` no gfix 2.5/3.0;
   senha do isql (`-password` vs `-pass`).
4. Alimentar o runtime probe (F7) para que a validacao vire automatica.