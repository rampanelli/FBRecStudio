# IDENTIDADE VISUAL - FBRecStudio (F0-T7)

Referencia: PLANO.md, seccao 5.3 (paleta). Docs em UTF-8 podem usar
acentos; o codigo-fonte .pas/.rc deve permanecer ASCII (ver README.md).

## 1. Paleta

| Papel          | Tema claro            | Tema escuro            |
|----------------|-----------------------|------------------------|
| Fundo          | `#F5F5F7`             | `#1E1E20`              |
| Texto          | `#1D1D1F`             | `#F5F5F7`              |
| Destaque       | `#0A84FF`             | `#409CFF`              |
| Sucesso        | `#248A3D`             | `#32D74B`              |
| Atencao        | `#B25E09`             | `#FF9F0A`              |
| Erro           | `#D70015`             | `#FF453A`              |

Regra de uso: sucesso/atencao/erro apenas para estados; nunca para
acao primaria (usa-se o Destaque).

## 2. Tipografia

- UI: Segoe UI, depois Tahoma, depois MS Sans Serif.
- Codigo (saidas de console, SQL, log): Consolas, depois Lucida Console,
  depois Courier New.

## 3. Geometria

- Raios de cantos: 12 px (janelas/dialogos), 7 px (botoes), 6 px
  (campos), 4 px (badges/chips).
- Sidebar da F1: 220 px de largura.
- Espacamento base de 8 px (margens 12/16/24 conforme hierarquia).

## 4. Iconografia

- `res/icons/FBRecStudio.ico` - icone principal. F0: **placeholder
  16x16 32bpp gerado** (conceito do PLANO 2.1: squircle azul gradiente
  `#0A84FF -> #5E5CE6`, cilindro branco + seta de restauracao com ponta
  verde `#30D158`), ja referenciado pelo `src/app/FBRecStudio.rc`.
  F1: design final multi-tamanho (16/24/32/48/256 px).
- Demais icones de acao entram junto com as telas (F1+).

## 5. Estado atual (F0)

A casca usa os padroes nativos do Delphi 7 (clBtnFace/Tahoma); a paleta
acima e aplicada a partir da F1 (Tema light/dark salvo em [General]
Theme do config.ini - uAppConfig). O placeholder do icone (secao 4)
segue o conceito do PLANO 2.1 e e compilado pelo src/app/FBRecStudio.rc
via build.bat (brcc32).
