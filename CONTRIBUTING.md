# Contribuindo com o FBRecStudio

Obrigado por contribuir! Antes de abrir uma *issue* ou um *pull request*, leia
este guia e a documentação do projeto.

## Código de conduta

Seja respeitoso e construtivo. Este projeto adota um ambiente aberto e cordial;
comportamento abusivo não é tolerado.

## Como reportar problemas

Use o rastreador de *issues* e inclua:

- Versão do app (veja o log em `%APPDATA%\FBRecStudio\logs\fbrecstudio.log` e o
  arquivo `bin\FBRecStudio.exe` usado).
- Passos para reproduzir (arquivo de entrada, tipo `.fbk/.gbk/.fdb/.gdb`,
  versão do Firebird/InterBase e do utilitário detectado).
- Resultado esperado × obtido; mensagens de erro; trecho do log (remova
  qualquer senha antes de publicar).
- Sistema operacional e DPI, se relevante.

## Pedidos de melhoria / bugs de comportamento

Antes de implementar, abra uma *issue* descrevendo o cenário e o comportamento
desejado. Para alterações de recuperação de banco (que podem **escrever** em
arquivos), a proposta precisa explicar o risco e como será testada.

## Ambiente de desenvolvimento

- **Delphi 7** (necessário para a GUI e para os 18 testes de console com exit 0).
- **Free Pascal 3.2.2** (`-Mdelphi`) para validação adicional do núcleo
  não-GUI. Não é obrigatório para contribuições de GUI.
- Não há dependências de terceiros no código comum.

### Compilar e testar

```
src\app\build.bat          # app completo -> bin\FBRecStudio.exe
# testes (exemplo com um teste):
dcc32 -Q -B -N"..\build\tdcu\Teste" -U"..\src\core;..\src\persist;..\src\firebird;..\src\diag;..\src\engines;..\src\export;..\src\fw;..\src\ui" tests\Teste.dpr
```

Regra: sua alteração deve manter os testes existentes verdes e, se possível,
adicionar um teste console (PASS/FAIL, `Halt(falhas)`, exit code 0).

## Convenções de código (importante)

- **Identificadores em inglês**; **comentários em pt-BR sem diacríticos**
  (ASCII puro) — o Delphi 7 lê fontes ANSI e o repositório é UTF-8.
- **Delphi 7 puro** no código comum: sem generics, sem anonymous methods, sem
  `for..in` de classes, sem `TStringBuilder`, sem `inline` problemático.
  `{$IFDEF FPC}` apenas nas divergências reais (ex.: FPC separa
  `wincrypt`/`tlhelp32`/`shlobj` de `Windows.pas`).
- Núcleo (`src\core`), persistência (`src\persist`), Firebird (`src\firebird`),
  diagnóstico (`src\diag`), engines (`src\engines`) e exportação
  (`src\export`): **sem dependência de `Forms`** (testáveis por console).
  Apenas `src\ui` pode usar VCL/Forms.
- Unidades com nomes de até **31 caracteres**.
- Chaves de utilitários **sempre** via `uFBSwitchCatalog` (nunca montadas na
  mão); comandos logados com `-pass` **mascarado**.
- Operações que **escrevem** no banco devem passar pela guarda de segurança
  (`uGuardaSeguranca`) e, quando GUI, por confirmação explícita.

## Enviando um pull request

1. Faça um *fork* e crie um branch descritivo (`fix/...`, `feat/...`).
2. Faça commits pequenos e com mensagem clara (ex.: `feat(f2a): ...`).
3. Atualize/adicione testes e rode a suíte (Delphi 7; FPC quando aplicável).
4. Atualize a documentação afetada (`docs/`), inclusive o guia
   `AJUDA-MASTERDEV.md` quando mudar comportamento visível.
5. Abra o PR descrevendo a mudança, o risco e como foi testada.

## O que não deve ser incluído

- Credenciais/senhas (nem em logs de exemplo).
- Arquivos binários, DCUs/PPUs, `.exe`, corpora de banco (ver `.gitignore`).
- Dependências de runtime moderno ou código que exija Delphi > 7.
