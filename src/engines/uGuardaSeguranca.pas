{
  uGuardaSeguranca.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F3-T2 (PLANO.md 4.2 Tecnica 3 "guarda de seguranca" e criterio de
  aceite 8.3 item 6): regras de protecao ANTES de qualquer escrita em
  um banco. Sem Forms; testavel por console/FPC.

    * TestarAcessoBanco: heuristica de deteccao de "banco em uso" sem
      driver: tenta abrir o arquivo com dwShareMode = 0. Se o servidor
      Firebird/InterBase (ou outro processo) tiver o arquivo aberto sem
      permitir compartilhamento, o CreateFileW falha com
      ERROR_SHARING_VIOLATION/ERROR_LOCK_VIOLATION => em uso. Limite
      documentado: o servidor pode ter o arquivo aberto de forma
      compativel (share) e a heuristica nao detecta; o teste real e o
      attach do utilitario (probe da F7).
    * GuardaAntesDeEscrita: politica unica usada pelas engines (F3 e
      futuras): operacao read-only nunca exige copia; operacao write
      exige (a) copia de seguranca ja realizada (uSafeCopy) e (b) o
      banco nao estar em uso. Em falha devolve mensagem amigavel.

  Regras do repositorio: Delphi 7 puro, comentarios pt-BR ASCII,
  sem generics/anonymous/for..in, units <= 31 chars.
  ------------------------------------------------------------------
}
unit uGuardaSeguranca;

{$H+}

interface

uses
  SysUtils, Windows;

type
  // Resultado do teste de acesso ao arquivo do banco.
  TGfAcesso = (
    gaOk,            // abriu (leitura; nada bloqueia) - banco livre
    gaInexistente,   // arquivo nao existe
    gaEmUso,         // falha de share/lock -> outro processo aberto
    gaSemPermissao,  // ERROR_ACCESS_DENIED (sem direito ou travado)
    gaOutroErro      // outro erro (retorna GetLastError via out)
  );

// ------------------------------------------------------------------
// Testa se o arquivo do banco pode ser aberto para leitura com
// dwShareMode = 0 (heuristica de "banco em uso"; limite documentado).
// AOutErro: codigo GetLastError quando gaOutroErro/gaSemPermissao.
// ------------------------------------------------------------------
function TestarAcessoBanco(const ACaminhoBanco: string;
  out AOutErro: DWORD): TGfAcesso;

// 'em uso' p/ decidir sem tratar os demais estados.
function BancoEmUso(const ACaminhoBanco: string): Boolean;

// ------------------------------------------------------------------
// Politica da guarda (PLANO 4.2 e 8.3): antes de operacao que ESCREVE
// no banco exige-se copia de seguranca feita e banco livre.
//   AAcaoEscrita  - True p/ acoes que escrevem no arquivo do banco;
//   ACopiaFeita   - True quando uSafeCopy ja concluiu a copia;
//   APermiteEmUso - True libera seguir mesmo 'em uso' (uso avancado/
//                   forcar; default False).
// AMsg preenche o motivo em falha. Retorna False e bloqueia.
// ------------------------------------------------------------------
function GuardaAntesDeEscrita(const ACaminhoBanco: string;
  AAcaoEscrita, ACopiaFeita, APermiteEmUso: Boolean;
  var AMsg: string): Boolean;

// Texto pt-BR do acesso (logs/relatorios).
function GfAcessoParaTexto(AAcesso: TGfAcesso): string;

implementation

// ------------------------------------------------------------------
// TestarAcessoBanco
// ------------------------------------------------------------------
function TestarAcessoBanco(const ACaminhoBanco: string;
  out AOutErro: DWORD): TGfAcesso;
var
  h: THandle;
  Erro: DWORD;
begin
  AOutErro := 0;
  if not FileExists(ACaminhoBanco) then
  begin
    Result := gaInexistente;
    Exit;
  end;

  // dwShareMode = 0: pede acesso exclusivo. Se outro processo abriu
  // sem compartilhar (tipico de servidor FB), o Windows nega.
  h := CreateFileW(PWideChar(WideString(ACaminhoBanco)), GENERIC_READ,
        0, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if h <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(h);
    Result := gaOk;
    Exit;
  end;

  Erro := GetLastError;
  AOutErro := Erro;
  case Erro of
    ERROR_SHARING_VIOLATION,
    ERROR_LOCK_VIOLATION:
      Result := gaEmUso;
    ERROR_ACCESS_DENIED:
      Result := gaSemPermissao;
  else
    Result := gaOutroErro;
  end;
end;

function BancoEmUso(const ACaminhoBanco: string): Boolean;
var
  Erro: DWORD;
begin
  Result := TestarAcessoBanco(ACaminhoBanco, Erro) = gaEmUso;
end;

// ------------------------------------------------------------------
// GuardaAntesDeEscrita
// ------------------------------------------------------------------
function GuardaAntesDeEscrita(const ACaminhoBanco: string;
  AAcaoEscrita, ACopiaFeita, APermiteEmUso: Boolean;
  var AMsg: string): Boolean;
var
  Acesso: TGfAcesso;
  Erro: DWORD;
begin
  AMsg := '';
  Result := True;

  // Read-only nunca exige copia nem trava por 'em uso'.
  if not AAcaoEscrita then
    Exit;

  if not ACopiaFeita then
  begin
    AMsg := 'Operacao de escrita exige uma copia de seguranca ' +
            'concluida antes (nunca operar direto no original).';
    Result := False;
    Exit;
  end;

  if not APermiteEmUso then
  begin
    Acesso := TestarAcessoBanco(ACaminhoBanco, Erro);
    if Acesso = gaEmUso then
    begin
      AMsg := 'O banco parece estar EM USO por outro processo ' +
              '(servidor Firebird/InterBase?). Feche as conexoes e ' +
              'repita a operacao.';
      Result := False;
      Exit;
    end;
    if Acesso = gaInexistente then
    begin
      AMsg := 'Banco nao encontrado: ' + ACaminhoBanco;
      Result := False;
      Exit;
    end;
  end;
end;

function GfAcessoParaTexto(AAcesso: TGfAcesso): string;
begin
  case AAcesso of
    gaOk:           Result := 'acesso livre (read)';
    gaInexistente:  Result := 'arquivo nao encontrado';
    gaEmUso:        Result := 'banco em uso (exclusivo)';
    gaSemPermissao: Result := 'sem permissao de acesso';
    gaOutroErro:    Result := 'erro de acesso';
  else
    Result := 'acesso desconhecido';
  end;
end;

end.
