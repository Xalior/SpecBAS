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

Unit SP_3DEngineUnit;

// SpecBAS software 3D engine — v1: flat-shaded perspective rendering.
//
// Coordinate system:  right-handed, Y-up.
// Camera:             looks down -Z in camera space.
// Matrices:           row-major 4x4, row-vector convention  v' = v * M.
// Angles:             degrees in the public API; radians internally.
// Colours:            8-bit palette indices matching the current window palette.
//
// --- Model bank (SP_MODEL_BANK = 9) ---
//   Info   : TSP_ModelHeader  (VertexCount, FaceCount, Flags)
//   Memory : TSP_3DVertex array immediately followed by TSP_3DFace array.
//   Flags  : SP3D_FLAG_BUILT (1) — data is packed and normals computed.
//            SP3D_FLAG_DIRTY (2) — vertex/face data changed, rebuild needed.
//   Models are auto-built before rendering when SP3D_FLAG_DIRTY is set.
//   MODEL BUILD may also be called explicitly to pre-build on a quiet frame.
//
// --- Scene bank (SP_SCENE_BANK = 10) ---
//   Info   : TSP_SceneHeader  (SlotCount)
//   Memory : packed array of TSP_ModelInstance.
//   Slots are never compacted; Active=False marks a free/removed slot.
//   Each instance caches its MV and NM matrices and a MatrixDirty flag.
//   Camera changes set SP3D_CamDirty which invalidates all instances.
//
// Shade table: SP3D_ShadeTable[colour, band] maps a palette index and a
// 0..15 intensity band to the nearest palette index at that brightness.
// Rebuilt automatically on first render and whenever SP3D_ShadeDirty is set.
// Call SP_3D_InvalidateShadeTable after any PALETTE command.

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}
{$INCLUDE SpecBAS.inc}

Interface

Uses
  Math, SysUtils, SyncObjs, Classes,
  SP_BankFiling, SP_BankManager, SP_Errors, SP_SysVars, SP_Graphics, SP_Util;

// ---------------------------------------------------------------------------
// Public constants
// ---------------------------------------------------------------------------

Const
  // --- MODEL HEADER & INSTANCE FLAGS ---
  // Stored in TSP_ModelHeader.Flags and TSP_ModelInstance.InstFlags (32-bit)
  SP3D_FLAG_BUILT        = 1;   // Bit 0
  SP3D_FLAG_DIRTY        = 2;   // Bit 1
  SP3D_FLAG_SMOOTH       = 4;   // Bit 2
  SP3D_FLAG_WIREFRAME    = 8;   // Bit 3
  SP3D_FLAG_WIRE_NOCULL  = 16;  // Bit 4
  SP3D_FLAG_WIRE_SOLID   = 32;  // Bit 5
  SP3D_FLAG_HASFRAMES    = 64;  // Bit 6
  SP3D_FLAG_NEEDS_EDGES  = 128; // Internal: Tells the builder "Generate the edge list"
  SP3D_FLAG_NEEDS_SMOOTH = 256; // Internal: Tells the builder "Generate the smooth LUT"

  // --- FACE FLAGS ---
  // Stored in TSP_3DFace.Flags (Byte)
  // We avoid bits 0-6 to prevent accidental overlap with Instance logic
  SP3D_FACE_TEXTURED    = 1;   // Bit 0 (Safe because we never check Inst.Flags for this)
  SP3D_FACE_GOURAUD     = 2;   // Bit 1
  SP3D_FACE_NOEDGE_01   = 4;   // Bit 2
  SP3D_FACE_NOEDGE_20   = 8;   // Bit 3
  SP3D_FACE_DEFAULTCOLOUR = 128; // Bit 7 - MOVED far away from WIRE_SOLID (32)

  // --- VERTEX FLAGS ---
  // Stored in TSP_3DVertex.Flags (Byte)
  SP3D_VERTEX_DEFAULTCOLOUR = 128; // Match the face logic for consistency

  // --- SYSTEM IDs & LIMITS ---
  SP_MODEL_BANK         = 9;
  SP_SCENE_BANK         = 10;
  SP3D_INSTANCE_MASK    = Integer($80000000);

  // --- RENDERING CONFIG ---
  SP3D_SHADE_BANDS      = 16;
  SP3D_FOG_BANDS        = 16;
  SP3D_FRAME_NAME_LEN   = 32;
  SP3D_LUT_CACHE_SIZE   = 512;
  SP3D_MAX_RENDER_THREADS = 32;

Var
  SP3D_NEAR_PLANE : aFloat = 0.1;
  ci, band: Integer;

// ---------------------------------------------------------------------------
// Packed types stored inside banks
// ---------------------------------------------------------------------------

Type
  TClipVert = Record X, Y, Z, U, V: aFloat; End;
  TClipTri  = Array[0..2] of TClipVert;

  TSP3D_LUTCacheEntry = Record
    GC0, GC1, GC2 : Byte;
    Valid          : Boolean;
    LUT            : Array[0..15, 0..15] of Byte;
  End;

  TSP_3DVertex = Packed Record
    X, Y, Z    : aFloat;    // position
    NX, NY, NZ : aFloat;    // smooth vertex normal (computed at MODEL BUILD)
    Colour     : LongWord;  // palette index for point cloud / Gouraud base colour
    Flags      : Byte;
    Pad        : Array[0..2] of Byte;
  End;
  pSP_3DVertex = ^TSP_3DVertex;

  TSP_3DFace = Packed Record
    V0, V1, V2 : Word;
    Colour     : LongWord;
    Flags      : Byte;      // bit 0 = SP3D_FACE_TEXTURED
    NX, NY, NZ : aFloat;
    PolyIdx    : LongWord;
    TexBank    : Integer;   // graphic bank ID; -1 = untextured
    U0, Vt0    : aFloat;    // UV for vertex V0  (Vt prefix avoids clash)
    U1, Vt1    : aFloat;
    U2, Vt2    : aFloat;
  End;
  pSP_3DFace = ^TSP_3DFace;

  TSP_3DEdge = Packed Record
    V0, V1  : LongWord;          // vertex indices; V0 < V1 always
    F0, F1  : Integer;           // adjacent face indices; -1 = none
    Colour  : LongWord;
  End;
  pSP_3DEdge = ^TSP_3DEdge;

  TSP3D_PolyDir = Packed Record
    TriStart  : LongWord;   // index of first packed triangle for this polygon
    TriCount  : Word;       // N-2 triangles
    VertCount : Word;       // original N vertices
  End;
  pSP3D_PolyDir = ^TSP3D_PolyDir;

  // Directory entry for one animation frame. Stored in bank Info after the header.
  // Offset is byte offset from start of frame data section in bank Memory.
  TSP3D_FrameDir = Packed Record
    Name   : Array[0..SP3D_FRAME_NAME_LEN-1] of AnsiChar;
    Offset : LongWord;   // byte offset into Memory frame section
  End;
  pSP3D_FrameDir = ^TSP3D_FrameDir;

  // Compact XYZ-only vertex position for frame storage (no normals, no colour)
  TSP3D_FrameVert = Packed Record
    X, Y, Z : aFloat;
  End;
  pSP3D_FrameVert = ^TSP3D_FrameVert;

  TSP3D_TempEdge = Record
    SortKey : Int64;
    V0, V1  : LongWord;
    FaceIdx : Integer;
    Colour  : LongWord;
  End;
  TSP3D_TempEdgeArray = Array of TSP3D_TempEdge;

  TSP_ModelHeader = Packed Record
    VertexCount : LongWord;
    FaceCount   : LongWord;
    Flags       : LongWord;
    EdgeCount   : LongWord;
    PolyCount   : LongWord;
    BSX, BSY, BSZ : aFloat;   // bounding sphere centre (model space)
    BSRadius      : aFloat;   // bounding sphere radius
    FrameCount  : LongWord;   // Animation frame count
  End;
  pSP_ModelHeader = ^TSP_ModelHeader;

  T3DMatrix = Array[0..15] of aFloat;
  pT3DMatrix = ^T3DMatrix;

  // TSP_ModelInstance lives inside scene bank Memory, so layout is fixed.
  // Pad keeps the record a multiple of 4 bytes.
  TSP_ModelInstance = Packed Record
    ID            : Integer;
    BankID        : Integer;
    X, Y, Z       : aFloat;
    RX, RY, RZ    : aFloat;
    Scale         : aFloat;
    Visible       : Boolean;
    Active        : Boolean;
    MatrixDirty   : Boolean;
    Billboard     : Boolean;
    MV            : T3DMatrix;   // cached model-view matrix
    NM            : T3DMatrix;   // cached normal (rotation-only) matrix
    ColourOverride    : LongWord;
    UseColourOverride : Boolean;
    AnimFrameA  : Integer;   // index of 'from' frame (-1 = no animation)
    AnimFrameB  : Integer;   // index of 'to' frame
    AnimT       : aFloat;    // interpolation position 0..1
    AnimSpeed   : aFloat;    // delta per render call
    AnimPlaying : Boolean;
    AnimPad     : Byte;
    ParentID    : Integer;
    InstFlags   : LongWord;
  End;
  pSP_ModelInstance = ^TSP_ModelInstance;

  TSP_SceneHeader = Packed Record
    SlotCount  : LongWord;
    Cam_X      : aFloat;
    Cam_Y      : aFloat;
    Cam_Z      : aFloat;
    Cam_RX     : aFloat;
    Cam_RY     : aFloat;
    Cam_RZ     : aFloat;
    Cam_FOV    : aFloat;
    Cam_Near   : aFloat;
  End;
  pSP_SceneHeader = ^TSP_SceneHeader;

  TSP3D_TransNormal = Packed Record
    NX, NY, NZ: aFloat;
  End;

// ---------------------------------------------------------------------------
// Build-state scratch (not stored in a bank)
// ---------------------------------------------------------------------------

  TSP_ModelBuildState = Record
    BankID : Integer;
    Active : Boolean;
    NextPolyIdx: Integer;
    Verts  : Array of TSP_3DVertex;
    Faces  : Array of TSP_3DFace;
    Frames : Array of Record                // scratch frame storage
               Name  : String[SP3D_FRAME_NAME_LEN-1];
               Verts : Array of TSP3D_FrameVert;
             End;
  End;

// ---------------------------------------------------------------------------
// Internal render-pipeline type
// ---------------------------------------------------------------------------
  pSP_RenderFace = ^TSP_RenderFace;
  TRasterProc = Procedure(Const RF: pSP_RenderFace; SurfPtr: pByte; Stride: Integer; ClipX1, ClipY1, ClipX2, ClipY2: Integer);

  TSP_RenderFace = Record
    SX, SY     : Array[0..2] of Integer;
    AvgCZ      : aFloat;
    Colour     : LongWord;
    Textured   : Boolean;
    Gouraud    : Boolean;
    GouraudUniform : Boolean;
    FogBand    : Byte;
    FogT       : aFloat;
    FogI       : Integer;
    TranspIdx  : Integer;     // -1 = opaque
    TexData    : pByte;
    TexW, TexH : Integer;
    TexWMask   : Integer;
    TexHMask   : Integer;
    TexBankID  : Integer;
    SU, SVt    : Array[0..2] of aFloat;
    SW         : Array[0..2] of aFloat;
    IntenBand  : Byte;
    GC         : Array[0..2] of Byte;
    GouraudLUTIdx : Integer;
    IntenF         : aFloat;                    // float intensity for 32bpp path
    IntenIR        : Integer;                   // per-channel intensity × 256 (= IntenI × LightR)
    IntenIG        : Integer;
    IntenIB        : Integer;
    BaseARGB       : Array[0..2] of LongWord;   // Y-sorted vertex ARGB for 32bpp Gouraud
    Raster8        : TRasterProc;               // 8bpp rasteriser dispatch
    Raster32       : TRasterProc;               // 32bpp rasteriser dispatch
    TexPal         : pTP_Colour;                // 32bpp: pointer to graphic bank palette
  End;

  TSP3D_RenderBandParams = Record
    SurfPtr                         : pByte;
    Stride                          : Integer;
    ClipX1, ClipY1, ClipX2, ClipY2 : Integer;
    RFaceCount                      : Integer;
    BitDepth                        : Integer;
    Done                            : Boolean;
  End;
  pSP3D_RenderBandParams = ^TSP3D_RenderBandParams;

  TSP3D_RenderThread = Class(TThread)
  Private
    FParams : pSP3D_RenderBandParams;
  Protected
    Procedure Execute; Override;
  Public
    StartEvent : TEvent;
    Terminate_ : Boolean;
    Constructor Create;
    Destructor  Destroy; Override;
    Procedure   AssignBand(Params: pSP3D_RenderBandParams);
  End;

// ---------------------------------------------------------------------------
// Public globals
// ---------------------------------------------------------------------------

Var
  SP3D_RFaces         : Array of TSP_RenderFace;
  SP_ModelBuildStates : Array of TSP_ModelBuildState;
  SP3D_ActiveScene    : Integer;
  SP3D_RFacesAlloc    : Integer;

  SP3D_Cam_X,  SP3D_Cam_Y,  SP3D_Cam_Z  : aFloat;
  SP3D_Cam_RX, SP3D_Cam_RY, SP3D_Cam_RZ : aFloat;
  SP3D_Cam_FOV   : aFloat;
  SP3D_CamDirty  : Boolean;
  SP3D_ViewMatrix    : T3DMatrix;
  SP3D_ViewMatrixOK  : Boolean;
  SP3D_CamRotMatrix  : T3DMatrix;   // camera rotation only (for billboard NM)

  SP3D_Light_DX, SP3D_Light_DY, SP3D_Light_DZ : aFloat;
  SP3D_Light_Ambient : aFloat;
  SP3D_Light_Active  : Boolean;
  SP3D_Light_R, SP3D_Light_G, SP3D_Light_B : aFloat;  // light colour, 0..1 each; default 1,1,1

  SP3D_ShadeTable : Array[0..255, 0..SP3D_SHADE_BANDS-1] of Byte;
  SP3D_PalCache   : Array[0..255] of TP_Colour;
  SP3D_ShadeDirty : Boolean;
  SP3D_ShadeDirty32 : Boolean;

  SP3D_FogActive  : Boolean;
  SP3D_FogNear    : aFloat;
  SP3D_FogFar     : aFloat;
  SP3D_FogColour  : Byte;
  SP3D_FogDirty   : Boolean;
  SP3D_FogTable   : Array[0..255, 0..SP3D_FOG_BANDS-1] of Byte;

  SP3D_TransVerts     : Array of TSP_3DVertex;   // camera-space transformed verts
  SP3D_TransVertAlloc : Integer;

  SP3D_InstOrder      : Array of Integer;
  SP3D_InstModelIdx   : Array of Integer;   // cached SP_FindBankID result
  SP3D_InstDistArr    : Array of aFloat;
  SP3D_InstOrderAlloc : Integer;

  SP3D_LUTCache      : Array[0..SP3D_LUT_CACHE_SIZE-1] of TSP3D_LUTCacheEntry;
  SP3D_LUTCacheNext  : Integer;
  SP3D_LUTCacheDirty : Boolean;

  SP3D_GouraudLUTBuf   : Array of Byte;   // flat buffer: slot i at [i*256]
  SP3D_GouraudLUTCount : Integer;         // slots consumed this render call
  SP3D_BlendTable  : Array[0..255, 0..255] of Byte;
  SP3D_BlendDirty  : Boolean;
  SP3D_ColourCube  : Array[0..31, 0..31, 0..31] of Byte;
  SP3D_GouraudWeights : Array[0..255] of Packed Record W0, W1, W2: Byte; End;
  SP3D_TransNormals   : Array of TSP3D_TransNormal;
  SP3D_TransNormAlloc : Integer;

  SP3D_FaceIsFront      : Array of Boolean;
  SP3D_FaceIntenBand    : Array of Byte;
  SP3D_FaceIntenF       : Array of aFloat;
  SP3D_FaceIsFrontAlloc : Integer;

  SP3D_RenderThreads    : Array[0..SP3D_MAX_RENDER_THREADS-1] of TSP3D_RenderThread;
  SP3D_RenderBandParams : Array[0..SP3D_MAX_RENDER_THREADS-1] of TSP3D_RenderBandParams;
  SP3D_ThreadCount      : Integer;
  SP3D_BandsRemaining   : Integer;
  SP3D_AllBandsDone     : TEvent;

  SP3D_NextInstID : Integer = 0; // Instance counter

// ---------------------------------------------------------------------------
// Public interface
// ---------------------------------------------------------------------------

// Shade table invalidation (call after PALETTE changes)
Function  ResolveColour(BakedColour: LongWord; IsDefault: Boolean; Const Inst: pSP_ModelInstance): LongWord; Inline;
Function  ResolveVertexColour(BakedColour: LongWord; IsDefault: Boolean; FaceColour: LongWord; Const Inst: pSP_ModelInstance): LongWord; Inline;
Procedure SP_3D_BuildShadeTable(Const Pal: Array of TP_Colour);
Procedure SP_3D_InvalidateShadeTable;
Procedure SP_3D_BuildColourCube;

// Scenes
Function  GetSceneBank(SceneID: Integer; Var Error: TSP_ErrorCode): pSP_Bank;
Function  SP_Scene_New  (Var Error: TSP_ErrorCode): Integer;
Procedure SP_Scene_Use  (SceneID: Integer; Var Error: TSP_ErrorCode);
Procedure SP_Scene_Clear(SceneID: Integer; Var Error: TSP_ErrorCode);
Procedure SP_Scene_Erase(SceneID: Integer; Var Error: TSP_ErrorCode);
Function  SceneSlotCount(Bank: pSP_Bank): LongWord;
Procedure InvalidateAllSceneMatrices;
Function  FindInstInScene(Bank: pSP_Bank; InstID: Integer): pSP_ModelInstance;

// Model banks
Function  SP_Model_New   (Var Error: TSP_ErrorCode): Integer;
Function  SP_Model_Vertex(BankID: Integer; X, Y, Z: aFloat; Colour: Integer; Var Error: TSP_ErrorCode): Integer;
Procedure SP_Model_VertexArray(BankID, ArrIdx: Integer; Var Error: TSP_ErrorCode);
Procedure SP_Model_Face(BankID, V0, V1, V2, Colour, TexBank: Integer; U0, Vt0, U1, Vt1, U2, Vt2: aFloat; Var Error: TSP_ErrorCode);
Procedure SP_Model_FaceArray(BankID, ArrIdx: Integer; Var Error: TSP_ErrorCode);
Procedure SP_Model_Poly(BankID: Integer; Const Verts: Array of Integer; Const UVs: Array of aFloat; Colour, TexBank: Integer; Var Error: TSP_ErrorCode);
Procedure SP_Model_UpdateUV(BankID, PolyIdx: Integer; Const UVs: Array of aFloat; Var Error: TSP_ErrorCode);
Procedure SP_Model_SetVert(BankID, Idx: Integer; X, Y, Z: aFloat; Var Error: TSP_ErrorCode);
Procedure SP_Model_Build (BankID: Integer; Var Error: TSP_ErrorCode);
Procedure SP_Model_Erase (BankID: Integer; Var Error: TSP_ErrorCode);
Function  SP_Model_IsPlaying(InstID: Integer; Var Error: TSP_ErrorCode): Boolean;
Procedure SP_Model_SetParent(InstID, ParentID: Integer; Var Error: TSP_ErrorCode);

// Model animation
Procedure SP_Model_AddFrame  (BankID: Integer; Const FrameName: aString; Var Error: TSP_ErrorCode);
Procedure SP_Model_AnimPlay  (InstID: Integer; Const FrameA, FrameB: aString; Speed: aFloat; Var Error: TSP_ErrorCode);
Procedure SP_Model_AnimStop  (InstID: Integer; Var Error: TSP_ErrorCode);
Procedure SP_Model_AnimFrame (InstID: Integer; Const FrameName: aString; Var Error: TSP_ErrorCode);
Function  SP_Model_AnimGetFrame(InstID: Integer; Var Error: TSP_ErrorCode): aString;

// Instances (all target the active scene)
Function  SP_Model_Place(BankID: Integer; X, Y, Z, RX, RY, RZ, Scale: aFloat; Var Error: TSP_ErrorCode): Integer;
Procedure SP_Model_Move  (InstID: Integer; DX, DY, DZ: aFloat; Var Error: TSP_ErrorCode);
Procedure SP_Model_Turn  (InstID: Integer; DRX, DRY, DRZ: aFloat; Var Error: TSP_ErrorCode);
Procedure SP_Model_Scale (InstID: Integer; S: aFloat; Var Error: TSP_ErrorCode);
Procedure SP_Model_MoveTo(InstID: Integer; X, Y, Z: aFloat; Var Error: TSP_ErrorCode);
Procedure SP_Model_TurnTo(InstID: Integer; RX, RY, RZ: aFloat; Var Error: TSP_ErrorCode);
Procedure SP_Model_GetPos(InstID: Integer; Var X, Y, Z: aFloat; Var Error: TSP_ErrorCode);
Procedure SP_Model_GetRot(InstID: Integer; Var RX, RY, RZ: aFloat; Var Error: TSP_ErrorCode);
Procedure SP_Model_GetScale(InstID: Integer; Var S: aFloat; Var Error: TSP_ErrorCode);
Procedure SP_Model_Remove(InstID: Integer; Var Error: TSP_ErrorCode);
Procedure SP_Model_Hide  (InstID: Integer; Var Error: TSP_ErrorCode);
Procedure SP_Model_Show  (InstID: Integer; Var Error: TSP_ErrorCode);
Procedure SP_Model_SetBillboard(InstID: Integer; On: Boolean; Var Error: TSP_ErrorCode);
Procedure SP_Model_SetShading(BankID: Integer; Smooth: Boolean; Var Error: TSP_ErrorCode);
Procedure SP_Model_SetWireframe(BankID: Integer; Enabled, NoCull, Solid: Boolean; Var Error: TSP_ErrorCode);
Procedure SP_Model_SetColourOverride(InstID: Integer; Colour: Integer; Var Error: TSP_ErrorCode);
Procedure BuildInstanceMatrices(Var Inst: TSP_ModelInstance; ParentMV: pT3DMatrix = Nil; ParentNM: pT3DMatrix = Nil);

// Camera
Procedure SP_3D_Camera    (X, Y, Z, RX, RY, RZ, FOV: aFloat);
Procedure SP_3D_CameraMove(DX, DY, DZ: aFloat);
Procedure SP_3D_CameraTurn(DRX, DRY, DRZ: aFloat);
Procedure SP_3D_CameraFacePoint(TX, TY, TZ: aFloat);
Procedure SP_3D_CameraFaceInst (InstID: Integer; Var Error: TSP_ErrorCode);
Procedure SP_3D_GetCamera(Var X, Y, Z, RX, RY, RZ, FOV: aFloat);
Procedure SP_3D_SetNearPlane(Near: aFloat);
Function  SP_3D_ModelColl      (InstA, InstB: Integer; Var Error: TSP_ErrorCode): Boolean;
Function  SP_3D_Point3D        (SX, SY: Integer; Var Error: TSP_ErrorCode): Integer;
Function  SP_3D_FaceAt         (InstID, SX, SY: Integer; Var Error: TSP_ErrorCode): Integer;

// Light
Procedure SP_3D_LightDir    (DX, DY, DZ: aFloat);
Procedure SP_3D_LightAmbient(A: aFloat);
Procedure SP_3D_LightColour (R, G, B: aFloat);

// Fog

Procedure SP_3D_Fog    (Near, Far: aFloat; Colour: Byte);
Procedure SP_3D_FogOff;
Procedure SP_3D_InvalidateFogTable;
Procedure SP_3D_BuildFogTable(Const Pal: Array of TP_Colour);

// Render
Procedure SortFaces_Range(Var Faces: Array of TSP_RenderFace; Lo, Hi: Integer);
Function  ClipTriNear(Const V0, V1, V2: TClipVert; Near: aFloat; Out T1, T2: TClipTri): Integer;
Procedure TransformPos(X, Y, Z: aFloat; Const M: T3DMatrix; Out OX, OY, OZ: aFloat);
Procedure TransformDir(X, Y, Z: aFloat; Const M: T3DMatrix; Out OX, OY, OZ: aFloat);
Procedure SP_3D_Render(WindowID, SceneID, ThreadCount: Integer; Var Error: TSP_ErrorCode);

// Hook called from SP_DeleteBank / SP_DeleteAllBanks
Procedure SP_3D_OnDeleteBank(BankID, DataType: Integer);
Procedure SP_3D_ResetState;

// Threading
Procedure SP_3D_EnsureThreadPool(NumThreads: Integer);
Procedure SP_3D_RenderBands(SurfPtr: pByte; Stride, NumThreads, ClipX1, ClipY1, ClipX2, ClipY2: Integer; IsAsync: Boolean; BitDepth: Integer; AFaceCount: Integer);
Procedure SP_3D_RenderSync;

Implementation

Uses
  SP_AnsiStringList,
  SP_Main, SP_Variables;

// Debugging

Procedure SP_3D_DumpModel(BankID: Integer);
Var
  Idx  : Integer;
  Bank : pSP_Bank;
  Hdr  : pSP_ModelHeader;
  V    : pSP_3DVertex;
  F    : pSP_3DFace;
  i    : Integer;
Begin
  Idx := SP_FindBankID(BankID);
  If Idx < 0 Then Begin WriteLn('Bank not found'); Exit; End;
  Bank := SP_BankList[Idx];
  Hdr  := pSP_ModelHeader(@Bank^.Info[0]);
  LogError('VertexCount: ' + IntToString( Hdr^.VertexCount));
  LogError('FaceCount: ' + IntToString(Hdr^.FaceCount));
  V := pSP_3DVertex(@Bank^.Memory[0]);
  For i := 0 To Min(4, Integer(Hdr^.VertexCount) - 1) Do Begin
    LogError(aString(Format('V%d: %.3f %.3f %.3f colour=%d flags=%d',
      [i, V^.X, V^.Y, V^.Z, V^.Colour, V^.Flags])));
    Inc(V);
  End;
  F := pSP_3DFace(NativeUInt(@Bank^.Memory[0]) +
       LongWord(Hdr^.VertexCount) * SizeOf(TSP_3DVertex));
  For i := 0 To Min(4, Integer(Hdr^.FaceCount) - 1) Do Begin
    LogError(aString(Format('F%d: V0=%d V1=%d V2=%d colour=%d flags=%d U0=%.3f V0=%.3f',
      [i, F^.V0, F^.V1, F^.V2, F^.Colour, F^.Flags, F^.U0, F^.Vt0])));
    Inc(F);
  End;
End;

// ===========================================================================
// Matrix helpers  (row-major 4x4, row-vector convention: v' = v * M)
// Element layout: [row*4 + col]
// ===========================================================================

Procedure Mat4Identity(Out M: T3DMatrix);
Begin
  FillChar(M, SizeOf(M), 0);
  M[0] := 1;  M[5] := 1;  M[10] := 1;  M[15] := 1;
End;

Procedure Mat4Mul(Const A, B: T3DMatrix; Out Res: T3DMatrix);
Var row, col, k: Integer;
Begin
  For row := 0 To 3 Do
    For col := 0 To 3 Do Begin
      Res[row*4+col] := 0;
      For k := 0 To 3 Do
        Res[row*4+col] := Res[row*4+col] + A[row*4+k] * B[k*4+col];
    End;
End;

Procedure Mat4Trans(TX, TY, TZ: aFloat; Out M: T3DMatrix);
Begin
  Mat4Identity(M);
  M[12] := TX;  M[13] := TY;  M[14] := TZ;
End;

Procedure Mat4RotX(A: aFloat; Out M: T3DMatrix);
Var S, C: aFloat;
Begin
  SinCos(A, S, C);
  Mat4Identity(M);
  M[5]  :=  C;  M[6]  := S;
  M[9]  := -S;  M[10] := C;
End;

Procedure Mat4RotY(A: aFloat; Out M: T3DMatrix);
Var S, C: aFloat;
Begin
  SinCos(A, S, C);
  Mat4Identity(M);
  M[0]  :=  C;  M[2]  := -S;
  M[8]  :=  S;  M[10] :=  C;
End;

Procedure Mat4RotZ(A: aFloat; Out M: T3DMatrix);
Var S, C: aFloat;
Begin
  SinCos(A, S, C);
  Mat4Identity(M);
  M[0] :=  C;  M[1] := S;
  M[4] := -S;  M[5] := C;
End;

Procedure Mat4ScaleU(S: aFloat; Out M: T3DMatrix);
Begin
  Mat4Identity(M);
  M[0] := S;  M[5] := S;  M[10] := S;
End;

Procedure TransformPos(X, Y, Z: aFloat; Const M: T3DMatrix; Out OX, OY, OZ: aFloat);
Begin
  OX := X*M[0] + Y*M[4] + Z*M[8]  + M[12];
  OY := X*M[1] + Y*M[5] + Z*M[9]  + M[13];
  OZ := X*M[2] + Y*M[6] + Z*M[10] + M[14];
End;

Procedure TransformDir(X, Y, Z: aFloat; Const M: T3DMatrix; Out OX, OY, OZ: aFloat);
Begin
  OX := X*M[0] + Y*M[4] + Z*M[8];
  OY := X*M[1] + Y*M[5] + Z*M[9];
  OZ := X*M[2] + Y*M[6] + Z*M[10];
End;

Procedure BuildViewMatrix;
Var
  MCT, MCRz, MCRx, MCRy, Tmp : T3DMatrix;
  ARX, ARY, ARZ : aFloat;
Begin
  ARX := SP3D_Cam_RX;  SP_AngleToRad(ARX);
  ARY := SP3D_Cam_RY;  SP_AngleToRad(ARY);
  ARZ := SP3D_Cam_RZ;  SP_AngleToRad(ARZ);
  Mat4Trans(-SP3D_Cam_X, -SP3D_Cam_Y, -SP3D_Cam_Z, MCT);
  Mat4RotZ(-ARZ, MCRz);
  Mat4RotX(-ARX, MCRx);
  Mat4RotY(-ARY, MCRy);
  Mat4Mul(MCT, MCRz, Tmp);  Mat4Mul(Tmp, MCRx, SP3D_ViewMatrix);
  Mat4Mul(SP3D_ViewMatrix, MCRy, Tmp);  SP3D_ViewMatrix := Tmp;
  // Camera rotation only (no translation) for billboard normal matrix
  Mat4Mul(MCRz, MCRx, Tmp);  Mat4Mul(Tmp, MCRy, SP3D_CamRotMatrix);
  SP3D_ViewMatrixOK := True;
End;

Procedure BuildInstanceMatrices(Var Inst: TSP_ModelInstance; ParentMV: pT3DMatrix = Nil; ParentNM: pT3DMatrix = Nil);
Var
  MS, MRx, MRy, MRz, MT : T3DMatrix;
  Model, Tmp, Tmp2       : T3DMatrix;
  ARX, ARY, ARZ          : aFloat;
  CRT                    : T3DMatrix;
  BaseView               : T3DMatrix;   // either SP3D_ViewMatrix or parent's MV
  BaseNorm               : T3DMatrix;   // either SP3D_ViewMatrix or parent's NM
Begin
  If Not SP3D_ViewMatrixOK Then BuildViewMatrix;

  // Choose which matrix to combine with — parent's or global view
  If Assigned(ParentMV) Then Begin
    BaseView := ParentMV^;
    BaseNorm := ParentNM^;
  End Else Begin
    BaseView := SP3D_ViewMatrix;
    BaseNorm := SP3D_ViewMatrix;
  End;

  Mat4ScaleU(Inst.Scale, MS);
  Mat4Trans(Inst.X, Inst.Y, Inst.Z, MT);

  If Inst.Billboard Then Begin
    CRT[0]  := SP3D_CamRotMatrix[0];  CRT[1]  := SP3D_CamRotMatrix[4];  CRT[2]  := SP3D_CamRotMatrix[8];  CRT[3]  := 0;
    CRT[4]  := SP3D_CamRotMatrix[1];  CRT[5]  := SP3D_CamRotMatrix[5];  CRT[6]  := SP3D_CamRotMatrix[9];  CRT[7]  := 0;
    CRT[8]  := SP3D_CamRotMatrix[2];  CRT[9]  := SP3D_CamRotMatrix[6];  CRT[10] := SP3D_CamRotMatrix[10]; CRT[11] := 0;
    CRT[12] := 0; CRT[13] := 0; CRT[14] := 0; CRT[15] := 1;
    ARZ := Inst.RZ;  SP_AngleToRad(ARZ);
    Mat4RotZ(ARZ, MRz);
    Mat4Mul(MS,  MRz, Tmp);
    Mat4Mul(Tmp, CRT, Tmp2);
    Mat4Mul(Tmp2, MT, Model);
    Mat4Mul(Model, BaseView, Inst.MV);
    Mat4Mul(MRz, CRT, Tmp);
    Mat4Mul(Tmp, SP3D_CamRotMatrix, Inst.NM);
  End Else Begin
    ARX := Inst.RX;  SP_AngleToRad(ARX);
    ARY := Inst.RY;  SP_AngleToRad(ARY);
    ARZ := Inst.RZ;  SP_AngleToRad(ARZ);
    Mat4RotX(ARX, MRx);
    Mat4RotY(ARY, MRy);
    Mat4RotZ(ARZ, MRz);
    Mat4Mul(MS, MRx, Tmp);     Mat4Mul(Tmp, MRy, Model);
    Mat4Mul(Model, MRz, Tmp);  Mat4Mul(Tmp, MT, Model);
    Mat4Mul(Model, BaseView, Inst.MV);
    Mat4Mul(MRx, MRy, Tmp);    Mat4Mul(Tmp, MRz, Model);
    Mat4Mul(Model, BaseNorm, Inst.NM);
  End;

  Inst.MatrixDirty := False;
End;

// ===========================================================================
// Shade table
// ===========================================================================

Procedure SP_3D_BuildShadeTable(Const Pal: Array of TP_Colour);
Var
  ci, band, pi : Integer;
  Intensity    : aFloat;
  SR, SG, SB   : Integer;
  Best, Cur    : Int64;
  E            : TP_Colour;
Begin
  Move(Pal[0], SP3D_PalCache[0], SizeOf(SP3D_PalCache));
  For ci := 0 To 255 Do
    For band := 0 To SP3D_SHADE_BANDS - 1 Do Begin
      Intensity := band / (SP3D_SHADE_BANDS - 1);
      E  := Pal[ci];
      SR := Round(E.R * Intensity * SP3D_Light_R);  If SR > 255 Then SR := 255;
      SG := Round(E.G * Intensity * SP3D_Light_G);  If SG > 255 Then SG := 255;
      SB := Round(E.B * Intensity * SP3D_Light_B);  If SB > 255 Then SB := 255;
      Best := High(Int64);
      SP3D_ShadeTable[ci, band] := ci;
      For pi := 0 To 255 Do Begin
        E   := Pal[pi];
        Cur := Int64(SR - E.R) * Int64(SR - E.R) +
               Int64(SG - E.G) * Int64(SG - E.G) +
               Int64(SB - E.B) * Int64(SB - E.B);
        If Cur < Best Then Begin
          Best := Cur;
          SP3D_ShadeTable[ci, band] := Byte(pi);
        End;
      End;
    End;
  SP3D_ShadeDirty := False;
End;

Procedure SP_3D_InvalidateShadeTable;
Begin
  SP3D_ShadeDirty    := True;
  SP3D_FogDirty      := True;
  SP3D_BlendDirty    := True;
  SP3D_LUTCacheDirty := True;
  SP3D_ShadeDirty32  := True;
End;

Function ShadedIndex(BaseIdx: Byte; Intensity: aFloat): Byte; Inline;
Var Band: Integer;
Begin
  Band := Round(Intensity * (SP3D_SHADE_BANDS - 1));
  If Band < 0                  Then Band := 0;
  If Band > SP3D_SHADE_BANDS-1 Then Band := SP3D_SHADE_BANDS - 1;
  Result := SP3D_ShadeTable[BaseIdx, Band];
End;

Procedure SP_3D_BuildBlendTable(Const Pal: Array of TP_Colour);
Var
  c0, c1, pi : Integer;
  TR, TG, TB : Integer;
  Best, Cur  : Int64;
  E          : TP_Colour;
Begin
  For c0 := 0 To 255 Do
    For c1 := 0 To 255 Do Begin
      If c0 = c1 Then Begin
        SP3D_BlendTable[c0, c1] := c0;
        Continue;
      End;
      TR := (Pal[c0].R + Pal[c1].R) Shr 1;
      TG := (Pal[c0].G + Pal[c1].G) Shr 1;
      TB := (Pal[c0].B + Pal[c1].B) Shr 1;
      Best := High(Int64);
      SP3D_BlendTable[c0, c1] := c0;
      For pi := 0 To 255 Do Begin
        E   := Pal[pi];
        Cur := Int64(TR-E.R)*Int64(TR-E.R) +
               Int64(TG-E.G)*Int64(TG-E.G) +
               Int64(TB-E.B)*Int64(TB-E.B);
        If Cur = 0 Then Begin
          SP3D_BlendTable[c0, c1] := Byte(pi);
          Break;
        End;
        If Cur < Best Then Begin
          Best := Cur;
          SP3D_BlendTable[c0, c1] := Byte(pi);
        End;
      End;
    End;
  SP3D_BlendDirty := False;
End;

Procedure SP_3D_BuildColourCube;
Var
  r, g, b, pi : Integer;
  TR, TG, TB  : Integer;
  Best, Cur   : Int64;
Begin
  For r := 0 To 31 Do
    For g := 0 To 31 Do
      For b := 0 To 31 Do Begin
        TR   := r * 8 + 4;   // centre of 5-bit cell: covers r*8 .. r*8+7
        TG   := g * 8 + 4;
        TB   := b * 8 + 4;
        Best := High(Int64);
        SP3D_ColourCube[r, g, b] := 0;
        For pi := 0 To 255 Do Begin
          Cur := Int64(TR - SP3D_PalCache[pi].R) * Int64(TR - SP3D_PalCache[pi].R) +
                 Int64(TG - SP3D_PalCache[pi].G) * Int64(TG - SP3D_PalCache[pi].G) +
                 Int64(TB - SP3D_PalCache[pi].B) * Int64(TB - SP3D_PalCache[pi].B);
          If Cur = 0 Then Begin
            SP3D_ColourCube[r, g, b] := Byte(pi);
            Break;
          End;
          If Cur < Best Then Begin
            Best := Cur;
            SP3D_ColourCube[r, g, b] := Byte(pi);
          End;
        End;
      End;
End;

Procedure BuildGouraudLUT(C0, C1, C2: Byte; LUT: pByte);
Var
  k          : Integer;
  W0, W1, W2 : Integer;
  TR, TG, TB : Integer;
  R0, G0, B0 : Integer;
  R1, G1, B1 : Integer;
  R2, G2, B2 : Integer;
Begin
  R0 := SP3D_PalCache[C0].R;  G0 := SP3D_PalCache[C0].G;  B0 := SP3D_PalCache[C0].B;
  R1 := SP3D_PalCache[C1].R;  G1 := SP3D_PalCache[C1].G;  B1 := SP3D_PalCache[C1].B;
  R2 := SP3D_PalCache[C2].R;  G2 := SP3D_PalCache[C2].G;  B2 := SP3D_PalCache[C2].B;
  For k := 0 To 255 Do Begin
    W0 := SP3D_GouraudWeights[k].W0;
    W1 := SP3D_GouraudWeights[k].W1;
    W2 := SP3D_GouraudWeights[k].W2;
    TR := (R0*W0 + R1*W1 + R2*W2 + 7) Div 15;
    TG := (G0*W0 + G1*W1 + G2*W2 + 7) Div 15;
    TB := (B0*W0 + B1*W1 + B2*W2 + 7) Div 15;
    pByte(NativeUInt(LUT) + LongWord(k))^ :=
      SP3D_ColourCube[TR Shr 3, TG Shr 3, TB Shr 3];
  End;
End;

// ---------------------------------------------------------------------------
// GetGouraudLUT
// Returns a pointer to a cached 256-byte LUT for (GC0, GC1, GC2).
// Builds and caches on miss. Round-robin eviction on cache full.
// All entries invalidated when SP3D_LUTCacheDirty is set.
// ---------------------------------------------------------------------------
Function GetGouraudLUT(GC0, GC1, GC2: Byte): pByte;
Var
  Slot : Integer;
  H    : Cardinal;
Begin
  If SP3D_LUTCacheDirty Then Begin
    FillChar(SP3D_LUTCache, SizeOf(SP3D_LUTCache), 0);
    SP3D_LUTCacheDirty := False;
  End;

  // Direct-mapped hash: O(1) lookup — no linear scan
  H    := (Cardinal(GC0) Xor (Cardinal(GC1) Shl 8) Xor (Cardinal(GC2) Shl 16));
  H    := (H Xor (H Shr 16)) * $45D9F3B;
  Slot := Integer((H Xor (H Shr 16)) And Cardinal(SP3D_LUT_CACHE_SIZE - 1));

  If Not SP3D_LUTCache[Slot].Valid Or
     (SP3D_LUTCache[Slot].GC0 <> GC0) Or
     (SP3D_LUTCache[Slot].GC1 <> GC1) Or
     (SP3D_LUTCache[Slot].GC2 <> GC2) Then Begin
    SP3D_LUTCache[Slot].GC0  := GC0;
    SP3D_LUTCache[Slot].GC1  := GC1;
    SP3D_LUTCache[Slot].GC2  := GC2;
    SP3D_LUTCache[Slot].Valid := True;
    BuildGouraudLUT(GC0, GC1, GC2, @SP3D_LUTCache[Slot].LUT[0, 0]);
  End;

  Result := @SP3D_LUTCache[Slot].LUT[0, 0];
End;

// ===========================================================================
// Build-state helpers
// ===========================================================================

Function FindBuildState(BankID: Integer): Integer;
Var i: Integer;
Begin
  Result := -1;
  For i := 0 To High(SP_ModelBuildStates) Do
    If SP_ModelBuildStates[i].Active And (SP_ModelBuildStates[i].BankID = BankID) Then
      Begin Result := i; Exit; End;
End;

Function AllocBuildState(BankID: Integer): Integer;
Var i: Integer;
Begin
  For i := 0 To High(SP_ModelBuildStates) Do
    If Not SP_ModelBuildStates[i].Active Then Begin
      SP_ModelBuildStates[i].BankID := BankID;
      SP_ModelBuildStates[i].Active := True;
      SP_ModelBuildStates[i].NextPolyIdx := 0;
      SetLength(SP_ModelBuildStates[i].Verts, 0);
      SetLength(SP_ModelBuildStates[i].Faces, 0);
      Result := i;  Exit;
    End;
  i := Length(SP_ModelBuildStates);
  SetLength(SP_ModelBuildStates, i + 1);
  SP_ModelBuildStates[i].BankID := BankID;
  SP_ModelBuildStates[i].Active := True;
  SP_ModelBuildStates[i].NextPolyIdx := 0;
  SetLength(SP_ModelBuildStates[i].Verts, 0);
  SetLength(SP_ModelBuildStates[i].Faces, 0);
  Result := i;
End;

Procedure FreeBuildState(Idx: Integer);
Begin
  SP_ModelBuildStates[Idx].Active := False;
  SetLength(SP_ModelBuildStates[Idx].Verts, 0);
  SetLength(SP_ModelBuildStates[Idx].Faces, 0);
End;

// ===========================================================================
// Scene bank helpers
// ===========================================================================

Function GetSceneBank(SceneID: Integer; Var Error: TSP_ErrorCode): pSP_Bank;
Var Idx: Integer;
Begin
  Result := Nil;
  Idx := SP_FindBankID(SceneID);
  If Idx < 0 Then Begin
    Error.Code := SP_ERR_BANK_NOT_FOUND;
    Exit;
  End;
  If SP_BankList[Idx]^.DataType <> SP_SCENE_BANK Then Begin
    Error.Code := SP_ERR_BANK_NOT_FOUND;
    Exit;
  End;
  Result := SP_BankList[Idx];
End;

Function SceneSlotCount(Bank: pSP_Bank): LongWord;
Begin
  If Length(Bank^.Info) >= SizeOf(TSP_SceneHeader) Then
    Result := pSP_SceneHeader(@Bank^.Info[0])^.SlotCount
  Else
    Result := 0;
End;

Function FindInstInScene(Bank: pSP_Bank; InstID: Integer): pSP_ModelInstance;
Var
  i    : Integer;
  n    : LongWord;
  Slot : pSP_ModelInstance;
Begin
  Result := Nil;
  n := SceneSlotCount(Bank);
  For i := 0 To Integer(n) - 1 Do Begin
    Slot := pSP_ModelInstance(@Bank^.Memory[i * SizeOf(TSP_ModelInstance)]);
    If Slot^.Active And (Slot^.ID = InstID) Then Begin
      Result := Slot; Exit;
    End;
  End;
End;

Function AllocInstSlot(Bank: pSP_Bank): pSP_ModelInstance;
Var
  i      : Integer;
  n      : LongWord;
  Slot   : pSP_ModelInstance;
  OldLen : Integer;
  Hdr    : pSP_SceneHeader;
Begin
  n := SceneSlotCount(Bank);
  For i := 0 To Integer(n) - 1 Do Begin
    Slot := pSP_ModelInstance(@Bank^.Memory[i * SizeOf(TSP_ModelInstance)]);
    If Not Slot^.Active Then Begin
      FillChar(Slot^, SizeOf(TSP_ModelInstance), 0);
      Slot^.AnimFrameA := -1;
      Slot^.AnimFrameB := -1;
      Slot^.ID          := (SP3D_NextInstID And $7FFFFFFF) Or SP3D_INSTANCE_MASK;
      Slot^.MatrixDirty := True;
      Slot^.ParentID := -1;
      Inc(SP3D_NextInstID);
      If SP3D_NextInstID < 0 Then
        SP3D_NextInstID := 0;
      Result := Slot;  Exit;
    End;
  End;
  OldLen := Length(Bank^.Memory);
  SetLength(Bank^.Memory, OldLen + SizeOf(TSP_ModelInstance));
  FillChar(Bank^.Memory[OldLen], SizeOf(TSP_ModelInstance), 0);
  Result := pSP_ModelInstance(@Bank^.Memory[OldLen]);
  Hdr := pSP_SceneHeader(@Bank^.Info[0]);
  Result^.ID          := (SP3D_NextInstID And $7FFFFFFF) Or SP3D_INSTANCE_MASK;
  Result^.MatrixDirty := True;
  Result^.AnimFrameA  := -1;
  Result^.AnimFrameB  := -1;
  Result^.ParentID := -1;
  Inc(SP3D_NextInstID);
  If SP3D_NextInstID < 0 Then
    SP3D_NextInstID := 0;
  Inc(Hdr^.SlotCount);
End;

Function GetActiveSceneBank(Var Error: TSP_ErrorCode): pSP_Bank;
Begin
  Result := Nil;
  If SP3D_ActiveScene < 0 Then Begin
    Error.Code := SP_ERR_INVALID_OBJECT;
    Exit;
  End;
  Result := GetSceneBank(SP3D_ActiveScene, Error);
End;

// Mark all instance matrices dirty in one scene bank.
Procedure InvalidateSceneMatrices(Bank: pSP_Bank);
Var
  i    : Integer;
  n    : LongWord;
  Slot : pSP_ModelInstance;
Begin
  n := SceneSlotCount(Bank);
  For i := 0 To Integer(n) - 1 Do Begin
    Slot := pSP_ModelInstance(@Bank^.Memory[i * SizeOf(TSP_ModelInstance)]);
    If Slot^.Active Then
      Slot^.MatrixDirty := True;
  End;
End;

// Camera changed — walk every scene bank and invalidate all instance matrices.
Procedure InvalidateAllSceneMatrices;
Var i: Integer;
Begin
  SP3D_ViewMatrixOK := False;
  For i := 0 To High(SP_BankList) Do
    If SP_BankList[i]^.DataType = SP_SCENE_BANK Then
      InvalidateSceneMatrices(SP_BankList[i]);
  SP3D_CamDirty := False;
End;

// ===========================================================================
// Public: scene management
// ===========================================================================

Function SP_Scene_New(Var Error: TSP_ErrorCode): Integer;
Var
  BankID  : Integer;
  ListIdx : Integer;
  Hdr     : TSP_SceneHeader;
  Bank    : pSP_Bank;
Begin
  Result := -1;
  DisplaySection.Enter;

  BankID  := SP_NewBank(0);
  ListIdx := SP_FindBankID(BankID);
  If ListIdx < 0 Then Begin
    Error.Code := SP_ERR_OUT_OF_MEMORY;
    DisplaySection.Leave;  Exit;
  End;

  Bank           := SP_BankList[ListIdx];
  Bank^.DataType := SP_SCENE_BANK;
  Hdr.SlotCount := 0;
  Hdr.Cam_X     := SP3D_Cam_X;    Hdr.Cam_Y   := SP3D_Cam_Y;
  Hdr.Cam_Z     := SP3D_Cam_Z;    Hdr.Cam_RX  := SP3D_Cam_RX;
  Hdr.Cam_RY    := SP3D_Cam_RY;   Hdr.Cam_RZ  := SP3D_Cam_RZ;
  Hdr.Cam_FOV   := SP3D_Cam_FOV;  Hdr.Cam_Near:= SP3D_NEAR_PLANE;
  SetLength(Bank^.Info, SizeOf(TSP_SceneHeader));
  Move(Hdr, Bank^.Info[0], SizeOf(Hdr));

  If SP3D_ActiveScene < 0 Then
    SP3D_ActiveScene := BankID;

  Result := BankID;
  DisplaySection.Leave;
End;

// Writes the live camera globals into the header of scene bank SceneID.
Procedure FlushCameraToScene(SceneID: Integer);
Var Idx: Integer; Hdr: pSP_SceneHeader;
Begin
  If SceneID < 0 Then Exit;
  Idx := SP_FindBankID(SceneID);
  If (Idx < 0) Or (SP_BankList[Idx]^.DataType <> SP_SCENE_BANK) Then Exit;
  If Length(SP_BankList[Idx]^.Info) < SizeOf(TSP_SceneHeader) Then Exit;
  Hdr := pSP_SceneHeader(@SP_BankList[Idx]^.Info[0]);
  Hdr^.Cam_X    := SP3D_Cam_X;    Hdr^.Cam_Y    := SP3D_Cam_Y;
  Hdr^.Cam_Z    := SP3D_Cam_Z;    Hdr^.Cam_RX   := SP3D_Cam_RX;
  Hdr^.Cam_RY   := SP3D_Cam_RY;   Hdr^.Cam_RZ   := SP3D_Cam_RZ;
  Hdr^.Cam_FOV  := SP3D_Cam_FOV;  Hdr^.Cam_Near := SP3D_NEAR_PLANE;
End;

// Loads the camera globals from the header of scene bank SceneID.
Procedure RestoreCameraFromScene(SceneID: Integer);
Var Idx: Integer; Hdr: pSP_SceneHeader;
Begin
  If SceneID < 0 Then Exit;
  Idx := SP_FindBankID(SceneID);
  If (Idx < 0) Or (SP_BankList[Idx]^.DataType <> SP_SCENE_BANK) Then Exit;
  If Length(SP_BankList[Idx]^.Info) < SizeOf(TSP_SceneHeader) Then Exit;
  Hdr := pSP_SceneHeader(@SP_BankList[Idx]^.Info[0]);
  SP3D_Cam_X      := Hdr^.Cam_X;    SP3D_Cam_Y   := Hdr^.Cam_Y;
  SP3D_Cam_Z      := Hdr^.Cam_Z;    SP3D_Cam_RX  := Hdr^.Cam_RX;
  SP3D_Cam_RY     := Hdr^.Cam_RY;   SP3D_Cam_RZ  := Hdr^.Cam_RZ;
  SP3D_Cam_FOV    := Hdr^.Cam_FOV;
  SP3D_NEAR_PLANE := Hdr^.Cam_Near;
  SP3D_CamDirty   := True;
End;

Procedure SP_Scene_Use(SceneID: Integer; Var Error: TSP_ErrorCode);
Var Idx: Integer;
Begin
  Idx := SP_FindBankID(SceneID);
  If (Idx < 0) Or (SP_BankList[Idx]^.DataType <> SP_SCENE_BANK) Then Begin
    Error.Code := SP_ERR_BANK_NOT_FOUND;
    Exit;
  End;
  FlushCameraToScene(SP3D_ActiveScene);   // save current camera into old scene
  SP3D_ActiveScene := SceneID;
  RestoreCameraFromScene(SceneID);         // load new scene's camera into globals
End;

Procedure SP_Scene_Clear(SceneID: Integer; Var Error: TSP_ErrorCode);
Var
  Bank : pSP_Bank;
  Hdr  : pSP_SceneHeader;
Begin
  Bank := GetSceneBank(SceneID, Error);
  If Not Assigned(Bank) Then Exit;
  SetLength(Bank^.Memory, 0);
  Hdr := pSP_SceneHeader(@Bank^.Info[0]);
  Hdr^.SlotCount := 0;   // leave camera fields untouched
End;

Procedure SP_Scene_Erase(SceneID: Integer; Var Error: TSP_ErrorCode);
Var Idx: Integer;
Begin
  Idx := SP_FindBankID(SceneID);
  If (Idx < 0) Or (SP_BankList[Idx]^.DataType <> SP_SCENE_BANK) Then Begin
    Error.Code := SP_ERR_BANK_NOT_FOUND;  Exit;
  End;
  SP_DeleteBank(Idx, Error);
  If SP3D_ActiveScene = SceneID Then SP3D_ActiveScene := -1;
End;

// ===========================================================================
// Public: model bank management
// ===========================================================================

Function SP_Model_New(Var Error: TSP_ErrorCode): Integer;
Var
  BankID  : Integer;
  ListIdx : Integer;
  BSIdx   : Integer;
  Hdr     : TSP_ModelHeader;
  Bank    : pSP_Bank;
Begin
  Result := -1;
  DisplaySection.Enter;

  BankID  := SP_NewBank(0);
  ListIdx := SP_FindBankID(BankID);
  If ListIdx < 0 Then Begin
    Error.Code := SP_ERR_OUT_OF_MEMORY;
    DisplaySection.Leave;  Exit;
  End;

  Bank           := SP_BankList[ListIdx];
  Bank^.DataType := SP_MODEL_BANK;

  BSIdx := FindBuildState(BankID);
  If BSIdx >= 0 Then FreeBuildState(BSIdx);

  SetLength(Bank^.Memory, 0);
  FillChar(Hdr, SizeOf(Hdr), 0);
  SetLength(Bank^.Info, SizeOf(TSP_ModelHeader));
  Move(Hdr, Bank^.Info[0], SizeOf(Hdr));

  AllocBuildState(BankID);

  Result := BankID;
  DisplaySection.Leave;
End;

Function SP_Model_Vertex(BankID: Integer; X, Y, Z: aFloat; Colour: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  BSIdx : Integer;
  n     : Integer;
  V     : TSP_3DVertex;
  Idx   : Integer;
  Hdr   : pSP_ModelHeader;
Begin
  Result := -1;
  BSIdx  := FindBuildState(BankID);
  If BSIdx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
  FillChar(V, SizeOf(V), 0);
  V.X := X;  V.Y := Y;  V.Z := Z;
  If Colour < 0 Then Begin
    V.Colour  := CINK;
    V.Flags   := SP3D_VERTEX_DEFAULTCOLOUR;
  End Else Begin
    V.Colour  := Colour;
    V.FLags   := 0;
  End;
  n := Length(SP_ModelBuildStates[BSIdx].Verts);
  SetLength(SP_ModelBuildStates[BSIdx].Verts, n + 1);
  SP_ModelBuildStates[BSIdx].Verts[n] := V;
  Result := n;
  Idx := SP_FindBankID(BankID);
  If Idx >= 0 Then Begin
    Hdr := pSP_ModelHeader(@SP_BankList[Idx]^.Info[0]);
    Hdr^.Flags := (Hdr^.Flags Or SP3D_FLAG_DIRTY) And Not SP3D_FLAG_BUILT;
  End;
End;

Procedure SP_Model_VertexArray(BankID, ArrIdx: Integer; Var Error: TSP_ErrorCode);
Var
  BSIdx   : Integer;
  pIdx, vIdx, n, iSize, numPts : Integer;
  V       : TSP_3DVertex;
  Idx     : Integer;
  Hdr     : pSP_ModelHeader;
Begin
  BSIdx := FindBuildState(BankID);
  If BSIdx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
  If (ArrIdx < 0) Or (ArrIdx >= Length(NumArrays)) Then Begin
    Error.Code := SP_ERR_ARRAY_NOT_FOUND; Exit;
  End;
  If NumArrays[ArrIdx].NumIndices <> 2 Then Begin
    Error.Code := SP_ERR_UNSUITABLE_ARRAY; Exit;
  End;
  iSize  := NumArrays[ArrIdx].Indices[1];
  If iSize < 3 Then Begin Error.Code := SP_ERR_UNSUITABLE_ARRAY; Exit; End;
  numPts := NumArrays[ArrIdx].Indices[0];

  vIdx := 0;
  For pIdx := 0 To numPts - 1 Do Begin
    FillChar(V, SizeOf(V), 0);
    V.X := NumArrays[ArrIdx].Values[vIdx]^.Value;
    V.Y := NumArrays[ArrIdx].Values[vIdx+1]^.Value;
    V.Z := NumArrays[ArrIdx].Values[vIdx+2]^.Value;
    If iSize >= 4 Then Begin
      V.Colour := LongWord(Round(NumArrays[ArrIdx].Values[vIdx+3]^.Value));
      V.Flags  := 0;
    End Else Begin
      V.Colour := CINK;
      V.Flags  := SP3D_VERTEX_DEFAULTCOLOUR;
    End;
    n := Length(SP_ModelBuildStates[BSIdx].Verts);
    SetLength(SP_ModelBuildStates[BSIdx].Verts, n + 1);
    SP_ModelBuildStates[BSIdx].Verts[n] := V;
    Inc(vIdx, iSize);
  End;

  Idx := SP_FindBankID(BankID);
  If Idx >= 0 Then Begin
    Hdr := pSP_ModelHeader(@SP_BankList[Idx]^.Info[0]);
    Hdr^.Flags := (Hdr^.Flags Or SP3D_FLAG_DIRTY) And Not SP3D_FLAG_BUILT;
  End;
End;

Procedure SP_Model_Face(BankID, V0, V1, V2, Colour, TexBank: Integer;
                        U0, Vt0, U1, Vt1, U2, Vt2: aFloat;
                        Var Error: TSP_ErrorCode);
Var
  BSIdx : Integer;
  n, vc : Integer;
  F     : TSP_3DFace;
  Idx   : Integer;
  Hdr   : pSP_ModelHeader;
Begin
  BSIdx := FindBuildState(BankID);
  If BSIdx < 0 Then Begin
    Error.Code := SP_ERR_BANK_NOT_FOUND;
    Exit;
  End;
  vc := Length(SP_ModelBuildStates[BSIdx].Verts);
  If (V0 < 0) Or (V0 >= vc) Or
     (V1 < 0) Or (V1 >= vc) Or
     (V2 < 0) Or (V2 >= vc) Then Begin
    Error.Code := SP_ERR_SUBSCRIPT_WRONG;
    Exit;
  End;
  FillChar(F, SizeOf(F), 0);
  F.V0      := Word(V0);
  F.V1      := Word(V1);
  F.V2      := Word(V2);
  If Colour < 0 Then Begin
    F.Colour := CINK;
    F.Flags  := F.Flags Or SP3D_FACE_DEFAULTCOLOUR;
  End Else Begin
    F.Colour := LongWord(Colour);
  End;
  F.TexBank := TexBank;
  If TexBank >= 0 Then Begin
    F.Flags := F.Flags Or SP3D_FACE_TEXTURED;
    F.U0  := U0;  F.Vt0 := Vt0;
    F.U1  := U1;  F.Vt1 := Vt1;
    F.U2  := U2;  F.Vt2 := Vt2;
  End;
  F.PolyIdx := LongWord(SP_ModelBuildStates[BSIdx].NextPolyIdx);
  Inc(SP_ModelBuildStates[BSIdx].NextPolyIdx);
  n := Length(SP_ModelBuildStates[BSIdx].Faces);
  SetLength(SP_ModelBuildStates[BSIdx].Faces, n + 1);
  SP_ModelBuildStates[BSIdx].Faces[n] := F;

  Idx := SP_FindBankID(BankID);
  If Idx >= 0 Then Begin
    Hdr := pSP_ModelHeader(@SP_BankList[Idx]^.Info[0]);
    Hdr^.Flags := (Hdr^.Flags Or SP3D_FLAG_DIRTY) And Not SP3D_FLAG_BUILT;
  End;
End;

Procedure SP_Model_FaceArray(BankID, ArrIdx: Integer; Var Error: TSP_ErrorCode);
Var
  BSIdx   : Integer;
  pIdx, vIdx, n, iSize, numFaces, vc : Integer;
  F       : TSP_3DFace;
  Idx     : Integer;
  Hdr     : pSP_ModelHeader;
  V0, V1, V2 : Integer;
Begin
  // Build a list of polys from coordinates in an array.
  // TRIANGLES ONLY!
  BSIdx := FindBuildState(BankID);
  If BSIdx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
  If (ArrIdx < 0) Or (ArrIdx >= Length(NumArrays)) Then Begin
    Error.Code := SP_ERR_ARRAY_NOT_FOUND; Exit;
  End;
  If NumArrays[ArrIdx].NumIndices <> 2 Then Begin
    Error.Code := SP_ERR_UNSUITABLE_ARRAY; Exit;
  End;
  iSize    := NumArrays[ArrIdx].Indices[1];
  If iSize < 4 Then Begin Error.Code := SP_ERR_UNSUITABLE_ARRAY; Exit; End;
  numFaces := NumArrays[ArrIdx].Indices[0];
  vc       := Length(SP_ModelBuildStates[BSIdx].Verts);

  vIdx := 0;
  For pIdx := 0 To numFaces - 1 Do Begin
    V0 := Round(NumArrays[ArrIdx].Values[vIdx]^.Value);
    V1 := Round(NumArrays[ArrIdx].Values[vIdx+1]^.Value);
    V2 := Round(NumArrays[ArrIdx].Values[vIdx+2]^.Value);
    If (V0 < 0) Or (V0 >= vc) Or (V1 < 0) Or (V1 >= vc) Or
       (V2 < 0) Or (V2 >= vc) Then Begin
      Error.Code := SP_ERR_SUBSCRIPT_WRONG; Exit;
    End;
    FillChar(F, SizeOf(F), 0);
    F.V0     := Word(V0);
    F.V1     := Word(V1);
    F.V2     := Word(V2);
    F.Colour := LongWord(Round(NumArrays[ArrIdx].Values[vIdx+3]^.Value));
    F.TexBank := -1;
    F.PolyIdx := LongWord(SP_ModelBuildStates[BSIdx].NextPolyIdx);
    Inc(SP_ModelBuildStates[BSIdx].NextPolyIdx);
    n := Length(SP_ModelBuildStates[BSIdx].Faces);
    SetLength(SP_ModelBuildStates[BSIdx].Faces, n + 1);
    SP_ModelBuildStates[BSIdx].Faces[n] := F;
    Inc(vIdx, iSize);
  End;

  Idx := SP_FindBankID(BankID);
  If Idx >= 0 Then Begin
    Hdr := pSP_ModelHeader(@SP_BankList[Idx]^.Info[0]);
    Hdr^.Flags := (Hdr^.Flags Or SP3D_FLAG_DIRTY) And Not SP3D_FLAG_BUILT;
  End;
End;

Procedure SP_Model_Poly(BankID: Integer; Const Verts: Array of Integer; Const UVs: Array of aFloat; Colour, TexBank: Integer; Var Error: TSP_ErrorCode);
Var
  BSIdx    : Integer;
  i, n     : Integer;
  vc       : Integer;
  F        : TSP_3DFace;
  Idx      : Integer;
  Hdr      : pSP_ModelHeader;
  HasTex   : Boolean;
Begin
  BSIdx := FindBuildState(BankID);
  If BSIdx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
  If Length(Verts) < 3 Then Begin Error.Code := SP_ERR_SUBSCRIPT_WRONG; Exit; End;

  vc := Length(SP_ModelBuildStates[BSIdx].Verts);
  For i := 0 To High(Verts) Do
    If (Verts[i] < 0) Or (Verts[i] >= vc) Then Begin
      Error.Code := SP_ERR_SUBSCRIPT_WRONG; Exit;
    End;

  // UVs array must be exactly Length(Verts)*2 entries if provided
  HasTex := (TexBank >= 0) And (Length(UVs) = Length(Verts) * 2);

  For i := 1 To Length(Verts) - 2 Do Begin
    FillChar(F, SizeOf(F), 0);
    F.V0      := Word(Verts[0]);
    F.V1      := Word(Verts[i + 1]);
    F.V2      := Word(Verts[i]);
    F.PolyIdx := LongWord(SP_ModelBuildStates[BSIdx].NextPolyIdx);
    If Colour < 0 Then Begin
      F.Colour := CINK;
      F.Flags  := F.Flags Or SP3D_FACE_DEFAULTCOLOUR;
    End Else Begin
      F.Colour := LongWord(Colour);
    End;
    F.TexBank := TexBank;
    F.Flags   := 0;

    // V0-V1 is diagonal on first triangle, V2-V0 is diagonal on last
    If i = 1 Then
      F.Flags := F.Flags Or SP3D_FACE_NOEDGE_01
    Else If i = Length(Verts) - 2 Then
      F.Flags := F.Flags Or SP3D_FACE_NOEDGE_20;
    // Middle triangles of larger polygons suppress both
    If (i > 1) And (i < Length(Verts) - 2) Then
      F.Flags := F.Flags Or SP3D_FACE_NOEDGE_01 Or SP3D_FACE_NOEDGE_20;

    If HasTex Then Begin
      F.Flags  := F.Flags Or SP3D_FACE_TEXTURED;
      F.U0  := UVs[0];          F.Vt0 := UVs[1];           // Verts[0] UVs always
      F.U2  := UVs[(i+1) * 2];  F.Vt1 := UVs[(i+1) * 2 + 1]; // Verts[i+1] UVs
      F.U1  := UVs[i * 2];      F.Vt2 := UVs[i * 2 + 1];  // Verts[i] UVs
    End;
    n := Length(SP_ModelBuildStates[BSIdx].Faces);
    SetLength(SP_ModelBuildStates[BSIdx].Faces, n + 1);
    SP_ModelBuildStates[BSIdx].Faces[n] := F;
  End;
  Inc(SP_ModelBuildStates[BSIdx].NextPolyIdx);

  Idx := SP_FindBankID(BankID);
  If Idx >= 0 Then Begin
    Hdr := pSP_ModelHeader(@SP_BankList[Idx]^.Info[0]);
    Hdr^.Flags := (Hdr^.Flags Or SP3D_FLAG_DIRTY) And Not SP3D_FLAG_BUILT;
  End;
End;

Procedure SP_Model_UpdateUV(BankID, PolyIdx: Integer; Const UVs: Array of aFloat; Var Error: TSP_ErrorCode);
Var
  BSIdx    : Integer;
  Idx      : Integer;
  Bank     : pSP_Bank;
  Hdr      : pSP_ModelHeader;
  FBase    : pSP_3DFace;
  Face     : pSP_3DFace;
  PDirBase : pSP3D_PolyDir;
  PDir     : pSP3D_PolyDir;
  i        : Integer;
  TriStart : Integer;
  TriCount : Integer;
  VertCount: Integer;
Begin
  // Validate UV count against poly directory in packed memory
  Idx := SP_FindBankID(BankID);
  If Idx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
  Bank := SP_BankList[Idx];
  Hdr  := pSP_ModelHeader(@Bank^.Info[0]);

  If (Hdr^.Flags And SP3D_FLAG_BUILT) = 0 Then Begin
    // Not yet built — update build state only, UV count validated against VertCount
    BSIdx := FindBuildState(BankID);
    If BSIdx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
    // Find first face with matching PolyIdx to get VertCount
    TriStart := -1;  TriCount := 0;
    For i := 0 To High(SP_ModelBuildStates[BSIdx].Faces) Do
      If Integer(SP_ModelBuildStates[BSIdx].Faces[i].PolyIdx) = PolyIdx Then Begin
        If TriStart < 0 Then TriStart := i;
        Inc(TriCount);
      End;
    If TriStart < 0 Then Begin Error.Code := SP_ERR_SUBSCRIPT_WRONG; Exit; End;
    VertCount := TriCount + 2;
    If Length(UVs) <> VertCount * 2 Then Begin
      Error.Code := SP_ERR_INTEGER_OUT_OF_RANGE; Exit;
    End;
    For i := 0 To TriCount - 1 Do Begin
      With SP_ModelBuildStates[BSIdx].Faces[TriStart + i] Do Begin
        U0  := UVs[0];                Vt0 := UVs[1];
        U1  := UVs[(i+2) * 2];       Vt1 := UVs[(i+2) * 2 + 1];
        U2  := UVs[(i+1) * 2];       Vt2 := UVs[(i+1) * 2 + 1];
      End;
    End;
    Exit;
  End;

  // Built — use poly directory for O(1) lookup
  If (PolyIdx < 0) Or (LongWord(PolyIdx) >= Hdr^.PolyCount) Then Begin
    Error.Code := SP_ERR_SUBSCRIPT_WRONG; Exit;
  End;
  PDirBase := pSP3D_PolyDir(
                NativeUInt(@Bank^.Memory[0]) +
                LongWord(Hdr^.VertexCount) * SizeOf(TSP_3DVertex) +
                LongWord(Hdr^.FaceCount)   * SizeOf(TSP_3DFace) +
                LongWord(Hdr^.EdgeCount)   * SizeOf(TSP_3DEdge));
  PDir      := pSP3D_PolyDir(NativeUInt(PDirBase) + LongWord(PolyIdx) * SizeOf(TSP3D_PolyDir));
  TriStart  := Integer(PDir^.TriStart);
  TriCount  := Integer(PDir^.TriCount);
  VertCount := Integer(PDir^.VertCount);

  If Length(UVs) <> VertCount * 2 Then Begin
    Error.Code := SP_ERR_INTEGER_OUT_OF_RANGE; Exit;
  End;

  FBase := pSP_3DFace(
             NativeUInt(@Bank^.Memory[0]) +
             LongWord(Hdr^.VertexCount) * SizeOf(TSP_3DVertex));

  // Fan UV distribution matching SP_Model_Poly's winding:
  // V0=Verts[0], V1=Verts[i+1], V2=Verts[i] for triangle i (1-based -> 0-based here)
  For i := 0 To TriCount - 1 Do Begin
    Face := pSP_3DFace(NativeUInt(FBase) + LongWord(TriStart + i) * SizeOf(TSP_3DFace));
    Face^.U0  := UVs[0];                Face^.Vt0 := UVs[1];              // Verts[0]
    Face^.U1  := UVs[(i + 2) * 2];     Face^.Vt1 := UVs[(i + 2) * 2 + 1]; // Verts[i+1] -> V1
    Face^.U2  := UVs[(i + 1) * 2];     Face^.Vt2 := UVs[(i + 1) * 2 + 1]; // Verts[i]   -> V2
  End;

  // Update build state too for consistency on next rebuild
  BSIdx := FindBuildState(BankID);
  If BSIdx >= 0 Then Begin
    For i := 0 To TriCount - 1 Do Begin
      With SP_ModelBuildStates[BSIdx].Faces[TriStart + i] Do Begin
        U0  := UVs[0];                Vt0 := UVs[1];
        U1  := UVs[(i + 2) * 2];     Vt1 := UVs[(i + 2) * 2 + 1];
        U2  := UVs[(i + 1) * 2];     Vt2 := UVs[(i + 1) * 2 + 1];
      End;
    End;
  End;
End;

Procedure SP_Model_SetVert(BankID, Idx: Integer; X, Y, Z: aFloat; Var Error: TSP_ErrorCode);
Var BSIdx: Integer;
Begin
  BSIdx := FindBuildState(BankID);
  If BSIdx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
  If (Idx < 0) Or (Idx >= Length(SP_ModelBuildStates[BSIdx].Verts)) Then Begin
    Error.Code := SP_ERR_SUBSCRIPT_WRONG; Exit;
  End;
  SP_ModelBuildStates[BSIdx].Verts[Idx].X := X;
  SP_ModelBuildStates[BSIdx].Verts[Idx].Y := Y;
  SP_ModelBuildStates[BSIdx].Verts[Idx].Z := Z;
End;

Function SP_Model_IsPlaying(InstID: Integer; Var Error: TSP_ErrorCode): Boolean;
Var
  SB   : pSP_Bank;
  Inst : pSP_ModelInstance;
Begin
  Result := False;
  SB := GetActiveSceneBank(Error);
  If Not Assigned(SB) Then Exit;
  Inst := FindInstInScene(SB, InstID);
  If Not Assigned(Inst) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  Result := Inst^.AnimPlaying;
End;

Procedure SP_Model_SetParent(InstID, ParentID: Integer; Var Error: TSP_ErrorCode);
Var
  SB   : pSP_Bank;
  Inst : pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);
  If Not Assigned(SB) Then Exit;
  Inst := FindInstInScene(SB, InstID);
  If Not Assigned(Inst) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  // Sanity: don't allow an instance to parent itself
  If ParentID = InstID Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  Inst^.ParentID    := ParentID;
  Inst^.MatrixDirty := True;
End;

Procedure SortTempEdges(Var Edges: TSP3D_TempEdgeArray; Lo, Hi: Integer);
Var
  I, J  : Integer;
  Pivot : Int64;
  Tmp   : TSP3D_TempEdge;
Begin
  If Lo >= Hi Then Exit;
  Pivot := Edges[(Lo + Hi) Div 2].SortKey;
  I := Lo; J := Hi;
  Repeat
    While Edges[I].SortKey < Pivot Do Inc(I);
    While Edges[J].SortKey > Pivot Do Dec(J);
    If I <= J Then Begin
      Tmp := Edges[I]; Edges[I] := Edges[J]; Edges[J] := Tmp;
      Inc(I); Dec(J);
    End;
  Until I > J;
  If Lo < J Then SortTempEdges(Edges, Lo, J);
  If I < Hi Then SortTempEdges(Edges, I, Hi);
End;

Procedure SP_Model_Build(BankID: Integer; Var Error: TSP_ErrorCode);
Var
  BSIdx              : Integer;
  Idx                : Integer;
  Bank               : pSP_Bank;
  Hdr                : TSP_ModelHeader;
  VC, FC             : Integer;
  VBytes, FBytes     : Integer;
  i                  : Integer;
  Vert0, Vert1, Vert2 : TSP_3DVertex;
  AX, AY, AZ         : aFloat;
  BX, BY, BZ         : aFloat;
  FNX, FNY, FNZ, L   : aFloat;
  BSX, BSY, BSZ : aFloat;
  BSR, Dx, Dy, Dz, Dist : aFloat;
  vi2 : Integer;
  VNX, VNY, VNZ : Array of aFloat;   // accumulated normals
  VNC           : Array of Integer;  // face count per vertex
  vni           : Integer;
  VnL           : aFloat;
  TempEdges   : TSP3D_TempEdgeArray;
  UniqueEdges : Array of TSP_3DEdge;
  EC, UEC, k  : Integer;
  EBytes      : Integer;
  CurKey      : Int64;
  Lo_v, Hi_v  : LongWord;
  FC2      : Integer;   // frame count (FC already used for face count above)
  FVBytes  : LongWord;  // bytes for one frame's vertex data
  DirBytes : LongWord;  // bytes for the frame directory
  OldMemLen: Integer;
  FrameBase: LongWord;  // byte offset in Memory where frame data starts
  fi2      : Integer;
  DirEntry : pSP3D_FrameDir;
  FVPtr    : pSP3D_FrameVert;
  NameLen  : Integer;
  PolyDirs  : Array of TSP3D_PolyDir;
  PC        : Integer;     // unique poly count
  PBytes    : Integer;
  CurPoly   : LongWord;
  TriStart  : Integer;
  V         : TSP_3DVertex;

Begin
  BSIdx := FindBuildState(BankID);
  If BSIdx < 0 Then Begin
    Error.Code := SP_ERR_BANK_NOT_FOUND;
    Exit;
  End;
  Idx := SP_FindBankID(BankID);
  If Idx < 0 Then Begin
    Error.Code := SP_ERR_BANK_NOT_FOUND;
    Exit;
  End;
  Bank := SP_BankList[Idx];

  VC := Length(SP_ModelBuildStates[BSIdx].Verts);
  FC := Length(SP_ModelBuildStates[BSIdx].Faces);

  // Compute face normals
  For i := 0 To FC - 1 Do Begin
    With SP_ModelBuildStates[BSIdx].Faces[i] Do Begin
      Vert0 := SP_ModelBuildStates[BSIdx].Verts[V0];
      Vert1 := SP_ModelBuildStates[BSIdx].Verts[V1];
      Vert2 := SP_ModelBuildStates[BSIdx].Verts[V2];
      AX := Vert1.X - Vert0.X;  AY := Vert1.Y - Vert0.Y;  AZ := Vert1.Z - Vert0.Z;
      BX := Vert2.X - Vert0.X;  BY := Vert2.Y - Vert0.Y;  BZ := Vert2.Z - Vert0.Z;
      FNX := AY*BZ - AZ*BY;
      FNY := AZ*BX - AX*BZ;
      FNZ := AX*BY - AY*BX;
      L   := Sqrt(FNX*FNX + FNY*FNY + FNZ*FNZ);
      If L > 1e-7 Then Begin
        NX := FNX/L;  NY := FNY/L;  NZ := FNZ/L;
      End Else Begin
        NX := 0;  NY := 1;  NZ := 0;
      End;
      // If face has no explicit colour, use the first vertex colour
      // This makes flat shading work naturally on vertex-coloured models.
      If (Flags And SP3D_FACE_DEFAULTCOLOUR) <> 0 Then Begin
        Colour := Vert0.Colour;
        Flags  := Flags And Not SP3D_FACE_DEFAULTCOLOUR;
      End;
    End;
  End;

  If (pSP_ModelHeader(@SP_BankList[Idx]^.Info[0])^.Flags And SP3D_FLAG_NEEDS_SMOOTH) <> 0 Then Begin
    SetLength(VNX, VC);  SetLength(VNY, VC);  SetLength(VNZ, VC);
    SetLength(VNC, VC);
    FillChar(VNX[0], VC * SizeOf(aFloat), 0);
    FillChar(VNY[0], VC * SizeOf(aFloat), 0);
    FillChar(VNZ[0], VC * SizeOf(aFloat), 0);
    FillChar(VNC[0], VC * SizeOf(Integer), 0);

    // Accumulate face normals into vertex normals
    For i := 0 To FC - 1 Do
      With SP_ModelBuildStates[BSIdx].Faces[i] Do Begin
        VNX[V0] := VNX[V0] + NX;  VNY[V0] := VNY[V0] + NY;  VNZ[V0] := VNZ[V0] + NZ;  Inc(VNC[V0]);
        VNX[V1] := VNX[V1] + NX;  VNY[V1] := VNY[V1] + NY;  VNZ[V1] := VNZ[V1] + NZ;  Inc(VNC[V1]);
        VNX[V2] := VNX[V2] + NX;  VNY[V2] := VNY[V2] + NY;  VNZ[V2] := VNZ[V2] + NZ;  Inc(VNC[V2]);
      End;

    // Normalise and store in vertex records
    For vni := 0 To VC - 1 Do Begin
      If VNC[vni] > 0 Then Begin
        VnL := Sqrt(VNX[vni]*VNX[vni] + VNY[vni]*VNY[vni] + VNZ[vni]*VNZ[vni]);
        If VnL > 1e-7 Then Begin
          SP_ModelBuildStates[BSIdx].Verts[vni].NX := VNX[vni] / VnL;
          SP_ModelBuildStates[BSIdx].Verts[vni].NY := VNY[vni] / VnL;
          SP_ModelBuildStates[BSIdx].Verts[vni].NZ := VNZ[vni] / VnL;
        End;
      End;
      // Mark faces as Gouraud
      For i := 0 To FC - 1 Do
        SP_ModelBuildStates[BSIdx].Faces[i].Flags :=
          SP_ModelBuildStates[BSIdx].Faces[i].Flags Or SP3D_FACE_GOURAUD;
    End;
    pSP_ModelHeader(@Bank^.Info[0])^.Flags := pSP_ModelHeader(@Bank^.Info[0])^.Flags And Not SP3D_FLAG_NEEDS_SMOOTH;
  End;

  // Pack into bank memory: vertex block then face block
  VBytes := VC * SizeOf(TSP_3DVertex);
  FBytes := FC * SizeOf(TSP_3DFace);

  // Build edge list if wireframe flag is set
  UEC := 0;
  EBytes := 0;
  Hdr.EdgeCount := 0;
  If (pSP_ModelHeader(@Bank^.Info[0])^.Flags And SP3D_FLAG_NEEDS_EDGES) <> 0 Then Begin
    // Collect one temp edge per face-edge (3 per face)
    SetLength(TempEdges, FC * 3);
    EC := 0;
    For i := 0 To FC - 1 Do
      With SP_ModelBuildStates[BSIdx].Faces[i] Do Begin
        // Edge V0-V1 — colour from winding V0
        If (Flags And SP3D_FACE_NOEDGE_01) = 0 Then Begin
          If V0 < V1 Then Begin Lo_v := V0; Hi_v := V1; End
          Else             Begin Lo_v := V1; Hi_v := V0; End;
          TempEdges[EC].SortKey := (Int64(Lo_v) Shl 32) Or Int64(Hi_v);
          TempEdges[EC].V0 := Lo_v;  TempEdges[EC].V1 := Hi_v;
          TempEdges[EC].FaceIdx := i;
          V := SP_ModelBuildStates[BSIdx].Verts[V0];
          TempEdges[EC].Colour := IfThen((V.Flags And SP3D_VERTEX_DEFAULTCOLOUR) <> 0, CINK, V.Colour);
          Inc(EC);
        End;        // Edge V1-V2 — colour from winding V1
        If V1 < V2 Then Begin Lo_v := V1; Hi_v := V2; End
        Else             Begin Lo_v := V2; Hi_v := V1; End;
        TempEdges[EC].SortKey := (Int64(Lo_v) Shl 32) Or Int64(Hi_v);
        TempEdges[EC].V0 := Lo_v;  TempEdges[EC].V1 := Hi_v;
        TempEdges[EC].FaceIdx := i;
        V := SP_ModelBuildStates[BSIdx].Verts[V1];
        TempEdges[EC].Colour := IfThen((V.Flags And SP3D_VERTEX_DEFAULTCOLOUR) <> 0, CINK, V.Colour);
        Inc(EC);
        // Edge V2-V0 — colour from winding V2
        If Flags And SP3D_FACE_NOEDGE_20 = 0 Then Begin
          If V2 < V0 Then Begin Lo_v := V2; Hi_v := V0; End
          Else             Begin Lo_v := V0; Hi_v := V2; End;
          TempEdges[EC].SortKey := (Int64(Lo_v) Shl 32) Or Int64(Hi_v);
          TempEdges[EC].V0 := Lo_v;  TempEdges[EC].V1 := Hi_v;
          TempEdges[EC].FaceIdx := i;
          V := SP_ModelBuildStates[BSIdx].Verts[V2];
          TempEdges[EC].Colour := IfThen((V.Flags And SP3D_VERTEX_DEFAULTCOLOUR) <> 0, CINK, V.Colour);
          Inc(EC);
        End;
      End;

    // Sort by vertex-pair key
    If EC > 1 Then SortTempEdges(TempEdges, 0, EC - 1);

    // Deduplicate: emit one TSP_3DEdge per unique (V0,V1) pair, filling F1 on shared edge
    SetLength(UniqueEdges, EC);
    UEC := 0;
    k   := 0;
    While k < EC Do Begin
      CurKey := TempEdges[k].SortKey;
      FillChar(UniqueEdges[UEC], SizeOf(TSP_3DEdge), 0);
      UniqueEdges[UEC].V0     := TempEdges[k].V0;
      UniqueEdges[UEC].V1     := TempEdges[k].V1;
      UniqueEdges[UEC].F0     := TempEdges[k].FaceIdx;
      UniqueEdges[UEC].F1     := -1;
      UniqueEdges[UEC].Colour := TempEdges[k].Colour;
      Inc(k);
      While (k < EC) And (TempEdges[k].SortKey = CurKey) Do Begin
        If UniqueEdges[UEC].F1 = -1 Then
          UniqueEdges[UEC].F1 := TempEdges[k].FaceIdx;
        Inc(k);
      End;
      Inc(UEC);
    End;

    pSP_ModelHeader(@Bank^.Info[0])^.Flags := pSP_ModelHeader(@Bank^.Info[0])^.Flags And Not SP3D_FLAG_NEEDS_EDGES;
    EBytes        := UEC * SizeOf(TSP_3DEdge);
    Hdr.EdgeCount := LongWord(UEC);
    SetLength(TempEdges,   0);
  End;

  // Build poly directory — group consecutive faces by PolyIdx
  PC := 0;
  PBytes := 0;
  If FC > 0 Then Begin
    SetLength(PolyDirs, FC);   // upper bound
    k := 0;
    While k < FC Do Begin
      CurPoly  := SP_ModelBuildStates[BSIdx].Faces[k].PolyIdx;
      TriStart := k;
      While (k < FC) And
            (SP_ModelBuildStates[BSIdx].Faces[k].PolyIdx = CurPoly) Do
        Inc(k);
      PolyDirs[PC].TriStart  := LongWord(TriStart);
      PolyDirs[PC].TriCount  := Word(k - TriStart);
      // VertCount = TriCount + 2 for a fan
      PolyDirs[PC].VertCount := Word(k - TriStart + 2);
      Inc(PC);
    End;
    PBytes := PC * SizeOf(TSP3D_PolyDir);
  End;
  Hdr.PolyCount := LongWord(PC);

  // Pack: [Vertices][Faces][Edges]
  SetLength(Bank^.Memory, VBytes + FBytes + EBytes + PBytes);
  If VC > 0 Then Move(SP_ModelBuildStates[BSIdx].Verts[0],  Bank^.Memory[0],               VBytes);
  If FC > 0 Then Move(SP_ModelBuildStates[BSIdx].Faces[0],  Bank^.Memory[VBytes],           FBytes);
  If (EBytes > 0) And (UEC > 0) Then
    Move(UniqueEdges[0],  Bank^.Memory[VBytes + FBytes],          EBytes);
  If (PBytes > 0) Then
    Move(PolyDirs[0],     Bank^.Memory[VBytes + FBytes + EBytes], PBytes);
  SetLength(PolyDirs, 0);
  SetLength(UniqueEdges, 0);

  Hdr.VertexCount := LongWord(VC);
  Hdr.FaceCount   := LongWord(FC);
  Hdr.EdgeCount   := LongWord(UEC);
  Hdr.PolyCount   := LongWord(PC);

  // Preserve all user-settable model flags across rebuilds; add new flags here
  Hdr.Flags := (pSP_ModelHeader(@Bank^.Info[0])^.Flags And
               (SP3D_FLAG_SMOOTH Or SP3D_FLAG_WIREFRAME Or
                SP3D_FLAG_WIRE_NOCULL Or SP3D_FLAG_WIRE_SOLID))
               Or SP3D_FLAG_BUILT;
  SetLength(Bank^.Info, SizeOf(TSP_ModelHeader));
  Move(Hdr, Bank^.Info[0], SizeOf(Hdr));

  If VC > 0 Then Begin
    // Start with centroid as initial centre
    BSX := 0;  BSY := 0;  BSZ := 0;
    For vi2 := 0 To VC - 1 Do Begin
      BSX := BSX + SP_ModelBuildStates[BSIdx].Verts[vi2].X;
      BSY := BSY + SP_ModelBuildStates[BSIdx].Verts[vi2].Y;
      BSZ := BSZ + SP_ModelBuildStates[BSIdx].Verts[vi2].Z;
    End;
    BSX := BSX / VC;  BSY := BSY / VC;  BSZ := BSZ / VC;

    // Radius = max distance from centroid to any vertex
    BSR := 0;
    For vi2 := 0 To VC - 1 Do Begin
      Dx := SP_ModelBuildStates[BSIdx].Verts[vi2].X - BSX;
      Dy := SP_ModelBuildStates[BSIdx].Verts[vi2].Y - BSY;
      Dz := SP_ModelBuildStates[BSIdx].Verts[vi2].Z - BSZ;
      Dist := Sqrt(Dx*Dx + Dy*Dy + Dz*Dz);
      If Dist > BSR Then BSR := Dist;
    End;

    // Store in header (re-read after bank resize)
    pSP_ModelHeader(@Bank^.Info[0])^.BSX    := BSX;
    pSP_ModelHeader(@Bank^.Info[0])^.BSY    := BSY;
    pSP_ModelHeader(@Bank^.Info[0])^.BSZ    := BSZ;
    pSP_ModelHeader(@Bank^.Info[0])^.BSRadius := BSR;
  End Else Begin
    pSP_ModelHeader(@Bank^.Info[0])^.BSX    := 0;
    pSP_ModelHeader(@Bank^.Info[0])^.BSY    := 0;
    pSP_ModelHeader(@Bank^.Info[0])^.BSZ    := 0;
    pSP_ModelHeader(@Bank^.Info[0])^.BSRadius := 0;
  End;

  FC2 := Length(SP_ModelBuildStates[BSIdx].Frames);

  // Update header FrameCount (BSIdx already freed above — re-find is needed
  // but BSIdx was just freed so use Idx which is still valid)
  pSP_ModelHeader(@Bank^.Info[0])^.FrameCount := LongWord(FC2);

  If FC2 > 0 Then Begin
    pSP_ModelHeader(@Bank^.Info[0])^.Flags :=
      pSP_ModelHeader(@Bank^.Info[0])^.Flags Or SP3D_FLAG_HASFRAMES;

    // Extend Info to hold the frame directory
    DirBytes := LongWord(FC2) * SizeOf(TSP3D_FrameDir);
    SetLength(Bank^.Info, SizeOf(TSP_ModelHeader) + DirBytes);

    // Extend Memory to hold frame vertex data
    FVBytes   := LongWord(VC) * SizeOf(TSP3D_FrameVert);
    OldMemLen := Length(Bank^.Memory);
    FrameBase := LongWord(OldMemLen);
    SetLength(Bank^.Memory, OldMemLen + Integer(FVBytes) * FC2);

    // Write directory and frame data
    For fi2 := 0 To FC2 - 1 Do Begin
      // Directory entry
      DirEntry := pSP3D_FrameDir(
        NativeUInt(@Bank^.Info[0]) + SizeOf(TSP_ModelHeader) +
        LongWord(fi2) * SizeOf(TSP3D_FrameDir));
      FillChar(DirEntry^, SizeOf(TSP3D_FrameDir), 0);
      DirEntry^.Offset := FrameBase + LongWord(fi2) * FVBytes;
      NameLen := Length(SP_ModelBuildStates[BSIdx].Frames[fi2].Name);
      If NameLen >= SP3D_FRAME_NAME_LEN Then NameLen := SP3D_FRAME_NAME_LEN - 1;
      For vi2 := 0 To NameLen - 1 Do
        DirEntry^.Name[vi2] := AnsiChar(SP_ModelBuildStates[BSIdx].Frames[fi2].Name[vi2+1]);

      // Frame vertex data
      FVPtr := pSP3D_FrameVert(@Bank^.Memory[DirEntry^.Offset]);
      For vi2 := 0 To VC - 1 Do Begin
        pSP3D_FrameVert(NativeUInt(FVPtr) + LongWord(vi2)*SizeOf(TSP3D_FrameVert))^.X :=
          SP_ModelBuildStates[BSIdx].Frames[fi2].Verts[vi2].X;
        pSP3D_FrameVert(NativeUInt(FVPtr) + LongWord(vi2)*SizeOf(TSP3D_FrameVert))^.Y :=
          SP_ModelBuildStates[BSIdx].Frames[fi2].Verts[vi2].Y;
        pSP3D_FrameVert(NativeUInt(FVPtr) + LongWord(vi2)*SizeOf(TSP3D_FrameVert))^.Z :=
          SP_ModelBuildStates[BSIdx].Frames[fi2].Verts[vi2].Z;
      End;
    End;
  End;

  // Clean up frame scratch data
  For fi2 := 0 To FC2 - 1 Do
    SetLength(SP_ModelBuildStates[BSIdx].Frames[fi2].Verts, 0);
  SetLength(SP_ModelBuildStates[BSIdx].Frames, 0);

End;

Procedure SP_Model_Erase(BankID: Integer; Var Error: TSP_ErrorCode);
Var Idx: Integer;
Begin
  SP_3D_OnDeleteBank(BankID, SP_MODEL_BANK);
  Idx := SP_FindBankID(BankID);
  If Idx >= 0 Then SP_DeleteBank(Idx, Error);
End;

// Animation

Function FindFrameByName(Bank: pSP_Bank; Const Name: aString): Integer;
Var
  Hdr  : pSP_ModelHeader;
  Entry: pSP3D_FrameDir;
  Dir  : pSP3D_FrameDir;
  i, j : Integer;
  EntryName: aString;
Begin
  Result := -1;
  Hdr    := pSP_ModelHeader(@Bank^.Info[0]);
  If Hdr^.FrameCount = 0 Then Exit;

  // Frame directory lives in Info immediately after TSP_ModelHeader
  Dir  := pSP3D_FrameDir(NativeUInt(@Bank^.Info[0]) + SizeOf(TSP_ModelHeader));

  For i := 0 To Integer(Hdr^.FrameCount) - 1 Do Begin
    Entry := pSP3D_FrameDir(NativeUInt(Dir) + LongWord(i) * SizeOf(TSP3D_FrameDir));
    EntryName := '';
    For j := 0 To SP3D_FRAME_NAME_LEN - 1 Do Begin
      If Entry^.Name[j] = #0 Then Break;
      EntryName := EntryName + aChar(Entry^.Name[j]);
    End;
    If EntryName = Name Then Begin
      Result := i;  Exit;
    End;
  End;
End;

Procedure SP_Model_AddFrame(BankID: Integer; Const FrameName: aString; Var Error: TSP_ErrorCode);
Var
  BSIdx  : Integer;
  VC, fi : Integer;
  n      : Integer;
Begin
  BSIdx := FindBuildState(BankID);
  If BSIdx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;

  VC := Length(SP_ModelBuildStates[BSIdx].Verts);
  If VC = 0 Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;

  n := Length(SP_ModelBuildStates[BSIdx].Frames);
  SetLength(SP_ModelBuildStates[BSIdx].Frames, n + 1);
  SP_ModelBuildStates[BSIdx].Frames[n].Name := FrameName;
  SetLength(SP_ModelBuildStates[BSIdx].Frames[n].Verts, VC);

  For fi := 0 To VC - 1 Do Begin
    SP_ModelBuildStates[BSIdx].Frames[n].Verts[fi].X := SP_ModelBuildStates[BSIdx].Verts[fi].X;
    SP_ModelBuildStates[BSIdx].Frames[n].Verts[fi].Y := SP_ModelBuildStates[BSIdx].Verts[fi].Y;
    SP_ModelBuildStates[BSIdx].Frames[n].Verts[fi].Z := SP_ModelBuildStates[BSIdx].Verts[fi].Z;
  End;
End;

Procedure SP_Model_AnimPlay(InstID: Integer; Const FrameA, FrameB: aString;
                             Speed: aFloat; Var Error: TSP_ErrorCode);
Var
  SB      : pSP_Bank;
  Inst    : pSP_ModelInstance;
  MIdx    : Integer;
  MBank   : pSP_Bank;
  FA, FB  : Integer;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  Inst := FindInstInScene(SB, InstID);
  If Not Assigned(Inst) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;

  MIdx := SP_FindBankID(Inst^.BankID);
  If MIdx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
  MBank := SP_BankList[MIdx];

  FA := FindFrameByName(MBank, FrameA);
  FB := FindFrameByName(MBank, FrameB);
  If (FA < 0) Or (FB < 0) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;

  Inst^.AnimFrameA  := FA;
  Inst^.AnimFrameB  := FB;
  Inst^.AnimT       := 0.0;
  Inst^.AnimSpeed   := Speed;
  Inst^.AnimPlaying := True;
End;

Procedure SP_Model_AnimStop(InstID: Integer; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; Inst: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  Inst := FindInstInScene(SB, InstID);
  If Not Assigned(Inst) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  Inst^.AnimPlaying := False;
End;

Procedure SP_Model_AnimFrame(InstID: Integer; Const FrameName: aString; Var Error: TSP_ErrorCode);
Var
  SB    : pSP_Bank;
  Inst  : pSP_ModelInstance;
  MIdx  : Integer;
  MBank : pSP_Bank;
  FIdx  : Integer;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  Inst := FindInstInScene(SB, InstID);
  If Not Assigned(Inst) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  MIdx := SP_FindBankID(Inst^.BankID);
  If MIdx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
  MBank := SP_BankList[MIdx];
  FIdx := FindFrameByName(MBank, FrameName);
  If FIdx < 0 Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  Inst^.AnimFrameA  := FIdx;
  Inst^.AnimFrameB  := FIdx;
  Inst^.AnimT       := 0.0;
  Inst^.AnimPlaying := False;
End;

Function SP_Model_AnimGetFrame(InstID: Integer; Var Error: TSP_ErrorCode): aString;
Var
  SB    : pSP_Bank;
  Inst  : pSP_ModelInstance;
  MIdx  : Integer;
  MBank : pSP_Bank;
  Hdr   : pSP_ModelHeader;
  Dir   : pSP3D_FrameDir;
  Entry : pSP3D_FrameDir;
  j     : Integer;
Begin
  Result := '';
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  Inst := FindInstInScene(SB, InstID);
  If Not Assigned(Inst) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  If Inst^.AnimFrameA < 0 Then Exit;
  MIdx := SP_FindBankID(Inst^.BankID);
  If MIdx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
  MBank := SP_BankList[MIdx];
  Hdr   := pSP_ModelHeader(@MBank^.Info[0]);
  If Inst^.AnimFrameA >= Integer(Hdr^.FrameCount) Then Exit;
  Dir   := pSP3D_FrameDir(NativeUInt(@MBank^.Info[0]) + SizeOf(TSP_ModelHeader));
  Entry := pSP3D_FrameDir(NativeUInt(Dir) + LongWord(Inst^.AnimFrameA) * SizeOf(TSP3D_FrameDir));
  For j := 0 To SP3D_FRAME_NAME_LEN - 1 Do Begin
    If Entry^.Name[j] = #0 Then Break;
    Result := Result + aChar(Entry^.Name[j]);
  End;
End;

// ===========================================================================
// Public: instance management (all target active scene)
// ===========================================================================

Function ResolveModelBankID(BankID: Integer): Integer; // Helper to find models
Var
  SB   : pSP_Bank;
  Inst : pSP_ModelInstance;
  Err  : TSP_ErrorCode;
Begin
  Result   := BankID;
  Err.Code := SP_ERR_OK;
  SB       := GetActiveSceneBank(Err);
  If Assigned(SB) Then Begin
    Inst := FindInstInScene(SB, BankID);
    If Assigned(Inst) Then
      Result := Inst^.BankID;
  End;
End;

Procedure MarkChildrenDirty(SceneBank: pSP_Bank; ParentInstID: Integer);
Var
  n    : LongWord;
  i    : Integer;
  Slot : pSP_ModelInstance;
Begin
  n := SceneSlotCount(SceneBank);
  For i := 0 To Integer(n) - 1 Do Begin
    Slot := pSP_ModelInstance(@SceneBank^.Memory[i * SizeOf(TSP_ModelInstance)]);
    If Slot^.Active And (Slot^.ParentID = ParentInstID) Then Begin
      Slot^.MatrixDirty := True;
      // Recurse for grandchildren
      MarkChildrenDirty(SceneBank, Slot^.ID);
    End;
  End;
End;

Function SP_Model_Place(BankID: Integer; X, Y, Z, RX, RY, RZ, Scale: aFloat;
                        Var Error: TSP_ErrorCode): Integer;
Var
  SceneBank : pSP_Bank;
  ModelIdx  : Integer;
  Hdr       : pSP_ModelHeader;
  Inst      : pSP_ModelInstance;
Begin
  Result    := -1;
  SceneBank := GetActiveSceneBank(Error);
  If Not Assigned(SceneBank) Then Exit;

  ModelIdx := SP_FindBankID(BankID);
  If ModelIdx < 0 Then Begin
    Error.Code := SP_ERR_BANK_NOT_FOUND;  Exit;
  End;
  If SP_BankList[ModelIdx]^.DataType <> SP_MODEL_BANK Then Begin
    Error.Code := SP_ERR_BANK_NOT_FOUND;  Exit;
  End;

  Hdr := pSP_ModelHeader(@SP_BankList[ModelIdx]^.Info[0]);

  Inst              := AllocInstSlot(SceneBank);
  Inst^.BankID      := BankID;
  Inst^.X           := X;    Inst^.Y  := Y;    Inst^.Z  := Z;
  Inst^.RX          := RX;   Inst^.RY := RY;   Inst^.RZ := RZ;
  Inst^.Scale       := Scale;
  Inst^.Visible     := True;
  Inst^.Active      := True;
  Inst^.MatrixDirty := True;
  Inst^.Billboard   := False;
  Inst^.InstFlags   := Hdr^.Flags;
  Result := Inst^.ID;
End;

Procedure SP_Model_Move(InstID: Integer; DX, DY, DZ: aFloat; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; I: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  I  := FindInstInScene(SB, InstID);
  If Not Assigned(I) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  I^.X := I^.X + DX;  I^.Y := I^.Y + DY;  I^.Z := I^.Z + DZ;
  I^.MatrixDirty := True;
  MarkChildrenDirty(SB, InstID);
End;

Procedure SP_Model_Turn(InstID: Integer; DRX, DRY, DRZ: aFloat; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; I: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  I  := FindInstInScene(SB, InstID);
  If Not Assigned(I) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  I^.RX := I^.RX + DRX;  I^.RY := I^.RY + DRY;  I^.RZ := I^.RZ + DRZ;
  I^.MatrixDirty := True;
  MarkChildrenDirty(SB, InstID);
End;

Procedure SP_Model_Scale(InstID: Integer; S: aFloat; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; I: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  I  := FindInstInScene(SB, InstID);
  If Not Assigned(I) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  I^.Scale       := S;
  I^.MatrixDirty := True;
  MarkChildrenDirty(SB, InstID);
End;

Procedure SP_Model_MoveTo(InstID: Integer; X, Y, Z: aFloat; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; I: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  I  := FindInstInScene(SB, InstID);
  If Not Assigned(I) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  I^.X := X;  I^.Y := Y;  I^.Z := Z;
  I^.MatrixDirty := True;
  MarkChildrenDirty(SB, InstID);
End;

Procedure SP_Model_TurnTo(InstID: Integer; RX, RY, RZ: aFloat; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; I: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  I  := FindInstInScene(SB, InstID);
  If Not Assigned(I) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  I^.RX := RX;  I^.RY := RY;  I^.RZ := RZ;
  I^.MatrixDirty := True;
  MarkChildrenDirty(SB, InstID);
End;

Procedure SP_Model_GetPos(InstID: Integer; Var X, Y, Z: aFloat; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; I: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  I  := FindInstInScene(SB, InstID);
  If Not Assigned(I) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  X := I^.X;  Y := I^.Y;  Z := I^.Z;
End;

Procedure SP_Model_GetRot(InstID: Integer; Var RX, RY, RZ: aFloat; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; I: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  I  := FindInstInScene(SB, InstID);
  If Not Assigned(I) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  RX := I^.RX;  RY := I^.RY;  RZ := I^.RZ;
End;

Procedure SP_Model_GetScale(InstID: Integer; Var S: aFloat; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; I: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  I  := FindInstInScene(SB, InstID);
  If Not Assigned(I) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  S := I^.Scale;
End;

Procedure SP_Model_Remove(InstID: Integer; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; I: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  I  := FindInstInScene(SB, InstID);
  If Not Assigned(I) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  I^.Active := False;
End;

Procedure SP_Model_Hide(InstID: Integer; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; I: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  I  := FindInstInScene(SB, InstID);
  If Not Assigned(I) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  I^.Visible := False;
End;

Procedure SP_Model_Show(InstID: Integer; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; I: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  I  := FindInstInScene(SB, InstID);
  If Not Assigned(I) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  I^.Visible := True;
End;

Procedure SP_Model_SetBillboard(InstID: Integer; On: Boolean; Var Error: TSP_ErrorCode);
Var SB: pSP_Bank; I: pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);  If Not Assigned(SB) Then Exit;
  I  := FindInstInScene(SB, InstID);
  If Not Assigned(I) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  I^.Billboard     := On;
  I^.MatrixDirty   := True;
End;

Procedure SP_Model_SetShading(BankID: Integer; Smooth: Boolean; Var Error: TSP_ErrorCode);
Var
  SB        : pSP_Bank;
  Inst      : pSP_ModelInstance;
  Idx       : Integer;
  Hdr       : pSP_ModelHeader;
Begin
  SB := GetActiveSceneBank(Error);
  Inst := Nil;
  If Assigned(SB) Then
    Inst := FindInstInScene(SB, BankID);
  If Assigned(Inst) Then Begin
    If Smooth Then
      Inst^.InstFlags := Inst^.InstFlags Or SP3D_FLAG_SMOOTH
    Else
      Inst^.InstFlags := Inst^.InstFlags And Not SP3D_FLAG_SMOOTH;
    Idx := SP_FindBankID(Inst^.BankID);
    If Idx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
    Hdr := pSP_ModelHeader(@SP_BankList[Idx]^.Info[0]);
    If Smooth Then
      Hdr^.Flags := Hdr^.Flags or SP3D_FLAG_NEEDS_SMOOTH;
  End Else Begin
    Idx := SP_FindBankID(ResolveModelBankID(BankID));
    If Idx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
    Hdr := pSP_ModelHeader(@SP_BankList[Idx]^.Info[0]);
    If Smooth Then Begin
      Hdr^.Flags := Hdr^.Flags Or SP3D_FLAG_SMOOTH;
      Hdr^.Flags := Hdr^.Flags or SP3D_FLAG_NEEDS_SMOOTH;
    End Else
      Hdr^.Flags := Hdr^.Flags And Not SP3D_FLAG_SMOOTH;
  End;
  Hdr^.Flags := (Hdr^.Flags Or SP3D_FLAG_DIRTY) And Not SP3D_FLAG_BUILT;
End;

Procedure SP_Model_SetWireframe(BankID: Integer; Enabled, NoCull, Solid: Boolean; Var Error: TSP_ErrorCode);
Var
  Idx       : Integer;
  Hdr       : pSP_ModelHeader;
  SB        : pSP_Bank;
  Inst      : pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);
  Inst := Nil;
  If Assigned(SB) Then
    Inst := FindInstInScene(SB, BankID);
  If Assigned(Inst) Then Begin
    If Enabled Then
      Inst^.InstFlags := Inst^.InstFlags Or SP3D_FLAG_WIREFRAME
    Else
      Inst^.InstFlags := Inst^.InstFlags And Not SP3D_FLAG_WIREFRAME;
    If NoCull Then
      Inst^.InstFlags := Inst^.InstFlags Or SP3D_FLAG_WIRE_NOCULL
    Else
      Inst^.InstFlags := Inst^.InstFlags And Not SP3D_FLAG_WIRE_NOCULL;
    If Solid Then
      Inst^.InstFlags := Inst^.InstFlags Or SP3D_FLAG_WIRE_SOLID
    Else
      Inst^.InstFlags := Inst^.InstFlags And Not SP3D_FLAG_WIRE_SOLID;
    Idx := SP_FindBankID(Inst^.BankID);
    If Idx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
    If SP_BankList[Idx]^.DataType <> SP_MODEL_BANK Then Begin
      Error.Code := SP_ERR_BANK_NOT_FOUND; Exit;
    End;
    Hdr := pSP_ModelHeader(@SP_BankList[Idx]^.Info[0]);
    If Enabled Then
      Hdr^.Flags := Hdr^.Flags Or SP3D_FLAG_NEEDS_EDGES;
  End Else Begin
    Idx := SP_FindBankID(ResolveModelBankID(BankID));
    If Idx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
    If SP_BankList[Idx]^.DataType <> SP_MODEL_BANK Then Begin
      Error.Code := SP_ERR_BANK_NOT_FOUND; Exit;
    End;
    Hdr := pSP_ModelHeader(@SP_BankList[Idx]^.Info[0]);
    If Enabled Then Begin
      Hdr^.Flags := Hdr^.Flags Or SP3D_FLAG_WIREFRAME;
      Hdr^.Flags := Hdr^.Flags Or SP3D_FLAG_NEEDS_EDGES;
    End Else
      Hdr^.Flags := Hdr^.Flags And Not SP3D_FLAG_WIREFRAME;
    If NoCull Then
      Hdr^.Flags := Hdr^.Flags Or SP3D_FLAG_WIRE_NOCULL
    Else
      Hdr^.Flags := Hdr^.Flags And Not SP3D_FLAG_WIRE_NOCULL;
    If Solid Then
      Hdr^.Flags := Hdr^.Flags Or SP3D_FLAG_WIRE_SOLID
    Else
      Hdr^.Flags := Hdr^.Flags And Not SP3D_FLAG_WIRE_SOLID;
  End;
  Hdr^.Flags := (Hdr^.Flags Or SP3D_FLAG_DIRTY) And Not SP3D_FLAG_BUILT;
End;

Procedure SP_Model_SetColourOverride(InstID: Integer; Colour: Integer; Var Error: TSP_ErrorCode);
Var
  SB   : pSP_Bank;
  Inst : pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);
  If Not Assigned(SB) Then Exit;
  Inst := FindInstInScene(SB, InstID);
  If Not Assigned(Inst) Then Begin
    Error.Code := SP_ERR_BANK_NOT_FOUND; Exit;
  End;
  If Colour < 0 Then Begin
    Inst^.UseColourOverride := False;
    Inst^.ColourOverride    := 0;
  End Else Begin
    Inst^.UseColourOverride := True;
    Inst^.ColourOverride    := LongWord(Colour);
  End;
End;

// ===========================================================================
// Public: camera
// ===========================================================================

Procedure SP_3D_Camera(X, Y, Z, RX, RY, RZ, FOV: aFloat);
Begin
  SP3D_Cam_X  := X;   SP3D_Cam_Y  := Y;   SP3D_Cam_Z  := Z;
  SP3D_Cam_RX := RX;  SP3D_Cam_RY := RY;  SP3D_Cam_RZ := RZ;
  If FOV > 0 Then SP3D_Cam_FOV := FOV;
  SP3D_CamDirty := True;
  FlushCameraToScene(SP3D_ActiveScene);
End;

Procedure SP_3D_CameraMove(DX, DY, DZ: aFloat);
Begin
  SP3D_Cam_X := SP3D_Cam_X + DX;
  SP3D_Cam_Y := SP3D_Cam_Y + DY;
  SP3D_Cam_Z := SP3D_Cam_Z + DZ;
  SP3D_CamDirty := True;
  FlushCameraToScene(SP3D_ActiveScene);
End;

Procedure SP_3D_CameraTurn(DRX, DRY, DRZ: aFloat);
Begin
  SP3D_Cam_RX := SP3D_Cam_RX + DRX;
  SP3D_Cam_RY := SP3D_Cam_RY + DRY;
  SP3D_Cam_RZ := SP3D_Cam_RZ + DRZ;
  SP3D_CamDirty := True;
  FlushCameraToScene(SP3D_ActiveScene);
End;

Procedure SP_3D_GetCamera(Var X, Y, Z, RX, RY, RZ, FOV: aFloat);
Begin
  X   := SP3D_Cam_X;   Y   := SP3D_Cam_Y;   Z   := SP3D_Cam_Z;
  RX  := SP3D_Cam_RX;  RY  := SP3D_Cam_RY;  RZ  := SP3D_Cam_RZ;
  FOV := SP3D_Cam_FOV;
End;

Procedure SP_3D_SetNearPlane(Near: aFloat);
Begin
  If Near > 0 Then Begin
    SP3D_NEAR_PLANE := Near;
    SP3D_CamDirty   := True;
    FlushCameraToScene(SP3D_ActiveScene);
  End;
End;

// ---------------------------------------------------------------------------
// SP_3D_CameraFacePoint
// Rotates camera to look at the world-space point (TX,TY,TZ).
// Computes yaw (RY) and pitch (RX). RZ is left unchanged.
// Pitch is clamped to ±89° (in radians: ±1.5533) to avoid gimbal singularity.
// Output angles respect MATHMODE.
// ---------------------------------------------------------------------------
Procedure SP_3D_CameraFacePoint(TX, TY, TZ: aFloat);
Var
  DX, DY, DZ  : aFloat;
  Horiz, Yaw  : aFloat;
  Pitch       : aFloat;
Begin
  DX := TX - SP3D_Cam_X;
  DY := TY - SP3D_Cam_Y;
  DZ := TZ - SP3D_Cam_Z;

  // Horizontal distance for pitch calculation
  Horiz := Sqrt(DX*DX + DZ*DZ);

  // Yaw: angle around Y axis. ArcTan2(DX, DZ) gives bearing.
  // We negate because +RY rotates camera left (looking right).
  If (Abs(DX) < 1e-10) And (Abs(DZ) < 1e-10) Then
    Yaw := SP3D_Cam_RY   // directly above/below — keep current yaw
  Else
    Yaw := -ArcTan2(DX, DZ);

  // Pitch: angle up/down. Positive pitch = look up.
  Pitch := ArcTan2(DY, Horiz);

  // Clamp pitch to avoid gimbal lock at poles
  If Pitch >  1.5533 Then Pitch :=  1.5533;
  If Pitch < -1.5533 Then Pitch := -1.5533;

  // Convert radians to current MATHMODE units
  SP_RadToAngle(Yaw);
  SP_RadToAngle(Pitch);

  SP3D_Cam_RY := Yaw;
  SP3D_Cam_RX := -Pitch;  // RX positive = tilt down in our convention
  SP3D_CamDirty    := True;
  SP3D_ViewMatrixOK := False;
  FlushCameraToScene(SP3D_ActiveScene);
End;

// ---------------------------------------------------------------------------
// SP_3D_CameraFaceInst
// Aims camera at the world-space position of the given instance.
// ---------------------------------------------------------------------------
Procedure SP_3D_CameraFaceInst(InstID: Integer; Var Error: TSP_ErrorCode);
Var
  SB   : pSP_Bank;
  Inst : pSP_ModelInstance;
Begin
  SB := GetActiveSceneBank(Error);
  If Not Assigned(SB) Then Exit;
  Inst := FindInstInScene(SB, InstID);
  If Not Assigned(Inst) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;
  SP_3D_CameraFacePoint(Inst^.X, Inst^.Y, Inst^.Z);
End;

// ---------------------------------------------------------------------------
// SP_3D_ModelColl
// Returns True if the bounding spheres of the two instances overlap.
// Sphere radii are scaled by Inst.Scale.
// Both instances must be in the active scene.
// ---------------------------------------------------------------------------
Function SP_3D_ModelColl(InstA, InstB: Integer; Var Error: TSP_ErrorCode): Boolean;
Var
  SB      : pSP_Bank;
  IA, IB  : pSP_ModelInstance;
  MIdxA, MIdxB : Integer;
  HdrA, HdrB   : pSP_ModelHeader;
  RAx, RAy, RAz : aFloat;   // world-space centre of sphere A
  RBx, RBy, RBz : aFloat;   // world-space centre of sphere B
  RA, RB        : aFloat;   // scaled radii
  Dx, Dy, Dz    : aFloat;
  DistSq        : aFloat;
Begin
  Result := False;
  SB := GetActiveSceneBank(Error);
  If Not Assigned(SB) Then Exit;

  IA := FindInstInScene(SB, InstA);
  IB := FindInstInScene(SB, InstB);
  If Not Assigned(IA) Or Not Assigned(IB) Then Begin
    Error.Code := SP_ERR_INVALID_OBJECT;  Exit;
  End;

  MIdxA := SP_FindBankID(IA^.BankID);
  MIdxB := SP_FindBankID(IB^.BankID);
  If (MIdxA < 0) Or (MIdxB < 0) Then Begin
    Error.Code := SP_ERR_BANK_NOT_FOUND;  Exit;
  End;

  HdrA := pSP_ModelHeader(@SP_BankList[MIdxA]^.Info[0]);
  HdrB := pSP_ModelHeader(@SP_BankList[MIdxB]^.Info[0]);

  // Transform bounding sphere centres to world space.
  // BSX/BSY/BSZ are in model space; instance position is the translation.
  // For a simple sphere-collision test we treat the instance as having no
  // rotation effect on the centre (centre is at the model origin, which is
  // reasonable for symmetric models). For rotated asymmetric models the
  // sphere is conservative anyway.
  RAx := IA^.X + HdrA^.BSX * IA^.Scale;
  RAy := IA^.Y + HdrA^.BSY * IA^.Scale;
  RAz := IA^.Z + HdrA^.BSZ * IA^.Scale;
  RA  := HdrA^.BSRadius * IA^.Scale;

  RBx := IB^.X + HdrB^.BSX * IB^.Scale;
  RBy := IB^.Y + HdrB^.BSY * IB^.Scale;
  RBz := IB^.Z + HdrB^.BSZ * IB^.Scale;
  RB  := HdrB^.BSRadius * IB^.Scale;

  Dx := RAx - RBx;
  Dy := RAy - RBy;
  Dz := RAz - RBz;
  DistSq := Dx*Dx + Dy*Dy + Dz*Dz;

  Result := DistSq <= (RA + RB) * (RA + RB);
End;

// ---------------------------------------------------------------------------
// Helper: build a ray from screen pixel (SX,SY) in camera space.
// Returns unit direction vector in camera space.
// ---------------------------------------------------------------------------
Procedure ScreenRay(SX, SY, ScrW, ScrH: Integer;
                    FX, FY: aFloat;
                    Out RDX, RDY, RDZ: aFloat);
Var
  Len : aFloat;
Begin
  RDX := (SX - ScrW * 0.5) / FX;
  RDY := -(SY - ScrH * 0.5) / FY;   // flip Y: screen down = camera down
  RDZ := 1.0;
  Len := Sqrt(RDX*RDX + RDY*RDY + RDZ*RDZ);
  RDX := RDX / Len;
  RDY := RDY / Len;
  RDZ := RDZ / Len;
End;

// ---------------------------------------------------------------------------
// SP_3D_Point3D
// Returns the instance ID of the frontmost instance whose bounding sphere
// is hit by the ray through screen pixel (SX, SY).
// Returns -1 if no instance is hit.
// Uses the last rendered frame's cached MV matrices — call after RENDER.
// ---------------------------------------------------------------------------
Function SP_3D_Point3D(SX, SY: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  SceneBank  : pSP_Bank;
  SlotCount  : LongWord;
  si         : Integer;
  Inst       : pSP_ModelInstance;
  Hdr        : pSP_ModelHeader;
  ModelIdx   : Integer;
  RDX, RDY, RDZ  : aFloat;     // ray direction (camera space)
  BSCx, BSCy, BSCz, BSCr : aFloat;
  // Ray-sphere: solve |O + t*D|² = r²  with O=origin(0,0,0)
  // O is camera origin so simplifies to |t*D - C|² = r²
  // t²|D|² - 2t(D·C) + |C|² - r² = 0
  // Since D is unit: t² - 2t(D·C) + |C|²-r² = 0
  B, C, Disc, T : aFloat;
  BestT      : aFloat;
  ScrW, ScrH : Integer;
  FX, FY     : aFloat;
  FOVRad     : aFloat;
Begin
  Result := -1;
  BestT  := 1e30;

  If SP3D_ActiveScene < 0 Then Exit;
  SceneBank := GetSceneBank(SP3D_ActiveScene, Error);
  If Not Assigned(SceneBank) Then Begin Error.Code := SP_ERR_OK; Exit; End;

  // Reconstruct projection constants from current camera state
  ScrW   := SCREENWIDTH;   ScrH := SCREENHEIGHT;
  FOVRad := DegToRad(SP3D_Cam_FOV);
  FY     := (ScrH * 0.5) / Tan(FOVRad * 0.5);
  FX     := FY;

  ScreenRay(SX, SY, ScrW, ScrH, FX, FY, RDX, RDY, RDZ);

  SlotCount := SceneSlotCount(SceneBank);
  For si := 0 To Integer(SlotCount) - 1 Do Begin
    Inst := pSP_ModelInstance(@SceneBank^.Memory[si * SizeOf(TSP_ModelInstance)]);
    If Not Inst^.Active Or Not Inst^.Visible Then Continue;
    ModelIdx := SP_FindBankID(Inst^.BankID);
    If ModelIdx < 0 Then Continue;
    If SP_BankList[ModelIdx]^.DataType <> SP_MODEL_BANK Then Continue;
    If Length(SP_BankList[ModelIdx]^.Info) < SizeOf(TSP_ModelHeader) Then Continue;

    Hdr := pSP_ModelHeader(@SP_BankList[ModelIdx]^.Info[0]);
    If (Hdr^.Flags And SP3D_FLAG_BUILT) = 0 Then Continue;

    TransformPos(Hdr^.BSX, Hdr^.BSY, Hdr^.BSZ, Inst^.MV, BSCx, BSCy, BSCz);
    BSCr := Hdr^.BSRadius * Inst^.Scale;

    // Ray-sphere intersection (ray from origin along RDX,RDY,RDZ)
    // B = -2 * dot(D, C)  where C = sphere centre
    B    := -(RDX*BSCx + RDY*BSCy + RDZ*BSCz);
    C    := BSCx*BSCx + BSCy*BSCy + BSCz*BSCz - BSCr*BSCr;
    Disc := B*B - C;
    If Disc < 0 Then Continue;    // ray misses sphere

    T := B - Sqrt(Disc);          // nearest intersection
    If T < 0 Then T := B + Sqrt(Disc);  // camera inside sphere
    If T < 0 Then Continue;       // sphere behind camera
    If T < BestT Then Begin
      BestT  := T;
      Result := Inst^.ID;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// SP_3D_FaceAt
// Returns the index of the frontmost face of the given instance that is
// hit by the ray through screen pixel (SX, SY).
// Returns -1 if no face is hit.
// Uses Möller–Trumbore ray-triangle intersection.
// ---------------------------------------------------------------------------
Function SP_3D_FaceAt(InstID, SX, SY: Integer; Var Error: TSP_ErrorCode): Integer;
Var
  SceneBank  : pSP_Bank;
  Inst       : pSP_ModelInstance;
  Hdr        : pSP_ModelHeader;
  ModelIdx   : Integer;
  ModelBank  : pSP_Bank;
  VBase      : pSP_3DVertex;
  FBase      : pSP_3DFace;
  Face       : pSP_3DFace;
  fi         : Integer;
  RDX, RDY, RDZ : aFloat;
  // Möller–Trumbore
  V0, V1, V2    : TSP_3DVertex;   // camera-space verts (from TransVerts if available)
  E1X, E1Y, E1Z : aFloat;
  E2X, E2Y, E2Z : aFloat;
  HX, HY, HZ    : aFloat;
  A, F, U, V    : aFloat;
  SX2, SY2, SZ2 : aFloat;
  QX, QY, QZ    : aFloat;
  T             : aFloat;
  BestT         : aFloat;
  ScrW, ScrH    : Integer;
  FX, FY        : aFloat;
  FOVRad        : aFloat;
  vi            : Integer;
  vc            : Integer;
Begin
  Result := -1;
  BestT  := 1e30;

  If SP3D_ActiveScene < 0 Then Exit;
  SceneBank := GetSceneBank(SP3D_ActiveScene, Error);
  If Not Assigned(SceneBank) Then Begin Error.Code := SP_ERR_OK; Exit; End;

  Inst := FindInstInScene(SceneBank, InstID);
  If Not Assigned(Inst) Then Begin Error.Code := SP_ERR_INVALID_OBJECT; Exit; End;

  ModelIdx := SP_FindBankID(Inst^.BankID);
  If ModelIdx < 0 Then Begin Error.Code := SP_ERR_BANK_NOT_FOUND; Exit; End;
  ModelBank := SP_BankList[ModelIdx];
  If Length(ModelBank^.Info) < SizeOf(TSP_ModelHeader) Then Begin
    Error.Code := SP_ERR_BANK_NOT_FOUND; Exit;
  End;

  Hdr := pSP_ModelHeader(@ModelBank^.Info[0]);
  If (Hdr^.Flags And SP3D_FLAG_BUILT) = 0 Then Exit;

  // Re-transform vertices into SP3D_TransVerts (may be stale from last render)
  vc := Integer(Hdr^.VertexCount);
  If vc > SP3D_TransVertAlloc Then Begin
    SetLength(SP3D_TransVerts, vc);
    SP3D_TransVertAlloc := vc;
  End;
  VBase := pSP_3DVertex(@ModelBank^.Memory[0]);
  For vi := 0 To vc - 1 Do
    With pSP_3DVertex(NativeUInt(VBase) + LongWord(vi) * SizeOf(TSP_3DVertex))^ Do
      TransformPos(X, Y, Z, Inst^.MV,
                   SP3D_TransVerts[vi].X,
                   SP3D_TransVerts[vi].Y,
                   SP3D_TransVerts[vi].Z);

  ScrW   := SCREENWIDTH;  ScrH := SCREENHEIGHT;
  FOVRad := DegToRad(SP3D_Cam_FOV);
  FY     := (ScrH * 0.5) / Tan(FOVRad * 0.5);
  FX     := FY;
  ScreenRay(SX, SY, ScrW, ScrH, FX, FY, RDX, RDY, RDZ);

  FBase := pSP_3DFace(
             NativeUInt(@ModelBank^.Memory[0]) +
             LongWord(Hdr^.VertexCount) * SizeOf(TSP_3DVertex));

  For fi := 0 To Integer(Hdr^.FaceCount) - 1 Do Begin
    Face := pSP_3DFace(NativeUInt(FBase) + LongWord(fi) * SizeOf(TSP_3DFace));

    V0 := SP3D_TransVerts[Face^.V0];
    V1 := SP3D_TransVerts[Face^.V1];
    V2 := SP3D_TransVerts[Face^.V2];

    // Edge vectors
    E1X := V1.X - V0.X;  E1Y := V1.Y - V0.Y;  E1Z := V1.Z - V0.Z;
    E2X := V2.X - V0.X;  E2Y := V2.Y - V0.Y;  E2Z := V2.Z - V0.Z;

    // H = D × E2
    HX := RDY*E2Z - RDZ*E2Y;
    HY := RDZ*E2X - RDX*E2Z;
    HZ := RDX*E2Y - RDY*E2X;

    A := E1X*HX + E1Y*HY + E1Z*HZ;
    If Abs(A) < 1e-10 Then Continue;  // ray parallel to triangle

    F := 1.0 / A;

    // S = O - V0  (ray origin is camera at 0,0,0)
    SX2 := -V0.X;  SY2 := -V0.Y;  SZ2 := -V0.Z;

    U := F * (SX2*HX + SY2*HY + SZ2*HZ);
    If (U < 0) Or (U > 1) Then Continue;

    // Q = S × E1
    QX := SY2*E1Z - SZ2*E1Y;
    QY := SZ2*E1X - SX2*E1Z;
    QZ := SX2*E1Y - SY2*E1X;

    V := F * (RDX*QX + RDY*QY + RDZ*QZ);
    If (V < 0) Or (U + V > 1) Then Continue;

    T := F * (E2X*QX + E2Y*QY + E2Z*QZ);
    If T < 1e-6 Then Continue;   // intersection behind camera

    If T < BestT Then Begin
      BestT  := T;
      Result := fi;
    End;
  End;
End;

// ===========================================================================
// Public: light
// ===========================================================================

Procedure SP_3D_LightDir(DX, DY, DZ: aFloat);
Var L: aFloat;
Begin
  L := Sqrt(DX*DX + DY*DY + DZ*DZ);
  If L > 1e-7 Then Begin
    SP3D_Light_DX := DX/L;  SP3D_Light_DY := DY/L;  SP3D_Light_DZ := DZ/L;
  End Else Begin
    SP3D_Light_DX := 0;  SP3D_Light_DY := -1;  SP3D_Light_DZ := 0;
  End;
  SP3D_Light_Active := True;
End;

Procedure SP_3D_LightAmbient(A: aFloat);
Begin
  If A < 0.0 Then A := 0.0;
  If A > 1.0 Then A := 1.0;
  SP3D_Light_Ambient := A;
End;

Procedure SP_3D_LightColour(R, G, B: aFloat);
Begin
  If R < 0.0 Then R := 0.0;  If R > 1.0 Then R := 1.0;
  If G < 0.0 Then G := 0.0;  If G > 1.0 Then G := 1.0;
  If B < 0.0 Then B := 0.0;  If B > 1.0 Then B := 1.0;
  SP3D_Light_R := R;
  SP3D_Light_G := G;
  SP3D_Light_B := B;
  SP3D_ShadeDirty    := True;   // 8bpp: rebuild shade table with new tint
  SP3D_ShadeDirty32  := True;   // 32bpp: rebuild any cached LUTs
End;

// Fogging

Procedure SP_3D_BuildFogTable(Const Pal: Array of TP_Colour);
Var
  ci, band, pi : Integer;
  T            : aFloat;
  FogRGB       : TP_Colour;
  OrigRGB      : TP_Colour;
  BR, BG, BB   : Integer;
  Best, Cur    : Int64;
Begin
  FogRGB := Pal[SP3D_FogColour];
  For ci := 0 To 255 Do
    For band := 0 To SP3D_FOG_BANDS - 1 Do Begin
      T      := band / (SP3D_FOG_BANDS - 1);
      OrigRGB := Pal[ci];
      BR := Round(OrigRGB.R * (1.0 - T) + FogRGB.R * T);
      BG := Round(OrigRGB.G * (1.0 - T) + FogRGB.G * T);
      BB := Round(OrigRGB.B * (1.0 - T) + FogRGB.B * T);
      If BR > 255 Then BR := 255;
      If BG > 255 Then BG := 255;
      If BB > 255 Then BB := 255;
      Best := High(Int64);
      SP3D_FogTable[ci, band] := ci;
      For pi := 0 To 255 Do Begin
        Cur := Int64(BR - Pal[pi].R) * Int64(BR - Pal[pi].R) +
               Int64(BG - Pal[pi].G) * Int64(BG - Pal[pi].G) +
               Int64(BB - Pal[pi].B) * Int64(BB - Pal[pi].B);
        If Cur < Best Then Begin
          Best := Cur;
          SP3D_FogTable[ci, band] := Byte(pi);
        End;
      End;
    End;
  SP3D_FogDirty := False;
End;

Procedure SP_3D_InvalidateFogTable;
Begin
  SP3D_FogDirty := True;
End;

Procedure SP_3D_Fog(Near, Far: aFloat; Colour: Byte);
Begin
  SP3D_FogNear   := Near;
  SP3D_FogFar    := Far;
  SP3D_FogColour := Colour;
  SP3D_FogActive := True;
  SP3D_FogDirty  := True;
End;

Procedure SP_3D_FogOff;
Begin
  SP3D_FogActive := False;
End;

// ===========================================================================
// Internal: near-plane clipper
// "Inside" = Z >= Near (objects in front of camera have +Z in camera space).
// Returns 0, 1 or 2 output triangles in T1/T2.
// Winding order is preserved so the screen-space backface cull is correct.
// ===========================================================================

Function ClipLerp(Const A, B: TClipVert; Near: aFloat): TClipVert;
Var T: aFloat;
Begin
  T        := (Near - A.Z) / (B.Z - A.Z);
  Result.X := A.X + T * (B.X - A.X);
  Result.Y := A.Y + T * (B.Y - A.Y);
  Result.Z := Near;
  Result.U := A.U + T * (B.U - A.U);
  Result.V := A.V + T * (B.V - A.V);
End;

Function ClipTriNear(Const V0, V1, V2: TClipVert; Near: aFloat; Out T1, T2: TClipTri): Integer;
Var
  In0, In1, In2 : Boolean;
  IC            : Integer;
  IVA, IVB      : TClipVert;
  OVA           : TClipVert;
  P1, P2        : TClipVert;
Begin
  In0 := V0.Z >= Near;  In1 := V1.Z >= Near;  In2 := V2.Z >= Near;
  IC  := Ord(In0) + Ord(In1) + Ord(In2);

  If IC = 0 Then Begin Result := 0; Exit; End;
  If IC = 3 Then Begin T1[0] := V0; T1[1] := V1; T1[2] := V2; Result := 1; Exit; End;

  If IC = 1 Then Begin
    If      In0 Then Begin IVA := V0; OVA := V1; IVB := V2; End
    Else If In1 Then Begin IVA := V1; OVA := V2; IVB := V0; End
    Else              Begin IVA := V2; OVA := V0; IVB := V1; End;
    P1 := ClipLerp(IVA, OVA, Near);
    P2 := ClipLerp(IVA, IVB, Near);
    T1[0] := IVA;  T1[1] := P1;  T1[2] := P2;
    Result := 1;
  End Else Begin
    If      Not In0 Then Begin OVA := V0; IVA := V1; IVB := V2; End
    Else If Not In1 Then Begin OVA := V1; IVA := V2; IVB := V0; End
    Else                  Begin OVA := V2; IVA := V0; IVB := V1; End;
    P1 := ClipLerp(IVA, OVA, Near);
    P2 := ClipLerp(IVB, OVA, Near);
    T1[0] := IVA;  T1[1] := IVB;  T1[2] := P1;
    T2[0] := IVB;  T2[1] := P2;   T2[2] := P1;
    Result := 2;
  End;
End;

// ---------------------------------------------------------------------------
// Shared span-fill kernel macros — implemented as inline helpers to avoid
// duplicating the edge-stepping setup across all 14 procs.
// The top/bottom half setup is identical in every proc; only the inner
// pixel loop differs.  We use a nested procedure pattern so the compiler
// can see the outer variables directly without parameter passing.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 1. RasterFlat8  —  flat shaded, no fog
// ---------------------------------------------------------------------------

Procedure RasterFlat8(Const RF: pSP_RenderFace;
                      SurfPtr: pByte; Stride: Integer;
                      ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Var
  X0, Y0, X1, Y1, X2, Y2 : Integer;
  Colour                  : Byte;
  DY, yStart, yEnd, Skip  : Integer;
  xLeft, xRight, y        : Integer;
  xL, xR, dxL, dxR       : Int64;
  RowPtr                  : pByte;

  Procedure Swap2(Var A, B: Integer); Inline;
  Var T: Integer; Begin T := A; A := B; B := T; End;

Begin
  X0 := RF^.SX[0]; Y0 := RF^.SY[0];
  X1 := RF^.SX[1]; Y1 := RF^.SY[1];
  X2 := RF^.SX[2]; Y2 := RF^.SY[2];
  Colour := RF^.Colour;

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
        RowPtr := pByte(NativeUInt(SurfPtr) + LongWord(y * Stride + xLeft));
        FillChar(RowPtr^, xRight - xLeft + 1, Colour);
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
        RowPtr := pByte(NativeUInt(SurfPtr) + LongWord(y * Stride + xLeft));
        FillChar(RowPtr^, xRight - xLeft + 1, Colour);
      End;
      xL := xL + dxL; xR := xR + dxR;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 2. RasterFlat8Fog  —  flat shaded, fogged
// ---------------------------------------------------------------------------

Procedure RasterFlat8Fog(Const RF: pSP_RenderFace;
                         SurfPtr: pByte; Stride: Integer;
                         ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Var
  X0, Y0, X1, Y1, X2, Y2 : Integer;
  Colour                  : Byte;
  DY, yStart, yEnd, Skip  : Integer;
  xLeft, xRight, y        : Integer;
  xL, xR, dxL, dxR       : Int64;
  RowPtr                  : pByte;

  Procedure Swap2(Var A, B: Integer); Inline;
  Var T: Integer; Begin T := A; A := B; B := T; End;

Begin
  X0 := RF^.SX[0]; Y0 := RF^.SY[0];
  X1 := RF^.SX[1]; Y1 := RF^.SY[1];
  X2 := RF^.SX[2]; Y2 := RF^.SY[2];
  // Colour already has shading baked in from gather; fog applied here
  Colour := SP3D_FogTable[RF^.Colour, RF^.FogBand];

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
        RowPtr := pByte(NativeUInt(SurfPtr) + LongWord(y * Stride + xLeft));
        FillChar(RowPtr^, xRight - xLeft + 1, Colour);
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
        RowPtr := pByte(NativeUInt(SurfPtr) + LongWord(y * Stride + xLeft));
        FillChar(RowPtr^, xRight - xLeft + 1, Colour);
      End;
      xL := xL + dxL; xR := xR + dxR;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// Shared edge-stepping setup for Gouraud procs.
// Rather than repeat the full top/bottom half boilerplate 6 times,
// the Gouraud procs share a common span-dispatch approach using a nested
// procedure for the inner pixel loop.  The edge variables are declared in
// the outer scope and the inner proc closes over them.
//
// For clarity and debuggability each proc is still self-contained below,
// but the pixel loop body is the only part that differs.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 3. RasterGouraudUniform8  —  single colour, no fog
// ---------------------------------------------------------------------------

Procedure RasterGouraudUniform8(Const RF: pSP_RenderFace;
                                SurfPtr: pByte; Stride: Integer;
                                ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Var
  X0, Y0, IB0,
  X1, Y1, IB1,
  X2, Y2, IB2    : Integer;
  ShadeRowPtr    : pByte;
  DY, yStart, yEnd, Skip, y, px : Integer;
  xLeft, xRight, SpanW, Tx      : Integer;
  xL, dxL              : Int64;
  ibL, dibL            : Int64;
  xR_top, dxR_top      : Int64;
  ibR_top, dibR_top    : Int64;
  xR_bot, dxR_bot      : Int64;
  ibR_bot, dibR_bot    : Int64;
  sibL, sibR           : Int64;
  ibSpan, dibSpan      : Int64;
  RowPtr               : pByte;

  Procedure Swap3(Var AX,AY,AC, BX,BY,BC: Integer); Inline;
  Var TX,TY,TC: Integer;
  Begin TX:=AX; TY:=AY; TC:=AC; AX:=BX; AY:=BY; AC:=BC; BX:=TX; BY:=TY; BC:=TC; End;

Begin
  X0 := RF^.SX[0]; Y0 := RF^.SY[0]; IB0 := RF^.GC[0];
  X1 := RF^.SX[1]; Y1 := RF^.SY[1]; IB1 := RF^.GC[1];
  X2 := RF^.SX[2]; Y2 := RF^.SY[2]; IB2 := RF^.GC[2];
  ShadeRowPtr := @SP3D_ShadeTable[RF^.Colour, 0];

  If (Y0 >= ClipY2) And (Y1 >= ClipY2) And (Y2 >= ClipY2) Then Exit;
  If (Y0 < ClipY1)  And (Y1 < ClipY1)  And (Y2 < ClipY1)  Then Exit;

  If Y0 > Y1 Then Swap3(X0,Y0,IB0, X1,Y1,IB1);
  If Y0 > Y2 Then Swap3(X0,Y0,IB0, X2,Y2,IB2);
  If Y1 > Y2 Then Swap3(X1,Y1,IB1, X2,Y2,IB2);
  If Y0 = Y2 Then Exit;

  DY   := Y2 - Y0;
  dxL  := Int64(X2 - X0) * 65536 Div DY;
  dibL := Int64(IB2 - IB0) * 65536 Div DY;
  xL   := Int64(X0) * 65536;
  ibL  := Int64(IB0) * 65536;

  If Y0 < Y1 Then Begin
    DY       := Y1 - Y0;
    dxR_top  := Int64(X1 - X0) * 65536 Div DY;
    dibR_top := Int64(IB1 - IB0) * 65536 Div DY;
    xR_top   := Int64(X0) * 65536;
    ibR_top  := Int64(IB0) * 65536;
    yStart := Y0; yEnd := Y1;
    If yStart < ClipY1 Then Begin
      Skip    := ClipY1 - yStart;
      xL      := xL + dxL*Skip;      ibL     := ibL + dibL*Skip;
      xR_top  := xR_top + dxR_top*Skip; ibR_top := ibR_top + dibR_top*Skip;
      yStart  := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR_top Shr 16);
      If xLeft <= xRight Then Begin sibL := ibL; sibR := ibR_top; End
      Else Begin Tx := xLeft; xLeft := xRight; xRight := Tx; sibL := ibR_top; sibR := ibL; End;
      SpanW := xRight - xLeft;
      If SpanW > 0 Then dibSpan := (sibR - sibL) Div SpanW Else dibSpan := 0;
      ibSpan := sibL;
      If xLeft < ClipX1 Then Begin ibSpan := ibSpan + dibSpan*(ClipX1-xLeft); xLeft := ClipX1; End;
      If xRight > ClipX2-1 Then xRight := ClipX2-1;
      If xLeft <= xRight Then Begin
        RowPtr := pByte(NativeUInt(SurfPtr) + LongWord(y*Stride + xLeft));
        For px := xLeft To xRight Do Begin
          RowPtr^ := ShadeRowPtr[Integer(ibSpan Shr 16) And 15];
          Inc(RowPtr); ibSpan := ibSpan + dibSpan;
        End;
      End;
      xL := xL + dxL; ibL := ibL + dibL;
      xR_top := xR_top + dxR_top; ibR_top := ibR_top + dibR_top;
    End;
  End;

  xL  := Int64(X0)*65536 + dxL  * Int64(Y1-Y0);
  ibL := Int64(IB0)*65536 + dibL * Int64(Y1-Y0);

  If Y1 < Y2 Then Begin
    DY       := Y2 - Y1;
    dxR_bot  := Int64(X2 - X1) * 65536 Div DY;
    dibR_bot := Int64(IB2 - IB1) * 65536 Div DY;
    xR_bot   := Int64(X1) * 65536;
    ibR_bot  := Int64(IB1) * 65536;
    yStart := Y1; yEnd := Y2;
    If yStart < ClipY1 Then Begin
      Skip    := ClipY1 - yStart;
      xL      := xL + dxL*Skip;      ibL     := ibL + dibL*Skip;
      xR_bot  := xR_bot + dxR_bot*Skip; ibR_bot := ibR_bot + dibR_bot*Skip;
      yStart  := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR_bot Shr 16);
      If xLeft <= xRight Then Begin sibL := ibL; sibR := ibR_bot; End
      Else Begin Tx := xLeft; xLeft := xRight; xRight := Tx; sibL := ibR_bot; sibR := ibL; End;
      SpanW := xRight - xLeft;
      If SpanW > 0 Then dibSpan := (sibR - sibL) Div SpanW Else dibSpan := 0;
      ibSpan := sibL;
      If xLeft < ClipX1 Then Begin ibSpan := ibSpan + dibSpan*(ClipX1-xLeft); xLeft := ClipX1; End;
      If xRight > ClipX2-1 Then xRight := ClipX2-1;
      If xLeft <= xRight Then Begin
        RowPtr := pByte(NativeUInt(SurfPtr) + LongWord(y*Stride + xLeft));
        For px := xLeft To xRight Do Begin
          RowPtr^ := ShadeRowPtr[Integer(ibSpan Shr 16) And 15];
          Inc(RowPtr); ibSpan := ibSpan + dibSpan;
        End;
      End;
      xL := xL + dxL; ibL := ibL + dibL;
      xR_bot := xR_bot + dxR_bot; ibR_bot := ibR_bot + dibR_bot;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 4. RasterGouraudUniform8Fog  —  single colour, fogged
// ---------------------------------------------------------------------------

Procedure RasterGouraudUniform8Fog(Const RF: pSP_RenderFace;
                                   SurfPtr: pByte; Stride: Integer;
                                   ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Var
  X0, Y0, IB0,
  X1, Y1, IB1,
  X2, Y2, IB2    : Integer;
  ShadeRowPtr    : pByte;
  FogBand        : Byte;
  DY, yStart, yEnd, Skip, y, px : Integer;
  xLeft, xRight, SpanW, Tx      : Integer;
  xL, dxL              : Int64;
  ibL, dibL            : Int64;
  xR_top, dxR_top      : Int64;
  ibR_top, dibR_top    : Int64;
  xR_bot, dxR_bot      : Int64;
  ibR_bot, dibR_bot    : Int64;
  sibL, sibR           : Int64;
  ibSpan, dibSpan      : Int64;
  ibq                  : Integer;
  RowPtr               : pByte;

  Procedure Swap3(Var AX,AY,AC, BX,BY,BC: Integer); Inline;
  Var TX,TY,TC: Integer;
  Begin TX:=AX; TY:=AY; TC:=AC; AX:=BX; AY:=BY; AC:=BC; BX:=TX; BY:=TY; BC:=TC; End;

Begin
  X0 := RF^.SX[0]; Y0 := RF^.SY[0]; IB0 := RF^.GC[0];
  X1 := RF^.SX[1]; Y1 := RF^.SY[1]; IB1 := RF^.GC[1];
  X2 := RF^.SX[2]; Y2 := RF^.SY[2]; IB2 := RF^.GC[2];
  ShadeRowPtr := @SP3D_ShadeTable[RF^.Colour, 0];
  FogBand     := RF^.FogBand;

  If (Y0 >= ClipY2) And (Y1 >= ClipY2) And (Y2 >= ClipY2) Then Exit;
  If (Y0 < ClipY1)  And (Y1 < ClipY1)  And (Y2 < ClipY1)  Then Exit;

  If Y0 > Y1 Then Swap3(X0,Y0,IB0, X1,Y1,IB1);
  If Y0 > Y2 Then Swap3(X0,Y0,IB0, X2,Y2,IB2);
  If Y1 > Y2 Then Swap3(X1,Y1,IB1, X2,Y2,IB2);
  If Y0 = Y2 Then Exit;

  DY   := Y2 - Y0;
  dxL  := Int64(X2 - X0) * 65536 Div DY;
  dibL := Int64(IB2 - IB0) * 65536 Div DY;
  xL   := Int64(X0) * 65536;
  ibL  := Int64(IB0) * 65536;

  If Y0 < Y1 Then Begin
    DY       := Y1 - Y0;
    dxR_top  := Int64(X1 - X0) * 65536 Div DY;
    dibR_top := Int64(IB1 - IB0) * 65536 Div DY;
    xR_top   := Int64(X0) * 65536;
    ibR_top  := Int64(IB0) * 65536;
    yStart := Y0; yEnd := Y1;
    If yStart < ClipY1 Then Begin
      Skip := ClipY1 - yStart;
      xL := xL + dxL*Skip; ibL := ibL + dibL*Skip;
      xR_top := xR_top + dxR_top*Skip; ibR_top := ibR_top + dibR_top*Skip;
      yStart := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR_top Shr 16);
      If xLeft <= xRight Then Begin sibL := ibL; sibR := ibR_top; End
      Else Begin Tx := xLeft; xLeft := xRight; xRight := Tx; sibL := ibR_top; sibR := ibL; End;
      SpanW := xRight - xLeft;
      If SpanW > 0 Then dibSpan := (sibR - sibL) Div SpanW Else dibSpan := 0;
      ibSpan := sibL;
      If xLeft < ClipX1 Then Begin ibSpan := ibSpan + dibSpan*(ClipX1-xLeft); xLeft := ClipX1; End;
      If xRight > ClipX2-1 Then xRight := ClipX2-1;
      If xLeft <= xRight Then Begin
        RowPtr := pByte(NativeUInt(SurfPtr) + LongWord(y*Stride + xLeft));
        For px := xLeft To xRight Do Begin
          ibq     := Integer(ibSpan Shr 16) And 15;
          RowPtr^ := SP3D_FogTable[ShadeRowPtr[ibq], FogBand];
          Inc(RowPtr); ibSpan := ibSpan + dibSpan;
        End;
      End;
      xL := xL + dxL; ibL := ibL + dibL;
      xR_top := xR_top + dxR_top; ibR_top := ibR_top + dibR_top;
    End;
  End;

  xL  := Int64(X0)*65536 + dxL  * Int64(Y1-Y0);
  ibL := Int64(IB0)*65536 + dibL * Int64(Y1-Y0);

  If Y1 < Y2 Then Begin
    DY       := Y2 - Y1;
    dxR_bot  := Int64(X2 - X1) * 65536 Div DY;
    dibR_bot := Int64(IB2 - IB1) * 65536 Div DY;
    xR_bot   := Int64(X1) * 65536;
    ibR_bot  := Int64(IB1) * 65536;
    yStart := Y1; yEnd := Y2;
    If yStart < ClipY1 Then Begin
      Skip := ClipY1 - yStart;
      xL := xL + dxL*Skip; ibL := ibL + dibL*Skip;
      xR_bot := xR_bot + dxR_bot*Skip; ibR_bot := ibR_bot + dibR_bot*Skip;
      yStart := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR_bot Shr 16);
      If xLeft <= xRight Then Begin sibL := ibL; sibR := ibR_bot; End
      Else Begin Tx := xLeft; xLeft := xRight; xRight := Tx; sibL := ibR_bot; sibR := ibL; End;
      SpanW := xRight - xLeft;
      If SpanW > 0 Then dibSpan := (sibR - sibL) Div SpanW Else dibSpan := 0;
      ibSpan := sibL;
      If xLeft < ClipX1 Then Begin ibSpan := ibSpan + dibSpan*(ClipX1-xLeft); xLeft := ClipX1; End;
      If xRight > ClipX2-1 Then xRight := ClipX2-1;
      If xLeft <= xRight Then Begin
        RowPtr := pByte(NativeUInt(SurfPtr) + LongWord(y*Stride + xLeft));
        For px := xLeft To xRight Do Begin
          ibq     := Integer(ibSpan Shr 16) And 15;
          RowPtr^ := SP3D_FogTable[ShadeRowPtr[ibq], FogBand];
          Inc(RowPtr); ibSpan := ibSpan + dibSpan;
        End;
      End;
      xL := xL + dxL; ibL := ibL + dibL;
      xR_bot := xR_bot + dxR_bot; ibR_bot := ibR_bot + dibR_bot;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 5. RasterGouraudFull8  —  multi-colour LUT, no fog
// ---------------------------------------------------------------------------

Procedure RasterGouraudFull8(Const RF: pSP_RenderFace;
                             SurfPtr: pByte; Stride: Integer;
                             ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Var
  X0, Y0, IB0,
  X1, Y1, IB1,
  X2, Y2, IB2    : Integer;
  SortedLUT      : pByte;
  DY, yStart, yEnd, Skip, y, px : Integer;
  xLeft, xRight, SpanW, Tx      : Integer;
  xL, dxL              : Int64;
  w2L, dw2L            : Int64;
  ibL, dibL            : Int64;
  xR_top, dxR_top      : Int64;
  w1R_top, dw1R_top    : Int64;
  ibR_top, dibR_top    : Int64;
  xR_bot, dxR_bot      : Int64;
  w1R_bot, dw1R_bot    : Int64;
  w2R_bot, dw2R_bot    : Int64;
  ibR_bot, dibR_bot    : Int64;
  sw1L, sw2L, sibL     : Int64;
  sw1R, sw2R, sibR     : Int64;
  w1Span, w2Span       : Int64;
  ibSpan               : Int64;
  dw1Span, dw2Span     : Int64;
  dibSpan              : Int64;
  w1q, w2q             : Integer;
  Col                  : Byte;
  RowPtr               : pByte;

  Procedure Swap3(Var AX,AY,AC, BX,BY,BC: Integer); Inline;
  Var TX,TY,TC: Integer;
  Begin TX:=AX; TY:=AY; TC:=AC; AX:=BX; AY:=BY; AC:=BC; BX:=TX; BY:=TY; BC:=TC; End;

Begin
  X0 := RF^.SX[0]; Y0 := RF^.SY[0]; IB0 := RF^.GC[0];
  X1 := RF^.SX[1]; Y1 := RF^.SY[1]; IB1 := RF^.GC[1];
  X2 := RF^.SX[2]; Y2 := RF^.SY[2]; IB2 := RF^.GC[2];
  SortedLUT := @SP3D_GouraudLUTBuf[RF^.GouraudLUTIdx * 256];

  If (Y0 >= ClipY2) And (Y1 >= ClipY2) And (Y2 >= ClipY2) Then Exit;
  If (Y0 < ClipY1)  And (Y1 < ClipY1)  And (Y2 < ClipY1)  Then Exit;

  If Y0 > Y1 Then Swap3(X0,Y0,IB0, X1,Y1,IB1);
  If Y0 > Y2 Then Swap3(X0,Y0,IB0, X2,Y2,IB2);
  If Y1 > Y2 Then Swap3(X1,Y1,IB1, X2,Y2,IB2);
  If Y0 = Y2 Then Exit;

  DY   := Y2 - Y0;
  dxL  := Int64(X2 - X0) * 65536 Div DY;
  dw2L := Int64(15) * 65536 Div DY;
  dibL := Int64(IB2 - IB0) * 65536 Div DY;
  xL   := Int64(X0) * 65536;
  w2L  := 0;
  ibL  := Int64(IB0) * 65536;

  If Y0 < Y1 Then Begin
    DY        := Y1 - Y0;
    dxR_top   := Int64(X1 - X0) * 65536 Div DY;
    dw1R_top  := Int64(15) * 65536 Div DY;
    dibR_top  := Int64(IB1 - IB0) * 65536 Div DY;
    xR_top    := Int64(X0) * 65536;
    w1R_top   := 0;
    ibR_top   := Int64(IB0) * 65536;
    yStart := Y0; yEnd := Y1;
    If yStart < ClipY1 Then Begin
      Skip    := ClipY1 - yStart;
      xL      := xL + dxL*Skip;    w2L     := w2L + dw2L*Skip;      ibL     := ibL + dibL*Skip;
      xR_top  := xR_top + dxR_top*Skip; w1R_top := w1R_top + dw1R_top*Skip; ibR_top := ibR_top + dibR_top*Skip;
      yStart  := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR_top Shr 16);
      If xLeft <= xRight Then Begin sw1L := 0; sw2L := w2L; sibL := ibL; sw1R := w1R_top; sw2R := 0; sibR := ibR_top; End
      Else Begin Tx := xLeft; xLeft := xRight; xRight := Tx; sw1L := w1R_top; sw2L := 0; sibL := ibR_top; sw1R := 0; sw2R := w2L; sibR := ibL; End;
      SpanW := xRight - xLeft;
      If SpanW > 0 Then Begin dw1Span := (sw1R-sw1L) Div SpanW; dw2Span := (sw2R-sw2L) Div SpanW; dibSpan := (sibR-sibL) Div SpanW; End
      Else Begin dw1Span := 0; dw2Span := 0; dibSpan := 0; End;
      w1Span := sw1L; w2Span := sw2L; ibSpan := sibL;
      If xLeft < ClipX1 Then Begin w1Span := w1Span + dw1Span*(ClipX1-xLeft); w2Span := w2Span + dw2Span*(ClipX1-xLeft); ibSpan := ibSpan + dibSpan*(ClipX1-xLeft); xLeft := ClipX1; End;
      If xRight > ClipX2-1 Then xRight := ClipX2-1;
      If xLeft <= xRight Then Begin
        RowPtr := pByte(NativeUInt(SurfPtr) + LongWord(y*Stride + xLeft));
        For px := xLeft To xRight Do Begin
          w1q := Integer(w1Span Shr 16) And 15; w2q := Integer(w2Span Shr 16) And 15;
          If w1q + w2q > 15 Then w2q := 15 - w1q;
          Col     := pByte(NativeUInt(SortedLUT) + LongWord(w1q*16 + w2q))^;
          RowPtr^ := SP3D_ShadeTable[Col, Integer(ibSpan Shr 16) And 15];
          Inc(RowPtr); w1Span := w1Span + dw1Span; w2Span := w2Span + dw2Span; ibSpan := ibSpan + dibSpan;
        End;
      End;
      xL := xL + dxL; w2L := w2L + dw2L; ibL := ibL + dibL;
      xR_top := xR_top + dxR_top; w1R_top := w1R_top + dw1R_top; ibR_top := ibR_top + dibR_top;
    End;
  End;

  xL  := Int64(X0)*65536 + dxL  * Int64(Y1-Y0);
  w2L := dw2L * Int64(Y1-Y0);
  ibL := Int64(IB0)*65536 + dibL * Int64(Y1-Y0);

  If Y1 < Y2 Then Begin
    DY        := Y2 - Y1;
    dxR_bot   := Int64(X2 - X1) * 65536 Div DY;
    dw1R_bot  := -(Int64(15) * 65536 Div DY);
    dw2R_bot  :=   Int64(15) * 65536 Div DY;
    dibR_bot  := Int64(IB2 - IB1) * 65536 Div DY;
    xR_bot    := Int64(X1) * 65536;
    w1R_bot   := Int64(15) * 65536;
    w2R_bot   := 0;
    ibR_bot   := Int64(IB1) * 65536;
    yStart := Y1; yEnd := Y2;
    If yStart < ClipY1 Then Begin
      Skip    := ClipY1 - yStart;
      xL      := xL + dxL*Skip;    w2L     := w2L + dw2L*Skip;      ibL     := ibL + dibL*Skip;
      xR_bot  := xR_bot + dxR_bot*Skip; w1R_bot := w1R_bot + dw1R_bot*Skip; w2R_bot := w2R_bot + dw2R_bot*Skip; ibR_bot := ibR_bot + dibR_bot*Skip;
      yStart  := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR_bot Shr 16);
      If xLeft <= xRight Then Begin sw1L := 0; sw2L := w2L; sibL := ibL; sw1R := w1R_bot; sw2R := w2R_bot; sibR := ibR_bot; End
      Else Begin Tx := xLeft; xLeft := xRight; xRight := Tx; sw1L := w1R_bot; sw2L := w2R_bot; sibL := ibR_bot; sw1R := 0; sw2R := w2L; sibR := ibL; End;
      SpanW := xRight - xLeft;
      If SpanW > 0 Then Begin dw1Span := (sw1R-sw1L) Div SpanW; dw2Span := (sw2R-sw2L) Div SpanW; dibSpan := (sibR-sibL) Div SpanW; End
      Else Begin dw1Span := 0; dw2Span := 0; dibSpan := 0; End;
      w1Span := sw1L; w2Span := sw2L; ibSpan := sibL;
      If xLeft < ClipX1 Then Begin w1Span := w1Span + dw1Span*(ClipX1-xLeft); w2Span := w2Span + dw2Span*(ClipX1-xLeft); ibSpan := ibSpan + dibSpan*(ClipX1-xLeft); xLeft := ClipX1; End;
      If xRight > ClipX2-1 Then xRight := ClipX2-1;
      If xLeft <= xRight Then Begin
        RowPtr := pByte(NativeUInt(SurfPtr) + LongWord(y*Stride + xLeft));
        For px := xLeft To xRight Do Begin
          w1q := Integer(w1Span Shr 16) And 15; w2q := Integer(w2Span Shr 16) And 15;
          If w1q + w2q > 15 Then w2q := 15 - w1q;
          Col     := pByte(NativeUInt(SortedLUT) + LongWord(w1q*16 + w2q))^;
          RowPtr^ := SP3D_ShadeTable[Col, Integer(ibSpan Shr 16) And 15];
          Inc(RowPtr); w1Span := w1Span + dw1Span; w2Span := w2Span + dw2Span; ibSpan := ibSpan + dibSpan;
        End;
      End;
      xL := xL + dxL; w2L := w2L + dw2L; ibL := ibL + dibL;
      xR_bot := xR_bot + dxR_bot; w1R_bot := w1R_bot + dw1R_bot; w2R_bot := w2R_bot + dw2R_bot; ibR_bot := ibR_bot + dibR_bot;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// 6. RasterGouraudFull8Fog  —  multi-colour LUT, fogged
// ---------------------------------------------------------------------------

Procedure RasterGouraudFull8Fog(Const RF: pSP_RenderFace;
                                SurfPtr: pByte; Stride: Integer;
                                ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Var
  X0, Y0, IB0,
  X1, Y1, IB1,
  X2, Y2, IB2    : Integer;
  SortedLUT      : pByte;
  FogBand        : Byte;
  DY, yStart, yEnd, Skip, y, px : Integer;
  xLeft, xRight, SpanW, Tx      : Integer;
  xL, dxL              : Int64;
  w2L, dw2L            : Int64;
  ibL, dibL            : Int64;
  xR_top, dxR_top      : Int64;
  w1R_top, dw1R_top    : Int64;
  ibR_top, dibR_top    : Int64;
  xR_bot, dxR_bot      : Int64;
  w1R_bot, dw1R_bot    : Int64;
  w2R_bot, dw2R_bot    : Int64;
  ibR_bot, dibR_bot    : Int64;
  sw1L, sw2L, sibL     : Int64;
  sw1R, sw2R, sibR     : Int64;
  w1Span, w2Span       : Int64;
  ibSpan               : Int64;
  dw1Span, dw2Span     : Int64;
  dibSpan              : Int64;
  w1q, w2q, ibq        : Integer;
  Col                  : Byte;
  RowPtr               : pByte;

  Procedure Swap3(Var AX,AY,AC, BX,BY,BC: Integer); Inline;
  Var TX,TY,TC: Integer;
  Begin TX:=AX; TY:=AY; TC:=AC; AX:=BX; AY:=BY; AC:=BC; BX:=TX; BY:=TY; BC:=TC; End;

Begin
  X0 := RF^.SX[0]; Y0 := RF^.SY[0]; IB0 := RF^.GC[0];
  X1 := RF^.SX[1]; Y1 := RF^.SY[1]; IB1 := RF^.GC[1];
  X2 := RF^.SX[2]; Y2 := RF^.SY[2]; IB2 := RF^.GC[2];
  SortedLUT := @SP3D_GouraudLUTBuf[RF^.GouraudLUTIdx * 256];
  FogBand   := RF^.FogBand;

  If (Y0 >= ClipY2) And (Y1 >= ClipY2) And (Y2 >= ClipY2) Then Exit;
  If (Y0 < ClipY1)  And (Y1 < ClipY1)  And (Y2 < ClipY1)  Then Exit;

  If Y0 > Y1 Then Swap3(X0,Y0,IB0, X1,Y1,IB1);
  If Y0 > Y2 Then Swap3(X0,Y0,IB0, X2,Y2,IB2);
  If Y1 > Y2 Then Swap3(X1,Y1,IB1, X2,Y2,IB2);
  If Y0 = Y2 Then Exit;

  DY   := Y2 - Y0;
  dxL  := Int64(X2 - X0) * 65536 Div DY;
  dw2L := Int64(15) * 65536 Div DY;
  dibL := Int64(IB2 - IB0) * 65536 Div DY;
  xL   := Int64(X0) * 65536;
  w2L  := 0;
  ibL  := Int64(IB0) * 65536;

  If Y0 < Y1 Then Begin
    DY        := Y1 - Y0;
    dxR_top   := Int64(X1 - X0) * 65536 Div DY;
    dw1R_top  := Int64(15) * 65536 Div DY;
    dibR_top  := Int64(IB1 - IB0) * 65536 Div DY;
    xR_top    := Int64(X0) * 65536;
    w1R_top   := 0;
    ibR_top   := Int64(IB0) * 65536;
    yStart := Y0; yEnd := Y1;
    If yStart < ClipY1 Then Begin
      Skip    := ClipY1 - yStart;
      xL      := xL + dxL*Skip;    w2L     := w2L + dw2L*Skip;      ibL     := ibL + dibL*Skip;
      xR_top  := xR_top + dxR_top*Skip; w1R_top := w1R_top + dw1R_top*Skip; ibR_top := ibR_top + dibR_top*Skip;
      yStart  := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR_top Shr 16);
      If xLeft <= xRight Then Begin sw1L := 0; sw2L := w2L; sibL := ibL; sw1R := w1R_top; sw2R := 0; sibR := ibR_top; End
      Else Begin Tx := xLeft; xLeft := xRight; xRight := Tx; sw1L := w1R_top; sw2L := 0; sibL := ibR_top; sw1R := 0; sw2R := w2L; sibR := ibL; End;
      SpanW := xRight - xLeft;
      If SpanW > 0 Then Begin dw1Span := (sw1R-sw1L) Div SpanW; dw2Span := (sw2R-sw2L) Div SpanW; dibSpan := (sibR-sibL) Div SpanW; End
      Else Begin dw1Span := 0; dw2Span := 0; dibSpan := 0; End;
      w1Span := sw1L; w2Span := sw2L; ibSpan := sibL;
      If xLeft < ClipX1 Then Begin w1Span := w1Span + dw1Span*(ClipX1-xLeft); w2Span := w2Span + dw2Span*(ClipX1-xLeft); ibSpan := ibSpan + dibSpan*(ClipX1-xLeft); xLeft := ClipX1; End;
      If xRight > ClipX2-1 Then xRight := ClipX2-1;
      If xLeft <= xRight Then Begin
        RowPtr := pByte(NativeUInt(SurfPtr) + LongWord(y*Stride + xLeft));
        For px := xLeft To xRight Do Begin
          w1q := Integer(w1Span Shr 16) And 15; w2q := Integer(w2Span Shr 16) And 15;
          If w1q + w2q > 15 Then w2q := 15 - w1q;
          ibq     := Integer(ibSpan Shr 16) And 15;
          Col     := pByte(NativeUInt(SortedLUT) + LongWord(w1q*16 + w2q))^;
          RowPtr^ := SP3D_FogTable[SP3D_ShadeTable[Col, ibq], FogBand];
          Inc(RowPtr); w1Span := w1Span + dw1Span; w2Span := w2Span + dw2Span; ibSpan := ibSpan + dibSpan;
        End;
      End;
      xL := xL + dxL; w2L := w2L + dw2L; ibL := ibL + dibL;
      xR_top := xR_top + dxR_top; w1R_top := w1R_top + dw1R_top; ibR_top := ibR_top + dibR_top;
    End;
  End;

  xL  := Int64(X0)*65536 + dxL  * Int64(Y1-Y0);
  w2L := dw2L * Int64(Y1-Y0);
  ibL := Int64(IB0)*65536 + dibL * Int64(Y1-Y0);

  If Y1 < Y2 Then Begin
    DY        := Y2 - Y1;
    dxR_bot   := Int64(X2 - X1) * 65536 Div DY;
    dw1R_bot  := -(Int64(15) * 65536 Div DY);
    dw2R_bot  :=   Int64(15) * 65536 Div DY;
    dibR_bot  := Int64(IB2 - IB1) * 65536 Div DY;
    xR_bot    := Int64(X1) * 65536;
    w1R_bot   := Int64(15) * 65536;
    w2R_bot   := 0;
    ibR_bot   := Int64(IB1) * 65536;
    yStart := Y1; yEnd := Y2;
    If yStart < ClipY1 Then Begin
      Skip    := ClipY1 - yStart;
      xL      := xL + dxL*Skip;    w2L     := w2L + dw2L*Skip;      ibL     := ibL + dibL*Skip;
      xR_bot  := xR_bot + dxR_bot*Skip; w1R_bot := w1R_bot + dw1R_bot*Skip; w2R_bot := w2R_bot + dw2R_bot*Skip; ibR_bot := ibR_bot + dibR_bot*Skip;
      yStart  := ClipY1;
    End;
    If yEnd > ClipY2 Then yEnd := ClipY2;
    For y := yStart To yEnd - 1 Do Begin
      xLeft  := Integer(xL Shr 16); xRight := Integer(xR_bot Shr 16);
      If xLeft <= xRight Then Begin sw1L := 0; sw2L := w2L; sibL := ibL; sw1R := w1R_bot; sw2R := w2R_bot; sibR := ibR_bot; End
      Else Begin Tx := xLeft; xLeft := xRight; xRight := Tx; sw1L := w1R_bot; sw2L := w2R_bot; sibL := ibR_bot; sw1R := 0; sw2R := w2L; sibR := ibL; End;
      SpanW := xRight - xLeft;
      If SpanW > 0 Then Begin dw1Span := (sw1R-sw1L) Div SpanW; dw2Span := (sw2R-sw2L) Div SpanW; dibSpan := (sibR-sibL) Div SpanW; End
      Else Begin dw1Span := 0; dw2Span := 0; dibSpan := 0; End;
      w1Span := sw1L; w2Span := sw2L; ibSpan := sibL;
      If xLeft < ClipX1 Then Begin w1Span := w1Span + dw1Span*(ClipX1-xLeft); w2Span := w2Span + dw2Span*(ClipX1-xLeft); ibSpan := ibSpan + dibSpan*(ClipX1-xLeft); xLeft := ClipX1; End;
      If xRight > ClipX2-1 Then xRight := ClipX2-1;
      If xLeft <= xRight Then Begin
        RowPtr := pByte(NativeUInt(SurfPtr) + LongWord(y*Stride + xLeft));
        For px := xLeft To xRight Do Begin
          w1q := Integer(w1Span Shr 16) And 15; w2q := Integer(w2Span Shr 16) And 15;
          If w1q + w2q > 15 Then w2q := 15 - w1q;
          ibq     := Integer(ibSpan Shr 16) And 15;
          Col     := pByte(NativeUInt(SortedLUT) + LongWord(w1q*16 + w2q))^;
          RowPtr^ := SP3D_FogTable[SP3D_ShadeTable[Col, ibq], FogBand];
          Inc(RowPtr); w1Span := w1Span + dw1Span; w2Span := w2Span + dw2Span; ibSpan := ibSpan + dibSpan;
        End;
      End;
      xL := xL + dxL; w2L := w2L + dw2L; ibL := ibL + dibL;
      xR_bot := xR_bot + dxR_bot; w1R_bot := w1R_bot + dw1R_bot; w2R_bot := w2R_bot + dw2R_bot; ibR_bot := ibR_bot + dibR_bot;
    End;
  End;
End;

// ---------------------------------------------------------------------------
// Textured procs — shared perspective-correct span setup.
// The 8 textured variants differ only in their inner pixel loop.
// Edge stepping and span setup is identical across all 8 so we define it
// once via a common local var block pattern.  Each proc is self-contained.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 7. RasterTexPow2Opaque8  —  pow2, opaque, no fog
// ---------------------------------------------------------------------------

Procedure RasterTexPow2Opaque8(Const RF: pSP_RenderFace;
                               SurfPtr: pByte; Stride: Integer;
                               ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2          : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                 : aFloat;
  IntenBand                   : Byte;
  TexData                     : pByte;
  TexW, TexWMask, TexHMask : Integer;
  DY, yStart, yEnd, Skip, y   : Integer;
  xLeft, xRight, SpanW        : Integer;
  SubEnd, SubW, px, ppx, tInt : Integer;
  dxL, xL, dxR, xR            : Int64;
  dUZL,dVZL,dWZL              : aFloat;
  dUZR,dVZR,dWZR              : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR    : aFloat;
  ULeft,VLeft,URight,VRight   : aFloat;
  U_fp,V_fp,dU_fp,dV_fp       : Int64;
  UZSpan,VZSpan,WZSpan        : aFloat;
  dUZSpan,dVZSpan,dWZSpan     : aFloat;
  UZNext,VZNext,WZNext        : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                      : Integer;
  RowPtr                      : pByte;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenBand:=RF^.IntenBand; TexData:=RF^.TexData;
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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) And TexHMask)*TexW+(Integer(U_fp Shr 16) And TexWMask);
            RowPtr^:=SP3D_ShadeTable[pByte(NativeUInt(TexData)+LongWord(TexIdx))^, IntenBand];
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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
        If WZSpan<>0 Then Begin ULeft:=UZSpan/WZSpan; VLeft:=VZSpan/WZSpan; End Else Begin ULeft:=0; VLeft:=0; End;
        While px<=xRight Do Begin
          SubEnd:=px+SUBDIV-1; If SubEnd>xRight Then SubEnd:=xRight; SubW:=SubEnd-px;
          UZNext:=UZSpan+dUZSpan*(SubW+1); VZNext:=VZSpan+dVZSpan*(SubW+1); WZNext:=WZSpan+dWZSpan*(SubW+1);
          If WZNext<>0 Then Begin URight:=UZNext/WZNext; VRight:=VZNext/WZNext; End Else Begin URight:=ULeft; VRight:=VLeft; End;
          U_fp:=Round(ULeft*65536); V_fp:=Round(VLeft*65536);
          If SubW>0 Then Begin dU_fp:=Round((URight-ULeft)*65536) Div SubW; dV_fp:=Round((VRight-VLeft)*65536) Div SubW; End Else Begin dU_fp:=0; dV_fp:=0; End;
          For ppx:=px To SubEnd Do Begin
            TexIdx:=(Integer(V_fp Shr 16) And TexHMask)*TexW+(Integer(U_fp Shr 16) And TexWMask);
            RowPtr^:=SP3D_ShadeTable[pByte(NativeUInt(TexData)+LongWord(TexIdx))^, IntenBand];
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
// 8. RasterTexPow2Opaque8Fog  —  pow2, opaque, fogged
// Inner loop only differs: SP3D_FogTable[ShadeTable[...], FogBand]
// ---------------------------------------------------------------------------

Procedure RasterTexPow2Opaque8Fog(Const RF: pSP_RenderFace;
                                  SurfPtr: pByte; Stride: Integer;
                                  ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2          : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                 : aFloat;
  IntenBand, FogBand          : Byte;
  TexData                     : pByte;
  TexW, TexWMask, TexHMask : Integer;
  DY, yStart, yEnd, Skip, y   : Integer;
  xLeft, xRight, SpanW        : Integer;
  SubEnd, SubW, px, ppx, tInt : Integer;
  dxL, xL, dxR, xR            : Int64;
  dUZL,dVZL,dWZL              : aFloat;
  dUZR,dVZR,dWZR              : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR    : aFloat;
  ULeft,VLeft,URight,VRight   : aFloat;
  U_fp,V_fp,dU_fp,dV_fp       : Int64;
  UZSpan,VZSpan,WZSpan        : aFloat;
  dUZSpan,dVZSpan,dWZSpan     : aFloat;
  UZNext,VZNext,WZNext        : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                      : Integer;
  TexPix                      : Byte;
  RowPtr                      : pByte;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenBand:=RF^.IntenBand; FogBand:=RF^.FogBand;
  TexData:=RF^.TexData; TexW:=RF^.TexW; TexWMask:=RF^.TexWMask; TexHMask:=RF^.TexHMask;

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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            RowPtr^:=SP3D_FogTable[SP3D_ShadeTable[TexPix, IntenBand], FogBand];
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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            RowPtr^:=SP3D_FogTable[SP3D_ShadeTable[TexPix, IntenBand], FogBand];
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
// 9. RasterTexPow2Transp8  —  pow2, transparent, no fog
// ---------------------------------------------------------------------------

Procedure RasterTexPow2Transp8(Const RF: pSP_RenderFace;
                               SurfPtr: pByte; Stride: Integer;
                               ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2          : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                 : aFloat;
  IntenBand                   : Byte;
  TranspIdx                   : Integer;
  TexData                     : pByte;
  TexW, TexWMask, TexHMask : Integer;
  DY, yStart, yEnd, Skip, y   : Integer;
  xLeft, xRight, SpanW        : Integer;
  SubEnd, SubW, px, ppx, tInt : Integer;
  dxL, xL, dxR, xR            : Int64;
  dUZL,dVZL,dWZL              : aFloat;
  dUZR,dVZR,dWZR              : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR    : aFloat;
  ULeft,VLeft,URight,VRight   : aFloat;
  U_fp,V_fp,dU_fp,dV_fp       : Int64;
  UZSpan,VZSpan,WZSpan        : aFloat;
  dUZSpan,dVZSpan,dWZSpan     : aFloat;
  UZNext,VZNext,WZNext        : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                      : Integer;
  TexPix                      : Byte;
  RowPtr                      : pByte;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenBand:=RF^.IntenBand; TranspIdx:=RF^.TranspIdx;
  TexData:=RF^.TexData; TexW:=RF^.TexW; TexWMask:=RF^.TexWMask; TexHMask:=RF^.TexHMask;

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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            If TexPix <> Byte(TranspIdx) Then
              RowPtr^:=SP3D_ShadeTable[TexPix, IntenBand];
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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            If TexPix <> Byte(TranspIdx) Then
              RowPtr^:=SP3D_ShadeTable[TexPix, IntenBand];
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
// 10. RasterTexPow2Transp8Fog  —  pow2, transparent, fogged
// ---------------------------------------------------------------------------

Procedure RasterTexPow2Transp8Fog(Const RF: pSP_RenderFace;
                                  SurfPtr: pByte; Stride: Integer;
                                  ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2          : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                 : aFloat;
  IntenBand, FogBand          : Byte;
  TranspIdx                   : Integer;
  TexData                     : pByte;
  TexW, TexWMask, TexHMask : Integer;
  DY, yStart, yEnd, Skip, y   : Integer;
  xLeft, xRight, SpanW        : Integer;
  SubEnd, SubW, px, ppx, tInt : Integer;
  dxL, xL, dxR, xR            : Int64;
  dUZL,dVZL,dWZL              : aFloat;
  dUZR,dVZR,dWZR              : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR    : aFloat;
  ULeft,VLeft,URight,VRight   : aFloat;
  U_fp,V_fp,dU_fp,dV_fp       : Int64;
  UZSpan,VZSpan,WZSpan        : aFloat;
  dUZSpan,dVZSpan,dWZSpan     : aFloat;
  UZNext,VZNext,WZNext        : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                      : Integer;
  TexPix                      : Byte;
  RowPtr                      : pByte;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenBand:=RF^.IntenBand; FogBand:=RF^.FogBand; TranspIdx:=RF^.TranspIdx;
  TexData:=RF^.TexData; TexW:=RF^.TexW; TexWMask:=RF^.TexWMask; TexHMask:=RF^.TexHMask;

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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            If TexPix <> Byte(TranspIdx) Then
              RowPtr^:=SP3D_FogTable[SP3D_ShadeTable[TexPix, IntenBand], FogBand];
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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            If TexPix <> Byte(TranspIdx) Then
              RowPtr^:=SP3D_FogTable[SP3D_ShadeTable[TexPix, IntenBand], FogBand];
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
// 11. RasterTexNPOTOpaque8  —  non-power-of-2, opaque, no fog
// ---------------------------------------------------------------------------

Procedure RasterTexNPOTOpaque8(Const RF: pSP_RenderFace;
                               SurfPtr: pByte; Stride: Integer;
                               ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2          : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                 : aFloat;
  IntenBand                   : Byte;
  TexData                     : pByte;
  TexW, TexH                  : Integer;
  DY, yStart, yEnd, Skip, y   : Integer;
  xLeft, xRight, SpanW        : Integer;
  SubEnd, SubW, px, ppx, tInt : Integer;
  dxL, xL, dxR, xR            : Int64;
  dUZL,dVZL,dWZL              : aFloat;
  dUZR,dVZR,dWZR              : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR    : aFloat;
  ULeft,VLeft,URight,VRight   : aFloat;
  U_fp,V_fp,dU_fp,dV_fp       : Int64;
  UZSpan,VZSpan,WZSpan        : aFloat;
  dUZSpan,dVZSpan,dWZSpan     : aFloat;
  UZNext,VZNext,WZNext        : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                      : Integer;
  RowPtr                      : pByte;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenBand:=RF^.IntenBand; TexData:=RF^.TexData; TexW:=RF^.TexW; TexH:=RF^.TexH;

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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            RowPtr^:=SP3D_ShadeTable[pByte(NativeUInt(TexData)+LongWord(TexIdx))^, IntenBand];
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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            RowPtr^:=SP3D_ShadeTable[pByte(NativeUInt(TexData)+LongWord(TexIdx))^, IntenBand];
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
// 12. RasterTexNPOTOpaque8Fog  —  non-power-of-2, opaque, fogged
// ---------------------------------------------------------------------------

Procedure RasterTexNPOTOpaque8Fog(Const RF: pSP_RenderFace;
                                  SurfPtr: pByte; Stride: Integer;
                                  ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2          : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                 : aFloat;
  IntenBand, FogBand          : Byte;
  TexData                     : pByte;
  TexW, TexH                  : Integer;
  DY, yStart, yEnd, Skip, y   : Integer;
  xLeft, xRight, SpanW        : Integer;
  SubEnd, SubW, px, ppx, tInt : Integer;
  dxL, xL, dxR, xR            : Int64;
  dUZL,dVZL,dWZL              : aFloat;
  dUZR,dVZR,dWZR              : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR    : aFloat;
  ULeft,VLeft,URight,VRight   : aFloat;
  U_fp,V_fp,dU_fp,dV_fp       : Int64;
  UZSpan,VZSpan,WZSpan        : aFloat;
  dUZSpan,dVZSpan,dWZSpan     : aFloat;
  UZNext,VZNext,WZNext        : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                      : Integer;
  TexPix                      : Byte;
  RowPtr                      : pByte;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenBand:=RF^.IntenBand; FogBand:=RF^.FogBand; TexData:=RF^.TexData; TexW:=RF^.TexW; TexH:=RF^.TexH;

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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            RowPtr^:=SP3D_FogTable[SP3D_ShadeTable[TexPix, IntenBand], FogBand];
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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            RowPtr^:=SP3D_FogTable[SP3D_ShadeTable[TexPix, IntenBand], FogBand];
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
// 13. RasterTexNPOTTransp8  —  non-power-of-2, transparent, no fog
// ---------------------------------------------------------------------------

Procedure RasterTexNPOTTransp8(Const RF: pSP_RenderFace;
                               SurfPtr: pByte; Stride: Integer;
                               ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2          : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                 : aFloat;
  IntenBand                   : Byte;
  TranspIdx                   : Integer;
  TexData                     : pByte;
  TexW, TexH                  : Integer;
  DY, yStart, yEnd, Skip, y   : Integer;
  xLeft, xRight, SpanW        : Integer;
  SubEnd, SubW, px, ppx, tInt : Integer;
  dxL, xL, dxR, xR            : Int64;
  dUZL,dVZL,dWZL              : aFloat;
  dUZR,dVZR,dWZR              : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR    : aFloat;
  ULeft,VLeft,URight,VRight   : aFloat;
  U_fp,V_fp,dU_fp,dV_fp       : Int64;
  UZSpan,VZSpan,WZSpan        : aFloat;
  dUZSpan,dVZSpan,dWZSpan     : aFloat;
  UZNext,VZNext,WZNext        : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                      : Integer;
  TexPix                      : Byte;
  RowPtr                      : pByte;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenBand:=RF^.IntenBand; TranspIdx:=RF^.TranspIdx;
  TexData:=RF^.TexData; TexW:=RF^.TexW; TexH:=RF^.TexH;

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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            If TexPix <> Byte(TranspIdx) Then
              RowPtr^:=SP3D_ShadeTable[TexPix, IntenBand];
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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            If TexPix <> Byte(TranspIdx) Then
              RowPtr^:=SP3D_ShadeTable[TexPix, IntenBand];
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
// 14. RasterTexNPOTTransp8Fog  —  non-power-of-2, transparent, fogged
// ---------------------------------------------------------------------------

Procedure RasterTexNPOTTransp8Fog(Const RF: pSP_RenderFace;
                                  SurfPtr: pByte; Stride: Integer;
                                  ClipX1, ClipY1, ClipX2, ClipY2: Integer);
Const SUBDIV = 16;
Var
  X0,Y0,X1,Y1,X2,Y2          : Integer;
  UZ0,VZ0,WZ0,UZ1,VZ1,WZ1,
  UZ2,VZ2,WZ2                 : aFloat;
  IntenBand, FogBand          : Byte;
  TranspIdx                   : Integer;
  TexData                     : pByte;
  TexW, TexH                  : Integer;
  DY, yStart, yEnd, Skip, y   : Integer;
  xLeft, xRight, SpanW        : Integer;
  SubEnd, SubW, px, ppx, tInt : Integer;
  dxL, xL, dxR, xR            : Int64;
  dUZL,dVZL,dWZL              : aFloat;
  dUZR,dVZR,dWZR              : aFloat;
  UZL,VZL,WZL,UZR,VZR,WZR    : aFloat;
  ULeft,VLeft,URight,VRight   : aFloat;
  U_fp,V_fp,dU_fp,dV_fp       : Int64;
  UZSpan,VZSpan,WZSpan        : aFloat;
  dUZSpan,dVZSpan,dWZSpan     : aFloat;
  UZNext,VZNext,WZNext        : aFloat;
  sUZL,sVZL,sWZL,sUZR,sVZR,sWZR : aFloat;
  TexIdx                      : Integer;
  TexPix                      : Byte;
  RowPtr                      : pByte;

  Procedure SwapIntPair(Var AX,AY: Integer; Var AUZ,AVZ,AWZ: aFloat;
                        Var BX,BY: Integer; Var BUZ,BVZ,BWZ: aFloat); Inline;
  Var TX,TY: Integer; TUZ,TVZ,TWZ: aFloat;
  Begin TX:=AX;TY:=AY;TUZ:=AUZ;TVZ:=AVZ;TWZ:=AWZ; AX:=BX;AY:=BY;AUZ:=BUZ;AVZ:=BVZ;AWZ:=BWZ; BX:=TX;BY:=TY;BUZ:=TUZ;BVZ:=TVZ;BWZ:=TWZ; End;

Begin
  X0:=RF^.SX[0]; Y0:=RF^.SY[0]; X1:=RF^.SX[1]; Y1:=RF^.SY[1]; X2:=RF^.SX[2]; Y2:=RF^.SY[2];
  UZ0:=RF^.SU[0]; VZ0:=RF^.SVt[0]; WZ0:=RF^.SW[0];
  UZ1:=RF^.SU[1]; VZ1:=RF^.SVt[1]; WZ1:=RF^.SW[1];
  UZ2:=RF^.SU[2]; VZ2:=RF^.SVt[2]; WZ2:=RF^.SW[2];
  IntenBand:=RF^.IntenBand; FogBand:=RF^.FogBand; TranspIdx:=RF^.TranspIdx;
  TexData:=RF^.TexData; TexW:=RF^.TexW; TexH:=RF^.TexH;

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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            If TexPix <> Byte(TranspIdx) Then
              RowPtr^:=SP3D_FogTable[SP3D_ShadeTable[TexPix, IntenBand], FogBand];
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
        RowPtr:=pByte(NativeUInt(SurfPtr)+LongWord(y*Stride+xLeft)); px:=xLeft;
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
            If TexPix <> Byte(TranspIdx) Then
              RowPtr^:=SP3D_FogTable[SP3D_ShadeTable[TexPix, IntenBand], FogBand];
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
// Internal: painter's sort — Quick sort, descending AvgCZ (far first)
// ===========================================================================

Procedure SortFaces(Var Faces: Array of TSP_RenderFace; Count: Integer);

  Procedure QSort(Lo, Hi: Integer);
  Var
    i, j, Mid : Integer;
    Pivot      : aFloat;
    Tmp        : TSP_RenderFace;
  Begin
    While Lo < Hi Do Begin

      // Median-of-three pivot
      Mid := Lo + (Hi - Lo) Shr 1;
      If Faces[Lo].AvgCZ < Faces[Mid].AvgCZ Then Begin Tmp := Faces[Lo]; Faces[Lo] := Faces[Mid]; Faces[Mid] := Tmp; End;
      If Faces[Lo].AvgCZ < Faces[Hi].AvgCZ  Then Begin Tmp := Faces[Lo]; Faces[Lo] := Faces[Hi];  Faces[Hi]  := Tmp; End;
      If Faces[Mid].AvgCZ < Faces[Hi].AvgCZ Then Begin Tmp := Faces[Mid]; Faces[Mid] := Faces[Hi]; Faces[Hi]  := Tmp; End;

      // If 3 or fewer elements, sorted by the swaps above
      If Hi - Lo <= 2 Then Exit;

      // Move pivot to Hi-1
      Tmp := Faces[Mid]; Faces[Mid] := Faces[Hi-1]; Faces[Hi-1] := Tmp;
      Pivot := Faces[Hi-1].AvgCZ;

      i := Lo;
      j := Hi - 1;
      Repeat
        Inc(i); While Faces[i].AvgCZ > Pivot Do Inc(i);
        Dec(j); While Faces[j].AvgCZ < Pivot Do Dec(j);
        If i < j Then Begin Tmp := Faces[i]; Faces[i] := Faces[j]; Faces[j] := Tmp; End;
      Until i >= j;

      // Restore pivot
      Tmp := Faces[i]; Faces[i] := Faces[Hi-1]; Faces[Hi-1] := Tmp;

      // Recurse on smaller partition, iterate on larger (limits stack depth)
      If i - Lo < Hi - i Then Begin
        QSort(Lo, i - 1);
        Lo := i + 1;
      End Else Begin
        QSort(i + 1, Hi);
        Hi := i - 1;
      End;
    End;
  End;

Begin
  If Count > 1 Then QSort(0, Count - 1);
End;

Procedure SortFaces_Range(Var Faces: Array of TSP_RenderFace; Lo, Hi: Integer);

  Procedure QSort(L, H: Integer);
  Var
    i, j, Mid : Integer;
    Pivot      : aFloat;
    Tmp        : TSP_RenderFace;
  Begin
    While L < H Do Begin
      Mid := L + (H - L) Shr 1;
      If Faces[L].AvgCZ < Faces[Mid].AvgCZ Then Begin Tmp := Faces[L]; Faces[L] := Faces[Mid]; Faces[Mid] := Tmp; End;
      If Faces[L].AvgCZ < Faces[H].AvgCZ  Then Begin Tmp := Faces[L]; Faces[L] := Faces[H];  Faces[H]  := Tmp; End;
      If Faces[Mid].AvgCZ < Faces[H].AvgCZ Then Begin Tmp := Faces[Mid]; Faces[Mid] := Faces[H]; Faces[H] := Tmp; End;
      If H - L <= 2 Then Exit;
      Tmp := Faces[Mid]; Faces[Mid] := Faces[H-1]; Faces[H-1] := Tmp;
      Pivot := Faces[H-1].AvgCZ;
      i := L;  j := H - 1;
      Repeat
        Inc(i); While Faces[i].AvgCZ > Pivot Do Inc(i);
        Dec(j); While Faces[j].AvgCZ < Pivot Do Dec(j);
        If i < j Then Begin Tmp := Faces[i]; Faces[i] := Faces[j]; Faces[j] := Tmp; End;
      Until i >= j;
      Tmp := Faces[i]; Faces[i] := Faces[H-1]; Faces[H-1] := Tmp;
      If i - L < H - i Then Begin QSort(L, i-1); L := i+1; End
      Else Begin QSort(i+1, H); H := i-1; End;
    End;
  End;

Begin
  If Hi > Lo Then QSort(Lo, Hi);
End;

Function ARGBToPalIdx(Colour: LongWord): Byte; Inline;
Begin
  Result := Byte(Colour);
End;

Function ResolveColour(BakedColour: LongWord; IsDefault: Boolean; Const Inst: pSP_ModelInstance): LongWord; Inline;
Begin
  If Inst^.UseColourOverride Then
    Result := Inst^.ColourOverride
  Else If IsDefault Then
    Result := CINK
  Else
    Result := BakedColour;
End;

Function ResolveVertexColour(BakedColour: LongWord; IsDefault: Boolean; FaceColour: LongWord; Const Inst: pSP_ModelInstance): LongWord; Inline;
Begin
  If Inst^.UseColourOverride Then
    Result := Inst^.ColourOverride
  Else If IsDefault Then
    Result := FaceColour   // inherit from face rather than T_INK
  Else
    Result := BakedColour;
End;

// ===========================================================================
// Public: renderer
// ===========================================================================

Procedure SP_3D_Render(WindowID, SceneID, ThreadCount: Integer; Var Error: TSP_ErrorCode);
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

  FogBand     : Byte;
  FogT        : aFloat;

  // Per-object sort
  InstOrderCount : Integer;
  si2, siTmp     : Integer;
  InstDist       : aFloat;

  // Frustum culling
  BSCx, BSCy, BSCz, BSCr : aFloat;    // bounding sphere in camera space
  FrustumOK              : Boolean;

  // Frustum planes (camera space, normal pointing inward)
  // Order: near, far, left, right, top, bottom
  // Each plane: (nx, ny, nz, d) where point is inside if dot(n,p)+d >= 0
  FP : Array[0..5, 0..3] of aFloat;

  FarPlane, HalfFOV, HalfFOVY: aFloat;

  PSX, PSY: Integer;
  PV: TSP_3DVertex;
  pCol: Byte;
  GC0, GC1, GC2: Byte;
  VDot, VInten: aFloat;

  BaseC0, BaseC1, BaseC2 : Byte;   // base colours from vertex bank
  GouraudUniform  : Boolean;
  GouraudFaceLUT  : pByte;
  SortGC0,SortGC1,SortGC2: Byte;
  SortBC0,SortBC1,SortBC2: Byte;
  HasSmooth: Boolean;

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
  WireColour    : Byte;
  WireInten     : Byte;
  siTmpModel    : Integer;
  V0X, V0Y, V0Z : aFloat;
  V1X, V1Y, V1Z : aFloat;
  V2X, V2Y, V2Z : aFloat;
  DotN          : aFloat;
  BandSum, BandCount : Integer;
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

  MatPassDone    : Boolean;
  MatPassCount   : Integer;
  MatPassInst    : pSP_ModelInstance;
  MatParentInst  : pSP_ModelInstance;
  MatSi          : Integer;
  ASYNC          : Boolean;

  LastDispTexBank: Integer;
  LastDispGfxInfo: pSP_Graphic_Info;

  Procedure SwapI(Var A,B: Integer); Inline;
  Var T: Integer; Begin T:=A; A:=B; B:=T; End;

  Procedure SwapB(Var A,B: Byte); Inline;
  Var T: Byte; Begin T:=A; A:=B; B:=T; End;

Const

  MaxHierarchyDepth = 8;

Begin
  Error.Code := SP_ERR_OK;

  // Flush camera dirty flag first — invalidates all instance matrices
  If SP3D_CamDirty Then
    InvalidateAllSceneMatrices;

  // Switch window if requested
  SavedBank := SCREENBANK;
  If WindowID <> SCREENBANK Then Begin
    SP_SetDrawingWindow(WindowID);
    If SCREENBANK <> Abs(WindowID) Then Begin
      Error.Code := SP_ERR_WINDOW_NOT_FOUND; Exit;
    End;
  End;

  SurfPtr := SCREENPOINTER;
  ScrW    := SCREENWIDTH;
  ScrH    := SCREENHEIGHT;
  Stride  := SCREENSTRIDE;
  ClipX1  := T_CLIPX1;  ClipY1 := T_CLIPY1;
  ClipX2  := T_CLIPX2;  ClipY2 := T_CLIPY2;
  Move(pSP_Window_Info(WINDOWPOINTER)^.Palette[0], WinPal[0], SizeOf(WinPal));

  // Rebuild shade table if palette changed
  If SP3D_ShadeDirty Then Begin
    SP_3D_BuildShadeTable(WinPal);
    SP_3D_BuildColourCube;
  End;

  If SP3D_FogDirty And SP3D_FogActive Then
    SP_3D_BuildFogTable(WinPal);

  // Resolve scene
  If SceneID < 0 Then SceneID := SP3D_ActiveScene;
  SceneBank := GetSceneBank(SceneID, Error);
  If Not Assigned(SceneBank) Then Begin
    If (WindowID >= 0) And (SavedBank <> WindowID) Then
      SP_SetDrawingWindow(SavedBank);
    Exit;
  End;

  // Projection constants
  If SP3D_Cam_FOV < 1 Then SP3D_Cam_FOV := 60;
  FOVRad := DegToRad(SP3D_Cam_FOV);
  FY     := (ScrH * 0.5) / Tan(FOVRad * 0.5);
  FX     := FY;
  HalfW  := ScrW * 0.5;
  HalfH  := ScrH * 0.5;

  // Build frustum planes in camera space
  // Near and far
  FP[0][0] :=  0;  FP[0][1] :=  0;  FP[0][2] :=  1;  FP[0][3] := -SP3D_NEAR_PLANE;
  FarPlane := 1000.0;  // effectively infinite; tighten if fog is active
  If SP3D_FogActive Then FarPlane := SP3D_FogFar * 1.1;
  FP[1][0] :=  0;  FP[1][1] :=  0;  FP[1][2] := -1;  FP[1][3] :=  FarPlane;
  // Left and right (from FOV)
  HalfFOV := ArcTan((ScrW * 0.5) / FX);
  FP[2][0] :=  Cos(HalfFOV);  FP[2][1] := 0;  FP[2][2] := Sin(HalfFOV);  FP[2][3] := 0;
  FP[3][0] := -Cos(HalfFOV);  FP[3][1] := 0;  FP[3][2] := Sin(HalfFOV);  FP[3][3] := 0;
  // Top and bottom
  HalfFOVY := ArcTan((ScrH * 0.5) / FY);
  FP[4][0] := 0;  FP[4][1] :=  Cos(HalfFOVY);  FP[4][2] := Sin(HalfFOVY);  FP[4][3] := 0;
  FP[5][0] := 0;  FP[5][1] := -Cos(HalfFOVY);  FP[5][2] := Sin(HalfFOVY);  FP[5][3] := 0;

  If SP3D_RFacesAlloc < 8192 Then Begin
    SetLength(SP3D_RFaces, 8192);
    SetLength(SP3D_GouraudLUTBuf, 8192 * 256);
    SP3D_RFacesAlloc := 8192;
  End;
  RFCount := 0;
  SP3D_GouraudLUTCount := 0;

  // Build per-object sort order
  SlotCount := SceneSlotCount(SceneBank);
  If Integer(SlotCount) > SP3D_InstOrderAlloc Then Begin
    SP3D_InstOrderAlloc := Integer(SlotCount) + 16;
    SetLength(SP3D_InstOrder,    SP3D_InstOrderAlloc);
    SetLength(SP3D_InstModelIdx, SP3D_InstOrderAlloc);
    SetLength(SP3D_InstDistArr,  SP3D_InstOrderAlloc);
  End;
  InstOrderCount := 0;

  MatPassCount := 0;
  Repeat
    MatPassDone := True;
    For MatSi := 0 To Integer(SlotCount) - 1 Do Begin
      MatPassInst := pSP_ModelInstance(@SceneBank^.Memory[MatSi * SizeOf(TSP_ModelInstance)]);
      If Not MatPassInst^.Active Then Continue;
      If Not MatPassInst^.MatrixDirty Then Continue;

      If MatPassInst^.ParentID < 0 Then Begin
        // Root instance — build with global view matrix
        BuildInstanceMatrices(MatPassInst^);
      End Else Begin
        // Child — find parent
        MatParentInst := FindInstInScene(SceneBank, MatPassInst^.ParentID);
        If Assigned(MatParentInst) And (Not MatParentInst^.MatrixDirty) Then Begin
          // Parent is ready — build child now
          BuildInstanceMatrices(MatPassInst^, @MatParentInst^.MV, @MatParentInst^.NM);
        End Else Begin
          // Parent not ready yet — will be handled in a later pass
          MatPassDone := False;
        End;
      End;
    End;
    Inc(MatPassCount);
  Until MatPassDone Or (MatPassCount >= MaxHierarchyDepth);

  For si := 0 To Integer(SlotCount) - 1 Do Begin
    Inst := pSP_ModelInstance(@SceneBank^.Memory[si * SizeOf(TSP_ModelInstance)]);
    If Not Inst^.Active  Then Continue;
    If Not Inst^.Visible Then Continue;

    ModelIdx := SP_FindBankID(Inst^.BankID);
    If ModelIdx < 0 Then Continue;
    ModelBank := SP_BankList[ModelIdx];
    If ModelBank^.DataType <> SP_MODEL_BANK Then Continue;
    If Length(ModelBank^.Info) < SizeOf(TSP_ModelHeader) Then Continue;

    Hdr := pSP_ModelHeader(@ModelBank^.Info[0]);

    If (Hdr^.Flags And SP3D_FLAG_DIRTY) <> 0 Then Begin
      SP_Model_Build(Inst^.BankID, Error);
      If Error.Code <> SP_ERR_OK Then Begin Error.Code := SP_ERR_OK; Continue; End;
      Hdr := pSP_ModelHeader(@ModelBank^.Info[0]);
      Inst^.MatrixDirty := True;
    End;
    If (Hdr^.Flags And SP3D_FLAG_BUILT) = 0 Then Continue;

    If Hdr^.FaceCount = 0 Then Begin
      // Point cloud — add to render order (rendered after transform below)
      SP3D_InstOrder[InstOrderCount]    := si;
      SP3D_InstModelIdx[InstOrderCount] := ModelIdx;
      SP3D_InstDistArr[InstOrderCount]  := 1e30;   // always rendered last
      Inc(InstOrderCount);
      Continue;
    End;

    // Frustum cull: transform bounding sphere centre to camera space
    TransformPos(Hdr^.BSX, Hdr^.BSY, Hdr^.BSZ, Inst^.MV, BSCx, BSCy, BSCz);
    BSCr := Hdr^.BSRadius * Inst^.Scale;
    FrustumOK := True;
    For si2 := 0 To 5 Do
      If FP[si2][0]*BSCx + FP[si2][1]*BSCy + FP[si2][2]*BSCz + FP[si2][3] < -BSCr Then Begin
        FrustumOK := False;
        Break;
      End;
    If Not FrustumOK Then Continue;

    // Record for distance sort: use camera-space sphere centre Z (negative = in front)
    // Distance = sphere centre Z (smaller = closer)
    SP3D_InstOrder[InstOrderCount]   := si;
    SP3D_InstModelIdx[InstOrderCount] := ModelIdx;
    SP3D_InstDistArr[InstOrderCount] := BSCz - BSCr;  // front edge of sphere
    Inc(InstOrderCount);
  End;

  // Insertion sort instances far->near (N is usually small — 1..50 objects)
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

  // Render instances in sorted order (far first)
  For si := 0 To InstOrderCount - 1 Do Begin
    Inst := pSP_ModelInstance(@SceneBank^.Memory[SP3D_InstOrder[si] * SizeOf(TSP_ModelInstance)]);
    ModelIdx  := SP3D_InstModelIdx[si];
    ModelBank := SP_BankList[ModelIdx];
    Hdr       := pSP_ModelHeader(@ModelBank^.Info[0]);

    VBase := pSP_3DVertex(@ModelBank^.Memory[0]);
    FBase := pSP_3DFace(
               NativeUInt(@ModelBank^.Memory[0]) +
               LongWord(Hdr^.VertexCount) * SizeOf(TSP_3DVertex));

    // Point cloud (no faces) — transform vertices now and render as pixels
    If Hdr^.FaceCount = 0 Then Begin
      vc := Integer(Hdr^.VertexCount);
      If vc > SP3D_TransVertAlloc Then Begin
        SetLength(SP3D_TransVerts, vc);
        SP3D_TransVertAlloc := vc;
      End;
      For vi := 0 To vc - 1 Do
        With pSP_3DVertex(NativeUInt(VBase) + LongWord(vi) * SizeOf(TSP_3DVertex))^ Do
          TransformPos(X, Y, Z, Inst^.MV,
                       SP3D_TransVerts[vi].X,
                       SP3D_TransVerts[vi].Y,
                       SP3D_TransVerts[vi].Z);
      For vi := 0 To vc - 1 Do Begin
        PV := SP3D_TransVerts[vi];
        If PV.Z < SP3D_NEAR_PLANE Then Continue;
        PSX := Round( PV.X / PV.Z * FX + HalfW);
        PSY := Round(-PV.Y / PV.Z * FY + HalfH);
        If (PSX < ClipX1) Or (PSX >= ClipX2) Or
           (PSY < ClipY1) Or (PSY >= ClipY2) Then Continue;
        SrcV := pSP_3DVertex(NativeUInt(VBase) + LongWord(vi)*SizeOf(TSP_3DVertex));
        If SP3D_FogActive Then Begin
          FogT := (PV.Z - SP3D_FogNear) / (SP3D_FogFar - SP3D_FogNear);
          If FogT < 0 Then FogT := 0;  If FogT > 1 Then FogT := 1;
          FogBand := Round(FogT * (SP3D_FOG_BANDS - 1));
          PCol := SP3D_FogTable[SP3D_ShadeTable[SrcV^.Colour, SP3D_SHADE_BANDS-1], FogBand];
        End Else
          PCol := SrcV^.Colour;
        pByte(NativeUInt(SurfPtr) + LongWord(PSY * Stride + PSX))^ := PCol;
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
        SetLength(SP3D_TransNormals, vc);
        SP3D_TransNormAlloc := vc;
      End;
      For vi := 0 To vc - 1 Do
        With pSP_3DVertex(NativeUInt(VBase) + LongWord(vi) * SizeOf(TSP_3DVertex))^ Do
          TransformDir(NX, NY, NZ, Inst^.NM,
                       SP3D_TransNormals[vi].NX,
                       SP3D_TransNormals[vi].NY,
                       SP3D_TransNormals[vi].NZ);
    End;

    fc := Integer(Hdr^.FaceCount);
    IsWireframe := (Inst^.InstFlags And SP3D_FLAG_WIREFRAME) <> 0;
    If IsWireFrame Then Begin
      If fc > SP3D_FaceIsFrontAlloc Then Begin
        SetLength(SP3D_FaceIsFront,   fc);
        SetLength(SP3D_FaceIntenBand, fc);
        SP3D_FaceIsFrontAlloc := fc;
      End;
      FillChar(SP3D_FaceIsFront[0],   fc, 0);
      FillChar(SP3D_FaceIntenBand[0], fc, 0);
      // Cull-only pass: compute front-face flags without gathering render faces
      For fi := 0 To Integer(Hdr^.FaceCount) - 1 Do Begin
        Face := pSP_3DFace(NativeUInt(FBase) + LongWord(fi) * SizeOf(TSP_3DFace));
        // Clip test
        V0X := SP3D_TransVerts[Face^.V0].X;
        V0Y := SP3D_TransVerts[Face^.V0].Y;
        V0Z := SP3D_TransVerts[Face^.V0].Z;
        V1X := SP3D_TransVerts[Face^.V1].X;
        V1Y := SP3D_TransVerts[Face^.V1].Y;
        V1Z := SP3D_TransVerts[Face^.V1].Z;
        V2X := SP3D_TransVerts[Face^.V2].X;
        V2Y := SP3D_TransVerts[Face^.V2].Y;
        V2Z := SP3D_TransVerts[Face^.V2].Z;

        If (V0Z < SP3D_NEAR_PLANE) And
           (V1Z < SP3D_NEAR_PLANE) And
           (V2Z < SP3D_NEAR_PLANE) Then Continue;
        If V0Z < SP3D_NEAR_PLANE Then V0Z := SP3D_NEAR_PLANE;
        If V1Z < SP3D_NEAR_PLANE Then V1Z := SP3D_NEAR_PLANE;
        If V2Z < SP3D_NEAR_PLANE Then V2Z := SP3D_NEAR_PLANE;

        SX0 := Round( V0X / V0Z * FX + HalfW);  SY0 := Round(-V0Y / V0Z * FY + HalfH);
        SX1 := Round( V1X / V1Z * FX + HalfW);  SY1 := Round(-V1Y / V1Z * FY + HalfH);
        SX2 := Round( V2X / V2Z * FX + HalfW);  SY2 := Round(-V2Y / V2Z * FY + HalfH);
        E1X := SX1 - SX0;  E1Y := SY1 - SY0;
        E2X := SX2 - SX0;  E2Y := SY2 - SY0;
        Cross := E1X * E2Y - E1Y * E2X;
        SP3D_FaceIsFront[fi] := Cross > 0;
        // Compute intensity for edge shading
        DotN := -(Face^.NX * SP3D_Light_DX +
                  Face^.NY * SP3D_Light_DY +
                  Face^.NZ * SP3D_Light_DZ);
        If DotN < 0 Then DotN := 0;
        Inten := SP3D_Light_Ambient + (1.0 - SP3D_Light_Ambient) * DotN;
        SP3D_FaceIntenBand[fi] := Round(Inten * (SP3D_SHADE_BANDS - 1));
        If SP3D_FaceIntenBand[fi] > SP3D_SHADE_BANDS - 1 Then
          SP3D_FaceIntenBand[fi] := SP3D_SHADE_BANDS - 1;
      End;
    End Else Begin
      LastDispTexBank := -1;
      LastDispGfxInfo := Nil;
      For fi := 0 To Integer(Hdr^.FaceCount) - 1 Do Begin
        Face := pSP_3DFace(NativeUInt(FBase) + LongWord(fi) * SizeOf(TSP_3DFace));

        If (Face^.Flags And SP3D_FACE_TEXTURED) <> 0 Then Begin
          CV[0].U := Face^.U0;  CV[0].V := Face^.Vt0;
          CV[1].U := Face^.U1;  CV[1].V := Face^.Vt1;
          CV[2].U := Face^.U2;  CV[2].V := Face^.Vt2;
        End;

        CV[0].X := SP3D_TransVerts[Face^.V0].X;  CV[0].Y := SP3D_TransVerts[Face^.V0].Y;  CV[0].Z := SP3D_TransVerts[Face^.V0].Z;
        CV[1].X := SP3D_TransVerts[Face^.V1].X;  CV[1].Y := SP3D_TransVerts[Face^.V1].Y;  CV[1].Z := SP3D_TransVerts[Face^.V1].Z;
        CV[2].X := SP3D_TransVerts[Face^.V2].X;  CV[2].Y := SP3D_TransVerts[Face^.V2].Y;  CV[2].Z := SP3D_TransVerts[Face^.V2].Z;

        NTri := ClipTriNear(CV[0], CV[1], CV[2], SP3D_NEAR_PLANE, T1, T2);
        If NTri = 0 Then Continue;

        GC0 := 0; GC1 := 0; GC2 := 0;
        BASEC0 := 0; BASEC1 := 0; BASEC2 := 0;
        GouraudUniform := False; GouraudFaceLUT := nil;
        If Inst^.Billboard Then Begin
          // Billboard always fully lit from camera direction
          Inten := SP3D_Light_Ambient + (1.0 - SP3D_Light_Ambient);  // = 1.0
          WNX := 0;  WNY := 0;  WNZ := -1;
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
              BaseC0 := ARGBToPalIdx(ResolveVertexColour(Colour, (Flags And SP3D_VERTEX_DEFAULTCOLOUR) <> 0, Face^.Colour, Inst));
            With pSP_3DVertex(NativeUInt(VBase) + LongWord(Face^.V1)*SizeOf(TSP_3DVertex))^ Do
              BaseC1 := ARGBToPalIdx(ResolveVertexColour(Colour, (Flags And SP3D_VERTEX_DEFAULTCOLOUR) <> 0, Face^.Colour, Inst));
            With pSP_3DVertex(NativeUInt(VBase) + LongWord(Face^.V2)*SizeOf(TSP_3DVertex))^ Do
              BaseC2 := ARGBToPalIdx(ResolveVertexColour(Colour, (Flags And SP3D_VERTEX_DEFAULTCOLOUR) <> 0, Face^.Colour, Inst));
            If SP3D_Light_Active Then Begin
              VDot := -(SP3D_TransNormals[Face^.V0].NX * SP3D_Light_DX +
                        SP3D_TransNormals[Face^.V0].NY * SP3D_Light_DY +
                        SP3D_TransNormals[Face^.V0].NZ * SP3D_Light_DZ);
              If VDot < 0 Then VDot := 0;
              VInten := SP3D_Light_Ambient + (1.0 - SP3D_Light_Ambient) * VDot;
            End Else VInten := 1.0;
            GC0 := Round(VInten * 15);  If GC0 > 15 Then GC0 := 15;

            If SP3D_Light_Active Then Begin
              VDot := -(SP3D_TransNormals[Face^.V1].NX * SP3D_Light_DX +
                        SP3D_TransNormals[Face^.V1].NY * SP3D_Light_DY +
                        SP3D_TransNormals[Face^.V1].NZ * SP3D_Light_DZ);
              If VDot < 0 Then VDot := 0;
              VInten := SP3D_Light_Ambient + (1.0 - SP3D_Light_Ambient) * VDot;
            End Else VInten := 1.0;
            GC1 := Round(VInten * 15);  If GC1 > 15 Then GC1 := 15;

            If SP3D_Light_Active Then Begin
              VDot := -(SP3D_TransNormals[Face^.V2].NX * SP3D_Light_DX +
                        SP3D_TransNormals[Face^.V2].NY * SP3D_Light_DY +
                        SP3D_TransNormals[Face^.V2].NZ * SP3D_Light_DZ);
              If VDot < 0 Then VDot := 0;
              VInten := SP3D_Light_Ambient + (1.0 - SP3D_Light_Ambient) * VDot;
            End Else VInten := 1.0;
            GC2 := Round(VInten * 15);  If GC2 > 15 Then GC2 := 15;

            GouraudUniform := (BaseC0 = BaseC1) And (BaseC1 = BaseC2);
            GouraudFaceLUT := Nil;
          End;
        End;

        HasTex  := False;
        TexData := Nil;
        TexW    := 0;
        TexH    := 0;
        If (Face^.Flags And SP3D_FACE_TEXTURED) <> 0 Then Begin
          GfxErr.Code := SP_ERR_OK;
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
          GFXInfo := Nil;

        For t := 0 To NTri - 1 Do Begin
          If t = 0 Then CT := T1 Else CT := T2;
          If CT[0].Z < SP3D_NEAR_PLANE Then CT[0].Z := SP3D_NEAR_PLANE;
          If CT[1].Z < SP3D_NEAR_PLANE Then CT[1].Z := SP3D_NEAR_PLANE;
          If CT[2].Z < SP3D_NEAR_PLANE Then CT[2].Z := SP3D_NEAR_PLANE;
          SX0 := Round( CT[0].X / CT[0].Z * FX + HalfW);  SY0 := Round(-CT[0].Y / CT[0].Z * FY + HalfH);
          SX1 := Round( CT[1].X / CT[1].Z * FX + HalfW);  SY1 := Round(-CT[1].Y / CT[1].Z * FY + HalfH);
          SX2 := Round( CT[2].X / CT[2].Z * FX + HalfW);  SY2 := Round(-CT[2].Y / CT[2].Z * FY + HalfH);
          E1X := SX1 - SX0;  E1Y := SY1 - SY0;
          E2X := SX2 - SX0;  E2Y := SY2 - SY0;
          Cross := E1X * E2Y - E1Y * E2X;

          If Not Inst^.Billboard Then Begin
            If Cross <= 0 Then Continue;
          End;

          AvgCZ := (CT[0].Z + CT[1].Z + CT[2].Z) * 0.33333;
          If SP3D_FogActive Then Begin
            FogT := (AvgCZ - SP3D_FogNear) / (SP3D_FogFar - SP3D_FogNear);
            If FogT < 0 Then FogT := 0;  If FogT > 1 Then FogT := 1;
            FogBand := Round(FogT * (SP3D_FOG_BANDS - 1));
          End Else
            FogBand := 0;
          If RFCount >= SP3D_RFacesAlloc Then Begin
            Inc(SP3D_RFacesAlloc, 4096);
            SetLength(SP3D_RFaces, SP3D_RFacesAlloc);
            SetLength(SP3D_GouraudLUTBuf, SP3D_RFacesAlloc * 256);
          End;
          RF := @SP3D_RFaces[RFCount];
          // Y-sort screen verts + Gouraud attributes so the LUT key matches the
          // rasterizer's own vertex order (top -> mid -> bottom by screen Y).
          // This is the missing implementation referred to by the SortGC/SortBC vars.
          If (Face^.Flags And SP3D_FACE_GOURAUD) <> 0 Then Begin
            SortGC0 := GC0;  SortGC1 := GC1;  SortGC2 := GC2;
            SortBC0 := BaseC0;  SortBC1 := BaseC1;  SortBC2 := BaseC2;
            If SY0 > SY1 Then Begin SwapI(SX0,SX1); SwapI(SY0,SY1); SwapB(SortGC0,SortGC1); SwapB(SortBC0,SortBC1); End;
            If SY0 > SY2 Then Begin SwapI(SX0,SX2); SwapI(SY0,SY2); SwapB(SortGC0,SortGC2); SwapB(SortBC0,SortBC2); End;
            If SY1 > SY2 Then Begin SwapI(SX1,SX2); SwapI(SY1,SY2); SwapB(SortGC1,SortGC2); SwapB(SortBC1,SortBC2); End;
            If Not GouraudUniform Then
              GouraudFaceLUT := GetGouraudLUT(SortBC0, SortBC1, SortBC2);
          End;
          RF^.SX[0] := SX0;  RF^.SY[0] := SY0;
          RF^.SX[1] := SX1;  RF^.SY[1] := SY1;
          RF^.SX[2] := SX2;  RF^.SY[2] := SY2;
          RF^.AvgCZ   := AvgCZ;
          RF^.FogBand := FogBand;
          RF^.Gouraud        := (Face^.Flags And SP3D_FACE_GOURAUD) <> 0;
          RF^.GouraudUniform := GouraudUniform;
          If RF^.Gouraud Then Begin
            RF^.GC[0] := SortGC0;    // Y-sorted intensity bands
            RF^.GC[1] := SortGC1;
            RF^.GC[2] := SortGC2;
            If Not GouraudUniform Then Begin
              RF^.GouraudLUTIdx := SP3D_GouraudLUTCount;
              Move(GouraudFaceLUT^, SP3D_GouraudLUTBuf[SP3D_GouraudLUTCount * 256], 256);
              Inc(SP3D_GouraudLUTCount);
            End Else
              RF^.GouraudLUTIdx := -1;
            If GouraudUniform Then RF^.Colour := BaseC0;
          End;
          If HasTex Then Begin
            RF^.Textured  := True;
            RF^.TexData   := TexData;
            RF^.TexW      := TexW;  RF^.TexH := TexH;
            RF^.TexWMask  := IfThen((TexW And (TexW-1)) = 0, TexW-1, -1);
            RF^.TexHMask  := IfThen((TexH And (TexH-1)) = 0, TexH-1, -1);
            RF^.TranspIdx := Integer(GfxInfo^.Transparent);
            RF^.TexBankID := Face^.TexBank;
            RF^.IntenBand := Round(Inten * (SP3D_SHADE_BANDS - 1));
            If RF^.IntenBand > SP3D_SHADE_BANDS-1 Then RF^.IntenBand := SP3D_SHADE_BANDS-1;
            RF^.SU[0]  := (TexW - 1 - CT[0].U) / CT[0].Z;
            RF^.SU[1]  := (TexW - 1 - CT[1].U) / CT[1].Z;
            RF^.SU[2]  := (TexW - 1 - CT[2].U) / CT[2].Z;
            RF^.SVt[0] := CT[0].V / CT[0].Z;  RF^.SW[0] := 1.0 / CT[0].Z;
            RF^.SVt[1] := CT[1].V / CT[1].Z;  RF^.SW[1] := 1.0 / CT[1].Z;
            RF^.SVt[2] := CT[2].V / CT[2].Z;  RF^.SW[2] := 1.0 / CT[2].Z;
          End Else Begin
            RF^.Textured  := False;
            RF^.TranspIdx := -1;
            If Not RF^.Gouraud Then
              RF^.Colour := ShadedIndex(ARGBToPalIdx(ResolveColour(Face^.Colour, (Face^.Flags And SP3D_FACE_DEFAULTCOLOUR) <> 0, Inst)), Inten);
          End;
          // Select the correct 8bpp rasteriser for this face.
          // All the information we need is already set on RF at this point.
          If RF^.Textured Then Begin
            If RF^.TexWMask >= 0 Then Begin
              // Power-of-2 texture
              If RF^.TranspIdx >= 0 Then Begin
                If RF^.FogBand > 0 Then RF^.Raster8 := RasterTexPow2Transp8Fog
                Else                    RF^.Raster8 := RasterTexPow2Transp8;
              End Else Begin
                If RF^.FogBand > 0 Then RF^.Raster8 := RasterTexPow2Opaque8Fog
                Else                    RF^.Raster8 := RasterTexPow2Opaque8;
              End;
            End Else Begin
              // Non-power-of-2 texture
              If RF^.TranspIdx >= 0 Then Begin
                If RF^.FogBand > 0 Then RF^.Raster8 := RasterTexNPOTTransp8Fog
                Else                    RF^.Raster8 := RasterTexNPOTTransp8;
              End Else Begin
                If RF^.FogBand > 0 Then RF^.Raster8 := RasterTexNPOTOpaque8Fog
                Else                    RF^.Raster8 := RasterTexNPOTOpaque8;
              End;
            End;
          End Else If RF^.Gouraud Then Begin
            If RF^.GouraudUniform Then Begin
              If RF^.FogBand > 0 Then RF^.Raster8 := RasterGouraudUniform8Fog
              Else                    RF^.Raster8 := RasterGouraudUniform8;
            End Else Begin
              If RF^.FogBand > 0 Then RF^.Raster8 := RasterGouraudFull8Fog
              Else                    RF^.Raster8 := RasterGouraudFull8;
            End;
          End Else Begin
            // Flat shaded
            If RF^.FogBand > 0 Then RF^.Raster8 := RasterFlat8Fog
            Else                    RF^.Raster8 := RasterFlat8;
          End;

          Inc(RFCount);
        End;
      End;

      If RFCount - RFStart > 1 Then SortFaces_Range(SP3D_RFaces, RFStart, RFCount - 1);
      RFStart := RFCount;
    End;

    // Wireframe pass
    If IsWireframe Then Begin
      IsSolid := (Inst^.InstFlags And SP3D_FLAG_WIRE_SOLID) <> 0;
      DoCull  := (Inst^.InstFlags And SP3D_FLAG_WIRE_NOCULL) = 0;
      EBase   := pSP_3DEdge(
                   NativeUInt(@ModelBank^.Memory[0]) +
                   LongWord(Hdr^.VertexCount) * SizeOf(TSP_3DVertex) +
                   LongWord(Hdr^.FaceCount)   * SizeOf(TSP_3DFace));

      If IsSolid Then Begin // Solid fill the face first so objects behind are obscured
        For fi := 0 To Integer(Hdr^.FaceCount) - 1 Do Begin
          If Not SP3D_FaceIsFront[fi] Then Continue;
          Face := pSP_3DFace(NativeUInt(FBase) + LongWord(fi) * SizeOf(TSP_3DFace));
          V0X := SP3D_TransVerts[Face^.V0].X;  V0Y := SP3D_TransVerts[Face^.V0].Y;  V0Z := SP3D_TransVerts[Face^.V0].Z;
          V1X := SP3D_TransVerts[Face^.V1].X;  V1Y := SP3D_TransVerts[Face^.V1].Y;  V1Z := SP3D_TransVerts[Face^.V1].Z;
          V2X := SP3D_TransVerts[Face^.V2].X;  V2Y := SP3D_TransVerts[Face^.V2].Y;  V2Z := SP3D_TransVerts[Face^.V2].Z;
          If V0Z < SP3D_NEAR_PLANE Then V0Z := SP3D_NEAR_PLANE;
          If V1Z < SP3D_NEAR_PLANE Then V1Z := SP3D_NEAR_PLANE;
          If V2Z < SP3D_NEAR_PLANE Then V2Z := SP3D_NEAR_PLANE;
          SX0 := Round( V0X / V0Z * FX + HalfW);  SY0 := Round(-V0Y / V0Z * FY + HalfH);
          SX1 := Round( V1X / V1Z * FX + HalfW);  SY1 := Round(-V1Y / V1Z * FY + HalfH);
          SX2 := Round( V2X / V2Z * FX + HalfW);  SY2 := Round(-V2Y / V2Z * FY + HalfH);
          RF := @SP3D_RFaces[RFCount];
          RF^.SX[0] := SX0; RF^.SY[0] := SY0;
          RF^.SX[1] := SX1; RF^.SY[1] := SY1;
          RF^.SX[2] := SX2; RF^.SY[2] := SY2;
          RF^.Colour := ARGBToPalIdx(CPAPER);
          RF^.FogBand := 0;
          RasterFlat8(RF, SurfPtr, Stride, ClipX1, ClipY1, ClipX2, ClipY2);
        End;
      End;

      For ei := 0 To Integer(Hdr^.EdgeCount) - 1 Do Begin
        Edge := pSP_3DEdge(NativeUInt(EBase) + LongWord(ei) * SizeOf(TSP_3DEdge));

        // Culling: draw only if at least one adjacent face is front-facing
        If DoCull Then Begin
          WireVisible := False;
          If (Edge^.F0 >= 0) And (Edge^.F0 < SP3D_FaceIsFrontAlloc) Then
            If SP3D_FaceIsFront[Edge^.F0] Then WireVisible := True;
          If (Edge^.F1 >= 0) And (Edge^.F1 < SP3D_FaceIsFrontAlloc) Then
            If SP3D_FaceIsFront[Edge^.F1] Then WireVisible := True;
          If Not WireVisible Then Continue;
        End;

        // Colour: edge colour shaded by average of adjacent front-face intensities
        SrcVtx     := pSP_3DVertex(NativeUInt(VBase) + LongWord(Edge^.V0) * SizeOf(TSP_3DVertex));
        WireColour := ARGBToPalIdx(ResolveColour(SrcVtx^.Colour, (SrcVtx^.Flags And SP3D_VERTEX_DEFAULTCOLOUR) <> 0, Inst));
        WireInten  := SP3D_SHADE_BANDS - 1;
        If SP3D_Light_Active Then Begin
          BandSum   := 0;
          BandCount := 0;
          If Edge^.F0 >= 0 Then Begin
            Inc(BandSum, SP3D_FaceIntenBand[Edge^.F0]);
            Inc(BandCount);
          End;
          If Edge^.F1 >= 0 Then Begin
            Inc(BandSum, SP3D_FaceIntenBand[Edge^.F1]);
            Inc(BandCount);
          End;
          If BandCount > 0 Then
            WireInten := BandSum Div BandCount
          Else
            WireInten := SP3D_SHADE_BANDS - 1;
        End;
        WireColour := SP3D_ShadeTable[WireColour, WireInten];

        // Camera-space endpoints (already pre-transformed for this instance)
        ECX0 := SP3D_TransVerts[Edge^.V0].X;
        ECY0 := SP3D_TransVerts[Edge^.V0].Y;
        ECZ0 := SP3D_TransVerts[Edge^.V0].Z;
        ECX1 := SP3D_TransVerts[Edge^.V1].X;
        ECY1 := SP3D_TransVerts[Edge^.V1].Y;
        ECZ1 := SP3D_TransVerts[Edge^.V1].Z;

        // Near-plane clip
        If ECZ0 < SP3D_NEAR_PLANE Then Begin
          If ECZ1 < SP3D_NEAR_PLANE Then Continue;  // both behind — skip
          // V0 behind, V1 in front — clip V0 to near plane
          ClipT := (SP3D_NEAR_PLANE - ECZ0) / (ECZ1 - ECZ0);
          ECX0  := ECX0 + ClipT * (ECX1 - ECX0);
          ECY0  := ECY0 + ClipT * (ECY1 - ECY0);
          ECZ0  := SP3D_NEAR_PLANE;
        End Else If ECZ1 < SP3D_NEAR_PLANE Then Begin
          // V1 behind, V0 in front — clip V1 to near plane
          ClipT := (SP3D_NEAR_PLANE - ECZ0) / (ECZ1 - ECZ0);
          ECX1  := ECX0 + ClipT * (ECX1 - ECX0);
          ECY1  := ECY0 + ClipT * (ECY1 - ECY0);
          ECZ1  := SP3D_NEAR_PLANE;
        End;

        // Project to screen
        ESX0 := Round( ECX0 / ECZ0 * FX + HalfW);
        ESY0 := Round(-ECY0 / ECZ0 * FY + HalfH);
        ESX1 := Round( ECX1 / ECZ1 * FX + HalfW);
        ESY1 := Round(-ECY1 / ECZ1 * FY + HalfH);

        SP_DrawLineTo(ESX0, ESY0, ESX1, ESY1, WireColour);
      End;
    End;

  End;

  // No global sort needed — instances are already in far->near order,
  // and faces within each instance are sorted.

  ASYNC := True;
  If ThreadCount = -1 Then Begin
    ThreadCount := 1;
    ASYNC := False;
  End;

  SP_3D_RenderBands(SurfPtr, Stride, ThreadCount, ClipX1, ClipY1, ClipX2, ClipY2, ASYNC, 8, RFCount);
  SP_InvalidateWholeDisplay;

  If (WindowID >= 0) And (SavedBank <> WindowID) Then
    SP_SetDrawingWindow(SavedBank);

End;

// ===========================================================================
// Render thread pool
// ===========================================================================

Constructor TSP3D_RenderThread.Create;
Begin
  StartEvent := TEvent.Create(Nil, False, False, '');
  Terminate_ := False;
  FParams    := Nil;
  FreeOnTerminate := False;
  Inherited Create(False); // Last — thread starts executing immediately
End;

Destructor TSP3D_RenderThread.Destroy;
Begin
  StartEvent.Free;
  Inherited Destroy;
End;

Procedure TSP3D_RenderThread.AssignBand(Params: pSP3D_RenderBandParams);
Begin
  FParams := Params;
End;

Procedure TSP3D_RenderThread.Execute;
Var fi: Integer;
Begin
  NameThreadForDebugging('Render thread');
  While Not Terminate_ Do Begin
    StartEvent.WaitFor(INFINITE);
    If Terminate_ Then Break;

    If Assigned(FParams) Then Begin
      If FParams^.BitDepth = 32 Then Begin
        For fi := 0 To FParams^.RFaceCount - 1 Do
          If Assigned(SP3D_RFaces[fi].Raster32) Then
            SP3D_RFaces[fi].Raster32(
              @SP3D_RFaces[fi],
              FParams^.SurfPtr, FParams^.Stride,
              FParams^.ClipX1, FParams^.ClipY1,
              FParams^.ClipX2, FParams^.ClipY2);
      End Else Begin
        For fi := 0 To FParams^.RFaceCount - 1 Do
          If Assigned(SP3D_RFaces[fi].Raster8) Then
            SP3D_RFaces[fi].Raster8(
              @SP3D_RFaces[fi],
              FParams^.SurfPtr, FParams^.Stride,
              FParams^.ClipX1, FParams^.ClipY1,
              FParams^.ClipX2, FParams^.ClipY2);
      End;
      FParams^.Done := True;
    End;

    If AtomicDecrement(SP3D_BandsRemaining) = 0 Then
      SP3D_AllBandsDone.SetEvent;
  End;
End;

// ---------------------------------------------------------------------------
// SP_3D_EnsureThreadPool
// ---------------------------------------------------------------------------

Procedure SP_3D_EnsureThreadPool(NumThreads: Integer);
Var i: Integer;
Begin
  If NumThreads > SP3D_MAX_RENDER_THREADS Then
    NumThreads := SP3D_MAX_RENDER_THREADS;
  For i := 0 To NumThreads - 1 Do
    If Not Assigned(SP3D_RenderThreads[i]) Then
      SP3D_RenderThreads[i] := TSP3D_RenderThread.Create;
  If SP3D_ThreadCount < NumThreads Then
    SP3D_ThreadCount := NumThreads;
End;

// ---------------------------------------------------------------------------
// SP_3D_RenderBands
// ---------------------------------------------------------------------------

Procedure SP_3D_RenderBands(SurfPtr: pByte; Stride, NumThreads, ClipX1, ClipY1, ClipX2, ClipY2: Integer; IsAsync: Boolean; BitDepth: Integer; AFaceCount: Integer);
Var
  i, BandHeight, BandY1, BandY2 : Integer;
  TotalHeight                    : Integer;
  ActualThreads                  : Integer;
Begin

  // Ensure any previous async render is complete before starting a new one
  If Assigned(SP3D_AllBandsDone) Then
    SP3D_AllBandsDone.WaitFor(INFINITE);

  If NumThreads > SP3D_MAX_RENDER_THREADS Then NumThreads := SP3D_MAX_RENDER_THREADS;
  If NumThreads < 1 Then NumThreads := 1;

  If IsAsync And (NUmThreads <= 1) Then Begin
    IsAsync := False;
    NumThreads := 1;
  End;

  SP_3D_EnsureThreadPool(NumThreads);

  TotalHeight   := ClipY2 - ClipY1;
  BandHeight    := (TotalHeight + NumThreads - 1) Div NumThreads;
  ActualThreads := NumThreads;

  // Count actual threads needed — some bands may be empty if screen is small
  For i := NumThreads - 1 Downto 1 Do
    If ClipY1 + i * BandHeight >= ClipY2 Then
      Dec(ActualThreads)
    Else
      Break;

  // Reset done event and set counter
  If Not Assigned(SP3D_AllBandsDone) Then
    SP3D_AllBandsDone := TEvent.Create(Nil, True, True, '');
  SP3D_AllBandsDone.ResetEvent;
  SP3D_BandsRemaining := ActualThreads;

  For i := 0 To NumThreads - 1 Do Begin
    BandY1 := ClipY1 + i * BandHeight;
    BandY2 := BandY1 + BandHeight;
    If BandY2 > ClipY2 Then BandY2 := ClipY2;
    If BandY1 >= ClipY2 Then Continue;  // Empty band — skip

    SP3D_RenderBandParams[i].SurfPtr    := SurfPtr;
    SP3D_RenderBandParams[i].Stride     := Stride;
    SP3D_RenderBandParams[i].ClipX1     := ClipX1;
    SP3D_RenderBandParams[i].ClipY1     := BandY1;
    SP3D_RenderBandParams[i].ClipX2     := ClipX2;
    SP3D_RenderBandParams[i].ClipY2     := BandY2;
    SP3D_RenderBandParams[i].RFaceCount := AFaceCount;
    SP3D_RenderBandParams[i].BitDepth   := BitDepth;
    SP3D_RenderBandParams[i].Done       := False;

    SP3D_RenderThreads[i].AssignBand(@SP3D_RenderBandParams[i]);
    SP3D_RenderThreads[i].StartEvent.SetEvent;
  End;

  If Not IsAsync Then
    SP3D_AllBandsDone.WaitFor(INFINITE);
End;

// ---------------------------------------------------------------------------
// SP_3D_RenderSync
// ---------------------------------------------------------------------------

Procedure SP_3D_RenderSync;
Begin
  If Assigned(SP3D_AllBandsDone) Then
    SP3D_AllBandsDone.WaitFor(INFINITE);
End;

// ===========================================================================
// Public: bank deletion hook
// ===========================================================================

Procedure SP_3D_OnDeleteBank(BankID, DataType: Integer);
Var i: Integer;
Begin
  If DataType = SP_MODEL_BANK Then Begin
    If BankID = -1 Then Begin
      SP_3D_ResetState;
    End Else Begin
      i := FindBuildState(BankID);
      If i >= 0 Then FreeBuildState(i);
    End;
  End;

  If DataType = SP_SCENE_BANK Then Begin
    If BankID = -1 Then Begin
      SP_3D_ResetState;
    End Else Begin
      If SP3D_ActiveScene = BankID Then
        SP3D_ActiveScene := -1;
    End;
  End;
End;

Procedure SP_3D_ResetState;
Var
  i: Integer;
Begin
  // Thread pool teardown
  For i := 0 To SP3D_MAX_RENDER_THREADS - 1 Do
    If Assigned(SP3D_RenderThreads[i]) Then Begin
      SP3D_RenderThreads[i].Terminate_ := True;
      SP3D_RenderThreads[i].StartEvent.SetEvent;
      SP3D_RenderThreads[i].WaitFor;
      FreeAndNil(SP3D_RenderThreads[i]);
    End;
  SP3D_ThreadCount      := 0;
  SP3D_BandsRemaining   := 0;

  // Recreate completion event
  FreeAndNil(SP3D_AllBandsDone);
  SP3D_AllBandsDone := TEvent.Create(Nil, True, True, '');

  // Reset all other 3D globals
  SP3D_ActiveScene      := -1;
  SP3D_Cam_X            := 0;  SP3D_Cam_Y       := 0;  SP3D_Cam_Z   := 0;
  SP3D_Cam_RX           := 0;  SP3D_Cam_RY      := 0;  SP3D_Cam_RZ  := 0;
  SP3D_Cam_FOV          := 60.0;
  SP3D_CamDirty         := False;
  SP3D_Light_DX         := 0;  SP3D_Light_DY    := -1; SP3D_Light_DZ := 0;
  SP3D_Light_Ambient    := 0.25;
  SP3D_Light_Active     := False;
  SP3D_Light_R          := 1.0;  SP3D_Light_G := 1.0;  SP3D_Light_B := 1.0;
  SP3D_FogActive        := False;
  SP3D_FogNear          := 5.0;
  SP3D_FogFar           := 20.0;
  SP3D_FogColour        := 0;
  SP3D_ShadeDirty       := True;
  SP3D_FogDirty         := True;
  SP3D_LUTCacheDirty    := True;
  SP3D_LUTCacheNext     := 0;
  SP3D_BlendDirty       := True;
  SP3D_RFacesAlloc      := 0;
  SP3D_TransVertAlloc   := 0;
  SP3D_ViewMatrixOK     := False;
  SP3D_InstOrderAlloc   := 0;
  SP3D_FaceIsFrontAlloc := 0;
  SP3D_TransNormAlloc   := 0;
  SP3D_GouraudLUTCount  := 0;
  SP3D_NextInstID       := 0;
  SP3D_NEAR_PLANE       := 0.1;
  SetLength(SP_ModelBuildStates, 0);
  SetLength(SP3D_RFaces, 0);
  SetLength(SP3D_TransVerts, 0);
  SetLength(SP3D_TransNormals, 0);
  SetLength(SP3D_InstOrder, 0);
  SetLength(SP3D_InstModelIdx, 0);
  SetLength(SP3D_InstDistArr, 0);
  SetLength(SP3D_GouraudLUTBuf, 0);
  SetLength(SP3D_FaceIsFront, 0);
  SetLength(SP3D_FaceIntenBand, 0);
  FillChar(SP3D_PalCache,   SizeOf(SP3D_PalCache),   0);
  FillChar(SP3D_ColourCube, SizeOf(SP3D_ColourCube),  0);
End;

// ===========================================================================
// Bank filing — scene banks (SP_SCENE_BANK)
// ===========================================================================

// SP_3D_SaveSceneToINI
// Writes all active instances in the scene to INI sections 'Instance 0',
// 'Instance 1', ... Fields map 1:1 to TSP_ModelInstance members.
// MatrixDirty and the cached MV/NM matrices are intentionally NOT saved;
// they are always rebuilt on load via SP_3D_Scene_PostLoad.

Procedure SP_3D_SaveSceneToINI(INI: TAnsiStringList; Bank: pSP_Bank);
Var
  Hdr        : pSP_SceneHeader;
  n, i       : Integer;
  ActiveCount: Integer;
  WriteIdx   : Integer;
  Inst       : pSP_ModelInstance;
  Sect       : aString;
Begin
  INIWriteString(INI, 'Bank Info', 'Bank Type', 'Scene Bank');
  Hdr := pSP_SceneHeader(@Bank^.Info[0]);
  n   := Integer(Hdr^.SlotCount);
  // Count active slots only, for the header value in the file
  ActiveCount := 0;
  For i := 0 To n - 1 Do
    If pSP_ModelInstance(@Bank^.Memory[i * SizeOf(TSP_ModelInstance)])^.Active Then
      Inc(ActiveCount);
  INIWriteInt(INI, 'Info', 'SlotCount', ActiveCount);
  INIWriteFloat(INI, 'Camera', 'X',    Hdr^.Cam_X);
  INIWriteFloat(INI, 'Camera', 'Y',    Hdr^.Cam_Y);
  INIWriteFloat(INI, 'Camera', 'Z',    Hdr^.Cam_Z);
  INIWriteFloat(INI, 'Camera', 'RX',   Hdr^.Cam_RX);
  INIWriteFloat(INI, 'Camera', 'RY',   Hdr^.Cam_RY);
  INIWriteFloat(INI, 'Camera', 'RZ',   Hdr^.Cam_RZ);
  INIWriteFloat(INI, 'Camera', 'FOV',  Hdr^.Cam_FOV);
  INIWriteFloat(INI, 'Camera', 'Near', Hdr^.Cam_Near);
  WriteIdx := 0;
  For i := 0 To n - 1 Do Begin
    Inst := pSP_ModelInstance(@Bank^.Memory[i * SizeOf(TSP_ModelInstance)]);
    If Not Inst^.Active Then Continue;
    Sect := 'Instance ' + IntToString(WriteIdx);
    INIWriteInt  (INI, Sect, 'ID',               Inst^.ID);
    INIWriteInt  (INI, Sect, 'BankID',            Inst^.BankID);
    INIWriteBool (INI, Sect, 'Visible',           Inst^.Visible);
    INIWriteFloat(INI, Sect, 'X',                 Inst^.X);
    INIWriteFloat(INI, Sect, 'Y',                 Inst^.Y);
    INIWriteFloat(INI, Sect, 'Z',                 Inst^.Z);
    INIWriteFloat(INI, Sect, 'RX',                Inst^.RX);
    INIWriteFloat(INI, Sect, 'RY',                Inst^.RY);
    INIWriteFloat(INI, Sect, 'RZ',                Inst^.RZ);
    INIWriteFloat(INI, Sect, 'Scale',             Inst^.Scale);
    INIWriteBool (INI, Sect, 'Billboard',         Inst^.Billboard);
    INIWriteLong (INI, Sect, 'ColourOverride',    Inst^.ColourOverride);
    INIWriteBool (INI, Sect, 'UseColourOverride', Inst^.UseColourOverride);
    INIWriteInt  (INI, Sect, 'AnimFrameA',        Inst^.AnimFrameA);
    INIWriteInt  (INI, Sect, 'AnimFrameB',        Inst^.AnimFrameB);
    INIWriteFloat(INI, Sect, 'AnimT',             Inst^.AnimT);
    INIWriteFloat(INI, Sect, 'AnimSpeed',         Inst^.AnimSpeed);
    INIWriteBool (INI, Sect, 'AnimPlaying',       Inst^.AnimPlaying);
    INIWriteInt  (INI, Sect, 'ParentID',          Inst^.ParentID);
    INIWriteLong (INI, Sect, 'InstFlags',         Inst^.InstFlags);
    Inc(WriteIdx);
  End;
End;

// SP_3D_LoadSceneFromINI
// Restores a scene bank from INI text. Allocates Memory for SlotCount
// instances and fills them from the 'Instance N' sections.
// MatrixDirty is forced True for all instances; SP_3D_Scene_PostLoad
// advances SP3D_NextInstID past any loaded instance IDs.

Procedure SP_3D_LoadSceneFromINI(INI: TAnsiStringList; Bank: pSP_Bank);
Var
  n    : Integer;
  i    : Integer;
  Hdr  : TSP_SceneHeader;
  Inst : pSP_ModelInstance;
  Sect : aString;
Begin
  Bank^.DataType := SP_SCENE_BANK;
  n := INIReadInt(INI, 'Info', 'SlotCount', 0);
  Hdr.SlotCount := LongWord(n);
  Hdr.Cam_X    := INIReadFloat(INI, 'Camera', 'X',    0.0);
  Hdr.Cam_Y    := INIReadFloat(INI, 'Camera', 'Y',    0.0);
  Hdr.Cam_Z    := INIReadFloat(INI, 'Camera', 'Z',    0.0);
  Hdr.Cam_RX   := INIReadFloat(INI, 'Camera', 'RX',   0.0);
  Hdr.Cam_RY   := INIReadFloat(INI, 'Camera', 'RY',   0.0);
  Hdr.Cam_RZ   := INIReadFloat(INI, 'Camera', 'RZ',   0.0);
  Hdr.Cam_FOV  := INIReadFloat(INI, 'Camera', 'FOV',  60.0);
  Hdr.Cam_Near := INIReadFloat(INI, 'Camera', 'Near', 0.1);
  SetLength(Bank^.Info, SizeOf(TSP_SceneHeader));
  Move(Hdr, Bank^.Info[0], SizeOf(TSP_SceneHeader));
  SetLength(Bank^.Memory, n * SizeOf(TSP_ModelInstance));
  If n > 0 Then FillChar(Bank^.Memory[0], Length(Bank^.Memory), 0);
  For i := 0 To n - 1 Do Begin
    Inst := pSP_ModelInstance(@Bank^.Memory[i * SizeOf(TSP_ModelInstance)]);
    Sect := 'Instance ' + IntToString(i);
    Inst^.ID               := INIReadInt  (INI, Sect, 'ID',               0);
    Inst^.BankID           := INIReadInt  (INI, Sect, 'BankID',           -1);
    Inst^.Active           := True;   // only active instances are saved
    Inst^.Visible          := INIReadBool (INI, Sect, 'Visible',          True);
    Inst^.X                := INIReadFloat(INI, Sect, 'X',                0);
    Inst^.Y                := INIReadFloat(INI, Sect, 'Y',                0);
    Inst^.Z                := INIReadFloat(INI, Sect, 'Z',                0);
    Inst^.RX               := INIReadFloat(INI, Sect, 'RX',               0);
    Inst^.RY               := INIReadFloat(INI, Sect, 'RY',               0);
    Inst^.RZ               := INIReadFloat(INI, Sect, 'RZ',               0);
    Inst^.Scale            := INIReadFloat(INI, Sect, 'Scale',            1.0);
    Inst^.Billboard        := INIReadBool (INI, Sect, 'Billboard',        False);
    Inst^.ColourOverride   := INIReadLong (INI, Sect, 'ColourOverride',   0);
    Inst^.UseColourOverride:= INIReadBool (INI, Sect, 'UseColourOverride',False);
    Inst^.AnimFrameA       := INIReadInt  (INI, Sect, 'AnimFrameA',       -1);
    Inst^.AnimFrameB       := INIReadInt  (INI, Sect, 'AnimFrameB',       -1);
    Inst^.AnimT            := INIReadFloat(INI, Sect, 'AnimT',            0);
    Inst^.AnimSpeed        := INIReadFloat(INI, Sect, 'AnimSpeed',        0);
    Inst^.AnimPlaying      := INIReadBool (INI, Sect, 'AnimPlaying',      False);
    Inst^.ParentID         := INIReadInt  (INI, Sect, 'ParentID',         -1);
    Inst^.InstFlags        := INIReadLong (INI, Sect, 'InstFlags',        0);
    Inst^.MatrixDirty      := True;
  End;
End;

// SP_3D_Scene_PostLoad
// Called after a scene bank is placed in SP_BankList (both binary and text
// load paths). Marks all instance matrices dirty and advances SP3D_NextInstID
// past any IDs already present, preventing future ID collisions.

Procedure SP_3D_Scene_PostLoad(Bank: pSP_Bank);
Var
  n     : LongWord;
  i     : Integer;
  Inst  : pSP_ModelInstance;
  RawID : Integer;
Begin
  n := SceneSlotCount(Bank);
  For i := 0 To Integer(n) - 1 Do Begin
    Inst := pSP_ModelInstance(@Bank^.Memory[i * SizeOf(TSP_ModelInstance)]);
    If Not Inst^.Active Then Continue;
    Inst^.MatrixDirty := True;
    // Strip INSTANCE_MASK and advance the counter past this ID
    RawID := Inst^.ID And $7FFFFFFF;
    If RawID >= SP3D_NextInstID Then
      SP3D_NextInstID := RawID + 1;
    RestoreCameraFromScene(Bank^.ID);
  End;
End;

// ===========================================================================
// Bank filing — model banks (SP_MODEL_BANK)
// ===========================================================================

// SP_3D_SaveModelToINI
// Saves the vertex array and face array as compact hex blobs, plus the
// user-settable model flags and any animation frame data.
// Edges and the poly directory are NOT saved — they are derived data
// that SP_Model_Build recomputes from vertices and faces on first render.

Procedure SP_3D_SaveModelToINI(INI: TAnsiStringList; Bank: pSP_Bank);
Var
  Hdr       : pSP_ModelHeader;
  VC, FC    : Integer;
  VBytes    : Integer;
  Dir       : pSP3D_FrameDir;
  Entry     : pSP3D_FrameDir;
  fi, j     : Integer;
  FrameName : aString;
  UserFlags : LongWord;
  FBase     : pSP_3DFace;
  Face      : pSP_3DFace;
  TexList   : aString;
  TexID     : Integer;
  AlreadySeen: Array[0..1023] of Boolean;   // enough for any realistic texture count
  SeenCount : Integer;
Begin
  INIWriteString(INI, 'Bank Info', 'Bank Type', 'Model Bank');
  Hdr := pSP_ModelHeader(@Bank^.Info[0]);
  VC  := Integer(Hdr^.VertexCount);
  FC  := Integer(Hdr^.FaceCount);
  // Preserve only the user-settable flags across save/load
  UserFlags := Hdr^.Flags And (SP3D_FLAG_SMOOTH Or SP3D_FLAG_WIREFRAME Or
                                SP3D_FLAG_WIRE_NOCULL Or SP3D_FLAG_WIRE_SOLID);
  INIWriteInt (INI, 'Info', 'VertexCount', VC);
  INIWriteInt (INI, 'Info', 'FaceCount',   FC);
  INIWriteLong(INI, 'Info', 'Flags',       UserFlags);
  INIWriteInt (INI, 'Info', 'FrameCount',  Integer(Hdr^.FrameCount));
  VBytes := VC * SizeOf(TSP_3DVertex);
  // Vertex and face data — raw hex blobs
  INIWriteString(INI, 'Data', 'Vertices',
    RawHexDump(@Bank^.Memory[0], VBytes));
  INIWriteString(INI, 'Data', 'Faces',
    RawHexDump(pByte(NativeUInt(@Bank^.Memory[0]) + LongWord(VBytes)),
               FC * SizeOf(TSP_3DFace)));
  // Informational: list every distinct graphic bank ID referenced by textured
  // faces. Ignored on load; tells the user which banks must exist beforehand.
  If FC > 0 Then Begin
    FillChar(AlreadySeen, SizeOf(AlreadySeen), 0);
    FBase   := pSP_3DFace(NativeUInt(@Bank^.Memory[0]) + LongWord(VBytes));
    TexList   := '';
    SeenCount := 0;
    For fi := 0 To FC - 1 Do Begin
      Face := pSP_3DFace(NativeUInt(FBase) + LongWord(fi) * SizeOf(TSP_3DFace));
      TexID := Face^.TexBank;
      If (TexID >= 0) And (TexID < Length(AlreadySeen)) And Not AlreadySeen[TexID] Then Begin
        AlreadySeen[TexID] := True;
        If SeenCount > 0 Then TexList := TexList + ',';
        TexList := TexList + IntToString(TexID);
        Inc(SeenCount);
      End;
    End;
    If TexList <> '' Then
      INIWriteString(INI, 'Referenced Banks', 'Textures', TexList);
  End;
  // Animation frames: name + per-frame vertex positions
  If Hdr^.FrameCount > 0 Then Begin
    Dir := pSP3D_FrameDir(NativeUInt(@Bank^.Info[0]) + SizeOf(TSP_ModelHeader));
    For fi := 0 To Integer(Hdr^.FrameCount) - 1 Do Begin
      Entry := pSP3D_FrameDir(NativeUInt(Dir) + LongWord(fi) * SizeOf(TSP3D_FrameDir));
      FrameName := '';
      For j := 0 To SP3D_FRAME_NAME_LEN - 1 Do Begin
        If Entry^.Name[j] = #0 Then Break;
        FrameName := FrameName + aChar(Entry^.Name[j]);
      End;
      INIWriteString(INI, 'Frame ' + IntToString(fi), 'Name', FrameName);
      INIWriteString(INI, 'Frame ' + IntToString(fi), 'Verts',
        RawHexDump(@Bank^.Memory[Entry^.Offset], VC * SizeOf(TSP3D_FrameVert)));
    End;
  End;
End;

// SP_3D_LoadModelFromINI
// Restores vertex and face data into Bank^.Memory and fills Bank^.Info
// with a TSP_ModelHeader. SP3D_FLAG_DIRTY is set so the engine rebuilds
// edges, normals, and the poly directory on first render.
// SP_3D_Model_PostLoad then reconstructs the build state from Memory.

Procedure SP_3D_LoadModelFromINI(INI: TAnsiStringList; Bank: pSP_Bank);
Var
  VC, FC, FrameCount : Integer;
  Hdr       : TSP_ModelHeader;
  UserFlags : LongWord;
  VBytes, FBytes  : Integer;
  VBuf, FBuf      : aString;
  FVBytes, DirBytes: Integer;
  OldMemLen : Integer;
  FrameBase : LongWord;
  DirEntry  : pSP3D_FrameDir;
  fi, j     : Integer;
  FrameName : aString;
  FVBuf     : aString;
  NameLen   : Integer;
  t: aString;
Begin
  Bank^.DataType := SP_MODEL_BANK;
  VC         := INIReadInt (INI, 'Info', 'VertexCount', 0);
  FC         := INIReadInt (INI, 'Info', 'FaceCount',   0);
  UserFlags  := INIReadLong(INI, 'Info', 'Flags',       0);
  FrameCount := INIReadInt (INI, 'Info', 'FrameCount',  0);
  VBytes := VC * SizeOf(TSP_3DVertex);
  FBytes := FC * SizeOf(TSP_3DFace);
  // Load vertex and face data
  SetLength(Bank^.Memory, VBytes + FBytes);
  t := INIReadString(INI, 'Data', 'Vertices', '');
  VBuf := ReadRawHex(t);
  t := INIReadString(INI, 'Data', 'Faces',    '');
  FBuf := ReadRawHex(t);
  If (VC > 0) And (Length(VBuf) >= VBytes) Then
    CopyMem(@Bank^.Memory[0], @VBuf[1], VBytes);
  If (FC > 0) And (Length(FBuf) >= FBytes) Then
    CopyMem(@Bank^.Memory[VBytes], @FBuf[1], FBytes);
  // Build header — DIRTY flag forces a full rebuild on first render
  FillChar(Hdr, SizeOf(Hdr), 0);
  Hdr.VertexCount := LongWord(VC);
  Hdr.FaceCount   := LongWord(FC);
  Hdr.Flags       := UserFlags Or SP3D_FLAG_DIRTY;
  Hdr.FrameCount  := LongWord(FrameCount);
  If FrameCount > 0 Then Begin
    Hdr.Flags := Hdr.Flags Or SP3D_FLAG_HASFRAMES;
    FVBytes   := VC * SizeOf(TSP3D_FrameVert);
    DirBytes  := FrameCount * SizeOf(TSP3D_FrameDir);
    SetLength(Bank^.Info, SizeOf(TSP_ModelHeader) + DirBytes);
    Move(Hdr, Bank^.Info[0], SizeOf(TSP_ModelHeader));
    OldMemLen := Length(Bank^.Memory);
    FrameBase := LongWord(OldMemLen);
    SetLength(Bank^.Memory, OldMemLen + FVBytes * FrameCount);
    For fi := 0 To FrameCount - 1 Do Begin
      DirEntry := pSP3D_FrameDir(
        NativeUInt(@Bank^.Info[0]) + SizeOf(TSP_ModelHeader) +
        LongWord(fi) * SizeOf(TSP3D_FrameDir));
      FillChar(DirEntry^, SizeOf(TSP3D_FrameDir), 0);
      DirEntry^.Offset := FrameBase + LongWord(fi) * LongWord(FVBytes);
      FrameName := INIReadString(INI, 'Frame ' + IntToString(fi), 'Name', '');
      NameLen   := Length(FrameName);
      If NameLen >= SP3D_FRAME_NAME_LEN Then NameLen := SP3D_FRAME_NAME_LEN - 1;
      For j := 0 To NameLen - 1 Do
        DirEntry^.Name[j] := AnsiChar(FrameName[j+1]);
      t := INIReadString(INI, 'Frame ' + IntToString(fi), 'Verts', '');
      FVBuf := ReadRawHex(t);
      If (VC > 0) And (Length(FVBuf) >= FVBytes) Then
        CopyMem(@Bank^.Memory[DirEntry^.Offset], @FVBuf[1], FVBytes);
    End;
    // Refresh FrameCount in the now-committed header
    pSP_ModelHeader(@Bank^.Info[0])^.FrameCount := LongWord(FrameCount);
  End Else Begin
    SetLength(Bank^.Info, SizeOf(TSP_ModelHeader));
    Move(Hdr, Bank^.Info[0], SizeOf(TSP_ModelHeader));
  End;
End;

// SP_3D_Model_PostLoad
// Called after a model bank is placed in SP_BankList (both binary and text
// load paths). Reconstructs the build state from the packed Memory so that
// subsequent SP_Model_SetShading / SP_Model_SetWireframe / SP_Model_Build
// calls work correctly.
// The SP3D_FLAG_DIRTY bit (set by the loader or preserved from the file)
// causes SP_3D_Render to call SP_Model_Build on first use, which will
// recompute normals, edges, bounding sphere, and poly directory.

Procedure SP_3D_Model_PostLoad(Bank: pSP_Bank);
Var
  Hdr    : pSP_ModelHeader;
  VC, FC : Integer;
  VBytes : Integer;
  BSIdx  : Integer;
  Dir    : pSP3D_FrameDir;
  Entry  : pSP3D_FrameDir;
  FVPtr  : pSP3D_FrameVert;
  fi, j  : Integer;
  FName  : aString;
Begin
  If Length(Bank^.Info) < SizeOf(TSP_ModelHeader) Then Exit;
  Hdr := pSP_ModelHeader(@Bank^.Info[0]);
  VC  := Integer(Hdr^.VertexCount);
  FC  := Integer(Hdr^.FaceCount);
  VBytes := VC * SizeOf(TSP_3DVertex);
  // Discard any stale build state and allocate a fresh one
  BSIdx := FindBuildState(Bank^.ID);
  If BSIdx >= 0 Then FreeBuildState(BSIdx);
  BSIdx := AllocBuildState(Bank^.ID);
  // Copy vertices and faces from packed Memory into the build state
  SetLength(SP_ModelBuildStates[BSIdx].Verts, VC);
  If VC > 0 Then
    Move(Bank^.Memory[0], SP_ModelBuildStates[BSIdx].Verts[0], VBytes);
  SetLength(SP_ModelBuildStates[BSIdx].Faces, FC);
  If FC > 0 Then
    Move(Bank^.Memory[VBytes], SP_ModelBuildStates[BSIdx].Faces[0],
         FC * SizeOf(TSP_3DFace));
  // NextPolyIdx: PolyCount is the number of fan-polygons, which equals the
  // highest PolyIdx + 1. After a rebuild the renderer uses this to validate
  // SP_Model_UpdateUV calls.
  SP_ModelBuildStates[BSIdx].NextPolyIdx := Integer(Hdr^.PolyCount);
  // Reconstruct frame scratch arrays so SP_Model_Build can re-pack them
  If Hdr^.FrameCount > 0 Then Begin
    SetLength(SP_ModelBuildStates[BSIdx].Frames, Integer(Hdr^.FrameCount));
    Dir := pSP3D_FrameDir(NativeUInt(@Bank^.Info[0]) + SizeOf(TSP_ModelHeader));
    For fi := 0 To Integer(Hdr^.FrameCount) - 1 Do Begin
      Entry := pSP3D_FrameDir(NativeUInt(Dir) + LongWord(fi) * SizeOf(TSP3D_FrameDir));
      FName := '';
      For j := 0 To SP3D_FRAME_NAME_LEN - 1 Do Begin
        If Entry^.Name[j] = #0 Then Break;
        FName := FName + aChar(Entry^.Name[j]);
      End;
      SP_ModelBuildStates[BSIdx].Frames[fi].Name := FName;
      SetLength(SP_ModelBuildStates[BSIdx].Frames[fi].Verts, VC);
      FVPtr := pSP3D_FrameVert(@Bank^.Memory[Entry^.Offset]);
      For j := 0 To VC - 1 Do
        With SP_ModelBuildStates[BSIdx].Frames[fi].Verts[j] Do Begin
          X := pSP3D_FrameVert(NativeUInt(FVPtr) + LongWord(j)*SizeOf(TSP3D_FrameVert))^.X;
          Y := pSP3D_FrameVert(NativeUInt(FVPtr) + LongWord(j)*SizeOf(TSP3D_FrameVert))^.Y;
          Z := pSP3D_FrameVert(NativeUInt(FVPtr) + LongWord(j)*SizeOf(TSP3D_FrameVert))^.Z;
        End;
    End;
  End;
  // Ensure SP3D_FLAG_DIRTY is set so the first render rebuilds the bank
  Hdr^.Flags := (Hdr^.Flags Or SP3D_FLAG_DIRTY) And Not SP3D_FLAG_BUILT;
End;

// ===========================================================================
// Bank filing — hook dispatch (registered in Initialization)
// ===========================================================================

Procedure SP_3D_SaveBankHook(INI: TAnsiStringList; Bank: pSP_Bank);
Begin
  If Bank^.DataType = SP_MODEL_BANK Then
    SP_3D_SaveModelToINI(INI, Bank)
  Else If Bank^.DataType = SP_SCENE_BANK Then
    SP_3D_SaveSceneToINI(INI, Bank);
End;

Procedure SP_3D_LoadBankHook(BankType: aString; INI: TAnsiStringList; Bank: pSP_Bank);
Begin
  If BankType = 'Model Bank' Then
    SP_3D_LoadModelFromINI(INI, Bank)
  Else If BankType = 'Scene Bank' Then
    SP_3D_LoadSceneFromINI(INI, Bank);
End;

Procedure SP_3D_PostLoadHook(Bank: pSP_Bank);
Begin
  If Bank^.DataType = SP_MODEL_BANK Then
    SP_3D_Model_PostLoad(Bank)
  Else If Bank^.DataType = SP_SCENE_BANK Then
    SP_3D_Scene_PostLoad(Bank);
End;

Initialization

  // Register bank filing hooks so SP_BankFiling can save/load/restore
  // model and scene banks without a circular unit dependency.
  SP_3D_Hook_SaveBank := SP_3D_SaveBankHook;
  SP_3D_Hook_LoadBank := SP_3D_LoadBankHook;
  SP_3D_Hook_PostLoad := SP_3D_PostLoadHook;

  FillChar(SP3D_RenderThreads, SizeOf(SP3D_RenderThreads), 0);
  SP_3D_ResetState;

  For ci := 0 To 255 Do
    For band := 0 To SP3D_FOG_BANDS - 1 Do
      SP3D_FogTable[ci, band] := ci;

  // Precompute barycentric weight triples for all 256 LUT grid positions.
  // W0+W1+W2 = 15 always. For i+j <= 15: exact. For i+j > 15: clamp to edge.
  For ci := 0 To 15 Do
    For band := 0 To 15 Do Begin
      If ci + band <= 15 Then Begin
        SP3D_GouraudWeights[ci*16+band].W0 := Byte(15 - ci - band);
        SP3D_GouraudWeights[ci*16+band].W1 := Byte(ci);
        SP3D_GouraudWeights[ci*16+band].W2 := Byte(band);
      End Else Begin
        SP3D_GouraudWeights[ci*16+band].W0 := 0;
        SP3D_GouraudWeights[ci*16+band].W1 := Byte(Round(ci * 15.0 / (ci + band)));
        SP3D_GouraudWeights[ci*16+band].W2 := Byte(15 - SP3D_GouraudWeights[ci*16+band].W1);
      End;
    End;

Finalization
  FreeAndNil(SP3D_AllBandsDone);

End.
