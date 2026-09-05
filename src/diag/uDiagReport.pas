{
  uDiagReport.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  F1-T5: relatorio TEXTUAL legivel do resultado do diagnostico de
  arquivo (TDiagResult). Usado pelos logs, pela GUI (fase F1-T6,
  bloqueada sem Delphi 7) e pelos testes. Sem Forms.
  ------------------------------------------------------------------
}
unit uDiagReport;

{$H+}

interface

uses
  uDiagFileProbe;

// Relatorio completo em texto (multilinha) de um diagnostico.
function RelatorioDoArquivo(const ACaminho: string;
  const D: TDiagResult): string;

// Uma linha por campo (sem quebras adicionais alem das notas).
function ResumoDoDiagnostico(const D: TDiagResult): string;

implementation

uses
  SysUtils;

function TamanhoLegivel(ATam: Int64): string;
begin
  if ATam < 0 then
    Result := 'desconhecido'
  else if ATam < 1024 then
    Result := IntToStr(ATam) + ' bytes'
  else if ATam < 1024 * 1024 then
    Result := FormatFloat('0.#', ATam / 1024) + ' KB'
  else
    Result := FormatFloat('0.##', ATam / (1024 * 1024)) + ' MB';
end;

function OdsLegivel(const D: TDiagResult): string;
begin
  if D.OdsMaior = 0 then
    Result := 'nao determinado'
  else
    Result := IntToStr(D.OdsMaior) + '.' + IntToStr(D.OdsMenor);
end;

function SimNao(AB: Boolean): string;
begin
  if AB then
    Result := 'sim'
  else
    Result := 'nao';
end;

function RelatorioDoArquivo(const ACaminho: string;
  const D: TDiagResult): string;
var
  L: string;
begin
  Result := '';
  L := '=== Diagnostico de arquivo FB/IB ===';
  Result := L;
  Result := Result + #13#10 + 'Arquivo ............: ' + ACaminho;
  Result := Result + #13#10 + 'Tamanho ............: ' +
            TamanhoLegivel(D.FileSize);
  Result := Result + #13#10 + 'Classificacao ......: ' +
            DiagKindParaTexto(D.FileKind) +
            '  (por ' + D.ClassificadoPor + ')';
  Result := Result + #13#10 + 'ODS ................: ' + OdsLegivel(D);
  if D.PageSize > 0 then
    Result := Result + #13#10 + 'Page size ..........: ' +
              IntToStr(D.PageSize)
  else
    Result := Result + #13#10 + 'Page size ..........: nao determinado';
  if D.Dialect > 0 then
    Result := Result + #13#10 + 'Dialeto SQL ........: ' + IntToStr(D.Dialect)
  else
    Result := Result + #13#10 + 'Dialeto SQL ........: nao determinado';
  Result := Result + #13#10 + 'Em shutdown ........: ' + SimNao(D.Shutdown);
  Result := Result + #13#10 + 'FSS suspeito .......: ' +
            SimNao(D.SuspiciousFss);
  if D.CompatibleServer <> '' then
    Result := Result + #13#10 + 'Servidor compativel.: ' + D.CompatibleServer;
  if D.RecommendedTech <> '' then
    Result := Result + #13#10 + 'Tecnica recomendada.: ' + D.RecommendedTech;
  if D.Notes <> '' then
    Result := Result + #13#10 + 'Notas:' + #13#10 + D.Notes;
end;

function ResumoDoDiagnostico(const D: TDiagResult): string;
var
  S: string;
begin
  S := DiagKindParaTexto(D.FileKind);
  if D.OdsMaior <> 0 then
    S := S + ' ODS ' + IntToStr(D.OdsMaior) + '.' + IntToStr(D.OdsMenor);
  if D.PageSize > 0 then
    S := S + ' page ' + IntToStr(D.PageSize);
  if D.Dialect > 0 then
    S := S + ' dialecto ' + IntToStr(D.Dialect);
  if D.Shutdown then
    S := S + ' shutdown';
  if D.RecommendedTech <> '' then
    S := S + ' | ' + D.RecommendedTech;
  Result := S;
end;

end.