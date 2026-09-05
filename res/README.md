# res/ - Recursos e identidade do FBRecStudio

Estrutura:

    res/
      FBRecStudio.manifest  Manifesto win32 (comctl32 v6 + asInvoker),
                            referenciado por src\app\FBRecStudio.rc
                            como recurso RT_MANIFEST (id 1, tipo 24).
      app.rc                Referencia/documentacao F0-T7 do bloco
                            VERSIONINFO pt-BR (o .rc que compila de
                            verdade e o src\app\FBRecStudio.rc, que ja
                            inclui o icone + VERSIONINFO).
      IDENTIDADE.md         Paleta, tipografia e geometria (PLANO 5.3).
      icons/
        FBRecStudio.ico     Placeholder oficial 16x16 32bpp (F0),
                            versionado; desenho conforme conceito do
                            PLANO 2.1 (squircle azul gradiente +
                            cilindro branco + seta de restauracao com
                            ponta verde). Gerado por script (nao ha IDE
                            Delphi nesta maquina); fonte/parametros em
                            res\README.md.
        (_*.ico/_*.png)     Rascunhos locais IGNORADOS pelo git.

## Compilacao de recursos

O build.bat (src\app) executa `brcc32 FBRecStudio.rc`, que gera
FBRecStudio.res com: icone (`100 ICON "..\..\res\icons\FBRecStudio.ico"`),
manifesto (RT_MANIFEST id 1) e VERSIONINFO pt-BR. res\app.rc e mantido
apenas como referencia/documentacao — NAO compilar os dois .rc juntos
(evita VERSIONINFO duplicado no mesmo .res).

## Regeneracao do icone placeholder (F0)

O `FBRecStudio.ico` atual e um bitmap clássico ICO 16×16, 32bpp BGRA
com máscara AND zerada (transparencia via canal alpha), valido do
Windows XP em diante. Foi gerado com PowerShell (System.Drawing foi
usado apenas para validar: `ExtractIconEx`/GDI+ retornam ok). Estrutura
de bytes (para recriar ou substituir por um pacote maior):

    ICONDIR (6) + ICONDIRENTRY (16)            -> offset 22
    BITMAPINFOHEADER (40): w=16 h=32(2x) bpp=32, biSizeImage = XOR+mask
    XOR: 16 linhas bottom-up (64 B/linha)      -> 1024 bytes
    AND: 16 linhas 1bpp zeradas (4 B/linha)    -> 64 bytes

Regra para a F1: substituir por um conjunto multi-tamanho
(16/24/32/48/256) com o design final aprovado (§2.1 + decisao de marca
do PLANO §9) — de preferencia gerado por designer/ferramenta propria.

## Codificacao

Manifest e .rc sao ASCII puro (seguranca do brcc32/codepage). Arquivos
`.md` podem usar UTF-8 com acentos.

## Versao

0.1.0.0 (F0). Versionamento centralizado: iguais em src\app\FBRecStudio.rc
e res\app.rc.
