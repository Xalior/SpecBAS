unit SP_UITools;

// Editor-only UI tools: About dialog, Find/Replace, Breakpoint editor,
// Text requester (goto line / expressions — used only by SP_FPEditor).
// This entire unit is excluded from RUNTIMEONLY builds.
// File requesters and shared dialog infrastructure live in SP_Dialogs.pas.

{$INCLUDE SpecBAS.inc}

interface

{$IFNDEF RUNTIMEONLY}

Uses Types, SysUtils, Math, SyncObjs, SP_Tokenise, SP_Components, SP_Util,
     SP_BankFiling, SP_Errors, SP_SysVars, SP_Graphics, SP_FileIO, SP_BankManager,
     SP_Package, SP_ButtonUnit, SP_RadioGroupUnit, SP_BaseComponentUnit,
     SP_CheckBoxUnit, SP_ComboBoxUnit, SP_LabelUnit, SP_FileListBoxUnit,
     SP_EditUnit, SP_ContainerUnit, SP_BASICEditorUnit;

Type

  SP_About = Class
    Procedure Open(Animate: Boolean = False);
    Procedure DoAnim(Control: SP_BaseComponent);
    Procedure OnKeyDown(Sender: SP_BaseComponent; Key: Integer; Down: Boolean; Var Handled: Boolean);
    Procedure OnMouseDown(Sender: SP_BaseComponent; Mx, My, Button: Integer);
  End;

  SP_FindReplace = Class
    FindMode: Boolean;
    Editor: SP_BASICEditor;
    okBtn, allBtn, caBtn: SP_Button;
    dirGroup, originGroup: SP_RadioGroup;
    caseChk, wholeChk, inselChk, expChk: SP_CheckBox;
    searchEdt, replaceEdt: SP_ComboBox;
    searchLbl, replaceLbl: SP_Label;
    Function  Open(Mode: Boolean; Editor: SP_BASICEditor): Integer;
    Procedure OkBtnClick(Sender: SP_BaseComponent);
    Procedure CancelBtnClick(Sender: SP_BaseComponent);
    Procedure searchEdtChange(Sender: SP_BaseComponent; Text: aString);
    Procedure Accept(Sender: SP_BaseComponent; s: aString);
    Procedure Abort(Sender: SP_BaseComponent);
    Procedure expChkChange(Sender: SP_BaseComponent);
    Function  OnEvalExpr(Sender: SP_BaseComponent; Const Expr: aString; Var Error: TSP_ErrorCode): aString;
  End;

  SP_TextRequester = Class
    LineEdt: SP_Edit;
    okBtn, caBtn: SP_Button;
    shouldEvaluate: Boolean;
    TextKind: Integer;
    Function  Open(Caption, DefaultText: aString; Kind: Integer; Evaluate: Boolean; Var Error: TSP_ErrorCode): aString;
    Procedure OkBtnClick(Sender: SP_BaseComponent);
    Procedure CaBtnClick(Sender: SP_BaseComponent);
    Procedure Abort(Sender: SP_BaseComponent);
    Procedure Accept(Sender: SP_BaseComponent; s: aString);
    Procedure LineEdtChange(Sender: SP_BaseComponent; Text: aString);
  End;

  SP_BreakPointWindow = Class
    cmbType: SP_ComboBox;
    edtLine, edtCondition, edtPassCount: SP_Edit;
    lblLine, lblCondition, lblPassCount, lblType: SP_Label;
    okBtn, caBtn: SP_Button;
    Width, Height, FW, FH: Integer;
    Caption: aString;
    Accepted: Boolean;
    BpLine, BpSt, BpPasses: Integer;
    BpCondition: aString;
    Procedure Open(BpIndex, BpType, Line, Statement, PassCount: Integer; Caption, Condition: aString);
    Procedure PlaceControls;
    Procedure ValidateFields;
    Procedure TypeChange(Sender: SP_BaseComponent; Text: aString);
    Procedure EdtLineChange(Sender: SP_BaseComponent; Text: aString);
    Procedure OkBtnClick(Sender: SP_BaseComponent);
    Procedure CaBtnClick(Sender: SP_BaseComponent);
    Procedure Accept(Sender: SP_BaseComponent; s: aString);
    Procedure Abort(Sender: SP_BaseComponent);
  End;

  Procedure ShowAboutDialog(Animate: Boolean = False);

Const

  tkLineStatement = 0;
  tkAnyExpression = 1;
  tkString        = 2;
  tkNumeric       = 3;
  tkText          = 4;

implementation

Uses SP_Main, SP_FPEditor, SP_Input, {$IFDEF SDL2}SP_SDL2Host{$ELSE}MainForm{$ENDIF}, SP_Interpret_PostFix,
     SP_MenuActions, SP_MemoUnit, SP_BASICEditorHostUnit, SP_Sound,
     SP_Execute, SP_Debugging, SP_Dialogs;

Var

  FDWindowID: Integer;
  SearchHistory: TStringList;
  ReplaceHistory: TStringList;

// ---------------------------------------------------------------------------
// About dialog
// ---------------------------------------------------------------------------

Procedure ShowAboutDialog(Animate: Boolean);
Var
  aboutDialog: SP_About;
Begin
  aboutDialog := SP_About.Create;
  aboutDialog.Open(Animate);
End;

Procedure SP_About.Open(Animate: Boolean);
Var
  ctr: SP_Container;
  Error: TSP_ErrorCode;
  win: pSP_Window_Info;
  Text, StripeText: aString;
  Font, w, h, x, cnt: Integer;
Const
  stClrRed    = #10;
  stClrYellow = #14;
  stClrGreen  = #12;
  stClrCyan   = #5;
  stClrBlue   = #9;
Begin

  DisplaySection.Enter;

  ToolWindowDone := False;

  Font := SP_SetFPEditorFont;
  If SYSTEMSTATE in [SS_EDITOR, SS_DIRECT, SS_NEW, SS_ERROR] Then Begin
    FW := Trunc(FONTWIDTH * EDFONTSCALEX);
    FH := Trunc(FONTHEIGHT * EDFONTSCALEY);
  End Else Begin
    FH := FONTHEIGHT;
    FW := FONTWIDTH;
  End;

  W := Min(Fw * 48, DISPLAYWIDTH);
  H := Fh * 14;

  FDWindowID := CreateToolWindow('', (DISPLAYWIDTH - w) Div 2, (DISPLAYHEIGHT - h) Div 2, w, h);
  SP_GetWindowDetails(FDWindowID, Win, Error);
  SP_SetDrawingWindow(FDWindowID);

  Text := #32#32#32#32#32#32#32#32#32#32#32#32#32#32#32#32#32#32#32#138#13+
          #32#32#139#131#131#131#133#131#131#131#138#139#131#131#135#133#131#131#131#130#139#131#131#135#129#131#131#131#138#139#131#131#131#13+
          #32#32#131#131#131#135#133#131#131#131#130#139#131#131#131#133#32#32#32#32#138#32#32#133#133#131#131#131#138#131#131#131#135#13+
          #32#32#131#131#131#131#129#32#32#32#32#131#131#131#131#129#131#131#131#130#131#131#131#131#129#131#131#131#130#131#131#131#131;
  StripeText := #16+stClrRed+#0#0#0#255#16+stClrYellow+#0#0#0#17+stClrRed+#0#0#0#255#16+stClrGreen+#0#0#0#17+stClrYellow+#0#0#0#255#16+stClrCyan+#0#0#0#17+stClrGreen+#0#0#0#255#16#0#0#0#0#17+stClrCyan+#0#0#0#255;

  ctr := SP_Container.Create(Win^.Component);
  ctr.Transparent := False;
  ctr.BackgroundClr := 0;
  ctr.Border := False;
  ctr.Proportional := False;
  ctr.Align := SP_AlignAll;
  ctr.OnMouseDown := OnMouseDown;
  ctr.OnKeyDown := OnKeyDown;
  ctr.SetFocus(True);
  CaptureControl := ctr;
  ForceCapture := True;

  ctr.PRINT(8, 8, Text, 2, 0, 1, 1, False, False, False, False);
  ctr.PRINT(16, 40, 'Version ' + BuildStr, 7, 0, 1, 1, False, False, False, False);

  DisplaySection.Leave;

  If Animate Then
    DoAnim(ctr);

  Cnt := H - 4;
  x := 48;
  While x > 0 Do Begin
    Ctr.PRINT(W - x, Cnt, StripeText, 0, 0, 1, 2, False, False, False, False);
    Dec(Cnt, 16); Dec(x, 8);
  End;
  ctr.PRINT(16, H - 22, #127+' '+IntToString(CurrentYear)+' ZX Development Ltd.', 232, 0, 1, 1, False, False, False, False);

  SP_InvalidateWholeDisplay;
  SP_WaitForSync;

  SwitchFocusedWindow(-1);

  WaitForDialog;

  ctr.SetFocus(False);
  CaptureControl := nil;
  ForceCapture := False;

  SP_SetSystemFont(Font, Error);
  SP_DeleteWindow(FDWindowID, Error);
  SP_InvalidateWholeDisplay;
  ForceCapture := False;
  Free;

End;

Procedure SP_About.DoAnim(Control: SP_BaseComponent);
Var
  TargetTicks: aFloat;
  Error: TSP_ErrorCode;
  WinW, WinH, sz, x, cnt, ofs, ink: Integer;

  Procedure Update;
  Begin
    SP_InvalidateWholeDisplay;
    SP_NeedDisplayUpdate := True;
  End;

Begin
  WinW := Control.Width;
  WinH := Control.Height;

  Delay(250);
  SP_PlaySignature;

  If SIGSAMPLEBANK > -1 Then Begin

    For x := 16 To WinW -16 Do
      Control.DrawLine(x, WinH - 32, x, WinH -16, 2);
    TargetTicks := CB_GetTicks + 35;
    Update;
    Repeat SP_WaitForSync; Until CB_GetTicks >= TargetTicks;

    For x := 16 To WinW -16 Do
      Control.DrawLine(x, WinH - 32, x, WinH -16, 5);
    TargetTicks := CB_GetTicks + 65;
    Update;
    Repeat SP_WaitForSync; Until CB_GetTicks >= TargetTicks;

    TargetTicks := CB_GetTicks + 500;
    ofs := 65536;
    While CB_GetTicks < TargetTicks Do Begin
      For x := 16 To WinW -16 Do Begin
        If (x+ofs) mod 16 < 8 + (Random(4) -2) Then ink := 5 Else ink := 2;
        Control.DrawLine(x, WinH - 32, x, WinH -16, ink);
        Dec(Ofs, 2);
      End;
      Update;
      SP_WaitForSync;
    End;

    Cnt := 0;
    TargetTicks := CB_GetTicks + 160;
    While CB_GetTicks < TargetTicks Do Begin
      x := 16; Sz := 0; Ofs := 0;
      While x < WinW - 16 Do Begin
        If Sz = 0 Then Begin
          If Ofs = 0 Then Begin
            If Random(32)>16 Then Sz := 4 Else Sz := 8;
            Inc(Sz, Random(4) -2);
            Cnt := Sz;
            Ofs := 1;
          End Else Begin
            Ofs := 0;
            Sz := Cnt;
          End;
        End;
        If Ofs = 0 Then ink := 1 Else ink := 6;
        Control.DrawLine(x, WinH - 32, x, WinH -16, ink);
        Inc(x);
        Dec(Sz);
      End;
      Update;
      SP_WaitForSync;
    End;

    Control.FillRect(16, WinH - 32, WinW - 16, WinH - 16, 0);
    Update;
    SP_WaitForSync;

  End Else
    SP_WaitForSync;

  SP_Stop_Sound;
  If SIGSAMPLEBANK > -1 Then Begin
    SP_DeleteBank(SIGSAMPLEBANK, Error);
    SIGSAMPLEBANK := -1;
  End;

End;

Procedure SP_About.OnKeyDown(Sender: SP_BaseComponent; Key: Integer; Down: Boolean; Var Handled: Boolean);
Begin
  Handled := True;
  ToolWindowDone := True;
End;

Procedure SP_About.OnMouseDown(Sender: SP_BaseComponent; Mx, My, Button: Integer);
Begin
  ToolWindowDone := True;
End;

// ---------------------------------------------------------------------------
// Find / Replace dialog
// ---------------------------------------------------------------------------

Function SP_FindReplace.Open(Mode: Boolean; Editor: SP_BASICEditor): Integer;
Var
  FW, FH, w, h, tp, cw, nBW, nBH: Integer;
  Caption: aString;
  Win: pSP_Window_Info;
  Error: TSP_ErrorCode;
Begin

  Result := -1;
  DisplaySection.Enter;
  ToolWindowDone := False;

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

  FindMode := Mode;
  If FindMode Then Caption := 'Find...' else Caption := 'Replace...';
  Self.Editor := Editor;

  w := 38 * FW; h := FPFh + 23 + (10 * FH) + (Ord(Not FindMode) * (nbh + FH)) + (5 * nbh) + 8;
  FDWindowID := CreateToolWindow(Caption, (DISPLAYWIDTH - w) Div 2, (DISPLAYHEIGHT - h) Div 2, w, h);
  Dec(w, 1);
  SP_GetWindowDetails(FDWindowID, Win, Error);
  SP_SetDrawingWindow(FDWindowID);

  searchLbl := SP_Label.Create(Win^.Component);
  SearchEdt := SP_ComboBox.Create(Win^.Component);
  SearchEdt.AllowLiterals := True;

  If FindMode Then Begin
    searchLbl.Caption := 'Find:';
    searchLbl.SetBounds(nBw +1, FPCaptionHeight + 2 + nBh, FW * Length(searchLbl.Caption), FH);
    searchLbl.TextJustify := 1;
    searchEdt.AddStrings(SearchHistory);
    searchEdt.BackgroundClr := SP_UIBackground;
    searchEdt.SetBounds(searchLbl.Left + searchLbl.Width + nbw, searchLbl.Top -2, w - (searchLbl.Left + searchLbl.Width + (nbw * 2)) +1, searchLbl.Height);
    searchEdt.Editable := True;
    tp := searchEdt.Top + searchEdt.Height + nbh;
    LastFindwasReplace := False;
  End Else Begin
    searchLbl.Caption := 'Replace:';
    searchLbl.SetBounds(nBw +1, FPCaptionHeight + 2 + nBh, FW * Length(searchLbl.Caption), FH);
    searchLbl.TextJustify := 1;
    replaceLbl := SP_Label.Create(Win^.Component);
    replaceLbl.Caption := 'With:';
    replaceLbl.SetBounds(7 + BSize, searchLbl.Top + searchLbl.Height + nbh, FW * Length(searchLbl.Caption), FH);
    replaceLbl.TextJustify := 1;
    searchEdt.AddStrings(SearchHistory);
    searchEdt.BackgroundClr := SP_UIBackground;
    searchEdt.SetBounds(searchLbl.Left + searchLbl.Width + nbw, searchLbl.Top -2, w - (searchLbl.Left + searchLbl.Width + (nbw * 2)), searchLbl.Height);
    searchEdt.Editable := True;
    replaceEdt := SP_ComboBox.Create(Win^.Component);
    replaceEdt.AddStrings(ReplaceHistory);
    replaceEdt.BackgroundClr := SP_UIBackground;
    replaceEdt.SetBounds(searchEdt.Left, searchLbl.Top + searchLbl.Height + nbh, searchEdt.Width, searchLbl.Height);
    replaceEdt.Editable := True;
    replaceEdt.OnAccept := Accept;
    replaceEdt.OnAbort := Abort;
    replaceEdt.AllowLiterals := True;
    replaceEdt.ChainControl := searchEdt;
    searchEdt.ChainControl := replaceEdt;
    tp := replaceEdt.Top + replaceEdt.Height + nbh;
    LastFindwasReplace := True;
  End;
  searchEdt.OnAccept := Accept;
  searchEdt.OnAbort := Abort;

  dirGroup := SP_RadioGroup.Create(Win^.Component);
  dirGroup.SetBounds(searchLbl.Left, tp, (17 * FW) - nBw, FH * 5 + 8);
  dirGroup.AddItem('Forward');
  dirGroup.AddItem('Backward');
  dirGroup.Caption := 'Direction';

  originGroup := SP_RadioGroup.Create(Win^.Component);
  originGroup.SetBounds(dirGroup.Left + dirGroup.Width + nbw, tp, (searchEdt.Left + searchEdt.Width) - (dirGroup.Width + dirGroup.Left + nbW), FH * 5 + 8);
  originGroup.AddItem('Start of BASIC');
  originGroup.AddItem('Cursor pos');
  originGroup.Caption := 'Origin';

  caseChk  := SP_CheckBox.Create(Win^.Component);
  wholeChk := SP_CheckBox.Create(Win^.Component);
  inselChk := SP_CheckBox.Create(Win^.Component);
  expChk   := SP_CheckBox.Create(Win^.Component);

  caseChk.Caption  := 'Match case';
  wholeChk.Caption := 'Whole words';
  inselChk.Caption := 'In selection';
  expChk.Caption   := 'Expression';

  caseChk.SetBounds(dirGroup.Left, dirGroup.Top + dirGroup.Height + nbh, dirGroup.Width, FH + nbh);
  wholeChk.SetBounds(dirGroup.Left, caseChk.Top + caseChk.Height + 2, dirGroup.Width, FH + nbh);
  inselChk.SetBounds(originGroup.Left, CaseChk.Top, originGroup.Width, FH + nbh);
  expChk.SetBounds(inselChk.Left, inSelChk.Top + inSelChk.Height + 2, inselChk.Width, FH + nbh);

  If soForward in FPSearchOptions Then dirGroup.ItemIndex := 0 Else dirGroup.ItemIndex := 1;
  If soStart in FPSearchOptions Then originGroup.ItemIndex := 0 Else originGroup.ItemIndex := 1;
  caseChk.Checked  := soMatchCase in FPSearchOptions;
  wholeChk.Checked := soWholeWords in FPSearchOptions;
  inSelChk.Checked := soInSelection in FPSearchOptions;
  expChk.Checked   := soExpression in FPSearchOptions;
  expChk.OnCheck   := expChkChange;

  caBtn := SP_Button.Create(Win^.Component);
  caBtn.Caption := 'Cancel';
  cw := Fw * (Length(caBtn.Caption) +2);
  caBtn.SetBounds(w - (cw + nBw), h - (FH + 6) - nBh -1, cw, FH + 6);
  caBtn.CentreCaption;
  caBtn.Enabled := True;

  If FindMode Then
    tp := caBtn.Left
  Else Begin
    allBtn := SP_Button.Create(Win^.Component);
    allBtn.Caption := 'Replace All';
    cw := Fw * (Length(allBtn.Caption) + 2);
    allBtn.SetBounds(caBtn.Left - (cw + 6), caBtn.Top, cw, FH + 6);
    allBtn.CentreCaption;
    tp := allBtn.Left;
  End;

  okBtn := SP_Button.Create(Win^.Component);
  okBtn.Caption := 'Okay';
  cw := Fw * (Length(OkBtn.Caption) + 2);
  okBtn.SetBounds(tp - (cw + 6), caBtn.Top, cw, FH + 6);
  okBtn.CentreCaption;

  okBtn.OnClick := OkBtnClick;
  caBtn.OnClick := CancelBtnClick;
  If Not FindMode Then allBtn.OnClick := OkBtnClick;

  searchEdt.SetFocus(True);
  searchEdt.OnChange := searchEdtChange;
  If Not FindMode Then replaceEdt.OnChange := searchEdtChange;

  inSelChk.Enabled := Assigned(Editor) And Editor.HasSelection;
  inSelChk.Checked := inSelChk.Enabled;

  If Not FindMode Then Begin
    okBtn.Enabled := searchEdt.Text <> '';
    AllBtn.Enabled := okBtn.Enabled;
  End Else
    okBtn.Enabled := searchEdt.Text <> '';

  DisplaySection.Leave;
  WaitForDialog;

  SP_DeleteWindow(FDWindowID, Error);
  SP_InvalidateWholeDisplay;
  Free;

End;

Procedure SP_FindReplace.searchEdtChange(Sender: SP_BaseComponent; Text: aString);
Var
  b: Boolean;
  s: aString;
  Error: TSP_ErrorCode;
Begin
  b := True;
  If expChk.Checked And (SearchEdt.Text <> '') Then Begin
    Error.Code := SP_ERR_OK;
    s := SP_FPExecuteAnyExpression(SearchEdt.Text, Error);
    b := Error.Code = SP_ERR_OK;
    If not b Then expChk.FontClr := 2 Else expChk.FontClr := 4;
    If Not FindMode Then
      If b And (ReplaceEdt.Text <> '') Then Begin
        s := SP_FPExecuteAnyExpression(ReplaceEdt.Text, Error);
        b := Error.Code = SP_ERR_OK;
        If not b Then expChk.FontClr := 2 Else expChk.FontClr := 4;
      End;
  End Else
    expChk.FontClr := 0;
  If FindMode Then
    OkBtn.Enabled := b And (SearchEdt.Text <> '')
  Else Begin
    OkBtn.Enabled := b And (SearchEdt.Text <> '');
    allBtn.Enabled := OkBtn.Enabled;
  End;
End;

Procedure SP_FindReplace.expChkChange(Sender: SP_BaseComponent);
Begin
  searchEdtChange(nil, searchEdt.Text);
End;

Function SP_FindReplace.OnEvalExpr(Sender: SP_BaseComponent; Const Expr: aString; Var Error: TSP_ErrorCode): aString;
Begin
  Result := SP_FPExecuteAnyExpression(Expr, Error);
End;

Procedure SP_FindReplace.OkBtnClick(Sender: SP_BaseComponent);
Var
  i: Integer;
  sOpt: SP_SearchOptions;
  Error: TSP_ErrorCode;
Begin
  sOPt := [];
  FPSearchTerm := searchEdt.Text;
  If Sender = allBtn Then sOpt := sOpt + [soAll];
  If Not FindMode Then FPReplaceTerm := replaceEdt.Text;
  If dirGroup.ItemIndex = 0 Then sOpt := sOpt + [soForward] Else sOpt := sOpt + [soBackwards];
  If originGroup.ItemIndex = 0 Then sOpt := sOpt + [soStart] Else sOpt := sOpt + [soCursorPos];
  If caseChk.Checked  Then sOpt := sOpt + [soMatchCase];
  If wholeChk.Checked Then sOpt := sOpt + [soWholeWords];
  If inselChk.Checked Then sOpt := sOpt + [soInSelection];
  If expChk.Checked Then Begin
    sOpt := sOpt + [soExpression];
    FPSearchTerm := SP_FPExecuteAnyExpression(SearchEdt.Text, Error);
    If Not FindMode Then FPReplaceTerm := SP_FPExecuteAnyExpression(FPReplaceTerm, Error);
  End;
  If FPSearchTerm <> '' Then Begin
    i := SearchHistory.IndexOf(FPSearchTerm);
    If i > -1 Then SearchHistory.Delete(i);
    SearchHistory.Insert(0, FPSearchTerm);
  End;
  If Not FindMode Then
    If FPReplaceTerm <> '' Then Begin
      i := ReplaceHistory.IndexOf(FPReplaceTerm);
      If i > -1 Then ReplaceHistory.Delete(i);
      ReplaceHistory.Insert(0, FPReplaceTerm);
    End;
  FPSearchOptions := sOpt;
  If FindMode Then
    Editor.BASICFindAll(FPSearchTerm, sOpt, OnEvalExpr)
  Else
    Editor.BASICReplaceAll(FPSearchTerm, FPReplaceTerm, sOpt, OnEvalExpr);
  ToolWindowDone := True;
End;

Procedure SP_FindReplace.CancelBtnClick(Sender: SP_BaseComponent);
Begin
  ToolWindowDone := True;
End;

Procedure SP_FindReplace.Accept(Sender: SP_BaseComponent; s: aString);
Begin
  If OkBtn.Enabled Then OkBtnClick(Sender);
End;

Procedure SP_FindReplace.Abort(Sender: SP_BaseComponent);
Begin
  ToolWindowDone := True;
End;

// ---------------------------------------------------------------------------
// Text requester (Goto Line / expression entry — SP_FPEditor use only)
// ---------------------------------------------------------------------------

Function SP_TextRequester.Open(Caption, DefaultText: aString; Kind: Integer; Evaluate: Boolean; Var Error: TSP_ErrorCode): aString;
Var
  Font, w, h, cw: Integer;
  win: pSP_Window_Info;
Begin

  DisplaySection.Enter;
  ToolWindowDone := False;
  shouldEvaluate := Evaluate;
  TextKind := Kind;

  Font := SP_SetFPEditorFont;
  If SYSTEMSTATE in [SS_EDITOR, SS_DIRECT, SS_NEW, SS_ERROR] Then Begin
    FW := Trunc(FONTWIDTH * EDFONTSCALEX);
    FH := Trunc(FONTHEIGHT * EDFONTSCALEY);
  End Else Begin
    FH := FONTHEIGHT;
    FW := FONTWIDTH;
  End;

  w := ((5 + Max(Length(Caption), 10)) * FW) + (Bh * 2);
  h := ((FH + 6) * 2) + FPCaptionHeight + (Bh * 3);
  FDWindowID := CreateToolWindow(Caption, (DISPLAYWIDTH - w) Div 2, (DISPLAYHEIGHT - h) Div 2, w, h);
  SP_GetWindowDetails(FDWindowID, Win, Error);
  SP_SetDrawingWindow(FDWindowID);

  LineEdt := SP_Edit.Create(Win^.Component);
  lineEdt.BackgroundClr := SP_UIBackground;
  lineEdt.SetBounds(Bw +1, FPFh + 10, w - 1 - (Bh * 2), 0);
  lineEdt.Editable := True;
  lineEdt.OnAccept := Accept;
  lineEdt.OnAbort := Abort;
  lineEdt.OnChange := LineEdtChange;
  lineEdt.SetFocus(True);

  caBtn := SP_Button.Create(Win^.Component);
  caBtn.Caption := 'Cancel';
  cw := Fw * (Length(caBtn.Caption) +2);
  caBtn.SetBounds(w - (cw + Bw), h - (FH + 6) - Bh -1, cw, FH + 6);
  caBtn.CentreCaption;
  caBtn.Enabled := True;

  okBtn := SP_Button.Create(Win^.Component);
  okBtn.Caption := 'Okay';
  cw := Fw * (Length(OkBtn.Caption) + 2);
  okBtn.SetBounds(caBtn.Left - (cw + Bw), caBtn.Top, cw, FH + 6);
  okBtn.CentreCaption;

  okBtn.OnClick := OkBtnClick;
  caBtn.OnClick := CaBtnClick;

  SwitchFocusedWindow(-1);
  DisplaySection.Leave;

  FPGotoText := '';
  WaitForDialog;

  SP_SetSystemFont(Font, Error);
  SP_DeleteWindow(FDWindowID, Error);
  SP_InvalidateWholeDisplay;
  Free;

End;

Procedure SP_TextRequester.OkBtnClick(Sender: SP_BaseComponent);
Begin
  FPGotoText := LineEdt.Text;
  ToolWindowDone := True;
End;

Procedure SP_TextRequester.CaBtnClick(Sender: SP_BaseComponent);
Begin
  ToolWindowDone := True;
End;

Procedure SP_TextRequester.Accept(Sender: SP_BaseComponent; s: aString);
Begin
  If OkBtn.Enabled Then OkBtnClick(Sender);
End;

Procedure SP_TextRequester.Abort(Sender: SP_BaseComponent);
Begin
  ToolWindowDone := True;
End;

Procedure SP_TextRequester.LineEdtChange(Sender: SP_BaseComponent; Text: aString);
Var
  Error: TSP_ErrorCode;
  s, l, lineTxt, statementTxt: aString;
  b: Boolean;
  Found: TPoint;
  line, statement: aFloat;
  i: Integer;
Begin

  If LineEdt.Text <> '' Then Begin

    i := 1;
    Found.y := -1;
    Error.Code := SP_ERR_OK;

    If Pos(':', lineEdt.Text) > 0 Then Begin
      LineTxt := Copy(Text, 1, Pos(':', Text) -1);
      StatementTxt := Copy(Text, Pos(':', Text) +1);
    End Else Begin
      LineTxt := Text;
      StatementTxt := '1';
    End;

    If TextKind = tkLineStatement Then Begin

      l := SP_FPExecuteAnyExpression(LineTxt, Error);
      If Error.Code = SP_ERR_OK Then
        s := SP_FPExecuteAnyExpression(StatementTxt, Error);

      b := (Error.Code = SP_ERR_OK) and SP_GetNumber(l, i, line, True);
      i := 1;
      b := b And SP_GetNumber(s, i, statement, True);

      If Not b Then
        b := Assigned(FPBASICEditor) And FPBASICEditor.LabelExists(lineEdt.Text);

    End Else Begin

      b := SP_FPCheckExpression(Text, Error);

      If TextKind = tkAnyExpression Then Begin
        If b And ShouldEvaluate Then Begin
          SP_FPExecuteAnyExpression(Text, Error);
          b := Error.Code = SP_ERR_OK;
        End;
      End Else If TextKind = tkString Then Begin
        If b And ShouldEvaluate Then Begin
          SP_FPExecuteStringExpression(Text, Error);
          b := Error.Code = SP_ERR_OK;
        End;
      End Else If TextKind = tkNumeric Then Begin
        If b And ShouldEvaluate Then Begin
          SP_FPExecuteNumericExpression(Text, Error);
          b := Error.Code = SP_ERR_OK;
        End;
      End Else If TextKind = tkText Then
        b := True;

    End;

    okBtn.Enabled := b;
    lineEdt.ValidText := b;

  End Else Begin
    okBtn.Enabled := False;
    lineEdt.ValidText := False;
  End;

End;

// ---------------------------------------------------------------------------
// Breakpoint window
// ---------------------------------------------------------------------------

Procedure SP_BreakpointWindow.Open(BpIndex, BpType, Line, Statement, PassCount: Integer; Caption, Condition: aString);
Var
  Font, w, h: Integer;
  win: pSP_Window_Info;
  Error: TSP_ErrorCode;
Begin

  DisplaySection.Enter;
  ToolWindowDone := False;

  Font := SP_SetFPEditorFont;
  If SYSTEMSTATE in [SS_EDITOR, SS_DIRECT, SS_NEW, SS_ERROR] Then Begin
    FW := Trunc(FONTWIDTH * EDFONTSCALEX);
    FH := Trunc(FONTHEIGHT * EDFONTSCALEY);
  End Else Begin
    FH := FONTHEIGHT;
    FW := FONTWIDTH;
  End;

  w := (45 * FW) + (Bh * 2) -2;
  h := FPCaptionHeight + (4 * FH + 8) + (Bh * 6);
  Width := w; Height := h;
  Self.Caption := Caption;
  FDWindowID := CreateToolWindow(Caption, (DISPLAYWIDTH - w) Div 2, (DISPLAYHEIGHT - h) Div 2, w, h);
  SP_GetWindowDetails(FDWindowID, Win, Error);
  SP_SetDrawingWindow(FDWindowID);

  lblType := SP_Label.Create(Win^.Component);
  lblType.Caption := 'Type';
  lblType.SetBounds(7 + (10 * FW) + Bw, FPCaptionHeight + Bh + 2, FW * Length(lblType.Caption), FH);
  lblType.TextJustify := 1;

  cmbType := SP_ComboBox.Create(Win^.Component);
  cmbType.SetBounds(lblType.Left + lblType.Width + Bh, lblType.Top -2, 17 * FW, LblType.Height);
  cmbType.AddItem('Source');
  cmbType.AddItem('Conditional');
  cmbType.AddItem('Data');
  cmbType.BackgroundClr := SP_UIBackground;

  edtLine := SP_Edit.Create(Win^.Component);
  edtLine.BackgroundClr := SP_UIBackground;
  edtLine.OnChange := EdtLineChange;
  edtCondition := SP_Edit.Create(Win^.Component);
  edtCondition.BackgroundClr := SP_UIBackground;
  edtCondition.OnChange := EdtLineChange;
  edtCondition.AllowLiterals := True;
  edtPassCount := SP_Edit.Create(Win^.Component);
  edtPassCount.BackgroundClr := SP_UIBackground;
  edtPassCount.OnChange := EdtLineChange;

  lblLine      := SP_Label.Create(Win^.Component); lblLine.Caption      := 'Line:Statement';
  lblCondition := SP_Label.Create(Win^.Component); lblCondition.Caption := 'Condition';
  lblPassCount := SP_Label.Create(Win^.Component); lblPassCount.Caption := 'Pass count';

  cmbType.ChainControl := edtLine;
  cmbType.OnAccept := Accept;
  cmbType.OnAbort  := Abort;
  edtLine.ChainControl      := edtCondition;
  edtCondition.ChainControl := edtPassCount;
  edtPassCount.ChainControl := cmbType;

  caBtn := SP_Button.Create(Win^.Component); caBtn.Caption := 'Cancel'; caBtn.OnClick := CaBtnClick;
  okBtn := SP_Button.Create(Win^.Component); okBtn.Caption := 'Okay';   okBtn.OnClick := OkBtnClick;

  Case BpType of
    BP_Stop:        Begin cmbType.ItemIndex := 0; edtLine.Text := IntToString(Line) + ':' + IntToString(Statement); edtCondition.Text := Condition; End;
    BP_Conditional: Begin cmbType.ItemIndex := 1; edtCondition.Text := Condition; End;
    BP_Data:        Begin cmbType.ItemIndex := 2; edtCondition.Text := Condition; End;
  End;

  cmbType.OnChange := TypeChange;
  edtPassCount.Text := IntToString(PassCount);

  PlaceControls;
  ValidateFields;

  Accepted := False;
  SwitchFocusedWindow(-1);
  DisplaySection.Leave;

  WaitForDialog;

  If Accepted Then Begin
    Case cmbType.ItemIndex of
      0: Begin
           If SP_BreakPointExists(Line, Statement) Then
             SP_AddSourceBreakpoint(False, Line, Statement, 0, '');
           SP_AddSourceBreakpoint(False, BpLine, BpSt, BpPasses, BpCondition);
         End;
      1: SP_AddConditionalBreakpoint(BpIndex, BpPasses, BpCondition, False);
      2: SP_AddConditionalBreakpoint(BpIndex, BpPasses, BpCondition, True);
    End;
  End;

  SP_SetSystemFont(Font, Error);
  SP_DeleteWindow(FDWindowID, Error);
  SP_InvalidateWholeDisplay;
  Free;

End;

Procedure SP_BreakpointWindow.PlaceControls;
Var
  y, cw: Integer;
  Win: pSP_Window_Info;
  Error: TSP_ErrorCode;
Begin

  SP_GetWindowDetails(FDWindowID, Win, Error);
  SP_SetDrawingWindow(FDWindowID);

  lblCondition.Visible := True; edtCondition.Visible := True;
  lblPassCount.Visible := True; edtPassCount.Visible := True;
  y := lblType.Top + lblType.Height + Bh;

  lblLine.Enabled := cmbType.ItemIndex = 0;
  edtLine.Enabled := lblLine.Enabled;
  lblLine.SetBounds(7 + Bh, y + 2, Length(LblLine.Caption) * FW, FH);
  edtLine.SetBounds(lblLine.Left + lblLine.Width + Bh, y, 10 * FW, FH);
  Inc(y, FH + Bh);

  edtCondition.SetBounds(edtLine.Left, y, 29 * FW, FH);
  lblCondition.SetBounds(edtCondition.Left - Bh - (Length(lblCondition.Caption) * FW), y + 2, Length(lblCondition.Caption) * FW, FH);
  Inc(y, FH + Bh);
  edtPassCount.SetBounds(edtLine.Left, y, 7 * FW, FH);
  lblPassCount.SetBounds(edtPassCount.Left - Bh - (Length(lblPassCount.Caption) * FW), y + 2, Length(lblPassCount.Caption) * FW, FH);

  edtCondition.OnAccept := Accept; edtLine.OnAccept := Accept; edtPassCount.OnAccept := Accept;
  edtCondition.OnAbort  := Abort;  edtLine.OnAbort  := Abort;  edtPassCount.OnAbort  := Abort;

  cw := Fw * (Length(caBtn.Caption) +2);
  caBtn.SetBounds(Width - (cw + Bh), Height - (FH + 6 + Bh), cw, FH + 6);
  caBtn.CentreCaption; caBtn.Enabled := True;

  cw := Fw * (Length(OkBtn.Caption) + 2);
  okBtn.SetBounds(caBtn.Left - (cw + 6), caBtn.Top, cw, FH + 6);
  okBtn.CentreCaption; okBtn.Enabled := False;

  SP_ResizeWindow(FDWindowID, Width, Height, 8, False, False, Error);
  SP_Decorate_Window(FDWindowID, Caption, True, False, True);
  SP_MoveWindow(FDWindowID, (DISPLAYWIDTH - Width) Div 2, (DISPLAYHEIGHT - Height) Div 2, Error);
  SP_SetDrawingWindow(DefaultWindow);

End;

Procedure SP_BreakPointWindow.TypeChange(Sender: SP_BaseComponent; Text: aString);
Begin
  PlaceControls;
  ValidateFields;
End;

Procedure SP_BreakPointWindow.ValidateFields;
Var
  i, ln, st: Integer;
  Found: TPoint;
  Error: TSP_ErrorCode;
  Line, Statement: aFloat;
  LineTxt, StatementTxt, Text, s, l: aString;
  b, b2, b3: Boolean;
Begin

  Text := edtLine.Text;

  If cmbType.ItemIndex = 0 Then Begin
    i := 1; Found.y := -1; Error.Code := SP_ERR_OK;
    If Pos(':', Text) > 0 Then Begin
      LineTxt := Copy(Text, 1, Pos(':', Text) -1);
      StatementTxt := Copy(Text, Pos(':', Text) +1);
    End Else Begin
      LineTxt := Text; StatementTxt := '1';
    End;
    If LineTxt <> '' Then Begin
      l := SP_FPExecuteAnyExpression(LineTxt, Error);
      If (Error.Code = SP_ERR_OK) And (StatementTxt <> '') Then
        s := SP_FPExecuteAnyExpression(StatementTxt, Error)
      Else
        Error.Code := SP_ERR_SYNTAX_ERROR;
    End Else
      Error.Code := SP_ERR_SYNTAX_ERROR;
    ln := StringToInt(l, MAXINT); st := StringToInt(s, MAXINT);
    BpLine := Ln; BpSt := St;
    b := (Error.Code = SP_ERR_OK) and SP_GetNumber(l, i, line, True) and (ln <> MAXINT) and (ln > 0);
    i := 1;
    b := b And SP_GetNumber(s, i, statement, True) and (st <> MAXINT) and (st > 0);
    If Not b Then b := Assigned(FPBASICEditor) And FPBASICEditor.LabelExists(EdtLine.Text);
    If not b Then lblLine.FontClr := 2 Else lblLine.FontClr := 0;
  End Else
    b := True;

  b2 := cmbType.ItemIndex <> 2;
  If edtCondition.Text <> '' Then Begin
    Error.Code := SP_ERR_OK;
    b2 := SP_FPCheckExpression(edtCondition.Text, Error) and (Error.ReturnType = SP_VALUE);
    BpCondition := edtCondition.Text;
  End;
  If not b2 Then lblCondition.FontClr := 2 Else lblCondition.FontClr := 0;

  If edtPassCount.Text <> '' Then Begin
    Error.Code := SP_ERR_OK;
    BpPasses := Round(SP_FPExecuteNumericExpression(edtPassCount.Text, Error));
    b3 := (Error.Code = SP_ERR_OK) and (Error.ReturnType = SP_VALUE);
  End Else
    b3 := False;
  If not b3 Then lblPassCount.FontClr := 2 Else lblPassCount.FontClr := 0;

  okBtn.Enabled := b and b2 and b3;
  edtLine.ValidText      := b;
  edtCondition.ValidText := b2;
  edtPassCount.ValidText := b3;

End;

Procedure SP_BreakPointWindow.EdtLineChange(Sender: SP_BaseComponent; Text: aString);
Begin
  ValidateFields;
End;

Procedure SP_BreakPointWindow.OkBtnClick(Sender: SP_BaseComponent);
Begin
  Accepted := True;
  ToolWindowDone := True;
End;

Procedure SP_BreakPointWindow.CaBtnClick(Sender: SP_BaseComponent);
Begin
  ToolWindowDone := True;
End;

Procedure SP_BreakpointWindow.Accept(Sender: SP_BaseComponent; s: aString);
Begin
  If OkBtn.Enabled Then OkBtnClick(Sender);
End;

Procedure SP_BreakpointWindow.Abort(Sender: SP_BaseComponent);
Begin
  ToolWindowDone := True;
End;

Initialization

  SearchHistory := TStringList.Create;
  ReplaceHistory := TStringList.Create;

Finalization

  SearchHistory.Free;
  ReplaceHistory.Free;

{$ELSE}

implementation

{$ENDIF} // RUNTIMEONLY

end.
