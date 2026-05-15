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

unit SP_MemoUnit;

// SP_Memo - Multiline text editor base class for SpecBAS
//
// Provides plain-text editing: word-wrap, scrollbars, cursor, selection,
// undo/redo, clipboard, tab stops, auto-indent.
// Integrated find bar: Ctrl+F to open, F3/Shift+F3 next/prev, Esc to close.
// Highlights all matches in the text (colour 208) and marks them on the
// vertical scrollbar track via OnPaintAfter.
//
// Subclass SP_BASICEditor (SP_BASICEditorUnit) for BASIC syntax highlighting,
// gutter, bracket matching and smart indent.
// Subclass SP_AmigaGuide for richtext/hyperlink display.

{$INCLUDE SpecBAS.inc}

interface

Uses Math, SysUtils, {$IFNDEF FPC}Vcl.ClipBrd{$ELSE}ClipBrd{$ENDIF}, Types,
     SP_BaseComponentUnit, SP_ContainerUnit, SP_EditUnit, SP_ButtonUnit,
     SP_Util, SP_Errors;

Type

  SP_NotifyEvent = Procedure(Sender: SP_BaseComponent) Of Object;

  TWrappedLineInfo = Record
    RawLine:      Integer;   // Index into fLines for this visual segment
    RawOffset:    Integer;   // Char offset within raw line where segment starts
    Text:         aString;   // Plain text of this visual segment
    StartSyntax:  aString;   // Syntax state at start of segment (subclass use)
    VisualIndent: Integer;   // Extra pixel indent for continuation segments
    Proportional: Boolean;   // True = proportional font for this segment
  End;

  TUndoOpType = (uoNone, uoInsertChar, uoDeleteBack, uoDeleteFwd, uoSplitLine, uoMergeLine, uoBlock);

  TSearchHit = Record
    Line, Col, Len: Integer;
    Colour: Byte;           // highlight colour; 0 = default search highlight
  End;

  SP_SearchInfo = Record
    Line, Position, Length: Integer;
    Split: Boolean;
  End;

  SP_SearchOptions = Set Of (
    soStart, soCursorPos, soForward, soBackwards,
    soInREM, soInString, soMatchCase, soLoop,
    soInSelection, soCondenseSpaces,
    soWholeWords, soVarName, soExpression,
    soAll);

  SP_EvalEvent = Function(Sender: SP_BaseComponent;
                           Const Expr: aString;
                           Var Error: TSP_ErrorCode): aString Of Object;

SP_Memo = Class(SP_BaseComponent)

  Protected

    fLines:            TStringList;
    fMargin:           Integer;
    fCursorLine:       Integer;
    fCursorCol:        Integer;
    fCursorOn:         Boolean;
    fSelLine:          Integer;
    fSelCol:           Integer;
    fTopPixel:         Integer;
    fLeftPixel:        Integer;
    fWordWrap:         Boolean;
    fEditable:         Boolean;
    fVScroll:          SP_BaseComponent;
    fHScroll:          SP_BaseComponent;
    fFlashTimer:       Integer;
    fCursFg, fCursBg:  Integer;
    fBrkFg, fBrkBg,
    fCursUnfocFg,
    fCursUnfocBg:      Integer;
    fDesiredCol:       Integer;
    fDesiredX:         Integer;
    fMouseIsDown:      Boolean;
    fUndoList:         TStringList;
    fRedoList:         TStringList;
    fLastUndoOp:       TUndoOpType;
    fLastUndoLine:     Integer;
    fLastUndoCol:      Integer;
    fOnChange:         SP_EditEvent;
    Compiled_OnChange,
    User_OnChange:     aString;
    fIndentSize:       Integer;
    fWrapDirty:        Boolean;
    fWrapped:          Array of TWrappedLineInfo;
    fWrappedCount:     Integer;
    fRawToFirstWrap:   Array of Integer;
    fLastClientW:      Integer;
    fRebuildingWraps:  Boolean;
    fSuppressUndo:     Boolean;
    fTextMarginLeft:   Integer;
    fTextMarginRight:  Integer;
    fBulkInsert:       Boolean;
    fOnCursorMove:     SP_NotifyEvent;

    // -----------------------------------------------------------------------
    // Search bar state
    // -----------------------------------------------------------------------
    fSearchTerm:       aString;
    fSearchResults:    Array of TSearchHit;
    fSearchCurrent:    Integer;         // Index of focused match (-1 = none)
    fSearchBarVisible: Boolean;
    fSearchWrapped:    Boolean;         // Showing "Wrapped" indicator
    // Child controls - real SP_Container/SP_Edit/SP_Button, like FPEditor
    fSearchPanel:      SP_Container;
    fSearchEdit:       SP_Edit;
    fSearchNextBtn:    SP_Button;       // ▼  Tag = 1
    fSearchPrevBtn:    SP_Button;       // ▲  Tag = -1
    fSearchCloseBtn:   SP_Button;       // ×  Tag = 0

    // Pixel width of the left margin (gutter). Base returns 0.
    Function  ExtraLeftMargin: Integer; Virtual;

    // Pixel width of the right margin (gutter). Base returns 0.
    Function  ExtraRightMargin: Integer; Virtual;

    // Determine which column in the left margin corresponds to the given X pixel.
    Function  MarginColFromX(RawLine, X: Integer): Integer; Virtual;

    // Chars at the start of RawLine that belong to the left margin.
    // Base returns 0. BASIC subclass returns line-number digit count.
    Function  GetLineNumLen(RawLine: Integer): Integer; Virtual;

    // Leading space count for soft-wrap continuation indent.
    // Base returns 0. BASIC subclass returns fLineIndent[RawIdx].
    Function  GetLineContinuationIndent(RawIdx: Integer): Integer; Virtual;

    // Called at start of RebuildWrappedLines, before WrapOneLine loop.
    // Subclass populates per-line arrays (and calls CalcGutterWidth).
    Procedure OnRebuildPerLineData; Virtual;

    // Called after fRawToFirstWrap is built. Subclass validates syntax cache.
    Procedure OnAfterRebuildWraps; Virtual;

    // Called at start of Draw, before the row loop, to warm any display cache
    // over the visible range. firstWL/lastWL are wrapped indices; lastRaw is
    // the highest raw line index visible.
    Procedure PreDrawVisibleLines(firstWL, lastWL, lastRaw: Integer); Virtual;

    // Called whenever a raw line's content changes.
    Procedure OnLineChanged(RawIdx: Integer); Virtual;

    // Called after cursor position changes.
    Procedure OnCursorMoved; Virtual;

    // Returns a display-ready (possibly coloured) string for a wrapped segment.
    Function  FormatLineForDisplay(WrapIdx: Integer): aString; Virtual;

    // Returns the char under the cursor for cursor rendering.
    Function  GetCursorChar(RawLine, RawCol: Integer): aChar; Virtual;

    // Called once before the row loop to pre-fill left margin background.
    Procedure DrawLeftMarginBackground; Virtual;

    // Called per visual row to paint the left margin.
    // WrapIdx = -1 for empty rows beyond last line.
    Procedure DrawLeftMargin(WrapIdx, X, Y, H: Integer); Virtual;

    // Called after selection highlight, before Print, per row.
    // Subclass draws bracket highlights etc.
    Procedure DrawLineDecorations(WrapIdx, X, Y, H: Integer); Virtual;

    // Called when cursor is in the left margin area. Subclass draws digit cursor.
    Procedure DrawMarginCursor(RawLine, RawCol, X, Y: Integer); Virtual;

    // Called when user clicks in the left margin. Subclass fires gutter event.
    Procedure OnMarginClick(WrapIdx, X, Y, Btn: Integer); Virtual;

    // True if typing ch should snap cursor to col 1 and clear leading spaces.
    Function  ShouldSnapToLineStart(ch: aChar): Boolean; Virtual;

    // Ask if the current text warrants a current line highlight
    Function  WantCurrentLineHighlight: Boolean; Virtual;

    // Returns indent string for new line after SplitLine.
    // Base carries spaces from current line (after any margin chars).
    // Subclass calls Inherited then may adjust for smart-indent keywords.
    Function  ComputeAutoIndent: aString; Virtual;

    // Called after any whole-text replacement (undo/redo restore, SetText, Clear)
    // so subclasses can resize per-line arrays and invalidate stale cached state.
    Procedure OnFullTextReplaced; Virtual;

    // Called after any insert/delete of lines so subclasses can shift
    // per-line arrays (breakpoints, line states, bookmarks).
    // AtLine = first affected raw line index; Delta = +n inserted / -n deleted.
    Procedure OnLinesChanged(AtLine, Delta: Integer); Virtual;

    // Determines if leading digits are text (for direct mode) or line numbers (for the editor)
    Function  TreatsLeadingDigitsAsLineNum(RawIdx: Integer): Boolean; Virtual;

    // Returns the proportional rendering mode for a given raw line.
    // Base returns the control's own fProportional setting.
    // Subclass (e.g. SP_AmigaGuide) overrides to return per-line mode.
    Function  GetLineProportional(RawIdx: Integer): Boolean; Virtual;

    // Determine what cursor colours are appropriate
    Procedure GetCursorClrs(Out Fg, Bg: Integer); Virtual;

    // -----------------------------------------------------------------------
    // Internal helpers (accessible to subclasses)
    // -----------------------------------------------------------------------

    Procedure RebuildWrappedLines;
    Function  WrapOneLine(RawIdx, MaxW: Integer): Integer; Virtual;
    // Returns the number of bold characters in a segment of raw line RawIdx
    // from column SegStart to SegEnd (1-based, inclusive).  Used by WrapOneLine
    // to subtract Round(count * iSX) from effectiveMaxW, compensating for the
    // 1-scaled-pixel-per-bold-character overhead that Print() adds at render time.
    // Base implementation returns 0 (no bold); subclasses override as needed.
    Function  BoldCharsInSegment(RawIdx, SegStart, SegEnd: Integer): Integer; Virtual;
    Function  VisibleLines: Integer;
    Function  ClientW: Integer;
    Function  ClientH: Integer;
    Function  VSBWidth: Integer;
    Function  HSBHeight: Integer;
    Procedure UpdateScrollbars;
    Procedure FlashTimer(p: Pointer); Virtual;
    Procedure OnVScroll(Delta, NewPos: aFloat);
    Procedure OnHScroll(Delta, NewPos: aFloat);
    Procedure UpdateDesiredPos;
    Function  WrappedLineOfRaw(RawLine, RawCol: Integer): Integer;
    Procedure RawPosFromMouse(X, Y: Integer; Out RLine, RCol: Integer);
    Procedure DeleteSelection;
    Procedure SetCursorRaw(RLine, RCol: Integer; ExtendSel: Boolean; UpdateDesired: Boolean = True);
    Procedure MoveCursorUp(Extend: Boolean);
    Procedure MoveCursorDown(Extend: Boolean);
    Procedure MoveWordLeft(Extend: Boolean);
    Procedure MoveWordRight(Extend: Boolean);
    Function  TabAdvance: Integer;
    Function  TabRetreat: Integer;
    Procedure IndentSelection;
    Procedure DedentSelection;
    Procedure StoreUndo(Op: TUndoOpType);
    Procedure PerformUndo;
    Procedure PerformRedo;
    Function  UndoSnapshot: aString;
    Function  IsNewUndoBatch(Op: TUndoOpType): Boolean;
    Procedure RestoreUndoSnapshot(s: aString);
    Procedure DeleteCharBack; Virtual;
    Procedure DeleteCharFwd; Virtual;
    Procedure SplitLine;
    Procedure SetWordWrap(b: Boolean);
    Procedure SetTextMargin(v: Integer);
    Procedure SetEditable(b: Boolean);
    Procedure SetCursorLine(l: Integer);
    Procedure SetCursorCol(c: Integer);
    Function  GetLeftOffset: Integer;

    Function  GetTopOffset: Integer; Virtual;
    Function  GetRightOffset: Integer;
    Function  GetBottomOffset: Integer;


    // -----------------------------------------------------------------------
    // Search bar helpers (internal, accessible to subclasses)
    // -----------------------------------------------------------------------
    Function  SearchBarH: Integer;
    Procedure BuildSearchResults;
    Procedure ResizeSearchPanel;
    Procedure SearchPanelPaint(Control: SP_BaseComponent);
    Procedure SearchEditChange(Sender: SP_BaseComponent; Text: aString);
    Procedure SearchEditKeyDown(Sender: SP_BaseComponent; Key: Integer; Down: Boolean; Var Handled: Boolean);
    Procedure SearchBtnClick(Sender: SP_BaseComponent);
    Procedure VScrollPaintAfter(Control: SP_BaseComponent); Virtual;

  Public

    fShowVertSB: BooLean;

    Procedure Draw; Override;
    Function  GetText: aString;
    Procedure SetText(s: aString);
    Procedure InsertChar(ch: aString); Virtual;
    Procedure InsertText(s: aString); Virtual;
    Procedure EnsureCursorVisible;
    Procedure PerformKeyDown(Var Handled: Boolean); Override;
    Procedure PerformKeyUp(Var Handled: Boolean); Override;
    Procedure MouseDown(Sender: SP_BaseComponent; X, Y, Btn: Integer); Override;
    Procedure MouseUp(Sender: SP_BaseComponent; X, Y, Btn: Integer); Override;
    Procedure MouseMove(Sender: SP_BaseComponent; X, Y, Btn: Integer); Override;
    Procedure MouseWheel(Sender: SP_BaseComponent; X, Y, Btn, Delta: Integer; Var Handled: Boolean); Override;
    Procedure DoubleClick(X, Y, Btn: Integer); Override;
    Procedure HasSized; Override;
    Procedure SetBounds(x, y, w, h: Integer); Override;

    Function  PackEditorState: aString;
    Procedure UnpackEditorState(Const State: aString);

    Procedure AddLine(const s: aString);
    Procedure InsertLine(Index: Integer; const s: aString);
    Procedure DeleteLine(Index: Integer);
    Procedure Clear;
    Function  LineCount: Integer;
    Function  GetLine(Index: Integer): aString;
    Procedure SetLine(Index: Integer; const s: aString);
    Procedure GotoLine(RawLine, RawCol: Integer);
    Function  HasSelection: Boolean;
    Procedure SelectAll;
    Procedure SelectWordAtCursor;
    Procedure CopySelection;
    Procedure CutSelection;
    Procedure PasteSelection; Virtual;
    Function  GetSelectedText: aString;
    Procedure GetSelectionOrder(Out L1, C1, L2, C2: Integer);
    Function  GetCharHeight: Integer;
    Function  CharRectFromRawPos(RawLine, ColStart, ColEnd: Integer): TRect;
    Procedure SetShowVertSB(b: Boolean);

    Procedure GetCharPosFromMouse(X, Y: Integer; Out RLine, RCol: Integer);

    // Search bar public API
    Procedure ShowSearchBar;
    Procedure HideSearchBar;
    Procedure FindNext(Forward: Boolean);
    Procedure ClearSearchResults;

    Property Text:       aString      read GetText    write SetText;
    Property WordWrap:   Boolean      read fWordWrap  write SetWordWrap;
    Property TextMarginLeft:  Integer read fTextMarginLeft  write fTextMarginLeft;
    Property TextMarginRight: Integer read fTextMarginRight write fTextMarginRight;
    Property TextMargin:      Integer read fTextMarginLeft  write SetTextMargin;
    Property Editable:   Boolean      read fEditable  write SetEditable;
    Property Lines:      TStringList  read fLines;
    Property IndentSize: Integer      read fIndentSize write fIndentSize;
    Property OnChange:   SP_EditEvent read fOnChange   write fOnChange;
    Property CursorLine: Integer      read fCursorLine  write SetCursorLine;
    Property CursorCol:  Integer      read fCursorCol  write SetCursorCol;
    Property Margin:     Integer      read fMargin     write fMargin;
    Property WrappedCount: Integer    read fWrappedCount;
    Property OnCursorMove: SP_NotifyEvent read fOnCursorMove write fOnCursorMove;
    Property CharHeight: Integer      read GetCharHeight;
    Property ShowVertSB: Boolean      read fShowVertSB write SetShowVertSB;

    Constructor Create(Owner: SP_BaseComponent);
    Destructor  Destroy; Override;

    Procedure RegisterProperties; Override;
    Procedure RegisterMethods; Override;

    Procedure Set_Text(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
    Function  Get_Text: aString;
    Procedure Set_Editable(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
    Function  Get_Editable: aString;
    Procedure Set_WordWrap(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
    Function  Get_WordWrap: aString;
    Procedure Set_OnChange(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
    Function  Get_OnChange: aString;
    Procedure Set_LineCount(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
    Function  Get_LineCount: aString;
    Procedure Set_Line(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
    Function  Get_Line: aString;
    Procedure Set_TopLine(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
    Function  Get_TopLine: aString;
    Procedure Set_CursorLine(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
    Function  Get_CursorLine: aString;
    Procedure Set_CursorCol(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
    Function  Get_CursorCol: aString;

    Procedure Method_AddLine(Params: Array of aString; Var Error: TSP_ErrorCode);
    Procedure Method_InsertLine(Params: Array of aString; Var Error: TSP_ErrorCode);
    Procedure Method_DeleteLine(Params: Array of aString; Var Error: TSP_ErrorCode);
    Procedure Method_Clear(Params: Array of aString; Var Error: TSP_ErrorCode);
    Procedure Method_SelectAll(Params: Array of aString; Var Error: TSP_ErrorCode);

End;

Const
  MemoLineBg   = 249;   // Current-line highlight colour (matches original)
  MemoGutterBg = 246;   // Left margin background (for subclass use)
  MemoSearchClr = 208;  // Search hit paper highlight (matches FPEditor SearchClr)
  MemoSearchWrapClr = 2;

implementation

Uses SP_Components, SP_SysVars, SP_Input, SP_Sound,
     SP_Interpret_PostFix, SP_ScrollBarUnit;

// ---------------------------------------------------------------------------
// Construction / Destruction
// ---------------------------------------------------------------------------

Constructor SP_Memo.Create(Owner: SP_BaseComponent);
Begin
  Inherited;
  fTypeName  := 'spMemo';
  fShowVertSB := True;
  fCanFocus  := True;
  fWantTab   := True;
  fBorder    := True;
  fEditable  := True;
  fWordWrap  := True;
  fWrapDirty := True;
  fTextMarginLeft  := 0;
  fTextMarginRight := 0;
  fLines     := TStringList.Create;
  fUndoList  := TStringList.Create;
  fRedoList  := TStringList.Create;
  CursorLine       := 0;  CursorCol   := 1;
  fSelLine         := 0;  fSelCol     := 1;
  fTopPixel        := 0;  fLeftPixel  := 0;
  fLastUndoOp      := uoNone;
  fLastUndoLine    := 0;  fLastUndoCol := 1;
  fMouseIsDown     := False;
  fIndentSize      := 3;
  fLastClientW     := -1;
  fRebuildingWraps := False;
  fCursFg      := 9;    fCursBg      := 15;
  fCursUnfocFg := 236;  fCursUnfocBg := 244;
  fBrkFg       := 9;    fBrkBg       := 14;
  fColour      := 7;
  fBackgroundClr := SP_UIBackground;
  fFontClr       := SP_UIText;
  fDesiredCol := 1;
  fDesiredX   := 0;

  // Search state
  fSearchTerm       := '';
  fSearchCurrent    := -1;
  fSearchBarVisible := False;
  fSearchWrapped    := False;
  SetLength(fSearchResults, 0);

  fVScroll := SP_ScrollBar.Create(Self);
  SP_ScrollBar(fVScroll).Border   := False;
  SP_ScrollBar(fVScroll).Kind     := spVertical;
  SP_ScrollBar(fVScroll).OnScroll := OnVScroll;
  fVScroll.OnPaintAfter           := VScrollPaintAfter;

  fHScroll := SP_ScrollBar.Create(Self);
  SP_ScrollBar(fHScroll).Border   := False;
  SP_ScrollBar(fHScroll).Kind     := spHorizontal;
  SP_ScrollBar(fHScroll).Visible  := False;
  SP_ScrollBar(fHScroll).OnScroll := OnHScroll;

  // Search panel - real SP_Container + SP_Edit + SP_Buttons, like FPEditor
  fSearchPanel := SP_Container.Create(Self);
  fSearchPanel.Visible      := False;
  fSearchPanel.BackgroundClr := 251; //SP_UIWindowBack;
  fSearchPanel.Border       := False;
  fSearchPanel.OnPaintAfter := SearchPanelPaint;
  fSearchPanel.Transparent  := False;

  fSearchEdit := SP_Edit.Create(fSearchPanel);
  fSearchEdit.Border       := True;
  fSearchEdit.BackgroundClr := SP_UIBackground;
  fSearchEdit.OnChange     := SearchEditChange;
  fSearchEdit.OnKeyDown    := SearchEditKeyDown;
  fSearchEdit.WantTAB      := True;

  fSearchNextBtn := SP_Button.Create(fSearchPanel);
  fSearchNextBtn.Caption    := #252;   // ▼
  fSearchNextBtn.Tag        := 1;
  fSearchNextBtn.BackgroundClr := SP_UIWindowBack;
  fSearchNextBtn.OnClick    := SearchBtnClick;

  fSearchPrevBtn := SP_Button.Create(fSearchPanel);
  fSearchPrevBtn.Caption    := #251;   // ▲
  fSearchPrevBtn.Tag        := -1;
  fSearchPrevBtn.BackgroundClr := SP_UIWindowBack;
  fSearchPrevBtn.OnClick    := SearchBtnClick;

  fSearchCloseBtn := SP_Button.Create(fSearchPanel);
  fSearchCloseBtn.Caption   := #244;  // ×
  fSearchCloseBtn.Tag       := 0;
  fSearchCloseBtn.BackgroundClr := SP_UIWindowBack;
  fSearchCloseBtn.OnClick   := SearchBtnClick;

  AddOverrideControl(Self);
  fFlashTimer := AddTimer(Self, FLASHINTERVAL, FlashTimer, False, False)^.ID;
  If fLines.Count = 0 Then fLines.Add('');
End;

Destructor SP_Memo.Destroy;
Begin
  RemoveTimer(fFlashTimer);
  fLines.Free; fUndoList.Free; fRedoList.Free;
  Inherited;
End;

// ---------------------------------------------------------------------------
// Virtual hook defaults
// ---------------------------------------------------------------------------

Function  SP_Memo.ExtraLeftMargin: Integer;                               Begin Result := fTextMarginLeft;  End;
Function  SP_Memo.ExtraRightMargin: Integer;                              Begin Result := fTextMarginRight; End;
Function  SP_Memo.GetLineNumLen(RawLine: Integer): Integer;               Begin Result := 0; End;
Function  SP_Memo.GetLineContinuationIndent(RawIdx: Integer): Integer;    Begin Result := 0; End;
Function  SP_Memo.BoldCharsInSegment(RawIdx, SegStart, SegEnd: Integer): Integer; Begin Result := 0; End;
Procedure SP_Memo.OnRebuildPerLineData;                                   Begin End;
Procedure SP_Memo.OnAfterRebuildWraps;                                    Begin End;
Procedure SP_Memo.PreDrawVisibleLines(firstWL, lastWL, lastRaw: Integer); Begin End;
Procedure SP_Memo.OnLineChanged(RawIdx: Integer);                         Begin ClearSearchResults; End;
Procedure SP_Memo.OnLinesChanged(AtLine, Delta: Integer);                 Begin End;
Procedure SP_Memo.OnFullTextReplaced;                                     Begin End;
Procedure SP_Memo.OnCursorMoved;                                          Begin End;
Procedure SP_Memo.DrawLeftMarginBackground;                               Begin End;
Procedure SP_Memo.DrawLeftMargin(WrapIdx, X, Y, H: Integer);              Begin End;
Procedure SP_Memo.DrawLineDecorations(WrapIdx, X, Y, H: Integer);         Begin End;
Procedure SP_Memo.DrawMarginCursor(RawLine, RawCol, X, Y: Integer);       Begin End;
Procedure SP_Memo.OnMarginClick(WrapIdx, X, Y, Btn: Integer);             Begin End;
Function  SP_Memo.ShouldSnapToLineStart(ch: aChar): Boolean;              Begin Result := False; End;
Function  SP_Memo.WantCurrentLineHighlight: Boolean;                      Begin Result := True; End;
Function  SP_Memo.MarginColFromX(RawLine, X: Integer): Integer;           Begin Result := 1; End;
Function  SP_Memo.TreatsLeadingDigitsAsLineNum(RawIdx: Integer): Boolean; Begin Result := True; End;
Function  SP_Memo.GetLineProportional(RawIdx: Integer): Boolean;          Begin Result := Proportional; End;

Function SP_Memo.FormatLineForDisplay(WrapIdx: Integer): aString;
Begin
  Result := InsertLiterals(fWrapped[WrapIdx].Text);
End;

Function SP_Memo.GetCursorChar(RawLine, RawCol: Integer): aChar;
Begin
  If RawCol <= Length(fLines[RawLine]) Then
    Result := fLines[RawLine][RawCol]
  Else
    Result := ' ';
End;

Function SP_Memo.ComputeAutoIndent: aString;
Var s: aString; i, numLen: Integer;
Begin
  Result := '';
  s      := fLines[fCursorLine];
  numLen := GetLineNumLen(fCursorLine);
  i      := numLen + 1;
  While (i <= Length(s)) And (s[i] = ' ') Do Begin
    Result := Result + ' ';
    Inc(i);
  End;
End;

// ---------------------------------------------------------------------------
// Layout helpers
// ---------------------------------------------------------------------------

Function SP_Memo.VSBWidth: Integer;
Begin If fVScroll.Visible Then Result := fVScroll.Width Else Result := 0; End;

Function SP_Memo.HSBHeight: Integer;
Begin If fHScroll.Visible Then Result := fHScroll.Height Else Result := 0; End;

Function SP_Memo.ClientW: Integer;
Begin
  Result := fWidth - GetLeftOffset - GetRightOffset - VSBWidth - ExtraLeftMargin - ExtraRightMargin;
  If Result < 0 Then Result := 0;
End;

Function SP_Memo.ClientH: Integer;
Begin
  Result := fHeight - GetTopOffset - GetBottomOffset - HSBHeight;
  If fSearchBarVisible Then Dec(Result, SearchBarH);
  If Result < 0 Then Result := 0;
End;

Function SP_Memo.VisibleLines: Integer;
Var
  cfH: Integer;
Begin
  cfH := Max(1, Round(iFH * iSY));
  Result := ClientH Div cfH;
End;

// ---------------------------------------------------------------------------
// Word-wrap
// ---------------------------------------------------------------------------

Function SP_Memo.WrapOneLine(RawIdx, MaxW: Integer): Integer;
Var
  measureStr,
  s:             aString;
  Seg:           TWrappedLineInfo;
  Idx, LastSep, i,
  wLen, segStart: Integer;
  cfW:           Integer;
  BreakAt:       Integer;
  indentW:       Integer;
  effectiveMaxW: Integer;
  firstSeg:      Boolean;
  numLen:        Integer;
  prop:          Boolean;
Begin
  Result  := 0;
  s       := fLines[RawIdx];
  cfW     := Max(1, Round(iFW * iSX));
  If MaxW <= 0 Then MaxW := 9999;

  indentW := 0;
  If fWordWrap Then indentW := GetLineContinuationIndent(RawIdx) * cfW;

  Seg.StartSyntax := '';

  If s = '' Then Begin
    If fWrappedCount >= Length(fWrapped) Then SetLength(fWrapped, fWrappedCount + 64);
    Seg.RawLine      := RawIdx;
    Seg.RawOffset    := 1;
    Seg.Text         := '';
    Seg.VisualIndent := 0;
    Seg.Proportional := GetLineProportional(RawIdx);
    fWrapped[fWrappedCount] := Seg;
    Inc(fWrappedCount); Inc(Result);
    Exit;
  End;

  numLen   := GetLineNumLen(RawIdx);
  segStart := 1;
  LastSep  := 0;
  firstSeg := True;

  If (numLen > 0) And TreatsLeadingDigitsAsLineNum(RawIdx) Then Begin
    segStart := numLen + 1;
    If segStart > Length(s) Then Begin
      If fWrappedCount >= Length(fWrapped) Then SetLength(fWrapped, fWrappedCount + 64);
      Seg.RawLine      := RawIdx;
      Seg.RawOffset    := segStart;
      Seg.Text         := '';
      Seg.VisualIndent := 0;
      Seg.Proportional := GetLineProportional(RawIdx);
      fWrapped[fWrappedCount] := Seg;
      Inc(fWrappedCount); Inc(Result);
      Exit;
    End;
  End;

  Idx           := segStart;
  effectiveMaxW := MaxW;

  prop := fProportional;
  fProportional := GetLineProportional(RawIdx);
  While Idx <= Length(s) Do Begin
    If fProportional Then Begin
      measureStr := Copy(s, segStart, Idx - segStart + 1);
      For i := 1 To Length(measureStr) Do If measureStr[i] = #1 Then measureStr[i] := ' ';
      wLen := TextWidth(measureStr);
      // Add bold rendering overhead: Print() advances each bold character by an
      // extra Round(1 * ScaleX) pixel.  BoldCharsInSegment returns 0 in the base
      // class; subclasses (SP_AmigaGuide, SP_BASICEditor) override it.
      Inc(wLen, Round(BoldCharsInSegment(RawIdx, segStart, Idx) * iSX));
    End Else
      wLen := (Idx - segStart + 1) * cfW;

    If wLen > effectiveMaxW Then Begin
      If LastSep > segStart Then BreakAt := LastSep Else BreakAt := Idx - 1;

      // Prevent splitting AmigaGuide #1 button placeholders across lines
      If (BreakAt >= segStart) And (BreakAt <= Length(s)) And (s[BreakAt] = #1) Then Begin
        // Back up to the start of the #1 block
        While (BreakAt > segStart) And (s[BreakAt] = #1) Do Dec(BreakAt);

        // If the #1 block is the very first thing on the line, we MUST NOT split it.
        // Force the entire block onto this line so it stays intact as a single widget.
        If (BreakAt = segStart) And (s[segStart] = #1) Then Begin
          While (BreakAt < Length(s)) And (s[BreakAt+1] = #1) Do Inc(BreakAt);
        End;
      End;

      If BreakAt < segStart Then BreakAt := segStart;

      If fWrappedCount >= Length(fWrapped) Then SetLength(fWrapped, fWrappedCount + 64);
      Seg.RawLine      := RawIdx;
      Seg.RawOffset    := segStart;
      Seg.Text         := Copy(s, segStart, BreakAt - segStart + 1);
      Seg.VisualIndent := IfThen(firstSeg, 0, indentW);
      Seg.Proportional := fProportional;
      fWrapped[fWrappedCount] := Seg;
      Inc(fWrappedCount); Inc(Result);

      firstSeg      := False;
      effectiveMaxW := MaxW - indentW;
      segStart      := BreakAt + 1;
      If (segStart <= Length(s)) And (s[segStart] = ' ') Then Inc(segStart);
      LastSep := 0;
      Idx     := segStart;
      Continue;
    End;
    If s[Idx] In [' ', '(', ')', ',', ';', '"', #39, '=', '+', '-', '/', '*', '^', '%', '$', '|', '&', ':', '>', '<'] Then LastSep := Idx;
    Inc(Idx);
  End;

  If segStart <= Length(s) Then Begin
    If fWrappedCount >= Length(fWrapped) Then SetLength(fWrapped, fWrappedCount + 64);
    Seg.RawLine      := RawIdx;
    Seg.RawOffset    := segStart;
    Seg.Text         := Copy(s, segStart, Length(s));
    Seg.VisualIndent := IfThen(firstSeg, 0, indentW);
    Seg.Proportional := fProportional;
    fWrapped[fWrappedCount] := Seg;
    Inc(fWrappedCount); Inc(Result);
  End;
  fProportional := prop;
End;

Procedure SP_Memo.RebuildWrappedLines;
Var i, maxW: Integer;
Begin
  fWrappedCount := 0;
  SetLength(fWrapped, Max(fLines.Count * 2, 64));

  OnRebuildPerLineData;  // Subclass fills per-line arrays, calls CalcGutterWidth etc.

  If fWordWrap Then maxW := ClientW Else maxW := 9999;

  For i := 0 To fLines.Count - 1 Do WrapOneLine(i, maxW);
  SetLength(fWrapped, fWrappedCount);

  SetLength(fRawToFirstWrap, fLines.Count);
  For i := 0 To fLines.Count - 1 Do fRawToFirstWrap[i] := -1;
  For i := 0 To fWrappedCount - 1 Do
    If fRawToFirstWrap[fWrapped[i].RawLine] < 0 Then
      fRawToFirstWrap[fWrapped[i].RawLine] := i;

  OnAfterRebuildWraps;   // Subclass validates syntax cache size etc.

  fWrapDirty := False;
  UpdateScrollbars;
End;

// ---------------------------------------------------------------------------
// Scrollbars
// ---------------------------------------------------------------------------

Procedure SP_Memo.OnVScroll(Delta, NewPos: aFloat); Begin fTopPixel := Trunc(NewPos); Paint; End;
Procedure SP_Memo.OnHScroll(Delta, NewPos: aFloat); Begin fLeftPixel := Trunc(NewPos); Paint; End;

Procedure SP_Memo.UpdateScrollbars;
Var
  bOffL, bOffR, bOffT, bOffB, sw, sh, vx, vy, vw, vh, hx, hy, hw, hh, i: Integer;
  cfH, cfW, j, maxW, totalH, newClientW, lm: Integer;
  needV, needH: Boolean;
  fullW, fullH: Integer;
  measureStr: aString;
Begin
  bOffL := GetLeftOffset;
  bOffT := GetTopOffset;
  bOffR := GetRightOffset;
  bOffB := GetBottomOffset;
  cfH  := Max(1, Round(iFH * iSY));
  cfW  := Max(1, Round(iFW * iSX));
  sw   := cfW; sh := cfH;
  lm   := ExtraLeftMargin;

  totalH := fWrappedCount * cfH;
  maxW   := 0;
  If Not fWordWrap Then
    For j := 0 To fWrappedCount - 1 Do
      If Proportional Then Begin
        measureStr := fWrapped[j].Text + ' ';
        For i := 1 To Length(measureStr) Do If measureStr[i] = #1 Then measureStr[i] := ' ';
        maxW := Max(maxW, TextWidth(measureStr));
      End Else
        maxW := Max(maxW, (Length(fWrapped[j].Text) + 1) * cfW);

  fullH := fHeight - (bOffT + bOffB);
  fullW := fWidth  - (bOffR + bOffL) - lm;

  needV := totalH > (fullH - sh);
  needH := (Not fWordWrap) And (maxW > (fullW - sw));
  If needV And Not needH Then needV := totalH > fullH;
  If needH And Not needV Then needH := maxW > fullW;

  fVScroll.Visible := needV;
  fHScroll.Visible := needH;

  If fWordWrap Then Begin
    newClientW := fWidth - (bOffL + bOffR) - (Ord(needV) * sw) - lm;
    If newClientW <> fLastClientW Then Begin
      fLastClientW := newClientW;
      fWrapDirty   := True;
    End;
  End;

  If needV Then Begin
    vx := fWidth - bOffR - sw; vy := bOffT;
    vw := sw; vh := fHeight - (bOffB + bOffT) - (Ord(needH) * sh) - (Ord(fSearchBarVisible) * SearchBarH);
    fVScroll.SetBounds(vx, vy, vw, vh);
    SP_ScrollBar(fVScroll).Min      := 0;
    SP_ScrollBar(fVScroll).Max      := Max(fullH, totalH);
    SP_ScrollBar(fVScroll).PageSize := ClientH;
    SP_ScrollBar(fVScroll).Pos      := fTopPixel;
  End Else Begin
    fTopPixel := 0;
    SP_ScrollBar(fVScroll).Pos := 0;
  End;

  If needH Then Begin
    hx := bOffL + lm; hy := fHeight - bOffB - sh;
    hw := fWidth - (bOffL + bOffR) - lm - (Ord(needV) * sw); hh := sh;
    fHScroll.SetBounds(hx, hy, hw, hh);
    SP_ScrollBar(fHScroll).Min      := 0;
    SP_ScrollBar(fHScroll).Max      := Max(ClientW, maxW);
    SP_ScrollBar(fHScroll).PageSize := ClientW;
    SP_ScrollBar(fHScroll).Pos      := fLeftPixel;
  End Else Begin
    fLeftPixel := 0;
    SP_ScrollBar(fHScroll).Pos := 0;
  End;

  If fWrapDirty And Not fRebuildingWraps Then Begin
    fRebuildingWraps := True;
    RebuildWrappedLines;
    fRebuildingWraps := False;
  End;
End;

// ---------------------------------------------------------------------------
// Cursor and selection
// ---------------------------------------------------------------------------

Procedure SP_Memo.SetCursorLine(l: Integer);
Begin

  fCursorLine := l;
  If Assigned(fOnCursorMove) Then
    fOnCursorMove(Self);

End;

Procedure SP_Memo.SetCursorCol(c: Integer);
Begin

  fCursorCol := c;
  If Assigned(fOnCursorMove) Then
    fOnCursorMove(Self);

End;

Function SP_Memo.GetLeftOffset:   Integer; Begin Result := (Ord(fBorder) * 2) + fPaddingLeft;   End;
Function SP_Memo.GetTopOffset:    Integer; Begin Result := (Ord(fBorder) * 2) + fPaddingTop;    End;
Function SP_Memo.GetRightOffset:  Integer; Begin Result := (Ord(fBorder) * 2) + fPaddingRight;  End;
Function SP_Memo.GetBottomOffset: Integer; Begin Result := (Ord(fBorder) * 2) + fPaddingBottom; End;

Function SP_Memo.HasSelection: Boolean;
Begin Result := (fSelLine <> fCursorLine) Or (fSelCol <> fCursorCol); End;

Procedure SP_Memo.GetSelectionOrder(Out L1, C1, L2, C2: Integer);
Begin
  If (fCursorLine < fSelLine) Or
     ((fCursorLine = fSelLine) And (fCursorCol < fSelCol)) Then Begin
    L1 := fCursorLine; C1 := fCursorCol; L2 := fSelLine;    C2 := fSelCol;
  End Else Begin
    L1 := fSelLine;    C1 := fSelCol;    L2 := fCursorLine; C2 := fCursorCol;
  End;
End;

Function SP_Memo.WrappedLineOfRaw(RawLine, RawCol: Integer): Integer;
Var i: Integer; found: Boolean;
Begin
  Result := 0; found := False;
  For i := 0 To fWrappedCount - 1 Do Begin
    If fWrapped[i].RawLine = RawLine Then Begin
      If Not found Then Begin Result := i; found := True; End;
      If fWrapped[i].RawOffset <= RawCol Then Result := i;
    End Else If found And (fWrapped[i].RawLine <> MaxInt) Then Break;
  End;
End;

Procedure SP_Memo.EnsureCursorVisible;
Var cfW, cfH, wl, co, vis: Integer;
Begin
  cfH := Max(1, Round(iFH * iSY));
  cfW := Max(1, Round(iFW * iSX));
  If fWrapDirty Then RebuildWrappedLines;
  If fWrappedCount = 0 Then Exit;
  vis := VisibleLines;
  wl  := WrappedLineOfRaw(fCursorLine, fCursorCol);
  If wl * cfH < fTopPixel Then Begin
    If SP_ScrollBar(fVScroll).Pos <> wl * cfH Then
      SP_ScrollBar(fVScroll).Pos := wl * cfH;
  End Else
    If wl * cfH >= fTopPixel + vis * cfH Then Begin
      If SP_ScrollBar(fVScroll).Pos <> (wl - vis + 1) * cfH Then
        SP_ScrollBar(fVScroll).Pos := (wl - vis + 1) * cfH;
    End;
  If fHScroll.Visible And (fCursorCol > GetLineNumLen(fCursorLine)) Then Begin
    co := fWrapped[wl].VisualIndent +
          Max(0, fCursorCol - fWrapped[wl].RawOffset) * cfW;
    If co < fLeftPixel Then Begin
      If SP_ScrollBar(fHScroll).Pos <> co Then SP_ScrollBar(fHScroll).Pos := co;
    End Else
      If co > fLeftPixel + ClientW - cfW Then Begin
        If SP_ScrollBar(fHScroll).Pos <> co - ClientW + cfW Then
          SP_ScrollBar(fHScroll).Pos := co - ClientW + cfW;
      End;
  End;
End;

Procedure SP_Memo.SetCursorRaw(RLine, RCol: Integer; ExtendSel, UpdateDesired: Boolean);
Begin
  If fLines.Count > 0 Then Begin
    fCursorLine := Max(0, Min(RLine, fLines.Count - 1));
    fCursorCol  := Max(1, Min(RCol,  Length(fLines[fCursorLine]) + 1));
    If Not ExtendSel Then Begin
      fSelLine := fCursorLine;
      fSelCol := fCursorCol;
    End;
  End Else Begin
    CursorLine := 0; CursorCol := 1;
  End;
  If UpdateDesired Then UpdateDesiredPos;
  OnCursorMoved;
  EnsureCursorVisible;
  Paint;
End;

Procedure SP_Memo.MoveCursorUp(Extend: Boolean);
Var wl, cfW, targetX, newRLine, newRCol, prevWl, relX: Integer;
Begin
  If fWrapDirty Then RebuildWrappedLines;
  cfW := Max(1, Round(iFW * iSX));
  If fCursorCol <= GetLineNumLen(fCursorLine) Then
    wl := fRawToFirstWrap[fCursorLine]
  Else
    wl := WrappedLineOfRaw(fCursorLine, fCursorCol);
  prevWl := wl - 1;
  If prevWl < 0 Then Exit;
  newRLine := fWrapped[prevWl].RawLine;
  targetX  := fDesiredX;
  If fDesiredCol <= GetLineNumLen(fCursorLine) Then Begin
    If GetLineNumLen(newRLine) > 0 Then
      newRCol := Min(fDesiredCol, GetLineNumLen(newRLine))
    Else
      newRCol := fWrapped[prevWl].RawOffset;
  End Else Begin
    // Remove the VisualIndent of the target line to find the relative text column
    relX := targetX - fWrapped[prevWl].VisualIndent;
    If relX < 0 Then relX := 0;
    newRCol := fWrapped[prevWl].RawOffset + (relX Div cfW);

    // Crucial Clamp: Prevent the column from spilling into the next wrapped segment
    If (prevWl + 1 < fWrappedCount) And (fWrapped[prevWl + 1].RawLine = newRLine) Then
      newRCol := Min(newRCol, fWrapped[prevWl + 1].RawOffset - 1)
    Else
      newRCol := Min(newRCol, Length(fLines[newRLine]) + 1);
  End;
  SetCursorRaw(newRLine, newRCol, Extend, False);
End;

Procedure SP_Memo.MoveCursorDown(Extend: Boolean);
Var wl, cfW, targetX, newRLine, newRCol, nextWl, relX: Integer;
Begin
  If fWrapDirty Then RebuildWrappedLines;
  cfW := Max(1, Round(iFW * iSX));
  If fCursorCol <= GetLineNumLen(fCursorLine) Then Begin
    wl     := fRawToFirstWrap[fCursorLine];
    nextWl := wl + 1;
    If nextWl >= fWrappedCount Then Exit;
    newRLine := fWrapped[nextWl].RawLine;
    If newRLine = fCursorLine Then
      newRCol := fWrapped[nextWl].RawOffset
    Else Begin
      If GetLineNumLen(newRLine) > 0 Then
        newRCol := Min(fDesiredCol, GetLineNumLen(newRLine))
      Else
        newRCol := fWrapped[nextWl].RawOffset;
    End;
    SetCursorRaw(newRLine, newRCol, Extend);
    Exit;
  End;
  wl     := WrappedLineOfRaw(fCursorLine, fCursorCol);
  nextWl := wl + 1;
  If nextWl >= fWrappedCount Then Exit;
  newRLine := fWrapped[nextWl].RawLine;
  targetX  := fDesiredX;

  // Remove the VisualIndent of the target line to find the relative text column
  relX := targetX - fWrapped[nextWl].VisualIndent;
  If relX < 0 Then relX := 0;
  newRCol  := fWrapped[nextWl].RawOffset + (relX Div cfW);

  // Crucial Clamp: Prevent the column from spilling into the next-next wrapped segment
  If (nextWl + 1 < fWrappedCount) And (fWrapped[nextWl + 1].RawLine = newRLine) Then
    newRCol := Min(newRCol, fWrapped[nextWl + 1].RawOffset - 1)
  Else
    newRCol := Min(newRCol, Length(fLines[newRLine]) + 1);

  SetCursorRaw(newRLine, newRCol, Extend, False);
End;

Procedure SP_Memo.MoveWordLeft(Extend: Boolean);
Var s: aString; p: Integer;
Begin
  s := fLines[fCursorLine] + ' '; p := fCursorCol;
  If (p > 1) And (s[p-1] In Seps) Then Dec(p);
  While (p > 1) And Not (s[p-1] In Seps) Do Dec(p);
  fDesiredCol := p; SetCursorRaw(fCursorLine, p, Extend); UpdateDesiredPos;
End;

Procedure SP_Memo.MoveWordRight(Extend: Boolean);
Var s: aString; p: Integer;
Begin
  s := fLines[fCursorLine] + ' '; p := fCursorCol;
  While (p <= Length(s)) And (s[p] In Seps) Do Inc(p);
  While (p <= Length(s)) And Not (s[p] In Seps) Do Inc(p);
  fDesiredCol := p; SetCursorRaw(fCursorLine, p, Extend); UpdateDesiredPos;
End;

Procedure SP_Memo.UpdateDesiredPos;
Var wl, cfW: Integer;
Begin
  fDesiredCol := fCursorCol;
  cfW := Max(1, Round(iFW * iSX));
  If fWrapDirty Then RebuildWrappedLines;
  If fWrappedCount > 0 Then Begin
    wl := WrappedLineOfRaw(fCursorLine, fCursorCol);
    // Add VisualIndent so fDesiredX represents the absolute visual X
    fDesiredX := Max(0, fCursorCol - fWrapped[wl].RawOffset) * cfW + fWrapped[wl].VisualIndent;
  End Else
    fDesiredX := 0;
End;

Procedure SP_Memo.RawPosFromMouse(X, Y: Integer; Out RLine, RCol: Integer);
Var
  i, bOffL, bOffT, cfH, cfW, wl, col, lm, relX: Integer;
  measureStr: aString;
Begin
  bOffL := GetLeftOffset;
  bOffT := GetTopOffset;
  cfH  := Max(1, Round(iFH * iSY));
  cfW  := Max(1, Round(iFW * iSX));
  lm   := ExtraLeftMargin;
  If fWrapDirty Then RebuildWrappedLines;
  If fWrappedCount = 0 Then Exit;

  // --- MARGIN CLICK/DRAG LOGIC ---
  If (lm > 0) And (X < bOffL + lm) Then Begin
    wl := (fTopPixel Div cfH) + ((Y - bOffT + (fTopPixel Mod cfH)) Div cfH);
    wl := Max(0, Min(wl, fWrappedCount - 1));
    OnMarginClick(wl, X, Y, 1);

    RLine := fWrapped[wl].RawLine;

    // Ask the subclass exactly which column the mouse X coordinate lands on!
    If (wl = 0) Or (fWrapped[wl - 1].RawLine <> RLine) Then Begin
      RCol      := MarginColFromX(RLine, X);
      fDesiredX := 0;
    End Else Begin
      RCol      := fWrapped[wl].RawOffset;
      fDesiredX := fWrapped[wl].VisualIndent;
    End;

    fDesiredCol := RCol;
    Exit;
  End;

  // --- TEXT AREA CLICK/DRAG LOGIC ---
  wl    := (fTopPixel Div cfH) + ((Y - bOffT + (fTopPixel Mod cfH)) Div cfH);
  If wl >= fWrappedCount Then Begin
    RLine := fWrappedCount;
    Exit;
  End;
  wl    := Max(0, Min(wl, fWrappedCount - 1));
  RLine := fWrapped[wl].RawLine;

  // Guard: wl may land on an injected padding row (RawLine = MaxInt in
  // AmigaGuide, or any out-of-range value inserted by a subclass).
  // Walk backwards to the nearest real line.
  While (RLine < 0) Or (RLine >= fLines.Count) Do Begin
    Dec(wl);
    If wl < 0 Then Begin RLine := 0; RCol := 1; Exit; End;
    RLine := fWrapped[wl].RawLine;
  End;

  relX := X + fLeftPixel - bOffL - lm - fWrapped[wl].VisualIndent;
  If relX < 0 Then relX := 0;

  If Proportional Then Begin
    col := fWrapped[wl].RawOffset;
    While col <= Length(fLines[RLine]) Do Begin
      measureStr := Copy(fLines[RLine], fWrapped[wl].RawOffset, col - fWrapped[wl].RawOffset + 1);
      For i := 1 To Length(measureStr) Do If measureStr[i] = #1 Then measureStr[i] := ' ';
      If TextWidth(measureStr) >= relX Then Break;
      Inc(col);
    End;
    RCol := col;
    If (wl + 1 < fWrappedCount) And (fWrapped[wl + 1].RawLine = RLine) Then
      RCol := Min(RCol, fWrapped[wl + 1].RawOffset - 1);
  End Else Begin
    col  := relX Div cfW;
    RCol := fWrapped[wl].RawOffset + col;
    If (wl + 1 < fWrappedCount) And (fWrapped[wl + 1].RawLine = RLine) Then
      RCol := Min(RCol, fWrapped[wl + 1].RawOffset - 1)
    Else
      RCol := Max(1, Min(RCol, Length(fLines[RLine]) + 1));
  End;
End;

// ---------------------------------------------------------------------------
// Tab helpers
// ---------------------------------------------------------------------------

Function SP_Memo.TabAdvance: Integer;
Var numLen, textCol, nextStop: Integer;
Begin
  numLen  := GetLineNumLen(fCursorLine);
  textCol := fCursorCol - numLen;
  If textCol < 1 Then textCol := 1;
  If textCol < 2 Then nextStop := 2
  Else nextStop := 2 + ((textCol - 2) Div fIndentSize + 1) * fIndentSize;
  Result := nextStop - textCol;
  If Result < 1 Then Result := 1;
End;

Function SP_Memo.TabRetreat: Integer;
Var numLen, textCol, prevStop: Integer;
Begin
  numLen  := GetLineNumLen(fCursorLine);
  textCol := fCursorCol - numLen;
  If textCol < 1 Then textCol := 1;
  If textCol <= 2 Then prevStop := 1
  Else prevStop := 2 + ((textCol - 3) Div fIndentSize) * fIndentSize;
  Result := textCol - prevStop;
  If Result < 1 Then Result := 1;
End;

Procedure SP_Memo.IndentSelection;
Var L1, C1, L2, C2, i, numLen, spaces, textCol, curDepth: Integer; s: aString;
Begin
  GetSelectionOrder(L1, C1, L2, C2);
  StoreUndo(uoBlock);
  For i := L1 To L2 Do Begin
    s := fLines[i]; numLen := GetLineNumLen(i);
    textCol := numLen + 1;
    While (textCol <= Length(s)) And (s[textCol] = ' ') Do Inc(textCol);
    curDepth := textCol - numLen - 1;
    If curDepth < 1 Then spaces := 1
    Else If curDepth < 2 Then spaces := 2 - curDepth
    Else spaces := fIndentSize - ((curDepth - 2) Mod fIndentSize);
    If spaces < 1 Then spaces := fIndentSize;
    fLines[i] := Copy(s, 1, numLen) +
                 SP_StringOfChar(' ', curDepth + spaces) +
                 Copy(s, textCol, Length(s));
    OnLineChanged(i);
  End;
  CursorCol := Max(1, Min(fCursorCol, Length(fLines[fCursorLine]) + 1));
  fWrapDirty := True;
End;

Procedure SP_Memo.DedentSelection;
Var L1, C1, L2, C2, i, numLen, spaces, textCol, curDepth, prevStop: Integer; s: aString;
Begin
  GetSelectionOrder(L1, C1, L2, C2);
  StoreUndo(uoBlock);
  For i := L1 To L2 Do Begin
    s := fLines[i]; numLen := GetLineNumLen(i);
    textCol := numLen + 1;
    While (textCol <= Length(s)) And (s[textCol] = ' ') Do Inc(textCol);
    curDepth := textCol - numLen - 1;
    If curDepth <= 0 Then Continue;
    If curDepth <= 1 Then prevStop := 0
    Else If curDepth <= 2 Then prevStop := 1
    Else prevStop := 2 + ((curDepth - 3) Div fIndentSize) * fIndentSize;
    spaces := curDepth - prevStop;
    If spaces < 1 Then spaces := 1;
    fLines[i] := Copy(s, 1, numLen) +
                 SP_StringOfChar(' ', curDepth - spaces) +
                 Copy(s, textCol, Length(s));
    OnLineChanged(i);
  End;
  fWrapDirty := True;
End;

// ---------------------------------------------------------------------------
// Editing
// ---------------------------------------------------------------------------

Function SP_Memo.UndoSnapshot: aString;
Var i: Integer;
Begin
  Result := LongWordToString(fCursorLine) + LongWordToString(fCursorCol) +
            LongWordToString(fSelLine)    + LongWordToString(fSelCol);
  For i := 0 To fLines.Count - 1 Do Result := Result + fLines[i] + #0;
End;

Procedure SP_Memo.RestoreUndoSnapshot(s: aString);
Var p, i: Integer;
Begin
  CursorLine := pLongWord(@s[1])^; CursorCol := pLongWord(@s[5])^;
  fSelLine   := pLongWord(@s[9])^; fSelCol   := pLongWord(@s[13])^;
  fLines.Clear; p := 17;
  While p <= Length(s) Do Begin
    i := p;
    While (i <= Length(s)) And (s[i] <> #0) Do Inc(i);
    fLines.Add(Copy(s, p, i - p)); p := i + 1;
  End;
  fWrapDirty := True; RebuildWrappedLines;
  OnFullTextReplaced;
  EnsureCursorVisible; Paint;
End;

Function SP_Memo.IsNewUndoBatch(Op: TUndoOpType): Boolean;
Begin
  If Op <> fLastUndoOp Then Begin Result := True; Exit; End;
  Case Op Of
    uoInsertChar: Result := (fCursorLine <> fLastUndoLine) Or (fCursorCol <> fLastUndoCol + 1);
    uoDeleteBack: Result := (fCursorLine <> fLastUndoLine) Or (fCursorCol <> fLastUndoCol - 1);
    uoDeleteFwd:  Result := (fCursorLine <> fLastUndoLine) Or (fCursorCol <> fLastUndoCol);
    Else          Result := True;
  End;
End;

Procedure SP_Memo.StoreUndo(Op: TUndoOpType);
Begin
  If fSuppressUndo Then Exit;
  fRedoList.Clear;
  If IsNewUndoBatch(Op) Then fUndoList.Add(UndoSnapshot);
  fLastUndoOp := Op; fLastUndoLine := fCursorLine; fLastUndoCol := fCursorCol;
End;

Procedure SP_Memo.PerformUndo;
Begin
  If fUndoList.Count > 0 Then Begin
    fRedoList.Add(UndoSnapshot);
    RestoreUndoSnapshot(fUndoList[fUndoList.Count - 1]);
    fUndoList.Delete(fUndoList.Count - 1);
    fLastUndoOp := uoNone;
  End;
End;

Procedure SP_Memo.PerformRedo;
Begin
  If fRedoList.Count > 0 Then Begin
    fUndoList.Add(UndoSnapshot);
    RestoreUndoSnapshot(fRedoList[fRedoList.Count - 1]);
    fRedoList.Delete(fRedoList.Count - 1);
    fLastUndoOp := uoNone;
  End;
End;

// Pack the complete editor state (undo/redo stacks, scroll position, cursor,
// selection, last-undo tracking) into a single aString for external storage.
// fLines content is NOT included - that is handled separately by the Listing.
// The packed string can be restored by UnpackEditorState.
//
// Format (all integers as 4-byte LongWord):
//   topPixel, leftPixel, cursorLine, cursorCol, selLine, selCol,
//   lastUndoOp, lastUndoLine, lastUndoCol,
//   undoCount, [len, bytes] * undoCount,
//   redoCount, [len, bytes] * redoCount
Function SP_Memo.PackEditorState: aString;
Var
  i, n: Integer;
  entry: aString;
Begin
  Result := LongWordToString(fTopPixel)           +
            LongWordToString(fLeftPixel)           +
            LongWordToString(fCursorLine)          +
            LongWordToString(fCursorCol)           +
            LongWordToString(fSelLine)             +
            LongWordToString(fSelCol)              +
            LongWordToString(Ord(fLastUndoOp))     +
            LongWordToString(fLastUndoLine)        +
            LongWordToString(fLastUndoCol)         +
            LongWordToString(fUndoList.Count);
  For i := 0 To fUndoList.Count - 1 Do Begin
    entry  := fUndoList[i];
    n      := Length(entry);
    Result := Result + LongWordToString(n) + entry;
  End;
  Result := Result + LongWordToString(fRedoList.Count);
  For i := 0 To fRedoList.Count - 1 Do Begin
    entry  := fRedoList[i];
    n      := Length(entry);
    Result := Result + LongWordToString(n) + entry;
  End;
End;

// Restore undo/redo stacks, scroll position, cursor, and selection from a
// PackEditorState snapshot.  fLines must already contain the correct content
// before calling (typically via EditorHost_LoadFromListing/SetText).
// Safe to call immediately after SetText - it does NOT call Clear.
Procedure SP_Memo.UnpackEditorState(Const State: aString);
Var
  p, i, cnt, len: Integer;
Begin
  // Minimum: 9 LongWords (36 bytes) for header + 2 count fields
  If Length(State) < 40 Then Exit;
  p := 1;

  fTopPixel     := pLongWord(@State[p])^; Inc(p, 4);
  fLeftPixel    := pLongWord(@State[p])^; Inc(p, 4);
  CursorLine    := pLongWord(@State[p])^; Inc(p, 4);
  CursorCol     := pLongWord(@State[p])^; Inc(p, 4);
  fSelLine      := pLongWord(@State[p])^; Inc(p, 4);
  fSelCol       := pLongWord(@State[p])^; Inc(p, 4);
  fLastUndoOp   := TUndoOpType(pLongWord(@State[p])^); Inc(p, 4);
  fLastUndoLine := pLongWord(@State[p])^; Inc(p, 4);
  fLastUndoCol  := pLongWord(@State[p])^; Inc(p, 4);

  fUndoList.Clear;
  If p + 3 > Length(State) Then Exit;
  cnt := pLongWord(@State[p])^; Inc(p, 4);
  For i := 0 To cnt - 1 Do Begin
    If p + 3 > Length(State) Then Break;
    len := pLongWord(@State[p])^; Inc(p, 4);
    If p + len - 1 > Length(State) Then Break;
    fUndoList.Add(Copy(State, p, len)); Inc(p, len);
  End;

  fRedoList.Clear;
  If p + 3 > Length(State) Then Exit;
  cnt := pLongWord(@State[p])^; Inc(p, 4);
  For i := 0 To cnt - 1 Do Begin
    If p + 3 > Length(State) Then Break;
    len := pLongWord(@State[p])^; Inc(p, 4);
    If p + len - 1 > Length(State) Then Break;
    fRedoList.Add(Copy(State, p, len)); Inc(p, len);
  End;

  // Sync scroll bars to restored positions
  If fVScroll.Visible Then SP_ScrollBar(fVScroll).Pos := fTopPixel;
  If fHScroll.Visible Then SP_ScrollBar(fHScroll).Pos := fLeftPixel;
  EnsureCursorVisible;
  Paint;
End;

Procedure SP_Memo.DeleteSelection;
Var L1, C1, L2, C2, i: Integer; s: aString;
Begin
  If Not HasSelection Then Exit;
  GetSelectionOrder(L1, C1, L2, C2);
  StoreUndo(uoBlock);
  If L1 = L2 Then Begin
    s := fLines[L1];
    fLines[L1] := Copy(s, 1, C1 - 1) + Copy(s, C2, Length(s));
  End Else Begin
    s := Copy(fLines[L1], 1, C1 - 1) + Copy(fLines[L2], C2, Length(fLines[L2]));
    fLines[L1] := s;
    For i := L1 + 1 To L2 Do fLines.Delete(L1 + 1);
    OnLinesChanged(L1 + 1, -(L2 - L1));
  End;
  CursorLine := L1; fCursorCol := C1; fSelLine := L1; fSelCol := C1;
  fWrapDirty  := True; OnLineChanged(L1);
End;

Procedure SP_Memo.InsertChar(ch: aString);
Var
  s: aString;
  p: Integer;
  wasSel: Boolean;
Begin
  // Track if we had a selection so we don't accidentally overwrite the char
  // immediately following a replaced block of text.
  wasSel := HasSelection;
  If wasSel Then DeleteSelection Else StoreUndo(uoInsertChar);

  If fLines.Count = 0 Then fLines.Add('');

  If (ch <> '') And ShouldSnapToLineStart(ch[1]) Then Begin
    s := fLines[fCursorLine];
    If s <> '' Then Begin
      p := 1;
      While (p <= Length(s)) And (s[p] = ' ') Do Inc(p);
      If p > Length(s) Then Begin
        fLines[fCursorLine] := ''; fCursorCol := 1; fSelCol := 1;
      End;
    End;
  End;

  s := fLines[fCursorLine];

  // OVERWRITE MODE LOGIC
  // If INSERT is false, we had no selection, and we aren't at the end of the line:
  If (Not INSERT) And (Not wasSel) And (fCursorCol <= Length(s)) Then
    fLines[fCursorLine] := Copy(s, 1, fCursorCol - 1) + ch + Copy(s, fCursorCol + 1, Length(s))
  Else
    fLines[fCursorLine] := Copy(s, 1, fCursorCol - 1) + ch + Copy(s, fCursorCol, Length(s));

  Inc(fCursorCol, Length(ch));
  fSelLine := fCursorLine; fSelCol := fCursorCol;
  fWrapDirty := True;
  OnLineChanged(fCursorLine);
  OnCursorMoved;
  UpdateDesiredPos;
  If Not fBulkInsert Then
    EnsureCursorVisible;
End;

Procedure SP_Memo.InsertText(s: aString);
Var i: Integer;
    sub, Accum: aString;
    startCurs: Integer;
Begin
  fBulkInsert := True;
  StartCurs := CursorLine;
  Try
    i := 1;
    Accum := '';
    While i <= Length(s) Do Begin
      If (s[i] = #13) Or (s[i] = #10) Then Begin
        InsertChar(Accum); Accum := '';
        If HasSelection Then DeleteSelection Else StoreUndo(uoSplitLine);
        fWrapDirty := True;
        sub := fLines[fCursorLine];
        fLines[fCursorLine] := Copy(sub, 1, fCursorCol - 1);
        CursorLine := CursorLine + 1;
        fLines.Insert(fCursorLine, Copy(sub, fCursorCol, Length(sub)));
        CursorCol := 1;
        fSelLine := fCursorLine;
        fSelCol  := fCursorCol;
        OnLinesChanged(fCursorLine, 1);
        OnLineChanged(fCursorLine - 1);
        If (s[i] = #13) And (i < Length(s)) And (s[i+1] = #10) Then Inc(i);
      End Else
        Accum := Accum + s[i];
      Inc(i);
    End;
    OnLineChanged(fCursorLine);
  Finally
    fBulkInsert := False;
  End;
  If Accum <> '' Then InsertChar(Accum);
  For i := startCurs To CursorLine Do
    OnLineChanged(i);
  fWrapDirty := True;
  EnsureCursorVisible;
End;

Procedure SP_Memo.DeleteCharBack;
Var s: aString; numLen, p, spaces: Integer;
Begin
  If HasSelection Then Begin DeleteSelection; Exit; End;
  If fCursorCol > 1 Then Begin
    s := fLines[fCursorLine]; numLen := GetLineNumLen(fCursorLine);
    If fCursorCol > numLen + 1 Then Begin
      p := numLen + 1;
      While (p < fCursorCol) And (s[p] = ' ') Do Inc(p);
      If p >= fCursorCol Then Begin
        spaces := TabRetreat;
        spaces := Min(spaces, fCursorCol - numLen - 1);
        StoreUndo(uoDeleteBack);
        fLines[fCursorLine] := Copy(s, 1, fCursorCol - spaces - 1) +
                               Copy(s, fCursorCol, Length(s));
        Dec(fCursorCol, spaces);
        fSelLine := fCursorLine; fSelCol := fCursorCol;
        fWrapDirty := True; OnLineChanged(fCursorLine); Exit;
      End;
    End;
    StoreUndo(uoDeleteBack);
    fLines[fCursorLine] := Copy(s, 1, fCursorCol - 2) + Copy(s, fCursorCol, Length(s));
    Dec(fCursorCol);
    fSelLine := fCursorLine; fSelCol := fCursorCol;
    fWrapDirty := True; OnLineChanged(fCursorLine);
  End Else
    If fCursorLine > 0 Then Begin
      StoreUndo(uoMergeLine);
      s := fLines[fCursorLine - 1] + fLines[fCursorLine];
      fCursorCol := Length(fLines[fCursorLine - 1]) + 1;
      fLines.Delete(fCursorLine); Dec(fCursorLine);
      fLines[fCursorLine] := s;
      fSelLine := fCursorLine; fSelCol := fCursorCol;
      OnLinesChanged(fCursorLine + 1, -1);
      fWrapDirty := True; OnLineChanged(fCursorLine);
    End;
  UpdateDesiredPos;
End;

Procedure SP_Memo.DeleteCharFwd;
Var s: aString;
Begin
  If fCursorLine >= fLines.Count Then Exit;
  If HasSelection Then Begin DeleteSelection; Exit; End;
  If fCursorCol <= Length(fLines[fCursorLine]) Then Begin
    StoreUndo(uoDeleteFwd);
    s := fLines[fCursorLine];
    fLines[fCursorLine] := Copy(s, 1, fCursorCol - 1) + Copy(s, fCursorCol + 1, Length(s));
    fWrapDirty := True; OnLineChanged(fCursorLine);
  End Else
    If fCursorLine < fLines.Count - 1 Then Begin
      StoreUndo(uoMergeLine);
      fLines[fCursorLine] := fLines[fCursorLine] + fLines[fCursorLine + 1];
      fLines.Delete(fCursorLine + 1);
      OnLinesChanged(fCursorLine + 1, -1);
      fWrapDirty := True; OnLineChanged(fCursorLine);
    End;
  UpdateDesiredPos;
End;

Procedure SP_Memo.SplitLine;
Var s, indent: aString;
Begin
  If HasSelection Then DeleteSelection Else StoreUndo(uoSplitLine);
  s      := fLines[fCursorLine];
  indent := ComputeAutoIndent;
  fLines[fCursorLine] := Copy(s, 1, fCursorCol - 1);
  Inc(fCursorLine);
  fLines.Insert(fCursorLine, indent + Copy(s, fCursorCol, Length(s)));
  fCursorCol := Length(indent) + 1;
  fSelLine   := fCursorLine; fSelCol := fCursorCol;
  OnLinesChanged(fCursorLine, 1);
  fWrapDirty := True;
  OnLineChanged(fCursorLine - 1);
  OnLineChanged(fCursorLine);
  UpdateDesiredPos;
End;

// ---------------------------------------------------------------------------
// Flash timer, cursor colours
// ---------------------------------------------------------------------------

Procedure SP_Memo.GetCursorClrs(Out Fg, Bg: Integer);
Var
  f, b: Integer;
Begin
  If Not SP_SysVars.FOCUSED Then Begin
    f := 236; b := 244;                      // app not focused - grey
  End Else Begin
    f := fCursFg;  b := fCursBg;             // normal - use whatever host set
  End;
  If fCursorOn Then Begin
    Fg := b;  Bg := f;
  End Else Begin
    Fg := f;  Bg := b;
  End;
End;

Procedure SP_Memo.FlashTimer(p: Pointer);
Begin
  If Not fEditable Then Exit;
  fCursorOn := Not fCursorOn;   // local toggle, immune to FLASHSTATE phase
  Paint;
End;

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

Procedure SP_Memo.Draw;
Var
  bOffL, BoffR, bOffT, bOffB, cfH, cfW,
  y, i, j, wl, visL, lm: Integer;
  x, selX1, selX2: Integer;
  synLine, plainLine: aString;
  CurWL, curRelCol: Integer;
  L1, C1, L2, C2: Integer;
  segStart, segEnd: Integer;
  Clr, SelClr, maskClr: Byte;
  selC1, selC2: Integer;
  curChar: aChar;
  curStr: aString;
  cx: Integer;
  r: TRect;
  oldProportional: Boolean;
  firstWL, lastWL, lastRaw: Integer;
  hitIdx, drawS, drawE, hx1, hx2: Integer;  // search highlight temps
Begin
  If fWrapDirty Then RebuildWrappedLines;

  bOffL := GetLeftOffset;   bOffT := GetTopOffset;
  bOffR := GetRightOffset;  bOffB := GetBottomOffset;
    cfH  := Max(1, Round(iFH * iSY));
  cfW  := Max(1, Round(iFW * iSX));
  lm   := ExtraLeftMargin;

  If Not Transparent Then Begin
    FillRect(0, 0, Width - 1, fPaddingTop, fBackgroundClr);
    FillRect(0, fPaddingTop, fPaddingLeft, Height -1, fBackgroundClr);
    FillRect(fPaddingLeft, Height - 1 - fPaddingBottom, Width - 1, Height -1, fBackgroundClr);
    FillRect(WIdth - 1 - fPaddingRight, fPaddingTop, Width - 1, Height - 1 - fPaddingBottom, fBackgroundClr);
    FillRect(fPaddingLeft, fPaddingTop, Width - 1 - fPaddingRight, Height - 1 - fPaddingBottom, fColour);
  End Else
    FillRect(0, 0, Width - 1, Height - 1, fBackgroundClr);

  DrawLeftMarginBackground;

  visL := VisibleLines;
  If fEnabled Then Clr := fFontClr Else Clr := fDisabledFontClr;

  If HasSelection Then
    GetSelectionOrder(L1, C1, L2, C2)
  Else
    Begin
      L1 := -1; C1 := -1; L2 := -1; C2 := -1;
    End;

  CurWL := WrappedLineOfRaw(fCursorLine, fCursorCol);

  If fWrappedCount > 0 Then Begin
    firstWL := fTopPixel Div cfH;
    lastWL  := Min(fWrappedCount - 1, firstWL + visL + 1);
    lastRaw := fWrapped[lastWL].RawLine;
    PreDrawVisibleLines(firstWL, lastWL, lastRaw);
  End;

  If fWrappedCount = 0 Then Begin
    y := bOffT;
    DrawLeftMargin(-1, bOffL, y, cfH);
    x := bOffL + lm;
    If fFocused And fEditable Then Begin
      GetCursorClrs(fCursFG, fCursBG);
      Print(x, y, ' ', fCursFg, fCursBg, iSX, iSY, False, False, False, False)
    End;
  End Else Begin

    oldProportional := fProportional;
    For i := 0 To visL +1 Do Begin
      wl := (fTopPixel Div cfH) + i;
      y  := (bOffT + i * cfH) - (fTopPixel Mod cfH);

      If wl >= fWrappedCount Then Begin
        DrawLeftMargin(-1, bOffL, y, cfH);
        Continue;
      End;

      x         := bOffL + lm - fLeftPixel + fWrapped[wl].VisualIndent;
      plainLine := fWrapped[wl].Text;
      segStart  := fWrapped[wl].RawOffset;
      segEnd    := segStart + Length(plainLine) - 1;
      synLine   := FormatLineForDisplay(wl);
      // Switch rendering mode to match this line's proportional flag.
      // Restored at end of row so cursor/selection math uses the same mode.
      fProportional := fWrapped[wl].Proportional;

      For j := 1 To Length(plainLine) Do If plainLine[j] = #1 Then plainLine[j] := ' ';

      // Current-line highlight.
      If fFocused And Not HasSelection And (fWrapped[wl].RawLine = fCursorLine) And WantCurrentLineHighlight Then
        FillRect(bOffL + lm, y, fWidth - bOffR - 1, y + cfH - 1, MemoLineBg);

      // Subclass decorations (bracket highlights etc).
      DrawLineDecorations(wl, x, y, cfH);

      // Search hit highlights - drawn after line-highlight, before selection,
      // so selection always wins on the current match.
      If Length(fSearchResults) > 0 Then Begin
        For hitIdx := 0 To Length(fSearchResults) - 1 Do Begin
          If fSearchResults[hitIdx].Line <> fWrapped[wl].RawLine Then Continue;
          drawS := fSearchResults[hitIdx].Col;
          drawE := drawS + fSearchResults[hitIdx].Len;
          // Clamp to this wrapped segment
          If (drawS > segEnd + 1) Or (drawE <= segStart) Then Continue;
          drawS := Max(drawS, segStart) - segStart;
          drawE := Min(drawE, segEnd + 1) - segStart;
          If Proportional Then Begin
            hx1 := TextWidth(Copy(plainLine, 1, drawS));
            hx2 := TextWidth(Copy(plainLine, 1, drawE));
          End Else Begin
            hx1 := drawS * cfW;
            hx2 := drawE * cfW;
          End;
          If fSearchResults[hitIdx].Colour = 0 Then
            FillRect(x + hx1, y, x + hx2 -1, y + cfH - 1, MemoSearchClr)
          Else
            FillRect(x + hx1, y, x + hx2 -1, y + cfH - 1, fSearchResults[hitIdx].Colour);
        End;
      End;

      // Selection highlight.
      If HasSelection And
         (fWrapped[wl].RawLine >= L1) And (fWrapped[wl].RawLine <= L2) Then Begin
        If fWrapped[wl].RawLine = L1 Then selC1 := Max(C1, segStart) - segStart
        Else selC1 := 0;
        If fWrapped[wl].RawLine = L2 Then selC2 := Min(C2, segEnd + 1) - segStart
        Else selC2 := Length(plainLine);
        If selC1 < selC2 Then Begin
          If fFocused Then SelClr := fHighlightClr Else SelClr := fUnfocusedHighlightClr;
          If Proportional Then Begin
            selX1 := TextWidth(Copy(plainLine, 1, selC1));
            selX2 := TextWidth(Copy(plainLine, 1, selC2));
          End Else Begin
            selX1 := selC1 * cfW; selX2 := selC2 * cfW;
          End;
          FillRect(x + selX1, y, x + selX2 - 1, y + cfH - 1, SelClr);
        End;
      End;

      Print(x, y, synLine, Clr, -1, iSX, iSY, False, False, False, False);

      // Left margin - drawn after text to overpaint any bleed.
      DrawLeftMargin(wl, bOffL, y, cfH);

      // Cursor - suppressed when search bar has keyboard focus.
      If fFocused And fEditable And (wl = CurWL) Then Begin
        GetCursorClrs(fCursFG, fCursBG);
        curChar := GetCursorChar(fCursorLine, fCursorCol);
        If curChar < ' ' Then curStr := aChar(#5) + curChar Else curStr := curChar;

        If (lm > 0) And (fCursorCol <= GetLineNumLen(fCursorLine)) Then Begin
          DrawMarginCursor(fCursorLine, fCursorCol, bOffL, y);
        End Else Begin
          curRelCol := fCursorCol - fWrapped[wl].RawOffset;
          If curRelCol < 0 Then curRelCol := 0;
          If Proportional Then
            cx := x + TextWidth(Copy(plainLine, 1, curRelCol))
          Else
            cx := x + curRelCol * cfW;
          If cx >= bOffL + lm Then
            Print(cx, y, curStr, fCursFg, fCursBg, iSX, iSY, False, False, False, False);
        End;
      End;
      // Restore control-level proportional setting for anything drawn after the row loop.
      fProportional := oldProportional;

    End;
  End;

  If fVScroll.Visible Then Begin
    r := fVScroll.BoundsRect; r.Left := r.Left - 1;
    If fTransparent Then FillRect(r, fBackgroundClr) Else FillRect(r, fColour);
  End;
  If fHScroll.Visible Then Begin
    r := fHScroll.BoundsRect; r.Right := fWidth; r.Top := r.Top - 1;
    If fTransparent Then FillRect(r, fBackgroundClr) Else FillRect(r, fColour);
  End;

  // Mask bleeding text before border draws
  maskClr := fBackgroundClr;
  FillRect(0,              0,               fWidth - 1,      bOffT - 1,         maskClr); // Top
  FillRect(0,              fHeight - bOffB, fWidth - 1,      fHeight - 1,       maskClr); // Bottom
  FillRect(0,              bOffT,           bOffL - 1,       fHeight - bOffB - 1, maskClr); // Left
  FillRect(fWidth - bOffR, bOffT,           fWidth - 1,      fHeight - bOffB - 1, maskClr); // Right

  If fBorder Then Begin
    DrawRect(fPaddingLeft, fPaddingTop, Width - fPaddingRight - 1, Height - fPaddingBottom - 1, fBorderClr);
    DrawRect(fPaddingLeft + 1, fPaddingTop + 1, Width - fPaddingRight - 2, Height - fPaddingBottom - 2, fColour);
  End;
End;

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

Procedure SP_Memo.PerformKeyDown(Var Handled: Boolean);
Var
  NewChar: Byte;
  cfH, vis, pg: Integer;
  oText: aString;
  ch: aChar;
Begin
  If Not (fEnabled And fFocused) Then Exit;
  cfH := Max(1, Round(iFH * iSY)); Handled := False; oText := GetText;
  NewChar := DecodeKey(cLastKey);
  If (NewChar = 0) And (cLastKeyChar = 0) Then Begin
    Case cLastKey Of

      K_INSERT:
        Begin
          INSERT := Not INSERT;
          OnCursorMoved;
          SP_PlaySystem(CLICKCHAN, CLICKBANK);
        End;

      K_TAB:
        Begin
          If fEditable Then Begin
            If HasSelection Then Begin
              If cKEYSTATE[K_SHIFT] = 1 Then DedentSelection Else IndentSelection;
              RebuildWrappedLines; EnsureCursorVisible; UpdateDesiredPos; Paint;
            End Else
              If cKEYSTATE[K_SHIFT] = 1 Then Begin
                DeleteCharBack; RebuildWrappedLines; EnsureCursorVisible; UpdateDesiredPos; Paint;
              End Else Begin
                InsertText(SP_StringOfChar(' ', TabAdvance));
                RebuildWrappedLines; EnsureCursorVisible; UpdateDesiredPos; Paint;
              End;
            SP_PlaySystem(CLICKCHAN, CLICKBANK);
          End;
          Handled := True;
        End;

      K_UP:
        Begin
          If cKEYSTATE[K_CONTROL] = 1 Then Begin
            fTopPixel := Max(0, fTopPixel - cfH);
            SP_ScrollBar(fVScroll).Pos := fTopPixel; Paint;
          End Else MoveCursorUp(cKEYSTATE[K_SHIFT] = 1);
          SP_PlaySystem(CLICKCHAN, CLICKBANK);
          Handled := True;
        End;

      K_DOWN:
        Begin
          If cKEYSTATE[K_CONTROL] = 1 Then Begin
            fTopPixel := Min(fWrappedCount - 1, fTopPixel + cfH);
            SP_ScrollBar(fVScroll).Pos := fTopPixel; Paint;
          End Else MoveCursorDown(cKEYSTATE[K_SHIFT] = 1);
          SP_PlaySystem(CLICKCHAN, CLICKBANK);
          Handled := True;
        End;

      K_LEFT:
        Begin
          If cKEYSTATE[K_CONTROL] = 1 Then MoveWordLeft(cKEYSTATE[K_SHIFT] = 1)
          Else Begin
            If fCursorCol > 1 Then
              SetCursorRaw(fCursorLine, fCursorCol - 1, cKEYSTATE[K_SHIFT] = 1)
            Else If fCursorLine > 0 Then
              SetCursorRaw(fCursorLine - 1, Length(fLines[fCursorLine-1]) + 1, cKEYSTATE[K_SHIFT] = 1);
            UpdateDesiredPos;
          End;
          SP_PlaySystem(CLICKCHAN, CLICKBANK); Handled := True;
        End;

      K_RIGHT:
        Begin
          If cKEYSTATE[K_CONTROL] = 1 Then MoveWordRight(cKEYSTATE[K_SHIFT] = 1)
          Else Begin
            If fCursorCol <= Length(fLines[fCursorLine]) Then
              SetCursorRaw(fCursorLine, fCursorCol + 1, cKEYSTATE[K_SHIFT] = 1)
            Else If fCursorLine < fLines.Count - 1 Then
              SetCursorRaw(fCursorLine + 1, 1, cKEYSTATE[K_SHIFT] = 1);
            UpdateDesiredPos;
          End;
          SP_PlaySystem(CLICKCHAN, CLICKBANK); Handled := True;
        End;

      K_HOME:
        Begin
          If cKEYSTATE[K_CONTROL] = 1 Then SetCursorRaw(0, 1, cKEYSTATE[K_SHIFT] = 1)
          Else SetCursorRaw(fCursorLine, 1, cKEYSTATE[K_SHIFT] = 1);
          UpdateDesiredPos; SP_PlaySystem(CLICKCHAN, CLICKBANK); Handled := True;
        End;

      K_END:
        Begin
          If cKEYSTATE[K_CONTROL] = 1 Then
            SetCursorRaw(fLines.Count - 1, Length(fLines[fLines.Count-1]) + 1, cKEYSTATE[K_SHIFT] = 1)
          Else
            SetCursorRaw(fCursorLine, Length(fLines[fCursorLine]) + 1, cKEYSTATE[K_SHIFT] = 1);
          UpdateDesiredPos; SP_PlaySystem(CLICKCHAN, CLICKBANK); Handled := True;
        End;

      K_PRIOR:
        Begin
          vis := VisibleLines; fTopPixel := Max(0, fTopPixel - vis * cfH);
          SP_ScrollBar(fVScroll).Pos := fTopPixel;
          MoveCursorUp(cKEYSTATE[K_SHIFT] = 1);
          For pg := 1 To vis - 1 Do MoveCursorUp(cKEYSTATE[K_SHIFT] = 1);
          SP_PlaySystem(CLICKCHAN, CLICKBANK);
          Handled := True;
        End;

      K_NEXT:
        Begin
          vis := VisibleLines;
          fTopPixel := Min(Max(0, fWrappedCount - vis), fTopPixel + vis * cfH);
          SP_ScrollBar(fVScroll).Pos := fTopPixel;
          MoveCursorDown(cKEYSTATE[K_SHIFT] = 1);
          For pg := 1 To vis - 1 Do MoveCursorDown(cKEYSTATE[K_SHIFT] = 1);
          SP_PlaySystem(CLICKCHAN, CLICKBANK);
          Handled := True;
        End;

      K_RETURN:
        Begin
          If fEditable Then Begin
            SplitLine; fWrapDirty := True; RebuildWrappedLines;
            EnsureCursorVisible; SP_PlaySystem(CLICKCHAN, CLICKBANK);
            UpdateDesiredPos; Paint;
          End;
          Handled := True;
        End;

      K_BACK:
        Begin
          If fEditable Then Begin
            If cKEYSTATE[K_CONTROL] = 1 Then MoveWordLeft(True)
            Else Begin DeleteCharBack; RebuildWrappedLines; EnsureCursorVisible; End;
            SP_PlaySystem(CLICKCHAN, CLICKBANK); UpdateDesiredPos; Paint;
          End;
          Handled := True;
        End;

      K_DELETE:
        Begin
          If fEditable Then Begin
            If cKEYSTATE[K_CONTROL] = 1 Then MoveWordRight(True)
            Else Begin DeleteCharFwd; RebuildWrappedLines; EnsureCursorVisible; End;
            SP_PlaySystem(CLICKCHAN, CLICKBANK); Paint;
          End;
          Handled := True;
        End;

      K_ESCAPE:
        Begin
          If fSearchBarVisible Then HideSearchBar;
          SP_PlaySystem(CLICKCHAN, CLICKBANK);
          Handled := True;
        End;

    Else
      Inherited;
    End;

  End Else Begin
    If cKEYSTATE[K_CONTROL] = 1 Then Begin
      If NewChar = 0 Then ch := aChar(Ord(cLastKeyChar)) Else ch := aChar(NewChar);
      Case ch Of
        'z': Begin If cKEYSTATE[K_ALT] = 0 Then PerformUndo Else PerformRedo; Handled := True; End;
        'y': Begin PerformRedo; Handled := True; End;
        'c': Begin CopySelection; Handled := True; End;
        'x': Begin If fEditable Then CutSelection; Handled := True; End;
        'v': Begin If fEditable Then PasteSelection; Handled := True; End;
        'a': Begin SelectAll; Handled := True; End;
        'f': Begin ShowSearchBar; Handled := True; End;
      Else
        Inherited;
      End;
      SP_PlaySystem(CLICKCHAN, CLICKBANK);
    End Else Begin
      If fEditable Then Begin
        If NewChar = 0 Then NewChar := Ord(cLastKeyChar);
        If NewChar >= 32 Then Begin
          InsertChar(aChar(NewChar));
          fWrapDirty := True; RebuildWrappedLines; EnsureCursorVisible;
          SP_PlaySystem(CLICKCHAN, CLICKBANK); Paint; Handled := True;
        End;
      End;
    End;
  End;

  If oText <> GetText Then Begin
    If Assigned(fOnChange) Then fOnChange(Self, GetText);
    If Not Locked And (Compiled_OnChange <> '') Then SP_AddOnEvent(Compiled_OnChange);
  End;
End;

Procedure SP_Memo.PerformKeyUp(Var Handled: Boolean); Begin End;

// ---------------------------------------------------------------------------
// Mouse
// ---------------------------------------------------------------------------

Procedure SP_Memo.MouseDown(Sender: SP_BaseComponent; X, Y, Btn: Integer);
Var RLine, RCol: Integer;
Begin
  If Not fEnabled Then Exit;
  fMouseIsDown := True; SetFocus(True); RLine := -1;
  RawPosFromMouse(X, Y, RLine, RCol);
  If RLine >= 0 Then Begin
    SetCursorRaw(RLine, RCol, cKEYSTATE[K_SHIFT] = 1);
    SP_PlaySystem(CLICKCHAN, CLICKBANK);
  End;
  Inherited;
End;

Procedure SP_Memo.MouseUp(Sender: SP_BaseComponent; X, Y, Btn: Integer);
Begin fMouseIsDown := False; Inherited; End;

Procedure SP_Memo.MouseMove(Sender: SP_BaseComponent; X, Y, Btn: Integer);
Var RLine, RCol: Integer;
Begin
  If fMouseIsDown Then Begin
    RawPosFromMouse(X, Y, RLine, RCol);
    SetCursorRaw(RLine, RCol, True);
  End;
  Inherited;
End;

Procedure SP_Memo.MouseWheel(Sender: SP_BaseComponent; X, Y, Btn, Delta: Integer; Var Handled: Boolean);
Var cfH: Integer;
Begin
  cfH := Max(1, Round(iFH * iSY));
  If fWrapDirty Then RebuildWrappedLines;
  SP_ScrollBar(fVScroll).Pos := Max(0, Min((fWrappedCount - VisibleLines) * cfH,
                                  fTopPixel + Delta * cfH * SP_ScrollWheelValue));
  Handled := True;
End;

Procedure SP_Memo.DoubleClick(X, Y, Btn: Integer);
Var bOffL, bOffT, cfH, lm, wl, RLine, RCol: Integer;
Begin
  // Double-click in the left margin - route to OnMarginClick with Btn=2.
  // Double-click in the text area - fall through to base (word-select etc).
  bOffL := GetLeftOffset;
  bOffT := GetTopOffset;
  lm   := ExtraLeftMargin;
  cfH  := Max(1, Round(iFH * iSY));
  If (lm > 0) And (X < bOffL + lm) Then Begin
    If fWrapDirty Then RebuildWrappedLines;
    If fWrappedCount > 0 Then Begin
      wl := (fTopPixel Div cfH) + ((Y - bOffT + (fTopPixel Mod cfH)) Div cfH);
      wl := Max(0, Min(wl, fWrappedCount - 1));
      OnMarginClick(wl, X, Y, 2);
    End;
    Exit;
  End Else Begin
    RawPosFromMouse(X, Y, RLine, RCol);
    If RLine >= 0 Then Begin
      SetCursorRaw(RLine, RCol, cKEYSTATE[K_SHIFT] = 1);
      SelectWordAtCursor;
      SP_PlaySystem(CLICKCHAN, CLICKBANK);
    End;
  End;
  Inherited;
End;

// ---------------------------------------------------------------------------
// Sizing
// ---------------------------------------------------------------------------

Procedure SP_Memo.HasSized;
Begin
  fWrapDirty := True;
  RebuildWrappedLines;
  If fSearchBarVisible Then ResizeSearchPanel;
End;

Procedure SP_Memo.SetBounds(x, y, w, h: Integer);
Begin Inherited; fWrapDirty := True; End;

// ---------------------------------------------------------------------------
// Property setters
// ---------------------------------------------------------------------------

Procedure SP_Memo.SetTextMargin(v: Integer);
Begin
  If (fTextMarginLeft <> v) Or (fTextMarginRight <> v) Then Begin
    fTextMarginLeft  := v;
    fTextMarginRight := v;
    fWrapDirty := True;
    RebuildWrappedLines;
    Paint;
  End;
End;

Procedure SP_Memo.SetWordWrap(b: Boolean);
Begin
  If fWordWrap <> b Then Begin
    fWordWrap := b; fHScroll.Visible := Not b;
    fWrapDirty := True; RebuildWrappedLines; Paint;
  End;
End;

Procedure SP_Memo.SetEditable(b: Boolean);
Begin
  If fEditable <> b Then Begin
    fEditable := b;
    fCanFocus := b;
    If Not b Then
      SetFocus(False);
    If b Then Begin
      If fFlashTimer = -1 Then
        fFlashTimer := AddTimer(Self, FLASHINTERVAL, FlashTimer, False, False)^.ID;
    End Else
      RemoveTimer(fFlashTimer);
    Paint;
  End;
End;

Procedure SP_Memo.SetText(s: aString);
Var p, i: Integer;
Begin
  fLines.Clear; p := 1;
  While p <= Length(s) Do Begin
    i := p;
    While (i <= Length(s)) And (s[i] <> #13) And (s[i] <> #10) Do Inc(i);
    fLines.Add(Copy(s, p, i - p));
    If (i <= Length(s)) And (s[i] = #13) Then Inc(i);
    If (i <= Length(s)) And (s[i] = #10) Then Inc(i);
    p := i;
  End;
  If fLines.Count = 0 Then fLines.Add('');
  CursorLine := 0; CursorCol := 1; fSelLine := 0; fSelCol := 1;
  fTopPixel := 0; fLeftPixel := 0; fWrapDirty := True;
  fUndoList.Clear; fRedoList.Clear;
  RebuildWrappedLines;
  OnFullTextReplaced;
  Paint;
End;

Function SP_Memo.GetText: aString;
Var i: Integer;
Begin
  Result := '';
  For i := 0 To fLines.Count - 1 Do Begin
    If i > 0 Then Result := Result + #13;
    Result := Result + fLines[i];
  End;
End;

// ---------------------------------------------------------------------------
// Lines management
// ---------------------------------------------------------------------------

Procedure SP_Memo.AddLine(const s: aString);
Begin
  fLines.Add(s);
  OnLinesChanged(fLines.Count - 1, 1);
  fWrapDirty := True; RebuildWrappedLines; Paint;
End;

Procedure SP_Memo.InsertLine(Index: Integer; const s: aString);
Begin
  If Index < 0 Then Index := 0;
  If Index >= fLines.Count Then fLines.Add(s) Else fLines.Insert(Index, s);
  OnLinesChanged(Index, 1);
  fWrapDirty := True; RebuildWrappedLines; Paint;
End;

Procedure SP_Memo.DeleteLine(Index: Integer);
Begin
  If (Index >= 0) And (Index < fLines.Count) Then Begin
    fLines.Delete(Index);
    If fLines.Count = 0 Then fLines.Add('');
    OnLinesChanged(Index, -1);
    CursorLine := Min(fCursorLine, fLines.Count - 1);
    fSelLine    := fCursorLine;
    fWrapDirty  := True; RebuildWrappedLines; Paint;
  End;
End;

Procedure SP_Memo.Clear;
Begin
  fLines.Clear; fLines.Add('');
  CursorLine := 0; CursorCol := 1; fSelLine := 0; fSelCol := 1;
  fTopPixel := 0; fLeftPixel := 0; fWrapDirty := True;
  fUndoList.Clear; fRedoList.Clear;
  RebuildWrappedLines;
  OnFullTextReplaced;
  Paint;
End;

Function  SP_Memo.LineCount: Integer; Begin Result := fLines.Count; End;

Procedure SP_Memo.GotoLine(RawLine, RawCol: Integer);
Begin
  If fWrapDirty Then RebuildWrappedLines;
  RawLine := Max(0, Min(RawLine, fLines.Count - 1));
  RawCol  := Max(1, Min(RawCol,  Length(fLines[RawLine]) + 1));
  fDesiredCol := RawCol;
  SetCursorRaw(RawLine, RawCol, False);
  UpdateDesiredPos;
End;

Function SP_Memo.GetLine(Index: Integer): aString;
Begin
  If (Index >= 0) And (Index < fLines.Count) Then Result := fLines[Index] Else Result := '';
End;

Procedure SP_Memo.SetLine(Index: Integer; const s: aString);
Begin
  If (Index >= 0) And (Index < fLines.Count) Then Begin
    fLines[Index] := s; fWrapDirty := True; RebuildWrappedLines; Paint;
  End;
End;

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

Procedure SP_Memo.SelectAll;
Begin
  If fWrappedCount > 0 Then Begin
    fSelLine := 0; fSelCol := 1;
    CursorLine := fLines.Count - 1;
    CursorCol  := Length(fLines[fCursorLine]) + 1;
    Paint;
  End;
End;

Procedure SP_Memo.SelectWordAtCursor;
Var
  s: aString;
  sIdx, eIdx: Integer;
Begin
  If (fCursorLine < fLines.Count) And (fCursorLine >= 0) Then Begin
    s := fLines[fCursorLine];
    if (s <> '') and (fCursorCol > 0) And (fCursorCol <= Length(s)+1) Then Begin
      sIdx := fCursorCol;
      eIdx := fCursorCol;
      While (eIdx <= Length(s)) And (Not (s[eIdx] in Seps)) Do Inc(eIdx);
      While (sIdx > 1) And (Not (s[sIdx] in Seps)) Do Dec(sIdx);
      fSelLine := fCursorLine;
      fSelCol := sIdx +1;
      fCursorCol := eIdx;
      Paint;
    End;
  End;
End;

Procedure SP_Memo.CopySelection;
Var L1, C1, L2, C2, i: Integer; s: aString;
Begin
  If Not HasSelection Then Exit;
  GetSelectionOrder(L1, C1, L2, C2);
  If L1 = L2 Then s := Copy(fLines[L1], C1, C2 - C1)
  Else Begin
    s := Copy(fLines[L1], C1, Length(fLines[L1])) + #13;
    For i := L1 + 1 To L2 - 1 Do s := s + fLines[i] + #13;
    s := s + Copy(fLines[L2], 1, C2 - 1);
  End;
  Clipboard.AsText := String(s);
End;

Procedure SP_Memo.CutSelection;
Begin
  CopySelection;
  DeleteSelection;
  fWrapDirty := True;
  RebuildWrappedLines;
  Paint;
End;

Procedure SP_Memo.PasteSelection;
Var s: aString;
Begin
  s := aString(Clipboard.AsText);
  If s <> '' Then Begin
    If HasSelection Then DeleteSelection Else StoreUndo(uoBlock);
    fSuppressUndo := True;
    InsertText(s);
    fSuppressUndo := False;
    fLastUndoOp := uoNone;
    fWrapDirty := True;
    RebuildWrappedLines;
    EnsureCursorVisible;
    Paint;
  End;
End;

Function SP_Memo.GetSelectedText: aString;
Var L1, C1, L2, C2, i: Integer;
Begin
  Result := '';
  If Not HasSelection Then Exit;
  GetSelectionOrder(L1, C1, L2, C2);
  If L1 = L2 Then
    Result := Copy(fLines[L1], C1, C2 - C1)
  Else Begin
    Result := Copy(fLines[L1], C1, Length(fLines[L1])) + #13;
    For i := L1 + 1 To L2 - 1 Do Result := Result + fLines[i] + #13;
    Result := Result + Copy(fLines[L2], 1, C2 - 1);
  End;
End;

Procedure SP_Memo.GetCharPosFromMouse(X, Y: Integer; Out RLine, RCol: Integer);
Begin
  RawPosFromMouse(X, Y, RLine, RCol);
End;

Procedure SP_Memo.SetShowVertSB(b: Boolean);
Begin
  if b <> fShowVertSB Then Begin
    fShowVertSB := b;
    fVScroll.Visible := b;
    Paint;
  End;
End;

Function SP_Memo.GetCharHeight: Integer;
Begin
  Result := Max(1, Round(iFH * iSY));
End;

Function SP_Memo.CharRectFromRawPos(RawLine, ColStart, ColEnd: Integer): TRect;
Var
  cfW, cfH, bOffL, bOffT, lm, wl, x1, x2, y: Integer;
Begin
  Result := Rect(0, 0, 0, 0);
  If fWrapDirty Then RebuildWrappedLines;
  cfW  := Max(1, Round(iFW * iSX));
  cfH  := Max(1, Round(iFH * iSY));
  bOffL := GetLeftOffset;
  bOffT := GetTopOffset;
  lm   := ExtraLeftMargin;
  wl   := WrappedLineOfRaw(RawLine, ColStart);
  y    := bOffT + wl * cfH - fTopPixel;
  x1   := bOffL + lm + (ColStart - fWrapped[wl].RawOffset) * cfW - fLeftPixel;
  x2   := bOffL + lm + (ColEnd   - fWrapped[wl].RawOffset) * cfW - fLeftPixel;
  Result := Rect(x1, y, x2, y + cfH);
End;

// ---------------------------------------------------------------------------
// Search bar - FPEditor-style: SP_Container + SP_Edit + SP_Buttons
// ---------------------------------------------------------------------------

Function SP_Memo.SearchBarH: Integer;
Begin
  Result := Max(1, Round(iFH * iSY)) + 12;
End;

Procedure SP_Memo.BuildSearchResults;
Var
  i, j, tl, rl: Integer;
  s, term: aString;
Begin
  SetLength(fSearchResults, 0);
  rl   := 0;
  term := Lower(fSearchTerm);
  tl   := Length(term);
  If tl = 0 Then Exit;

  For i := 0 To fLines.Count - 1 Do Begin
    s := Lower(fLines[i]);
    j := 1;
    While j <= Length(s) - tl + 1 Do Begin
      If Copy(s, j, tl) = term Then Begin
        SetLength(fSearchResults, rl + 1);
        fSearchResults[rl].Line := i;
        fSearchResults[rl].Col  := j;
        fSearchResults[rl].Len  := tl;
        Inc(rl);
        Inc(j, tl);
      End Else
        Inc(j);
    End;
  End;
End;

Procedure SP_Memo.ClearSearchResults;
Begin
  SetLength(fSearchResults, 0);
  fSearchCurrent    := -1;
  fSearchWrapped    := False;
  fSearchEdit.SetTextNoUpdate('');
  fSearchTerm := '';
  If Not fBulkInsert Then Begin
    If fVScroll.Visible Then fVScroll.Paint;
    Paint;
  End;
End;

// Position the panel and its children - called on open and on resize.
// Mirrors SP_ResizeSearchPanel in SP_MenuActions.pas.
Procedure SP_Memo.ResizeSearchPanel;
Var
  cfH, cfW, barH, editH, btnW, x, y: Integer;
Begin
  cfH  := Max(1, Round(iFH * iSY));
  cfW  := Max(1, Round(iFW * iSX));
  barH := SearchBarH;

  // Panel spans the full width so the memo border draws cleanly over its edges
  fSearchPanel.SetBounds(0, fHeight - barH, fWidth, barH);

  editH := cfH + 4;
  btnW  := editH;
  y     := 4;   // explicit gap - clears the 2px top border decoration with room to spare

  // Edit box: leave room left for "Find:" label (approx 5 chars + gap)
  x := cfW * 5 + 4;
  fSearchEdit.SetBounds(x, y, cfW * 32 + 4, editH);
  Inc(x, fSearchEdit.Width + 2);

  fSearchNextBtn.SetBounds(x, y, btnW, btnW);
  fSearchNextBtn.CentreCaption;
  Inc(x, btnW + 2);

  fSearchPrevBtn.SetBounds(x, y, btnW, btnW);
  fSearchPrevBtn.CentreCaption;
  Inc(x, btnW + 2);

  fSearchCloseBtn.SetBounds(x, y, btnW, btnW);
  fSearchCloseBtn.CentreCaption;

  fSearchPanel.Paint;
End;

// OnPaintAfter for fSearchPanel - draws "Find:" label + decorative border lines
// + transient "Wrapped" indicator.  Mirrors FPEditorSearchBarPaint.
Procedure SP_Memo.SearchPanelPaint(Control: SP_BaseComponent);
Var lx, ly, b: Integer;
Begin
  b := Ord(fBorder);
  With Control Do Begin
    DrawLine(0, 0, fWidth - 1, 0, fBorderClr);
    DrawLine(b, 1, fWidth - (1 + b), 1, 15);
    DrawLine(b, fHeight - 1, fWidth - (1 + b), fHeight - 1, SP_UIShadow);
    DrawLine(fWidth - (1 + b), 1, fWidth - (1 + b), fHeight -1, SP_UIShadow);

    lx := fSearchEdit.Left - Round(TextWidth('Find: ')) - 2;
    If lx < 2 Then lx := 2;
    ly := (fHeight - Max(1, Round(iFH * iSY))) Div 2;
    Print(lx, ly, 'Find:', SP_UIText, -1, iSX, iSY, False, False, False, False);

    If fSearchWrapped Then Begin
      lx := fSearchCloseBtn.Left + fSearchCloseBtn.Width + 6;
      Print(lx, ly, 'Wrapped', MemoSearchWrapClr, -1, iSX, iSY, False, False, False, False);
    End;
  End;
End;

// OnChange for fSearchEdit - rebuild results and jump to first match.
// Mirrors FPSearchBoxChange.
Procedure SP_Memo.SearchEditChange(Sender: SP_BaseComponent; Text: aString);
Begin
  fSearchTerm    := Text;
  fSearchCurrent := -1;
  fSearchWrapped := False;
  BuildSearchResults;
  If fVScroll.Visible Then fVScroll.Paint;
  If Length(fSearchResults) > 0 Then FindNext(True)
  Else Paint;
End;

// OnKeyDown for fSearchEdit - Escape/Return/F3/Tab.
// Mirrors SP_SearchKeyDown.
Procedure SP_Memo.SearchEditKeyDown(Sender: SP_BaseComponent; Key: Integer;
                                    Down: Boolean; Var Handled: Boolean);
Begin
  If Not Down Then Exit;
  If Key = K_ESCAPE Then Begin
    HideSearchBar; Handled := True;
  End Else If Key In [K_RETURN, K_F3] Then Begin
    If fSearchTerm <> '' Then
      FindNext(cKEYSTATE[K_SHIFT] = 0);
    fSearchEdit.SetFocus(False);
    SetFocus(True);
    Handled := True;
  End Else If Key = K_TAB Then Begin
    fSearchEdit.SetFocus(False);
    SetFocus(True);
    Handled := True;
  End;
End;

// OnClick for all three buttons - uses Tag to distinguish.
// Mirrors SP_SearchBtnClick: Tag 1 = next, -1 = prev, 0 = close.
Procedure SP_Memo.SearchBtnClick(Sender: SP_BaseComponent);
Begin
  If Sender.Tag > 0 Then Begin
    FindNext(True);
    SetFocus(True);
  End Else If Sender.Tag < 0 Then Begin
    FindNext(False);
    SetFocus(True);
  End Else
    HideSearchBar;
End;

Procedure SP_Memo.ShowSearchBar;
Var L1, C1, L2, C2: Integer; sel: aString;
Begin
  If Not fSearchBarVisible Then Begin
    fSearchBarVisible := True;
    fSearchPanel.Visible := True;
    fWrapDirty := True;
    RebuildWrappedLines;
  End;

  // Pre-fill from single-line selection
  If HasSelection Then Begin
    GetSelectionOrder(L1, C1, L2, C2);
    If L1 = L2 Then Begin
      sel := Copy(fLines[L1], C1, C2 - C1);
      If sel <> '' Then Begin
        fSearchEdit.SetTextNoUpdate(sel);
        fSearchTerm := sel;
      End;
    End;
  End;

  ResizeSearchPanel;
  fSearchWrapped := False;
  If fSearchTerm <> '' Then Begin
    BuildSearchResults;
    If fVScroll.Visible Then fVScroll.Paint;
  End;
  fSearchEdit.SetFocus(True);
  Paint;
End;

Procedure SP_Memo.HideSearchBar;
Begin
  fSearchBarVisible := False;
  fSearchPanel.Visible := False;
  fSearchWrapped    := False;
  fWrapDirty        := True;
  ClearSearchResults;
  RebuildWrappedLines;
  If fVScroll.Visible Then fVScroll.Paint;
  SetFocus(True);
  Paint;
End;

Procedure SP_Memo.FindNext(Forward: Boolean);
Var n, total: Integer; wrapped: Boolean;
Begin
  total := Length(fSearchResults);
  If total = 0 Then Begin fSearchCurrent := -1; Paint; Exit; End;

  wrapped := False;

  If fSearchCurrent < 0 Then Begin
    n := 0;
    If Forward Then Begin
      While (n < total) And
            ((fSearchResults[n].Line < fCursorLine) Or
             ((fSearchResults[n].Line = fCursorLine) And
              (fSearchResults[n].Col < fCursorCol))) Do Inc(n);
      If n >= total Then Begin n := 0; wrapped := True; End;
    End Else Begin
      n := total - 1;
      While (n >= 0) And
            ((fSearchResults[n].Line > fCursorLine) Or
             ((fSearchResults[n].Line = fCursorLine) And
              (fSearchResults[n].Col >= fCursorCol))) Do Dec(n);
      If n < 0 Then Begin n := total - 1; wrapped := True; End;
    End;
  End Else Begin
    If Forward Then Begin
      n := fSearchCurrent + 1;
      If n >= total Then Begin n := 0; wrapped := True; End;
    End Else Begin
      n := fSearchCurrent - 1;
      If n < 0 Then Begin n := total - 1; wrapped := True; End;
    End;
  End;

  fSearchCurrent := n;
  fSelLine   := fSearchResults[n].Line;
  fSelCol    := fSearchResults[n].Col;
  CursorLine := fSearchResults[n].Line;
  CursorCol  := fSearchResults[n].Col + fSearchResults[n].Len;
  OnCursorMoved;
  EnsureCursorVisible;

  fSearchWrapped := wrapped;
  If fSearchBarVisible Then fSearchPanel.Paint;
  Paint;
End;


// ---------------------------------------------------------------------------
// VScroll OnPaintAfter - search hit markers in the scrollbar track
// ---------------------------------------------------------------------------

Procedure SP_Memo.VScrollPaintAfter(Control: SP_BaseComponent);
Var
  i, y, trackTop, trackH, hitLine, cfH: Integer;
Begin
  If Length(fSearchResults) = 0 Then Exit;
  If fLines.Count = 0 Then Exit;

  trackTop := 0;
  trackH   := Control.Height;
  If SP_ScrollBar(Control).ShowButtons Then Begin
    cfH      := Max(1, Round(iFH * iSY));
    trackTop := cfH;
    Dec(trackH, cfH * 2);
  End;
  If trackH <= 4 Then Exit;

  For i := 0 To Length(fSearchResults) - 1 Do Begin
    hitLine := fSearchResults[i].Line;
    If (i > 0) And (fSearchResults[i - 1].Line = hitLine) Then Continue;
    y := trackTop + Round((trackH - 4) * hitLine / fLines.Count);
    Control.FillRect(1, y + 1, Control.Width - 2, y + 2, MemoSearchClr);
  End;
End;

// ---------------------------------------------------------------------------
// RegisterProperties / RegisterMethods
// ---------------------------------------------------------------------------

Procedure SP_Memo.RegisterProperties;
Begin
  Inherited;
  RegisterProperty('text',       Get_Text,       Set_Text,       ':s|s');
  RegisterProperty('readonly',   Get_Editable,   Set_Editable,   ':v|v');
  RegisterProperty('wordwrap',   Get_WordWrap,   Set_WordWrap,   ':v|v');
  RegisterProperty('onchange',   Get_OnChange,   Set_OnChange,   ':s|s');
  RegisterProperty('linecount',  Get_LineCount,  Set_LineCount,  ':v');
  RegisterProperty('line',       Get_Line,       Set_Line,       ':s|vs');
  RegisterProperty('topline',    Get_TopLine,    Set_TopLine,    ':v|v');
  RegisterProperty('cursorline', Get_CursorLine, Set_CursorLine, ':v|v');
  RegisterProperty('cursorcol',  Get_CursorCol,  Set_CursorCol,  ':v|v');
End;

Procedure SP_Memo.RegisterMethods;
Begin
  Inherited;
  RegisterMethod('addline',    's',  Method_AddLine);
  RegisterMethod('insertline', 'vs', Method_InsertLine);
  RegisterMethod('deleteline', 'v',  Method_DeleteLine);
  RegisterMethod('clear',      '',   Method_Clear);
  RegisterMethod('selectall',  '',   Method_SelectAll);
End;

Procedure SP_Memo.Set_Text(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
Begin Text := s; End;
Function SP_Memo.Get_Text: aString; Begin Result := Text; End;

Procedure SP_Memo.Set_Editable(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
Begin Editable := StringToInt(s) = 0; End;
Function SP_Memo.Get_Editable: aString; Begin Result := IntToString(Ord(Not Editable)); End;

Procedure SP_Memo.Set_WordWrap(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
Begin WordWrap := StringToInt(s) <> 0; End;
Function SP_Memo.Get_WordWrap: aString; Begin Result := IntToString(Ord(WordWrap)); End;

Procedure SP_Memo.Set_OnChange(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
Begin
  Compiled_OnChange := SP_ConvertToTokens(s, Error);
  If Compiled_OnChange <> '' Then User_OnChange := s;
End;
Function SP_Memo.Get_OnChange: aString; Begin Result := User_OnChange; End;

Procedure SP_Memo.Set_LineCount(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
Begin Handled := False; End;
Function SP_Memo.Get_LineCount: aString; Begin Result := IntToString(fLines.Count); End;

Procedure SP_Memo.Set_Line(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
Var idx, p: Integer; t: aString;
Begin
  p := Pos('|', s);
  If p > 0 Then Begin
    idx := StringToInt(Copy(s, 1, p-1), 0); t := Copy(s, p+1, Length(s)); SetLine(idx, t);
  End;
End;
Function SP_Memo.Get_Line: aString; Begin Result := GetLine(fCursorLine); End;

Procedure SP_Memo.Set_TopLine(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
Var cfH: Integer;
Begin
  cfH := Max(1, Round(iFH * iSY));
  fTopPixel := Max(0, Min(StringToInt(s, 0) * cfH, (fWrappedCount - 1) * cfH));
  SP_ScrollBar(fVScroll).Pos := fTopPixel; Paint;
End;
Function SP_Memo.Get_TopLine: aString;
Var cfH: Integer;
Begin cfH := Max(1, Round(iFH * iSY)); Result := IntToString(fTopPixel Div cfH); End;

Procedure SP_Memo.Set_CursorLine(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
Begin SetCursorRaw(StringToInt(s, 0), fCursorCol, False); End;
Function SP_Memo.Get_CursorLine: aString; Begin Result := IntToString(fCursorLine); End;

Procedure SP_Memo.Set_CursorCol(s: aString; Var Handled: Boolean; Var Error: TSP_ErrorCode);
Begin SetCursorRaw(fCursorLine, StringToInt(s, 1), False); End;
Function SP_Memo.Get_CursorCol: aString; Begin Result := IntToString(fCursorCol); End;

Procedure SP_Memo.Method_AddLine(Params: Array of aString; Var Error: TSP_ErrorCode);
Begin If Length(Params) >= 1 Then AddLine(Params[0]); End;
Procedure SP_Memo.Method_InsertLine(Params: Array of aString; Var Error: TSP_ErrorCode);
Begin If Length(Params) >= 2 Then InsertLine(StringToInt(Params[0], 0), Params[1]); End;
Procedure SP_Memo.Method_DeleteLine(Params: Array of aString; Var Error: TSP_ErrorCode);
Begin If Length(Params) >= 1 Then DeleteLine(StringToInt(Params[0], 0)); End;
Procedure SP_Memo.Method_Clear(Params: Array of aString; Var Error: TSP_ErrorCode);
Begin Clear; End;
Procedure SP_Memo.Method_SelectAll(Params: Array of aString; Var Error: TSP_ErrorCode);
Begin SelectAll; End;

end.
