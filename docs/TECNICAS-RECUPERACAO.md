# Tecnicas de recuperacao - auditoria e cobertura

Documento de consulta (v0.3): auditoria das tecnicas de recuperacao de
bancos Firebird/InterBase danificados frente ao que o FBRecStudio
implementa, e como a recuperacao automatica (uMotorAutoRec) escolhe e
combina tecnicas.

## 1. Universo das tecnicas conhecidas

### Para um BACKUP gbak (.fbk/.gbk) que nao restaura
| Tecnica | Ferramenta | Quando usar | Cobertura |
|---|---|---|---|
| Restore limpo (-c -v) | gbak | via normal | uMotorAutoRec T1 |
| Restore tolerante (-c -v -ig) | gbak | checksum/registro invalido | T2 (catalogo ssIgnorarChecksum) |
| Restore de outra versao/familia | gbak | engine incompativel com o formato do backup (ex.: InterBase antigo x formato 9) | diagnostico nota formato + sondagem de engine |
| Extracao de texto dos dados | uExtratorTexto | backup estruturalmente destruido | T4 (L4) |
| Regerar o backup na origem | manual | backup truncado/incompleto | orientado no relatorio (secao 5) |

### Para um BANCO (.fdb/.gdb) corrompido
| Tecnica | Ferramenta | Quando usar | Cobertura |
|---|---|---|---|
| Copia forense byte a byte | uSafeCopy | SEMPRE antes de qualquer escrita | L0 do salvage |
| Validar estrutura (-v / -v -full) | gfix | diagnostico (read-only) | L1 |
| Reparar indices/estrutura (-mend) | gfix | validacao acusou problema (somente na copia, sob guarda) | L1 (autorizado) |
| Reativar banco em shutdown (-activate) | gfix | hdr_flags de shutdown | engine gfix gaActivate |
| Sweep / housekeeping | gfix | lixo/versoes antigas | engine gfix |
| Modo somente leitura (-mode read_only) | gfix | forcar leitura estavel | engine gfix |
| Limpar transacoes limbo (-kill, FB3+) | gfix | transacoes limbo | engine gfix |
| Backup do que abre (gbak -b; com -ig se necessario) | gbak | isolar o que e legivel | L3 |
| Exportar DDL (isql -extract) | isql | estrutura para recriar | Exportar SQL (GUI) |
| Exportar dados por tabela (datapump) | driver fbclient | extracao fina pulando tabelas ruins | PENDENTE (requer driver fbclient - F5; registrado como tal) |
| Extracao de texto das paginas | uExtratorTexto | ultima barreira | L4 |

## 2. Decisao de escolha (passo 1 do fluxo automatico)

uMotorAutoRec.Executar roda primeiro o DIAGNOSTICO estatico
(uDiagFileProbe) e so entao monta o plano:

1. tipo do arquivo: backup x banco (assinatura do stream, extensao);
2. banco: ODS, page size, flags de shutdown (heuristicas, F7);
3. backup: FORMATO do stream (novo no v0.3): bytes 00 02 04 <ver>;
   ver 1..3 = legado InterBase/FB1; >= 8 = Firebird moderno. Isso
   impede o erro classico do gbak InterBase antigo
   ("Expected backup version 1,2,3. Found 9") - e a base para exigir
   o engine certo;
4. sondagem dos engines detectados (gbak -z com timeout): so entra no
   plano um engine que RESPONDE - nunca mais trava esperando um gbak
   pendurado (timeout padrao de 30 min por subprocesso quando o
   config.ini nao define outro).

## 3. Combinacao (cascata)

Backup: T1 restore limpo -> se falhar, T2 restore tolerante (-ig) ->
se falhar, T4 extrator de texto. Cada resultado e VERIFICADO: gfix -v
no banco restaurado e contagem real de tabelas/registros via isql
(relatorio com numeros, nao "sucesso" no ar).

Banco: TMotorSalvage (L0 copia -> L1 gfix validar/-mend na copia ->
L3 backup do que abre -> L4) e depois contagem via isql sobre o
artefato que abriu.

Resultado possivel: recuperacao completa / parcial (com o que sobrou,
o que falhou e por que) / nada (com orientacao do que fazer).

## 4. Lacunas conhecidas (honestas)

- L2 datapump tabela a tabela depende do driver de dados (fbclient) -
  fica registrada como "nao tentada" no relatorio, nunca como sucesso;
- bancos ODS de Firebird 4/5 exigem gbak/gfix dessas versoes (o kit
  embarcado v0.3 traz Firebird 2.5.9); a ferramenta orienta, nao faz
  downgrade;
- backup truncado (arquivo cortado) nao e reconstruivel por ferramenta:
  o relatorio orienta a regenerar na origem;
- heuristica de shutdown/FSS ainda a validar com corpus real (F7).

## 5. Caso verificado (v0.3)

dados.gbk (backup Firebird, formato 9): diagnostico -> restore limpo
-> gfix -v ok -> 283 tabelas / 23.880 registros contados -> veredito
"RECUPERACAO COMPLETA", banco + relatorio gravados em pasta
recuperacao_dados/. O mesmo fluxo foi testado com copia corrompida
(flips de byte): cascata caiu para o extrator de texto e o veredito
foi "PARCIAL" com dump de texto - nunca silencio nem trava.
