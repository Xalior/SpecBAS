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

unit SP_AmigaGuideUnit;

// SP_AmigaGuide - AmigaGuide hypertext viewer, subclass of SP_Memo.
//
// Supported inline tags:
//   @{b}/@{ub}           Bold on/off
//   @{i}/@{ui}           Italic on/off
//   @{u}/@{uu}           Underline on/off  (drawn by DrawLineDecorations)
//   @{fg colour}         Foreground ink  (named or palette index 0-255)
//   @{bg colour}         Background paper (named or palette index 0-255)
//   @{"t" LINK target}   Hyperlink button
//
// Supported line-level tags:
//   @{JCENTER}           Centre-justify current line
//   @{JRIGHT}            Right-justify current line
//   @{JLEFT}             Left-justify (default)
//   @{lindent n}         Left-indent n character columns
//   @{line}              Hard line break
//   @{par}               Paragraph break (inserts a blank line)
//
// AmigaGuide named colours are mapped to SpecBAS palette:
//   text/detail/filltext -> 0 (black)   shine     -> 15 (bright white)
//   shadow               -> 240         fill      ->  5 (cyan)
//   background           ->   7 (grey)  halflight -> 249
//   Numeric strings are used directly as palette indices.
//
// Navigation:
//   Click a link button  - follow the link
//   Back/Fwd buttons     - history navigation
//
// Background defaults to colour 7 (mid-grey).

{$INCLUDE SpecBAS.inc}

interface

Uses
  Math, SysUtils, Classes, Types, SP_Tokenise,
  SP_BaseComponentUnit, SP_Util, SP_Errors, SP_EditUnit,
  SP_ButtonUnit, SP_LabelUnit, SP_ContainerUnit, SP_MemoUnit;

Type

  // Formatting

  TGuideSpan = Record
    ColStart, ColEnd:           Integer;  // 1-based columns in the raw plain text
    Bold, Italic, Underline:    Boolean;
    HasInk:  Boolean; Ink:  Byte;
    HasPaper: Boolean; Paper: Byte;
  End;

  TGuideLineInfo = Record
    Justify:      Integer;           // -1=left, 0=center, 1=right
    LIndent:      Integer;           // @{lindent n} leading spaces
    Spans:        Array of TGuideSpan;
    SpanCount:    Integer;
    Proportional: Boolean;        // False in @{code} blocks, True in @{body}
    IsBASIC:      Boolean;        // True = syntax-highlight as BASIC
  End;

  // Link buttons

  TGuideLink = Record
    Caption:        aString;
    Target:         aString;
    RawLine:        Integer;
    RawCol:         Integer;
    PlaceholderLen: Integer;
    Button:         SP_Button;
  End;

  // Parsed node

  TGuideNode = Record
    Name, Title: aString;
    Lines:     TStringList;
    LineInfos: Array of TGuideLineInfo;
    Links:     Array of TGuideLink;
    LinkCount: Integer;
    Redirect:  aString;
  End;

  // Nav history entry: node index + scroll position for Issues 5 & 6

  TNavHistEntry = Record
    NodeIdx:  Integer;
    TopPixel: Integer;
  End;

  TSearchMatch = Record
    NodeIdx: Integer;
    LineIdx: Integer;
    Col:     Integer;
    Len:     Integer;
  End;

  // Viewer

  SP_AmigaGuide = Class(SP_Memo)

  Private

    fNodes:       Array of TGuideNode;
    fNodeCount:   Integer;
    fCurrentNode: Integer;
    fLinks:       Array of TGuideLink;
    fLinkCount:   Integer;
    fLineInfos:   Array of TGuideLineInfo;

    fNavHistory: Array of TNavHistEntry;
    fNavHistLen: Integer;
    fNavHistPos: Integer;

    fPendingNavNode: aString;
    fSearchEdit:     SP_Edit;
    fSearchBtn:      SP_Button;

    fHighlightNode:  Integer;
    fHighlightLine:  Integer;
    fHighlightCol:   Integer;
    fHighlightLen:   Integer;

    fHasResultsNode: Boolean;
    fSearchMatches:  Array of TSearchMatch;

    fNavBar:      SP_Container;
    fBackBtn:     SP_Button;
    fFwdBtn:      SP_Button;
    fContentsBtn: SP_Button;
    fIndexBtn:    SP_Button;
    fPageLabel:   SP_Label;
    fPrevNodeBtn: SP_Button;
    fNextNodeBtn: SP_Button;

    fOnNodeChanged: SP_NotifyEvent;

    Procedure ParseGuide(Const s: aString);
    Procedure FreeNodes;
    Function  HasPrevNode: Boolean;
    Function  HasNextNode: Boolean;
    Procedure StepNode(Delta: Integer);
    Procedure LoadNode(NodeIdx: Integer; PushHistory: Boolean);
    Procedure DestroyButtons;
    Procedure PendingNavTimer(p: Pointer);
    Function  PropTextWidth(Const s: aString): Integer;
    Procedure RepositionButtons;
    Procedure LinkBtnClick(Sender: SP_BaseComponent);
    Procedure NavBarSearchClick(Sender: SP_BaseComponent);
    Procedure NavBarSearchAccept(Sender: SP_BaseComponent; Text: aString);
    Procedure SearchResultClick(Sender: SP_BaseComponent);
    Procedure BuildSearchResults(Const Term: aString);
    Procedure RemoveResultsNode;
    Procedure NavBarBackClick(Sender: SP_BaseComponent);
    Procedure NavBarFwdClick(Sender: SP_BaseComponent);
    Procedure NavBarContentsClick(Sender: SP_BaseComponent);
    Procedure NavBarIndexClick(Sender: SP_BaseComponent);
    Procedure NavBarPrevNodeClick(Sender: SP_BaseComponent);
    Procedure NavBarNextNodeClick(Sender: SP_BaseComponent);
    Procedure NavBarPaint(Control: SP_BaseComponent);
    Procedure ResizeNavBar;
    Procedure UpdateNavBar;
    Function  ButtonW(Const Caption: aString; Proportional: Boolean = False): Integer;
    Function  ButtonH: Integer;

    Function  MapGuideColour(Const Name: aString): Byte;
    Function  InkCode(c: Byte): aString;
    Function  PaperCode(c: Byte): aString;
    Function  BoldCode(On: Boolean): aString;
    Function  ItalicCode(On: Boolean): aString;
    Procedure GetFormatAtCol(Const Info: TGuideLineInfo; Col: Integer;
                             Out Bold, Italic, Underline: Boolean;
                             Out HasInk: Boolean; Out Ink: Byte;
                             Out HasPaper: Boolean; Out Paper: Byte);
    Function  EmptyLineInfo: TGuideLineInfo;

  Protected

    Function  GetTopOffset: Integer; Override;
    Function  GetLineProportional(RawIdx: Integer): Boolean; Override;
    Function  FormatLineForDisplay(WrapIdx: Integer): aString; Override;
    Procedure DrawLineDecorations(WrapIdx, X, Y, H: Integer); Override;
    Procedure OnAfterRebuildWraps; Override;
    Function  GetLineContinuationIndent(RawIdx: Integer): Integer; Override;
    Function  WantCurrentLineHighlight: Boolean; Override;
    Function  TreatsLeadingDigitsAsLineNum(RawIdx: Integer): Boolean; Override;

  Public

    Constructor Create(Owner: SP_BaseComponent);
    Destructor  Destroy; Override;
    Procedure   Draw; Override;
    Procedure   PerformKeyDown(Var Handled: Boolean); Override;
    Function    NavBarH: Integer;

    Procedure LoadGuide(Const Filename: aString);
    Procedure LoadGuideFromString(Const Content: aString);
    Procedure GoToNode(Const NodeName: aString);
    Procedure GoBack;
    Procedure GoForward;
    Function  CanGoBack:    Boolean;
    Function  CanGoForward: Boolean;
    Function  CurrentNodeTitle: aString;
    Function  CurrentNodeName:  aString;
    Function  FindNode(Const Name: aString): Integer;
    Procedure RestorePosition(Const NodeName: aString; ScrollY: Integer);
    Procedure RefreshNavBar;
    Procedure HasSized; Override;

    Property OnNodeChanged: SP_NotifyEvent read fOnNodeChanged write fOnNodeChanged;
    Property TopPixel:      Integer        read fTopPixel      write fTopPixel;

  End;

implementation

Uses SP_Components, SP_SysVars, SP_Input, SP_Sound, SP_ScrollBarUnit, SP_BankManager;

// ---------------------------------------------------------------------------
// Construction / Destruction
// ---------------------------------------------------------------------------

Constructor SP_AmigaGuide.Create(Owner: SP_BaseComponent);
Begin
  Inherited;
  fTypeName    := 'spAmigaGuide';
  Editable     := False;
  fCanFocus    := True;
  fWantTab     := True;
  fColour      := SP_UIWindowBack; //7;
  fBackgroundClr := 7;
  fCurrentNode    := -1;
  fNodeCount      := 0;
  fLinkCount      := 0;
  fNavHistLen     := 0;
  fNavHistPos     := -1;
  SetLength(fNodes, 0); SetLength(fLinks, 0);
  SetLength(fLineInfos, 0); SetLength(fNavHistory, 0);

  fPaddingTop := 0;

  fNavBar := SP_Container.Create(Self);
  fNavBar.Border        := False;
  fNavBar.Transparent   := False;
  fNavBar.BackgroundClr := SP_UIBackground;
  fNavBar.OnPaintAfter  := NavBarPaint;

  fBackBtn := SP_Button.Create(fNavBar);
  fBackBtn.Caption := #254;
  fBackBtn.SetBounds(2, 2, 12, 12); fBackBtn.CentreCaption;
  fBackBtn.OnClick := NavBarBackClick;

  fFwdBtn := SP_Button.Create(fNavBar);
  fFwdBtn.Caption := #253;
  fFwdBtn.SetBounds(16, 2, 12, 12); fFwdBtn.CentreCaption;
  fFwdBtn.OnClick := NavBarFwdClick;

  fContentsBtn := SP_Button.Create(fNavBar);
  fContentsBtn.Caption := 'Contents';
  fContentsBtn.SetBounds(32, 2, 80, 12); fContentsBtn.CentreCaption;
  fContentsBtn.OnClick := NavBarContentsClick;

  fIndexBtn := SP_Button.Create(fNavBar);
  fIndexBtn.Caption := 'Index';
  fIndexBtn.SetBounds(116, 2, 56, 12); fIndexBtn.CentreCaption;
  fIndexBtn.OnClick := NavBarIndexClick;

  fPageLabel := SP_Label.Create(fNavBar);
  fPageLabel.TextJustify := 0;
  fPageLabel.Border      := False;
  fPageLabel.Caption     := '';

  fPrevNodeBtn := SP_Button.Create(fNavBar);
  fPrevNodeBtn.Caption := #254;
  fPrevNodeBtn.SetBounds(2, 2, 12, 12); fPrevNodeBtn.CentreCaption;
  fPrevNodeBtn.OnClick := NavBarPrevNodeClick;

  fNextNodeBtn := SP_Button.Create(fNavBar);
  fNextNodeBtn.Caption := #253;
  fNextNodeBtn.SetBounds(16, 2, 12, 12); fNextNodeBtn.CentreCaption;
  fNextNodeBtn.OnClick := NavBarNextNodeClick;

  fSearchEdit := SP_Edit.Create(fNavBar);
  fSearchEdit.GhostText := 'Search...';
  fSearchEdit.OnAccept  := NavBarSearchAccept;

  fSearchBtn := SP_Button.Create(fNavBar);
  fSearchBtn.Caption  := 'Find';
  fSearchBtn.OnClick  := NavBarSearchClick;

  fHighlightNode  := -1;
  fHighlightLine  := 0;
  fHighlightCol   := 0;
  fHighlightLen   := 0;
  fHasResultsNode := False;
  SetLength(fSearchMatches, 0);

End;

Destructor SP_AmigaGuide.Destroy;
Begin DestroyButtons; FreeNodes; Inherited; End;

// ---------------------------------------------------------------------------
// Nav bar
// ---------------------------------------------------------------------------

Function SP_AmigaGuide.NavBarH: Integer;
Begin
  Result := 35;
End;

// All content below the navbar accounts for its height via GetTopOffset.
Function SP_AmigaGuide.GetTopOffset: Integer;
Begin
  Result := Inherited GetTopOffset + NavBarH;
End;

Function SP_AmigaGuide.GetLineProportional(RawIdx: Integer): Boolean;
Begin
  If (RawIdx >= 0) And (RawIdx < Length(fLineInfos)) Then
    Result := fLineInfos[RawIdx].Proportional
  Else
    Result := Proportional;
End;

Procedure SP_AmigaGuide.NavBarPaint(Control: SP_BaseComponent);
Begin
  With Control Do Begin
    DrawLine(0, fHeight-3, fWidth-1, fHeight-3, SP_UIHalfLight);
    DrawLine(0, fHeight-2, fWidth-1, fHeight-2, SP_UIShadow);
    DrawLine(0, fHeight-1, fWidth-1, fHeight-1, SP_UIBorder);
  End;
End;

Procedure SP_AmigaGuide.ResizeNavBar;
Const
  BtnH = 12; BtnW1 = 12; BtnY = 2; BtnGap = 2;
Var
  x, btnW, labelW, rightX, row2Y: Integer;
Begin
  fNavBar.SetBounds(fPaddingLeft + Ord(fBorder),
                    fPaddingTop  + Ord(fBorder),
                    fWidth - fPaddingLeft - fPaddingRight - (Ord(fBorder) * 2),
                    NavBarH);
  fNavBar.BackgroundClr := SP_UIBackground;

  // --- Row 1: Back, Fwd, Contents, Index, Prev/Label/Next ---

  fBackBtn.SetBounds(BtnGap, BtnY, BtnW1, BtnH); fBackBtn.CentreCaption;
  fFwdBtn.SetBounds(BtnGap + BtnW1 + BtnGap, BtnY, BtnW1, BtnH); fFwdBtn.CentreCaption;
  x := BtnGap + (BtnW1 + BtnGap) * 2 + BtnGap;

  btnW := (Length(fContentsBtn.Caption) + 2) * Max(1, Round(iFW * iSX));
  fContentsBtn.SetBounds(x, BtnY, btnW, BtnH); fContentsBtn.CentreCaption;
  Inc(x, btnW + BtnGap);

  btnW := (Length(fIndexBtn.Caption) + 2) * Max(1, Round(iFW * iSX));
  fIndexBtn.SetBounds(x, BtnY, btnW, BtnH); fIndexBtn.CentreCaption;

  // Right group: prev [n/m] next
  labelW := (Length(IntToString(fNodeCount) + '/' + IntToString(fNodeCount)) + 2)
            * Max(1, Round(iFW * iSX));
  If labelW < BtnW1 * 2 Then labelW := BtnW1 * 2;

  rightX := fNavBar.Width - BtnGap - BtnW1 - BtnGap - labelW - BtnGap - BtnW1 - BtnGap;
  fPrevNodeBtn.SetBounds(rightX, BtnY, BtnW1, BtnH); fPrevNodeBtn.CentreCaption;
  Inc(rightX, BtnW1 + BtnGap);
  fPageLabel.Transparent := False;
  fPageLabel.SetBounds(rightX + 1, BtnY, labelW, BtnH);
  fPageLabel.Prepare;
  fPageLabel.Draw;
  Inc(rightX, labelW + BtnGap + 2);
  fNextNodeBtn.SetBounds(rightX, BtnY, BtnW1, BtnH); fNextNodeBtn.CentreCaption;

  // --- Row 2: Search edit + Find button ---

  row2Y := BtnY + BtnH + BtnGap + 2;
  btnW  := (Length(fSearchBtn.Caption) + 2) * Max(1, Round(iFW * iSX));
  fSearchEdit.SetBounds(BtnGap, row2Y,
                        fNavBar.Width - BtnGap * 3 - btnW, BtnH);
  fSearchBtn.SetBounds(fNavBar.Width - BtnGap - btnW, row2Y, btnW, BtnH);
  fSearchBtn.CentreCaption;

  fNavBar.Paint;
End;

Procedure SP_AmigaGuide.UpdateNavBar;
Begin
  fBackBtn.Enabled     := CanGoBack;
  fFwdBtn.Enabled      := CanGoForward;
  fContentsBtn.Enabled := fNodeCount > 0;
  fIndexBtn.Enabled    := FindNode('INDEX') >= 0;
  fPrevNodeBtn.Enabled := HasPrevNode;
  fNextNodeBtn.Enabled := HasNextNode;
  If fNodeCount > 0 Then
    fPageLabel.Caption := IntToString(fCurrentNode+1) + '/' + IntToString(fNodeCount)
  Else
    fPageLabel.Caption := '';
End;

Procedure SP_AmigaGuide.NavBarBackClick(Sender: SP_BaseComponent);
Begin
  If CanGoBack Then
    GoBack;
End;

Procedure SP_AmigaGuide.NavBarFwdClick(Sender: SP_BaseComponent);
Begin
  If CanGoForward Then
    GoForward;
End;

Procedure SP_AmigaGuide.NavBarContentsClick(Sender: SP_BaseComponent);
Begin
  GoToNode('MAIN');
End;

Procedure SP_AmigaGuide.NavBarIndexClick(Sender: SP_BaseComponent);
Begin
  GoToNode('INDEX');
End;

Procedure SP_AmigaGuide.NavBarPrevNodeClick(Sender: SP_BaseComponent);
Begin
  StepNode(-1);
End;

Procedure SP_AmigaGuide.NavBarNextNodeClick(Sender: SP_BaseComponent);
Begin
  StepNode(1);
End;

Procedure SP_AmigaGuide.HasSized;
Begin ResizeNavBar; Inherited; End;

Procedure SP_AmigaGuide.RefreshNavBar;
Begin
  ResizeNavBar;
End;

Procedure SP_AmigaGuide.RemoveResultsNode;
Begin
  If fHasResultsNode And (fNodeCount > 0) Then Begin
    fNodes[fNodeCount - 1].Lines.Free;
    fNodes[fNodeCount - 1].Lines := Nil;
    SetLength(fNodes[fNodeCount - 1].Links,     0);
    SetLength(fNodes[fNodeCount - 1].LineInfos, 0);
    Dec(fNodeCount);
    fHasResultsNode := False;
  End;
  SetLength(fSearchMatches, 0);
End;

Procedure SP_AmigaGuide.BuildSearchResults(Const Term: aString);
Type
  TNodeMatch = Record
    NodeIdx:  Integer;
    LineIdx:  Integer;
    Col:      Integer;
    Len:      Integer;
    Snippet:  aString;
  End;
Var
  available: Integer;
  ni, li, col, j: Integer;
  maxCap, titlePrefixLen, btnW, spcW: Integer;
  lowerTerm, lowerLine, lineText: aString;
  termLen, snipStart, snipEnd: Integer;
  snippet, caption: aString;
  ResultNode: TGuideNode;
  lk: TGuideLink;
  propInfo, info: TGuideLineInfo;
  match: TSearchMatch;
  // Per-occurrence collection
  AllMatches:   Array of TNodeMatch;
  AllMatchCount: Integer;
  nm: TNodeMatch;
  // Grouping
  groupStart, groupEnd, groupNi: Integer;
  matchCount: Integer;
Begin
  If Term = '' Then Exit;
  RemoveResultsNode;

  lowerTerm := Lower(Term);
  termLen   := Length(lowerTerm);

  // Initialise synthetic node
  ResultNode.Name      := 'SEARCH_RESULTS';
  ResultNode.Title     := 'Search: ' + Term;
  ResultNode.Lines     := TStringList.Create;
  ResultNode.LinkCount := 0;
  ResultNode.Redirect  := '';
  SetLength(ResultNode.Links,     0);
  SetLength(ResultNode.LineInfos, 0);

  info := EmptyLineInfo;
  propInfo := EmptyLineInfo;
  propInfo.Proportional := fProportional;

  // Header
  ResultNode.Lines.Add('Results for: ' + Term);
  SetLength(ResultNode.LineInfos, ResultNode.Lines.Count);
  ResultNode.LineInfos[ResultNode.Lines.Count - 1] := info;
  ResultNode.Lines.Add(' ');
  SetLength(ResultNode.LineInfos, ResultNode.Lines.Count);
  ResultNode.LineInfos[ResultNode.Lines.Count - 1] := info;

  // --- Pass 1: collect all occurrences in node order ---
  AllMatchCount := 0;
  SetLength(AllMatches, 0);
  SetLength(fSearchMatches, 0);

  For ni := 0 To fNodeCount - 1 Do Begin
    If fNodes[ni].Name = 'SEARCH_RESULTS' Then Continue;
    For li := 0 To fNodes[ni].Lines.Count - 1 Do Begin
      lineText  := fNodes[ni].Lines[li];
      lowerLine := Lower(lineText);
      col := SP_Util.Pos(lowerTerm, lowerLine);
      While col > 0 Do Begin
        snipStart := Max(1, col - 15);
        snipEnd   := Min(Length(lineText), col + termLen + 20);
        snippet   := SP_Trim(SP_Copy(lineText, snipStart, snipEnd - snipStart + 1));
        For j := 1 To Length(snippet) Do
          If snippet[j] = #1 Then snippet[j] := ' ';

        If snipStart > 1              Then snippet := '...' + snippet;
        If snipEnd < Length(lineText) Then snippet := snippet + '...';

        // Cap snippet width to fit the panel, accounting for node title prefix.
        // ButtonW measures the full caption; we shrink the snippet until it fits.
        maxCap := (fWidth - ExtraLeftMargin - 8) Div Max(1, Round(iFW * iSX));
        titlePrefixLen := Length(fNodes[ni].Title) + 2; // +2 for ': '
        If Length(snippet) + titlePrefixLen > maxCap Then Begin
          available := maxCap - titlePrefixLen - 3; // -3 for trailing '...'
          If available < 8 Then available := 8;
          snippet := Copy(snippet, 1, available) + '...';
        End;

        If AllMatchCount >= Length(AllMatches) Then
          SetLength(AllMatches, AllMatchCount + 32);
        nm.NodeIdx := ni;
        nm.LineIdx := li;
        nm.Col     := col;
        nm.Len     := termLen;
        nm.Snippet := snippet;
        AllMatches[AllMatchCount] := nm;
        Inc(AllMatchCount);

        col := SP_Util.Pos(lowerTerm, lowerLine, col + 1);
      End;
    End;
  End;

  // --- Pass 2: emit one button per node group, snippets as plain text ---
  If AllMatchCount = 0 Then Begin
    ResultNode.Lines.Add('No matches found.');
    SetLength(ResultNode.LineInfos, ResultNode.Lines.Count);
    ResultNode.LineInfos[ResultNode.Lines.Count - 1] := info;
  End Else Begin
    groupStart := 0;
    While groupStart < AllMatchCount Do Begin
      groupNi := AllMatches[groupStart].NodeIdx;

      // Find end of this node's group
      groupEnd := groupStart;
      While (groupEnd + 1 < AllMatchCount) And
            (AllMatches[groupEnd + 1].NodeIdx = groupNi) Do
        Inc(groupEnd);

      matchCount := groupEnd - groupStart + 1;
      If matchCount = 1 Then
        caption := fNodes[groupNi].Title + '  (1 match)'
      Else
        caption := fNodes[groupNi].Title + '  (' + IntToString(matchCount) + ' matches)';

      // Record the first match in this group for scroll+highlight on click
      match.NodeIdx := groupNi;
      match.LineIdx := AllMatches[groupStart].LineIdx;
      match.Col     := AllMatches[groupStart].Col;
      match.Len     := termLen;
      SetLength(fSearchMatches, Length(fSearchMatches) + 1);
      fSearchMatches[High(fSearchMatches)] := match;

      // Link button

      btnW := ButtonW(caption, False);
      spcW := Max(1, Round(iFW * iSX));

      lk.Caption        := caption;
      lk.Target         := fNodes[groupNi].Name;
      lk.RawLine        := ResultNode.Lines.Count;
      lk.RawCol         := 1;
      lk.PlaceholderLen := (btnW + spcW - 1) Div spcW;
      lk.Button         := Nil;

      ResultNode.Lines.Add(SP_StringOfChar(#1, lk.PlaceholderLen));
      SetLength(ResultNode.LineInfos, ResultNode.Lines.Count);
      ResultNode.LineInfos[ResultNode.Lines.Count - 1] := propInfo;

      If ResultNode.LinkCount >= Length(ResultNode.Links) Then
        SetLength(ResultNode.Links, ResultNode.LinkCount + 16);
      ResultNode.Links[ResultNode.LinkCount] := lk;
      Inc(ResultNode.LinkCount);

      // Snippet lines for each occurrence in this group
      For j := groupStart To groupEnd Do Begin
        ResultNode.Lines.Add('  ' + AllMatches[j].Snippet);
        SetLength(ResultNode.LineInfos, ResultNode.Lines.Count);
        ResultNode.LineInfos[ResultNode.Lines.Count - 1] := propInfo;
      End;

      // Spacer between groups
      ResultNode.Lines.Add(' ');
      SetLength(ResultNode.LineInfos, ResultNode.Lines.Count);
      ResultNode.LineInfos[ResultNode.Lines.Count - 1] := propInfo;

      groupStart := groupEnd + 1;
    End;
  End;

  // Add synthetic node
  If fNodeCount >= Length(fNodes) Then
    SetLength(fNodes, fNodeCount + 4);
  fNodes[fNodeCount] := ResultNode;
  Inc(fNodeCount);
  fHasResultsNode := True;

  GoToNode('SEARCH_RESULTS');
End;

Procedure SP_AmigaGuide.SearchResultClick(Sender: SP_BaseComponent);
Var idx: Integer;
Begin
  idx := Sender.Tag;
  If (idx >= 0) And (idx < Length(fSearchMatches)) Then Begin
    fHighlightNode  := fSearchMatches[idx].NodeIdx;
    fHighlightLine  := fSearchMatches[idx].LineIdx;
    fHighlightCol   := fSearchMatches[idx].Col;
    fHighlightLen   := fSearchMatches[idx].Len;
    fPendingNavNode := fNodes[fHighlightNode].Name;
    AddTimer(Self, 1, PendingNavTimer, False, True);
  End;
End;

Procedure SP_AmigaGuide.NavBarSearchClick(Sender: SP_BaseComponent);
Begin
  BuildSearchResults(fSearchEdit.Text);
End;

Procedure SP_AmigaGuide.NavBarSearchAccept(Sender: SP_BaseComponent; Text: aString);
Begin
  BuildSearchResults(Text);
End;

// ---------------------------------------------------------------------------
// Button sizing
// ---------------------------------------------------------------------------

Function SP_AmigaGuide.ButtonW(Const Caption: aString; Proportional: Boolean = False): Integer;
Begin
  If Proportional Then
    Result := PropTextWidth(Caption) + (2 * Max(1, Round(iFW*iSX)))
  Else
    Result := (Length(Caption)+2) * Max(1, Round(iFW*iSX));
End;

Function SP_AmigaGuide.ButtonH: Integer;
Begin
  Result := Max(1, Round(iFH*iSY)) + 4;
End;

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

Function SP_AmigaGuide.EmptyLineInfo: TGuideLineInfo;
Begin
  Result.Justify      := -1;
  Result.LIndent      := 0;
  Result.SpanCount    := 0;
  Result.Proportional := False;
  Result.IsBASIC      := False;

  SetLength(Result.Spans, 0);
End;

Function SP_AmigaGuide.MapGuideColour(Const Name: aString): Byte;
Var v: Integer;
Begin
  If      (Name='TEXT')      Or (Name='DETAIL') Or (Name='FILLTEXT') Then Result := SP_UIText
  Else If  Name='SHINE'      Then Result := 15
  Else If  Name='SHADOW'     Then Result := SP_UIShadow
  Else If  Name='FILL'       Then Result := 5
  Else If  Name='BACKGROUND' Then Result := SP_UIWindowBack//7
  Else If  Name='HALFLIGHT'  Then Result := SP_UIHalfLight
  Else Begin
    v := StringToInt(Name, -1);
    If (v >= 0) And (v <= 255) Then Result := Byte(v) Else Result := SP_UIText;
  End;
End;

Function SP_AmigaGuide.InkCode(c: Byte): aString;
Begin Result := aChar(#16)+aChar(c)+aChar(0)+aChar(0)+aChar(0); End;

Function SP_AmigaGuide.PaperCode(c: Byte): aString;
Begin Result := aChar(#17)+aChar(c)+aChar(0)+aChar(0)+aChar(0); End;

Function SP_AmigaGuide.BoldCode(On: Boolean): aString;
Begin
  If On Then Result := aChar(#27)+aChar(1)+aChar(0)+aChar(0)+aChar(0)
  Else       Result := aChar(#27)+aChar(0)+aChar(0)+aChar(0)+aChar(0);
End;

Function SP_AmigaGuide.ItalicCode(On: Boolean): aString;
Begin
  If On Then Result := aChar(#26)+aChar(1)+aChar(0)+aChar(0)+aChar(0)
  Else       Result := aChar(#26)+aChar(0)+aChar(0)+aChar(0)+aChar(0);
End;

Procedure SP_AmigaGuide.GetFormatAtCol(Const Info: TGuideLineInfo; Col: Integer;
                                        Out Bold, Italic, Underline: Boolean;
                                        Out HasInk: Boolean; Out Ink: Byte;
                                        Out HasPaper: Boolean; Out Paper: Byte);
Var i: Integer;
Begin
  Bold     := False; Italic    := False; Underline := False;
  HasInk   := False; Ink       := SP_UIText;
  HasPaper := False; Paper     := SP_UIWindowBack;//7;
  For i := 0 To Info.SpanCount-1 Do Begin
    If (Info.Spans[i].ColStart <= Col) And (Info.Spans[i].ColEnd >= Col) Then Begin
      If Info.Spans[i].Bold      Then Bold      := True;
      If Info.Spans[i].Italic    Then Italic    := True;
      If Info.Spans[i].Underline Then Underline := True;
      If Info.Spans[i].HasInk   Then Begin HasInk   := True; Ink   := Info.Spans[i].Ink;   End;
      If Info.Spans[i].HasPaper Then Begin HasPaper := True; Paper := Info.Spans[i].Paper; End;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// Guide parsing
// ---------------------------------------------------------------------------

Procedure SP_AmigaGuide.FreeNodes;
Var i: Integer;
Begin
  RemoveResultsNode;
  For i := 0 To fNodeCount-1 Do Begin
    FreeAndNil(fNodes[i].Lines);
    SetLength(fNodes[i].LineInfos, 0);
    SetLength(fNodes[i].Links,     0);
  End;
  SetLength(fNodes, 0);
  fNodeCount := 0;
End;

Function SP_AmigaGuide.FindNode(Const Name: aString): Integer;
Var i: Integer; UC: aString;
Begin
  Result := -1; UC := Upper(Name);
  For i := 0 To fNodeCount-1 Do
    If fNodes[i].Name = UC Then Begin Result := i; Exit; End;
End;

Procedure SP_AmigaGuide.RestorePosition(Const NodeName: aString; ScrollY: Integer);
Begin
  If NodeName <> '' Then
    GoToNode(NodeName);
  fTopPixel := ScrollY;
  SP_ScrollBar(fVScroll).Pos := ScrollY;
  Paint;
End;

Procedure SP_AmigaGuide.ParseGuide(Const s: aString);
Type
  TFmtState = Record
    Bold, Italic, Underline: Boolean;
    HasInk: Boolean; Ink: Byte;
    HasPaper: Boolean; Paper: Byte;
  End;
Var
  btnW, spcW:       Integer;
  RawLines:         TStringList;
  i, p, q, ni:      Integer;
  Line, Tag, Verb,
  NodeName,
  NodeTitle,
  Target, OutLine:  aString;
  InNode:           Boolean;
  curFmt, prevFmt:  TFmtState;
  spanStart,
  colIdx:           Integer;
  lineInfo:         TGuideLineInfo;
  sp:               TGuideSpan;
  lk:               TGuideLink;
  curJustify:       Integer;
  codeMode:         Boolean;   // @{code}=True (line-by-line), @{body}=False (flowing)
  basicHighlight:   Boolean;   // @{basic}/@{endbasic} within @{code} blocks

  Procedure DefaultFmt(Out f: TFmtState);
  Begin f.Bold:=False; f.Italic:=False; f.Underline:=False;
        f.HasInk:=False; f.Ink:=SP_UIText; f.HasPaper:=False; f.Paper:=SP_UIWindowBack{7}; End;

  Function FmtDiff(Const a, b: TFmtState): Boolean;
  Begin
    Result := (a.Bold<>b.Bold) Or (a.Italic<>b.Italic) Or (a.Underline<>b.Underline) Or
              (a.HasInk<>b.HasInk) Or (a.HasInk And (a.Ink<>b.Ink)) Or
              (a.HasPaper<>b.HasPaper) Or (a.HasPaper And (a.Paper<>b.Paper));
  End;

  Procedure CloseSpan;
  Begin
    If (spanStart < colIdx) And
       (prevFmt.Bold Or prevFmt.Italic Or prevFmt.Underline Or
        prevFmt.HasInk Or prevFmt.HasPaper) Then Begin
      sp.ColStart  := spanStart; sp.ColEnd    := colIdx-1;
      sp.Bold      := prevFmt.Bold;    sp.Italic    := prevFmt.Italic;
      sp.Underline := prevFmt.Underline;
      sp.HasInk    := prevFmt.HasInk;  sp.Ink   := prevFmt.Ink;
      sp.HasPaper  := prevFmt.HasPaper; sp.Paper := prevFmt.Paper;
      If lineInfo.SpanCount >= Length(lineInfo.Spans) Then
        SetLength(lineInfo.Spans, lineInfo.SpanCount+8);
      lineInfo.Spans[lineInfo.SpanCount] := sp;
      Inc(lineInfo.SpanCount);
    End;
    prevFmt   := curFmt;
    spanStart := colIdx;
  End;

  Procedure CommitLine;
  Begin
    CloseSpan;
    lineInfo.Justify := curJustify;
    lineInfo.Proportional := Not codeMode;
    lineInfo.IsBASIC      := codeMode And basicHighlight;
    With fNodes[ni] Do Begin
      If OutLine = '' Then Lines.Add(' ') Else Lines.Add(OutLine);
      If Lines.Count > Length(LineInfos) Then SetLength(LineInfos, Lines.Count+4);
      LineInfos[Lines.Count-1] := lineInfo;
    End;
    OutLine := ''; colIdx := 1; spanStart := 1;
    // (Note: DefaultFmt removed here so formatting spans across lines)
    lineInfo := EmptyLineInfo;
    lineInfo.Justify := curJustify;
  End;

  Procedure AddBlankLine;
  Var blank: TGuideLineInfo;
  Begin
    blank := EmptyLineInfo;
    With fNodes[ni] Do Begin
      Lines.Add(' ');  // Force a space so SP_Memo renders the gap
      If Lines.Count > Length(LineInfos) Then SetLength(LineInfos, Lines.Count+4);
      LineInfos[Lines.Count-1] := blank;
    End;
  End;

Begin
  FreeNodes;
  RawLines := TStringList.Create;
  Try
    p := 1;
    While p <= Length(s) Do Begin
      q := p;
      // Advance q until we hit ANY line break character
      While (q <= Length(s)) And (s[q] <> #13) And (s[q] <> #10) Do Inc(q);

      // Add the extracted line (will safely add '' for consecutive breaks)
      RawLines.Add(Copy(s, p, q - p));

      If q <= Length(s) Then Begin
        // Check for Windows (CRLF) or rare Acorn (LFCR) pairs and jump them safely
        If (q < Length(s)) And
           (((s[q] = #13) And (s[q+1] = #10)) Or
            ((s[q] = #10) And (s[q+1] = #13))) Then
          p := q + 2
        Else
          p := q + 1; // Single Amiga LF or Mac CR
      End Else
        Break;
    End;

    InNode := False; ni := -1;
    curJustify := -1;
    codeMode := False;
    basicHighlight := False;
    i := 0;
    While i < RawLines.Count Do Begin
      Line := RawLines[i]; Inc(i);
      If Not codeMode Then Line := SP_TrimRight(Line);

      If (Length(Line) > 0) And (Line[1] = '@') Then Begin

        If SP_CompareText(Copy(Line,1,6),'@NODE ') = 0 Then Begin
          p := 7;
          While (p<=Length(Line)) And (Line[p]=' ') Do Inc(p);
          q := p;
          While (q<=Length(Line)) And (Line[q]>' ') Do Inc(q);
          NodeName := Upper(Copy(Line,p,q-p));
          p := q;
          While (p<=Length(Line)) And (Line[p]=' ') Do Inc(p);
          If (p<=Length(Line)) And (Line[p]='"') Then Begin
            Inc(p); q := p;
            While (q<=Length(Line)) And (Line[q]<>'"') Do Inc(q);
            NodeTitle := Copy(Line,p,q-p);
          End Else NodeTitle := NodeName;
          If fNodeCount >= Length(fNodes) Then SetLength(fNodes, fNodeCount+16);
          fNodes[fNodeCount].Name      := NodeName;
          fNodes[fNodeCount].Title     := NodeTitle;
          fNodes[fNodeCount].Lines     := TStringList.Create;
          fNodes[fNodeCount].LinkCount := 0;
          fNodes[fNodeCount].Redirect  := '';
          SetLength(fNodes[fNodeCount].Links,     0);
          SetLength(fNodes[fNodeCount].LineInfos, 0);
          ni := fNodeCount; Inc(fNodeCount);
          InNode := True;
          curJustify := -1;
          codeMode := False;   // default is body (flowing) mode
          DefaultFmt(curFmt); DefaultFmt(prevFmt);
          lineInfo := EmptyLineInfo;
          OutLine := ''; colIdx := 1; spanStart := 1;
          Continue;
        End;

        If SP_CompareText(Copy(Line,1,8),'@ENDNODE') = 0 Then Begin
          If OutLine <> '' Then CommitLine;
          InNode := False; ni := -1; Continue;
        End;

        If Not InNode Then Continue;

        If SP_CompareText(Copy(Line,1,6),'@{PAR}') = 0 Then Begin If OutLine <> '' Then CommitLine; AddBlankLine; Continue; End;
        If SP_CompareText(Copy(Line,1,7),'@{LINE}') = 0 Then Begin CommitLine; Continue; End;
        If SP_CompareText(Copy(Line,1,7),'@{CODE}') = 0 Then Begin If OutLine <> '' Then CommitLine; codeMode := True;  Continue; End;
        If SP_CompareText(Copy(Line,1,7),'@{BODY}') = 0 Then Begin If OutLine <> '' Then CommitLine; codeMode := False; Continue; End;
        If SP_CompareText(Copy(Line,1,8),'@{BASIC}') = 0 Then Begin If OutLine <> '' Then CommitLine; basicHighlight := True;  Continue; End;
        If SP_CompareText(Copy(Line,1,11),'@{ENDBASIC}') = 0 Then Begin If OutLine <> '' Then CommitLine; basicHighlight := False; Continue; End;
        If SP_CompareText(Copy(Line,1,9),'@REDIRECT') = 0 Then Begin
          p := 10;
          While (p <= Length(Line)) And (Line[p] = ' ') Do Inc(p);
          fNodes[ni].Redirect := Upper(SP_Trim(Copy(Line, p, MaxInt)));
          Continue;
        End;

        p := 2;
        While (p<=Length(Line)) And (Line[p]>' ') And (Line[p]<>'{') Do Inc(p);
        If p > Length(Line) Then Continue;
      End;

      If Not InNode Then Continue;

      p := 1;
      While p <= Length(Line) Do Begin

        If Line[p] = #9 Then Begin
          OutLine := OutLine + '   '; Inc(colIdx,3); Inc(p); Continue;
        End;

        If (Line[p]='@') And (p < Length(Line)) And (Line[p+1]='{') Then Begin
          q := p+2;

          If (q <= Length(Line)) And (Line[q]='"') Then Begin
            Inc(q); Tag := '';
            While (q<=Length(Line)) And (Line[q]<>'"') Do Begin Tag:=Tag+Line[q]; Inc(q); End;
            If q<=Length(Line) Then Inc(q);
            While (q<=Length(Line)) And (Line[q]=' ') Do Inc(q);
            Verb := '';
            While (q<=Length(Line)) And (Line[q]>' ') And (Line[q]<>'}') Do Begin Verb:=Verb+UpCase(Line[q]); Inc(q); End;
            While (q<=Length(Line)) And (Line[q]=' ') Do Inc(q);
            Target := '';
            While (q<=Length(Line)) And (Line[q]<>'}') Do Begin Target:=Target+Line[q]; Inc(q); End;
            Target := SP_Trim(Target);
            If (Length(Target)>=2) And (Target[1]='"') Then Target := Copy(Target,2,Length(Target)-2);
            If q<=Length(Line) Then Inc(q);

            If Verb = 'LINK' Then Begin
              lk.Caption        := Tag;
              lk.Target         := Upper(Target);
              lk.RawLine        := fNodes[ni].Lines.Count;
              lk.RawCol         := colIdx;
              If codeMode Then Begin
                btnW := ButtonW(Tag, False);
                spcW := Max(1, Round(iFW*iSX));
              End Else Begin
                btnW := ButtonW(Tag, True);
                // Guaranteed absolute space width, immune to trailing trims
                spcW := PropTextWidth('A A') - PropTextWidth('AA');
                If spcW <= 0 Then spcW := PropTextWidth('A'); // Fallback
                If spcW <= 0 Then spcW := 1;              // Failsafe
              End;
              lk.PlaceholderLen := (btnW + spcW - 1) Div spcW;
              lk.Button         := Nil;
              // Use #1 (non-breaking) so WrapOneLine never splits inside the button.
              OutLine := OutLine + SP_StringOfChar(#1, lk.PlaceholderLen);
              Inc(colIdx, lk.PlaceholderLen);
              With fNodes[ni] Do Begin
                If LinkCount >= Length(Links) Then SetLength(Links, LinkCount+8);
                Links[LinkCount] := lk; Inc(LinkCount);
              End;
            End;
            p := q;

          End Else Begin
            Tag := '';
            While (q<=Length(Line)) And (Line[q]<>'}') Do Begin Tag:=Tag+UpCase(Line[q]); Inc(q); End;
            If q<=Length(Line) Then Inc(q);

            If FmtDiff(curFmt, prevFmt) Then CloseSpan;

            If      Tag='B'       Then curFmt.Bold      := True
            Else If Tag='UB'      Then curFmt.Bold      := False
            Else If Tag='I'       Then curFmt.Italic    := True
            Else If Tag='UI'      Then curFmt.Italic    := False
            Else If Tag='U'       Then curFmt.Underline := True
            Else If Tag='UU'      Then curFmt.Underline := False
            Else If Tag='JLEFT'   Then Begin curJustify := -1; lineInfo.Justify := -1; End
            Else If Tag='JCENTER' Then Begin curJustify :=  0; lineInfo.Justify :=  0; End
            Else If Tag='JRIGHT'  Then Begin curJustify :=  1; lineInfo.Justify :=  1; End
            Else If Tag='LINE' Then CommitLine
            Else If Tag='PAR'  Then Begin If OutLine <> '' Then CommitLine; AddBlankLine; End
            Else If Tag='CODE' Then Begin If OutLine <> '' Then CommitLine; codeMode := True;  End
            Else If Tag='BODY' Then Begin If OutLine <> '' Then CommitLine; codeMode := False; End
            Else If Tag='BASIC'    Then Begin If OutLine <> '' Then CommitLine; basicHighlight := True;  End
            Else If Tag='ENDBASIC' Then Begin If OutLine <> '' Then CommitLine; basicHighlight := False; End
            Else If Copy(Tag,1,7)='LINDENT' Then Begin
              Verb := SP_Trim(Copy(Tag,8));
              lineInfo.LIndent := Max(0, StringToInt(Verb, 0));
              If lineInfo.LIndent > 0 Then Begin
                OutLine    := SP_StringOfChar(' ', lineInfo.LIndent) + OutLine;
                Inc(colIdx,    lineInfo.LIndent);
                Inc(spanStart, lineInfo.LIndent);
              End;
            End
            Else If Copy(Tag,1,2)='FG' Then Begin
              Verb := SP_Trim(Copy(Tag,3));
              curFmt.HasInk := True; curFmt.Ink := MapGuideColour(Verb);
            End
            Else If Copy(Tag,1,2)='BG' Then Begin
              Verb := SP_Trim(Copy(Tag,3));
              curFmt.HasPaper := True; curFmt.Paper := MapGuideColour(Verb);
            End;

            If FmtDiff(curFmt, prevFmt) Then CloseSpan;
            p := q;
          End;

        End Else Begin
          OutLine := OutLine + Line[p]; Inc(colIdx); Inc(p);
        End;
      End;

      // In code mode every source line is a display line.
      // In body mode, consecutive lines flow together; a blank source line
      // (or @{par}/@{line} above) creates a paragraph break.
      If codeMode Then Begin
        CommitLine;
      End Else Begin
        If SP_TrimRight(Line) = '' Then Begin
          If OutLine <> '' Then CommitLine;
          AddBlankLine;
        End Else Begin
          If OutLine <> '' Then Begin OutLine := OutLine + ' '; Inc(colIdx); End;
        End;
      End;

    End;

    // Commit any pending content when the loop ends.
    If InNode And (ni >= 0) Then CommitLine;
  Finally
    RawLines.Free;
  End;
End;

// ---------------------------------------------------------------------------
// Node loading
// ---------------------------------------------------------------------------

Procedure SP_AmigaGuide.DestroyButtons;
Var i: Integer;
Begin
  For i := 0 To fLinkCount-1 Do
    If Assigned(fLinks[i].Button) Then Begin fLinks[i].Button.Free; fLinks[i].Button := Nil; End;
  SetLength(fLinks, 0); fLinkCount := 0;
End;

Function SP_AmigaGuide.HasPrevNode: Boolean;
Var idx: Integer;
Begin
  idx := fCurrentNode - 1;
  While idx >= 0 Do Begin
    If fNodes[idx].Redirect = '' Then Begin Result := True; Exit; End;
    Dec(idx);
  End;
  Result := False;
End;

Function SP_AmigaGuide.HasNextNode: Boolean;
Var idx: Integer;
Begin
  idx := fCurrentNode + 1;
  While idx < fNodeCount Do Begin
    If fNodes[idx].Redirect = '' Then Begin Result := True; Exit; End;
    Inc(idx);
  End;
  Result := False;
End;

Procedure SP_AmigaGuide.StepNode(Delta: Integer);
Var idx: Integer;
Begin
  idx := fCurrentNode + Delta;
  While (idx >= 0) And (idx < fNodeCount) Do Begin
    If fNodes[idx].Redirect = '' Then Begin
      LoadNode(idx, True);
      Exit;
    End;
    Inc(idx, Delta);
  End;
End;

Procedure SP_AmigaGuide.LoadNode(NodeIdx: Integer; PushHistory: Boolean);
Var
  i:     Integer;
  Btn:   SP_Button;
  btnH:  Integer;
Begin
  If (NodeIdx < 0) Or (NodeIdx >= fNodeCount) Then Exit;

  // Follow @REDIRECT immediately - do not push the alias node into history
  If fNodes[NodeIdx].Redirect <> '' Then Begin
    i := FindNode(fNodes[NodeIdx].Redirect);
    If i >= 0 Then Begin
      LoadNode(i, PushHistory);
      Exit;
    End;
  End;

  If PushHistory Then Begin
    If fNavHistPos >= 0 Then
      fNavHistory[fNavHistPos].TopPixel := fTopPixel;
    fNavHistLen := fNavHistPos + 1;
    If fNavHistLen >= Length(fNavHistory) Then SetLength(fNavHistory, fNavHistLen + 16);
    fNavHistory[fNavHistLen].NodeIdx  := NodeIdx;
    fNavHistory[fNavHistLen].TopPixel := 0;
    Inc(fNavHistLen);
    fNavHistPos := fNavHistLen - 1;
  End;

  fCurrentNode := NodeIdx;
  DestroyButtons;
  fLines.Clear;

  For i := 0 To fNodes[NodeIdx].Lines.Count-1 Do
    fLines.Add(fNodes[NodeIdx].Lines[i]);

  SetLength(fLineInfos, fLines.Count);
  For i := 0 To fLines.Count-1 Do fLineInfos[i] := fNodes[NodeIdx].LineInfos[i];

  fLinkCount := fNodes[NodeIdx].LinkCount;
  SetLength(fLinks, fLinkCount);
  For i := 0 To fLinkCount-1 Do fLinks[i] := fNodes[NodeIdx].Links[i];

  btnH := ButtonH;
  For i := 0 To fLinkCount-1 Do Begin
    Btn  := SP_Button.Create(Self);
    Btn.Caption := fLinks[i].Caption;
    Btn.SetBounds(0, 0, 0, btnH);  // width set by RepositionButtons once wraps are known
    Btn.CentreCaption;
    Btn.Tag     := i;
    If fHasResultsNode And (NodeIdx = fNodeCount - 1) Then
      Btn.OnClick := SearchResultClick
    Else
      Btn.OnClick := LinkBtnClick;
    Btn.Visible := False;
    fLinks[i].Button := Btn;
  End;

  fCursorLine := 0; fCursorCol := 1; fSelLine := 0; fSelCol := 1;
  // FIX (Issue 6): zero fTopPixel before RebuildWrappedLines so that
  // UpdateScrollbars (called inside it) starts from the top, then explicitly
  // reset the scrollbar thumb position after the rebuild.
  fTopPixel  := 0;
  fWrapDirty := True;
  If Assigned(fOnNodeChanged) Then fOnNodeChanged(Self);
  UpdateNavBar;
  RebuildWrappedLines;
  Paint;
End;

// ---------------------------------------------------------------------------
// Button positioning
// ---------------------------------------------------------------------------

Function SP_AmigaGuide.PropTextWidth(Const s: aString): Integer;
Begin
  Result := Round(SP_GetPropTextWidth(FONTBANKID, s, '') * iSX);
End;

Procedure SP_AmigaGuide.RepositionButtons;
Var
  i, j, wl, NextWl:Integer;
  bOffL, bOffT:    Integer;
  cfH, cfW, lm:    Integer;
  bx, by, btnW,
  btnH, firstWL,
  lastWL, vis:     Integer;
  visTop, visBot:  Integer;
  textSlice:       aString;
Begin
  If (fLinkCount=0) Or fWrapDirty Then Exit;
  bOffL := GetLeftOffset; bOffT := GetTopOffset;
  cfH   := Max(1, Round(iFH*iSY)); cfW := Max(1, Round(iFW*iSX));
  lm    := ExtraLeftMargin; vis := VisibleLines;
  firstWL := fTopPixel Div cfH;
  lastWL  := Min(fWrappedCount-1, firstWL+vis+1);
  visTop  := bOffT; visBot := bOffT+ClientH;
  btnH    := ButtonH;

  For i := 0 To fLinkCount-1 Do Begin
    If Not Assigned(fLinks[i].Button) Then Continue;
    If fLinks[i].RawLine >= fLines.Count Then Begin fLinks[i].Button.Visible := False; Continue; End;

    wl := WrappedLineOfRaw(fLinks[i].RawLine, fLinks[i].RawCol);
    If (wl < firstWL) Or (wl > lastWL) Then Begin fLinks[i].Button.Visible := False; Continue; End;

    // Compute bx: pixel offset from left edge to button start.
    // In proportional mode, measure the text slice preceding the button.
    // Subtract 2 to compensate for the trailing bearing TextWidth includes
    // on the last character of the slice.
    If fWrapped[wl].Proportional Then Begin
      textSlice := Copy(fWrapped[wl].Text, 1, fLinks[i].RawCol - fWrapped[wl].RawOffset);
      For j := 1 To Length(textSlice) Do If textSlice[j] = #1 Then textSlice[j] := ' ';
      bx := bOffL + lm - fLeftPixel + PropTextWidth(textSlice) -2;
    End Else
      bx := bOffL + lm - fLeftPixel + fWrapped[wl].VisualIndent +
            (fLinks[i].RawCol - fWrapped[wl].RawOffset) * cfW;

    by   := bOffT + (wl - firstWL) * cfH - (fTopPixel Mod cfH) - 2;
    btnW := ButtonW(fLinks[i].Caption, fWrapped[wl].Proportional);

    If (bx + btnW > bOffL + lm + ClientW) Then Begin
      nextWl := wl + 1;

      // Skip over any injected MaxInt padding lines to find the real text continuation
      While (nextWl < fWrappedCount) And (fWrapped[nextWl].RawLine = MaxInt) Do
        Inc(nextWl);

      If (nextWl < fWrappedCount) And (fWrapped[nextWl].RawLine = fWrapped[wl].RawLine) Then Begin
        wl := nextWl;
        bx   := bOffL + lm - fLeftPixel + fWrapped[wl].VisualIndent;
        by   := bOffT + (wl - firstWL) * cfH - (fTopPixel Mod cfH) - 2;
        btnW := ButtonW(fLinks[i].Caption, fWrapped[wl].Proportional);
      End;
    End;

    If (by + btnH <= visTop) Or (by >= visBot) Or (bx + btnW <= bOffL + lm) Then Begin
      fLinks[i].Button.Visible := False; Continue;
    End;

    fLinks[i].Button.SetBounds(bx, by, btnW, btnH);
    fLinks[i].Button.Proportional := fWrapped[wl].Proportional;
    fLinks[i].Button.CentreCaption;
    fLinks[i].Button.Visible := True;
  End;
End;

Procedure SP_AmigaGuide.PendingNavTimer(p: Pointer);
Begin
  Paint;
End;

Procedure SP_AmigaGuide.LinkBtnClick(Sender: SP_BaseComponent);
Var idx: Integer;
Begin
  idx := Sender.Tag;
  If (idx >= 0) And (idx < fLinkCount) Then Begin
    fPendingNavNode := fLinks[idx].Target;
    AddTimer(Self, 1, PendingNavTimer, False, True);
  End;
End;

// ---------------------------------------------------------------------------
// SP_Memo virtual overrides
// ---------------------------------------------------------------------------

Function SP_AmigaGuide.FormatLineForDisplay(WrapIdx: Integer): aString;
Var
  RawLine, SegOfs, SegLen, col: Integer;
  plain:   aString;
  info:    TGuideLineInfo;
  pB, pI, pU, pHI, pHP: Boolean;
  pInk, pPap: Byte;
  cB, cI, cU, cHI, cHP: Boolean;
  cInk, cPap: Byte;
  cfW, availCols, lead: Integer;
  plainBuf: aString;
  hlStart, hlEnd: Integer;
  inHL:           Boolean;

  // Extract the trailing colour/style state from a highlighted string so it
  // can be passed as PrevSyntax to the next line's SP_SyntaxHighlight call.
  Function ExtractEndSyntax(Const s: aString): aString;
  Var i, Ink, Paper, Bold, Italic: Integer;
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
    Result := '';
    If Ink    >= 0 Then Result := Result + #16 + LongWordToString(Ink);
    If Paper  >= 0 Then Result := Result + #17 + LongWordToString(Paper);
    If Italic >= 0 Then Result := Result + #26 + LongWordToString(Italic);
    If Bold   >= 0 Then Result := Result + #27 + LongWordToString(Bold);
  End;

  Procedure FlushBuf;
  Begin
    If plainBuf <> '' Then Begin
      Result   := Result + InsertLiterals(plainBuf);
      plainBuf := '';
    End;
  End;

  Procedure EmitCtrl(Const code: aString);
  Begin FlushBuf; Result := Result + code; End;

Begin
  RawLine := fWrapped[WrapIdx].RawLine;

  SegOfs  := fWrapped[WrapIdx].RawOffset;
  plain   := fWrapped[WrapIdx].Text;
  // Replace non-breaking placeholder chars with spaces for display.
  For col := 1 To Length(plain) Do
    If plain[col] = #1 Then plain[col] := ' ';
  SegLen  := Length(plain);

  If SegLen = 0 Then Begin Result := ''; Exit; End;

  If RawLine < Length(fLineInfos) Then info := fLineInfos[RawLine]
  Else info := EmptyLineInfo;

  // BASIC syntax highlighting - pass StartSyntax for multi-line state
  // (e.g. unclosed strings or REM continuation across wrapped segments).
  If info.IsBASIC Then Begin
    Result := SP_SyntaxHighlight(plain, fWrapped[WrapIdx].StartSyntax, False, False);
    // Store end-state back into the next segment so it carries forward.
    If WrapIdx + 1 < fWrappedCount Then
      If fWrapped[WrapIdx + 1].RawLine = RawLine Then
        fWrapped[WrapIdx + 1].StartSyntax := ExtractEndSyntax(Result);
    Exit;
  End;

  GetFormatAtCol(info, SegOfs-1, pB,pI,pU, pHI,pInk, pHP,pPap);

  Result   := '';
  plainBuf := '';

  If pB  Then EmitCtrl(BoldCode(True));
  If pI  Then EmitCtrl(ItalicCode(True));
  If pHI Then EmitCtrl(InkCode(pInk));
  If pHP Then EmitCtrl(PaperCode(pPap));

  // Compute highlight overlap for this segment
  hlStart := 0; hlEnd := 0;
  If (fHighlightNode >= 0) And
     (fCurrentNode = fHighlightNode) And
     (RawLine = fHighlightLine) Then Begin
    hlStart := fHighlightCol;
    hlEnd   := fHighlightCol + fHighlightLen - 1;
  End;

  For col := SegOfs To SegOfs+SegLen-1 Do Begin
    GetFormatAtCol(info, col, cB,cI,cU, cHI,cInk, cHP,cPap);

    // Override ink/paper for highlight range
    inHL := (hlStart > 0) And (col >= hlStart) And (col <= hlEnd);
    If inHL Then Begin
      cHI  := True; cInk  := 0;   // black ink
      cHP  := True; cPap  := 6;   // yellow paper
    End;

    If cB <> pB Then Begin EmitCtrl(BoldCode(cB));   pB := cB; End;
    If cI <> pI Then Begin EmitCtrl(ItalicCode(cI)); pI := cI; End;

    If cHI Then Begin
      If (Not pHI) Or (cInk <> pInk) Then Begin
        EmitCtrl(InkCode(cInk)); pHI := True; pInk := cInk;
      End;
    End Else If pHI Then Begin
      EmitCtrl(InkCode(SP_UIText)); pHI := False;
    End;

    If cHP Then Begin
      If (Not pHP) Or (cPap <> pPap) Then Begin
        EmitCtrl(PaperCode(cPap)); pHP := True; pPap := cPap;
      End;
    End Else If pHP Then Begin
      EmitCtrl(PaperCode(SP_UIWindowBack{7})); pHP := False;
    End;

    plainBuf := plainBuf + plain[col-SegOfs+1];
  End;

  FlushBuf;

  If pB  Then EmitCtrl(BoldCode(False));
  If pI  Then EmitCtrl(ItalicCode(False));
  If pHI Then EmitCtrl(InkCode(SP_UIText));
  If pHP Then EmitCtrl(PaperCode(SP_UIWindowBack{7}));

  If (SegOfs = 1) And (info.Justify <> -1) Then Begin
    cfW       := Max(1, Round(iFW*iSX));
    availCols := Max(1, ClientW Div cfW);
    If info.Justify = 0 Then lead := Max(0, (availCols-SegLen) Div 2)
    Else                     lead := Max(0,  availCols-SegLen);
    If lead > 0 Then Result := InsertLiterals(SP_StringOfChar(aChar(' '), lead)) + Result;
  End;
End;

Procedure SP_AmigaGuide.DrawLineDecorations(WrapIdx, X, Y, H: Integer);
Var
  RawLine, SegOfs, SegEnd, si, cs, ce: Integer;
  cfW, x1, x2: Integer;
  info: TGuideLineInfo;
Begin
  RawLine := fWrapped[WrapIdx].RawLine;
  If RawLine >= Length(fLineInfos) Then Exit;
  info := fLineInfos[RawLine];
  If info.SpanCount = 0 Then Exit;
  SegOfs := fWrapped[WrapIdx].RawOffset;
  SegEnd := SegOfs + Length(fWrapped[WrapIdx].Text) - 1;
  cfW    := Max(1, Round(iFW*iSX));
  For si := 0 To info.SpanCount-1 Do Begin
    If Not info.Spans[si].Underline Then Continue;
    cs := info.Spans[si].ColStart; ce := info.Spans[si].ColEnd;
    If (cs > SegEnd) Or (ce < SegOfs) Then Continue;
    cs := Max(cs, SegOfs); ce := Min(ce, SegEnd);
    x1 := X + (cs-SegOfs)*cfW;
    x2 := X + (ce-SegOfs+1)*cfW - 1;
    DrawLine(x1, Y+H, x2, Y+H, fFontClr);
  End;
End;

Function SP_AmigaGuide.GetLineContinuationIndent(RawIdx: Integer): Integer;
Begin
  If (RawIdx >= 0) And (RawIdx < Length(fLineInfos)) Then
    Result := fLineInfos[RawIdx].LIndent
  Else
    Result := 0;
End;

//Procedure SP_AmigaGuide.OnAfterRebuildWraps; Begin RepositionButtons; End;

Procedure SP_AmigaGuide.OnAfterRebuildWraps;
Var
  i, j, k, wl: Integer;
  btnLines: Array of Integer;
  numBtnLines: Integer;
  AlreadyAdded: Boolean;
Begin
  If fLinkCount > 0 Then Begin
    numBtnLines := 0;
    SetLength(btnLines, fLinkCount);

    // 1. Identify which wrapped lines contain buttons
    For i := 0 To fLinkCount - 1 Do Begin
      If fLinks[i].RawLine < fLines.Count Then Begin
        wl := WrappedLineOfRaw(fLinks[i].RawLine, fLinks[i].RawCol);
        If wl >= 0 Then Begin
          AlreadyAdded := False;
          For j := 0 To numBtnLines - 1 Do
            If btnLines[j] = wl Then Begin AlreadyAdded := True; Break; End;
          If Not AlreadyAdded Then Begin
            btnLines[numBtnLines] := wl;
            Inc(numBtnLines);
          End;
        End;
      End;
    End;

    // 2. Sort lines DESCENDING so we can inject lines without shifting upcoming indices
    If numBtnLines > 1 Then Begin
      For i := 0 To numBtnLines - 2 Do
        For j := i + 1 To numBtnLines - 1 Do
          If btnLines[i] < btnLines[j] Then Begin
            k := btnLines[i]; btnLines[i] := btnLines[j]; btnLines[j] := k;
          End;
    End;

    // 3. Inject visual padding lines above and below
    For i := 0 To numBtnLines - 1 Do Begin
      wl := btnLines[i];

      If fWrappedCount + 2 >= Length(fWrapped) Then
        SetLength(fWrapped, fWrappedCount + 16);

      // Inject AFTER the button line
      // (Only inject if the line below isn't already a gap from another button)
      If (wl = fWrappedCount - 1) Or (fWrapped[wl+1].RawLine <> MaxInt) Then Begin
        For j := fWrappedCount DownTo wl + 2 Do
          fWrapped[j] := fWrapped[j - 1];
        fWrapped[wl + 1].RawLine := MaxInt;   // MaxInt protects it from WrappedLineOfRaw
        fWrapped[wl + 1].RawOffset := 0;
        fWrapped[wl + 1].Text := '';
        fWrapped[wl + 1].VisualIndent := 0;
        Inc(fWrappedCount);
      End;

      // Inject BEFORE the button line
      If (wl = 0) Or (fWrapped[wl-1].RawLine <> MaxInt) Then Begin
        For j := fWrappedCount DownTo wl + 1 Do
          fWrapped[j] := fWrapped[j - 1];
        fWrapped[wl].RawLine := MaxInt;
        fWrapped[wl].RawOffset := 0;
        fWrapped[wl].Text := '';
        fWrapped[wl].VisualIndent := 0;
        Inc(fWrappedCount);
      End;
    End;

    // 4. Update the scrollbar maximum to account for the newly added display lines
    If Assigned(fVScroll) Then
      // Max must be in pixels (same unit as UpdateScrollbars uses).
      SP_ScrollBar(fVScroll).Max := Max(ClientH, fWrappedCount * Max(1, Round(iFH * iSY)));
  End;

  RepositionButtons;
End;

Function  SP_AmigaGuide.WantCurrentLineHighlight: Boolean; Begin Result := False; End;
Function  SP_AmigaGuide.TreatsLeadingDigitsAsLineNum(RawIdx: Integer): Boolean; Begin Result := False; End;

// ---------------------------------------------------------------------------
// Draw / Keyboard
// ---------------------------------------------------------------------------

Procedure SP_AmigaGuide.Draw;
Var
  nav: aString;
  wl, cfH: Integer;
Begin
  If fPendingNavNode <> '' Then Begin
    nav := fPendingNavNode; fPendingNavNode := '';
    GoToNode(nav);
    // If arriving at a search result target, scroll to the matching line
    If fHighlightNode >= 0 Then Begin
      If fCurrentNode = fHighlightNode Then Begin
        cfH := Max(1, Round(iFH * iSY));
        wl  := WrappedLineOfRaw(fHighlightLine, fHighlightCol);
        If wl >= 0 Then Begin
          fTopPixel := wl * cfH;
          SP_ScrollBar(fVScroll).Pos := fTopPixel;
        End;
      End Else
        // Wrong node - clear highlight so it doesn't misfire later
        fHighlightNode := -1;
    End;
    Exit;
  End;

  If fNavBar.Width <> fWidth - fPaddingLeft - fPaddingRight - (Ord(fBorder) * 2) Then
    ResizeNavBar;

  fSelLine := fCursorLine;
  fSelCol  := fCursorCol;

  RepositionButtons;
  Inherited;
  fHighlightNode := -1;  // highlight shown for one paint only
  fNavBar.Paint;
End;

Procedure SP_AmigaGuide.PerformKeyDown(Var Handled: Boolean);
Begin
  Handled := False;

  // There's no real way to tell that an amigaguide _has_ focus
  // so if it does then stealing keypresses will infuriate users that want to type their BASIC
  // So for now, I've disabled keyboard handling.

{  If (cLastKey=K_BACK) Or ((cLastKey=K_LEFT) And (cKEYSTATE[K_ALT]=1)) Then Begin
    If CanGoBack Then Begin GoBack; SP_PlaySystem(CLICKCHAN,CLICKBANK); End;
    Handled := True; Exit;
  End;
  If (cLastKey=K_RIGHT) And (cKEYSTATE[K_ALT]=1) Then Begin
    If CanGoForward Then Begin GoForward; SP_PlaySystem(CLICKCHAN,CLICKBANK); End;
    Handled := True; Exit;
  End;
  Inherited;}
End;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

Procedure SP_AmigaGuide.LoadGuide(Const Filename: aString);
Var SL: TStringList;
Begin
  SL := TStringList.Create;
  Try
    SL.LoadFromFile(Filename);
    LoadGuideFromString(SL.Text);
  Finally
    SL.Free;
  End;
End;

Procedure SP_AmigaGuide.LoadGuideFromString(Const Content: aString);
Var idx: Integer;
Begin
  DestroyButtons; FreeNodes;
  fCurrentNode:=-1; fNavHistLen:=0; fNavHistPos:=-1;
  fLines.Clear; SetLength(fLineInfos,0); fWrapDirty:=True;
  ParseGuide(Content);
  If fNodeCount > 0 Then Begin
    idx := FindNode('MAIN');
    If idx < 0 Then idx := 0;
    // FIX (Issues 5 & 6): history is now TNavHistEntry records.
    SetLength(fNavHistory, 16);
    fNavHistory[0].NodeIdx  := idx;
    fNavHistory[0].TopPixel := 0;
    fNavHistLen := 1;
    fNavHistPos := 0;
    LoadNode(idx, False);
  End;
End;

Procedure SP_AmigaGuide.GoToNode(Const NodeName: aString);
Var idx, sp: Integer; part: aString;
Begin
  idx := FindNode(NodeName);
  If idx < 0 Then Begin
    sp := Pos('/', NodeName);
    If sp > 0 Then Begin
      part := Upper(SP_Copy(NodeName, sp+1, MaxInt));
      If part = '' Then part := 'MAIN';
      idx := FindNode(part);
    End;
  End;
  If idx >= 0 Then Begin
    LoadNode(idx, True);
    fTopPixel := 0;
    SP_ScrollBar(fVScroll).Pos := fTopPixel;
  End;
End;

// FIX (Issues 5 & 6): restore saved scroll position when navigating history.
Procedure SP_AmigaGuide.GoBack;
Begin
  If fNavHistPos > 0 Then Begin
    Dec(fNavHistPos);
    LoadNode(fNavHistory[fNavHistPos].NodeIdx, False);
    fTopPixel := fNavHistory[fNavHistPos].TopPixel;
    SP_ScrollBar(fVScroll).Pos := fTopPixel;
    Paint;
  End;
End;

Procedure SP_AmigaGuide.GoForward;
Begin
  If fNavHistPos < fNavHistLen-1 Then Begin
    Inc(fNavHistPos);
    LoadNode(fNavHistory[fNavHistPos].NodeIdx, False);
    fTopPixel := fNavHistory[fNavHistPos].TopPixel;
    SP_ScrollBar(fVScroll).Pos := fTopPixel;
    Paint;
  End;
End;

Function SP_AmigaGuide.CanGoBack:    Boolean; Begin Result := fNavHistPos > 0; End;
Function SP_AmigaGuide.CanGoForward: Boolean; Begin Result := fNavHistPos < fNavHistLen-1; End;

Function SP_AmigaGuide.CurrentNodeTitle: aString;
Begin If fCurrentNode >= 0 Then Result := fNodes[fCurrentNode].Title Else Result := ''; End;

Function SP_AmigaGuide.CurrentNodeName: aString;
Begin If fCurrentNode >= 0 Then Result := fNodes[fCurrentNode].Name  Else Result := ''; End;

end.
