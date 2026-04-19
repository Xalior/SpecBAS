unit SP_Compiler;

// Deals with the compiler thread and listing management

{$INCLUDE SpecBAS.inc}

interface

Uses Types, Classes;

Type

  TCompilerThread = Class(TThread)
    Finish, CompilerBusy: Boolean;
    Procedure Execute; Override;
  End;

  Procedure SetAllToCompile;
  Procedure SP_ForceCompile;
  Procedure SP_StartCompiler;
  Procedure SP_StopCompiler;
  Procedure AddCompileLine(Line: Integer; ScanForDuplicates: Boolean = True);
  Procedure RemoveCompileLine(Line: Integer);
  Procedure SP_MarkAsDirty(Idx: Integer);
  Procedure SP_MarkWholeProgramDirty;

implementation

Uses SysUtils, SyncObjs, SP_AnsiStringlist, Math, SP_Main, SP_FPEditor, SP_InfixToPostFix, SP_Tokenise, SP_Errors, SP_SysVars, SP_Util,
     SP_BASICEditorHostUnit;

Procedure SetAllToCompile;
Var
  i: Integer;
Begin
  MaxCompileLines := -1;
  for i := 0 To Listing.Count -1 do
    If SP_LineHasNumber(i) <> 0 Then
      AddCompileLine(i);
End;

Procedure SP_ForceCompile;
Var
  s, s2:    aString;
  Idx, lIdx, i: Integer;
  InString: Boolean;
  Error:    TSP_ErrorCode;
Begin
  Idx := 0;
  SP_Program_Clear;

  If Assigned(Listing) Then
    While Idx < Listing.Count Do Begin
      lIdx := Idx;   // remember the numbered-line row
      s := Listing[Idx];
      Inc(Idx);
      InString := False;
      If s <> '' Then
        For i := 1 To Length(s) Do
          If s[i] = '"' Then InString := Not InString;
      While (Idx < Listing.Count) And (SP_LineHasNumber(Idx) = 0) Do Begin
        s2 := Listing[Idx];
        If (s <> '') And (s2 <> '') And Not InString Then
          s := s + ' ' + s2
        Else
          s := s + s2;
        If s2 <> '' Then
          For i := 1 To Length(s2) Do
            If s2[i] = '"' Then InString := Not InString;
        Inc(Idx);
      End;
      s := SP_TokeniseLine(s, False, True) + SP_TERMINAL_SEQUENCE;
      If s <> SP_TERMINAL_SEQUENCE Then Begin
        SP_Convert_ToPostFix(s, Error.Position, Error);
        If Error.Code = SP_ERR_OK Then Begin
          SP_Store_Line(s);
          // *** FIX: update the Listing flag to match, so the background
          // compiler thread sees spLineOk and skips recompiling this line,
          // preventing a race-condition duplicate that produces a false
          // spLineDuplicate (blue blob) on the last line.
          If lIdx < Listing.Count Then
            Listing.Flags[lIdx].State := spLineOk;
        End Else Begin
          If lIdx < Listing.Count Then
            Listing.Flags[lIdx].State := spLineError;
        End;
      End Else Begin
        // Empty/whitespace-only line - clear dirty flag.
        If lIdx < Listing.Count Then
          Listing.Flags[lIdx].State := spLineNull;
      End;
    End;

  // Now that Listing flags reflect the actual compile results, tell the
  // editor component to repaint its gutter blobs.
  EditorHost_RefreshLineStates;
End;

Procedure SP_MarkAsDirty(Idx: Integer);
Begin

  // Marks a line in the text editor as dirty - i.e, changed and needing to be syntax checked and compiled.
  // The compiler thread will pick this up.

  While (Idx > 0) And (SP_LineHasNumber(Idx) = 0) Do Dec(Idx);
  Listing.Flags[Idx].State := spLineDirty;
  AddCompileLine(Idx);

End;

Procedure SP_MarkWholeProgramDirty;
Var
  Idx: Integer;
Begin

  Idx := 0;
  While Idx < Listing.Count Do Begin
    If SP_LineHasNumber(Idx) > 0 Then
      SP_MarkAsDirty(Idx);
    Inc(Idx);
  End;

End;

Procedure AddCompileLine(Line: Integer; ScanForDuplicates: Boolean = True);
Var
  i: Integer;
Begin
  i := Line;
  While (i > 0) And (SP_lineHasNumber(i) = 0) Do Dec(i);
  if i >= 0 Then Begin
    Line := i;
    Listing.Flags[Line].State := spLineDirty;
    if MaxCompileLines >= 0 Then
      For i := 0 to MaxCompileLines Do
        If CompileList[i] = Line Then
          Exit;
    Inc(MaxCompileLines);
    If MaxCompileLines >= Length(CompileList) Then
      SetLength(CompileList, Length(CompileList) + 1000);
    CompileList[MaxCompileLines] := Line;
    If ScanForDuplicates Then Begin
      For i := 0 To Listing.Count -1 Do
        if Listing.Flags[i].State = spLineDuplicate Then
          AddCompileLine(i, False);
    End;
  End;
End;

Procedure RemoveCompileLine(Line: Integer);
Var
  i, j: Integer;
Begin
  For i := 0 To MaxCompileLines Do
    If CompileList[i] = Line Then Begin
      For j := i To MaxCompileLines -1 Do
        CompileList[j] := CompileList[j +1];
      Dec(MaxCompileLines);
      Exit;
    End;
End;

Procedure SP_StopCompiler;
Begin

  If Assigned(CompilerThread) Then Begin
    CompilerThread.Finish := True;
    Repeat
      CB_YIELD(1);
    Until Not CompilerRunning;
    CompilerThread := nil;
  End;

End;

Procedure SP_StartCompiler;
Begin

  If Not Assigned(CompilerThread) then
    CompilerThread := TCompilerThread.Create(False);

End;

Procedure TCompilerThread.Execute;
Var
  s, t, Compiled: aString;
  Idx, lIdx, i: Integer;
  Error: TSP_ErrorCode;
  InString: Boolean;
Begin

  NameThreadForDebugging('Compiler Thread');
  Priority := tpIdle;
  Idx := Listing.Count;
  CompilerRunning := True;
  CompilerBusy := False;
  Finish := False;
  FreeOnTerminate := True;

  While Not (QUITMSG or Finish) Do Begin

    CompilerBusy := False;
    If MaxCompileLines > -1 Then Begin
      If CompilerLock.TryEnter Then Begin
        If Listing.Flags[CompileList[0]].State in [spLineError, spLineDirty, spLineduplicate] Then Begin
          CompilerBusy := True;
          Idx := CompileList[0]
        End;
        RemoveCompileLine(CompileList[0]);
        CompilerLock.Leave;
      End;
    End Else
      Sleep(20);

    While Not (Finish or QUITMSG) And CompilerBusy Do Begin

      // Get the line we want to compile.

      If CompilerLock.TryEnter Then Begin

        If Listing.Flags[Idx].State in [spLineDirty, spLineDuplicate] Then Begin

          lIdx := Idx;
          InString := False;
          While (Idx > 0) And (SP_LineHasNumber(Idx) = 0) Do Dec(Idx);
          s := Listing[Idx];
          For i := 1 To Length(s) Do
            If s[i] = '"' Then
              InString := not InString;
          Inc(Idx);

          While (Idx < Listing.Count) And (SP_LineHasNumber(Idx) = 0) Do Begin
            t := Listing[Idx];
            For i := 1 To Length(t) Do
              If t[i] = '"' Then
                InString := not InString;
            If Not InString Then
              t := ' ' + t;
            s := s + t;
            Inc(Idx);
          End;

          If s <> '' Then Begin

            // Check its syntax and compile it.

            Compiled := SP_TokeniseLine(s, False, True) + SP_TERMINAL_SEQUENCE;
            SP_Convert_ToPostFix(Compiled, Error.Position, Error);

            If Compiled <> SP_TERMINAL_SEQUENCE Then
              If Byte(Compiled[1]) <> SP_LINE_NUM Then
                Error.Code := SP_ERR_SYNTAX_ERROR;

            If Error.Code = SP_ERR_OK Then Begin

              If (lIdx < Listing.Count) Then Begin
                If SP_CheckForConflict(lIdx) Then
                  Listing.Flags[lIdx].State := spLineDuplicate
                Else Begin
                  Listing.Flags[lIdx].State := spLineOk;
                  SP_Store_Line(Compiled);
                End;
                EditorHost_RefreshLineStates;
              End;

            End Else Begin

              // An error in compilation. Set this listing line's flags as containing an error - the listing display routines
              // will pick it up.

              If lIdx < Listing.Count Then Begin
                Listing.Flags[lIdx].State := spLineError;
                EditorHost_RefreshLineStates;
              End;

            End;

          End Else Begin

            Idx := lIdx;
            While (Idx < Listing.Count) And (SP_LineHasNumber(Idx) = 0) Do Begin
              If Listing.Flags[Idx].State = spLineDirty Then Begin
                Listing.Flags[Idx].State := spLineNull;
              End;
              Inc(Idx);
            End;

          End;

        End;

        CompilerBusy := False;
        CompilerLock.Leave;

      End;

    End;

  End;

  SP_FinalizeThreadVars;
  CompilerRunning := False;

End;


end.
