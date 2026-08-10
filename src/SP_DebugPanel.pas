unit SP_DebugPanel;

{$INCLUDE SpecBAS.inc}

interface

uses {$IFNDEF SDL2}Dialogs,{$ENDIF} Math, Classes, SyncObjs, SysUtils, SP_Util, SP_BaseComponentUnit, SP_ListBoxUnit, SP_ComboBoxUnit, SP_ControlMsgs, SP_ButtonUnit, SP_Input, SP_ContainerUnit, SP_AmigaGuideUnit;

Type

  SP_PoIInfo = Record PoI_Type, Line, Statement: Integer; Name: aString; End;

  SP_DebugPanelActionProcs = Class

  Public

    Class Procedure PanelSwitch(Sender: SP_BaseComponent; Text: aString);
    Class Procedure DblClick(Sender: SP_BaseComponent; Index: Integer; Text: aString);
    Class Procedure PanelSelect(Sender: SP_BaseComponent; Index: Integer);
    Class Procedure ButtonClick(Sender: SP_BaseComponent);
    Class Procedure SelectItem(Sender: SP_BaseComponent; Index: Integer);
    Class Procedure SetFocus(Sender: SP_BaseComponent; WillFocus: Boolean);
    Class Procedure PaintGrabber(Control: SP_BaseComponent);

  End;

Procedure SP_OpenDebugPanel;
Procedure SP_CloseDebugPanel;
Procedure SP_User_OpenDebugPanel;
Procedure SP_User_CloseDebugPanel;
Procedure SP_FillDebugPanel;
Procedure SP_ResizeDebugPanel(X: Integer);
Procedure SP_FPUpdatePoIList;
Procedure SP_ShowHelpForWord(Const Word: aString);

var

  FPDebugPanel: SP_ListBox;
  FPDebugContainer, FPDebugContent: SP_Container;
  FPDebugCombo: SP_ComboBox;
  FPSizeGrabber: SP_Container;
  FPResizingDebugPanel: Boolean;
  FPUserOpenedDebugPanel: Boolean;
  FPDebugPanelVisible: Boolean;
  FPDebugPanelWidth: Integer;
  FPDebugPanelMode: Integer;
  FPDebugBPAdd,
  FPDebugBPDel,
  FPDebugBPEdt: SP_Button;
  FPPoIList: Array of SP_PoIInfo;
  DebugCurWindow: Integer;
  LastHelpNode: aString = '';
  LastHelpScroll: Integer = 0;
  LastDebugPanelIndex: Integer;
  FPShowingDebugFind: Boolean = False;
  FPHelpViewer: SP_AmigaGuide;
  FPHelpPanelMinWidth: Integer = 300;

Const

  PoI_Label = 0;
  PoI_Proc = 1;
  PoI_Fn = 2;

  dbgVariables = 1;
  dbgWatches = 2;
  dbgBreakpoints = 4;
  dbgLabels = 8;
  dbgProcs = 16;
  dgbCharset = 32;
  dbgDisassembly = 64;
  dbgProgMap = 128;

implementation

Uses {$IFNDEF FPC}Vcl.ClipBrd,{$ELSE}{$IFNDEF SDL2}ClipBrd,{$ENDIF}{$ENDIF} SP_FPEditor, SP_Errors, SP_Graphics, SP_BankManager, SP_BankFiling, SP_SysVars, SP_Components, SP_Variables, SP_AnsiStringList,
     SP_Interpret_PostFix, SP_FileIO, SP_Main, SP_MenuActions, SP_BASICEditorHostUnit, SP_MemoUnit, SP_Debugging, SP_Execute;

Procedure SP_UpdateAfterDebug;
Begin
  // Trigger layout so FPBASICEditor (AlignAll) resizes to fill the space
  // not occupied by FPDebugContainer (AlignRight).
  If Assigned(FPBASICEditor) Then
    FPBASICEditor.GetParentControl.AlignChildren;
  If FPShowingSearchResults And Assigned(FPDebugPanel) Then
    SP_DebugPanelActionProcs.SelectItem(Nil, FPDebugPanel.SelectedIndex);
  SP_Decorate_Window(FPWindowID, 'Program listing - ' + SP_GetProgName(PROGNAME, True), False, False, FocusedWindow = fwEditor);
End;

Procedure SP_ResizeDebugPanel(X: Integer);
Var
  NewW, MinW, MaxW: Integer;
Begin
  If Not Assigned(FPDebugContainer) Then Exit;

  // NewW is the width the container needs to be so its left edge sits at MOUSEX.
  // FPWindowLeft + FPWindowWidth is the right edge of the window in screen coords.
  NewW := FPWindowLeft + FPWindowWidth - X;

  MinW := 100 + BSize + (FPDebugContainer.Padding * 2);
  MaxW := (FPWindowWidth * 3 Div 4);

  If NewW < MinW Then NewW := MinW;
  If NewW > MaxW Then NewW := MaxW;

  // Setting Width triggers SetWidth -> DoResize -> parent.AlignChildren.
  // AlignRight repositions this container; AlignAll resizes FPBASICEditor.
  // No other bookkeeping needed.
  FPDebugContainer.Width := NewW;
End;

Procedure SP_User_OpenDebugPanel;
Begin
  FPUserOpenedDebugPanel := True;
  SP_OpenDebugPanel;
End;

Procedure SP_User_CloseDebugPanel;
Begin
  FPUserOpenedDebugPanel := False;
  If FPShowingDebugFind Then Begin
    FPBASICEditor.ClearSearchResults;   // clears highlights and repaints editor
    FPShowingSearchResults := False;    // clears the debug panel list state
    FPShowingDebugFind := False;        // clear the flag
  End;
  SP_CloseDebugPanel;
End;

Procedure SP_OpenDebugPanel;
Var
  Error: TSP_ErrorCode;
  Win: pSP_Window_Info;
Begin

  DisplaySection.Enter;

  SP_GetWindowDetails(FPWindowID, Win, Error);

  If Not Assigned(FPDebugContainer) Then Begin
    // Container sits on the right edge - AlignRight, width = panel + grabber strip.
    FPDebugContainer := SP_Container.Create(Win^.Component);
    FPDebugContainer.Padding     := 0;  // must precede Width
    FPDebugContainer.Width       := FPDebugPanelWidth + BSize + (FPDebugContainer.Padding * 2);
    FPDebugContainer.Align       := SP_AlignRight;
    FPDebugContainer.Border      := False;
    FPDebugContainer.Transparent := False;
    FPDebugContainer.BackgroundClr := FPBASICEditor.Colour;
    FPDebugContainer.Caption     := '';

    // Grabber strip - left edge of container, full height.
    FPSizeGrabber := SP_Container.Create(FPDebugContainer);
    FPSizeGrabber.Width       := BSize +1;
    FPSizeGrabber.Align       := SP_AlignLeft;
    FPSizeGrabber.Transparent := True;
    FPSizeGrabber.Border      := False;
    FPSizeGrabber.Caption     := '';
    FPSizeGrabber.Erase       := True;
    FPSizeGrabber.OnMouseDown := SP_MenuActionProcs.GrabberMouseDown;
    FPSizeGrabber.OnMouseMove := SP_MenuActionProcs.GrabberMouseMove;
    FPSizeGrabber.OnMouseUp   := SP_MenuActionProcs.GrabberMouseUp;
    FPSizeGrabber.OnFocus     := SP_DebugPanelActionProcs.SetFocus;
    FPSizeGrabber.OnPaintAfter := SP_DebugPanelActionProcs.PaintGrabber;
    FPSizeGrabber.Paint;

    FPDebugContent := SP_Container.Create(FPDebugContainer);
    FPDebugContent.Align       := SP_AlignAll;
    FPDebugContent.Padding     := BSize;
    FPDebugContent.fPaddingLeft:= 0;
    FPDebugContent.Border      := False;
    FPDebugContent.Transparent := False;
    FPDebugContent.BackgroundClr := FPBASICEditor.Colour;
    FPDebugContent.Caption     := '';

    // Combo box - top of remaining space inside container.
    FPDebugCombo := SP_ComboBox.Create(FPDebugContent);
    FPDebugCombo.Height   := FH;
    FPDebugCombo.Align    := SP_AlignTop;
    FPDebugCombo.CanFocus := False;
    FPDebugCombo.AddItem('Variables');
    FPDebugCombo.AddItem('SysVars');
    FPDebugCombo.AddItem('Watches');
    FPDebugCombo.AddItem('Breakpoints');
    FPDebugCombo.AddItem('Labels');
    FPDebugCombo.AddItem('Procedures/Functions');
    FPDebugCombo.AddItem('Character Set');
    FPDebugCombo.AddItem('Online Help');
    FPDebugCombo.ItemIndex := LastDebugPanelIndex;
    FPDebugCombo.OnChange  := SP_DebugPanelActionProcs.PanelSwitch;

    // Buttons - AlignBottom inside container.
    FPDebugBPEdt := SP_Button.Create(FPDebugContent);
    FPDebugBPEdt.Height   := FH + (BSize * 2);
    FPDebugBPEdt.Align    := SP_AlignBottom;
    FPDebugBPEdt.Visible  := False;
    FPDebugBPEdt.OnClick  := SP_DebugPanelActionProcs.ButtonClick;

    FPDebugBPDel := SP_Button.Create(FPDebugContent);
    FPDebugBPDel.Height   := FH + (BSize * 2);
    FPDebugBPDel.Align    := SP_AlignBottom;
    FPDebugBPDel.Visible  := False;
    FPDebugBPDel.OnClick  := SP_DebugPanelActionProcs.ButtonClick;

    FPDebugBPAdd := SP_Button.Create(FPDebugContent);
    FPDebugBPAdd.Height   := FH + (BSize * 2);
    FPDebugBPAdd.Align    := SP_AlignBottom;
    FPDebugBPAdd.Visible  := False;
    FPDebugBPAdd.OnClick  := SP_DebugPanelActionProcs.ButtonClick;

    // List box - AlignAll, fills remaining space.
    FPDebugPanel := SP_ListBox.Create(FPDebugContent);
    FPDebugPanel.fPaddingTop    := BSize;
    FPDebugPanel.Align          := SP_AlignAll;
    FPDebugPanel.AllowLiterals  := True;
    FPDebugPanel.CanUserSort    := True;
    FPDebugPanel.SortByAlpha    := True;
    FPDebugPanel.MultiSelect    := False;
    FPDebugPanel.OnFocus        := SP_DebugPanelActionProcs.SetFocus;
    FPDebugPanel.OnChoose       := SP_DebugPanelActionProcs.DblClick;
    FPDebugPanel.OnSelect       := SP_DebugPanelActionProcs.SelectItem;
    FPDebugPanel.BackgroundClr  := FPBASICEditor.Colour;
    FPDebugPanel.Colour         := SP_UIWindowBack;

    // AmigaGuide help viewer - hidden until the user switches to Help.
    FPHelpViewer := SP_AmigaGuide.Create(FPDebugContent);
    FPHelpViewer.Border       := True;
    FPHelpViewer.fPaddingTop  := BSize;
    FPHelpViewer.Align        := SP_AlignAll;
    FPHelpViewer.Shadow       := True;
    FPHelpViewer.TextMargin   := 8;
    FPHelpViewer.Proportional := True;
    FPHelpViewer.Visible      := LastHelpNode <> '';
    FPHelpViewer.LoadGuide('/sb.guide');
    FPHelpViewer.RestorePosition(LastHelpNode, LastHelpScroll);
  End;

  FPDebugPanelVisible := True;
  FocusedControl := Nil;

  SP_FillDebugPanel;
  SP_DebugPanelActionProcs.PanelSwitch(FPDebugCombo, '');
  SP_UpdateAfterDebug;

  FPBASICEditor.fPaddingRight := 0;
  FPBASICEditor.Paint;

  DisplaySection.Leave;

End;

Procedure SP_CloseDebugPanel;
Begin
  If Assigned(FPHelpViewer) Then Begin
    LastHelpNode   := FPHelpViewer.CurrentNodeName;
    LastHelpScroll := FPHelpViewer.TopPixel;
  End;
  FPDebugPanelVisible := False;
  If Assigned(FPDebugContainer) Then
    FPDebugPanelWidth := FPDebugContainer.Width - BSize - (FPDebugContainer.Padding * 2);
  FreeAndNil(FPDebugContainer);
  // Container owns and has freed all children - nil the pointers.
  FPDebugPanel   := nil;
  FPDebugCombo   := nil;
  FPDebugBPAdd   := nil;
  FPDebugBPDel   := nil;
  FPDebugBPEdt   := nil;
  FPSizeGrabber  := nil;
  FPHelpViewer   := nil;  // owned and freed by FPDebugContent
  If Assigned(FPBASICEditor) Then Begin
    FPBASICEditor.fPaddingRight := 4;
    FPBASICEditor.Paint;
  End;
  // Restore focus to whatever was active before the panel opened
  SwitchFocusedWindow(DebugCurWindow);
  SP_UpdateAfterDebug;
End;

Procedure SP_MakeBreakPointList(var List: TAnsiStringlist);
Var
  i: Integer;

  Function GetBreakPointInfo(Var Bp: TSP_BreakPointInfo): aString;
  Var
    s: aString;
  Begin
    With Bp Do Begin
      Case bpType Of
        BP_Stop:
          Begin
            s := 'S' + #255 + IntToString(Line) + ':' + IntToString(Statement);
            s := s + #255 + IntToString(PassCount) + '/' + IntToString(PassNum);
            If Condition <> '' Then
              s := s + #255 + Condition;
          End;
        BP_Conditional:
          Begin
            s := 'C' + #255 + '-:--';
            s := s + #255 + IntToString(PassCount) + '/' + IntToString(PassNum) + #255 + Condition;
          End;
        BP_Data:
          Begin
            s := 'D' + #255 + '-:--';
            s := s + #255 + IntToString(PassCount) + '/' + IntToString(PassNum) + #255 + Condition;
          End;
      End;
    End;
    Result := s;
  End;

Begin

  List.Clear;

  For i := 0 To Length(SP_SourceBreakPointList) -1 Do Begin
    List.Add(GetBreakPointInfo(SP_SourceBreakPointList[i]));
    List.Objects[List.Count -1] := TObject(@SP_SourceBreakPointList[i]);
  End;

  For i := 0 To Length(SP_ConditionalBreakPointList) -1 Do Begin
    List.Add(GetBreakPointInfo(SP_ConditionalBreakPointList[i]));
    List.Objects[List.Count -1] := TObject(@SP_ConditionalBreakPointList[i]);
  End;

  If List.Count = 0 Then Begin
    List.Add('');
    List.Objects[0] := TObject(-1);
  End;

End;

Procedure SP_FillDebugPanel;
Var
  Changed: Boolean;
  i, MaxW, MaxWC, MaxP, p, j, OldP, cFW: Integer;
  s, vType, vName, vContent, vExtra, vPass: aString;
  List, OldVars, OldContents, OldWatches, OldExprs: TAnsiStringlist;
  Error: TSP_ErrorCode;
  Hdr: SP_ListBoxHeader;

Const

  PoINameT: Array[0..2] of aString = ('@', 'Proc', 'Fn');
  BoolStrs: Array[0..1] of aString = ('False', 'True');

  Procedure SetButtons;
  Var
    i: Integer;
    Btn: SP_Button;
  Const
    Caps: Array[0..2] of aChar = (#240, '-', '+');
  Begin
    FPDebugBPAdd.Visible := False;
    FPDebugBPDel.Visible := False;
    FPDebugBPEdt.Visible := False;
    If FPDebugCombo.ItemIndex = 7 Then Exit;  // Help tab has no list buttons
    Case FPDebugCombo.ItemIndex of
      0: // Vars - Hide add/delete button, show edit button.
        Begin
          If FPDebugPanel.Enabled Then Begin
            FPDebugBPEdt.Visible := True;
          End;
        End;
      2, 3: // Watches and breakpoints
        Begin
          FPDebugBPAdd.Visible := True;
          If FPDebugPanel.Enabled Then Begin
            FPDebugBPEdt.Visible := True;
            FPDebugBPDel.Visible := True;
          End;
        End;
    End;

    // Buttons use SP_AlignBottom inside the container - just set captions.
    Btn := nil;
    For i := 0 to 2 Do Begin
      Case i of
        0: Btn := FPDebugBPEdt;
        1: Btn := FPDebugBPDel;
        2: Btn := FPDebugBPAdd;
      End;
      If Btn.Visible Then Begin
        Btn.Proportional := False;
        Btn.Caption := Caps[i];
        Btn.CentreCaption;
      End;
    End;
    FPDebugBPDel.Enabled := FPDebugPanel.fSelCount > 0;
    FPDebugBPEdt.Enabled := FPDebugPanel.fSelCount > 0;
    If Assigned(FPDebugContainer) Then
      FPDebugContainer.AlignChildren;
  End;

Begin

  If FPDebugPanelVisible And not QUITMSG And (FPWIndowID >= 0) Then Begin

    List := TAnsiStringlist.Create;

    // Help tab manages its own content - nothing for SP_FillDebugPanel to do.
    If FPDebugCombo.ItemIndex = 7 Then Begin List.Free; Exit; End;

    With FPDebugPanel Do Begin
      Lock;
      cFW := Round(iFW * iSX);
      Case FPDebugCombo.ItemIndex of
        0: // Variables
          Begin
            SP_MakeListVarOutput(List, True);
            If Integer(List.Objects[0]) = -1 Then Begin
              Clear;
              Add(' No variables defined');
              Enabled := False;
            End Else Begin
              OldVars := TAnsiStringlist.Create;
              OldContents := TAnsiStringlist.Create;
              For i := 0 To Count -1 Do Begin
                s := FPDebugPanel.Items[i];
                if s[1] = ' ' then s := Copy(s, 2);
                if s[1] < ' ' then s := Copy(s, 6);
                OldVars.Add(Copy(s, 1, Pos(#255, s) -1));
                OldContents.Add(Copy(s, Pos(#255, s) +7));
              End;
              Clear;
              MaxW := 0;
              MaxP := 0;
              For i := 0 To List.Count -1 Do Begin
                s := List[i];
                vName := Copy(s, 1, Pos('=', s) -1);
                MaxP := Max(MaxP, Length(vName));
                OldP := OldVars.IndexOf(vName);
                If OldP >= 0 Then Begin
                  // Variable already exists from previous update - check for changes
                  vContent := Copy(s, Pos('=', s) +1);
                  MaxW := Max(MaxW, Length(vContent));
                  If OldContents[OldP] <> vContent then
                    vContent := #16 + LongWordToString(debugChg) + vContent
                  Else
                    vContent := #16#0#0#0#0 + vContent;
                End Else Begin
                  vName := #16 + LongWordToString(debugNew) + vName;
                  vContent := Copy(s, Pos('=', s) +1);
                  MaxW := Max(MaxW, Length(vContent));
                  vContent := #16 + LongWordToString(debugNew) + vContent;
                End;
                Add(' ' + vName + #255 + ' ' + vContent);
              End;
              MaxW := Max(10, MaxW);
              MaxP := Max(6, MaxP +1);
              AddHeader(' Name', MaxP * cFW);
              AddHeader(' Contents', MaxW * cFW);
              fHeaders[1].Proportional := False;
              //SortByAlpha := True;
              //Sort(0);
              Enabled := True;
              OldVars.Free;
              OldContents.Free;
            End;
          End;
        1: // SysVars
          Begin
            Clear;
            MaxP := 0;
            MaxW := 0;
            For i := 0 To High(SysVars) Do Begin
              vName := SysVars[i].Name;
              MaxP := Max(MaxP, Length(vName));
              Case SysVars[i].svType Of
                svString:
                  Begin
                    vName := ' $' + #255 + ' ' + vName;
                    vContent := ' ' + SP_MakePretty(SP_GetSysVarS(SysVars[i].Name, Error));
                  End;
                svArray:
                  Begin
                    vName := ' A' + #255 + ' ' + vName;
                    vContent := ' ' + SP_MakePretty(SP_GetSysVarS(SysVars[i].Name, Error));
                  End;
                svBoolean:
                  Begin
                    vName := ' B' + #255 + ' ' + vName;
                    vContent := ' ' + BoolStrs[Round(SP_GetSysVarN(SysVars[i].Name, Error))];
                  End;
                svLongWord:
                  Begin
                    vName := ' L' + #255 + ' ' + vName;
                    vContent := ' ' + aString(FloatToStr(SP_GetSysVarN(SysVars[i].Name, Error)));
                  End;
                svaFloat:
                  Begin
                    vName := ' F' + #255 + ' ' + vName;
                    vContent := ' ' + aString(FloatToStr(SP_GetSysVarN(SysVars[i].Name, Error)));
                  End;
                svInteger:
                  Begin
                    vName := ' I' + #255 + ' ' + vName;
                    vContent := ' ' + aString(FloatToStr(SP_GetSysVarN(SysVars[i].Name, Error)));
                  End;
                svPointer:
                  Begin
                    vName := ' P' + #255 + ' ' + vName;
                    vContent := ' ' + aString(FloatToStr(SP_GetSysVarN(SysVars[i].Name, Error)));
                  End;
                svByte:
                  Begin
                    vName := ' b' + #255 + ' ' + vName;
                    vContent := ' ' + aString(FloatToStr(SP_GetSysVarN(SysVars[i].Name, Error)));
                  End;
                svColour:
                  Begin
                    vName := ' C' + #255 + ' ' + vName;
                    vContent := ' $' + IntToHex(Round(SP_GetSysVarN(SysVars[i].Name, Error)), 8);
                  End;
              End;
              MaxW := Max(MaxW, Length(vContent));
              vName := vName + #255 + vContent;
              Add(vName);
            End;
            MaxW := Max(10, MaxW);
            MaxP := Max(6, MaxP +1);
            AddHeader(' Type', 2 * cFW);
            AddHeader(' Name', MaxP * cFW);
            AddHeader(' Contents', MaxW * cFW);
            fHeaders[2].Proportional := False;
            Enabled := True;
            Sort(0);
          End;
        2: // Watches
          Begin
            If Length(SP_WatchList) = 0 then Begin
              Clear;
              Add(' No watches defined');
              Enabled := False;
            End Else Begin
              Clear;
              MaxW := 0;
              MaxP := 0;
              OldExprs := TAnsiStringList.Create;
              OldWatches := TAnsiStringlist.Create;
              For i := 0 To Count -1 Do Begin
                s := Items[i];
                If s[1] = #16 Then
                  s := Copy(s, 6);
                p := Pos(#255, s) +1;
                OldWatches.Add(Copy(s, p));
                s := Copy(s, 1, p -2);
                If s[1] = #16 Then
                  s := Copy(s, 6);
                OldExprs.Add(s);
              End;
              For i := 0 To Length(SP_WatchList) -1 Do Begin
                Error.Code := SP_ERR_OK;
                s := ' ' + SP_WatchList[i].Expression;
                MaxW := Max(Length(s), MaxW);
                vContent := ' ' + SP_FPExecuteAnyExpression(SP_WatchList[i].Compiled_Expression, Error);
                If Error.Code <> SP_ERR_OK Then Begin
                  vContent := ' ' + ProcessErrorMessage(ErrorMessages[Error.Code]);
                  MaxP := Max(Length(vContent), MaxP);
                  vContent := #16#2#0#0#0 + vContent;
                End Else Begin
                  j := OldExprs.IndexOf(s);
                  Changed := (j >= 0) And (OldWatches[j] <> vContent);
                  MaxP := Max(Length(vContent), MaxP);
                  If Changed Then Begin
                    s := #16 + LongWordToString(debugNew) + s;
                    vContent := #16 + LongWordToString(debugNew) + vContent;
                  End;
                End;
                Add(s + #255 + vContent);
              End;
              AddHeader(' Expr', Max(6, MaxW) * cFW);
              AddHeader(' Result', Max(7, MaxP) * cFW);
              Sort(0);
              Enabled := True;
              OldExprs.Free;
              OldWatches.Free;
            End;
          End;
        3: // Breakpoints
          Begin
            SP_MakeBreakpointList(List);
            If Integer(List.Objects[0]) = -1 Then Begin
              Clear;
              Add(' No breakpoints defined');
              Enabled := False;
            End Else Begin
              Clear;
              MaxW := 0;
              MaxP := 0;
              MaxWC := 0;
              For i := 0 To List.Count -1 Do Begin
                s := List[i];
                vType := s[1];
                s := Copy(s, 3);
                p := Pos(#255, s);
                vContent := ' ' + Copy(s, 1, p -1);
                s := Copy(s, p +1);
                p := Pos(#255, s);
                If p > 0 Then Begin
                  vPass := ' ' + Copy(s, 1, p -1);
                  vExtra := ' ' + Copy(s, p +1);
                  Add(vType + #255 + vContent + #255 + vPass + #255 + vExtra);
                  MaxWC := Max(MaxWC, Length(vExtra) +1);
                End Else Begin
                  vPass := ' ' + s;
                  Add(vType + #255 + vContent + #255 + vPass);
                End;
                Objects[Count -1] := List.Objects[i];
                MaxW := Max(MaxW, Length(vContent) +1);
                MaxP := Max(MaxP, Length(vPass) +1);
              End;
              MaxW := Max(5, MaxW);
              MaxP := Max(6, MaxP);
              MaxWC := Max(10, MaxWC);
              Hdr.Caption := ' ';
              Hdr.Width := 2 * cFW;
              Hdr.Justify := 0;
              AddHeader(Hdr);
              AddHeader(' Line', MaxW * cFW);
              AddHeader(' Pass', MaxP * cFW);
              If MaxWC > 0 Then
                AddHeader(' Condition', MaxWC * cFW);
              Sort(0);
              Enabled := True;
            End;
          End;
        4: // Labels - double click to jump
          Begin
            Clear;
            MaxW := 0;
            MaxP := 0;
            For i := 0 To Length(FPPoIList) -1 Do
              If FPPoIList[i].PoI_Type = PoI_Label Then Begin
                s := ' ' + FPPoIList[i].Name;
                j := FPPoIList[i].Line;
                vContent := ' ' + IntToString(SP_GetLineNumberFromIndex(j)) + ':' + IntToString(FPPoIList[i].Statement);
                MaxW := Max(MaxW, Length(vContent) +1);
                MaxP := Max(MaxP, Length(s) +1);
                Add(s + #255 + vContent);
                Objects[Count -1] := TObject(i);
              End;
            If Count > 0 Then Begin
              MaxW := Max(6, MaxW);
              MaxP := Max(16, MaxP);
              AddHeader(' Name', MaxP * cFW);
              AddHeader(' Line:Statement', MaxW * cFW);
              Enabled := True;
            End Else Begin
              Add(' No labels defined');
              Enabled := False;
            End;
          End;
        5: // Procedures/functions
          Begin
            Clear;
            MaxW := 0;
            MaxP := 0;
            For i := 0 To Length(FPPoIList) -1 Do
              If FPPoIList[i].PoI_Type in [PoI_Proc, PoI_Fn] Then Begin
                s := ' ' + PoINameT[FPPoIList[i].PoI_Type] + ' ' + FPPoIList[i].Name;
                j := FPPoIList[i].Line;
                vContent := ' ' + IntToString(SP_GetLineNumberFromIndex(j)) + ':' + IntToString(FPPoIList[i].Statement);
                MaxW := Max(MaxW, Length(vContent) +1);
                MaxP := Max(MaxP, Length(s) +1);
                Add(s + #255 + vContent);
                Objects[Count -1] := TObject(i);
              End;
            If Count > 0 Then Begin
              MaxW := Max(6, MaxW);
              MaxP := Max(16, MaxP);
              AddHeader(' Name', MaxP * cFW);
              AddHeader(' Line:Statement', MaxW * cFW);
              Enabled := True;
              Sort(0);
            End Else Begin
              Add(' No Fn/Procs defined');
              Enabled := False;
            End;
          End;
        6: // Character Set
          Begin
            Clear;
            MaxW := 5;
            MaxP := 13;
            AddHeader(' Hex ', MaxW * cFW);
            AddHeader(' Dec ', MaxW * cFW);
            AddHeader(' Character ', MaxP * cFW);
            fHeaders[0].Proportional := False;
            fHeaders[1].Proportional := False;
            fHeaders[2].Proportional := False;
            For i := 0 to 255 Do Begin
              vName := IntToString(i);
              If i < 32 Then Begin
                Case i Of
                  6:  vContent := 'PRINT comma';
                  8:  vContent := 'Cursor left';
                  9:  vContent := 'Cursor right';
                  10: vContent := 'Cursor down';
                  11: vContent := 'Cursor up';
                  13: vContent := 'Return';
                  15: vContent := 'FONT';
                  16: vContent := 'INK';
                  17: vContent := 'PAPER';
                  18: vContent := 'OVER';
                  19: vContent := 'TRANSPARENT';
                  20: vContent := 'INVERSE';
                  21: vContent := 'MOVE';
                  22: vContent := 'AT';
                  23: vContent := 'TAB';
                  24: vContent := 'CENTRE';
                  25: vContent := 'SCALE';
                  26: vContent := 'ITALIC';
                  27: vContent := 'BOLD';
                  29: vContent := 'PROP';
                Else
                  Begin
                    vContent := aChar(5) + aChar(i And $FF);
                  End;
                End;
              End Else
                If i = 255 Then
                  vContent := '\$FF'
                Else
                  vContent := aChar(i);
              s := ' $' + IntToHex(i, 2) + #255 + ' ' + SP_Copy('000', 1, 3 - Length(vName)) + vName + #255 + ' ' + vContent;
              Add(s);
              Objects[Count -1] := TObject(i);
            End;
            Enabled := True;
            Sort(0);
          End;
        7: // Help
          Begin

          End;
        8: // Map
          Begin

          End;
      End;
      SetButtons;
      Unlock;
    End;

    List.Free;

  End;

End;

Class Procedure SP_DebugPanelActionProcs.PanelSwitch(Sender: SP_BaseComponent; Text: aString);
Begin

  LastDebugPanelIndex := FPDebugCombo.ItemIndex;

  If Assigned(FPHelpViewer) Then Begin
    If FPDebugCombo.ItemIndex = 7 Then Begin
      // Switching TO Help - show viewer, hide list and buttons.
      FPDebugPanel.Visible := False;
      FPDebugBPAdd.Visible := False;
      FPDebugBPDel.Visible := False;
      FPDebugBPEdt.Visible := False;
      FPHelpViewer.Visible := True;
      FPHelpViewer.SetFocus(True);
      FPHelpViewer.RefreshNavBar;
      FPDebugContent.AlignChildren;
    End Else Begin
      // Switching AWAY from Help - restore list, hide viewer.
      FPHelpViewer.Visible := False;
      FPDebugPanel.Visible := True;
    End;
  End;

  SP_FPUpdatePoIList;

End;

Class Procedure SP_DebugPanelActionProcs.PanelSelect(Sender: SP_BaseComponent; Index: Integer);
Begin

  // Toggle the edit and delete buttons if there's a selection

  FPDebugBPDel.Enabled := FPDebugPanel.fSelCount > 0;
  FPDebugBPEdt.Enabled := FPDebugPanel.fSelCount > 0;

End;

Procedure SP_EditBreakpoint(Index: Integer; Delete: Boolean);
Var
  i: Integer;
  s: aString;
  Bp: pSP_BreakPointInfo;
Begin

  // Edit or delete a breakpoint. If editing, we send a custom message to the interpreter thread
  // to open the BP editor dialog. If deleting, do it here.

  SetLength(s, SizeOf(LongWord) + SizeOf(pSP_BreakPointInfo));
  Bp := pSP_BreakPointInfo(FPDebugPanel.Objects[Index]);
  Index := -1;
  If Bp^.bpType = BP_STOP Then Begin
    For i := 0 To Length(SP_SourceBreakPointList) -1 Do
      If @SP_SourceBreakPointList[i] = Bp Then Begin
        Index := i;
        Break;
      End;
  End Else Begin
    For i := 0 To Length(SP_ConditionalBreakPointList) -1 Do
      If @SP_ConditionalBreakPointList[i] = Bp Then Begin
        Index := i;
        Break;
      End;
  End;

  If Delete Then Begin
    If Bp^.bpType = BP_STOP Then Begin
      For i := Index To Length(SP_SourceBreakPointList) -2 Do
        SP_SourceBreakPointList[i] := SP_SourceBreakPointList[i +1];
      SetLength(SP_SourceBreakPointList, Length(SP_SourceBreakPointList) -1);
    End Else Begin
      For i := Index To Length(SP_ConditionalBreakPointList) -2 Do
        SP_ConditionalBreakPointList[i] := SP_ConditionalBreakPointList[i +1];
      SetLength(SP_ConditionalBreakPointList, Length(SP_ConditionalBreakPointList) -1);
    End;
    SP_GetDebugStatus(dbgBreakpoints);
  End Else Begin
    pLongWord(@s[1])^ := Index;
    pNativeUInt(@s[1 + SizeOf(LongWord)])^ := NativeUInt(Bp);
    AddControlMsg(clBPEdit, s);
  End;

End;

Class Procedure SP_DebugPanelActionProcs.SelectItem(Sender: SP_BaseComponent; Index: Integer);
var
  s: aString;
Begin

  PanelSelect(Sender, Index);

  If Index < 0 Then Begin
    FPBASICEditor.ClearSearchResults;
    Exit;
  End Else
    Case FPDebugCombo.ItemIndex of
      0: // Variables - Highlight all instances
        Begin
          FPSearchTerm := FPDebugPanel.Items[Index];
          if FPSearchTerm[1] = ' ' then FPSearchTerm := Copy(FPSearchTerm, 2);
          if FPSearchTerm[1] < ' ' then FPSearchTerm := Copy(FPSearchTerm, 6);
          FPSearchTerm := Copy(FPSearchTerm, 1, Pos(#255, FPSearchTerm) -1);
          If Pos('(', FPSearchTerm) > 0 Then
            FPSearchTerm := Copy(FPSearchTerm, 1, Pos('(', FPSearchTerm));
          FPSearchOptions := [soForward, soStart, soVarName];
          FPBASICEditor.BASICFindAll(FPSearchTerm, FPSearchOptions, nil);
          FPShowingSearchResults := FPBASICEditor.HasFindResults;
          FPShowingSearchResults := True;
          FPShowingDebugFind := True;
        End;
      1: // SysVars - highlight all sysvarss
        Begin

        End;
      4: // Labels - highlight all @Label instances
        Begin
          Index := Integer(FPDebugPanel.Objects[Index]);
          FPSearchTerm := '@' + FPPoIList[Index].Name;
          FPSearchOptions := [soForward, soStart];
          FPBASICEditor.BASICFindAll(FPSearchTerm, FPSearchOptions, nil);
          FPShowingSearchResults := True;
          FPShowingDebugFind := True;
        End;
      5: // Procs and FNs - highlight all usages. Find "Fn x" and "Proc x", "DEF FN x" and "DEF PROC x" as well as "CALL x".
        Begin
          Index := Integer(FPDebugPanel.Objects[Index]);
          s := FPPoIList[Index].Name;
          if Pos('(', s) > 0 Then
            s := Copy(s, 1, Pos('(', s) -1);
          if FPPoIList[Index].PoI_Type = PoI_Fn then
            FPSearchTerm := 'fn ' + s
          else
            FPSearchTerm := 'proc ' + s;
          FPSearchOptions := [soForward, soStart];
          FPBASICEditor.BASICFindAll(FPSearchTerm, FPSearchOptions, nil, True);
          FPSearchTerm := 'def ' + FPSearchTerm;
          FPBASICEditor.BASICFindAll(FPSearchTerm, FPSearchOptions, nil, False);
          if FPPoIList[Index].PoI_Type = PoI_Proc then Begin
            FPSearchTerm := 'call ' + s;
            FPBASICEditor.BASICFindAll(FPSearchTerm, FPSearchOptions, nil, False);
          End;
          FPShowingSearchResults := True;
          FPShowingDebugFind := True;
        End;
    End;

End;

Class Procedure SP_DebugPanelActionProcs.DblClick(Sender: SP_BaseComponent; Index: Integer; Text: aString);
Var
  s: aString;
  Error: TSP_ErrorCode;
Begin

  // User double clicked (or used the enter key) on a breakpoint so open it and edit it.

  Index := Integer(FPDebugPanel.Objects[Index]);

  Case FPDebugCombo.ItemIndex of
    0: // Variables - edit the var
      Begin
      End;
    1: // SysVars
      Begin
      End;
    2: // Watches - edit the watch
      Begin
        AddControlMsg(clEditWatch, LongWordToString(FPDebugPanel.SelectedIndex));
      End;
    3: // Breakpoints - edit the breakpoint
      Begin
        SP_EditBreakpoint(Index, False);
      End;
    4: // Labels - double click to jump to that label declaration
      Begin
        s := EDITLINE;
        EDITLINE := '@' + FPPoIList[Index].Name;
        SP_FPBringToEditor(0, 0, Error, False);
        EDITLINE := s;
      End;
    5: // Procs and FNs - jump to declaration
      Begin
        PROGLINE := SP_GetLineNumberFromIndex(FPPoiList[Index].Line);
        SP_FPScrollToLine(PROGLINE, FPPoIList[Index].Statement);
      End;
    6: // Character set - paste character at cursor pos
      Begin
        If DebugCurWindow = fwEditor Then Begin
          FPBASICEditor.SetFocus(True);
          FPBASICEditor.InsertChar(aChar(Integer(FPDebugPanel.Objects[Index])));
          FPBASICEditor.EnsureCursorVisible;
          FPBASICEditor.Paint;
        End Else
          If DebugCurWindow = fwDirect Then Begin
            DWBASICEditor.SetFocus(True);
            DWBASICEditor.InsertChar(aChar(Integer(FPDebugPanel.Objects[Index])));
            DWBASICEditor.EnsureCursorVisible;
            DWBASICEditor.Paint;
          End;
      End;
  End;

End;

Class Procedure SP_DebugPanelActionProcs.ButtonClick(Sender: SP_BaseComponent);
Begin

  Case FPDebugCombo.ItemIndex of
    0: // Variables
      Begin
      End;
    1: // SysVars
      Begin
      End;
    2: // Watches
      Begin
        If Sender = FPDebugBPEdt Then Begin
          AddControlMsg(clEditWatch, LongWordToString(FPDebugPanel.SelectedIndex));
        End Else
          If Sender = FPDebugBPAdd Then Begin
            AddControlMsg(clKeypress, aChar(Sender.GetParentWindowID)+aChar(K_CONTROL) + aChar(K_W));
          End Else
            If Sender = FPDebugBPDel Then Begin
              SP_DeleteWatch(FPDebugPanel.SelectedIndex);
            End;
      End;
    3: // Breakpoints
      Begin
        If Sender = FPDebugBPEdt Then Begin
          SP_EditBreakPoint(FPDebugPanel.SelectedIndex, False);
        End Else
          If Sender = FPDebugBPAdd Then Begin
            AddControlMsg(clKeypress, aChar(Sender.GetParentWindowID)+aChar(K_CONTROL) + aChar(K_N));
          End Else
            If Sender = FPDebugBPDel Then Begin
              SP_EditBreakPoint(FPDebugPanel.SelectedIndex, True);
            End;
      End;
    4: // Labels
      Begin
      End;
    5: // Procs and Fns
      Begin
      End;
    6: // Disassembly
      Begin
      End;
    7: // Program map
      Begin
      End;
  End;

End;

Class Procedure SP_DebugPanelActionProcs.PaintGrabber(Control: SP_BaseComponent);
var
  i, y, x: Integer;
Begin

  With Control do Begin
    FillRect(0, 0, fWidth, fHeight, FPBASICEditor.Colour);
    x := (Width Div 2) -1;
    y := (Height Div 2) - 5;
    for i := 0 to 2 do
      FillRect(x, y+(i * 4), x + 2, y+2+(i*4), fDisabledFontClr);
  end;

End;

Class Procedure SP_DebugPanelActionProcs.SetFocus(Sender: SP_BaseComponent; WillFocus: Boolean);
Begin

  If WillFocus Then Begin
    If FocusedWindow > fwNone then
      DebugCurWindow := FocusedWindow;
    SP_SwitchFocus(fwDebugPanel);
    If Not Sender.CanFocus Then
      FocusedControl := nil;
  End Else Begin
    SP_SwitchFocus(DebugCurWindow);
    FocusedControl := nil;
  End;

End;

Procedure SP_ShowHelpForWord(Const Word: aString);
Var
  PrevFocus: SP_BaseComponent;
  raw, col, numLen, lLen, lo, hi, lo2, hi2, p: Integer;
  line, prevWord, nextWord, compound, compoundFwd: aString;
Begin

  // Open the panel if it isn't already, switch to the Help tab, and
  // navigate the guide to the closest matching node.
  If Not FPDebugPanelVisible Then Begin
    SP_User_OpenDebugPanel;
    If Assigned(FPDebugContainer) And
       (FPDebugContainer.Width < FPHelpPanelMinWidth) Then
      FPDebugContainer.Width := FPHelpPanelMinWidth;
  End;

  If Assigned(FPDebugCombo) Then Begin
    FPDebugCombo.ItemIndex := 7;
    SP_DebugPanelActionProcs.PanelSwitch(FPDebugCombo, '');
  End;

  If Assigned(FPHelpViewer) Then Begin
    PrevFocus := FocusedControl;
    If Word <> '' Then Begin
      compound := '';

      // Try to extend Word with the following word on the line
      // to handle compound keywords like DEF FN, END IF etc.
      If Assigned(FPBASICEditor) Then Begin
        raw  := FPBASICEditor.CursorLine;
        line := FPBASICEditor.Lines[raw];
        col  := FPBASICEditor.CursorCol;
        lLen := Length(line);
        numLen := FPBASICEditor.GetLineNumLen(raw);

        // Find extent of current word
        lo := col;
        While (lo > numLen + 1) And
              (line[lo - 1] In ['A'..'Z','a'..'z','0'..'9','$','_']) Do
          Dec(lo);
        hi := col;
        While (hi < lLen) And
              (line[hi + 1] In ['A'..'Z','a'..'z','0'..'9','$','_']) Do
          Inc(hi);

        // Look backwards for a preceding word
        p := lo - 1;
        While (p >= numLen + 1) And (line[p] = ' ') Do Dec(p);
        If p >= numLen + 1 Then Begin
          hi2 := p;
          While (p > numLen + 1) And
                (line[p - 1] In ['A'..'Z','a'..'z','0'..'9','$','_']) Do
            Dec(p);
          prevWord := Copy(line, p, hi2 - p + 1);
        End Else
          prevWord := '';

        // Look forwards for a following word
        p := hi + 1;
        While (p <= lLen) And (line[p] = ' ') Do Inc(p);
        lo2 := p;
        While (p <= lLen) And
              (line[p] In ['A'..'Z','a'..'z','0'..'9','$','_']) Do
          Inc(p);
        nextWord := Copy(line, lo2, p - lo2);

        // Build candidates
        If prevWord <> '' Then
          compound := Upper(prevWord + '_' + Word)
        Else
          compound := '';

        If nextWord <> '' Then
          compoundFwd := Upper(Word + '_' + nextWord)
        Else
          compoundFwd := '';
      End;

      // Lookup priority
      If (compound    <> '') And (FPHelpViewer.FindNode(compound)    >= 0) Then
        FPHelpViewer.GoToNode(compound)
      Else If (compoundFwd <> '') And (FPHelpViewer.FindNode(compoundFwd) >= 0) Then
        FPHelpViewer.GoToNode(compoundFwd)
      Else If FPHelpViewer.FindNode(Word) >= 0 Then
        FPHelpViewer.GoToNode(Word)
      Else If FPHelpViewer.FindNode(Upper(Word)) >= 0 Then
        FPHelpViewer.GoToNode(Upper(Word))
      Else
        FPHelpViewer.GoToNode('MAIN');
    End Else
      FPHelpViewer.GoToNode('MAIN');
    If Assigned(PrevFocus) Then
      PrevFocus.SetFocus(True);
  End;

End;

Procedure SP_FPUpdatePoIList;
var
  i, j, l, ps, St, bc, ofs: Integer;
  inString: Boolean;
  s, lbl: aString;

  Function InAString(const t: aString): Boolean;
  Var k: Integer; q: Boolean;
  Begin
    q := False;
    For k := 1 To Length(t) Do
      If t[k] = '"' Then q := Not q;
    Result := q;
  End;

  Procedure AddToList(iType: Integer; iName: aString; iLine, iStatement: Integer);
  Begin
    l := Length(FPPoIList);
    SetLength(FPPoIList, l +1);
    FPPoIList[l].Line := iLine;
    FPPoIList[l].Statement := iStatement;
    FPPoIList[l].Name := iName;
    FPPoIList[l].PoI_Type := iType;
  End;

Label
  Again;
Begin

  SetLength(FPPoIList, 0);
  For i := 0 To Listing.Count -1 Do
    If Listing.Flags[i].PoI Then Begin
      j := i; s := '';
      While (j > 0) And (SP_LineHasNumber(j) = 0) Do Dec(j);
      While j < i Do Begin
        s := s + Listing[j];
        Inc(j);
      End;
      s := lower(s + Listing[i]);
      St := 1;
      If (i < Listing.Count -2) And (SP_LineHasNumber(i + 1) = 0) Then
        s := s + Lower(Listing[i + 1]);
    Again:
      lbl := '';
      ps := SP_Util.Pos('label', s); // Label search
      if ps > 0 Then Begin
        Inc(St, FPBASICEditor.CountStatementSeps(Copy(s, 1, ps - 1), 0));
        InString := InAString(Copy(s, 1, ps - 1));
        If not InString then Begin
          Inc(ps, 5);
          while (ps < length(s)) and (s[ps] <= ' ') do inc(ps);
          if (ps < length(s)) and (s[ps] = '@') Then begin
            Inc(ps);
            while (ps <= length(s)) and (s[ps] in ['0'..'9', 'a'..'z', '_']) do Begin
              lbl := lbl + s[ps];
              inc(ps);
            end;
          end;
          If lbl <> '' Then
            AddToList(PoI_Label, lbl, i, St);
          s := Copy(s, ps);
          Goto Again;
        End;
      End Else Begin
        ps := SP_Util.Pos('def proc', s); ofs := 8; // Procedure search
        If ps = 0 then begin
          ps := SP_Util.Pos('def fn', s); ofs := 6;// Look for a function if no procedures found
        end;
        if ps > 0 Then Begin
          Inc(St, FPBASICEditor.CountStatementSeps(Copy(s, 1, ps - 1), 0));
          InString := InAString(Copy(s, 1, ps - 1));
          If Not InString Then Begin
            Inc(ps, ofs);
            while (ps < length(s)) and (s[ps] <= ' ') do inc(ps);
            while (ps <= length(s)) and (s[ps] in ['0'..'9', 'a'..'z', '_']) do Begin
              lbl := lbl + s[ps];
              inc(ps);
            end;
            while (ps < length(s)) and (s[ps] <= ' ') do inc(ps);
            if (ps <= Length(s)) and (s[ps] = '(') Then Begin // Optional parameter list. Let's hoover it up.
              lbl := lbl + '(';
              Inc(ps);
              bc := 0;
              while (ps <= Length(s)) and (s[ps] in ['_', '0'..'9', 'a'..'z', '(', ')', ',', ' ', '$']) Do Begin
                if s[ps] = '(' then Begin
                  Inc(ps);
                  lbl := lbl + '(';
                  Inc(bc);
                end else
                  if s[ps] = ')' then begin
                    Inc(ps);
                    lbl := lbl + ')';
                    if bc = 0 then
                      break
                    else
                      dec(bc);
                  end else begin
                    if s[ps] <> ' ' then
                      lbl := lbl + s[ps];
                    inc(ps);
                  end;
              end;
            end;
            if lbl <> '' Then
              if ofs = 8 then
                AddToList(PoI_Proc, lbl, i, St)
              else
                AddToList(PoI_Fn, lbl, i, St);
            s := Copy(s, ps);
            Goto Again;
          End;
        End;
      End;
    End;

  SP_FillDebugPanel;

end;

end.

