{
  uFrmMain.pas  -  FBRecStudio (FB Recovery Studio)
  ------------------------------------------------------------------
  Janela principal FUNCIONAL (v1) do utilitario de recuperacao,
  construida 100% EM CODIGO (sem .dfm; ver F0-T2 no ROADMAP-STATUS).

  Funcionalidades desta integracao (F2-B simplificada):
    * Ao abrir: auto-deteccao dos utilitarios Firebird/InterBase
      (uFBAutoDetect) exibida no log e binario escolhido selecionado;
    * "Abrir backup": seleciona um .fbk/.gbk (ou banco .fdb/.gdb);
    * "Restaurar": executa gbak em uma WORKER THREAD (uKernelExec +
      uEngineGbak) com log para o TLogger, resultado (exit code/resumo)
      no memo e cancelamento pelo botao (Runner.Cancel, thread-safe).
    * Credenciais (usuario/senha com PasswordChar) editaveis na tela.
  As linhas do utilitario sao drenadas em tempo real para o memo
  (TCapOp/DoTick) e o resumo/log completo e apresentado ao concluir,
  alem da faixa de progresso da operacao.
  A engine roda fora da thread da UI (a janela nunca fica bloqueada;
  execucao cancelavel via Runner.Cancel, thread-safe).

  Regras: identificadores em ingles; comentarios pt-BR sem diacriticos
  (ASCII); unica unidade com Forms em todo o projeto; requer dcc32.
  ------------------------------------------------------------------
}
unit uFrmMain;

{$H+}

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms,
  StdCtrls, ExtCtrls, ComCtrls, Dialogs, Registry, IniFiles, SyncObjs,
  ShellAPI,
  uQuoting, uTextCodec, uHash, uAppConfig, uLogger, uKernelExec,
  uEngineBase, uEngineGbak, uFBVersionInfo, uFBSwitchCatalog,
  uFBAutoDetect, uDiagFileProbe, uHistoryStore, uExportSQL,
    uMotorAutoRec, uCredStore, Clipbrd;

type
  // Coletor de saida do motor (sem tocar na UI de dentro do runner).
  // Tambem encaminha as linhas para a fila "ao vivo" da GUI (com lock).
  TCapOp = class(TInterfacedObject, IOutputSink)
  private
    FQ: TStringList;
    FCS: TCriticalSection;
  public
    Linhas: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure SetLive(AQ: TStringList; ACS: TCriticalSection);
    procedure OnLine(AStream: TStreamId; const ALine: string);
    procedure OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
  end;

  // Worker: roda o restore/backup (TMotorGbak) fora da thread da UI.
  TOpThread = class(TThread)
  private
    FArquivo, FDestino, FUser, FSenha: string;
    FFixFss: Boolean;
    FBackup: Boolean;
    FResultado: string;
  public
    constructor Create(const AArquivo, ADestino, AUser, ASenha: string;
      AFixFss, ABackup: Boolean);
    procedure Execute; override;
  end;

  // Worker da exportacao SQL/DDL (isql -extract) fora da thread da UI.
  TSqlThread = class(TThread)
  private
    FArquivo, FUser, FSenha: string;
    FResultado: string;
  public
    constructor Create(const AArquivo, AUser, ASenha: string);
    procedure Execute; override;
  end;

  // Worker da recuperacao AUTOMATICA (uMotorAutoRec): diagnostico ->
  // escolha de tecnica -> tecnicas combinadas -> relatorio detalhado.
  TRecThread = class(TThread)
  private
    FArquivo, FUser, FSenha: string;
    FResultado: string;
    FArquivoFinal: string;
    FVeredito: TRecAutoResultado;
  public
    constructor Create(const AArquivo, AUser, ASenha: string);
    procedure Execute; override;
  end;

  TfrmMain = class(TForm)
  private
    FConfig: TAppConfig;
    FLog: TMemo;
    FUser: TEdit;
    FPass: TEdit;
    FDest: TEdit;
    FStatus: TLabel;
    FArquivo: string;
    FBins: TBinSetArray;
    FBinSel: Integer;
    FWorker: TOpThread;
    FSqlThread: TSqlThread;
    FRecThread: TRecThread;
    FRecCancelar: Boolean;
    FRunner: IProcessRunner;
    FOpen: TOpenDialog;
    FSave: TSaveDialog;
    FOrigemEdit: TEdit;
    FHistoricoPath: string;
    FPBar: TProgressBar;
    FPctLbl: TLabel;
    FTempoIni: TDateTime;   // inicio da operacao (contador de tempo)
    FTimer: TTimer;
    FQ: TStringList;
    FQCS: TCriticalSection;
    FProgSrc, FProgDst: string;
    FOpAtiva: Boolean;
    procedure BuildUi;
    procedure AddLine(const ALine: string);
    procedure AtualizarStatus(const ATexto: string);
    procedure EscolherBinario;
    procedure DoAbrir(Sender: TObject);
    procedure DoDiag(Sender: TObject);
    procedure DoRestaurar(Sender: TObject);
    procedure DoRecuperar(Sender: TObject);
    procedure RecOpConcluida;   // via Synchronize (thread de recuperacao)
    procedure DoCancelar(Sender: TObject);
    procedure DoBackupFbk(Sender: TObject);
    procedure DoDestino(Sender: TObject);
    procedure DoHistorico(Sender: TObject);
    procedure DoAssociar(Sender: TObject);
    procedure OpConcluida;   // chamado via Synchronize pela worker
    procedure CarregarArquivo(const ACaminho: string;
      AManterDestino: Boolean = False);
    procedure CarregarIni;
    procedure SalvarIni;
    procedure WMCopyData(var Msg: TMessage); message WM_COPYDATA;
    procedure DoExportarSql(Sender: TObject);
    procedure OpSqlConcluida;
    procedure DoAjuda(Sender: TObject);
    procedure DoCopiar(Sender: TObject);
    procedure DoTick(Sender: TObject);
    procedure DrainLive;
    procedure ProgAtualizar;
    // Lembranca de sessao (origem/destino/credenciais por tipo).
    function ExtAtual: string;
    function CaminhoCofre(const AExt: string): string;
    procedure CarregarCredenciais(const AExt: string);
    procedure SalvarCredenciais(const AExt: string);
    procedure PreencherUltimaSessao;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetConfig(const AConfig: TAppConfig);
  end;

var
  frmMain: TfrmMain;

implementation

uses
  uSafeCopy;

// ====================================================================
// Dialogos com titulo e texto curto (apresentacao limpa).
// ====================================================================
function ConfirmarDlg(const ATitulo, ATexto: string): Integer;
begin
  Result := Application.MessageBox(PChar(ATexto), PChar(ATitulo),
             MB_ICONQUESTION or MB_YESNOCANCEL);
end;

function InformarDlg(const ATitulo, ATexto: string): Integer;
begin
  Result := Application.MessageBox(PChar(ATexto), PChar(ATitulo),
             MB_ICONINFORMATION or MB_OK);
end;

// Tamanho em bytes de um arquivo (0 em erro/ausente).
function FileSizeBytes(const ACaminho: string): Int64;
var
  H: Integer;
  Ok: Boolean;
begin
  Result := 0;
  H := FileOpen(ACaminho, fmOpenRead or fmShareDenyNone);
  if H < 0 then
    Exit;
  try
    Ok := FileSeek(H, 0, 2) >= 0;
    if Ok then
      Result := FileSeek(H, 0, 1);
  finally
    FileClose(H);
  end;
end;

// ====================================================================
// TCapOp - coletor de stdout/stderr do processo (memoria, teto).
// ====================================================================
constructor TCapOp.Create;
begin
  inherited Create;
  Linhas := TStringList.Create;
  FQ := nil;
  FCS := nil;
end;

destructor TCapOp.Destroy;
begin
  Linhas.Free;
  inherited Destroy;
end;

procedure TCapOp.SetLive(AQ: TStringList; ACS: TCriticalSection);
begin
  FQ := AQ;
  FCS := ACS;
end;

procedure TCapOp.OnLine(AStream: TStreamId; const ALine: string);
begin
  if Linhas.Count < 12000 then
    Linhas.Add(ALine);
  if FQ <> nil then
  begin
    FCS.Enter;
    try
      if FQ.Count < 20000 then
        FQ.Add(ALine);
    finally
      FCS.Leave;
    end;
  end;
end;

procedure TCapOp.OnProcessEvent(AEvent: TProcEvent; const AInfo: string);
begin
  // nao usado pela v1 (eventos ficam no TLogger via motor)
end;

// ====================================================================
// TOpThread - executa o restore em background.
// ====================================================================
constructor TOpThread.Create(const AArquivo, ADestino, AUser,
  ASenha: string; AFixFss, ABackup: Boolean);
begin
  inherited Create(True);   // suspensa; o form decide quando rodar
  FArquivo := AArquivo;
  FDestino := ADestino;
  FUser := AUser;
  FSenha := ASenha;
  FFixFss := AFixFss;
  FBackup := ABackup;
  FResultado := '';
end;

procedure TOpThread.Execute;
var
  Motor: TMotorGbak;
  Plano: TPlanoGbak;
  Runner: IProcessRunner;
  Cap: TCapOp;
  Sink: IOutputSink;
  Res: TProcessResult;
  Msg: string;
  Full: TStringArray;
  I: Integer;
  Linhas: TStringList;
  Mostra: Integer;
begin
  Linhas := TStringList.Create;
  try
    Plano := TPlanoGbak.Create;
    try
      Plano.GbakExe := frmMain.FBins[frmMain.FBinSel].CaminhoBin + 'gbak.exe';
      Plano.VersaoGbak := frmMain.FBins[frmMain.FBinSel].Versao;
      Plano.Origem := FArquivo;
      if FBackup then
        Plano.Destino := ChangeFileExt(FArquivo, '.fbk')
      else
        Plano.Destino := FDestino;
      if FBackup then
        Plano.Modo := mgBackup
      else
        Plano.Modo := mgRestoreCriar;
      Plano.Usuario := FUser;
      Plano.Senha := FSenha;
      Plano.Verboso := True;
      Plano.NoGC := True;
      // Timeout default de 30 min por processo (0 = espera infinita,
      // causa historica de travamento com engine pendurado).
      Plano.TimeoutMs := 1800000;

      Motor := TMotorGbak.Create(nil);
      try
        Motor.AtribuirPlano(Plano);
        if not Motor.ValidarAmbiente(Msg) then
        begin
          FResultado := 'Ambiente: ' + Msg;
          Synchronize(frmMain.OpConcluida);
          Exit;
        end;
        if not Motor.BuildArgs then
        begin
          FResultado := 'Args: ' + Motor.ErroAmbiente;
          Synchronize(frmMain.OpConcluida);
          Exit;
        end;
        // comando (mascarado) p/ o relatorio
        SetLength(Full, Length(Motor.Argv) + 1);
        Full[0] := Plano.GbakExe;
        for I := 0 to Length(Motor.Argv) - 1 do
          Full[I + 1] := Motor.Argv[I];

        Runner := TProcessRunner.Create;
        frmMain.FRunner := Runner;
        Cap := TCapOp.Create;
        Cap.SetLive(frmMain.FQ, frmMain.FQCS);
        Sink := Cap;
        Res := Motor.Executar(Runner, Sink);
        frmMain.FRunner := nil;
        Linhas.AddStrings(Cap.Linhas);
        Sink := nil;
        Cap := nil;
        Runner := nil;

        FResultado := 'Comando: ' + MakeDisplayCommandLine(Full) + #13#10;
        if Motor.Resumo.Ok then
          FResultado := FResultado + 'Resultado: SUCESSO (exit 0)' + #13#10
        else
          FResultado := FResultado + 'Resultado: FALHA' + #13#10;
        if Motor.Resumo.Cancelado then
          FResultado := FResultado + 'Cancelado pelo usuario.' + #13#10;
        if Motor.Resumo.Timeout then
          FResultado := FResultado + 'Timeout.' + #13#10;
        if Motor.Resumo.MensagemErro <> '' then
          FResultado := FResultado + 'Mensagem: ' + Motor.Resumo.MensagemErro +
                        #13#10;

        Mostra := Linhas.Count;
        if Mostra > 300 then
        begin
          FResultado := FResultado + '... (ultimas linhas do gbak) ...' +
                        #13#10;
          Mostra := 300;
        end;
        for I := Linhas.Count - Mostra to Linhas.Count - 1 do
          if (I >= 0) and (I < Linhas.Count) then
            FResultado := FResultado + Linhas[I] + #13#10;
      finally
        Motor.Free;
      end;
    finally
      Plano.Free;
    end;
  except
    on E: Exception do
      FResultado := 'Excecao: ' + E.ClassName + ' - ' + E.Message;
  end;
  Synchronize(frmMain.OpConcluida);
end;

// ====================================================================
// TfrmMain
// ====================================================================
constructor TfrmMain.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  FConfig := nil;
  FWorker := nil;
  FSqlThread := nil;
  FRecThread := nil;
  FRecCancelar := False;
  FRunner := nil;
  FBinSel := -1;
  FArquivo := '';
    FOpAtiva := False;
    FTempoIni := Now;
    FProgSrc := '';
  FProgDst := '';
  FQ := TStringList.Create;
  FQCS := TCriticalSection.Create;
  Caption := 'FB Recovery Studio 0.3.0 (recuperacao automatica)';
  Width := 1140;
  Height := 740;
  Position := poScreenCenter;
  BorderStyle := bsSingle;   // tamanho fixo (sem redimensionar)
  AutoScroll := False;
  Constraints.MinWidth := Width;
  Constraints.MaxWidth := Width;
  Constraints.MinHeight := Height;
  Constraints.MaxHeight := Height;
  BuildUi;
    EscolherBinario;
    CarregarIni;
    // sem arquivo na linha de comando: traz a ultima sessao.
    if (ParamCount = 0) then
      PreencherUltimaSessao;
    // assinatura de arquivo (duplo clique / linha de comando)
    if (ParamCount > 0) and (ParamStr(1) <> '') then
      CarregarArquivo(ParamStr(1));
end;

destructor TfrmMain.Destroy;
begin
  SalvarIni;
  if FWorker <> nil then
  begin
    if FRunner <> nil then
      FRunner.Cancel;
    FWorker := nil;   // FreeOnTerminate: a propria thread se libera
  end;
  if FSqlThread <> nil then
  begin
    if FRunner <> nil then
      FRunner.Cancel;
    FSqlThread := nil;
  end;
  if FRecThread <> nil then
  begin
    FRecCancelar := True;   // o motor encerra os subprocessos
    FRecThread := nil;      // FreeOnTerminate (nunca Free no fechamento)
  end;
  FQCS.Enter;
  try
    FQ.Clear;
  finally
    FQCS.Leave;
  end;
  FQCS.Free;
  FQ.Free;
  inherited Destroy;
end;

// ====================================================================
// Paleta (PLANO 5.3) e controles flat locais (v1 da F6).
// ====================================================================
const
  K_FUNDO     = TColor($F7F5F5);   // #F5F5F7
  K_CARTAO    = clWhite;
  K_TXT       = TColor($1F1D1D);   // #1D1D1F
  K_TXT2      = TColor($736E6E);   // #6E6E73
  K_BORDA     = TColor($E9E6E6);   // #E2E2E8
  K_ACENTE    = TColor($FF840A);   // #0A84FF
  K_ACENTE_H  = TColor($EF7700);   // #0060DF (hover)
  K_NEUTRO    = TColor($F1EFF3);
  K_OK        = TColor($3D8A24);   // #248A3D
  K_ERRO      = TColor($150040);   // #D70015 (BGR invertido)
  K_ALERTA    = TColor($0991B2);   // #B25E09
  K_GRAD_A    = TColor($FF840A);   // #0A84FF
  K_GRAD_B    = TColor($E65C5E);   // #5E5CE6
  K_HEADER    = TColor($FF840A);
  K_HEADER_HI = TColor($E65C5E);

function UiFont: string;
begin
  if Screen.Fonts.IndexOf('Segoe UI') >= 0 then
    Result := 'Segoe UI'
  else
    Result := 'Tahoma';
end;

function MonFont: string;
begin
  if Screen.Fonts.IndexOf('Consolas') >= 0 then
    Result := 'Consolas'
  else if Screen.Fonts.IndexOf('Lucida Console') >= 0 then
    Result := 'Lucida Console'
  else
    Result := 'Courier New';
end;

// ------------------------------------------------------------------
// TGradBar - painel com gradiente vertical (cabecalho).
// ------------------------------------------------------------------
type
  TGradBar = class(TPanel)
  public
    FTopColor: TColor;
    FBottomColor: TColor;
    constructor Create(AOwner: TComponent); override;
  protected
    procedure Paint; override;
  end;

constructor TGradBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTopColor := K_GRAD_A;
  FBottomColor := K_GRAD_B;
  BevelOuter := bvNone;
end;

procedure TGradBar.Paint;
var
  I, H: Integer;
  C1, C2, CC: array[0..2] of Byte;
  T: Double;
  C: TColor;
begin
  inherited Paint;
  H := Height;
  if H < 1 then
    Exit;
  C1[0] := GetRValue(ColorToRGB(FTopColor));
  C1[1] := GetGValue(ColorToRGB(FTopColor));
  C1[2] := GetBValue(ColorToRGB(FTopColor));
  C2[0] := GetRValue(ColorToRGB(FBottomColor));
  C2[1] := GetGValue(ColorToRGB(FBottomColor));
  C2[2] := GetBValue(ColorToRGB(FBottomColor));
  Canvas.Pen.Style := psSolid;
  for I := 0 to H - 1 do
  begin
    T := I / H;
    CC[0] := C1[0] + Round((C2[0] - C1[0]) * T);
    CC[1] := C1[1] + Round((C2[1] - C1[1]) * T);
    CC[2] := C1[2] + Round((C2[2] - C1[2]) * T);
    C := RGB(CC[0], CC[1], CC[2]);
    Canvas.Pen.Color := C;
    Canvas.MoveTo(0, I);
    Canvas.LineTo(Width, I);
  end;
end;

// ------------------------------------------------------------------
// TSwBtn - botao flat com cantos arredondados (sem imagens; GDI).
// ------------------------------------------------------------------
type
  TSwBtn = class(TCustomControl)
  private
    FTexto: string;
    FPrimario: Boolean;   // fundo acento, texto branco
    FNeutro: Boolean;     // fundo cinza claro, texto normal
    FPerigo: Boolean;     // texto vermelho (acao destrutiva)
    FDown: Boolean;
    procedure SetTexto(const ATexto: string);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    property Texto: string read FTexto write SetTexto;
  end;

constructor TSwBtn.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTexto := '';
  FPrimario := False;
  FNeutro := True;
  FPerigo := False;
  FDown := False;
  Cursor := crHandPoint;
  Width := 120;
  Height := 32;
end;

procedure TSwBtn.SetTexto(const ATexto: string);
begin
  FTexto := ATexto;
  Invalidate;
end;

procedure TSwBtn.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  FDown := True;
  Invalidate;
end;

procedure TSwBtn.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDown := False;
  Invalidate;
end;

procedure TSwBtn.Paint;
var
  Rgn: HRGN;
  R: TRect;
  C: TColor;
  Tx: TColor;
begin
  if FDown then
    C := K_ACENTE_H
  else if FPrimario then
    C := K_ACENTE
  else if FNeutro then
    C := K_NEUTRO
  else
    C := K_NEUTRO;
  Tx := clWhite;
  if (not FPrimario) then
  begin
    if FPerigo then
      Tx := K_ERRO
    else if FNeutro then
      Tx := K_TXT
    else
      Tx := K_ACENTE;
  end;
  Rgn := CreateRoundRectRgn(0, 0, Width, Height, 12, 12);
  SelectClipRgn(Canvas.Handle, Rgn);
  Canvas.Brush.Color := C;
  Canvas.FillRect(ClientRect);
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Name := UiFont;
  Canvas.Font.Size := 10;
  Canvas.Font.Color := Tx;
  R := ClientRect;
  DrawText(Canvas.Handle, PChar(FTexto), Length(FTexto), R,
           DT_CENTER or DT_VCENTER or DT_SINGLELINE);
  SelectClipRgn(Canvas.Handle, 0);
  DeleteObject(Rgn);
end;

procedure TfrmMain.BuildUi;
var
  Grad: TGradBar;
  Card, Prog: TPanel;
  L: TLabel;
  SB: TSwBtn;
  Inner: TPanel;
  AW, X, Y, BW, ColW, EditW, RightEdge: Integer;
  EachW, I: Integer;

  // Mede o texto com a fonte real (respeita DPI/tipografia).
  function Medir(const S: string; APontos: Integer;
    ANegrito: Boolean): Integer;
  begin
    Canvas.Font.Name := UiFont;
    Canvas.Font.Style := [];
    if ANegrito then
      Canvas.Font.Style := [fsBold];
    Canvas.Font.Size := APontos;
    Result := Canvas.TextWidth(S) + 4;
  end;

  // Titulo de secao (rotulo acima do campo).
  procedure Secao(const ACap: string);
  begin
    L := TLabel.Create(Self);
    L.Parent := Card;
    L.Left := 24;
    L.Top := Y;
    L.Caption := ACap;
    L.AutoSize := True;
    L.Transparent := True;
    L.Font.Name := UiFont;
    L.Font.Size := 9;
    L.Font.Style := [fsBold];
    L.Font.Color := K_TXT2;
    Inc(Y, 24);
  end;

begin
  Color := K_FUNDO;
  Font.Name := UiFont;
  Font.Size := 10;
  if not HandleAllocated then
    HandleNeeded;
  AW := ClientWidth - 48;
  RightEdge := 24 + AW;

  // ---------- cabecalho ----------
  Grad := TGradBar.Create(Self);
  Grad.Parent := Self;
  Grad.Align := alTop;
  Grad.Height := 82;
  L := TLabel.Create(Self);
  L.Parent := Grad;
  L.Left := 26;
  L.Top := 13;
  L.AutoSize := True;
  L.Caption := 'FB Recovery Studio';
  L.Transparent := True;
  L.Font.Name := UiFont;
  L.Font.Size := 20;
  L.Font.Style := [fsBold];
  L.Font.Color := clWhite;
  L := TLabel.Create(Self);
  L.Parent := Grad;
  L.Left := 27;
  L.Top := 49;
  L.AutoSize := True;
  L.Caption := 'Recuperacao de bancos Firebird e InterBase';
  L.Transparent := True;
  L.Font.Name := UiFont;
  L.Font.Size := 10;
  L.Font.Color := TColor($EAF4FF);

  // ---------- cartao de controles ----------
  Card := TPanel.Create(Self);
  Card.Parent := Self;
  Card.Align := alTop;
  Card.BevelOuter := bvNone;
  Card.Color := K_CARTAO;

  Y := 16;

  // 1) Origem: campo de edicao + botao 'Abrir arquivo...' ao lado
  Secao('ORIGEM (.FBK/.GBK OU BANCO .FDB/.GDB)');
  // largura unica p/ os dois botoes (Origem e Destino ficam iguais)
  BW := Medir('Abrir arquivo...', 10, False) + 24;
  if Medir('Selecionar destino...', 10, False) + 24 > BW then
    BW := Medir('Selecionar destino...', 10, False) + 24;
  if BW < 176 then
    BW := 176;
  EditW := AW - BW - 12;
  FOrigemEdit := TEdit.Create(Self);
  FOrigemEdit.Parent := Card;
  FOrigemEdit.Left := 24;
  FOrigemEdit.Top := Y;
  FOrigemEdit.Width := EditW;
  FOrigemEdit.Height := 34;
  FOrigemEdit.Font.Name := UiFont;
  FOrigemEdit.Font.Size := 11;
  FOrigemEdit.ShowHint := True;
  SB := TSwBtn.Create(Self);
  SB.Parent := Card;
  SB.Left := 24 + EditW + 12;
  SB.Top := Y;
  SB.Width := BW;
  SB.Height := 34;
  SB.FPrimario := False;
  SB.FNeutro := True;
  SB.Texto := 'Abrir arquivo...';
  SB.OnClick := DoAbrir;
  Inc(Y, 34 + 14);

  // 2) Destino: campo de edicao + botao de selecao ao lado
  Secao('DESTINO (.FDB NOVO)');
  EditW := AW - BW - 12;
  FDest := TEdit.Create(Self);
  FDest.Parent := Card;
  FDest.Left := 24;
  FDest.Top := Y;
  FDest.Width := EditW;
  FDest.Height := 34;
  FDest.Font.Name := UiFont;
  FDest.Font.Size := 11;
  FDest.Text := '';
  FDest.ShowHint := True;
  SB := TSwBtn.Create(Self);
  SB.Parent := Card;
  SB.Left := 24 + EditW + 12;
  SB.Top := Y;
  SB.Width := BW;
  SB.Height := 34;
  SB.FPrimario := False;
  SB.FNeutro := True;
  SB.Texto := 'Selecionar destino...';
  SB.OnClick := DoDestino;
  Inc(Y, 34 + 14);

  // 3) Acesso (usuario e senha em duas colunas)
  Secao('ACESSO (USUARIO E SENHA)');
  ColW := (AW - 12) div 2;
  L := TLabel.Create(Self);
  L.Parent := Card;
  L.Left := 24;
  L.Top := Y + 4;
  L.Caption := 'Usuario';
  L.AutoSize := True;
  L.Transparent := True;
  L.Font.Name := UiFont;
  L.Font.Size := 10;
  L.Font.Color := K_TXT2;
  L := TLabel.Create(Self);
  L.Parent := Card;
  L.Left := 24 + ColW + 12;
  L.Top := Y + 4;
  L.Caption := 'Senha';
  L.AutoSize := True;
  L.Transparent := True;
  L.Font.Name := UiFont;
  L.Font.Size := 10;
  L.Font.Color := K_TXT2;
  Inc(Y, 26);
  FUser := TEdit.Create(Self);
  FUser.Parent := Card;
  FUser.Left := 24;
  FUser.Top := Y;
  FUser.Width := ColW;
  FUser.Height := 30;
  FUser.Font.Name := UiFont;
  FUser.Font.Size := 11;
  FUser.Text := 'sysdba';
  FPass := TEdit.Create(Self);
  FPass.Parent := Card;
  FPass.Left := 24 + ColW + 12;
  FPass.Top := Y;
  FPass.Width := ColW;
  FPass.Height := 30;
  FPass.Font.Name := UiFont;
  FPass.Font.Size := 11;
  FPass.PasswordChar := '*';
  Inc(Y, 30 + 14);

  // 4) Servidor / utilitarios detectados
  Secao('SERVIDOR / UTILITARIOS DETECTADOS');
  FStatus := TLabel.Create(Self);
  FStatus.Parent := Card;
  FStatus.Left := 24;
  FStatus.Top := Y + 5;
  FStatus.Width := AW;
  FStatus.AutoSize := False;
  FStatus.ShowHint := True;
  FStatus.Caption := 'detectando...';
  FStatus.Font.Name := UiFont;
  FStatus.Font.Size := 10;
  FStatus.Font.Color := K_OK;
  Inc(Y, 26);

  // 5) Acoes - fileira unica, botoes iguais e uniformemente espacados
    Inc(Y, 10);
    EachW := (AW - (9 - 1) * 10) div 9;
    X := 24;
    for I := 0 to 8 do
    begin
      SB := TSwBtn.Create(Self);
      SB.Parent := Card;
      SB.Left := X;
      SB.Top := Y;
      SB.Width := EachW;
      SB.Height := 34;
      SB.FPrimario := (I = 8);
      SB.FNeutro := (I <> 8);
      case I of
        0: begin SB.Texto := 'Diagnosticar';  SB.OnClick := DoDiag;        end;
        1: begin SB.Texto := 'Backup .fbk';   SB.OnClick := DoBackupFbk;   end;
        2: begin SB.Texto := 'Exportar SQL';  SB.OnClick := DoExportarSql; end;
        3: begin SB.Texto := 'Historico';     SB.OnClick := DoHistorico;   end;
        4: begin SB.Texto := 'Associar';      SB.OnClick := DoAssociar;    end;
        5: begin SB.Texto := 'Copiar rel.';   SB.OnClick := DoCopiar;      end;
        6: begin SB.Texto := 'Cancelar';      SB.OnClick := DoCancelar;    end;
        7: begin SB.Texto := 'Ajuda';         SB.OnClick := DoAjuda;       end;
        8: begin SB.Texto := 'Recuperar';    SB.OnClick := DoRecuperar;   end;
      end;
      X := X + EachW + 10;
    end;
  Inc(Y, 34);

  Card.Height := Y + 18;

  // ---------- faixa de progresso ----------
  Prog := TPanel.Create(Self);
  Prog.Parent := Self;
  Prog.Align := alTop;
  Prog.Height := 48;
  Prog.BevelOuter := bvNone;
  Prog.Color := K_CARTAO;

  X := 24;
  L := TLabel.Create(Self);
  L.Parent := Prog;
  L.Left := X;
  L.Top := 12;
  L.Caption := 'Progresso da operacao:';
  L.AutoSize := True;
  L.Transparent := True;
  L.Font.Name := UiFont;
  L.Font.Size := 9;
  L.Font.Style := [fsBold];
  L.Font.Color := K_TXT2;
  X := X + Medir('Progresso da operacao:', 9, True) + 10;

  FPctLbl := TLabel.Create(Self);
  FPctLbl.Parent := Prog;
  FPctLbl.Left := X;
  FPctLbl.Top := 12;
  FPctLbl.Caption := '0% (sem operacao)';
  FPctLbl.AutoSize := True;
  FPctLbl.Transparent := True;
  FPctLbl.Font.Name := UiFont;
  FPctLbl.Font.Size := 9;
  FPctLbl.Font.Color := K_TXT;
  X := X + Medir('0% (sem operacao)', 9, False) + 16;

  FPBar := TProgressBar.Create(Self);
  FPBar.Parent := Prog;
  FPBar.Left := X;
  FPBar.Top := 18;
  FPBar.Width := RightEdge - X;
  FPBar.Height := 12;
  FPBar.Min := 0;
  FPBar.Max := 100;
  FPBar.Position := 0;
  FPBar.Smooth := True;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 350;
  FTimer.OnTimer := DoTick;

  // ---------- painel de log ----------
  Inner := TPanel.Create(Self);
  Inner.Parent := Self;
  Inner.Align := alClient;
  Inner.BevelOuter := bvNone;
  Inner.Color := K_CARTAO;

  FLog := TMemo.Create(Self);
  FLog.Parent := Inner;
  FLog.Left := 24;
  FLog.Top := 12;
  FLog.Width := Inner.ClientWidth - 48;
  FLog.Height := Inner.ClientHeight - 24;
  FLog.Anchors := [akLeft, akTop, akRight, akBottom];
  FLog.ReadOnly := True;
  FLog.ScrollBars := ssVertical;
  FLog.WordWrap := True;
  FLog.Ctl3D := False;
  FLog.BorderStyle := bsNone;
  FLog.Color := K_CARTAO;
  FLog.Font.Name := MonFont;
  FLog.Font.Size := 10;
  FLog.Font.Color := K_TXT;

  FHistoricoPath := ExcludeTrailingPathDelimiter(
    SysUtils.GetEnvironmentVariable('APPDATA')) +
    '\FBRecStudio\history.csv';
  FOpen := TOpenDialog.Create(Self);
  FOpen.Filter := 'Backups e bancos|*.fbk;*.gbk;*.fdb;*.gdb|' +
                  'Backup Firebird (*.fbk)|*.fbk|Backup InterBase (*.gbk)|*.gbk|' +
                  'Banco (*.fdb;*.gdb)|*.fdb;*.gdb|Todos|*.*';
  FSave := TSaveDialog.Create(Self);
  FSave.DefaultExt := '.fdb';
  FSave.Filter := 'Banco Firebird (*.fdb)|*.fdb|Banco InterBase (*.gdb)|*.gdb';
end;
procedure TfrmMain.AddLine(const ALine: string);
begin
  FLog.Lines.Add(ALine);
end;

procedure TfrmMain.AtualizarStatus(const ATexto: string);
begin
  FStatus.Caption := ATexto;
end;

// Escolhe (e lista) os utilitarios detectados; guarda em FBins.
procedure TfrmMain.EscolherBinario;
var
  N, I: Integer;
  S: string;
  Extras: TStringList;
begin
  FBins := nil;
  FBinSel := -1;
  // Inclui a pasta de ferramentas embarcadas que acompanha o app
  // (bin\ferramentas) - o app roda portatil, sem instalacao.
  Extras := TStringList.Create;
  try
    Extras.Add(ExtractFilePath(Application.ExeName) + 'ferramentas');
    N := AutoDetectar(Extras, FBins);
  finally
    Extras.Free;
  end;
  S := 'nenhum';
  // prioridade: primeiro gbak com versao valida
  for I := 0 to N - 1 do
    if FBins[I].TemGbak and FBins[I].Versao.Valida then
    begin
      FBinSel := I;
      Break;
    end;
  if FBinSel >= 0 then
  begin
    S := FBins[FBinSel].CaminhoBin;
    AtualizarStatus(ExtractFileName(ExcludeTrailingPathDelimiter(S)) +
                    ' (gbak ' + VersaoParaTexto(FBins[FBinSel].Versao) + ')');
    if AppLogger <> nil then
      AppLogger.Info('main', 'Binario selecionado: ' + S);
  end
  else
    AtualizarStatus('nenhum (informe um binario valido antes de restaurar)');
end;

procedure TfrmMain.DoAbrir(Sender: TObject);
begin
  if FOpen.Execute then
    CarregarArquivo(FOpen.FileName);
end;

procedure TfrmMain.DoDestino(Sender: TObject);
begin
  if FSave.Execute then
    FDest.Text := FSave.FileName;
end;

procedure TfrmMain.CarregarArquivo(const ACaminho: string;
  AManterDestino: Boolean);
begin
  if ACaminho = '' then
    Exit;
  if not FileExists(ACaminho) then
  begin
    MessageDlg('Arquivo nao encontrado:' + #13#10 + ACaminho, mtError,
               [mbOk], 0);
    Exit;
  end;
  FArquivo := ACaminho;
    if not AManterDestino then
      FDest.Text := ChangeFileExt(FArquivo, '.fdb');
    if FOrigemEdit <> nil then
      FOrigemEdit.Text := ACaminho;
    AtualizarStatus('arquivo carregado');
    // Credenciais conforme o tipo do arquivo aberto (.gbk/.fbk x .fdb/...).
    CarregarCredenciais(ExtAtual);
  if AppLogger <> nil then
    AppLogger.Info('main', 'Arquivo carregado: ' + FArquivo);
end;

procedure TfrmMain.WMCopyData(var Msg: TMessage);
var
  P: PCopyDataStruct;
  S: string;
begin
  if Msg.LParam <> 0 then
  begin
    P := PCopyDataStruct(Msg.LParam);
    if (P.dwData = 1) and (P.cbData > 0) then
    begin
      SetString(S, PAnsiChar(P.lpData), P.cbData);
      CarregarArquivo(S);
      Msg.Result := 1;
      Exit;
    end;
  end;
  inherited;
end;

// ====================================================================
// Lembranca de sessao: origem/destino em ui.ini e credenciais por
// tipo de arquivo no cofre DPAPI (nunca em claro).
// ====================================================================
function UiIniPath: string;
begin
  Result := ExcludeTrailingPathDelimiter(
    SysUtils.GetEnvironmentVariable('APPDATA')) + '\FBRecStudio\ui.ini';
end;

function TfrmMain.ExtAtual: string;
var
  S: string;
begin
  Result := 'geral';
  S := '';
  if FArquivo <> '' then
    S := FArquivo
  else if (FOrigemEdit <> nil) and (FOrigemEdit.Text <> '') then
    S := FOrigemEdit.Text;
  if S <> '' then
  begin
    S := LowerCase(ExtractFileExt(S));
    if S <> '' then
      Result := Copy(S, 2, MaxInt);   // '.gbk' -> 'gbk'
  end;
end;

function TfrmMain.CaminhoCofre(const AExt: string): string;
var
  E: string;
  I: Integer;
begin
  E := AExt;
  if E = '' then
    E := 'geral';
  // So caracteres seguros para nome de arquivo.
  for I := 1 to Length(E) do
    if not (E[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) then
      E[I] := '_';
  Result := IncludeTrailingPathDelimiter(GetAppDataDir) +
            'credentials_' + E + '.bin';
end;

procedure TfrmMain.CarregarCredenciais(const AExt: string);
var
  Cofre: TCredStore;
  U, S: string;
begin
  U := '';
  S := '';
  Cofre := TCredStore.Create(CaminhoCofre(AExt));
  try
    if Cofre.Load(U, S) then
    begin
      if FUser <> nil then
        FUser.Text := U;
      if FPass <> nil then
        FPass.Text := S;
    end
    else
    begin
      // Sem cofre ainda: padrao sysdba / sem senha.
      if FUser <> nil then
        FUser.Text := 'sysdba';
      if FPass <> nil then
        FPass.Text := '';
    end;
  finally
    Cofre.Free;
  end;
end;

procedure TfrmMain.SalvarCredenciais(const AExt: string);
var
  Cofre: TCredStore;
begin
  if (FUser = nil) or (FPass = nil) then
    Exit;
  Cofre := TCredStore.Create(CaminhoCofre(AExt));
  try
    Cofre.Save(FUser.Text, FPass.Text);
  finally
    Cofre.Free;
  end;
end;

// Preenche Origem/Destino/credenciais com a ultima sessao (quando o
// app abre sem arquivo na linha de comando).
procedure TfrmMain.PreencherUltimaSessao;
var
  Ini: TIniFile;
  Origem, Destino, Tipo: string;
begin
  if not FileExists(UiIniPath) then
    Exit;
  Ini := TIniFile.Create(UiIniPath);
  try
    Origem := Ini.ReadString('recentes', 'ultimo_arquivo', '');
    Destino := Ini.ReadString('recentes', 'ultimo_destino', '');
    Tipo := Ini.ReadString('recentes', 'ultimo_tipo', 'geral');
  finally
    Ini.Free;
  end;
  if Origem = '' then
    Exit;
  if FileExists(Origem) then
  begin
    // Abre DE VERDADE o arquivo da ultima sessao (FArquivo, destino,
    // credenciais por tipo) - respeita o caminho digitado/mostrado.
    if (Destino <> '') and (FDest <> nil) then
      FDest.Text := Destino;
    CarregarArquivo(Origem, True);
    AtualizarStatus('ultima sessao reaberta: ' + Origem);
  end
  else
  begin
    if FOrigemEdit <> nil then
      FOrigemEdit.Text := Origem;
    if (Destino <> '') and (FDest <> nil) then
      FDest.Text := Destino;
    CarregarCredenciais(Tipo);
    AtualizarStatus('ultima sessao: arquivo nao encontrado (campos ' +
                    'preenchidos).');
  end;
end;

procedure TfrmMain.CarregarIni;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(UiIniPath);
  try
    if FUser <> nil then
      FUser.Text := Ini.ReadString('credenciais', 'usuario', 'sysdba');
    FHistoricoPath := Ini.ReadString('caminhos', 'history',
      ExcludeTrailingPathDelimiter(
        SysUtils.GetEnvironmentVariable('APPDATA')) +
        '\FBRecStudio\history.csv');
  finally
    Ini.Free;
  end;
end;

procedure TfrmMain.SalvarIni;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(UiIniPath);
  try
    if FUser <> nil then
      Ini.WriteString('credenciais', 'usuario', FUser.Text);
    Ini.WriteString('caminhos', 'history', FHistoricoPath);
    if FArquivo <> '' then
          Ini.WriteString('recentes', 'ultimo_arquivo', FArquivo);
        // Lembranca de sessao: destino e tipo (credenciais no cofre DPAPI).
        if FDest <> nil then
          Ini.WriteString('recentes', 'ultimo_destino', FDest.Text);
        Ini.WriteString('recentes', 'ultimo_tipo', ExtAtual);
        // Persiste usuario/senha atuais no cofre do tipo (DPAPI).
        SalvarCredenciais(ExtAtual);
  finally
    Ini.Free;
  end;
end;

procedure TfrmMain.DoDiag(Sender: TObject);
var
  R: TDiagResult;
  S: string;
begin
  if FArquivo = '' then
  begin
    MessageDlg('Abra um arquivo .fbk/.gbk/.fdb primeiro.', mtInformation,
               [mbOk], 0);
    Exit;
  end;
  FillChar(R, SizeOf(R), 0);
  if not DiagnosticarArquivo(FArquivo, R) then
  begin
    MessageDlg('Falha ao diagnosticar.' + #13#10 + R.Notes, mtError,
               [mbOk], 0);
    Exit;
  end;
  S := 'Tipo: ' + DiagKindParaTexto(R.FileKind) + #13#10 +
       'ODS: ' + IntToStr(R.OdsMaior) + '.' + IntToStr(R.OdsMenor) +
       #13#10 + 'Tamanho: ' + Format('%d', [R.FileSize]) + ' bytes' +
       #13#10 + 'Tecnica: ' + R.RecommendedTech + #13#10;
  if R.Notes <> '' then
    S := S + 'Nota: ' + Copy(R.Notes, 1, 140) + #13#10;
  AddLine('=== Diagnostico ===');
  AddLine('Arquivo: ' + FArquivo);
  AddLine(S);
  InformarDlg('Diagnostico',
    'Arquivo: ' + ExtractFileName(FArquivo) + #13#10 + S);
end;

procedure TfrmMain.DoBackupFbk(Sender: TObject);
var
  Msg: string;
  Ext: string;
begin
  if FWorker <> nil then
  begin
    MessageDlg('Uma operacao ja esta em andamento.', mtWarning, [mbOk], 0);
    Exit;
  end;
  if FArquivo = '' then
  begin
    MessageDlg('Abra um banco .fdb/.gdb para gerar o backup .fbk.',
               mtInformation, [mbOk], 0);
    Exit;
  end;
  Ext := LowerCase(ExtractFileExt(FArquivo));
  if (Ext <> '.fdb') and (Ext <> '.gdb') then
  begin
    MessageDlg('Backup nativo (gbak -b) exige um banco .fdb/.gdb como ' +
               'origem (voce abriu um backup).', mtInformation, [mbOk], 0);
    Exit;
  end;
  if FBinSel < 0 then
  begin
    MessageDlg('Nenhum gbak detectado.', mtError, [mbOk], 0);
    Exit;
  end;
  if ConfirmarDlg('Backup .fbk',
       'Gerar backup (.fbk) de:' + #13#10 + FArquivo + #13#10 +
       'Confirma?') <> IDYES then
    Exit;
  FProgSrc := FArquivo;
      FProgDst := ChangeFileExt(FArquivo, '.fbk');
      FOpAtiva := True;
      FTempoIni := Now;
      SalvarCredenciais(ExtAtual);
    if FPBar <> nil then
    FPBar.Position := 0;
  if FPctLbl <> nil then
    FPctLbl.Caption := '0% (backup...)';
  FWorker := TOpThread.Create(FArquivo, '', FUser.Text, FPass.Text,
                              False, True);
  FWorker.FreeOnTerminate := True;
  FWorker.Resume;
  AtualizarStatus('backup...');
  AddLine('Iniciando backup gbak -b em ' + FormatDateTime('hh:nn:ss', Now));
end;

procedure TfrmMain.DoHistorico(Sender: TObject);
var
  SL: TStringList;
  I, Inicio: Integer;
begin
  SL := TStringList.Create;
  try
    if (FHistoricoPath <> '') and FileExists(FHistoricoPath) then
      SL.LoadFromFile(FHistoricoPath)
    else
      AddLine('Historico vazio (arquivo: ' + FHistoricoPath + ').');
    Inicio := SL.Count - 40;
    if Inicio < 0 then
      Inicio := 0;
    AddLine('=== Historico (' + IntToStr(SL.Count) +
            ' registros; ultimos ' + IntToStr(SL.Count - Inicio) + ') ===');
    for I := Inicio to SL.Count - 1 do
      AddLine(SL[I]);
  finally
    SL.Free;
  end;
end;

procedure TfrmMain.DoAssociar(Sender: TObject);
const
  K_EXE = '"%s" "%%1"';
var
  Exe: string;
  ProgID: string;
begin
  Exe := Application.ExeName;
  with TRegistry.Create do
  try
    RootKey := HKEY_CURRENT_USER;
    // .fbk
    if OpenKey('Software\Classes\.fbk', True) then
      WriteString('', 'FBRecStudio.fbk');
    if OpenKey('Software\Classes\FBRecStudio.fbk\DefaultIcon', True) then
      WriteString('', '"' + Exe + '",0');
    if OpenKey('Software\Classes\FBRecStudio.fbk\shell\open\command', True) then
      WriteString('', Format(K_EXE, [Exe]));
    CloseKey;
    // .gbk
    if OpenKey('Software\Classes\.gbk', True) then
      WriteString('', 'FBRecStudio.gbk');
    if OpenKey('Software\Classes\FBRecStudio.gbk\DefaultIcon', True) then
      WriteString('', '"' + Exe + '",0');
    if OpenKey('Software\Classes\FBRecStudio.gbk\shell\open\command', True) then
      WriteString('', Format(K_EXE, [Exe]));
    CloseKey;
  finally
    Free;
  end;
  MessageDlg('Associacao criada para este usuario (HKCU, sem UAC).',
             mtInformation, [mbOk], 0);
  AddLine('Associacao .fbk/.gbk registrada para ' + Exe);
end;

procedure TfrmMain.DoRestaurar(Sender: TObject);
var
  Msg: string;
begin
  if FWorker <> nil then
  begin
    MessageDlg('Uma operacao ja esta em andamento.', mtWarning, [mbOk], 0);
    Exit;
  end;
  if FArquivo = '' then
  begin
    MessageDlg('Abra um arquivo de backup (.fbk/.gbk) primeiro.', mtInformation,
               [mbOk], 0);
    Exit;
  end;
  if FBinSel < 0 then
  begin
    MessageDlg('Nenhum gbak detectado. Instale/aponte o Firebird ' +
               'ou InterBase.', mtError, [mbOk], 0);
    Exit;
  end;
  if FDest.Text = '' then
    FDest.Text := ChangeFileExt(FArquivo, '.fdb');
  if ConfirmarDlg('Restaurar',
       'Restaurar de:' + #13#10 + FArquivo + #13#10 +
       'para:' + #13#10 + FDest.Text + #13#10 +
       'Usuario: ' + FUser.Text + #13#10 +
       'Confirma?') <> IDYES then
    Exit;

  // cria a pasta do destino e uma copia de seguranca? (v1: apenas cria
  // a pasta; a engine valida o resto)
  ForceDirectories(ExtractFilePath(FDest.Text));

  FProgSrc := FArquivo;
      FProgDst := FDest.Text;
      FOpAtiva := True;
      FTempoIni := Now;
      SalvarCredenciais(ExtAtual);
    if FPBar <> nil then
    FPBar.Position := 0;
  if FPctLbl <> nil then
    FPctLbl.Caption := '0% (restaurando...)';

  FWorker := TOpThread.Create(FArquivo, FDest.Text, FUser.Text,
                              FPass.Text, False, False);
  FWorker.OnTerminate := nil;
  FWorker.FreeOnTerminate := True;
  FWorker.Resume;
  AtualizarStatus('restaurando...');
  AddLine('Iniciando restore (thread) em ' + FormatDateTime('hh:nn:ss', Now));
end;

procedure TfrmMain.DoCancelar(Sender: TObject);
begin
  if FRecThread <> nil then
  begin
    FRecCancelar := True;   // encerra no proximo ponto de checagem
    AddLine('Cancelamento solicitado (recuperacao)...');
  end;
  if FRunner <> nil then
  begin
    FRunner.Cancel;
    AddLine('Cancelamento solicitado...');
  end
  else if FRecThread = nil then
    AddLine('Nenhuma operacao em andamento para cancelar.');
end;

procedure TfrmMain.OpConcluida;
var
  R: string;
begin
  if FWorker <> nil then
  begin
    R := FWorker.FResultado;
    FWorker := nil;   // thread se libera via FreeOnTerminate
    FRunner := nil;
  end;
  if R <> '' then
    AddLine('');
  AddLine('=== Resultado da operacao ===');
  AddLine(R);
  FOpAtiva := False;
  if FPBar <> nil then
    FPBar.Position := 100;
  if FPctLbl <> nil then
    FPctLbl.Caption := 'concluido (100%)';
  AtualizarStatus('concluido.');
end;

procedure TfrmMain.SetConfig(const AConfig: TAppConfig);
begin
  FConfig := AConfig;
end;

// ------------------------------------------------------------------
// TSqlThread - exportacao SQL/DDL via isql -extract (captura stdout).
// ------------------------------------------------------------------
constructor TSqlThread.Create(const AArquivo, AUser, ASenha: string);
begin
  inherited Create(True);
  FArquivo := AArquivo;
  FUser := AUser;
  FSenha := ASenha;
  FResultado := '';
end;

procedure TSqlThread.Execute;
var
  Argv: TStringArray;
  Msg: string;
  Opt: TCapturaOptions;
  Res: TResultadoCaptura;
  Runner: IProcessRunner;
  Erros: TStringList;
  Catalogo: ISwitchCatalog;
  Destino: string;
  I: Integer;
begin
  FResultado := '';
  Erros := TStringList.Create;
  try
    if (frmMain.FBinSel >= 0) and
       (frmMain.FBinSel < Length(frmMain.FBins)) and
       frmMain.FBins[frmMain.FBinSel].TemIsql then
    begin
      Destino := ChangeFileExt(FArquivo, '.sql');
      Catalogo := CriarCatalogPadrao;
      MontarArgvIsqlExtract(FUser, FSenha, '', FArquivo, Catalogo,
                            frmMain.FBins[frmMain.FBinSel].Versao,
                            Argv, Msg);
      if Msg = '' then
      begin
        Opt.Executavel := frmMain.FBins[frmMain.FBinSel].CaminhoBin +
                          'isql.exe';
        Opt.WorkDir := '';
        Opt.Args := Argv;
        Opt.Destino := Destino;
        Opt.Charset := '';
        Opt.TetoBytes := 0;
        Opt.TimeoutMs := 1800000; // 30 min (0 = espera infinita)
        Opt.KillTree := True;
        Opt.ConsoleCodePage := 0;
        Runner := TProcessRunner.Create;
        frmMain.FRunner := Runner;
        try
          Res := CapturarStdoutParaArquivo(Runner, Opt, nil, Erros);
        finally
          frmMain.FRunner := nil;
        end;
        if Res.Ok then
          FResultado := 'SUCESSO (exit 0): ' + Destino + #13#10 +
                        IntToStr(Integer(Res.Linhas)) + ' linhas, ' +
                        IntToStr(Integer(Res.Bytes)) + ' bytes gravados.'
        else
        begin
          FResultado := 'FALHA: ' + Res.Erro + ' (exit ' +
                        IntToStr(Integer(Res.ExitCode)) + ')' + #13#10;
          for I := 0 to Erros.Count - 1 do
            if I < 12 then
              FResultado := FResultado + Erros[I] + #13#10;
        end;
      end
      else
        FResultado := 'Falha ao montar argumentos do isql: ' + Msg;
    end
    else
      FResultado := 'Binario selecionado sem isql.exe (impossivel ' +
                    'exportar SQL/DDL).';
  finally
    Erros.Free;
  end;
  Synchronize(frmMain.OpSqlConcluida);
end;

// ====================================================================
// Adaptador ILogPasso -> fila da GUI: leva as mensagens do motor de
// recuperacao para o painel AO VIVO (mesma fila + timer do gbak).
// ====================================================================
type
  TLogFila = class(TInterfacedObject, ILogPasso)
  private
    FQ: TStringList;
    FCS: TCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetFila(AQ: TStringList; ACS: TCriticalSection);
    procedure Log(const ACanal: string; const AMensagem: string);
  end;

constructor TLogFila.Create;
begin
  inherited Create;
  FQ := nil;
  FCS := nil;
end;

destructor TLogFila.Destroy;
begin
  FQ := nil;
  FCS := nil;
  inherited Destroy;
end;

procedure TLogFila.SetFila(AQ: TStringList; ACS: TCriticalSection);
begin
  FQ := AQ;
  FCS := ACS;
end;

procedure TLogFila.Log(const ACanal: string; const AMensagem: string);
var
  S: string;
begin
  if FQ = nil then
    Exit;
  // NAO inundar o painel com o despejo cru das ferramentas (gbak -v
  // emite milhares de linhas e afoga o TMemo da interface): somente
  // as mensagens de ETAPA do motor (canal app) vao ao vivo.
  if (ACanal = LC_STDOUT) or (ACanal = LC_STDERR) then
    Exit;
  if (ACanal = LC_APP) or (ACanal = '') then
    S := AMensagem
  else
    S := '[' + ACanal + '] ' + AMensagem;
  FCS.Enter;
  try
    if FQ.Count < 8000 then
      FQ.Add(S);
  finally
    FCS.Leave;
  end;
end;

// ====================================================================
// TRecThread - recuperacao automatica (uMotorAutoRec) em background.
// ====================================================================
constructor TRecThread.Create(const AArquivo, AUser, ASenha: string);
begin
  inherited Create(True);
  FArquivo := AArquivo;
  FUser := AUser;
  FSenha := ASenha;
  FResultado := '';
  FArquivoFinal := '';
  FVeredito := raNaoIniciada;
end;

procedure TRecThread.Execute;
var
  Extras: TStringList;
  Bins: TBinSetArray;
  N: Integer;
  Entrada: TRecAutoEntrada;
  Motor: TMotorAutoRec;
  FilaLog: TLogFila;
  IntfLog: ILogPasso;
  Res: TRecAutoResultado;
  I: Integer;
  P: string;
  RelPath: string;
begin
  FResultado := '';
  try
    Extras := TStringList.Create;
    try
      // Ferramentas embarcadas que acompanham o aplicativo (portatil).
      Extras.Add(ExtractFilePath(Application.ExeName) + 'ferramentas');
      N := AutoDetectar(Extras, Bins);
      FillChar(Entrada, SizeOf(Entrada), 0);
      Entrada.Origem := FArquivo;
      Entrada.Destino := frmMain.FDest.Text;  // respeita o destino digitado
      Entrada.PastaTrabalho := ''; // default: pasta ao lado do arquivo
      Entrada.Usuario := FUser;
      Entrada.Senha := FSenha;
      Entrada.TimeoutMs := 0;      // default interno (30 min/passo)
      Entrada.PermitirReparoMend := True;
      Entrada.Bins := Bins;
      // Log ao vivo: as mensagens do motor vao para o painel via fila.
      FilaLog := TLogFila.Create;
      FilaLog.SetFila(frmMain.FQ, frmMain.FQCS);
      IntfLog := FilaLog;
      Motor := TMotorAutoRec.Create(Entrada, IntfLog);
      try
        Motor.AtribuirCancelamento(@frmMain.FRecCancelar);
        Res := Motor.Executar;
        FVeredito := Res;
        FArquivoFinal := Motor.ArquivoFinal;
        // Monta o texto do relatorio (mesmo sem banco: honesto).
        for I := 0 to Motor.Relatorio.Count - 1 do
          FResultado := FResultado + Motor.Relatorio[I] + #13#10;
        // Salva o relatorio .txt junto do DESTINO informado (nome do
        // destino + _relatorio_recuperacao.txt); sem destino, na pasta
        // de trabalho padrao.
        RelPath := '';
        if frmMain.FDest.Text <> '' then
        begin
          P := ExtractFilePath(frmMain.FDest.Text);
          if P = '' then
            P := ExtractFilePath(Application.ExeName);
          if P <> '' then
          begin
            if P[Length(P)] <> '\' then
              P := P + '\';
            RelPath := P + ChangeFileExt(
              ExtractFileName(frmMain.FDest.Text), '') +
              '_relatorio_recuperacao.txt';
          end;
        end
        else
        begin
          P := ExtractFilePath(FArquivo);
          if P = '' then
            P := ExtractFilePath(Application.ExeName);
          if P <> '' then
          begin
            if P[Length(P)] <> '\' then
              P := P + '\';
            RelPath := P + 'recuperacao\relatorio_recuperacao.txt';
          end;
        end;
        if (RelPath <> '') and Motor.SalvarRelatorio(RelPath) then
        begin
          FResultado := FResultado + #13#10 +
            'Relatorio salvo em: ' + RelPath + #13#10;
          if AppLogger <> nil then
            AppLogger.Info('recuperar', 'Relatorio: ' + RelPath);
        end;
      finally
        Motor.Free;
        IntfLog := nil;   // libera o adaptador de log (refcount)
      end;
    finally
      Extras.Free;
    end;
  except
    on E: Exception do
      FResultado := 'Excecao na recuperacao: ' + E.ClassName + ' - ' +
                    E.Message;
  end;
  Synchronize(frmMain.RecOpConcluida);
end;

procedure TfrmMain.DoRecuperar(Sender: TObject);
var
  Msg: string;
  P: string;
begin
  if (FWorker <> nil) or (FRecThread <> nil) then
  begin
    MessageDlg('Uma operacao ja esta em andamento.', mtWarning, [mbOk], 0);
    Exit;
  end;
  if FArquivo = '' then
  begin
    MessageDlg('Abra um arquivo .fbk/.gbk/.fdb primeiro.', mtInformation,
               [mbOk], 0);
    Exit;
  end;
  if ConfirmarDlg('Recuperar',
       'Recuperacao automatica de:' + #13#10 + FArquivo + #13#10 +
       #13#10 +
       'Diagnostica, escolhe a tecnica, valida o resultado e grava ' +
       'relatorio em pasta "recuperacao_" ao lado do arquivo.' +
       #13#10 +
       'O arquivo ORIGINAL nunca e alterado.' + #13#10 +
       'Confirma?') <> IDYES then
    Exit;
  FRecCancelar := False;
  // Relatorio sempre zerado: painel limpo + fila limpa - cada execucao
  // gera um relatorio NOVO, sem itens duplicados.
  FQCS.Enter;
  try
    FQ.Clear;
  finally
    FQCS.Leave;
  end;
  if FLog <> nil then
    FLog.Lines.Clear;
  FOpAtiva := True;
        FTempoIni := Now;
        SalvarCredenciais(ExtAtual);
        // Progresso real: a barra acompanha o crescimento do banco sendo
  // restaurado (mesma heuristica do restore manual).
  P := ExtractFilePath(FArquivo);
  if P = '' then
    P := ExtractFilePath(Application.ExeName);
  if P[Length(P)] <> '\' then
    P := P + '\';
  if FDest.Text = '' then
    FDest.Text := ChangeFileExt(FArquivo, '.fdb');
  FProgSrc := FArquivo;
  FProgDst := FDest.Text;   // progresso acompanha o destino real
  if FPBar <> nil then
    FPBar.Position := 0;
  if FPctLbl <> nil then
    FPctLbl.Caption := '0% (recuperando...)';
  FRecThread := TRecThread.Create(FArquivo, FUser.Text, FPass.Text);
  FRecThread.FreeOnTerminate := True;
  FRecThread.Resume;
  AtualizarStatus('recuperando (automatico)...');
  if AppLogger <> nil then
    AppLogger.Info('recuperar', 'Iniciando recuperacao automatica de ' +
                  FArquivo);
end;

procedure TfrmMain.RecOpConcluida;
var
  R: string;
  RList: TStringList;
  V: TRecAutoResultado;
begin
  V := raNaoIniciada;
  R := '';
  if FRecThread <> nil then
  begin
    R := FRecThread.FResultado;
    V := FRecThread.FVeredito;
    FRecThread := nil;  // thread se libera via FreeOnTerminate
    FRunner := nil;
  end;
  FOpAtiva := False;
  if FPBar <> nil then
    FPBar.Position := 100;
  if FPctLbl <> nil then
    FPctLbl.Caption := 'concluido';
  // Descarta linhas ao vivo remanescentes e mostra o relatorio final
  // UMA vez (sem duplicar - o loop antigo re-adicionava a string
  // inteira a cada iteracao).
  FQCS.Enter;
  try
    FQ.Clear;
  finally
    FQCS.Leave;
  end;
  RList := TStringList.Create;
  try
    RList.Text := R;   // setter de Text quebra em linhas (uma por item)
    if RList.Count > 400 then
    begin
      while RList.Count > 400 do
        RList.Delete(RList.Count - 1);
      RList.Add('... (relatorio completo salvo em arquivo .txt)');
    end;
    FLog.Lines.BeginUpdate;
    try
      FLog.Lines.Clear;
      FLog.Lines.Add('=== Recuperacao automatica concluida ===');
      FLog.Lines.AddStrings(RList);
    finally
      FLog.Lines.EndUpdate;
    end;
  finally
    RList.Free;
  end;
  AtualizarStatus('recuperacao: ' + RecAutoResultadoParaTexto(V) +
                  ' (ver relatorio no painel).');
end;

procedure TfrmMain.DoExportarSql(Sender: TObject);
var
  Msg: string;
  Ext: string;
begin
  if FSqlThread <> nil then
  begin
    MessageDlg('Uma exportacao ja esta em andamento.', mtWarning, [mbOk], 0);
    Exit;
  end;
  if FArquivo = '' then
  begin
    MessageDlg('Abra um banco .fdb/.gdb para exportar o SQL/DDL.',
               mtInformation, [mbOk], 0);
    Exit;
  end;
  Ext := LowerCase(ExtractFileExt(FArquivo));
  if (Ext <> '.fdb') and (Ext <> '.gdb') then
  begin
    MessageDlg('isql -extract exige um banco .fdb/.gdb (voce abriu um ' +
               'backup).', mtInformation, [mbOk], 0);
    Exit;
  end;
  if (FBinSel < 0) or (not FBins[FBinSel].TemIsql) then
  begin
    MessageDlg('Nenhum isql detectado. Instale/aponte o Firebird ou ' +
               'InterBase.', mtError, [mbOk], 0);
    Exit;
  end;
  if ConfirmarDlg('Exportar SQL',
       'Exportar SQL/DDL de:' + #13#10 + FArquivo + #13#10 +
       'para: ' + ChangeFileExt(FArquivo, '.sql') + #13#10 +
       'Confirma?') <> IDYES then
    Exit;
  FProgSrc := FArquivo;
      FProgDst := ChangeFileExt(FArquivo, '.sql');
      FOpAtiva := True;
      FTempoIni := Now;
      SalvarCredenciais(ExtAtual);
    if FPBar <> nil then
    FPBar.Position := 0;
  if FPctLbl <> nil then
    FPctLbl.Caption := '0% (exportando sql...)';
  FSqlThread := TSqlThread.Create(FArquivo, FUser.Text, FPass.Text);
  FSqlThread.FreeOnTerminate := True;
  FSqlThread.Resume;
  AtualizarStatus('exportando sql...');
  AddLine('Iniciando exportacao SQL/DDL em ' + FormatDateTime('hh:nn:ss', Now));
end;

procedure TfrmMain.OpSqlConcluida;
var
  R: string;
begin
  if FSqlThread <> nil then
  begin
    R := FSqlThread.FResultado;
    FSqlThread := nil;  // thread se libera via FreeOnTerminate
    FRunner := nil;
  end;
  AddLine('');
  AddLine('=== Exportacao SQL/DDL ===');
  AddLine(R);
  FOpAtiva := False;
  if FPBar <> nil then
    FPBar.Position := 100;
  if FPctLbl <> nil then
    FPctLbl.Caption := 'concluido (100%)';
  AtualizarStatus('exportacao concluida.');
end;

// ------------------------------------------------------------------
// Copia o relatorio do painel (ou a ultima operacao) p/ a area de
// transferencia - colar em email/WhatsApp/relatorio.
// ------------------------------------------------------------------
procedure TfrmMain.DoCopiar(Sender: TObject);
begin
  if FLog <> nil then
  begin
    Clipboard.AsText := FLog.Lines.Text;
    AtualizarStatus('relatorio copiado para a area de transferencia.');
    AddLine('Relatorio copiado para a area de transferencia.');
  end;
end;

// ------------------------------------------------------------------
procedure TfrmMain.DoAjuda(Sender: TObject);
var
  P: string;
begin
  P := ExtractFilePath(Application.ExeName) + 'AJUDA-MASTERDEV.md';
  if not FileExists(P) then
    P := ExtractFilePath(Application.ExeName) +
         '..\docs\AJUDA-MASTERDEV.md';
  if FileExists(P) then
    ShellExecute(Handle, 'open', PChar(P), nil, nil, SW_SHOWNORMAL)
  else
    MessageDlg('Arquivo de ajuda nao encontrado:' + #13#10 + P,
               mtInformation, [mbOk], 0);
end;

// Drena as linhas "ao vivo" da fila. Durante uma operacao NENHUM
// texto e escrito no TMemo por tick (o controle de texto e o ponto de
// estrangulamento que congelava a interface): o feedback vira o rotulo
// de status com a ultima etapa. O memo so recebe texto fora de
// operacao e o relatorio final (RecOpConcluida).
procedure TfrmMain.DrainLive;
const
  K_DRAIN_TICK = 400;    // max linhas lidas por tick
var
  L: TStringList;
  I, N: Integer;
  Ultima: string;
begin
  if FLog = nil then
    Exit;
  L := TStringList.Create;
  try
    FQCS.Enter;
    try
      N := FQ.Count;
      if N > K_DRAIN_TICK then
        N := K_DRAIN_TICK;
      for I := 0 to N - 1 do
        L.Add(FQ[I]);
      while N > 0 do
      begin
        FQ.Delete(0);
        Dec(N);
      end;
    finally
      FQCS.Leave;
    end;
    if L.Count > 0 then
    begin
      Ultima := L[L.Count - 1];
      if FOpAtiva then
      begin
        // Operacao rodando: so o rotulo (barato, nao trava).
        if Ultima <> '' then
        begin
          if Length(Ultima) > 70 then
            Ultima := Copy(Ultima, 1, 70) + '...';
          FStatus.Caption := 'em andamento: ' + Ultima;
        end;
      end
      else
      begin
        // Fora de operacao: pode acumular no memo (volume pequeno).
        FLog.Lines.BeginUpdate;
        try
          for I := 0 to L.Count - 1 do
            FLog.Lines.Add(L[I]);
        finally
          FLog.Lines.EndUpdate;
        end;
        FLog.SelStart := Length(FLog.Text);
        SendMessage(FLog.Handle, EM_SCROLLCARET, 0, 0);
      end;
    end;
  finally
    L.Free;
  end;
end;

// Atualiza a barra/% usando o crescimento do arquivo de destino em
// relacao ao de origem (aproximacao visivel; gbak nao emite % propria).
procedure TfrmMain.ProgAtualizar;
var
  Dst, Src: Int64;
  Pct: Integer;
  Seg: Double;
  Temp: string;
begin
  if (not FOpAtiva) or (FPBar = nil) then
    Exit;
  Dst := FileSizeBytes(FProgDst);
  Src := FileSizeBytes(FProgSrc);
  if Src > 0 then
  begin
    Pct := Round((Dst / Src) * 100);
    if Pct > 99 then
      Pct := 99;   // 100% so no fim (validacao real)
  end
  else
    Pct := 0;
  FPBar.Position := Pct;
  if FPctLbl <> nil then
  begin
    // Mostra % + tempo decorrido (contador da operacao).
    Seg := (Now - FTempoIni) * 86400;
    Temp := Format('%.0f', [Seg]) + 's';
    FPctLbl.Caption := IntToStr(Pct) + '% (' + Temp + ')';
  end;
end;

procedure TfrmMain.DoTick(Sender: TObject);
begin
  DrainLive;
  ProgAtualizar;
end;

end.
