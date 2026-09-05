# Estrutura do repositório — FBRecStudio

Mapa atual do repositório. O estado por fase e as convenções de código estão em
`docs/ESTADO-DO-PROJETO.md` e `CONTRIBUTING.md`.

## Árvore

    FBRecStudio/
      .gitignore
      README.md                    Visão geral, build, convenções
      build/dcu/                   DCUs intermediárias (gerado, ignorado)
      docs/
        ESTRUTURA.md               Este arquivo
        ROADMAP-STATUS.md          Status por tarefa/roadmap
      installer/
        README.md                  Instalação (fase futura)
      res/
        README.md                  Recursos: o quê compila e quando
        IDENTIDADE.md              Paleta/identidade (PLANO 5.3)
        FBRecStudio.manifest       Manifesto win32 (comctl32 v6)
        app.rc                     Referencia F0-T7 (VERSIONINFO/icone)
        icons/                     FBRecStudio.ico (placeholder 16x16 F0)
      src/
        app/
          FBRecStudio.dpr          Programa (GUI)
          FBRecStudio.rc           Recursos da aplicação (brcc32)
          build.bat                Compilação Delphi 7
        core/                      Núcleo puro (sem Forms)
          uTextCodec.pas           Encoding (PLANO 6.5)
          uLogger.pas              Log UTF-8 com BOM (PLANO 4.x/6.8)
          uQuoting.pas             Quoting CRT + parser + máscara (6.3)
          uHash.pas                Hash MD5/SHA-1 (CryptoAPI)
          uKernelExec.pas          Execução robusta de processos (6.2)
        ui/
          uFrmMain.pas              Casca F0 (form criado em código, sem
                                    .dfm; self-test do núcleo na abertura)
        persist/
          uAppConfig.pas           Config INI ANSI (6.6)
          uCredStore.pas           Cofre DPAPI (6.6)
          uHistoryStore.pas        Histórico CSV anexo (4.6)
        diag/ firebird/ engines/ export/ fw/ thirdparty/
          (.gitkeep)               Pastas reservadas do plano 6.1
      tests/
        README.md                  Como rodar os testes
        build_tests.bat
        TestCodec.dpr, TestQuoting.dpr,
        TestLogger.dpr, TestKernelExec.dpr
        corpora/README.md          Amostras (F1+) — conteúdo ignorado

## Mapa de responsabilidades (PLANO 6.1 → código)

| Pasta do plano | Unidade F0 | Papel |
|---|---|---|
| src/core | uTextCodec | Toda conversão OEM/UTF-8/ACP |
| src/core | uLogger | Log thread-safe, UTF-8 BOM, canais app/stdout/stderr |
| src/core | uQuoting | Montagem de argv, parser de referência, mascarar -pass |
| src/core | uHash | MD5/SHA-1 (CryptoAPI) p/ histórico e integridade |
| src/core | uKernelExec | Contratos IOutputSink/IProcessRunner; pipes, threads, timeout, Job Object |
| src/ui | uFrmMain | Única unidade com Forms (regra: negócio sem UI) |
| src/persist | uAppConfig | config.ini ANSI em %APPDATA%\FBRecStudio |
| src/persist | uCredStore | credentials.bin protegido por DPAPI (nunca claro) |
| src/persist | uHistoryStore | history.csv colunas da seção 4.6 |

## Contratos principais (6.2) — implementados em uKernelExec.pas

- `TProcessOptions` (Executable, WorkDir, Args, TimeoutMs,
  KillTreeOnCancel, ConsoleCodePage[ext. F0]);
- `TProcessResult` (ExitCode, Ok, Started/Finished, Canceled, TimedOut,
  Summary, ErrorText[ext. F0]);
- `IOutputSink.OnLine(TStreamId, linha decodificada)` e
  `IOutputSink.OnProcessEvent(TProcEvent, info)`;
- `IProcessRunner.Run(...)` síncrono (rodar em worker) e `Cancel`
  (evento, seguro de qualquer thread);
- `BuildAndRun(Opt, OutLines, ErrLines)` — execução síncrona simples
  (auxiliar das engines; entrega linhas decodificadas em `TStrings`).
- `IOutputSink` implementado por `TCollectingSink` (coleta em `TStrings`).

Decisão de threading (6.8): quem executa `Run` recebe os callbacks no
próprio thread; consumidores fora do `Run` guardam estado próprio (ver
`TCollectSink` no TestKernelExec; consumo na GUI fica para a F1).

## Regras de código (todas as unidades)

- Delphi 7 puro: sem generics, sem métodos anônimos, sem TStringBuilder;
- Unidades de negócio SEM `Forms` (dependência de UI apenas em src/ui);
- Identificadores em inglês; comentários pt-BR SEM diacríticos (ASCII)
  nos fontes .pas/.rc (o .md pode usar UTF-8 com acentos);
- Sem dependência de terceiros; caminhos sempre via
  `IncludeTrailingPathDelimiter`/`ExtractFilePath` (nunca concatenação crua);
- Nenhum arquivo temporário de nome fixo;
- Comandos logados com `-pass` mascarado (uQuoting.MakeDisplayCommandLine);
- Chamadas WinAPI que o Windows.pas do D7 não declara usam wrappers com
  identificador único (`Kb*`, `Api*`, `Kc*`) + `packed record`.

## Build e execução

    src\app\build.bat [caminho\do\dcc32.exe]
    tests\build_tests.bat [caminho\do\dcc32.exe]

Dados em runtime: `%APPDATA%\FBRecStudio\` (config.ini, logs, credentials.bin,
history.csv) — veja .gitignore.
