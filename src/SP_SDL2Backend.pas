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

unit SP_SDL2Backend;

// The host layer in SDL2 terms: one window, one renderer, one streaming
// texture, the clipboard, the display geometry and the clock.
//
// SpecBAS draws its whole picture itself into a 32-bit-per-pixel linear byte
// array. Moving that array to the screen once a frame is the only thing this
// unit does on the picture side:
//
//   SDL_UpdateTexture(Tex, nil, Buffer, Pitch)
//   SDL_RenderCopy(Ren, Tex, nil, nil)
//   SDL_RenderPresent(Ren)
//
// Both rectangles are nil, so the texture is the logical screen size and the
// renderer stretches it to whatever size the window is. Nothing else has to
// know the window was resized.
//
// The texture format is SDL_PIXELFORMAT_ARGB8888, which on a little-endian
// machine lays a pixel down as B, G, R, A. That is the order SpecBAS already
// produces; the Windows OpenGL path uploads the same array as GL_BGRA.
//
// Vertical sync is off. SpecBAS paces its own frames in SP_Display.FrameLoop
// against the rate it was told, and a renderer synchronised to the display
// would pace them against a different number.
//
// Every call below that creates, changes or destroys the window or the
// texture runs on the thread that created the window, and is marshalled
// there when another thread asks for it. SpecBAS asks from its interpreter
// thread: SCREEN FULL reaches SDLB_SetFullScreen that way. On macOS, SDL2
// answers SDL_SetWindowFullscreen by asking NSApplication for events while
// the transition runs, which AppKit permits from the main thread alone and
// otherwise refuses by raising an Objective-C exception that no Free Pascal
// handler catches. Confining the texture to the same thread serialises it
// with the frame present, which happens there too.

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$INCLUDE SpecBAS.inc}

interface

Uses SysUtils, Classes, SDL2;

Var

  SDLB_Window:   PSDL_Window   = Nil;
  SDLB_Renderer: PSDL_Renderer = Nil;
  SDLB_Texture:  PSDL_Texture  = Nil;

  // The size of the streaming texture, which is SpecBAS's logical screen and
  // not the window.
  SDLB_TexWidth:  Integer = 0;
  SDLB_TexHeight: Integer = 0;

  Function  SDLB_Start(Const Title: String; W, H: Integer): Boolean;
  Procedure SDLB_Stop;

  // Match the texture to a new logical screen size. Idempotent, and cheap
  // when the size has not changed.
  Function  SDLB_SetLogicalSize(W, H: Integer): Boolean;

  // Buffer is the first byte of the logical screen; Pitch is the distance in
  // bytes from the start of one row to the start of the next.
  Procedure SDLB_Present(Buffer: Pointer; Pitch: Integer);

  Procedure SDLB_SetTitle(Const Title: String);
  Procedure SDLB_GetClientSize(Out W, H: Integer);
  Procedure SDLB_SetClientSize(W, H: Integer);
  Procedure SDLB_GetWindowPos(Out X, Y: Integer);
  Procedure SDLB_SetWindowPos(X, Y: Integer);
  Function  SDLB_SetFullScreen(OnOff: Boolean): Boolean;

  // Bounds of the display the window is on.
  Procedure SDLB_GetDisplayBounds(Out X, Y, W, H: Integer);
  Function  SDLB_GetRefreshRate: Integer;

  // Where the pointer is in window coordinates, and whether it is over the
  // window at all.
  Function  SDLB_GetMousePos(Out X, Y: Integer): Boolean;
  Procedure SDLB_WarpMouse(X, Y: Integer);

  Function  SDLB_GetClipboardText: String;
  Procedure SDLB_SetClipboardText(Const S: String);

  // Milliseconds since SDLB_Start, from the high-resolution counter.
  // SDL_GetTicks counts whole milliseconds, which is too coarse to pace a
  // frame with.
  Function  SDLB_Milliseconds: Double;

implementation

Type

  // One window or texture call, parked for the owning thread to make. Run
  // calls straight back into the public procedure, which by then finds
  // itself on the owning thread and does the work.
  TSDLB_CallKind = (ckFullScreen, ckClientSize, ckWindowPos, ckTitle, ckLogicalSize);

  TSDLB_Call = Class
    Kind:   TSDLB_CallKind;
    W, H:   Integer;
    OnOff:  Boolean;
    Title:  AnsiString;
    Answer: Boolean;
    Procedure Run;
  End;

Var
  StartCounter: UInt64 = 0;
  CounterFreq:  Double = 1.0;

// The window belongs to the thread that created it, which is the thread the
// program started on.
Function OnOwningThread: Boolean;
Begin
  Result := GetCurrentThreadId = MainThreadID;
End;

Function CallOnOwningThread(Kind: TSDLB_CallKind; W, H: Integer; OnOff: Boolean;
                            Const Title: AnsiString): Boolean;
Var
  Call: TSDLB_Call;
Begin
  Call := TSDLB_Call.Create;
  Try
    Call.Kind   := Kind;
    Call.W      := W;
    Call.H      := H;
    Call.OnOff  := OnOff;
    Call.Title  := Title;
    Call.Answer := False;
    TThread.Synchronize(Nil, Call.Run);
    Result := Call.Answer;
  Finally
    Call.Free;
  End;
End;

Procedure TSDLB_Call.Run;
Begin
  Case Kind of
    ckFullScreen:  Answer := SDLB_SetFullScreen(OnOff);
    ckClientSize:  SDLB_SetClientSize(W, H);
    ckWindowPos:   SDLB_SetWindowPos(W, H);
    ckTitle:       SDLB_SetTitle(String(Title));
    ckLogicalSize: Answer := SDLB_SetLogicalSize(W, H);
  End;
End;

Function SDLB_Milliseconds: Double;
Begin
  Result := ((SDL_GetPerformanceCounter - StartCounter) * 1000.0) / CounterFreq;
End;

Function SDLB_Start(Const Title: String; W, H: Integer): Boolean;
Begin
  Result := False;

  If SDL_Init(SDL_INIT_VIDEO or SDL_INIT_TIMER) <> 0 Then Exit;

  CounterFreq := SDL_GetPerformanceFrequency;
  If CounterFreq <= 0 Then CounterFreq := 1.0;
  StartCounter := SDL_GetPerformanceCounter;

  SDLB_Window := SDL_CreateWindow(PAnsiChar(AnsiString(Title)),
                                  SDL_WINDOWPOS_CENTERED,
                                  SDL_WINDOWPOS_CENTERED,
                                  W, H,
                                  SDL_WINDOW_SHOWN or SDL_WINDOW_RESIZABLE);
  If SDLB_Window = Nil Then Exit;

  // No SDL_RENDERER_PRESENTVSYNC; see the note at the top of the unit.
  SDLB_Renderer := SDL_CreateRenderer(SDLB_Window, -1, SDL_RENDERER_ACCELERATED);
  If SDLB_Renderer = Nil Then
    SDLB_Renderer := SDL_CreateRenderer(SDLB_Window, -1, SDL_RENDERER_SOFTWARE);
  If SDLB_Renderer = Nil Then Exit;

  If Not SDLB_SetLogicalSize(W, H) Then Exit;

  // SpecBAS draws its own pointer, so the system one stays hidden.
  SDL_ShowCursor(SDL_DISABLE);
  // Without this SDL2 delivers no SDL_TEXTINPUT event, and that is the only
  // event that carries a typed character.
  SDL_StartTextInput;

  Result := True;
End;

Procedure SDLB_Stop;
Begin
  If SDLB_Texture <> Nil Then Begin
    SDL_DestroyTexture(SDLB_Texture);
    SDLB_Texture := Nil;
  End;
  If SDLB_Renderer <> Nil Then Begin
    SDL_DestroyRenderer(SDLB_Renderer);
    SDLB_Renderer := Nil;
  End;
  If SDLB_Window <> Nil Then Begin
    SDL_DestroyWindow(SDLB_Window);
    SDLB_Window := Nil;
  End;
  SDL_Quit;
End;

Function SDLB_SetLogicalSize(W, H: Integer): Boolean;
Begin
  Result := False;
  If (W <= 0) or (H <= 0) or (SDLB_Renderer = Nil) Then Exit;
  If (SDLB_Texture <> Nil) and (W = SDLB_TexWidth) and (H = SDLB_TexHeight) Then Begin
    Result := True;
    Exit;
  End;
  If Not OnOwningThread Then Begin
    Result := CallOnOwningThread(ckLogicalSize, W, H, False, '');
    Exit;
  End;

  If SDLB_Texture <> Nil Then Begin
    SDL_DestroyTexture(SDLB_Texture);
    SDLB_Texture := Nil;
  End;

  SDLB_Texture := SDL_CreateTexture(SDLB_Renderer, SDL_PIXELFORMAT_ARGB8888,
                                    SDL_TEXTUREACCESS_STREAMING, W, H);
  If SDLB_Texture = Nil Then Exit;

  SDLB_TexWidth  := W;
  SDLB_TexHeight := H;
  Result := True;
End;

Procedure SDLB_Present(Buffer: Pointer; Pitch: Integer);
Begin
  If (SDLB_Renderer = Nil) or (SDLB_Texture = Nil) or (Buffer = Nil) Then Exit;
  SDL_UpdateTexture(SDLB_Texture, Nil, Buffer, Pitch);
  SDL_RenderCopy(SDLB_Renderer, SDLB_Texture, Nil, Nil);
  SDL_RenderPresent(SDLB_Renderer);
End;

Procedure SDLB_SetTitle(Const Title: String);
Begin
  If SDLB_Window = Nil Then Exit;
  If Not OnOwningThread Then Begin
    CallOnOwningThread(ckTitle, 0, 0, False, AnsiString(Title));
    Exit;
  End;
  SDL_SetWindowTitle(SDLB_Window, PAnsiChar(AnsiString(Title)));
End;

Procedure SDLB_GetClientSize(Out W, H: Integer);
Var
  cw, ch: LongInt;
Begin
  W := SDLB_TexWidth;
  H := SDLB_TexHeight;
  If SDLB_Window = Nil Then Exit;
  SDL_GetWindowSize(SDLB_Window, @cw, @ch);
  W := cw;
  H := ch;
End;

Procedure SDLB_SetClientSize(W, H: Integer);
Begin
  If (SDLB_Window = Nil) or (W <= 0) or (H <= 0) Then Exit;
  If Not OnOwningThread Then Begin
    CallOnOwningThread(ckClientSize, W, H, False, '');
    Exit;
  End;
  SDL_SetWindowSize(SDLB_Window, W, H);
End;

Procedure SDLB_GetWindowPos(Out X, Y: Integer);
Var
  wx, wy: LongInt;
Begin
  X := 0; Y := 0;
  If SDLB_Window = Nil Then Exit;
  SDL_GetWindowPosition(SDLB_Window, @wx, @wy);
  X := wx;
  Y := wy;
End;

Procedure SDLB_SetWindowPos(X, Y: Integer);
Begin
  If SDLB_Window = Nil Then Exit;
  If Not OnOwningThread Then Begin
    CallOnOwningThread(ckWindowPos, X, Y, False, '');
    Exit;
  End;
  SDL_SetWindowPosition(SDLB_Window, X, Y);
End;

Function SDLB_SetFullScreen(OnOff: Boolean): Boolean;
Var
  Flags: UInt32;
Begin
  Result := False;
  If SDLB_Window = Nil Then Exit;
  If Not OnOwningThread Then Begin
    Result := CallOnOwningThread(ckFullScreen, 0, 0, OnOff, '');
    Exit;
  End;
  // Desktop fullscreen rather than a video mode change: the renderer already
  // stretches the logical screen to whatever it is given, so switching the
  // monitor's mode would buy nothing.
  If OnOff Then Flags := SDL_WINDOW_FULLSCREEN_DESKTOP Else Flags := 0;
  Result := SDL_SetWindowFullscreen(SDLB_Window, Flags) = 0;
End;

Procedure SDLB_GetDisplayBounds(Out X, Y, W, H: Integer);
Var
  R: TSDL_Rect;
  Idx: Integer;
Begin
  X := 0; Y := 0; W := 0; H := 0;
  If SDLB_Window = Nil Then Exit;
  Idx := SDL_GetWindowDisplayIndex(SDLB_Window);
  If Idx < 0 Then Idx := 0;
  FillChar(R, SizeOf(R), 0);
  If SDL_GetDisplayBounds(Idx, @R) = 0 Then Begin
    X := R.x; Y := R.y; W := R.w; H := R.h;
  End;
End;

Function SDLB_GetRefreshRate: Integer;
Var
  Mode: TSDL_DisplayMode;
  Idx: Integer;
Begin
  Result := 0;
  If SDLB_Window = Nil Then Exit;
  Idx := SDL_GetWindowDisplayIndex(SDLB_Window);
  If Idx < 0 Then Idx := 0;
  FillChar(Mode, SizeOf(Mode), 0);
  If SDL_GetCurrentDisplayMode(Idx, @Mode) = 0 Then
    Result := Mode.refresh_rate;
End;

Function SDLB_GetMousePos(Out X, Y: Integer): Boolean;
Var
  mx, my, wx, wy, ww, wh: LongInt;
Begin
  X := 0; Y := 0;
  Result := False;
  If SDLB_Window = Nil Then Exit;
  // The global position is answered whether or not the window has focus,
  // which is what SP_Display.HandleMouse needs in order to notice that the
  // pointer has left.
  SDL_GetGlobalMouseState(@mx, @my);
  SDL_GetWindowPosition(SDLB_Window, @wx, @wy);
  SDL_GetWindowSize(SDLB_Window, @ww, @wh);
  X := mx - wx;
  Y := my - wy;
  Result := (X >= 0) and (Y >= 0) and (X < ww) and (Y < wh);
End;

Procedure SDLB_WarpMouse(X, Y: Integer);
Begin
  If SDLB_Window <> Nil Then
    SDL_WarpMouseInWindow(SDLB_Window, X, Y);
End;

Function SDLB_GetClipboardText: String;
Var
  P: PAnsiChar;
Begin
  Result := '';
  P := SDL_GetClipboardText;
  If P <> Nil Then Begin
    Result := String(AnsiString(P));
    SDL_free(P);
  End;
End;

Procedure SDLB_SetClipboardText(Const S: String);
Begin
  SDL_SetClipboardText(PAnsiChar(AnsiString(S)));
End;

end.
