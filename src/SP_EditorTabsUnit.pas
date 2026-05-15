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

unit SP_EditorTabsUnit;

// Per-tab editor state for SP_TabBar.
//
// -- Per-tab state --------------------------------------------------------
//
// Each tab owns:
//   - Listing text + per-line compiler flags
//   - SP_Program token array (instant restore, no recompile)
//   - SP_Memo undo/redo stacks, scroll position, cursor (PackEditorState)
//   - Program identity: StoredProgName (raw PROGNAME), StoredDisplayName
//     (SP_GetProgName result for tab caption), StoredProgLine, StoredFileChanged,
//     StoredAutoStart
//
// -- Tab switching --------------------------------------------------------
//
//   SP_EditorTab_Switch(NewIdx)
//     1. SP_EditorTab_SaveActive
//     2. SP_ActiveTab := NewIdx
//     3. SP_EditorTab_RestoreActive
//
// -- RUN / re-enter editor ------------------------------------------------
//
//   SP_CloseEditorWindows -> SP_EditorTab_SaveActive -> EditorHost_Destroy
//   SP_CreateEditorWindows -> EditorHost_Init (SetupTabBar) -> SP_CreateDirectWindow
//                          -> SP_EditorTab_SyncActiveIfChanged -> SP_EditorTab_RestoreActive
//
// -- Display name sync ----------------------------------------------------
//
//   SP_EditorTab_SyncDisplay(SP_GetProgName(PROGNAME, True)) is called from
//   SP_FPEditor whenever a fresh formatted name is available:
//     - FP_OnTabSwitched  (after every RestoreActive)
//     - After EditorHost_Init in SP_CreateFPWindow  (initial startup)
//     - SP_SwitchFocus fwEditor branch  (editor gains focus / user clicks)

{$INCLUDE SpecBAS.inc}

interface

Uses SP_AnsiStringList, SP_Util, SP_BaseComponentUnit;

Type

  TSP_EditorTab = Record

    // -- Listing snapshot ------------------------------------------------
    ListingText:    AnsiString;
    ListingFlags:   Array of TLineFlags;
    ListingCount:   Integer;
    ListingFPCLine: Integer;
    ListingFPCPos:  Integer;
    ListingFPSelLine: Integer;
    ListingFPSelPos:  Integer;

    // -- Tokenised program snapshot --------------------------------------
    ProgTokens:     Array of aString;
    ProgCount:      Integer;

    // -- Editor visual + undo/redo state ---------------------------------
    EditorState:    aString;   // from SP_Memo.PackEditorState

    // -- Program identity ------------------------------------------------
    // Field names use the Stored prefix to avoid shadowing SP_SysVars globals
    // (PROGNAME, PROGLINE, FILECHANGED, AUTOSTART) inside With blocks.
    StoredProgName:    aString;   // raw PROGNAME; only restored if non-empty
    StoredDisplayName: aString;   // SP_GetProgName(PROGNAME,True); drives tab caption
    StoredProgLine:    Integer;
    StoredFileChanged: Boolean;
    StoredFileNamed:   Boolean;

  End;

  SP_TabChangeEvent = Procedure(Sender: SP_BaseComponent; Index: Integer) Of Object;
  SP_TabCloseEvent  = Procedure(Sender: SP_BaseComponent; Index: Integer) Of Object;

Var

  SP_EditorTabs: Array of TSP_EditorTab;
  SP_ActiveTab:  Integer = -1;

Type
  TSP_TabEventBridge = Class
    Procedure TabChange(Sender: SP_BaseComponent; Index: Integer);
    Procedure AddTab(Sender: SP_BaseComponent);
    Procedure CloseTab(Sender: SP_BaseComponent; Index: Integer);
  End;

Var
  TabBridge: TSP_TabEventBridge = nil;

// Lifecycle
Procedure SP_EditorTab_Init;
Procedure SP_EditorTab_SetupTabBar;
Function  SP_EditorTab_New(Const Caption: aString): Integer;
Procedure SP_EditorTab_Switch(NewIdx: Integer);
Procedure SP_EditorTab_Close(Idx: Integer);

// Called around editor window destroy / recreate
Procedure SP_EditorTab_SaveActive;
Procedure SP_EditorTab_RestoreActive;
Procedure SP_EditorTab_SyncActiveIfChanged(Const sNewProgName: aString);

// Called by SP_FPEditor with a fresh SP_GetProgName result.
// Updates StoredDisplayName and renames the visual tab button.
Procedure SP_EditorTab_SyncDisplay(Const DisplayName: aString);
Function  TabDisplayName(Const Tab: TSP_EditorTab): aString;

// Persistence helpers - called from SP_Main (save) and SP_Editor (restore).
// These are kept out of SP_EditorTabsUnit's own file I/O to avoid a circular
// dependency through SP_FileIO -> SP_BASICEditorHostUnit -> SP_EditorTabsUnit.

// Snapshot current Listing/SP_Program/globals into tab slot Idx.
// Creates the slot if Idx = Length(SP_EditorTabs) (append).
// Called from SP_Editor after each SP_LoadProgram during multi-tab restore.
Procedure SP_EditorTab_CaptureFromGlobals(Idx: Integer; Const DisplayName: aString);

// Restore Listing/SP_Program globals from tab slot Idx without touching the
// live editor component.  Called from SP_Editor after all tabs are loaded, to
// ensure the active tab's content is in the globals when the editor opens.
Procedure SP_EditorTab_RestoreGlobals(Idx: Integer);

// Returns the raw listing text for tab Idx (for SP_Main's save loop).
Function  SP_EditorTab_GetListingText(Idx: Integer): AnsiString;

// Returns StoredProgName for tab Idx (written to ZXASCII PROG header).
Function  SP_EditorTab_GetProgName(Idx: Integer): aString;

// Returns StoredFileChanged for tab Idx (written to ZXASCII CHANGED header).
Function  SP_EditorTab_GetFileChanged(Idx: Integer): Boolean;

// Returns StoredDisplayName for tab Idx (written to s:tabstate).
Function  SP_EditorTab_GetDisplayName(Idx: Integer): aString;

// Hook: wired by SP_FPEditor to a procedure that refreshes the window title.
// Fired after every RestoreActive (tab switch, new, close, re-entry).
Type TSP_TabNotify = Procedure;
Var  SP_EditorTab_OnAfterSwitch: TSP_TabNotify = nil;

implementation

Uses
  Math, SysUtils, SyncObjs,
  SP_FPEditor,
  SP_Tokenise,
  SP_SysVars,
  SP_BASICEditorHostUnit;

// ---------------------------------------------------------------------------
// Name formatting
// ---------------------------------------------------------------------------

// Strips the blob suffix appended by SP_GetProgName: #16 + 4 colour bytes + ' ' + #244.
// Must be called before storing a display name so baked-in focus-state colour
// codes don't pollute StoredDisplayName.
Function StripBlobSuffix(Const s: aString): aString;
Var n: Integer;
Begin
  Result := s;
  // The suffix is always 7 bytes: #16 (ink control) + 4 LongWord bytes + ' ' + #244
  n := Length(s);
  If (n >= 7) And (s[n] = BlobChar) And (s[n-1] = ' ') And (s[n-6] = #16) Then
    SetLength(Result, n - 7);
End;

// Returns a clean display name: strips path, .bas extension, AND blob suffix.
// Fallback to 'New program' for empty input.
Function FormatTabName(Const s: aString): aString;
Var
  n: aString;
  i: Integer;
Begin
  n := SP_Trim(StripBlobSuffix(s));
  If n = '' Then Begin Result := NEWPROGNAME; Exit; End;

  // Strip path: find last '/' or '\' or ':' 
  For i := Length(n) DownTo 1 Do
    If (n[i] = '/') Or (n[i] = '\') Or (n[i] = ':') Then Begin
      n := Copy(n, i + 1, Length(n));
      Break;
    End;

  If SP_Trim(n) = '' Then Result := NEWPROGNAME
  Else              Result := n;
End;

// Appends the changed/clean blob to a name using the editor colours.
// Always uses editor-focus colour constants (not DW-focus), because the tab
// bar is part of the editor window regardless of which sub-window has focus.
Function AppendBlob(Const name: aString; Changed: Boolean): aString;
Const
  cl_changed = 2;   // red   - matches SP_GetProgName editor-focused changed
  cl_normal  = 4;   // green - matches SP_GetProgName editor-focused normal
Begin
  If Changed Then
    Result := name + aChar(#16) + LongWordToString(cl_changed) + ' ' + BlobChar
  Else
    Result := name + aChar(#16) + LongWordToString(cl_normal)  + ' ' + BlobChar;
End;

// Returns the display name to show on a tab button.
// StoredDisplayName holds the clean filename (no path, no blob); the blob is
// appended fresh here using StoredFileChanged so the colour is always correct
// regardless of which sub-window had focus when SyncDisplay last fired.
Function TabDisplayName(Const Tab: TSP_EditorTab): aString;
Var baseName: aString;
Begin
  If Tab.StoredDisplayName <> '' Then
    baseName := Tab.StoredDisplayName
  Else
    baseName := FormatTabName(Tab.StoredProgName);
  Result := AppendBlob(baseName, Tab.StoredFileChanged);
End;

// ---------------------------------------------------------------------------
// Snapshot helpers (called by reference, no With blocks)
// ---------------------------------------------------------------------------

Procedure SnapshotListing(Var Tab: TSP_EditorTab);
Var i: Integer;
Begin
  Tab.ListingText    := Listing.Text;
  Tab.ListingCount   := Listing.Count;
  SetLength(Tab.ListingFlags, Tab.ListingCount);
  For i := 0 To Tab.ListingCount - 1 Do
    Tab.ListingFlags[i] := Listing.Flags[i]^;
  Tab.ListingFPCLine   := Listing.FPCLine;
  Tab.ListingFPCPos    := Listing.FPCPos;
  Tab.ListingFPSelLine := Listing.FPSelLine;
  Tab.ListingFPSelPos  := Listing.FPSelPos;
End;

Procedure RestoreListing(Const Tab: TSP_EditorTab);
Var i: Integer;
Begin
  Listing.SetText(Tab.ListingText);
  For i := 0 To Min(Tab.ListingCount, Listing.Count) - 1 Do
    Listing.Flags[i] := @Tab.ListingFlags[i];
  Listing.FPCLine   := Tab.ListingFPCLine;
  Listing.FPCPos    := Tab.ListingFPCPos;
  Listing.FPSelLine := Tab.ListingFPSelLine;
  Listing.FPSelPos  := Tab.ListingFPSelPos;
End;

Procedure SnapshotProgram(Var Tab: TSP_EditorTab);
Var i: Integer;
Begin
  Tab.ProgCount := SP_Program_Count;
  SetLength(Tab.ProgTokens, Tab.ProgCount);
  For i := 0 To Tab.ProgCount - 1 Do
    Tab.ProgTokens[i] := SP_Program[i];
End;

Procedure RestoreProgram(Const Tab: TSP_EditorTab);
Var i: Integer;
Begin
  SP_Program_Count := Tab.ProgCount;
  SetLength(SP_Program, Tab.ProgCount);
  For i := 0 To Tab.ProgCount - 1 Do
    SP_Program[i] := Tab.ProgTokens[i];
End;

// ---------------------------------------------------------------------------
// SyncDisplay
// ---------------------------------------------------------------------------

Procedure SP_EditorTab_SyncDisplay(Const DisplayName: aString);
Var name: aString;
Begin
  If (SP_ActiveTab < 0) Or (SP_ActiveTab >= Length(SP_EditorTabs)) Then Exit;
  // Strip path, extension, and any blob suffix before storing.
  // TabDisplayName appends the blob fresh at draw time using StoredFileChanged,
  // so the colour is always correct regardless of focus state when this fired.
  name := FormatTabName(DisplayName);
  If name = '' Then name := NEWPROGNAME;
  SP_EditorTabs[SP_ActiveTab].StoredDisplayName := name;
  If Assigned(FPTabBar) Then
    FPTabBar.RenameTab(SP_ActiveTab, AppendBlob(name, FILECHANGED));
End;

// ---------------------------------------------------------------------------
// SyncActiveIfChanged
// ---------------------------------------------------------------------------

Procedure SP_EditorTab_SyncActiveIfChanged(Const sNewProgName: aString);
Var
  ContentChanged: Boolean;
  TabName:        aString;
Begin
  If (SP_ActiveTab < 0) Or (SP_ActiveTab >= Length(SP_EditorTabs)) Then Exit;

  CompilerLock.Enter;
  ContentChanged :=
    (Listing.Count    <> SP_EditorTabs[SP_ActiveTab].ListingCount) Or
    (SP_Program_Count <> SP_EditorTabs[SP_ActiveTab].ProgCount) Or
    // Also trigger when identity changed without a line-count change.
    // This covers reloading the same file (same counts, but FILECHANGED went
    // False), saving (FILECHANGED False, PROGNAME may have changed), or loading
    // a different file that happens to have the same number of lines.
    (PROGNAME    <> SP_EditorTabs[SP_ActiveTab].StoredProgName) Or
    (FILECHANGED <> SP_EditorTabs[SP_ActiveTab].StoredFileChanged);
  CompilerLock.Leave;

  If Not ContentChanged Then Exit;

  CompilerLock.Enter;
  Try
    SnapshotListing(SP_EditorTabs[SP_ActiveTab]);
  Finally
    CompilerLock.Leave;
  End;
  SnapshotProgram(SP_EditorTabs[SP_ActiveTab]);

  // Discard stale EditorState - undo entries reference the old file's content.
  SP_EditorTabs[SP_ActiveTab].EditorState        := '';
  SP_EditorTabs[SP_ActiveTab].StoredProgName     := PROGNAME;
  // Strip blob suffix before storing - TabDisplayName appends it fresh.
  SP_EditorTabs[SP_ActiveTab].StoredDisplayName  := FormatTabName(sNewProgName);
  SP_EditorTabs[SP_ActiveTab].StoredProgLine     := PROGLINE;
  SP_EditorTabs[SP_ActiveTab].StoredFileChanged  := False;
  SP_EditorTabs[SP_ActiveTab].StoredFileNAMED    := FILENAMED;
  FILECHANGED := False;

  TabName := sNewProgName;
  If TabName = '' Then TabName := NEWPROGNAME;
  If Assigned(FPTabBar) Then
    FPTabBar.RenameTab(SP_ActiveTab, TabDisplayName(SP_EditorTabs[SP_ActiveTab]));
End;

// ---------------------------------------------------------------------------
// Core save / restore
// ---------------------------------------------------------------------------

Procedure SP_EditorTab_SaveActive;
Begin
  If (SP_ActiveTab < 0) Or (SP_ActiveTab >= Length(SP_EditorTabs)) Then Exit;

  CompilerLock.Enter;
  Try
    SnapshotListing(SP_EditorTabs[SP_ActiveTab]);
  Finally
    CompilerLock.Leave;
  End;

  SnapshotProgram(SP_EditorTabs[SP_ActiveTab]);

  If Assigned(FPBASICEditor) Then
    SP_EditorTabs[SP_ActiveTab].EditorState := FPBASICEditor.PackEditorState
  Else
    SP_EditorTabs[SP_ActiveTab].EditorState := '';

  // Store program identity using explicit indexing (not a With block) so that
  // PROGNAME, PROGLINE, FILECHANGED, AUTOSTART refer to the SP_SysVars globals,
  // not the record fields (which share the same name case-insensitively).
  SP_EditorTabs[SP_ActiveTab].StoredProgName    := PROGNAME;
  SP_EditorTabs[SP_ActiveTab].StoredProgLine    := PROGLINE;
  SP_EditorTabs[SP_ActiveTab].StoredFileChanged := FILECHANGED;
  SP_EditorTabs[SP_ActiveTab].StoredFileNamed  := FILENAMED;

  // Sync tab bar caption.
  If Assigned(FPTabBar) Then
    FPTabBar.RenameTab(SP_ActiveTab, TabDisplayName(SP_EditorTabs[SP_ActiveTab]));
End;

Procedure SP_EditorTab_RestoreActive;
Begin
  If (SP_ActiveTab < 0) Or (SP_ActiveTab >= Length(SP_EditorTabs)) Then Exit;
  If Not Assigned(FPBASICEditor) Then Exit;

  // All accesses use explicit indexing so the field names StoredProgName etc.
  // are unambiguously the record fields, and PROGNAME/PROGLINE/FILECHANGED/AUTOSTART
  // are unambiguously the SP_SysVars globals.

  CompilerLock.Enter;
  Try
    RestoreListing(SP_EditorTabs[SP_ActiveTab]);
  Finally
    CompilerLock.Leave;
  End;

  RestoreProgram(SP_EditorTabs[SP_ActiveTab]);

  EditorHost_LoadFromListing;

  // Restore identity globals BEFORE UnpackEditorState so cursor events
  // (SetCursorRaw -> OnCursorMoved -> UpdateStatusLabel) see the correct PROGNAME.
  // Only restore PROGNAME when non-empty: a blank StoredProgName means we have
  // no reliable value and should leave whatever PROGNAME SpecBAS already has.
  If SP_EditorTabs[SP_ActiveTab].StoredProgName <> '' Then
    PROGNAME := SP_EditorTabs[SP_ActiveTab].StoredProgName
  ELSE
    PROGNAME := NEWPROGNAME;
  PROGLINE  := SP_EditorTabs[SP_ActiveTab].StoredProgLine;

  // Refresh gutter blobs and clear exec line BEFORE restoring FILECHANGED.
  // Both calls can trigger internal events that set FILECHANGED := True.
  // Restoring FILECHANGED afterwards overrides any such side-effects.
  EditorHost_RefreshLineStates;
  EditorHost_ClearExecLine;

  // Restore undo/redo and scroll/cursor AFTER SetText has cleared them.
  If SP_EditorTabs[SP_ActiveTab].EditorState <> '' Then
    FPBASICEditor.UnpackEditorState(SP_EditorTabs[SP_ActiveTab].EditorState);

  // FILECHANGED is set last: everything above may set it as a side-effect.
  FILECHANGED := SP_EditorTabs[SP_ActiveTab].StoredFileChanged;
  FILENAMED := SP_EditorTabs[SP_ActiveTab].StoredFileNamed;

  If Assigned(SP_EditorTab_OnAfterSwitch) Then SP_EditorTab_OnAfterSwitch;
End;

// ---------------------------------------------------------------------------
// Tab lifecycle
// ---------------------------------------------------------------------------

Procedure SP_EditorTab_Init;
Begin
  If SP_ActiveTab >= 0 Then Exit;

  SetLength(SP_EditorTabs, 1);
  FillChar(SP_EditorTabs[0], SizeOf(SP_EditorTabs[0]), 0);

  CompilerLock.Enter;
  Try
    SnapshotListing(SP_EditorTabs[0]);
  Finally
    CompilerLock.Leave;
  End;
  SnapshotProgram(SP_EditorTabs[0]);

  // Explicit indexing for the same reason as SaveActive/RestoreActive.
  SP_EditorTabs[0].StoredProgName    := PROGNAME;
  SP_EditorTabs[0].StoredProgLine    := PROGLINE;
  SP_EditorTabs[0].StoredFileChanged := FILECHANGED;
  SP_EditorTabs[0].StoredFileNamed   := FILENAMED;
  // StoredDisplayName is intentionally left empty here.  FP_OnTabSwitched is
  // called explicitly after EditorHost_Init in SP_CreateFPWindow and will
  // populate it from SP_GetProgName(PROGNAME, True).

  SP_ActiveTab := 0;

  If Not Assigned(TabBridge) Then TabBridge := TSP_TabEventBridge.Create;
  If Assigned(FPTabBar) Then Begin
    FPTabBar.OnTabChange := TabBridge.TabChange;
    FPTabBar.OnAddTab    := TabBridge.AddTab;
    FPTabBar.OnTabClose  := TabBridge.CloseTab;
  End;
End;

Procedure SP_EditorTab_SetupTabBar;
Var i: Integer;
Begin
  If Not Assigned(FPTabBar) Then Exit;

  If SP_ActiveTab < 0 Then Begin
    FPTabBar.AddTab(NEWPROGNAME);
    SP_EditorTab_Init;
  End Else Begin
    For i := 0 To Length(SP_EditorTabs) - 1 Do
      FPTabBar.AddTab(TabDisplayName(SP_EditorTabs[i]));
    FPTabBar.SelectedTab := SP_ActiveTab;
    If Not Assigned(TabBridge) Then TabBridge := TSP_TabEventBridge.Create;
    FPTabBar.OnTabChange := TabBridge.TabChange;
    FPTabBar.OnAddTab    := TabBridge.AddTab;
    FPTabBar.OnTabClose  := TabBridge.CloseTab;
  End;
End;

Function SP_EditorTab_New(Const Caption: aString): Integer;
Var
  NewTab: TSP_EditorTab;
  NewIdx: Integer;
Begin
  SP_EditorTab_SaveActive;

  FillChar(NewTab, SizeOf(NewTab), 0);
  NewTab.ListingText          := '';
  NewTab.ListingCount         := 1;
  SetLength(NewTab.ListingFlags, 1);
  NewTab.ListingFlags[0].State := 0;
  NewTab.ListingFPCLine        := 0;
  NewTab.ListingFPCPos         := 1;
  NewTab.ListingFPSelLine      := 0;
  NewTab.ListingFPSelPos       := 1;
  NewTab.ProgCount             := 0;
  NewTab.StoredProgName        := '';       // no file loaded yet
  NewTab.StoredDisplayName     := Caption;  // caption = display name until a file is loaded
  NewTab.StoredProgLine        := 0;
  NewTab.StoredFileChanged     := False;
  NewTab.StoredFileNamed       := False;

  NewIdx := Length(SP_EditorTabs);
  SetLength(SP_EditorTabs, NewIdx + 1);
  SP_EditorTabs[NewIdx] := NewTab;

  If Assigned(FPTabBar) Then
    FPTabBar.AddTab(Caption);

  SP_ActiveTab := NewIdx;
  If Assigned(FPTabBar) Then
    FPTabBar.SelectedTab := NewIdx;
  SP_EditorTab_RestoreActive;

  Result := NewIdx;
End;

Procedure SP_EditorTab_Switch(NewIdx: Integer);
Begin
  If (NewIdx = SP_ActiveTab) Or
     (NewIdx < 0) Or (NewIdx >= Length(SP_EditorTabs)) Then Exit;

  SP_EditorTab_SaveActive;
  SP_ActiveTab := NewIdx;
  SP_EditorTab_RestoreActive;

  If Assigned(FPTabBar) And (FPTabBar.SelectedTab <> NewIdx) Then
    FPTabBar.SelectedTab := NewIdx;
End;

Procedure SP_EditorTab_Close(Idx: Integer);
Var
  i, newActive: Integer;
Begin
  If Length(SP_EditorTabs) <= 1 Then Exit;
  If (Idx < 0) Or (Idx >= Length(SP_EditorTabs)) Then Exit;

  If Idx = SP_ActiveTab Then Begin
    If Idx > 0 Then newActive := Idx - 1
    Else            newActive := 1;
    SP_ActiveTab := newActive;
    SP_EditorTab_RestoreActive;
    If Assigned(FPTabBar) Then FPTabBar.SelectedTab := SP_ActiveTab;
  End Else If Idx < SP_ActiveTab Then
    Dec(SP_ActiveTab);

  For i := Idx To Length(SP_EditorTabs) - 2 Do
    SP_EditorTabs[i] := SP_EditorTabs[i + 1];
  SetLength(SP_EditorTabs, Length(SP_EditorTabs) - 1);

  If Assigned(FPTabBar) Then FPTabBar.RemoveTab(Idx);
End;

// ---------------------------------------------------------------------------
// Persistence helpers
// ---------------------------------------------------------------------------

Procedure SP_EditorTab_CaptureFromGlobals(Idx: Integer; Const DisplayName: aString);
Begin
  // Append a new slot if needed.
  If Idx >= Length(SP_EditorTabs) Then Begin
    SetLength(SP_EditorTabs, Idx + 1);
    FillChar(SP_EditorTabs[Idx], SizeOf(SP_EditorTabs[Idx]), 0);
  End;

  CompilerLock.Enter;
  Try
    SnapshotListing(SP_EditorTabs[Idx]);
  Finally
    CompilerLock.Leave;
  End;
  SnapshotProgram(SP_EditorTabs[Idx]);

  SP_EditorTabs[Idx].StoredProgName    := PROGNAME;
  SP_EditorTabs[Idx].StoredDisplayName := DisplayName;
  SP_EditorTabs[Idx].StoredProgLine    := PROGLINE;
  SP_EditorTabs[Idx].StoredFileChanged := FILECHANGED;
  SP_EditorTabs[Idx].StoredFileNamed   := FILENAMED;
  SP_EditorTabs[Idx].EditorState       := '';  // no undo history from a fresh load
End;

Procedure SP_EditorTab_RestoreGlobals(Idx: Integer);
Begin
  If (Idx < 0) Or (Idx >= Length(SP_EditorTabs)) Then Exit;

  CompilerLock.Enter;
  Try
    RestoreListing(SP_EditorTabs[Idx]);
  Finally
    CompilerLock.Leave;
  End;
  RestoreProgram(SP_EditorTabs[Idx]);

  If SP_EditorTabs[Idx].StoredProgName <> '' Then
    PROGNAME := SP_EditorTabs[Idx].StoredProgName;
  PROGLINE    := SP_EditorTabs[Idx].StoredProgLine;
  FILECHANGED := SP_EditorTabs[Idx].StoredFileChanged;
  FILENAMED   := SP_EditorTabs[Idx].StoredFileNamed;
End;

Function SP_EditorTab_GetListingText(Idx: Integer): AnsiString;
Begin
  If (Idx >= 0) And (Idx < Length(SP_EditorTabs)) Then
    Result := SP_EditorTabs[Idx].ListingText
  Else
    Result := '';
End;

Function SP_EditorTab_GetProgName(Idx: Integer): aString;
Begin
  If (Idx >= 0) And (Idx < Length(SP_EditorTabs)) Then
    Result := SP_EditorTabs[Idx].StoredProgName
  Else
    Result := '';
End;

Function SP_EditorTab_GetFileChanged(Idx: Integer): Boolean;
Begin
  If (Idx >= 0) And (Idx < Length(SP_EditorTabs)) Then
    Result := SP_EditorTabs[Idx].StoredFileChanged
  Else
    Result := False;
End;

Function SP_EditorTab_GetDisplayName(Idx: Integer): aString;
Begin
  // Return the plain display name without the blob suffix.
  // The blob is focus-state-dependent and must not be persisted to s:tabstate;
  // TabDisplayName (used for live display) appends it fresh at draw time.
  If (Idx >= 0) And (Idx < Length(SP_EditorTabs)) Then Begin
    If SP_EditorTabs[Idx].StoredDisplayName <> '' Then
      Result := SP_EditorTabs[Idx].StoredDisplayName
    Else
      Result := FormatTabName(SP_EditorTabs[Idx].StoredProgName);
  End Else
    Result := NEWPROGNAME;
End;

// ---------------------------------------------------------------------------
// FPTabBar event callbacks
// ---------------------------------------------------------------------------

Procedure TSP_TabEventBridge.TabChange(Sender: SP_BaseComponent; Index: Integer);
Begin
  SP_EditorTab_Switch(Index);
End;

Procedure TSP_TabEventBridge.AddTab(Sender: SP_BaseComponent);
Begin
  SP_EditorTab_New(NEWPROGNAME);
End;

Procedure TSP_TabEventBridge.CloseTab(Sender: SP_BaseComponent; Index: Integer);
Begin
  SP_EditorTab_Close(Index);
End;

end.
