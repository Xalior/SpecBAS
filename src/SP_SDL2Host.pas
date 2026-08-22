// Copyright (C) 2010 By Paul Dunn
// Copyright (C) 2026 By D. Rimron-Soutter
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

// What MainForm.pas is to the Lazarus build, this unit is to the SDL2 one.
// It starts the window, starts the interpreter thread, fills in the CB_
// callback table the rest of SpecBAS reaches the host through, turns SDL2
// events into SpecBAS's own input, and owns the main loop.
//
// It exports the names MainForm.pas exports and the rest of SpecBAS calls
// for - Main, Quitting, GetTicks, MouseInForm and the others - so a unit
// that wants the host picks between the two in its uses clause and needs no
// other change.
//
// TSDLMain is not a window class. It is a small object over the SDL2 window
// that answers the questions SP_Display.pas asks a form: where the window
// is, how big it is, and how to resize it.

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$INCLUDE SpecBAS.inc}

interface

Uses
  SysUtils, Classes, Types, Math, SyncObjs, SDL2,
  SP_SysVars, SP_Util, SP_Errors, SP_Input, SP_Main, SP_FileIO,
  SP_Graphics, SP_Graphics32, SP_BankManager, SP_Menu, SP_Sound, Bass,
  SP_Tokenise, SP_Components, SP_BaseComponentUnit, RunTimeCompiler,
  SP_SDL2Backend, SP_SDL2Keys;

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
    // SDL2 measures the window by its client area, so the window size and
    // the client size are one number and the border margin SP_Display.pas
    // allows for is zero.
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

  // SP_BankManager.IntLoadImage is called on the interpreter thread and the
  // picture has to be decoded on the thread that owns the window, so it
  // hands one of these to TThread.Synchronize.
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

  // Drain the SDL2 event queue once. The main loop calls it every pass, and
  // so does MsgProc when the interpreter asks the host to catch up.
  Procedure SDLHost_PumpEvents;

  // Window, interpreter, main loop and shutdown. The program calls this and
  // nothing else.
  Procedure SDLHost_Run;

Var

  Main: TSDLMain = Nil;
  BASThread: TSpecBAS_Thread = Nil;
  Quitting: Boolean = False;
  InitTime: LongWord;
  ImgResource: Array of Byte;
  BaseTime: aFloat = 0;
  LastMouseX, LastMouseY: Integer;
  MouseInForm, AltDown, FormActivated: Boolean;
  AltChars: aString;
  CaptionString: String;
  MainCanResize: Boolean = True;
  PendingKeyInfo:  SP_KeyInfo;
  PendingKeyValid: Boolean = False;

implementation

Uses
  {$IFNDEF RUNTIMEONLY}SP_FPEditor, SP_ToolTipWindow, SP_BASICEditorHostUnit,{$ENDIF}
  SP_Display, SP_WindowMenuUnit, SP_PopUpMenuUnit, SP_BASICInterpreter,
  SP_BankFiling, SP_Interpret_PostFix, SP_AnsiStringlist, DynLibs,
  // Pictures are decoded and encoded through Free Pascal's own fcl-image.
  // There is no LCL here to supply TBitmap, TPortableNetworkGraphic,
  // TJPEGImage or TGIFImage.
  FPImage, FPReadPNG, FPReadBMP, FPReadJPEG, FPReadGIF, FPWritePNG, FPWriteBMP;

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
  If Quitting Then Exit;
  SDLB_GetClientSize(W, H);
  If (W <= 0) or (H <= 0) Then Exit;
  SetScaling(DISPLAYWIDTH, DISPLAYHEIGHT, W, H);
  DPtrBackup := DISPLAYPOINTER;
End;

Procedure TSDLMain.CreateGDIBitmap;
Begin
  // The device-independent bitmap this builds under Windows is the surface
  // StretchBlt draws from. The SDL2 build presents from the frame buffer
  // itself, and SetScaling allocates that.
End;

Procedure TLoadImageSync.Run;
Begin
  CB_Load_Image(FFilename, FError);
End;

// ---------------------------------------------------- interpreter thread

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

// SDL2's performance counter, which is monotonic and finer than a
// millisecond. Free Pascal 3.2.2 declares no clock_gettime on every target
// this build covers, and SDL_GetTicks counts whole milliseconds, which is
// too coarse to pace a frame with.
Function GetTicks: aFloat;
Begin
  Result := SDLB_Milliseconds - BaseTime;
End;

Procedure YieldProc(const ms: aFloat);
Begin

  SmartSleep(ms);
  LASTINKEYFRAME := FRAMES;

End;

Procedure MsgProc;
Begin

  // The interpreter thread calls this as well, and SDL2's event queue may
  // only be drained on the thread that owns the window.
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

  // Into window coordinates from SpecBAS's own.

  SDLB_WarpMouse(Round(ToX * ScaleMouseX), Round(ToY * ScaleMouseY));

End;

Procedure Quit;
Begin
  Quitting := True;
End;

Procedure SetWindowCaption;
Var
  s: aString;
Begin
  if WCAPTION <> '' Then
    s := WCAPTION
  Else
    s := aString(ChangeFileExt(ExtractFilename(ParamStr(0)), ''));
  CaptionString := String(s);
  SDLB_SetTitle(CaptionString);
End;

// The frames-per-second reading in the window title, which the Lazarus host
// refreshes from a TTimer. Nothing here has a timer, so the main loop calls
// this and the interval is kept here.
Const
  CaptionInterval = 250;

Var
  LastCaptionTime: aFloat = 0;

Procedure UpdateCaption;
Var
  s: String;
  CurTime: aFloat;
Begin
  CurTime := GetTicks;
  If (CurTime - LastCaptionTime) < CaptionInterval Then Exit;
  LastCaptionTime := CurTime;

  If WCAPTION = '' Then Begin
    GetOSDString;
    If AvgFrameTime > 0 Then
      s := Format('%.0f', [1000/AvgFrameTime])
    Else
      s := 'INF';
    SDLB_SetTitle(CaptionString + ' ' + String(BUILDSTR) + ' - ' + s + ' fps');
  End Else
    SDLB_SetTitle(String(WCAPTION));
End;

// -------------------------------------------------------------- pictures

// fcl-image decodes into a TFPCustomImage whose pixels carry sixteen bits a
// channel. SpecBAS's own ImgWidth, ImgHeight, ImgBpp, ImgStride, ImgPtr and
// ImgPalette are filled in from that here exactly as MainForm.pas fills them
// in from a decoded TBitmap, so SP_BankManager reads what it already
// expects whichever host decoded the picture.
Procedure LoadImage(Filename: aString; Var Error: TSP_ErrorCode);
Var
  FS:          TFileStream;
  MagicBuf:    Array[0..7] of Byte;
  FirstBytes:  aString;
  Ext:         aString;
  Img:         TFPMemoryImage;
  Reader:      TFPCustomImageReader;
  BmpBitCount: Word;
  X, Y, ci,
  ColCount,
  Idx:         Integer;
  Found,
  Decoded:     Boolean;
  ColMap:      Array[0..255] of LongWord;
  Clr:         TFPColor;
  Pixel:       LongWord;
  DPtr:        pByte;
Begin

  If Not FileExists(String(Filename)) Then Begin
    Error.Code := SP_ERR_FILE_MISSING;
    Exit;
  End;

  // Detect format from magic bytes - never trust the file extension
  FS := TFileStream.Create(String(Filename), fmOpenRead Or fmShareDenyNone);
  Try
    FS.Read(MagicBuf[0], 8);
  Finally
    FS.Free;
  End;
  SetLength(FirstBytes, 8);
  Move(MagicBuf[0], FirstBytes[1], 8);

  Ext := '';
  If Copy(FirstBytes, 1, 2) = 'BM'      Then Ext := '.bmp';
  If FirstBytes = #137'PNG'#13#10#26#10 Then Ext := '.png';
  If Copy(FirstBytes, 1, 3) = 'GIF'     Then Ext := '.gif';
  If Copy(FirstBytes, 1, 2) = #$FF#$D8  Then Ext := '.jpg';

  If Ext = '' Then Begin
    Error.Code := SP_ERR_UNSUPPORTED_IMAGE_FORMAT;
    Exit;
  End;

  ERRStr := Filename;

  ImgBpp  := 32;
  Decoded := True;

  Img := TFPMemoryImage.Create(0, 0);
  Try

    FS := TFileStream.Create(String(Filename), fmOpenRead Or fmShareDenyNone);
    Try

      Reader := Nil;
      Try
        Try

          If Ext = '.png' Then Begin

            Reader := TFPReaderPNG.Create;
            Reader.ImageRead(FS, Img);
            // Colour type 0 is greyscale and 3 is indexed; between them
            // they never carry more than 256 colours. The rest are true
            // colour. This is the IHDR field MainForm.pas reads to make the
            // same decision.
            If (TFPReaderPNG(Reader).ColorType In [0, 3]) And
               (TFPReaderPNG(Reader).BitDepth <= 8) Then
              ImgBpp := 8;

          End Else If Ext = '.bmp' Then Begin

            // fcl-image's BMP reader does not report the source depth, so
            // it comes from the file: biBitCount sits fourteen bytes into
            // the BITMAPINFOHEADER, which follows a fourteen-byte
            // BITMAPFILEHEADER.
            FS.Position := 28;
            FS.Read(BmpBitCount, 2);
            FS.Position := 0;
            If BmpBitCount <= 8 Then ImgBpp := 8;
            Reader := TFPReaderBMP.Create;
            Reader.ImageRead(FS, Img);

          End Else If Ext = '.jpg' Then Begin

            // JPEG has no palette support - always 32bpp
            Reader := TFPReaderJPEG.Create;
            Reader.ImageRead(FS, Img);

          End Else Begin // '.gif'

            // GIF is always palette/indexed - always 8bpp
            ImgBpp := 8;
            Reader := TFPReaderGIF.Create;
            Reader.ImageRead(FS, Img);

          End;

        Except
          Decoded := False;
        End;
      Finally
        Reader.Free;
      End;

    Finally
      FS.Free;
    End;

    If Not Decoded Then Begin
      Error.Code := SP_ERR_UNSUPPORTED_IMAGE_FORMAT;
      Exit;
    End;

    ImgWidth  := Img.Width;
    ImgHeight := Img.Height;

    If ImgBpp = 8 Then Begin

      // 8bpp output: extract palette and build index array from the decoded
      // true-colour pixels. fcl-image hands those back rather than the
      // source file's indices, exactly as the LCL canvas does on
      // MainForm.pas's own Free Pascal path, so the palette is recovered
      // the same way: collect the unique colours, then index against them.
      // A genuine palette image has no more than 256 of them.
      ColCount := 0;
      FillChar(ColMap, SizeOf(ColMap), 0);

      For Y := 0 To Img.Height - 1 Do
        For X := 0 To Img.Width - 1 Do Begin
          Clr := Img.Colors[X, Y];
          Pixel := ((Clr.red Shr 8) Shl 16) Or ((Clr.green Shr 8) Shl 8) Or (Clr.blue Shr 8);
          Found := False;
          For ci := 0 To ColCount - 1 Do
            If ColMap[ci] = Pixel Then Begin Found := True; Break; End;
          If Not Found And (ColCount < 256) Then Begin
            ColMap[ColCount] := Pixel;
            Inc(ColCount);
          End;
        End;

      For ci := 0 To ColCount - 1 Do Begin
        ImgPalette[ci].B := ColMap[ci] And $FF;
        ImgPalette[ci].G := (ColMap[ci] Shr 8) And $FF;
        ImgPalette[ci].R := (ColMap[ci] Shr 16) And $FF;
      End;

      SetLength(ImgResource, Img.Width * Img.Height);
      DPtr := @ImgResource[0];
      ImgPtr := DPtr;
      For Y := 0 To Img.Height - 1 Do
        For X := 0 To Img.Width - 1 Do Begin
          Clr := Img.Colors[X, Y];
          Pixel := ((Clr.red Shr 8) Shl 16) Or ((Clr.green Shr 8) Shl 8) Or (Clr.blue Shr 8);
          DPtr^ := 0; // default index 0 if not found (shouldn't happen)
          For ci := 0 To ColCount - 1 Do
            If ColMap[ci] = Pixel Then Begin DPtr^ := ci; Break; End;
          Inc(DPtr);
        End;
      ImgStride := Img.Width;

    End Else Begin

      // 32bpp output: one pixel is B, G, R, A, which is the frame buffer's
      // own order.
      SetLength(ImgResource, Img.Width * Img.Height * 4);
      DPtr := @ImgResource[0];
      ImgPtr := DPtr;
      For Y := 0 To Img.Height - 1 Do
        For X := 0 To Img.Width - 1 Do Begin
          Clr := Img.Colors[X, Y];
          DPtr^ := Clr.blue  Shr 8; Inc(DPtr);
          DPtr^ := Clr.green Shr 8; Inc(DPtr);
          DPtr^ := Clr.red   Shr 8; Inc(DPtr);
          DPtr^ := Clr.alpha Shr 8; Inc(DPtr);
        End;
      ImgStride := Img.Width * 4;

      // Patch alpha=0 to $FF for formats that have no alpha channel.
      // PNG alpha is preserved as-is (may have genuine transparent pixels).
      If (Ext = '.jpg') Or (Ext = '.bmp') Or (Ext = '.gif') Then Begin
        DPtr := @ImgResource[3]; // first alpha byte
        For Idx := 0 To Img.Width * Img.Height - 1 Do Begin
          If DPtr^ = 0 Then DPtr^ := $FF;
          Inc(DPtr, 4);
        End;
      End;

    End;

  Finally
    Img.Free;
  End;

End;

// The picture is written as a palette image carrying SpecBAS's own 256
// colours, with SpecBAS's own indices in the pixels. That is what the
// Lazarus host writes - MainForm.pas builds a pf8Bit bitmap and calls
// SetDIBColorTable - and it is what makes the file reload as an 8bpp
// graphic bank rather than a true-colour one.
//
// Pixels is therefore read as one palette index per pixel, as MainForm.pas
// reads it: the signature carries no depth alongside the data, so there is
// nothing to tell a 32bpp bank apart from an 8bpp one on either host.
Procedure SaveImage(Filename: aString; w, h: Integer; Pixels, Palette: pByte);
Var
  Ext:      aString;
  Img:      TFPMemoryImage;
  Writer:   TFPCustomImageWriter;
  Clr:      TFPColor;
  Row:      pByte;
  X, Y:     Integer;
Begin

  If (w <= 0) Or (h <= 0) Or (Pixels = Nil) Or (Palette = Nil) Then Exit;

  Ext := Lower(aString(ExtractFileExt(String(Filename))));
  If (Ext <> '.png') And (Ext <> '.bmp') Then Exit;

  If FileExists(String(Filename)) Then
    DeleteFile(String(Filename));

  Img := TFPMemoryImage.Create(w, h);
  Try

    Img.UsePalette := True;
    Img.Palette.Clear;
    For X := 0 To 255 Do Begin
      Clr.red   := Palette^ * $101; Inc(Palette);
      Clr.green := Palette^ * $101; Inc(Palette);
      Clr.blue  := Palette^ * $101; Inc(Palette, 2);
      Clr.alpha := alphaOpaque;
      Img.Palette.Add(Clr);
    End;

    Row := Pixels;
    For Y := 0 To h - 1 Do Begin
      For X := 0 To w - 1 Do
        Img.Pixels[X, Y] := (Row + X)^;
      Inc(Row, w);
    End;

    If Ext = '.png' Then Begin
      Writer := TFPWriterPNG.Create;
      TFPWriterPNG(Writer).UseAlpha  := False;
      // Without these two the writer emits sixteen bits a channel of true
      // colour for a picture that only ever had 256 colours in it.
      TFPWriterPNG(Writer).WordSized := False;
      TFPWriterPNG(Writer).Indexed   := True;
    End Else
      Writer := TFPWriterBMP.Create;

    Try
      Img.SaveToFile(String(Filename), Writer);
    Finally
      Writer.Free;
    End;

  Finally
    Img.Free;
  End;

End;

Procedure FreeImageResource;
Begin

  // Removes an image from memory after loading.

  SetLength(ImgResource, 0);

End;

// --------------------------------------------------------------- events

// Take DisplaySection on the owning thread without ever blocking on it
// alone.
//
// Delivering an event to a SpecBAS control needs this lock, and the
// interpreter thread holds it across SP_Display.SetScreen. Inside SetScreen
// the interpreter asks this thread for the window calls SP_SDL2Backend will
// only make here, and waits for them. A plain wait on the lock would leave
// each thread waiting for the other, so this wait runs the queue those calls
// arrive on. Nothing that reaches the queue takes DisplaySection itself, so
// servicing it from inside the wait cannot re-enter the lock.
Procedure EnterDisplaySection;
Begin
  While Not DisplaySection.TryEnter Do
    CheckSynchronize(1);
End;

Procedure HandleKeyDown(Const Ev: TSDL_Event);
Var
  Key: Word;
  k: Integer;
  kInfo: SP_KeyInfo;
Begin

  Key := SDL2_ScanCodeToKey(Ev.key.keysym.scancode);
  If Key = 0 Then Exit;

  If Key = K_PAUSE Then Begin // the BREAK key on PC keyboards always saves a screengrab.
    ScreenShot(False);
    Exit;
  End;

  kInfo.CanRepeat := True;
  kInfo.IsKey := True;
  kInfo.KeyChar := #0;
  kInfo.KeyCode := Key And $7F;
  kInfo.NextFrameTime := FRAMES;
  kInfo.WindowID := FocusedWindow;

  If Not SDL2_IsNonPrintingKey(Key) Then Begin
    // The character belongs to the SDL_TEXTINPUT event that follows, which
    // is the only thing that reads keyboard layouts, dead keys and input
    // methods correctly.
    //
    // A key held with Control is the exception. It is a shortcut rather
    // than typing, and no usable character event follows one: macOS sends
    // none at all once a shortcut modifier is down, and where one does
    // arrive it carries a control code, which is dropped further on. So the
    // character comes from the key itself. SDL2's keycode is the character
    // the layout puts on that physical key, which is the answer
    // MainForm.pas takes from GetCharFromVirtualKey, and it is what
    // SP_Components and the widgets read a shortcut from.
    If KEYSTATE[K_CONTROL] = 0 Then Begin
      PendingKeyInfo  := kInfo;
      PendingKeyValid := True;
      Exit;
    End;
    If (Ev.key.keysym.sym > 0) And (Ev.key.keysym.sym < 128) Then
      kInfo.KeyChar := aChar(Ev.key.keysym.sym);
  End;

  If Key = K_ALT Then Begin // ALT went down

    AltDown := True;
    AltChars := '';

  End Else Begin

    If AltDown Then Begin

      If Key in [K_NUMPAD0..K_NUMPAD9, K_0..K_9] Then Begin

        if Key in [K_NUMPAD0..K_NUMPAD9] Then
          k := Key - K_NUMPAD0
        else
          k := Key - K_0;

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

  End;

  If ControlsAreInUse Then Begin
    EnterDisplaySection;
    If ControlKeyEvent(kInfo.KeyChar, kInfo.KeyCode, True, kInfo.IsKey) Then Begin
      DisplaySection.Leave;
      Exit;
    End Else
      DisplaySection.Leave;
  End;

  SP_AddKey(kInfo);

End;

Procedure DeliverCharacter(C: aChar);
Var
  kInfo: SP_KeyInfo;
Begin

  If (C < ' ') or (C = #127) Then Exit;

  If PendingKeyValid Then Begin
    kInfo := PendingKeyInfo;
    PendingKeyValid := False;
  End Else Begin
    // A character with no key-down of its own: a paste, an input method, or
    // a string put in by another program. SpecBAS still wants a key code,
    // and for letters and digits that code is the upper-case character, so
    // the character supplies its own.
    kInfo.CanRepeat := True;
    kInfo.IsKey := True;
    kInfo.KeyCode := Ord(UpCase(Char(C))) and $7F;
    kInfo.NextFrameTime := FRAMES;
    kInfo.WindowID := FocusedWindow;
  End;

  kInfo.KeyChar := C;

  If ControlsAreInUse Then Begin
    EnterDisplaySection;
    If ControlKeyEvent(kInfo.KeyChar, kInfo.KeyCode, True, kInfo.IsKey) Then Begin
      DisplaySection.Leave;
      Exit;
    End Else
      DisplaySection.Leave;
  End;

  SP_AddKey(kInfo);

End;

Procedure HandleTextInput(Const Ev: TSDL_Event);
Var
  i: Integer;
  C: aChar;
Begin
  // One SDL_TEXTINPUT event may carry several characters: pasted text, an
  // input method committing a phrase, a string put in by another program.
  // Each byte becomes a key of its own.
  //
  // The field is UTF-8, and SpecBAS's character set is single-byte, so a
  // byte above 127 begins a sequence there is no room for and is dropped
  // rather than delivered as one meaningless character.
  For i := 0 To SDL_TEXTINPUTEVENT_TEXT_SIZE - 1 Do Begin
    C := aChar(Ev.text.text[i]);
    If C = #0 Then Break;
    If C < #128 Then
      DeliverCharacter(C);
  End;
  PendingKeyValid := False;
End;

Procedure HandleKeyUp(Const Ev: TSDL_Event);
Var
  Key: Word;
Begin

  Key := SDL2_ScanCodeToKey(Ev.key.keysym.scancode);
  If Key = 0 Then Exit;

  KEYSTATE[Key] := 0;
  cKEYSTATE[Key And $7F] := 0;        // always clear - can't be skipped
  ControlKeyEvent(#0, Key And $7F, False, True);
  SP_RemoveKey(Key And $7F);

  If AltDown And (Key = K_ALT) Then Begin
    AltDown := False;
    SP_RemoveKey(StringToInt(AltChars));
    AltChars := '';
  End;

End;

// The button that changed, for a button-down or button-up event, on the
// 1 (left) / 2 (right) / 4 (middle) bitmask SpecBAS uses everywhere.
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

// Every button currently held, on the same bitmask. SDL2's own mask bits do
// not sit in those positions, so they are read across one at a time.
Function ButtonStateMask(State: LongWord): Integer;
Begin
  Result := 0;
  If (State and SDL_BUTTON_LMASK) <> 0 Then Result := Result Or 1;
  If (State and SDL_BUTTON_RMASK) <> 0 Then Result := Result Or 2;
  If (State and SDL_BUTTON_MMASK) <> 0 Then Result := Result Or 4;
End;

// TestForWindowMenu takes a TShiftState, which is declared in the RTL's
// Classes unit rather than in the LCL. It reads ssLeft, ssRight and
// ssMiddle and nothing else, which is exactly what the bitmask carries.
Function ToShiftState(Shift: Integer): TShiftState;
Begin
  Result := [];
  If (Shift and 1) <> 0 Then Include(Result, ssLeft);
  If (Shift and 2) <> 0 Then Include(Result, ssRight);
  If (Shift and 4) <> 0 Then Include(Result, ssMiddle);
End;

Procedure HandleMouseMotion(Const Ev: TSDL_Event);
Var
  Win: Pointer;
  p: TPoint;
  Shift, LMenu, LItem, Btn, X, Y, tX, tY, ID, Dx, Dy, NewX, NewY, NewW, NewH: Integer;
  Handled: Boolean;
  sPtr: pSP_Window_Info;
  BankIdx: Integer;
  Err: TSP_ErrorCode;
Begin

  X := Ev.motion.x;
  Y := Ev.motion.y;

  If ((X = LastMouseX) And (Y = LastMouseY)) or SIZINGMAIN or (ScaleMouseX = 0) Then Exit;

  Handled := False;
  LastMouseX := X;
  LastMouseY := Y;
  If ScaleMouseX > 0 Then
    X := Round(X / ScaleMouseX);
  If ScaleMouseY > 0 Then
    Y := Round(Y / ScaleMouseY);
  If (X = LastScaledMouseX) And (Y = LastScaledMouseY) Then Exit;
  LastScaledMouseX := X;
  LastScaledMouseY := Y;

  Shift := ButtonStateMask(Ev.motion.state);
  Btn := Shift;
  M_DELTAX := X - MOUSEX;
  M_DELTAY := Y - MOUSEY;
  MOUSEX := X;
  MOUSEY := Y;

  // Origin shifted by the pointer's hotspot, which is where the image is
  // actually drawn.
  SP_SetDirtyRect(Min(MOUSEX, MOUSESTOREX) - MOUSEHSX, Min(MOUSEY, MOUSESTOREY) - MOUSEHSY,
                  Max(MOUSEX, MOUSESTOREX) - MOUSEHSX + MOUSEW, Max(MOUSEY, MOUSESTOREY) - MOUSEHSY + MOUSEH);
  SP_NeedDisplayUpdate := True;

  // Decorated window drag/resize
  For BankIdx := 0 To Length(SP_BankList) -1 Do Begin
    If SP_BankList[BankIdx]^.DataType <> SP_WINDOW_BANK Then Continue;
    sPtr := @SP_BankList[BankIdx].Info[0];
    If sPtr^.Dragging Then Begin
      Err.Code := SP_ERR_OK;
      SP_MoveWindow(sPtr^.ID, MOUSEX - sPtr^.DragOffX, MOUSEY - sPtr^.DragOffY, Err);
      SP_NeedDisplayUpdate := True;
      Handled := True;
      Break;
    End;
    If sPtr^.Resizing Then Begin
      DX   := MOUSEX - sPtr^.ResizeMouseX;
      DY   := MOUSEY - sPtr^.ResizeMouseY;
      NewX := sPtr^.ResizeOrigX;
      NewY := sPtr^.ResizeOrigY;
      NewW := sPtr^.ResizeOrigW;
      NewH := sPtr^.ResizeOrigH;
      If sPtr^.ResizeEdge And 1 <> 0 Then Begin  // left edge
        NewX := sPtr^.ResizeOrigX + DX;
        NewW := sPtr^.ResizeOrigW - DX;
      End;
      If sPtr^.ResizeEdge And 2 <> 0 Then         // right edge
        NewW := sPtr^.ResizeOrigW + DX;
      If sPtr^.ResizeEdge And 4 <> 0 Then Begin   // top edge
        NewY := sPtr^.ResizeOrigY + DY;
        NewH := sPtr^.ResizeOrigH - DY;
      End;
      If sPtr^.ResizeEdge And 8 <> 0 Then         // bottom edge
        NewH := sPtr^.ResizeOrigH + DY;
      // clamp to minimum size
      If NewW < 40 Then Begin
        NewW := 40;
        If sPtr^.ResizeEdge And 1 <> 0 Then
          NewX := sPtr^.ResizeOrigX + sPtr^.ResizeOrigW - 40;
      End;
      If NewH < sPtr^.CaptionHeight + 10 Then Begin
        NewH := sPtr^.CaptionHeight + 10;
        If sPtr^.ResizeEdge And 4 <> 0 Then
          NewY := sPtr^.ResizeOrigY + sPtr^.ResizeOrigH - (sPtr^.CaptionHeight + 10);
      End;
      Err.Code := SP_ERR_OK;
      If (NewX <> sPtr^.Left) Or (NewY <> sPtr^.Top) Then
        SP_MoveWindow(sPtr^.ID, NewX, NewY, Err);
      If (NewW <> sPtr^.Width) Or (NewH <> sPtr^.Height) Then
        SP_ResizeWindow(sPtr^.ID, NewW, NewH, -1, SPFULLSCREEN, False, Err);
      If sPtr^.ID = SCREENBANK Then
        SP_WindowResizeFlag := sPtr^.ID;
      SP_NeedDisplayUpdate := True;
      Handled := True;
      Break;
    End;
  End;

  If (CURMENU <> -1) And ((Shift and 2) <> 0) And MENUSHOWING Then Begin

    LMenu := LASTMENU;
    LItem := LASTMENUITEM;
    SP_SetMenuSelection(X, Y, CURMENU);
    SP_InvalidateWholeDisplay;
    SP_NeedDisplayUpdate := True;

    If (LMenu <> LASTMENU) or (LItem <> LASTMENUITEM) Then
      MENU_HIGHLIGHTFLAG := True;

  End Else

    If (Assigned(CaptureControl) or MOUSEVISIBLE) And Not SIZINGMAIN Then Begin

      // Now check for controls under the mouse

      Handled := False;
      If DisplaySection.TryEnter Then Begin

        tX := X; tY := Y;
        {$IFNDEF RUNTIMEONLY}
        If TipWindowID <> -1 Then CheckForTip(tx, ty);
        {$ENDIF}
        Win := WindowAtPoint(tX, tY, ID);

        If Assigned(Win) Then Begin
          Win := ControlAtPoint(Win, tX, tY);
          If Not Assigned(Win) Or (MouseControl <> pSP_BaseComponent(Win)^) Then
            If Assigned(MouseControl) And SP_CanInteract(MouseControl) Then
              MouseControl.MouseLeave;
        End;
        If Assigned(CaptureControl) And CaptureControl.Visible Then Begin
          p := CaptureControl.ScreenToClient(Point(x, y));
          If SP_CanInteract(CaptureControl) Then Begin
            CaptureControl.PreMouseMove(p.x, p.y, Btn);
            Handled := True;
          End;
        End Else Begin
          If Assigned(Win) And pSP_BaseComponent(Win)^.Enabled Then Begin
            If MouseControl <> pSP_BaseComponent(Win)^ Then Begin
              MouseControl := pSP_BaseComponent(Win)^;
              p := MouseControl.ScreenToClient(Point(tX, tY));
              If SP_CanInteract(MouseControl) Then
                MouseControl.MouseEnter(p.X, p.Y);
            End;
            If SP_CanInteract(pSP_BaseComponent(Win)^) Then
              pSP_BaseComponent(Win)^.PreMouseMove(tX, tY, Btn);
            Handled := True;
          End Else
            If Assigned(MouseControl) And SP_CanInteract(MouseControl) Then
              MouseControl.MouseLeave;
        End;

        // Released inside the guard that took it. A failed TryEnter means
        // another thread holds the lock, and releasing one this thread does
        // not own is a pthread error, which the runtime turns into an
        // exception no caller here catches.
        DisplaySection.Leave;

      End;

    End;

    // Fall through to allow user code to get mousemove events

  If Not Handled Then Begin
    M_MOVEFLAG := True;
    MOUSEBTN := Btn;
  End;

End;

// SDL_CaptureMouse keeps events arriving while a button is held even after
// the pointer leaves the window, which is what SetCapture does for the
// Lazarus host. SpecBAS's own CaptureControl, further down, is a different
// thing with a similar name.
Procedure HandleMouseDown(Const Ev: TSDL_Event);
Var
  mi: SP_MenuSelection;
  Win: Pointer;
  Shift, Btn, ID, X, Y: Integer;
  WShift: TShiftState;
  p: TPoint;
  Handled: Boolean;
  sPtr: pSP_Window_Info;
  Edge: Integer;
Begin

  If ScaleMouseX > 0 Then Begin

    SDL_CaptureMouse(SDL_TRUE);

    X := Round(Ev.button.x / ScaleMouseX);
    Y := Round(Ev.button.y / ScaleMouseY);

    MOUSEX := X;
    MOUSEY := Y;
    Shift := ButtonMask(Ev);
    Btn := Shift;

    // Menus take precedence over everything

    If CURMENU <> -1 Then Begin

      If (Shift and 2) <> 0 Then
        If Not (MENUSHOWING Or MENUBLOCK) Then Begin

          SP_DisplayMainMenu;
          SP_SetMenuSelection(X, Y, CURMENU);
          SP_InvalidateWholeDisplay;
          MENU_SHOWFLAG := True;
          Exit;

        End;

      If (Shift and 1) <> 0 Then
        If MENUSHOWING Then Begin

          SP_SetMenuSelection(X, Y, CURMENU);
          mi := SP_WhichItem(X, Y);
          LASTMENU := mi.MenuID;
          LASTMENUITEM := mi.ItemIdx;
          SP_DisplayMainMenu;
          SP_InvalidateWholeDisplay;
          Refresh_Display;
          MENUBLOCK := True;

          MENU_HIDEFLAG := True;
          Exit;

        End;

    End;

    // Now check for controls under the mouse
    // *** TO DO make windowmenu appear when right-clicking if not visible ***

    Handled := False;
    {$IFNDEF RUNTIMEONLY}
    CloseTipWindow;
    {$ENDIF}

    If ForceCapture Then Begin
      If CaptureControl.CanFocus Then
        CaptureControl.SetFocus(True);
      p := CaptureControl.ScreenToClient(Point(X, Y));
      If SP_CanInteract(CaptureControl) Then
        SP_BaseComponent(CaptureControl).MouseDown(SP_BaseComponent(CaptureControl), p.X, p.Y, Btn);
      Handled := True;
    End Else Begin
      Win := WindowAtPoint(X, Y, ID);  // X, Y become window-relative after this
      If Assigned(Win) Then Begin
        sPtr := pSP_Window_Info(Win);
        If sPtr^.Decorated And ((Shift and 1) <> 0) Then Begin
          Edge := 0;
          If sPtr^.Resizable Then Begin
            If X < 2                     Then Edge := Edge Or 1;
            If X >= sPtr^.Width  - 2     Then Edge := Edge Or 2;
            If Y < 2                     Then Edge := Edge Or 4;
            If Y >= sPtr^.Height - 2     Then Edge := Edge Or 8;
            If (X >= sPtr^.Width - 8) And
               (Y >= sPtr^.Height - 8)   Then Edge := Edge Or 10;
          End;
          If (Edge = 0) And sPtr^.Draggable And (Y < sPtr^.CaptionHeight) Then Begin
            sPtr^.Dragging  := True;
            sPtr^.DragOffX  := MOUSEX - sPtr^.Left;
            sPtr^.DragOffY  := MOUSEY - sPtr^.Top;
            SwitchFocusedWindow(ID);
            Handled := True;
          End Else If Edge <> 0 Then Begin
            sPtr^.Resizing    := True;
            sPtr^.ResizeEdge  := Edge;
            sPtr^.ResizeOrigX := sPtr^.Left;
            sPtr^.ResizeOrigY := sPtr^.Top;
            sPtr^.ResizeOrigW := sPtr^.Width;
            sPtr^.ResizeOrigH := sPtr^.Height;
            sPtr^.ResizeMouseX := MOUSEX;
            sPtr^.ResizeMouseY := MOUSEY;
            SwitchFocusedWindow(ID);
            Handled := True;
          End;
        End;
        If Not Handled Then Begin
          WShift := ToShiftState(Shift);
          If not TestForWindowMenu(Nil, WShift) Then Begin
            If Not (SYSTEMSTATE in [SS_EDITOR, SS_DIRECT, SS_EVALUATE]) and (MODALWINDOW = -1) Then
              SwitchFocusedWindow(ID); // The editor handles this.
            Win := ControlAtPoint(Win, X, Y);
            If Assigned(Win) Then Begin
              if pSP_BaseComponent(Win)^.Enabled Then Begin
                CaptureControl := pSP_BaseComponent(Win)^;
                If CaptureControl.CanFocus Then
                  CaptureControl.SetFocus(True);
                If SP_CanInteract(CaptureControl) Then
                  SP_BaseComponent(CaptureControl).MouseDown(SP_BaseComponent(CaptureControl), X, Y, Btn);
                Handled := True;
              End;
            End Else Begin
              If Assigned(CaptureControl) And SP_CanInteract(CaptureControl) Then
                SP_BaseComponent(CaptureControl).MouseDown(SP_BaseComponent(CaptureControl), X, Y, Btn);
              If Assigned(FocusedControl) And (MODALWINDOW = -1) And ((FocusedControl Is SP_PopUpMenu) or (FocusedControl is SP_WindowMenu)) Then
                FocusedControl.SetFocus(False);
            End;
          End;
        End;
      End;
    End;

    // Finally, pass the mouse event to the interpreter

    If Not Handled Then Begin
      MOUSEBTN := Btn;
      M_DOWNFLAG := True;
    End;

  End;

End;

Procedure HandleMouseUp(Const Ev: TSDL_Event);
Var
  mi: SP_MenuSelection;
  Win: Pointer;
  Shift, Btn, ID, X, Y, BankIdx: Integer;
  WShift: TShiftState;
  p: TPoint;
  Handled: Boolean;
  sPtr: pSP_Window_Info;
Begin

  SDL_CaptureMouse(SDL_FALSE);

  If ScaleMouseX = 0 Then Exit;
  X := Round(Ev.button.x / ScaleMouseX);
  Y := Round(Ev.button.y / ScaleMouseY);

  MOUSEX := X;
  MOUSEY := Y;

  Shift := ButtonMask(Ev);
  Btn := Shift;

  For BankIdx := 0 To Length(SP_BankList) -1 Do Begin
    If SP_BankList[BankIdx]^.DataType <> SP_WINDOW_BANK Then Continue;
    sPtr := @SP_BankList[BankIdx].Info[0];
    If sPtr^.Dragging Or sPtr^.Resizing Then Begin
      sPtr^.Dragging := False;
      sPtr^.Resizing := False;
      SP_NeedDisplayUpdate := True;
    End;
  End;

  // Menus take precedence

  If (CURMENU <> -1) And (Not ((Shift and 2) <> 0)) And MENUSHOWING Then Begin

    SP_SetMenuSelection(X, Y, CURMENU);
    mi := SP_WhichItem(X, Y);
    LASTMENU := mi.MenuID;
    LASTMENUITEM := mi.ItemIdx;
    SP_DisplayMainMenu;
    SP_InvalidateWholeDisplay;
    SP_NeedDisplayUpdate := True;

    MENU_HIDEFLAG := True;

  End Else Begin

    // Now check for controls under the mouse

    WShift := ToShiftState(Shift);
    Handled := TestForWindowMenu(Nil, WShift);
    If Assigned(CaptureControl) Then Begin
      p := CaptureControl.ScreenToClient(Point(x, y));
      If SP_CanInteract(CaptureControl) Then
        CaptureControl.MouseUp(CaptureControl, p.x, p.y, Btn);
      If Not ForceCapture Then
        CaptureControl := Nil;
      Handled := True;
    End Else Begin
      Win := WindowAtPoint(X, Y, ID);
      If Assigned(Win) Then Begin
        Win := ControlAtPoint(Win, X, Y);
        If Assigned(Win) And pSP_BaseComponent(Win)^.Enabled And SP_CanInteract(pSP_BaseComponent(Win)^) Then Begin
          pSP_BaseComponent(Win)^.MouseUp(pSP_BaseComponent(Win)^, X, Y, Btn);
          Handled := True;
        End;
      End;
    End;

    // Finally, pass the mouse event to the interpreter

    MOUSEBTN := MOUSEBTN And Not Btn;
    If Not Handled Then Begin
      M_UPFLAG := True;
    End;

  End;

  MENUBLOCK := (Shift and 2) <> 0;

End;

Procedure DoMouseWheelDown(Shift: Integer);
Var
  p: TPoint;
  Win: Pointer;
  cp: pSP_BaseComponent;
  Ctrl: SP_BaseComponent;
  X, Y, Btn, ID: Integer;
  Handled: Boolean;
Begin

  X := MOUSEX;
  Y := MOUSEY;
  Btn := Shift;

  Handled := False;
  EnterDisplaySection;

  If Assigned(CaptureControl) Then Begin
    p := CaptureControl.ScreenToClient(Point(x, y));
    CaptureControl.MouseMove(CaptureControl, p.x, p.y, Btn);
  End Else Begin
    Win := WindowAtPoint(X, Y, ID);
    If Assigned(Win) Then Begin
      cp := ControlAtPoint(Win, X, Y);
      If Assigned(cp) Then Begin
        Ctrl := cp^;
        While Assigned(Ctrl) And Not Handled Do Begin
          Ctrl.MouseWheel(Ctrl, X, Y, Btn, 1, Handled);
          If Not Handled Then
            If Ctrl.fParentType = spWindow Then
              Ctrl := Nil
            Else
              Ctrl := Ctrl.GetParentControl;
        End;
      End;
    End;
  End;

  DisplaySection.Leave;

  If Not Handled Then Begin
    M_WHEELDNFLAG := True;
    Inc(MOUSEWHEEL);
  End;

End;

Procedure DoMouseWheelUp(Shift: Integer);
Var
  p: TPoint;
  Win: Pointer;
  cp: pSP_BaseComponent;
  Ctrl: SP_BaseComponent;
  X, Y, Btn, ID: Integer;
  Handled: Boolean;
Begin

  X := MOUSEX;
  Y := MOUSEY;
  Btn := Shift;

  Handled := False;
  EnterDisplaySection;

  If Assigned(CaptureControl) Then Begin
    p := CaptureControl.ScreenToClient(Point(x, y));
    CaptureControl.MouseMove(CaptureControl, p.x, p.y, Btn);
  End Else Begin
    Win := WindowAtPoint(X, Y, ID);
    If Assigned(Win) Then Begin
      cp := ControlAtPoint(Win, X, Y);
      If Assigned(cp) Then Begin
        Ctrl := cp^;
        While Assigned(Ctrl) And not Handled Do Begin
          Ctrl.MouseWheel(Ctrl, X, Y, Btn, -1, Handled);
          If Not Handled Then
            If Ctrl.fParentType = spWindow Then
              Ctrl := Nil
            Else
              Ctrl := Ctrl.GetParentControl;
        End;
      End;
    End;
  End;

  DisplaySection.Leave;

  If Not Handled Then Begin
    M_WHEELUPFLAG := True;
    Dec(MouseWheel);
  End;

End;

// SDL2 reports one signed scroll amount where the LCL splits the wheel into
// an up handler and a down handler, so the sign picks between the two.
// Positive is away from the user, which is the direction the LCL routes to
// OnMouseWheelUp; a flipped direction (natural scrolling) reverses it.
// SDL_MOUSEWHEEL carries no held-button state of its own, so that is asked
// for separately.
Procedure HandleMouseWheel(Const Ev: TSDL_Event);
Var
  Delta: Integer;
  Shift: Integer;
Begin
  Delta := Ev.wheel.y;
  If Ev.wheel.direction = SDL_MOUSEWHEEL_FLIPPED Then Delta := -Delta;
  If Delta = 0 Then Exit;

  Shift := ButtonStateMask(SDL_GetMouseState(Nil, Nil));

  If Delta > 0 Then
    DoMouseWheelUp(Shift)
  Else
    DoMouseWheelDown(Shift);
End;

{$IFNDEF RUNTIMEONLY}
Procedure HandleDropFile(Const Name: String);
Var
  sl: TAnsiStringList;
  paste, s: aString;
  i: Integer;
Begin
  sl := TAnsiStringList.Create;
  Try
    sl.LoadFromHost(Name);
    Paste := '';
    If sl.Count > 0 Then Begin
      if sl[0] = 'ZXASCII' Then Begin
        for i := 0 To sl.Count -1 Do Begin
          s := aString(sl[i]);
          If (Copy(s, 1, 7) <> 'ZXASCII') and (Copy(s, 1, 4) <> 'AUTO') and (Copy(s, 1, 4) <> 'PROG') and (Copy(s, 1, 7) <> 'CHANGED') Then
            paste := paste + s + #13#10;
        End;
      End;
      FPBASICEditor.SetFocus(True);
      FPBASICEditor.InsertText(paste);
      FPBASICEditor.EnsureCursorVisible;
      FPBASICEditor.Paint;
    end;
  Finally
    sl.Free;
  End;
End;
{$ENDIF}

Procedure SDLHost_PumpEvents;
Var
  Ev: TSDL_Event;
Begin
  While SDL_PollEvent(@Ev) = 1 Do
    Case Ev.type_ of

      SDL_QUITEV:
        Quit;

      SDL_KEYDOWN:
        // SpecBAS repeats a held key from its own frame clock, in
        // SP_GetNextKey, so the platform's repeats are dropped here.
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

      SDL_MOUSEWHEEL:
        HandleMouseWheel(Ev);

      SDL_DROPFILE:
        Begin
          {$IFNDEF RUNTIMEONLY}
          HandleDropFile(String(AnsiString(Ev.drop.file_)));
          {$ENDIF}
          SDL_free(Ev.drop.file_);
        End;

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

// ----------------------------------------------------- start and finish

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

  MOUSEVISIBLE := FALSE;

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
      if Copy(s, 1, 1) <> '-' then Begin
        if FileExists(s) then Begin
          PARAMS.Add(aString(s));
          Inc(PCOUNT);
        End;
      End Else Begin
        PARAMS.Add(aString(s));
        Inc(PCOUNT);
      End;
    End;

    dir := GetCurrentDir;
    If (PCOUNT = 0) And FileExists(dir + PathDelim + 'autorun') Then Begin
      PCOUNT := 1;
      PARAMS.Add(aString(dir)+ PathDelim + 'autorun');
    End;

  End;

  BaseTime := SDLB_Milliseconds;
  InitTime := Round(GetTicks);

  If Not PAYLOADPRESENT Then Begin

    // The project's version, from the same place the Windows build takes
    // it: the VERSIONINFO in src/SpecBAS.rc. There is no version resource
    // to read back at run time here, so build-sdl2/Makefile reads that file
    // and writes SpecBAS_Version.inc.
    BUILDSTR := {$INCLUDE SpecBAS_Version.inc};
    {$IFDEF DEBUG}
      BUILDSTR := BUILDSTR + ' [Debug]';
    {$ENDIF}

    // Set the HOME folder - if we're loading a parameter file, extract the
    // directory and set that as HOMEFOLDER

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

  SDLB_SetTitle(CaptionString + String(BuildStr));

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

  // Initialise callbacks

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

  // Start graphics server

  SP_SetFPS(GetScreenRefreshrate);
  SP_InitialGFXSetup(ScrWidth, ScrHeight, False);
  SP_GetMonitorMetrics;
  Main.DoResizeMain((REALSCREENWIDTH - Main.Width) Div 2,
                    (REALSCREENHEIGHT - Main.Height) Div 2,
                    Main.Width, Main.Height);

  WINLEFT := Main.Left;
  WINTOP := Main.Top;

  // Launch the interpreter

  SP_CLS(CPAPER);
  EDITLINE := '';
  CURSORPOS := 0;
  CURSORCHAR := 32;
  SYSTEMSTATE := SS_IDLE;

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

  While InterpreterThreadAlive Do Begin
    // The interpreter thread may be parked on a window call this thread has
    // to make before it can finish. See SDLHost_Run's loop.
    CheckSynchronize;
    CB_YIELD(1);
  End;

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

  DisplaySection.Enter;
  SetScreenResolution(OrgWidth, OrgHeight, False);
  DisplaySection.Leave;

  SP_FinalizeThreadVars;

End;

Procedure SDLHost_Run;
Begin

  If Not SDLB_Start('SpecBAS', 800, 480) Then Begin
    WriteLn(StdErr, 'SpecBAS: SDL2 would not start: ', SDL_GetError);
    Halt(1);
  End;

  SDL_EventState(SDL_DROPFILE, SDL_ENABLE);

  Main := TSDLMain.Create;
  Main.Handle := 0;

  Try
    HostCreate;

    While Not (Quitting or QUITMSG) Do Begin
      SDLHost_PumpEvents;
      // Two things the interpreter thread cannot do for itself arrive
      // through TThread.Synchronize, which parks the call on this thread's
      // queue and waits for it: the host's picture loader and every window
      // call in SP_SDL2Backend. Something here has to run that queue or the
      // wait never ends. The LCL's own idle handler does it in the Lazarus
      // build; here the main loop does it.
      CheckSynchronize;
      If MainCanResize Then
        FrameLoop;
      UpdateCaption;
    End;

    HostDestroy;
  Finally
    FreeAndNil(Main);
    SDLB_Stop;
  End;

End;

end.
