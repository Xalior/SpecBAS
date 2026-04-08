// Copyright (C) 2016 By Paul Dunn
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

Unit SP_FPEditor;

{$INCLUDE SpecBAS.inc}

// todo:

// High Priority:

//    Upgrade INPUT line editor to respond like the current DW (if no FORMAT specified!)
//    UI Toolkit:
//      Windows with decoration, moveable, resizeable
//      graphic, tabcontrol bar, icon bar, treeview

// Medium Priority:

//    New dialogs:
//      *File (load/save)
//      *Find/Replace
//      *GO TO (line number, proc/fn, label)
//      *Debug window - Tabs for Virtual CPU, Variables, Machine Stack, GOSUB Stack, Watches, Breakpoints
//      Preferences
//      Tool management (add/remove to/from tools menu)
//        Character map
//        Paintbox for sprites
//        Font Editor
//        User tools submenu

// Low Priority:

interface

Uses Types, Classes, SyncObjs, SysUtils, Math{$IFNDEF FPC}, Windows{$ENDIF}, SP_Graphics, SP_BankManager, SP_SysVars,
     SP_Errors, SP_Main, SP_Tokenise, SP_BankFiling, SP_UITools, SP_Input, SP_Sound, SP_InfixToPostFix, SP_Interpret_PostFix,
     SP_FileIO, SP_Package, SP_Variables, SP_Components, SP_Menu, SP_AnsiStringlist, SP_WindowMenuUnit, SP_PopUpMenuUnit,
     SP_MenuActions, SP_Util, SP_ProgressBarUnit, SP_ToolTipWindow, SP_Compiler, SP_BASICEditorHostUnit, SP_MemoUnit;

Type

  pSP_EditorEvent = Pointer;
  SP_EventData = Record Pos, Key, Button, X, Y, tsData: Integer; ObjectPtr: Pointer; End;
  SP_EventHandler = Procedure(Var Data: SP_EventData);
  SP_EventOnLaunch = Procedure(Event: pSP_EditorEvent);
  SP_SelectionInfo = Record Active, Multiline: Boolean; StartL, EndL, StartP, EndP, Dir: Integer; End;
  SP_SearchInfo = Record Line, Position, Length: Integer; Split: Boolean; End;

  SP_EditorEvent = Record
    ID: Integer;
    EvType: Integer;              // Type of event
    TargetFrame: Integer;         // The framecount needed for this event to trigger
    Delay1, Delay2: Integer;      // After being triggered, this is the number of frames to wait before triggering again. 0 = one-shot.
    Data: SP_EventData;           // the data for the event (mouse position/button, key)
    OnLaunch: SP_EventOnLaunch;   // The address of the procedure to call
    OneShot: Boolean;             // If set, event is removed from the event list once executed.
    Tag: NativeUInt;              // Anything using the event can set a value here
  End;

Procedure SetIsPoI(Index: Integer); inline;
Procedure UpdatePoIStatus; Inline;

Procedure SP_InitFPEditor;
Procedure SP_AddLine(Const l, s, c: aString);
Procedure SP_InsertLine(Index: Integer; Const l, s, c: aString; MarkDirty: Boolean = True);
Procedure SP_DeleteLine(Index: Integer; MarkDirty: Boolean = True);
Procedure SP_ClearListing;
Function  SP_LineFlags(Index: Integer): pLineFlags;
Procedure SP_FPEditorError(Var Error: TSP_ErrorCode; LineNum: Integer = -2);
Procedure SP_CreateFontMetrics;
Procedure SP_SetFPClientMetrics;
Procedure SP_CreateFPWindow;
Procedure SP_InitDWMetrics;
Procedure SP_CreateDirectWindow;
Procedure SP_FPCycleEditorWindows(HideMode: Integer);
Procedure SP_FPResizeWindow(NewH: Integer);
Procedure SP_DWResizeWindow(NewW, NewH: Integer);
Procedure SP_Decorate_Window(WindowID: Integer; Title: aString; Clear, SizeGrip, Focused: Boolean);
Procedure SP_DrawStripe(Dst: pByte; Width, StripeWidth, StripeHeight, BatteryLevel: Integer; Focused: Boolean);
Function  SP_SetFPEditorFont: Integer;
Procedure SP_SwitchFocus(FocusMode: Integer);
Procedure SP_FPNewProgram;
Procedure SP_FPEditorLoop;
Function  SP_CheckForConflict(LineIndex: Integer): Boolean;
Function  SP_GetLineIndex(LineNum: Integer): Integer;
Function  SP_GetLineNumberFromText(Const Txt: aString): Integer;
Function  SP_GetFPLineNumber(Idx: Integer): Integer;
Procedure SP_FPScrollToLine(Line, Statement: Integer);
Procedure SP_GetFPUserInput;
Procedure SP_FPEditorHandleMouseUp(X, Y: Integer);
Procedure SP_FPEditorHandleMouseDown(X, Y: Integer);
Procedure SP_FPEditorHandleMouseMove(X, Y: Integer);
Procedure SP_FPEditorHandleMouseWheel(WheelUp: Boolean; X, Y: Integer);
Function  SP_GetLineNumberFromIndex(Var Idx: Integer): Integer;
Function  SP_LineNumberSize(Idx: Integer): Integer;
Function  SP_LineHasNumber(Idx: Integer): Integer;
Function  SP_LineHasNumber_Fast(Idx: Integer): Boolean;
Procedure SP_AddEvent(Var Event: SP_EditorEvent);
Function  SP_FindEvent(ID: Integer): Integer;
Procedure SP_DeleteEvent(ID: Integer);
Procedure SP_DeleteAllEvents(eventType: Integer);
Procedure SP_LaunchEvent(Event: pSP_EditorEvent);
Procedure SP_CheckEvents;
Function  SP_PtInSelection(Sel: SP_SelectionInfo; p: TPoint): Boolean;
Procedure SP_FPEditorPerformEdit(Key: pSP_KeyInfo);
Procedure SP_FPBringToEditor(LineNum, Statement: Integer; Var Error: TSP_ErrorCode; DoEdit: Boolean = True);
Procedure SP_DWPerformEdit(Key: pSP_KeyInfo);
Procedure SP_DWStoreLine(Line: aString);
Procedure SP_StoreBASICLine(Const TokensStr: aString);
Procedure SP_ShowExprResult(Const Expr: aString);
Procedure SP_FPExecuteEditLine(Var Line: aString);
Function  SP_FPExecuteNumericExpression(Const Expr: aString; var Error: TSP_ErrorCode): aFloat;
Function  SP_FPExecuteStringExpression(Const Expr: aString; var Error: TSP_ErrorCode): aString;
Function  SP_FPExecuteAnyExpression(Const Expr: aString; var Error: TSP_ErrorCode): aString;
Procedure SP_FPExecuteExpression(Const Expr: aString; var Error: TSP_ErrorCode);
Function  SP_FPCheckExpression(Const Expr: aString; var Error: TSP_ErrorCode): Boolean;
Procedure SP_CloseEditorWindows;
Procedure SP_CreateEditorWindows;
Function  SP_ReOrderListing(Var Error: TSP_ErrorCode): Boolean;
Procedure SP_FPRenumberListing(Start, Finish, Line, Step: Integer; Var Error: TSP_ErrorCode);
Procedure SP_FPDeleteLines(Start, Finish: Integer; var Error: TSP_ErrorCode);
Procedure SP_FPMergeLines(Start, Finish: Integer; var Error: TSP_ErrorCode);
Function  SP_EditorLineCount: Integer;
Function  SP_EditorLine(Idx: Integer): aString;
Procedure SP_LoadIntoEditor(Const NewProg: Array Of aString);
Procedure SP_LoadIntoEditorFromText(Const RawText: aString;
                                    Out AutoStart: Integer;
                                    Out ProgName:  aString;
                                    Out Changed:   Boolean);

Procedure ListingChange(Index, Operation: Integer);
Procedure StartWatchOp(Index: Integer);
Procedure StartBPEditOp(BPIndex: Integer; Bp: pSP_BreakPointInfo);
Procedure StartGotoOp;
Procedure StartFindOp(Find: Boolean);
Procedure StartFileOp(Operation: Integer; Filename: aString);
Procedure FindNext(jumpNext: Boolean);
Function  ProcessHint(Var s: aString; cPos: Integer; var i, j: Integer): SP_Hint;
Procedure EvaluateHint(Var Result: SP_Hint);

Function  SP_CheckProgram(OnlyErrors: Boolean = False): Boolean;
Procedure SP_ShowError(Code, Line, Pos: Integer);
Procedure SP_FPSetDisplayColours;
Procedure SP_ToggleBreakPoint(Hidden: Boolean);
Procedure SP_FPGotoLine(line, statement: Integer);
Procedure SP_ResetConditionalBreakPoints;
Procedure SP_PrepareBreakpoints(Create: Boolean);
Function  SP_IsSourceBreakPoint(Line, Statement: Integer): Boolean;
Procedure SP_SingleStep;
Function  SP_StepOver: Boolean;
Procedure SP_ClearBreakPoints;
Procedure SP_GetDebugStatus(StatType: Integer);

Var
  // Editor window
  FPWindowID, FPFw, FPFh, Fw, Fh, FPWindowWidth, FPWindowHeight, FPWindowTop, FPWindowLeft: Integer;
  FPGutterWidth, FPCaptionHeight, FPStripePos: Integer;
  BringToEditorAfterError: Boolean = False;
  Listing: TAnsiStringlist;
  EdSc, EdCSc: aString;
  Events: Array of SP_EditorEvent;
  FPEditorMarkers: Array[0..9] of TPoint;
  FPShowingSearchResults, FPShowingBraces, FPHasBookMarks: Boolean;
  FPGotoText: aString;
  // Direct command window
  DWWindowID, DWWindowWidth, DWWindowHeight, DWWIndowTop, DWWindowLeft,
  FPEditorDefaultWindow: Integer;
  FPEditorDRPOSX, FPEditorDRPOSY, FPEditorSaveFPS: aFloat;
  FPEditorPRPOSX, FPEditorPRPOSY, FPEditorFRAME_MS: aFloat;
  FPEditorOVER: Integer;
  FPEditorMouseStatus: Boolean;
  // Compiler
  CompilerLock: TCriticalSection;
  CompilerThread: TCompilerThread;
  CompilerRunning: Boolean;
  CompileList: Array of Integer;
  MaxCompileLines: Integer;
  // Editor system
  EditorHistory: Array of aString;
  FPWIndowMode: Integer;
  FPEditorOutSet: Boolean;
  NeedGutterRefresh: Boolean;
  // Tools
  ToolWindowDone: Boolean;
  ToolStrResult: aString;
  ToolMode: NativeInt;

  // Search system
  LastFindwasReplace: Boolean;
  FPSearchTerm, FPReplaceTerm: aString;
  FPSearchOptions: SP_SearchOptions;
  FPShowingFindResults: Boolean;

  // Go to and Watch edit dialog
  GotoWindow: SP_TextRequester;

Const

  FPMarginSize = 2; // Gap between buttons and track in scrollbars
  FPMinGutterWidth = 4;

  evtMouseDown = 1;
  evtMouseUp = 2;
  evtMouseMove = 3;
  evtKeyDown = 4;
  evtKeyUp = 5;
  evtRefreshLine = 7;
  evtClearStatus = 8;

  evtLeftButton = 1;
  evtRightButton = 2;
  evtMiddleButton = 4;

  spLineNull= 0;
  spLineOk = 1;
  spLineDirty = 2;
  spLineDuplicate = 3;
  spLineError = 4;

  spHardReturn = 1;
  spSoftReturn = 2;

  fwNone =       -1;
  fwDebugPanel = -2;

  Seps = [' ', '(', ')', ',', ';', '"', #39, '=', '+', '-', '/', '*', '^', '%', '$', '|', '&', ':', '>', '<'];

implementation

Uses SP_ControlMsgs, SP_DebugPanel, SP_PreRun, SP_Display, SP_Graphics32, SP_BaseComponentUnit, SP_BASICEditorUnit, SP_AmigaGuideUnit, SP_Narrator;

Procedure SetIsPoI(Index: Integer);
var
  s: aString;
  c: Boolean;
Begin

  If Index > -1 Then Begin
    s := Lower(Listing[Index]);
    c := SP_Util.Pos('label', s) > 0;
    c := c or (SP_Util.Pos('def proc', s) > 0);
    c := c or (SP_Util.Pos('def fn', s) > 0);
    Listing.Flags[Index].PoI := c;
  End;

End;

Procedure UpdatePoIStatus;
Var
  i: Integer;
Begin

  For i := 0 To Listing.Count -1 Do
    SetIsPoi(i);

End;

Procedure ListingChange(Index, Operation: Integer);
Var
  c: Boolean;
Begin

  SetIsPoI(Index);
  If FPDebugPanelVisible And (FPDebugCombo.ItemIndex in  [3, 4]) Then Begin
    UpdateStatusLabel;
    SP_FPUpdatePoIList;
  End;

  Case Operation of
    0: // Changed line
      AddCompileLine(Index);
    1: // Removed line
      if Index > -1 Then
        RemoveCompileLine(Index);
    2: // Added line
      AddCompileLine(Index);
  End;

  c := FILECHANGED;
  FILECHANGED := True;
  If Not c And (FPWindowID > -1) Then
    SP_Decorate_Window(FPWindowID, 'Program listing - ' + SP_GetProgName(PROGNAME, True), False, False, FocusedWindow = fwEditor);
End;

Procedure SP_InitFPEditor;
Begin

  CompilerLock := TCriticalSection.Create;
  Listing := TStringList.Create;
  Listing.OnChange := ListingChange;

End;

Procedure SP_FPEditorLoop;
Var
  c: Boolean;
  Error: TSP_ErrorCode;
Begin

  c := FILECHANGED; // Preserve here so we don't corrupt it while initialising
  FPShowingSearchResults := False;

  // Startup sequence

  MaxCompileLines := -1;
  FPGutterWidth := FPMinGutterWidth;

  SP_CreateFontMetrics;
  SP_SetFPEditorFont;
  EDITORMENU := CURMENU;

  Error.Line := 0; // Trigger NEW in the error handler
  Error.Statement := 0;
  Error.Code := -1;
  NXTLINE := -1;
  Error.Position := 1;

  WaitForDisplayInit;

  ShowAboutDialog(True);

  FPDebugPanelVisible := False;
  FPResizingDebugPanel := False;
  FPDebugPanelWidth := 285;
  FPWindowMode := 2;

  If Listing.Count = 0 Then Begin
    Listing.FPCLine := 0;
    Listing.FPCPos := 1;
    Listing.FPSelLine := 0;
    Listing.FPSelPos := 1;
    SP_AddLine('', '', '');
  End;

  FILECHANGED := c; // Previous AddLine() will cause a change, we don't want that.

  SP_InitDWMetrics;
  SP_CreateFPWindow;
  SP_CreateDirectWindow;

  FPGutterWidth := 0; // Trigger a re-wrap in MarkAsDirty
  SP_MarkAsDirty(0);
  EDITORREADY := True;

  SwitchFocusedWindow(fwDirect);
  SP_SwitchFocus(FocusedWindow);
  SP_FPCycleEditorWindows(2);

  SetAllToCompile;
  SP_StartCompiler;

  Listing.CommenceUndo;
  Listing.CompleteUndo;

  PROGSTATE := SP_PR_STOP;

  SP_GetFPUserInput;

  {$IFNDEF RTComp}
  DoAutoSave;
  {$ENDIF}

  CompilerLock.Free;
  Listing.Free;
  EditorHost_Destroy;
  DWHost_Destroy;

End;

Procedure SP_AddLine(Const l, s, c: aString);
Var
  nl: Integer;
Begin
  CompilerLock.Enter;
  Listing.Add(l);
  nl := SP_LineHasNumber(Listing.Count -1);
  If (nl > 0) Then
    Listing.Flags[Listing.Count -1].State := spLineDirty
  Else
    Listing.Flags[Listing.Count -1].State := spLineNull;
  CompilerLock.Leave;
End;

Procedure SP_InsertLine(Index: Integer; Const l, s, c: aString; MarkDirty: Boolean = True);
Var
  i: Integer;
Begin
  CompilerLock.Enter;
  Listing.Insert(Index, l);
  i := SP_LineHasNumber(Index);
  If (i > 0) Then
    Listing.Flags[Index].State := spLineDirty
  Else
    Listing.Flags[Index].State := spLineNull;
  CompilerLock.Leave;
End;

Procedure SP_DeleteLine(Index: Integer; MarkDirty: Boolean = True);
Begin
  CompilerLock.Enter;
  Listing.Delete(Index);
  CompilerLock.Leave;
End;

Procedure SP_ClearListing;
Begin
  Listing.Clear;
End;

Function  SP_LineFlags(Index: Integer): pLineFlags;
Begin
  Result := Listing.Flags[Index];
End;

Function SP_SetFPEditorFont: Integer;
Var
  Err: TSP_ErrorCode;
Begin

  SP_SetSystemFont(EDITORFONT, Err);
  EdSc := #25 + aFloatToString(EDFONTSCALEX) + aFloatToString(EDFONTSCALEY);
  EdCSc := #25 + aFloatToString(1) + aFloatToString(1);
  SP_CreateFontMetrics;
  Result := FONTBANKID;

End;

Procedure SP_CreateFontMetrics;
Begin

  FPFw := Trunc(FONTWIDTH * EDFONTSCALEX);
  FPFh := Trunc(FONTHEIGHT * EDFONTSCALEY);
  If SYSTEMSTATE in [SS_EDITOR, SS_DIRECT, SS_NEW, SS_ERROR] Then Begin
    FW := Trunc(FONTWIDTH * EDFONTSCALEX);
    FH := Trunc(FONTHEIGHT * EDFONTSCALEY);
  End Else Begin
    FH := FONTHEIGHT;
    FW := FONTWIDTH;
  End;

End;

Procedure SP_InitDWMetrics;
Begin
  FPEditorDefaultWindow := SCREENBANK;
  FPEditorDRPOSX := DRPOSX;
  FPEditorDRPOSY := DRPOSY;
  FPEditorPRPOSX := PRPOSX;
  FPEditorPRPOSY := PRPOSY;
  FPEditorOVER := COVER;
  FPEditorSaveFPS := FPS;
  FPEditorFRAME_MS := FRAME_MS;
  FPEditorMouseStatus := MOUSEVISIBLE;
  MOUSEVISIBLE := True;

  COVER := 0;
  T_OVER := COVER;

  FPCaptionHeight := FPFh + 2;

  DWWindowWidth  := DISPLAYWIDTH - (BSize * 2);
  DWWindowHeight := FPFh + (BSize * 2) + 1 + FPCaptionHeight;
  DWWindowTop    := DISPLAYHEIGHT - BSize - DWWindowHeight;
  DWWindowLeft   := BSize;
End;

Procedure SP_CreateDirectWindow;
Var
  Idx: LongWord;
  Error: TSP_ErrorCode;
  Win: pSP_Window_Info;
Begin

  DWWindowID := SP_Add_Window(DWWindowLeft, DISPLAYHEIGHT, DWWindowWidth, DWWindowHeight, -1, 8, 0, Error);
  SP_SetDrawingWindow(DWWindowID);
  COVER := 0;
  CINVERSE := 0;
  CITALIC := 0;
  CBOLD := 0;
  CPROP := 0;
  SP_GetWindowDetails(DWWindowID, Win, Error);
  For Idx := 0 To 255 Do Win^.Palette[Idx] := DefaultPalette[Idx];
  Win^.CaptionHeight := FPCaptionHeight;   // lets AlignChildren place component below caption
  fwDirect := DWWindowID;
  SP_SetWindowShadow(DWWindowID, True);
  CreateStatusLabels;

  SP_FillRect(0, 0, DWWindowWidth, DWWindowHeight, paperClr);
  SP_Decorate_Window(DWWindowID, 'Direct Command', False, False, False);

  DWHost_Init(Win^.Component);

  SP_SetDrawingWindow(FPEditorDefaultWindow);

End;

Procedure SP_UpdateBatteryStatus;
Var
  Win: pSP_Window_Info;
  Err: TSP_ErrorCode;
  {$IFNDEF FPC}
  SysPowerStatus: TSystemPowerStatus;
  {$ENDIF}
Begin

  SP_GetWindowDetails(DWWindowID, Win, Err);
  If Not Assigned(Win) Then Exit;

  {$IFDEF PANDORA}
  BATTLEVEL := StrToInt(ReadLinuxFile('/sys/class/power_supply/bq27500-0/capacity'));
  {$ELSE}
    {$IFNDEF FPC}
      // Windows
      GetSystemPowerStatus(SysPowerStatus);
      Case SysPowerStatus.ACLineStatus of
        1: BATTLEVEL := 100;
        0: BATTLEVEL := SysPowerStatus.BatteryLifePercent;
      end;
    {$ELSE}
      // put Darwin here
    {$ENDIF}
  {$ENDIF}

  SP_DrawStripe(Win^.Surface, Win^.Width, FPFw, FPFh, BATTLEVEL, FocusedWindow = DWWindowID);

End;

Procedure SP_Decorate_Window(WindowID: Integer; Title: aString; Clear, SizeGrip, Focused: Boolean);
Var
  Win: pSP_Window_Info;
  Err: TSP_ErrorCode;
  Window, sp, FB, i, tClr: Integer;
  Stroke, Scale: aFloat;
  iFPFh, iFPFw: Integer;
  iEDSC, s: aString;
Begin

  Window := SCREENBANK;

  If SYSTEMSTATE in [SS_EDITOR, SS_DIRECT, SS_NEW, SS_ERROR] Then Begin
    FB := EDITORFONT;
    iFPFW := Trunc(EDFONTWIDTH * EDFONTSCALEX);
    iFPFH := Trunc(EDFONTHEIGHT * EDFONTSCALEY);
    iEdSc := #25 + aFloatToString(EDFONTSCALEX) + aFloatToString(EDFONTSCALEY);
    Scale := EDFONTSCALEX;
  End Else Begin
    FB := FONTBANKID;
    iFPFH := Round(FONTHEIGHT * T_SCALEY);
    iFPFW := Round(FONTWIDTH * T_SCALEX);
    iEdSc := #25 + aFloatToString(T_SCALEX) + aFloatToString(T_SCALEY);
    Scale := T_SCALEX;
  End;
  T_FONT := FB;

  SP_GetWindowDetails(WindowID, Win, Err);
  If Not Assigned(Win) Then Exit;

  SP_SetDrawingWindow(WindowID);

  tClr := 11;
  T_INK := capBack;
  T_OVER := 0;
  T_BOLD := 0;
  T_CLIPX1 := 0;
  T_CLIPX2 := Win^.Width;
  T_CLIPY1 := 0;
  T_CLIPY2 := Win^.Height;
  Win^.Transparent := tClr;

  If Clear Then
    SP_FillRect(0, 0, Win^.Width, Win^.Height, SP_UIWindowBack);
  SP_FillRect(0, 0, Win^.Width, iFPFh +2, capBack);

  Sp := (Win^.Width - ((iFPFw * 4)) - iFPFh *2) - iFPFw;
  s := ''; i := 1;
  While (i <= Length(Title)) And (Round(SP_GetPropTextWidth(T_FONT, s, '') * Scale) < Sp) Do Begin
    s := s + Title[i];
    Inc(i);
  End;

  Stroke := T_STROKE;
  T_STROKE := 1;
  If Focused Then T_INK := 0;
  SP_DrawRectangle(0, 0, Win^.Width -1, Win^.Height -1);
  If Focused Then
    SP_TextOut(FB, iFPFw Div 2, 1, iEdSc + s, capText, capBack, True)
  Else
    SP_TextOut(FB, iFPFw Div 2, 1, iEdSc + s, capInactive, CapBack, True);

  SP_SetPixelClr(0, 0, tClr);
  SP_SetPixelClr(Win^.Width -1, 0, tClr);

  If WindowID = DWWindowID Then
    SP_UpdateBatteryStatus
  else
    SP_DrawStripe(Win^.Surface, Win^.Width, iFPFw, iFPFh, 100, Focused);

  If SizeGrip Then
    SP_TextOut(FB, Win^.Width -(iFPFw + 6), Win^.Height - (iFPFh + 6), EdCSc + #250, gripClr, -1, False);

  SP_SetDirtyRect(Win^.Left, Win^.Top, Win^.Left + Win^.Width -1, Win^.Top + Win^.Height);
  SP_SetDrawingWindow(Window);
  T_STROKE := Stroke;

End;

Procedure SP_DrawStripe(Dst: pByte; Width, StripeWidth, StripeHeight, BatteryLevel: Integer; Focused: Boolean);
Var
  X, Y, X2, i, bw, sw: Integer;
  oPtr: pByte;
Const
  ClrsFocused: Array[0..3] of Byte   = (2, 6, 4, 5);
  ClrsUnFocused: Array[0..3] of Byte = (238, 252, 246, 243); //(231, 245, 238, 241);
Begin

  If Width < 160 Then Exit;

  sw := StripeWidth * 5;
  X := Width - sw - StripeHeight;
  FPStripePos := X;
  oPtr := pByte(NativeUInt(Dst) + (Width * StripeHeight) + X);

  bw := Round((BatteryLevel / 100) * (sw -2));

  For Y := StripeHeight DownTo 1 Do Begin
    For X2 := X to X + (StripeWidth * 4) -1 Do Begin
      i := (X2 - X) Div StripeWidth;
      If ((Y = StripeHeight) or (Y = 1) or (X2 = X) or (X2 = X + SW -1)) or (X2 < bw + X + 1) Then
        If Focused Then
          oPtr^ := ClrsFocused[i] + (8 * Ord(i < 4))
        Else
          oPtr^ := ClrsUnFocused[i];
      inc(oPtr);
    End;
    Dec(oPtr, Width + (StripeWidth * 4) - ({y and }1)); // change "(y and 1)" to "1" for 45 degree stripes
  End;

End;

Procedure SP_SetFPClientMetrics;
Var
  Win: pSP_Window_Info;
  Error: TSP_ErrorCode;
Begin

  SP_GetWindowDetails(FPWindowID, Win, Error);
  FPCaptionHeight := FPFh + 2;

End;

Procedure SP_CreateFPWindow;
Var
  Idx: Integer;
  Error: TSP_ErrorCode;
  Win: pSP_Window_Info;
Begin

  // Create the main editor window - fullscreen (with margin/border)

  FPWindowWidth := DISPLAYWIDTH - (BSize * 2);
  FPWindowHeight := DISPLAYHEIGHT - (BSize * 2) - (DWWindowHeight + BSize);
  FPWindowTop := BSize;
  FPWindowLeft := BSize;

  FPWindowID := SP_Add_Window(FPWindowLeft, -FPWindowHeight, FPWindowWidth, FPWindowHeight, 255, 8, 0, Error);
  SP_GetWindowDetails(FPWindowID, Win, Error);
  Win^.CaptionHeight := FPCaptionHeight;
  SP_SetWindowShadow(FPWindowID, True);
  SP_CreateEditorMenu;
  //SP_CreateEditorTabBar;
  fwEditor := FPWIndowID;

  SP_SetFPClientMetrics;

  SP_SetDrawingWindow(FPWindowID);
  For Idx := 0 To 255 Do Win^.Palette[Idx] := DefaultPalette[Idx];
  COVER := 0;
  CINVERSE := 0;
  CITALIC := 0;
  CBOLD := 0;

  SP_FillRect(0, 0, FPWindowWidth, FPWindowHeight, 7);
  SP_Decorate_Window(FPWindowID, 'Program listing - ' + SP_GetProgName(PROGNAME, True), False, False, False);

  EditorHost_Init(Win^.Component);

  If FPUserOpenedDebugPanel Then
    SP_OpenDebugPanel;

  SetLength(Events, 0);

End;

Function SP_GetWindowFromID(Id: Integer): Integer;
Begin

  If Id = FPWindowID Then
    Result := fwEditor
  Else
    If Id = DWWindowID Then
      Result := fwDirect
    Else
      Result := fwNone;

End;

Procedure SP_SwitchFocus(FocusMode: Integer);
Var
  OldFocus, Ln: Integer;
Begin

  EDITERROR := False;
  EDITRESULT := False;
  OldFocus := FocusedWindow;
  SwitchFocusedWindow(FocusMode);

  If FocusMode = fwDebugPanel Then Begin
    // We're switching from wherever to the Debug panel. So...
    If OldFocus = fwDirect Then
      DWBASICEditor.SetFocus(False)
    Else
      FPBASICEditor.SetFocus(False);
  End Else Begin
    // Defocus the window we're leaving
    If OldFocus = fwDirect Then Begin
      SP_Decorate_Window(DWWindowID, 'Direct command', False, False, False);
      If Assigned(DWBASICEditor) Then DWBASICEditor.SetFocus(False);
    End Else
      If OldFocus = fwEditor Then Begin
        SP_Decorate_Window(FPWindowID, 'Program listing - ' + SP_GetProgName(PROGNAME, True), False, False, False);
        Ln := Listing.FPCLine;
        PROGLINE := SP_GetLineNumberFromIndex(Ln);
        If Assigned(FPBASICEditor) Then
          FPBASICEditor.SetFocus(False);
      End;

    // Focus the new window
    If FocusMode = fwDirect Then Begin
      SP_Decorate_Window(DWWindowID, 'Direct command', False, False, True);
      If Assigned(DWBASICEditor) Then DWBASICEditor.SetFocus(True);
      EditorHost_SwitchMode(False);
    End Else
      If FocusMode = fwEditor Then Begin
        If FPWindowMode = 0 Then Begin
          FPWindowMode := 2;
          SP_FPCycleEditorWindows(2);
        End;
        SP_Decorate_Window(FPWindowID, 'Program listing - ' + SP_GetProgName(PROGNAME, True), False, False, True);
        If Listing.FPCLine >= Listing.Count Then Begin
          Listing.FPCLine := Listing.Count - 1;
          Listing.FPCPos  := 1;
        End;
        If Assigned(FPBASICEditor) Then Begin
          EditorHost_SwitchMode(True);
          FPBASICEditor.SetFocus(True);
        End;
      End Else Begin
        SP_Decorate_Window(DWWindowID, 'Direct command', False, False, False);
        SP_Decorate_Window(FPWindowID, 'Program listing - ' + SP_GetProgName(PROGNAME, True), False, False, False);
        Ln := Listing.FPCLine;
        PROGLINE := SP_GetLineNumberFromIndex(Ln);
        If Assigned(FPBASICEditor) Then Begin
          FPBASICEditor.SetFocus(False);
          EditorHost_SwitchMode(False);
        End;
      End;

    Listing.FPSelLine := Listing.FPCLine;
    Listing.FPSelPos  := Listing.FPCPos;
    UpdateStatusLabel;
  End;

End;

Procedure SP_FPNewProgram;
Var
  Error: TSP_ErrorCode;
  tStr: aString;
Begin
  EditorHost_NewProgram;
  tStr := '';
  SP_ClearListing;
  SP_AddLine('', '', '');
  SP_ClearBreakpoints;
  SP_PreParse(True, True, Error, tStr);
  Listing.FPCLine := 0;
  Listing.FPCPos := 1;
  Listing.FPSelLine := Listing.FPCLine;
  Listing.FPSelPos := Listing.FPCPos;
  FPGutterWidth := FPMinGutterWidth;
  EDITERROR := False;
  EDITRESULT := False;
  Listing.CommenceUndo;
  Listing.CompleteUndo;
  LASTERRORLINE := -1;
  LASTERRORSTATEMENT := -1;
  FILECHANGED := False;
End;

Function SP_GetLineNumberFromIndex(Var Idx: Integer): Integer;
Begin

  // Returns the line number of the line Idx occupies.

  Result := -1;
  While (Idx >= 0) And (SP_LineHasNumber(Idx) = 0) Do Dec(Idx);
  If Idx > -1 Then
    If SP_LineHasNumber(Idx) > 0 Then
      Result := SP_GetFPLineNumber(Idx);

End;

Function SP_FindFPLine(LineNum: Integer): Integer;
Begin

 // Returns the index in the listing of the line with the specified line number.

  Result := 0;
  While Result < Listing.Count Do Begin
    If (SP_GetFPLineNumber(Result) = LineNum) Then
      Exit;
    Inc(Result);
  End;

  // We didn't find it, so find the next-larger line number.

  Result := 0;
  While Result < Listing.Count Do Begin
    If (SP_GetFPLineNumber(Result) >= LineNum) Then
      Exit;
    Inc(Result);
  End;
  Result := -1;

End;

Function  SP_CheckForConflict(LineIndex: Integer): Boolean;
Var
  Idx, Line: Integer;
Begin

  // Counts instances of a given line number. If more than one, then a conflict.

  Idx := 0;
  Result := False;
  Line := SP_GetLineNumberFromIndex(LineIndex);
  While (Idx < Listing.Count) And (Idx <> LineIndex) Do Begin
    If SP_LineHasNumber(Idx) > 0 Then
      If SP_GetLineNumberFromText(Listing[Idx]) = Line Then Begin
        Result := True;
        Break;
      End;
    Inc(Idx);
  End;

End;

Function  SP_GetLineIndex(LineNum: Integer): Integer;
Begin

  // Result holds the index of the line desired, or the index of the line after it if it doesn't exist.
  // Result will be out of bounds is not existing at all.

  Result := 0;
  While (Result < Listing.Count) And ((SP_GetLineNumberFromText(Listing[Result]) < LineNum)) Do
    Inc(Result);

End;

Function SP_GetExactLineIndex(LineNum: Integer): Integer;
Begin

  Result := 0;
  While (Result < Listing.Count) And ((SP_GetLineNumberFromText(Listing[Result]) < LineNum)) Do
    Inc(Result);
  If Result < Listing.Count Then
    If (SP_GetLineNumberFromText(Listing[Result]) <> LineNum)  Then
      Result := Listing.Count;

End;

Function SP_GetLineNumberFromText(Const Txt: aString): Integer;
Var
  i: Integer;
Begin

  i := 1;
  Result := 0;
  While (i <= Length(Txt)) And (Txt[i] <= ' ') Do Inc(i);
  While (i <= Length(Txt)) And (Txt[i] in ['0'..'9']) Do Begin
    Result := (Result * 10) + Ord(Txt[i]) - 48;
    If i > 6 Then Begin
      Result := 0;
      Exit;
    End Else
      Inc(i);
  End;

End;

Function SP_GetFPLineNumber(Idx: Integer): Integer;
Var
  s: aString;
Begin

  s := Listing[Idx];
  Result := SP_GetLineNumberFromText(s);

End;

Function SP_GetLineTextFromNumber(Num: Integer): aString;
Var
  Idx: Integer;
Begin

  // Grabs the text of a line including all statements.

  Result := '';
  Idx := SP_FindFPLine(Num);
  If Idx > -1 Then Begin
    Result := Listing[Idx];
    Inc(Idx);
    While (Idx < Listing.Count) And ((SP_LineHasNumber(Idx) = 0)) Do Begin
      Result := Result + Listing[Idx];
      Inc(Idx);
    End;
  End;

End;

Procedure SP_FPWaitForUserEvent(Var Key: pSP_KeyInfo; Var LocalFlashState: Integer);
Begin

  Repeat

    ProcessNextControlMsg;
    DoTimerEvents;

    If LocalFlashState <> FLASHSTATE Then Begin
      SP_UpdateBatteryStatus;
      LocalFlashState := FLASHSTATE;
    End;

    {$IFNDEF RTComp}
    If (AutoFrameCount mod AUTOSAVETIME = 0) and (PROGSTATE <> SP_PR_RUN) Then
       DoAutoSave;
    {$ENDIF}

    If QUITMSG Then Exit;

    SP_CheckEvents;
    If NeedGutterRefresh Then Begin
      NeedGutterRefresh := False;
      SP_WaitForSync;
    End;

    If SP_KeyEventWaiting Then SP_UnBufferKey;
    Key := SP_GetNextKey(FRAMES);
    If Not Assigned(Key) Then
      SP_WaitForSync;

    If K_UPFLAG Then K_UPFLAG := False;

  Until M_DOWNFLAG or M_UPFLAG or M_MOVEFLAG or M_WHEELUPFLAG or M_WHEELDNFLAG or Assigned(Key) or DWCommandPending;

End;

Procedure SP_GetFPUserInput;
Var
  Finished: Boolean;
  KeyInfo: pSP_KeyInfo;
  LocalFlashState: Integer;
Begin

  KeyInfo := nil;
  SYSTEMSTATE := SS_EDITOR;
  Finished := False;
  LocalFlashState := FLASHSTATE;

  // Restore component focus whenever we re-enter the editor loop.
  // After a RUN/STEP cycle the focus lands on fwDirect; if that was triggered
  // from the editor pane we want it back.
  If (FocusedWindow = fwEditor) And Assigned(FPBASICEditor) Then
    FPBASICEditor.SetFocus(True)
  Else If (FocusedWindow = fwDirect) And Assigned(DWBASICEditor) Then
    DWBASICEditor.SetFocus(True);

  While Not (Finished or QUITMSG) Do Begin

    SP_FPWaitForUserEvent(KeyInfo, LocalFlashState);

    // DW command submitted by VCL thread via OnExecute.
    // EDITLINE was pre-populated by TDWEditorBridge.Execute before the flag
    // was set, so we can call SP_FPExecuteEditLine safely here on the
    // interpreter thread.
    If DWCommandPending Then Begin
      DWCommandPending := False;
      If StripLeadingSpaces(EDITLINE) = '' Then Begin
        // Empty Enter: cycle editor windows (same as old SP_DWPerformEdit).
        If FPWindowMode = 0 Then FPWindowMode := 3 Else FPWindowMode := 2;
        SP_FPCycleEditorWindows(-1);
      End Else Begin
        If Assigned(DWBASICEditor) Then
          DWBASICEditor.ClearText;
        SP_FPExecuteEditLine(EDITLINE);
      End;
    End;

    If Assigned(KeyInfo) Then Begin
      If (KeyInfo^.WIndowID = fwEditor) or (KeyInfo^.WIndowID = fwDebugPanel) Then
        SP_FPEditorPerformEdit(KeyInfo)
      Else
        If KeyInfo^.WIndowID = fwDirect Then Begin
          // Sync EDITLINE from the component so that SP_DWPerformEdit's
          // save/restore of EDITLINE (used by F4/F7/F8/F9) reflects the
          // actual current content.
          If Assigned(DWBASICEditor) Then
            EDITLINE := DWBASICEditor.GetText;
          SP_DWPerformEdit(KeyInfo);
        End;
      KeyInfo := nil;
    End;

    if QUITMSG then Exit;

    If M_DOWNFLAG Then SP_FPEditorHandleMouseDown(MOUSEX, MOUSEY);
    If M_UPFLAG Then SP_FPEditorHandleMouseUp(MOUSEX, MOUSEY);
    If M_MOVEFLAG Then SP_FPEditorHandleMouseMove(MOUSEX, MOUSEY);
    If M_WHEELUPFLAG Then SP_FPEditorHandleMouseWheel(True, MOUSEX, MOUSEY);
    If M_WHEELDNFLAG Then SP_FPEditorHandleMouseWheel(False, MOUSEX, MOUSEY);

    M_DOWNFLAG := False;
    M_UPFLAG := False;
    M_MOVEFLAG := False;
    M_WHEELUPFLAG := False;
    M_WHEELDNFLAG := False;

  End;

End;

Procedure SP_FPEditorHandleMouseUp(X, Y: Integer);
Var
  Idx: Integer;
Begin

  M_DOWNFLAG := False;
  M_UPFLAG := False;

  Idx := 0;
  While Idx < Length(Events) Do
    If Events[Idx].evType in [evtMouseDown, evtMouseUp] Then
      SP_DeleteEvent(Events[Idx].ID)
    Else
      Inc(Idx);

End;

Procedure SP_FPEditorHandleMouseDown(X, Y: Integer);
Var
  Idx: Integer;
  Window: pSP_Window_Info;
  Focus: Integer;
Begin

  Window := nil;
  M_DOWNFLAG := False;

  // Which window is the mouse pointer in? Windows are stored in back to front order, so work backwards.

  Idx := NUMBANKS -1;
  While Idx >= 0 Do Begin
    If SP_BankList[Idx]^.DataType = SP_WINDOW_BANK Then Begin
      Window := @SP_BANKLIST[Idx]^.Info[0];
      With Window^ Do
        If PtInRect(Rect(Left, Top, Left + Width, Top + Height), Point(X, Y)) And Visible Then
          Break;
    End;
    Dec(Idx);
  End;

  If Idx >= 0 Then Begin

    If Idx = FPWindowID Then
      SP_SwitchFocus(fwEditor)
    Else
      If Idx = DWWindowID Then
        SP_SwitchFocus(fwDirect);

    Focus := SP_GetWindowFromID(Window^.ID);
    If (Focus >= 0) And (Focus <> FocusedWindow) Then
      SP_SwitchFocus(Focus);

  End;

End;

Procedure SP_FPEditorHandleMouseMove(X, Y: Integer);
Begin
  M_MOVEFLAG := False;
  If MOUSEBTN = 0 Then // Check for tooltip hoverings
    CheckForTip(x, y);
End;

Procedure SP_FPEditorHandleMouseWheel(WheelUp: Boolean; X, Y: Integer);
Begin
  CloseTipWindow;
End;

Procedure SP_AddEvent(Var Event: SP_EditorEvent);
Var
  Cnt, NewID, Idx: Integer;
  Done, Found: Boolean;
Begin

  Case Event.evType of
    evtMouseDown, evtMouseUp, evtMouseMove:
      Begin
        Idx := 0;
        While Idx < Length(Events) Do
          If Events[Idx].evType = Event.evType Then
            SP_DeleteEvent(Events[Idx].ID)
          Else
            Inc(Idx);
      End;
  End;

  Cnt := Length(Events);
  SetLength(Events, Cnt +1);
  CopyMem(@Events[Cnt].ID, @Event.ID, SizeOf(SP_EditorEvent));
  NewID := 0;
  Done := Length(SP_BankList) = 0;
  While Not Done Do Begin
    Found := False;
    For Idx := 0 To Length(Events) -1 Do Begin
      If Events[Idx].ID = NewID Then Begin
        Inc(NewID);
        Found := True;
        Break;
      End;
    End;
    If Not Found Then
      Done := True;
  End;
  Events[Cnt].ID := NewID;

End;

Function  SP_FindEvent(ID: Integer): Integer;
Begin
  Result := Length(Events) -1;
  While Result >= 0 Do
    If Events[Result].ID = ID Then Exit Else Dec(Result);
End;

Procedure SP_DeleteEvent(ID: Integer);
Begin
  ID := SP_FindEvent(ID);
  While ID < Length(Events) -1 Do Begin
    CopyMem(@Events[ID].ID, @Events[ID+1].ID, SizeOf(SP_EditorEvent));
    Inc(ID);
  End;
  If ID >= 0 Then
    SetLength(Events, ID);
End;

Procedure SP_DeleteEventByIndex(Idx: Integer);
Begin
  If Idx >= 0 Then Begin
    While Idx < Length(Events) -1 Do Begin
      CopyMem(@Events[Idx].ID, @Events[Idx+1].ID, SizeOf(SP_EditorEvent));
      Inc(Idx);
    End;
    SetLength(Events, Length(Events) -1);
  End;
End;

Procedure SP_DeleteAllEvents(eventType: Integer);
Var
  Idx: Integer;
Begin
  Idx := 0;
  While Idx < Length(Events) Do Begin
    If Events[Idx].evType = eventType Then
      SP_DeleteEventByIndex(Idx)
    Else
      Inc(Idx);
  End;
End;

Procedure SP_LaunchEvent(Event: pSP_EditorEvent);
Begin

  SP_EditorEvent(Event^).OnLaunch(Event);

End;

Procedure SP_CheckEvents;
Var
  Idx: Integer;
  Event: SP_EditorEvent;
Begin

  Idx := 0;
  If Length(Events) > 0 Then Begin
    While Idx < Length(Events) Do Begin
      Event := Events[Idx];
      With Event Do Begin
        If OneShot Then
          SP_DeleteEventByIndex(Idx)
        Else
          Inc(Idx);
        Case evType of
          evtRefreshLine: ;
        Else
          If FRAMES >= TargetFrame Then
            If Assigned(Event.OnLaunch) Then
              SP_LaunchEvent(@Event);
        End;
      End;
    End;
  End;

End;

Function  SP_PtInSelection(Sel: SP_SelectionInfo; p: TPoint): Boolean;
Begin
  If Sel.MultiLine Then Begin
    If p.y = Sel.StartL Then
      Result := p.X >= Sel.StartP
    Else
      If p.y = Sel.EndL Then
        Result := p.x <= Sel.EndP
      Else
        Result := (p.y > Sel.StartL) and (p.Y < Sel.EndL);
  End Else
    Result := (p.y = Sel.StartL) and (p.x >= Sel.StartP) and (p.x <= Sel.EndP);
End;

Function SP_LineNumberSize(Idx: Integer): Integer;
Var
  CodeLine: aString;
Begin

  Result := 0;
  If Idx < Listing.Count Then Begin
    CodeLine := Listing[Idx];
    If CodeLine <> '' Then Begin
        Result := 1;
        While (Result <= Length(CodeLine)) And (CodeLine[Result] in ['0'..'9']) Do
          Inc(Result);
    End;
  End;

End;

Function SP_LineHasNumber_Fast(Idx: Integer): Boolean;
Begin
  Result := False;
  If (Idx < 0) or (Idx >= Listing.Count) Then Exit;
  Result := (Listing[Idx] <> '') and (Listing[Idx][1] in ['0'..'9']);
End;

Function SP_LineHasNumber(Idx: Integer): Integer;
Var
  CodeLine: aString;
Begin

  // Returns the size in characters of a possible line number at idx

  Result := 0;
  If (Idx >= 0) And (Idx < Listing.Count) Then Begin
    CodeLine := Listing[Idx];
    If CodeLine <> '' Then Begin
      Result := 1;
              While (Result <= Length(CodeLine)) And (CodeLine[Result] in ['0'..'9']) Do
          Inc(Result);
      If Result <= Length(CodeLine) Then Dec(Result);
    End;
  End;

End;

Procedure SP_FPCycleEditorWindows(HideMode: Integer);
Var
  t, t3: LongWord;
  DTop, LTop, LHeight, DMove, LMove, LSize, t2: aFloat;
  EditorTargetY, EditorTargetHeight, CmdTargetY, SwitchTo: Integer;
  SizeEditor, MoveEditor, MoveCmd: Boolean;
  ListWin, ComWin: pSP_Window_Info;
  Error: TSP_ErrorCode;
Begin

  // Switch between Editor, Editor+Cmd, Cmd and none

  CmdTargetY := 0;
  EditorTargetHeight := FPWindowHeight;
  EditorTargetY := FPWindowTop;
  SizeEditor := False;
  MoveEditor := False;
  MoveCmd := False;

  SwitchTo := FocusedWindow;

  If HideMode = -1 Then Begin

    Case FPWindowMode of
      0: // Command window only - bring in the editor, full size
        Begin
          // Resize the Editor to fill the screen and remove the command window
          SwitchTo := fwEditor;
          EditorTargetHeight := DISPLAYHEIGHT - (BSize * 2) +1;
          SizeEditor := True;
          MoveEditor := True;
          EditorTargetY := BSize -1;
          CmdTargetY := DISPLAYHEIGHT;
          MoveCmd := True;
          FPWindowMode := 1;
        End;
      1: // Editor only - bring in the command window and resize the Editor
        Begin
          SwitchTo := fwDirect;
          EditorTargetHeight := DISPLAYHEIGHT - (BSize * 3) - DWWindowHeight;
          CmdTargetY := DISPLAYHEIGHT - BSize - DWWindowHeight;
          MoveCmd := True;
          SizeEditor := True;
          FPWindowMode := 2;
        End;
      2: // Editor + Cmd - Move the editor off-screen
        Begin
          SwitchTo := fwDirect;
          EditorTargetY := - (FPWindowHeight + dsOffsetY + dsBlurRadius);
          MoveEditor := True;
          FPWindowMode := 0;
        End;
      3: // Command window only - bring in Editor.
        Begin
          SwitchTo := fwDirect;
          EditorTargetHeight := DISPLAYHEIGHT - (BSize * 3) - DWWindowHeight +1;
          EditorTargetY := BSize -1;
          MoveEditor := True;
          SizeEditor := True;
          FPWindowMode := 2;
        End;
    End;

  End Else Begin

    // A hide/show operation

    If HideMode = 1 Then Begin

      EditorTargetY := -FPWindowHeight;
      CmdTargetY := DISPLAYHEIGHT;
      MoveCmd := True;
      MoveEditor := True;

    End Else Begin

      If FPWindowMode in [1, 2] Then Begin
        If FPWindowMode = 1 Then Begin
          SizeEditor := True;
          EditorTargetHeight := DISPLAYHEIGHT - (BSize * 2) +1;
        End;
        EditorTargetY := FPWindowTop;
        MoveEditor := True;
      End;

      If FPWIndowMode in [0, 2] Then Begin
        CmdTargetY := DWWindowTop;
        MoveCmd := True;
      End;

    End;

  End;

  // Now do the animation.

  SP_GetWindowDetails(FPWindowID, ListWin, Error);
  SP_GetWindowDetails(DWWindowID, ComWin, Error);

  t := Round(CB_GETTICKS);
  DMove := CmdTargetY - ComWin^.Top;
  LMove := EditorTargetY - ListWin.Top;
  LSize := EditorTargetHeight - ListWin^.Height;
  LTop := ListWin^.Top;
  DTop := ComWin^.Top;
  LHeight := ListWin^.Height;

  Repeat
    t3 := Round(CB_GETTICKS);
    t2 := (t3 - t)/ANIMSPEED;
    DisplaySection.Enter;
    If MoveEditor Then Begin
      ListWin^.Top := Trunc(LTop + (LMove * t2));
      If ((LMove > 0) And (ListWin^.Top > EditorTargetY)) or ((LMove < 0) And (ListWin^.Top < EditorTargetY)) Then
        ListWin^.Top := EditorTargetY;
    End;
    If MoveCmd Then Begin
      ComWin^.Top := Trunc(DTop + (DMove * t2));
      If ((DMove > 0) And (ComWin^.Top > CmdTargetY)) or ((DMove < 0) And (ComWin^.Top < CmdTargetY)) Then
        ComWin^.Top := CmdTargetY;
    End;
    If SizeEditor Then Begin
      ListWin^.Height := Trunc(LHeight + (LSize * t2));
      If ((LSize > 0) And (ListWin^.Height > EditorTargetHeight)) or ((LSize < 0) And (ListWin^.Height < EditorTargetHeight)) Then
        ListWin^.Height := EditorTargetHeight;
    End;
    DisplaySection.Leave;
    If SizeEditor Then
      SP_FPResizeWindow(ListWin^.Height);
    SP_InvalidateWholeDisplay;
    SP_WaitForSync;
  Until (t3 - t) >= LongWord(ANIMSPEED);

  SP_FPResizeWindow(ListWin^.Height);
  SP_SwitchFocus(SwitchTo);
  SP_InvalidateWholeDisplay;

End;

Procedure SP_FPEditorPerformEdit(Key: pSP_KeyInfo);
Var
  s, s2: aString;
  Error: TSP_ErrorCode;
  Params: TNarratorParams;

  Procedure PlayClick;
  Begin
    If LASTKEYFLAG And KF_NOCLICK = 0 Then SP_PlaySystem(CLICKCHAN, CLICKBANK);
  End;

Begin

  If Not (Key.KeyCode in [K_F3, K_ESCAPE]) Then FPBASICEditor.ClearSearchResults;

  If (Key.KeyChar = #0) And (Key.KeyCode <> 0) Then Begin

    Case Key.KeyCode of

      K_F1..K_F10:
        Begin
          Case Key.KeyCode of

            K_F1:
              SP_ShowHelpForWord(EditorHost_GetWordAtCursor);

K_F2:
  If KEYSTATE[K_SHIFT] = 1 Then Begin
    SP_NarratorDefaultParams(Params);
    SP_Say('HH EH LL OW PA2 WW ER LL DD', Params, False);
  End;

            K_F3:
              FindNext(True);

            K_F4: // RUN to current line.  Shift = CONTINUE.
              If SP_CheckProgram Then Begin
                SP_ToggleBreakPoint(True);
                s := EDITLINE;
                If KEYSTATE[K_SHIFT] = 0 Then EDITLINE := 'RUN'
                Else                          EDITLINE := 'CONTINUE';
                Listing.CompleteUndo;
                SP_FPExecuteEditLine(EDITLINE);
                If QUITMSG Then Exit;
                EDITLINE := s;
                SP_SwitchFocus(fwEditor);
                SP_ClearAllKeys;
              End Else Begin
                SP_PlaySystem(ERRORCHAN, ERRSNDBANK);
                // set fp editor cursor to error colour
              End;

            K_F5: // Toggle breakpoint at cursor
              EditorHost_ToggleBreakpoint;

            K_F7:
              Begin
                If SP_CheckProgram Then Begin
                  SP_SingleStep;
                  SP_SwitchFocus(fwEditor);  // ? ADD THIS
                End Else Begin
                  SP_PlaySystem(ERRORCHAN, ERRSNDBANK);
                // set fp editor cursor to error colour
                End;
                Exit;
              End;

            K_F8: // Step over
              If SP_CheckProgram Then Begin
                If SP_StepOver Then Begin
                  s := EDITLINE;
                  EDITLINE := 'CONTINUE';
                  Listing.CompleteUndo;
                  SP_FPExecuteEditLine(EDITLINE);
                  If QUITMSG Then Exit;
                  If EDITLINE = 'CONTINUE' Then EDITLINE := s;
                  SCREENLOCK := False;
                  SP_SwitchFocus(fwEditor);
                  SP_ClearAllKeys;
                End;
              End Else Begin
                SP_PlaySystem(ERRORCHAN, ERRSNDBANK);
                // set fp editor cursor to error colour
              End;

            K_F9: // RUN (Shift = CONTINUE)
              Begin
                If SP_CheckProgram Then Begin
                  s := EDITLINE;
                  If KEYSTATE[K_SHIFT] = 0 Then EDITLINE := 'RUN'
                  Else                          EDITLINE := 'CONTINUE';
                  s2 := EDITLINE;
                  Listing.CompleteUndo;
                  SP_FPExecuteEditLine(EDITLINE);
                  If QUITMSG Then Exit;
                  If EDITLINE = s2 Then EDITLINE := s;
                  SP_SwitchFocus(fwEditor);
                  SP_ClearAllKeys;
                End Else Begin
                  SP_PlaySystem(ERRORCHAN, ERRSNDBANK);
                  EDITERROR := True;
                  // set fp editor cursor to error colour
                End;
                Exit;
              End;

            K_F10: // GO TO current line (Shift = RUN from line)
              Begin
                s := IntToString(EditorHost_GetCursorBASICLine);
                If (s <> '-1') And SP_CheckProgram Then Begin
                  If KEYSTATE[K_SHIFT] = 0 Then EDITLINE := 'GO TO ' + s
                  Else                          EDITLINE := 'RUN '   + s;
                  s2 := EDITLINE;
                  Listing.CompleteUndo;
                  SP_FPExecuteEditLine(EDITLINE);
                  If QUITMSG Then Exit;
                  If EDITLINE = s2 Then EDITLINE := '';
                  SP_SwitchFocus(fwEditor);
                End Else Begin
                  SP_PlaySystem(ERRORCHAN, ERRSNDBANK);
                // set fp editor cursor to error colour
                End;
                Exit;
              End;

          End; // inner Case
          PlayClick;
        End; // K_F1..K_F10

      K_RETURN:
        Begin
          // Plain Enter is handled by the component.
          // Ctrl+Return: cycle editor windows.
          // Ctrl+Shift+Return: hide windows temporarily.
          If KEYSTATE[K_CONTROL] = 1 Then Begin
            PlayClick;
            If KEYSTATE[K_SHIFT] = 0 Then
              SP_FPCycleEditorWindows(-1)
            Else Begin
              SP_FPCycleEditorWindows(1);
              SYSTEMSTATE := SS_IDLE;
              SP_SwitchFocus(fwNone);      // ? remove focus from component
              SP_ClearAllKeys;
              Repeat
                Key := SP_GetNextKey(FRAMES);
                CB_YIELD(10);
              Until (Assigned(Key) And Not (Key.KeyCode In [K_SHIFT, K_CONTROL, K_ALT, K_ALTGR])) Or M_DOWNFLAG;
              M_DOWNFLAG := False;
              SYSTEMSTATE := SS_EDITOR;
              SP_ClearAllKeys;
              SP_FPCycleEditorWindows(2);
              SP_SwitchFocus(fwEditor);    // ? restore focus
            End;
          End;
        End;

      K_ESCAPE:
        Begin
          SP_SwitchFocus(fwDirect);
          PlayClick;
        End;

    End; // outer Case Key.KeyCode

  End Else Begin

    // Ctrl+char editor-level actions.  The component handles all printable
    // characters; we only intercept Ctrl+combos that open dialogs or operate
    // on the program as a whole.
    If KEYSTATE[K_CONTROL] = 1 Then
      Case Lower(Key.KeyChar)[1] of
        '9': Begin GFXLOCK := 1 - GFXLOCK; End;
        'r': StartFindOp(False);
        'f': If KEYSTATE[K_SHIFT] = 1 Then
              StartFindOp(True)          // Ctrl+Shift+F: advanced Find dialog
             Else
              If Assigned(FPBASICEditor) Then
                FPBASICEditor.ShowSearchBar; // Ctrl+F: editor inline search bar
        'g': If KEYSTATE[K_SHIFT] = 0 Then
              StartGotoOp
             Else
              SP_FPGotoLine(LASTERRORLINE, LASTERRORSTATEMENT);
        'o': Begin
               Listing.CommenceUndo;
               SP_ReOrderListing(Error);
               Listing.CompleteUndo;
             End;
        'l': StartFileOp(SP_KW_LOAD, '');
        'm': StartFileOp(SP_KW_MERGE, '');
        'n': StartBPEditOp(-1, nil);
        's': StartFileOp(SP_KW_SAVE, PROGNAME);
        'w': StartWatchOp(-1);
        'b': If FPDebugPanelVisible Then SP_User_CloseDebugPanel Else SP_User_OpenDebugPanel;
      End;

  End;

  EDITERROR := False;
  EDITRESULT := False;

  // Keep Listing.FPCLine/Pos in sync so SP_ToggleBreakpoint, the debug panel
  // and UpdateStatusLabel see consistent coordinates.
  If Assigned(FPBASICEditor) Then Begin
    Listing.FPCLine := FPBASICEditor.CursorLine;
    Listing.FPCPos  := FPBASICEditor.CursorCol;
  End;

  UpdateStatusLabel;

End;

Function SP_EditorLineCount: Integer;
Begin
  Result := EditorHost_GetLineCount;
End;

Function SP_EditorLine(Idx: Integer): aString;
Begin
  Result := EditorHost_GetLine(Idx);
End;

Procedure SP_LoadIntoEditor(Const NewProg: Array Of aString);
Begin
  EditorHost_SetProgram(NewProg);
End;

Procedure SP_LoadIntoEditorFromText(Const RawText: aString;
                                    Out AutoStart: Integer;
                                    Out ProgName:  aString;
                                    Out Changed:   Boolean);
Begin
  EditorHost_LoadFromText(RawText, AutoStart, ProgName, Changed);
End;

Procedure SP_FPResizeWindow(NewH: Integer);
Var
  WindowID: Integer;
  Err: TSP_ErrorCode;
Begin

  {$IFDEF RefreshThread}
  CB_PauseDisplay;
  {$ENDIF}
  DisplaySection.Enter;

  NewH := Max(NewH, 0);

  WindowID := SCREENBANK;
  SP_SetDrawingWindow(FPWindowID);

  FPWindowWidth := DISPLAYWIDTH - BSize * 2;
  FPWindowHeight := NewH;

  FPCaptionHeight := FPFh + 2;
  SP_SetFPClientMetrics;

  SP_ResizeWindow(FPWindowID, FPWindowWidth, FPWindowHeight, 8, False, False, Err);
  SP_Decorate_Window(FPWindowID, 'Program listing - ' + SP_GetProgName(PROGNAME, True), False, False, FocusedWindow = fwEditor);

  SP_SetDrawingWindow(WindowID);
  EditorHost_Resize;

  DisplaySection.Leave;
  {$IFDEF RefreshThread}
  CB_ResumeDisplay;
  {$ENDIF}

End;

Procedure SP_DWResizeWindow(NewW, NewH: Integer);
Var
  WindowID: Integer;
  Win: pSP_Window_Info;
  Err: TSP_ErrorCode;
Begin

  WindowID := SCREENBANK;
  SP_SetDrawingWindow(DWWindowID);

  If SP_WindowVisible(FPWindowID, Err) And (FPWindowMode in [1, 2]) Then
    SP_FPResizeWindow(DISPLAYHEIGHT - BSize * 2 - (NewH + BSize));

  DWWindowTop := DISPLAYHEIGHT - NewH - BSize;
  SP_MoveWindow(DWWindowID, DWWindowLeft, DWWindowTop, Err);
  SP_ResizeWindow(DWWindowID, NewW, NewH, -1, False, False, Err);
  SP_GetWindowDetails(DWWindowID, Win, Err);

  DWWindowLeft := Win^.Left;
  DWWindowTop := Win^.Top;
  DWWindowWidth := Win^.Width;
  DWWindowHeight := Win^.Height;

  SP_Decorate_Window(DWWindowID, 'Direct command', False, False, True);

  // Let the component reposition itself to the resized client rect.
  DWHost_Resize;
  SP_SetDrawingWindow(WindowID);

End;

Procedure SP_FPBringToEditor(LineNum, Statement: Integer; Var Error: TSP_ErrorCode; DoEdit: Boolean = True);
Var
  ref: aString;
  cPos: Integer;
  foundLine: Integer;
Begin
  If (LineNum = 0) And (Statement = 0) Then Begin
    If Assigned(DWBASICEditor) Then ref := DWBASICEditor.GetText
    Else ref := EDITLINE;
    If ref = '' Then ref := IntToString(PROGLINE);
    If Not FPBASICEditor.NavigateTo(ref, foundLine) Then Begin
      EDITERROR := True;
      SP_PlaySystem(ERRORCHAN, ERRSNDBANK);
      Exit;
    End;
  End Else Begin
    foundLine := LineNum;
    FPBASICEditor.GotoBASICLine(LineNum, Statement);
  End;

  PROGLINE := foundLine;
  Listing.FPCLine   := FPBASICEditor.CursorLine;
  Listing.FPCPos    := FPBASICEditor.CursorCol;
  Listing.FPSelLine := Listing.FPCLine;
  Listing.FPSelPos  := Listing.FPCPos;

  If DoEdit Then Begin
    cPos := 1;
    EDITLINE := SP_DeTokenise(SP_TokeniseLine(SP_GetLineTextFromNumber(PROGLINE), False, True), cPos, False, False);
    If Assigned(DWBASICEditor) Then Begin
      DWBASICEditor.SetText(EDITLINE);
      DWBASICEditor.GotoLine(0, Length(EDITLINE) + 1);
      DWBASICEditor.SetFocus(True);
      DWBASICEditor.Paint;
    End;
  End;
End;

Procedure SP_DWPerformEdit(Key: pSP_KeyInfo);
Var
  s, s2: aString;
  c, Idx: Integer;
  Error: TSP_ErrorCode;

  Procedure PlayClick;
  Begin
    If LASTKEYFLAG And KF_NOCLICK = 0 Then SP_PlaySystem(CLICKCHAN, CLICKBANK);
  End;

Begin

  // All character editing, cursor movement, selection, undo/redo, clipboard,
  // history (Up/Down), Enter, and Escape are handled by DWBASICEditor.
  // Only keys that the component intentionally passes through reach here:
  //   F3..F10, Ctrl+Enter, Tab, Ctrl+Up, Ctrl+Down.

  Error.Code := SP_ERR_OK;

  If (Key^.KeyChar = #0) And (Key^.KeyCode <> 0) Then Begin

    Case Key^.KeyCode of

      K_F1..K_F10:
        Begin
          Case Key^.KeyCode of

            K_F1:
              SP_ShowHelpForWord(EditorHost_GetWordAtCursor);

            K_F3:
              // Repeat find/replace
              FindNext(True);

            K_F4:
              // RUN to current line/statement.  Shift = CONTINUE.
              If SP_CheckProgram Then Begin
                SP_ToggleBreakPoint(True);
                Listing.CompleteUndo;
                s := EDITLINE;
                If KEYSTATE[K_SHIFT] = 0 Then EDITLINE := 'RUN'
                Else                          EDITLINE := 'CONTINUE';
                s2 := EDITLINE;
                SP_FPExecuteEditLine(EDITLINE);
                If QUITMSG Then Exit;
                If EDITLINE = s2 Then EDITLINE := s;
                SP_SwitchFocus(fwDirect);
              End Else
                SP_ShowError(SP_ERR_SYNTAX_ERROR, Listing.FPCLine, Listing.FPCPos);

            K_F5:
              // Toggle breakpoint at PROGLINE:1
              SP_ToggleBreakPoint(False);

            K_F7:
              // Single step
              Begin
                If SP_CheckProgram Then
                  SP_SingleStep
                Else
                  SP_ShowError(SP_ERR_SYNTAX_ERROR, Listing.FPCLine, Listing.FPCPos);
                Exit;
              End;

            K_F8:
              // Step Over
              Begin
                If SP_CheckProgram Then Begin
                  If SP_StepOver Then Begin
                    Listing.CompleteUndo;
                    s := EDITLINE;
                    EDITLINE := 'CONTINUE';
                    SP_FPExecuteEditLine(EDITLINE);
                    If QUITMSG Then Exit;
                    If EDITLINE = 'CONTINUE' Then EDITLINE := s;
                    SCREENLOCK := False;
                    SP_SwitchFocus(fwDirect);
                    SP_ClearAllKeys;
                  End Else
                    SP_ShowError(SP_ERR_STATEMENT_LOST, Listing.FPCLine, Listing.FPCPos);
                End Else
                  SP_ShowError(SP_ERR_SYNTAX_ERROR, Listing.FPCLine, Listing.FPCPos);
                Exit;
              End;

            K_F9:
              // RUN.  Shift = CONTINUE.
              If SP_CheckProgram Then Begin
                Listing.CompleteUndo;
                s := EDITLINE;
                If KEYSTATE[K_SHIFT] = 0 Then EDITLINE := 'RUN'
                Else                          EDITLINE := 'CONTINUE';
                s2 := EDITLINE;
                SP_FPExecuteEditLine(EDITLINE);
                SP_ClearAllNonAsciiKeys;
                If QUITMSG Then Exit;
                If EDITLINE = s2 Then EDITLINE := s;
                SP_SwitchFocus(fwDirect);
              End Else Begin
                SP_PlaySystem(ERRORCHAN, ERRSNDBANK);
                EDITERROR := True;
                Exit;
              End;

            K_F10:
              // RUN from current PROGLINE.  Shift = GO TO.
              If SP_CheckProgram Then Begin
                Listing.CompleteUndo;
                c := CURSORPOS;
                If PROGLINE > 0 Then Begin
                  s := EDITLINE;
                  If KEYSTATE[K_SHIFT] = 0 Then EDITLINE := 'RUN '   + IntToString(PROGLINE)
                  Else                          EDITLINE := 'GO TO ' + IntToString(PROGLINE);
                  s2 := EDITLINE;
                  SP_FPExecuteEditLine(EDITLINE);
                  If QUITMSG Then Exit;
                  If EDITLINE = s2 Then EDITLINE := s;
                  CURSORPOS := c;
                  SP_SwitchFocus(fwDirect);
                End Else
                  SP_ShowError(SP_ERR_SYNTAX_ERROR, Listing.FPCLine, Listing.FPCPos);
              End;

          End; // inner Case
          PlayClick;
        End; // K_F1..K_F10

      K_RETURN:
        Begin
          // Plain K_RETURN without Ctrl is handled by the component (DWCommandPending).
          // Only Ctrl+Return reaches here.
          PlayClick;
          If KEYSTATE[K_CONTROL] = 1 Then Begin
            If KEYSTATE[K_SHIFT] = 0 Then
              SP_FPCycleEditorWindows(-1)
            Else Begin
              SP_FPCycleEditorWindows(1);
              SYSTEMSTATE := SS_IDLE;
              SP_SwitchFocus(fwNone);
              SP_ClearAllKeys;
              Repeat
                Key := SP_GetNextKey(FRAMES);
                CB_YIELD(10);
              Until (Assigned(Key) And Not (Key.KeyCode In [K_SHIFT, K_CONTROL, K_ALT, K_ALTGR])) Or M_DOWNFLAG;
              M_DOWNFLAG := False;
              SYSTEMSTATE := SS_EDITOR;
              SP_ClearAllKeys;
              SP_FPCycleEditorWindows(2);
              SP_SwitchFocus(fwEditor);
            End;
          End;
        End;

      K_TAB:
        Begin
          // Pull the current PROGLINE (or line number typed in DW) into the editor.
          SP_FPBringToEditor(0, 0, Error);
          If Error.Code = SP_ERR_OK Then Begin
            // Update the component to show the newly fetched line.
            If Assigned(DWBASICEditor) Then Begin
              DWBASICEditor.SetText(EDITLINE);
              DWBASICEditor.GotoLine(0, CURSORPOS);
              DWBASICEditor.Paint;
            End;
            PlayClick;
          End;
        End;

      K_UP:
        Begin
          // Ctrl+Up: move PROGLINE highlight to the previous listing line.
          If KEYSTATE[K_CONTROL] = 1 Then Begin
            Idx := Max(SP_FindFPLine(PROGLINE), 0);
            While Idx > 0 Do Begin
              Dec(Idx);
              If SP_GetFPLineNumber(Idx) > 0 Then Break;
            End;
            If SP_GetFPLineNumber(Idx) > 0 Then Begin
              PROGLINE := SP_GetFPLineNumber(Idx);
              Listing.FPCLine := Idx;
              Listing.FPSelLine := Idx;
              Listing.FPCPos := SP_LineHasNumber(Idx) + 1;
              Listing.FPSelPos := Listing.FPCPos;
              SP_FPScrollToLine(PROGLINE, 1);
            End;
            PlayClick;
          End;
        End;

      K_DOWN:
        Begin
          // Ctrl+Down: move PROGLINE highlight to the next listing line.
          If KEYSTATE[K_CONTROL] = 1 Then Begin
            Idx := Max(0, SP_FindFPLine(PROGLINE));
            While Idx < Listing.Count - 1 Do Begin
              Inc(Idx);
              If SP_GetFPLineNumber(Idx) > 0 Then Break;
            End;
            If Idx < Listing.Count Then Begin
              If SP_GetFPLineNumber(Idx) > 0 Then Begin
                PROGLINE := SP_GetFPLineNumber(Idx);
                Listing.FPCLine := Idx;
                Listing.FPSelLine := Idx;
                Listing.FPCPos := SP_LineHasNumber(Idx) + 1;
                Listing.FPSelPos := Listing.FPCPos;
                SP_FPScrollToLine(PROGLINE, 9999);
              End;
            End;
            PlayClick;
          End;
        End;

    End; // Case Key^.KeyCode

  End Else Begin

    // Ctrl+char: program-level operations that work from the direct window.
    // Ctrl+Z/Y/C/X/V/A are handled by the component and never reach here.
    // Ctrl+F is intercepted in bemDirect PerformKeyDown and forwarded here.
    If KEYSTATE[K_CONTROL] = 1 Then
      Case Lower(Key^.KeyChar)[1] Of

        'r': StartFindOp(False);       // Find & Replace on program listing
        'f': If KEYSTATE[K_SHIFT] = 1 Then
              StartFindOp(True)          // Ctrl+Shift+F: advanced Find dialog
             Else
              If Assigned(FPBASICEditor) Then
                FPBASICEditor.ShowSearchBar; // Ctrl+F: editor inline search bar
        'g': If KEYSTATE[K_SHIFT] = 0  // Go to line / label
               Then StartGotoOp
               Else SP_FPGotoLine(LASTERRORLINE, LASTERRORSTATEMENT);

        'o': Begin                     // Re-order listing
               Listing.CommenceUndo;
               SP_ReOrderListing(Error);
               Listing.CompleteUndo;
             End;

        'l': StartFileOp(SP_KW_LOAD,  '');         // LOAD ""
        'm': StartFileOp(SP_KW_MERGE, '');         // MERGE ""
        's': StartFileOp(SP_KW_SAVE,  PROGNAME);   // SAVE

        'n': StartBPEditOp(-1, nil);   // New breakpoint

        'w': StartWatchOp(-1);         // Watch expression

        'b': If FPDebugPanelVisible    // Toggle debug panel
               Then SP_User_CloseDebugPanel
               Else SP_User_OpenDebugPanel;

      End;

  End;

  UpdateStatusLabel;

End;

Procedure SP_FPEditorError(Var Error: TSP_ErrorCode; LineNum: Integer = -2);
Var
  Err: TSP_ErrorCode;
  ErrWin: pSP_Window_Info;
  ErrorText, Text, Title, tempText: aString;
  t2, EMove, ETop: aFloat;
  ERRORWINDOW, WinW, WinH, WinX, WinY, MaxW, Lines, Cnt, Idx, MaxLen,
  Font, Window: Integer;
  t, t3: NativeUInt;
  WasTab: Boolean;
Begin

  WasTab := False;
  SP_HaltAllControls;

  SP_Interpreter_Ready := True;
  Window := SCREENBANK;
  REPCOUNT := FRAMES;

  SP_SetCurrentWindowSettings;
  Font := SP_SetFPEditorFont;

  // Turn off ON ERROR - we don't want this to trigger now, it should have done it before if at all.
  // The EVERY system is also turned off, as the system should halt completely here.

  ERROR_LineNum := -2;
  SP_ClearEvery;

  SCREENLOCK := False;
  FPEditorOutSet := OUTSET;
  OUTSET := False;

  // Get the error Text

  SystemState := SS_ERROR;

  If LineNum = -2 Then Begin
    If Error.Line < 0 Then
      Error.Line := 0
    Else Begin
      If Error.Line >= SP_Program_Count Then
        Error.Line := SP_Program_Count -1;
      Error.Line := pLongWord(@SP_Program[Error.Line][2])^;
    End;
  End Else
    Error.Line := SP_GetLineNumberFromText(Listing[LineNum]);
  tempText := ErrorMessages[Error.Code];
  If ErrStr <> '' Then
    If ErrStr[1] = '!' Then Begin
      ErrStr := Copy(ErrStr, 2);
      If Copy(tempText, Length(tempText) -1, 2) = '()' Then
        tempText := Copy(tempText, 1, Length(tempText) -2);
    End;
  If Error.Code = 51 Then Begin
    If SP_KeyWordID < 4000 Then
      Text := IntToString(Error.Code)+' '+ProcessErrorMessage(tempText) + SP_KEYWORDS[SP_KeyWordID - SP_KeyWord_Base] + ', ' + IntToString(Error.Line)+':'+IntToString(Error.Statement)
    Else
      Text := IntToString(Error.Code)+' '+ProcessErrorMessage(tempText) + IntToString(SP_KeyWordID) + ', ' + IntToString(Error.Line)+':'+IntToString(Error.Statement);
  End Else
    Text := IntToString(Error.Code)+' '+ProcessErrorMessage(tempText) + ', ' + IntToString(Error.Line)+':'+IntToString(Error.Statement);

  If Error.Code <> SP_ERR_BREAKPOINT Then Begin

    // Create a window.

    Idx := 1;
    Cnt := 0;
    ErrorText := '';
    MaxW := DISPLAYWIDTH - (2 + FPFw + FPFw);
    While Idx <= Length(Text) Do Begin
      ErrorText := ErrorText + Text[Idx];
      If Text[Idx] >= ' ' Then
        Inc(Cnt);
      If Cnt > MaxW Div FPFw Then Begin
        If Text[Idx] = ' ' Then
          ErrorText[Length(ErrorText)] := #13
        Else Begin
          While (Idx > 1) and (Text[Idx] > ' ') Do Begin
            Dec(Idx);
            ErrorText := Copy(ErrorText, 1, Length(ErrorText) -1);
          End;
          ErrorText := ErrorText + #13;
        End;
        Cnt := 0;
      End;
      If Text[Idx] = #13 Then
        Cnt := 0;
      Inc(Idx);
    End;

    Idx := 1;
    Cnt := 0;
    Lines := 1;
    MaxLen := 0;
    While Idx < Length(ErrorText) Do Begin
      If ErrorText[Idx] >= ' ' Then
        Inc(Cnt);
      If ErrorText[Idx] = #13 Then Begin
        Inc(Lines);
        If Cnt > MaxLen Then
          MaxLen := Cnt;
        Cnt := 0;
      End;
      Inc(Idx);
    End;
    WinH := FPCaptionHeight + (BSize * 2) + 1 + (FPFh * Lines);

    SHOWLIST := False;
    If (Error.Code <> SP_ERR_OK) And (Error.Code <> SP_ERR_BREAK) And (Error.Code <> SP_ERR_STOP) Then Begin
      Title := 'SpecBAS error';
      WinW := DISPLAYWIDTH - BSize * 2;
    End Else Begin
      Title := 'SpecBAS message';
      WinW := DISPLAYWIDTH - BSize * 2;
    End;

    WinX := (DISPLAYWIDTH - WinW) Div 2;
    If Error.Line < -1 Then
      WinY := (DISPLAYHEIGHT - WinH) Div 2
    Else
      WinY := (DISPLAYHEIGHT - WinH) - BSize;

    ERRORWINDOW := SP_Add_Window(WinX, WinY, WinW, WinH, -1, 8, 0, Error);
    SP_SetDrawingWindow(ERRORWINDOW);
    SP_GetWindowDetails(ERRORWINDOW, ErrWin, Error);
    For Idx := 0 To 255 Do ErrWin^.Palette[Idx] := DefaultPalette[Idx];
    SP_SetWindowShadow(ERRORWINDOW, True);

    SP_FillRect(0, 0, WinW, WinH, 7);
    SP_Decorate_Window(ERRORWINDOW, Title, False, False, True);
    COVER := 0;
    T_INK := 0;
    T_OVER := 0;
    SP_TextOut(-1, 1 + BSize, Integer(BSize) + FPCaptionHeight, EdSc + ErrorText, 0, 7, False);
    SP_SetWindowVisible(ERRORWINDOW, False, Error);
    SP_InvalidateWholeDisplay;
    SP_NeedDisplayUpdate := True;

    ErrWin^.Top := DISPLAYHEIGHT +1;
    SP_SetWindowVisible(ERRORWINDOW, True, Error);

    t := Round(CB_GetTicks);
    EMove := WinY - ErrWin^.Top;
    ETop := ErrWin^.Top;

    Repeat
      t3 := Round(CB_GetTicks);
      t2 := (t3 - t)/ANIMSPEED;
      DisplaySection.Enter;
      ErrWin^.Top := Trunc(ETop + (EMove * t2));
      If ((EMove > 0) And (ErrWin^.Top > WinY)) or ((EMove < 0) And (ErrWin^.Top < WinY)) Then
        ErrWin^.Top := WinY;
      DisplaySection.Leave;
      SP_InvalidateWholeDisplay;
      SP_WaitForSync;
    Until (t3 - t) >= ANIMSPEED;

    // Wait for any key - also clear the ESCAPE key's status as it might be left set down.

    SP_ClearAllKeys;
    MOUSEBTN := 0;

    Repeat
      SP_WaitForSync;
      If KEYSTATE[K_TAB] = 1 Then
        WasTab := True;
    Until (Length(ActiveKeys) > 0) or (MOUSEBTN <> 0) Or QUITMSG;
    SP_PlaySystem(CLICKCHAN, CLICKBANK);
    M_DOWNFLAG := False;

    If QUITMSG Then Exit;

    t := Round(CB_GetTicks);
    WinY := DisplayHeight +1;
    EMove := WinY - ErrWin^.Top;
    ETop := ErrWin^.Top;

    Repeat
      t3 := Round(CB_GetTicks);
      t2 := (t3 - t)/ANIMSPEED;
      DisplaySection.Enter;
      ErrWin^.Top := Trunc(ETop + (EMove * t2));
      If ((EMove > 0) And (ErrWin^.Top > WinY)) or ((EMove < 0) And (ErrWin^.Top < WinY)) Then
        ErrWin^.Top := WinY;
      DisplaySection.Leave;
      SP_InvalidateWholeDisplay;
      SP_WaitForSync;
    Until (t3 - t) >= ANIMSPEED;

    SP_SetWindowVisible(ERRORWINDOW, False, Err);
    SP_NeedDisplayUpdate := True;
    SP_WaitForSync;

    Err.Code := SP_ERR_OK;
    SP_DeleteWindow(ERRORWINDOW, Err);

  End;

  SP_Stop_Sound;

  SP_SetSystemFont(Font, Err);
  SP_SetDrawingWindow(Window);

  // Record error position for the caller to navigate to after recreating windows.
  If (Error.Code <> SP_ERR_OK) And (Error.Code <> SP_ERR_BREAK) Then
    If Error.Line > 0 Then
      PROGLINE := Error.Line;

  // TAB: user wants the error line brought into the DW editor for editing.
  If Error.Code <> SP_ERR_BREAKPOINT Then
    If WasTab And (Error.Line > 0) And (Error.Code > 0) Then
      BringToEditorAfterError := True;

  OUTSET := FPEditorOutSet;
  SP_NeedDisplayUpdate := True;
  CauseUpdate := True;

End;

Procedure SP_CloseEditorWindows;
Var
  Error: TSP_ErrorCode;
Begin

  SP_CloseDebugPanel;
  SP_FPCycleEditorWindows(1);
  DWHost_Destroy;
  EditorHost_Destroy;
  FreeAndNil(FPDebugContainer);   // frees entire tree; SP_BaseComponent.Destroy
                                  // calls RemoveTimer(Self) for every component
  FPDebugPanel     := nil;        // owned by FPDebugContainer, already freed above
  FPDebugCombo     := nil;
  FPHelpViewer     := nil;
  FPDebugBPAdd     := nil;
  FPDebugBPDel     := nil;
  FPDebugBPEdt     := nil;
  FPSizeGrabber    := nil;
  FPDebugContent   := nil;
  FPDebugContainer := nil;

  SetLength(Events, 0);
  Error.Code := SP_ERR_OK;
  SP_DeleteWindow(FPWindowID, Error);
  SP_DeleteWindow(DWWindowID, Error);
  FPWIndowID := -1;
  DWWindowID := -1;

  DRPOSX := FPEditorDRPOSX;
  DRPOSY := FPEditorDRPOSY;
  PRPOSX := FPEditorPRPOSX;
  PRPOSY := FPEditorPRPOSY;
  COVER := FPEditorOVER;
  T_OVER := COVER;
  SCREENBANK := -1;
  WINDOWPOINTER := Nil;
  SP_SetDrawingWindow(FPEditorDefaultWindow);
  SCREENBANK := FPEditorDefaultWindow;
  SP_Reset_Temp_Colours;
  SP_NeedDisplayUpdate := True;
  CauseUpdate := True;
  MOUSEVISIBLE := FPEditorMouseStatus;

  CURMENU := EDITORMENU;

End;

Procedure SP_CreateEditorWindows;
Begin

  SP_InitDWMetrics;
  SP_CreateFPWindow;
  SP_CreateDirectWindow;
  SwitchFocusedWindow(fwDirect);
  SP_SwitchFocus(FocusedWindow);
  SP_FPCycleEditorWindows(2);

End;

Function SP_FPExecuteNumericExpression(Const Expr: aString; var Error: TSP_ErrorCode): aFloat;
Var
  Backup: Pointer;
Begin

  Result := 0;
  Backup := SP_StackPtr;
  Error.Code := SP_ERR_OK;
  Error.ReturnType := 0;
  SP_FPExecuteExpression(Expr, Error);
  If Error.Code = SP_ERR_OK Then
    If SP_StackPtr^.OpType = SP_VALUE Then Begin
      Error.ReturnType := SP_VALUE;
      Result := SP_StackPtr^.Val
    End Else
      Error.Code := SP_ERR_SYNTAX_ERROR;
  SP_StackPtr := pSP_StackItem(Backup);

End;

Function SP_FPExecuteStringExpression(Const Expr: aString; var Error: TSP_ErrorCode): aString;
Var
  Backup: Pointer;
Begin

  Backup := SP_StackPtr;
  SP_FPExecuteExpression(Expr, Error);
  If Error.Code = SP_ERR_OK Then
    If SP_StackPtr^.OpType = SP_STRING Then
      Result := SP_StackPtr^.Str
    Else
      Error.Code := SP_ERR_SYNTAX_ERROR;
  SP_StackPtr := pSP_StackItem(Backup);

End;

Function SP_FPCheckExpression(Const Expr: aString; var Error: TSP_ErrorCode): Boolean;
Var
  Position: Integer;
  s, t: aString;
Begin

  Position := 1;
  s := SP_TokeniseLine(Expr, True, False) + #255;
  t := SP_Convert_Expr(s, Position, Error, -1);
  Result := (Error.Code = SP_ERR_OK) And (Position >= Length(s));

End;

Function SP_FPExecuteAnyExpression(Const Expr: aString; var Error: TSP_ErrorCode): aString;
Var
  sbnk: Integer;
  Backup: Pointer;
Begin

  Result := '';
  sBnk := SCREENBANK;
  Backup := SP_StackPtr;
  SP_SetDrawingWindow(FPEditorDefaultWindow);
  SP_FPExecuteExpression(Expr, Error);
  If Error.Code = SP_ERR_OK Then
    If SP_StackPtr^.OpType = SP_VALUE Then
      Result := aFloatToStr(SP_StackPtr^.Val)
    Else
      Result := SP_StackPtr^.Str;
  SP_StackPtr := pSP_StackItem(Backup);
  SP_SetDrawingWindow(sBnk);

End;

Procedure SP_FPExecuteExpression(Const Expr: aString; var Error: TSP_ErrorCode);
Var
  Position, state: Integer;
  ValTkn: paString;
  Str1, ValTokens: aString;
  changed: Boolean;
Begin

  // Executes a line of BASIC as an expression. Calling functions can deal with the result and any errors.

  Position := 1;
  State := SYSTEMSTATE;
  SYSTEMSTATE := SS_EVALUATE;
  If Expr <> '' Then Begin
    If Expr[1] <> #$F Then Begin
      Str1 := SP_TokeniseLine(Expr, True, False) + #255;
      ValTokens := SP_Convert_Expr(Str1, Position, Error, -1) + #255;
      If (Position <> Length(Str1)) or ((Position < Length(Str1)) And (Str1[Position] <> #255)) Then Begin
        Error.Code := SP_ERR_SYNTAX_ERROR;
        SYSTEMSTATE := State;
        Exit;
      End;
      SP_RemoveBlocks(ValTokens);
      SP_TestConsts(ValTokens, 1, Error, False, changed);
      SP_AddHandlers(ValTokens);
    End Else
      ValTokens := Copy(Expr, 2);

    If ValTokens = #255 Then Begin
      Error.Code := SP_ERR_SYNTAX_ERROR;
      SYSTEMSTATE := State;
      Exit;
    End;

    If Error.Code = SP_ERR_OK Then Begin
      Position := 1;
      ValTkn := @ValTokens;
      SP_InterpretCONTSafe(ValTkn, Position, Error);
    End;
  End;
  SYSTEMSTATE := State;

End;

Procedure SP_StoreBASICLine(Const TokensStr: aString);
// Stores a numbered BASIC line into the listing and syncs the editor component.
Begin
  SP_DeleteIncludes;
  {$IFNDEF RTComp}
  DoAutoSave;
  {$ENDIF}
  PROGLINE := dLongWord(@TokensStr[2]);
  ProcListAvailable := False;
  SP_DWStoreLine(TokensStr);
  SP_PlaySystem(OKCHAN, OKSNDBANK);
End;

Procedure SP_ShowExprResult(Const Expr: aString);
Var
  Display: aString;
  Idx: Integer;
Begin
  Display := SP_TrimRight(Expr);

  // Add to component history so the user can recall/edit it with cursor-up.
  // Don't add to the global EditorHistory buffer - that's for persistence only.
  If Assigned(DWBASICEditor) Then
    DWBASICEditor.AddToHistory(Display);

  // Animate character by character
  For Idx := 1 To Length(Display) Do Begin
    If Assigned(DWBASICEditor) Then
      DWBASICEditor.ShowResult(Copy(Display, 1, Idx));
    SP_WaitForSync;
  End;

  // Final full text - cursor, flash and R indicator now active
  If Assigned(DWBASICEditor) Then
    DWBASICEditor.ShowResult(Display);
End;

Procedure SP_FPExecuteEditLine(Var Line: aString);
Var
  TokensStr, Expr:                          aString;
  Tokens:                                   paString;
  PreParseErrorCode,
  PreParseErrorLine,
  PreParseErrorStatement:                   Integer;
  saveCONTLINE, saveCONTSTATEMENT:         Integer;
  ErrorBASICLine, ErrorStatement:           Integer;
  Error:                                    TSP_ErrorCode;
Begin
  EDITERROR    := False;
  EDITERRORPOS := 0;
  If StripLeadingSpaces(Line) = '' Then Exit;

  SP_ClearAllKeys;
  TokensStr := SP_TokeniseLine(Line, False, True) + SP_TERMINAL_SEQUENCE;
  SP_Convert_ToPostFix(TokensStr, Error.Position, Error);
  Line := SP_DeTokenise(TokensStr, Error.Position, False, False);
  BREAKSIGNAL := False;

  // ── Tokenisation / syntax error ──────────────────────────────────────────
  If Error.Code <> SP_ERR_OK Then Begin

    // Try as an expression (catches things like "1+1" or "PRINT a$")
    If Error.Code <> SP_ERR_INVALID_KEYWORD Then Begin
      // Hard syntax error - show in DW and bail
      EDITLINE  := SP_DeTokenise(TokensStr, Error.Position, False, False);
      EDITERROR := True;
      EDITERRORPOS := Error.Position;
      If Assigned(DWBASICEditor) Then Begin
        DWBASICEditor.SetText(EDITLINE);
        DWBASICEditor.Paint;
      End;
      SP_PlaySystem(ERRORCHAN, ERRSNDBANK);
      PROGSTATE := SP_PR_STOP;
      SP_GetDebugStatus(-1);
      If FocusedWindow = fwEditor Then SYSTEMSTATE := SS_EDITOR
      Else SYSTEMSTATE := SS_DIRECT;
      Exit;
    End;

    // SP_ERR_INVALID_KEYWORD - try as expression
    Error.Code     := SP_ERR_OK;
    Error.Position := 1;
    TokensStr := SP_TokeniseLine(EDITLINE, True, False) + SP_TERMINAL_SEQUENCE;
    EDITLINE  := SP_DeTokenise(TokensStr, Error.Position, False, False);
    If (Ord(TokensStr[Error.Position]) = SP_SYMBOL) And
       (TokensStr[Error.Position + 1] = '?') Then
      Inc(Error.Position, 2);
    Expr := SP_Convert_Expr(TokensStr, Error.Position, Error, -1) + SP_TERMINAL_SEQUENCE;
    SP_RemoveBlocks(Expr);
    TokensStr := TokensStr + Expr;

    If (Error.Code <> SP_ERR_OK) Or (Expr = SP_TERMINAL_SEQUENCE) Then Begin
      // Not a valid expression either
      EDITLINE  := SP_DeTokenise(TokensStr, Error.Position, False, False);
      EDITERROR := True;
      EDITERRORPOS := Error.Position;
      If Assigned(DWBASICEditor) Then Begin
        DWBASICEditor.SetText(EDITLINE);
        DWBASICEditor.Paint;
      End;
      SP_PlaySystem(ERRORCHAN, ERRSNDBANK);
      PROGSTATE := SP_PR_STOP;
      SP_GetDebugStatus(-1);
      If FocusedWindow = fwEditor Then SYSTEMSTATE := SS_EDITOR
      Else SYSTEMSTATE := SS_DIRECT;
      Exit;
    End;

    // Valid expression - run it and show the result
    Error.Position := Length(TokensStr) - Length(Expr) + 1;
    COMMAND_TOKENS := TokensStr;
    NXTSTATEMENT := -1; NXTLINE := -1;
    SP_StackPtr := SP_StackStart;
    Tokens := @TokensStr;
    SP_DeleteIncludes;
    SP_PreParse(False, False, Error, Tokens^);
    PreParseErrorCode := Error.Code;
    Error.Code := SP_ERR_OK;
    PROGSTATE := SP_PR_RUN;
    SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                      exOverflow, exUnderflow, exPrecision]);
    ClearFlags;
    OUTSET := FPEditorOutSet;
    SP_SetDrawingWindow(FPEditorDefaultWindow);
    saveCONTLINE      := CONTLINE;
    saveCONTSTATEMENT := CONTSTATEMENT;
    SP_Interpreter(Tokens, Error.Position, Error, PreParseErrorCode);
    CONTLINE      := saveCONTLINE;
    CONTSTATEMENT := saveCONTSTATEMENT;

    If (Error.Code = SP_ERR_OK) And
       (LongWord(SP_StackPtr) = LongWord(SP_StackStart) + SizeOf(SP_StackItem)) Then Begin
      If SP_StackPtr^.OpType = SP_VALUE Then
        Expr := aFloatToStr(SP_StackPtr^.Val) + ' '
      Else Begin
        Expr := SP_MakePretty(SP_StackPtr^.Str) + ' ';
        If Length(Expr) > 256 Then Expr := Copy(Expr, 1, 256);
      End;
      EDITLINE := '';
      SP_PlaySystem(OKCHAN, OKSNDBANK);
      SP_ShowExprResult(Expr);
    End Else Begin
      If (Error.Code = SP_ERR_OK) And (SP_StackPtr = SP_StackStart) Then Begin
        EDITERRORPOS := Min(Error.Position, Length(EDITLINE));
        EDITERROR    := True;
        If Assigned(DWBASICEditor) Then DWBASICEditor.Paint;
        SP_PlaySystem(ERRORCHAN, ERRSNDBANK);
      End Else Begin
        // Expression evaluation failed with a runtime error - show error and recreate windows
        PROGSTATE := SP_PR_STOP;
        SP_CloseEditorWindows;
        If Not QUITMSG Then Begin
          SP_FPEditorError(Error);
          SP_StartCompiler;
          SP_CreateEditorWindows;
        End;
        SP_GetDebugStatus(-1);
        If FocusedWindow = fwEditor Then SYSTEMSTATE := SS_EDITOR
        Else SYSTEMSTATE := SS_DIRECT;
        STEPMODE := SM_None;
        Exit;
      End;
    End;

    PROGSTATE := SP_PR_STOP;
    SP_StartCompiler;
    SP_GetDebugStatus(-1);
    If FocusedWindow = fwEditor Then SYSTEMSTATE := SS_EDITOR
    Else SYSTEMSTATE := SS_DIRECT;
    STEPMODE := SM_None;
    Exit;
  End;

  EDITERROR := False;
  EDITRESULT := False;

  // ── Numbered BASIC line - store it ───────────────────────────────────────
  If TokensStr[1] = aChar(SP_LINE_NUM) Then Begin
    SP_StoreBASICLine(TokensStr);
    Line := '';
    PROGSTATE := SP_PR_STOP;
    SP_GetDebugStatus(-1);
    SYSTEMSTATE := SS_DIRECT;
    STEPMODE := SM_None;
    Exit;
  End;

  // ── Execute a command ─────────────────────────────────────────────────────
  If STEPMODE = SM_None Then Begin
    BPSIGNAL := False;
    SP_CloseEditorWindows;
  End Else Begin
    SP_SetDrawingWindow(FPEditorDefaultWindow);
    SP_Reset_Temp_Colours;
  End;

  Line := '';
  Error.Line      := -2;
  Error.Statement := 1;
  Error.Position  := SP_FindStatement(@TokensStr, 1);
  COMMAND_TOKENS  := TokensStr;
  NXTSTATEMENT := -1; NXTLINE := -1;
  SP_StackPtr := SP_StackStart;
  Tokens := @TokensStr;
  SP_DeleteIncludes;
  SP_PreParse(False, False, Error, Tokens^);
  PreParseErrorCode      := Error.Code;
  PreParseErrorLine      := Error.Line;
  PreParseErrorStatement := Error.Statement;
  If Error.Code <> SP_ERR_OK Then Begin
    Error.Line      := -2;
    Error.Statement := 1;
    Error.Code      := SP_ERR_OK;
  End;
  Error.ReturnType := 0;
  PROGSTATE := SP_PR_RUN;
  ClearFlags;
  OUTSET := FPEditorOutSet;
  SystemState := SS_DIRECT;

  SP_Interpreter(Tokens, Error.Position, Error, PreParseErrorCode);

  If STEPMODE <> SM_None Then SP_ClearAllKeys;
  SP_PrepareBreakpoints(False);

  // Font scale sanity check
  While (Round((FPWindowWidth - FPFw) -
         (FPGutterWidth * (EDFONTSCALEX * Fw))) Div
         Round(EDFONTSCALEX * Fw)) - 2 < FPGutterWidth Do Begin
    EDFONTSCALEX := EDFONTSCALEX - 1;
    EDFONTSCALEY := EDFONTSCALEY - 1;
  End;

  // Reconcile error line: if pre-parse and runtime agree, use pre-parse position
  If (Error.Code <> SP_ERR_OK) And (Error.Code = PreParseErrorCode) Then Begin
    Error.Line      := PreParseErrorLine;
    Error.Statement := PreParseErrorStatement;
  End;

  // ── SP_ERR_EDITOR: runtime signals "jump to this listing line" ───────────
  If Error.Code = SP_ERR_EDITOR Then Begin
    // Error.Line is a listing INDEX here - convert to BASIC line number
    ErrorBASICLine := SP_GetLineNumberFromText(Listing[Error.Line]);
    ErrorStatement := Error.Statement;
    SP_PlaySystem(ERRORCHAN, ERRSNDBANK);
    Error.Code := SP_ERR_NO_ERROR;
    If STEPMODE = SM_None Then SP_CreateEditorWindows;
    SP_FPBringToEditor(ErrorBASICLine, ErrorStatement, Error, False);
    SP_SwitchFocus(fwEditor);
    SP_ClearAllKeys;
    PROGSTATE := SP_PR_STOP;
    SP_StartCompiler;
    SP_GetDebugStatus(-1);
    SYSTEMSTATE := SS_EDITOR;
    STEPMODE := SM_None;
    Exit;
  End;

  // ── Normal error / break / stop ───────────────────────────────────────────
  PROGSTATE := SP_PR_STOP;
  SP_StartCompiler;

  If Not QUITMSG And Not EDITERROR Then Begin

    If STEPMODE < SM_Single Then Begin

      // Show error window (sets PROGLINE to the BASIC line number, WasTab path handled)
      If STEPMODE = SM_None Then
        If Error.Line = -10 Then // NEW signalled
          ShowAboutDialog
        Else
          SP_FPEditorError(Error);

      // Recreate editor windows - components now exist
      SP_CreateEditorWindows;

      If BringToEditorAfterError Then Begin
        // TAB during error window: bring error line into DW editor for editing
        BringToEditorAfterError := False;
        SP_FPBringToEditor(PROGLINE, Error.Statement, Error, True);
        SP_SwitchFocus(fwDirect);
      End Else If PROGLINE > 0 Then Begin
        // Normal error: scroll editor to the error line, no DW population
        SP_FPBringToEditor(PROGLINE, Error.Statement, Error, False);
      End;

      // Place exec arrow at the continue point
      If (CONTLINE >= 0) And (CONTLINE < SP_Program_Count) And
         (SP_Program[CONTLINE] <> '') Then
        EditorHost_SetExecLineWithScroll(
          pLongWord(@SP_Program[CONTLINE][2])^, CONTSTATEMENT);

    End Else If STEPMODE = SM_StepOver Then Begin

      // Restore editor state that was saved before step-over
      FPEditorDefaultWindow  := SCREENBANK;
      FPEditorDRPOSX         := DRPOSX;
      FPEditorDRPOSY         := DRPOSY;
      FPEditorPRPOSX         := PRPOSX;
      FPEditorPRPOSY         := PRPOSY;
      FPEditorOVER           := COVER;
      FPEditorSaveFPS        := FPS;
      FPEditorFRAME_MS       := FRAME_MS;
      FPEditorMouseStatus    := MOUSEVISIBLE;

      If Not ((CONTLINE = -1) Or (CONTLINE >= SP_Program_Count) Or
              (SP_Program[CONTLINE] = '')) Then
        PROGLINE := pLongWord(@SP_Program[CONTLINE][2])^;

      If FPWindowID = -1 Then SP_CreateEditorWindows;
      EditorHost_SetExecLineWithScroll(
        pLongWord(@SP_Program[CONTLINE][2])^, CONTSTATEMENT);

    End;

    COVER  := 0;
    T_OVER := 0;
  End;

  SP_GetDebugStatus(-1);
  If FocusedWindow = fwEditor Then SYSTEMSTATE := SS_EDITOR
  Else SYSTEMSTATE := SS_DIRECT;
  STEPMODE := SM_None;

End;

Procedure SP_DWStoreLine(Line: aString);
Var
  s: aString;
  LineNum, Idx: Integer;
  Extents: TPoint;
  IsDelete: Boolean;

  Procedure SP_nDeleteLine;
  Begin
    CompilerLock.Enter;
    SP_DeleteLine(Extents.x, False);
    If Listing.Count = 0 Then
      SP_AddLine('', '', '');
    CompilerLock.Leave;
  End;

Begin

  // Takes the compiled text of the editline, EDITLINE contains the detokenised code,
  // which is stored in the listing.

  s := StripSpaces(EDITLINE);
  LineNum := SP_GetLineNumberFromText(s);
  IsDelete := StringToInt(s, -1) <> -1;
  If IsDelete Then Begin
    // A single line number, so a line delete operation
    Idx := SP_GetExactLineIndex(LineNum);
    If Idx < Listing.Count Then Begin
      Extents.X := Idx; Extents.Y := Idx; {Extents always (Idx,Idx)}
      Listing.CommenceUndo;
      SP_nDeleteLine;
      Listing.CompleteUndo;
    End;
    If Listing.FPCLine >= Idx Then
      If Idx > 0 Then
        Listing.FPCLine := Idx -1
      Else
        Listing.FPCLine := 0;
  End Else Begin
    // Store this line. Find either the next larger line and insert there,
    // or an existing line and replace that.
    Idx := SP_GetLineIndex(LineNum);
    If Idx = Listing.Count Then Begin
      // Line is non-existing or has a line number greater than that of the last line
      CompilerLock.Enter;
      Listing.CommenceUndo;
      If (Listing.Count = 1) And (StripSpaces(Listing[0]) = '') Then
        Listing[0] := EDITLINE
      Else
        SP_AddLine(EDITLINE, '', '');
      CompilerLock.Leave;
      PROGLINE := LineNum;
      Listing.FPCLine := Listing.Count -1;
      Listing.CompleteUndo;
    End Else Begin
      // Line can either be inserted or needs to replace a line.
      Listing.CommenceUndo;
      If SP_GetLineNumberFromText(Listing[Idx]) = LineNum Then Begin
        // A replace operation. Get the extents of the line to be replaced.
        Extents.X := Idx; Extents.Y := Idx; {Extents always (Idx,Idx)}
        SP_nDeleteLine;
      End;
      // Insert the new line
      CompilerLock.Enter;
      SP_InsertLine(Idx, EDITLINE, '', '');
      CompilerLock.Leave;
      PROGLINE := LineNum;
      Listing.FPCLine := Idx;
      Listing.CompleteUndo;
    End;

  End;

  EDITLINE := '';
  Listing.FPCPos := 1;
  Listing.FPSelLine := Listing.FPCLine;
  Listing.FPSelPos := Listing.FPCPos;
  SP_MarkAsDirty(Listing.FPCLine);

  // Sync the editor component so its text matches the updated Listing.
  // Pass 0 for a delete so GotoBASICLine is skipped.
  If IsDelete Then
    EditorHost_StoreLine(0)
  Else
    EditorHost_StoreLine(LineNum);

End;

Function SP_ReOrderListing(Var Error: TSP_ErrorCode): Boolean;
Var
  i, j, iLine, jLine: Integer;
  tmpStr: aString;
  tmpFlags: TLineFlags;
Begin
  Result := True;
  If Assigned(FPBASICEditor) Then Begin
    // Component is open: delegate to its sort which also reflows wraps/highlights.
    EditorHost_SortByLineNumber;
    Exit;
  End;

  // Component not open: simple insertion sort on Listing by BASIC line number.
  For i := 1 To Listing.Count - 1 Do Begin
    iLine := SP_GetLineNumberFromText(Listing[i]);
    If iLine = 0 Then Continue;
    j := i - 1;
    While j >= 0 Do Begin
      jLine := SP_GetLineNumberFromText(Listing[j]);
      If (jLine > 0) And (jLine > iLine) Then Begin
        tmpStr               := Listing[j];
        tmpFlags             := Listing.Flags[j]^;
        Listing[j]           := Listing[j + 1];
        Listing.Flags[j]^    := Listing.Flags[j + 1]^;
        Listing[j + 1]       := tmpStr;
        Listing.Flags[j + 1]^:= tmpFlags;
        Dec(j);
      End Else
        Break;
    End;
  End;
End;

Procedure SP_FPRenumberListing(Start, Finish, Line, Step: Integer; Var Error: TSP_ErrorCode);
Type
  TLineRec = Record Org, New: Integer; End;  // Flag and Indent removed
Var
  Idx, sIdx, fIdx, nIdx, LineNum, curLineNum, kw, l, nl: Integer;
  NewList, OutList: TStringList;
  ChangeList: Array of TLineRec;
  InString, InREM: Boolean;
  s, w, e: aString;
  Extents: TPoint;
Begin

  SP_DeleteIncludes;
  DoAutoSave;
  CompilerLock.Enter;

  If Start < 0 Then Start := 0;
  If Finish < 0 Then Finish := 9999999;

  If Step < 1 Then Begin
    Error.Code := SP_ERR_INTEGER_OUT_OF_RANGE;
    CompilerLock.Leave;
    Exit;
  End;

  Listing.CommenceUndo;
  SP_ReOrderListing(Error);
  If Error.Code <> SP_ERR_OK Then Begin
    CompilerLock.Leave;
    Exit;
  End;

  // --- Phase 1: Serialise lines-to-renumber into NewList ---
  // Packed format per raw line: [4 bytes length][text]

  NewList := TStringList.Create;
  Idx := 0;
  sIdx := -1;
  fIdx := -1;
  While Idx < Listing.Count Do Begin
    LineNum := SP_GetLineNumberFromText(Listing[Idx]);
    If (LineNum > 0) And (LineNum >= Start) And (LineNum <= Finish) Then Begin
      If sIdx = -1 Then sIdx := Idx;
      Extents.X := Idx; Extents.Y := Idx;
      While (Extents.Y + 1 < Listing.Count) And
            (SP_GetLineNumberFromText(Listing[Extents.Y + 1]) = 0) Do
        Inc(Extents.Y);
      s := '';
      For nIdx := Extents.X To Extents.Y Do
        s := s + LongWordToString(Length(Listing[nIdx])) + Listing[nIdx];
      NewList.Add(s);
      Idx := Extents.Y;
    End Else
      If (LineNum > Finish) And (fIdx = -1) Then
        fIdx := Idx;
    Inc(Idx);
  End;
  If fIdx = -1 Then fIdx := Listing.Count;

  // --- Phase 2: Delete the renumber range from Listing ---

  For Idx := sIdx To fIdx - 1 Do SP_DeleteLine(sIdx, False);

  // --- Phase 3: Serialise remaining lines into OutList ---

  OutList := TStringList.Create;
  Idx := 0;
  While Idx < Listing.Count Do Begin
    If SP_GetLineNumberFromText(Listing[Idx]) > 0 Then Begin
      Extents.X := Idx; Extents.Y := Idx;
      While (Extents.Y + 1 < Listing.Count) And
            (SP_GetLineNumberFromText(Listing[Extents.Y + 1]) = 0) Do
        Inc(Extents.Y);
      s := '';
      For nIdx := Extents.X To Extents.Y Do Begin
        s := s + LongWordToString(Length(Listing[Extents.X])) + Listing[Extents.X];
        SP_DeleteLine(Extents.X, False);
      End;
      OutList.Add(s);
    End Else
      Inc(Idx);
  End;

  // --- Phase 4: Assign new line numbers to NewList entries ---
  // Each entry's packed string begins with the first raw line (the numbered one).
  // Unpack it, strip old number, insert new number, repack. Record old->new map.

  SetLength(ChangeList, NewList.Count);
  CurLineNum := Line;
  For Idx := 0 To NewList.Count - 1 Do Begin
    s  := NewList[Idx];
    kw := pLongWord(@s[1])^;          // length of first raw line
    e  := Copy(s, kw + 5);            // remainder of packed string (continuations)
    s  := Copy(s, 5, kw);             // first raw line text
    l  := Length(s);
    nIdx := 1;
    While (nIdx <= l) And (s[nIdx] In ['0'..'9']) Do Inc(nIdx);
    ChangeList[Idx].Org := StringToLong(Copy(s, 1, nIdx - 1));
    ChangeList[Idx].New := CurLineNum;
    s := IntToString(CurLineNum) + Copy(s, nIdx);
    NewList[Idx] := LongWordToString(Length(s)) + s + e;
    Inc(CurLineNum, Step);
  End;

  // --- Phase 5: Merge NewList into OutList in line-number order ---
  // Every entry in both lists starts with a numbered line, so we can always
  // extract the line number from bytes 5 onwards of each entry.

  For Idx := 0 To NewList.Count - 1 Do Begin
    LineNum := SP_GetLineNumberFromText(Copy(NewList[Idx], 5));
    nIdx := 0;
    While nIdx < OutList.Count Do Begin
      CurLineNum := SP_GetLineNumberFromText(Copy(OutList[nIdx], 5));
      If CurLineNum > 0 Then
        If CurLineNum = LineNum Then Begin
          OutList[nIdx] := NewList[Idx];
          Break;
        End Else
          If CurLineNum > LineNum Then Begin
            OutList.Insert(nIdx, NewList[Idx]);
            Break;
          End;
      Inc(nIdx);
    End;
    If nIdx = OutList.Count Then
      OutList.Add(NewList[Idx]);
  End;

  // --- Phase 6: Unpack OutList back into Listing ---

  For Idx := 0 To OutList.Count - 1 Do Begin
    s := OutList[Idx];
    While s <> '' Do Begin
      nl := pLongWord(@s[1])^;
      SP_AddLine(Copy(s, 5, nl), '', '');
      s := Copy(s, nl + 5);
    End;
  End;

  // --- Phase 7: Patch line number references in source text ---

  InREM := False; InString := False;
  For Idx := 0 To Listing.Count - 1 Do Begin
    nIdx := 1;
    s := Upper(Listing[Idx]);
    If SP_GetLineNumberFromText(s) > 0 Then Begin
      InREM := False; InString := False;
    End;
    While (nIdx < Length(s)) And Not InREM Do Begin
      While (nIdx < Length(s)) And (Not (s[nIdx] In ['A'..'Z']) Or InString) Do Begin
        If s[nIdx] = '"' Then InString := Not InString;
        Inc(nIdx);
      End;
      w := '';
      While (nIdx < Length(s)) And (s[nIdx] In ['A'..'Z', ' ']) Do Begin
        If s[nIdx] = ' ' Then
          If w <> 'GO' Then Begin
            SP_SkipSpaces(s, nIdx);
            Break;
          End;
        w := w + s[nIdx];
        Inc(nIdx);
      End;
      w := StripSpaces(w);
      If (w = 'GOTO') Or (w = 'GOSUB') Or (w = 'RUN') Or
         (w = 'RESTORE') Or (w = 'LIST') Then Begin
        LineNum := 0;
        While (nIdx <= Length(s)) And (s[nIdx] <= ' ') Do Inc(nIdx);
        fIdx := nIdx;
        While (nIdx <= Length(s)) And (s[nIdx] In ['0'..'9']) Do Begin
          LineNum := (LineNum * 10) + Ord(s[nIdx]) - 48;
          Inc(nIdx);
        End;
        If LineNum > 0 Then Begin
          e := IntToString(LineNum);
          sIdx := 0;
          While sIdx < Length(ChangeList) Do Begin
            If ChangeList[sIdx].Org >= LineNum Then Begin
              LineNum := ChangeList[sIdx].New;
              Break;
            End;
            Inc(sIdx);
          End;
          If sIdx < Length(ChangeList) Then Begin
            w := IntToString(LineNum);
            s := Listing[Idx];
            s := Copy(s, 1, fIdx - 1) + w + Copy(s, nIdx);
            Listing[Idx] := s;
            s := Upper(s);
            Inc(nIdx, Length(w) - Length(e));
          End;
        End;
      End Else
        If w = 'REM' Then InREM := True;
    End;
  End;

  SP_ForceCompile;

  Listing.CompleteUndo;
  CompilerLock.Leave;

  SetLength(ChangeList, 0);
  NewList.Free;
  OutList.Free;

  If Assigned(FPBASICEditor) Then EditorHost_LoadFromListing;

End;

Procedure SP_FPDeleteLines(Start, Finish: Integer; var Error: TSP_ErrorCode);
Var
  LineNum, Idx: Integer;
  NeedStart, NeedFinish: Boolean;
Begin

  SP_DeleteIncludes;
  DoAutoSave;
  CompilerLock.Enter;

  If Start > Finish Then Begin
    Error.Code := SP_ERR_INTEGER_OUT_OF_RANGE;
    CompilerLock.Leave;
    Exit;
  End;

  SP_ReOrderListing(Error);
  If Error.Code <> SP_ERR_OK Then Begin
    CompilerLock.Leave;
    Exit;
  End;

  LineNum    := 0;
  NeedStart  := True;
  NeedFinish := True;

  For Idx := 0 To Listing.Count -1 Do Begin
    LineNum := SP_GetLineNumberFromText(Listing[Idx]);
    If LineNum > 0 Then Begin
      If NeedStart Then
        If LineNum >= Start Then Begin
          Start := LineNum; NeedStart := False;
        End;
      If NeedFinish Then
        If LineNum >= Finish Then Begin
          Finish := LineNum; NeedFinish := False;
        End;
    End;
  End;
  If NeedFinish Then Finish := LineNum;

  Idx := 0;
  Listing.CommenceUndo;
  While Idx < Listing.Count Do Begin
    LineNum := SP_GetLineNumberFromText(Listing[Idx]);
    If (LineNum >= Start) And (LineNum <= Finish) Then Begin
      SP_DeleteLine(Idx, False);
      While (Idx < Listing.Count) And (SP_LineHasNumber(Idx) = 0) Do
        SP_DeleteLine(Idx, False);
    End Else
      Inc(Idx);
  End;
  Listing.CompleteUndo;

  CompilerLock.Leave;

  If Assigned(FPBASICEditor) Then EditorHost_LoadFromListing;

End;


Procedure SP_FPMergeLines(Start, Finish: Integer; var Error: TSP_ErrorCode);
Var
  LineNum, Idx, sIdx, nIdx: Integer;
  NeedStart, NeedFinish: Boolean;
  s: aString;
Begin

  SP_DeleteIncludes;
  DoAutoSave;
  CompilerLock.Enter;
  Listing.CommenceUndo;

  If Start > Finish Then Begin
    Error.Code := SP_ERR_INTEGER_OUT_OF_RANGE;
    CompilerLock.Leave;
    Exit;
  End;

  SP_ReOrderListing(Error);
  If Error.Code <> SP_ERR_OK Then Begin
    CompilerLock.Leave;
    Exit;
  End;

  LineNum    := 0;
  NeedStart  := True;
  NeedFinish := True;

  For Idx := 0 To Listing.Count -1 Do Begin
    LineNum := SP_GetLineNumberFromText(Listing[Idx]);
    If LineNum > 0 Then Begin
      If NeedStart Then
        If LineNum >= Start Then Begin
          Start := LineNum; NeedStart := False;
        End;
      If NeedFinish Then
        If LineNum >= Finish Then Begin
          Finish := LineNum; NeedFinish := False;
        End;
    End;
  End;
  If NeedFinish Then Finish := LineNum;

  s := '';
  Idx := 0;
  sIdx := -1;

  While Idx < Listing.Count Do Begin
    LineNum := SP_GetLineNumberFromText(Listing[Idx]);
    If (LineNum > 0) And (LineNum >= Start) And (LineNum <= Finish) Then Begin
      If sIdx = -1 Then sIdx := Idx;
      If Idx <> sIdx Then Begin
        // Append this numbered line's content to the previous line with ':'
        Listing[Idx -1] := Listing[Idx -1] + ':';
        s := Listing[Idx];
        nIdx := 1;
        While s[nIdx] In ['0'..'9'] Do Inc(nIdx);
        s := Copy(s, nIdx);
        Listing[Idx] := s;
      End Else
        Inc(Idx);
    End Else If (LineNum = 0) And (sIdx >= 0) Then Begin
      // Continuation line within the range: treat as plain content, join with ':'
      Listing[Idx -1] := Listing[Idx -1] + ':' + Listing[Idx];
      SP_DeleteLine(Idx, False);
    End Else
      If (LineNum > 0) And (LineNum > Finish) Then
        Break
      Else
        Inc(Idx);
  End;

  For Idx := 0 To Listing.Count -1 Do Begin
    SP_MarkAsDirty(Idx);
  End;

  Listing.CompleteUndo;
  CompilerLock.Leave;

  If Assigned(FPBASICEditor) Then EditorHost_LoadFromListing;

End;

Procedure SP_FPGotoLine(Line, Statement: Integer);
Var
  Error: TSP_ErrorCode;
Begin

  If FocusedWindow = fwDirect Then Begin
    SP_FPBringToEditor(Line, Statement, Error);
  End Else Begin
    EditorHost_ScrollToLine(Line, Statement);
    If Assigned(FPBASICEditor) Then Begin
      FPBASICEditor.SetMode(bemEditor);
      FPBASICEditor.SetFocus(True);
    End;
    // Keep Listing.FPCLine in sync for the rest of the editor infrastructure.
    Listing.FPCLine := FPBASICEditor.CursorLine;
    Listing.FPCPos  := FPBASICEditor.CursorCol;
    Listing.FPSelLine := Listing.FPCLine;
    Listing.FPSelPos  := Listing.FPCPos;
  End;

  UpdateStatusLabel;

End;

Procedure StartFileOp(Operation: Integer; Filename: aString);
Var
  Error: TSP_ErrorCode;
Begin

  Case Operation of
    SP_KW_LOAD:
      Begin
        Filename := OpenFileReq('Load program', PROGNAME, '10:ZXASCII;10:ZXPACK', False, Error);
        If Filename <> '' Then
          AddControlMsg(clInterpretCommand, 'LOAD "'+Filename+'"');
      End;
    SP_KW_SAVE:
      Begin
        If FILENAMED Then Begin
          // Save the file
          AddControlMsg(clInterpretCommand, 'SAVE "'+Filename+'"');
        End Else Begin
          // Save using the File requester
          Filename := OpenFileReq('Save program', PROGNAME, '10:ZXASCII;10:ZXPACK', True, Error);
          If Filename <> '' Then
            AddControlMsg(clInterpretCommand, 'SAVE "'+Filename+'"');
        End;
      End;
    SP_KW_MERGE:
      Begin
        Filename := OpenFileReq('Merge program', PROGNAME, '10:ZXASCII', False, Error);
        If Filename <> '' Then
          AddControlMsg(clInterpretCommand, 'MERGE "'+Filename+'"');
      End;
  End;

  SP_InvalidateWholeDisplay;

End;

Procedure StartBPEditOp(BPIndex: Integer; Bp: pSP_BreakPointInfo);
Var
  BPWindow: SP_BreakpointWindow;
Begin

  BPWindow := SP_BreakpointWindow.Create;
  If BPIndex = -1 Then Begin
    // New breakpoint
    If FocusedWindow = FWDirect Then
      BPWindow.Open(BpIndex, BP_Stop, PROGLINE, 1, 0, 'Add breakpoint', '')
    Else
      BPWindow.Open(BpIndex, BP_Stop, EditorHost_GetCursorBASICLine, EditorHost_GetCursorStatement, 0, 'Add breakpoint', '');
  End Else Begin
    // Edit current breakpoint
    With Bp^ Do
      BPWindow.Open(BpIndex, bpType, Line, Statement, PassCount, 'Edit breakpoint', Condition);
  End;

End;

Procedure StartWatchOp(Index: Integer);
Var
  Error: TSP_ErrorCode;
  t: aString;
Begin

  If Index = -1 Then
    t := ''
  Else
    t := SP_WatchList[Index].Expression;

  Error.Code := SP_ERR_OK;
  GotoWindow := SP_TextRequester.Create;
  GotoWindow.Open('Create new watch', t, tkAnyExpression, False, Error);

  If FPGotoText <> '' Then Begin
    SP_AddWatch(Index, FPGotoText);
    SP_GetDebugStatus(dbgWatches);
  End;

End;

Procedure StartGotoOp;
Var
  Error: TSP_ErrorCode;
  b: Boolean;
  l, s, Linetxt, StatementTxt: aString;
  line, statement: aFloat;
  i, foundLine: Integer;
  Found: TPoint;
Begin

  GotoWindow := SP_TextRequester.Create;
  GotoWindow.Open('GO TO line or label', '', tkLineStatement, True, Error);

  i := 1;
  Found.y := -1;

  If Pos(':', FPGotoText) > 0 Then Begin
    LineTxt := Copy(FPGotoText, 1, Pos(':', FPGotoText) -1);
    StatementTxt := Copy(FPGotoText, Pos(':', FPGotoText) +1);
  End Else Begin
    LineTxt := FPGotoText;
    StatementTxt := '1';
  End;

  If LineTxt <> '' Then Begin

    l := SP_FPExecuteAnyExpression(LineTxt, Error);
    If Error.Code = SP_ERR_OK Then
      s := SP_FPExecuteAnyExpression(StatementTxt, Error);

    b := (Error.Code = SP_ERR_OK) and SP_GetNumber(l, i, line, True);
    i := 1;
    b := b And SP_GetNumber(s, i, statement, True);

    If Not b Then Begin
      // Use component NavigateTo for label search
      b := FPBASICEditor.NavigateTo('@' + FPGotoText, foundLine);
      If b Then Begin
        Line      := foundLine;
        Statement := 1;
      End;

    End;

    If b Then
      SP_FPGotoLine(Trunc(line), Trunc(Statement));

  End;

End;

Procedure StartFindOp(Find: Boolean);
Begin
  If Not Assigned(FPBASICEditor) Then Exit;
  SP_FindReplace.Create.Open(Find, FPBASICEditor);
  FPShowingSearchResults := FPBASICEditor.HasFindResults;
End;

Procedure FindNext(jumpNext: Boolean);
Begin
  If Not Assigned(FPBASICEditor) Then Exit;
  If Not FPBASICEditor.HasFindResults Then Exit;
  FPBASICEditor.BASICFindNext(soForward In FPSearchOptions);
  FPShowingSearchResults := FPBASICEditor.HasFindResults;
End;

Function SP_CheckProgram(OnlyErrors: Boolean = False): Boolean;
Var
  Idx: Integer;
  HasDirty, HasErrors: Boolean;
Label
  ErrorCheck;
Begin

  ErrorCheck:

  HasErrors := False;
  HasDirty := False;
  For Idx := 0 To Listing.Count -1 Do Begin

    HasErrors := HasErrors or (Listing.Flags[Idx].State in [spLineError, spLineDuplicate]);

    If Listing.Flags[Idx].State in [spLineDirty] Then Begin
      AddCompileLine(Idx);
      HasDirty := True;
    End;

    If HasErrors Then
      Break;
  End;

  if Not OnlyErrors Then
    If HasDirty Then Begin
      CB_YIELD(10);
      Goto ErrorCheck;
    End;

  Result := Not HasErrors;

End;

Procedure SP_ShowError(Code, Line, Pos: Integer);
Var
  Error: TSP_ErrorCode;
Begin

  If FPWindowID >= 0 Then
    SP_CloseEditorWindows;

  Error.Code := Code;
  Error.Line := Line;
  Error.Statement := 1;
  PROGSTATE := SP_PR_STOP;
  SP_FPEditorError(Error, Line);
  SP_CreateEditorWindows;
  COVER := 0;
  T_OVER := 0;

End;

Procedure SP_FPSetDisplayColours;
Begin

  // Editor syntax highlighting colours.
  // IMPORTANT: The following are STRINGS, and are 3 (or more) sets of 5 BYTES. No more, no less.

  // #16 - INK
  // #17 - PAPER
  // #26 - ITALIC 0/1
  // #27 - BOLD 0/1

  // The four bytes following are a 32bit integer -
  // #7#0#0#0 is 7 - The first byte is the one you want to change.
  // In these examples, #26#0#0#0#0 will turn off ITALIC, #27#0#0#0#0 will turn off BOLD.
  // #26#1#0#0#0 will turn ITALIC on. etc.

  // #16#1#0#0#0 will make blue INK. #17#4#0#0#0 will make green PAPER.

  BackClr     := #17#7#0#0#0{#26#0#0#0#0#27#0#0#0#0};    // Background colour
  noClr       := #16#0#0#0#0#27#0#0#0#0#26#0#0#0#0;    // No highlight - black ink, no bold, no italic
  kwdClr      := #16#0#0#0#0#27#1#0#0#0#26#0#0#0#0;    // Keyword
  fnClr       := #16#0#0#0#0#27#1#0#0#0#26#0#0#0#0;    // Function
  numClr      := #16#1#0#0#0#26#0#0#0#0#27#0#0#0#0;    // Decimal number
  hexClr      := #16#1#0#0#0#26#0#0#0#0#27#0#0#0#0;    // Hex value
  binClr      := #16#1#0#0#0#26#0#0#0#0#27#0#0#0#0;    // Binary number
  baseClr     := #16#1#0#0#0#26#0#0#0#0#27#0#0#0#0;    // Arbitrary base number
  strClr      := #16#26#0#0#0#26#0#0#0#0#27#0#0#0#0;   // String literal
  nvClr       := #16#84#0#0#0#26#0#0#0#0#27#0#0#0#0;   // Numeric variable
  svClr       := #16#86#0#0#0#26#0#0#0#0#27#0#0#0#0;   // String variable
  remClr      := #16#26#0#0#0#26#1#0#0#0#27#0#0#0#0;   // remark or comment
  constClr    := #16#3#0#0#0#26#0#0#0#0#27#0#0#0#0;    // Constant
  symClr      := #16#0#0#0#0#26#0#0#0#0#27#0#0#0#0;    // Symbol (: , ; ' etc)
  LinClr      := #16#0#0#0#0#26#0#0#0#0#27#0#0#0#0;    // Line number
  relClr      := #16#0#0#0#0#26#0#0#0#0#27#0#0#0#0;    // Rel-op
  mathClr     := #16#0#0#0#0#26#0#0#0#0#27#0#0#0#0;    // Math op
  labClr      := #16#1#0#0#0#26#1#0#0#0#27#0#0#0#0;    // Label
  SelClr      := #17#5#0#0#0#26#8#0#0#0#27#8#0#0#0;    // Selected text colour
  SelUFClr    := #17#240#0#0#0#26#8#0#0#0#27#8#0#0#0;  // Selected text colour, unfocused
  SearchClr   := #17#208#0#0#0#26#8#0#0#0#27#8#0#0#0;  // Search term highlight
  NoSearchClr := #28#0#0#0#0#26#8#0#0#0#27#8#0#0#0;    // End of search term
  BraceHltClr := #17#6#0#0#0#26#8#0#0#0#27#8#0#0#0;    // Bracket highlight - applies to ()[]
  BraceClr    := #16#1#0#0#0#26#0#0#0#0#27#1#0#0#0;    // Bracket colour, no highlight

  // These are just numbers, corresponding to entries in the default palette

  lineClr     := 249;                                  // Line highlight colour
  gutterClr   := 246;                                  // Gutter background colour
  paperClr    := 7;                                    // Editor background colour
  proglineClr := 5;                                    // PROGLINE colour for highlighted lines
  proglineGtr := 35;                                   // Colour for PROGLINE's gutter
  lineErrClr  := 2;

  winBack     := 7;                                    // Default window background colour for dialogs etc
  capBack     := 228;                                  // Caption bar colour
  winBorder   := 0;                                    // Window border colour
  capText     := 15;                                   // Caption active text
  capInactive := 240;                                  // Caption inactive text
  gripClr     := 0;                                    // Text colour of the sizegrip for resizeable windows

  scrollback  := 7;                                    // Background colour of the scrollbar. Should be the same as the editor window background
  scrolltrack := 8;                                    // Colour of the "track" where the thumb sits
  scrollActive := 0;                                   // Colour of an active button
  scrollInactive := 8;                                 // Colour of a disabled button
  scrollThumb := 0;                                    // Colour of the scrollbar's "thumb" - the part you grab and move.

  debugPanel := 246;                                   // Colour of the debug panel's main list box
  debugCombo := 251;                                   // Colour of the debug panel's combobox
  debugNew   := 32;                                    // New variable in the debug panel
  debugChg   := 2;                                     // Changed variable in the debug panel

End;

// Debugging

Procedure SP_ToggleBreakPoint(Hidden: Boolean);
Begin

  // If editing, this toggles a breakpoint at the start of the current statement.
  // If in Direct mode, toggles a breakpoint at the first statement of PROGLINE

  If FocusedWindow = fwEditor Then
    EditorHost_ToggleBreakpoint
  Else
    SP_AddSourceBreakpoint(Hidden, PROGLINE, 1, 0, '');

End;

Function SP_IsSourceBreakPoint(Line, Statement: Integer): Boolean;
Var
  Idx: Integer;
Begin

  Idx := 0;
  Result := False;
  While Idx < Length(SP_SourceBreakpointList) Do
    If (SP_SourceBreakpointList[Idx].Line = Line) And (SP_SourceBreakpointList[Idx].Statement = Statement) And (SP_SourceBreakpointList[Idx].bpType <> BP_IsHidden) Then Begin
      Result := True;
      Exit;
    End Else
      Inc(Idx);

End;

Procedure SP_ResetConditionalBreakPoints;
Var
  i: Integer;
  res: aString;
  Error: TSP_ErrorCode;
Begin

  For i := 0 To Length(SP_ConditionalBreakPointList) -1 Do Begin
    SP_ConditionalBreakPointList[i].PassCount := SP_ConditionalBreakPointList[i].PassNum;
    res := SP_FPExecuteAnyExpression(SP_ConditionalBreakPointList[i].Compiled_Condition, Error);
    If Error.Code = SP_ERR_OK Then Begin
      SP_ConditionalBreakPointList[i].HasResult := True;
      SP_ConditionalBreakPointList[i].CurResult := res;
    End Else
      SP_ConditionalBreakPointList[i].HasResult := False;
  End;

End;

Procedure SP_PrepareBreakpoints(Create: Boolean);
Var
  i, j, l, Idx, stIdx, LineNum, Statement: Integer;
  Tokens: paString;
  Token: pToken;
Begin

  If Create Then Begin

    For i := 0 To Length(SP_SourceBreakpointList) -1 Do Begin

      LineNum := SP_SourceBreakpointList[i].Line;
      Statement := SP_SourceBreakpointList[i].Statement;

      Idx := SP_FindLine(LineNum, True);
      If Idx > -1 Then Begin
        Tokens := @SP_Program[Idx];
        stIdx := SP_FindStatement(Tokens, Statement);
        Token := @Tokens^[stIdx];
        Token^.BPIndex := i;
        SP_SourceBreakpointList[i].PassCount := SP_SourceBreakpointList[i].PassNum;
      End;

    End;

  End Else Begin

    // Also remove hidden breakpoints from the list.

    l := Length(SP_SourceBreakpointList);
    i := 0;
    While i < l Do Begin
      If SP_SourceBreakpointList[i].bpType = BP_IsHidden Then Begin
        For j := i To l -2 Do
          SP_SourceBreakpointList[j] := SP_SourceBreakpointList[j +1];
        Dec(l);
        SetLength(SP_SourceBreakpointList, l);
      End Else
        Inc(i);
    End;

  End;

  SP_GetDebugStatus(dbgBreakpoints);

End;

Procedure SP_SingleStep;
Var
  Info: TSP_iInfo;
  Inf: pSP_iInfo;
  Tokens: paString;
  Position, savedContline,
  savedContStatement: Integer;
  Error: TSP_ErrorCode;
  tStr: aString;
Label
  WasActuallyAnError;
Begin

  // Set the BPSIGNAL to true, so the first statement will be executed and then terminate back to the
  // editor. Also set STEPMODE so the interpreter knows not to stop with an error.          after step/step over/bp triggered, show continue statement as gray text in direct window

  SP_SwitchFocus(fwDirect);
  STEPMODE := SM_Single;
  SP_GetDebugStatus(MAXINT);

  Listing.CompleteUndo;
  If Assigned(CompilerThread) Then SP_StopCompiler;
  inf := @Info;
  Error.Code := SP_ERR_OK;
  Error.ReturnType := 0;
  Info.Error := @Error;

  PROGSTATE := SP_PR_RUN;
  SP_WaitForSync;

  tStr := '';
  // SP_PreParse - SP_ForceCompile - SP_InterpretCONTSafe clobbers CONTSTATEMENT
  // (the "safe" wrapper increments it as a side-effect of constant folding/AUTODIM).
  // Save and restore so the continuation point is intact when SP_Interpret_CONTINUE runs.
  savedContLine := CONTLINE;
  savedContStatement := CONTSTATEMENT;
  SP_Preparse(False, False, Error, tStr);
  CONTLINE      := savedContLine;
  CONTSTATEMENT := savedContStatement;
  SP_Interpret_CONTINUE(Inf);
  If Error.Code = SP_ERR_OK Then Begin
    Tokens := nil;
    Position := 0;
    BPSIGNAL := True;
    Error.ReturnType := 0;
    Error.Code := SP_ERR_OK;
    SP_SetDrawingWindow(FPEditorDefaultWindow);
    SP_ClearAllKeys;
    SP_Interpreter(Tokens, Position, Info.Error^, 0, True);
    SP_ClearAllKeys;
    FPEditorDefaultWindow := SCREENBANK;
    FPEditorDRPOSX := DRPOSX;
    FPEditorDRPOSY := DRPOSY;
    FPEditorPRPOSX := PRPOSX;
    FPEditorPRPOSY := PRPOSY;
    FPEditorOVER := COVER;
    FPEditorSaveFPS := FPS;
    FPEditorFRAME_MS := FRAME_MS;
    FPEditorMouseStatus := MOUSEVISIBLE;
    If STEPMODE > 0 Then
      If FocusedWindow = fwEditor then
        SP_SetDrawingWindow(FPWindowID)
      else
        SP_SetDrawingWindow(DWWindowID);
    SP_PrepareBreakpoints(False);
  End;
  STEPMODE := 0;
  SCREENLOCK := False;
  PROGSTATE := SP_PR_STOP;
  SYSTEMSTATE := SS_DIRECT;
  If CONTSTATEMENT = 0 Then
    Inc(CONTSTATEMENT);
  If (Error.Code <> SP_ERR_BREAKPOINT) And (Error.Code <> SP_ERR_OK) Then Begin
    WasActuallyAnError:
    If Error.Code = SP_ERR_STATEMENT_LOST Then Begin
      Error.Line := -2;
      Error.Statement := 0;
    End;
    If FPWindowID >= 0 Then SP_CloseEditorWindows;
    SP_FPEditorError(Error);
    SP_CreateEditorWindows;
  End Else Begin
    If (CONTLINE = -1) or (CONTLINE >= SP_Program_Count) or (SP_Program[CONTLINE] = '') Then
      Goto WasActuallyAnError;
    PROGLINE := pLongWord(@SP_Program[CONTLINE][2])^;
    If FPWindowID = -1 Then SP_CreateEditorWindows;
    EditorHost_SetExecLineWithScroll(pLongWord(@SP_Program[CONTLINE][2])^, CONTSTATEMENT);
  End;

  SP_Reset_Temp_Colours;
  SP_GetDebugStatus(dbgVariables or dbgWatches);
  SP_StartCompiler;

End;

Function SP_StepOver: Boolean;
Var
  line: TSP_GOSUB_Item;
Begin

  SP_SwitchFocus(fwDirect);
  STEPMODE := SM_StepOver;
  PROGSTATE := SP_PR_RUN;
  SP_WaitForSync;

  line := SP_ConvertLineStatement(CONTLINE, CONTSTATEMENT +1);
  If Line.Line >= 0 Then Begin
    SP_AddSourceBreakpoint(True, pLongWord(@SP_Program[line.Line][2])^, Line.St, 0, '');
    Result := True;
  End Else
    Result := False;
  SP_ClearAllKeys;
  SP_GetDebugStatus(dbgVariables or dbgWatches);

End;

Procedure SP_FPScrollToLine(Line, Statement: Integer);
Begin
  EditorHost_ScrollToLine(Line, Statement);
End;

Procedure SP_ClearBreakPoints;
Begin

  SP_PrepareBreakPoints(False);
  SetLength(SP_SourceBreakpointList, 0);
  SetLength(SP_ConditionalBreakpointList, 0);
  BPSIGNAL := False;
  STEPMODE := 0;
  SP_GetDebugStatus(dbgBreakpoints);

End;

Procedure SP_GetDebugStatus(StatType: Integer);
Begin

  DEBUGGING := (Length(SP_SourceBreakpointList) > 0) or (Length(SP_ConditionalBreakpointList) > 0) or (STEPMODE > 0);
  If (StatType = -1) or (FPDebugPanelVisible And (StatType And (1 Shl FPDebugCombo.ItemIndex) <> 0)) Then
    SP_FillDebugPanel;

End;

Procedure EvaluateHint(Var Result: SP_Hint);
Var
  Error: TSP_ErrorCode;
  tStr: aString;
Begin
  Error.Code := SP_ERR_OK;
  tStr := SP_FPExecuteAnyExpression(Result.Hint, Error);
  if (Error.Code = SP_ERR_OK) or (Error.Code = SP_ERR_MISSING_VAR) Then Begin
    if (tStr <> '') Then Begin
      If tStr <> Result.Hint Then
        Result.Hint := Result.Hint + '=' + #16#1#0#0#0 + InsertLiterals(tStr)
      Else Begin
        Result.Hint := '';
        Exit;
      End;
    End else
      Result.Hint := Result.Hint + ' ' + #16#2#0#0#0 + 'Not found';
  End Else
    If (Error.Code = SP_ERR_SYNTAX_ERROR) or SP_IsReserved(Upper(Result.Hint)) Then Begin
      Result.Hint := '';
      Exit;
    End Else
      Result.Hint := Result.Hint + '=' + #16#2#0#0#0 + ProcessErrorMessage(ErrorMessages[Error.Code]);
End;

Function ProcessHint(Var s: aString; cPos: Integer; var i, j: Integer): SP_Hint;
Var
  InString, CanREM, Found: Boolean;
  l, t, Idx, Idx2: Integer;
  nVar: pSP_NumVarContent;
  sVar: pSP_StrVarContent;
  NewWord, tStr: aString;
Const
  Seps = [' ', '(', ')', ',', ';', '"', #39, '=', '+', '-', '/', '*', '^', '|', '&', ':', '>', '<', '[', ']'];
Begin
  InString := False;
  Found := False;
  CanREM := True;
  s := s + ' ';

  i := 1;
  While i <= cPos Do Begin
    If s[i] = '"' Then Begin
      InString := Not InString;
      Inc(i);
    End Else
      If Not Instring Then Begin
        If s[i] = ':' Then Begin
          CanREM := True;
          Inc(i);
        End Else Begin
          NewWord := '';
          While (i <= Length(s)) and (s[i] in ['A'..'Z']) Do Begin
            NewWord := NewWord + s[i];
            Inc(i);
          End;
          If (NewWord = 'THEN') or (NewWord = 'ELSE') Then
            CanREM := True
          Else
            If CanREM and (NewWord = 'REM') Then
              Exit;
          If NewWord = '' Then
            Inc(i);
        End;
      End Else
        Inc(i);
  End;

  If Not InString Then Begin
    i := cPos;
    l := Length(s);
    While (i > 1) And (s[i] in Seps) Do Dec(i);
    While (i > 1) And Not (s[i] in Seps) Do Dec(i);
    If (i <= l) And (s[i] in Seps) Then Inc(i);
    j := i;
    While (j <= l) And Not (s[j] in Seps) Do Inc(j);
    If (j <= l) and (s[j] = '$') Then Inc(j);
    Result.Hint := Copy(s, i, j - i);

    If Result.Hint <> '' Then Begin
      t := SP_IsConstant(Result.Hint);
      if t >= 0 Then Begin
        Result.Hint := #16#1#0#0#0 + AFloatToStr(SP_Constants[t].Value);
      End Else Begin
        If Result.Hint[1] = '@' Then Begin
          SP_FPUpdatePoIList;
          For Idx := 0 To Length(FPPoIList) -1 Do
            If (FPPoIList[Idx].PoI_Type = PoI_Label) And (FPPoIList[Idx].Name = Copy(Result.Hint, 2)) Then Begin
              Found := True;
              Result.Hint := Result.Hint + ' (' + IntToString(SP_GetLineNumberFromIndex(FPPoIList[Idx].Line)) + ':' + IntToString(FPPoIList[Idx].Statement) + ')';
              Break;
            End;
        End Else
          If Result.Hint[Length(Result.Hint)] = '$' Then Begin
            Idx := SP_FindStrArray(Lower(Copy(Result.Hint, 1, Length(Result.Hint) -1)));
            Idx2 := SP_FindStrVar(Lower(Copy(Result.Hint, 1, Length(Result.Hint) -1)));
            If ((Idx > -1) And (s[j] = '(')) or ((Idx > -1) And (Idx2 = -1) And (s[j] <> '(')) Then Begin
              Found := True;
              Result.Hint := Result.Hint + '(';
              For Idx2 := 0 To StrArrays[Idx].NumIndices -1 Do Begin
                Result.Hint := Result.Hint + IntToString(StrArrays[Idx].Indices[Idx2]);
                If Idx2 < StrArrays[Idx].NumIndices -1 Then
                  Result.Hint := Result.Hint + ',';
              End;
              Result.Hint := Result.Hint + ')=' + InsertLiterals(SP_StrArrayToString(Idx, -1));
            End Else Begin
              Idx := SP_FindStrVar(Lower(Copy(Result.Hint, 1, Length(Result.Hint) -1)));
              If Idx > -1 Then Begin
                Found := True;
                Result.Hint := '';
                sVar := StrVars[Idx]^.ContentPtr;
                If StrVars[Idx]^.ProcVar Then
                  For Idx2 := SP_ProcStackPtr DownTo 0 Do
                    If Idx >= SP_ProcStack[Idx2].VarPosS Then Begin
                      Result.Hint := '['+SP_ProcsList[SP_ProcStack[Idx2].ProcIndex].Name+']' + #13;
                      Break;
                    End;
                tStr := sVar^.Value;
                Result.Hint := Result.Hint + StrVars[Idx]^.Name + '$="' + InsertLiterals(tStr);
                Result.Hint := Result.Hint + '"';
              End;
            End;
          End Else Begin
            Idx := SP_FindNumVar(Lower(Result.Hint));
            If (Idx > -1) And (s[j] <> '(') Then Begin
              Found := True;
              Result.Hint := '';
              nVar := NumVars[Idx]^.ContentPtr;
              If NumVars[Idx]^.ProcVar Then
                For Idx2 := SP_ProcStackPtr DownTo 0 Do
                  If Idx >= SP_ProcStack[Idx2].VarPosN Then Begin
                    Result.Hint := '['+SP_ProcsList[SP_ProcStack[Idx2].ProcIndex].Name+']' + #13;
                    Break;
                  End;
              Result.Hint := Result.Hint + NumVars[Idx]^.Name + '=';
              If nVar^.VarType = SP_FORVAR Then Begin
                Result.Hint := Result.Hint + aString(aFloatToStr(nVar^.Value) + ', FOR ' + aFloatToStr(nVar^.InitVal) + ' TO ' + aFloatToStr(nVar^.EndAt));
                If nVar^.Step <> 1 Then
                  Result.Hint := Result.Hint + ' STEP ' + aString(aFloatToStr(nVar^.Step));
                If (nVar^.LoopLine >= 0) And (nVar^.LoopLine < SP_Program_Count) Then
                  Result.Hint := Result.Hint + ', NEXT at ' + IntToString(pInteger(@SP_Program[nVar^.LoopLine][2])^) + ':' + IntToString(nVar^.St)
                Else
                  Result.Hint := Result.Hint + ', NEXT Statement lost';
              End Else
                Result.Hint := Result.Hint + aString(aFloatToStr(nVar^.Value));
            End Else Begin
              Idx := SP_FindNumArray(Lower(Result.Hint));
              If Idx > -1 Then Begin
                Found := True;
                Result.Hint := Result.Hint + '(';
                For Idx2 := 0 To NumArrays[Idx].NumIndices -1 Do Begin
                  Result.Hint := Result.Hint + IntToString(NumArrays[Idx].Indices[Idx2]);
                  If Idx2 < NumArrays[Idx].NumIndices -1 Then
                    Result.Hint := Result.Hint + ',';
                End;
                Result.Hint := Result.Hint + ')=' + SP_NumArrayToString(Idx, -1);
              End;
            End;
          End;

        If Not Found Then Begin
          SP_FPUpdatePoIList;
          For Idx := 0 To Length(FPPoIList) -1 Do Begin
            tStr := FPPoIList[Idx].Name;
            If Pos('(', tStr) > 0 Then
              tStr := Copy(tStr, 1, Pos('(', tStr) -1);
            If (FPPoIList[Idx].PoI_Type in [PoI_Proc, PoI_Fn]) And (tStr = Result.Hint) Then Begin
              Found := True;
              Result.Hint := FPPoIList[Idx].Name + ' [' + IntToString(SP_GetLineNumberFromIndex(FPPoIList[Idx].Line)) + ':' + IntToString(FPPoIList[Idx].Statement) + ']';
              Break;
            End;
          End;
          If Not Found Then Begin
            If i > 1 Then
              if s[i-1] in ['%', '$'] Then
                Result.Hint := s[i-1] + Result.Hint;
            EvaluateHint(Result);
          End;
        End;

      End;

    End;

  End;

End;

Initialization

  BSize := 8;

end.
