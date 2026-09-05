# Validacao FPC - nucleo (core + persist), firebird e diag - FBRecStudio

Data: F0 e F1, validacao real com **Free Pascal 3.2.2 (i386-win32)**.
Contexto: nao ha Delphi 7/dcc32 nesta maquina; o plano exige fonte **Delphi 7
puro**, entao o FPC roda em `-Mdelphi` apenas como compilador de validacao do
nucleo nao-GUI. **Nada aqui altera a compatibilidade com o Delphi 7** - as
correcoes usam somente sintaxe/APIs D7, com `{$IFDEF FPC}` apenas onde o FPC
diverge (ex.: inicio de thread).

## 1. Comando de compilacao (modo Delphi)

Raiz: a raiz do repositório.

```
fpc.exe (via FB_FPC/PATH) -Mdelphi ^
  -Fu..\src\core -Fu..\src\persist -FU..\build\fpc-out ^
  -o..\build\fpc-out\<Teste>.exe <Teste>.dpr
```

(executado dentro de `tests\`; `build\fpc-out` e descartavel/ignorado).

Projetos de teste compilados:

| Projeto | Unidades exercitadas |
|---|---|
| `tests\TestCodec.dpr` | uTextCodec |
| `tests\TestQuoting.dpr` | uQuoting |
| `tests\TestLogger.dpr` | uLogger, uTextCodec |
| `tests\TestKernelExec.dpr` | uKernelExec, uQuoting, uTextCodec |
| `tests\RunCoreTests.dpr` | **todas**: uTextCodec, uQuoting, uLogger, uHash, uKernelExec, uAppConfig, uCredStore, uHistoryStore |

Units compiladas diretamente pelo FPC (todas, via os .dpr acima):
`src\core\uTextCodec.pas`, `uQuoting.pas`, `uLogger.pas`, `uHash.pas`,
`uKernelExec.pas`; `src\persist\uAppConfig.pas`, `uCredStore.pas`,
`uHistoryStore.pas`.

## 2. Erros/avisos encontrados e correcoes (lista)

Correcoes **nas units** (todas mantem sintaxe D7 pura; divergencias FPC
isoladas com `{$IFDEF FPC}`):

1. **`uKernelExec.pas` - funcao dentro do bloco `type` (bug latente D7)**.
   `BuildAndRun` era declarada no meio do bloco `type` iniciado no topo; o
   FPC sinalizou "IMPLEMENTATION expected". Corrigido reabrindo o bloco com
   `type` apos a declaracao da funcao (necessario tambem no D7).
2. **`uKernelExec.pas` - `ReadFile(FPipe, @Buf[0], ...)`**: o parametro
   `lpBuffer` do Windows.pas e um `var` sem tipo (D7 **e** FPC); passar a
   expressao `@Buf[0]` nao compila. Corrigido passando o elemento `Buf[0]`
   (lvalue -> endereco) - compila em D7 e FPC.
3. **`uKernelExec.pas` - `IsPidInList(AllParents[I], Pending)`**: argumentos
   na ordem errada (lista de PIDs esperada primeiro, pid depois); o BFS de
   descendentes nunca acharia os filhos. Corrigida a ordem nas duas chamadas.
4. **`uKernelExec.pas` - `T.Resume`**: existe no D7, mas o FPC a deprecia
   (prefere `T.Start`). Isolado com `{$IFDEF FPC} T.Start {$ELSE} T.Resume
   {$ENDIF}`.
5. **`uKernelExec.pas` - `GetTickCount`**: o FPC a deprecia a favor de
   `GetTickCount64` (**Vista+**; o produto exige Windows XP). Criado binding
   proprio `KbGetTickCount` (`kernel32!GetTickCount`, padrao `Kb*` ja usado
   na unit) - sem warning no FPC, XP-safe e D7-compativel.
6. **`uKernelExec.pas` - dependencia circular `TProcessRunner` <-> 
   `TPipeReaderThread`** via *forward class* (`TProcessRunner = class;`).
   Sem dcc32 para provar aceite no D7 puro, a declaracao adiante foi
   **removida**: `TPipeReaderThread` passa a ser declarada antes e guarda o
   dono como `TObject` (convertido no `Execute`; private e visivel na mesma
   unit em D7 e FPC). Estrutura 100% D7.
7. **`uAppConfig.pas` - conversao implicita `WideString -> AnsiString`**
   (em `DefaultDestDir`): valida no D7; o FPC emite warning de perda
   potencial. Cast explicito `AnsiString(W)` apenas sob `{$IFDEF FPC}`
   (mesmo efeito: conversao via ACP).

Correcoes **nos testes** (bugs latentes da F0, nunca executados):

8. **`tests\TestCodec.dpr` - vetor cp850 errado**: `#$84` **nao** e `a` com
   til em cp850 (e `a` com trema/umlaut U+00E4); o `a` com til e `#$C6`
   (validado via `WideCharToMultiByte` real). Corrigido o byte e o
   comentario. A unit uTextCodec estava correta.
9. **`tests\TestLogger.dpr` - `GetTempPath` sem argumentos**: a API exige 2
   parametros (nao compila em D7 nem FPC). Criada funcao local `TempDir`
   (`GetTempPath(SizeOf(Buf), PChar(@Buf[0]))` + `SetString`).
10. **`tests\TestLogger.dpr` - variavel morta `First3`** (warning). Removida.
11. **`tests\TestKernelExec.dpr` - `OutLines[0]`**: no Windows real o
    `cmd /c ver` emite **linha em branco inicial** (`0D 0A`) antes do texto
    (validado com dump de bytes); a 1a linha util e a seguinte. O teste
    passou a procurar `Microsoft` em qualquer linha coletada.

Novo arquivo: **`tests\RunCoreTests.dpr`** - programa de console unico que
exercita **todas** as units core/persist (os antigos nao cobriam uHash,
uAppConfig, uCredStore e uHistoryStore). Usa pasta **temporaria unica por
execucao** em `%TEMP%` (nunca `%APPDATA%` real), DPAPI real, processos reais.

## 3. Resultado da execucao (Windows real, FPC 3.2.2 win32)

Todos os 5 executaveis retornaram **exit code 0** (96 verificacoes, 0 falhas):

| Teste | Checks | Resultado | O que testa |
|---|---|---|---|
| TestCodec | 9 | PASS | UTF-8/OEM/ACP: roundtrip ansi->utf8->ansi, cp850 deterministico, heuristica de decodificacao |
| TestQuoting | 14 | PASS | quoting CRT ida-e-volta (parser), `-pass` mascarado |
| TestLogger | 7 | PASS | arquivo em %TEMP%, BOM `EF BB BF`, linha canonica `[data][etapa][canal]`, logar sem abrir nao grava |
| TestKernelExec | 11 | PASS | `cmd /c ver` real (exit 0, coleta por sink), timeout matando a arvore (`ping`), sem cancelamento espurio |
| RunCoreTests | 55 | PASS | **todas as 8 units**: hash MD5/SHA-1 (vetores conhecidos, CryptoAPI real), `BuildAndRun` exit 0 **e** exit 7, timeout, **cancelamento real via thread** (Job Object mata a arvore), uAppConfig load/save/`EnsureDefaultValues` (nao sobrescreve), uCredStore **DPAPI real** (Save->Load roundtrip->Erase), uHistoryStore (CSV anexo, escape de `;`/aspas, contagem, hash) |

Detalhes relevantes do ambiente real:

- **DPAPI (uCredStore)**: `CryptProtectData`/`CryptUnprotectData` funcionaram
  na sessao real (save/load/erase PASS). Os dados nunca ficam em claro no
  arquivo (`credentials.bin` contem Base64 do blob cifrado).
- **uKernelExec**: `cmd /c exit 7` -> `ExitCode=7`; timeout de 1s num
  `ping -n 30` retorna em ~1s e o **cancelamento** (thread de cancelamento
  apos 400 ms) tambem retorna rapido - o **Job Object** mata cmd **e** o
  `ping` filho (nenhum processo `ping` sobrou apos os testes; wall-clock
  total do RunCoreTests ~ 2,3 s).
- **Saida do `cmd`**: no Windows atual o `ver` localizado traz `versao` em
  **UTF-8** (`C3 A3`) e uma **linha em branco inicial** - a heuristica do
  uTextCodec decodifica corretamente (prova real do fluxo 6.5 do plano).

## 4. Compatibilidades preservadas (Delphi 7 puro)

- Fonte das units/testes sem generics, metodos anonimos, `for..in`,
  `TStringBuilder` ou recursos pos-D7 (regra do plano) - compilacao
  `-Mdelphi` usou apenas o subconjunto D7.
- Bindings de API com nomes proprios (`Kb*`/`Kc*`/`Api*`) continuam isolando
  o codigo do conteudo do `Windows.pas` (D7 **nao** separa wincrypt/tlhelp32/
  shlobj/shellapi como o FPC - mas as units nao dependem disso).
- Construtores das units de persist ja aceitam caminho explicito
  (`TCredStore.Create`, `TAppConfig.Create`, `THistoryStore.Create`,
  `TLogger.Open`) -> os testes injetam pasta `%TEMP%` sem tocar `%APPDATA%`
  real, sem API nova.
- `{$IFDEF FPC}` usado somente em 3 pontos de divergencia real: inicio de
  thread (`T.Start` vs `T.Resume`), cast de WideString no uAppConfig, e nos
  testes (mesma questao de thread). Todo o restante e codigo comum D7/FPC.
- O GUI (VCL Forms, `src\app`, `src\ui`) **nao e compilado pelo FPC** (o FPC
  nao tem VCL; e LCL). Permanece intocado para o Delphi 7 real.

## 5. Saida final da compilacao

Ultima compilacao completa do RunCoreTests (todas as 8 units):

```
3433 lines compiled, 1.7 sec, 221440 bytes code, 7828 bytes data
```

Sem erros nem warnings nas 8 units e nos 5 programas de teste.

## 6. Validacao da F1 (firebird + diag) - 161 verificacoes, 0 falhas

Comando (dentro de `tests\`, mesmo espirito da secao 1):

```
fpc.exe (via FB_FPC/PATH) -Mdelphi ^
  -Fu..\src\core -Fu..\src\persist -Fu..\src\firebird -Fu..\src\diag ^
  -FU..\build\fpc-out -o..\build\fpc-out\<Teste>.exe <Teste>.dpr
```

| Projeto | Unidades exercitadas | Verificacoes |
|---|---|---|
| `tests\TestFBVersion.dpr` | uFBVersionInfo (firebird) | 29 PASS / 0 FAIL |
| `tests\TestSwitchCatalog.dpr` | uFBVersionInfo, uFBSwitchCatalog | 70 PASS / 0 FAIL |
| `tests\TestFBAutoDetect.dpr` | uFBVersionInfo, uFBSwitchCatalog, uFBAutoDetect | 19 PASS / 0 FAIL |
| `tests\TestDiagProbe.dpr` | uDiagParser, uDiagFileProbe, uDiagReport (diag) | 43 PASS / 0 FAIL |

Units novas: `src\firebird\uFBVersionInfo.pas`, `uFBSwitchCatalog.pas`,
`uFBAutoDetect.pas`; `src\diag\uDiagParser.pas`, `uDiagFileProbe.pas`,
`uDiagReport.pas`. Os testes usam somente buffers sinteticos em memoria e
diretorios fake em %TEMP% - **nenhum binario Firebird/InterBase e
executado** (nao ha servidor instalado).

Divergencias FPC resolvidas (mantendo D7 puro; bindings proprios seguindo o
padrao Api*/Kb* ja usado no repositorio):

1. `record` **nao pode ser declarado dentro de bloco `const`**
   (`TRowOds` movido para o bloco `type` de uFBSwitchCatalog - corrigia
   erro "illegal expression"; o D7 tambem reprovaria).
2. **`FindClose(TSearchRec)`** nao existe no FPC (SysUtils dele so expoe a
   versao Windows com THandle): `ColetarRaizComFilhos` do uFBAutoDetect usa
   `FindFirstFileW/FindNextFileW/FindClose` + `TWIN32FindDataW` direto.
3. **`GetFileSizeEx`** nao e seguro entre compiladores: binding proprio
   `ApiGetFileSizeEx` (kernel32) no uDiagFileProbe.
4. **`GetEnvironmentVariable`** (overload Ansi/Wide) e ambiguo no FPC:
   binding proprio `ApiGetEnvironmentVariableW` no uFBAutoDetect.
5. Conversoes Wide/Ansi implicitas (WideString de registro/valor) viram
   warning no FPC; casts explicitos `string(WideString(...))`/PWideChar,
   compativeis com D7.
6. Constantes de registro usadas como PAnsiChar/layout assumem chaves de
   registro `\0`-terminadas; documentado como heuristica **a validar com
   bins reais na F7**.

Nota: `tests\TestSwitchCatalog.dpr` emite 1 warning do FPC ("function
result variable of a managed type does not seem to be initialized" na
funcao auxiliar `Ver`) - analise de fluxo do FPC nao enxerga que
`ZerarVersion(Result)` inicializa todos os campos; o D7 nao emite esse
aviso. E so o auxiliar de teste, sem efeito nas units.
