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

unit SP_FileIO;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}
{$INCLUDE SpecBAS.inc}

interface

Uses {$IFNDEF FPC}Windows, {$ENDIF}Types, Classes, SysUtils, SyncObjs, SP_Util, SP_Errors,
     SP_SysVars, SP_Variables, SP_InfixToPostFix{$IFDEF FPC}, {$IFDEF SDL2}SP_SDL2Compat{$ELSE}FileUtil{$ENDIF}{$ENDIF}, SP_AnsiStringlist;

Type

  TSP_File = Packed Record
    ID: Integer;
    Stream: TFileStream;
    Filename: aString;
    NeedCreate: Boolean;
    PackageFile: Boolean;
  End;
  pSP_File = ^TSP_File;

Procedure SP_FindAll(Path: aString; var List: TAnsiStringList; Var Sizes: TAnsiStringList);
Function  WildComp(const mask: aString; const target: aString): Boolean;

Function  SP_FilterMatch(Filename, Filter: aString): Boolean;
Function  SP_ConvertFilenameToHost(const Filename: aString; var Error: TSP_ErrorCode): aString;
Function  SP_ConvertHostFilename(const Filename: aString; Var Error: TSP_ErrorCode): aString;
Function  SP_FileOpen(Filename: aString; Create: Boolean; Var Error: TSP_ErrorCode): Integer;
Function  SP_FileOpenDirty(Filename: aString; Var Error: TSP_ErrorCode): Integer;
Procedure SP_FileSeek(ID, Position: Integer; Var Error: TSP_ErrorCode);
Function  SP_FileSize(ID: Integer; Var Error: TSP_ErrorCode): Integer;
Function  SP_FilePosition(ID: Integer; Var Error: TSP_ErrorCode): Integer;
Function  SP_FileRead(ID: Integer; Buffer: Pointer; Count: Integer; Var Error: TSP_ErrorCode): Integer;
Function  SP_FileReadLn(ID: Integer; Var Error: TSP_ErrorCode): aString;
Function  SP_FileReadLnChar(ID: Integer; SepChar: aChar; Var Error: TSP_ErrorCode): aString;
Function  SP_FileWrite(ID: Integer; Buffer: Pointer; Count: Integer; Var Error: TSP_ErrorCode): Integer;
Function  SP_FileReWrite(ID: Integer; Var Error: TSP_ErrorCode): Integer;
Procedure SP_FileClose(ID: Integer; Var Error: TSP_ErrorCode);
Function  SP_FileExists(Filename: aString): Boolean;
Procedure SP_SetCurrentDir(Dir: aString; Var Error: TSP_ErrorCode);
Function  SP_GetCurrentDir: aString;
Function  SP_GetHostCWD: aString;
Function  SP_IsDirectory(const Path: aString): Boolean;
Function  SP_GetParentDir(Const Dir: aString): aString;
Function  SP_DirectoryExists(Dir: aString): Boolean;
Procedure SP_DeleteFile(Filename: aString; var Error: TSP_ErrorCode);
Function  SP_GetFileListRecursive(Var FileSpec: aString; WantEXP: Boolean; Var Error: TSP_ErrorCode): aString;
Procedure SP_GetFileList(Var FileSpec: aString; Var Files, FileSizes: TAnsiStringList; Var Error: TSP_ErrorCode; PreserveDirs: Boolean);
Procedure SP_DeleteDirContents(DirString: aString; var Error: TSP_ErrorCode);
Procedure SP_RmDir(DirString: aString; var Error: TSP_ErrorCode);
Procedure SP_RmDirUnsafe(DirString: aString; Var Error: TSP_ErrorCode);
Procedure SP_CopyFiles(FileSpec, Dest: aString; Overwrite: Boolean; var Error: TSP_ErrorCode);
Procedure SP_MoveFiles(FileSpec, Dest: aString; Overwrite: Boolean; var Error: TSP_ErrorCode);
Procedure SP_MakeDir(Dir: aString; var Error: TSP_ErrorCode);
Procedure SP_FileRename(Src, Dst: aString; var Error: TSP_ErrorCode);
Procedure SP_RenameFiles(SrcFiles, DstFiles: aString; var Error: TSP_ErrorCode);
Function  SP_ExtractFileDir(Filename: aString): aString;
Function  SP_ExtractFilename(Filename: aString): aString;

Procedure SP_SetAssign(Ass, Path: aString; var Error: TSP_ErrorCode);
Function  SP_Decode_Assignment(Ass: aString; var Error: TSP_ErrorCode): aString;
Function  SP_ConvertPathToAssigns(Filename: aString): aString;
Function  SP_DecomposePathWithAssigns(Path: aString): aString;

Function  SP_FileFindID(ID: Integer): Integer;
Procedure SP_FileCloseAll;

Procedure SP_SaveProgram(Filename: aString; AutoStart: Integer; Var Error: TSP_ErrorCode);
Procedure SP_LoadProgram(Filename: aString; Merge: Boolean; DirtyFile: Boolean; Const pList: TAnsiStringList; Var Error: TSP_ErrorCode);
Procedure SP_IncludeFile(Filename: aString; Var Error: TSP_ErrorCode);
Procedure SP_DeleteIncludes;

Procedure CopyDirectoryRecursive(inDir: String; outDir: String);

Procedure SP_AddToRecentFiles(Filename: aString; Saving: Boolean);
Procedure SP_LoadRecentFiles;
Procedure SP_SaveRecentFiles;
Function  SP_GetProgName(s: aString; Display: Boolean = False): aString;

Var

  SP_FileList: Array of pSP_File;
  SP_Ass_List: Array of aString;
  SP_RecentFiles: Array of aString;

  FileSection: TCriticalSection;

implementation

Uses SP_Main, SP_Package, SP_Graphics, SP_PreRun, SP_Tokenise
     {$IFNDEF RUNTIMEONLY}
     , SP_Compiler, SP_Editor, SP_FPEditor, SP_BASICEditorUnit,
     SP_BASICEditorHostUnit
     {$ENDIF};

Procedure CopyFiles(inDir: String; outDir: String);
Var
  s: TSearchRec;
  SrcName, DestName: String;
  sTime, dTime: TDateTime;
  cpy: Boolean;
  Err: TSP_ErrorCode;
Begin

  If FindFirst(IncludeTrailingPathDelimiter(inDir) + '*', $1FF - $10, s) = 0 Then Begin
     Repeat
       cpy := True;
       If s.Attr And faDirectory <> faDirectory Then Begin
         DestName := IncludeTrailingPathDelimiter(outDir) + s.Name;
         SrcName := IncludeTrailingPathDelimiter(inDir) + s.Name;
         If FileExists(DestName) Then Begin
           FileAge(SrcName, sTime);
           FileAge(DestName, dTime);
           cpy := sTime > dTime;
         end;
       End;
       SCROLLCNT := 0;
       If cpy Then Begin
         SP_PRINT(-1, Round(PRPOSX), Round(PRPOSY), -1, 'Copying '+ aString(DestName), 0, 8, Err);
         {$IFDEF FPC}
         {$IFDEF SDL2}SP_SDL2Compat{$ELSE}FileUtil{$ENDIF}.CopyFile(SrcName, DestName, True);
         {$ENDIF}
       End Else
         SP_PRINT(-1, Round(PRPOSX), Round(PRPOSY), -1, 'Skipped '+ aString(DestName), 2, 8, Err);
       PRPOSX := 0;
       PRPOSY := PRPOSY + FONTHEIGHT;
     Until SysUtils.FindNext(s) <> 0;
  End;
  FindClose(s);
End;

procedure CopyDirectoryRecursive(inDir: String; outDir: String);
// Based on code by Matthew Hipkin ( http://www.matthewhipkin.co.uk/codelib/copy-directory-structure-in-delphi-and-lazarus/ )
var
  s: TSearchRec;
  nInDir, nOutDir: String;
begin
  CopyFiles(inDir, outDir);
  If Not DirectoryExists(outDir) Then
    mkDir(outDir);
  if FindFirst(IncludeTrailingPathDelimiter(inDir) + '*', faDirectory, s) = 0 then
  begin
    repeat
      if (s.Name <> '.') and (s.Name <> '..') and ((s.Attr and faDirectory) = faDirectory) then
      begin
        nInDir := IncludeTrailingPathDelimiter(inDir) + s.Name;
        nOutDir := IncludeTrailingPathDelimiter(outDir) + s.Name;
        // Create new subdirectory in outDir
        If Not DirectoryExists(nOutDir) Then
          mkdir(nOutDir);
        // Recurse into subdirectory in inDir
        copyDirectoryRecursive(nInDir, nOutDir);
      end;
    until SysUtils.FindNext(s) <> 0;
  end;
  FindClose(s);
end;

Procedure SP_FindAll(Path: aString; var List: TAnsiStringList; Var Sizes: TAnsiStringList);
Var
  Res: TSearchRec;
  EOFound: Boolean;
  Idx, Cnt, nIdx, sIdx: Integer;
  Size, Size2, AgeStr: aString;
  Age: TDateTime;
  Error: TSP_ErrorCode;
Begin

  If PackageIsOpen And (Pos(':', Path) = 0) Then Begin

    SP_PackageFindAll(Path, List, Sizes, Error);

  End Else Begin

    If Pos(':', Path) <> 0 Then
      Path := SP_ConvertFilenameToHost(Path, Error);
    EOFound:= False;
    // FindFirst answers 0 for success and a positive code otherwise, 18 for
    // an empty directory. It never answers a negative one.
    If FindFirst(String(Path), faAnyFile, Res) <> 0 Then
      Exit
    Else
      While Not EOFound Do Begin
        Idx := List.Add(aString(Res.Name));
        If Res.Attr And faDirectory > 0 Then
          List.Objects[Idx] := Pointer(1)
        Else
          List.Objects[Idx] := Pointer(0);
        Size := aString(IntToStr(Int64(Res.Size)));
        Size2 := ''; Cnt := 0;
        nIdx := Length(Size);
        While nIdx > 0 Do Begin
          Size2 := Size[nIdx] + Size2;
          Inc(Cnt);
          If (Cnt = 3) And (nIdx > 1) Then Begin
            Size2 := ',' + Size2;
            Cnt := 0;
          End;
          Dec(nIdx);
        End;
        Age := Res.TimeStamp;
        If Age > -1 Then Begin
          AgeStr := aString(DateToStr(Age));
          If Length(AgeStr) < 10 Then
            If AgeStr[2] = '/' Then
              AgeStr := '0' + AgeStr
            Else
              AgeStr := Copy(AgeStr, 1, 3) + '0' + Copy(AgeStr, 4, Length(AgeStr));
          If Length(AgeStr) < 10 Then
            AgeStr := Copy(AgeStr, 1, 3) + '0' + Copy(AgeStr, 4, Length(AgeStr));
          AgeStr := Copy(AgeStr, 1, 2) + '/' + Copy(AgeStr, 4, 2) + '/' + Copy(AgeStr, 7, 4);
          sIdx := Sizes.Add(Size2 + ' ' + SP_StringOfChar(' ', 10 - Length(AgeStr)) + AgeStr);
        End Else
          sIdx := Sizes.Add(Size2 + '            ');
        Sizes.Objects[sIdx] := Pointer(StringToLong(Size));
        EOFound:= SysUtils.FindNext(Res) <> 0;
      End;
    FindClose(Res);
  End;

End;

Function WildComp(const mask: aString; const target: aString): Boolean;

  // This function was retrieved from http://www.delphifaq.com/faq/delphi/strings/f112.shtml
  // And was posted by thomas_kelsey@techie.com under the GPL License, and
  // as such can be included in SpecBAS. Modified to remove the "." issue, as SpecBAS
  // doesn't use file extensions for anything but music.

  // '*' matches greedy & ungreedy
  // simple recursive descent parser - not fast but easy to understand
  function WComp(const maskI: Integer; const targetI: Integer): Boolean;
  begin
    if maskI > Length(mask) then begin
      Result := targetI = Length(target) + 1;
      Exit;
    end;
    if targetI > Length(target) then begin
      // unread chars in filter or would have read '#0'
      // Only exception is a trailing "*" in the mask - that matches everything else including
      // the empty string. A trailing "?" MUST match a character.
      Result := (maskI = Length(Mask)) and (mask[maskI] = '*');
      Exit;
    end;
    case mask[maskI] of
      '*':
        // try with and without ending match - but always matches at least one char
        Result := WComp(succ(maskI), Succ(targetI)) or WComp(maskI, Succ(targetI)) or WComp(succ(MaskI), targetI);
      '?':
        Result := WComp(succ(maskI), Succ(targetI));
    else
      // includes '.' which only matches itself
      if mask[maskI] = target[targetI] then
        Result := WComp(succ(maskI), Succ(targetI))
      else
        Result := False;
    end;// case
  end;
begin
  WildComp := WComp(1, 1);
end;

Function SP_ConvertFilenameToHost(const Filename: aString; var Error: TSP_ErrorCode): aString;
Var
  fName, fName2: aString;
Begin

  // Converts a specbas file/folder to the host architecture's file/folder

  ERRStr := SP_ExtractFileDir(Filename);
  If Pos(':', Filename) <> 0 Then Begin
    fName := SP_Decode_Assignment(Copy(Filename, 1, Pos(':', Filename) -1), Error);
    fName2 := Copy(Filename, Pos(':', Filename) +1, Length(Filename));
    While Copy(fName2, 1, 1) = '/' Do
      fName2 := Copy(fName2, 2, Length(fName2));
    fName2 := fName + fName2;
  End Else
    fName2 := Filename;

  If fName2 <> '' Then Begin
    If fName2[1] = '/' Then
      If Lower(Copy(fName2, 1, Length(HOMEFOLDER))) <> Lower(HOMEFOLDER) Then
        fName2 := HOMEFOLDER + Copy(fName2, 2, Length(fName2));

    fName := aString(ExpandFileName(String(fName2)));

    If Lower(Copy(fName, 1, Length(HOMEFOLDER) -1)) <> Lower(Copy(Homefolder, 1, Length(HomeFolder) -1)) Then Begin
      Result := #255;
      Error.Code := SP_ERR_DIR_NOT_FOUND;
      Exit;
    End;

  End Else

    fName := '';

  Result := fName;

End;

Function SP_ConvertHostFilename(const Filename: aString; Var Error: TSP_ErrorCode): aString;
Var
  fName: aString;
  Idx: Integer;
Begin

  // Converts a host-friendly filename to a specbas style filename.

  fName := aString(ExpandFileName(String(Filename)));
  If fName[Length(fName)] <> PathDelim Then fName := fName + PathDelim;

  If Lower(Copy(fName, 1, Length(HOMEFOLDER))) <> Lower(Homefolder) Then Begin
    Result := '';
    ERRStr := Filename;
    Error.Code := SP_ERR_INVALID_FILENAME;
    Exit;
  End Else Begin
    If fName <> '' Then Begin
      For Idx := 1 to Length(fName) Do
        If fName[Idx] = '\' Then fName[Idx] := '/';
    End;
    fName := '/' + Copy(fName, Length(HOMEFOLDER) +1, Length(fName));
    Result := fName;
  End;

End;

Function SP_FileOpen(Filename: aString; Create: Boolean; Var Error: TSP_ErrorCode): Integer;
Var
  fName: aString;
  Idx, FoundIdx, NewID: Integer;
  NewFile: pSP_File;
  Done, Found, System: Boolean;
Begin

  Result := -1;
  LASTFILENAME := Filename;

  // Filename is in SpecBAS format.

  System := Pos(':', Filename) > 0;
  ERRStr := Filename;

  If System or Not PackageIsOpen Then Begin

    fName := SP_ConvertFilenameToHost(Filename, Error);

    If Lower(Copy(fName, 1, Length(HOMEFOLDER))) <> Lower(Homefolder) Then Begin
      Result := -1;
      Error.Code := SP_ERR_INVALID_FILENAME;
      Exit;
    End;

  End Else

    fName := Filename;

  // Check if the file is already open in the file list

  FoundIdx := -1;
  For Idx := 0 To Length(SP_FileList) -1 Do Begin
    If SP_FileList[Idx]^.Filename = fName Then Begin
      FoundIdx := Idx;
      Break;
    End;
  End;

  // Not open, so create a new file list entry.

  If FoundIdx = -1 Then Begin

    If (SP_ExtractFileDir(Filename) = '') Or (SP_DirectoryExists(SP_ExtractFileDir(FileName))) Then Begin

      New(NewFile);
      NewID := 0;
      Done := Length(SP_FileList) = 0;
      While Not Done Do Begin
        Found := False;
        For Idx := 0 To Length(SP_FileList) -1 Do Begin
          If SP_FileList[Idx]^.ID = NewID Then Begin
            Inc(NewID);
            Found := True;
            Break;
          End;
        End;
        If Not Found Then
          Done := True;
      End;

      NewFile^.ID := NewID;
      NewFile^.Filename := fName;
      NewFile^.PackageFile := False;
      NewFile^.NeedCreate := False;

      // Create the new file.

      If Not SP_FileExists(fName) Then Begin
        If Create Then Begin
          NewFile^.NeedCreate := True;
          NewFile^.Stream := Nil;
        End Else Begin
          Error.Code := SP_ERR_FILE_ALREADY_EXISTS;
          Dispose(NewFile);
          Result := -1;
          Exit;
        End;
      End Else Begin

        Try
          If System or Not PackageIsOpen Then Begin
            NewFile^.Stream := TFileStream.Create(String(fName), fmOpenReadWrite or fmShareDenyNone)
          End Else
            NewFile^.PackageFile := True;
        Except
          On Exception Do Begin
            Dispose(NewFile);
            Error.Code := SP_ERR_COULD_NOT_OPEN_FILE;
            Result := -1;
            Exit;
          End;
        End;

      End;

      SetLength(SP_FileList, Length(SP_FileList) +1);
      SP_FileList[Length(SP_FileList) -1] := NewFile;
      FoundIdx := Length(SP_FileList) -1;
      If Not System Then
        NewFile^.PackageFile := PackageIsOpen;

      Result := SP_FileList[FoundIdx]^.ID;
      If System or Not PackageIsOpen Then Begin
        If SP_FileList[FoundIdx]^.Stream <> Nil Then Begin
          SP_FileList[FoundIdx]^.Stream.Seek(0, soFromBeginning);
        End;
      End Else
        If Not NewFile^.NeedCreate Then
          SP_SeekToPackageFile(fName, 0, Error);

    End Else Begin

      ERRStr := SP_ExtractFileDir(ERRStr);
      Error.Code := SP_ERR_DIRECTORYNOTFOUND;
      Result := -1;

    End;

  End;

End;

Function  SP_FileOpenDirty(Filename: aString; Var Error: TSP_ErrorCode): Integer;
Var
  fName: aString;
  Idx, FoundIdx, NewID: Integer;
  NewFile: pSP_File;
  Done, Found, System: Boolean;
Begin

  Result := -1;
  LASTFILENAME := Filename;

  // Filename might be in SpecBAS format, but may also be a host-format filename.

  System := Pos(':', Filename) > 0;
  ERRStr := Filename;

  If System or Not PackageIsOpen Then Begin
    If System Then Begin
      fName := SP_ConvertFilenameToHost(Filename, Error);
      If Lower(Copy(fName, 1, Length(HOMEFOLDER))) <> Lower(Homefolder) Then Begin
        Error.Code := SP_ERR_INVALID_FILENAME;
        Result := -1;
        Exit;
      End;
    End Else
      fName := Filename;

  End Else

    fName := Filename;

  // Check if the file is already open in the file list

  FoundIdx := -1;
  For Idx := 0 To Length(SP_FileList) -1 Do Begin
    If SP_FileList[Idx]^.Filename = fName Then Begin
      FoundIdx := Idx;
      Break;
    End;
  End;

  // Not open, so create a new file list entry.

  If FoundIdx = -1 Then Begin

    New(NewFile);
    NewID := 0;
    Done := Length(SP_FileList) = 0;
    While Not Done Do Begin
      Found := False;
      For Idx := 0 To Length(SP_FileList) -1 Do Begin
        If SP_FileList[Idx]^.ID = NewID Then Begin
          Inc(NewID);
          Found := True;
          Break;
        End;
      End;
      If Not Found Then
        Done := True;
    End;

    NewFile^.ID := NewID;
    NewFile^.Filename := fName;
    NewFile^.PackageFile := False;
    NewFile^.NeedCreate := False;
    // Create the new file.

    Try
      If System or Not PackageIsOpen Then Begin
        NewFile^.Stream := TFileStream.Create(String(fName), fmOpenReadWrite or fmShareDenyNone)
      End Else
        NewFile^.PackageFile := True;
    Except
      On Exception Do Begin
        Error.Code := SP_ERR_COULD_NOT_OPEN_FILE;
        Dispose(NewFile);
        Result := -1;
        Exit;
      End;
    End;

    SetLength(SP_FileList, Length(SP_FileList) +1);
    SP_FileList[Length(SP_FileList) -1] := NewFile;
    FoundIdx := Length(SP_FileList) -1;
    If Not System Then
      NewFile^.PackageFile := PackageIsOpen;

    Result := SP_FileList[FoundIdx]^.ID;
    If System or Not PackageIsOpen Then Begin
      If SP_FileList[FoundIdx]^.Stream <> Nil Then Begin
        SP_FileList[FoundIdx]^.Stream.Seek(0, soFromBeginning);
      End;
    End Else
      SP_SeekToPackageFile(fName, 0, Error);

  End;

End;

Procedure SP_FileSeek(ID, Position: Integer; Var Error: TSP_ErrorCode); inline;
Var
  Idx: Integer;
Begin

  Idx := SP_FileFindID(ID);
  If Idx > -1 Then Begin
    If SP_FileList[Idx]^.PackageFile Then
      SP_SeekToPackageFile(SP_FileList[Idx]^.Filename, Position, Error)
    Else
      If SP_FileList[Idx]^.Stream <> nil Then
        SP_FileList[Idx]^.Stream.Seek(Position, soFromBeginning);
  End Else
    Error.Code := SP_ERR_FILE_NOT_OPEN;

End;

Function  SP_FileSize(ID: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  Idx: Integer;
Begin

  Result := -1;
  Idx := SP_FileFindID(ID);
  If Idx > -1 Then Begin
    If SP_FileList[Idx]^.PackageFile Then
      Result := SP_GetSizeFromPackageFile(SP_FileList[Idx]^.Filename, Error)
    Else
      If SP_FileList[Idx]^.Stream <> nil Then
        Result := SP_FileList[Idx]^.Stream.Size
      Else
        Result := 0;
  End Else
    Error.Code := SP_ERR_FILE_NOT_OPEN;

End;

Function  SP_FilePosition(ID: Integer; Var Error: TSP_ErrorCode): Integer; inline;
Var
  Idx: Integer;
Begin

  Result := -1;
  Idx := SP_FileFindID(ID);
  If Idx > -1 Then Begin
    If SP_FileList[Idx]^.PackageFile Then
      Result := SP_GetSeekPosFromPackageFile(SP_FileList[Idx]^.Filename, Error)
    Else
      If SP_FileList[Idx]^.Stream <> nil Then
        Result := SP_FileList[Idx]^.Stream.Position
      Else
        Result := 0;
  End Else
    Error.Code := SP_ERR_FILE_NOT_OPEN;

End;

Function SP_FileRead(ID: Integer; Buffer: Pointer; Count: Integer; Var Error: TSP_ErrorCode): Integer; inline;
Var
  Idx: Integer;
Begin

  Result := 0;
  Idx := SP_FileFindID(ID);
  If Idx > -1 Then Begin
    If SP_FileList[Idx]^.PackageFile Then
      Result := SP_ReadFromPackageFile(SP_FileList[Idx]^.Filename, pByte(Buffer), Count, Error)
    Else
      If SP_FileList[Idx]^.Stream <> nil Then Begin
        Result := SP_FileList[Idx]^.Stream.Read(Buffer^, Count);
      End Else Begin
        Result := -1;
        Exit;
      End;
  End Else
    Error.Code := SP_ERR_FILE_NOT_OPEN;

End;

Function SP_FileReadLn(ID: Integer; Var Error: TSP_ErrorCode): aString;
Var
  Done: Boolean;
  Idx, l, i, cl, iPos: Integer;
  Buffer: Array of Byte;
  readByte: Byte;
Begin

  Result := '';
  Idx := SP_FileFindID(ID);
  If Idx > -1 Then Begin
    If SP_FileList[Idx]^.PackageFile Then
      Result := SP_ReadLnFromPackageFile(SP_FileList[Idx]^.Filename, Error)
    Else
      With SP_FileList[Idx]^ Do
        If Stream <> nil Then Begin
          cl := 0;
          iPos := Stream.Position;
          SetLength(Buffer, 1024);
          Done := False;
          While Not Done Do Begin
            l := Stream.Read(Buffer[cl], 1024);
            if (l = 0) and (cl = 0) then Exit;
            i := cl;
            While i < l + cl Do Begin
              if Buffer[i] in [13, 10] Then Begin
                Done := True;
                Break;
              End Else
                inc(i);
            End;
            If Stream.Position >= Stream.Size Then Done := True;
            If Not Done Then Begin
              Inc(cl, l);
              SetLength(Buffer, cl + 1025);
            End Else Begin
              if i > 0 Then Begin
                SetLength(Result, i);
                CopyMem(@Result[1], @Buffer[0], i);
                Stream.Seek(iPos + i +1, soFromBeginning);
                if Buffer[i] <> 10 then Begin // Handle CRLF
                  Stream.Read(readByte, 1);
                  if ReadByte <> 10 then
                    Stream.Seek(-1, soFromCurrent);
                End;
              End Else
                If i = 0 Then Begin
                  If Buffer[i] = 13 Then
                    Inc(i);
                  If Buffer[i] = 10 Then
                    Inc(i);
                  Stream.Seek(iPos + i, soFromBeginning);
                End;
            End;
          End;
        End Else Begin
          Result := '';
          Exit;
        End;
  End Else
    Error.Code := SP_ERR_FILE_NOT_OPEN;

End;

Function SP_FileReadLnChar(ID: Integer; SepChar: aChar; Var Error: TSP_ErrorCode): aString;
Var
  Done: Boolean;
  Idx, l, i, cl, iPos: Integer;
  Buffer: Array of Byte;
Begin

  Result := '';
  Idx := SP_FileFindID(ID);
  If Idx > -1 Then Begin
    If SP_FileList[Idx]^.PackageFile Then
      Result := SP_ReadLnCharFromPackageFile(SP_FileList[Idx]^.Filename, SepChar, Error)
    Else
      With SP_FileList[Idx]^ Do
        If Stream <> nil Then Begin
          cl := 0;
          iPos := Stream.Position;
          SetLength(Buffer, 1024);
          Done := False;
          While Not Done Do Begin
            l := Stream.Read(Buffer[cl], 1024);
            if (l = 0) and (cl = 0) then Exit;
            i := cl;
            While i < l + cl Do Begin
              if Buffer[i] = Ord(SepChar) Then Begin
                Done := True;
                Break;
              End Else
                inc(i);
            End;
            If Not Done Then Begin
              Inc(cl, l);
              SetLength(Buffer, cl + 1025);
            End Else Begin
              if i > 0 Then Begin
                SetLength(Result, i);
                CopyMem(@Result[1], @Buffer[0], i);
              End Else
                Result := '';
              Stream.Seek(iPos + i +1, soFromBeginning);
            End;
          End;
        End Else Begin
          Result := '';
          Exit;
        End;
  End Else
    Error.Code := SP_ERR_FILE_NOT_OPEN;

End;

Function SP_FileWrite(ID: Integer; Buffer: Pointer; Count: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  Idx: Integer;
Begin

  Result := -1;
  Idx := SP_FileFindID(ID);
  If Idx > -1 Then Begin
    If SP_FileList[Idx]^.PackageFile Then Begin
      If SP_FileList[Idx]^.NeedCreate Then Begin
         SP_CreatePackageFile(SP_FileList[Idx]^.Filename, Error);
         SP_FileList[Idx]^.NeedCreate := False;
      End;
      Result := SP_WriteToPackageFile(SP_FileList[Idx]^.Filename, pByte(Buffer), Count, Error);
    End Else Begin
      Try
        If SP_FileList[Idx]^.NeedCreate Then Begin
           SP_FileList[Idx]^.Stream := TFileStream.Create(String(SP_FileList[Idx]^.Filename), fmCreate or fmShareDenyNone);
           SP_FileList[Idx]^.NeedCreate := False;
        End;
        Result := SP_FileList[Idx]^.Stream.Write(Buffer^, Count);
      Except
        ERRStr := '';
        Error.Code := SP_ERR_SAVE_OPEN_ERROR;
      End;
    End;
  End Else
    Error.Code := SP_ERR_FILE_NOT_OPEN;

End;

Function SP_FileReWrite(ID: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  Filename: aString;
  NewID, OldID, Idx: Integer;
Begin

  Result := -1;
  Idx := SP_FileFindID(ID);
  If Idx > -1 Then Begin
    OldID := ID;
    Filename := SP_FileList[Idx]^.Filename;
    SP_FileClose(OldID, Error);
    If DeleteFile(String(Filename)) Then Begin
      NewID := SP_FileOpen(Filename, True, Error);
      Idx := SP_FileFindID(NewID);
      SP_FileList[Idx]^.ID := OldID;
      Result := OldID;
    End Else Begin
      Result := -1;
      Error.Code := SP_ERR_FILE_LOCKED;
    End;
  End Else
    Error.Code := SP_ERR_FILE_NOT_OPEN;

End;

Procedure SP_FileClose(ID: Integer; Var Error: TSP_ErrorCode);
Var
  Index, Idx: Integer;
Begin

  Idx := SP_FileFindID(ID);
  If (Idx > -1) And Assigned(SP_FileList[Idx]) Then Begin
    If Not SP_FileList[Idx]^.PackageFile Then
      If SP_FileList[Idx]^.Stream <> nil Then
        SP_FileList[Idx]^.Stream.Free;
    Dispose(SP_FileList[Idx]);
    For Index := Idx To Length(SP_FileList) -2 Do
      SP_FileList[Index] := SP_FileList[Index +1];
    SetLength(SP_FileList, Length(SP_FileList) -1);
  End Else
    Error.Code := SP_ERR_FILE_NOT_OPEN;

End;

Function SP_FileFindID(ID: Integer): Integer;
Var
  Idx: Integer;
Begin

  Result := -1;
  Idx := 0;
  While Idx < Length(SP_FileList) Do Begin
    If SP_FileList[Idx]^.ID = ID Then Begin
      Result := Idx;
      Exit;
    End;
    Inc(Idx);
  End;

End;

Function SP_FileExists(Filename: aString): Boolean;
Var
  HostName: aString;
  Error: TSP_ErrorCode;
  System: Boolean;
Begin

  System := Pos(':', Filename) > 0;
  If PackageIsOpen And Not System Then
    Result := SP_PackageFileExists(Filename, Error)
  Else Begin
    HostName := SP_ConvertFilenameToHost(Filename, Error);
    Result := FileExists(String(HostName));
  End;

End;

Procedure SP_FileCloseAll;
Var
  Idx: Integer;
Begin

  FileSection.Enter;

  For Idx := 0 To Length(SP_FileList) -1 Do
    If Assigned(SP_FileList[Idx]) Then Begin
      If Not SP_FileList[Idx]^.PackageFile Then
        If Assigned(SP_FileList[Idx]^.Stream) Then
          SP_FileList[Idx]^.Stream.Free;
      Dispose(SP_FileList[Idx]);
    End;

  SetLength(SP_FileList, 0);

  FileSection.Leave;

End;

Function SP_GetProgName(s: aString; Display: Boolean = False): aString;
{$IFNDEF RUNTIMEONLY}
Var
  cl_changed, cl_normal: Longword;
{$ENDIF}
Begin

  {$IFNDEF RUNTIMEONLY}
  If Not FILENAMED Then
    Result := NEWPROGNAME
  Else
    Result := s;

  If Display Then Begin
    If FocusedWindow = fwDirect Then Begin
      cl_changed := 120;
      cl_normal := 26;
    End Else Begin
      cl_changed := 10;
      cl_normal := 12;
    End;
    If FILECHANGED Then
      Result := Result + aChar(#16)+LongWordToString(cl_changed)+' '+ BlobChar
    Else
      Result := Result + aChar(#16)+LongWordToString(cl_normal)+' '+ BlobChar;
  End;
  {$ENDIF}

End;

Procedure SP_SaveProgram(Filename: aString; AutoStart: Integer; Var Error: TSP_ErrorCode);
{$IFNDEF RUNTIMEONLY}
Var
  FileID, Idx, ProgLen, p: Integer;
  SaveBuffer, Backup: aString;
  System, BackBool: Boolean;
Const
  ASCIITAG: aString = 'ZXASCII'#13#10;
  TrueFalse: Array[0..1] of aString = ('FALSE', 'TRUE');
{$ENDIF}
Begin
  {$IFNDEF RUNTIMEONLY}
  BackBool := FILENAMED;
  Backup   := PROGNAME;

  If Filename = '' Then
    If FILENAMED Then
      Filename := PROGNAME
    Else Begin
      Error.Code := SP_ERR_INVALID_FILENAME;
      CompilerLock.Leave;
      Exit;
    End;

  ERRStr := Filename;
  If SP_FileExists(Filename) Then Begin
    System := Pos(':', Filename) > 0;
    If PackageIsOpen And Not System Then Begin
      SP_DeletePackageFile(Filename, Error);
      If Error.Code <> SP_ERR_OK Then Exit;
    End Else Begin
      SP_DeleteFile(Filename, Error);
      If Error.Code <> SP_ERR_OK Then Exit;
    End;
  End;

  FileID     := SP_FileOpen(Filename, True, Error);
  SaveBuffer := '';

  If FileID > -1 Then Begin

    ProgLen := SP_EditorLineCount;

    If (Lower(Filename) <> 's:autosave') And
       (Lower(Filename) <> 's:oldprog')  And
       (Lower(Filename) <> 's:old_temp') Then Begin
      PROGNAME := SP_ExtractFileDir(Filename);
      Repeat
        p := Pos('\', PROGNAME);
        If p > 0 Then
          PROGNAME := Copy(PROGNAME, 1, p-1) + '/' + Copy(PROGNAME, p+1);
      Until p = 0;
      If Copy(PROGNAME, Length(PROGNAME), 1) <> '/' Then
        PROGNAME := PROGNAME + '/';
      PROGNAME    := PROGNAME + SP_ExtractFileName(Filename);
      FILENAMED   := True;
      FILECHANGED := False;
      SP_AddToRecentFiles(Filename, True);
      LASTFILENAME := Filename;
    End;

    SaveBuffer := ASCIITAG +
                  'AUTO '    + IntToString(AutoStart)         + #13#10 +
                  'PROG '    + PROGNAME                       + #13#10 +
                  'CHANGED ' + TrueFalse[Ord(FILECHANGED)]   + #13#10;

    For Idx := 0 To ProgLen - 1 Do
      SaveBuffer := SaveBuffer + SP_EditorLine(Idx) + #13#10;

    SP_FileWrite(FileID, @SaveBuffer[1], Length(SaveBuffer), Error);
    SP_FileClose(FileID, Error);

    If Error.Code <> SP_ERR_OK Then Begin
      PROGNAME  := Backup;
      FILENAMED := BackBool;
    End;

  End Else
    If Error.Code = SP_ERR_OK Then
      Error.Code := SP_ERR_SAVE_OPEN_ERROR;
  {$ENDIF}
End;

Procedure SP_IncludeFile(Filename: aString; Var Error: TSP_ErrorCode);
Var
  Tokens: aString;
  NewProg: TAnsiStringList;
  CurLastLine, Idx, Idx2, cPos, Token, LineNumber: Integer;
  CanTest, Changed, ChangeFlag: Boolean;
Begin

  // Loads a program into a temporary memory area, and then appends it to the current program.
  // If the program doesn't exist in the current directory, try prepending INCLUDE: to it.

  NewProg := TAnsiStringList.Create;

  If Not SP_FileExists(Filename) Then
    If SP_FileExists('include:'+Filename) Then
      Filename := 'include:'+Filename
    Else
      If SP_FileExists('include:'+SP_ExtractFilename(Filename)) Then
        Filename := 'include:'+SP_ExtractFilename(Filename);

  SP_LoadProgram(Filename, False, False, NewProg, Error);
  If Error.Code <> SP_ERR_OK Then Begin
    NewProg.Free;
    Exit;
  End;

  For Idx := 0 To NewProg.Count -1 Do Begin
    Tokens := SP_TokeniseLine(NewProg[Idx], False, True) + SP_TERMINAL_SEQUENCE;
    If Tokens <> SP_TERMINAL_SEQUENCE Then
      SP_Convert_ToPostFix(Tokens, Error.Position, Error);
    NewProg[Idx] := Tokens;
  End;

  // Ok, got the program into our stringlist. Now grab the initial line number (for later) and start to process
  // the code.

  If Byte(NewProg[0][1]) = SP_LINE_NUM Then Begin

    CurLastLine := pLongWord(@SP_Program[SP_Program_Count -1][2])^ + 10;

    For Idx := 0 To NewProg.Count -1 Do Begin

      Idx2 := 1; cPos := 1;
      Tokens := SP_Detokenise(NewProg[Idx], cPos, False, False);
      Tokens := SP_TokeniseLine(Tokens, False, True) + SP_TERMINAL_SEQUENCE;
      Changed := False;
      CanTest := False;
      ChangeFlag := False;

      // Now search the text for the trigger keywords. If found, determine if a label is present - if not,
      // then (if there is a parameter present) insert the "baseaddr+(" + ")" expression.

      If Tokens[Idx2] = aChar(SP_LINE_NUM) Then Begin
        // Increment the line number by the base amount
        Inc(Idx2);
        LineNumber := pLongWord(@Tokens[Idx2])^;
        Inc(LineNumber, CurLastLine);
        pLongWord(@Tokens[Idx2])^ := LineNumber;
        Inc(Idx2, SizeOf(LongWord));
        ChangeFlag := True;
      End;

      If Tokens[Idx2] = aChar(SP_LINE_LEN) Then Inc(Idx2, SizeOf(LongWord) +1);
      If Tokens[Idx2] = aChar(SP_STATEMENTS) Then Inc(Idx2, 1 +((1 + pLongWord(@Tokens[Idx2 +1])^) * SizeOf(LongWord)));

      While Idx2 <= Length(Tokens) Do Begin

        Token := Byte(Tokens[Idx2]);
        Inc(Idx2);

        Case Token of

          SP_KEYWORD:
            Begin
              Case pLongWord(@Tokens[Idx2])^ of
                SP_KW_GO:
                  Begin
                    Inc(Idx2, SizeOf(LongWord));
                    If Byte(Tokens[Idx2]) = SP_KEYWORD Then Begin
                      Inc(Idx2);
                      Case pLongWord(@Tokens[Idx2])^ of
                        SP_KW_TO, SP_KW_SUB:
                          Begin
                            Inc(Idx2, SizeOf(LongWord));
                            CanTest := True;
                          End;
                      Else
                        Begin
                          Inc(Idx2, SizeOf(LongWord));
                        End;
                      End;
                    End;
                  End;
                SP_KW_RESTORE, SP_KW_RUN:
                  Begin
                    CanTest := True;
                    Inc(Idx2, SizeOf(LongWord));
                  End;
                SP_KW_ELSE:
                  Begin
                    If Changed Then Begin
                      Tokens := Copy(Tokens, 1, Idx2 -2) + aChar(SP_SYMBOL) + ')' + Copy(Tokens, Idx2 -1, Length(Tokens));
                      Changed := False;
                      ChangeFlag := True;
                    End;
                    Inc(Idx2, SizeOf(LongWord));
                  End;
              Else
                Begin
                  Inc(Idx2, SizeOf(LongWord));
                End;
              End;
            End;
          SP_LABEL, SP_COMMENT, SP_STRING, SP_STRUCT_MEMBER_N, SP_STRUCT_MEMBER_S:
            Inc(Idx2, SizeOf(LongWord) + pLongWord(@Tokens[Idx2])^);
          SP_VALUE, SP_STRINGCHAR:
            Inc(Idx2, SizeOf(aFloat));
          SP_VALUE10:
            Inc(Idx2, 10);
          SP_NUMVAR, SP_STRVAR:
            Inc(Idx2, (SizeOf(LongWord)*2) + pLongWord(@Tokens[Idx2 + SizeOf(LongWord)])^);
          SP_TEXT:
            Inc(Idx2, SizeOf(LongWord) + pLongWord(@Tokens[Idx2])^);
          SP_SYMBOL:
            Begin
              If Tokens[Idx2] = ':' Then
                If Changed Then Begin
                  Tokens := Copy(Tokens, 1, Idx2 -2) + aChar(SP_SYMBOL) + ')' + Copy(Tokens, Idx2 -1, Length(Tokens));
                  Changed := False;
                  ChangeFlag := True;
                End;
              Inc(Idx2);
            End;
          SP_TERMINAL:
            Begin
              If Changed Then Begin
                Tokens := Copy(Tokens, 1, Idx2 -2) + aChar(SP_SYMBOL) + ')' + Copy(Tokens, Idx2 -1, Length(Tokens));
                ChangeFlag := True;
              End;
              Break;
            End;
        End;

        If CanTest Then Begin
          Token := Byte(Tokens[Idx2]);
          If Not(((Token = SP_SYMBOL) And (Tokens[Idx2 + 1] = ':')) or (Token = SP_LABEL) or (Token = SP_COMMENT) or (Token = SP_TERMINAL) or ((Token = SP_KEYWORD) And (pLongWord(@Tokens[Idx2 + 1])^ = SP_KW_ELSE))) Then Begin
            // Found a valid place to insert our code snippet
            Tokens := Copy(Tokens, 1, Idx2 -1) +
                      aChar(SP_VALUE) + aFloatToString(CurLastLine) + aChar(SP_TEXT) + LongWordToString(Length(IntToString(CurLastLine))) + IntToString(CurLastLine) +
                      aChar(SP_SYMBOL) + '+' +
                      aChar(SP_SYMBOL) + '(' + Copy(Tokens, Idx2, Length(Tokens));
            Changed := True;
            ChangeFlag := True;
          End;
          CanTest := False;
        End;

      End;

      If ChangeFlag Then Begin
        Error.Position := 1;
        SP_Convert_ToPostFix(Tokens, Error.Position, Error);
        NewProg[Idx] := Tokens;
      End;

    End;

    // Now the code is all ready to be added to the current program!

    If Error.Code = SP_ERR_OK Then Begin
      Tokens := SP_TokeniseLine(IntToString(CurLastLine -1) + ' HALT', False, True) + SP_TERMINAL_SEQUENCE;
      SP_Convert_ToPostFix(Tokens, Error.Position, Error);
      NewProg.Insert(0, Tokens);
      SP_Program_AddStrings(NewProg);
    End Else
      Exit;

  End Else

    Error.Code := SP_ERR_FILE_CORRUPT;

  NewProg.Free;

End;

Procedure SP_DeleteIncludes;
Begin

  // Remove all included procedures from the current program

  If INCLUDEFROM >= 0 Then Begin

    SetLength(SP_Program, INCLUDEFROM);
    SP_Program_Count := Length(SP_Program);
    INCLUDEFROM := -10;

  End;

End;

Function SP_FilterMatch(Filename, Filter: aString): Boolean;
var
  b: Boolean;
  fDirectory, t, s2, FilterOut, Buffer: aString;
  MaxContentLen, ps, ps2, i, j: Integer;
  Error: TSP_ErrorCode;
  filterlist: TAnsiStringlist;

  Function IsMatch(fn, fl: aString): Boolean;
  var
    f: Integer;
  Begin
    Result := False;
    If Fl[1] = #0 Then // Mask
      Result := WildComp(Copy(Fl, 2), Fn)
    Else
      If Fl[1] = #1 Then Begin // File content
        If Not b Then Begin
          f := SP_FileOpen(fDirectory + Fn, False, Error);
          SP_FileRead(f, @Buffer[1], MaxContentLen, Error);
          SP_FileClose(f, Error);
          b := True;
        End;
        t := Copy(Fl, 6);
        Result := Copy(Buffer, pLongWord(@Fl[2])^, Length(t)) = t;
      End;
  End;

Begin

  Result := False;
  If Filter <> '' Then Begin
    b := False;
    fDirectory := SP_ExtractFileDir(Filename);
    FilterList := TStringlist.Create;
    Repeat
      ps := Pos(';', Filter);
      If ps = 0 Then ps := Length(Filter) + 2;
      If Filter[1] = '0' Then // File mask
        FilterOut := #0 + Copy(Filter, 2, ps - 2)
      Else
        If Filter[1] = '1' Then Begin // File contents
          s2 := Copy(Filter, 2, ps -2);
          ps2 := Pos(':', s2);
          If ps2 = 0 Then
            Exit
          Else Begin
            i := StringToLong(Copy(s2, 1, ps2 - 1));
            s2 := Copy(s2, ps2 + 1);
            FilterOut := #1 + LongwordToString(i) + s2;
            MaxContentLen := SP_Max(i + Length(s2), MaxContentLen);
          End;
        End;
      Filter := Copy(Filter, ps + 1);
      FilterList.Add(FilterOut);
    Until Filter = '';
    For j := 0 To FilterList.Count -1 Do Begin
      Result := IsMatch(FileName, FilterList[j]);
      If Result Then Break;
    End;
    FilterList.Free;
  End;

End;

Procedure SP_LoadFromRawText(Const RawText: aString; Out AutoStart: Integer; Out ProgName: aString; Out Changed: Boolean; Var Error: TSP_ErrorCode);
Var
  Lines:     TStringList;
  i:         Integer;
  s, s2:     aString;
  Compiled:  aString;
  InString:  Boolean;
  CCol:      Integer;
  CleanText: aString;
  InStr:     Boolean;
  k:         Integer;

  // Inline equivalent of SP_LineHasNumber (from SP_FPEditor) but working on
  // a raw source text line rather than Listing. Returns the length of the
  // leading decimal digit run, or 0 if the line has no line number.
  Function LineHasNumber(Const Line: aString): Integer;
  Var
    j: Integer;
  Begin
    Result := 0;
    j := 1;
    // Skip any leading spaces
    While (j <= Length(Line)) And (Line[j] = ' ') Do Inc(j);
    If j > Length(Line) Then Exit;
    If Not (Line[j] In ['0'..'9']) Then Exit;
    While (j <= Length(Line)) And (Line[j] In ['0'..'9']) Do Begin
      Inc(Result);
      Inc(j);
    End;
  End;

Begin

  AutoStart := -1;
  ProgName  := '';
  Changed   := False;
  Error.Code := SP_ERR_OK;

  // Strip tabs outside strings (matches EditorHost_LoadFromText behaviour)
  CleanText := RawText;
  Begin
    Instr := False;
    For i := 1 To Length(CleanText) Do
      If CleanText[i] = '"' Then
        InStr := Not InStr
      Else If (CleanText[i] = #9) And Not InStr Then
        CleanText[i] := ' ';
  End;

  // Expand compound keywords: DEFPROC->DEF PROC, GOTO->GO TO, etc.
  // CCol is a cursor-column hint used by the editor; pass 1 as a dummy.
  CCol := 1;
  AutoExpandCompounds(CleanText, CCol);

  // Parse headers and split into source lines.
  // After this call, Lines contains only BASIC source lines (no ZXASCII/AUTO/PROG headers).
  // SP_ParseBASICText is the renamed version of SP_BASICEditor.ParseBASICText,
  // moved to SP_Tokenise as part of the editor/runtime split.
  Lines := ParseBASICText(CleanText, AutoStart, ProgName, Changed);
  Try

    SP_Program_Clear;

    i := 0;
    While i < Lines.Count Do Begin

      s := Lines[i];
      Inc(i);

      // Join continuation lines (lines without a leading line number) onto
      // the current numbered line, exactly as SP_ForceCompile does.
      InString := False;
      If s <> '' Then Begin
        For k := 1 To Length(s) Do
          If s[k] = '"' Then InString := Not InString;
      End;

      While (i < Lines.Count) And (LineHasNumber(Lines[i]) = 0) Do Begin
        s2 := Lines[i];
        If (s <> '') And (s2 <> '') And Not InString Then
          s := s + ' ' + s2
        Else
          s := s + s2;
        If s2 <> '' Then Begin
          For k := 1 To Length(s2) Do
            If s2[k] = '"' Then InString := Not InString;
        End;
        Inc(i);
      End;

      // Tokenise and compile the joined line
      Compiled := SP_TokeniseLine(s, False, True) + SP_TERMINAL_SEQUENCE;

      If Compiled <> SP_TERMINAL_SEQUENCE Then Begin

        SP_Convert_ToPostFix(Compiled, Error.Position, Error);

        If Error.Code = SP_ERR_OK Then
          SP_Store_Line(Compiled)
        Else Begin
          // Non-fatal: record the error but continue loading remaining lines.
          // Matches SP_ForceCompile behaviour - a bad line doesn't abort the load.
          Error.Code := SP_ERR_OK;
          Error.Position := 0;
        End;

      End;
      // Empty/whitespace-only lines produce SP_TERMINAL_SEQUENCE alone - skip them.

    End;

  Finally
    Lines.Free;
  End;

  SP_RESTORE;

End;

Procedure SP_LoadProgram(Filename: aString; Merge, DirtyFile: Boolean;
                         Const pList: TAnsiStringList; Var Error: TSP_ErrorCode);
Var
  FileID, FileSize, AutoStart, Idx: Integer;
  {$IFNDEF RUNTIMEONLY}
  LineNum, InsertAt: Integer;
  s: aString;
  {$ENDIF}
  pName, Dir, tStr, RawText: aString;
  Changed, isAutoSaved: Boolean;
  Buffer: Array of Byte;
  ParsedLines: TAnsiStringList;
Label
  Finish, DoneLoad;

  Function StrCopy(Ptr: pByte; Len: Integer): aString;
  Var n: Integer;
  Begin
    SetLength(Result, Len);
    For n := 1 To Len Do Begin
      pByte(@Result[n])^ := Ptr^;
      Inc(Ptr);
    End;
  End;

Begin

  FileID      := -1;
  Changed     := False;
  ERRStr      := Filename;
  AutoStart   := -1;
  pName       := Filename;
  isAutoSaved := (Lower(Filename) = 's:autosave') Or
                 (Lower(Filename) = 's:oldprog')  Or
                 // Multi-tab autosaves: s:autosave_0, s:autosave_1, etc.
                 ((Length(Filename) > 11) And
                  (Lower(Copy(Filename, 1, 11)) = 's:autosave_'));

  Dir := SP_ExtractFileDir(Filename);
  If DirtyFile Then Begin
    SetCurrentDir(String(Dir));
    Filename := SP_ExtractFileName(Filename);
  End Else
    SP_SetCurrentDir(Dir, Error);
  If Error.Code <> SP_ERR_OK Then Goto Finish;

  If Not SP_FileExists(Filename) Then Begin
    If DirtyFile Then Begin
      If FileExists(String(Dir + Filename)) Then
        FileID := SP_FileOpenDirty(Filename, Error);
      If Error.Code <> SP_ERR_OK Then Goto Finish;
    End Else Begin
      Error.Code := SP_ERR_FILE_NOT_FOUND;
      Goto DoneLoad;
    End;
  End;

  If FileID = -1 Then
    FileID := SP_FileOpen(Filename, False, Error);

  If FileID > -1 Then Begin

    FileSize := SP_FileSize(FileID, Error);
    If Error.Code <> SP_ERR_OK Then Goto Finish;

    // Peek at first 6 bytes to detect ZXPACK
    SetLength(Buffer, 6);
    SP_FileRead(FileID, @Buffer[0], 6, Error);
    If Error.Code <> SP_ERR_OK Then Goto Finish;

    If StrCopy(@Buffer[0], 6) = 'ZXPACK' Then Begin
      SP_FileClose(FileID, Error);
      FileID := -1;
      SP_CreatePackage(Filename, Error);
      If Error.Code = SP_ERR_OK Then
        If SP_FileExists('/autorun') Then Begin
          SP_LoadProgram('/autorun', False, False, pList, Error);
          If pList = nil Then Begin
            NXTLINE := SP_FindLine(0, False);
            Error.ReturnType := SP_JUMP;
            tStr := '';
            SP_PreParse(True, True, Error, tStr);
          End;
        End;
      Goto DoneLoad;
    End;

    // Read full file
    SetLength(Buffer, FileSize);
    SP_FileSeek(FileID, 0, Error);
    If (Error.Code <> SP_ERR_OK) Or (FileSize <= 7) Then Goto Finish;
    SP_FileRead(FileID, @Buffer[0], FileSize, Error);
    If Error.Code <> SP_ERR_OK Then Goto Finish;

    // Must be ZXASCII plain text
    If StrCopy(@Buffer[0], 7) <> 'ZXASCII' Then Begin
      Error.Code := SP_ERR_FILE_CORRUPT;
      Goto Finish;
    End;

    // Hand the raw bytes to the component as a string
    SetLength(RawText, FileSize);
    Move(Buffer[0], RawText[1], FileSize);

  End Else
    Error.Code := SP_ERR_COULD_NOT_OPEN_FILE;

Finish:

  If pList = nil Then Begin

    If Error.Code = SP_ERR_OK Then Begin

      SP_DeleteIncludes;
      {$IFNDEF RUNTIMEONLY}
      DoAutoSave;
      {$ENDIF}

      If Not Merge Then Begin
        // Component parses ZXASCII headers and loads lines into the editor.
        // OnTextReset fires ? TextReset ? Listing rebuilt + SetAllToCompile.
        {$IFNDEF RUNTIMEONLY}
        FPShowingSearchResults := False;
        SP_LoadIntoEditorFromText(RawText, AutoStart, pName, Changed);

        // For autosaved files only, honour the CHANGED flag from the header.
        If Not isAutoSaved Then Changed := False;
        FILECHANGED := Changed;
        PROGCHANGED := True;

        // Build runtime bytecode from the freshly-populated Listing
        SP_ForceCompile;
        {$ELSE}
        SP_LoadFromRawText(RawText, AutoStart, pName, Changed, Error);
        {$ENDIF}

        If AutoStart <> -1 Then Begin
          NXTLINE := SP_FindLine(AutoStart, False);
          Error.ReturnType := SP_JUMP;
          tStr := '';
          SP_PreParse(True, True, Error, tStr);
          FileID := -1;
        End;

        If SP_FileExists(pName) And Not DirtyFile Then Begin
          SP_SetCurrentDir(SP_ExtractFileDir(pName), Error);
          PROGNAME := Lower(SP_ConvertPathToAssigns(pName));
          If Not INSTARTUP Then SP_AddToRecentFiles(PROGNAME, False);
          LASTFILENAME := PROGNAME;
          FILENAMED    := True;
        End Else Begin
          PROGNAME  := SP_ExtractFilename(pName);
          FILENAMED := False;
        End;

        {$IFNDEF RUNTIMEONLY}
        If SP_Program_Count > 0 Then
          SP_SysVars.PROGLINE := SP_GetFPLineNumber(0);
        {$ENDIF}
        SP_RESTORE;
      End Else Begin
        {$IFNDEF RUNTIMEONLY}
        // Merge=True: insert/replace lines from the incoming file.
        // Incoming lines take priority on line-number collision.
        ParsedLines := ParseBASICText(RawText, AutoStart, pName, Changed);
        Try
          CompilerLock.Enter;
          Try
            InsertAt := 0;
            For Idx := 0 To ParsedLines.Count - 1 Do Begin
              s := ParsedLines[Idx];
              LineNum := SP_GetLineNumberFromText(s);
              If LineNum > 0 Then Begin
                // Numbered line: find insertion point
                InsertAt := SP_GetLineIndex(LineNum);
                // Collision: delete existing line and its continuation lines
                If (InsertAt < Listing.Count) And
                   (SP_GetLineNumberFromText(Listing[InsertAt]) = LineNum) Then Begin
                  SP_DeleteLine(InsertAt, False);
                  While (InsertAt < Listing.Count) And
                        (SP_GetLineNumberFromText(Listing[InsertAt]) = 0) Do
                    SP_DeleteLine(InsertAt, False);
                End;
                SP_InsertLine(InsertAt, s, '', '', False);
                Inc(InsertAt);
              End Else Begin
                // Continuation line: insert immediately after its parent
                SP_InsertLine(InsertAt, s, '', '', False);
                Inc(InsertAt);
              End;
            End;
          Finally
            CompilerLock.Leave;
          End;
        Finally
          ParsedLines.Free;
        End;
        EditorHost_LoadFromListing;
        SP_ForceCompile;
        FILECHANGED := True;
        PROGCHANGED := True;
        {$ENDIF}
      End;

    End;

  End Else Begin
    // pList non-nil: caller wants lines without touching the editor
    // (SP_IncludeFile, internal use). Parse without loading.
    ParsedLines := ParseBASICText(RawText, AutoStart, pName, Changed);
    Try
      pList.Clear;
      For Idx := 0 To ParsedLines.Count - 1 Do
        pList.Add(ParsedLines[Idx]);
    Finally
      ParsedLines.Free;
    End;
  End;

DoneLoad:
  SetLength(Buffer, 0);
  If FileID > -1 Then SP_FileClose(FileID, Error);
  CONTLINE      := 0;
  CONTSTATEMENT := 1;

End;

Procedure SP_SetAssign(Ass, Path: aString; var Error: TSP_ErrorCode);
Var
  Idx, ListPos: Integer;
Begin

  Error.Code := SP_ERR_OK;

  FileSection.Enter;

  // First determine if the Assignment is valid - the name doesn't contain any
  // illegal characters.

  If Ass[Length(Ass)] = ':' Then
    Ass := Copy(Ass, 1, Length(Ass) -1);

  Idx := 1;
  While Idx < Length(Ass) Do Begin
    If Ass[Idx] in ['0'..'9', 'a'..'z', '_'] Then
      Inc(Idx)
    Else Begin
      ERRStr := Ass + ':';
      Error.Code := SP_ERR_INVALID_ASSIGNMENT;
      FileSection.Leave;
      Exit;
    End;
  End;

  // Now find the Assignment, if it exists.

  Idx := 0;
  ListPos := -1;
  While Idx < Length(SP_Ass_List) Do Begin
    If Copy(SP_Ass_List[Idx], 1, Pos(#255, SP_Ass_List[Idx]) -1) = Ass Then Begin
      ListPos := Idx;
      Break;
    End Else
      Inc(Idx);
  End;

  // If the path is empty, then remove the Assignment, if it exists.

  If Path = '' Then Begin

    If ListPos >= 0 then Begin

      For Idx := ListPos To Length(SP_Ass_List) -2 Do
        SP_Ass_List[Idx] := SP_Ass_List[Idx +1];
      SetLength(SP_Ass_List, Length(SP_Ass_List) -1);

    End;

  End Else Begin

    // Otherwise, check the path - does it exist in the host filesystem?

    ERRStr := Path;
    Path := SP_ConvertFilenameToHost(Path, Error);
    If DirectoryExists(String(Path)) Then Begin

      // Path exists, so add/update the assignment.

      Path := SP_ConvertHostFilename(Path, Error);

      If ListPos <> -1 Then Begin

        SP_Ass_List[ListPos] := Ass + #255 + Path;

      End Else Begin

        SetLength(SP_Ass_List, Length(SP_Ass_List) +1);
        SP_Ass_List[Length(SP_Ass_List) -1] := Ass + #255 + Path;

      End;

    End Else

      Error.Code := SP_ERR_DIR_NOT_FOUND;

  End;

  FileSection.Leave;

End;

Function SP_Decode_Assignment(Ass: aString; var Error: TSP_ErrorCode): aString;
Var
  Idx, ListPos: Integer;
Begin

  Result := '';
  If Ass = '' Then Begin
    ErrStr := '';
    Error.Code := SP_ERR_ASSIGNMENT_NOT_FOUND;
    Exit;
  End Else
    Error.Code := SP_ERR_OK;

  FileSection.Enter;

  If Ass[Length(Ass)] = ':' Then
    Ass := Copy(Ass, 1, Length(Ass) -1);

  // Now find the Assignment, if it exists.

  Idx := 0;
  ListPos := -1;
  While Idx < Length(SP_Ass_List) Do Begin
    If Lower(Copy(SP_Ass_List[Idx], 1, Pos(#255, SP_Ass_List[Idx]) -1)) = Lower(Ass) Then Begin
      ListPos := Idx;
      Break;
    End Else
      Inc(Idx);
  End;

  ERRStr := Ass + ':';
  If ListPos = -1 Then Begin
    If Ass = '$' Then
      Result := SP_ConvertHostFilename(aString(GetCurrentDir+PathDelim), Error)
    Else
      Error.Code := SP_ERR_ASSIGNMENT_NOT_FOUND;
  End Else Begin
    Result := Copy(SP_Ass_List[ListPos], Pos(#255, SP_Ass_List[ListPos]) +1, Length(SP_Ass_List[ListPos]));
    If Copy(Result, Length(Result), 1) <> '/' Then
      Result := Result + '/';
  End;

  FileSection.Leave;

End;

Function SP_ConvertPathToAssigns(Filename: aString): aString;
Var
  i, j, alen, pLen, aIdx: Integer;
  fName, Ass, Path, s: aString;
Begin

  alen := 0; aIdx := -1;
  fName := Lower(Filename);
  For i := 1 To Length(SP_Ass_List) -1 Do Begin
    s := SP_Ass_List[i];
    j := Pos(#255, s);
    Ass := Copy(s, 1, j -1);
    Path := Copy(s, j +1);
    pLen := Length(Path);
    If Lower(Path) = Copy(fName, 1, pLen) Then
      If aLen < pLen Then Begin
        aLen := pLen;
        aIdx := i;
      End;
  End;

  If aIdx > -1 Then Begin
    s := SP_Ass_List[aIdx];
    j := Pos(#255, s);
    Ass := Copy(s, 1, j -1);
    Path := Copy(s, j +1);
    pLen := Length(Path);
    Filename := Copy(Filename, pLen +1);
    While Filename[1] = '/' Do
      Filename := Copy(Filename, 2);
    Filename := Ass + ':' + Filename;
  End;

  Result := Filename;

End;

Function SP_DecomposePathWithAssigns(Path: aString): aString;
Var
  i, l: Integer;
  s: aString;
Begin

  For i := 0 To Length(SP_Ass_List) -1 Do Begin
    s := SP_Ass_List[i];
    s := Copy(s, 1, Pos(#255, s) -1) + ':';
    l := Length(s);
    If Copy(Path, 1, l) = s Then Begin
      Result := Copy(SP_Ass_List[i], Pos(#255, SP_Ass_List[i]) +1) + Copy(Path, l +1);
      Exit;
    End;
  End;

  Result := Path;

End;

Function SP_GetCurrentDir: aString;
Begin

  If Not PackageIsOpen Then
    Result := aString(GetCurrentDir)
  Else
    Result := SP_GetPackageDir;

End;

Function SP_DirectoryExists(Dir: aString): Boolean;
Var
  Error: TSP_ErrorCode;
Begin

  If PackageIsOpen And (Pos(':', Dir) = 0) then
    Result := SP_PackageDirExists(Dir, Error)
  Else
    Result := DirectoryExists(String(SP_ConvertFilenameToHost(Dir, Error)));

End;

Procedure SP_DeleteFile(Filename: aString; var Error: TSP_ErrorCode);
Begin

  ErrStr := Filename;
  If PackageIsOpen And (Pos(':', Filename) = 0) Then
    SP_DeletePackageFile(Filename, Error)
  Else Begin
    Filename := SP_ConvertFilenameToHost(Filename, Error);
    If Error.Code = SP_ERR_OK Then
      If FileExists(String(Filename)) Then
        DeleteFile(String(Filename))
      Else
        Error.Code := SP_ERR_FILE_MISSING;
  End;

End;

Procedure SP_SetCurrentDir(Dir: aString; Var Error: TSP_ErrorCode);
Begin

  ERRStr := Dir;
  If Dir <> '' Then
    If Not PackageIsOpen or (Pos(':', Dir) > 0) Then Begin
      Dir := SP_ConvertFilenameToHost(Dir, Error);
      If Not SetCurrentDir(String(Dir)) Then
        Error.Code := SP_ERR_DIR_NOT_FOUND;
    End Else
      SP_SetPackageDir(Dir, Error);

End;

Function SP_GetHostCWD: aString;
Var
  Error: TSP_ErrorCode;
Begin

  Result := SP_ConvertHostFilename(SP_GetCurrentDir, Error);

End;

Function SP_FixMask(Var FileSpec: aString): aString;
Var
  MinPos, MQ, MS, Idx: Integer;
Begin

  Result := SP_ExtractFileDir(FileSpec);
  FileSpec  := SP_ExtractFileName(FileSpec);

  // If there are '*' or '?' in the path string, then they should be in the filespec.

  MinPos := 0;
  MQ := Pos('?', Result);
  MS := Pos('*', Result);
  If (MQ > 0) or (MS > 0) Then Begin
    If MQ <> 0 Then
      If MS <> 0 Then Begin
        If MQ < MS Then
          MinPos := MQ
        Else
          MinPos := MS;
      End Else
        MinPos := MQ;
    If MS <> 0 Then
      If MQ <> 0 Then Begin
        If MS < MQ Then
          MinPos := MS
        Else
          MinPos := MQ;
      End Else
        MinPos := MS;
    Idx := MinPos;
    While Idx > 0 Do
      If Result[Idx] = PathDelim Then
        Break
      Else
        Dec(Idx);
    If Idx > 0 Then
      MinPos := Idx +1;
    FileSpec := Copy(Result, MinPos, Length(Result)) + FileSpec;
    Result := Copy(Result, 1, MinPos -1);
  End;

End;

Function SP_GetFileListRecursive(Var FileSpec: aString; WantEXP: Boolean; Var Error: TSP_ErrorCode): aString;
Var
  Files, FileSizes, Dirs: TAnsiStringList;
  ResultStr, PadStr, fSpec, pSpec: aString;
  Idx, FileCount, MaxSize, SizeCount: Integer;
Begin

  Result := '';

  Files := TAnsiStringList.Create;
  FileSizes := TAnsiStringList.Create;

  fSpec := FileSpec;
  pSpec := SP_FixMask(fSpec);

  SP_GetFileList(FileSpec, Files, FileSizes, Error, True);

  Idx := 0;
  Dirs := TAnsiStringList.Create;

  While Idx < Files.Count Do Begin

    If LongWord(Files.Objects[Idx]) = 1 Then Begin
      Dirs.Add(Files[Idx]);
      Files.Delete(Idx)
    End Else
      Inc(Idx);

  End;

  If Files.Count > 0 Then Begin

    ResultStr := 'File list for ' + FileSpec + #13#13;

    FileCount := 0;
    Files.Sort;

    MaxSize := 0;
    SizeCount := 0;
    For Idx := 0 To FileSizes.Count -1 Do Begin
      Inc(SizeCount, LongWord(FileSizes.Objects[Idx]));
      If Length(FileSizes[Idx]) > MaxSize Then
        MaxSize := Length(FileSizes[Idx]);
    End;

    If WantEXP Then Begin
      PadStr := aString(StringOfChar(' ', MaxSize +1));
      For Idx := 0 To Files.Count -1 Do Begin
        ResultStr := ResultStr + aString(SP_StringOfChar(' ', MaxSize - Length(FileSizes[Idx])) + FileSizes[Idx] + ' ' + Files[Idx])+#13;
        Inc(FileCount);
      End;
    End Else Begin
      PadStr := '';
      For Idx := 0 To Files.Count -1 Do Begin
        ResultStr := ResultStr + aString(Files[Idx])+#13;
        Inc(FileCount);
      End;
    End;

    ResultStr := ResultStr + #13#13;

  End;

  If pSpec <> '' Then
    SP_SetCurrentDir(pSpec, Error);

  For Idx := 0 To Dirs.Count -1 Do Begin

    SP_SetCurrentDir(Dirs[Idx], Error);
    FileSpec := fSpec;
    ResultStr := ResultStr + SP_GetFileListRecursive(FileSpec, WantEXP, Error);
    FileSpec := fSpec;
    SP_SetCurrentDir('..', Error);

  End;

  Result := ResultStr;

  FileSizes.Free;
  Files.Free;
  Dirs.Free;

End;

Procedure SP_GetFileList(Var FileSpec: aString; Var Files, FileSizes: TAnsiStringList; Var Error: TSP_ErrorCode; PreserveDirs: Boolean);
Var
  PathStr, lowerSpec, Name: aString;
  Idx: Integer;
  HostPath, IsDir: Boolean;
Begin

  HostPath := Pos(':', FileSpec) > 0;
  If HostPath or Not PackageIsOpen then
    FileSpec := SP_ConvertFilenameToHost(FileSpec, Error);

  If Error.Code <> SP_ERR_OK Then Exit;

  PathStr := SP_FixMask(FileSpec);

  // If no path was specified, then use the current folder, in host format.

  If PathStr = '' Then
    PathStr := SP_GetCurrentDir;

  If Not PackageIsOpen or HostPath Then Begin
    If Copy(PathStr, Length(PathStr), 1) <> PathDelim Then
      PathStr := PathStr + PathDelim;
  End Else
    If PackageIsOpen Then
      If Copy(PathStr, Length(PathStr), 1) <> '/' Then
        PathStr := PathStr + '/';

  ERRStr := PathStr;
  If SP_DirectoryExists(PathStr) Then Begin

    // Get all the files in the folder.

    SP_FindAll(PathStr + '*', Files, FileSizes);

    // Was the only file matching, actually the filespec? If so, is the filespec a folder?

    If (FileSpec <> '') And (Files.Count > 0) Then Begin
      LowerSpec := Lower(FileSpec);
      idx := 0;
      While idx < Files.Count Do Begin
        IsDir := NativeUInt(Files.Objects[idx]) = 1;  // no filesystem call needed
        Name  := Lower(aString(Files[idx]));
        If IsDir Then Begin
          If PreserveDirs Then
            Inc(idx)
          Else If WildComp(LowerSpec, Name) Or WildComp(LowerSpec, Name + PathDelim) Then
            Inc(idx)
          Else Begin
            Files.Delete(idx);
            FileSizes.Delete(idx);
          End;
        End Else Begin
          If WildComp(LowerSpec, Name) Then
            Inc(idx)
          Else Begin
            Files.Delete(idx);
            FileSizes.Delete(idx);
          End;
        End;
      End;
    End;

    If (Files.Count = 1) And (Lower(aString(Files[0])) = Lower(FileSpec)) And (SP_IsDirectory(PathStr + FileSpec)) Then Begin

      // If the filespec is a directory, and it's the only entry, then get all the files in that directory

      Files.Clear;
      FileSizes.Clear;
      SP_FindAll(PathStr + FileSpec + aString(PathDelim) + '*', Files, FileSizes);

    End;

    If (Files.Count > 0) And (Files[0] = '.') Then Begin Files.Delete(0); FileSizes.Delete(0); End;
    If (Files.Count > 0) And (Files[0] = '..') Then Begin Files.Delete(0); FileSizes.Delete(0); End;

    If PackageIsOpen And Not HostPath Then
      FileSpec := PathStr
    Else
      FileSpec := SP_ConvertHostFilename(PathStr, Error);

  End Else

    Error.Code := SP_ERR_DIR_NOT_FOUND;

End;

Function SP_IsDirectory(const Path: aString): Boolean;
var
  Attr: Integer;
  Error: TSP_ErrorCode;
begin
  If PackageIsOpen And (Pos(':', Path) = 0) Then
    Result := SP_PackageDirExists(Path, Error)
  Else Begin
    Attr := SysUtils.FileGetAttr(String(Path));
    Result := (Attr <> -1) and (Attr And SysUtils.faDirectory <> 0);
  End;
end;

Function SP_GetParentDir(Const Dir: aString): aString;
Var
  c: aChar;
  i: Integer;
Begin

  i := Length(Dir);
  While (i > 1) And (Dir[i] = '/') Do Dec(i);
  c := Dir[i];
  If c = ':' Then Begin
    Result := '/';
    Exit;
  End;

  While (i > 0) And Not (Dir[i] in [':', '/']) Do
    Dec(i);

  If i = 0 Then
    Result := '/'
  Else
    Result := Copy(Dir, 1, i);

End;

Procedure SP_RmDir(DirString: aString; var Error: TSP_ErrorCode);
Begin

  If PackageIsOpen And (Pos(':', DirString) = 0) Then
    SP_PackageDeleteDir(DirString, Error)
  Else Begin
    DirString := SP_ConvertFilenameToHost(DirString, Error);
    If DirectoryExists(String(DirString)) Then
      If Lower(DirString) <> lower(HOMEFOLDER) Then
        RmDir(String(Sp_ConvertFilenameToHost(DirString, Error)));
  End;

End;

Procedure SP_RmDirUnsafe(DirString: aString; Var Error: TSP_ErrorCode);
var
  Path: string;
  Search: TSearchRec;
begin
  Error.Code := SP_ERR_OK;
  Path := (IncludeTrailingPathDelimiter(String(SP_ConvertFilenameToHost(DirString, Error))));
  If DirectoryExists(Path) Then
    If Error.Code = SP_ERR_OK Then Begin
      If FindFirst(Path + '*.*', faAnyFile, Search) = 0 then
      try
        repeat
          if (Search.Attr and faDirectory) <> 0 then
            SP_RmDirUnSafe(aString(Path + Search.Name), Error)
          else
            DeleteFile(Path + Search.Name);
        until SysUtils.FindNext(Search) <> 0;
      finally
        FindClose(Search);
      end;
      RmDir(Path);
    End;
end;

Procedure SP_DeleteDirContents(DirString: aString; var Error: TSP_ErrorCode);
Var
  Dir: aString;
  Idx: Integer;
  Files, FileSizes: TAnsiStringList;
Begin

  Dir := DirString;
  Files := TAnsiStringList.Create;
  FileSizes := TAnsiStringList.Create;
  SP_GetFileList(DirString, Files, FileSizes, Error, False);

  If Files.Count > 0 Then Begin

    For Idx := 0 To Files.Count -1 Do Begin

      If LongWord(Files.Objects[Idx]) = 0 Then
        SP_DeleteFile(aString(Files[Idx]), Error)
      Else Begin
        If Copy(DirString, Length(DirString), 1) = '/' Then
          SP_DeleteDirContents(DirString + aString(Files[Idx]), Error)
        Else
          SP_DeleteDirContents(DirString + '/' + aString(Files[Idx]), Error);

        SP_RmDir(DirString, Error);

      End;

    End;

  End;

End;

Procedure SP_CopyFiles(FileSpec, Dest: aString; Overwrite: Boolean; var Error: TSP_ErrorCode);
Var
  Idx, FileID_Src, FileID_Dst, BytesRead, BuffSize: Integer;
  Buffer: Array of Byte;
  Files, FileSizes: TAnsiStringList;
  OrgFileSpecDir: aString;
Begin

  Files := TAnsiStringList.Create;
  FileSizes := TAnsiStringList.Create;
  BuffSize := 1024*1024-1;
  SetLength(Buffer, BuffSize);

  OrgFileSpecDir := SP_ExtractFileDir(FileSpec);

  ERRStr := FileSpec;
  SP_GetFileList(FileSpec, Files, FileSizes, Error, False);

  If Files.Count > 0 Then Begin

    ERRStr := Dest;
    If SP_DirectoryExists(Dest) Then Begin

      If Copy(Dest, Length(Dest), 1) <> '/' Then
        Dest := Dest + '/';

      For Idx := 0 To Files.Count -1 Do Begin

        If SP_FileExists(Dest + aString(Files[Idx])) Then
          If Overwrite Then
            SP_DeleteFile(Dest + aString(Files[Idx]), Error);

        If Not (SP_FileExists(Dest + aString(Files[Idx]))) And SP_DirectoryExists(Dest) Then Begin

          FileID_Src := SP_FileOpen(OrgFileSpecDir + aString(Files[Idx]), False, Error);
          FileID_Dst := SP_FileOpen(Dest + aString(Files[Idx]), True, Error);

          SP_FileSeek(FileID_Src, 0, Error);

          Repeat

            BytesRead := SP_FileRead(FileID_Src, @Buffer[0], BuffSize, Error);
            SP_FileWrite(FileID_Dst, @Buffer[0], BytesRead, Error);

          Until BytesRead = 0;

          SP_FileClose(FileID_Src, Error);
          SP_FileClose(FileID_Dst, Error);

        End Else Begin

          If Not SP_DirectoryExists(Dest) Then Begin
            ERRStr := Dest;
            Error.Code := SP_ERR_DIR_NOT_FOUND;
          End Else Begin
            ERRStr := Files[Idx];
            Error.Code := SP_ERR_FILE_ALREADY_EXISTS;
          End;
          Break;

        End;

      End;

    End Else

      Error.Code := SP_ERR_DIR_NOT_FOUND;

  End Else

    Error.Code := SP_ERR_FILE_MISSING;

  Files.Free;
  FileSizes.Free;

End;

Procedure SP_MoveFiles(FileSpec, Dest: aString; Overwrite: Boolean; var Error: TSP_ErrorCode);
Var
  Idx: Integer;
  Files, FileSizes: TAnsiStringList;
Begin

  // Moves the specified filespec to the directory specified. Dest must exist,
  // Filespec must reference at least one valid file.

  SP_CopyFiles(FileSpec, Dest, Overwrite, Error);

  If Error.Code = SP_ERR_OK Then Begin

    Files := TAnsiStringList.Create;
    FileSizes := TAnsiStringList.Create;

    SP_GetFileList(FileSpec, Files, FileSizes, Error, False);

    If Files.Count > 0 Then Begin

      For Idx := 0 To Files.Count -1 Do Begin

        SP_DeleteFile(FileSpec + aString(Files[Idx]), Error);
        If Error.Code <> SP_ERR_OK Then Break;

      End;

    End;

    Files.Free;
    FileSizes.Free;

  End;

End;

Procedure SP_MakeDir(Dir: aString; var Error: TSP_ErrorCode);
Begin

  ERRStr := Dir;
  If PackageIsOpen And (Pos(':', Dir) = 0) Then Begin

    SP_PackageCreateDir(Dir, Error);

  End Else Begin

    Dir := SP_ConvertFilenameToHost(Dir, Error);

    If SP_DirectoryExists(Dir) Then
      Error.Code := SP_ERR_DIR_ALREADY_EXISTS
    Else Begin
      {$IOChecks off}
      MkDir(String(Dir));
      If IOResult <> 0 Then
        Error.Code := SP_ERR_DIR_CREATE_FAILED;
      {$IOChecks on}
    End;

  End;

End;

Procedure SP_FileRename(Src, Dst: aString; var Error: TSP_ErrorCode);
Begin

  // Rename a host-filesystem file. Filename must be in host format.

  ErrStr := Src;
  If FileExists(String(Src)) Then begin

    {$IOChecks off}
    RenameFile(String(Src), String(Dst));
    If IOResult <> 0 Then
      Error.Code := SP_ERR_RENAME_FAILED;
    {$IOChecks on}

  End Else

    Error.Code := SP_ERR_FILE_MISSING;

End;

Procedure SP_RenameFiles(SrcFiles, DstFiles: aString; var Error: TSP_ErrorCode);
Var
  Idx, SrcPtr, DstPtr, FilePtr, pS, oSP: Integer;
  FileSpec, chkMask, SrcMask, DstMask, OrgFilename, NewFilename, nTerm: aString;
  Files, FileSizes: TAnsiStringList;
  SrcHost, DstHost, HostFS: Boolean;
Begin

  // Renames a Single file, a directory or a Wildcard-spec in *both* src and dst.

  SrcFiles := Lower(SrcFiles);
  DstFiles := Lower(DstFiles);

  SrcHost := Pos(':', SrcFiles) > 0;
  DstHost := Pos(':', DstFiles) > 0;

  If SrcHost <> DstHost Then Begin
    Error.Code := SP_ERR_PACKAGE_RENAME_HOST;
    Exit;
  End Else
    HostFS := SrcHost;


  If (Pos('?', SrcFiles) = 0) And (Pos('*', SrcFiles) = 0) And (Pos('?', DstFiles) = 0) And (Pos('*', DstFiles) = 0) Then Begin

    If HostFS Then
      SP_FileRename(SP_ConvertFilenameToHost(SrcFiles, Error), SP_ConvertFilenameToHost(DstFiles, Error), Error)
    Else
      SP_PackageFileRename(SrcFiles, DstFiles, Error);

  End Else Begin

    // Check masks for matches and validity.

    SrcMask := ''; Idx := Length(SrcFiles); While (Idx > 0) And (Not (SrcFiles[Idx] in ['/', ':'])) Do Begin SrcMask := SrcFiles[Idx] + SrcMask; Dec(Idx); End;
    DstMask := ''; Idx := Length(DstFiles); While (Idx > 0) And (Not (DstFiles[Idx] in ['/', ':'])) Do Begin DstMask := DstFiles[Idx] + DstMask; Dec(Idx); End;
    chkMask := ''; Idx := 1; While Idx < Length(SrcMask) Do Begin If SrcMask[Idx] in ['?', '*'] Then chkMask := chkMask + SrcMask[Idx]; Inc(Idx); End;

    DstPtr := 1;
    For Idx := 1 To Length(DstMask) Do
      If DstMask[Idx] in ['?', '*'] Then
        If DstPtr > Length(chkMask) then Begin
          Error.Code := SP_ERR_MISMATCHED_MASK;
          Exit;
        End Else
          If chkMask[DstPtr] = DstMask[Idx] Then
            Inc(DstPtr)
          Else Begin
            Error.Code := SP_ERR_MISMATCHED_MASK;
            Exit;
          End;

    // Masks appear fine - gather a list of files that match the source filespec.

    Files := TAnsiStringList.Create;
    FileSizes := TAnsiStringList.Create;

    ERRStr := SrcFiles;
    FileSpec := SrcFiles;
    SP_GetFileList(FileSpec, Files, FileSizes, Error, False);

    If Files.Count > 0 Then Begin

      For Idx := 0 To Files.Count -1 Do Begin

        OrgFilename := Lower(aString(Files[Idx]));
        NewFilename := '';

        SrcPtr := 1;
        DstPtr := 1;
        FilePtr := 1;

        While SrcPtr <= Length(SrcMask) Do Begin

          If SrcMask[SrcPtr] = '*' Then Begin
            oSP := SrcPtr +1;
            nTerm := '';
            Inc(SrcPtr);
            Inc(DstPtr);
            While (SrcPtr <= Length(SrcMask)) And (SrcMask[SrcPtr] <> '*') Do Begin
              nTerm := nTerm + SrcMask[SrcPtr];
              Inc(SrcPtr);
            End;
            If nTerm = '' Then Begin
              If SrcPtr > Length(SrcMask) Then
                NewFilename := NewFilename + Copy(OrgFilename, FilePtr, Length(OrgFilename));
            End Else Begin
              pS := Pos(nTerm, Copy(OrgFilename, FilePtr, Length(OrgFilename)));
              If pS > 0 Then Begin
                NewFilename := NewFilename + Copy(Copy(OrgFilename, FilePtr, Length(OrgFilename)), 1, pS -1);
                Inc(FilePtr, pS);
              End;
              SrcPtr := oSP;
            End;
          End Else
            If SrcMask[SrcPtr] = '?' Then Begin
              Inc(SrcPtr);
              Inc(DstPtr);
              NewFilename := NewFileName + OrgFilename[FilePtr];
              Inc(FilePtr);
            End Else Begin
              While (SrcPtr <= Length(SrcMask)) And Not (SrcMask[SrcPtr] in ['?', '*']) Do Begin
                Inc(SrcPtr);
                Inc(FilePtr);
              End;
              While (DstPtr <= Length(DstMask)) And Not (DstMask[DstPtr] in ['?', '*']) Do Begin
                NewFilename := NewFilename + DstMask[DstPtr];
                Inc(DstPtr);
              End;
            End;

        End;

        If HostFS Then
          SP_FileRename(SP_ConvertFilenameToHost(FileSpec + OrgFilename, Error), SP_ConvertFilenameToHost(NewFilename, Error), Error)
        Else
          SP_PackageFileRename(FileSpec + OrgFilename, NewFilename, Error);

      End;

    End Else

      Error.Code := SP_ERR_FILE_MISSING;

    Files.Free;
    FileSizes.Free;

  End;

End;

Function SP_ExtractFilename(Filename: aString): aString;
Var
  Idx: Integer;
Begin

  Result := '';

  If Filename <> '' Then Begin

    Idx :=  Length(Filename);
    While (Idx > 0) And not (Filename[Idx] in ['/', '\', ':']) Do Begin
      Result := Filename[Idx] + Result;
      Dec(Idx);
    End;

  End;

End;

Function SP_ExtractFileDir(Filename: aString): aString;
Var
  Idx: Integer;
Begin

  Result := '';

  If Filename <> '' Then Begin

    Idx := Length(Filename);
    While (Idx > 0) And not (Filename[Idx] in [':', '/', '\']) Do
      Dec(Idx);

    Result := Copy(Filename, 1, Idx);

  End;

End;

Procedure SP_AddToRecentFiles(Filename: aString; Saving: Boolean);
Var
  i, j, l, p: Integer;
  Exists: Boolean;
Begin

  // Convert backslash to slash

  Repeat
    p := Pos('\', Filename);
    If p > 0 Then
      Filename := Copy(Filename, 1, p -1) + '/' + Copy(Filename, p +1);
  Until p = 0;

  If Not Saving And Not SP_FileExists(Filename) then Exit;

  Filename := SP_ConvertPathToAssigns(Filename);
  If Lower(SP_Copy(Filename, 1, 2)) = 's:' Then Exit;

  // Check if the filename already exists in the recents list.

  i := 0;
  Exists := False;
  l := Length(SP_RecentFiles);
  While i < Length(SP_RecentFiles) Do
    If Lower(SP_RecentFiles[i]) = Lower(Filename) Then Begin
      Exists := True;
      Break;
    End Else
      Inc(i);

  If Exists Then Begin

    // Already exists - move it to the top of the list.
    // First, delete it. The rest of the routine will handle insertion at position 0
    For j := i To l -2 Do
      SP_RecentFiles[j] := SP_RecentFiles[j +1];

  End Else Begin

    If Length(SP_RecentFiles) < 10 Then Begin
      SetLength(SP_RecentFiles, l +1);
      Inc(l);
    End;

  End;

  // Now insert at position 0.

  For j := l -1 DownTo 1 Do
    SP_RecentFiles[j] := SP_RecentFiles[j -1];

  SP_RecentFiles[0] := Filename;
  SP_SaveRecentFiles;

End;

Procedure SP_LoadRecentFiles;
Var
  i: Integer;
  list: TAnsiStringlist;
Begin

  SetLength(SP_RecentFiles, 0);
  If SP_FileExists('s:recent_files') Then Begin

    list := TAnsiStringList.Create;
    list.LoadFromFile('s:recent_files');
    For i := list.Count -1 DownTo 0 Do
      If SP_FileExists(list[i]) Then
        SP_AddToRecentFiles(list[i], False);
    list.Free;

  End;

End;

Procedure SP_SaveRecentFiles;
Var
  i: Integer;
  list: TAnsiStringlist;
Begin

  list := TAnsiStringlist.Create;
  For i := 0 To Length(SP_RecentFiles) -1 Do
    list.Add(SP_RecentFiles[i]);
  list.SaveToFile('s:recent_files');
  list.Free;

End;

Initialization

  FileSection := TCriticalSection.Create;

Finalization

  FileSection.Free;

end.

