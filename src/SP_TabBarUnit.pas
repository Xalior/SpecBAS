// Copyright (C) 2010 By Paul Dunn
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

unit SP_TabBarUnit;

// SP_TabBar - a horizontal row of labelled tabs with a "+" new-tab button.
//
// -- Styles ------------------------------------------------------------------
//
// tbsButton (default):
//   Tabs look like normal buttons: DrawRect black border + coloured fill.
//   Selected = fSelTabColour (default 5, cyan, matching menu highlight).
//   Unselected = fTabColour (default 15, white).
//   Bar = fBarColour (default 251).  Gap of SP_TabEdgeGap on all sides.
//   1px drop shadow on right+bottom of each tab button.
//   "+" also looks like a button (Border=True, click animation).
//
// tbsMerge:
//   Selected tab omits its joining-edge border and starts flush at that edge,
//   appearing to merge with the listing (as the active menu item does).
//   The gradient at the joining edge acts as the dividing line; the selected
//   tab's fill overpaints its portion, breaking the line only there.
//   Unselected tabs are recessed SP_TabRecess pixels from the joining edge.
//
// -- Always drawn ------------------------------------------------------------
//   - Gradient: SP_TabShadowLines rows from palette 224 (greyscale near-black)
//     to fBarColour at the joining edge.  Blends into bar background.
//   - 1px SP_UIBorder at the opposite (non-joining) edge.
//
// -- Notes -------------------------------------------------------------------
//   Requires SP_AlignBottom fix in SP_BaseComponentUnit.AlignChildren:
//     Dec(pRect.Bottom, fHeight - 1)   ← not Dec(pRect.Bottom, fHeight)
//   This closes the 1-pixel gap between the listing editor and the tab bar.

{$INCLUDE SpecBAS.inc}

interface

Uses
  Types, SysUtils, Math,
  SP_Util, SP_BaseComponentUnit, SP_ButtonUnit, SP_Errors;

Const

  SP_TabPadX        = 6;    // horizontal text padding per tab (each side)
  SP_TabPadY        = 3;    // vertical padding per tab (each side)
  SP_TabCloseW      = 12;   // pixel width of the close (x) hit zone
  SP_TabGap         = 2;    // gap between adjacent tabs
  SP_TabMinW        = 40;   // minimum tab pixel width
  SP_TabRecess      = 2;    // tbsMerge: recess of unselected tabs from joining edge
  SP_TabEdgeGap     = 4;    // gap between tabs/buttons and bar boundary
  SP_TabShadowLines = 4;    // number of gradient rows at the joining edge
  SP_TabShadowStart = 224;  // start colour of gradient (greyscale near-black)

Type

  TSP_TabBarStyle = (tbsButton, tbsMerge);

  TSP_TabItem = Record
    Caption:   aString;
    Dirty:     Boolean;
    HitRect:   TRect;
    CloseRect: TRect;
  End;

  SP_TabChangeEvent = Procedure(Sender: SP_BaseComponent; Index: Integer) Of Object;
  SP_TabCloseEvent  = Procedure(Sender: SP_BaseComponent; Index: Integer) Of Object;

  SP_TabBar = Class(SP_BaseComponent)

  Private

    fTabs:         Array Of TSP_TabItem;
    fTabCount:     Integer;
    fSelectedTab:  Integer;
    fStyle:        TSP_TabBarStyle;
    fTabsOnBottom: Boolean;
    fMaxTabWidth:  Integer;
    fBarColour:    Byte;
    fTabColour:    Byte;
    fSelTabColour: Byte;
    fHotTab:       Integer;
    fHotClose:     Integer;
    fPressTab:     Integer;
    fPressClose:   Integer;
    fAddBtn:       SP_Button;

    fOnTabChange:  SP_TabChangeEvent;
    fOnTabClose:   SP_TabCloseEvent;
    fOnAddTab:     SP_BaseEvent;

    Function  AddBtnReservedW: Integer;
    Function  TabDrawY(Index: Integer): Integer;
    Function  TabDrawH(Index: Integer): Integer;
    Function  DisplayCaption(Index: Integer): aString;
    Function  TabFromPoint(X, Y: Integer): Integer;
    Function  CloseFromPoint(X, Y: Integer): Integer;
    Procedure LayoutTabs;
    Procedure DrawTab(Index: Integer);
    Procedure UpdateAddBtn;
    Procedure AddBtnClick(Sender: SP_BaseComponent);

    Procedure SetStyle(s: TSP_TabBarStyle);
    Procedure SetSelectedTab(NewIdx: Integer);
    Procedure SetTabsOnBottom(b: Boolean);
    Procedure SetMaxTabWidth(w: Integer);
    Procedure SetBarColour(c: Byte);
    Procedure SetTabColour(c: Byte);
    Procedure SetSelTabColour(c: Byte);

  Public

    Constructor Create(Owner: SP_BaseComponent);

    Procedure Draw; Override;
    Procedure MouseDown(Sender: SP_BaseComponent; X, Y, Btn: Integer); Override;
    Procedure MouseUp(Sender: SP_BaseComponent; X, Y, Btn: Integer); Override;
    Procedure MouseMove(Sender: SP_BaseComponent; X, Y, Btn: Integer); Override;
    Procedure MouseLeave; Override;
    Procedure SetBounds(x, y, w, h: Integer); Override;

    Function  AddTab(Const Caption: aString): Integer;
    Procedure RemoveTab(Index: Integer);
    Procedure RenameTab(Index: Integer; Const NewCaption: aString);
    Procedure SetTabDirty(Index: Integer; IsDirty: Boolean);
    Function  TabCaption(Index: Integer): aString;
    Function  TabDirty(Index: Integer): Boolean;
    Function  PreferredHeight: Integer;

    Property Style:        TSP_TabBarStyle  Read fStyle        Write SetStyle;
    Property SelectedTab:  Integer          Read fSelectedTab  Write SetSelectedTab;
    Property TabCount:     Integer          Read fTabCount;
    Property TabsOnBottom: Boolean          Read fTabsOnBottom Write SetTabsOnBottom;
    Property MaxTabWidth:  Integer          Read fMaxTabWidth  Write SetMaxTabWidth;
    Property BarColour:    Byte             Read fBarColour    Write SetBarColour;
    Property TabColour:    Byte             Read fTabColour    Write SetTabColour;
    Property SelTabColour: Byte             Read fSelTabColour Write SetSelTabColour;
    Property AddButton:    SP_Button        Read fAddBtn;

    Property OnTabChange:  SP_TabChangeEvent  Read fOnTabChange  Write fOnTabChange;
    Property OnTabClose:   SP_TabCloseEvent   Read fOnTabClose   Write fOnTabClose;
    Property OnAddTab:     SP_BaseEvent       Read fOnAddTab     Write fOnAddTab;

  End;

implementation

Uses SP_Components, SP_SysVars, SP_Sound, SP_Input;

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

// Horizontal space reserved at the right of the bar for the "+" button.
// btnSide = fHeight - SP_TabEdgeGap * 2  (button is square, matching tab height)
// reserved = btnSide + SP_TabEdgeGap (right margin) + SP_TabGap (gap to last tab)
Function SP_TabBar.AddBtnReservedW: Integer;
Var btnSide: Integer;
Begin
  btnSide := fHeight - SP_TabEdgeGap * 2;
  Result  := btnSide + SP_TabEdgeGap + SP_TabGap;
End;

// Y-origin of the drawn (visible) part of a tab.
Function SP_TabBar.TabDrawY(Index: Integer): Integer;
Begin
  Case fStyle Of
    tbsButton:
      Result := SP_TabEdgeGap;   // uniform gap from joining edge in button style
    tbsMerge:
      If fTabsOnBottom Then Begin
        If Index = fSelectedTab Then Result := 0             // flush: merges with listing
        Else                         Result := SP_TabRecess; // recessed
      End Else
        Result := SP_TabEdgeGap;  // tabs-on-top: gap at top (non-joining edge)
    Else
      Result := SP_TabEdgeGap;
  End;
End;

// Pixel height of the drawn part of a tab.
Function SP_TabBar.TabDrawH(Index: Integer): Integer;
Begin
  Case fStyle Of
    tbsButton:
      // Uniform: SP_TabEdgeGap gap at BOTH edges.
      Result := fHeight - SP_TabEdgeGap * 2;
    tbsMerge:
      If fTabsOnBottom Then
        // Non-joining edge = bar bottom: leave SP_TabEdgeGap gap there.
        Result := (fHeight - SP_TabEdgeGap) - TabDrawY(Index)
      Else Begin
        // Non-joining edge = bar top (accounted for in TabDrawY).
        // Joining edge = bar bottom: selected reaches it; unselected recessed.
        If Index = fSelectedTab Then Result := fHeight - SP_TabEdgeGap
        Else                         Result := fHeight - SP_TabEdgeGap - SP_TabRecess;
      End;
    Else
      Result := fHeight - SP_TabEdgeGap * 2;
  End;
End;

// Caption with dirty flag prepended, truncated to the available pixel width.
Function SP_TabBar.DisplayCaption(Index: Integer): aString;
Var
  cap:    aString;
  availW: Integer;
  maxCh:  Integer;
Begin
  If (Index < 0) Or (Index >= fTabCount) Then Begin Result := ''; Exit; End;
  cap := fTabs[Index].Caption;
  If fTabs[Index].Dirty Then cap := '*' + cap;
  availW := (fTabs[Index].HitRect.Right - fTabs[Index].HitRect.Left) - SP_TabPadX * 2 - 2;
  If fTabCount > 1 Then Dec(availW, SP_TabCloseW);
  If availW <= 0 Then Begin Result := ''; Exit; End;
  If Proportional Then Begin
    If TextWidth(cap) > availW Then Begin
      While (Length(cap) > 1) And (TextWidth(cap + '...') > availW) Do
        SetLength(cap, Length(cap) - 1);
      cap := cap + '...';
    End;
  End Else Begin
    maxCh := availW Div Max(1, Round(iFW * iSX));
    If Length(cap) > maxCh Then
      cap := Copy(cap, 1, Max(1, maxCh - 3)) + '...';
  End;
  Result := cap;
End;

Function SP_TabBar.TabFromPoint(X, Y: Integer): Integer;
Var i: Integer;
Begin
  Result := -1;
  For i := 0 To fTabCount - 1 Do
    If PtInRect(fTabs[i].HitRect, Point(X, Y)) Then Begin Result := i; Exit; End;
End;

Function SP_TabBar.CloseFromPoint(X, Y: Integer): Integer;
Var i: Integer;
Begin
  Result := -1;
  For i := 0 To fTabCount - 1 Do
    If PtInRect(fTabs[i].CloseRect, Point(X, Y)) Then Begin Result := i; Exit; End;
End;

// Sync the "+" button appearance to the current style and colours.
Procedure SP_TabBar.UpdateAddBtn;
Begin
  If Not Assigned(fAddBtn) Then Exit;
  Case fStyle Of
    tbsButton: Begin
      fAddBtn.Border         := True;       // visible frame + click animation
      fAddBtn.fBackgroundClr := fBarColour;
      fAddBtn.fColour        := 15; // matches unselected tabs
      fAddBtn.Proportional   := False;
    End;
    tbsMerge: Begin
      fAddBtn.Border         := False;
      fAddBtn.fBackgroundClr := fBarColour;
      fAddBtn.fColour        := fBarColour;
      fAddBtn.Proportional   := False;
    End;
  End;
  If Assigned(fAddBtn) Then fAddBtn.Paint;
End;

// Recompute every tab's HitRect / CloseRect and reposition the "+" button.
// Width policy: natural width per tab; equal compression only on overflow.
Procedure SP_TabBar.LayoutTabs;
Var
  i, x, availW, cfH, closeY: Integer;
  naturalW, totalW, compressW: Integer;
  btnSide, btnX, btnY: Integer;
  cap: aString;
  tabWidths: Array Of Integer;
Begin
  If Not Assigned(fAddBtn) Then Exit;

  cfH := Max(1, Round(iFH * iSY));

  // "+" button: square, inset SP_TabEdgeGap from top, bottom, and right edge.
  btnSide := fHeight - SP_TabEdgeGap * 2;
  If btnSide < 4 Then btnSide := 4;
  btnX := fWidth - SP_TabEdgeGap - btnSide +1;
  btnY := SP_TabEdgeGap;
  fAddBtn.SetBounds(btnX, btnY, btnSide, btnSide);
  fAddBtn.Proportional := False;
  fAddBtn.CentreCaption;

  If fTabCount = 0 Then Exit;

  // Available width: bar width minus reserved + button section, minus left inset.
  availW := (fWidth - AddBtnReservedW) - SP_TabEdgeGap + 4;
  If availW <= 0 Then Exit;

  SetLength(tabWidths, fTabCount);

  // Pass 1: natural width per tab from the full (untruncated) caption.
  For i := 0 To fTabCount - 1 Do Begin
    cap := fTabs[i].Caption;
    If fTabs[i].Dirty Then cap := '*' + cap;
    If Proportional Then naturalW := TextWidth(cap)
    Else                 naturalW := Length(cap) * Max(1, Round(iFW * iSX));
    // Only reserve space for the close zone when there is more than one tab.
    If fTabCount > 1 Then
      Inc(naturalW, SP_TabPadX * 2 + SP_TabCloseW + 2)
    Else
      Inc(naturalW, SP_TabPadX * 2 + 2);
    If (fMaxTabWidth > 0) And (naturalW > fMaxTabWidth) Then naturalW := fMaxTabWidth;
    If naturalW < SP_TabMinW Then naturalW := SP_TabMinW;
    tabWidths[i] := naturalW;
  End;

  // Pass 2: equal compression if total exceeds available width.
  totalW := 0;
  For i := 0 To fTabCount - 1 Do Inc(totalW, tabWidths[i] + SP_TabGap);
  Dec(totalW, SP_TabGap);
  If totalW > availW Then Begin
    compressW := (availW - (fTabCount - 1) * SP_TabGap) Div fTabCount;
    If (fMaxTabWidth > 0) And (compressW > fMaxTabWidth) Then compressW := fMaxTabWidth;
    If compressW < SP_TabMinW Then compressW := SP_TabMinW;
    For i := 0 To fTabCount - 1 Do tabWidths[i] := compressW;
  End;

  // Close zone: vertically centred within the shallower of the two tab states.
  Case fStyle Of
    tbsButton:
      closeY := SP_TabEdgeGap + (fHeight - SP_TabEdgeGap * 2 - cfH) Div 2;
    tbsMerge:
      If fTabsOnBottom Then
        closeY := SP_TabRecess + (fHeight - SP_TabEdgeGap - SP_TabRecess - cfH) Div 2
      Else
        closeY := SP_TabEdgeGap + (fHeight - SP_TabEdgeGap - SP_TabRecess - cfH) Div 2;
    Else
      closeY := SP_TabEdgeGap + (fHeight - SP_TabEdgeGap * 2 - cfH) Div 2;
  End;

  x := SP_TabEdgeGap -2;  // left inset margin before the first tab
  For i := 0 To fTabCount - 1 Do Begin
    fTabs[i].HitRect := Rect(x, 0, x + tabWidths[i], fHeight);
    If fTabCount > 1 Then
      fTabs[i].CloseRect := Rect(
        x + tabWidths[i] - SP_TabCloseW - SP_TabPadX,
        closeY,
        x + tabWidths[i] - SP_TabPadX,
        closeY + cfH
      )
    Else
      fTabs[i].CloseRect := Rect(0, 0, 0, 0);  // no close zone when only tab
    Inc(x, tabWidths[i] + SP_TabGap);
  End;
End;

Procedure SP_TabBar.AddBtnClick(Sender: SP_BaseComponent);
Begin
  If Assigned(fOnAddTab) Then fOnAddTab(Self);
End;

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------

Constructor SP_TabBar.Create(Owner: SP_BaseComponent);
Begin
  Inherited;

  fTypeName     := 'spTabBar';
  fTabCount     := 0;
  fSelectedTab  := -1;
  fHotTab       := -1;
  fHotClose     := -1;
  fPressTab     := -1;
  fPressClose   := -1;
  fStyle        := tbsButton;
  fTabsOnBottom := True;
  fMaxTabWidth  := 0;
  fBarColour    := 251;           // SP_UIWindowBack: contrasts with both editor and tabs
  fTabColour    := 7;             // 15, white
  fSelTabColour := 15;            // cyan, matching the menu selection highlight
  fBorder       := False;
  fCanFocus     := False;

  fAddBtn := SP_Button.Create(Self);
  fAddBtn.Caption   := '+';
  fAddBtn.fCanFocus := False;
  fAddBtn.OnClick   := AddBtnClick;
  fAddBtn.Proportional := False;

  // fShadow is already True from SP_Button.Create - no change needed
  UpdateAddBtn;

  fHeight := PreferredHeight;
  // LayoutTabs is deferred to the first SetBounds call (from AlignChildren).
  // fWidth is still 16px here and would produce nonsense results.
End;

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

Procedure SP_TabBar.DrawTab(Index: Integer);
Var
  r:              TRect;
  x1, y1, x2, y2: Integer;
  cap:            aString;
  cfH, ty, tx:   Integer;
  sz, cxL, cxR, cyT, cyB: Integer;
  bgClr:          Byte;
  isSelected:     Boolean;
  isHot:          Boolean;
  isHotClose:     Boolean;
  isPressClose:   Boolean;
  isPressTab:     Boolean;
Begin
  If (Index < 0) Or (Index >= fTabCount) Then Exit;

  r  := fTabs[Index].HitRect;
  x1 := r.Left;
  y1 := TabDrawY(Index);
  x2 := r.Right - 1;
  y2 := y1 + TabDrawH(Index) - 1;

  isSelected   := (Index = fSelectedTab);
  isHot        := (Index = fHotTab) And Not isSelected;
  isHotClose   := (Index = fHotClose);
  isPressClose := (Index = fPressClose);
  isPressTab   := (fPressTab >= 0) And (Index = fPressTab) And Not isSelected;

  cfH := Max(1, Round(iFH * iSY));

  // Body colour.
  // tbsButton tabs are drawn using the same DrawRect+FillRect pattern as
  // SP_Button.Draw (which itself calls DrawBtnFrame, currently flat).  If
  // SP_Button's default visual changes (e.g. DrawBtnFrame gains 3-D shading),
  // update DrawTab to match - or refactor tab buttons to be real SP_Button
  // children, which would make the coupling automatic.
  If isSelected Then bgClr := fSelTabColour
  Else If isHot Then bgClr := SP_UIHalfLight   // lighter than BtnBackFocus to avoid
                                               // looking "pressed" on hover
  Else               bgClr := fTabColour;

  // -- Drop shadow (tbsButton, not actively pressed) -------------------------
  // 1px on the right and bottom edges, outside the button frame.
  // Matches the shadow behaviour of SP_Button (shadow disabled while pressed).
  If (fStyle = tbsButton) And Not isPressTab Then Begin
    DrawLine(x2 + 1, y1 + 1, x2 + 1, y2 + 1, fShadowClr);  // right shadow
    DrawLine(x1 + 1, y2 + 1, x2 + 1, y2 + 1, fShadowClr);  // bottom shadow
  End;

  // -- Frame and fill --------------------------------------------------------

  Case fStyle Of

    tbsButton: Begin
      // Standard button: black outline + coloured fill.
      // Pressed state: shift the entire graphic 1px right+down, matching
      // SP_Button.Draw's DrawBtnFrame(Rect(1,1,fWidth,fHeight), ...) behaviour.
      If isPressTab Then Begin
        DrawRect(x1 + 1, y1 + 1, x2, y2, SP_UIBorder);
        FillRect(x1 + 2, y1 + 2, x2 - 1, y2 - 1, bgClr);
      End Else Begin
        DrawRect(x1, y1, x2, y2, SP_UIBorder);
        FillRect(x1 + 1, y1 + 1, x2 - 1, y2 - 1, bgClr);
      End;
    End;

    tbsMerge: Begin
      // Three-sided border; joining edge omitted for selected tab.
      FillRect(x1, y1, x2, y2, bgClr);
      If fTabsOnBottom Then Begin
        DrawLine(x1,     y1, x1,     y2, SP_UIHighlight);
        DrawLine(x2,     y1, x2,     y2, SP_UIShadow);
        DrawLine(x1 + 1, y2, x2 - 1, y2, SP_UIShadow);
        If Not isSelected Then
          DrawLine(x1 + 1, y1, x2 - 1, y1, SP_UIBorder);
      End Else Begin
        DrawLine(x1,     y1, x1,     y2, SP_UIHighlight);
        DrawLine(x2,     y1, x2,     y2, SP_UIShadow);
        DrawLine(x1 + 1, y1, x2 - 1, y1, SP_UIHighlight);
        If Not isSelected Then
          DrawLine(x1 + 1, y2, x2 - 1, y2, SP_UIBorder);
      End;
    End;

  End;

  // -- Caption --------------------------------------------------------------
  cap := DisplayCaption(Index);
  ty  := y1 + (TabDrawH(Index) - cfH) Div 2;
  tx  := x1 + SP_TabPadX;
  // tbsButton pressed: shift content 1px right+down, matching SP_Button.Draw behaviour.
  If (fStyle = tbsButton) And isPressTab Then Begin
    Inc(tx); Inc(ty);
  End;
  Print(tx, ty, cap, fFontClr, -1, iSX, iSY, False, False, False, False);

  // -- Close zone highlight (hover / press) ---------------------------------
  With fTabs[Index].CloseRect Do Begin
    If isPressClose Then
      FillRect(Left + 2, Top -1, Right - 2, Bottom - 1, SP_UISelection)
    Else If isHotClose Then
      FillRect(Left + 2, Top -1, Right - 2, Bottom - 1, SP_UIHalfLight);
  End;

  // -- Close symbol: square ×, only drawn when multiple tabs exist ---------
  // sz is derived from the smaller dimension so the × is always square.
  If fTabCount > 1 Then
    With fTabs[Index].CloseRect Do Begin
      sz  := Min(Right - Left, Bottom - Top) - 4;
      If sz < 2 Then sz := 2;
      cxL := Left  + (Right  - Left  - sz) Div 2;
      cxR := cxL + sz;
      cyT := Top   + (Bottom - Top   - sz) Div 2 -1;
      cyB := cyT + sz;
      DrawLine(cxL, cyT, cxR, cyB, fFontClr);
      DrawLine(cxR, cyT, cxL, cyB, fFontClr);
    End;

End;

Procedure SP_TabBar.Draw;
Var
  i, shade: Integer;
Begin
  // -- Bar background -------------------------------------------------------
  FillRect(0, 0, fWidth - 1, fHeight - 1, fBarColour);

  // -- Gradient shadow at the joining edge ----------------------------------
  // SP_TabShadowLines rows from greyscale 224 (near-black) to fBarColour.
  // Steps evenly through the palette greyscale ramp using integer arithmetic.
  // In tbsMerge the selected tab's fill (drawn last) overpaints its portion
  // of the gradient, creating a clean break only under the active tab.
  If fBarColour >= SP_TabShadowStart Then Begin
    For i := 0 To SP_TabShadowLines - 1 Do Begin
      shade := SP_TabShadowStart
               + i * (fBarColour - SP_TabShadowStart) Div (SP_TabShadowLines - 1);
      If fTabsOnBottom Then
        DrawLine(0, i, fWidth - 1, i, shade)
      Else
        DrawLine(0, fHeight - 1 - i, fWidth - 1, fHeight - 1 - i, shade);
    End;
  End;

  // -- Border at the non-gradient edge --------------------------------------
  If fTabsOnBottom Then
    DrawLine(0, fHeight - 1, fWidth - 1, fHeight - 1, SP_UIBorder)
  Else
    DrawLine(0, 0, fWidth - 1, 0, SP_UIBorder);

  // -- Tabs: unselected first so selected tab paints on top -----------------
  // In tbsMerge this lets the selected tab's y=0 fill overpaint the gradient
  // within its x range, breaking the gradient line only there.
  For i := 0 To fTabCount - 1 Do
    If i <> fSelectedTab Then DrawTab(i);
  If (fSelectedTab >= 0) And (fSelectedTab < fTabCount) Then
    DrawTab(fSelectedTab);
End;

// ---------------------------------------------------------------------------
// Layout / resize
// ---------------------------------------------------------------------------

Procedure SP_TabBar.SetBounds(x, y, w, h: Integer);
Begin
  Inherited;
  LayoutTabs;
End;

// ---------------------------------------------------------------------------
// Tab management
// ---------------------------------------------------------------------------

Function SP_TabBar.AddTab(Const Caption: aString): Integer;
Begin
  Result := fTabCount;
  Inc(fTabCount);
  SetLength(fTabs, fTabCount);
  fTabs[Result].Caption   := Caption;
  fTabs[Result].Dirty     := False;
  fTabs[Result].HitRect   := Rect(0, 0, 0, 0);
  fTabs[Result].CloseRect := Rect(0, 0, 0, 0);
  If fSelectedTab < 0 Then fSelectedTab := 0;
  LayoutTabs;
  Paint;
End;

Procedure SP_TabBar.RemoveTab(Index: Integer);
Var i: Integer;
Begin
  If (Index < 0) Or (Index >= fTabCount) Then Exit;
  For i := Index To fTabCount - 2 Do fTabs[i] := fTabs[i + 1];
  Dec(fTabCount);
  SetLength(fTabs, fTabCount);
  If fSelectedTab >= fTabCount Then fSelectedTab := fTabCount - 1;
  If (fSelectedTab < 0) And (fTabCount > 0) Then fSelectedTab := 0;
  fHotTab := -1; fHotClose := -1; fPressTab := -1; fPressClose := -1;
  LayoutTabs;
  Paint;
End;

Procedure SP_TabBar.RenameTab(Index: Integer; Const NewCaption: aString);
Begin
  If (Index < 0) Or (Index >= fTabCount) Then Exit;
  If fTabs[Index].Caption <> NewCaption Then Begin
    fTabs[Index].Caption := NewCaption;
    LayOutTabs;
  End;
  Paint;
End;

Procedure SP_TabBar.SetTabDirty(Index: Integer; IsDirty: Boolean);
Begin
  If (Index < 0) Or (Index >= fTabCount) Then Exit;
  If fTabs[Index].Dirty <> IsDirty Then Begin
    fTabs[Index].Dirty := IsDirty;
    LayoutTabs;
    Paint;
  End;
End;

Function SP_TabBar.TabCaption(Index: Integer): aString;
Begin
  If (Index >= 0) And (Index < fTabCount) Then Result := fTabs[Index].Caption
  Else                                         Result := '';
End;

Function SP_TabBar.TabDirty(Index: Integer): Boolean;
Begin
  If (Index >= 0) And (Index < fTabCount) Then Result := fTabs[Index].Dirty
  Else                                         Result := False;
End;

Function SP_TabBar.PreferredHeight: Integer;
Var cfH: Integer;
Begin
  cfH := Max(1, Round(iFH * iSY));
  Case fStyle Of
    // tbsButton: gap top AND bottom, so 2 × SP_TabEdgeGap.
    tbsButton: Result := cfH + SP_TabPadY * 2 + SP_TabEdgeGap * 2 + 2;
    // tbsMerge: gap only at non-joining edge (bottom), plus recess allowance.
    tbsMerge:  Result := cfH + SP_TabPadY * 2 + SP_TabRecess + SP_TabEdgeGap + 2;
    Else       Result := cfH + SP_TabPadY * 2 + SP_TabEdgeGap * 2 + 2;
  End;
End;

// ---------------------------------------------------------------------------
// Property setters
// ---------------------------------------------------------------------------

Procedure SP_TabBar.SetStyle(s: TSP_TabBarStyle);
Begin
  If fStyle <> s Then Begin
    fStyle  := s;
    fHeight := PreferredHeight;
    UpdateAddBtn;
    LayoutTabs;
    Paint;
  End;
End;

Procedure SP_TabBar.SetSelectedTab(NewIdx: Integer);
Begin
  If (NewIdx = fSelectedTab) Or (NewIdx < 0) Or (NewIdx >= fTabCount) Then Exit;
  fSelectedTab := NewIdx;
  Paint;
  If Assigned(fOnTabChange) Then fOnTabChange(Self, NewIdx);
End;

Procedure SP_TabBar.SetTabsOnBottom(b: Boolean);
Begin
  If fTabsOnBottom <> b Then Begin fTabsOnBottom := b; LayoutTabs; Paint; End;
End;

Procedure SP_TabBar.SetMaxTabWidth(w: Integer);
Begin
  If fMaxTabWidth <> w Then Begin fMaxTabWidth := w; LayoutTabs; Paint; End;
End;

Procedure SP_TabBar.SetBarColour(c: Byte);
Begin
  If fBarColour <> c Then Begin
    fBarColour := c;
    UpdateAddBtn;
    Paint;
  End;
End;

Procedure SP_TabBar.SetTabColour(c: Byte);
Begin
  If fTabColour <> c Then Begin
    fTabColour := c;
    UpdateAddBtn;
    Paint;
  End;
End;

Procedure SP_TabBar.SetSelTabColour(c: Byte);
Begin
  If fSelTabColour <> c Then Begin fSelTabColour := c; Paint; End;
End;

// ---------------------------------------------------------------------------
// Mouse events
// ---------------------------------------------------------------------------

Procedure SP_TabBar.MouseDown(Sender: SP_BaseComponent; X, Y, Btn: Integer);
Var idx: Integer;
Begin
  If Btn = 1 Then Begin
    idx := CloseFromPoint(X, Y);
    If idx >= 0 Then Begin
      fPressClose := idx; fPressTab := -1;
    End Else Begin
      idx := TabFromPoint(X, Y);
      If idx >= 0 Then Begin
        fPressTab := idx; fPressClose := -1;
      End Else Begin
        // Click is in the bar but not on any tab (e.g. on the + button or
        // empty bar area).  Explicitly clear any stale press state so the
        // next Paint doesn't show a ghost pressed tab.
        fPressTab := -1; fPressClose := -1;
      End;
    End;
    Paint;
  End;
  Inherited;
End;

Procedure SP_TabBar.MouseUp(Sender: SP_BaseComponent; X, Y, Btn: Integer);
Var idx: Integer;
Begin
  If Btn = 1 Then Begin
    If fPressClose >= 0 Then Begin
      idx := CloseFromPoint(X, Y);
      If (idx >= 0) And (idx = fPressClose) Then Begin
        fHotClose := -1; fPressClose := -1;
        If Assigned(fOnTabClose) Then fOnTabClose(Self, idx);
      End Else
        fPressClose := -1;
    End Else If fPressTab >= 0 Then Begin
      idx := TabFromPoint(X, Y);
      If (idx >= 0) And (idx = fPressTab) Then SetSelectedTab(idx);
      fPressTab := -1;
    End;
    Paint;
  End;
  Inherited;
End;

Procedure SP_TabBar.MouseMove(Sender: SP_BaseComponent; X, Y, Btn: Integer);
Var newHotTab, newHotClose: Integer;
Begin
  newHotClose := CloseFromPoint(X, Y);
  If newHotClose >= 0 Then newHotTab := newHotClose
  Else                     newHotTab := TabFromPoint(X, Y);
  If (newHotTab <> fHotTab) Or (newHotClose <> fHotClose) Then Begin
    fHotTab := newHotTab; fHotClose := newHotClose;
    Paint;
  End;
  Inherited;
End;

Procedure SP_TabBar.MouseLeave;
Begin
  fHotTab := -1; fHotClose := -1; fPressTab := -1; fPressClose := -1;
  Paint;
  Inherited;
End;

end.
