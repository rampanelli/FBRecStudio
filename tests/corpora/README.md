# tests/corpora/ - Amostras para testes

Esta pasta recebe, a partir da F1, arquivos pequenos de exemplo:
bancos Firebird/InterBase de teste, saidas de gbak/gfix/isql e bytes
crus de console (OEM/UTF-8) para os testes de encoding.

Regras:
- Conteudo NAO e versionado (ver .gitignore): apenas este README.
- Somente arquivos pequenos e sem dados sensiveis.
- Prefira gerar os corpora por script dentro do proprio teste quando
  possivel (bancos criados on-the-fly com isql).
