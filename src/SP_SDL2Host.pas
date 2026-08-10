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

unit SP_SDL2Host;

// What MainForm.pas is to the Lazarus build, this unit is to the SDL2 one:
// the single platform-specific file. It creates the window, starts the
// interpreter thread, fills in the CB_* callback table the rest of SpecBAS
// reaches the host through, translates SDL2 events into SpecBAS's own input
// vocabulary, and owns the main loop.
//
// It deliberately exports the same names MainForm.pas does — Main,
// Quitting, GetTicks, MouseInForm and the rest — so SP_Display.pas selects
// between the two with a conditional in its uses clause and needs no other
// change.
//
// TSDLMain is not a window class. It is a small object over the SDL window
// that answers the questions SP_Display.pas asks a form: where it is, how
// big it is, and how to resize it.

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$INCLUDE SpecBAS.inc}

interface

Uses
  {$IFDEF UNIX}Unix, BaseUnix,{$ENDIF}
  SysUtils, Classes, Types, Math, SyncObjs, SDL2,
  SP_SysVars, SP_Util, SP_Errors, SP_Input, SP_Main, SP_FileIO,
  SP_Graphics, SP_Graphics32, SP_BankManager, SP_Menu, SP_Sound, Bass,
  SP_Tokenise, SP_Components, SP_BaseComponentUnit, RunTimeCompiler,
  SP_SDL2Backend, SP_SDL2Keys;

Const

  // MainForm.pas defines this as a Windows message id. Nothing sends it
  // here; it exists so SP_Display.pas's Delphi branch still parses.
  WM_RESIZEMAIN = 1025;

Type

  TSDLMain = Class
  Private
    Function  GetClientWidth: Integer;
    Function  GetClientHeight: Integer;
    Procedure SetClientWidth(Value: Integer);
    Procedure SetClientHeight(Value: Integer);
    Function  GetLeft: Integer;
    Function  GetTop: Integer;
    Procedure SetLeft(Value: Integer);
    Procedure SetTop(Value: Integer);
  Public
    Handle: NativeUInt;
    // The SDL window carries no border of its own as far as the renderer is
    // concerned, so the window size and the client size are the same number.
    Property ClientWidth:  Integer read GetClientWidth  write SetClientWidth;
    Property ClientHeight: Integer read GetClientHeight write SetClientHeight;
    Property Width:        Integer read GetClientWidth  write SetClientWidth;
    Property Height:       Integer read GetClientHeight write SetClientHeight;
    Property Left:         Integer read GetLeft         write SetLeft;
    Property Top:          Integer read GetTop          write SetTop;
    Function  ClientRect: TRect;
    Function  ScreenToClient(Const P: TPoint): TPoint;
    Function  ClientToScreen(Const P: TPoint): TPoint;
    Procedure DoResizeMain(l, t, w, h: Integer);
    Procedure FormResize(Sender: TObject);
    Procedure CreateGDIBitmap;
  End;

  // Image loading is asked for from the interpreter thread and has to run
  // on the main one. SP_BankManager.IntLoadImage hands one of these to
  // TThread.Synchronize.
  TLoadImageSync = Class
    FFilename: aString;
    FError:    TSP_ErrorCode;
    Procedure  Run;
  End;

  TSpecBAS_Thread = Class(TThread)
    Procedure Execute; Override;
  End;

  Procedure YieldProc(const ms: aFloat);
  Procedure MsgProc;
  Procedure GetKeyState;
  Function  GetTicks: aFloat;
  Procedure MouseMoveTo(ToX, ToY: Integer);
  Procedure Quit;
  Procedure LoadImage(Filename: aString; Var Error: TSP_ErrorCode);
  Procedure SaveImage(Filename: aString; w, h: Integer; Pixels, Palette: pByte);
  Procedure FreeImageResource;
  Procedure SetWindowCaption;

  // Drain the SDL event queue once. Called every frame from the main loop,
  // and from MsgProc whenever the interpreter asks the host to catch up.
  Procedure SDLHost_PumpEvents;

  // Everything, from window creation to shutdown. The program calls this
  // and nothing else.
  Procedure SDLHost_Run;

Var

  Main: TSDLMain = Nil;
  BASThread: TSpecBAS_Thread = Nil;
  Quitting: Boolean = False;
  InitTime: LongWord;
  ImgResource: Array of Byte;
  BaseTime: aFloat = 0;
  MouseInForm: Boolean = False;
  AltDown: Boolean = False;
  FormActivated: Boolean = True;
  AltChars: aString = '';
  CaptionString: String = '';
  MainCanResize: Boolean = True;
  PendingKeyInfo:  SP_KeyInfo;
  PendingKeyValid: Boolean = False;

  // MainForm.pas keeps a TBitmap here for the Win32 blit path. Nothing in
  // the SDL2 build draws through one; the name survives because
  // SP_Display.pas frees it on shutdown.
  Bitmap: TObject = Nil;

implementation

Uses
  {$IFNDEF RUNTIMEONLY}SP_FPEditor, SP_ToolTipWindow, SP_BASICEditorHostUnit,{$ENDIF}
  SP_Display, SP_WindowMenuUnit, SP_PopUpMenuUnit, SP_BASICInterpreter,
  SP_BankFiling, SP_Interpret_PostFix, SP_MenuActions, DynLibs;

// ---------------------------------------------------------------- TSDLMain

Function TSDLMain.GetClientWidth: Integer;
Var
  W, H: Integer;
Begin
  SDLB_GetClientSize(W, H);
  Result := W;
End;

Function TSDLMain.GetClientHeight: Integer;
Var
  W, H: Integer;
Begin
  SDLB_GetClientSize(W, H);
  Result := H;
End;

Procedure TSDLMain.SetClientWidth(Value: Integer);
Var
  W, H: Integer;
Begin
  SDLB_GetClientSize(W, H);
  SDLB_SetClientSize(Value, H);
End;

Procedure TSDLMain.SetClientHeight(Value: Integer);
Var
  W, H: Integer;
Begin
  SDLB_GetClientSize(W, H);
  SDLB_SetClientSize(W, Value);
End;

Function TSDLMain.GetLeft: Integer;
Var
  X, Y: Integer;
Begin
  SDLB_GetWindowPos(X, Y);
  Result := X;
End;

Function TSDLMain.GetTop: Integer;
Var
  X, Y: Integer;
Begin
  SDLB_GetWindowPos(X, Y);
  Result := Y;
End;

Procedure TSDLMain.SetLeft(Value: Integer);
Var
  X, Y: Integer;
Begin
  SDLB_GetWindowPos(X, Y);
  SDLB_SetWindowPos(Value, Y);
End;

Procedure TSDLMain.SetTop(Value: Integer);
Var
  X, Y: Integer;
Begin
  SDLB_GetWindowPos(X, Y);
  SDLB_SetWindowPos(X, Value);
End;

Function TSDLMain.ClientRect: TRect;
Var
  W, H: Integer;
Begin
  SDLB_GetClientSize(W, H);
  Result := Rect(0, 0, W, H);
End;

Function TSDLMain.ScreenToClient(Const P: TPoint): TPoint;
Var
  X, Y: Integer;
Begin
  SDLB_GetWindowPos(X, Y);
  Result.X := P.X - X;
  Result.Y := P.Y - Y;
End;

Function TSDLMain.ClientToScreen(Const P: TPoint): TPoint;
Var
  X, Y: Integer;
Begin
  SDLB_GetWindowPos(X, Y);
  Result.X := P.X + X;
  Result.Y := P.Y + Y;
End;

Procedure TSDLMain.DoResizeMain(l, t, w, h: Integer);
Begin
  MainCanResize := False;
  Try
    FPSIMAGE := '';
    SDLB_SetClientSize(w, h);
    If Not SPFULLSCREEN Then
      SDLB_SetWindowPos(l, t);
    FormResize(Self);
  Finally
    SIZINGMAIN := False;
    MainCanResize := True;
  End;
End;

Procedure TSDLMain.FormResize(Sender: TObject);
Var
  W, H: Integer;
Begin
  SDLB_GetClientSize(W, H);
  If (W <= 0) or (H <= 0) Then Exit;
  SetScaling(DISPLAYWIDTH, DISPLAYHEIGHT, W, H);
  SP_InvalidateWholeDisplay;
  SP_NeedDisplayUpdate := True;
End;

Procedure TSDLMain.CreateGDIBitmap;
Begin
  // Nothing to do. The Win32 blit path this belongs to is not compiled here.
End;

Procedure TLoadImageSync.Run;
Begin
  CB_Load_Image(FFilename, FError);
End;

// ------------------------------------------------- interpreter thread

Procedure TSpecBAS_Thread.Execute;
Var
  Interpreter: TSP_BASICInterpreter;
Begin
  NameThreadForDebugging('Interpreter Thread');

  InterpreterThreadAlive := True;
  Priority := tpNormal;
  FreeOnTerminate := True;

  Interpreter := TSP_BASICInterpreter.Create(0);
  Try
    Interpreter.AcquireThreadVars;
    SP_MainLoop;
    Interpreter.ReleaseThreadVars;
  Finally
    Interpreter.Free;
  End;

  InterpreterThreadAlive := False;
End;

// ------------------------------------------------------------- the clock

Function GetTicks: aFloat;
Begin
  Result := SDLB_Milliseconds - BaseTime;
End;

Procedure YieldProc(const ms: aFloat);
Begin
  If ms <= 0 Then
    Sleep(0)
  Else
    Sleep(Round(ms));
End;

Procedure MsgProc;
Begin
  // The interpreter thread calls this too, and SDL's event queue may only
  // be pumped from the thread that created the window.
  If GetCurrentThreadId = MainThreadID Then
    SDLHost_PumpEvents;
End;

Procedure GetKeyState;
Var
  M: TSDL_KeyMod;
Begin
  M := SDL_GetModState;
  CAPSLOCK := Ord((M and KMOD_CAPS) <> 0);
  NUMLOCK  := Ord((M and KMOD_NUM) <> 0);
End;

Procedure MouseMoveTo(ToX, ToY: Integer);
Begin
  SDLB_WarpMouse(Round(ToX * ScaleMouseX), Round(ToY * ScaleMouseY));
End;

Procedure Quit;
Begin
  Quitting := True;
  QUITMSG := True;
End;

Procedure SetWindowCaption;
Var
  s: aString;
Begin
  If WCAPTION <> '' Then
    s := WCAPTION
  Else
    s := aString(ChangeFileExt(ExtractFilename(ParamStr(0)), ''));
  CaptionString := String(s);
  SDLB_SetTitle(CaptionString);
End;

// -------------------------------------------------------------- images

Procedure LoadImage(Filename: aString; Var Error: TSP_ErrorCode);
Begin
  // Not yet supplied on the SDL2 backend. SPX-011 requires this to be built
  // on Free Pascal's fcl-image, not on SDL2_image; until it is, a LOAD
  // SCREEN$ of a picture file reports an unsupported format rather than
  // producing a wrong picture.
  Error.Code := SP_ERR_INVALID_IMAGE_FORMAT;
End;

Procedure SaveImage(Filename: aString; w, h: Integer; Pixels, Palette: pByte);
Begin
  // As LoadImage.
End;

Procedure FreeImageResource;
Begin
  SetLength(ImgResource, 0);
End;

// ------------------------------------------------------------ the events

Procedure HandleKeyDown(Const Ev: TSDL_Event);
Var
  VK: Word;
  kInfo: SP_KeyInfo;
  k: Integer;
Begin
  VK := SDL2_ScanCodeToVK(Ev.key.keysym.scancode);
  If VK = 0 Then Exit;

  If VK = K_PAUSE Then Begin  // BREAK always saves a screen grab.
    ScreenShot(False);
    Exit;
  End;

  kInfo.KeyChar := #0;
  kInfo.KeyCode := VK and $7F;
  kInfo.NextFrameTime := FRAMES;
  kInfo.Repeating := False;
  kInfo.CanRepeat := True;
  kInfo.IsKey := True;
  kInfo.WindowID := FocusedWindow;

  // A printable key waits for the SDL_TEXTINPUT event that carries its
  // character. That event is the only thing that survives keyboard
  // layouts, dead keys and input methods correctly.
  If Not SDL2_IsNonPrintingKey(VK) Then Begin
    PendingKeyInfo  := kInfo;
    PendingKeyValid := True;
    Exit;
  End;

  If VK = K_ALT Then Begin

    AltDown := True;
    AltChars := '';

  End Else If AltDown Then Begin

    // ALT held with three digits enters a character by its code.
    If ((VK >= K_NUMPAD0) and (VK <= K_NUMPAD9)) or
       ((VK >= K_0) and (VK <= K_9)) Then Begin

      If (VK >= K_NUMPAD0) and (VK <= K_NUMPAD9) Then
        k := VK - K_NUMPAD0
      Else
        k := VK - K_0;

      AltChars := AltChars + IntToString(k);
      If Length(AltChars) = 3 Then Begin
        kInfo.KeyCode := StringToInt(AltChars);
        kInfo.KeyChar := aChar(kInfo.KeyCode);
        kInfo.CanRepeat := False;
        kInfo.IsKey := False;
        AltChars := '';
      End Else
        Exit;

    End;

  End;

  If ControlsAreInUse Then Begin
    DisplaySection.Enter;
    Try
      If ControlKeyEvent(kInfo.KeyChar, kInfo.KeyCode, True, kInfo.IsKey) Then
        Exit;
    Finally
      DisplaySection.Leave;
    End;
  End;

  SP_AddKey(kInfo);
End;

Procedure HandleTextInput(Const Ev: TSDL_Event);
Var
  C: aChar;
Begin
  If Not PendingKeyValid Then Exit;
  // The text field is UTF-8. SpecBAS's character set is single-byte, so
  // only a single-byte sequence can be delivered as a key.
  If (Ev.text.text[0] = #0) or (Ev.text.text[1] <> #0) Then Begin
    PendingKeyValid := False;
    Exit;
  End;
  C := aChar(Ev.text.text[0]);
  If (C < ' ') or (C = #127) Then Begin
    PendingKeyValid := False;
    Exit;
  End;

  PendingKeyInfo.KeyChar := C;
  PendingKeyValid := False;

  If ControlsAreInUse Then Begin
    DisplaySection.Enter;
    Try
      If ControlKeyEvent(PendingKeyInfo.KeyChar, PendingKeyInfo.KeyCode,
                         True, PendingKeyInfo.IsKey) Then
        Exit;
    Finally
      DisplaySection.Leave;
    End;
  End;

  SP_AddKey(PendingKeyInfo);
End;

Procedure HandleKeyUp(Const Ev: TSDL_Event);
Var
  VK: Word;
Begin
  VK := SDL2_ScanCodeToVK(Ev.key.keysym.scancode);
  If VK = 0 Then Exit;

  KEYSTATE[VK] := 0;
  cKEYSTATE[VK and $7F] := 0;
  ControlKeyEvent(#0, VK and $7F, False, True);
  SP_RemoveKey(VK and $7F);

  If AltDown and (VK = K_ALT) Then Begin
    AltDown := False;
    If AltChars <> '' Then
      SP_RemoveKey(StringToInt(AltChars));
    AltChars := '';
  End;
End;

Procedure HandleMouseMotion(Const Ev: TSDL_Event);
Var
  X, Y: Integer;
Begin
  If ScaleMouseX <= 0 Then Exit;
  X := Round(Ev.motion.x / ScaleMouseX);
  Y := Round(Ev.motion.y / ScaleMouseY);
  If (X = MOUSEX) and (Y = MOUSEY) Then Exit;
  MOUSEX := X;
  MOUSEY := Y;
  MOUSEMOVED := True;
  SP_NeedDisplayUpdate := True;
End;

Function ButtonMask(Const Ev: TSDL_Event): Integer;
Begin
  Case Ev.button.button of
    SDL_BUTTON_LEFT:   Result := 1;
    SDL_BUTTON_RIGHT:  Result := 2;
    SDL_BUTTON_MIDDLE: Result := 4;
  Else
    Result := 0;
  End;
End;

Procedure HandleMouseDown(Const Ev: TSDL_Event);
Begin
  If ScaleMouseX <= 0 Then Exit;
  MOUSEX := Round(Ev.button.x / ScaleMouseX);
  MOUSEY := Round(Ev.button.y / ScaleMouseY);
  MOUSEBTN := ButtonMask(Ev);
  M_DOWNFLAG := True;
End;

Procedure HandleMouseUp(Const Ev: TSDL_Event);
Begin
  If ScaleMouseX <= 0 Then Exit;
  MOUSEX := Round(Ev.button.x / ScaleMouseX);
  MOUSEY := Round(Ev.button.y / ScaleMouseY);
  MOUSEBTN := 0;
  M_UPFLAG := True;
End;

Procedure SDLHost_PumpEvents;
Var
  Ev: TSDL_Event;
Begin
  While SDL_PollEvent(@Ev) = 1 Do
    Case Ev.type_ of

      SDL_QUITEV:
        Begin
          Quit;
        End;

      SDL_KEYDOWN:
        If Ev.key.repeat_ = 0 Then HandleKeyDown(Ev);

      SDL_KEYUP:
        HandleKeyUp(Ev);

      SDL_TEXTINPUT:
        HandleTextInput(Ev);

      SDL_MOUSEMOTION:
        HandleMouseMotion(Ev);

      SDL_MOUSEBUTTONDOWN:
        HandleMouseDown(Ev);

      SDL_MOUSEBUTTONUP:
        HandleMouseUp(Ev);

      SDL_WINDOWEVENT:
        Case Ev.window.event of
          SDL_WINDOWEVENT_SIZE_CHANGED:
            If Assigned(Main) and MainCanResize Then Main.FormResize(Main);
          SDL_WINDOWEVENT_FOCUS_GAINED:
            Begin
              FormActivated := True;
              SP_SysVars.FOCUSED := True;
            End;
          SDL_WINDOWEVENT_FOCUS_LOST:
            Begin
              FormActivated := False;
              SP_SysVars.FOCUSED := False;
              SP_ClearAllKeys;
            End;
          SDL_WINDOWEVENT_EXPOSED:
            Begin
              SP_InvalidateWholeDisplay;
              SP_NeedDisplayUpdate := True;
            End;
        End;

    End;
End;

// ------------------------------------------------------ start and finish

Procedure HostCreate;
Var
  Idx: Integer;
  s, dir: String;
Begin
  INSTARTUP := True;
  HELPFILE := '/specbas.guide';

  DisplaySection.Enter;

  SP_GetMonitorMetrics;
  OrgWidth := REALSCREENWIDTH;
  OrgHeight := REALSCREENHEIGHT;

  MOUSEVISIBLE := False;

  EXENAME := ParamStr(0);
  PayLoad := TPayLoad.Create(EXENAME);
  PAYLOADPRESENT := PayLoad.HasPayLoad;
  If Not PAYLOADPRESENT Then
    PayLoad.Free;

  If Not PAYLOADPRESENT Then Begin
    PCOUNT := -1;
    PARAMS := TStringList.Create;
    For Idx := 0 To ParamCount Do Begin
      s := ParamStr(Idx);
      If Copy(s, 1, 1) <> '-' Then Begin
        If FileExists(s) Then Begin
          PARAMS.Add(aString(s));
          Inc(PCOUNT);
        End;
      End Else Begin
        PARAMS.Add(aString(s));
        Inc(PCOUNT);
      End;
    End;

    dir := GetCurrentDir;
    If (PCOUNT = 0) and FileExists(dir + PathDelim + 'autorun') Then Begin
      PCOUNT := 1;
      PARAMS.Add(aString(dir) + PathDelim + 'autorun');
    End;
  End;

  BaseTime := SDLB_Milliseconds;
  InitTime := Round(GetTicks);

  If Not PAYLOADPRESENT Then Begin

    BUILDSTR := '0.0.0.0-SDL2';
    {$IFDEF DEBUG}
    BUILDSTR := BUILDSTR + ' [Debug]';
    {$ENDIF}

    If PCOUNT <= 0 Then Begin
      CaptionString := 'SpecBAS v';
      HOMEFOLDER := aString(GetUserDir) + aString('specbas');
    End Else Begin
      CaptionString := ExtractFileName(String(PARAMS[1]));
      HOMEFOLDER := aString(ExtractFileDir(String(PARAMS[1])));
      If HOMEFOLDER = '' Then
        HOMEFOLDER := aString(GetCurrentDir);
    End;

  End Else Begin

    SetCurrentDir(ExtractFilePath(EXENAME));
    HOMEFOLDER := aString(GetCurrentDir);

  End;

  If Not DirectoryExists(String(HOMEFOLDER)) Then
    CreateDir(String(HOMEFOLDER));
  If Not DirectoryExists(String(HOMEFOLDER) + PathDelim + 'temp') Then
    CreateDir(String(HOMEFOLDER) + PathDelim + 'temp');
  TEMPDIR := HOMEFOLDER + aString(PathDelim + 'temp' + PathDelim);
  SetCurrentDir(String(HOMEFOLDER));
  HOMEFOLDER := Lower(HOMEFOLDER);
  If HOMEFOLDER[Length(HOMEFOLDER)] <> aChar(PathDelim) Then
    HOMEFOLDER := HOMEFOLDER + aChar(PathDelim);

  AUTOSAVE := Not PAYLOADPRESENT;

  ScrWidth := 800;
  ScrHeight := 480;
  SCALEWIDTH := 800;
  SCALEHEIGHT := 480;
  MENUBLOCK := False;

  // The callback table. This is how the platform-independent interpreter
  // reaches the host without importing it.

  CB_DecorateWindow := SP_Decorate_User_Window;
  CB_GetKeyLockState := GetKeyState;
  CB_Refresh_Display := Refresh_Display;
  CB_Quit := SP_SDL2Host.Quit;
  CB_SetScreenRes := SetScreen;
  CB_Test_Resolution := TestScreenResolution;
  CB_GetTicks := GetTicks;
  CB_Yield := YieldProc;
  CB_Load_Image := LoadImage;
  CB_Save_Image := SaveImage;
  CB_Free_Image := FreeImageResource;
  CB_Messages := MsgProc;
  CB_MouseMove := MouseMoveTo;
  CB_SETWINDOWCAPTION := SetWindowCaption;

  SP_SetFPS(GetScreenRefreshRate);
  SP_InitialGFXSetup(ScrWidth, ScrHeight, False);
  SP_GetMonitorMetrics;

  SDLB_SetTitle(CaptionString + String(BUILDSTR));
  Main.DoResizeMain((REALSCREENWIDTH - Main.Width) Div 2,
                    (REALSCREENHEIGHT - Main.Height) Div 2,
                    Main.Width, Main.Height);

  WINLEFT := Main.Left;
  WINTOP := Main.Top;

  SP_CLS(CPAPER);
  EDITLINE := '';
  CURSORPOS := 0;
  CURSORCHAR := 32;
  SYSTEMSTATE := SS_IDLE;

  // BASS is loaded dynamically and a failure is not fatal: a SpecBAS with
  // no sound library is silent, not dead.
  SoundEnabled := LoadLibrary(bassdll) <> NilHandle;
  SP_Init_Sound;

  CORECOUNT := System.CPUCount;

  BASThread := TSpecBAS_Thread.Create(True);

  DisplaySection.Leave;

  BASThread.Start;

  MouseInForm := SDLB_GetMousePos(Idx, Idx);
End;

Procedure HostDestroy;
Var
  Error: TSP_ErrorCode;
Begin
  PLAYSignalHalt(-1);
  If Not QUITMSG Then Begin
    Quitting := True;
    QUITMSG := True;
    BREAKSIGNAL := True;
    SP_WaitForSecondaries;
  End;

  While InterpreterThreadAlive Do
    CB_YIELD(1);

  If Assigned(PARAMS) Then PARAMS.Free;

  Quitting := True;

  If SoundEnabled Then
    BASS_Free;

  If PAYLOADPRESENT or (PCOUNT <> 0) Then Begin
    SP_RmDirUnSafe('/temp', Error);
    SP_RmDir('/s', Error);
    SP_RmDir('/fonts', Error);
    SP_RmDir('/keyboards', Error);
    SP_RmDir('/include', Error);
  End;

  SP_FinalizeThreadVars;
End;

Procedure SDLHost_Run;
Begin
  If Not SDLB_Start('SpecBAS', 800, 480) Then Begin
    WriteLn(StdErr, 'SpecBAS: SDL2 would not start: ', SDL_GetError);
    Halt(1);
  End;

  Main := TSDLMain.Create;
  Main.Handle := 0;

  Try
    HostCreate;

    While Not (Quitting or QUITMSG) Do Begin
      SDLHost_PumpEvents;
      FrameLoop;
    End;

    HostDestroy;
  Finally
    FreeAndNil(Main);
    SDLB_Stop;
  End;
End;

end.
