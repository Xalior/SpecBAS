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

unit SP_BASICEditorUnit;

// SP_BASICEditor - BASIC syntax editor, subclass of SP_Memo
//
// Adds: BASIC line-number gutter, syntax highlighting, bracket matching,
// smart indent, continuation-line indent, digit-snap on Enter.

{$INCLUDE SpecBAS.inc}

interface

Uses Math, SysUtils, Types,
     SP_BaseComponentUnit, SP_Util, SP_Errors,
     SP_MemoUnit;

Type

  TStringDynArray = Array of aString;

  SP_LineState = (spLineNull, spLineOk, spLineDirty, spLineDuplicate, spLineError);

  TBASICEditorMode = (bemPROGLINE, bemEditor, bemDirect);
  TIntegerDynArray = Array of Integer;

  SP_GutterPaintEvent = Procedure(Sender: TObject; RawLine: Integer; IsFirstSegment: Boolean; X, Y, W, H: Integer; Var DefaultDraw: Boolean) Of Object;
  SP_GutterClickEvent = Procedure(Sender: TObject; RawLine, Button: Integer) Of Object;

  SP_BreakpointEvent = Procedure(Sender: TObject;BASICLine, Statement: Integer; Active: Boolean) Of Object;

  // Fired on every single-line edit. BASICLine=-1 for unnumbered continuations.
  SP_LineChangeEvent = Procedure(Sender: TObject; RawLine, BASICLine, Statement: Integer) Of Object;

  // Fired when lines are inserted or deleted. Delta>0=inserted, <0=deleted.
  SP_StructureChangeEvent = Procedure(Sender: TObject; AtLine, Delta: Integer) Of Object;

SP_BASICEditor = Class(SP_Memo)

  Private

    fMode:               TBASICEditorMode;
    fHighlight:          Boolean;
    fSyntaxEndState:     Array of aString;
    fSyntaxEndInStr:     Array of Boolean;
    fSyntaxDirtyFrom:    Integer;
    fBracket1Line,
    fBracket1Col:        Integer;
    fBracket2Line,
    fBracket2Col:        Integer;
    fBracketMatch:       Boolean;
    fBracketErrorHighlight: Boolean;
    fShowGutter:         Boolean;
    fGutterWidth:        Integer;
    fGutterNumChars:     Integer;
    fLineNumLen:         TIntegerDynArray;
    fStatementIdx:       TIntegerDynArray;
    fLineIndent:         Array of Integer;
    fLineState:          Array of SP_LineState;
    fBreakpoints:        Array of Boolean;
    fBookmarks:          Array [0..9] of Integer;  // raw line index, -1 = unset
    fExecLine:           Integer;   // raw line of CONTINUE arrow, -1 = none
    fExecRunning:        Boolean;   // True = green arrow, False = yellow
    fExecBASICLine:      Integer;   // BASIC line number of exec position, -1 = none
    fExecStatement:      Integer;   // statement number of exec position
    fSmartIndent:        Boolean;
    fOnGutterPaint:      SP_GutterPaintEvent;
    fOnGutterClick:      SP_GutterClickEvent;
    fOnBreakpointToggle: SP_BreakpointEvent;
    fOnBASICLineChanged: SP_LineChangeEvent;
    fOnStructureChanged: SP_StructureChangeEvent;
    fOnTextReset:        SP_NotifyEvent;
    fOnEditorSearchRequest: SP_NotifyEvent;
    fPrevGutterStmt:     Integer;   // draw-time state, reset per frame
    fShowingResult:      Boolean;

    // bemDirect history and height-tracking
    fHistory:            Array of aString;
    fHistoryLen:         Integer;
    fHistoryPos:         Integer;   // -1 = not browsing
    fHistSavedText:      aString;   // text saved before browsing started
    fDWLastWraps:        Integer;   // last fWrappedCount seen; -1 = unset
    fNeedHeightFiring:   Boolean;   // re-entrancy guard for OnNeedHeight

    // Events
    fOnExecute:          SP_EditEvent;   // fires on Enter in bemDirect
    fOnNeedHeight:       SP_BaseEvent;   // fires when wrap count changes in bemDirect

    fSearchOptions:      SP_SearchOptions;  // last FindAll options, for FindNext


    // Marker helpers
    Procedure ResizeMarkerArrays;
    Procedure ShiftMarkerArrays(AtLine, Delta: Integer);

    // BASIC line helpers (private)
    Function  FindBASICLine(LineNum: Integer): Integer;
    Function  FindBASICLineWithStatement(LineNum, StatementNum: Integer): Integer;
    Function  LastRawOfBASICLine(FirstRaw: Integer): Integer;

    // Syntax helpers
    Function  ExtractEndSyntax(const s: aString): aString;
    Function  EndsInOpenString(const s: aString; StartsInStr: Boolean): Boolean;
    Procedure InvalidateSyntaxFrom(Line: Integer);
    Procedure UpdateSyntaxCache(LastRawLine: Integer);
    Function  GetSynChar(const s: aString; CharPos: Integer): aChar;

    // Bracket helpers
    Function  IsInString(const Line: aString; Col: Integer): Boolean;
    Function  FindMatchingBracket(BrackChar: aChar; StartLine, StartCol: Integer; Out MatchLine, MatchCol: Integer): Boolean;
    Function  FindAnyBracketBackwards(StartLine, StartCol: Integer; Out MatchLine, MatchCol: Integer): aChar;
    Function  CommentStartCol(RawLine: Integer): Integer;
    Procedure UpdateBracketPositions;

    // Gutter helpers
    Function  RawLineCanHasBlob(RawLine: Integer): Boolean;
    Procedure CalcGutterWidth;
    Procedure DrawGutterCell(RawLine: Integer; IsFirstSeg: Boolean; GutterX, Y, H: Integer; GutterSelX1, GutterSelX2: Integer; EmptyCell: Boolean = False);

    // Smart-indent helpers
    Function  StartsWithWord(const s, w: aString): Boolean;
    Function  EndsWithWord(const s, w: aString): Boolean;

    // Property setters
    Procedure SetShowGutter(b: Boolean);
    Procedure SetHighlight(b: Boolean);

  Protected

    // --- SP_Memo virtual overrides ---

    Function  ExtraLeftMargin: Integer; Override;
    Function  MarginColFromX(RawLine, X: Integer): Integer; Override;
    Function  GetLineContinuationIndent(RawIdx: Integer): Integer; Override;
    Procedure OnRebuildPerLineData; Override;
    Procedure OnAfterRebuildWraps; Override;
    Procedure PreDrawVisibleLines(firstWL, lastWL, lastRaw: Integer); Override;
    Procedure ExpandCompoundsFor(RawIdx: Integer);
    Procedure OnLineChanged(RawIdx: Integer); Override;
    Procedure OnCursorMoved; Override;
    Function  FormatLineForDisplay(WrapIdx: Integer): aString; Override;
    Function  GetCursorChar(RawLine, RawCol: Integer): aChar; Override;
    Procedure DrawLeftMarginBackground; Override;
    Procedure DrawLeftMargin(WrapIdx, X, Y, H: Integer); Override;
    Procedure DrawLineDecorations(WrapIdx, X, Y, H: Integer); Override;
    Procedure DrawMarginCursor(RawLine, RawCol, X, Y: Integer); Override;
    Procedure OnMarginClick(WrapIdx, X, Y, Btn: Integer); Override;
    Function  BoldCharsInSegment(RawIdx, SegStart, SegEnd: Integer): Integer; Override;
    Function  ShouldSnapToLineStart(ch: aChar): Boolean; Override;
    Function  ComputeAutoIndent: aString; Override;
    Procedure VScrollPaintAfter(Control: SP_BaseComponent); Override;
    Procedure OnLinesChanged(AtLine, Delta: Integer); Override;
    Procedure OnFullTextReplaced; Override;
    Function  WantCurrentLineHighlight: Boolean; Override;
    Function  TreatsLeadingDigitsAsLineNum(RawIdx: Integer): Boolean; Override;

  Public

    Constructor Create(Owner: SP_BaseComponent);
    Destructor Destroy; Override;
    Procedure Draw; Override;
    Procedure PasteSelection; Override;
    Procedure PerformKeyDown(Var Handled: Boolean); Override;
    Procedure MouseDown(Sender: SP_BaseComponent; X, Y, Btn: Integer); Override;
    Procedure AddToHistory(Const s: aString);
    Procedure ShowResult(Const s: aString);
    Procedure DismissResult;

    // Marker data - host calls these after compilation / debug state changes
    Function  LabelExists(Const LabelName: aString): Boolean;
    Function  StatementAtCol(RawIdx, CursorCol: Integer): Integer;
    Procedure SetLineState(RawLine: Integer; State: SP_LineState);
    Procedure SetAllLineStates(Const States: Array of SP_LineState);
    Procedure ClearLineStates;
    Procedure SetBreakpoint(RawLine: Integer; Active: Boolean);
    Procedure ClearBreakpoints;
    Function  HasBreakpoint(RawLine: Integer): Boolean;
    Procedure SetBookmarkBASICLine(Slot, Line, Statement: Integer);
    Procedure SetBookmark(Slot: Integer; RawLine: Integer);  // RawLine=-1 clears
    Procedure ClearBookmarks;
    Function  BookmarkLine(Slot: Integer): Integer;
    Procedure GoToBookMark(Slot: Integer);
    Function  NavigateTo(const Text: aString; Out FoundBASICLine: Integer): Boolean;
    Procedure SetExecLine(RawLine: Integer; Running: Boolean);
    Procedure SetExecLineByBASICLine(BASICLine, Statement: Integer);
    Procedure ClearExecLine;
    Procedure UpdateProgline;
    Procedure SetMode(NewMode: TBASICEditorMode);
    Procedure ClearText;
    Procedure InsertChar(ch: aString); Override;
    Procedure DeleteCharBack; Override;
    Procedure DeleteCharFwd; Override;
    Procedure GetCursorClrs(Out Fg, Bg: Integer); Override;
    Function  GetLineNumLen(RawLine: Integer): Integer; Override;

    // BASIC-aware content operations
    Procedure InsertBASICLine(s: aString);
    // Remove all raw lines belonging to the given BASIC line number.
    Procedure DeleteBASICLine(LineNum: Integer);
    // Navigate to a BASIC line number; Statement=1 means start of line.
    Procedure GotoBASICLine(LineNum: Integer; Statement: Integer = 1);
    // Set/clear a breakpoint using logical BASIC coordinates.
    Procedure SetBreakpointByBASICLine(LineNum, Statement: Integer; Active: Boolean);
    // Return the BASIC line number for a raw line index, or -1 for continuations.
    Function  RawLineNumber(RawIdx: Integer): Integer;
    Function  CountStatementSeps(const s: aString; SkipChars: Integer): Integer;
    Procedure InsertText(s: aString); Override;

    // ZXASCII file format - parse without loading (for SP_IncludeFile etc.)
    // Returns the program lines; header metadata via Out parameters.
    Class Function  ParseBASICText(Const RawText: aString; Out AutoStart: Integer; Out ProgName:  aString; Out Changed:   Boolean): TStringList;
    // Load a ZXASCII text block into the editor, firing OnTextReset normally.
    Procedure LoadFromBASICText(Const RawText: aString; Out AutoStart: Integer; Out ProgName:  aString; Out Changed:   Boolean);

    // Program-level structural operations (RENUM, DELETE range, MERGE range)
    // These all operate on BASIC line numbers, maintain undo, and fire the
    // appropriate bridge events so Listing stays in sync.
    Procedure SortByLineNumber;
    Procedure RenumberLines(Start, Finish, FirstLine, Step: Integer);
    Procedure DeleteLineRange(Start, Finish: Integer);
    Procedure MergeLineRange(Start, Finish: Integer);

    // Advanced BASIC-aware find/replace
    Procedure BASICFindAll(Const Text: aString; Options: SP_SearchOptions; OnEval: SP_EvalEvent; ClearFirst: Boolean = True; HitColour: Byte = 0);
    Procedure BASICFindNext(Forward: Boolean);
    Procedure BASICReplaceAll(Const Search, Replace: aString; Options: SP_SearchOptions; OnEval: SP_EvalEvent);
    Function  HasFindResults: Boolean;

    Procedure LoadHistory(Const Items: Array of aString);
    Function  GetHistorySnapshot: TStringDynArray;

    Property Highlight:     Boolean             read fHighlight    write SetHighlight;
    Property ShowGutter:    Boolean             read fShowGutter   write SetShowGutter;
    Property SmartIndent:   Boolean             read fSmartIndent  write fSmartIndent;
    Property ExecLine:      Integer             read fExecLine;
    Property ExecRunning:   Boolean             read fExecRunning;
    Property Mode:          TBASICEditorMode    read fMode         write SetMode;
    // Host-accessible cursor and per-line data
    Property CursorLine:    Integer             read fCursorLine;
    Property CursorCol:     Integer             read fCursorCol;
    Property LineNumLen:    TIntegerDynArray    read fLineNumLen;
    Property StatementIdx:  TIntegerDynArray    read fStatementIdx;
    // Events
    Property OnGutterPaint:       SP_GutterPaintEvent      read fOnGutterPaint       write fOnGutterPaint;
    Property OnGutterClick:       SP_GutterClickEvent      read fOnGutterClick       write fOnGutterClick;
    Property OnBreakpointToggle:  SP_BreakpointEvent       read fOnBreakpointToggle  write fOnBreakpointToggle;
    Property OnBASICLineChanged:  SP_LineChangeEvent       read fOnBASICLineChanged  write fOnBASICLineChanged;
    Property OnStructureChanged:  SP_StructureChangeEvent  read fOnStructureChanged  write fOnStructureChanged;
    Property OnTextReset:         SP_NotifyEvent           read fOnTextReset         write fOnTextReset;
    Property OnExecute:           SP_EditEvent             read fOnExecute           write fOnExecute;
    Property OnNeedHeight:        SP_BaseEvent             read fOnNeedHeight        write fOnNeedHeight;
    Property OnEditorSearchRequest: SP_NotifyEvent         read fOnEditorSearchRequest write fOnEditorSearchRequest;

End;

Const
  GutterBg        = 246;
  GutterCursorBg  = 247;
  NumColor        = 0;
  StmtColor      = 243;
  blobZone        = 10;
  // Scrollbar marker colours
  SBMarkerError   = 2;   // red
  SBMarkerBreak   = 2;   // red (same as error - breakpoints also stand out)
  SBMarkerExec    = 4;   // green
  SBMarkerBookmark= 6;   // yellow

  Procedure AutoExpandCompounds(Var s: aString; Var CCol: Integer);

implementation

Uses SP_Components, SP_SysVars, SP_FPEditor, SP_Tokenise, SP_ScrollBarUnit, SP_Input, SP_Sound;

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

Constructor SP_BASICEditor.Create(Owner: SP_BaseComponent);
Begin
  Inherited Create(Owner);
  fMode            := bemEditor;
  fTypeName        := 'spBASICEditor';
  fHighlight       := True;
  fShowGutter      := True;
  fGutterWidth     := 0;
  fGutterNumChars  := 0;
  fSyntaxDirtyFrom := 0;
  fSmartIndent     := False;
  fIndentSize      := 3;
  fPrevGutterStmt  := 0;
  fBracket1Line    := -1;
  fBracket1Col     := -1;
  fBracket2Line    := -1;
  fBracket2Col     := -1;
  fBracketMatch    := False;
  fBracketErrorHighlight := False;
  fExecLine        := -1;
  fExecRunning     := False;
  fProportional    := False;
  fExecLine        := -1;
  fExecRunning     := False;
  fExecBASICLine   := -1;
  fExecStatement   := 1;
  FillChar(fBookmarks, SizeOf(fBookmarks), $FF);  // all slots = -1
  // bemDirect state
  fDWLastWraps      := -1;
  fNeedHeightFiring := False;
  fHistoryLen       := 0;
  fHistoryPos       := -1;
  fHistSavedText    := '';
  SetLength(fHistory, 32);
End;

Destructor SP_BASICEditor.Destroy;
Begin
  SetLength(fHistory, 0);
  Inherited;
End;

Procedure SP_BASICEditor.SetMode(NewMode: TBASICEditorMode);
Begin
  If fMode <> NewMode Then Begin
    fMode     := NewMode;
    fEditable := NewMode In [bemEditor, bemDirect];
    If NewMode = bemDirect Then Begin
      fShowGutter  := False;
      CalcGutterWidth;
      fHighlight   := True;
      fDWLastWraps := -1;
      fHistoryPos  := -1;
      fWordWrap    := True;
    End;
    Paint;
  End;
End;

// ---------------------------------------------------------------------------
// Virtual overrides
// ---------------------------------------------------------------------------

Procedure SP_BASICEditor.InsertText(s: aString);
Var i: Integer;
    sub, Accum: aString;
    startCurs: Integer;

    Function StripSpacesIfLineNum(s2: aString): aString;
    var
      i2, l: Integer;
    Begin
      i2 := 1;
      l := Length(s2);
      While (i2 < l) And (s2[i2] <= ' ') Do Inc(i2);
      If (i2 <= l) And (s2[i2] in ['0'..'9']) Then
        Result := SP_Copy(s2, i2)
      Else
        Result := s2;
    End;

Begin
  fBulkInsert := True;
  StartCurs := CursorLine;
  Try
    i := 1;
    Accum := '';
    While i <= Length(s) Do Begin
      If (s[i] = #13) Or (s[i] = #10) Then Begin
        InsertChar(StripSpacesIfLineNum(Accum)); Accum := '';
        If HasSelection Then DeleteSelection Else StoreUndo(uoSplitLine);
        fWrapDirty := True;
        sub := fLines[fCursorLine];
        fLines[fCursorLine] := Copy(sub, 1, fCursorCol - 1);
        fCursorLine := fCursorLine + 1;
        fLines.Insert(fCursorLine, Copy(sub, fCursorCol, Length(sub)));
        fCursorCol := 1;
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
  If Accum <> '' Then InsertChar(StripSpacesIfLineNum(Accum));
  For i := startCurs To CursorLine Do
    OnLineChanged(i);
  fWrapDirty := True;
  EnsureCursorVisible;
End;

Function SP_BASICEditor.ExtraLeftMargin: Integer;
Begin
  If fMode = bemDirect Then
    Result := Max(1, Round(iFW * iSX) + fPaddingLeft)
  Else
    Result := fGutterWidth;
End;

Function SP_BASICEditor.MarginColFromX(RawLine, X: Integer): Integer;
Var
  bOff, startX, col, numLen: Integer;
Begin
  numLen := GetLineNumLen(RawLine);
  If numLen = 0 Then Begin Result := 1; Exit; End;

  bOff   := GetLeftOffset;

  // Calculate exactly where the very first digit of the line number starts rendering
  startX := bOff + blobZone + (fGutterNumChars - numLen) * 8;

  If X < startX Then
    col := 1
  Else Begin
    // Divide by the fixed 8-pixel width per digit to find the column offset
    col := 1 + (X - startX) Div 8;

    // Clamp it so we don't accidentally return a column inside the code block
    If col > numLen + 1 Then col := numLen + 1;
  End;

  Result := col;
End;

Function SP_BASICEditor.GetLineNumLen(RawLine: Integer): Integer;
Begin
  If fMode = bemDirect Then Begin
    Result := 0;
    Exit;
  End;
  If (RawLine >= 0) And (RawLine < Length(fLineNumLen)) Then
    Result := fLineNumLen[RawLine]
  Else
    Result := 0;
End;

Function SP_BASICEditor.GetLineContinuationIndent(RawIdx: Integer): Integer;
Begin
  If (RawIdx >= 0) And (RawIdx < Length(fLineIndent)) Then
    Result := fLineIndent[RawIdx]
  Else
    Result := 0;
End;

Procedure SP_BASICEditor.OnRebuildPerLineData;
Var i, n, stmtCurrent, seps: Integer; s: aString;
Begin
  CalcGutterWidth;

  SetLength(fLineNumLen,   fLines.Count);
  SetLength(fStatementIdx, fLines.Count);
  stmtCurrent := 1;
  For i := 0 To fLines.Count - 1 Do Begin
    s := fLines[i]; n := 0;
    If (s <> '') And (s[1] In['0'..'9']) Then
      While (n < Length(s)) And (s[n+1] In['0'..'9']) Do Inc(n);
    fLineNumLen[i] := n;

    If n > 0 Then Begin
      stmtCurrent      := 1;
      fStatementIdx[i] := 0;
    End Else
      fStatementIdx[i] := stmtCurrent;

    seps := CountStatementSeps(s, n);
    stmtCurrent := stmtCurrent + seps;
  End;

  SetLength(fLineIndent, fLines.Count);
  For i := 0 To fLines.Count - 1 Do Begin
    s := fLines[i]; n := fLineNumLen[i];
    fLineIndent[i] := 0;
    While (n < Length(s)) And (s[n+1] = ' ') Do Begin Inc(fLineIndent[i]); Inc(n); End;
  End;

  ResizeMarkerArrays;
End;

Procedure SP_BASICEditor.OnAfterRebuildWraps;
Begin
  Inherited;
  ResizeMarkerArrays;
  If Length(fSyntaxEndState) <> fLines.Count Then
    SetLength(fSyntaxEndState, fLines.Count);
  If Length(fSyntaxEndInStr) <> fLines.Count Then
    SetLength(fSyntaxEndInStr, fLines.Count);
  // RebuildWrappedLines wipes all fWrapped[].StartSyntax. Always force
  // UpdateSyntaxCache to repopulate them on the next paint, regardless
  // of whether the line count changed.
  fSyntaxDirtyFrom := 0;
  // Re-derive exec arrow raw line now that fLineNumLen is fully populated
  If fExecBASICLine >= 0 Then Begin
    fExecLine := -1;
    SetExecLineByBASICLine(fExecBASICLine, fExecStatement);
  End;

  // In bemDirect, notify the host whenever the visual wrap count changes so
  // it can grow or shrink the DW window to fit.  Re-entrancy guard prevents
  // infinite loops if the host calls SetHeight (which triggers a repaint /
  // RebuildWrappedLines) from within the callback.
  If (fMode = bemDirect) And (fWrappedCount <> fDWLastWraps)
                          And Not fNeedHeightFiring Then Begin
    fDWLastWraps      := fWrappedCount;
    fNeedHeightFiring := True;
    Try
      If Assigned(fOnNeedHeight) Then fOnNeedHeight(Self);
    Finally
      fNeedHeightFiring := False;
    End;
  End;
End;

Procedure SP_BASICEditor.PreDrawVisibleLines(firstWL, lastWL, lastRaw: Integer);
Begin
  If fHighlight Then
    UpdateSyntaxCache(lastRaw);
  fPrevGutterStmt := 0;   // Reset per-frame gutter statement counter.
End;

Procedure SP_BASICEditor.ExpandCompoundsFor(RawIdx: Integer);
Var
  s: aString;
  c, oldC: Integer;
Begin
  s := fLines[RawIdx];
  c := fCursorCol;
  oldC := c;  // <-- Remember where the cursor started

  AutoExpandCompounds(s, c);

  // If a replacement happened, write it back to the buffer safely
  If s <> fLines[RawIdx] Then Begin
    fLines[RawIdx] := s;
    fCursorCol := c;
    If (fSelLine = fCursorLine) And (fSelCol = oldC) Then
      fSelCol := c;
    fWrapDirty := True; // Force word-wrap to recalculate the new length
  End;

End;

Procedure SP_BASICEditor.OnLineChanged(RawIdx: Integer);
Var
  FirstRaw, BASICLine, Statement: Integer;
Begin
  Inherited;

  If (Not fBulkInsert) And (RawIdx >= 0) And (RawIdx < fLines.Count) Then
    ExpandCompoundsFor(RawIdx);

  InvalidateSyntaxFrom(RawIdx);

  // In bemDirect mode there are no BASIC line numbers; skip the host event.
  If (fMode <> bemDirect) And Assigned(fOnBASICLineChanged) Then Begin
    FirstRaw := RawIdx;
    While (FirstRaw > 0) And (fLineNumLen[FirstRaw] = 0) Do Dec(FirstRaw);
    BASICLine := RawLineNumber(FirstRaw);
    Statement := fStatementIdx[RawIdx];
    If Statement = 0 Then Statement := 1;
    fOnBASICLineChanged(Self, RawIdx, BASICLine, Statement);
  End;
End;

Procedure SP_BASICEditor.OnCursorMoved;
Begin
  If Not fBulkInsert Then UpdateBracketPositions;
  If Assigned(fOnCursorMove) Then
    fOnCursorMove(Self);
End;

Function SP_BASICEditor.FormatLineForDisplay(WrapIdx: Integer): aString;
Begin
  If fHighlight Then
    Result := SP_SyntaxHighlight(fWrapped[WrapIdx].Text, fWrapped[WrapIdx].StartSyntax, False, False)
  Else
    Result := InsertLiterals(fWrapped[WrapIdx].Text);
End;

Function SP_BASICEditor.BoldCharsInSegment(RawIdx, SegStart, SegEnd: Integer): Integer;
Var
  highlighted, seg, startSyntax: aString;
  fs, i: Integer;
  inBold: Boolean;
Begin
  Result := 0;
  If Not fHighlight Then Exit;
  If (RawIdx < 0) Or (RawIdx >= fLines.Count) Then Exit;
  If SegEnd < SegStart Then Exit;

  // Seed the start syntax so highlighting is correct for continuation segments.
  fs := fRawToFirstWrap[RawIdx];
  startSyntax := '';
  If fs >= 0 Then startSyntax := fWrapped[fs].StartSyntax;

  // Highlight just the segment we are measuring.  HasNumber = False because
  // a segment starting mid-line never begins with a line number.
  seg := Copy(fLines[RawIdx], SegStart, SegEnd - SegStart + 1);
  highlighted := SP_SyntaxHighlight(seg, startSyntax, False, False);

  // Count visible characters that fall within a bold-on region.
  // Bold control code: #27 + 4-byte LongWord; non-zero value = bold on.
  inBold := False;
  i := 1;
  While i <= Length(highlighted) Do Begin
    Case Ord(highlighted[i]) Of
      27: Begin  // bold control: #27 + 4 bytes
            If i + 4 <= Length(highlighted) Then
              inBold := pLongWord(@highlighted[i+1])^ <> 0;
            Inc(i, 5);
          End;
      16, 17, 18, 19, 20, 26, 29: // other colour controls: skip 4 bytes
          Inc(i, 5);
      5:  // literal char follows
          Begin
            If inBold Then Inc(Result);
            Inc(i, 2);
          End;
      6..13, 28: // single-byte controls
          Inc(i, 2);
      21, 22: // MOVE/AT: 2 x Integer
          Inc(i, 1 + SizeOf(Integer) * 2);
      23, 24: // TAB/CENTRE: 1 x Integer
          Inc(i, 1 + SizeOf(Integer));
      25: // SCALE: 2 x aFloat
          Inc(i, 1 + SizeOf(aFloat) * 2);
    Else
      // Printable character
      If inBold Then Inc(Result);
      Inc(i);
    End;
  End;
End;

Function SP_BASICEditor.GetCursorChar(RawLine, RawCol: Integer): aChar;
Var
  fs: Integer;
  lss: aString;
Begin
  Result := ' ';
  If RawLine >= fLines.Count Then Exit;
  If fHighlight And (RawCol <= Length(fLines[RawLine])) Then Begin
    fs := fRawToFirstWrap[RawLine];
    lss := '';
    If fs >= 0 Then lss := fWrapped[fs].StartSyntax;
    Result := GetSynChar(
      SP_SyntaxHighlight(fLines[RawLine], lss,
        (fLines[RawLine] <> '') And (fLines[RawLine][1] In ['0'..'9']), False),
      RawCol);
  End Else Begin
    If RawCol <= Length(fLines[RawLine]) Then
      Result := fLines[RawLine][RawCol]
    Else
      Result := ' ';
  End;
End;

Procedure SP_BASICEditor.GetCursorClrs(Out Fg, Bg: Integer);
Var
  curChar: aChar;
  f, b: Integer;
Begin
  If Not SP_SysVars.FOCUSED Then Begin
    f := 236; b := 244;                       // app not focused - grey
  End Else If EDITERROR Then Begin
    f := 15;  b := 10;                        // white on bright red - error
  End Else If EDITRESULT Then Begin
    f := 0;   b := 4;                         // black on green - result
  End Else If GFXLOCK = 1 Then Begin
    f := 14;  b := 0;                         // bright yellow on black - graphics
  End Else Begin
    curChar := GetCursorChar(fCursorLine, fCursorCol);
    If SP_Util.Pos(curChar, '()[]{}') > 0 Then Begin
      f := 14; b := 9;                        // Bracket - yellow on blue
    End Else Begin
      f := 15;  b := 9;                       // bright white on bright blue - normal
    End;
  End;
  If fCursorOn Then Begin
    Fg := b;  Bg := f;                        // flipped
  End Else Begin
    Fg := f;  Bg := b;                        // base
  End;
End;

Procedure SP_BASICEditor.DrawLeftMarginBackground;
Var bOff, cw: Integer;
Begin
  If fMode = bemDirect Then Begin
    bOff := GetLeftOffset;
    cw   := Max(1, Round(iFW * iSX));
    FillRect(bOff, 0, bOff + cw - 1, fHeight - 1, GutterBg);
  End Else
    If fHighlight And fShowGutter And (fGutterWidth > 0) Then Begin
      bOff := GetLeftOffset;
      FillRect(bOff, 0, bOff + fGutterWidth - 1, fHeight - 1, GutterBg);
    End;
End;

Procedure SP_BASICEditor.DrawLeftMargin(WrapIdx, X, Y, H: Integer);
Var
  numLen, dSel1, dSel2, gutterSelX1, gutterSelX2: Integer;
  L1, C1, L2, C2: Integer;
  isFirstSeg: Boolean;
  Ch:      aString;
  Fg, Bg:  Integer;
  ny:      Integer;
Begin

  If fMode = bemDirect Then Begin
    // Only draw the letter on the very first visual row.
    If WrapIdx > 0 Then Exit;

    ny := Y + (H - Max(1, Round(iFH * iSY))) Div 2;

    If GFXLOCK = 1 Then Begin
      Ch := 'G'; Fg := 15; Bg := 0;
    End Else If EDITRESULT Then Begin
      Ch := 'R'; Fg := 12; Bg := 0;    // green on black - result mode
    End Else If EDITERROR Then Begin
      Ch := 'E'; Fg := 15; Bg := 2;   // white on red - genuine error
    End Else Begin
      Fg := 15; Bg := 0;
      If CAPSLOCK > 0 Then
        Ch := 'C'
      Else If GetText = '' Then
        Ch := 'K'
      Else
        Ch := 'L';
    End;

    Print(X, ny, Ch, Fg, Bg, iSX, iSY, False, False, False, False);
    Exit;
  End;

  If Not fShowGutter Then Exit;

  If WrapIdx < 0 Then Begin
    DrawGutterCell(0, True, X, Y, H, -1, -1, True);
    Exit;
  End;

  // Move this up so we know if this row actually draws a line number!
  isFirstSeg := (WrapIdx = 0) Or
                (fWrapped[WrapIdx].RawLine <> fWrapped[WrapIdx - 1].RawLine);

  numLen := fLineNumLen[fWrapped[WrapIdx].RawLine];
  gutterSelX1 := -1; gutterSelX2 := -1;

  // Only calculate gutter highlights if this segment contains the line number
  If isFirstSeg And HasSelection Then Begin
    GetSelectionOrder(L1, C1, L2, C2);
    If (numLen > 0) And
       (fWrapped[WrapIdx].RawLine >= L1) And (fWrapped[WrapIdx].RawLine <= L2) Then Begin
      dSel1 := 1; dSel2 := numLen + 1;
      If fWrapped[WrapIdx].RawLine = L1 Then dSel1 := Max(C1, 1);
      If fWrapped[WrapIdx].RawLine = L2 Then dSel2 := Min(C2, numLen + 1);
      If dSel1 < dSel2 Then Begin
        gutterSelX1 := X + blobZone + (fGutterNumChars - numLen + dSel1 - 1) * 8;
        gutterSelX2 := X + blobZone + (fGutterNumChars - numLen + dSel2 - 1) * 8;
      End;
    End;
  End;

  DrawGutterCell(fWrapped[WrapIdx].RawLine, isFirstSeg, X, Y, H, gutterSelX1, gutterSelX2);
End;

Procedure SP_BASICEditor.DrawLineDecorations(WrapIdx, X, Y, H: Integer);
Var
  cfW, bClr, bx, b1rel, b2rel: Integer;
  cfH: Integer;
  plainLine: aString;
  FirstRaw, BASICLine, bOff: Integer;
Begin
  // --- PROGLINE Text Area Highlight ---
  If fMode = bemPROGLINE Then Begin
    FirstRaw := fWrapped[WrapIdx].RawLine;
    While (FirstRaw > 0) And (fLineNumLen[FirstRaw] = 0) Do Dec(FirstRaw);
    BASICLine := RawLineNumber(FirstRaw);

    If BASICLine = SP_SysVars.PROGLINE Then Begin
      bOff := GetLeftOffset;
      // Fill the entire width of the memo canvas from the edge of the gutter
      FillRect(bOff + fGutterWidth, Y, fWidth - 1, Y + H - 1, ProglineClr);
    End;
  End;

  // --- Normal Bracket Highlights ---
  If Not fHighlight Then Exit;
  If HasSelection Then Exit;

  cfW      := Max(1, Round(iFW * iSX));
  cfH      := Max(1, Round(iFH * iSY));
  plainLine := fWrapped[WrapIdx].Text;

  If fBracketErrorHighlight Then bClr := 2 Else bClr := SP_UIBracketHighlight;

  If fBracket1Line = fWrapped[WrapIdx].RawLine Then Begin
    b1rel := fBracket1Col - fWrapped[WrapIdx].RawOffset;
    If (b1rel >= 0) And (b1rel < Length(plainLine)) Then Begin
      If Proportional Then bx := X + TextWidth(Copy(plainLine, 1, b1rel))
      Else bx := X + b1rel * cfW;
      FillRect(bx, Y, bx + cfW - 1, Y + cfH - 1, bClr);
    End;
  End;

  If fBracketMatch And (fBracket2Line = fWrapped[WrapIdx].RawLine) Then Begin
    b2rel := fBracket2Col - fWrapped[WrapIdx].RawOffset;
    If (b2rel >= 0) And (b2rel < Length(plainLine)) Then Begin
      If Proportional Then bx := X + TextWidth(Copy(plainLine, 1, b2rel))
      Else bx := X + b2rel * cfW;
      FillRect(bx, Y, bx + cfW - 1, Y + cfH - 1, bClr);
    End;
  End;
End;

Procedure SP_BASICEditor.DrawMarginCursor(RawLine, RawCol, X, Y: Integer);
Var curChar: aChar; curStr: aString; cx: Integer;
Begin
  // Cursor is on a line-number digit in the gutter.
  If RawCol <= Length(fLines[RawLine]) Then
    curChar := fLines[RawLine][RawCol]
  Else
    curChar := ' ';
  If curChar < ' ' Then curStr := aChar(#5) + curChar Else curStr := curChar;
  cx := X + blobZone + (fGutterNumChars - fLineNumLen[RawLine] + (RawCol - 1)) * 8;
  Print(cx, Y, curStr, fCursFg, fCursBg, iSX, iSY, False, False, False, False);
End;

Procedure SP_BASICEditor.OnMarginClick(WrapIdx, X, Y, Btn: Integer);
Var
  RawLine:   Integer;
  FirstRaw:  Integer;
  BlobRaw:   Integer;
  BASICLine: Integer;
  Statement: Integer;
  NewActive: Boolean;
Begin
  If WrapIdx < 0 Then Exit;
  RawLine := fWrapped[WrapIdx].RawLine;

  // Single-click: notify host of gutter click (existing behaviour)
  If Btn = 1 Then Begin
    If Assigned(fOnGutterClick) Then
      fOnGutterClick(Self, RawLine, 1);
    Exit;
  End;

  // Double-click: toggle breakpoint at the logical BASIC line/statement
  If Btn = 2 Then Begin

    // Walk back to the numbered raw line that starts this BASIC line
    FirstRaw := RawLine;
    While (FirstRaw > 0) And (fLineNumLen[FirstRaw] = 0) Do
      Dec(FirstRaw);

    BASICLine := RawLineNumber(FirstRaw);
    If BASICLine < 0 Then Exit;

    // Determine which statement the clicked row belongs to.
    // fStatementIdx = 0 on numbered lines (those are statement 1).
    Statement := fStatementIdx[RawLine];
    If Statement = 0 Then Statement := 1;

    // Redirect to the blob-owning raw line for this statement.
    // A blobless row has fLineNumLen=0 AND fStatementIdx=1 - it is a
    // mid-statement word-wrap of statement 1, whose blob lives on FirstRaw.
    // Any row with fLineNumLen>0 or fStatementIdx>1 already owns its blob.
    If (fLineNumLen[RawLine] = 0) And (Statement = 1) Then
      BlobRaw := FirstRaw
    Else
      BlobRaw := RawLine;

    While (BlobRaw > 0) And (fStatementIdx[BlobRaw] = fStatementIdx[BlobRaw -1]) Do
      Dec(BlobRaw);

    // Toggle on the blob-owning row so the indicator is always visible
    If BlobRaw < Length(fBreakpoints) Then Begin
      NewActive := Not fBreakpoints[BlobRaw];
      fBreakpoints[BlobRaw] := NewActive;
      Paint;

      If Assigned(fOnBreakpointToggle) Then
        fOnBreakpointToggle(Self, BASICLine, Statement, NewActive);

      If Assigned(fOnGutterClick) Then
        fOnGutterClick(Self, BlobRaw, 2);
    End;
  End;
End;

Function SP_BASICEditor.ShouldSnapToLineStart(ch: aChar): Boolean;
Begin
  Result := fShowGutter And (ch In ['0'..'9']);
End;

Function SP_BASICEditor.ComputeAutoIndent: aString;
Var
  s, trimmed, above: aString;
  numLen, i: Integer;
Begin
  // Base: carry indent from current line.
  s      := fLines[fCursorLine];
  numLen := fLineNumLen[fCursorLine];
  Result := '';
  i      := numLen + 1;
  While (i <= Length(s)) And (s[i] = ' ') Do Begin
    Result := Result + ' ';
    Inc(i);
  End;

  If fSmartIndent Then Begin
    trimmed := SP_TrimRight(Copy(s, 1, fCursorCol - 1));
    If trimmed <> '' Then
      If EndsWithWord(trimmed, 'THEN') Or
         EndsWithWord(trimmed, 'ELSE') Then
        Result := Result + SP_StringOfChar(' ', fIndentSize);

    above := Upper(SP_TrimLeft(Copy(s, numLen + 1, Length(s))));
    If StartsWithWord(above, 'NEXT')   Or
       StartsWithWord(above, 'LOOP')   Or
       StartsWithWord(above, 'UNTIL')  Or
       StartsWithWord(above, 'END IF') Then
      If Length(Result) >= fIndentSize Then
        Result := Copy(Result, 1, Length(Result) - fIndentSize);
  End;
End;

Procedure SP_BASICEditor.AddToHistory(Const s: aString);
Var i: Integer;
Begin
  // Deduplicate: skip if identical to the most recent entry
  If (fHistoryLen > 0) And (fHistory[fHistoryLen - 1] = s) Then Exit;

  // Grow array on demand
  If fHistoryLen >= Length(fHistory) Then
    SetLength(fHistory, fHistoryLen + 32);

  fHistory[fHistoryLen] := s;
  Inc(fHistoryLen);

  // Cap at 100 entries: drop the oldest
  If fHistoryLen > 100 Then Begin
    For i := 0 To fHistoryLen - 2 Do
      fHistory[i] := fHistory[i + 1];
    fHistory[fHistoryLen - 1] := '';
    Dec(fHistoryLen);
  End;

  fHistoryPos := -1;
End;

Procedure SP_BASICEditor.ClearText;
Begin
  fHistoryPos    := -1;
  fHistSavedText := '';
  SetText('');
End;

Procedure SP_BASICEditor.UpdateProgline;
Begin
  If fMode = bemPROGLINE Then Paint;
End;

Procedure SP_BASICEditor.MouseDown(Sender: SP_BaseComponent; X, Y, Btn: Integer);
Begin
  If EDITERROR Then EDITERROR := False; // cursor movement should clear the editor error.
  If (fMode = bemDirect) And fShowingResult Then Begin
    DismissResult;
    Exit;
  End;
  Inherited;
End;

Procedure SP_BASICEditor.ShowResult(Const s: aString);
Begin
  fShowingResult := True;
  EDITRESULT     := True;
  SetText(s);                     // OnFullTextReplaced is now a no-op
  GotoLine(fLines.Count - 1,      // cursor to end of last line
           Length(fLines[fLines.Count - 1]) + 1);
  Paint;
End;

Procedure SP_BASICEditor.DismissResult;
Begin
  fShowingResult := False;
  EDITRESULT     := False;
  ClearText;                      // now safe - OnFullTextReplaced fires normally
  Paint;
End;

Procedure SP_BASICEditor.PerformKeyDown(Var Handled: Boolean);
Var
  s:       aString;
  NewChar: Byte;
Begin

  // -- GFXLOCK - active in both bemEditor and bemDirect ---------------------
  //
  // Shift+Alt / Shift+AltGr toggles graphics-input mode.  K_ALT (18) and
  // K_ALTGR (10) both reach the component via ControlKeyEvent; cKEYSTATE
  // [K_SHIFT] is already 1 by the time K_ALT fires.
  //
  // When GFXLOCK is active, printable characters are stored as char+128
  // (UDG / graphics bytes).  We intercept before Inherited so SP_Memo's
  // own NewChar >= 32 path does not also insert the plain character.
  //
  // bemPROGLINE is read-only (fEditable=False), so neither branch fires there.

  // Result display mode - any keypress clears it and swallows the key.

  If EDITERROR Then EDITERROR := False; // cursor movement should clear the editor error.

  If (fMode = bemDirect) and fShowingResult Then Begin
    DismissResult;
    Handled := True;
    Exit;
  End;

  If not fFocused Then
    Exit;

  If fMode In [bemEditor, bemDirect] Then Begin

    If ((cLastKey In [K_ALT, K_ALTGR]) And (cKEYSTATE[K_SHIFT] = 1)) Or
       (cLastKey = K_9) And (cKEYSTATE[K_CONTROL] = 1) Then Begin
      GFXLOCK := 1 - GFXLOCK;
      SP_PlaySystem(CLICKCHAN, CLICKBANK);
      Paint;   // refreshes the mode indicator in bemDirect; harmless in bemEditor
      Handled := True;
      Exit;
    End;

    If GFXLOCK = 1 Then Begin
      NewChar := DecodeKey(cLastKey);
      If NewChar = 0 Then NewChar := cLastKeyChar;
      If (NewChar >= 32) And (cKEYSTATE[K_CONTROL] = 0) Then Begin
        If fEditable Then Begin
          InsertChar(aChar(NewChar + 128));
          fWrapDirty := True; RebuildWrappedLines; EnsureCursorVisible;
          SP_PlaySystem(CLICKCHAN, CLICKBANK); Paint;
        End;
        Handled := True;
        Exit;
      End;
    End;

  End;

  // -- bemDirect ------------------------------------------------------------
  If fMode = bemDirect Then Begin

    // Ctrl+F: open the program editor's inline search bar.
    // Ctrl+Shift+F: pass through to SP_DWPerformEdit for the advanced Find dialog.
    // Both must be intercepted here before Inherited calls SP_Memo.ShowSearchBar
    // on the DW component itself.
    If (cKEYSTATE[K_CONTROL] = 1) And (cLastKey = K_F) Then Begin
      If cKEYSTATE[K_SHIFT] = 1 Then
        Handled := False   // Ctrl+Shift+F falls through to SP_DWPerformEdit
      Else Begin
        If Assigned(fOnEditorSearchRequest) Then fOnEditorSearchRequest(Self);
        Handled := True;
      End;
      Exit;
    End;

    // Enter (without Ctrl) - execute the command, clear the editor
    If (cLastKey = K_RETURN) And (cKEYSTATE[K_CONTROL] = 0) Then Begin
      s := GetText;
      If s <> '' Then AddToHistory(s);
      If Assigned(fOnExecute) Then fOnExecute(Self, s);
      // The host is expected to call ClearText after SP_FPExecuteEditLine
      // returns; we just mark the key handled here.
      Handled := True;
      Exit;
    End;

    // Escape - return focus to the main editor window,
    // but only when the DW window actually has focus.
    If (cLastKey = K_ESCAPE) And Not fSearchBarVisible And (FocusedWindow = fwDirect) Then Begin
      If GetText <> '' Then
        ClearText
      Else Begin
        SP_SwitchFocus(fwEditor);
        SP_PlaySystem(CLICKCHAN, CLICKBANK);
      End;
      Handled := True;
      Exit;
    End;

    // Up arrow - browse backwards through history
    If (cLastKey = K_UP) And (cKEYSTATE[K_CONTROL] = 1) And (cKEYSTATE[K_SHIFT] = 1) Then Begin
      If fHistoryPos = -1 Then Begin
        fHistSavedText := GetText;
        fHistoryPos    := fHistoryLen;   // start browsing from the newest entry
      End;
      If fHistoryPos > 0 Then Begin
        Dec(fHistoryPos);
        SetText(fHistory[fHistoryPos]);
        GotoLine(fLines.Count - 1, Length(fLines[fLines.Count - 1]) + 1);
      End;
      Handled := True;
      Exit;
    End;

    // Down arrow - browse forwards through history (or restore saved text)
    If (cLastKey = K_DOWN) And (cKEYSTATE[K_CONTROL] = 1) And (cKEYSTATE[K_SHIFT] = 1) Then Begin
      If fHistoryPos >= 0 Then Begin
        Inc(fHistoryPos);
        If fHistoryPos >= fHistoryLen Then Begin
          // Past the newest entry - restore the text that was there before browsing
          fHistoryPos := -1;
          SetText(fHistSavedText);
        End Else
          SetText(fHistory[fHistoryPos]);
        GotoLine(fLines.Count - 1, Length(fLines[fLines.Count - 1]) + 1);
      End;
      Handled := True;
      Exit;
    End;

    // Ctrl+Up / Ctrl+Down: navigate PROGLINE in the program listing.
    // Must be intercepted before Inherited (SP_Memo eats all Up/Down).
    If (cLastKey In [K_UP, K_DOWN]) And (cKEYSTATE[K_CONTROL] = 1) Then Begin
      Handled := False;
      Exit;
    End;

    // All other keys fall through to the standard SP_Memo handler below.
  End;

  // -- bemEditor ------------------------------------------------------------
  If (fMode = bemEditor) And (cLastKey = K_ESCAPE) And Not fSearchBarVisible And (FocusedWindow = fwEditor) Then Begin
    SP_SwitchFocus(fwDirect);
    SP_PlaySystem(CLICKCHAN, CLICKBANK);
    Handled := True;
    Exit;
  End;
  // Ctrl+Return is handled by the host (e.g. bring-to-editor); don't consume.
  If (cLastKey = K_RETURN) And (cKEYSTATE[K_CONTROL] = 1) Then Begin
    Handled := False;
    Exit;
  End;

  Inherited;
End;

// ---------------------------------------------------------------------------
// BASIC line helpers
// ---------------------------------------------------------------------------

// Return the integer line number of raw line RawIdx, or -1 if it's a
// continuation (no leading digits).
Function SP_BASICEditor.RawLineNumber(RawIdx: Integer): Integer;
Var n: Integer; s: aString;
Begin
  Result := -1;
  If (RawIdx < 0) Or (RawIdx >= fLines.Count) Then Exit;
  n := fLineNumLen[RawIdx];
  If n = 0 Then Exit;
  s := Copy(fLines[RawIdx], 1, n);
  Result := StrToIntDef(String(s), -1);
End;

// Binary search: return the index of the first raw line whose BASIC line
// number equals LineNum, or -1 if not found.
// Relies on the listing being in ascending line-number order.
Function SP_BASICEditor.FindBASICLine(LineNum: Integer): Integer;
Var lo, hi, mid, n, first: Integer;
Begin
  Result := -1;
  lo := 0; hi := fLines.Count - 1;
  While lo <= hi Do Begin
    mid := (lo + hi) Div 2;
    // Find the first raw line of the BASIC line containing mid
    first := mid;
    While (first > 0) And (fLineNumLen[first] = 0) Do Dec(first);
    n := RawLineNumber(first);
    If n = -1 Then Begin lo := mid + 1; Continue; End;
    If n = LineNum Then Begin Result := first; Exit; End
    Else If n < LineNum Then lo := LastRawOfBASICLine(first) + 1
    Else hi := first - 1;
  End;
End;

// Return the index of the last raw line that belongs to the BASIC line
// starting at FirstRaw (i.e. walk forward while lines have no line number).
Function SP_BASICEditor.LastRawOfBASICLine(FirstRaw: Integer): Integer;
Begin
  Result := FirstRaw;
  While (Result + 1 < fLines.Count) And
        (fLineNumLen[Result + 1] = 0) Do
    Inc(Result);
End;

Function SP_BASICEditor.LabelExists(Const LabelName: aString): Boolean;
Var
  searchStr: aString;
  i: Integer;
Begin
  Result := False;
  searchStr := Upper('LABEL ' + LabelName);
  For i := 0 To fLines.Count - 1 Do
    If SP_Util.Pos(searchStr, Upper(fLines[i])) > 0 Then Begin
      Result := True;
      Exit;
    End;
End;

Function SP_BASICEditor.StatementAtCol(RawIdx, CursorCol: Integer): Integer;
Var
  s: aString;
  i, slen: Integer;
  inStr: Boolean;
  c: aChar;
Begin
  s      := fLines[RawIdx];
  slen   := Length(s);
  Result := fStatementIdx[RawIdx];
  If Result = 0 Then Result := 1;
  i      := fLineNumLen[RawIdx] + 1;
  inStr  := False;
  While i < CursorCol Do Begin
    If i > slen Then Break;
    c := s[i];
    If c = '"' Then inStr := Not inStr;
    If Not inStr Then Begin
      If c = ':' Then Inc(Result)
      Else If (i + 3 <= slen) And
         ((c In ['T','t']) And (s[i+1] In ['H','h']) And
          (s[i+2] In ['E','e']) And (s[i+3] In ['N','n'])) And
         ((i = 1) Or Not (s[i-1] In ['A'..'Z','a'..'z','0'..'9','_'])) And
         ((i + 4 > slen) Or Not (s[i+4] In['A'..'Z','a'..'z','0'..'9','_'])) Then Begin
        Inc(Result); Inc(i, 3);
      End Else If (i + 3 <= slen) And
         ((c In['E','e']) And (s[i+1] In ['L','l']) And
          (s[i+2] In ['S','s']) And (s[i+3] In ['E','e'])) And
         ((i = 1) Or Not (s[i-1] In['A'..'Z','a'..'z','0'..'9','_'])) And
         ((i + 4 > slen) Or Not (s[i+4] In['A'..'Z','a'..'z','0'..'9','_'])) Then Begin
        Inc(Result); Inc(i, 3);
      End;
    End;
    Inc(i);
  End;
End;

// ---------------------------------------------------------------------------
// BASIC-aware content operations
// ---------------------------------------------------------------------------

// Insert or replace one or more BASIC lines.
// s may be #13-separated.  Each segment that starts with a digit begins a
// new logical BASIC line; segments without a leading digit are hard-break
// continuations of the preceding numbered segment.
//
// Algorithm per logical BASIC line (numbered segment + its continuations):
//   1. Extract the line number from the leading digits.
//   2. Search for that line number in the current listing.
//   3. If found: remove that raw line and all its continuations, insert
//      the new segments at exactly that position.
//   4. If not found: find the first existing line number that is greater,
//      insert before it; if none, append at the end.
// The undo system, OnLinesChanged, and RebuildWrappedLines are all invoked
// through the standard StoreUndo / fLines.Insert / fLines.Delete paths.
Procedure SP_BASICEditor.InsertBASICLine(s: aString);
Var
  segments:    Array of aString;
  segCount:    Integer;
  i, j:        Integer;
  p:           Integer;
  seg:         aString;

  // Per-group state
  groupStart:  Integer;   // index into segments[] where current group begins
  lineNum:     Integer;
  firstRaw:    Integer;
  lastRaw:     Integer;
  insertAt:    Integer;
  delta:       Integer;
  existing:    Integer;
  groupLen:    Integer;
  searchRaw:   Integer;
  bestLineNum: Integer;
  candLineNum: Integer;
Begin
  If fWrapDirty Then RebuildWrappedLines;

  // -- Split s on #13 ------------------------------------------------------
  segCount := 0;
  SetLength(segments, 0);
  p := 1;
  While p <= Length(s) Do Begin
    i := p;
    While (i <= Length(s)) And (s[i] <> #13) Do Inc(i);
    seg := Copy(s, p, i - p);
    // Skip the trailing #10 of a #13#10 pair
    If (i < Length(s)) And (s[i] = #13) And (s[i+1] = #10) Then Inc(i);
    SetLength(segments, segCount + 1);
    segments[segCount] := seg;
    Inc(segCount);
    p := i + 1;
  End;
  If segCount = 0 Then Exit;

  // -- Process groups ------------------------------------------------------
  StoreUndo(uoBlock);

  i := 0;
  While i < segCount Do Begin
    seg := segments[i];

    // Is this segment a numbered BASIC line?
    If (seg = '') Or Not (seg[1] In ['0'..'9']) Then Begin
      // Orphan continuation skip; shouldn't happen from well-formed input
      Inc(i); Continue;
    End;

    // Collect the group: this numbered segment plus following unnumbered ones
    groupStart := i;
    groupLen   := 1;
    j          := i + 1;
    While (j < segCount) And
          ((segments[j] = '') Or Not (segments[j][1] In ['0'..'9'])) Do Begin
      Inc(groupLen);
      Inc(j);
    End;

    // Extract line number
    lineNum := 0;
    p       := 1;
    While (p <= Length(seg)) And (seg[p] In ['0'..'9']) Do Begin
      lineNum := lineNum * 10 + Ord(seg[p]) - Ord('0');
      Inc(p);
    End;

    // -- Find insertion / replacement point -----------------------------
    existing := FindBASICLine(lineNum);

    If existing >= 0 Then Begin
      // Replace: remove old raw lines for this BASIC line number
      firstRaw := existing;
      lastRaw  := LastRawOfBASICLine(firstRaw);
      delta    := lastRaw - firstRaw + 1;  // raw lines being removed
      For j := 1 To delta Do fLines.Delete(firstRaw);
      OnLinesChanged(firstRaw, -delta);
      insertAt := firstRaw;
    End Else Begin
      // Insert: find the first raw line with a higher BASIC line number
      insertAt    := fLines.Count;  // default: append
      bestLineNum := MaxInt;
      For searchRaw := 0 To fLines.Count - 1 Do Begin
        candLineNum := RawLineNumber(searchRaw);
        If (candLineNum > lineNum) And (candLineNum < bestLineNum) Then Begin
          bestLineNum := candLineNum;
          insertAt    := searchRaw;
        End;
      End;
    End;

    // -- Insert the group segments ----------------------------------------
    For j := groupStart To groupStart + groupLen - 1 Do Begin
      If insertAt + (j - groupStart) >= fLines.Count Then
        fLines.Add(segments[j])
      Else
        fLines.Insert(insertAt + (j - groupStart), segments[j]);
    End;
    OnLinesChanged(insertAt, groupLen);

    i := j;  // advance past this group
  End;

  // One rebuild covers everything
  fWrapDirty := True;
  RebuildWrappedLines;
  Paint;
End;

// Returns the raw index of the line and statement number
Function SP_BASICEditor.FindBASICLineWithStatement(LineNum, StatementNum: Integer): Integer;
Var
  firstRaw: Integer;
  raw:      Integer;
  stmtBase: Integer;
  stmtEnd:  Integer;
Begin
  Result := 0;
  If fWrapDirty Then RebuildWrappedLines;

  firstRaw := FindBASICLine(LineNum);
  If firstRaw < 0 Then Exit;
  If StatementNum <= 1 Then Begin
    Result := firstRaw;
    Exit;
  End;
  raw := firstRaw;
  While raw <= LastRawOfBASICLine(firstRaw) Do Begin
    stmtBase := fStatementIdx[raw];
    If stmtBase = 0 Then stmtBase := 1;

    If (raw < LastRawOfBASICLine(firstRaw)) And (fStatementIdx[raw + 1] > stmtBase) Then
      stmtEnd := fStatementIdx[raw + 1] - 1
    Else
      stmtEnd := stmtBase + CountStatementSeps(fLines[raw], fLineNumLen[raw]);

    If StatementNum <= stmtEnd Then Begin
      Result    := raw;
      Exit;
    End;
    Inc(raw);
  End;

End;

// Navigate to a BASIC line number.
// Statement = 1 - beginning of that line's text.
// Statement > 1 - character position of that statement within the logical line,
//                 following the cursor to the correct raw (hard-break) segment.
Procedure SP_BASICEditor.GotoBASICLine(LineNum: Integer; Statement: Integer);
Var
  firstRaw: Integer;
  raw:      Integer;
  col:      Integer;
  stmtBase: Integer;
  stmtEnd:  Integer;
Begin
  If fWrapDirty Then RebuildWrappedLines;

  firstRaw := FindBASICLine(LineNum);
  If firstRaw < 0 Then Exit;

  If Statement <= 1 Then Begin
    // Land at the first text character after the line number
    col := fLineNumLen[firstRaw] + 1;
    GotoLine(firstRaw, col);
    Exit;
  End;

  // Walk raw lines belonging to this BASIC line to find which one holds
  // the target statement.
  raw := firstRaw;
  While raw <= LastRawOfBASICLine(firstRaw) Do Begin
    stmtBase := fStatementIdx[raw];
    If stmtBase = 0 Then stmtBase := 1;

    If (raw < LastRawOfBASICLine(firstRaw)) And (fStatementIdx[raw + 1] > stmtBase) Then
      stmtEnd := fStatementIdx[raw + 1] - 1
    Else
      stmtEnd := stmtBase + CountStatementSeps(fLines[raw], fLineNumLen[raw]);

    If Statement <= stmtEnd Then Begin
      fExecLine    := raw;
      fExecRunning := False;
      Exit;
    End;
    Inc(raw);
  End;
  // Statement number out of range - land at last raw line's end
  GotoLine(raw - 1, Length(fLines[raw - 1]) + 1);
End;

Procedure SP_BASICEditor.DeleteBASICLine(LineNum: Integer);
Var FirstRaw, LastRaw, Count, i: Integer;
Begin
  If fWrapDirty Then RebuildWrappedLines;
  FirstRaw := FindBASICLine(LineNum);
  If FirstRaw < 0 Then Exit;
  LastRaw := LastRawOfBASICLine(FirstRaw);
  Count   := LastRaw - FirstRaw + 1;
  StoreUndo(uoBlock);
  For i := 1 To Count Do fLines.Delete(FirstRaw);
  OnLinesChanged(FirstRaw, -Count);
  If fLines.Count = 0 Then fLines.Add('');
  fCursorLine := Min(fCursorLine, fLines.Count - 1);
  fSelLine    := fCursorLine;
  fWrapDirty  := True;
  RebuildWrappedLines;
  Paint;
End;

Procedure SP_BASICEditor.PasteSelection;
Var SaveLineChanged: SP_LineChangeEvent;
    SaveStructure:   SP_StructureChangeEvent;
Begin
  SaveLineChanged := fOnBASICLineChanged;
  SaveStructure   := fOnStructureChanged;
  fOnBASICLineChanged := nil;
  fOnStructureChanged := nil;
  Inherited;
  fOnBASICLineChanged := SaveLineChanged;
  fOnStructureChanged := SaveStructure;
  If Assigned(fOnTextReset) Then fOnTextReset(Self);
End;

Procedure SP_BASICEditor.SetBreakpointByBASICLine(LineNum, Statement: Integer; Active: Boolean);
Var
  FirstRaw, LastRaw, Raw, BlobRaw, stmtBase, stmtEnd: Integer;
Begin
  If fWrapDirty Then RebuildWrappedLines;
  FirstRaw := FindBASICLine(LineNum);
  If FirstRaw < 0 Then Exit;
  LastRaw := LastRawOfBASICLine(FirstRaw);
  BlobRaw := FirstRaw;
  Raw     := FirstRaw;
  While Raw <= LastRaw Do Begin
    stmtBase := fStatementIdx[Raw];
    If stmtBase = 0 Then stmtBase := 1;

    If (Raw < LastRaw) And (fStatementIdx[Raw + 1] > stmtBase) Then
      stmtEnd := fStatementIdx[Raw + 1] - 1
    Else
      stmtEnd := stmtBase + CountStatementSeps(fLines[Raw], fLineNumLen[Raw]);

    If Statement <= stmtEnd Then Begin BlobRaw := Raw; Break; End;
    Inc(Raw);
  End;
  While (BlobRaw > FirstRaw) And
        (fStatementIdx[BlobRaw] = fStatementIdx[BlobRaw - 1]) Do Dec(BlobRaw);
  If BlobRaw < Length(fBreakpoints) Then Begin
    fBreakpoints[BlobRaw] := Active;
    Paint;
  End;
End;

Procedure SP_BASICEditor.ResizeMarkerArrays;
Var n, i: Integer;
Begin
  n := fLines.Count;
  If Length(fLineState)   <> n Then SetLength(fLineState,   n);
  If Length(fBreakpoints) <> n Then SetLength(fBreakpoints, n);
  // Pad new elements with safe defaults
  For i := Length(fLineState) To n - 1 Do   fLineState[i]   := spLineNull;
  For i := Length(fBreakpoints) To n - 1 Do fBreakpoints[i] := False;
End;

Procedure SP_BASICEditor.ShiftMarkerArrays(AtLine, Delta: Integer);
Var i, slot, newN: Integer;
Begin
  If (Length(fLineState) = 0) Or (AtLine < 0) Then Exit;
  newN := Length(fLineState) + Delta;
  If newN < 1 Then newN := 1;

  If Delta > 0 Then Begin
    // Insert Delta blank entries at AtLine
    SetLength(fLineState,    newN);
    SetLength(fBreakpoints,  newN);
    SetLength(fLineNumLen,   newN);
    SetLength(fStatementIdx, newN);
    SetLength(fLineIndent,   newN);
    For i := newN - 1 DownTo AtLine + Delta Do Begin
      fLineState[i]    := fLineState[i - Delta];
      fBreakpoints[i]  := fBreakpoints[i - Delta];
      fLineNumLen[i]   := fLineNumLen[i - Delta];
      fStatementIdx[i] := fStatementIdx[i - Delta];
      fLineIndent[i]   := fLineIndent[i - Delta];
    End;
    For i := AtLine To AtLine + Delta - 1 Do Begin
      fLineState[i]    := spLineNull;
      fBreakpoints[i]  := False;
      fLineNumLen[i]   := 0;
      fStatementIdx[i] := 0;
      fLineIndent[i]   := 0;
    End;
  End Else Begin
    // Remove -Delta entries starting at AtLine
    For i := AtLine To newN - 1 Do Begin
      fLineState[i]    := fLineState[i - Delta];
      fBreakpoints[i]  := fBreakpoints[i - Delta];
      fLineNumLen[i]   := fLineNumLen[i - Delta];
      fStatementIdx[i] := fStatementIdx[i - Delta];
      fLineIndent[i]   := fLineIndent[i - Delta];
    End;
    SetLength(fLineState,    newN);
    SetLength(fBreakpoints,  newN);
    SetLength(fLineNumLen,   newN);
    SetLength(fStatementIdx, newN);
    SetLength(fLineIndent,   newN);
  End;

  // Shift bookmark slots
  For slot := 0 To 9 Do Begin
    If fBookmarks[slot] < 0 Then Continue;
    If Delta > 0 Then Begin
      If fBookmarks[slot] >= AtLine Then
        Inc(fBookmarks[slot], Delta);
    End Else Begin
      If fBookmarks[slot] >= AtLine Then Begin
        If fBookmarks[slot] < AtLine - Delta Then
          fBookmarks[slot] := -1           // the bookmarked line was deleted
        Else
          Inc(fBookmarks[slot], Delta);    // shift down
      End;
    End;
  End;

  // Shift exec line
  If fExecLine >= 0 Then Begin
    If Delta > 0 Then Begin
      If fExecLine >= AtLine Then Inc(fExecLine, Delta);
    End Else Begin
      If fExecLine >= AtLine Then Begin
        If fExecLine < AtLine - Delta Then fExecLine := -1
        Else Inc(fExecLine, Delta);
      End;
    End;
  End;

End;

Procedure SP_BASICEditor.OnLinesChanged(AtLine, Delta: Integer);
Begin
  ShiftMarkerArrays(AtLine, Delta);
  If Assigned(fOnStructureChanged) Then
    fOnStructureChanged(Self, AtLine, Delta);
End;

Function SP_BASICEditor.WantCurrentLineHighlight: Boolean;
Begin
  Result := fMode <> bemDirect;
End;

Function SP_BASICEditor.TreatsLeadingDigitsAsLineNum(RawIdx: Integer): Boolean;
Begin
  Result := fMode <> bemDirect;
End;

// After a whole-text replacement (undo, redo, SetText, Clear): resize marker
// arrays to match the new line count, clear stale line states (the compiler
// will repopulate them), and clamp bookmarks/exec line to valid range.
Procedure SP_BASICEditor.OnFullTextReplaced;
Var
  i, n, slot: Integer;
Begin
  // While showing an expression result the text content is display-only
  // don't rebuild the listing or fire OnTextReset.
  If fShowingResult Then Exit;

  n := fLines.Count;
  If Length(fSyntaxEndInStr) <> n Then Begin
    SetLength(fSyntaxEndInStr, n);
    For i := 0 To n -1 Do
      fSyntaxEndInStr[i] := False;
  End;
  SetLength(fLineState,   n);
  SetLength(fBreakpoints, n);
  For i := 0 To n - 1 Do fLineState[i] := spLineNull;
  For slot := 0 To 9 Do
    If fBookmarks[slot] >= n Then fBookmarks[slot] := -1;
  If fExecBASICLine >= 0 Then Begin
    fExecLine := -1;
    SetExecLineByBASICLine(fExecBASICLine, fExecStatement);
  End;
  If Assigned(fOnTextReset) Then fOnTextReset(Self);
End;

Procedure SP_BASICEditor.SetLineState(RawLine: Integer; State: SP_LineState);
Begin
  If (RawLine >= 0) And (RawLine < Length(fLineState)) Then
    fLineState[RawLine] := State;
End;

Procedure SP_BASICEditor.SetAllLineStates(Const States: Array of SP_LineState);
Var i: Integer;
Begin
  ResizeMarkerArrays;
  For i := 0 To Min(High(States), fLines.Count - 1) Do
    fLineState[i] := States[i];
End;

Procedure SP_BASICEditor.ClearLineStates;
Var i: Integer;
Begin
  For i := 0 To Length(fLineState) - 1 Do fLineState[i] := spLineNull;
End;

Procedure SP_BASICEditor.SetBreakpoint(RawLine: Integer; Active: Boolean);
Begin
  If (RawLine >= 0) And (RawLine < Length(fBreakpoints)) Then
    fBreakpoints[RawLine] := Active;
End;

Procedure SP_BASICEditor.ClearBreakpoints;
Var i: Integer;
Begin
  For i := 0 To Length(fBreakpoints) - 1 Do fBreakpoints[i] := False;
End;

Function SP_BASICEditor.HasBreakpoint(RawLine: Integer): Boolean;
Begin
  Result := (RawLine >= 0) And (RawLine < Length(fBreakpoints)) And fBreakpoints[RawLine];
End;

Procedure SP_BASICEditor.SetBookmark(Slot: Integer; RawLine: Integer);
Begin
  If (Slot >= 0) And (Slot <= 9) Then fBookmarks[Slot] := RawLine;
  Paint;
End;

Procedure SP_BASICEditor.ClearBookmarks;
Var i: Integer;
Begin
  For i := 0 To 9 Do
    fBookmarks[i] := -1;
  Paint;
End;

Function SP_BASICEditor.BookmarkLine(Slot: Integer): Integer;
Begin
  If (Slot >= 0) And (Slot <= 9) Then
    Result := fBookmarks[Slot]
  Else
    Result := -1;
End;

Procedure SP_BASICEditor.GoToBookMark(Slot: Integer);
Var
  raw: Integer;
Begin
  raw := BookMarkLine(Slot);
  If raw >= 0 Then Begin
    SetCursorLine(raw);
    fSelLine := fCursorLine; fSelCol := fCursorCol;
  End;
End;

Procedure SP_BASICEditor.SetBookmarkBASICLine(Slot, Line, Statement: Integer);
Var
  raw: Integer;
Begin

  If Slot = -1 Then Begin
    Slot := 0;
    While Slot <= 9 Do
      if fBookMarks[Slot] = -1 Then
        Break
      Else
        Inc(Slot);
    If Slot > 9 Then Slot := 0;
  End Else
    If BookMarkLine(Slot) <> -1 Then Begin
      fBookMarks[Slot] := -1;
      Paint;
      Exit;
    End;

  If Line > 0 Then
    raw := FindBASICLineWithStatement(Line, Statement)
  Else
    raw := fCursorLine;

  SetBookMark(Slot, raw);

End;

Function SP_BASICEditor.NavigateTo(const Text: aString; Out FoundBASICLine: Integer): Boolean;
Var
  t: aString;
  LineNum, i: Integer;
  searchStr: aString;
Begin
  Result := False;
  FoundBASICLine := -1;
  t := SP_TrimLeft(Text);
  If t = '' Then Exit;

  If t[1] = '@' Then Begin
    // Label search - scan fLines for "LABEL <label>"
    searchStr := Upper('LABEL ' + Copy(t, 2, MaxInt));
    For i := 0 To fLines.Count - 1 Do
      If SP_Util.Pos(searchStr, Upper(fLines[i])) > 0 Then Begin
        FoundBASICLine := RawLineNumber(i);
        GotoLine(i, 1);
        Result := True;
        Exit;
      End;
  End Else Begin
    // Line number
    LineNum := 0;
    i := 1;
    While (i <= Length(t)) And (t[i] in ['0'..'9']) Do Begin
      LineNum := LineNum * 10 + Ord(t[i]) - 48;
      Inc(i);
    End;
    If LineNum > 0 Then Begin
      FoundBASICLine := LineNum;
      GotoBASICLine(LineNum, 1);
      Result := FindBASICLine(LineNum) >= 0;
    End;
  End;
End;

Procedure SP_BASICEditor.SetExecLine(RawLine: Integer; Running: Boolean);
Begin
  fExecLine    := RawLine;
  fExecRunning := Running;
End;

Procedure SP_BASICEditor.SetExecLineByBASICLine(BASICLine, Statement: Integer);
Var firstRaw, raw, stmtBase, stmtEnd: Integer;
Begin
  fExecBASICLine := BASICLine;
  fExecStatement := Statement;
  firstRaw := FindBASICLine(BASICLine);
  If firstRaw < 0 Then Exit;
  raw := firstRaw;
  While raw <= LastRawOfBASICLine(firstRaw) Do Begin
    stmtBase := fStatementIdx[raw];
    If stmtBase = 0 Then stmtBase := 1;

    If (raw < LastRawOfBASICLine(firstRaw)) And (fStatementIdx[raw + 1] > stmtBase) Then
      stmtEnd := fStatementIdx[raw + 1] - 1
    Else
      stmtEnd := stmtBase + CountStatementSeps(fLines[raw], fLineNumLen[raw]);

    If Statement <= stmtEnd Then Begin
      fExecLine    := raw;
      fExecRunning := False;
      Exit;
    End;
    Inc(raw);
  End;
  // Statement out of range - land on last raw line
  fExecLine    := raw - 1;
  fExecRunning := False;
End;

Procedure SP_BASICEditor.ClearExecLine;
Begin
  fExecLine      := -1;
  fExecBASICLine := -1;
  fExecStatement := 1;
End;

// ---------------------------------------------------------------------------
// Syntax helpers
// ---------------------------------------------------------------------------

Function SP_BASICEditor.ExtractEndSyntax(const s: aString): aString;
Var i, Ink, Paper, Bold, Italic: Integer; r: aString;
Begin
  Ink := -1; Paper := -1; Bold := -1; Italic := -1;
  i := 1;
  While i <= Length(s) Do Begin
    If (s[i] < ' ') And (s[i] <> #5) Then Begin
      Case s[i] Of
        #16: Ink    := pLongWord(@s[i+1])^;
        #17: Paper  := pLongWord(@s[i+1])^;
        #26: Italic := pLongWord(@s[i+1])^;
        #27: Bold   := pLongWord(@s[i+1])^;
      End;
      Inc(i, 5);
    End Else If s[i] = #5 Then Inc(i, 2)
    Else Inc(i);
  End;
  r := '';
  If Ink    >= 0 Then r := r + #16 + LongWordToString(Ink);
  If Paper  >= 0 Then r := r + #17 + LongWordToString(Paper);
  If Italic >= 0 Then r := r + #26 + LongWordToString(Italic);
  If Bold   >= 0 Then r := r + #27 + LongWordToString(Bold);
  Result := r;
End;

Function SP_BASICEditor.EndsInOpenString(const s: aString; StartsInStr: Boolean): Boolean;
Var i: Integer;
Begin
  Result := StartsInStr;
  i := 1;
  While i <= Length(s) Do Begin
    If s[i] = '"' Then Begin
      If Result And (i < Length(s)) And (s[i+1] = '"') Then
        Inc(i)   // doubled-quote escape - consume both, stay inside string
      Else
        Result := Not Result;
    End;
    Inc(i);
  End;
End;

Procedure SP_BASICEditor.InvalidateSyntaxFrom(Line: Integer);
Var i: Integer;
Begin
  i := Line;
  While (i > 0) And
        ((fLines[i] = '') Or Not (fLines[i][1] In ['0'..'9'])) Do Dec(i);
  If i < fSyntaxDirtyFrom Then fSyntaxDirtyFrom := Max(0, i);
End;

Procedure SP_BASICEditor.UpdateSyntaxCache(LastRawLine: Integer);
Var
  i, j: Integer;
  prevState, highlighted, segPrefix: aString;
  prevInStr, endInStr: Boolean;
  hasNum: Boolean;
Begin
  If Not fHighlight Then Exit;
  If fLines.Count = 0 Then Exit;
  If fSyntaxDirtyFrom > LastRawLine Then Exit;

  If Length(fSyntaxEndState)  < fLines.Count Then
    SetLength(fSyntaxEndState,  fLines.Count);
  If Length(fSyntaxEndInStr)  < fLines.Count Then
    SetLength(fSyntaxEndInStr,  fLines.Count);

  PrevInStr := False;
  If (fSyntaxDirtyFrom = 0) Or ((fLines[fSyntaxDirtyFrom] <> '') And (fLines[fSyntaxDirtyFrom][1] In ['0'..'9'])) Then Begin
    prevState := '';
    prevInStr := False;
  End Else
    If fSyntaxDirtyFrom > 0 Then Begin
      prevState := fSyntaxEndState[fSyntaxDirtyFrom - 1];
      prevInStr := fSyntaxEndInStr[fSyntaxDirtyFrom - 1];
    End;

  i := fSyntaxDirtyFrom;
  While i <= Min(LastRawLine, fLines.Count - 1) Do Begin
    hasNum      := (fLines[i] <> '') And (fLines[i][1] In ['0'..'9']);
    If hasNum Then prevInStr := False;               // new BASIC line always starts outside a string
    highlighted := SP_SyntaxHighlight(fLines[i], prevState, hasNum, prevInStr);  // pass flag
    endInStr    := EndsInOpenString(fLines[i], prevInStr);
    fSyntaxEndState[i]  := ExtractEndSyntax(highlighted);
    fSyntaxEndInStr[i]  := endInStr;

    If (i < Length(fRawToFirstWrap)) And (fRawToFirstWrap[i] >= 0) Then Begin
      j := fRawToFirstWrap[i];
      While (j < fWrappedCount) And (fWrapped[j].RawLine = i) Do Begin
        If fWrapped[j].RawOffset <= 1 Then
          fWrapped[j].StartSyntax := prevState
        Else Begin
          segPrefix := SP_SyntaxHighlight(Copy(fLines[i], 1, fWrapped[j].RawOffset - 1), prevState, hasNum, prevInStr);  // pass flag
          fWrapped[j].StartSyntax := ExtractEndSyntax(segPrefix);
        End;
        Inc(j);
      End;
    End;

    If (i + 1 <= Min(LastRawLine, fLines.Count - 1)) And
       ((fLines[i+1] = '') Or Not (fLines[i+1][1] In ['0'..'9'])) Then Begin
      prevState := fSyntaxEndState[i];
      prevInStr := endInStr;
    End Else Begin
      prevState := '';
      prevInStr := False;
    End;
    Inc(i);
  End;

  If fSyntaxDirtyFrom <= LastRawLine Then
    fSyntaxDirtyFrom := LastRawLine + 1;
End;

Function SP_BASICEditor.GetSynChar(const s: aString; CharPos: Integer): aChar;
Var i, j: Integer;
Begin
  Result := ' '; i := 1; j := 0;
  While i <= Length(s) Do Begin
    If (s[i] < ' ') And (s[i] <> #5) Then Inc(i, 5)
    Else Begin
      If s[i] = #5 Then Inc(i);
      Inc(j);
      If j = CharPos Then Begin Result := s[i]; Exit; End;
      Inc(i);
    End;
  End;
End;

// ---------------------------------------------------------------------------
// Bracket helpers
// ---------------------------------------------------------------------------

Function SP_BASICEditor.IsInString(const Line: aString; Col: Integer): Boolean;
Var i: Integer; InStr: Boolean;
Begin
  InStr := False; i := 1;
  While i < Col Do Begin
    If Line[i] = '"' Then Begin
      If InStr And (i < Length(Line)) And (Line[i+1] = '"') Then Inc(i)
      Else InStr := Not InStr;
    End;
    Inc(i);
  End;
  Result := InStr;
End;

Function SP_BASICEditor.FindMatchingBracket(BrackChar: aChar; StartLine, StartCol: Integer; Out MatchLine, MatchCol: Integer): Boolean;
Const
  Openers = aString('([{');
  Closers = aString(')]}');
Var
  SearchForward: Boolean; TargetChar: aChar;
  Depth, p, idx, Line: Integer; s: aString;
Begin
  Result := False; MatchLine := -1; MatchCol := -1;
  idx := SP_Util.Pos(BrackChar, Openers);
  If idx > 0 Then Begin SearchForward := True;  TargetChar := Closers[idx]; End
  Else Begin
    idx := SP_Util.Pos(BrackChar, Closers);
    If idx = 0 Then Exit;
    SearchForward := False; TargetChar := Openers[idx];
  End;
  Depth := 0;
  If SearchForward Then Begin
    Line := StartLine; p := StartCol + 1;
    While Line < fLines.Count Do Begin
      s := fLines[Line];
      While p <= Length(s) Do Begin
        If Not IsInString(s, p) Then Begin
          If s[p] = BrackChar Then Inc(Depth)
          Else If s[p] = TargetChar Then Begin
            If Depth = 0 Then Begin MatchLine := Line; MatchCol := p; Result := True; Exit; End;
            Dec(Depth);
          End;
        End;
        Inc(p);
      End;
      Inc(Line); p := 1;
      If (Line >= fLines.Count) or (fLineNumLen[Line] <> 0) Then
        Exit;
    End;
  End Else Begin
    Line := StartLine; p := StartCol - 1;
    While Line >= 0 Do Begin
      s := fLines[Line];
      If p > Length(s) Then p := Length(s);
      While p >= 1 Do Begin
        If Not IsInString(s, p) Then Begin
          If s[p] = BrackChar Then Inc(Depth)
          Else If s[p] = TargetChar Then Begin
            If Depth = 0 Then Begin MatchLine := Line; MatchCol := p; Result := True; Exit; End;
            Dec(Depth);
          End;
        End;
        Dec(p);
      End;
      If fLineNumLen[Line] <> 0 Then
        Exit
      Else
        Dec(Line);
      If Line >= 0 Then p := Length(fLines[Line]);
    End;
  End;
End;

Function SP_BASICEditor.FindAnyBracketBackwards(StartLine, StartCol: Integer; Out MatchLine, MatchCol: Integer): aChar;
Var
  Line, p, Depth: Integer;
  s: aString;
Begin
  Depth := 0;
  Result := #0; MatchLine := -1; MatchCol := -1;
  Line := StartLine; p := StartCol;
  While Line >= 0 Do Begin
    s := fLines[Line];
    If p > Length(s) Then p := Length(s);
    While p >= 1 Do Begin
      If Not IsInString(s, p) Then Begin
        If SP_Util.Pos(s[p], ')]}') > 0 Then
          Inc(Depth)
        Else
          If SP_Util.Pos(s[p], '([{') > 0 Then Begin
            If Depth = 0 Then Begin
              MatchLine := Line;
              MatchCol := p;
              Result := s[p];
              Exit;
            End;
            Dec(Depth);
          End;
      End;
      Dec(p);
    End;
    If fLineNumLen[Line] <> 0 Then
      Exit
    Else
      Dec(Line);
    If Line >= 0 Then
      p := Length(fLines[Line]);
  End;
End;

Procedure SP_BASICEditor.UpdateBracketPositions;
Var
  BrackChar: aChar;
  CheckCol, csc: Integer;
Begin
  fBracket1Line := -1; fBracket1Col  := -1;
  fBracket2Line := -1; fBracket2Col  := -1;
  fBracketMatch := False;
  If Not fHighlight Then Exit;
  If fLines.Count = 0 Then Exit;
  csc := CommentStartCol(fCursorLine);
  if (csc = -1) or ((csc <> 0) And (csc <= fCursorCol)) Then Exit;
  CheckCol := fCursorCol; BrackChar := #0;
  If (CheckCol >= 1) And (CheckCol <= Length(fLines[fCursorLine])) Then
    If SP_Util.Pos(fLines[fCursorLine][CheckCol], '()[]{}') > 0 Then Begin
      BrackChar := fLines[fCursorLine][CheckCol];
    End;
  If BrackChar = #0 Then Begin
    CheckCol := fCursorCol - 1;
    If (CheckCol >= 1) And (CheckCol <= Length(fLines[fCursorLine])) Then
      If SP_Util.Pos(fLines[fCursorLine][CheckCol], '()[]{}') > 0 Then Begin
        BrackChar := fLines[fCursorLine][CheckCol];
      End;
  End;

  If BrackChar = #0 Then Begin
    If ((csc <> 0) and (csc > fCursorCol)) or (csc = 0) then
      BrackChar := FindAnyBracketBackwards(fCursorLine, fCursorCol, fBracket1Line, fBracket1Col);
    If BrackChar = #0 Then Exit;
  End Else Begin
    fBracket1Line := fCursorLine;
    fBracket1Col := CheckCol;
  End;
  fBracketMatch := FindMatchingBracket(BrackChar, fBracket1Line, fBracket1Col, fBracket2Line, fBracket2Col);
  fBracketErrorHighlight := (fBracket1Line >= 0) And Not fBracketMatch;
End;

// ---------------------------------------------------------------------------
// Gutter helpers
// ---------------------------------------------------------------------------

Function SP_BASICEditor.RawLineCanHasBlob(RawLine: Integer): Boolean;
Begin
  // Only the raw line that carries a BASIC line number gets a status blob.
  // Continuation rows (statement 2, 3, … on their own raw lines, plus
  // word-wrap fragments) are all part of the same compiled unit - the
  // numbered line's blob speaks for all of them.
  If (RawLine < 0) Or (RawLine >= Length(fLineNumLen)) Then Exit(False);
  Result := fLineNumLen[RawLine] > 0;
End;

// Returns the column at which a REM comment begins on this line, or
// 0 if there is no comment, and -1 if there is but it started on a previous line.
// Skips quoted strings so a literal "REM" inside a string constant is not mistaken for a comment.
Function SP_BASICEditor.CommentStartCol(RawLine: Integer): Integer;
Var
  i: Integer;
  Line: aString;
  InStr: Boolean;
Begin
  Result := 0;
  InStr := False;
  i := 1;
  Line := fWrapped[RawLine].Text;
  While i <= Length(Line) Do Begin
    If InStr Then Begin
      If Line[i] = '"' Then Begin
        If (i < Length(Line)) And (Line[i+1] = '"') Then Inc(i)  // doubled quote escape
        Else InStr := False;
      End;
    End Else Begin
      If Line[i] = '"' Then
        InStr := True
      Else If (i + 2 <= Length(Line)) And
              ((Line[i] = 'R') Or (Line[i] = 'r')) And
              ((Line[i+1] = 'E') Or (Line[i+1] = 'e')) And
              ((Line[i+2] = 'M') Or (Line[i+2] = 'm')) And
              ((i + 3 > Length(Line)) Or
               Not (Line[i+3] In ['A'..'Z','a'..'z','0'..'9','_'])) Then Begin
        Result := i;
        Exit;
      End;
    End;
    Inc(i);
  End;
  If (RawLine > 0) And (fLineNumLen[RawLine] = 0) Then Begin
    Result := CommentStartCol(RawLine -1);
    If Result > 0 Then
      Result := -1;
  End;
End;

Procedure SP_BASICEditor.CalcGutterWidth;
Const
  MinGutterChars = 4;
Var
  i, digits, maxDigits: Integer; s: aString;
Begin
  If Not fShowGutter Then Begin
    fGutterNumChars := 0;
    fGutterWidth := 0;
    Exit;
  End;
  maxDigits := MinGutterChars;
  For i := 0 To fLines.Count - 1 Do Begin
    s := fLines[i];
    If (s <> '') And (s[1] In ['0'..'9']) Then Begin
      digits := 0;
      While (digits < Length(s)) And (s[digits+1] In ['0'..'9']) Do Inc(digits);
      If digits > maxDigits Then maxDigits := digits;
    End;
  End;
  fGutterNumChars := maxDigits;
  fGutterWidth    := blobZone + (maxDigits * 8);
End;

Function SP_BASICEditor.CountStatementSeps(const s: aString; SkipChars: Integer): Integer;
// Count statement separators in a BASIC source line.
// Separators: ':',  'THEN',  'ELSE',  and ';' outside InClr commands.
// InClr commands use ';' as a colour-parameter separator, not a statement break:
//   CIRCLE INPUT PRINT TEXT PLOT DRAW ELLIPSE CURVE RECTANGLE POLYGON FILL MULTIPLOT
Var
  i, slen, wStart: Integer;
  inStr, inREM, inClr: Boolean;
  c: aChar;
  w: aString;
Begin
  Result := 0; inStr := False; inREM := False; inClr := False;
  i := SkipChars + 1; slen := Length(s);
  // Skip line number digits and leading spaces
  While (i <= slen) And (s[i] In['0'..'9',' ']) Do Inc(i);
  While i <= slen Do Begin
    c := s[i];
    If inREM Then Break;
    If c = '"' Then Begin inStr := Not inStr; Inc(i); Continue; End;
    If inStr Then Begin Inc(i); Continue; End;
    If c = ':' Then Begin
      Inc(Result); inClr := False; Inc(i); Continue;
    End;
    If c = ';' Then Begin
      If Not inClr Then Inc(Result);
      Inc(i); Continue;
    End;
    // Extract next keyword (letters, numbers and underscores to prevent partial matches)
    If c In ['A'..'Z','a'..'z'] Then Begin
      wStart := i;
      While (i <= slen) And (s[i] In['A'..'Z','a'..'z','0'..'9','_']) Do Inc(i);
      w := '';
      While wStart < i Do Begin
        w := w + UpCase(s[wStart]);
        Inc(wStart);
      End;
      If (w = 'THEN') Or (w = 'ELSE') Then Begin
        Inc(Result); inClr := False;
      End Else If w = 'REM' Then
        inREM := True
      Else Begin
        inClr := (w = 'CIRCLE')    Or (w = 'INPUT')     Or (w = 'PRINT') Or
                 (w = 'TEXT')      Or (w = 'PLOT')       Or (w = 'DRAW')  Or
                 (w = 'ELLIPSE')   Or (w = 'CURVE')      Or (w = 'RECTANGLE') Or
                 (w = 'POLYGON')   Or (w = 'FILL')       Or (w = 'MULTIPLOT');
      End;
      Continue;
    End;
    Inc(i);
  End;
End;

Procedure SP_BASICEditor.InsertChar(ch: aString);
Begin
  If fMode = bemDirect Then Begin
    EDITERROR := False;
    EDITERRORPOS := 0;
  End;
  Inherited;
End;

Procedure SP_BASICEditor.DeleteCharBack;
Begin
  If fMode = bemDirect Then Begin
    EDITERROR := False;
    EDITERRORPOS := 0;
  End;
  Inherited;
End;

Procedure SP_BASICEditor.DeleteCharFwd;
Begin
  If fMode = bemDirect Then Begin
    EDITERROR := False;
    EDITERRORPOS := 0;
  End;
  Inherited;
End;

Procedure SP_BASICEditor.DrawGutterCell(RawLine: Integer; IsFirstSeg: Boolean;
  GutterX, Y, H: Integer; GutterSelX1, GutterSelX2: Integer; EmptyCell: Boolean);
Var
  DefaultDraw:   Boolean;
  NumStr:        aString;
  ax, ai, aj,
  blobx, bmSlot,
  slot, cfW,
  nx, ny:        Integer;
  aClr,
  BgClr, SelClr, nClr, sClr: Byte;
  FirstRaw, BASICLine: Integer;
  canHasBlob, isCursorLine, inProgLine, isBreakpoint:  Boolean;
Begin
  DefaultDraw  := True;

  If Assigned(fOnGutterPaint) Then
    fOnGutterPaint(Self, RawLine, IsFirstSeg, GutterX, Y, fGutterWidth, H, DefaultDraw);
  If Not DefaultDraw Then Exit;

  If EmptyCell Then Begin
    FillRect(GutterX, Y, GutterX + fGutterWidth - 1, Y + H - 1, GutterBg);
    Exit;
  End;

  cfW := Max(1, Round(iFW * iSX));

  // --- PROGLINE Gutter Highlight ---
  inProgLine := False;
  If fMode = bemPROGLINE Then Begin
    FirstRaw := RawLine;
    While (FirstRaw > 0) And (fLineNumLen[FirstRaw] = 0) Do Dec(FirstRaw);
    BASICLine := RawLineNumber(FirstRaw);
    If BASICLine = SP_SysVars.PROGLINE Then Begin
      BgClr := ProglineGtr;
      inProgLine := True;
    End Else
      BgClr := GutterBg;
  End Else Begin
    isCursorLine := (RawLine = fCursorLine) And fFocused And Not HasSelection;
    If isCursorLine Then BgClr := GutterCursorBg Else BgClr := GutterBg;
  End;

  isBreakpoint := (RawLine < Length(fBreakpoints)) And fBreakpoints[RawLine];
  If isBreakpoint Then
    FillRect(GutterX, Y, GutterX + fGutterWidth - 1, Y + H - 1, 10)  // bright red background
  Else
    FillRect(GutterX, Y, GutterX + fGutterWidth - 1, Y + H - 1, BgClr);
  // Left-edge emphasis bar - always drawn over the background
  If isBreakpoint Then
    FillRect(GutterX, Y, GutterX + 2, Y + H - 1, 2);                 // dark red strip

  If GutterSelX1 >= 0 Then Begin
    If fFocused Then SelClr := fHighlightClr Else SelClr := fUnfocusedHighlightClr;
    FillRect(GutterSelX1, Y, GutterSelX2 - 1, Y + H - 1, SelClr);
  End;

  ny := Y + (H - 8) Div 2;

  // --- Blob zone (leftmost blobZone pixels) ---
  If IsFirstSeg Then Begin
    blobX := GutterX + 2;
    bmSlot := -1;
    For slot := 0 To 9 Do
      If fBookmarks[slot] = RawLine Then Begin bmSlot := slot; Break; End;

    If Not isBreakpoint Then Begin
      If RawLine = fExecLine Then Begin
        // Arrow - green while running, yellow when paused
        ax := blobX + 8;
        If fExecRunning Then aClr := 4 Else aClr := 6;
        For ai := -1 To 1 Do
          For aj := -1 To 1 Do
            Print(ax + ai, ny + aj, #253, 0, -1, 1.0, 1.0, False, False, False, False);
        Print(ax, ny, #253, aClr, -1, 1.0, 1.0, False, False, False, False);
      End;
      canHasBlob := RawLineCanHasBlob(RawLine);
      If canHasBlob Then Begin
        Case fLineState[RawLine] Of
          spLineNull:
            Begin
              If Not inProgLine Then Begin
                Print(blobX, ny, #245, GutterBg - 1, -1, 1.0, 1.0, False, False, False, False);
                Print(blobX, ny, #244, GutterBg + 1, -1, 1.0, 1.0, False, False, False, False);
              End;
            End;
          spLineOk:
            Begin
              Print(blobX, ny, #245, 0, -1, 1.0, 1.0, False, False, False, False);
              Print(blobX, ny, #244, 4, -1, 1.0, 1.0, False, False, False, False);
            End;
          spLineError:
            Begin
              Print(blobX, ny, #243, 0, -1, 1.0, 1.0, False, False, False, False);
              Print(blobX, ny, #245, 2, -1, 1.0, 1.0, False, False, False, False);
            End;
          spLineDirty:
            Begin
              Print(blobX, ny, #245, 0, -1, 1.0, 1.0, False, False, False, False);
              Print(blobX, ny, #244, 1, -1, 1.0, 1.0, False, False, False, False);
            End;
          spLineDuplicate:
            Begin
              Print(blobX, ny, #243, 0, -1, 1.0, 1.0, False, False, False, False);
              Print(blobX, ny, #245, 6, -1, 1.0, 1.0, False, False, False, False);
            End;
        End;
      End;
    End;
    // Bookmark digit
    If bmSlot >= 0 Then
      Print(GutterX + 1 + (cfW * 2), ny, aString(#5 + aChar(bmSlot +1)), 1, 6, 1.0, 1.0, False, False, False, False);
  End;

  // --- Number / statement column ---

  If IsBreakPoint Then Begin
    nClr := 15;
    sClr := 7;
  End Else Begin
    nClr := NumColor;
    If inProgLine Then
      sClr := proglineClr
    Else
      sClr := StmtColor;
  End;
  If IsFirstSeg Then Begin
    If (RawLine < Length(fLineNumLen)) And (fLineNumLen[RawLine] > 0) Then Begin
      NumStr   := Copy(fLines[RawLine], 1, fLineNumLen[RawLine]);
      nx       := GutterX + blobZone + (fGutterNumChars - Length(NumStr)) * 8;
      Print(nx, y, NumStr, nClr, -1, iSX, iSY, False, False, False, False);
      fPrevGutterStmt := 1;
    End Else
      If (RawLine < Length(fStatementIdx)) And
         (fStatementIdx[RawLine] > 1) And
         (fStatementIdx[RawLine] <> fPrevGutterStmt) Then Begin
        NumStr := IntToString(fStatementIdx[RawLine]);
        nx     := GutterX + blobZone + (fGutterNumChars - Length(NumStr)) * 8;
        Print(nx, y, NumStr, sClr, -1, iSX, iSY, False, False, False, False);
        fPrevGutterStmt := fStatementIdx[RawLine];
      End;
  End;
End;

// ---------------------------------------------------------------------------
// Smart-indent helpers
// ---------------------------------------------------------------------------

Function SP_BASICEditor.StartsWithWord(const s, w: aString): Boolean;
Var wl: Integer;
Begin
  wl := Length(w);
  Result := (Length(s) >= wl) And (Upper(Copy(s, 1, wl)) = w) And
            ((Length(s) = wl) Or Not (s[wl+1] In ['A'..'Z','a'..'z','0'..'9','_']));
End;

Function SP_BASICEditor.EndsWithWord(const s, w: aString): Boolean;
Var wl, sl: Integer;
Begin
  wl := Length(w); sl := Length(s);
  Result := (sl >= wl) And (Upper(Copy(s, sl-wl+1, wl)) = w) And
            ((sl = wl) Or Not (s[sl-wl] In ['A'..'Z','a'..'z','0'..'9','_']));
End;

Procedure SP_BASICEditor.VScrollPaintAfter(Control: SP_BaseComponent);
Var
  i, y, trackTop, trackH, cfH, slot: Integer;
Begin
  // Let SP_Memo paint the search-result markers first
  Inherited VScrollPaintAfter(Control);

  If fLines.Count = 0 Then Exit;

  trackTop := 0;
  trackH   := Control.Height;
  If SP_ScrollBar(Control).ShowButtons Then Begin
    cfH      := Max(1, Round(iFH * iSY));
    trackTop := cfH;
    Dec(trackH, cfH * 2);
  End;
  If trackH <= 4 Then Exit;

  // Error lines (2px red tick)
  For i := 0 To Min(High(fLineState), fLines.Count - 1) Do
    If fLineState[i] = spLineError Then Begin
      y := trackTop + Round((trackH - 4) * i / fLines.Count);
      Control.FillRect(1, y + 1, Control.Width - 2, y + 2, SBMarkerError);
    End;

  // Breakpoints (2px red tick, slightly brighter - drawn over error so visible)
  For i := 0 To Min(High(fBreakpoints), fLines.Count - 1) Do
    If fBreakpoints[i] Then Begin
      y := trackTop + Round((trackH - 4) * i / fLines.Count);
      Control.FillRect(1, y, Control.Width - 2, y + 3, SBMarkerBreak);
    End;

  // Exec line (3px green or yellow tick)
  If (fExecLine >= 0) And (fExecLine < fLines.Count) Then Begin
    y := trackTop + Round((trackH - 4) * fExecLine / fLines.Count);
    If fExecRunning Then
      Control.FillRect(1, y, Control.Width - 2, y + 3, SBMarkerExec)
    Else
      Control.FillRect(1, y, Control.Width - 2, y + 3, SBMarkerBookmark);
  End;

  // Bookmarks (1px yellow tick)
  For slot := 0 To 9 Do
    If (fBookmarks[slot] >= 0) And (fBookmarks[slot] < fLines.Count) Then Begin
      y := trackTop + Round((trackH - 4) * fBookmarks[slot] / fLines.Count);
      Control.FillRect(2, y + 1, Control.Width - 3, y + 2, SBMarkerBookmark);
    End;
End;

// ---------------------------------------------------------------------------
// Property setters
// ---------------------------------------------------------------------------

Procedure SP_BASICEditor.SetShowGutter(b: Boolean);
Begin
  If b <> fShowGutter Then Begin
    fShowGutter := b; CalcGutterWidth;
    fWrapDirty := True; RebuildWrappedLines; Paint;
  End;
End;

Procedure SP_BASICEditor.SetHighlight(b: Boolean);
Begin
  If fHighlight <> b Then Begin
    fHighlight := b; fSyntaxDirtyFrom := 0; Paint;
  End;
End;

// ---------------------------------------------------------------------------
// Structural BASIC program operations
// ---------------------------------------------------------------------------

// Sort all raw lines into ascending BASIC line number order.
// Lines with no line number (continuations) travel with their owning numbered
// line as a unit.  Operates entirely on fLines; fires OnFullTextReplaced so
// the host bridge rebuilds Listing and calls SetAllToCompile.
Procedure SP_BASICEditor.SortByLineNumber;
Type
  TLineGroup = Record
    LineNum: Integer;
    Lines:   Array of aString;
  End;
Var
  Groups:   Array of TLineGroup;
  GCount:   Integer;
  i, j, n:  Integer;
  Tmp:      TLineGroup;
  Swapped:  Boolean;
Begin
  If fWrapDirty Then RebuildWrappedLines;
  If fLines.Count = 0 Then Exit;

  // Collect lines into groups: each numbered line + its continuations
  GCount := 0;
  SetLength(Groups, fLines.Count);
  i := 0;
  While i < fLines.Count Do Begin
    n := fLineNumLen[i];
    If n > 0 Then Begin
      Groups[GCount].LineNum := StrToIntDef(String(Copy(fLines[i], 1, n)), 0);
      SetLength(Groups[GCount].Lines, 0);
    End Else Begin
      // Continuation before any numbered line - attach to a phantom group 0
      If GCount = 0 Then Begin
        Groups[GCount].LineNum := -1;
        SetLength(Groups[GCount].Lines, 0);
        Inc(GCount);
      End;
      Dec(GCount); // will re-inc below
    End;
    j := Length(Groups[GCount].Lines);
    SetLength(Groups[GCount].Lines, j + 1);
    Groups[GCount].Lines[j] := fLines[i];
    Inc(GCount);
    Inc(i);
  End;

  // Bubble sort groups by line number (programs are rarely huge)
  Repeat
    Swapped := False;
    For i := 0 To GCount - 2 Do
      If (Groups[i].LineNum > 0) And (Groups[i+1].LineNum > 0) And
         (Groups[i].LineNum > Groups[i+1].LineNum) Then Begin
        Tmp          := Groups[i];
        Groups[i]    := Groups[i+1];
        Groups[i+1]  := Tmp;
        Swapped      := True;
      End;
  Until Not Swapped;

  // Rebuild fLines from sorted groups
  StoreUndo(uoBlock);
  fLines.Clear;
  For i := 0 To GCount - 1 Do
    For j := 0 To High(Groups[i].Lines) Do
      fLines.Add(Groups[i].Lines[j]);
  If fLines.Count = 0 Then fLines.Add('');

  fCursorLine := 0; fCursorCol := 1;
  fSelLine := 0; fSelCol := 1;
  fWrapDirty := True;
  RebuildWrappedLines;
  OnFullTextReplaced;
  Paint;
End;

// Renumber BASIC lines in the range [Start..Finish] to begin at FirstLine
// with the given Step, then patch all GO TO / GO SUB / RUN / RESTORE / LIST
// references throughout the whole program.
Procedure SP_BASICEditor.RenumberLines(Start, Finish, FirstLine, Step: Integer);
Type
  TChangeRec = Record OldNum, NewNum: Integer; End;
Var
  Changes:                 Array of TChangeRec;
  NChanges:                Integer;
  i, j, nIdx, fIdx:        Integer;
  LineNum, CurNew:         Integer;
  s, e:                    aString;
  InStr, InREM:            Boolean;
  Keyword:                 aString;
  OldLen, NewLen:          Integer;
Begin
  If Step < 1 Then Exit;
  If Start < 0  Then Start  := 0;
  If Finish < 0 Then Finish := MaxInt;

  If fWrapDirty Then RebuildWrappedLines;

  // Sort first - renumbering only makes sense on an ordered program
  SortByLineNumber;

  StoreUndo(uoBlock);

  // Pass 1 - build the change table and rewrite line number prefixes
  NChanges := 0;
  SetLength(Changes, fLines.Count);
  CurNew := FirstLine;

  For i := 0 To fLines.Count - 1 Do Begin
    If fLineNumLen[i] = 0 Then Continue;
    LineNum := RawLineNumber(i);
    If (LineNum >= Start) And (LineNum <= Finish) Then Begin
      Changes[NChanges].OldNum := LineNum;
      Changes[NChanges].NewNum := CurNew;
      Inc(NChanges);
      // Replace the line number prefix in fLines[i]
      s := fLines[i];
      s := IntToString(CurNew) + Copy(s, fLineNumLen[i] + 1, MaxInt);
      fLines[i] := s;
      // fLineNumLen will be rebuilt via RebuildWrappedLines after this
      Inc(CurNew, Step);
    End;
  End;
  SetLength(Changes, NChanges);

  // Pass 2 - scan all lines for branch keywords and patch targets
  For i := 0 To fLines.Count - 1 Do Begin
    s      := fLines[i];
    nIdx   := 1;
    InStr  := False;
    InREM  := False;
    If fLineNumLen[i] > 0 Then Begin
      InStr := False; InREM := False;
      nIdx  := fLineNumLen[i] + 1;
    End;

    While (nIdx <= Length(s)) And Not InREM Do Begin
      // Skip to next letter (outside strings)
      While (nIdx <= Length(s)) And (Not (s[nIdx] In ['A'..'Z','a'..'z']) Or InStr) Do Begin
        If s[nIdx] = '"' Then InStr := Not InStr;
        Inc(nIdx);
      End;
      If nIdx > Length(s) Then Break;

      // Collect keyword (letters and spaces, treating 'GO TO'/'GO SUB')
      Keyword := '';
      While (nIdx <= Length(s)) And (s[nIdx] In ['A'..'Z','a'..'z',' ']) Do Begin
        If s[nIdx] = ' ' Then Begin
          If Upper(Keyword) <> 'GO' Then Begin
            SP_SkipSpaces(s, nIdx);
            Break;
          End;
        End;
        Keyword := Keyword + s[nIdx];
        Inc(nIdx);
      End;
      Keyword := Upper(StripSpaces(Keyword));

      If (Keyword = 'GOTO') Or (Keyword = 'GOSUB') Or
         (Keyword = 'RUN')  Or (Keyword = 'RESTORE') Or
         (Keyword = 'LIST') Then Begin
        // Skip whitespace to the number
        While (nIdx <= Length(s)) And (s[nIdx] <= ' ') Do Inc(nIdx);
        fIdx := nIdx;
        LineNum := 0;
        While (nIdx <= Length(s)) And (s[nIdx] In ['0'..'9']) Do Begin
          LineNum := LineNum * 10 + Ord(s[nIdx]) - 48;
          Inc(nIdx);
        End;
        If LineNum > 0 Then Begin
          // Find the >= entry in the change table (sorted by OldNum asc)
          For j := 0 To NChanges - 1 Do
            If Changes[j].OldNum >= LineNum Then Begin
              If Changes[j].OldNum = LineNum Then Begin
                e      := IntToString(Changes[j].NewNum);
                OldLen := nIdx - fIdx;
                NewLen := Length(e);
                s      := Copy(s, 1, fIdx - 1) + e + Copy(s, nIdx, MaxInt);
                Inc(nIdx, NewLen - OldLen);
                fLines[i] := s;
              End;
              Break;
            End;
        End;
      End Else
        If Keyword = 'REM' Then InREM := True;
    End;
  End;

  // Rebuild wrap data and notify host
  fWrapDirty := True;
  RebuildWrappedLines;
  OnFullTextReplaced;
  Paint;
End;

// Delete all BASIC lines whose line numbers fall in [Start..Finish].
Procedure SP_BASICEditor.DeleteLineRange(Start, Finish: Integer);
Type
  TDelEntry = Record RawIdx, Count: Integer; End;
Var
  i, j, Count: Integer;
  LineNum:     Integer;
  Deletions:   Array of TDelEntry;
  nDel:        Integer;
Begin
  If Start > Finish Then Exit;
  If fWrapDirty Then RebuildWrappedLines;

  SortByLineNumber;
  StoreUndo(uoBlock);

  // --- Pass 1: collect affected groups, walking FORWARD so indices are
  // stable (nothing has been deleted yet).
  nDel := 0;
  SetLength(Deletions, 0);
  i := 0;
  While i < fLines.Count Do Begin
    If fLineNumLen[i] > 0 Then Begin
      LineNum := RawLineNumber(i);
      If (LineNum >= Start) And (LineNum <= Finish) Then Begin
        Count := LastRawOfBASICLine(i) - i + 1;
        SetLength(Deletions, nDel + 1);
        Deletions[nDel].RawIdx := i;
        Deletions[nDel].Count  := Count;
        Inc(nDel);
        Inc(i, Count);  // skip over continuation raw lines
        Continue;
      End;
    End;
    Inc(i);
  End;

  // --- Pass 2: delete BACKWARDS so earlier indices stay valid.
  // Fire OnLinesChanged per group - this is the same path DeleteBASICLine
  // uses, so StructureChanged (+ our new SP_Program_Delete_Line calls)
  // keeps Listing and SP_Program in sync for every group removed.
  For j := nDel - 1 DownTo 0 Do Begin
    For i := 1 To Deletions[j].Count Do
      fLines.Delete(Deletions[j].RawIdx);
    OnLinesChanged(Deletions[j].RawIdx, -Deletions[j].Count);
  End;

  If fLines.Count = 0 Then fLines.Add('');
  fCursorLine := Min(fCursorLine, fLines.Count - 1);
  fSelLine    := fCursorLine;
  fWrapDirty  := True;
  RebuildWrappedLines;
  // OnFullTextReplaced removed: no longer needed because every deletion
  // now fires OnLinesChanged, which keeps Listing and SP_Program in sync
  // incrementally. OnFullTextReplaced/TextReset would only SetAllToCompile
  // on surviving lines, leaving deleted SP_Program entries unreachable.
  Paint;
End;

// Merge BASIC lines in [Start..Finish] - each consecutive pair is joined with
// a colon separator so they become a single logical BASIC line.
// Merge BASIC lines in [Start..Finish] - each consecutive pair is joined with
// a colon separator so they become a single logical BASIC line.
Procedure SP_BASICEditor.MergeLineRange(Start, Finish: Integer);
Var
  i, sRaw: Integer;
  LineNum:  Integer;
  numLen:   Integer;
  joined:   aString;
  InRange:  Boolean;
Begin
  If Start > Finish Then Exit;
  If fWrapDirty Then RebuildWrappedLines;

  SortByLineNumber;
  StoreUndo(uoBlock);

  i       := 0;
  InRange := False;
  sRaw    := -1;

  While i < fLines.Count Do Begin
    If fLineNumLen[i] > 0 Then Begin
      LineNum := RawLineNumber(i);
      If (LineNum >= Start) And (LineNum <= Finish) Then Begin
        If Not InRange Then Begin
          sRaw    := i;
          InRange := True;
          Inc(i);
        End Else Begin
          // Merge line i into line sRaw: append ':' + body (sans line number)
          numLen          := fLineNumLen[i];
          joined          := fLines[sRaw] + ':' + Copy(fLines[i], numLen + 1, MaxInt);
          fLines[sRaw]    := joined;
          // Notify bridge that sRaw content changed - Listing[sRaw] updated
          // and AddCompileLine queues it for recompilation so SP_Program
          // gets the merged version.
          OnLineChanged(sRaw);
          // Delete the merged-away line from fLines, then fire OnLinesChanged
          // so StructureChanged removes it from both Listing and SP_Program.
          // (Don't increment i - the next line slides down to the same index.)
          fLines.Delete(i);
          OnLinesChanged(i, -1);
        End;
      End Else Begin
        InRange := False;
        Inc(i);
      End;
    End Else
      Inc(i);
  End;

  If fLines.Count = 0 Then fLines.Add('');
  fCursorLine := Min(fCursorLine, fLines.Count - 1);
  fSelLine    := fCursorLine;
  fWrapDirty  := True;
  RebuildWrappedLines;
  // OnFullTextReplaced removed: we now fire OnLineChanged + OnLinesChanged
  // for every change above, so Listing and SP_Program stay in sync
  // incrementally. The old OnFullTextReplaced/TextReset path left merged-away
  // lines alive in SP_Program because SetAllToCompile only marks survivors.
  Paint;
End;

Procedure SP_BASICEditor.LoadHistory(Const Items: Array of aString);
Var i: Integer;
Begin
  fHistoryLen := 0;
  For i := 0 To High(Items) Do
    AddToHistory(Items[i]);
End;

Function SP_BASICEditor.GetHistorySnapshot: TStringDynArray;
Var i: Integer;
Begin
  SetLength(Result, fHistoryLen);
  For i := 0 To fHistoryLen - 1 Do
    Result[i] := fHistory[i];
End;

// ---------------------------------------------------------------------------
// ZXASCII load
// ---------------------------------------------------------------------------

Procedure AutoExpandCompounds(Var s: aString; Var CCol: Integer);
Const
  Compounds: Array[0..9, 0..1] of aString =
    (('DEFPROC', 'DEF PROC'), ('DEFFN', 'DEF FN'), ('DEFSTRUCT', 'DEF STRUCT'),
     ('ENDPROC', 'END PROC'), ('ENDIF', 'END IF'), ('ENDSTRUCT', 'END STRUCT'),
     ('EXITPROC', 'EXIT PROC'), ('ENDCASE', 'END CASE'), ('GOTO', 'GO TO'),
     ('GOSUB', 'GO SUB'));
Var
  i, p, k, matchLen: Integer;
  inStr, isWordStart, isWordEnd: Boolean;
  uStr: aString;
Begin
  uStr := Upper(s);
  For i := 0 To 9 Do Begin
    p := 1;
    matchLen := Length(Compounds[i, 0]);
    While p <= Length(uStr) - matchLen + 1 Do Begin
      // Fast check on the first character
      If uStr[p] = Compounds[i, 0][1] Then Begin
        If Copy(uStr, p, matchLen) = Compounds[i, 0] Then Begin

          // 1. Ensure we are not inside a string
          inStr := False;
          For k := 1 To p - 1 Do
            If s[k] = '"' Then inStr := Not inStr;

          If Not inStr Then Begin
            // 2. Ensure it's a whole word (don't expand "MYGOTO")
            isWordStart := (p = 1) Or Not (uStr[p-1] In['A'..'Z', '0'..'9', '_']);
            isWordEnd   := (p + matchLen > Length(uStr)) Or Not (uStr[p + matchLen] In['A'..'Z', '0'..'9', '_']);

            If isWordStart And isWordEnd Then Begin
              // Modify the raw string
              Delete(s, p, matchLen);
              System.Insert(Compounds[i, 1], s, p);
              uStr := Upper(s); // Refresh upper string for subsequent searches

              // Shift the cursor forward if it was sitting after the injected space
              If CCol > p Then Inc(CCol);

              Inc(p, matchLen + 1);
              Continue;
            End;
          End;
        End;
      End;
      Inc(p);
    End;
  End;
End;

Class Function SP_BASICEditor.ParseBASICText(Const RawText: aString; Out AutoStart: Integer; Out ProgName:  aString; Out Changed:   Boolean): TStringList;
Var
  p, i: Integer;
  Line, Plain: aString;
Begin
  Result    := TStringList.Create;
  AutoStart := -1;
  ProgName  := '';
  Changed   := False;

  p := 1;
  If Copy(RawText, 1, 7) = 'ZXASCII' Then Begin
    p := 8;
    While (p <= Length(RawText)) And (RawText[p] < #32) Do Inc(p);
  End;

  While p <= Length(RawText) Do Begin

    i := p;
    While (i <= Length(RawText)) And (RawText[i] <> #13) And (RawText[i] <> #10) Do Inc(i);

    Line := Copy(RawText, p, i - p);
    p := i;
    If (p <= Length(RawText)) And (RawText[p] = #13) Then Inc(p);
    If (p <= Length(RawText)) And (RawText[p] = #10) Then Inc(p);

    While (Line <> '') And (Line[Length(Line)] <= ' ') Do
      SetLength(Line, Length(Line) - 1);

    Plain := StripLeadingSpaces(Line);

    If Lower(Copy(Plain, 1, 4)) = 'auto' Then Begin
      AutoStart := StrToIntDef(String(StripLeadingSpaces(Copy(Plain, 5, MaxInt))), -1);
    End Else If Lower(Copy(Plain, 1, 4)) = 'prog' Then Begin
      ProgName := StripLeadingSpaces(Copy(Plain, 5, MaxInt));
    End Else If Lower(Copy(Plain, 1, 7)) = 'changed' Then Begin
      Plain   := StripLeadingSpaces(Copy(Plain, 8, MaxInt));
      Changed := Lower(Copy(Plain, 1, 4)) = 'true';
    End Else If Line <> '' Then
      Result.Add(Line);

  End;
End;

Procedure SP_BASICEditor.LoadFromBASICText(Const RawText: aString; Out AutoStart: Integer; Out ProgName:  aString; Out Changed:   Boolean);
Var
  Lines: TStringList;
  i:     Integer;
  sb:    aString;
Begin
  Lines := ParseBASICText(RawText, AutoStart, ProgName, Changed);
  Try
    sb := '';
    For i := 0 To Lines.Count - 1 Do Begin
      If i > 0 Then sb := sb + #13;
      sb := sb + Lines[i];
    End;
    If sb = '' Then sb := ' ';
    SetText(sb);
  Finally
    Lines.Free;
  End;
End;

Procedure SP_BASICEditor.Draw;
Var
  bOff: Integer;
Begin

  Inherited;
  bOff := GetTopOffset;  // gutter fill only needs the vertical inset
  If fMode <> bemDirect Then Begin
    FillRect(0, 0,                  fGutterWidth + GetLeftOffset - 1, bOff - 1,            GutterBg); // top strip
    FillRect(0, bOff,               GetLeftOffset - 1, ClientH + bOff - 1,                 GutterBg); // left strip
    FillRect(0, ClientH + bOff,     fGutterWidth + GetLeftOffset - 1, ClientH + bOff * 2,  GutterBg); // bottom strip
  End;

End;

Procedure SP_BASICEditor.BASICFindAll(Const Text: aString; Options: SP_SearchOptions; OnEval: SP_EvalEvent; ClearFirst: Boolean = True; HitColour: Byte = 0);
Var
  SearchText, s: aString;
  i, k, e, tl, fl, lnc: Integer;
  InString, InREM, Match: Boolean;
  ps, pd: pByte;
  Error: TSP_ErrorCode;
  L1, C1, L2, C2: Integer;
  StartL, FinishL, StartP, FinishP: Integer;
Begin
  If ClearFirst Then Begin
    SetLength(fSearchResults, 0);
    fSearchCurrent := -1;
    fl := 0;
  End Else
    fl := Length(fSearchResults);
  fSearchOptions := Options;

  SearchText := Text;
  If SearchText = '' Then Begin Paint; Exit; End;

  // soExpression: evaluate to a string first
  If (soExpression In Options) And Assigned(OnEval) Then Begin
    Error.Code := SP_ERR_OK;
    SearchText := OnEval(Self, SearchText, Error);
    If Error.Code <> SP_ERR_OK Then Begin Paint; Exit; End;
  End;

  If soCondenseSpaces In Options Then SearchText := StripSpaces(SearchText);
  If Not (soMatchCase In Options) Then SearchText := Lower(SearchText);
  tl := Length(SearchText);
  If tl = 0 Then Begin Paint; Exit; End;

  // Selection bounds
  If (soInSelection In Options) And HasSelection Then Begin
    GetSelectionOrder(L1, C1, L2, C2);
    StartL := L1; StartP := C1;
    FinishL := L2; FinishP := C2;
  End Else Begin
    StartL := 0; StartP := 1;
    FinishL := fLines.Count - 1;
    FinishP := Length(fLines[fLines.Count - 1]);
  End;

  For i := StartL To FinishL Do Begin
    s := fLines[i];
    lnc := fLineNumLen[i];       // skip line-number prefix
    If lnc > 0 Then s := Copy(s, lnc + 1, MaxInt);
    If Not (soMatchCase In Options) Then s := Lower(s);
    If soCondenseSpaces In Options Then s := StripSpaces(s);

    If i = StartL Then k := Max(1, StartP - lnc)
    Else k := 1;
    If i = FinishL Then e := Min(Length(s), FinishP)
    Else e := Length(s);

    If Length(s) = 0 Then Continue;

    InString := False; InREM := False;

    ps := pByte(Pointer(s));
    Inc(ps, k - 1);
    pd := pByte(Pointer(SearchText));

    While k <= e Do Begin
      If SP_PartialMatchPtrs(ps, pd, tl) Then Begin
        // REM/string context tracking
        If (soInREM In Options) Or (soInString In Options) Then Begin
          Match := (soInREM In Options) And InREM;
          Match := Match Or ((soInString In Options) And InString);
        End Else Begin
          Match := Not InREM;
        End;

        If Match And (soWholeWords In Options) Then
          Match := ((k = 1) Or Not (s[k - 1] In
                    ['A'..'Z', 'a'..'z', '0'..'9', '_'])) And
                   ((k + tl - 1 >= Length(s)) Or Not (s[k + tl] In
                    ['A'..'Z', 'a'..'z', '0'..'9', '_']));

        If Match And (soVarName In Options) And (SearchText[tl] <> '(') Then
          Match := ((k = 1) Or Not (s[k - 1] In
                    ['_', '$', 'A'..'Z', 'a'..'z', '0'..'9'])) And
                   ((k + tl - 1 >= Length(s)) Or Not (s[k + tl] In
                    ['_', '$', 'A'..'Z', 'a'..'z', '0'..'9']));

        If Match Then Begin
          SetLength(fSearchResults, fl + 1);
          fSearchResults[fl].Line   := i;
          fSearchResults[fl].Col    := k + lnc;  // restore line-num offset
          fSearchResults[fl].Len    := tl;
          fSearchResults[fl].Colour := HitColour;
          Inc(fl);
          Inc(k, tl);
          Inc(ps, tl);
          Continue;
        End;
      End;

      // Track string/REM state
      If s[k] = '"' Then InString := Not InString;
      If Not InString And (k + 3 <= Length(s)) And
         (Lower(Copy(s, k, 4)) = 'rem ') Then InREM := True;

      Inc(k); Inc(ps);
    End;
  End;

  If fVScroll.Visible Then fVScroll.Paint;
  Paint;
End;

Procedure SP_BASICEditor.BASICFindNext(Forward: Boolean);
Begin
  FindNext(Forward);
End;

Procedure SP_BASICEditor.BASICReplaceAll(Const Search, Replace: aString; Options: SP_SearchOptions; OnEval: SP_EvalEvent);
Var
  SearchText, ReplaceText, s, seg: aString;
  i, k, tl, rl, lnc: Integer;
  InString: Boolean;
  Error: TSP_ErrorCode;
Begin
  SearchText  := Search;
  ReplaceText := Replace;

  If (soExpression In Options) And Assigned(OnEval) Then Begin
    Error.Code := SP_ERR_OK;
    SearchText  := OnEval(Self, SearchText,  Error);
    If Error.Code <> SP_ERR_OK Then Exit;
    ReplaceText := OnEval(Self, ReplaceText, Error);
    If Error.Code <> SP_ERR_OK Then Exit;
  End;

  If Not (soMatchCase In Options) Then SearchText := Lower(SearchText);
  tl := Length(SearchText);
  If tl = 0 Then Exit;

  rl := Length(ReplaceText);

  StoreUndo(uoBlock);

  For i := 0 To fLines.Count - 1 Do Begin
    s   := fLines[i];
    lnc := fLineNumLen[i];
    k   := lnc + 1;
    InString := False;

    While k <= Length(s) - tl + 1 Do Begin
      // Track context
      If s[k] = '"' Then InString := Not InString;

      If soMatchCase In Options Then seg := Copy(s, k, tl)
      Else seg := Lower(Copy(s, k, tl));

      If seg = SearchText Then Begin
        s := Copy(s, 1, k - 1) + ReplaceText + Copy(s, k + tl, MaxInt);
        Inc(k, rl);
      End Else
        Inc(k);
    End;

    If s <> fLines[i] Then
      fLines[i] := s;
  End;

  fWrapDirty := True;
  RebuildWrappedLines;
  OnFullTextReplaced;   // fires OnTextReset - host rebuilds Listing
  Paint;
End;

Function SP_BASICEditor.HasFindResults: Boolean;
Begin
  Result := Length(fSearchResults) > 0;
End;

end.
