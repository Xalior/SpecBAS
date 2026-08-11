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

unit SP_SDL2Keys;

// The keyboard mapping, shared by every SDL2 platform.
//
// SpecBAS names keys by the K_ constants in SP_Input.pas, and everything
// downstream of SP_AddKey indexes by them: the editor, the widget set,
// KEYSTATE, INKEY$. So a key arriving from SDL2 has to be given one of those
// names before it goes anywhere else.
//
// The mapping runs from the SDL scancode rather than the keycode. A scancode
// names the physical key and does not move when the keyboard layout changes,
// which is what a K_ constant means too. The SDL keycode is the character
// the layout puts on that key, which is a separate question, answered by the
// SDL_TEXTINPUT event.

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$INCLUDE SpecBAS.inc}

interface

Uses SDL2, SP_Input;

  // The K_ constant for an SDL scancode, or 0 for a key SpecBAS has no name
  // for.
  Function SDL2_ScanCodeToKey(ScanCode: TSDL_ScanCode): Word;

  // True for a key that carries no character, and is therefore complete on
  // the key-down event. Any other key waits for the SDL_TEXTINPUT event that
  // supplies its character.
  Function SDL2_IsNonPrintingKey(Key: Word): Boolean;

implementation

Function SDL2_ScanCodeToKey(ScanCode: TSDL_ScanCode): Word;
Begin
  Case ScanCode of

    // SDL runs the letters A..Z from one scancode and the K_ constants run
    // them from another, so each of these two ranges is one subtraction.
    // The digit rows put 1..9 first and 0 last, where the K_ constants
    // start at zero.
    SDL_SCANCODE_A..SDL_SCANCODE_Z:
      Result := K_A + (ScanCode - SDL_SCANCODE_A);
    SDL_SCANCODE_1..SDL_SCANCODE_9:
      Result := K_1 + (ScanCode - SDL_SCANCODE_1);
    SDL_SCANCODE_0:            Result := K_0;

    SDL_SCANCODE_RETURN:       Result := K_RETURN;
    SDL_SCANCODE_ESCAPE:       Result := K_ESCAPE;
    SDL_SCANCODE_BACKSPACE:    Result := K_BACK;
    SDL_SCANCODE_TAB:          Result := K_TAB;
    SDL_SCANCODE_SPACE:        Result := K_SPACE;

    // The OEM keys, named for where they sit on a US layout. Which
    // character each one produces is the layout's business, and arrives
    // separately.
    SDL_SCANCODE_MINUS:          Result := K_OEM_MINUS;
    SDL_SCANCODE_EQUALS:         Result := K_OEM_PLUS;
    SDL_SCANCODE_LEFTBRACKET:    Result := K_OEM_4;
    SDL_SCANCODE_RIGHTBRACKET:   Result := K_OEM_6;
    SDL_SCANCODE_BACKSLASH:      Result := K_OEM_5;
    SDL_SCANCODE_NONUSHASH:      Result := K_OEM_5;
    SDL_SCANCODE_SEMICOLON:      Result := K_OEM_1;
    SDL_SCANCODE_APOSTROPHE:     Result := K_OEM_7;
    SDL_SCANCODE_GRAVE:          Result := K_OEM_3;
    SDL_SCANCODE_COMMA:          Result := K_OEM_COMMA;
    SDL_SCANCODE_PERIOD:         Result := K_OEM_PERIOD;
    SDL_SCANCODE_SLASH:          Result := K_OEM_2;
    SDL_SCANCODE_NONUSBACKSLASH: Result := K_OEM_102;

    SDL_SCANCODE_CAPSLOCK:     Result := K_CAPITAL;

    SDL_SCANCODE_F1..SDL_SCANCODE_F12:
      Result := K_F1 + (ScanCode - SDL_SCANCODE_F1);
    SDL_SCANCODE_F13..SDL_SCANCODE_F24:
      Result := K_F13 + (ScanCode - SDL_SCANCODE_F13);

    SDL_SCANCODE_PRINTSCREEN:  Result := K_SNAPSHOT;
    SDL_SCANCODE_SCROLLLOCK:   Result := K_SCROLL;
    SDL_SCANCODE_PAUSE:        Result := K_PAUSE;
    SDL_SCANCODE_INSERT:       Result := K_INSERT;
    SDL_SCANCODE_HOME:         Result := K_HOME;
    SDL_SCANCODE_PAGEUP:       Result := K_PRIOR;
    SDL_SCANCODE_DELETE:       Result := K_DELETE;
    SDL_SCANCODE_END:          Result := K_END;
    SDL_SCANCODE_PAGEDOWN:     Result := K_NEXT;
    SDL_SCANCODE_RIGHT:        Result := K_RIGHT;
    SDL_SCANCODE_LEFT:         Result := K_LEFT;
    SDL_SCANCODE_DOWN:         Result := K_DOWN;
    SDL_SCANCODE_UP:           Result := K_UP;

    SDL_SCANCODE_NUMLOCKCLEAR: Result := K_NUMLOCK;
    SDL_SCANCODE_KP_DIVIDE:    Result := K_DIVIDE;
    SDL_SCANCODE_KP_MULTIPLY:  Result := K_MULTIPLY;
    SDL_SCANCODE_KP_MINUS:     Result := K_SUBTRACT;
    SDL_SCANCODE_KP_PLUS:      Result := K_ADD;
    SDL_SCANCODE_KP_ENTER:     Result := K_RETURN;
    SDL_SCANCODE_KP_1..SDL_SCANCODE_KP_9:
      Result := K_NUMPAD1 + (ScanCode - SDL_SCANCODE_KP_1);
    SDL_SCANCODE_KP_0:         Result := K_NUMPAD0;
    SDL_SCANCODE_KP_PERIOD:    Result := K_DECIMAL;
    SDL_SCANCODE_KP_EQUALS:    Result := K_OEM_PLUS;
    SDL_SCANCODE_KP_COMMA:     Result := K_OEM_COMMA;

    SDL_SCANCODE_APPLICATION:  Result := K_APPS;
    SDL_SCANCODE_MENU:         Result := K_APPS;
    SDL_SCANCODE_SELECT:       Result := K_SELECT;
    SDL_SCANCODE_EXECUTE:      Result := K_EXECUTE;
    SDL_SCANCODE_HELP:         Result := K_HELP;
    SDL_SCANCODE_CANCEL:       Result := K_CANCEL;
    SDL_SCANCODE_CLEAR:        Result := K_CLEAR;

    // SpecBAS names a modifier without a side, which is what KEYSTATE is
    // indexed by, so both of each pair answer the same.
    SDL_SCANCODE_LCTRL,
    SDL_SCANCODE_RCTRL:        Result := K_CONTROL;
    SDL_SCANCODE_LSHIFT,
    SDL_SCANCODE_RSHIFT:       Result := K_SHIFT;
    SDL_SCANCODE_LALT,
    SDL_SCANCODE_RALT:         Result := K_ALT;
    {$IFDEF MAC_COMMAND_IS_CONTROL}
    SDL_SCANCODE_LGUI,
    SDL_SCANCODE_RGUI:         Result := K_CONTROL;
    {$ELSE}
    SDL_SCANCODE_LGUI:         Result := K_LWIN;
    SDL_SCANCODE_RGUI:         Result := K_RWIN;
    {$ENDIF}

  Else
    Result := 0;
  End;
End;

Function SDL2_IsNonPrintingKey(Key: Word): Boolean;
Begin
  // The set MainForm.pas's FormKeyDown holds back on under Free Pascal,
  // written in the K_ names rather than the LCLType ones. A key in this set
  // reaches SP_AddKey on the key-down event; anything else waits for its
  // character.
  Result := Key In [K_ESCAPE, K_BACK, K_TAB, K_RETURN,
                    K_F1, K_F2, K_F3, K_F4, K_F5, K_F6,
                    K_F7, K_F8, K_F9, K_F10, K_F11, K_F12,
                    K_LEFT, K_RIGHT, K_UP, K_DOWN,
                    K_INSERT, K_DELETE, K_HOME, K_END,
                    K_PRIOR, K_NEXT, K_CAPITAL, K_NUMLOCK,
                    K_SCROLL, K_SHIFT, K_CONTROL, K_ALT];
End;

end.
