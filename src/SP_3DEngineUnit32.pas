// Copyright (C) 2026 By Paul Dunn
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

Unit SP_3DEngineUnit32;

// SpecBAS 3D engine — 32bpp render path.
//
// This unit provides a 32bpp-native render pipeline that runs alongside the
// 8bpp palette-index pipeline in SP_3DEngineUnit.  All model management,
// scene management, camera, lighting, and geometry is shared.  Only the
// rasterisers and their table infrastructure are new here.
//
// Pipeline differences from 8bpp:
//   Flat      : colour is ARGB from shade table, fog lerped in RGB space.
//   Gouraud   : vertex colours interpolated as RGB, no palette quantisation.
//   Textured  : texel palette index expanded through texture's ARGB palette,
//               then lit and fogged in RGB space.
//   Wireframe : calls SP_DrawLineTo32 with ARGB wire colour.
//
// Pixel format: $FF_RR_GG_BB (ARGB, A always $FF).
//
// Call SP_3D_Render32 in place of SP_3D_Render when the target window is
// 32bpp.  SP_Interpret_RENDER checks SCREENBPP and dispatches accordingly.

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}
{$INCLUDE SpecBAS.inc}

Interface

Uses
  Math, SysUtils, SyncObjs,
  SP_BankFiling, SP_BankManager, SP_Errors, SP_SysVars, SP_Graphics, SP_Graphics32, SP_Util,
  SP_3DEngineUnit;

// ---------------------------------------------------------------------------
// Public globals
// ---------------------------------------------------------------------------

Var
  // Window palette as ARGB LongWord, rebuilt with shade table.
  SP3D_BasePal32       : Array[0..255] of LongWord;

  // Fog colour as ARGB.
  SP3D_FogColour32     : LongWord;
  SP3D_FogDirty32      : Boolean;


// ---------------------------------------------------------------------------
// Public interface
// ---------------------------------------------------------------------------

Procedure SP_3D_InvalidateShadeTable32;
Procedure SP_3D_Render32(WindowID, SceneID, ThreadCount: Integer; Var Error: TSP_ErrorCode);

// ===========================================================================
Implementation
// ===========================================================================

Uses
  SP_Main, SP_Variables;

// ---------------------------------------------------------------------------
// SP_3D_InvalidateShadeTable32
// Call after any PALETTE command, same as SP_3D_InvalidateShadeTable.
// ---------------------------------------------------------------------------

Procedure SP_3D_InvalidateShadeTable32;
Begin
  SP3D_ShadeDirty32    := True;
  SP3D_FogDirty32      := True;
End;

// ---------------------------------------------------------------------------
// SP_3D_BuildShadeTable32
// Builds SP3D_ShadeTable32, SP3D_ShadeMultTable, and SP3D_BasePal32.
// Called once per palette change.
// ---------------------------------------------------------------------------

Procedure SP_3D_BuildBasePal32(Const Pal: Array of TP_Colour);
Var ci: Integer;
Begin
  For ci := 0 To 255 Do
    SP3D_BasePal32[ci] := $FF000000
                          Or (LongWord(Pal[ci].R) Shl 16)
                          Or (LongWord(Pal[ci].G) Shl 8)
                          Or  LongWord(Pal[ci].B);
  SP3D_ShadeDirty32 := False;
End;

// ---------------------------------------------------------------------------
// ApplyFog32
// Lerps an ARGB pixel toward the fog colour.
// ---------------------------------------------------------------------------

Function ApplyFog32(C: LongWord; FogI: Integer): LongWord; Inline;
Var R, G, B, FR, FG, FB : Integer;
Begin
  If FogI <= 0 Then Begin Result := C; Exit; End;
  If FogI >= 256 Then Begin Result := SP3D_FogColour32; Exit; End;
  R  := (C Shr 16) And $FF;  G  := (C Shr 8) And $FF;  B  := C And $FF;
  FR := (SP3D_FogColour32 Shr 16) And $FF;
  FG := (SP3D_FogColour32 Shr  8) And $FF;
  FB :=  SP3D_FogColour32         And $FF;
  R  := R + (FR - R) * FogI Shr 8;
  G  := G + (FG - G) * FogI Shr 8;
  B  := B + (FB - B) * FogI Shr 8;
  Result := $FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
End;

// Applies the scene light colour tint to an ARGB value without changing
// overall intensity. Used at gather time for Gouraud base colours.
Function TintByLight32(C: LongWord): LongWord; Inline;
Var R, G, B: Integer;
Begin
  R := Round(((C Shr 16) And $FF) * SP3D_Light_R);  If R > 255 Then R := 255;
  G := Round(((C Shr  8) And $FF) * SP3D_Light_G);  If G > 255 Then G := 255;
  B := Round(( C         And $FF) * SP3D_Light_B);  If B > 255 Then B := 255;
  Result := $FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
End;

Function ApplyInten32(C: LongWord; Inten: aFloat): LongWord; Inline;
Var R, G, B: Integer;
Begin
  R := Round(((C Shr 16) And $FF) * Inten * SP3D_Light_R);
  G := Round(((C Shr  8) And $FF) * Inten * SP3D_Light_G);
  B := Round(( C         And $FF) * Inten * SP3D_Light_B);
  If R > 255 Then R := 255;
  If G > 255 Then G := 255;
  If B > 255 Then B := 255;
  Result := $FF000000
            Or (LongWord(R) Shl 16)
            Or (LongWord(G) Shl 8)
            Or  LongWord(B);
End;

// ---------------------------------------------------------------------------
// 1. RasterFlat32  —  flat shaded, no fog
// ---------------------------------------------------------------------------

Procedure RasterFlat32(Const RF: pSP_RenderFace;
                       SurfPtr: pByte; Stride: Integer;
                       ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Var
  X0, Y0, X1, Y1, X2, Y2 : Integer;
  Colour32                : LongWord;
  DY, yStart, yEnd, Skip  : Integer;
  xLeft, xRight, y, px    : Integer;
  xL, xR, dxL, dxR       : Int64;
  RowPtr                  : pLongWord;

  Procedure Swap2(Var A, B: Integer); Inline;
  Var T: Integer; Begin T := A; A := B; B := T; End;

Begin
  X0 := RF^.SX[0]; Y0 := RF^.SY[0];
  X1 := RF^.SX[1]; Y1 := RF^.SY[1];
  X2 := RF^.SX[2]; Y2 := RF^.SY[2];
  Colour32 := ApplyInten32(RF^.Colour, RF^.IntenF);

  If (Y0 >= ClipY2) And (Y1 >= ClipY2) And (Y2 >= ClipY2) Then Exit;
  If (Y0 < ClipY1)  And (Y1 < ClipY1)  And (Y2 < ClipY1)  Then Exit;

  If Y0 > Y1 Then Begin Swap2(X0,X1); Swap2(Y0,Y1); End;
  If Y0 > Y2 Then Begin Swap2(X0,X2); Swap2(Y0,Y2); End;
  If Y1 > Y2 Then Begin Swap2(X1,X2); Swap2(Y1,Y2); End;
  If Y0 = Y2 Then Exit;

  DY  := Y2 - Y0;
  dxL := Int64(X2 - X0) * 65536 Div DY;
  xL  := Int64(X0) * 65536;

  If Y0 < Y1 Then Begin
    DY  := Y1 - Y0;
    dxR := Int64(X1 - X0) * 65536 Div DY;
    xR  := Int64(X0) * 65536;
    yStart := Y0; yEnd := Y1;
    If yStart < ClipY1 Then Begin
      Skip := ClipY1 - yStart;
      xL := xL + dxL*Skip; xR := xR + dxR*Skip;
      yStart := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR Shr 16);
      If xLeft > xRight Then Swap2(xLeft, xRight);
      If xLeft  < ClipX1     Then xLeft  := ClipX1;
      If xRight > ClipX2 - 1 Then xRight := ClipX2 - 1;
      If xLeft <= xRight Then Begin
        RowPtr := pLongWord(NativeUInt(SurfPtr) + LongWord(y * Stride + xLeft * 4));
        For px := xLeft To xRight Do Begin
          RowPtr^ := Colour32; Inc(RowPtr);
        End;
      End;
      xL := xL + dxL; xR := xR + dxR;
    End;
  End;

  xL := Int64(X0) * 65536 + dxL * Int64(Y1 - Y0);

  If Y1 < Y2 Then Begin
    DY  := Y2 - Y1;
    dxR := Int64(X2 - X1) * 65536 Div DY;
    xR  := Int64(X1) * 65536;
    yStart := Y1; yEnd := Y2;
    If yStart < ClipY1 Then Begin
      Skip := ClipY1 - yStart;
      xL := xL + dxL*Skip; xR := xR + dxR*Skip;
      yStart := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR Shr 16);
      If xLeft > xRight Then Swap2(xLeft, xRight);
      If xLeft  < ClipX1     Then xLeft  := ClipX1;
      If xRight > ClipX2 - 1 Then xRight := ClipX2 - 1;
      If xLeft <= xRight Then Begin
        RowPtr := pLongWord(NativeUInt(SurfPtr) + LongWord(y * Stride + xLeft * 4));
        For px := xLeft To xRight Do Begin
          RowPtr^ := Colour32; Inc(RowPtr);
        End;
      End;
      xL := xL + dxL; xR := xR + dxR;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 2. RasterFlat32Fog  —  flat shaded, fogged
// ---------------------------------------------------------------------------

Procedure RasterFlat32Fog(Const RF: pSP_RenderFace;
                          SurfPtr: pByte; Stride: Integer;
                          ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Var
  X0, Y0, X1, Y1, X2, Y2 : Integer;
  Colour32                : LongWord;
  DY, yStart, yEnd, Skip  : Integer;
  xLeft, xRight, y, px    : Integer;
  xL, xR, dxL, dxR       : Int64;
  RowPtr                  : pLongWord;

  Procedure Swap2(Var A, B: Integer); Inline;
  Var T: Integer; Begin T := A; A := B; B := T; End;

Begin
  X0 := RF^.SX[0]; Y0 := RF^.SY[0];
  X1 := RF^.SX[1]; Y1 := RF^.SY[1];
  X2 := RF^.SX[2]; Y2 := RF^.SY[2];
  Colour32 := ApplyFog32(ApplyInten32(RF^.Colour, RF^.IntenF), RF^.FogI);

  If (Y0 >= ClipY2) And (Y1 >= ClipY2) And (Y2 >= ClipY2) Then Exit;
  If (Y0 < ClipY1)  And (Y1 < ClipY1)  And (Y2 < ClipY1)  Then Exit;

  If Y0 > Y1 Then Begin Swap2(X0,X1); Swap2(Y0,Y1); End;
  If Y0 > Y2 Then Begin Swap2(X0,X2); Swap2(Y0,Y2); End;
  If Y1 > Y2 Then Begin Swap2(X1,X2); Swap2(Y1,Y2); End;
  If Y0 = Y2 Then Exit;

  DY  := Y2 - Y0;
  dxL := Int64(X2 - X0) * 65536 Div DY;
  xL  := Int64(X0) * 65536;

  If Y0 < Y1 Then Begin
    DY  := Y1 - Y0;
    dxR := Int64(X1 - X0) * 65536 Div DY;
    xR  := Int64(X0) * 65536;
    yStart := Y0; yEnd := Y1;
    If yStart < ClipY1 Then Begin
      Skip := ClipY1 - yStart;
      xL := xL + dxL*Skip; xR := xR + dxR*Skip;
      yStart := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR Shr 16);
      If xLeft > xRight Then Swap2(xLeft, xRight);
      If xLeft  < ClipX1     Then xLeft  := ClipX1;
      If xRight > ClipX2 - 1 Then xRight := ClipX2 - 1;
      If xLeft <= xRight Then Begin
        RowPtr := pLongWord(NativeUInt(SurfPtr) + LongWord(y * Stride + xLeft * 4));
        For px := xLeft To xRight Do Begin
          RowPtr^ := Colour32; Inc(RowPtr);
        End;
      End;
      xL := xL + dxL; xR := xR + dxR;
    End;
  End;

  xL := Int64(X0) * 65536 + dxL * Int64(Y1 - Y0);

  If Y1 < Y2 Then Begin
    DY  := Y2 - Y1;
    dxR := Int64(X2 - X1) * 65536 Div DY;
    xR  := Int64(X1) * 65536;
    yStart := Y1; yEnd := Y2;
    If yStart < ClipY1 Then Begin
      Skip := ClipY1 - yStart;
      xL := xL + dxL*Skip; xR := xR + dxR*Skip;
      yStart := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR Shr 16);
      If xLeft > xRight Then Swap2(xLeft, xRight);
      If xLeft  < ClipX1     Then xLeft  := ClipX1;
      If xRight > ClipX2 - 1 Then xRight := ClipX2 - 1;
      If xLeft <= xRight Then Begin
        RowPtr := pLongWord(NativeUInt(SurfPtr) + LongWord(y * Stride + xLeft * 4));
        For px := xLeft To xRight Do Begin
          RowPtr^ := Colour32; Inc(RowPtr);
        End;
      End;
      xL := xL + dxL; xR := xR + dxR;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 3. RasterGouraud32  —  Gouraud, no fog
// Handles both uniform and multi-colour cases — in 32bpp there is no LUT,
// RGB channels are interpolated directly from BaseARGB[0..2].
// ---------------------------------------------------------------------------

Procedure RasterGouraud32(Const RF: pSP_RenderFace;
                          SurfPtr: pByte; Stride: Integer;
                          ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Var
  X0, Y0, IB0,
  X1, Y1, IB1,
  X2, Y2, IB2    : Integer;
  R0, G0, B0,
  R1, G1, B1,
  R2, G2, B2     : Integer;
  DY, yStart, yEnd, Skip, y, px : Integer;
  xLeft, xRight, SpanW, Tx      : Integer;
  xL, dxL              : Int64;
  ibL, dibL            : Int64;
  rL, gL, bL           : Int64;
  drL, dgL, dbL        : Int64;
  xR_top, dxR_top      : Int64;
  ibR_top, dibR_top    : Int64;
  rR_top, gR_top, bR_top       : Int64;
  drR_top, dgR_top, dbR_top    : Int64;
  xR_bot, dxR_bot      : Int64;
  ibR_bot, dibR_bot    : Int64;
  rR_bot, gR_bot, bR_bot       : Int64;
  drR_bot, dgR_bot, dbR_bot    : Int64;
  sibL, sibR           : Int64;
  srL, sgL, sbL        : Int64;
  srR, sgR, sbR        : Int64;
  ibSpan, dibSpan      : Int64;
  rSpan, gSpan, bSpan  : Int64;
  drSpan, dgSpan, dbSpan : Int64;
  ibq, CR, CG, CB      : Integer;
  RowPtr               : pLongWord;

  Procedure Swap3(Var AX,AY,AC: Integer; Var AR,AG,AB: Integer;
                  Var BX,BY,BC: Integer; Var BR,BG,BB: Integer); Inline;
  Var TX,TY,TC,TR,TG,TB: Integer;
  Begin
    TX:=AX; TY:=AY; TC:=AC; TR:=AR; TG:=AG; TB:=AB;
    AX:=BX; AY:=BY; AC:=BC; AR:=BR; AG:=BG; AB:=BB;
    BX:=TX; BY:=TY; BC:=TC; BR:=TR; BG:=TG; BB:=TB;
  End;

Begin
  X0 := RF^.SX[0]; Y0 := RF^.SY[0]; IB0 := RF^.GC[0];
  X1 := RF^.SX[1]; Y1 := RF^.SY[1]; IB1 := RF^.GC[1];
  X2 := RF^.SX[2]; Y2 := RF^.SY[2]; IB2 := RF^.GC[2];
  R0 := (RF^.BaseARGB[0] Shr 16) And $FF;
  G0 := (RF^.BaseARGB[0] Shr  8) And $FF;
  B0 :=  RF^.BaseARGB[0]         And $FF;
  R1 := (RF^.BaseARGB[1] Shr 16) And $FF;
  G1 := (RF^.BaseARGB[1] Shr  8) And $FF;
  B1 :=  RF^.BaseARGB[1]         And $FF;
  R2 := (RF^.BaseARGB[2] Shr 16) And $FF;
  G2 := (RF^.BaseARGB[2] Shr  8) And $FF;
  B2 :=  RF^.BaseARGB[2]         And $FF;

  If (Y0 >= ClipY2) And (Y1 >= ClipY2) And (Y2 >= ClipY2) Then Exit;
  If (Y0 < ClipY1)  And (Y1 < ClipY1)  And (Y2 < ClipY1)  Then Exit;

  If Y0 > Y1 Then Swap3(X0,Y0,IB0,R0,G0,B0, X1,Y1,IB1,R1,G1,B1);
  If Y0 > Y2 Then Swap3(X0,Y0,IB0,R0,G0,B0, X2,Y2,IB2,R2,G2,B2);
  If Y1 > Y2 Then Swap3(X1,Y1,IB1,R1,G1,B1, X2,Y2,IB2,R2,G2,B2);
  If Y0 = Y2 Then Exit;

  DY   := Y2 - Y0;
  dxL  := Int64(X2 - X0) * 65536 Div DY;
  dibL := Int64(IB2 - IB0) * 65536 Div DY;
  drL  := Int64(R2 - R0)  * 65536 Div DY;
  dgL  := Int64(G2 - G0)  * 65536 Div DY;
  dbL  := Int64(B2 - B0)  * 65536 Div DY;
  xL   := Int64(X0) * 65536;
  ibL  := Int64(IB0) * 65536;
  rL   := Int64(R0)  * 65536;
  gL   := Int64(G0)  * 65536;
  bL   := Int64(B0)  * 65536;

  If Y0 < Y1 Then Begin
    DY       := Y1 - Y0;
    dxR_top  := Int64(X1 - X0) * 65536 Div DY;
    dibR_top := Int64(IB1 - IB0) * 65536 Div DY;
    drR_top  := Int64(R1 - R0)  * 65536 Div DY;
    dgR_top  := Int64(G1 - G0)  * 65536 Div DY;
    dbR_top  := Int64(B1 - B0)  * 65536 Div DY;
    xR_top   := Int64(X0) * 65536;
    ibR_top  := Int64(IB0) * 65536;
    rR_top   := Int64(R0)  * 65536;
    gR_top   := Int64(G0)  * 65536;
    bR_top   := Int64(B0)  * 65536;
    yStart := Y0; yEnd := Y1;
    If yStart < ClipY1 Then Begin
      Skip    := ClipY1 - yStart;
      xL      := xL + dxL*Skip;     ibL     := ibL + dibL*Skip;
      rL      := rL + drL*Skip;     gL      := gL + dgL*Skip;     bL  := bL + dbL*Skip;
      xR_top  := xR_top + dxR_top*Skip; ibR_top := ibR_top + dibR_top*Skip;
      rR_top  := rR_top + drR_top*Skip; gR_top  := gR_top + dgR_top*Skip; bR_top := bR_top + dbR_top*Skip;
      yStart  := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR_top Shr 16);
      If xLeft <= xRight Then Begin
        sibL := ibL;  srL := rL;  sgL := gL;  sbL := bL;
        sibR := ibR_top; srR := rR_top; sgR := gR_top; sbR := bR_top;
      End Else Begin
        Tx := xLeft; xLeft := xRight; xRight := Tx;
        sibL := ibR_top; srL := rR_top; sgL := gR_top; sbL := bR_top;
        sibR := ibL;     srR := rL;     sgR := gL;     sbR := bL;
      End;
      SpanW := xRight - xLeft;
      If SpanW > 0 Then Begin
        dibSpan := (sibR - sibL) Div SpanW;
        drSpan  := (srR - srL)   Div SpanW;
        dgSpan  := (sgR - sgL)   Div SpanW;
        dbSpan  := (sbR - sbL)   Div SpanW;
      End Else Begin dibSpan := 0; drSpan := 0; dgSpan := 0; dbSpan := 0; End;
      ibSpan := sibL; rSpan := srL; gSpan := sgL; bSpan := sbL;
      If xLeft < ClipX1 Then Begin
        Skip   := ClipX1 - xLeft;
        ibSpan := ibSpan + dibSpan*Skip; rSpan := rSpan + drSpan*Skip;
        gSpan  := gSpan  + dgSpan*Skip;  bSpan := bSpan + dbSpan*Skip;
        xLeft  := ClipX1;
      End;
      If xRight > ClipX2 - 1 Then xRight := ClipX2 - 1;
      If xLeft <= xRight Then Begin
        RowPtr := pLongWord(NativeUInt(SurfPtr) + LongWord(y * Stride + xLeft * 4));
        For px := xLeft To xRight Do Begin
          ibq := Integer(ibSpan Shr 16) And $FF;
          CR  := (Integer(rSpan Shr 16) * ibq) Shr 8;
          CG  := (Integer(gSpan Shr 16) * ibq) Shr 8;
          CB  := (Integer(bSpan Shr 16) * ibq) Shr 8;
          RowPtr^ := $FF000000 Or (LongWord(CR) Shl 16) Or (LongWord(CG) Shl 8) Or LongWord(CB);
          Inc(RowPtr);
          ibSpan := ibSpan + dibSpan; rSpan := rSpan + drSpan;
          gSpan  := gSpan  + dgSpan;  bSpan := bSpan + dbSpan;
        End;
      End;
      xL := xL + dxL; ibL := ibL + dibL;
      rL := rL + drL; gL  := gL + dgL; bL := bL + dbL;
      xR_top := xR_top + dxR_top; ibR_top := ibR_top + dibR_top;
      rR_top := rR_top + drR_top; gR_top  := gR_top + dgR_top; bR_top := bR_top + dbR_top;
    End;
  End;

  xL  := Int64(X0)*65536 + dxL  * Int64(Y1-Y0);
  ibL := Int64(IB0)*65536 + dibL * Int64(Y1-Y0);
  rL  := Int64(R0)*65536  + drL  * Int64(Y1-Y0);
  gL  := Int64(G0)*65536  + dgL  * Int64(Y1-Y0);
  bL  := Int64(B0)*65536  + dbL  * Int64(Y1-Y0);

  If Y1 < Y2 Then Begin
    DY       := Y2 - Y1;
    dxR_bot  := Int64(X2 - X1) * 65536 Div DY;
    dibR_bot := Int64(IB2 - IB1) * 65536 Div DY;
    drR_bot  := Int64(R2 - R1)  * 65536 Div DY;
    dgR_bot  := Int64(G2 - G1)  * 65536 Div DY;
    dbR_bot  := Int64(B2 - B1)  * 65536 Div DY;
    xR_bot   := Int64(X1) * 65536;
    ibR_bot  := Int64(IB1) * 65536;
    rR_bot   := Int64(R1)  * 65536;
    gR_bot   := Int64(G1)  * 65536;
    bR_bot   := Int64(B1)  * 65536;
    yStart := Y1; yEnd := Y2;
    If yStart < ClipY1 Then Begin
      Skip    := ClipY1 - yStart;
      xL      := xL + dxL*Skip;     ibL     := ibL + dibL*Skip;
      rL      := rL + drL*Skip;     gL      := gL + dgL*Skip;     bL  := bL + dbL*Skip;
      xR_bot  := xR_bot + dxR_bot*Skip; ibR_bot := ibR_bot + dibR_bot*Skip;
      rR_bot  := rR_bot + drR_bot*Skip; gR_bot  := gR_bot + dgR_bot*Skip; bR_bot := bR_bot + dbR_bot*Skip;
      yStart  := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR_bot Shr 16);
      If xLeft <= xRight Then Begin
        sibL := ibL;  srL := rL;  sgL := gL;  sbL := bL;
        sibR := ibR_bot; srR := rR_bot; sgR := gR_bot; sbR := bR_bot;
      End Else Begin
        Tx := xLeft; xLeft := xRight; xRight := Tx;
        sibL := ibR_bot; srL := rR_bot; sgL := gR_bot; sbL := bR_bot;
        sibR := ibL;     srR := rL;     sgR := gL;     sbR := bL;
      End;
      SpanW := xRight - xLeft;
      If SpanW > 0 Then Begin
        dibSpan := (sibR - sibL) Div SpanW;
        drSpan  := (srR - srL)   Div SpanW;
        dgSpan  := (sgR - sgL)   Div SpanW;
        dbSpan  := (sbR - sbL)   Div SpanW;
      End Else Begin dibSpan := 0; drSpan := 0; dgSpan := 0; dbSpan := 0; End;
      ibSpan := sibL; rSpan := srL; gSpan := sgL; bSpan := sbL;
      If xLeft < ClipX1 Then Begin
        Skip   := ClipX1 - xLeft;
        ibSpan := ibSpan + dibSpan*Skip; rSpan := rSpan + drSpan*Skip;
        gSpan  := gSpan  + dgSpan*Skip;  bSpan := bSpan + dbSpan*Skip;
        xLeft  := ClipX1;
      End;
      If xRight > ClipX2 - 1 Then xRight := ClipX2 - 1;
      If xLeft <= xRight Then Begin
        RowPtr := pLongWord(NativeUInt(SurfPtr) + LongWord(y * Stride + xLeft * 4));
        For px := xLeft To xRight Do Begin
          ibq := Integer(ibSpan Shr 16) And $FF;
          CR  := (Integer(rSpan Shr 16) * ibq) Shr 8;
          CG  := (Integer(gSpan Shr 16) * ibq) Shr 8;
          CB  := (Integer(bSpan Shr 16) * ibq) Shr 8;
          RowPtr^ := $FF000000 Or (LongWord(CR) Shl 16) Or (LongWord(CG) Shl 8) Or LongWord(CB);
          Inc(RowPtr);
          ibSpan := ibSpan + dibSpan; rSpan := rSpan + drSpan;
          gSpan  := gSpan  + dgSpan;  bSpan := bSpan + dbSpan;
        End;
      End;
      xL := xL + dxL; ibL := ibL + dibL;
      rL := rL + drL; gL  := gL + dgL; bL := bL + dbL;
      xR_bot := xR_bot + dxR_bot; ibR_bot := ibR_bot + dibR_bot;
      rR_bot := rR_bot + drR_bot; gR_bot  := gR_bot + dgR_bot; bR_bot := bR_bot + dbR_bot;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 4. RasterGouraud32Fog  —  Gouraud, fogged
// ---------------------------------------------------------------------------

Procedure RasterGouraud32Fog(Const RF: pSP_RenderFace;
                             SurfPtr: pByte; Stride: Integer;
                             ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Var
  X0, Y0, IB0,
  X1, Y1, IB1,
  X2, Y2, IB2    : Integer;
  R0, G0, B0,
  R1, G1, B1,
  R2, G2, B2     : Integer;
  FogI           : Integer;
  FogR, FogG, FogB : Integer;
  DY, yStart, yEnd, Skip, y, px : Integer;
  xLeft, xRight, SpanW, Tx      : Integer;
  xL, dxL              : Int64;
  ibL, dibL            : Int64;
  rL, gL, bL           : Int64;
  drL, dgL, dbL        : Int64;
  xR_top, dxR_top      : Int64;
  ibR_top, dibR_top    : Int64;
  rR_top, gR_top, bR_top       : Int64;
  drR_top, dgR_top, dbR_top    : Int64;
  xR_bot, dxR_bot      : Int64;
  ibR_bot, dibR_bot    : Int64;
  rR_bot, gR_bot, bR_bot       : Int64;
  drR_bot, dgR_bot, dbR_bot    : Int64;
  sibL, sibR           : Int64;
  srL, sgL, sbL        : Int64;
  srR, sgR, sbR        : Int64;
  ibSpan, dibSpan      : Int64;
  rSpan, gSpan, bSpan  : Int64;
  drSpan, dgSpan, dbSpan : Int64;
  ibq, CR, CG, CB      : Integer;
  RowPtr               : pLongWord;

  Procedure Swap3(Var AX,AY,AC: Integer; Var AR,AG,AB: Integer;
                  Var BX,BY,BC: Integer; Var BR,BG,BB: Integer); Inline;
  Var TX,TY,TC,TR,TG,TB: Integer;
  Begin
    TX:=AX; TY:=AY; TC:=AC; TR:=AR; TG:=AG; TB:=AB;
    AX:=BX; AY:=BY; AC:=BC; AR:=BR; AG:=BG; AB:=BB;
    BX:=TX; BY:=TY; BC:=TC; BR:=TR; BG:=TG; BB:=TB;
  End;

Begin
  X0 := RF^.SX[0]; Y0 := RF^.SY[0]; IB0 := RF^.GC[0];
  X1 := RF^.SX[1]; Y1 := RF^.SY[1]; IB1 := RF^.GC[1];
  X2 := RF^.SX[2]; Y2 := RF^.SY[2]; IB2 := RF^.GC[2];
  R0 := (RF^.BaseARGB[0] Shr 16) And $FF;
  G0 := (RF^.BaseARGB[0] Shr  8) And $FF;
  B0 :=  RF^.BaseARGB[0]         And $FF;
  R1 := (RF^.BaseARGB[1] Shr 16) And $FF;
  G1 := (RF^.BaseARGB[1] Shr  8) And $FF;
  B1 :=  RF^.BaseARGB[1]         And $FF;
  R2 := (RF^.BaseARGB[2] Shr 16) And $FF;
  G2 := (RF^.BaseARGB[2] Shr  8) And $FF;
  B2 :=  RF^.BaseARGB[2]         And $FF;
  FogI := RF^.FogI;
  FogR := (SP3D_FogColour32 Shr 16) And $FF;
  FogG := (SP3D_FogColour32 Shr  8) And $FF;
  FogB :=  SP3D_FogColour32         And $FF;

  If (Y0 >= ClipY2) And (Y1 >= ClipY2) And (Y2 >= ClipY2) Then Exit;
  If (Y0 < ClipY1)  And (Y1 < ClipY1)  And (Y2 < ClipY1)  Then Exit;

  If Y0 > Y1 Then Swap3(X0,Y0,IB0,R0,G0,B0, X1,Y1,IB1,R1,G1,B1);
  If Y0 > Y2 Then Swap3(X0,Y0,IB0,R0,G0,B0, X2,Y2,IB2,R2,G2,B2);
  If Y1 > Y2 Then Swap3(X1,Y1,IB1,R1,G1,B1, X2,Y2,IB2,R2,G2,B2);
  If Y0 = Y2 Then Exit;

  DY   := Y2 - Y0;
  dxL  := Int64(X2 - X0) * 65536 Div DY;
  dibL := Int64(IB2 - IB0) * 65536 Div DY;
  drL  := Int64(R2 - R0)  * 65536 Div DY;
  dgL  := Int64(G2 - G0)  * 65536 Div DY;
  dbL  := Int64(B2 - B0)  * 65536 Div DY;
  xL   := Int64(X0) * 65536;
  ibL  := Int64(IB0) * 65536;
  rL   := Int64(R0)  * 65536;
  gL   := Int64(G0)  * 65536;
  bL   := Int64(B0)  * 65536;

  If Y0 < Y1 Then Begin
    DY       := Y1 - Y0;
    dxR_top  := Int64(X1 - X0) * 65536 Div DY;
    dibR_top := Int64(IB1 - IB0) * 65536 Div DY;
    drR_top  := Int64(R1 - R0)  * 65536 Div DY;
    dgR_top  := Int64(G1 - G0)  * 65536 Div DY;
    dbR_top  := Int64(B1 - B0)  * 65536 Div DY;
    xR_top   := Int64(X0) * 65536;
    ibR_top  := Int64(IB0) * 65536;
    rR_top   := Int64(R0)  * 65536;
    gR_top   := Int64(G0)  * 65536;
    bR_top   := Int64(B0)  * 65536;
    yStart := Y0; yEnd := Y1;
    If yStart < ClipY1 Then Begin
      Skip    := ClipY1 - yStart;
      xL      := xL + dxL*Skip;     ibL     := ibL + dibL*Skip;
      rL      := rL + drL*Skip;     gL      := gL + dgL*Skip;     bL  := bL + dbL*Skip;
      xR_top  := xR_top + dxR_top*Skip; ibR_top := ibR_top + dibR_top*Skip;
      rR_top  := rR_top + drR_top*Skip; gR_top  := gR_top + dgR_top*Skip; bR_top := bR_top + dbR_top*Skip;
      yStart  := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR_top Shr 16);
      If xLeft <= xRight Then Begin
        sibL := ibL;  srL := rL;  sgL := gL;  sbL := bL;
        sibR := ibR_top; srR := rR_top; sgR := gR_top; sbR := bR_top;
      End Else Begin
        Tx := xLeft; xLeft := xRight; xRight := Tx;
        sibL := ibR_top; srL := rR_top; sgL := gR_top; sbL := bR_top;
        sibR := ibL;     srR := rL;     sgR := gL;     sbR := bL;
      End;
      SpanW := xRight - xLeft;
      If SpanW > 0 Then Begin
        dibSpan := (sibR - sibL) Div SpanW;
        drSpan  := (srR - srL)   Div SpanW;
        dgSpan  := (sgR - sgL)   Div SpanW;
        dbSpan  := (sbR - sbL)   Div SpanW;
      End Else Begin dibSpan := 0; drSpan := 0; dgSpan := 0; dbSpan := 0; End;
      ibSpan := sibL; rSpan := srL; gSpan := sgL; bSpan := sbL;
      If xLeft < ClipX1 Then Begin
        Skip   := ClipX1 - xLeft;
        ibSpan := ibSpan + dibSpan*Skip; rSpan := rSpan + drSpan*Skip;
        gSpan  := gSpan  + dgSpan*Skip;  bSpan := bSpan + dbSpan*Skip;
        xLeft  := ClipX1;
      End;
      If xRight > ClipX2 - 1 Then xRight := ClipX2 - 1;
      If xLeft <= xRight Then Begin
        RowPtr := pLongWord(NativeUInt(SurfPtr) + LongWord(y * Stride + xLeft * 4));
        For px := xLeft To xRight Do Begin
          ibq := Integer(ibSpan Shr 16) And $FF;
          CR  := (Integer(rSpan Shr 16) * ibq) Shr 8;
          CG  := (Integer(gSpan Shr 16) * ibq) Shr 8;
          CB  := (Integer(bSpan Shr 16) * ibq) Shr 8;
          CR  := CR + (FogR - CR) * FogI Shr 8;
          CG  := CG + (FogG - CG) * FogI Shr 8;
          CB  := CB + (FogB - CB) * FogI Shr 8;
          RowPtr^ := $FF000000 Or (LongWord(CR) Shl 16) Or (LongWord(CG) Shl 8) Or LongWord(CB);
          Inc(RowPtr);
          ibSpan := ibSpan + dibSpan; rSpan := rSpan + drSpan;
          gSpan  := gSpan  + dgSpan;  bSpan := bSpan + dbSpan;
        End;
      End;
      xL := xL + dxL; ibL := ibL + dibL;
      rL := rL + drL; gL  := gL + dgL; bL := bL + dbL;
      xR_top := xR_top + dxR_top; ibR_top := ibR_top + dibR_top;
      rR_top := rR_top + drR_top; gR_top  := gR_top + dgR_top; bR_top := bR_top + dbR_top;
    End;
  End;

  xL  := Int64(X0)*65536 + dxL  * Int64(Y1-Y0);
  ibL := Int64(IB0)*65536 + dibL * Int64(Y1-Y0);
  rL  := Int64(R0)*65536  + drL  * Int64(Y1-Y0);
  gL  := Int64(G0)*65536  + dgL  * Int64(Y1-Y0);
  bL  := Int64(B0)*65536  + dbL  * Int64(Y1-Y0);

  If Y1 < Y2 Then Begin
    DY       := Y2 - Y1;
    dxR_bot  := Int64(X2 - X1) * 65536 Div DY;
    dibR_bot := Int64(IB2 - IB1) * 65536 Div DY;
    drR_bot  := Int64(R2 - R1)  * 65536 Div DY;
    dgR_bot  := Int64(G2 - G1)  * 65536 Div DY;
    dbR_bot  := Int64(B2 - B1)  * 65536 Div DY;
    xR_bot   := Int64(X1) * 65536;
    ibR_bot  := Int64(IB1) * 65536;
    rR_bot   := Int64(R1)  * 65536;
    gR_bot   := Int64(G1)  * 65536;
    bR_bot   := Int64(B1)  * 65536;
    yStart := Y1; yEnd := Y2;
    If yStart < ClipY1 Then Begin
      Skip    := ClipY1 - yStart;
      xL      := xL + dxL*Skip;     ibL     := ibL + dibL*Skip;
      rL      := rL + drL*Skip;     gL      := gL + dgL*Skip;     bL  := bL + dbL*Skip;
      xR_bot  := xR_bot + dxR_bot*Skip; ibR_bot := ibR_bot + dibR_bot*Skip;
      rR_bot  := rR_bot + drR_bot*Skip; gR_bot  := gR_bot + dgR_bot*Skip; bR_bot := bR_bot + dbR_bot*Skip;
      yStart  := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR_bot Shr 16);
      If xLeft <= xRight Then Begin
        sibL := ibL;  srL := rL;  sgL := gL;  sbL := bL;
        sibR := ibR_bot; srR := rR_bot; sgR := gR_bot; sbR := bR_bot;
      End Else Begin
        Tx := xLeft; xLeft := xRight; xRight := Tx;
        sibL := ibR_bot; srL := rR_bot; sgL := gR_bot; sbL := bR_bot;
        sibR := ibL;     srR := rL;     sgR := gL;     sbR := bL;
      End;
      SpanW := xRight - xLeft;
      If SpanW > 0 Then Begin
        dibSpan := (sibR - sibL) Div SpanW;
        drSpan  := (srR - srL)   Div SpanW;
        dgSpan  := (sgR - sgL)   Div SpanW;
        dbSpan  := (sbR - sbL)   Div SpanW;
      End Else Begin dibSpan := 0; drSpan := 0; dgSpan := 0; dbSpan := 0; End;
      ibSpan := sibL; rSpan := srL; gSpan := sgL; bSpan := sbL;
      If xLeft < ClipX1 Then Begin
        Skip   := ClipX1 - xLeft;
        ibSpan := ibSpan + dibSpan*Skip; rSpan := rSpan + drSpan*Skip;
        gSpan  := gSpan  + dgSpan*Skip;  bSpan := bSpan + dbSpan*Skip;
        xLeft  := ClipX1;
      End;
      If xRight > ClipX2 - 1 Then xRight := ClipX2 - 1;
      If xLeft <= xRight Then Begin
        RowPtr := pLongWord(NativeUInt(SurfPtr) + LongWord(y * Stride + xLeft * 4));
        For px := xLeft To xRight Do Begin
          ibq := Integer(ibSpan Shr 16) And $FF;
          CR  := (Integer(rSpan Shr 16) * ibq) Shr 8;
          CG  := (Integer(gSpan Shr 16) * ibq) Shr 8;
          CB  := (Integer(bSpan Shr 16) * ibq) Shr 8;
          CR  := CR + (FogR - CR) * FogI Shr 8;
          CG  := CG + (FogG - CG) * FogI Shr 8;
          CB  := CB + (FogB - CB) * FogI Shr 8;
          RowPtr^ := $FF000000 Or (LongWord(CR) Shl 16) Or (LongWord(CG) Shl 8) Or LongWord(CB);
          Inc(RowPtr);
          ibSpan := ibSpan + dibSpan; rSpan := rSpan + drSpan;
          gSpan  := gSpan  + dgSpan;  bSpan := bSpan + dbSpan;
        End;
      End;
      xL := xL + dxL; ibL := ibL + dibL;
      rL := rL + drL; gL  := gL + dgL; bL := bL + dbL;
      xR_bot := xR_bot + dxR_bot; ibR_bot := ibR_bot + dibR_bot;
      rR_bot := rR_bot + drR_bot; gR_bot  := gR_bot + dgR_bot; bR_bot := bR_bot + dbR_bot;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// Textured 32bpp procs — 8 variants (Pow2/NPOT × Opaque/Transp × Plain/Fog)
// RF^.TexPal must be set at gather time to the graphic bank palette pointer.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 5. RasterTexPow2Opaque32  —  pow2, opaque, no fog
// ---------------------------------------------------------------------------

Procedure RasterTexPow2Opaque32(Const RF: pSP_RenderFace;
                                SurfPtr: pByte; Stride: Integer;
                                ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2            : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                   : aFloat;
  IntenIR, IntenIG, IntenIB : Integer;
  TexData                       : pByte;
  TexPal                        : pTP_Colour;
  TexW, TexWMask, TexHMask : Integer;
  DY, yStart, yEnd, Skip, y     : Integer;
  xLeft, xRight, SpanW          : Integer;
  SubEnd, SubW, px, ppx, tInt   : Integer;
  dxL, xL, dxR, xR              : Int64;
  dUZL,dVZL,dWZL                : aFloat;
  dUZR,dVZR,dWZR                : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR      : aFloat;
  ULeft,VLeft,URight,VRight     : aFloat;
  U_fp,V_fp,dU_fp,dV_fp         : Int64;
  UZSpan,VZSpan,WZSpan          : aFloat;
  dUZSpan,dVZSpan,dWZSpan       : aFloat;
  UZNext,VZNext,WZNext          : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                        : Integer;
  BaseC                         : LongWord;
  R, G, B                       : Integer;
  RowPtr                        : pLongWord;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenIR:=RF^.IntenIR; IntenIG:=RF^.IntenIG; IntenIB:=RF^.IntenIB; TexData:=RF^.TexData; TexPal:=RF^.TexPal;
  TexW:=RF^.TexW; TexWMask:=RF^.TexWMask; TexHMask:=RF^.TexHMask;

  If (Y0>=ClipY2) And (Y1>=ClipY2) And (Y2>=ClipY2) Then Exit;
  If (Y0<ClipY1)  And (Y1<ClipY1)  And (Y2<ClipY1)  Then Exit;
  If Y0>Y1 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X1,Y1,UZ1,VZ1,WZ1);
  If Y0>Y2 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X2,Y2,UZ2,VZ2,WZ2);
  If Y1>Y2 Then SwapIntPair(X1,Y1,UZ1,VZ1,WZ1,X2,Y2,UZ2,VZ2,WZ2);
  If Y0=Y2 Then Exit;

  DY:=Y2-Y0; dxL:=Int64(X2-X0)*65536 Div DY; dUZL:=(UZ2-UZ0)/DY; dVZL:=(VZ2-VZ0)/DY; dWZL:=(WZ2-WZ0)/DY;
  xL:=Int64(X0)*65536; UZL:=UZ0; VZL:=VZ0; WZL:=WZ0;

  If Y0<Y1 Then Begin
    DY:=Y1-Y0; dxR:=Int64(X1-X0)*65536 Div DY; dUZR:=(UZ1-UZ0)/DY; dVZR:=(VZ1-VZ0)/DY; dWZR:=(WZ1-WZ0)/DY;
    xR:=Int64(X0)*65536; UZR:=UZ0; VZR:=VZ0; WZR:=WZ0;
    yStart:=Y0; yEnd:=Y1;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) And TexHMask)*TexW+(Integer(U_fp Shr 16) And TexWMask);
            BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(pByte(NativeUInt(TexData)+LongWord(TexIdx))^)*SizeOf(TP_Colour))^.L;
            R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
            G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
            B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
            RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;

  xL:=Int64(X0)*65536+dxL*Int64(Y1-Y0); UZL:=UZ0+dUZL*(Y1-Y0); VZL:=VZ0+dVZL*(Y1-Y0); WZL:=WZ0+dWZL*(Y1-Y0);
  If Y1<Y2 Then Begin
    DY:=Y2-Y1; dxR:=Int64(X2-X1)*65536 Div DY; dUZR:=(UZ2-UZ1)/DY; dVZR:=(VZ2-VZ1)/DY; dWZR:=(WZ2-WZ1)/DY;
    xR:=Int64(X1)*65536; UZR:=UZ1; VZR:=VZ1; WZR:=WZ1;
    yStart:=Y1; yEnd:=Y2;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) And TexHMask)*TexW+(Integer(U_fp Shr 16) And TexWMask);
            BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(pByte(NativeUInt(TexData)+LongWord(TexIdx))^)*SizeOf(TP_Colour))^.L;
            R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
            G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
            B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
            RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 6. RasterTexPow2Opaque32Fog  —  pow2, opaque, fogged
// ---------------------------------------------------------------------------

Procedure RasterTexPow2Opaque32Fog(Const RF: pSP_RenderFace;
                                   SurfPtr: pByte; Stride: Integer;
                                   ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2            : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                   : aFloat;
  IntenIR, IntenIG, IntenIB, FogI : Integer;
  FogR, FogG, FogB              : Integer;
  TexData                       : pByte;
  TexPal                        : pTP_Colour;
  TexW, TexWMask, TexHMask : Integer;
  DY, yStart, yEnd, Skip, y     : Integer;
  xLeft, xRight, SpanW          : Integer;
  SubEnd, SubW, px, ppx, tInt   : Integer;
  dxL, xL, dxR, xR              : Int64;
  dUZL,dVZL,dWZL                : aFloat;
  dUZR,dVZR,dWZR                : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR      : aFloat;
  ULeft,VLeft,URight,VRight     : aFloat;
  U_fp,V_fp,dU_fp,dV_fp         : Int64;
  UZSpan,VZSpan,WZSpan          : aFloat;
  dUZSpan,dVZSpan,dWZSpan       : aFloat;
  UZNext,VZNext,WZNext          : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                        : Integer;
  BaseC                         : LongWord;
  R, G, B                       : Integer;
  RowPtr                        : pLongWord;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenIR:=RF^.IntenIR; IntenIG:=RF^.IntenIG; IntenIB:=RF^.IntenIB; FogI:=RF^.FogI;
  FogR:=(SP3D_FogColour32 Shr 16) And $FF;
  FogG:=(SP3D_FogColour32 Shr  8) And $FF;
  FogB:= SP3D_FogColour32         And $FF;
  TexData:=RF^.TexData; TexPal:=RF^.TexPal;
  TexW:=RF^.TexW; TexWMask:=RF^.TexWMask; TexHMask:=RF^.TexHMask;

  If (Y0>=ClipY2) And (Y1>=ClipY2) And (Y2>=ClipY2) Then Exit;
  If (Y0<ClipY1)  And (Y1<ClipY1)  And (Y2<ClipY1)  Then Exit;
  If Y0>Y1 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X1,Y1,UZ1,VZ1,WZ1);
  If Y0>Y2 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X2,Y2,UZ2,VZ2,WZ2);
  If Y1>Y2 Then SwapIntPair(X1,Y1,UZ1,VZ1,WZ1,X2,Y2,UZ2,VZ2,WZ2);
  If Y0=Y2 Then Exit;

  DY:=Y2-Y0; dxL:=Int64(X2-X0)*65536 Div DY; dUZL:=(UZ2-UZ0)/DY; dVZL:=(VZ2-VZ0)/DY; dWZL:=(WZ2-WZ0)/DY;
  xL:=Int64(X0)*65536; UZL:=UZ0; VZL:=VZ0; WZL:=WZ0;

  If Y0<Y1 Then Begin
    DY:=Y1-Y0; dxR:=Int64(X1-X0)*65536 Div DY; dUZR:=(UZ1-UZ0)/DY; dVZR:=(VZ1-VZ0)/DY; dWZR:=(WZ1-WZ0)/DY;
    xR:=Int64(X0)*65536; UZR:=UZ0; VZR:=VZ0; WZR:=WZ0;
    yStart:=Y0; yEnd:=Y1;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) And TexHMask)*TexW+(Integer(U_fp Shr 16) And TexWMask);
            BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(pByte(NativeUInt(TexData)+LongWord(TexIdx))^)*SizeOf(TP_Colour))^.L;
            R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
            G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
            B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
            R:=R+(FogR-R)*FogI Shr 8; G:=G+(FogG-G)*FogI Shr 8; B:=B+(FogB-B)*FogI Shr 8;
            RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;

  xL:=Int64(X0)*65536+dxL*Int64(Y1-Y0); UZL:=UZ0+dUZL*(Y1-Y0); VZL:=VZ0+dVZL*(Y1-Y0); WZL:=WZ0+dWZL*(Y1-Y0);
  If Y1<Y2 Then Begin
    DY:=Y2-Y1; dxR:=Int64(X2-X1)*65536 Div DY; dUZR:=(UZ2-UZ1)/DY; dVZR:=(VZ2-VZ1)/DY; dWZR:=(WZ2-WZ1)/DY;
    xR:=Int64(X1)*65536; UZR:=UZ1; VZR:=VZ1; WZR:=WZ1;
    yStart:=Y1; yEnd:=Y2;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) And TexHMask)*TexW+(Integer(U_fp Shr 16) And TexWMask);
            BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(pByte(NativeUInt(TexData)+LongWord(TexIdx))^)*SizeOf(TP_Colour))^.L;
            R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
            G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
            B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
            R:=R+(FogR-R)*FogI Shr 8; G:=G+(FogG-G)*FogI Shr 8; B:=B+(FogB-B)*FogI Shr 8;
            RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 7. RasterTexPow2Transp32  —  pow2, transparent, no fog
// ---------------------------------------------------------------------------

Procedure RasterTexPow2Transp32(Const RF: pSP_RenderFace;
                                SurfPtr: pByte; Stride: Integer;
                                ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2            : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                   : aFloat;
  IntenIR, IntenIG, IntenIB, TranspIdx : Integer;
  TexData                       : pByte;
  TexPal                        : pTP_Colour;
  TexW, TexWMask, TexHMask : Integer;
  DY, yStart, yEnd, Skip, y     : Integer;
  xLeft, xRight, SpanW          : Integer;
  SubEnd, SubW, px, ppx, tInt   : Integer;
  dxL, xL, dxR, xR              : Int64;
  dUZL,dVZL,dWZL                : aFloat;
  dUZR,dVZR,dWZR                : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR      : aFloat;
  ULeft,VLeft,URight,VRight     : aFloat;
  U_fp,V_fp,dU_fp,dV_fp         : Int64;
  UZSpan,VZSpan,WZSpan          : aFloat;
  dUZSpan,dVZSpan,dWZSpan       : aFloat;
  UZNext,VZNext,WZNext          : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                        : Integer;
  TexPix                        : Byte;
  BaseC                         : LongWord;
  R, G, B                       : Integer;
  RowPtr                        : pLongWord;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenIR:=RF^.IntenIR; IntenIG:=RF^.IntenIG; IntenIB:=RF^.IntenIB; TranspIdx:=RF^.TranspIdx;
  TexData:=RF^.TexData; TexPal:=RF^.TexPal;
  TexW:=RF^.TexW; TexWMask:=RF^.TexWMask; TexHMask:=RF^.TexHMask;

  If (Y0>=ClipY2) And (Y1>=ClipY2) And (Y2>=ClipY2) Then Exit;
  If (Y0<ClipY1)  And (Y1<ClipY1)  And (Y2<ClipY1)  Then Exit;
  If Y0>Y1 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X1,Y1,UZ1,VZ1,WZ1);
  If Y0>Y2 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X2,Y2,UZ2,VZ2,WZ2);
  If Y1>Y2 Then SwapIntPair(X1,Y1,UZ1,VZ1,WZ1,X2,Y2,UZ2,VZ2,WZ2);
  If Y0=Y2 Then Exit;

  DY:=Y2-Y0; dxL:=Int64(X2-X0)*65536 Div DY; dUZL:=(UZ2-UZ0)/DY; dVZL:=(VZ2-VZ0)/DY; dWZL:=(WZ2-WZ0)/DY;
  xL:=Int64(X0)*65536; UZL:=UZ0; VZL:=VZ0; WZL:=WZ0;

  If Y0<Y1 Then Begin
    DY:=Y1-Y0; dxR:=Int64(X1-X0)*65536 Div DY; dUZR:=(UZ1-UZ0)/DY; dVZR:=(VZ1-VZ0)/DY; dWZR:=(WZ1-WZ0)/DY;
    xR:=Int64(X0)*65536; UZR:=UZ0; VZR:=VZ0; WZR:=WZ0;
    yStart:=Y0; yEnd:=Y1;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) And TexHMask)*TexW+(Integer(U_fp Shr 16) And TexWMask);
            TexPix:=pByte(NativeUInt(TexData)+LongWord(TexIdx))^;
            If TexPix <> Byte(TranspIdx) Then Begin
              BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(TexPix)*SizeOf(TP_Colour))^.L;
              R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
              G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
              B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
              RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            End;
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;

  xL:=Int64(X0)*65536+dxL*Int64(Y1-Y0); UZL:=UZ0+dUZL*(Y1-Y0); VZL:=VZ0+dVZL*(Y1-Y0); WZL:=WZ0+dWZL*(Y1-Y0);
  If Y1<Y2 Then Begin
    DY:=Y2-Y1; dxR:=Int64(X2-X1)*65536 Div DY; dUZR:=(UZ2-UZ1)/DY; dVZR:=(VZ2-VZ1)/DY; dWZR:=(WZ2-WZ1)/DY;
    xR:=Int64(X1)*65536; UZR:=UZ1; VZR:=VZ1; WZR:=WZ1;
    yStart:=Y1; yEnd:=Y2;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) And TexHMask)*TexW+(Integer(U_fp Shr 16) And TexWMask);
            TexPix:=pByte(NativeUInt(TexData)+LongWord(TexIdx))^;
            If TexPix <> Byte(TranspIdx) Then Begin
              BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(TexPix)*SizeOf(TP_Colour))^.L;
              R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
              G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
              B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
              RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            End;
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 8. RasterTexPow2Transp32Fog  —  pow2, transparent, fogged
// ---------------------------------------------------------------------------

Procedure RasterTexPow2Transp32Fog(Const RF: pSP_RenderFace;
                                   SurfPtr: pByte; Stride: Integer;
                                   ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2            : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                   : aFloat;
  IntenIR, IntenIG, IntenIB, FogI, TranspIdx       : Integer;
  FogR, FogG, FogB              : Integer;
  TexData                       : pByte;
  TexPal                        : pTP_Colour;
  TexW, TexWMask, TexHMask : Integer;
  DY, yStart, yEnd, Skip, y     : Integer;
  xLeft, xRight, SpanW          : Integer;
  SubEnd, SubW, px, ppx, tInt   : Integer;
  dxL, xL, dxR, xR              : Int64;
  dUZL,dVZL,dWZL                : aFloat;
  dUZR,dVZR,dWZR                : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR      : aFloat;
  ULeft,VLeft,URight,VRight     : aFloat;
  U_fp,V_fp,dU_fp,dV_fp         : Int64;
  UZSpan,VZSpan,WZSpan          : aFloat;
  dUZSpan,dVZSpan,dWZSpan       : aFloat;
  UZNext,VZNext,WZNext          : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                        : Integer;
  TexPix                        : Byte;
  BaseC                         : LongWord;
  R, G, B                       : Integer;
  RowPtr                        : pLongWord;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenIR:=RF^.IntenIR; IntenIG:=RF^.IntenIG; IntenIB:=RF^.IntenIB; FogI:=RF^.FogI; TranspIdx:=RF^.TranspIdx;
  FogR:=(SP3D_FogColour32 Shr 16) And $FF;
  FogG:=(SP3D_FogColour32 Shr  8) And $FF;
  FogB:= SP3D_FogColour32         And $FF;
  TexData:=RF^.TexData; TexPal:=RF^.TexPal;
  TexW:=RF^.TexW; TexWMask:=RF^.TexWMask; TexHMask:=RF^.TexHMask;

  If (Y0>=ClipY2) And (Y1>=ClipY2) And (Y2>=ClipY2) Then Exit;
  If (Y0<ClipY1)  And (Y1<ClipY1)  And (Y2<ClipY1)  Then Exit;
  If Y0>Y1 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X1,Y1,UZ1,VZ1,WZ1);
  If Y0>Y2 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X2,Y2,UZ2,VZ2,WZ2);
  If Y1>Y2 Then SwapIntPair(X1,Y1,UZ1,VZ1,WZ1,X2,Y2,UZ2,VZ2,WZ2);
  If Y0=Y2 Then Exit;

  DY:=Y2-Y0; dxL:=Int64(X2-X0)*65536 Div DY; dUZL:=(UZ2-UZ0)/DY; dVZL:=(VZ2-VZ0)/DY; dWZL:=(WZ2-WZ0)/DY;
  xL:=Int64(X0)*65536; UZL:=UZ0; VZL:=VZ0; WZL:=WZ0;

  If Y0<Y1 Then Begin
    DY:=Y1-Y0; dxR:=Int64(X1-X0)*65536 Div DY; dUZR:=(UZ1-UZ0)/DY; dVZR:=(VZ1-VZ0)/DY; dWZR:=(WZ1-WZ0)/DY;
    xR:=Int64(X0)*65536; UZR:=UZ0; VZR:=VZ0; WZR:=WZ0;
    yStart:=Y0; yEnd:=Y1;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) And TexHMask)*TexW+(Integer(U_fp Shr 16) And TexWMask);
            TexPix:=pByte(NativeUInt(TexData)+LongWord(TexIdx))^;
            If TexPix <> Byte(TranspIdx) Then Begin
              BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(TexPix)*SizeOf(TP_Colour))^.L;
              R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
              G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
              B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
              R:=R+(FogR-R)*FogI Shr 8; G:=G+(FogG-G)*FogI Shr 8; B:=B+(FogB-B)*FogI Shr 8;
              RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            End;
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;

  xL:=Int64(X0)*65536+dxL*Int64(Y1-Y0); UZL:=UZ0+dUZL*(Y1-Y0); VZL:=VZ0+dVZL*(Y1-Y0); WZL:=WZ0+dWZL*(Y1-Y0);
  If Y1<Y2 Then Begin
    DY:=Y2-Y1; dxR:=Int64(X2-X1)*65536 Div DY; dUZR:=(UZ2-UZ1)/DY; dVZR:=(VZ2-VZ1)/DY; dWZR:=(WZ2-WZ1)/DY;
    xR:=Int64(X1)*65536; UZR:=UZ1; VZR:=VZ1; WZR:=WZ1;
    yStart:=Y1; yEnd:=Y2;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) And TexHMask)*TexW+(Integer(U_fp Shr 16) And TexWMask);
            TexPix:=pByte(NativeUInt(TexData)+LongWord(TexIdx))^;
            If TexPix <> Byte(TranspIdx) Then Begin
              BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(TexPix)*SizeOf(TP_Colour))^.L;
              R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
              G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
              B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
              R:=R+(FogR-R)*FogI Shr 8; G:=G+(FogG-G)*FogI Shr 8; B:=B+(FogB-B)*FogI Shr 8;
              RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            End;
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 9. RasterTexNPOTOpaque32  —  non-power-of-2, opaque, no fog
// ---------------------------------------------------------------------------

Procedure RasterTexNPOTOpaque32(Const RF: pSP_RenderFace;
                                SurfPtr: pByte; Stride: Integer;
                                ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2            : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                   : aFloat;
  IntenIR, IntenIG, IntenIB : Integer;
  TexData                       : pByte;
  TexPal                        : pTP_Colour;
  TexW, TexH                    : Integer;
  DY, yStart, yEnd, Skip, y     : Integer;
  xLeft, xRight, SpanW          : Integer;
  SubEnd, SubW, px, ppx, tInt   : Integer;
  dxL, xL, dxR, xR              : Int64;
  dUZL,dVZL,dWZL                : aFloat;
  dUZR,dVZR,dWZR                : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR      : aFloat;
  ULeft,VLeft,URight,VRight     : aFloat;
  U_fp,V_fp,dU_fp,dV_fp         : Int64;
  UZSpan,VZSpan,WZSpan          : aFloat;
  dUZSpan,dVZSpan,dWZSpan       : aFloat;
  UZNext,VZNext,WZNext          : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                        : Integer;
  BaseC                         : LongWord;
  R, G, B                       : Integer;
  RowPtr                        : pLongWord;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenIR:=RF^.IntenIR; IntenIG:=RF^.IntenIG; IntenIB:=RF^.IntenIB; TexData:=RF^.TexData; TexPal:=RF^.TexPal;
  TexW:=RF^.TexW; TexH:=RF^.TexH;

  If (Y0>=ClipY2) And (Y1>=ClipY2) And (Y2>=ClipY2) Then Exit;
  If (Y0<ClipY1)  And (Y1<ClipY1)  And (Y2<ClipY1)  Then Exit;
  If Y0>Y1 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X1,Y1,UZ1,VZ1,WZ1);
  If Y0>Y2 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X2,Y2,UZ2,VZ2,WZ2);
  If Y1>Y2 Then SwapIntPair(X1,Y1,UZ1,VZ1,WZ1,X2,Y2,UZ2,VZ2,WZ2);
  If Y0=Y2 Then Exit;

  DY:=Y2-Y0; dxL:=Int64(X2-X0)*65536 Div DY; dUZL:=(UZ2-UZ0)/DY; dVZL:=(VZ2-VZ0)/DY; dWZL:=(WZ2-WZ0)/DY;
  xL:=Int64(X0)*65536; UZL:=UZ0; VZL:=VZ0; WZL:=WZ0;

  If Y0<Y1 Then Begin
    DY:=Y1-Y0; dxR:=Int64(X1-X0)*65536 Div DY; dUZR:=(UZ1-UZ0)/DY; dVZR:=(VZ1-VZ0)/DY; dWZR:=(WZ1-WZ0)/DY;
    xR:=Int64(X0)*65536; UZR:=UZ0; VZR:=VZ0; WZR:=WZ0;
    yStart:=Y0; yEnd:=Y1;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) Mod TexH)*TexW+(Integer(U_fp Shr 16) Mod TexW);
            If TexIdx<0 Then TexIdx:=0;
            BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(pByte(NativeUInt(TexData)+LongWord(TexIdx))^)*SizeOf(TP_Colour))^.L;
            R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
            G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
            B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
            RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;

  xL:=Int64(X0)*65536+dxL*Int64(Y1-Y0); UZL:=UZ0+dUZL*(Y1-Y0); VZL:=VZ0+dVZL*(Y1-Y0); WZL:=WZ0+dWZL*(Y1-Y0);
  If Y1<Y2 Then Begin
    DY:=Y2-Y1; dxR:=Int64(X2-X1)*65536 Div DY; dUZR:=(UZ2-UZ1)/DY; dVZR:=(VZ2-VZ1)/DY; dWZR:=(WZ2-WZ1)/DY;
    xR:=Int64(X1)*65536; UZR:=UZ1; VZR:=VZ1; WZR:=WZ1;
    yStart:=Y1; yEnd:=Y2;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) Mod TexH)*TexW+(Integer(U_fp Shr 16) Mod TexW);
            If TexIdx<0 Then TexIdx:=0;
            BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(pByte(NativeUInt(TexData)+LongWord(TexIdx))^)*SizeOf(TP_Colour))^.L;
            R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
            G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
            B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
            RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 10. RasterTexNPOTOpaque32Fog  —  non-power-of-2, opaque, fogged
// ---------------------------------------------------------------------------

Procedure RasterTexNPOTOpaque32Fog(Const RF: pSP_RenderFace;
                                   SurfPtr: pByte; Stride: Integer;
                                   ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2            : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                   : aFloat;
  IntenIR, IntenIG, IntenIB, FogI : Integer;
  FogR, FogG, FogB              : Integer;
  TexData                       : pByte;
  TexPal                        : pTP_Colour;
  TexW, TexH                    : Integer;
  DY, yStart, yEnd, Skip, y     : Integer;
  xLeft, xRight, SpanW          : Integer;
  SubEnd, SubW, px, ppx, tInt   : Integer;
  dxL, xL, dxR, xR              : Int64;
  dUZL,dVZL,dWZL                : aFloat;
  dUZR,dVZR,dWZR                : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR      : aFloat;
  ULeft,VLeft,URight,VRight     : aFloat;
  U_fp,V_fp,dU_fp,dV_fp         : Int64;
  UZSpan,VZSpan,WZSpan          : aFloat;
  dUZSpan,dVZSpan,dWZSpan       : aFloat;
  UZNext,VZNext,WZNext          : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                        : Integer;
  BaseC                         : LongWord;
  R, G, B                       : Integer;
  RowPtr                        : pLongWord;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenIR:=RF^.IntenIR; IntenIG:=RF^.IntenIG; IntenIB:=RF^.IntenIB; FogI:=RF^.FogI;
  FogR:=(SP3D_FogColour32 Shr 16) And $FF;
  FogG:=(SP3D_FogColour32 Shr  8) And $FF;
  FogB:= SP3D_FogColour32         And $FF;
  TexData:=RF^.TexData; TexPal:=RF^.TexPal; TexW:=RF^.TexW; TexH:=RF^.TexH;

  If (Y0>=ClipY2) And (Y1>=ClipY2) And (Y2>=ClipY2) Then Exit;
  If (Y0<ClipY1)  And (Y1<ClipY1)  And (Y2<ClipY1)  Then Exit;
  If Y0>Y1 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X1,Y1,UZ1,VZ1,WZ1);
  If Y0>Y2 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X2,Y2,UZ2,VZ2,WZ2);
  If Y1>Y2 Then SwapIntPair(X1,Y1,UZ1,VZ1,WZ1,X2,Y2,UZ2,VZ2,WZ2);
  If Y0=Y2 Then Exit;

  DY:=Y2-Y0; dxL:=Int64(X2-X0)*65536 Div DY; dUZL:=(UZ2-UZ0)/DY; dVZL:=(VZ2-VZ0)/DY; dWZL:=(WZ2-WZ0)/DY;
  xL:=Int64(X0)*65536; UZL:=UZ0; VZL:=VZ0; WZL:=WZ0;

  If Y0<Y1 Then Begin
    DY:=Y1-Y0; dxR:=Int64(X1-X0)*65536 Div DY; dUZR:=(UZ1-UZ0)/DY; dVZR:=(VZ1-VZ0)/DY; dWZR:=(WZ1-WZ0)/DY;
    xR:=Int64(X0)*65536; UZR:=UZ0; VZR:=VZ0; WZR:=WZ0;
    yStart:=Y0; yEnd:=Y1;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) Mod TexH)*TexW+(Integer(U_fp Shr 16) Mod TexW);
            If TexIdx<0 Then TexIdx:=0;
            BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(pByte(NativeUInt(TexData)+LongWord(TexIdx))^)*SizeOf(TP_Colour))^.L;
            R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
            G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
            B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
            R:=R+(FogR-R)*FogI Shr 8; G:=G+(FogG-G)*FogI Shr 8; B:=B+(FogB-B)*FogI Shr 8;
            RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;

  xL:=Int64(X0)*65536+dxL*Int64(Y1-Y0); UZL:=UZ0+dUZL*(Y1-Y0); VZL:=VZ0+dVZL*(Y1-Y0); WZL:=WZ0+dWZL*(Y1-Y0);
  If Y1<Y2 Then Begin
    DY:=Y2-Y1; dxR:=Int64(X2-X1)*65536 Div DY; dUZR:=(UZ2-UZ1)/DY; dVZR:=(VZ2-VZ1)/DY; dWZR:=(WZ2-WZ1)/DY;
    xR:=Int64(X1)*65536; UZR:=UZ1; VZR:=VZ1; WZR:=WZ1;
    yStart:=Y1; yEnd:=Y2;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) Mod TexH)*TexW+(Integer(U_fp Shr 16) Mod TexW);
            If TexIdx<0 Then TexIdx:=0;
            BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(pByte(NativeUInt(TexData)+LongWord(TexIdx))^)*SizeOf(TP_Colour))^.L;
            R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
            G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
            B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
            R:=R+(FogR-R)*FogI Shr 8; G:=G+(FogG-G)*FogI Shr 8; B:=B+(FogB-B)*FogI Shr 8;
            RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 11. RasterTexNPOTTransp32  —  non-power-of-2, transparent, no fog
// ---------------------------------------------------------------------------

Procedure RasterTexNPOTTransp32(Const RF: pSP_RenderFace;
                                SurfPtr: pByte; Stride: Integer;
                                ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2            : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                   : aFloat;
  IntenIR, IntenIG, IntenIB, TranspIdx : Integer;
  TexData                       : pByte;
  TexPal                        : pTP_Colour;
  TexW, TexH                    : Integer;
  DY, yStart, yEnd, Skip, y     : Integer;
  xLeft, xRight, SpanW          : Integer;
  SubEnd, SubW, px, ppx, tInt   : Integer;
  dxL, xL, dxR, xR              : Int64;
  dUZL,dVZL,dWZL                : aFloat;
  dUZR,dVZR,dWZR                : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR      : aFloat;
  ULeft,VLeft,URight,VRight     : aFloat;
  U_fp,V_fp,dU_fp,dV_fp         : Int64;
  UZSpan,VZSpan,WZSpan          : aFloat;
  dUZSpan,dVZSpan,dWZSpan       : aFloat;
  UZNext,VZNext,WZNext          : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                        : Integer;
  TexPix                        : Byte;
  BaseC                         : LongWord;
  R, G, B                       : Integer;
  RowPtr                        : pLongWord;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenIR:=RF^.IntenIR; IntenIG:=RF^.IntenIG; IntenIB:=RF^.IntenIB; TranspIdx:=RF^.TranspIdx;
  TexData:=RF^.TexData; TexPal:=RF^.TexPal; TexW:=RF^.TexW; TexH:=RF^.TexH;

  If (Y0>=ClipY2) And (Y1>=ClipY2) And (Y2>=ClipY2) Then Exit;
  If (Y0<ClipY1)  And (Y1<ClipY1)  And (Y2<ClipY1)  Then Exit;
  If Y0>Y1 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X1,Y1,UZ1,VZ1,WZ1);
  If Y0>Y2 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X2,Y2,UZ2,VZ2,WZ2);
  If Y1>Y2 Then SwapIntPair(X1,Y1,UZ1,VZ1,WZ1,X2,Y2,UZ2,VZ2,WZ2);
  If Y0=Y2 Then Exit;

  DY:=Y2-Y0; dxL:=Int64(X2-X0)*65536 Div DY; dUZL:=(UZ2-UZ0)/DY; dVZL:=(VZ2-VZ0)/DY; dWZL:=(WZ2-WZ0)/DY;
  xL:=Int64(X0)*65536; UZL:=UZ0; VZL:=VZ0; WZL:=WZ0;

  If Y0<Y1 Then Begin
    DY:=Y1-Y0; dxR:=Int64(X1-X0)*65536 Div DY; dUZR:=(UZ1-UZ0)/DY; dVZR:=(VZ1-VZ0)/DY; dWZR:=(WZ1-WZ0)/DY;
    xR:=Int64(X0)*65536; UZR:=UZ0; VZR:=VZ0; WZR:=WZ0;
    yStart:=Y0; yEnd:=Y1;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) Mod TexH)*TexW+(Integer(U_fp Shr 16) Mod TexW);
            If TexIdx<0 Then TexIdx:=0;
            TexPix:=pByte(NativeUInt(TexData)+LongWord(TexIdx))^;
            If TexPix <> Byte(TranspIdx) Then Begin
              BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(TexPix)*SizeOf(TP_Colour))^.L;
              R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
              G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
              B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
              RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            End;
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;

  xL:=Int64(X0)*65536+dxL*Int64(Y1-Y0); UZL:=UZ0+dUZL*(Y1-Y0); VZL:=VZ0+dVZL*(Y1-Y0); WZL:=WZ0+dWZL*(Y1-Y0);
  If Y1<Y2 Then Begin
    DY:=Y2-Y1; dxR:=Int64(X2-X1)*65536 Div DY; dUZR:=(UZ2-UZ1)/DY; dVZR:=(VZ2-VZ1)/DY; dWZR:=(WZ2-WZ1)/DY;
    xR:=Int64(X1)*65536; UZR:=UZ1; VZR:=VZ1; WZR:=WZ1;
    yStart:=Y1; yEnd:=Y2;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) Mod TexH)*TexW+(Integer(U_fp Shr 16) Mod TexW);
            If TexIdx<0 Then TexIdx:=0;
            TexPix:=pByte(NativeUInt(TexData)+LongWord(TexIdx))^;
            If TexPix <> Byte(TranspIdx) Then Begin
              BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(TexPix)*SizeOf(TP_Colour))^.L;
              R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
              G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
              B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
              RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            End;
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 12. RasterTexNPOTTransp32Fog  —  non-power-of-2, transparent, fogged
// ---------------------------------------------------------------------------

Procedure RasterTexNPOTTransp32Fog(Const RF: pSP_RenderFace;
                                   SurfPtr: pByte; Stride: Integer;
                                   ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2            : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                   : aFloat;
  IntenIR, IntenIG, IntenIB, FogI, TranspIdx       : Integer;
  FogR, FogG, FogB              : Integer;
  TexData                       : pByte;
  TexPal                        : pTP_Colour;
  TexW, TexH                    : Integer;
  DY, yStart, yEnd, Skip, y     : Integer;
  xLeft, xRight, SpanW          : Integer;
  SubEnd, SubW, px, ppx, tInt   : Integer;
  dxL, xL, dxR, xR              : Int64;
  dUZL,dVZL,dWZL                : aFloat;
  dUZR,dVZR,dWZR                : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR      : aFloat;
  ULeft,VLeft,URight,VRight     : aFloat;
  U_fp,V_fp,dU_fp,dV_fp         : Int64;
  UZSpan,VZSpan,WZSpan          : aFloat;
  dUZSpan,dVZSpan,dWZSpan       : aFloat;
  UZNext,VZNext,WZNext          : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                        : Integer;
  TexPix                        : Byte;
  BaseC                         : LongWord;
  R, G, B                       : Integer;
  RowPtr                        : pLongWord;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenIR:=RF^.IntenIR; IntenIG:=RF^.IntenIG; IntenIB:=RF^.IntenIB; FogI:=RF^.FogI; TranspIdx:=RF^.TranspIdx;
  FogR:=(SP3D_FogColour32 Shr 16) And $FF;
  FogG:=(SP3D_FogColour32 Shr  8) And $FF;
  FogB:= SP3D_FogColour32         And $FF;
  TexData:=RF^.TexData; TexPal:=RF^.TexPal; TexW:=RF^.TexW; TexH:=RF^.TexH;

  If (Y0>=ClipY2) And (Y1>=ClipY2) And (Y2>=ClipY2) Then Exit;
  If (Y0<ClipY1)  And (Y1<ClipY1)  And (Y2<ClipY1)  Then Exit;
  If Y0>Y1 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X1,Y1,UZ1,VZ1,WZ1);
  If Y0>Y2 Then SwapIntPair(X0,Y0,UZ0,VZ0,WZ0,X2,Y2,UZ2,VZ2,WZ2);
  If Y1>Y2 Then SwapIntPair(X1,Y1,UZ1,VZ1,WZ1,X2,Y2,UZ2,VZ2,WZ2);
  If Y0=Y2 Then Exit;

  DY:=Y2-Y0; dxL:=Int64(X2-X0)*65536 Div DY; dUZL:=(UZ2-UZ0)/DY; dVZL:=(VZ2-VZ0)/DY; dWZL:=(WZ2-WZ0)/DY;
  xL:=Int64(X0)*65536; UZL:=UZ0; VZL:=VZ0; WZL:=WZ0;

  If Y0<Y1 Then Begin
    DY:=Y1-Y0; dxR:=Int64(X1-X0)*65536 Div DY; dUZR:=(UZ1-UZ0)/DY; dVZR:=(VZ1-VZ0)/DY; dWZR:=(WZ1-WZ0)/DY;
    xR:=Int64(X0)*65536; UZR:=UZ0; VZR:=VZ0; WZR:=WZ0;
    yStart:=Y0; yEnd:=Y1;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) Mod TexH)*TexW+(Integer(U_fp Shr 16) Mod TexW);
            If TexIdx<0 Then TexIdx:=0;
            TexPix:=pByte(NativeUInt(TexData)+LongWord(TexIdx))^;
            If TexPix <> Byte(TranspIdx) Then Begin
              BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(TexPix)*SizeOf(TP_Colour))^.L;
              R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
              G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
              B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
              R:=R+(FogR-R)*FogI Shr 8; G:=G+(FogG-G)*FogI Shr 8; B:=B+(FogB-B)*FogI Shr 8;
              RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            End;
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;

  xL:=Int64(X0)*65536+dxL*Int64(Y1-Y0); UZL:=UZ0+dUZL*(Y1-Y0); VZL:=VZ0+dVZL*(Y1-Y0); WZL:=WZ0+dWZL*(Y1-Y0);
  If Y1<Y2 Then Begin
    DY:=Y2-Y1; dxR:=Int64(X2-X1)*65536 Div DY; dUZR:=(UZ2-UZ1)/DY; dVZR:=(VZ2-VZ1)/DY; dWZR:=(WZ2-WZ1)/DY;
    xR:=Int64(X1)*65536; UZR:=UZ1; VZR:=VZ1; WZR:=WZ1;
    yStart:=Y1; yEnd:=Y2;
    If yStart<ClipY1 Then Begin Skip:=ClipY1-yStart; xL:=xL+dxL*Skip; UZL:=UZL+dUZL*Skip; VZL:=VZL+dVZL*Skip; WZL:=WZL+dWZL*Skip; xR:=xR+dxR*Skip; UZR:=UZR+dUZR*Skip; VZR:=VZR+dVZR*Skip; WZR:=WZR+dWZR*Skip; yStart:=ClipY1; End;
    If yEnd>ClipY2 Then yEnd:=ClipY2;
    For y:=yStart To yEnd-1 Do Begin
      xLeft:=Integer(xL Shr 16); xRight:=Integer(xR Shr 16);
      If xLeft<=xRight Then Begin sUZL:=UZL;sVZL:=VZL;sWZL:=WZL;sUZR:=UZR;sVZR:=VZR;sWZR:=WZR; End
      Else Begin tInt:=xLeft;xLeft:=xRight;xRight:=tInt; sUZL:=UZR;sVZL:=VZR;sWZL:=WZR;sUZR:=UZL;sVZR:=VZL;sWZR:=WZL; End;
      SpanW:=xRight-xLeft;
      If SpanW>0 Then Begin dUZSpan:=(sUZR-sUZL)/SpanW; dVZSpan:=(sVZR-sVZL)/SpanW; dWZSpan:=(sWZR-sWZL)/SpanW; End Else Begin dUZSpan:=0;dVZSpan:=0;dWZSpan:=0; End;
      UZSpan:=sUZL; VZSpan:=sVZL; WZSpan:=sWZL;
      If xLeft<ClipX1 Then Begin Skip:=ClipX1-xLeft; UZSpan:=UZSpan+dUZSpan*Skip; VZSpan:=VZSpan+dVZSpan*Skip; WZSpan:=WZSpan+dWZSpan*Skip; xLeft:=ClipX1; End;
      If xRight>ClipX2-1 Then xRight:=ClipX2-1;
      If xLeft<=xRight Then Begin
        RowPtr:=pLongWord(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft*4)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) Mod TexH)*TexW+(Integer(U_fp Shr 16) Mod TexW);
            If TexIdx<0 Then TexIdx:=0;
            TexPix:=pByte(NativeUInt(TexData)+LongWord(TexIdx))^;
            If TexPix <> Byte(TranspIdx) Then Begin
              BaseC:=pTP_Colour(NativeUInt(TexPal)+LongWord(TexPix)*SizeOf(TP_Colour))^.L;
              R:=((BaseC Shr 16) And $FF)*LongWord(IntenIR) Shr 8;
              G:=((BaseC Shr  8) And $FF)*LongWord(IntenIG) Shr 8;
              B:=( BaseC         And $FF)*LongWord(IntenIB) Shr 8;
              R:=R+(FogR-R)*FogI Shr 8; G:=G+(FogG-G)*FogI Shr 8; B:=B+(FogB-B)*FogI Shr 8;
              RowPtr^:=$FF000000 Or (LongWord(R) Shl 16) Or (LongWord(G) Shl 8) Or LongWord(B);
            End;
            Inc(RowPtr); U_fp:=U_fp+dU_fp; V_fp:=V_fp+dV_fp;
          End;
          UZSpan:=UZNext; VZSpan:=VZNext; WZSpan:=WZNext; ULeft:=URight; VLeft:=VRight; px:=SubEnd+1;
        End;
      End;
      xL:=xL+dxL; UZL:=UZL+dUZL; VZL:=VZL+dVZL; WZL:=WZL+dWZL;
      xR:=xR+dxR; UZR:=UZR+dUZR; VZR:=VZR+dVZR; WZR:=WZR+dWZR;
    End;
  End;
End;

// ===========================================================================
// SP_3D_Render32 — 32bpp entry point
// ===========================================================================

Procedure SP_3D_Render32(WindowID, SceneID, ThreadCount: Integer; Var Error: TSP_ErrorCode);
Var
  SurfPtr                         : pByte;
  ScrW, ScrH, Stride              : Integer;
  ClipX1, ClipY1, ClipX2, ClipY2 : Integer;
  WinPal                          : Array[0..255] of TP_Colour;
  SavedBank                       : Integer;

  FOVRad, FY, FX, HalfW, HalfH   : aFloat;

  SceneBank  : pSP_Bank;
  SlotCount  : LongWord;
  si         : Integer;
  Inst       : pSP_ModelInstance;

  ModelIdx   : Integer;
  ModelBank  : pSP_Bank;
  Hdr        : pSP_ModelHeader;
  VBase      : pSP_3DVertex;
  FBase      : pSP_3DFace;
  Face       : pSP_3DFace;
  fi, t      : Integer;

  CV         : Array[0..2] of TClipVert;
  T1, T2     : TClipTri;
  CT         : TClipTri;
  NTri       : Integer;

  WNX, WNY, WNZ, Dot, Inten     : aFloat;

  vc, vi, RFStart               : Integer;
  SX0, SY0, SX1, SY1, SX2, SY2  : Integer;
  E1X, E1Y, E2X, E2Y, Cross     : aFloat;
  AvgCZ                         : aFloat;

  RFCount : Integer;
  RF      : pSP_RenderFace;

  GfxInfo  : pSP_Graphic_Info;
  TexData  : pByte;
  TexW, TexH : Integer;
  HasTex   : Boolean;
  GfxErr   : TSP_ErrorCode;

  FogT     : aFloat;

  InstOrderCount : Integer;
  si2, siTmp     : Integer;
  InstDist       : aFloat;

  BSCx, BSCy, BSCz, BSCr : aFloat;
  FrustumOK              : Boolean;
  FP : Array[0..5, 0..3] of aFloat;
  FarPlane, HalfFOV, HalfFOVY: aFloat;

  PSX, PSY  : Integer;
  PV        : TSP_3DVertex;
  GC0, GC1, GC2: Byte;
  VDot, VInten: aFloat;
  BaseC0, BaseC1, BaseC2 : LongWord;
  GouraudUniform  : Boolean;
  SortGC0,SortGC1,SortGC2: Byte;
  SortBC0,SortBC1,SortBC2: LongWord;
  HasSmooth  : Boolean;

  EBase         : pSP_3DEdge;
  Edge          : pSP_3DEdge;
  ei            : Integer;
  IsWireframe   : Boolean;
  DoCull        : Boolean;
  IsSolid       : Boolean;
  WireVisible   : Boolean;
  fc            : Integer;
  ECX0,ECY0,ECZ0 : aFloat;
  ECX1,ECY1,ECZ1 : aFloat;
  ESX0,ESY0     : Integer;
  ESX1,ESY1     : Integer;
  ClipT         : aFloat;
  WireColour32  : LongWord;
  siTmpModel    : Integer;
  V0X, V0Y, V0Z : aFloat;
  V1X, V1Y, V1Z : aFloat;
  V2X, V2Y, V2Z : aFloat;
  DotN          : aFloat;
  SrcVtx : pSP_3DVertex;
  AnimDir : pSP3D_FrameDir;
  EntryA  : pSP3D_FrameDir;
  EntryB  : pSP3D_FrameDir;
  FVA     : pSP3D_FrameVert;
  FVB     : pSP3D_FrameVert;
  fT      : aFloat;
  OneMinT : aFloat;
  LX, LY, LZ : aFloat;
  VA: pSP3D_FrameVert;
  VB: pSP3D_FrameVert;
  SrcV: pSP_3DVertex;
  MatPassDone   : Boolean;
  MatPassCount  : Integer;
  MatPassInst   : pSP_ModelInstance;
  MatParentInst : pSP_ModelInstance;
  MatSi         : Integer;
  LastDispTexBank: Integer;
  LastDispGfxInfo: pSP_Graphic_Info;
  ASYNC:        Boolean;

  // Pre-computed flat colour for dispatch
  WireIntenF    : aFloat;               // float wire intensity for edge draw

  Procedure SwapL(Var A,B: LongWord); Inline;
  Var T: LongWord; Begin T:=A; A:=B; B:=T; End;

  Procedure SwapI(Var A,B: Integer); Inline;
  Var T: Integer; Begin T:=A; A:=B; B:=T; End;

  Procedure SwapB(Var A,B: Byte); Inline;
  Var T: Byte; Begin T:=A; A:=B; B:=T; End;

Const
  MaxHierarchyDepth = 8;

Begin
  Error.Code := SP_ERR_OK;

  If SP3D_CamDirty Then
    InvalidateAllSceneMatrices;

  SavedBank := SCREENBANK;
  If (WindowID >= 0) And (WindowID <> SCREENBANK) Then Begin
    SP_SetDrawingWindow(WindowID);
    If SCREENBANK <> WindowID Then Begin
      Error.Code := SP_ERR_WINDOW_NOT_FOUND;  Exit;
    End;
  End;

  SurfPtr := SCREENPOINTER;
  ScrW    := SCREENWIDTH;
  ScrH    := SCREENHEIGHT;
  Stride  := SCREENSTRIDE;
  ClipX1  := T_CLIPX1;  ClipY1 := T_CLIPY1;
  ClipX2  := T_CLIPX2;  ClipY2 := T_CLIPY2;
  Move(pSP_Window_Info(WINDOWPOINTER)^.Palette[0], WinPal[0], SizeOf(WinPal));

  // Rebuild tables if palette changed
  If SP3D_ShadeDirty Then Begin
    SP_3D_BuildShadeTable(WinPal);
    SP_3D_BuildColourCube;
  End;

  // 32bpp base palette — just ARGB expansion, no nearest-colour search
  If SP3D_ShadeDirty32 Then
    SP_3D_BuildBasePal32(WinPal);

  If SP3D_FogDirty Then Begin
    If SP3D_FogActive Then
      SP_3D_BuildFogTable(WinPal);
    SP3D_FogColour32 := $FF000000
                        Or (LongWord(WinPal[SP3D_FogColour].R) Shl 16)
                        Or (LongWord(WinPal[SP3D_FogColour].G) Shl 8)
                        Or  LongWord(WinPal[SP3D_FogColour].B);
    SP3D_FogDirty32 := False;
  End;

  If SceneID < 0 Then SceneID := SP3D_ActiveScene;
  SceneBank := GetSceneBank(SceneID, Error);
  If Not Assigned(SceneBank) Then Begin
    If (WindowID >= 0) And (SavedBank <> WindowID) Then
      SP_SetDrawingWindow(SavedBank);
    Exit;
  End;

  If SP3D_Cam_FOV < 1 Then SP3D_Cam_FOV := 60;
  FOVRad := DegToRad(SP3D_Cam_FOV);
  FY     := (ScrH * 0.5) / Tan(FOVRad * 0.5);
  FX     := FY;
  HalfW  := ScrW * 0.5;
  HalfH  := ScrH * 0.5;

  FP[0][0] :=  0;  FP[0][1] :=  0;  FP[0][2] :=  1;  FP[0][3] := -SP3D_NEAR_PLANE;
  FarPlane := 1000.0;
  If SP3D_FogActive Then FarPlane := SP3D_FogFar * 1.1;
  FP[1][0] :=  0;  FP[1][1] :=  0;  FP[1][2] := -1;  FP[1][3] :=  FarPlane;
  HalfFOV  := ArcTan((ScrW * 0.5) / FX);
  FP[2][0] :=  Cos(HalfFOV);  FP[2][1] := 0;  FP[2][2] := Sin(HalfFOV);  FP[2][3] := 0;
  FP[3][0] := -Cos(HalfFOV);  FP[3][1] := 0;  FP[3][2] := Sin(HalfFOV);  FP[3][3] := 0;
  HalfFOVY := ArcTan((ScrH * 0.5) / FY);
  FP[4][0] := 0;  FP[4][1] :=  Cos(HalfFOVY);  FP[4][2] := Sin(HalfFOVY);  FP[4][3] := 0;
  FP[5][0] := 0;  FP[5][1] := -Cos(HalfFOVY);  FP[5][2] := Sin(HalfFOVY);  FP[5][3] := 0;

  SlotCount := SceneSlotCount(SceneBank);
  If Integer(SlotCount) > SP3D_InstOrderAlloc Then Begin
    SetLength(SP3D_InstOrder,    Integer(SlotCount));
    SetLength(SP3D_InstModelIdx, Integer(SlotCount));
    SetLength(SP3D_InstDistArr,  Integer(SlotCount));
    SP3D_InstOrderAlloc := Integer(SlotCount);
  End;

  MatPassCount := 0;
  Repeat
    MatPassDone := True;
    For MatSi := 0 To Integer(SlotCount) - 1 Do Begin
      MatPassInst := pSP_ModelInstance(@SceneBank^.Memory[MatSi * SizeOf(TSP_ModelInstance)]);
      If Not MatPassInst^.Active Then Continue;
      If Not MatPassInst^.MatrixDirty Then Continue;

      If MatPassInst^.ParentID < 0 Then Begin
        BuildInstanceMatrices(MatPassInst^);
      End Else Begin
        MatParentInst := FindInstInScene(SceneBank, MatPassInst^.ParentID);
        If Assigned(MatParentInst) And (Not MatParentInst^.MatrixDirty) Then Begin
          BuildInstanceMatrices(MatPassInst^, @MatParentInst^.MV, @MatParentInst^.NM);
        End Else Begin
          MatPassDone := False;
        End;
      End;
    End;
    Inc(MatPassCount);
  Until MatPassDone Or (MatPassCount >= MaxHierarchyDepth);

  // --- Pre-alloc render face buffer ---
  RFCount := 0;
  If SP3D_RFacesAlloc < 8192 Then Begin
    SetLength(SP3D_RFaces, 8192);
    SetLength(SP3D_GouraudLUTBuf,   8192 * 256);
    SP3D_RFacesAlloc := 8192;
  End;

  // --- Frustum cull and sort ---
  InstOrderCount := 0;
  For si := 0 To Integer(SlotCount) - 1 Do Begin
    Inst := pSP_ModelInstance(@SceneBank^.Memory[si * SizeOf(TSP_ModelInstance)]);
    If Not Inst^.Active Or Not Inst^.Visible Then Continue;
    ModelIdx := SP_FindBankID(Inst^.BankID);
    If ModelIdx < 0 Then Continue;
    If SP_BankList[ModelIdx]^.DataType <> SP_MODEL_BANK Then Continue;
    If Length(SP_BankList[ModelIdx]^.Info) < SizeOf(TSP_ModelHeader) Then Continue;
    Hdr := pSP_ModelHeader(@SP_BankList[ModelIdx]^.Info[0]);
    If (Hdr^.Flags And SP3D_FLAG_DIRTY) <> 0 Then Begin
      SP_Model_Build(Inst^.BankID, Error);
      If Error.Code <> SP_ERR_OK Then Begin Error.Code := SP_ERR_OK; Continue; End;
      Hdr := pSP_ModelHeader(@SP_BankList[ModelIdx]^.Info[0]);
      Inst^.MatrixDirty := True;
    End;
    If (Hdr^.Flags And SP3D_FLAG_BUILT) = 0 Then Continue;
    If Hdr^.FaceCount = 0 Then Begin
      SP3D_InstOrder[InstOrderCount]    := si;
      SP3D_InstModelIdx[InstOrderCount] := ModelIdx;
      SP3D_InstDistArr[InstOrderCount]  := 1e30;
      Inc(InstOrderCount);
      Continue;
    End;
    TransformPos(Hdr^.BSX, Hdr^.BSY, Hdr^.BSZ, Inst^.MV, BSCx, BSCy, BSCz);
    BSCr := Hdr^.BSRadius * Inst^.Scale;
    FrustumOK := True;
    For si2 := 0 To 5 Do
      If FP[si2][0]*BSCx + FP[si2][1]*BSCy + FP[si2][2]*BSCz + FP[si2][3] < -BSCr Then Begin
        FrustumOK := False; Break;
      End;
    If Not FrustumOK Then Continue;
    SP3D_InstOrder[InstOrderCount]    := si;
    SP3D_InstModelIdx[InstOrderCount] := ModelIdx;
    SP3D_InstDistArr[InstOrderCount]  := BSCz - BSCr;
    Inc(InstOrderCount);
  End;

  For si := 1 To InstOrderCount - 1 Do Begin
    siTmp    := SP3D_InstOrder[si];
    InstDist := SP3D_InstDistArr[si];
    siTmpModel := SP3D_InstModelIdx[si];
    si2 := si - 1;
    While (si2 >= 0) And (SP3D_InstDistArr[si2] < InstDist) Do Begin
      SP3D_InstOrder[si2+1]    := SP3D_InstOrder[si2];
      SP3D_InstDistArr[si2+1]  := SP3D_InstDistArr[si2];
      SP3D_InstModelIdx[si2+1] := SP3D_InstModelIdx[si2];
      Dec(si2);
    End;
    SP3D_InstOrder[si2+1]    := siTmp;
    SP3D_InstDistArr[si2+1]  := InstDist;
    SP3D_InstModelIdx[si2+1] := siTmpModel;
  End;
  RFStart := 0;

  // =========================================================================
  // Main instance loop
  // =========================================================================

  For si := 0 To InstOrderCount - 1 Do Begin
    Inst      := pSP_ModelInstance(@SceneBank^.Memory[SP3D_InstOrder[si] * SizeOf(TSP_ModelInstance)]);
    ModelIdx  := SP3D_InstModelIdx[si];
    ModelBank := SP_BankList[ModelIdx];
    Hdr       := pSP_ModelHeader(@ModelBank^.Info[0]);

    VBase := pSP_3DVertex(@ModelBank^.Memory[0]);
    FBase := pSP_3DFace(
               NativeUInt(@ModelBank^.Memory[0]) +
               LongWord(Hdr^.VertexCount) * SizeOf(TSP_3DVertex));

    // Rebuild model if dirty
    If (Hdr^.Flags And SP3D_FLAG_DIRTY) <> 0 Then Begin
      SP_Model_Build(Inst^.BankID, Error);
      If Error.Code <> SP_ERR_OK Then Begin Error.Code := SP_ERR_OK; Continue; End;
      Hdr := pSP_ModelHeader(@ModelBank^.Info[0]);
      Inst^.MatrixDirty := True;
    End;
    If (Hdr^.Flags And SP3D_FLAG_BUILT) = 0 Then Continue;

    // Point cloud (no faces)
    If Hdr^.FaceCount = 0 Then Begin
      vc := Integer(Hdr^.VertexCount);
      If vc > SP3D_TransVertAlloc Then Begin
        SetLength(SP3D_TransVerts, vc); SP3D_TransVertAlloc := vc;
      End;
      For vi := 0 To vc - 1 Do
        With pSP_3DVertex(NativeUInt(VBase) + LongWord(vi) * SizeOf(TSP_3DVertex))^ Do
          TransformPos(X, Y, Z, Inst^.MV, SP3D_TransVerts[vi].X, SP3D_TransVerts[vi].Y, SP3D_TransVerts[vi].Z);
      For vi := 0 To vc - 1 Do Begin
        PV := SP3D_TransVerts[vi];
        If PV.Z < SP3D_NEAR_PLANE Then Continue;
        PSX := Round( PV.X / PV.Z * FX + HalfW);
        PSY := Round(-PV.Y / PV.Z * FY + HalfH);
        If (PSX < ClipX1) Or (PSX >= ClipX2) Or (PSY < ClipY1) Or (PSY >= ClipY2) Then Continue;
        SrcV := pSP_3DVertex(NativeUInt(VBase) + LongWord(vi)*SizeOf(TSP_3DVertex));
        If SP3D_FogActive Then Begin
          FogT := (PV.Z - SP3D_FogNear) / (SP3D_FogFar - SP3D_FogNear);
          If FogT < 0 Then FogT := 0;  If FogT > 1 Then FogT := 1;
          pLongWord(NativeUInt(SurfPtr) + LongWord(PSY * Stride + PSX * 4))^ := ApplyFog32(SrcV^.Colour, Round(FogT * 256));
        End Else
          pLongWord(NativeUInt(SurfPtr) + LongWord(PSY * Stride + PSX * 4))^ := SrcV^.Colour;
      End;
      Continue;
    End;

    // Pre-transform vertices — with animation lerp if active
    vc := Integer(Hdr^.VertexCount);
    If vc > SP3D_TransVertAlloc Then Begin
      SetLength(SP3D_TransVerts, vc);
      SP3D_TransVertAlloc := vc;
    End;

    If Inst^.AnimFrameA >= 0 Then Begin
      // --- Animated path ---
      // Advance animation
      If Inst^.AnimPlaying Then Begin
        Inst^.AnimT := Inst^.AnimT + Inst^.AnimSpeed;
        If Inst^.AnimT >= 1.0 Then Begin
          Inst^.AnimT       := 1.0;
          Inst^.AnimPlaying := False;
        End;
      End;

      // Get pointers to the two frame vertex arrays
      AnimDir := pSP3D_FrameDir(NativeUInt(@ModelBank^.Info[0]) + SizeOf(TSP_ModelHeader));
      EntryA := pSP3D_FrameDir(NativeUInt(AnimDir) + LongWord(Inst^.AnimFrameA) * SizeOf(TSP3D_FrameDir));
      EntryB := pSP3D_FrameDir(NativeUInt(AnimDir) + LongWord(Inst^.AnimFrameB) * SizeOf(TSP3D_FrameDir));
      FVA := pSP3D_FrameVert(@ModelBank^.Memory[EntryA^.Offset]);
      FVB := pSP3D_FrameVert(@ModelBank^.Memory[EntryB^.Offset]);
      fT := Inst^.AnimT;
      OneMinT := 1.0 - fT;

      // Lerp vertex positions, then transform to camera space
      For vi := 0 To vc - 1 Do Begin
        VA := pSP3D_FrameVert(NativeUInt(FVA) + LongWord(vi)*SizeOf(TSP3D_FrameVert));
        VB := pSP3D_FrameVert(NativeUInt(FVB) + LongWord(vi)*SizeOf(TSP3D_FrameVert));
        LX := VA^.X * OneMinT + VB^.X * fT;
        LY := VA^.Y * OneMinT + VB^.Y * fT;
        LZ := VA^.Z * OneMinT + VB^.Z * fT;
        TransformPos(LX, LY, LZ, Inst^.MV,
                     SP3D_TransVerts[vi].X,
                     SP3D_TransVerts[vi].Y,
                     SP3D_TransVerts[vi].Z);
      End;
    End Else Begin
      // --- Non-animated path (unchanged) ---
      For vi := 0 To vc - 1 Do
        With pSP_3DVertex(NativeUInt(VBase) + LongWord(vi) * SizeOf(TSP_3DVertex))^ Do
          TransformPos(X, Y, Z, Inst^.MV,
                       SP3D_TransVerts[vi].X,
                       SP3D_TransVerts[vi].Y,
                       SP3D_TransVerts[vi].Z);
    End;

    HasSmooth := (Inst^.InstFlags And SP3D_FLAG_SMOOTH) <> 0;
    If HasSmooth Then Begin
      If vc > SP3D_TransNormAlloc Then Begin
        SetLength(SP3D_TransNormals, vc); SP3D_TransNormAlloc := vc;
      End;
      For vi := 0 To vc - 1 Do
        With pSP_3DVertex(NativeUInt(VBase) + LongWord(vi) * SizeOf(TSP_3DVertex))^ Do
          TransformDir(NX, NY, NZ, Inst^.NM, SP3D_TransNormals[vi].NX, SP3D_TransNormals[vi].NY, SP3D_TransNormals[vi].NZ);
    End;

    fc := Integer(Hdr^.FaceCount);
    IsWireframe := (Inst^.InstFlags And SP3D_FLAG_WIREFRAME) <> 0;
    If IsWireframe Then Begin
      If fc > SP3D_FaceIsFrontAlloc Then Begin
        SetLength(SP3D_FaceIsFront,   fc);
        SetLength(SP3D_FaceIntenBand, fc);
        SetLength(SP3D_FaceIntenF,    fc);
        SP3D_FaceIsFrontAlloc := fc;
      End;
      FillChar(SP3D_FaceIsFront[0],   fc, 0);
      FillChar(SP3D_FaceIntenBand[0], fc, 0);
      FillChar(SP3D_FaceIntenF[0],    fc * SizeOf(aFloat), 0);
    End;

    // Frustum cull bounding sphere
    TransformPos(Hdr^.BSX, Hdr^.BSY, Hdr^.BSZ, Inst^.MV, BSCx, BSCy, BSCz);
    BSCr := Hdr^.BSRadius * Inst^.Scale;
    FrustumOK := True;
    For si2 := 0 To 5 Do
      If FP[si2][0]*BSCx + FP[si2][1]*BSCy + FP[si2][2]*BSCz + FP[si2][3] < -BSCr Then Begin
        FrustumOK := False; Break;
      End;
    If Not FrustumOK Then Continue;

    // =========================================================================
    // Face gather loop
    // =========================================================================

    If Not IsWireframe Then Begin
      LastDispTexBank := -1;
      LastDispGfxInfo := Nil;
      For fi := 0 To fc - 1 Do Begin
        Face := pSP_3DFace(NativeUInt(FBase) + LongWord(fi) * SizeOf(TSP_3DFace));
        CV[0].X := SP3D_TransVerts[Face^.V0].X; CV[0].Y := SP3D_TransVerts[Face^.V0].Y; CV[0].Z := SP3D_TransVerts[Face^.V0].Z;
        CV[0].U := Face^.U0;  CV[0].V := Face^.Vt0;
        CV[1].X := SP3D_TransVerts[Face^.V1].X; CV[1].Y := SP3D_TransVerts[Face^.V1].Y; CV[1].Z := SP3D_TransVerts[Face^.V1].Z;
        CV[1].U := Face^.U1;  CV[1].V := Face^.Vt1;
        CV[2].X := SP3D_TransVerts[Face^.V2].X; CV[2].Y := SP3D_TransVerts[Face^.V2].Y; CV[2].Z := SP3D_TransVerts[Face^.V2].Z;
        CV[2].U := Face^.U2;  CV[2].V := Face^.Vt2;
        NTri := ClipTriNear(CV[0], CV[1], CV[2], SP3D_NEAR_PLANE, T1, T2);
        If NTri = 0 Then Continue;

        GC0 := 0; GC1 := 0; GC2 := 0;
        BaseC0 := 0; BaseC1 := 0; BaseC2 := 0;
        GouraudUniform := False;

        If Inst^.Billboard Then Begin
          Inten := 1.0;
        End Else Begin
          TransformDir(Face^.NX, Face^.NY, Face^.NZ, Inst^.NM, WNX, WNY, WNZ);
          If SP3D_Light_Active Then Begin
            Dot  := -(WNX*SP3D_Light_DX + WNY*SP3D_Light_DY + WNZ*SP3D_Light_DZ);
            If Dot < 0 Then Dot := 0;
            Inten := SP3D_Light_Ambient + (1.0 - SP3D_Light_Ambient) * Dot;
          End Else
            Inten := 1.0;
          If (Face^.Flags And SP3D_FACE_GOURAUD) <> 0 Then Begin
            With pSP_3DVertex(NativeUInt(VBase) + LongWord(Face^.V0)*SizeOf(TSP_3DVertex))^ Do
              BaseC0 := SP3D_BasePal32[Byte(ResolveVertexColour(Colour, (Flags And SP3D_VERTEX_DEFAULTCOLOUR) <> 0, Face^.Colour, Inst))];
            With pSP_3DVertex(NativeUInt(VBase) + LongWord(Face^.V1)*SizeOf(TSP_3DVertex))^ Do
              BaseC1 := SP3D_BasePal32[Byte(ResolveVertexColour(Colour, (Flags And SP3D_VERTEX_DEFAULTCOLOUR) <> 0, Face^.Colour, Inst))];
            With pSP_3DVertex(NativeUInt(VBase) + LongWord(Face^.V2)*SizeOf(TSP_3DVertex))^ Do
              BaseC2 := SP3D_BasePal32[Byte(ResolveVertexColour(Colour, (Flags And SP3D_VERTEX_DEFAULTCOLOUR) <> 0, Face^.Colour, Inst))];
            If SP3D_Light_Active Then Begin
              VDot := -(SP3D_TransNormals[Face^.V0].NX*SP3D_Light_DX + SP3D_TransNormals[Face^.V0].NY*SP3D_Light_DY + SP3D_TransNormals[Face^.V0].NZ*SP3D_Light_DZ);
              If VDot < 0 Then VDot := 0;
              VInten := SP3D_Light_Ambient + (1.0 - SP3D_Light_Ambient) * VDot;
            End Else VInten := 1.0;
            GC0 := Round(VInten * 255);
            If SP3D_Light_Active Then Begin
              VDot := -(SP3D_TransNormals[Face^.V1].NX*SP3D_Light_DX + SP3D_TransNormals[Face^.V1].NY*SP3D_Light_DY + SP3D_TransNormals[Face^.V1].NZ*SP3D_Light_DZ);
              If VDot < 0 Then VDot := 0;
              VInten := SP3D_Light_Ambient + (1.0 - SP3D_Light_Ambient) * VDot;
            End Else VInten := 1.0;
            GC1 := Round(VInten * 255);
            If SP3D_Light_Active Then Begin
              VDot := -(SP3D_TransNormals[Face^.V2].NX*SP3D_Light_DX + SP3D_TransNormals[Face^.V2].NY*SP3D_Light_DY + SP3D_TransNormals[Face^.V2].NZ*SP3D_Light_DZ);
              If VDot < 0 Then VDot := 0;
              VInten := SP3D_Light_Ambient + (1.0 - SP3D_Light_Ambient) * VDot;
            End Else VInten := 1.0;
            GC2 := Round(VInten * 255);
            GouraudUniform := (BaseC0 = BaseC1) And (BaseC1 = BaseC2);
          End;
        End;

        HasTex  := False;
        TexData := Nil;
        TexW    := 0;  TexH := 0;
        If (Face^.Flags And SP3D_FACE_TEXTURED) <> 0 Then Begin
          If Face^.TexBank <> LastDispTexBank Then Begin
            GfxErr.Code := SP_ERR_OK;
            LastDispGfxInfo := SP_GetGraphicDetails(Face^.TexBank, GfxErr);
            LastDispTexBank := Face^.TexBank;
          End;
          GfxInfo := LastDispGfxInfo;
          If (GfxErr.Code = SP_ERR_OK) And Assigned(GfxInfo) And (GfxInfo^.Depth = 8) Then Begin
            HasTex  := True;
            TexData := GfxInfo^.Data;
            TexW    := Integer(GfxInfo^.Width);
            TexH    := Integer(GfxInfo^.Height);
          End;
        End Else
          GfxInfo := Nil;

        For t := 0 To NTri - 1 Do Begin
          If t = 0 Then CT := T1 Else CT := T2;
          If CT[0].Z < SP3D_NEAR_PLANE Then CT[0].Z := SP3D_NEAR_PLANE;
          If CT[1].Z < SP3D_NEAR_PLANE Then CT[1].Z := SP3D_NEAR_PLANE;
          If CT[2].Z < SP3D_NEAR_PLANE Then CT[2].Z := SP3D_NEAR_PLANE;
          SX0 := Round( CT[0].X/CT[0].Z*FX + HalfW);
          SY0 := Round(-CT[0].Y/CT[0].Z*FY + HalfH);
          SX1 := Round( CT[1].X/CT[1].Z*FX + HalfW);
          SY1 := Round(-CT[1].Y/CT[1].Z*FY + HalfH);
          SX2 := Round( CT[2].X/CT[2].Z*FX + HalfW);
          SY2 := Round(-CT[2].Y/CT[2].Z*FY + HalfH);
          E1X := SX1 - SX0;  E1Y := SY1 - SY0;
          E2X := SX2 - SX0;  E2Y := SY2 - SY0;
          Cross := E1X * E2Y - E1Y * E2X;
          If Not Inst^.Billboard Then
            If Cross <= 0 Then Continue;

          AvgCZ := (CT[0].Z + CT[1].Z + CT[2].Z) * 0.33333;
          If SP3D_FogActive Then Begin
            FogT := (AvgCZ - SP3D_FogNear) / (SP3D_FogFar - SP3D_FogNear);
            If FogT < 0 Then FogT := 0;  If FogT > 1 Then FogT := 1;
          End Else
            FogT := 0;

          If RFCount >= SP3D_RFacesAlloc Then Begin
            Inc(SP3D_RFacesAlloc, 4096);
            SetLength(SP3D_RFaces, SP3D_RFacesAlloc);
            SetLength(SP3D_GouraudLUTBuf, SP3D_RFacesAlloc * 256);
          End;
          RF := @SP3D_RFaces[RFCount];

          If (Face^.Flags And SP3D_FACE_GOURAUD) <> 0 Then Begin
            SortGC0 := GC0; SortGC1 := GC1; SortGC2 := GC2;
            SortBC0 := BaseC0; SortBC1 := BaseC1; SortBC2 := BaseC2;
            If SY0 > SY1 Then Begin SwapI(SX0,SX1); SwapI(SY0,SY1); SwapB(SortGC0,SortGC1); SwapL(SortBC0,SortBC1); End;
            If SY0 > SY2 Then Begin SwapI(SX0,SX2); SwapI(SY0,SY2); SwapB(SortGC0,SortGC2); SwapL(SortBC0,SortBC2); End;
            If SY1 > SY2 Then Begin SwapI(SX1,SX2); SwapI(SY1,SY2); SwapB(SortGC1,SortGC2); SwapL(SortBC1,SortBC2); End;
          End;

          RF^.BaseARGB[0] := TintByLight32(SortBC0);
          RF^.BaseARGB[1] := TintByLight32(SortBC1);
          RF^.BaseARGB[2] := TintByLight32(SortBC2);

          RF^.SX[0] := SX0;  RF^.SY[0] := SY0;
          RF^.SX[1] := SX1;  RF^.SY[1] := SY1;
          RF^.SX[2] := SX2;  RF^.SY[2] := SY2;
          RF^.AvgCZ    := AvgCZ;
          RF^.FogBand  := 0;
          RF^.FogT := FogT;
          RF^.FogI := Round(FogT * 256);
          RF^.Gouraud        := (Face^.Flags And SP3D_FACE_GOURAUD) <> 0;
          RF^.GouraudUniform := GouraudUniform;
          If RF^.Gouraud Then Begin
            RF^.GC[0] := SortGC0; RF^.GC[1] := SortGC1; RF^.GC[2] := SortGC2;
            RF^.GouraudLUTIdx := -1;   // unused in 32bpp
            // Store Y-sorted vertex ARGB for direct interpolation in rasteriser
            RF^.BaseARGB[0] := TintByLight32(SortBC0);
            RF^.BaseARGB[1] := TintByLight32(SortBC1);
            RF^.BaseARGB[2] := TintByLight32(SortBC2);
            If GouraudUniform Then RF^.Colour := TintByLight32(BaseC0);
          End;

          If HasTex Then Begin
            RF^.Textured  := True;
            RF^.TexData   := TexData;
            RF^.TexBankID := Face^.TexBank;
            RF^.TexW      := TexW;  RF^.TexH := TexH;
            RF^.TexWMask  := IfThen((TexW And (TexW-1)) = 0, TexW-1, -1);
            RF^.TexHMask  := IfThen((TexH And (TexH-1)) = 0, TexH-1, -1);
            RF^.TranspIdx := Integer(GfxInfo^.Transparent);
            RF^.IntenF  := Inten;
            RF^.IntenIR := Round(Inten * SP3D_Light_R * 256);
            RF^.IntenIG := Round(Inten * SP3D_Light_G * 256);
            RF^.IntenIB := Round(Inten * SP3D_Light_B * 256);
            RF^.SU[0] := (TexW-1-CT[0].U)/CT[0].Z;  RF^.SU[1] := (TexW-1-CT[1].U)/CT[1].Z;  RF^.SU[2] := (TexW-1-CT[2].U)/CT[2].Z;
            RF^.SVt[0] := CT[0].V/CT[0].Z;  RF^.SW[0] := 1.0/CT[0].Z;
            RF^.SVt[1] := CT[1].V/CT[1].Z;  RF^.SW[1] := 1.0/CT[1].Z;
            RF^.SVt[2] := CT[2].V/CT[2].Z;  RF^.SW[2] := 1.0/CT[2].Z;
          End Else Begin
            RF^.Textured  := False;
            RF^.TranspIdx := -1;
            If Not RF^.Gouraud Then
              RF^.Colour := SP3D_BasePal32[Byte(ResolveColour(Face^.Colour, (Face^.Flags And SP3D_FACE_DEFAULTCOLOUR) <> 0, Inst))];
            RF^.IntenF  := Inten;
            RF^.IntenIR := Round(Inten * SP3D_Light_R * 256);
            RF^.IntenIG := Round(Inten * SP3D_Light_G * 256);
            RF^.IntenIB := Round(Inten * SP3D_Light_B * 256);
            If RF^.IntenBand > SP3D_SHADE_BANDS-1 Then RF^.IntenBand := SP3D_SHADE_BANDS-1;
          End;
          // Set TexPal for textured faces before selecting rasteriser
          If RF^.Textured And Assigned(GfxInfo) Then
            RF^.TexPal := @GfxInfo^.Palette[0]
          Else
            RF^.TexPal := Nil;
          // Select 32bpp rasteriser
          If RF^.Textured Then Begin
            If RF^.TexWMask >= 0 Then Begin
              If RF^.TranspIdx >= 0 Then Begin
                If RF^.FogI > 0 Then RF^.Raster32 := RasterTexPow2Transp32Fog
                Else                 RF^.Raster32 := RasterTexPow2Transp32;
              End Else Begin
                If RF^.FogI > 0 Then RF^.Raster32 := RasterTexPow2Opaque32Fog
                Else                 RF^.Raster32 := RasterTexPow2Opaque32;
              End;
            End Else Begin
              If RF^.TranspIdx >= 0 Then Begin
                If RF^.FogI > 0 Then RF^.Raster32 := RasterTexNPOTTransp32Fog
                Else                 RF^.Raster32 := RasterTexNPOTTransp32;
              End Else Begin
                If RF^.FogI > 0 Then RF^.Raster32 := RasterTexNPOTOpaque32Fog
                Else                 RF^.Raster32 := RasterTexNPOTOpaque32;
              End;
            End;
          End Else If RF^.Gouraud Then Begin
            If RF^.FogI > 0 Then RF^.Raster32 := RasterGouraud32Fog
            Else                  RF^.Raster32 := RasterGouraud32;
          End Else Begin
            If RF^.FogI > 0 Then RF^.Raster32 := RasterFlat32Fog
            Else                  RF^.Raster32 := RasterFlat32;
          End;
          Inc(RFCount);
        End;
      End;

      If RFCount - RFStart > 1 Then SortFaces_Range(SP3D_RFaces, RFStart, RFCount - 1);
      RFStart := RFCount;
    End Else Begin

      // -----------------------------------------------------------------------
      // Wireframe: cull-only face pass
      // -----------------------------------------------------------------------
      For fi := 0 To fc - 1 Do Begin
        Face := pSP_3DFace(NativeUInt(FBase) + LongWord(fi) * SizeOf(TSP_3DFace));
        V0X := SP3D_TransVerts[Face^.V0].X;  V0Y := SP3D_TransVerts[Face^.V0].Y;  V0Z := SP3D_TransVerts[Face^.V0].Z;
        V1X := SP3D_TransVerts[Face^.V1].X;  V1Y := SP3D_TransVerts[Face^.V1].Y;  V1Z := SP3D_TransVerts[Face^.V1].Z;
        V2X := SP3D_TransVerts[Face^.V2].X;  V2Y := SP3D_TransVerts[Face^.V2].Y;  V2Z := SP3D_TransVerts[Face^.V2].Z;
        If (V0Z < SP3D_NEAR_PLANE) And (V1Z < SP3D_NEAR_PLANE) And (V2Z < SP3D_NEAR_PLANE) Then Continue;
        If V0Z < SP3D_NEAR_PLANE Then V0Z := SP3D_NEAR_PLANE;
        If V1Z < SP3D_NEAR_PLANE Then V1Z := SP3D_NEAR_PLANE;
        If V2Z < SP3D_NEAR_PLANE Then V2Z := SP3D_NEAR_PLANE;
        SX0 := Round( V0X/V0Z*FX + HalfW);  SY0 := Round(-V0Y/V0Z*FY + HalfH);
        SX1 := Round( V1X/V1Z*FX + HalfW);  SY1 := Round(-V1Y/V1Z*FY + HalfH);
        SX2 := Round( V2X/V2Z*FX + HalfW);  SY2 := Round(-V2Y/V2Z*FY + HalfH);
        E1X := SX1 - SX0;  E1Y := SY1 - SY0;
        E2X := SX2 - SX0;  E2Y := SY2 - SY0;
        Cross := E1X * E2Y - E1Y * E2X;
        SP3D_FaceIsFront[fi] := Cross > 0;
        TransformDir(Face^.NX, Face^.NY, Face^.NZ, Inst^.NM, WNX, WNY, WNZ);
        DotN := -(WNX*SP3D_Light_DX + WNY*SP3D_Light_DY + WNZ*SP3D_Light_DZ);
        If DotN < 0 Then DotN := 0;
        Inten := SP3D_Light_Ambient + (1.0 - SP3D_Light_Ambient) * DotN;
        SP3D_FaceIntenBand[fi] := Round(Inten * (SP3D_SHADE_BANDS - 1));
        If SP3D_FaceIntenBand[fi] > SP3D_SHADE_BANDS - 1 Then SP3D_FaceIntenBand[fi] := SP3D_SHADE_BANDS - 1;
        SP3D_FaceIntenF[fi] := Inten;   // full float for 32bpp
      End;

      // Wireframe edge pass
      IsSolid := (Inst^.InstFlags And SP3D_FLAG_WIRE_SOLID) <> 0;
      DoCull  := (Inst^.InstFlags And SP3D_FLAG_WIRE_NOCULL) = 0;
      EBase   := pSP_3DEdge(
                   NativeUInt(@ModelBank^.Memory[0]) +
                   LongWord(Hdr^.VertexCount) * SizeOf(TSP_3DVertex) +
                   LongWord(Hdr^.FaceCount)   * SizeOf(TSP_3DFace));

      If IsSolid Then Begin
        For fi := 0 To fc - 1 Do Begin
          If Not SP3D_FaceIsFront[fi] Then Continue;
          Face := pSP_3DFace(NativeUInt(FBase) + LongWord(fi) * SizeOf(TSP_3DFace));
          V0X := SP3D_TransVerts[Face^.V0].X;  V0Y := SP3D_TransVerts[Face^.V0].Y;  V0Z := SP3D_TransVerts[Face^.V0].Z;
          V1X := SP3D_TransVerts[Face^.V1].X;  V1Y := SP3D_TransVerts[Face^.V1].Y;  V1Z := SP3D_TransVerts[Face^.V1].Z;
          V2X := SP3D_TransVerts[Face^.V2].X;  V2Y := SP3D_TransVerts[Face^.V2].Y;  V2Z := SP3D_TransVerts[Face^.V2].Z;
          If V0Z < SP3D_NEAR_PLANE Then V0Z := SP3D_NEAR_PLANE;
          If V1Z < SP3D_NEAR_PLANE Then V1Z := SP3D_NEAR_PLANE;
          If V2Z < SP3D_NEAR_PLANE Then V2Z := SP3D_NEAR_PLANE;
          SX0 := Round( V0X/V0Z*FX + HalfW);  SY0 := Round(-V0Y/V0Z*FY + HalfH);
          SX1 := Round( V1X/V1Z*FX + HalfW);  SY1 := Round(-V1Y/V1Z*FY + HalfH);
          SX2 := Round( V2X/V2Z*FX + HalfW);  SY2 := Round(-V2Y/V2Z*FY + HalfH);
          RF := @SP3D_RFaces[RFCount];
          RF^.SX[0] := SX0; RF^.SY[0] := SY0;
          RF^.SX[1] := SX1; RF^.SY[1] := SY1;
          RF^.SX[2] := SX2; RF^.SY[2] := SY2;
          RF^.Colour := SP3D_BasePal32[Byte(CPAPER)];
          RF^.IntenF := 1.0;
          RF^.FogI := 0;
          RasterFlat32(RF, SurfPtr, Stride, ClipX1, ClipY1, ClipX2, ClipY2);
        End;
      End;

      For ei := 0 To Integer(Hdr^.EdgeCount) - 1 Do Begin
        Edge := pSP_3DEdge(NativeUInt(EBase) + LongWord(ei) * SizeOf(TSP_3DEdge));
        If DoCull Then Begin
          WireVisible := False;
          If (Edge^.F0 >= 0) And (Edge^.F0 < SP3D_FaceIsFrontAlloc) Then
            If SP3D_FaceIsFront[Edge^.F0] Then WireVisible := True;
          If (Edge^.F1 >= 0) And (Edge^.F1 < SP3D_FaceIsFrontAlloc) Then
            If SP3D_FaceIsFront[Edge^.F1] Then WireVisible := True;
          If Not WireVisible Then Continue;
        End;

        SrcVtx := pSP_3DVertex(NativeUInt(VBase) + LongWord(Edge^.V0) * SizeOf(TSP_3DVertex));
        WireIntenF := 1.0;
        If SP3D_Light_Active Then Begin
          If Edge^.F0 >= 0 Then WireIntenF := SP3D_FaceIntenF[Edge^.F0];
          If Edge^.F1 >= 0 Then
          WireIntenF := (WireIntenF + SP3D_FaceIntenF[Edge^.F1]) * 0.5;
        End;
        WireColour32 := ApplyInten32(SP3D_BasePal32[Byte(ResolveColour(SrcVtx^.Colour, (SrcVtx^.Flags And SP3D_VERTEX_DEFAULTCOLOUR) <> 0, Inst))], WireIntenF);

        ECX0 := SP3D_TransVerts[Edge^.V0].X;  ECY0 := SP3D_TransVerts[Edge^.V0].Y;  ECZ0 := SP3D_TransVerts[Edge^.V0].Z;
        ECX1 := SP3D_TransVerts[Edge^.V1].X;  ECY1 := SP3D_TransVerts[Edge^.V1].Y;  ECZ1 := SP3D_TransVerts[Edge^.V1].Z;

        If ECZ0 < SP3D_NEAR_PLANE Then Begin
          If ECZ1 < SP3D_NEAR_PLANE Then Continue;
          ClipT := (SP3D_NEAR_PLANE - ECZ0) / (ECZ1 - ECZ0);
          ECX0  := ECX0 + ClipT*(ECX1-ECX0); ECY0 := ECY0 + ClipT*(ECY1-ECY0); ECZ0 := SP3D_NEAR_PLANE;
        End Else If ECZ1 < SP3D_NEAR_PLANE Then Begin
          ClipT := (SP3D_NEAR_PLANE - ECZ0) / (ECZ1 - ECZ0);
          ECX1  := ECX0 + ClipT*(ECX1-ECX0); ECY1 := ECY0 + ClipT*(ECY1-ECY0); ECZ1 := SP3D_NEAR_PLANE;
        End;

        ESX0 := Round( ECX0/ECZ0*FX + HalfW);  ESY0 := Round(-ECY0/ECZ0*FY + HalfH);
        ESX1 := Round( ECX1/ECZ1*FX + HalfW);  ESY1 := Round(-ECY1/ECZ1*FY + HalfH);

        SP_DrawLineTo32(ESX0, ESY0, ESX1, ESY1, WireColour32);
      End;
    End;
  End;

  // =========================================================================
  // Rasterise gathered faces - Dispatch Loop
  // =========================================================================

  ASYNC := True;
  If ThreadCount = -1 Then Begin
    ThreadCount := 1;
    ASYNC := False;
  End;

  SP_3D_RenderBands(SurfPtr, Stride, ThreadCount, ClipX1, ClipY1, ClipX2, ClipY2, ASYNC, 32, RFCount);
  SP_InvalidateWholeDisplay;

  If (WindowID >= 0) And (SavedBank <> WindowID) Then
    SP_SetDrawingWindow(SavedBank);

End;

// ===========================================================================
// Initialization
// ===========================================================================

Initialization

  SP3D_ShadeDirty32    := True;
  SP3D_FogDirty32      := True;
  FillChar(SP3D_BasePal32,      SizeOf(SP3D_BasePal32),       0);
  SP3D_FogColour32 := $FF000000;

End.
