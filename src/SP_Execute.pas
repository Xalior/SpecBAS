unit SP_Execute;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}
{$INCLUDE SpecBAS.inc}

interface

Uses SP_Util, SP_Errors;

  Function  SP_FPExecuteNumericExpression(Const Expr: aString; var Error: TSP_ErrorCode): aFloat;
  Function  SP_FPExecuteStringExpression(Const Expr: aString; var Error: TSP_ErrorCode): aString;
  Function  SP_FPExecuteAnyExpression(Const Expr: aString; var Error: TSP_ErrorCode): aString;
  Procedure SP_FPExecuteExpression(Const Expr: aString; var Error: TSP_ErrorCode);
  Function  SP_FPCheckExpression(Const Expr: aString; var Error: TSP_ErrorCode): Boolean;

implementation

Uses {$IFNDEF RUNTIMEONLY}SP_FPEditor,{$ENDIF} SP_PreRun, SP_Graphics, SP_Sysvars, SP_InfixToPostFix, SP_Interpret_PostFix, SP_Tokenise;

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
  {$IFNDEF RUNTIMEONLY}
  SP_SetDrawingWindow(FPEditorDefaultWindow);
  {$ENDIF}
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

end.
