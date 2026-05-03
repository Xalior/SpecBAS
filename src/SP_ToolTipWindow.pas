unit SP_ToolTipWindow;

{$INCLUDE SpecBAS.inc}

interface

Uses SyncObjs, Types, SP_BaseComponentUnit, SP_Components, SP_SysVars, SP_Util;

Type

  SP_TipProcs = Class
  Public
    Class Procedure OnTipTimer(event: Pointer);
  End;

  SP_Hint = Record
    Hint: aString;
    HotRect: TRect;
    x, y, w, h: Integer;
  End;

Procedure OpenTipWindow(Var Hint: SP_Hint);
Procedure CheckForTip(X, Y: Integer);
Procedure CloseTipWindow;

Var

  TipWindowID: Integer;
  TipWindowActive: Boolean = False;
  TipComponent: SP_BaseComponent;
  TipTimerID: Integer;
  TipMouseX, TipMouseY: Integer;
  TipHotRect: TRect;
  TipDelay: NativeUInt;
  TipEvent: pSP_TimerEvent;
  TipBkClr, TipOutline: Integer;
  CurHint: SP_Hint;

implementation

Uses Math, SP_Main, SP_BankFiling, SP_FPEditor, SP_Graphics, SP_Graphics32, SP_BankManager, SP_Errors, SP_BASICEditorUnit, SP_BASICEditorHostUnit;

Procedure CheckForTip(X, Y: Integer);
Begin

  // test to see if a hint window should be opened
  If TipWindowID = -1 Then Begin
    If ((X <> TipMouseX) or (Y <> TipMouseY)) And (TipTimerID >= 0) Then Begin
      TimerSection.Enter;
      TipEvent := FindTimerByID(TipTimerID);
      If Assigned(TipEvent) Then
        TipEvent.NextFrameTime := Integer(FRAMES) + TipDelay;
      TimerSection.Leave;
    End;
    If TipTimerID = -1 Then Begin
      TipEvent := AddTimer(Nil, TipDelay, SP_TipProcs.OnTipTimer, False, True);
      TipTimerID := TipEvent^.ID;
    End;
    TipMouseX := X;
    TipMouseY := Y;
  End Else
    If Not PtInRect(TipHotRect, Point(X, Y)) then
      CloseTipWindow;
End;

Procedure FormatTip(var Tip: aString);
Var
  c: aChar;
  i, cnt, dw, h, LastSep, LastBreakAt: Integer;
Const
  Seps = [' ', '(', ')', ',', ';', '"', #39, '=', '+', '-', '/', '*', '^', '|', '&', ':', '>', '<'];
Begin

  // Inserts #13 chars into a string ready for displaying as a tooltip.

  dw := (DISPLAYWIDTH Div fpfW) - 10;

  i := 1;
  h := 1;
  cnt := 0;
  LastSep := 1;
  While i <= Length(Tip) Do Begin
    c := Tip[i];
    Case Ord(c) of
        5: // Literal char follows
          Begin
            Inc(Cnt);
            Inc(i, 2);
          End;
        6, 8, 9, 10, 11: // PRINT comma, Cursor moves
          Begin
            Inc(i);
          End;
        13: // Carriage return
          Begin
            Inc(h);
            Inc(i);
            LastSep := i;
            cnt := 0;
          End;
       16, 17, 18, 19, 20, 23, 26, 27:
          Begin
            Inc(i, 1 + SizeOf(LongWord));
          End;
       21, 22:
          Begin
            Inc(i, 1 + (SizeOf(LongWord) * 2));
          End;
       25:
          Begin
            Inc(i, 1 + (SizeOf(aFloat) * 2));
          End;
        Else
          Begin
            If (c In Seps) And Not (c in ['(', ')', '-']) Then LastSep := i;
            Inc(cnt);
            Inc(i);
          End;
    End;
    If cnt >= dw Then Begin
      If i - LastSep < 10 Then i := LastSep;
      LastBreakAt := i +1;
      Tip := Copy(Tip, 1, i -1) + #13 + Copy(Tip, i);
      Inc(i);
      Inc(h);
      If h > 10 Then Begin
        If cnt >= dw Then Begin
          i := LastBreakAt;
          While cnt > 3 Do Begin
            c := Tip[i];
            Case Ord(c) of
              5: Begin Inc(i, 2); Dec(cnt); End;
              6, 8, 9, 10, 11: Inc(i);
              16..20, 23, 26, 27: Inc(i, 1 + SizeOf(LongWord));
              21, 22: Inc(i, 1 + (SizeOf(LongWord) * 2));
              25: Inc(i, 1 + (SizeOf(aFloat) * 2));
            Else
              Begin
                Inc(i);
                Dec(cnt);
              End;
            End;
          End;
        End;
        Tip := Copy(Tip, 1, i) + '...';
        Exit;
      End;
      cnt := 0;
    End;
  End;

End;

Procedure OpenTipWindow(Var Hint: SP_Hint);
Var
  Str: aString;
  Error: TSP_ErrorCode;
  hw, hh, Font: Integer;
  Window: pSP_Window_Info;
  cX1, cY1, cX2, cY2, DR_Window, DefaultWindow: Integer;
Begin

  If TipWindowID <> -1 Then CloseTipWindow;

  Font := FONTBANKID;
  SP_SetSystemFont(EDITORFONT, Error);
  DR_Window := SCREENBANK;
  T_SCALEX := EdFontScaleX;
  T_SCALEY := EdFontScaleY;
  T_PAPER := TipBkClr;
  FormatTip(Hint.Hint);
  Str := SP_StringToTexture(#16#0#0#0#0#17#223#0#0#0 + Hint.Hint, True);
  If Str <> '' Then Begin
    hw := pInteger(@Str[1])^ + 4;
    hh := pInteger(@Str[1 + SizeOf(LongWord)])^ + 4;
    if Hint.x + hw > DISPLAYWIDTH - FpfW Then
      Hint.x := DISPLAYWIDTH - (hw + FPFw);
    if Hint.y + hh > DISPLAYHEIGHT - FPfH Then Begin
      Hint.y := DISPLAYHEIGHT - (hh + FPFh);
      If IntersectRect(Hint.HotRect, Rect(Hint.x, Hint.y, Hint.x+hw, Hint.y+hh)) Then
        Hint.y := Max(FPFh, Hint.HotRect.Top - (hh + (FPFh Div 4)));
    End;
    Hint.w := hw; Hint.h := hh;
    TipWindowActive := True;
    DefaultWindow := FocusedWindow;
    TipWindowID := SP_Add_Window(hint.x, hint.y, hw, hh, $FFFF, 8, 0, Error);
    SP_SetPalette(0, DefaultPalette);
    SP_GetWindowDetails(TipWindowID, Window, Error);
    SP_SetWindowShadow(TipWindowID, True, 6, 10);
    SP_FillRect(0, 0, hw, hh, TipBkClr);
    SP_DrawRect(0, 0, hw-1, hh-1, TipOutline);
    cX1 := 0; cY1 := 0; cX2 := hw; cY2 := hh;
    SP_PutRegion(Window^.Surface, 2, 2, hw, hh, @Str[1], Length(Str), 0, 1, cX1, cY1, cX2, cY2, Error);
    RemoveTimer(TipTimerID);
    SP_InvalidateWholeDisplay;
//    SP_ForceScreenUpdate;
    SwitchFocusedWindow(DefaultWindow);
    TipWindowActive := False;
    TipTimerID := -1;
  End;

  SP_SetSystemFont(Font, Error);
  SP_SetDrawingWindow(DR_Window);

End;

Procedure CloseTipWindow;
Var
  ID: Integer;
  Error: TSP_ErrorCode;
Begin
  If TipWindowID >= 0 Then Begin
    ID := TipWindowID;
    TipWindowID := -1;
    SP_SetDirtyRect(CurHint.x, CurHint.y, CurHint.x + CurHint.w, CurHint.y + CurHint.h);
    SP_NeedDisplayUpdate := True;
    SP_DeleteWindow(ID, Error);
  End;
End;

Class Procedure SP_TipProcs.OnTipTimer(event: Pointer);
Var
  tX, tY, ID, i, j, sX, sY: Integer;
  Win: pSP_Window_Info;
  Ctrl: pSP_BaseComponent;
  p1, p2: TPoint;
  RLine, RCol: Integer;
  s: aString;
  L1, C1, L2, C2: Integer;
  localRect: TRect;
Begin
  If MOUSEBTN <> 0 Then Exit;
  For i := 0 To High(cKEYSTATE) Do
    If cKEYSTATE[i] <> 0 Then Exit;

  CurHint.Hint := '';
  tX := TipMouseX;
  tY := TipMouseY;
  sX := tX;          // preserve screen coords for window placement
  sY := tY;

  DisplaySection.Enter;
  Win := WindowAtPoint(tX, tY, ID);
  If Assigned(Win) Then Begin
    Ctrl := pSP_BaseComponent(ControlAtPoint(Win, tX, tY));
    If Assigned(Ctrl) Then Begin
      p1 := Ctrl^.ClientToScreen(Point(0, 0));
      p2 := Ctrl^.ClientToScreen(Point(Ctrl^.Width, Ctrl^.Height));
      CurHint.HotRect := Rect(p1.x, p1.y, p2.x, p2.y);

      // Is this the BASIC editor?
      If Ctrl^ Is SP_BASICEditor Then Begin
        With SP_BASICEditor(Ctrl^) Do Begin
          If HasSelection Then Begin
            s := GetSelectedText;
            If s <> '' Then Begin
              GetSelectionOrder(L1, C1, L2, C2);
              CurHint.HotRect := CharRectFromRawPos(L1, C1, IfThen(L1 = L2, C2, Length(Lines[L1]) + 1));
              // Only show if mouse is actually over the selection
              If PtInRect(CurHint.HotRect, Point(tX, tY)) Then Begin
                CurHint.Hint := s;
                EvaluateHint(CurHint);
              End Else

            End;
          End Else Begin
            // Word under mouse
            GetCharPosFromMouse(tX, tY, RLine, RCol);
            If (RLine >= 0) And (RLine < Lines.Count) Then Begin
              s := Lines[RLine];
              If (s <> '') And (RCol >= 1) And (RCol <= Length(s)) Then Begin
                CurHint := ProcessHint(s, RCol, i, j);
                If CurHint.Hint <> '' Then Begin
                  localRect    := CharRectFromRawPos(RLine, i, j);
                  CurHint.HotRect := Rect(
                    ClientToScreen(Point(localRect.Left,  localRect.Top)).X,
                    ClientToScreen(Point(localRect.Left,  localRect.Top)).Y,
                    ClientToScreen(Point(localRect.Right, localRect.Bottom)).X,
                    ClientToScreen(Point(localRect.Right, localRect.Bottom)).Y);
                End;
              End;
            End;
          End;
        End;
      End Else Begin
        // Generic control - plain Hint property
        CurHint.Hint := Ctrl^.Hint;
      End;
    End;
  End;
  DisplaySection.Leave;

  If CurHint.Hint <> '' Then Begin
    TipHotRect := CurHint.HotRect;
    CurHint.x := sX + (FpfW Div 2);
    CurHint.y := sY + (FpFH Div 2);
    OpenTipWindow(CurHint);
  End Else Begin
    RemoveTimer(TipTimerID);
    TipTimerID := -1;
  End;
End;

Initialization

  TipWindowID := -1;
  TipTimerID := -1;
  TipMouseX := -1;
  TipMouseY := -1;
  TipDelay := 50;
  TipBkClr := 223;
  TipOutline := 6;

end.

// multiple hints for list boxes, groupboxes, checklistboxes, etc etc
