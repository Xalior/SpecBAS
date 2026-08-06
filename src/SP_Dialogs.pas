unit SP_Dialogs;

// Runtime-safe dialog infrastructure split from SP_UITools.
// Contains only SP_FileRequester and OpenFileReq — no editor dependencies.
// Safe to compile under RUNTIMEONLY.

{$INCLUDE SpecBAS.inc}

interface

Uses Types, SysUtils, Math, SyncObjs, SP_Tokenise, SP_Components, SP_Util,
     SP_BankFiling, SP_Errors, SP_SysVars, SP_Graphics, SP_FileIO, SP_BankManager,
     SP_Package, SP_ButtonUnit, SP_BaseComponentUnit, SP_CheckBoxUnit,
     SP_LabelUnit, SP_FileListBoxUnit, SP_EditUnit;

Type

  SP_FileRequester = Class
    pBtn, okBtn, caBtn: SP_Button;
    chk: SP_CheckBox;
    PathEdt, FilenameEdt: SP_Edit;
    FilesList: SP_FileListBox;
    Function  Open(Caption, Filename, Filter: aString; Save: Boolean; Var Error: TSP_ErrorCode): aString;
    Procedure ParentButtonClick(Sender: SP_BaseComponent);
    Procedure OkBtnClick(Sender: SP_BaseComponent);
    Procedure CaBtnClick(Sender: SP_BaseComponent);
    Procedure ChooseDir(Sender: SP_BaseComponent; s: aString);
    Procedure ChooseFile(Sender: SP_BaseComponent; s: aString);
    Procedure SelectFile(Sender: SP_BaseComponent; i: Integer);
    Procedure AcceptFile(Sender: SP_BaseComponent; s: aString);
    Procedure AcceptDir(Sender: SP_BaseComponent; s: aString);
    Procedure ChangeFilename(Sender: SP_BaseComponent; s: aString);
    Procedure Abort(Sender: SP_BaseComponent);
    Procedure OnKeyDown(Sender: SP_BaseComponent; Key: Integer; Down: Boolean; Var Handled: Boolean);
  End;

  Function OpenFileReq(Caption, Filename, Filter: aString; Save: Boolean; Var Error: TSP_ErrorCode): aString;

Const

  Bw = 8;
  Bh = 8;

Var

  preToolWindow: Integer;
  DefaultWindow: Integer;

  // Shared dialog infrastructure — used by SP_UITools dialogs too (editor build)
  Procedure WaitForDialog;
  Function  CreateToolWindow(Caption: aString; Left, Top, Width, Height: Integer): Integer;

implementation

Uses SP_Main, SP_Input, SP_Sound,
     {$IFNDEF RUNTIMEONLY}SP_FPEditor, SP_BASICEditorHostUnit, {$ENDIF}
     SP_Interpret_PostFix;

Var

  FDWindowID: Integer;

// ---------------------------------------------------------------------------
// Focus restoration after dialog closes.
// Under RUNTIMEONLY there is no editor to refocus — just restore the window.
// ---------------------------------------------------------------------------

Procedure RestoreEditorFocus;
Begin
  SwitchFocusedWindow(preToolWindow);
  {$IFNDEF RUNTIMEONLY}
  If preToolWindow = fwEditor Then Begin
    If Assigned(FPBASICEditor) Then
      FPBASICEditor.SetFocus(True);
  End Else
    If preToolWindow = fwDirect Then
      If Assigned(DWBASICEditor) Then
        DWBASICEditor.SetFocus(True);
  {$ENDIF}
End;

// ---------------------------------------------------------------------------
// Spin the event loop until the active tool window signals completion.
// ---------------------------------------------------------------------------

Procedure WaitForDialog;
Var
  Locked, Mouse: Boolean;
Begin

  SP_ClearAllKeys;
  RemoveTimerByProc(@SP_BaseComponent.KeyRepeat);

  Mouse := MOUSEVISIBLE;
  Locked := SCREENLOCK;
  SCREENLOCK := False;
  MOUSEVISIBLE := True;

  While Not ToolWindowDone And Not QUITMSG Do Begin
    SP_WaitForSync;
    DoTimerEvents;
  End;
  SP_ClearAllKeys;   // ensure no key-down state leaks after dialog closes

  SCREENLOCK := Locked;
  MOUSEVISIBLE := Mouse;
  RestoreEditorFocus;
  SP_SetDrawingWindow(PreToolWindow);

End;

// ---------------------------------------------------------------------------
// Create a centred, decorated modal tool window.
// Saves/restores draw-position state using local vars so no FPEditor globals
// are needed under RUNTIMEONLY.
// ---------------------------------------------------------------------------

Function CreateToolWindow(Caption: aString; Left, Top, Width, Height: Integer): Integer;
Var
  Idx: Integer;
  Win: pSP_Window_Info;
  Error: TSP_ErrorCode;
  SaveDRPOSX, SaveDRPOSY, SavePRPOSX, SavePRPOSY: aFloat;
  SaveOVER: Integer;
Begin

  preToolWindow := FocusedWindow;
  DefaultWindow := SCREENBANK;

  // Save draw state locally — no FPEditor globals needed
  SaveDRPOSX := DRPOSX;
  SaveDRPOSY := DRPOSY;
  SavePRPOSX := PRPOSX;
  SavePRPOSY := PRPOSY;
  SaveOVER   := COVER;

  COVER := 0;
  T_OVER := COVER;

  Result := SP_Add_Window(Left, Top, Width, Height, -1, 8, 0, Error);

  COVER := 0;
  CINVERSE := 0;
  CITALIC := 0;
  CBOLD := 0;
  SP_GetWindowDetails(Result, Win, Error);
  Win^.Component.Proportional := True;
  SP_SetWindowShadow(Result, True);

  For Idx := 0 To 255 Do Win^.Palette[Idx] := DefaultPalette[Idx];

  If Caption <> '' Then Begin
    Win^.Decorated := True;
    Win^.Caption := Caption;
    SP_FillRect(0, 0, Win^.Width, Win^.Height, SP_UIWindowBack);
    SP_Decorate_User_Window(Result);
  End;

  DRPOSX := SaveDRPOSX;
  DRPOSY := SaveDRPOSY;
  PRPOSX := SavePRPOSX;
  PRPOSY := SavePRPOSY;
  COVER  := SaveOVER;
  T_OVER := COVER;

  MODALWINDOW := Result;

End;

// ---------------------------------------------------------------------------
// SP_FileRequester
// ---------------------------------------------------------------------------

Function OpenFileReq(Caption, Filename, Filter: aString; Save: Boolean; Var Error: TSP_ErrorCode): aString;
Var
  FileReq: SP_FileRequester;
Begin
  FileReq := SP_FileRequester.Create;
  Result := FileReq.Open(Caption, Filename, Filter, Save, Error);
End;

Procedure SP_FileRequester.Abort(Sender: SP_BaseComponent);
Begin
  ToolStrResult := '';
  ToolWindowDone := True;
End;

Procedure SP_FileRequester.ParentButtonClick(Sender: SP_BaseComponent);
Begin
  FilesList.GoParent;
  PathEdt.Text := FilesList.Directory;
End;

Procedure SP_FileRequester.ChooseDir(Sender: SP_BaseComponent; s: aString);
Begin
  PathEdt.Text := FilesList.Directory;
  OkBtn.Enabled := False;
End;

Procedure SP_FileRequester.OkBtnClick(Sender: SP_BaseComponent);
Begin
  ChooseFile(Sender, FilenameEdt.Text);
End;

Procedure SP_FileRequester.CaBtnClick(Sender: SP_BaseComponent);
Begin
  Abort(nil);
End;

Procedure SP_FileRequester.ChooseFile(Sender: SP_BaseComponent; s: aString);
Var
  p: aString;
Begin
  If s <> '' Then Begin
    p := FilesList.Directory;
    If Copy(p, Length(p), 1) <> '/' Then
      p := p + '/';
    FilenameEdt.Text := s;
    ToolStrResult := p + s;
  End Else
    ToolStrResult := '';
  ToolWindowDone := True;
End;

Procedure SP_FileRequester.SelectFile(Sender: SP_BaseComponent; i: Integer);
Var
  p, s: aString;
Begin
  If i >= 0 Then Begin
    p := FilesList.Directory;
    If Copy(p, Length(p), 1) <> '/' Then
      p := p + '/';
    s := FilesList.Items[i];
    If FocusedControl <> FileNameEdt Then Begin
      FilenameEdt.SetTextNoUpdate(Copy(s, 2, Pos(#255, s) -2));
      FilesList.Find(s, True);
    End Else
      FilenameEdt.GhostText := Copy(s, 2, Pos(#255, s) -2);
    okBtn.Enabled := SP_FileExists(p + FilenameEdt.Text) or (ToolMode = 2);
  End Else Begin
    FileNameEdt.Text := '';
    okBtn.Enabled := False;
  End;
End;

Procedure SP_FileRequester.AcceptFile(Sender: SP_BaseComponent; s: aString);
Var
  p: aString;
Begin
  If okBtn.Enabled Then
    If s = '' Then AcceptDir(Sender, '') Else Begin
      If s <> #0 Then Begin
        p := FilesList.Directory;
        If Copy(p, Length(p), 1) <> '/' Then
          p := p + '/';
        ToolStrResult := p + s;
      End Else
        ToolStrResult := '';
      ToolWindowDone := True;
    End;
End;

Procedure SP_FileRequester.AcceptDir(Sender: SP_BaseComponent; s: aString);
Begin
  FilesList.Directory := PathEdt.Text;
End;

Procedure SP_FileRequester.ChangeFilename(Sender: SP_BaseComponent; s: aString);
Var
  p: aString;
Begin
  If s <> '' Then Begin
    FilesList.Find(s, False);
    p := FilesList.Directory;
    If Copy(p, Length(p), 1) <> '/' Then
      p := p + '/';
    s := p + s;
    okBtn.Enabled := SP_FileExists(s) or (ToolMode = 2);
  End Else
    okBtn.Enabled := False;
  FileNameEdt.ValidText := okBtn.Enabled;
End;

Procedure SP_FileRequester.OnKeyDown(Sender: SP_BaseComponent; Key: Integer; Down: Boolean; Var Handled: Boolean);
Begin
  Case Key of
    K_UP, K_DOWN, K_NEXT, K_PRIOR:
      Begin
        FilesList.SetFocus(True);
        FilesList.PerformKeyDown(Handled);
      End;
  End;
End;

Function SP_FileRequester.Open(Caption, Filename, Filter: aString; Save: Boolean; Var Error: TSP_ErrorCode): aString;
Var
  Win: pSP_Window_Info;
  cw, w, h, fw, fh, nbW, nbH: Integer;
  Str: aString;
  CaptionHeight: Integer;
Begin

  DisplaySection.Enter;

  ToolWindowDone := False;
  If Save Then ToolMode := 2 Else ToolMode := 1;

  If SYSTEMSTATE in [SS_EDITOR, SS_DIRECT, SS_NEW, SS_ERROR] Then Begin
    FW := Trunc(FONTWIDTH * EDFONTSCALEX);
    FH := Trunc(FONTHEIGHT * EDFONTSCALEY);
    nBW := Trunc(BW * EDFONTSCALEX);
    nBH := Trunc(BH * EDFONTSCALEY);
  End Else Begin
    FH := Round(FONTHEIGHT * T_SCALEY);
    FW := Round(FONTWIDTH * T_SCALEX);
    nBW := Min(Round(BW * T_SCALEX), 8);
    nBH := Min(Round(BH * T_SCALEY), 8);
  End;

  // Caption bar height: editor build uses FPCaptionHeight (= FPFh + 2);
  // runtime build computes the same value from the current font metrics.
  {$IFNDEF RUNTIMEONLY}
  CaptionHeight := FPCaptionHeight;
  {$ELSE}
  CaptionHeight := FH + 2;
  {$ENDIF}

  w := DISPLAYWIDTH - (DISPLAYWIDTH Div 4);
  h := DISPLAYHEIGHT - (DISPLAYHEIGHT Div 8);
  FDWindowID := CreateToolWindow(Caption, (DISPLAYWIDTH - w) Div 2, (DISPLAYHEIGHT - h) Div 2, w, h);
  Dec(w, 2); // Account for the 1 pixel black border
  SP_GetWindowDetails(FDWindowID, Win, Error);
  SP_SetDrawingWindow(FDWindowID);

  Win^.Component.Proportional := True;

  pBtn := SP_Button.Create(Win^.Component);
  pBtn.SetBounds(nBw + 1, CaptionHeight + nBh, Fw + 4, Fh + 4);
  pBtn.OverrideScaling := True;
  pBtn.Caption := #251;
  pBtn.CentreCaption;
  pBtn.Enabled := True;

  PathEdt := SP_Edit.Create(Win^.Component);
  PathEdt.BackgroundClr := SP_UIBackground;
  PathEdt.SetBounds(pBtn.Left + pBtn.Width + nBw, pBtn.Top, w - pBtn.Width - (nBw * 3), Fh);
  If PackageIsOpen Then
    Str := SP_GetPackageDir
  Else Begin
    Str := SP_ExtractFileDir(Filename);
    If Str = '' Then
      Str := SP_ConvertHostFilename(aString(GetCurrentDir), Error);
  End;
  PathEdt.RightJustify := True;
  PathEdt.Text := SP_DecomposePathWithAssigns(Str);
  PathEdt.OnKeyDown := OnKeyDown;
  PathEdt.SetFocus(False);

  caBtn := SP_Button.Create(Win^.Component);
  caBtn.Caption := 'Cancel';
  cw := caBtn.TextWidth(caBtn.Caption) + Fw * 2;
  caBtn.SetBounds(w - (cw + nBw) +1, h - (FH + 6) - nBh -1, cw, FH + 6);
  caBtn.CentreCaption;
  caBtn.Enabled := True;

  okBtn := SP_Button.Create(Win^.Component);
  okBtn.Caption := 'Okay';
  cw := okBtn.TextWidth(OkBtn.Caption) + Fw * 2;
  okBtn.SetBounds(caBtn.Left - (cw + nBw), caBtn.Top, cw, FH + 6);
  okBtn.CentreCaption;

  FilenameEdt := SP_Edit.Create(Win^.Component);
  FilenameEdt.BackgroundClr := SP_UIBackground;
  FilenameEdt.SetBounds(pBtn.Left, okBtn.Top - (Fh + 6 + nBh), pBtn.Width + nBw + PathEdt.Width, Fh);
  If SP_FileExists(Filename) Then
    FilenameEdt.Text := SP_ExtractFileName(Filename)
  Else
    FilenameEdt.Text := '';
  FilenameEdt.OnKeyDown := OnKeyDown;
  okBtn.Enabled := SP_FileExists(Filename) or ((ToolMode = 2) And (FilenameEdt.Text <> ''));

  FilesList := SP_FileListBox.Create(Win^.Component);
  FilesList.SetBounds(FilenameEdt.Left, pBtn.Top + pBtn.Height + nBh, FilenameEdt.Width, FilenameEdt.Top - PathEdt.Top - FileNameEdt.Height - (nBh * 2));
  FilesList.Filters := Filter;
  FilesList.Directory := PathEdt.Text;
  FilesList.Transparent := False;
  FilesList.Find(SP_ExtractFilename(Filename), True);

  PathEdt.ChainControl := FilesList;
  FilesList.ChainControl := FilenameEdt;
  FilenameEdt.ChainControl := PathEdt;
  FilesList.CanFocus := True;
  FilenameEdt.SetFocus(True);

  pBtn.OnClick := ParentButtonClick;
  FilesList.OnChooseDir := ChooseDir;
  FilesList.OnChooseFile := ChooseFile;
  FilesList.OnSelect := SelectFile;
  FilesList.OnAbort := Abort;
  PathEdt.OnAccept := AcceptDir;
  PathEdt.OnAbort := Abort;
  FilenameEdt.OnAccept := AcceptFile;
  FilenameEdt.OnChange := ChangeFilename;
  FilenameEdt.OnAbort := Abort;
  OkBtn.OnClick := OkBtnClick;
  caBtn.OnClick := CaBtnClick;

  pBtn.Paint;
  okBtn.Paint;

  DisplaySection.Leave;

  WaitForDialog;

  DisplaySection.Enter;
  Result := ToolStrResult;
  SP_DeleteWindow(FDWindowID, Error);
  DisplaySection.Leave;

  Free;

End;

end.
