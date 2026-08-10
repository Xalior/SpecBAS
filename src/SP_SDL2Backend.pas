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

unit SP_SDL2Backend;

// The host layer, in SDL2 terms: one window, one renderer, one streaming
// texture, the clipboard, and the display geometry.
//
// SpecBAS draws everything itself into PixArray, a 32-bit-per-pixel linear
// byte array it owns. This unit's only job on the picture side is to move
// that array to the screen once a frame:
//
//   SDL_UpdateTexture(Tex, nil, Buffer, Pitch)
//   SDL_RenderCopy(Ren, Tex, nil, nil)
//   SDL_RenderPresent(Ren)
//
// The nil rectangles are the whole of resize handling. The texture is the
// logical screen size; the renderer stretches it to whatever size the
// window currently is.
//
// The texture format is SDL_PIXELFORMAT_ARGB8888, which on a little-endian
// machine lays each pixel down as B, G, R, A. That is the byte order
// SpecBAS already produces — the OpenGL path uploads the same array with
// GL_BGRA.
//
// Vertical sync is deliberately off. SpecBAS paces itself to its own frame
// rate from SP_Display.FrameLoop; a renderer synchronised to the display
// would run at the display's rate instead, which is a different number.

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$INCLUDE SpecBAS.inc}

interface

Uses SysUtils, SDL2;

Var

  SDLB_Window:   PSDL_Window   = Nil;
  SDLB_Renderer: PSDL_Renderer = Nil;
  SDLB_Texture:  PSDL_Texture  = Nil;

  // Size of the streaming texture, which is SpecBAS's logical screen.
  SDLB_TexWidth:  Integer = 0;
  SDLB_TexHeight: Integer = 0;

  // Name of the renderer SDL2 chose, for the build string.
  SDLB_RendererName: String = '';

  Function  SDLB_Start(Const Title: String; W, H: Integer): Boolean;
  Procedure SDLB_Stop;

  // Make the streaming texture match a new logical screen size. Cheap and
  // idempotent: it does nothing when the size has not changed.
  Function  SDLB_SetLogicalSize(W, H: Integer): Boolean;

  // The seam. Buffer is the first byte of the logical screen; Pitch is the
  // distance in bytes between the start of one row and the next.
  Procedure SDLB_Present(Buffer: Pointer; Pitch: Integer);

  Procedure SDLB_SetTitle(Const Title: String);
  Procedure SDLB_GetClientSize(Out W, H: Integer);
  Procedure SDLB_SetClientSize(W, H: Integer);
  Procedure SDLB_GetWindowPos(Out X, Y: Integer);
  Procedure SDLB_SetWindowPos(X, Y: Integer);
  Function  SDLB_SetFullScreen(OnOff: Boolean): Boolean;

  // Bounds of the display the window is currently on.
  Procedure SDLB_GetDisplayBounds(Out X, Y, W, H: Integer);
  Function  SDLB_GetRefreshRate: Integer;

  // Mouse position in window coordinates. Reports whether the pointer is
  // over the window at all.
  Function  SDLB_GetMousePos(Out X, Y: Integer): Boolean;
  Procedure SDLB_WarpMouse(X, Y: Integer);

  Function  SDLB_GetClipboardText: String;
  Procedure SDLB_SetClipboardText(Const S: String);

  // Milliseconds since SDLB_Start, from the high-resolution counter.
  // SDL_GetTicks is millisecond-resolution and too coarse to pace a frame.
  Function  SDLB_Milliseconds: Double;

implementation

Var
  StartCounter: UInt64 = 0;
  CounterFreq:  Double = 1.0;

Function SDLB_Milliseconds: Double;
Begin
  Result := ((SDL_GetPerformanceCounter - StartCounter) * 1000.0) / CounterFreq;
End;

Function SDLB_Start(Const Title: String; W, H: Integer): Boolean;
Var
  Info: TSDL_RendererInfo;
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

  // No SDL_RENDERER_PRESENTVSYNC: see the note at the top of the unit.
  SDLB_Renderer := SDL_CreateRenderer(SDLB_Window, -1, SDL_RENDERER_ACCELERATED);
  If SDLB_Renderer = Nil Then
    SDLB_Renderer := SDL_CreateRenderer(SDLB_Window, -1, SDL_RENDERER_SOFTWARE);
  If SDLB_Renderer = Nil Then Exit;

  FillChar(Info, SizeOf(Info), 0);
  If SDL_GetRendererInfo(SDLB_Renderer, @Info) = 0 Then
    SDLB_RendererName := String(AnsiString(Info.name));

  If Not SDLB_SetLogicalSize(W, H) Then Exit;

  // SpecBAS draws its own pointer, so the system one stays hidden.
  SDL_ShowCursor(SDL_DISABLE);
  // Without this no SDL_TEXTINPUT event is ever delivered, and that is the
  // only event that carries a typed character.
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
  If SDLB_Window <> Nil Then
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
  If (SDLB_Window <> Nil) and (W > 0) and (H > 0) Then
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
  If SDLB_Window <> Nil Then
    SDL_SetWindowPosition(SDLB_Window, X, Y);
End;

Function SDLB_SetFullScreen(OnOff: Boolean): Boolean;
Var
  Flags: UInt32;
Begin
  Result := False;
  If SDLB_Window = Nil Then Exit;
  // Desktop fullscreen, not a video-mode change: SpecBAS's logical screen is
  // scaled to the display by the renderer, so there is nothing to gain from
  // switching the monitor's mode and a great deal to lose.
  If OnOff Then Flags := SDL_WINDOW_FULLSCREEN_DESKTOP Else Flags := 0;
  Result := SDL_SetWindowFullscreen(SDLB_Window, Flags) = 0;
End;

Procedure SDLB_GetDisplayBounds(Out X, Y, W, H: Integer);
Var
  R: TSDL_Rect;
  Idx: Integer;
Begin
  X := 0; Y := 0; W := 800; H := 600;
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
  // The global position works whether or not the window has focus, which is
  // what SP_Display.HandleMouse needs to decide if the pointer left.
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
