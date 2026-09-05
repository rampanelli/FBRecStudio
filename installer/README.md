# installer/ - Embalagem e instalacao (futuro)

A F0 nao produz instalador. A partir da fase de instalacao (roadmap) esta
pasta recebe:

- Inno Setup script (fonte .iss) para gerar setup.exe do FBRecStudio;
- arquivos de suporte: manifesto, icones, pastas %APPDATA%;

Requisitos de projeto que afetam o instalador:

- Nenhuma dependencia de terceiros embutida; o usuario fornece os
  utilitarios Firebird/InterBase (isql/gbak/...), configurados em
  [Paths] FbBinDir do config.ini.
- Instalacao por usuario (asInvoker), dados em %APPDATA%\FBRecStudio.
- Logs e historico continuam na pasta de dados do usuario.

Estado: placeholder (apenas .gitkeep/README na F0).
