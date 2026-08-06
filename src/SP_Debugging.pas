unit SP_Debugging;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}
{$INCLUDE SpecBAS.inc}

interface

Uses SP_Util;

Type

  TSP_WatchInfo = Packed Record
    Expression,
    Compiled_Expression: aString;
  End;

  TSP_BreakpointInfo = Packed Record
    bpType: Integer;
    PassCount, PassNum: Integer;
    Condition: aString;
    Compiled_Condition: aString;
    CurResult: aString;
    HasResult: Boolean;
    Line, Statement: Integer;
  End;
  pSP_BreakPointInfo = ^TSP_BreakPointInfo;

  Procedure SP_AddWatch(Index: Integer; Expr: aString);
  Procedure SP_DeleteWatch(Index: Integer);
  Function  SP_BreakPointExists(Line, Statement: Integer): Boolean;
  Procedure SP_AddSourceBreakPoint(Hidden: Boolean; Line, Statement, Passes: Integer; Condition: aString);
  Procedure SP_AddConditionalBreakpoint(BpIndex, Passes: Integer; Condition: aString; IsData: Boolean);
  Procedure SP_ToggleBreakPoint(Hidden: Boolean);
  Procedure SP_ResetConditionalBreakPoints;
  Procedure SP_PrepareBreakpoints(Create: Boolean);
  Function  SP_IsSourceBreakPoint(Line, Statement: Integer): Boolean;
  Procedure SP_SingleStep;
  Function  SP_StepOver: Boolean;
  Procedure SP_ClearBreakPoints;
  Procedure SP_GetDebugStatus(StatType: Integer);

Const

  SM_None     = 0;
  SM_NoError  = 1;
  SM_Single   = 2;
  SM_StepOver = 3;

  BP_Stop         = 1; // The program will stop if a token has this in its flags member and return to the editor paused.
  BP_IsHidden     = 2; // When stopped, if this bit is set in the flags member then it won't show up in the editor (used for single step and run-to).
  BP_Conditional  = 3; // Will trigger when condition is true.
  BP_Data         = 4; // Will trigger if the stored expression result changes.

Var

  SP_SourceBreakpointList,
  SP_ConditionalBreakPointList: Array of TSP_BreakpointInfo;
  SP_WatchList: Array of TSP_WatchInfo;

implementation

Uses SP_SysVars, SP_Errors, SP_Tokenise, SP_InfixToPostFix, SP_Interpret_PostFix, SP_PreRun, SP_DebugPanel, SP_Execute, SP_Compiler,
     SP_BASICEditorHostUnit, SP_FPEditor, SP_Graphics, SP_Main, SP_Input;

Procedure SP_GetDebugStatus(StatType: Integer);
Begin

  DEBUGGING := (Length(SP_SourceBreakpointList) > 0) or (Length(SP_ConditionalBreakpointList) > 0) or (STEPMODE > 0);
  If (StatType = -1) or (FPDebugPanelVisible And (StatType And (1 Shl FPDebugCombo.ItemIndex) <> 0)) Then
    SP_FillDebugPanel;

End;

Procedure SP_AddWatch(Index: Integer; Expr: aString);
Var
  s: aString;
  l: Integer;
  Error: TSP_ErrorCode;
  change: Boolean;
Begin

  // Add a new watch (if Index is -1) or replace an existing watch.

  l := Length(SP_WatchList);
  If Index = -1 Then Begin
    SetLength(SP_WatchList, l+1);
    Index := l;
  End;

  With SP_WatchList[Index] Do Begin
    Expression := Expr;
    Error.Position := 1;
    Error.Code := SP_ERR_OK;
    s := SP_TokeniseLine(Expression, True, False) + #255;
    s := SP_Convert_Expr(s, Error.Position, Error, -1) + #255;
    SP_RemoveBlocks(s);
    SP_TestConsts(s, 1, Error, False, change);
    SP_AddHandlers(s);
    Compiled_Expression := #$F + s;
  End;

End;

Procedure SP_DeleteWatch(Index: Integer);
Var
  i, l: Integer;
Begin

  l := Length(SP_WatchList);
  For i := Index To l -2 Do
    SP_WatchList[i] := SP_WatchList[i +1];
  SetLength(SP_WatchList, l -1);

End;

Function  SP_BreakPointExists(Line, Statement: Integer): Boolean;
Var
  l, i: Integer;
Begin
  Result := False;
  l := Length(SP_SourceBreakPointList);
  For i := 0 To l -1 Do
    If (SP_SourceBreakPointList[i].Line = Line) And (SP_SourceBreakPointList[i].Statement = Statement) Then Begin
      Result := True;
      Break;
    End;
End;

Procedure SP_AddSourceBreakPoint(Hidden: Boolean; Line, Statement, Passes: Integer; Condition: aString);
Var
  s: aString;
  i, l: Integer;
  Error: TSP_ErrorCode;
  Found, isHidden, change: Boolean;
Begin

  // Toggles a breakpoint in the internal list used during pre-parsing.
  // If not in the list, it's added.
  // If it's in the list and the Hidden property is different, then the hidden property is flipped.
  // Otherwise, it's removed.

  Found := False;
  l := Length(SP_SourceBreakPointList);
  For i := 0 To l -1 Do
    If (SP_SourceBreakPointList[i].Line = Line) And (SP_SourceBreakPointList[i].Statement = Statement) Then Begin
      Found := True;
      Break;
    End;

  If not Found Then Begin
    SetLength(SP_SourceBreakPointList, l +1);
    SP_SourceBreakPointList[l].bpType := Ord(Hidden) +1;
    SP_SourceBreakPointList[l].Line := Line;
    SP_SourceBreakPointList[l].Statement := Statement;
    i := l;
  End Else Begin
    If Not Hidden Then Begin
      // User breakpoint. If there's a hidden BP here, make it Shown, otherwise delete it.
      isHidden := SP_SourceBreakPointList[i].bpType = BP_IsHidden;
      If isHidden Then
        SP_SourceBreakPointList[i].bpType := BP_Stop
      Else Begin
        For i := i To l -2 Do
          SP_SourceBreakPointList[i] := SP_SourceBreakPointList[i +1];
        SetLength(SP_SourceBreakPointList, l -1);
        SP_GetDebugStatus(dbgBreakpoints);
        Exit;
      End;
    End; // A breakpoint here should remain, so do nothing.
  End;

  // If we get here, the breakpoint is active. Set up the condition evaluation.

  Error.Position := 1;
  Error.Code := SP_ERR_OK;
  s := SP_TokeniseLine(Condition, True, False) + #255;
  s := SP_Convert_Expr(s, Error.Position, Error, -1) + #255;
  SP_RemoveBlocks(s);
  SP_TestConsts(s, 1, Error, False, change);
  SP_AddHandlers(s);

  SP_SourceBreakPointList[i].PassNum := Passes;
  SP_SourceBreakPointList[i].Condition := Condition;
  SP_SourceBreakPointList[i].Compiled_Condition := #$F + s;

  SP_GetDebugStatus(dbgBreakpoints);

End;

Procedure SP_AddConditionalBreakpoint(BpIndex, Passes: Integer; Condition: aString; IsData: Boolean);
Var
  l: Integer;
  s: aString;
  Error: TSP_ErrorCode;
  change: Boolean;
Begin

  // Adds a conditional breakpoint to the current list of breakpoints.
  // No line or statement associated with this breakpoint, it's evaluated after every
  // statement.

  // VERY SLOW, use sparingly!

  If BpIndex = -1 Then Begin
    // New breakpoint, add to the list
    l := Length(SP_ConditionalBreakpointList);
    SetLength(SP_ConditionalBreakpointList, l +1);
  End Else Begin
    // Edit an existing breakpoint
    l := BPIndex;
  End;

  Error.Position := 1;
  Error.Code := SP_ERR_OK;
  s := SP_TokeniseLine(Condition, True, False) + #255;
  s := SP_Convert_Expr(s, Error.Position, Error, -1) + #255;
  SP_RemoveBlocks(s);
  SP_TestConsts(s, 1, Error, False, change);
  SP_AddHandlers(s);

  If IsData Then
    SP_ConditionalBreakPointList[l].bpType := BP_Data
  Else
    SP_ConditionalBreakPointList[l].bpType := BP_Conditional;
  SP_ConditionalBreakPointList[l].Condition := Condition;
  SP_ConditionalBreakPointList[l].PassNum := Passes;
  SP_ConditionalBreakPointList[l].Compiled_Condition := #$F + s;
  SP_ConditionalBreakPointList[l].CurResult := '';
  SP_ConditionalBreakPointList[l].HasResult := False;

  SP_GetDebugStatus(dbgBreakpoints);

End;

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

Procedure SP_ClearBreakPoints;
Begin

  SP_PrepareBreakPoints(False);
  SetLength(SP_SourceBreakpointList, 0);
  SetLength(SP_ConditionalBreakpointList, 0);
  BPSIGNAL := False;
  STEPMODE := 0;
  SP_GetDebugStatus(dbgBreakpoints);

End;

end.
