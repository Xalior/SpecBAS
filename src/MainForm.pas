// Copyright (C) 2010 By Paul Dunn
//
// This file is part of the SpecBAS BASIC Interpreter, which is in turn
// part of the SpecOS project.
//
// SpecBAS is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// SpecBAS is distributed in the hope that it will be entertaining,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with SpecBAS.  If not, see <http://www.gnu.org/licenses/>.

unit MainForm;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$INCLUDE SpecBAS.inc}

interface

uses
  {$IFNDEF FPC}SHFolder, MMSystem, Dialogs, System.Types, SyncObjs, SHellAPI, PNGImage, GIFImg, Windows, Messages,
  {$ELSE} LCLIntf, LCLType, FPReadPNG, FPImage, OpenGLContext,

  {$IFDEF Windows}Windows, Messages, MMSystem {$ELSE}LMessages{$ENDIF}, {$ENDIF}
  SysUtils, Variants, Classes, Graphics, Controls, Forms, Math, SP_SysVars, SP_Graphics, SP_Graphics32, SP_BankManager, SP_Util, SP_Main, SP_FileIO,
  ExtCtrls, SP_Input, SP_Errors, SP_Sound, Bass, SP_Tokenise, SP_Menu, RunTimeCompiler, SP_Components, SP_BaseComponentUnit, {$IFNDEF FPC}Vcl.ClipBrd{$ELSE}ClipBrd{$ENDIF};

Const

  WM_RESIZEMAIN = WM_USER + 1;

type

  { TMain }

  TMain = class(TForm)
    Timer1: TTimer;
    procedure FormShow(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormDestroy(Sender: TObject);
    procedure FormMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure FormMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure FormMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormMouseWheelDown(Sender: TObject; Shift: TShiftState; MousePos: TPoint; var Handled: Boolean);
    procedure FormMouseWheelUp(Sender: TObject; Shift: TShiftState; MousePos: TPoint; var Handled: Boolean);
    procedure FormPaint(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyPress(Sender: TObject; var Key: Char);
    procedure FormActivate(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
    procedure FormCanResize(Sender: TObject; var NewWidth, NewHeight: Integer; var Resize: Boolean);
    procedure Timer1Timer(Sender: TObject);
  private
    { Private declarations }
    {$IFDEF OpenGL}
    Minimised: Boolean;
    {$ENDIF}
    {$IFNDEF RefreshThread}
    Procedure OnIdle(Sender: TObject; Var Done: Boolean);
    {$ENDIF}
    procedure OnAppMessage(var Msg: TMsg; var Handled: Boolean);
    procedure CMDialogKey( Var msg: TCMDialogKey ); message CM_DIALOGKEY;
    Procedure OnResizeMain(Var Msg: TMessage); Message WM_RESIZEMAIN;
    {$IFNDEF FPC}
    procedure WMMenuChar(var MessageRec: TWMMenuChar); message WM_MENUCHAR;
    {$ENDIF}
  public
    { Public declarations }
    Function  GetCharFromVirtualKey(Var Key: Word): astring;
    procedure DropFiles(var msg: TMessage ); message WM_DROPFILES;
    Procedure CreateGDIBitmap;
    {$IFDEF FPC}
    Procedure DoResizeMain(l, t, w, h: Integer);
    Procedure AppDropFiles(Sender: TObject; const FileNames: array of String);
    {$ENDIF}
  end;

  {$IFDEF FPC}
  TLoadImageSync = Class
    FFilename: aString;
    FError:    TSP_ErrorCode;
    Procedure  Run;
  End;
  {$ENDIF}

  TSpecBAS_Thread = Class(TThread)
    Procedure Execute; Override;
  End;

  Procedure YieldProc(const ms: aFloat); inline;
  Procedure MsgProc; inline;
  Procedure GetKeyState;
  Function  GetTicks: aFloat;
  Procedure MouseMoveTo(ToX, ToY: Integer);
  Procedure Quit;
  function  Sto_GetFmtFileVersion(const FileName: String = ''; const Fmt: String = '%d.%d'): String;
  Procedure LoadImage(Filename: aString; Var Error: TSP_ErrorCode);
  Procedure SaveImage(Filename: aString; w, h: Integer; Pixels, Palette: pByte);
  Procedure FreeImageResource;
  Procedure UpdateLinuxBuildStr;
  Procedure SetWindowCaption;

var
  Main: TMain;
  BASThread: TSpecBAS_Thread;
  Quitting: Boolean = False;
  InitTime: LongWord;
  ImgResource: Array of Byte;
  lastt, ft: Longword;
  BaseTime: Int64;
  Bits: Pointer;
  Bitmap: TBitmap = Nil;
  LastMouseX, LastMouseY: Integer;
  MouseInForm, IgnoreNextMenuChar, AltDown, FormActivated: Boolean;
  AltChars: aString;
  CaptionString: String;
  MainCanResize: Boolean = True;
  {$IFDEF FPC}
  PendingKeyInfo:  SP_KeyInfo;
  PendingKeyValid: Boolean = False;
  {$ENDIF}

{$IFDEF OPENGL}
Const

  GL_BGRA = $80E1;
{$ENDIF}

implementation

Uses {$IFDEF FPC}
      {$IFDEF UNIX}
        Unix, BaseUnix,
      {$ENDIF}
    {$ENDIF}
    {$IFNDEF RUNTIMEONLY}SP_FPEditor, SP_ToolTipWindow, SP_BASICEditorHostUnit,{$ENDIF}
    SP_Display, SP_WindowMenuUnit, SP_PopUpMenuUnit, SP_BASICInterpreter, SP_BankFiling, SP_Interpret_PostFix;

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

{$IFNDEF RefreshThread}
Procedure TMain.OnIdle(Sender: TObject; Var Done: Boolean);
Begin
  If MainCanResize Then
    FrameLoop;
  Done := False;
End;
{$ENDIF}

{$IFDEF FPC}
Procedure TLoadImageSync.Run;
Begin
  CB_Load_Image(FFilename, FError);
End;

Procedure TMain.DoResizeMain(l, t, w, h: Integer);
Begin
  MainCanResize := False;
  FPSIMAGE := '';
  Left         := l;
  Top          := t;
  ClientWidth  := w;
  ClientHeight := h;
  // Call SetScaling directly with the TARGET dimensions
  // rather than reading back from GLControl which may not have resized yet
  SetScaling(DISPLAYWIDTH, DISPLAYHEIGHT, w, h);
  GLResize;
  SIZINGMAIN   := False;
  MainCanResize := True;
End;
{$ENDIF}

Procedure TMain.OnResizeMain(Var Msg: TMessage);
Var
  l, t, w, h, cw, ch: Integer;
Begin

  MainCanResize := False;

  FPSIMAGE := '';
  cw := ClientWidth;
  ch := ClientHeight;
  l := SmallInt(Msg.wParam And $FFFF);
  t := SmallInt((Msg.wParam Shr 16) And $FFFF);
  w := Msg.lParam And $FFFF;
  h := (Msg.lParam Shr 16) And $FFFF;

  If Visible Then
    SendMessage(Handle, WM_SETREDRAW, WPARAM(False), 0);

  try
    ClientWidth := w;
    ClientHeight := h;
    Left := l;
    Top := t;
  finally
    If Visible Then
      SendMessage(Handle, WM_SETREDRAW, WPARAM(True), 0);
  End;

  FormResize(Self); // must run here, or crash

  Msg.Result := 0;
  SIZINGMAIN := False;

  MainCanResize := True;

End;

procedure TMain.Timer1Timer(Sender: TObject);
Var
  s: String;
begin
  If WCAPTION = '' Then Begin
    GetOSDString;
    If AvgFrameTime > 0 Then
      s := Format('%.0f', [1000/AvgFrameTime])
    Else
      s := 'INF';
    Caption := CaptionString + ' ' + String(BUILDSTR) + ' - ' + s + ' fps';
  End Else
    Caption := String(WCAPTION);
end;

Function GetTicks: aFloat;
{$IFDEF UNIX}
Var
  ts: TimeSpec;
{$ENDIF}
Begin
  {$IFNDEF UNIX}
  Result := TimeGetTime - baseTime;
  {$ELSE}
  clock_gettime(CLOCK_MONOTONIC, @ts);
  Result := (ts.tv_sec * 1000.0) + (ts.tv_nsec / 1000000.0) - baseTime;
  {$ENDIF}
End;

procedure TMain.OnAppMessage(var Msg: TMsg; var Handled: Boolean);
begin

  case Msg.message of
    WM_SYSCHAR:
      Handled := aChar(Msg.wParam) in ['a'..'z', 'A'..'Z', '0'..'9'];
    WM_KEYDOWN:
      begin
        if (Msg.lParam shr 30) = 1 then begin
          Handled := True;
        end else
          Handled := False;
      end;
  else
     // Not handled
     Handled := False;
  end;

End;

Procedure TSpecBAS_Thread.Execute;
Var
  Interpreter: TSP_BASICInterpreter;
Begin

  NameThreadForDebugging('Interpreter Thread');

  InterpreterThreadAlive := True;
  Priority := tpNormal;
  FreeOnTerminate := True;

  Interpreter := TSP_BASICInterpreter.Create(0);
  Try
    Interpreter.AcquireThreadVars;
    SP_MainLoop;
    Interpreter.ReleaseThreadVars;
  Finally
    Interpreter.Free;
  End;

  InterpreterThreadAlive := False;

End;

procedure TMain.FormMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
Var
  mi: SP_MenuSelection;
  Win: Pointer;
  Btn, ID: Integer;
  p: TPoint;
  Handled: Boolean;
  sPtr: pSP_Window_Info;
  Edge: Integer;
begin

  If ScaleMouseX > 0 Then Begin

    SetCapture(Handle);
    SetCaptureControl(Self);

    X := Round(X / ScaleMouseX);
    Y := Round(Y / ScaleMouseY);

    MOUSEX := X;
    MOUSEY := Y;
    Btn := Integer(ssLeft in Shift) + (2 * Integer(ssRight in Shift)) + (4 * Integer(ssMiddle in Shift));

    // Menus take precedence over everything

    If CURMENU <> -1 Then Begin

      If (ssRight in Shift) Then
        If Not (MENUSHOWING Or MENUBLOCK) Then Begin

          SP_DisplayMainMenu;
          SP_SetMenuSelection(X, Y, CURMENU);
          SP_InvalidateWholeDisplay;
          MENU_SHOWFLAG := True;
          Exit;

        End;

      If (ssLeft in Shift) Then
        If MENUSHOWING Then Begin

          SP_SetMenuSelection(X, Y, CURMENU);
          mi := SP_WhichItem(X, Y);
          LASTMENU := mi.MenuID;
          LASTMENUITEM := mi.ItemIdx;
          SP_DisplayMainMenu;
          SP_InvalidateWholeDisplay;
          Refresh_Display;
          MENUBLOCK := True;

          MENU_HIDEFLAG := True;
          Exit;

        End;

    End;

    // Now check for controls under the mouse
    // *** TO DO make windowmenu appear when right-clicking if not visible ***

    Handled := False;
    {$IFNDEF RUNTIMEONLY}
    CloseTipWindow;
    {$ENDIF}

    If ForceCapture Then Begin
      If CaptureControl.CanFocus Then
        CaptureControl.SetFocus(True);
      p := CaptureControl.ScreenToClient(Point(X, Y));
      If SP_CanInteract(CaptureControl) Then
        SP_BaseComponent(CaptureControl).MouseDown(SP_BaseComponent(CaptureControl), p.X, p.Y, Btn);
      Handled := True;
    End Else Begin
      Win := WindowAtPoint(X, Y, ID);  // X, Y become window-relative after this
      If Assigned(Win) Then Begin
        sPtr := pSP_Window_Info(Win);
        If sPtr^.Decorated And (ssLeft In Shift) Then Begin
          Edge := 0;
          If sPtr^.Resizable Then Begin
            If X < 2                     Then Edge := Edge Or 1;
            If X >= sPtr^.Width  - 2     Then Edge := Edge Or 2;
            If Y < 2                     Then Edge := Edge Or 4;
            If Y >= sPtr^.Height - 2     Then Edge := Edge Or 8;
            If (X >= sPtr^.Width - 8) And
               (Y >= sPtr^.Height - 8)   Then Edge := Edge Or 10;
          End;
          If (Edge = 0) And sPtr^.Draggable And (Y < sPtr^.CaptionHeight) Then Begin
            sPtr^.Dragging  := True;
            sPtr^.DragOffX  := MOUSEX - sPtr^.Left;
            sPtr^.DragOffY  := MOUSEY - sPtr^.Top;
            SwitchFocusedWindow(ID);
            Handled := True;
          End Else If Edge <> 0 Then Begin
            sPtr^.Resizing    := True;
            sPtr^.ResizeEdge  := Edge;
            sPtr^.ResizeOrigX := sPtr^.Left;
            sPtr^.ResizeOrigY := sPtr^.Top;
            sPtr^.ResizeOrigW := sPtr^.Width;
            sPtr^.ResizeOrigH := sPtr^.Height;
            sPtr^.ResizeMouseX := MOUSEX;
            sPtr^.ResizeMouseY := MOUSEY;
            SwitchFocusedWindow(ID);
            Handled := True;
          End;
        End;
        If Not Handled Then Begin
          If not TestForWindowMenu(Nil, Shift) Then Begin
            If Not (SYSTEMSTATE in [SS_EDITOR, SS_DIRECT, SS_EVALUATE]) and (MODALWINDOW = -1) Then
              SwitchFocusedWindow(ID); // The editor handles this.
            Win := ControlAtPoint(Win, X, Y);
            If Assigned(Win) Then Begin
              if pSP_BaseComponent(Win)^.Enabled Then Begin
                CaptureControl := pSP_BaseComponent(Win)^;
                If CaptureControl.CanFocus Then
                  CaptureControl.SetFocus(True);
                If SP_CanInteract(CaptureControl) Then
                  SP_BaseComponent(CaptureControl).MouseDown(SP_BaseComponent(CaptureControl), X, Y, Btn);
                Handled := True;
              End;
            End Else Begin
              If Assigned(CaptureControl) And SP_CanInteract(CaptureControl) Then
                SP_BaseComponent(CaptureControl).MouseDown(SP_BaseComponent(CaptureControl), X, Y, Btn);
              If Assigned(FocusedControl) And (MODALWINDOW = -1) And ((FocusedControl Is SP_PopUpMenu) or (FocusedControl is SP_WindowMenu)) Then
                FocusedControl.SetFocus(False);
            End;
          End;
        End;
      End;
    End;

    // Finally, pass the mouse event to the interpreter

    If Not Handled Then Begin
      MOUSEBTN := Btn;
      M_DOWNFLAG := True;
    End;

  End;

end;

procedure TMain.FormMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
Var
  Win: Pointer;
  p: TPoint;
  LMenu, LItem, Btn, tX, tY, ID, Dx, Dy, NewX, NewY, NewW, NewH: Integer;
  Handled: Boolean;
  sPtr: pSP_Window_Info;
  BankIdx: Integer;
  Err: TSP_ErrorCode;
begin

  If ((X = LastMouseX) And (Y = LastMouseY)) or SIZINGMAIN or (ScaleMouseX = 0) Then Exit;

  Handled := False;
  LastMouseX := X;
  LastMouseY := Y;
  If ScaleMouseX > 0 Then
    X := Round(X / ScaleMouseX);
  If ScaleMouseY > 0 Then
    Y := Round(Y / ScaleMouseY);
  If (X = LastScaledMouseX) And (Y = LastScaledMouseY) Then Exit;
  LastScaledMouseX := X;
  LastScaledMouseY := Y;

  Btn := Integer(ssLeft in Shift) + (2 * Integer(ssRight in Shift)) + (4 * Integer(ssMiddle in Shift));
  M_DELTAX := X - MOUSEX;
  M_DELTAY := Y - MOUSEY;
  MOUSEX := X;
  MOUSEY := Y;

  SP_SetDirtyRect(Min(MOUSEX, MOUSESTOREX), Min(MOUSEY, MOUSESTOREY), Max(MOUSEX+MOUSEW, MOUSESTOREX+MOUSESTOREW), Max(MOUSEY+MOUSEH, MOUSESTOREY+MOUSESTOREH));
  SP_NeedDisplayUpdate := True;

  // Decorated window drag/resize
  For BankIdx := 0 To Length(SP_BankList) -1 Do Begin
    If SP_BankList[BankIdx]^.DataType <> SP_WINDOW_BANK Then Continue;
    sPtr := @SP_BankList[BankIdx].Info[0];
    If sPtr^.Dragging Then Begin
      Err.Code := SP_ERR_OK;
      SP_MoveWindow(sPtr^.ID, MOUSEX - sPtr^.DragOffX, MOUSEY - sPtr^.DragOffY, Err);
      SP_NeedDisplayUpdate := True;
      Handled := True;
      Break;
    End;
    If sPtr^.Resizing Then Begin
      DX   := MOUSEX - sPtr^.ResizeMouseX;
      DY   := MOUSEY - sPtr^.ResizeMouseY;
      NewX := sPtr^.ResizeOrigX;
      NewY := sPtr^.ResizeOrigY;
      NewW := sPtr^.ResizeOrigW;
      NewH := sPtr^.ResizeOrigH;
      If sPtr^.ResizeEdge And 1 <> 0 Then Begin  // left edge
        NewX := sPtr^.ResizeOrigX + DX;
        NewW := sPtr^.ResizeOrigW - DX;
      End;
      If sPtr^.ResizeEdge And 2 <> 0 Then         // right edge
        NewW := sPtr^.ResizeOrigW + DX;
      If sPtr^.ResizeEdge And 4 <> 0 Then Begin   // top edge
        NewY := sPtr^.ResizeOrigY + DY;
        NewH := sPtr^.ResizeOrigH - DY;
      End;
      If sPtr^.ResizeEdge And 8 <> 0 Then         // bottom edge
        NewH := sPtr^.ResizeOrigH + DY;
      // clamp to minimum size
      If NewW < 40 Then Begin
        NewW := 40;
        If sPtr^.ResizeEdge And 1 <> 0 Then
          NewX := sPtr^.ResizeOrigX + sPtr^.ResizeOrigW - 40;
      End;
      If NewH < sPtr^.CaptionHeight + 10 Then Begin
        NewH := sPtr^.CaptionHeight + 10;
        If sPtr^.ResizeEdge And 4 <> 0 Then
          NewY := sPtr^.ResizeOrigY + sPtr^.ResizeOrigH - (sPtr^.CaptionHeight + 10);
      End;
      Err.Code := SP_ERR_OK;
      If (NewX <> sPtr^.Left) Or (NewY <> sPtr^.Top) Then
        SP_MoveWindow(sPtr^.ID, NewX, NewY, Err);
      If (NewW <> sPtr^.Width) Or (NewH <> sPtr^.Height) Then
        SP_ResizeWindow(sPtr^.ID, NewW, NewH, -1, SPFULLSCREEN, False, Err);
      If sPtr^.ID = SCREENBANK Then
        SP_WindowResizeFlag := sPtr^.ID;
      SP_NeedDisplayUpdate := True;
      Handled := True;
      Break;
    End;
  End;

  If (CURMENU <> -1) And (ssRight in Shift) And MENUSHOWING Then Begin

    LMenu := LASTMENU;
    LItem := LASTMENUITEM;
    SP_SetMenuSelection(X, Y, CURMENU);
    SP_InvalidateWholeDisplay;
    SP_NeedDisplayUpdate := True;

    If (LMenu <> LASTMENU) or (LItem <> LASTMENUITEM) Then
      MENU_HIGHLIGHTFLAG := True;

  End Else

    If (Assigned(CaptureControl) or MOUSEVISIBLE) And Not SIZINGMAIN Then Begin

      // Now check for controls under the mouse

      Handled := False;
      If DisplaySection.TryEnter Then Begin

        tX := X; tY := Y;
        {$IFNDEF RUNTIMEONLY}
        If TipWindowID <> -1 Then CheckForTip(tx, ty);
        {$ENDIF}
        Win := WindowAtPoint(tX, tY, ID);

        If Assigned(Win) Then Begin
          Win := ControlAtPoint(Win, tX, tY);
          If Not Assigned(Win) Or (MouseControl <> pSP_BaseComponent(Win)^) Then
            If Assigned(MouseControl) And SP_CanInteract(MouseControl) Then
              MouseControl.MouseLeave;
        End;
        If Assigned(CaptureControl) And CaptureControl.Visible Then Begin
          p := CaptureControl.ScreenToClient(Point(x, y));
          If SP_CanInteract(CaptureControl) Then Begin
            CaptureControl.PreMouseMove(p.x, p.y, Btn);
            Handled := True;
          End;
        End Else Begin
          If Assigned(Win) And pSP_BaseComponent(Win)^.Enabled Then Begin
            If MouseControl <> pSP_BaseComponent(Win)^ Then Begin
              MouseControl := pSP_BaseComponent(Win)^;
              p := MouseControl.ScreenToClient(Point(tX, tY));
              If SP_CanInteract(MouseControl) Then
                MouseControl.MouseEnter(p.X, p.Y);
            End;
            If SP_CanInteract(pSP_BaseComponent(Win)^) Then
              pSP_BaseComponent(Win)^.PreMouseMove(tX, tY, Btn);
            Handled := True;
          End Else
            If Assigned(MouseControl) And SP_CanInteract(MouseControl) Then
              MouseControl.MouseLeave;
        End;

      End;

      DisplaySection.Leave;

    End;

    // Fall through to allow user code to get mousemove events

  If Not Handled Then Begin
    M_MOVEFLAG := True;
    MOUSEBTN := Btn;
  End;

end;

procedure TMain.FormMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
Var
  mi: SP_MenuSelection;
  Win: Pointer;
  Btn, ID, BankIdx: Integer;
  p: TPoint;
  Handled: Boolean;
  sPtr: pSP_Window_Info;
begin

  ReleaseCapture;

  If ScaleMouseX = 0 Then Exit;
  X := Round(X / ScaleMouseX);
  Y := Round(Y / ScaleMouseY);

  MOUSEX := X;
  MOUSEY := Y;

  Case Button of
    mbLeft: Btn := 1;
    mbMiddle: Btn := 4;
    mbRight: Btn := 2;
  Else
    Btn := 0;
  End;

  For BankIdx := 0 To Length(SP_BankList) -1 Do Begin
    If SP_BankList[BankIdx]^.DataType <> SP_WINDOW_BANK Then Continue;
    sPtr := @SP_BankList[BankIdx].Info[0];
    If sPtr^.Dragging Or sPtr^.Resizing Then Begin
      sPtr^.Dragging := False;
      sPtr^.Resizing := False;
//      SP_Decorate_User_Window(sPtr^.ID);
      SP_NeedDisplayUpdate := True;
    End;
  End;

  // Menus take precedence

  If (CURMENU <> -1) And (Not (ssRight in Shift)) And MENUSHOWING Then Begin

    SP_SetMenuSelection(X, Y, CURMENU);
    mi := SP_WhichItem(X, Y);
    LASTMENU := mi.MenuID;
    LASTMENUITEM := mi.ItemIdx;
    SP_DisplayMainMenu;
    SP_InvalidateWholeDisplay;
    SP_NeedDisplayUpdate := True;

    MENU_HIDEFLAG := True;

  End Else Begin

    // Now check for controls under the mouse

    Handled := TestForWindowMenu(Nil, Shift);
    If Assigned(CaptureControl) Then Begin
      p := CaptureControl.ScreenToClient(Point(x, y));
      If SP_CanInteract(CaptureControl) Then
        CaptureControl.MouseUp(CaptureControl, p.x, p.y, Btn);
      If Not ForceCapture Then
        CaptureControl := Nil;
      Handled := True;
    End Else Begin
      Win := WindowAtPoint(X, Y, ID);
      If Assigned(Win) Then Begin
        Win := ControlAtPoint(Win, X, Y);
        If Assigned(Win) And pSP_BaseComponent(Win)^.Enabled And SP_CanInteract(pSP_BaseComponent(Win)^) Then Begin
          pSP_BaseComponent(Win)^.MouseUp(pSP_BaseComponent(Win)^, X, Y, Btn);
          Handled := True;
        End;
      End;
    End;

    // Finally, pass the mouse event to the interpreter

    MOUSEBTN := MOUSEBTN And Not Btn;
    If Not Handled Then Begin
      M_UPFLAG := True;
    End;

  End;

  MENUBLOCK := (ssRight in Shift);

end;

Procedure TMain.FormActivate(Sender: TObject);
begin
  FormActivated := True;
  SP_SysVars.FOCUSED := True;
end;

procedure TMain.FormCanResize(Sender: TObject; var NewWidth, NewHeight: Integer; var Resize: Boolean);
var
  nw, nh{, sw, sh}: Integer;
  {Error: TSP_ErrorCode;}
begin

  Exit; // Not yet

  if WindowState = wsMinimized Then Begin
    Resize := False;
  End Else
    If MainCanResize Then Begin
      DisplaySection.Enter;
      NewHeight := Round(NewWidth * (Height / Width));
      nw := NewWidth - (Width - ClientWidth);
      nh := NewHeight - (Height - ClientHeight);
  {    sw := Ceil(nw * (DISPLAYWIDTH/SCALEWIDTH));
      sh := Ceil(nh * (DISPLAYHEIGHT/SCALEHEIGHT));
      SetScreen(sw, sh, nw, nh, SPFULLSCREEN);
      SP_ResizeWindow(0, sw, sh, -1, SPFULLSCREEN, Error);}
      SetScreen(DISPLAYWIDTH, DISPLAYHEIGHT, nw, nh, SPFULLSCREEN, True);
      SP_InvalidateWholeDisplay;
      SP_NeedDisplayUpdate := True;
      DisplaySection.Leave;
    End;

end;

Procedure TMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin

  PLAYSignalHalt(-1);
  If Not QUITMSG Then Begin
    Quitting := True;
    QUITMSG := True;
    BREAKSIGNAL := True;
    SP_WaitForSecondaries;
  End;

  While InterpreterThreadAlive {$IFDEF RefreshThread} And RefreshThreadAlive{$ENDIF} Do
    CB_YIELD(1);

  PARAMS.Free;

end;

Procedure MouseMoveTo(ToX, ToY: Integer);
var
  p: TPoint;
Begin

  // Convert to native coords from virtual

  p := Main.ClientToScreen(Point(0, 0));
  ToX := Round(p.x + (ToX * ScaleMouseX));
  ToY := Round(p.y + (Toy * ScaleMouseY));
  SetCursorPos(ToX, ToY);

End;

Procedure SetWindowCaption;
Var
  s: aString;
Begin
  if WCAPTION <> '' Then
    s := WCAPTION
  Else
    s := aString(ChangeFileExt(ExtractFilename(ParamStr(0)), ''));
  CaptionString := String(s);
  Main.Caption := CaptionString;
End;

{$IFDEF FPC}
Procedure TMain.AppDropFiles(Sender: TObject; const FileNames: array of String);
Var
  sl: TStringList;
  paste, s: aString;
  i: Integer;
Begin
  sl := TStringList.Create;
  For i := 0 To Length(FileNames) -1 Do
    sl.Add(FileNames[i]);
  s := Filenames[0];
  sl.LoadFromHost(String(s));
  Paste := '';
  If sl.Count > 0 Then Begin
    if sl[0] = 'ZXASCII' Then Begin
      for i := 0 To sl.Count -1 Do Begin
        s := aString(sl[i]);
        If (Copy(s, 1, 7) <> 'ZXASCII') and (Copy(s, 1, 4) <> 'AUTO') and (Copy(s, 1, 4) <> 'PROG') and (Copy(s, 1, 7) <> 'CHANGED') Then
          paste := paste + s + #13#10;
      End;
    End;
    {$IFNDEF RUNTIMEONLY}
    FPBASICEditor.SetFocus(True);
    FPBASICEditor.InsertText(paste);
    FPBASICEditor.EnsureCursorVisible;
    FPBASICEditor.Paint;
    {$ENDIF}
  end;
  sl.Free;
End;
{$ENDIF}

procedure TMain.FormCreate(Sender: TObject);
Var
  Path: Array [0..MAX_PATH] of Char;
  idx: Integer;
  p: TPoint;
  s, dir: String;
  {$IFDEF UNIX}
  ts: TimeSpec;
  {$ENDIF}
begin

  {$IFDEF FPC}
  SP_Display.GLControl := TOpenGLControl.Create(Self);
  SP_Display.GLControl.Parent := Self;
  SP_Display.GLControl.Align := alClient;
  SP_Display.GLControl.AutoResizeViewport := False;
  SP_Display.GLControl.MultiSampling := 0;  // no MSAA - we don't need it
  SP_Display.GLControl.Cursor := crNone;
  SP_Display.GLControl.OnMouseMove  := Main.FormMouseMove;   // forward to existing handler
  SP_Display.GLControl.OnMouseDown  := Main.FormMouseDown;
  SP_Display.GLControl.OnMouseUp    := Main.FormMouseUp;
  SP_Display.GLControl.OnMouseWheelDown := Main.FormMouseWheelDown;
  SP_Display.GLControl.OnMouseWheelUp := Main.FormMouseWheelUp;
  SP_Display.GLControl.OnKeyDown    := Main.FormKeyDown;
  SP_Display.GLControl.OnKeyUp      := Main.FormKeyUp;
  SP_Display.GLControl.OnKeyPress   := Main.FormKeyPress;
  {$ENDIF}

  {$IFDEF FPC}
  Application.OnDropFiles := AppDropFiles;
  {$ELSE}
  DragAcceptFiles(Handle, True);
  {$ENDIF}

  INSTARTUP := True;
  HELPFILE := '/specbas.guide';

  DisplaySection.Enter;

  SP_GetMonitorMetrics;
  OrgWidth := REALSCREENWIDTH;
  OrgHeight := REALSCREENHEIGHT;

  MOUSEVISIBLE := FALSE;

  EXENAME := ParamStr(0);
  PayLoad := TPayLoad.Create(EXENAME);
  PAYLOADPRESENT := PayLoad.HasPayLoad;
  If Not PAYLOADPRESENT Then
    PayLoad.Free;

  {$IFDEF OPENGL}
  DisplayFlip := False;
  {$ENDIF}
  If Not PAYLOADPRESENT Then Begin
    PCOUNT := -1;
    PARAMS := TStringList.Create;
    For Idx := 0 To ParamCount Do Begin
      s := ParamStr(Idx);
      {$IFDEF OPENGL}
      If s = 'flip' then
        DisplayFlip := True
      Else
      {$ENDIF}
        if Copy(s, 1, 1) <> '-' then Begin
          if FileExists(s) then Begin
            PARAMS.Add(aString(s));
            Inc(PCOUNT);
          End;
        End Else Begin
          PARAMS.Add(aString(s));
          Inc(PCOUNT);
        End;
    End;

    dir := GetCurrentDir;
    If (PCOUNT = 0) And FileExists(dir + PathDelim + 'autorun') Then Begin
      PCOUNT := 1;
      PARAMS.Add(aString(dir)+ PathDelim + 'autorun');
    End;

  End;

  Cursor := CrNone;

  {$IFNDEF UNIX}
  SetPriorityClass(GetCurrentProcess, $8000{ABOVE_NORMAL_PRIORITY_CLASS});
  TimeBeginPeriod(10);
  baseTime := TimeGetTime;
  {$ELSE}
  clock_gettime(CLOCK_MONOTONIC, @ts);
  baseTime := (ts.tv_sec * 1000.0) + (ts.tv_nsec / 1000000.0);
  {$ENDIF}
  InitTime := Round(GetTicks);

  If Not PAYLOADPRESENT Then Begin

    {$IFNDEF UNIX}
      BUILDSTR := aString(Sto_GetFmtFileVersion('', '%d.%d.%d.%d'));
      If IsDebuggerPresent Then UpdateLinuxBuildStr;
    {$ELSE}
      BUILDSTR := '0.0.0.0';
    {$ENDIF}
    {$IFDEF OPENGL}
      BUILDSTR := BUILDSTR + '-GL';
    {$ENDIF}
    {$IFDEF WIN64}
      BUILDSTR := BUILDSTR + ' x64';
    {$ENDIF}
    {$IFDEF DEBUG}
      BUILDSTR := BUILDSTR + ' [Debug';
    {$ENDIF}
    {$IFNDEF FPC}
    if (DebugHook <> 0) or IsDebuggerPresent then BUILDSTR := BUILDSTR + ' IDE';
    {$ENDIF}
    {$IFDEF DEBUG}
      BUILDSTR := BUILDSTR + ']';
    {$ENDIF}

    // Set the HOME folder - if we're loading a parameter file, extract the
    // directory and set that as HOMEFOLDER

    If PCOUNT <= 0 Then Begin
      {$IFNDEF FPC}
      CaptionString := 'SpecBAS for Windows v';
      Main.Caption := CaptionString + String(BuildStr);
      SHGetFolderPath(0,$0028,0,SHGFP_TYPE_CURRENT,@path[0]);
      HOMEFOLDER := aString(Path) + aString(PathDelim + 'specbas');
      {$ELSE}
      CaptionString := 'SpecBAS v';
      Main.Caption := CaptionString + String(BuildStr);
      HOMEFOLDER := aString(GetUserDir) + aString('specbas');
      {$ENDIF}

    End Else Begin

      CaptionString := ExtractFileName(String(PARAMS[1]));
      Main.Caption := CaptionString;
      HOMEFOLDER := aString(ExtractFileDir(String(PARAMS[1])));
      If HOMEFOLDER = '' Then
        HOMEFOLDER := aString(GetCurrentDir);

    End;

  End Else Begin

    SetCurrentDir(ExtractFilePath(EXENAME));
    HOMEFOLDER := aString(GetCurrentDir);

  End;

  If Not DirectoryExists(String(HOMEFOLDER)) Then
    CreateDir(String(HOMEFOLDER));
  If Not DirectoryExists(String(HOMEFOLDER) + PathDelim + 'temp') Then
    CreateDir(String(HOMEFOLDER) + PathDelim + 'temp');
  TEMPDIR := HOMEFOLDER + aString(PathDelim + 'temp' + PathDelim);
  SetCurrentDir(String(HOMEFOLDER));
  HOMEFOLDER := Lower(HOMEFOLDER);
  If HOMEFOLDER[Length(HOMEFOLDER)] <> aChar(PathDelim) Then
    HOMEFOLDER := HOMEFOLDER + aChar(PathDelim);

  AUTOSAVE := Not PAYLOADPRESENT;

  ScrWidth := 800;
  ScrHeight := 480;
  SCALEWIDTH := 800;
  SCALEHEIGHT := 480;
  MENUBLOCK := False;

  Application.OnActivate := OnActivate;
  Application.OnDeactivate := OnDeactivate;

  // Initialise callbacks

  CB_DecorateWindow := SP_Decorate_User_Window;
  CB_GetKeyLockState := GetKeyState;
  CB_Refresh_Display := Refresh_Display;
  CB_Quit := MainForm.Quit;
  CB_SetScreenRes := SetScreen;
  CB_Test_Resolution := TestScreenResolution;
  CB_GetTicks := GetTicks;
  CB_Yield := YieldProc;
  CB_Load_Image := LoadImage;
  CB_Save_Image := SaveImage;
  CB_Free_Image := FreeImageResource;
  CB_Messages := MsgProc;
  CB_MouseMove := MouseMoveTo;
  CB_SETWINDOWCAPTION := SetWindowCaption;
  {$IFDEF RefreshThread}
  CB_PauseDisplay := PauseDisplay;
  CB_ResumeDisplay := ResumeDisplay;
  {$ENDIF}

  // Start graphics server

  SP_SetFPS(GetScreenRefreshrate);
  SP_InitialGFXSetup(ScrWidth, ScrHeight, False);
  SP_GetMonitorMetrics;
  SetBounds((REALSCREENWIDTH - Width) Div 2, (REALSCREENHEIGHT - Height) Div 2, Width, Height);

  {$IFDEF RefreshThread}
  RefreshTimer := TRefreshThread.Create(False);
  {$ENDIF}

  WINLEFT := Left;
  WINTOP := Top;

  // Launch the interpreter

  SP_CLS(CPAPER);
  EDITLINE := '';
  CURSORPOS := 0;
  CURSORCHAR := 32;
  SYSTEMSTATE := SS_IDLE;

  SoundEnabled := LoadLibrary(bassdll) <> 0;
  SP_Init_Sound;

  CORECOUNT := System.CPUCount;

  BASThread := TSpecBAS_Thread.Create(True);
  {$IFNDEF FPC}
  Application.OnMessage := OnAppMessage;
  {$ENDIF}

  {$IF DEFINED(RefreshThread) AND NOT DEFINED(FPC)}
  SetThreadAffinityMask(RefreshTimer.ThreadID, 4);
  {$ENDIF}

  DisplaySection.Leave;

  BASThread.Start;

  GetCursorPos(p);
  p := Main.ScreenToClient(p);
  MouseInForm := PtInRect(Main.ClientRect, p);

  {$IFNDEF RefreshThread}
  Application.OnIdle := OnIdle;
  {$ENDIF}
  Activate;

end;

procedure TMain.FormDeactivate(Sender: TObject);
begin
  FormActivated := False;
  SP_SysVars.FOCUSED := False;
  SP_ClearAllKeys;
end;

Procedure TMain.FormDestroy(Sender: TObject);
Var
  Error: TSP_ErrorCode;
begin

  Quitting := True;

  If SoundEnabled Then
    BASS_Free;

  If PAYLOADPRESENT or (PCOUNT <> 0) Then Begin
    SP_RmDirUnSafe('/temp', Error);
    SP_RmDir('/s', Error);
    SP_RmDir('/fonts', Error);
    SP_RmDir('/keyboards', Error);
    SP_RmDir('/include', Error);
  End;

  DisplaySection.Enter;

  Bitmap.Free;
  SetScreenResolution(OrgWidth, OrgHeight, False);
  {$IFDEF OpenGL}
  CloseGL;
  {$ENDIF}

  DisplaySection.Leave;

  SP_FinalizeThreadVars;

  {$IFNDEF FPC}
  TimeEndPeriod(10);
  {$ENDIF}

end;

{$IFDEF FPC}
Function TMain.GetCharFromVirtualKey(Var Key: Word): aString;
Begin
  Result := '';
End;
{$ELSE}
Function TMain.GetCharFromVirtualKey(Var Key: Word): astring;
var
  keyboardState: TKeyboardState;
  asciiResult: Integer;
begin

  GetKeyboardState(keyboardState);

  // Filter out the CTRL key - it'll be picked up later.

  If KeyboardState[18] < 128 Then
    KeyBoardState[17] := 0;

  SetLength(Result, 2);
  asciiResult := ToAscii(key, MapVirtualKey(key, 0), KeyboardState, @Result[1], 0);
  case asciiResult of
    0: If Key < 32 Then Result := aChar(Key) Else Result := '';
    1: SetLength(Result, 1);
    2: Result := '';
    else
      Result := '';
  end;

  If Result <> '' Then Begin
    Case Ord(Result[1]) of
      194, 163: Result := #$60;
      96:  Result := #$7F;
    End;
  End;

end;
{$ENDIF}

procedure TMain.CMDialogKey(var msg: TCMDialogKey);
begin
  if msg.Charcode <> VK_TAB then
    inherited;
end;

procedure TMain.FormKeyPress(Sender: TObject; var Key: Char);
{$IFDEF FPC}
Begin
  If PendingKeyValid And (Key >= ' ') And (Key <> #127) Then Begin
    PendingKeyInfo.KeyChar := aChar(Key);
    PendingKeyValid := False;
    If ControlsAreInUse Then Begin
      DisplaySection.Enter;
      If ControlKeyEvent(PendingKeyInfo.KeyChar, PendingKeyInfo.KeyCode,
                         True, PendingKeyInfo.IsKey) Then Begin
        DisplaySection.Leave;
        Key := #0;
        Exit;
      End Else
        DisplaySection.Leave;
    End;
    SP_AddKey(PendingKeyInfo);
  End;
  Key := #0;
End;
{$ELSE}
Begin
  Key := #32;
End;
{$ENDIF}

{$IFNDEF FPC}
procedure TMain.WMMenuChar(var MessageRec: TWMMenuChar);
Begin
  if IgnoreNextMenuChar Then Begin
    MessageRec.Result := MakeLong(0, 1);
    IgnoreNextMenuChar := False;
  End;
End;
{$ENDIF}

procedure TMain.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
Var
  k: Word;
  aStr: aString;
  kInfo: SP_KeyInfo;
begin

  If Key = K_PAUSE Then Begin // the BREAK key on PC keyboards always saves a screengrab.
    ScreenShot(False);
    Exit;
  End;

  aStr := aString(GetCharFromVirtualKey(Key));
  If (aStr = '') or (aStr[1] < ' ') Then aStr := #0;

  kInfo.CanRepeat := True;
  kInfo.IsKey := True;
  kInfo.KeyChar := aStr[1];
  kInfo.KeyCode := Key And $7F;
  kInfo.NextFrameTime := FRAMES;
  kInfo.WindowID := FocusedWindow;

  {$IFDEF FPC}
  If Not (Key In [VK_ESCAPE, VK_BACK, VK_TAB, VK_RETURN,
                  VK_F1, VK_F2, VK_F3, VK_F4, VK_F5, VK_F6,
                  VK_F7, VK_F8, VK_F9, VK_F10, VK_F11, VK_F12,
                  VK_LEFT, VK_RIGHT, VK_UP, VK_DOWN,
                  VK_INSERT, VK_DELETE, VK_HOME, VK_END,
                  VK_PRIOR, VK_NEXT, VK_CAPITAL, VK_NUMLOCK,
                  VK_SCROLL, VK_SHIFT, VK_CONTROL, VK_MENU,
                  VK_LSHIFT, VK_RSHIFT, VK_LCONTROL, VK_RCONTROL,
                  VK_LMENU, VK_RMENU]) Then Begin
    PendingKeyInfo  := kInfo;
    PendingKeyValid := True;
    Exit;
  End;
  {$ENDIF}

  If Key = $12 Then Begin // ALT went down

    AltDown := True;
    AltChars := '';

  End Else Begin

    If AltDown then Begin

      If Key in [K_NUMPAD0..K_NUMPAD9, K_0..K_9] Then Begin

        if Key in [K_NUMPAD0..K_NUMPAD9] Then
          k := Key - K_NUMPAD0
        else
          k := Key - K_0;

        IgnoreNextMenuChar := True;
        AltChars := AltChars + IntToString(k);
        If Length(AltChars) = 3 Then Begin
          kInfo.KeyCode := StringToInt(AltChars);
          kInfo.keyChar := aChar(kInfo.KeyCode);
          kInfo.CanRepeat := False;
          kInfo.IsKey := False;
          ALtChars := '';
        End Else Begin
          Key := 0;
          Exit;
        End;

      End;

    End;

  End;

  If ControlsAreInUse Then Begin
    DisplaySection.Enter;
    If ControlKeyEvent(kInfo.KeyChar, kInfo.KeyCode, True, kInfo.IsKey) Then Begin
      DisplaySection.Leave;
      Exit;
    End Else
      DisplaySection.Leave;
  End;

  SP_AddKey(kInfo);

  Key := 0;

end;

Procedure TMain.FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
Begin
  KEYSTATE[Key] := 0;
  cKEYSTATE[Key And $7F] := 0;        // always clear - can't be skipped
  ControlKeyEvent(#0, Key And $7F, False, True);
  SP_RemoveKey(Key And $7F);

  If AltDown And (Key = $12) Then Begin
    AltDown := False;
    SP_RemoveKey(StringToInt(AltChars));
    AltChars := '';
  End;
End;

procedure TMain.FormMouseWheelDown(Sender: TObject; Shift: TShiftState; MousePos: TPoint; var Handled: Boolean);
Var
  p: TPoint;
  Win: Pointer;
  cp: pSP_BaseComponent;
  Ctrl: SP_BaseComponent;
  X, Y, Btn, ID: Integer;
begin

  X := MOUSEX;
  Y := MOUSEY;
  Btn := Integer(ssLeft in Shift) + (2 * Integer(ssRight in Shift)) + (4 * Integer(ssMiddle in Shift));

  Handled := False;
  DisplaySection.Enter;

  If Assigned(CaptureControl) Then Begin
    p := CaptureControl.ScreenToClient(Point(x, y));
    CaptureControl.MouseMove(CaptureControl, p.x, p.y, Btn);
  End Else Begin
    Win := WindowAtPoint(X, Y, ID);
    If Assigned(Win) Then Begin
      cp := ControlAtPoint(Win, X, Y);
      If Assigned(cp) Then Begin
        Ctrl := cp^;
        While Assigned(Ctrl) And Not Handled Do Begin
          Ctrl.MouseWheel(Ctrl, X, Y, Btn, 1, Handled);
          If Not Handled Then
            If Ctrl.fParentType = spWindow Then
              Ctrl := Nil
            Else
              Ctrl := Ctrl.GetParentControl;
        End;
      End;
    End;
  End;

  DisplaySection.Leave;

  If Not Handled Then Begin
    M_WHEELDNFLAG := True;
    Inc(MOUSEWHEEL);
  End;

end;

procedure TMain.FormMouseWheelUp(Sender: TObject; Shift: TShiftState; MousePos: TPoint; var Handled: Boolean);
Var
  p: TPoint;
  Win: Pointer;
  cp: pSP_BaseComponent;
  Ctrl: SP_BaseComponent;
  X, Y, Btn, ID: Integer;
begin

  X := MOUSEX;
  Y := MOUSEY;
  Btn := Integer(ssLeft in Shift) + (2 * Integer(ssRight in Shift)) + (4 * Integer(ssMiddle in Shift));

  Handled := False;
  DisplaySection.Enter;

  If Assigned(CaptureControl) Then Begin
    p := CaptureControl.ScreenToClient(Point(x, y));
    CaptureControl.MouseMove(CaptureControl, p.x, p.y, Btn);
  End Else Begin
    Win := WindowAtPoint(X, Y, ID);
    If Assigned(Win) Then Begin
      cp := ControlAtPoint(Win, X, Y);
      If Assigned(cp) Then Begin
        Ctrl := cp^;
        While Assigned(Ctrl) And not Handled Do Begin
          Ctrl.MouseWheel(Ctrl, X, Y, Btn, -1, Handled);
          If Not Handled Then
            If Ctrl.fParentType = spWindow Then
              Ctrl := Nil
            Else
              Ctrl := Ctrl.GetParentControl;
        End;
      End;
    End;
  End;

  DisplaySection.Leave;

  If Not Handled Then Begin
    M_WHEELUPFLAG := True;
    Dec(MouseWheel);
  End;

end;

procedure TMain.FormPaint(Sender: TObject);
{$IFNDEF OPENGL}
Var
  H1, H2: HWnd;
{$ENDIF}
begin

  {$IFNDEF OPENGL}
  If DPtrBackup <> Nil Then Begin
    H1 := Canvas.Handle;
    H2 := Bitmap.Canvas.Handle;
    With Canvas.ClipRect Do
      StretchBlt(H1, Left, Top, WIDTH, HEIGHT, H2, Left, Top, DISPLAYWIDTH, DISPLAYHEIGHT, SrcCopy);
  End;
  {$ENDIF}

end;

procedure TMain.FormResize(Sender: TObject);
begin

  If Not (Quitting) Then Begin

    {$IFDEF OPENGL}

      {$IFDEF FPC}
      If Assigned(SP_Display.GLControl) Then
        SetScaling(DISPLAYWIDTH, DISPLAYHEIGHT,
                   SP_Display.GLControl.Width,
                   SP_Display.GLControl.Height);
      {$ENDIF}

      If WindowState = wsMinimized Then Begin
        Minimised := True;
        Exit;
      End Else
        If Minimised Then Begin
          Minimised := False;
          GLInitDone := False;
          SP_InvalidateWholeDisplay;
          SP_NeedDisplayUpdate := True;
          Exit;
        End;

      SP_Display.SetScaling(DISPLAYWIDTH, DISPLAYHEIGHT, Main.ClientWidth, Main.ClientHeight);
      GLResize;

    {$ELSE}

      SP_Display.SetScaling(DISPLAYWIDTH, DISPLAYHEIGHT, Main.ClientWidth, Main.ClientHeight);

    {$ENDIF}

  End;

  DPtrBackup := DISPLAYPOINTER;
  {$IFDEF RefreshThread}
  CB_ResumeDisplay;
  {$ENDIF}

end;

Procedure TMain.CreateGDIBitmap;
{$IFNDEF OPENGL}
Var
  {$IFDEF FPC}
  BmInfo: BITMAPINFO;
  {$ELSE}
  BmInfo: tagBITMAPINFO;
  {$ENDIF}
{$ENDIF}
Begin

  {$IFNDEF OPENGL}
  If Bitmap <> Nil Then Begin
    DeleteObject(Bitmap.Handle);
    Bitmap.Free;
    Bitmap := Nil;
  End;

  BmInfo.bmiHeader.biSize := SizeOf(tagBITMAPINFOHEADER);
  BmInfo.bmiHeader.biWidth := DISPLAYWIDTH;
  BmInfo.bmiHeader.biHeight := -DISPLAYHEIGHT;
  BmInfo.bmiHeader.biPlanes := 1;
  BmInfo.bmiHeader.biBitCount := 32;
  BmInfo.bmiHeader.biCompression := BI_RGB;

  Bitmap := TBitmap.Create();
  Bitmap.Width := DISPLAYWIDTH;
  Bitmap.Height := DISPLAYHEIGHT;
  Bitmap.HandleType := bmDIB;
  Bitmap.Handle := CreateDIBSection(Main.Canvas.Handle, BmInfo, DIB_RGB_COLORS, Bits, 0, 0);

  DISPLAYSTRIDE := DISPLAYWIDTH * (BmInfo.bmiHeader.biBitCount Div 8);
  DISPLAYPOINTER := Bits;
  {$ENDIF}

End;

procedure TMain.FormShow(Sender: TObject);
Begin

  {$IFDEF FPC}
  GLControl.MakeCurrent(True);  // Make current once on main thread
  {$ENDIF}
  SetFocus;

end;

Procedure Quit;
Begin
  Quitting := True;
  {$IFNDEF FPC}
  PostMessage(Main.Handle, WM_CLOSE, 0, 0);
  {$ELSE}
  Application.Terminate;
  {$ENDIF}
End;

Procedure GetKeyState;
Begin
  {$IFNDEF FPC}
  CAPSLOCK := Windows.GetKeyState(VK_CAPITAL) And 1;
  NUMLOCK  := Windows.GetKeyState(VK_NUMLOCK)  And 1;
  {$ELSE}
  CAPSLOCK := Ord(LCLIntf.GetKeyState(VK_CAPITAL) And 1 <> 0);
  NUMLOCK  := Ord(LCLIntf.GetKeyState(VK_NUMLOCK)  And 1 <> 0);
  {$ENDIF}
End;

Procedure YieldProc(const ms: aFloat); inline;
Begin

  SmartSleep(ms);
  LASTINKEYFRAME := FRAMES;

End;

Procedure MsgProc; inline;
Begin

  Application.ProcessMessages;

End;

function Sto_GetFmtFileVersion(const FileName: String = ''; const Fmt: String = '%d.%d'): String;
var
  sFileName: String;
  iBufferSize: DWORD;
  iDummy: DWORD;
  pBuffer: Pointer;
  pFileInfo: Pointer;
  iVer: array[1..4] of Word;
begin
  // set default value
  Result := '';
  // get filename of exe/dll if no filename is specified
  sFileName := Trim(FileName);
  if (sFileName = '') then
    sFileName := GetModuleName(HInstance);
  // get size of version info (0 if no version info exists)
  iBufferSize := GetFileVersionInfoSize(PChar(sFileName), iDummy);
  if (iBufferSize > 0) then
  begin
    GetMem(pBuffer, iBufferSize);
    try
    // get fixed file info (language independent)
    GetFileVersionInfo(PChar(sFileName), 0, iBufferSize, pBuffer);
    VerQueryValue(pBuffer, '\', pFileInfo, iDummy);
    // read version blocks
    iVer[1] := HiWord(PVSFixedFileInfo(pFileInfo)^.dwFileVersionMS);
    iVer[2] := LoWord(PVSFixedFileInfo(pFileInfo)^.dwFileVersionMS);
    iVer[3] := HiWord(PVSFixedFileInfo(pFileInfo)^.dwFileVersionLS);
    iVer[4] := LoWord(PVSFixedFileInfo(pFileInfo)^.dwFileVersionLS);
    finally
      FreeMem(pBuffer);
    end;
    // format result string
    Result := IntToStr(iVer[3])+ '.' + IntToStr(iVer[4]);
  end;
end;

{$IFDEF FPC}
// TFPReaderPNG exposes ColorType and BitDepth directly from the PNG IHDR chunk,
// which is the only reliable way to determine palette vs direct-colour depth.
// ColorType = 0: grayscale        -> 8bpp
// ColorType = 2: truecolour       -> 32bpp
// ColorType = 3: indexed/palette  -> 8bpp
// ColorType = 4: grayscale+alpha  -> 32bpp
// ColorType = 6: truecolour+alpha -> 32bpp
Type
  TPNGImage = TPortableNetworkGraphic;
{$ENDIF}

Procedure LoadImage(Filename: aString; Var Error: TSP_ErrorCode);
Var
  NewBmp:     TBitmap;
  Idx, y:     Integer;
  DPtr:       pByte;
  Ext,
  FirstBytes,
  OldFilename,
  tStr:       aString;
  FS:         TFileStream;
  MagicBuf:   Array[0..7] of Byte;
  {$IFNDEF FPC}
  Bmp:        TPicture;
  MaxPal:     TMaxLogPalette;
  r, g, b:    Byte;
  RGBQ:       Array[0..255] of RGBQUAD;
  {$ELSE}
  SrcBmp:    TBitmap;
  Jpg:       TJPEGImage;
  Gif:       TGIFImage;
  Reader:    TFPReaderPNG;
  FPStream:  TFileStream;
  FPImg:     TFPMemoryImage;
  Png:       TPortableNetworkGraphic;
  ColorType: Byte;
  BitDepth:  Byte;
  ColMap:   Array[0..255] Of LongWord;
  ColCount,
  ci:       Integer;
  Found:    Boolean;
  Row32:    pLongWord;
  pixel:    LongWord;
  {$ENDIF}
Begin

  OldFilename := '';

  If Not FileExists(String(Filename)) Then Begin
    Error.Code := SP_ERR_FILE_MISSING;
    Exit;
  End;

  // Detect format from magic bytes - never trust the file extension
  FS := TFileStream.Create(String(FileName), fmOpenRead Or fmShareDenyNone);
  FS.Read(MagicBuf[0], 8);
  FS.Free;
  SetLength(FirstBytes, 8);
  Move(MagicBuf[0], FirstBytes[1], 8);

  Ext := '';
  If Copy(FirstBytes, 1, 2) = 'BM'     Then Ext := '.bmp';
  If FirstBytes = #137'PNG'#13#10#26#10 Then Ext := '.png';
  If Copy(FirstBytes, 1, 3) = 'GIF'    Then Ext := '.gif';
  If Copy(FirstBytes, 1, 2) = #$FF#$D8 Then Ext := '.jpg';

  If Ext = '' Then Begin
    Error.Code := SP_ERR_UNSUPPORTED_IMAGE_FORMAT;
    Exit;
  End;

  // Rename to correct extension if needed so loaders can identify the format
  OldFilename := Filename;
  tStr := aString(ExtractFilename(String(Filename)));
  tStr := Copy(tStr, 1, Length(tStr) - Length(aString(ExtractFileExt(String(Filename)))));
  Filename := aString(ExtractFilePath(String(Filename))) + tStr + Ext;
  If Filename = OldFilename Then
    OldFilename := ''  // no rename needed, clear so we don't rename back at end
  Else
    RenameFile(String(OldFilename), String(Filename));

  ERRStr := Filename;

  NewBmp := TBitmap.Create;
  Try

    {$IFDEF FPC}

    // -------------------------------------------------------------------------
    // FPC / macOS path
    // Load each format directly into its concrete type to avoid TPicture's
    // deferred-initialisation issues on the Cocoa backend.
    // All formats are drawn onto a pf32Bit TBitmap as the common intermediate.
    // Depth (ImgBpp) is determined from authoritative format metadata, not
    // from PixelFormat which is unreliable after LCL normalisation.
    // -------------------------------------------------------------------------

    ImgBpp := 32;

    If Ext = '.png' Then Begin

      // Use TFPReaderPNG to read ColorType/BitDepth from the IHDR chunk.
      // This is the authoritative depth source - PixelFormat is unreliable.
      Begin
        FPImg  := TFPMemoryImage.Create(0, 0);
        Reader := TFPReaderPNG.Create;
        FPStream := TFileStream.Create(String(Filename), fmOpenRead Or fmShareDenyNone);
        Try
          Reader.ImageRead(FPStream, FPImg);
          ColorType := Reader.ColorType;
          BitDepth  := Reader.BitDepth;
        Finally
          FPStream.Free;
          Reader.Free;
          FPImg.Free;
        End;

        // ColorType 0 = grayscale, 3 = indexed palette -> 8bpp
        // ColorType 2 = truecolour, 4 = grey+alpha, 6 = truecolour+alpha -> 32bpp
        If (ColorType In [0, 3]) And (BitDepth <= 8) Then
          ImgBpp := 8;

        // Now load via TPortableNetworkGraphic for proper LCL canvas integration
        Png := TPortableNetworkGraphic.Create;
        Try
          Png.LoadFromFile(String(Filename));
          NewBmp.PixelFormat := pf32Bit;
          NewBmp.Width       := Png.Width;
          NewBmp.Height      := Png.Height;
          NewBmp.Canvas.Draw(0, 0, Png);
        Finally
          Png.Free;
        End;
      End;

    End Else If Ext = '.bmp' Then Begin

      SrcBmp := TBitmap.Create;
      Try
        SrcBmp.LoadFromFile(String(Filename));
        // TBitmap.PixelFormat is reliable for BMP files
        If SrcBmp.PixelFormat In [pf1Bit, pf4Bit, pf8Bit] Then
          ImgBpp := 8;
        NewBmp.PixelFormat := pf32Bit;
        NewBmp.Width       := SrcBmp.Width;
        NewBmp.Height      := SrcBmp.Height;
        NewBmp.Canvas.Draw(0, 0, SrcBmp);
      Finally
        SrcBmp.Free;
      End;

    End Else If (Ext = '.jpg') Or (Ext = '.jpeg') Then Begin

      // JPEG has no palette support - always 32bpp
      Jpg := TJPEGImage.Create;
      Try
        Jpg.LoadFromFile(String(Filename));
        NewBmp.PixelFormat := pf32Bit;
        NewBmp.Width       := Jpg.Width;
        NewBmp.Height      := Jpg.Height;
        NewBmp.Canvas.Draw(0, 0, Jpg);
      Finally
        Jpg.Free;
      End;

    End Else If Ext = '.gif' Then Begin

      // GIF is always palette/indexed - always 8bpp
      ImgBpp := 8;
      Gif := TGIFImage.Create;
      Try
        Gif.LoadFromFile(String(Filename));
        NewBmp.PixelFormat := pf32Bit;
        NewBmp.Width       := Gif.Width;
        NewBmp.Height      := Gif.Height;
        NewBmp.Canvas.Draw(0, 0, Gif);
      Finally
        Gif.Free;
      End;

    End Else Begin
      Error.Code := SP_ERR_UNSUPPORTED_IMAGE_FORMAT;
      Exit;
    End;

    // NewBmp is now pf32Bit BGRA with image drawn onto it.

    If ImgBpp = 8 Then Begin

      // 8bpp output: extract palette and build index array from 32bpp canvas.
      // A genuine palette image has <= 256 unique colours so the scan is exact.
      // pf32Bit scanline layout: byte0=B, byte1=G, byte2=R, byte3=A
      Begin
        ColCount := 0;
        FillChar(ColMap, SizeOf(ColMap), 0);

        // Pass 1: collect unique colours (ignore alpha byte)
        For y := 0 To NewBmp.Height - 1 Do Begin
          Row32 := pLongWord(NewBmp.Scanline[y]);
          For Idx := 0 To NewBmp.Width - 1 Do Begin
            pixel := (Row32 + Idx)^ And $00FFFFFF;
            Found := False;
            For ci := 0 To ColCount - 1 Do
              If ColMap[ci] = pixel Then Begin Found := True; Break; End;
            If Not Found Then Begin
              If ColCount < 256 Then Begin
                ColMap[ColCount] := pixel;
                Inc(ColCount);
              End;
              // If ColCount would exceed 256 something is wrong with the source
              // image - we carry on and clip, which is better than crashing.
            End;
          End;
        End;

        // Build ImgPalette from collected BGR values
        For ci := 0 To ColCount - 1 Do Begin
          ImgPalette[ci].B := (ColMap[ci]       ) And $FF;
          ImgPalette[ci].G := (ColMap[ci] Shr 8 ) And $FF;
          ImgPalette[ci].R := (ColMap[ci] Shr 16) And $FF;
        End;

        // Pass 2: build palette index array
        SetLength(ImgResource, NewBmp.Width * NewBmp.Height);
        DPtr := @ImgResource[0];
        ImgPtr := DPtr;
        For y := 0 To NewBmp.Height - 1 Do Begin
          Row32 := pLongWord(NewBmp.Scanline[y]);
          For Idx := 0 To NewBmp.Width - 1 Do Begin
            pixel := (Row32 + Idx)^ And $00FFFFFF;
            DPtr^ := 0; // default index 0 if not found (shouldn't happen)
            For ci := 0 To ColCount - 1 Do
              If ColMap[ci] = pixel Then Begin DPtr^ := ci; Break; End;
            Inc(DPtr);
          End;
        End;
        ImgStride := NewBmp.Width;
      End;

    End Else Begin

      // 32bpp output: copy BGRA scanlines directly
      SetLength(ImgResource, NewBmp.Width * NewBmp.Height * 4);
      DPtr := @ImgResource[0];
      ImgPtr := DPtr;
      For y := 0 To NewBmp.Height - 1 Do Begin
        CopyMem(DPtr, NewBmp.Scanline[y], NewBmp.Width * 4);
        Inc(DPtr, NewBmp.Width * 4);
      End;
      ImgStride := NewBmp.Width * 4;

      // Patch alpha=0 to $FF for formats that have no alpha channel.
      // PNG alpha is preserved as-is (may have genuine transparent pixels).
      If (Ext = '.jpg') Or (Ext = '.jpeg') Or
         (Ext = '.bmp') Or (Ext = '.gif') Then Begin
        DPtr := @ImgResource[3]; // first alpha byte
        For Idx := 0 To NewBmp.Width * NewBmp.Height - 1 Do Begin
          If DPtr^ = 0 Then DPtr^ := $FF;
          Inc(DPtr, 4);
        End;
      End;

    End;

    {$ELSE}

    // -------------------------------------------------------------------------
    // Delphi / Windows path - original TPicture-based code, unchanged.
    // -------------------------------------------------------------------------

    Bmp := TPicture.Create;
    Try

      Try
        Bmp.LoadFromFile(String(Filename));
      Except
        On E: Exception Do Begin
          Error.Code := SP_ERR_UNSUPPORTED_IMAGE_FORMAT;
          Exit;
        End;
      End;

      If (Bmp.Graphic = Nil) Or (Bmp.Graphic.Width = 0) Then Begin
        Error.Code := SP_ERR_UNSUPPORTED_IMAGE_FORMAT;
        Exit;
      End;

      ImgBpp := 32;
      If Bmp.Graphic Is TPngImage Then Begin
        If ((Bmp.Graphic As TPngImage).Header.ColorType = COLOR_PALETTE) Or
           ((Bmp.Graphic As TPngImage).Header.ColorType = COLOR_GRAYSCALE) Then
          ImgBpp := 8;
      End Else
        If Bmp.Graphic Is TBitmap Then Begin
          If (Bmp.Graphic As TBitmap).PixelFormat = pf8Bit Then
            ImgBpp := 8;
        End Else
          If Bmp.Graphic Is TGIFImage Then
            ImgBpp := 8;

      NewBmp.Width  := Bmp.Graphic.Width;
      NewBmp.Height := Bmp.Graphic.Height;

      If ImgBpp = 8 Then Begin

        SetLength(ImgResource, Bmp.Graphic.Width * Bmp.Graphic.Height);
        NewBmp.PixelFormat := pf8Bit;
        GetPaletteEntries(Bmp.Graphic.Palette, 0, 256, MaxPal.palPalEntry);
        For Idx := 0 To 255 Do Begin
          r := MaxPal.palPalEntry[Idx].peRed;
          g := MaxPal.palPalEntry[Idx].peGreen;
          b := MaxPal.palPalEntry[Idx].peBlue;
          ImgPalette[Idx].R := r;  RGBQ[Idx].rgbRed   := r;
          ImgPalette[Idx].G := g;  RGBQ[Idx].rgbGreen := g;
          ImgPalette[Idx].B := b;  RGBQ[Idx].rgbBlue  := b;
        End;
        SetDIBColorTable(NewBmp.Canvas.Handle, 0, 256, RGBQ);
        NewBmp.Canvas.Draw(0, 0, Bmp.Graphic);
        DPtr := @ImgResource[0];
        ImgPtr := DPtr;
        For y := 0 To NewBmp.Height - 1 Do Begin
          CopyMem(DPtr, NewBmp.Scanline[y], NewBmp.Width);
          Inc(DPtr, NewBmp.Width);
        End;
        ImgStride := NewBmp.Width;

      End Else Begin

        SetLength(ImgResource, Bmp.Graphic.Width * Bmp.Graphic.Height * 4);
        NewBmp.PixelFormat := pf32Bit;
        NewBmp.Canvas.Draw(0, 0, Bmp.Graphic);
        DPtr := @ImgResource[0];
        ImgPtr := DPtr;
        For y := 0 To NewBmp.Height - 1 Do Begin
          CopyMem(DPtr, NewBmp.Scanline[y], NewBmp.Width * 4);
          Inc(DPtr, NewBmp.Width * 4);
        End;
        ImgStride := NewBmp.Width * 4;
        // Preserve PNG alpha; patch everything else to opaque
        If Not (Bmp.Graphic Is TPngImage) Then Begin
          DPtr := @ImgResource[3];
          For Idx := 0 To NewBmp.Width * NewBmp.Height - 1 Do Begin
            If DPtr^ = 0 Then DPtr^ := $FF;
            Inc(DPtr, 4);
          End;
        End;

      End;

    Finally
      Bmp.Free;
    End;

    {$ENDIF}

    ImgHeight := NewBmp.Height;
    ImgWidth  := NewBmp.Width;

  Finally
    NewBmp.Free;
  End;

  If OldFilename <> '' Then
    RenameFile(String(Filename), String(OldFilename));

End;

Procedure SaveImage(Filename: aString; w, h: Integer; Pixels, Palette: pByte);
{$IFDEF FPC}
Type
  TPNGImage = TPortableNetworkGraphic;
{$ENDIF}
Var
  Ext: aString;
  i: Integer;
  Bmp: TBitmap;
  Gif: TGIFImage;
  Png: TPNGImage;
  Pal: Array[0..255] of PaletteEntry;
Begin

  For i := 0 To 255 Do Begin
  Pal[i].peRed := Palette^;
  Inc(Palette);
  Pal[i].peGreen := Palette^;
  Inc(Palette);
  Pal[i].peBlue := Palette^;
  Pal[i].peFlags := $FF;
  Inc(Palette, 2);
  End;

  Bmp := TBitmap.Create;
  Bmp.PixelFormat := pf8Bit;
  Bmp.Width := w;
  Bmp.Height := h;
  SetDIBColorTable(Bmp.Canvas.Handle, 0, 256, Pal);
  For i := 0 to h -1 Do Begin
    CopyMem(Bmp.ScanLine[i], Pixels, w);
    Inc(Pixels, w);
  End;

  If FileExists(String(Filename)) Then
    DeleteFile(String(Filename));

  Ext := Lower(aString(ExtractFileExt(String(Filename))));
  If Ext = '.bmp' Then Begin
    Bmp.SaveToFile(String(Filename));
  End Else
    If Ext = '.png' Then Begin
      Png := TPNGImage.Create;
      Png.Assign(Bmp);
      Png.SaveToFile(String(Filename));
      Png.Free;
    End Else
      If Ext = '.gif' Then Begin
        Gif := TGIFImage.Create;
        Gif.Assign(Bmp);
        Gif.SaveToFile(String(Filename));
        Gif.Free;
      End;

  Bmp.Free;

End;

Procedure FreeImageResource;
Begin

  // Removes an image from memory after loading.

  SetLength(IMGResource, 0);

End;

Procedure UpdateLinuxBuildStr;
{Var
  Str: TStringList;
  Idx: Integer;}
Begin
{
  If FileExists('Linux\specbas.pas') Then Begin

    Str := TStringList.Create;
    Str.LoadFromFile('linux\specbas.pas');
    For Idx := 0 To Str.Count -1 Do Begin
      If Pos('  BUILDSTR := '#39, Str[Idx]) > 0 Then
        If Pos('SDL', Str[Idx]) = 0 Then
          Str[Idx] := '  BUILDSTR := '#39+BuildStr+#39+';'
        Else
          Str[Idx] := '  BUILDSTR := '#39+BuildStr+'-SDL'+#39+';';
    End;

    Str.SaveToFile('linux\specbas.pas');
    Str.Free;

  End;
}
End;

procedure TMain.DropFiles(var msg: TMessage);
var
  i, count, j: integer;
  dropFileName: array [0..511] of Char;
  MAXFILENAME: integer;
  sl: TStringlist;
  paste, s: aString;
begin
  MAXFILENAME := 511;
  count := DragQueryFile(msg.WParam, $FFFFFFFF, dropFileName, MAXFILENAME);
  for i := 0 to count - 1 do
  begin
    DragQueryFile(msg.WParam, i, dropFileName, MAXFILENAME);
    s := '';
    j := 0;
    While (j < 512) and (dropFileName[j] > #0) do Begin
      s := s + aChar(dropFilename[j]);
      inc(j);
    end;
    sl := TStringlist.Create;
    sl.LoadFromHost(String(s));
    Paste := '';
    If sl.Count > 0 Then Begin
      if sl[0] = 'ZXASCII' Then Begin
        for j := 0 To sl.Count -1 Do Begin
          s := aString(sl[j]);
          If (Copy(s, 1, 7) <> 'ZXASCII') and (Copy(s, 1, 4) <> 'AUTO') and (Copy(s, 1, 4) <> 'PROG') and (Copy(s, 1, 7) <> 'CHANGED') Then
            paste := paste + s + #13#10;
        End;
      End;
      {$IFNDEF RUNTIMEONLY}
      FPBASICEditor.SetFocus(True);
      FPBASICEditor.InsertText(paste);
      FPBASICEditor.EnsureCursorVisible;
      FPBASICEditor.Paint;
      {$ENDIF}
    End;
    sl.Free;
  end;
  DragFinish(msg.WParam);
end;

Initialization

  {$IFNDEF FPC}
  {$IFDEF OPENGL}
  RC := 0;
  {$ENDIF}
  {$ENDIF}

end.
