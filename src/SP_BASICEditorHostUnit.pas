// Copyright (C) 2026 By Paul Dunn
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

unit SP_BASICEditorHostUnit;

{$INCLUDE SpecBAS.inc}

interface

Uses
  SysUtils, Math, SyncObjs, Types,
  SP_BaseComponentUnit,
  SP_BASICEditorUnit,
  SP_TabBarUnit,
  SP_AnsiStringlist,
  SP_SysVars,
  SP_Errors,
  SP_Util;

Var
  // The listing editor component - accessible to SP_MenuActions, SP_DebugPanel.
  FPBASICEditor: SP_BASICEditor = nil;
  // The tab bar docked to the bottom of the listing editor window.
  FPTabBar:      SP_TabBar      = nil;
  // The direct command editor component.
  DWBASICEditor: SP_BASICEditor = nil;
  // Set True by the VCL thread (OnExecute) when a DW command is ready to run.
  // Cleared and acted upon by the interpreter thread in SP_GetFPUserInput.
  // EDITLINE must be populated before this flag is set.
  DWCommandPending: Boolean = False;

// listing Editor Lifecycle
Procedure EditorHost_Init(WinComponent: SP_BaseComponent);
Procedure EditorHost_Resize;
Procedure EditorHost_Destroy;
Procedure EditorHost_SwitchMode(EditorMode: Boolean);

// Direct command editor lifecycle
Procedure DWHost_Init(WinComponent: SP_BaseComponent);
Procedure DWHost_Resize;
Procedure DWHost_Destroy;

// Program content
Procedure EditorHost_LoadFromListing;
Procedure EditorHost_NewProgram;
Function  EditorHost_GetLineCount: Integer;
Function  EditorHost_GetLine(Idx: Integer): aString;
Procedure EditorHost_SetProgram(Const NewProg: Array Of aString);
// Load raw ZXASCII text into the editor; returns parsed metadata
Procedure EditorHost_LoadFromText(Const RawText: aString; Out AutoStart: Integer; Out ProgName:  aString; Out Changed:   Boolean);

// Navigation
Procedure EditorHost_ScrollToLine(LineNum, Statement: Integer);
Procedure EditorHost_StoreLine(LineNum: Integer);
Procedure EditorHost_SetExecLine(BASICLine, Statement: Integer);
Procedure EditorHost_SetExecLineWithScroll(BASICLine, Statement: Integer);
Procedure EditorHost_ClearExecLine;
Procedure EditorHost_SetBookMark(bmIndex, Line, Statement: Integer);
Procedure EditorHost_GotoBookMark(bmIndex: Integer);
Function  EditorHost_GetBookMark(bmIndex: Integer): Boolean;
Procedure EditorHost_ClearBookMarks;

// Structural program operations - delegate to SP_BASICEditor
Procedure EditorHost_SortByLineNumber;
Procedure EditorHost_RenumberLines(Start, Finish, FirstLine, Step: Integer);
Procedure EditorHost_DeleteLineRange(Start, Finish: Integer);
Procedure EditorHost_MergeLineRange(Start, Finish: Integer);

// Compiler bridge - call from RefreshDirtyLines
Procedure EditorHost_RefreshLineStates;

// Breakpoints - call from SP_ToggleBreakPoint (fwEditor branch)
Procedure EditorHost_ToggleBreakpoint;

// Queries
Function EditorHost_GetCursorBASICLine: Integer;
Function EditorHost_GetCursorStatement: Integer;
Function EditorHost_CheckProgram(OnlyErrors: Boolean = False): Boolean;
Function EditorHost_GetWordAtCursor: aString;  // word under the editor cursor for context-sensitive help

implementation

Uses
  SP_Compiler,          // AddCompileLine, SetAllToCompile, Listing, CompilerLock
  SP_Interpret_PostFix, // SP_SourceBreakpointList, SP_AddSourceBreakpoint, BP_IsHidden
  SP_FPEditor,          // SP_GetDebugStatus, spLine* state constants
  SP_DebugPanel,        // dbgBreakpoints constant
  SP_Graphics,          // SP_InvalidateWholeDisplay
  SP_MenuActions,       // UpdateStatusLabel
  SP_ToolTipWindow,     // For the hints system
  SP_MemoUnit,          // For character heights
  SP_EditorTabsUnit,    // Per-tab state save/restore
  SP_Tokenise;          // For SP_Program_Delete_Line

// ---------------------------------------------------------------------------
// TEditorHostBridge - holds the event handlers as methods.
// Of Object event types require method pointers; this class provides them.
// A single global instance (Bridge) is created in EditorHost_Init.
// ---------------------------------------------------------------------------

Type
  TEditorHostBridge = Class
    Procedure BASICLineChanged(Sender: TObject; RawLine, BASICLine, Statement: Integer);
    Procedure StructureChanged(Sender: TObject; AtLine, Delta: Integer);
    Procedure TextReset(Sender: SP_BaseComponent);
    Procedure BreakpointToggle(Sender: TObject; BASICLine, Statement: Integer; Active: Boolean);
    Procedure EditorFocused(Sender: SP_BaseComponent; Focused: Boolean);
    Procedure CursorMove(Sender: SP_BaseComponent);
    Procedure MouseMoved(Sender: SP_BaseComponent; Mx, My, Btn: Integer);
  End;

// ---------------------------------------------------------------------------
// TDWEditorBridge - event handlers for DWBASICEditor
// ---------------------------------------------------------------------------

Type
  TDWEditorBridge = Class
    Procedure Execute(Sender: SP_BaseComponent; Text: aString);
    Procedure NeedHeight(Sender: SP_BaseComponent);
    Procedure DWFocused(Sender: SP_BaseComponent; Focused: Boolean);
    Procedure CursorMove(Sender: SP_BaseComponent);
    Procedure EditorSearchRequest(Sender: SP_BaseComponent);
    Procedure MouseMoved(Sender: SP_BaseComponent; Mx, My, Btn: Integer);
  End;

Var
  Bridge:   TEditorHostBridge = nil;
  DWBridge: TDWEditorBridge   = nil;

// ---------------------------------------------------------------------------
// TDWEditorBridge method implementations
// ---------------------------------------------------------------------------

// Fired on the VCL thread when the user presses Enter in the direct command
// window.  We must NOT call SP_FPExecuteEditLine here - that function can
// re-enter SP_FPWaitForUserEvent / SP_WaitForSync, which blocks the VCL
// thread permanently (it can no longer pump Windows messages).
//
// Instead we pre-populate EDITLINE and raise DWCommandPending.  The
// interpreter thread checks this flag in its SP_GetFPUserInput loop,
// executes the command from there, and clears the component afterwards.
//
// Safety: the interpreter thread is blocked in SP_WaitForSync while the
// user is typing, so writing EDITLINE here before setting the flag is
// race-free on all x86/x64 platforms.


Procedure TDWEditorBridge.Execute(Sender: SP_BaseComponent; Text: aString);
Begin
  If EDITRESULT Then Exit;
  EDITLINE         := Text;
  DWCommandPending := True;
End;

// Fired whenever the component's wrapped-line count changes.
// Resize the DW window to fit exactly, which also adjusts the FP window above.
Procedure TDWEditorBridge.NeedHeight(Sender: SP_BaseComponent);
Var NewH: Integer;
Begin
  If Not Assigned(DWBASICEditor) Then Exit;
  // wraps * font height + top/bottom margin (BSize each) + caption + bottom border
  NewH := (DWBASICEditor.WrappedCount * FPFh) + FPCaptionHeight + (BSize * 2) + 1;
  NewH := Max(NewH, FPFh + FPCaptionHeight + (BSize * 2) + 1);  // at least one row
  If NewH <> DWWindowHeight Then
    SP_DWResizeWindow(DWWindowWidth, NewH);
End;

// Fired when the component gains or loses focus.
// Keeps fwDirect / FocusedWindow consistent with the component's focus state.
Procedure TDWEditorBridge.DWFocused(Sender: SP_BaseComponent; Focused: Boolean);
Begin
  If Focused And (FocusedWindow <> fwDirect) Then
    SP_SwitchFocus(fwDirect);
End;

Procedure TDWEditorBridge.MouseMoved(Sender: SP_BaseComponent; Mx, My, Btn: Integer);
Var
  screenPt: TPoint;
Begin
  If MOUSEBTN <> 0 Then Exit;
  screenPt := Sender.ClientToScreen(Point(Mx, My));
  CheckForTip(screenPt.X, screenPt.Y);
End;

// Fired on every cursor movement so the status bar column counter stays current.
Procedure TDWEditorBridge.CursorMove(Sender: SP_BaseComponent);
Begin
  UpdateStatusLabel;
End;

Procedure TDWEditorBridge.EditorSearchRequest(Sender: SP_BaseComponent);
Begin
  If Assigned(FPBASICEditor) Then FPBASICEditor.ShowSearchBar;
End;

Procedure EditorHost_SwitchMode(EditorMode: Boolean);
Begin
  If Not Assigned(FPBASICEditor) Then Exit;
  If EditorMode Then
    FPBASICEditor.Mode := bemEditor
  Else
    FPBASICEditor.Mode := bemPROGLINE;
End;

// Fired on every single-line text change.
Procedure TEditorHostBridge.BASICLineChanged(Sender: TObject; RawLine, BASICLine, Statement: Integer);
Var
  OldLineNum, PrevLine: Integer;
Begin
  If Not Assigned(Listing) Then Exit;
  CompilerLock.Enter;
  Try
    While Listing.Count <= RawLine Do
      Listing.Add('');

    OldLineNum := SP_GetLineNumberFromText(Listing[RawLine]);
    If (OldLineNum > 0) And (OldLineNum <> BASICLine) And (Listing.Flags[RawLine].State = spLineOk) Then
      SP_Program_Delete_Line(OldLineNum);

    Listing[RawLine] := FPBASICEditor.Lines[RawLine];
    AddCompileLine(RawLine);

    // if this raw line just acquired a line number where it previously
    // had none, the preceding BASIC line has lost a continuation and its
    // cached compile result is now stale. Re-queue it.
    If (OldLineNum = 0) And (SP_GetLineNumberFromText(Listing[RawLine]) > 0) And (RawLine > 0) Then Begin
      PrevLine := RawLine - 1;
      While (PrevLine > 0) And (SP_LineHasNumber(PrevLine) = 0) Do
        Dec(PrevLine);
      If SP_LineHasNumber(PrevLine) > 0 Then
        AddCompileLine(PrevLine);
    End;

    // If this raw line just LOST its line number, the preceding BASIC line
    // has gained a continuation and its compile result is stale.
    If (OldLineNum > 0) And (SP_GetLineNumberFromText(Listing[RawLine]) = 0)
       And (RawLine > 0) Then Begin
      PrevLine := RawLine - 1;
      While (PrevLine > 0) And (SP_LineHasNumber(PrevLine) = 0) Do
        Dec(PrevLine);
      If SP_LineHasNumber(PrevLine) > 0 Then
        AddCompileLine(PrevLine);
    End;

  Finally
    CompilerLock.Leave;
  End;
End;

// Fired when raw lines are inserted or deleted.
// Fired when raw lines are inserted or deleted.
Procedure TEditorHostBridge.StructureChanged(Sender: TObject; AtLine, Delta: Integer);
Var
  i, LineNum: Integer;
Begin
  If Not Assigned(Listing) Then Exit;
  CompilerLock.Enter;
  Try
    If Delta > 0 Then Begin
      For i := 1 To Delta Do Begin
        If AtLine <= Listing.Count Then Listing.Insert(AtLine, '')
        Else                            Listing.Add('');
        // TAnsiStringlist.Insert shifts entries down with a flag-copy loop,
        // so the new slot inherits the preceding entry's flags - including
        // its State.  A freshly-inserted continuation row must start as
        // spLineNull: it has no compile result of its own yet, and showing
        // the numbered line's spLineOk state on it produces a spurious green
        // blob in the gutter.
        If AtLine < Listing.Count Then
          Listing.Flags[AtLine].State := spLineNull;
      End;
    End Else Begin
      // Before removing rows from Listing, scrub any BASIC line numbers
      // they contain from SP_Program so deleted lines don't linger as ghosts.
      For i := AtLine To AtLine + (-Delta) - 1 Do
        If i < Listing.Count Then Begin
          LineNum := SP_GetLineNumberFromText(Listing[i]);
          If LineNum > 0 Then
            SP_Program_Delete_Line(LineNum);
        End;
      For i := 1 To -Delta Do
        If AtLine < Listing.Count Then Listing.Delete(AtLine);
    End;
  Finally
    CompilerLock.Leave;
  End;
End;

// Fired after a whole-text replacement.
Procedure TEditorHostBridge.TextReset(Sender: SP_BaseComponent);
Var i: Integer;
Begin
  If Not Assigned(Listing) Then Exit;
  CompilerLock.Enter;
  Try
    Listing.Clear;
    For i := 0 To FPBASICEditor.Lines.Count - 1 Do
      Listing.Add(FPBASICEditor.Lines[i]);
    // Reset stale flags - TAnsiStringlist.Add does not zero-init fFlags
    // on re-use after Clear, so old State values survive. SetAllToCompile
    // will mark numbered lines dirty; continuations must start as spLineNull.
    For i := 0 To Listing.Count - 1 Do
      Listing.Flags[i].State := spLineNull;
    SetAllToCompile;
  Finally
    CompilerLock.Leave;
  End;
End;

// Fired when the user double-clicks the gutter to toggle a breakpoint.
Procedure TEditorHostBridge.BreakpointToggle(Sender: TObject;
  BASICLine, Statement: Integer; Active: Boolean);
Var i, j, l: Integer;
Begin
  l := Length(SP_SourceBreakpointList);
  If Active Then Begin
    For i := 0 To l - 1 Do
      If (SP_SourceBreakpointList[i].Line      = BASICLine) And
         (SP_SourceBreakpointList[i].Statement = Statement) Then Exit;
    SP_AddSourceBreakpoint(False, BASICLine, Statement, 0, '');
  End Else Begin
    For i := 0 To l - 1 Do
      If (SP_SourceBreakpointList[i].Line      = BASICLine) And
         (SP_SourceBreakpointList[i].Statement = Statement) Then Begin
        For j := i To l - 2 Do
          SP_SourceBreakpointList[j] := SP_SourceBreakpointList[j + 1];
        SetLength(SP_SourceBreakpointList, l - 1);
        Break;
      End;
  End;
  SP_GetDebugStatus(dbgBreakpoints);
End;

Procedure TEditorHostBridge.EditorFocused(Sender: SP_BaseComponent; Focused: Boolean);
Begin
  If Focused And (FocusedWindow <> fwEditor) Then
    SP_SwitchFocus(fwEditor);
End;

Procedure TEditorHostBridge.CursorMove(Sender: SP_BaseComponent);
Begin
  UpdateStatusLabel;
End;

Procedure TEditorHostBridge.MouseMoved(Sender: SP_BaseComponent; Mx, My, Btn: Integer);
Var
  screenPt: TPoint;
Begin
  If MOUSEBTN <> 0 Then Exit;
  screenPt := Sender.ClientToScreen(Point(Mx, My));
  CheckForTip(screenPt.X, screenPt.Y);
End;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

Procedure WireEvents;
Begin
  FPBASICEditor.OnBASICLineChanged := Bridge.BASICLineChanged;
  FPBASICEditor.OnStructureChanged := Bridge.StructureChanged;
  FPBASICEditor.OnTextReset        := Bridge.TextReset;
  FPBASICEditor.OnBreakpointToggle := Bridge.BreakpointToggle;
  FPBASICEditor.OnFocus            := Bridge.EditorFocused;
  FPBASICEditor.OnCursorMove       := Bridge.CursorMove;
  FPBASICEditor.OnMouseMove        := Bridge.MouseMoved;
End;

Procedure SilenceEvents;
Begin
  FPBASICEditor.OnBASICLineChanged := nil;
  FPBASICEditor.OnStructureChanged := nil;
  FPBASICEditor.OnTextReset        := nil;
  FPBASICEditor.OnFocus            := nil;
  FPBASICEditor.OnCursorMove       := nil;
  FPBASICEditor.OnMouseMove        := nil;
End;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

Procedure EditorHost_Init(WinComponent: SP_BaseComponent);
Begin
  Bridge := TEditorHostBridge.Create;

  // Tab bar - SP_AlignBottom so AlignChildren pass 1 carves its height off the
  // bottom of the window before FPBASICEditor (SP_AlignAll) fills the rest.
  // Must be created before FPBASICEditor so it appears first in the component
  // list and is therefore processed in pass 1 before any AlignAll child.
  FPTabBar := SP_TabBar.Create(WinComponent);
  FPTabBar.Align := SP_AlignBottom;
  FPTabBar.Proportional := True;

  FPBASICEditor := SP_BASICEditor.Create(WinComponent);
  FPBASICEditor.Padding     := 4;
  FPBASICEditor.Align       := SP_AlignAll;  // fills the window client area
  FPBASICEditor.ShowGutter  := True;
  FPBASICEditor.Highlight   := True;
  FPBASICEditor.SmartIndent := True;
  FPBASICEditor.WordWrap    := EDITORWRAP;
  FPBASICEditor.Border      := False;
  FPBASICEditor.Name        := 'Editor';
  FPBASICEditor.BackgroundClr := 7;
  // AlignChildren has now run (triggered by SetAlign on FPBASICEditor above),
  // giving FPTabBar its real pixel width via SetBounds.  SetupTabBar calls
  // AddTab → LayoutTabs, which needs the correct fWidth to compute natural
  // tab widths.  Calling it before FPBASICEditor.Create meant LayoutTabs ran
  // with fWidth = 16px (the base constructor default), producing a narrow tab
  // that snapped to the correct width only on the first mouse-over repaint.
  SP_EditorTab_SetupTabBar;

  WireEvents;
  // Populate from whatever Listing already contains (may be empty for NEW,
  // or full if recovering from an error / returning from the runtime).
  EditorHost_LoadFromListing;
  EditorHost_RefreshLineStates;
  EditorHost_ClearExecLine;
  // If the editor is already the focused window (e.g. re-opening after a run),
  // give the component focus immediately so it can accept keystrokes.
  If FocusedWindow = fwEditor Then
    FPBASICEditor.SetFocus(True)
  Else
    FPBASICEditor.SetFocus(False);
End;

Procedure EditorHost_Resize;
Begin
  If Assigned(FPBASICEditor) Then Begin
    FPBASICEditor.GetParentControl.AlignChildren;
    SP_InvalidateWholeDisplay;
  End;
End;
Procedure EditorHost_Destroy;
Begin
  FreeAndNil(Bridge);
  If Assigned(TabBridge) Then FreeAndNil(TabBridge);
  FPTabBar      := nil;  // Freed by Win^.Component when the window is deleted
  FPBASICEditor := nil;  // Freed by Win^.Component when the window is deleted
End;

// ---------------------------------------------------------------------------
// Direct command editor lifecycle
// ---------------------------------------------------------------------------

Procedure DWHost_Init(WinComponent: SP_BaseComponent);
Begin
  DWBridge      := TDWEditorBridge.Create;
  DWBASICEditor := SP_BASICEditor.Create(WinComponent);
  DWBASICEditor.Padding      := 4;
  DWBASICEditor.Align        := SP_AlignAll;
  DWBASICEditor.Border       := False;
  DWBASICEditor.Margin       := BSize;         // 8px - matches legacy DWPaper insets
  DWBASICEditor.Mode         := bemDirect;     // hides gutter, enables history etc.
  DWBASICEditor.OnExecute    := DWBridge.Execute;
  DWBASICEditor.OnNeedHeight := DWBridge.NeedHeight;
  DWBASICEditor.OnFocus      := DWBridge.DWFocused;
  DWBASICEditor.OnCursorMove := DWBridge.CursorMove;
  DWBASICEditor.OnEditorSearchRequest := DWBridge.EditorSearchRequest;
  DWBASICEditor.OnMouseMove := DWBridge.MouseMoved;
  DWBASICEditor.Name        := 'Direct';
  DWBASICEditor.BackgroundClr := 7;

  // Restore history from previous session
  If Length(EditorHistory) > 0 Then
    DWBASICEditor.LoadHistory(EditorHistory);
  // Start unfocused; SP_SwitchFocus will grant focus when appropriate.
  DWBASICEditor.SetFocus(False);
End;

Procedure DWHost_Resize;
Begin
  If Assigned(DWBASICEditor) Then
    DWBASICEditor.GetParentControl.AlignChildren;
End;

Procedure DWHost_Destroy;
Var
  snap: TStringDynArray;
  i: Integer;
Begin
  If Assigned(DWBASICEditor) Then Begin
    snap := DWBASICEditor.GetHistorySnapshot;
    SetLength(EditorHistory, Length(snap));
    For i := 0 To Length(snap) - 1 Do
      EditorHistory[i] := snap[i];  // proper reference-counted assignment
  End;
  FreeAndNil(DWBridge);
  DWBASICEditor := nil;
End;

// ---------------------------------------------------------------------------
// Program content
// ---------------------------------------------------------------------------

Procedure EditorHost_LoadFromListing;
Var i: Integer; sb: aString;
Begin
  If Not Assigned(FPBASICEditor) Or Not Assigned(Listing) Then Exit;
  SilenceEvents;
  Try
    // Build a single #13-delimited string; SetText triggers OnFullTextReplaced
    // which resizes all marker arrays to match the new line count.
    sb := '';
    CompilerLock.Enter;
    Try
      For i := 0 To Listing.Count - 1 Do Begin
        If i > 0 Then sb := sb + #13;
        sb := sb + Listing[i];
      End;
    Finally
      CompilerLock.Leave;
    End;
    FPBASICEditor.SetText(sb);

    // Re-paint any breakpoints that were already set in SP_SourceBreakpointList
    // (e.g. restored from a saved session, or set before the window was created).
    For i := 0 To Length(SP_SourceBreakpointList) - 1 Do
      With SP_SourceBreakpointList[i] Do
        If bpType <> BP_IsHidden Then
          FPBASICEditor.SetBreakpointByBASICLine(Line, Statement, True);
  Finally
    WireEvents;
  End;
End;

Procedure EditorHost_NewProgram;
Begin
  If Not Assigned(FPBASICEditor) Then Exit;
  SilenceEvents;
  Try
    // Clear fires OnFullTextReplaced which resizes all marker arrays to 1.
    FPBASICEditor.Clear;
    FPBASICEditor.ClearLineStates;
    FPBASICEditor.ClearBreakpoints;
    FPBASICEditor.ClearExecLine;
  Finally
    WireEvents;
  End;
End;

Function EditorHost_GetLineCount: Integer;
Begin
  If Assigned(FPBASICEditor) Then
    Result := FPBASICEditor.Lines.Count
  Else If Assigned(Listing) Then
    Result := Listing.Count
  Else
    Result := 0;
End;

Function EditorHost_GetLine(Idx: Integer): aString;
Begin
  If Assigned(FPBASICEditor) Then Begin
    If (Idx >= 0) And (Idx < FPBASICEditor.Lines.Count) Then
      Result := FPBASICEditor.Lines[Idx]
    Else
      Result := '';
  End Else If Assigned(Listing) Then Begin
    If (Idx >= 0) And (Idx < Listing.Count) Then
      Result := Listing[Idx]
    Else
      Result := '';
  End Else
    Result := '';
End;

Procedure EditorHost_SetProgram(Const NewProg: Array Of aString);
Var i: Integer; sb: aString;
Begin
  If Assigned(FPBASICEditor) Then Begin
    sb := '';
    For i := 0 To High(NewProg) Do Begin
      If i > 0 Then sb := sb + #13;
      sb := sb + NewProg[i];
    End;
    FPBASICEditor.SetText(sb);
  End Else Begin
    CompilerLock.Enter;
    Try
      Listing.Clear;
      For i := 0 To High(NewProg) Do
        SP_AddLine(NewProg[i], '', '');
    Finally
      CompilerLock.Leave;
    End;
  End;
End;

Procedure EditorHost_LoadFromText(Const RawText: aString; Out AutoStart: Integer; Out ProgName:  aString; Out Changed:   Boolean);
Var
  Lines:      TAnsiStringList;
  i, c:       Integer;
  cleanText:  aString;
  InString:   Boolean;
Begin

  // Remove tab chars
  c := 1;
  CleanText := RawText;
  InString := False;
  For i := 1 To Length(CleanText) Do Begin
    If CleanText[i] = '"' Then
      InString := Not InString
    Else If (CleanText[i] = #9) And Not InString Then
      CleanText[i] := ' ';
  End;
  AutoExpandCompounds(CleanText, c);

  If Assigned(FPBASICEditor) Then Begin
    // Component is open: use the rich load path - fires OnTextReset which
    // rebuilds Listing and calls SetAllToCompile.
    FPBASICEditor.LoadFromBASICText(CleanText, AutoStart, ProgName, Changed);
  End Else Begin
    // Editor not yet open (startup sequence): parse the text and populate
    // Listing directly so EditorHost_LoadFromListing can push it across when
    // the editor window opens.
    Lines := SP_BASICEditor.ParseBASICText(CleanText, AutoStart, ProgName, Changed);
    Try
      CompilerLock.Enter;
      Try
        Listing.Clear;
        For i := 0 To Lines.Count - 1 Do
          SP_AddLine(Lines[i], '', '');
      Finally
        CompilerLock.Leave;
      End;
    Finally
      Lines.Free;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// Structural program operations
// ---------------------------------------------------------------------------

// All four operations delegate entirely to the component when it is open.
// The component fires OnFullTextReplaced - OnTextReset - host TextReset,
// which rebuilds Listing and calls SetAllToCompile - so no extra Listing
// manipulation is needed here.
//
// When the editor window is not yet open (startup / command-line only) we
// fall back to direct Listing manipulation via the existing SP_* helpers,
// which is the same path as before this refactor.

Procedure EditorHost_SortByLineNumber;
Begin
  If Assigned(FPBASICEditor) Then
    FPBASICEditor.SortByLineNumber
  Else Begin
    // Listing-only fallback: SP_ReOrderListing still lives in SP_FPEditor
    // and will be called from the SP_FPEditor wrapper for now.
  End;
End;

Procedure EditorHost_RenumberLines(Start, Finish, FirstLine, Step: Integer);
Begin
  // SP_FPRenumberListing now runs the full Listing-based algorithm directly and
  // calls EditorHost_LoadFromListing afterwards to sync the component.
  // This stub is retained for any future callers.
End;

Procedure EditorHost_DeleteLineRange(Start, Finish: Integer);
Begin
  // SP_FPDeleteLines now runs the full Listing-based algorithm directly and
  // calls EditorHost_LoadFromListing afterwards to sync the component.
End;

Procedure EditorHost_MergeLineRange(Start, Finish: Integer);
Begin
  // SP_FPMergeLines now runs the full Listing-based algorithm directly and
  // calls EditorHost_LoadFromListing afterwards to sync the component.
End;

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

Procedure EditorHost_ScrollToLine(LineNum, Statement: Integer);
Begin
  If Assigned(FPBASICEditor) Then
    FPBASICEditor.GotoBASICLine(LineNum, Statement);
End;

Procedure EditorHost_StoreLine(LineNum: Integer);
// Called by SP_DWStoreLine after Listing has been updated with a single
// typed line (new, replace, or delete).  Rebuilds the component text from
// Listing while preserving scroll position, then places the cursor on the
// affected BASIC line.  Uses the same SilenceEvents guard as LoadFromListing
// so no spurious TextReset / BASICLineChanged callbacks fire.
Var i: Integer; sb: aString;
Begin
  If Not Assigned(FPBASICEditor) Or Not Assigned(Listing) Then Exit;
  SilenceEvents;
  Try
    sb := '';
    CompilerLock.Enter;
    Try
      For i := 0 To Listing.Count - 1 Do Begin
        If i > 0 Then sb := sb + #13;
        sb := sb + Listing[i];
      End;
    Finally
      CompilerLock.Leave;
    End;
    FPBASICEditor.SetText(sb);
    // Restore breakpoint markers (SetText clears them).
    For i := 0 To Length(SP_SourceBreakpointList) - 1 Do
      With SP_SourceBreakpointList[i] Do
        If bpType <> BP_IsHidden Then
          FPBASICEditor.SetBreakpointByBASICLine(Line, Statement, True);
  Finally
    WireEvents;
  End;
  // Place the cursor on the line that was just stored/deleted.
  If LineNum > 0 Then
    FPBASICEditor.GotoBASICLine(LineNum, 1);
End;

Procedure EditorHost_SetExecLine(BASICLine, Statement: Integer);
Begin
  If Not Assigned(FPBASICEditor) Then Exit;
  FPBASICEditor.SetExecLineByBASICLine(BASICLine, Statement);
  FPBASICEditor.Paint;
  SP_InvalidateWholeDisplay;
End;

Procedure EditorHost_SetExecLineWithScroll(BASICLine, Statement: Integer);
Begin
  If Not Assigned(FPBASICEditor) Then Exit;
  FPBASICEditor.SetExecLineByBASICLine(BASICLine, Statement);
  EditorHost_ScrollToLine(BASICLine, Statement);
  FPBASICEditor.Paint;
  SP_InvalidateWholeDisplay;
End;

Procedure EditorHost_ClearExecLine;
Begin
  If Not Assigned(FPBASICEditor) Then Exit;
  FPBASICEditor.ClearExecLine;
  FPBASICEditor.Paint;
  SP_InvalidateWholeDisplay;
End;

Procedure EditorHost_SetBookMark(bmIndex, Line, Statement: Integer);
Begin
  If Not Assigned(FPBASICEditor) Then Exit;
  FPBASICEditor.SetBookmarkBASICLine(bmIndex, Line, Statement);
  SP_InvalidateWholeDisplay;
End;

Procedure EditorHost_GotoBookMark(bmIndex: Integer);
Begin
  If Not Assigned(FPBASICEditor) Then Exit;
  FPBASICEditor.GoToBookMark(bmIndex);
End;

Function EditorHost_GetBookMark(bmIndex: Integer): Boolean;
Begin
  Result := False;
  If Not Assigned(FPBASICEditor) Then Exit;
  Result := FPBASICEditor.BookMarkLine(bmIndex) <> -1;
End;

Procedure EditorHost_ClearBookMarks;
Begin
  If Not Assigned(FPBASICEditor) Then Exit;
  FPBASICEditor.ClearBookMarks;
End;

// ---------------------------------------------------------------------------
// Compiler bridge
// ---------------------------------------------------------------------------

Procedure EditorHost_RefreshLineStates;
Var
  i, n: Integer; st: SP_LineState;
Begin
  If Not Assigned(FPBASICEditor) Or Not Assigned(Listing) Then Exit;
  CompilerLock.Enter;
  Try
    n := Min(Listing.Count, FPBASICEditor.Lines.Count);
    For i := 0 To n - 1 Do Begin
      Case Listing.Flags[i].State Of
        spLineNull:      st := SP_BASICEditorUnit.spLineNull;
        spLineOk:        st := SP_BASICEditorUnit.spLineOk;
        spLineDirty:     st := SP_BASICEditorUnit.spLineDirty;
        spLineDuplicate: st := SP_BASICEditorUnit.spLineDuplicate;
        spLineError:     st := SP_BASICEditorUnit.spLineError;
      Else               st := SP_BASICEditorUnit.spLineNull;
      End;
      FPBASICEditor.SetLineState(i, st);
    End;
  Finally
    CompilerLock.Leave;
  End;
  // Signal the main loop to repaint - never call Paint from this thread.
  NeedGutterRefresh := True;
End;

// ---------------------------------------------------------------------------
// Breakpoints
// ---------------------------------------------------------------------------

Procedure EditorHost_ToggleBreakpoint;
Var
  BASICLine, Statement, i, j, l: Integer;
  WasActive: Boolean;
Begin
  If Not Assigned(FPBASICEditor) Then Exit;
  BASICLine := EditorHost_GetCursorBASICLine;
  Statement := EditorHost_GetCursorStatement;
  If BASICLine < 0 Then Exit;

  WasActive := False;
  l := Length(SP_SourceBreakpointList);
  For i := 0 To l - 1 Do
    If (SP_SourceBreakpointList[i].Line      = BASICLine) And
       (SP_SourceBreakpointList[i].Statement = Statement) And
       (SP_SourceBreakpointList[i].bpType   <> BP_IsHidden) Then Begin
      WasActive := True;
      Break;
    End;

  If WasActive Then Begin
    For j := i To l - 2 Do
      SP_SourceBreakpointList[j] := SP_SourceBreakpointList[j + 1];
    SetLength(SP_SourceBreakpointList, l - 1);
    FPBASICEditor.SetBreakpointByBASICLine(BASICLine, Statement, False);
  End Else Begin
    SP_AddSourceBreakpoint(False, BASICLine, Statement, 0, '');
    FPBASICEditor.SetBreakpointByBASICLine(BASICLine, Statement, True);
  End;

  SP_GetDebugStatus(dbgBreakpoints);
End;

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

Function EditorHost_GetCursorBASICLine: Integer;
Var raw, first: Integer;
Begin
  Result := -1;
  If Not Assigned(FPBASICEditor) Then Exit;
  raw   := FPBASICEditor.CursorLine;
  first := raw;
  While (first > 0) And
        (first < Length(FPBASICEditor.LineNumLen)) And
        (FPBASICEditor.LineNumLen[first] = 0) Do Dec(first);
  Result := FPBASICEditor.RawLineNumber(first);
End;

Function EditorHost_GetCursorStatement: Integer;
Var raw: Integer;
Begin
  Result := 1;
  If Not Assigned(FPBASICEditor) Then Exit;
  raw := FPBASICEditor.CursorLine;
  If (raw >= 0) And (raw < FPBASICEditor.Lines.Count) Then
    Result := FPBASICEditor.StatementAtCol(raw, FPBASICEditor.CursorCol);
End;

Function EditorHost_CheckProgram(OnlyErrors: Boolean): Boolean;
Var i: Integer; s: Byte;
Begin
  Result := True;
  If Not Assigned(Listing) Then Exit;
  CompilerLock.Enter;
  Try
    For i := 0 To Listing.Count - 1 Do Begin
      s := Listing.Flags[i].State;
      If s In [spLineError, spLineDuplicate] Then Begin Result := False; Break; End;
      If (Not OnlyErrors) And (s = spLineDirty)  Then Begin Result := False; Break; End;
    End;
  Finally
    CompilerLock.Leave;
  End;
End;

// ---------------------------------------------------------------------------
// Context-sensitive help support
// ---------------------------------------------------------------------------

// Return the BASIC keyword or identifier under (or adjacent to) the cursor.
// Walks left and right from CursorCol in the raw line text, collecting
// characters that are legal in a keyword or identifier: A-Z, a-z, 0-9, $.
// Leading line-number digits are skipped via GetLineNumLen.
// Returns '' if the cursor is on whitespace or punctuation.
Function EditorHost_GetWordAtCursor: aString;
Var
  raw, col, numLen, lLen, lo, hi: Integer;
  line: aString;
Begin
  Result := '';
  If Not Assigned(FPBASICEditor) Then Exit;

  raw    := FPBASICEditor.CursorLine;
  col    := FPBASICEditor.CursorCol;
  If (raw < 0) Or (raw >= FPBASICEditor.Lines.Count) Then Exit;

  line   := FPBASICEditor.Lines[raw];
  lLen   := Length(line);
  numLen := FPBASICEditor.GetLineNumLen(raw);

  // Clamp col to the content area (after line number)
  If col <= numLen Then col := numLen + 1;
  If col > lLen    Then col := lLen;
  If col < 1       Then Exit;

  // Check the character at col is part of a word
  If Not (line[col] In ['A'..'Z', 'a'..'z', '0'..'9', '$', '_']) Then Exit;

  // Walk left
  lo := col;
  While (lo > numLen + 1) And
        (line[lo - 1] In ['A'..'Z', 'a'..'z', '0'..'9', '$', '_']) Do
    Dec(lo);

  // Walk right
  hi := col;
  While (hi < lLen) And
        (line[hi + 1] In ['A'..'Z', 'a'..'z', '0'..'9', '$', '_']) Do
    Inc(hi);

  Result := Copy(line, lo, hi - lo + 1);
End;

end.
