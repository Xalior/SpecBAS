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

unit SP_SDL2Compat;

// Two small things the editor units get from Lazarus today, supplied here
// for the SDL2 backend so those units keep the shape they already have.
//
//   Clipboard.AsText  — SP_EditUnit and SP_MemoUnit copy and paste through
//                       this one property. SDL2 answers it directly.
//   CopyFile          — SP_FileIO and SP_Interpret_PostFix copy a file with
//                       overwrite. LazUtils supplies it in the Lazarus
//                       build; this is the same call over TFileStream.

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$INCLUDE SpecBAS.inc}

interface

Uses Classes, SysUtils, SP_SDL2Backend;

Type

  TSDLClipboard = Class
  Private
    Function  GetAsText: String;
    Procedure SetAsText(Const Value: String);
  Public
    Property AsText: String read GetAsText write SetAsText;
  End;

  Function Clipboard: TSDLClipboard;

  Function CopyFile(Const SrcName, DestName: String;
                    Overwrite: Boolean = False): Boolean;

implementation

Var
  TheClipboard: TSDLClipboard = Nil;

Function Clipboard: TSDLClipboard;
Begin
  If TheClipboard = Nil Then
    TheClipboard := TSDLClipboard.Create;
  Result := TheClipboard;
End;

Function TSDLClipboard.GetAsText: String;
Begin
  Result := SDLB_GetClipboardText;
End;

Procedure TSDLClipboard.SetAsText(Const Value: String);
Begin
  SDLB_SetClipboardText(Value);
End;

Function CopyFile(Const SrcName, DestName: String;
                  Overwrite: Boolean = False): Boolean;
Var
  Src, Dst: TFileStream;
Begin
  Result := False;
  If Not FileExists(SrcName) Then Exit;
  If FileExists(DestName) and Not Overwrite Then Exit;
  Try
    Src := TFileStream.Create(SrcName, fmOpenRead or fmShareDenyWrite);
    Try
      Dst := TFileStream.Create(DestName, fmCreate);
      Try
        Dst.CopyFrom(Src, Src.Size);
      Finally
        Dst.Free;
      End;
    Finally
      Src.Free;
    End;
    Result := True;
  Except
    Result := False;
  End;
End;

Initialization

Finalization

  FreeAndNil(TheClipboard);

end.
