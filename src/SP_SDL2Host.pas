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
  SP_BankFiling, SP_Interpret_PostFix, SP_MenuActions, DynLibs,
  // LoadImage/SaveImage decode and encode through Free Pascal's own
  // fcl-image, per SPX-011 - never SDL2_image, and there is no LCL here to
  // supply Graphics/TBitmap/TPortableNetworkGraphic. This Free Pascal
  // install ships readers for all four formats MainForm.pas recognises but
  // a writer only for PNG and BMP, not GIF; SaveImage below reflects that.
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

// Free Pascal's own fcl-image decodes into a TFPCustomImage of 16-bit-per-
// channel TFPColor pixels. SpecBAS's own globals - ImgWidth, ImgHeight,
// ImgBpp, ImgStride, ImgPtr and ImgPalette, all declared in SP_Graphics.pas
// - are set from that here the same way MainForm.pas's LoadImage sets them
// from a decoded TBitmap, so SP_BankManager's IntLoadImage and
// SP_New_GraphicC read exactly what they already expect no matter which
// host decoded the picture.
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

  // Detect the format from its magic bytes, exactly as MainForm.pas's
  // LoadImage does - a file arriving through SpecBAS's own filing system
  // may carry any extension, or none, so the extension itself is never
  // trusted. Unlike MainForm.pas, nothing here needs the file renamed to
  // match: the reader class below is chosen directly from Ext rather than
  // through an extension-dispatching loader.
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
            // ColorType 0 (greyscale) and 3 (indexed) never carry more than
            // 256 distinct colours between them; the rest always decode to
            // a full 32bpp picture. This is the same IHDR field
            // MainForm.pas reads to make the same decision.
            If (TFPReaderPNG(Reader).ColorType In [0, 3]) And
               (TFPReaderPNG(Reader).BitDepth <= 8) Then
              ImgBpp := 8;

          End Else If Ext = '.bmp' Then Begin

            // fcl-image's BMP reader does not expose the source bit depth
            // itself, so it is read directly off the BITMAPINFOHEADER: 14
            // bytes of BITMAPFILEHEADER, then the biBitCount field 14
            // bytes into BITMAPINFOHEADER.
            FS.Position := 28;
            FS.Read(BmpBitCount, 2);
            FS.Position := 0;
            If BmpBitCount <= 8 Then ImgBpp := 8;
            Reader := TFPReaderBMP.Create;
            Reader.ImageRead(FS, Img);

          End Else If Ext = '.jpg' Then Begin

            // JPEG carries no palette and no alpha channel - always 32bpp.
            Reader := TFPReaderJPEG.Create;
            Reader.ImageRead(FS, Img);

          End Else Begin // '.gif'

            // GIF is always palette/indexed.
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

      // fcl-image, like the LCL canvas MainForm.pas's own FPC path draws
      // onto, hands back true-colour pixels rather than the source file's
      // own palette indices, so a palette is re-derived here by
      // uniquifying the decoded colours - the same two-pass scheme
      // MainForm.pas uses on its FPC path.
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

      // 32bpp: bytes come out B,G,R,A per pixel, matching the frame
      // buffer's own byte order (SP_Display.pas uploads it as GL_BGRA).
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

      // A format with no alpha channel of its own decodes fully opaque
      // already - fcl-image's readers set every TFPColor.alpha to
      // alphaOpaque when the source has none - but patching any stray
      // zero byte here is cheap insurance, the same safety net
      // MainForm.pas applies explicitly for jpg/bmp. PNG alpha is left
      // exactly as decoded, since a PNG may carry genuine transparency.
      If (Ext = '.jpg') Or (Ext = '.bmp') Then Begin
        DPtr := @ImgResource[3];
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

// The inverse of LoadImage, and bound by the same signature SpecBAS calls
// it through everywhere - SP_Interpret_PostFix's SCREEN SAVE and GRAPHIC
// SAVE both pass a screen or a graphic bank's raw pixels and its palette
// with no depth of its own alongside them. Pixels is therefore always read
// as one palette index per pixel here, exactly as MainForm.pas's SaveImage
// reads it: that signature carries no way to tell a 32bpp bank's data
// apart from an 8bpp one, on either host.
Procedure SaveImage(Filename: aString; w, h: Integer; Pixels, Palette: pByte);
Var
  Ext:      aString;
  Img:      TFPMemoryImage;
  Writer:   TFPCustomImageWriter;
  Pal,
  PalEntry: pTP_Colour;
  Clr:      TFPColor;
  Row:      pByte;
  PIdx:     Byte;
  X, Y:     Integer;
Begin

  If (w <= 0) Or (h <= 0) Or (Pixels = Nil) Or (Palette = Nil) Then Exit;

  Ext := Lower(aString(ExtractFileExt(String(Filename))));

  // fcl-image on this Free Pascal install ships no GIF writer - there is an
  // FPReadGIF but no FPWriteGIF - and .gif is one of the three extensions
  // MainForm.pas's SaveImage accepts. Refusing it here is honest; writing
  // a renamed PNG in its place would not be.
  If (Ext <> '.png') And (Ext <> '.bmp') Then Exit;

  If FileExists(String(Filename)) Then
    DeleteFile(String(Filename));

  Pal := pTP_Colour(Palette);

  Img := TFPMemoryImage.Create(w, h);
  Try

    Row := Pixels;
    For Y := 0 To h - 1 Do Begin
      For X := 0 To w - 1 Do Begin
        PIdx := (Row + X)^;
        PalEntry := Pal;
        Inc(PalEntry, PIdx);
        Clr.red   := PalEntry^.R * $101;
        Clr.green := PalEntry^.G * $101;
        Clr.blue  := PalEntry^.B * $101;
        Clr.alpha := alphaOpaque;
        Img.Colors[X, Y] := Clr;
      End;
      Inc(Row, w);
    End;

    If Ext = '.png' Then Begin
      Writer := TFPWriterPNG.Create;
      TFPWriterPNG(Writer).UseAlpha := False;
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
  //
  // Ctrl held is the exception, because the key press is then a shortcut
  // and not typing, and no usable character event follows one: macOS sends
  // none at all, and where one does arrive it carries a control code, which
  // is dropped. So the character comes from the key instead. SDL's keycode
  // is the character the current layout puts on that physical key, which is
  // the same answer MainForm.pas takes from GetCharFromVirtualKey, and it
  // is what SP_Components and the widgets expect: they read the shortcut
  // from the lower-case letter.
  If Not SDL2_IsNonPrintingKey(VK) Then Begin
    If KEYSTATE[K_CONTROL] = 0 Then Begin
      PendingKeyInfo  := kInfo;
      PendingKeyValid := True;
      Exit;
    End;
    If (Ev.key.keysym.sym > 0) And (Ev.key.keysym.sym < 128) Then
      kInfo.KeyChar := aChar(Ev.key.keysym.sym);
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

Procedure DeliverCharacter(C: aChar);
Var
  kInfo: SP_KeyInfo;
Begin
  If (C < ' ') or (C = #127) Then Exit;

  If PendingKeyValid Then Begin
    // The key-down event that started this character is waiting for it.
    kInfo := PendingKeyInfo;
    PendingKeyValid := False;
  End Else Begin
    // A character with no key-down of its own: a paste, an input method, or
    // a whole string injected at once. SpecBAS still wants a key code, and
    // for letters and digits the virtual-key code is the upper-case
    // character, so the character supplies its own.
    kInfo.KeyCode := Ord(UpCase(Char(C))) and $7F;
    kInfo.NextFrameTime := FRAMES;
    kInfo.Repeating := False;
    kInfo.CanRepeat := True;
    kInfo.IsKey := True;
    kInfo.WindowID := FocusedWindow;
  End;

  kInfo.KeyChar := C;

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
  i: Integer;
  C: aChar;
Begin
  // SDL_TEXTINPUT is the only event that carries a typed character, and one
  // event may carry several: text pasted in, an input method committing a
  // phrase, or a whole string injected by another program. Each byte is
  // delivered as its own key.
  //
  // The field is UTF-8. SpecBAS's character set is single-byte, so anything
  // above 127 is the first byte of a sequence it has no room for and is
  // dropped rather than delivered as mojibake.
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

// MainForm.pas keeps these as TMain fields. They dedupe motion events at
// the raw window-pixel resolution, before SP_Display.pas's own
// LastScaledMouseX/Y dedupe the same events again at the scaled resolution.
Var
  LastMouseX: Integer = 0;
  LastMouseY: Integer = 0;

// The button that changed, for a button-down or button-up event: SDL's
// SDL_BUTTON_LEFT/RIGHT/MIDDLE constants (1/2/3) read onto the 1 (left) / 2
// (right) / 4 (middle) bitmask SpecBAS uses everywhere else. FormMouseDown
// built the equivalent value out of Shift, and FormMouseUp out of a Case on
// its own Button parameter; both come out the same, so this one function
// serves both ported handlers below.
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

// The full set of currently-held buttons, for a motion event (Ev.motion.state)
// or a wheel event (queried separately, since SDL_MOUSEWHEEL carries no
// button state of its own). SDL's own LMASK/RMASK/MMASK bits land on
// different positions than ButtonMask's single-button result, so this maps
// them onto the same 1/2/4 bitmask independently.
Function ButtonStateMask(State: LongWord): Integer;
Begin
  Result := 0;
  If (State and SDL_BUTTON_LMASK) <> 0 Then Result := Result Or 1;
  If (State and SDL_BUTTON_RMASK) <> 0 Then Result := Result Or 2;
  If (State and SDL_BUTTON_MMASK) <> 0 Then Result := Result Or 4;
End;

// TestForWindowMenu (SP_Components.pas) takes a TShiftState. That type is
// declared in the RTL's own Classes unit, not in the LCL, so it is honestly
// available here. It only ever inspects ssLeft, ssRight and ssMiddle — the
// same three bits this file tracks as a plain Integer — so this rebuilds a
// genuine TShiftState carrying just those three bits. No keyboard modifiers
// are carried, because none of the ported handlers below tracked any either.
Function ToShiftState(Shift: Integer): TShiftState;
Begin
  Result := [];
  If (Shift and 1) <> 0 Then Include(Result, ssLeft);
  If (Shift and 2) <> 0 Then Include(Result, ssRight);
  If (Shift and 4) <> 0 Then Include(Result, ssMiddle);
End;

// The pointer moved. In order: a decorated window being dragged or resized
// takes the movement; then an open menu tracks the highlight; then the
// captured or hovered control gets it; and if none of those claimed it, the
// interpreter's own MOUSEX and MOUSEY are all that changed.
Procedure HandleMouseMotion(Const Ev: TSDL_Event);
Var
  Shift: Integer;
  Win: Pointer;
  p: TPoint;
  LMenu, LItem, Btn, X, Y, tX, tY, ID, Dx, Dy, NewX, NewY, NewW, NewH: Integer;
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

  SP_SetDirtyRect(Min(MOUSEX, MOUSESTOREX), Min(MOUSEY, MOUSESTOREY), Max(MOUSEX+MOUSEW, MOUSESTOREX+MOUSESTOREW), Max(MOUSEY+MOUSEH, MOUSESTOREY+MOUSESTOREH));
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

      End;

      DisplaySection.Leave;

    End;

    // Fall through to allow user code to get mousemove events

  If Not Handled Then Begin
    M_MOVEFLAG := True;
    MOUSEBTN := Btn;
  End;

End;

// A button went down. Menus take precedence over everything; then a
// decorated window's edges and caption bar, for a resize or a drag; then
// the control under the pointer; and only if nothing claimed it does the
// interpreter see the click.
//
// SDL_CaptureMouse keeps events coming while the button is held even if the
// pointer leaves the window, so a drag that wanders off still delivers its
// button-up. SpecBAS's own CaptureControl, set further down, is an
// unrelated thing with a similar name.
Procedure HandleMouseDown(Const Ev: TSDL_Event);
Var
  Shift: Integer;
  WShift: TShiftState;
  mi: SP_MenuSelection;
  Win: Pointer;
  Btn, ID, X, Y: Integer;
  p: TPoint;
  Handled: Boolean;
  sPtr: pSP_Window_Info;
  Edge: Integer;
Begin

  If ScaleMouseX <= 0 Then Exit;

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

// A button came up. The capture is released first and unconditionally, so
// that a release always ends a drag even when nothing else about the event
// can be used.
Procedure HandleMouseUp(Const Ev: TSDL_Event);
Var
  Shift: Integer;
  WShift: TShiftState;
  mi: SP_MenuSelection;
  Win: Pointer;
  Btn, ID, X, Y, BankIdx: Integer;
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

// The wheel turned towards the user. The control under the pointer gets
// first refusal; failing that the scroll reaches the interpreter through
// MOUSEWHEEL. The position comes from MOUSEX and MOUSEY, which the motion
// handler keeps current.
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
  DisplaySection.Enter;

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

// The wheel turned away from the user. The same shape as DoMouseWheelDown,
// with the sign of the delta and the direction of MOUSEWHEEL reversed.
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
  DisplaySection.Enter;

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

// SDL_MOUSEWHEEL has no direct FormMouseWheelDown/FormMouseWheelUp split of
// its own — just a signed scroll amount — so this is the seam that decides
// which of the two ported handlers above a given wheel event means. Positive
// Ev.wheel.y is "away from the user", the same gesture Win32/GTK report as a
// positive wheel delta, which is what the LCL routes to OnMouseWheelUp; a
// SDL_MOUSEWHEEL_FLIPPED direction (natural/reversed scrolling) negates it
// first, per the field's own doc comment. Neither FormMouseWheelDown nor
// FormMouseWheelUp read the mouse position their MousePos parameter carried,
// using MOUSEX/MOUSEY instead, so nothing is lost by SDL not supplying one
// either. SDL_MOUSEWHEEL itself carries no held-button state, unlike a
// motion event, so that is asked for separately via SDL_GetMouseState.
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

      SDL_MOUSEWHEEL:
        HandleMouseWheel(Ev);

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

    // The project's version, taken from the same place the Windows build
    // takes it: the VERSIONINFO in src/SpecBAS.rc. There is no version
    // resource to read back at run time here, so build-sdl2/Makefile reads
    // that file and writes SpecBAS_Version.inc, and the number reaches the
    // title bar and the BUILDSTR system variable in the form the Windows
    // build shows it.
    BUILDSTR := {$INCLUDE SpecBAS_Version.inc};
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
      // The interpreter thread reaches the host's image loader through
      // TThread.Synchronize (SP_BankManager.IntLoadImage), which parks the
      // call on the main thread's queue and waits. Something on the main
      // thread has to run that queue or the wait never ends. Under Lazarus
      // the LCL's own idle handler did it; here there is no LCL, so the
      // main loop does it itself.
      CheckSynchronize;
      FrameLoop;
    End;

    HostDestroy;
  Finally
    FreeAndNil(Main);
    SDLB_Stop;
  End;
End;

end.
