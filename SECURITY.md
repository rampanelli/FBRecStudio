# Política de segurança

O FBRecStudio lida com **bancos de dados e credenciais**; a segurança é
tratada com prioridade.

## Comportamento do produto

- **Senhas nunca são salvas em texto claro.** Quando o armazenamento é usado,
  ele é feito via **DPAPI** (`uCredStore`) em `%APPDATA%\FBRecStudio\`;
  a GUI atual pede a senha a cada operação.
- **`-pass` é mascarado** (`******`) no comando exibido e nos logs.
- **Lista negra** de argumentos adicionais (`-pass`, `-password`, `>`, `<`,
  `|`, `&`) evita injeção/redirecionamento.
- Operações de **escrita** em banco exigem cópia de segurança e banco fora de
  uso (`uGuardaSeguranca`).
- Associação de arquivos é feita por usuário (**HKCU**, sem elevação).

## Reportando vulnerabilidades

**Não** abra uma *issue* pública para vulnerabilidades de segurança.
Envie um e-mail/contato privado dos mantenedores (definido na página do
repositório) com:

- descrição da falha e impacto;
- passos para reprodução (mínimos);
- versão afetada.

Você receberá resposta em até 7 dias úteis. Detalhes só são divulgados
publicamente após a correção ser publicada.

## Escopo

Estão fora do escopo desta política: versões antigas sem correção publicada,
ambientes sem o Delphi 7/utilitários Firebird suportados e vulnerabilidades nos
utilitários Firebird/InterBase (reportar aos respectivos projetos).
