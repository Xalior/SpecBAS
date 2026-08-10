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

program SpecBAS_SDL2;

// SpecBAS with the SDL2 backend. The Lazarus entry point is SpecBAS.dpr,
// which creates a form and hands the program to Application.Run; here the
// host owns its own loop and there is no GUI toolkit at all.

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$INCLUDE SpecBAS.inc}

uses
  {$IFDEF UNIX}CThreads,{$ENDIF}
  SysUtils,
  SP_SDL2Host;

begin
  SDLHost_Run;
end.
