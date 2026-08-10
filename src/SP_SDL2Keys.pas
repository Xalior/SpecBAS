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

unit SP_SDL2Keys;

// The one keyboard mapping for every SDL2 platform.
//
// SpecBAS identifies keys by Windows virtual-key code. The K_* table in
// SP_Input.pas is that set of codes, and everything downstream of
// SP_AddKey — the editor, the widget set, KEYSTATE, the BASIC keywords
// INKEY$ and KEYSTATE — indexes by it. So a key arriving from SDL2 has to
// be turned into a Windows virtual-key code before it goes anywhere else.
//
// The mapping runs from the SDL *scancode*, not the keycode. A scancode
// names the physical key and does not move when the keyboard layout
// changes, which is what a virtual-key code means as well. The SDL keycode
// is the character the layout produces, and that is a different question,
// answered separately by SDL_TEXTINPUT.

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$INCLUDE SpecBAS.inc}

interface

Uses SDL2;

  // The Windows virtual-key code for an SDL scancode, or 0 if this key has
  // no equivalent. Values match the K_* constants in SP_Input.pas.
  Function SDL2_ScanCodeToVK(ScanCode: TSDL_ScanCode): Word;

  // True for keys SpecBAS treats as complete on the key-down event, because
  // no printable character will follow them. Every other key waits for the
  // SDL_TEXTINPUT event that carries its character.
  Function SDL2_IsNonPrintingKey(VK: Word): Boolean;

implementation

Function SDL2_ScanCodeToVK(ScanCode: TSDL_ScanCode): Word;
Begin
  Case ScanCode of

    // Letters. SDL orders them A..Z from scancode 4; the virtual-key codes
    // run A..Z from 65, so this is one subtraction.
    SDL_SCANCODE_A..SDL_SCANCODE_Z:
      Result := 65 + (ScanCode - SDL_SCANCODE_A);

    // Digits along the top row. SDL puts 1..9 first and 0 last; the
    // virtual-key codes start at 0.
    SDL_SCANCODE_1..SDL_SCANCODE_9:
      Result := 49 + (ScanCode - SDL_SCANCODE_1);
    SDL_SCANCODE_0:            Result := 48;

    SDL_SCANCODE_RETURN:       Result := 13;   // K_RETURN
    SDL_SCANCODE_ESCAPE:       Result := 27;   // K_ESCAPE
    SDL_SCANCODE_BACKSPACE:    Result := 8;    // K_BACK
    SDL_SCANCODE_TAB:          Result := 9;    // K_TAB
    SDL_SCANCODE_SPACE:        Result := 32;   // K_SPACE

    // Punctuation. These are the OEM keys, named on a US layout.
    SDL_SCANCODE_MINUS:        Result := 189;  // K_OEM_MINUS
    SDL_SCANCODE_EQUALS:       Result := 187;  // K_OEM_PLUS
    SDL_SCANCODE_LEFTBRACKET:  Result := 219;  // VK_OEM_4
    SDL_SCANCODE_RIGHTBRACKET: Result := 221;  // VK_OEM_6
    SDL_SCANCODE_BACKSLASH:    Result := 220;  // VK_OEM_5
    SDL_SCANCODE_NONUSHASH:    Result := 220;
    SDL_SCANCODE_SEMICOLON:    Result := 186;  // K_OEM_1
    SDL_SCANCODE_APOSTROPHE:   Result := 222;  // VK_OEM_7
    SDL_SCANCODE_GRAVE:        Result := 192;  // VK_OEM_3
    SDL_SCANCODE_COMMA:        Result := 188;  // K_OEM_COMMA
    SDL_SCANCODE_PERIOD:       Result := 190;  // K_OEM_PERIOD
    SDL_SCANCODE_SLASH:        Result := 191;  // VK_OEM_2
    SDL_SCANCODE_NONUSBACKSLASH: Result := 226; // VK_OEM_102

    SDL_SCANCODE_CAPSLOCK:     Result := 20;   // K_CAPITAL

    SDL_SCANCODE_F1..SDL_SCANCODE_F12:
      Result := 112 + (ScanCode - SDL_SCANCODE_F1);
    SDL_SCANCODE_F13..SDL_SCANCODE_F24:
      Result := 124 + (ScanCode - SDL_SCANCODE_F13);

    SDL_SCANCODE_PRINTSCREEN:  Result := 44;   // K_SNAPSHOT
    SDL_SCANCODE_SCROLLLOCK:   Result := 145;  // K_SCROLL
    SDL_SCANCODE_PAUSE:        Result := 19;   // K_PAUSE
    SDL_SCANCODE_INSERT:       Result := 45;   // K_INSERT
    SDL_SCANCODE_HOME:         Result := 36;   // K_HOME
    SDL_SCANCODE_PAGEUP:       Result := 33;   // K_PRIOR
    SDL_SCANCODE_DELETE:       Result := 46;   // K_DELETE
    SDL_SCANCODE_END:          Result := 35;   // K_END
    SDL_SCANCODE_PAGEDOWN:     Result := 34;   // K_NEXT
    SDL_SCANCODE_RIGHT:        Result := 39;   // K_RIGHT
    SDL_SCANCODE_LEFT:         Result := 37;   // K_LEFT
    SDL_SCANCODE_DOWN:         Result := 40;   // K_DOWN
    SDL_SCANCODE_UP:           Result := 38;   // K_UP

    SDL_SCANCODE_NUMLOCKCLEAR: Result := 144;  // K_NUMLOCK
    SDL_SCANCODE_KP_DIVIDE:    Result := 111;  // K_DIVIDE
    SDL_SCANCODE_KP_MULTIPLY:  Result := 106;  // K_MULTIPLY
    SDL_SCANCODE_KP_MINUS:     Result := 109;  // K_SUBTRACT
    SDL_SCANCODE_KP_PLUS:      Result := 107;  // K_ADD
    SDL_SCANCODE_KP_ENTER:     Result := 13;   // K_RETURN
    // The keypad digits run 1..9 then 0, the same way the top row does.
    SDL_SCANCODE_KP_1..SDL_SCANCODE_KP_9:
      Result := 97 + (ScanCode - SDL_SCANCODE_KP_1);
    SDL_SCANCODE_KP_0:         Result := 96;   // K_NUMPAD0
    SDL_SCANCODE_KP_PERIOD:    Result := 110;  // K_DECIMAL
    SDL_SCANCODE_KP_EQUALS:    Result := 187;  // K_OEM_PLUS
    SDL_SCANCODE_KP_COMMA:     Result := 188;  // K_OEM_COMMA

    SDL_SCANCODE_APPLICATION:  Result := 93;   // K_APPS
    SDL_SCANCODE_MENU:         Result := 93;
    SDL_SCANCODE_SELECT:       Result := 41;   // K_SELECT
    SDL_SCANCODE_EXECUTE:      Result := 43;   // K_EXECUTE
    SDL_SCANCODE_HELP:         Result := 47;   // K_HELP
    SDL_SCANCODE_CANCEL:       Result := 3;    // K_CANCEL
    SDL_SCANCODE_CLEAR:        Result := 12;   // K_CLEAR

    // Modifiers. SpecBAS reads the side-independent code, which is what the
    // K_* table carries and what KEYSTATE is indexed by.
    SDL_SCANCODE_LCTRL,
    SDL_SCANCODE_RCTRL:        Result := 17;   // K_CONTROL
    SDL_SCANCODE_LSHIFT,
    SDL_SCANCODE_RSHIFT:       Result := 16;   // K_SHIFT
    SDL_SCANCODE_LALT,
    SDL_SCANCODE_RALT:         Result := 18;   // K_ALT
    SDL_SCANCODE_LGUI:         Result := 91;   // K_LWIN
    SDL_SCANCODE_RGUI:         Result := 92;   // K_RWIN

  Else
    Result := 0;
  End;
End;

Function SDL2_IsNonPrintingKey(VK: Word): Boolean;
Begin
  // The same set MainForm.pas defers on under Free Pascal, written as
  // virtual-key codes rather than LCLType names. A key in this set is
  // delivered to SP_AddKey immediately; a key outside it is held until the
  // SDL_TEXTINPUT event supplies its character.
  Case VK of
    27,                       // K_ESCAPE
    8,                        // K_BACK
    9,                        // K_TAB
    13,                       // K_RETURN
    112..135,                 // K_F1 .. K_F24
    37, 38, 39, 40,           // arrows
    45, 46,                   // K_INSERT, K_DELETE
    36, 35,                   // K_HOME, K_END
    33, 34,                   // K_PRIOR, K_NEXT
    20, 144, 145,             // K_CAPITAL, K_NUMLOCK, K_SCROLL
    16, 17, 18,               // K_SHIFT, K_CONTROL, K_ALT
    91, 92, 93,               // K_LWIN, K_RWIN, K_APPS
    19, 44:                   // K_PAUSE, K_SNAPSHOT
      Result := True;
  Else
    Result := False;
  End;
End;

end.
