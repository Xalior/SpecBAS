unit SP_BASICInterpreter;

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

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}
{$INCLUDE SpecBAS.inc}

// TSP_BASICInterpreter - encapsulates a single BASIC interpreter instance.
// TSP_BASICThread      - the OS thread that runs a secondary instance.
//
// DESIGN
//
//   Primary instance (ID=0)
//     Owns the editor, compiler thread, and SP_Program.  Created by
//     TSpecBAS_Thread in MainForm and runs SP_MainLoop exactly as before.
//     AcquireThreadVars sets CurrentInterpreter and initialises
//     SP_StackPtr/SP_StackStart to point at FStack, the primary's own
//     private evaluation stack.  FPayload is empty.
//
//   Secondary instance (ID>0)
//     Created by SP_Interpret_EXECUTE when the ASYNC flag is set.
//     Receives a compiled payload string (the already-tokenised EXECUTE
//     argument) in FPayload.  SP_LaunchSecondary creates a
//     TSP_BASICThread and starts it; that thread's Execute method calls
//     AcquireThreadVars (which seeds COMMAND_TOKENS, per-thread execution
//     state, and points SP_StackPtr/SP_StackStart at the thread's own
//     FStack), runs the secondary loop, then calls SP_FinalizeThreadVars
//     and ReleaseThreadVars before the thread ends.
//
//   Stack model
//     SP_Stack (the old global array) has been removed entirely.
//     Every interpreter instance - primary or secondary - has its own
//     FStack field.  SP_StackPtr and SP_StackStart are ThreadVar, so each
//     thread navigates only its own stack storage.
//     SP_OptimiseStack on the compiler thread uses a small local array
//     for the duration of each call and saves/restores the ThreadVar slots.
//
//   Shared state
//     SP_Program / SP_Program_Count   - read-only from secondaries.
//       Secondaries may navigate into SP_Program via GO TO, GO SUB, PROC.
//       Program-modifying commands (NEW, DELETE, RUN, LOAD etc.) are
//       blocked on secondaries with SP_ERR_NOT_IN_SECONDARY.
//     NumVars / StrVars / NumArrays / StrArrays - fully shared.
//       This is intentional and documented.  Callers must manage their
//       own variable name hygiene to avoid races.
//     BREAKSIGNAL - global; a single True stops all threads.
//     LOCAL inside PROCs - blocked on secondaries (SP_ERR_NOT_IN_SECONDARY)
//       because the proc-local variable machinery is not thread-safe.
//     ON EVERY / ON MOUSE* / ON KEY* / ON COLLIDE / ON MENU* - blocked on
//       secondaries; event handling belongs to the primary only.
//       ON ERROR is permitted on secondaries (ERROR_LineNum is ThreadVar).
//     INPUT - not blocked, but behaviour with concurrent callers is
//       undefined; document clearly.
//
//   Thread registry
//     SP_RegisterSecondary / SP_UnregisterSecondary maintain a list of
//     live secondary threads under SecondaryLock.
//     SP_WaitForSecondaries spin-yields until all secondaries have exited;
//     called by the primary on STOP, NEW, and clean program end so that
//     the primary never tears down shared state while a secondary is
//     still running.

interface

Uses
  SysUtils, Classes, SyncObjs, SP_Util, SP_Errors, SP_Interpret_PostFix;

Type

  TSP_BASICThread = class;

  TSP_BASICInterpreter = class
  private
    FID:      Integer;
    FPayload: aString;
    FThread:  TSP_BASICThread;
  public
    // Evaluation stack.  Every instance - primary and secondary - owns its
    // own FStack.  SP_StackStart is pointed at FStack[0]-1 in
    // AcquireThreadVars; SP_StackPtr starts there and grows upward.
    // SP_SECONDARY_STACK_DEPTH entries is ample for expression evaluation.
    FStack: Array[0..SP_SECONDARY_STACK_DEPTH - 1] of SP_StackItem;

    constructor Create(AID: Integer; const APayload: aString = '');
    destructor  Destroy; override;

    // AcquireThreadVars - must be called on this interpreter's own thread,
    // before entering the execution loop.
    //   Primary:   sets CurrentInterpreter, initialises SP_StackPtr and
    //              SP_StackStart to point at FStack.  All other threadvar
    //              state is initialised by SP_MainLoop / SP_PreParse.
    //   Secondary: sets CurrentInterpreter, seeds COMMAND_TOKENS from
    //              FPayload, initialises SP_StackPtr/SP_StackStart, and
    //              sets all other per-thread execution state to a clean
    //              slate (GOSUB stack, proc stack, event handler targets,
    //              cursor positions, etc.).
    procedure AcquireThreadVars;

    // ReleaseThreadVars - must be called on this interpreter's own thread,
    // after the execution loop exits and before SP_FinalizeThreadVars.
    // Currently a no-op; reserved for future state-snapshot support.
    procedure ReleaseThreadVars;

    property ID:      Integer           read FID;
    property Payload: aString           read FPayload;
    property Thread:  TSP_BASICThread   read FThread write FThread;
  end;

  // TSP_BASICThread - OS thread wrapper for a secondary interpreter.
  // FreeOnTerminate = True; caller must not free this object.
  TSP_BASICThread = class(TThread)
  private
    FInterpreter: TSP_BASICInterpreter;
  protected
    procedure Execute; override;
  public
    constructor Create(AInterpreter: TSP_BASICInterpreter);
    property Interpreter: TSP_BASICInterpreter read FInterpreter;
  end;

// ---------------------------------------------------------------------------
// Public registry and launch API
// ---------------------------------------------------------------------------

// Launch a secondary interpreter running APayload.  Called from
// SP_Interpret_EXECUTE on the primary thread when the ASYNC flag is set.
procedure SP_LaunchSecondary(const APayload: aString);

// Block (with CB_Yield) until all live secondary threads have exited.
// BREAKSIGNAL must already be set if an immediate stop is desired.
procedure SP_WaitForSecondaries;

// Count of currently live secondary threads.
function  SP_SecondaryCount: Integer;

// Called internally by TSP_BASICThread.Execute - do not call directly.
procedure SP_RegisterSecondary(AThread: TSP_BASICThread);
procedure SP_UnregisterSecondary(AThread: TSP_BASICThread);

// One slot per OS thread.  Set by AcquireThreadVars on the interpreter
// thread; nil on the VCL thread and compiler thread.
ThreadVar
  CurrentInterpreter: TSP_BASICInterpreter;

implementation

Uses
  Types,
  SP_Tokenise,
  SP_SysVars,
  SP_PreRun,
  SP_Main;

// ---------------------------------------------------------------------------
// Registry globals
// ---------------------------------------------------------------------------

Var
  SecondaryLock:     TCriticalSection;
  SecondaryThreads:  TList;
  NextInterpreterID: Integer;

// ---------------------------------------------------------------------------
// TSP_BASICInterpreter
// ---------------------------------------------------------------------------

constructor TSP_BASICInterpreter.Create(AID: Integer; const APayload: aString);
Begin
  Inherited Create;
  FID      := AID;
  FPayload := APayload;
  FThread  := nil;
End;

destructor TSP_BASICInterpreter.Destroy;
Var
  i: Integer;
Begin
  for i := Low(FStack) to High(FStack) do
  Begin
    FStack[i].Str := '';
  End;
  Finalize(fStack);
  Inherited Destroy;
End;

procedure TSP_BASICInterpreter.AcquireThreadVars;
Begin

  CurrentInterpreter := Self;

  // All instances - primary and secondary - point their ThreadVar stack
  // pointers at their own FStack array.
  SP_StackStart := @FStack[0];
  Dec(SP_StackStart);
  SP_StackPtr   := SP_StackStart;

  If FID = 0 Then Exit;  // Primary: stack is ready; everything else is
                          // initialised by SP_MainLoop / SP_PreParse.

  // ------------------------------------------------------------------
  // Secondary instance initialisation.
  // ------------------------------------------------------------------

  COMMAND_TOKENS := FPayload;

  NXTLINE      := -2;
  NXTSTATEMENT := -1;
  NXTST        := 0;

  SP_GOSUB_StackLen := MAXDEPTH;
  SetLength(SP_GOSUB_Stack, SP_GOSUB_StackLen);
  SP_GOSUB_StackPtr := 0;

  SP_ProcStackPtr  := -1;
  SP_CaseListPtr   := -1;

  INPROC             := 0;
  IGNORE_ON_ERROR    := False;
  INCLUDEFROM        := -1;
  BPSIGNAL           := False;

  SP_EveryCount      := 0;
  EveryEnabled       := True;
  IgnoreEvery        := False;
  ReEnableEvery      := False;
  FN_Recursion_Count := 0;
  DoingOnCtrl        := False;
  OnActive           := 0;

  MATHMODE  := 0;
  PRPOSX    := 0;
  PRPOSY    := 0;
  DRPOSX    := 0;
  DRPOSY    := 0;
  DRHEADING := 0;

  ERROR_LineNum     := -1;
  COLLIDE_LineNum   := -1;
  MOUSEDOWN_LineNum := -1;
  MOUSEMOVE_LineNum := -1;
  MOUSEUP_LineNum   := -1;
  KEYDOWN_LineNum   := -1;
  KEYUP_LineNum     := -1;
  WHEELUP_LineNum   := -1;
  WHEELDOWN_LineNum := -1;
  MENUSHOW_lineNum  := -1;
  MENUHIDE_lineNum  := -1;
  MENUITEM_lineNum  := -1;

End;

procedure TSP_BASICInterpreter.ReleaseThreadVars;
Begin
  // Reserved for future state-snapshot support.
  Finalize(fStack);
End;

// ---------------------------------------------------------------------------
// TSP_BASICThread
// ---------------------------------------------------------------------------

constructor TSP_BASICThread.Create(AInterpreter: TSP_BASICInterpreter);
Begin
  Inherited Create(True);
  FInterpreter    := AInterpreter;
  FreeOnTerminate := True;
  AInterpreter.Thread := Self;
End;

procedure TSP_BASICThread.Execute;
Var
  Error:         TSP_ErrorCode;
  Tkns:          aString;
  pTokens:       paString;
  NextStatement: Boolean;
  CurLine:       Integer;
Begin

  NameThreadForDebugging('BASIC Thread #' + IntToStr(FInterpreter.ID));

  SP_RegisterSecondary(Self);
  Try

    FInterpreter.AcquireThreadVars;

    Error.Code       := SP_ERR_OK;
    Error.Line       := -2;
    Error.Statement  := 1;
    Error.Position   := SP_FindStatement(@COMMAND_TOKENS, 1);
    Error.ReturnType := 0;

    Tkns          := COMMAND_TOKENS;
    NextStatement := True;

    While NextStatement And Not (BREAKSIGNAL Or QUITMSG) Do Begin

      NextStatement := False;
      pTokens := @Tkns;
      SP_InterpretCONTSafe(pTokens, Error.Position, Error);

      If (Error.Code <> SP_ERR_OK) Or
         (NXTLINE >= SP_Program_Count) Then Begin
        Break;
      End Else
        If NXTLINE <> -1 Then Begin

          If NXTLINE = -2 Then Begin
            CurLine := -2;
            Tkns    := COMMAND_TOKENS;
            If NXTSTATEMENT = -1 Then Break;
            Error.Position := NXTSTATEMENT;
          End Else Begin
            CurLine := NXTLINE;
            Tkns    := SP_Program[CurLine];
            If NXTSTATEMENT <> -1 Then
              Error.Position := NXTSTATEMENT
            Else Begin
              Error.Statement := 1;
              Error.Position  := SP_FindStatement(@Tkns, 1);
            End;
          End;

          NXTSTATEMENT := -1;
          Inc(NXTLINE);
          If NXTLINE <> 0 Then Begin
            Error.Line    := CurLine;
            NextStatement := True;
          End;

        End;

    End;

    SP_FinalizeThreadVars;
    FInterpreter.ReleaseThreadVars;

  Finally
    SP_UnregisterSecondary(Self);
    FInterpreter.Free;
  End;

End;

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

procedure SP_RegisterSecondary(AThread: TSP_BASICThread);
Begin
  SecondaryLock.Enter;
  SecondaryThreads.Add(AThread);
  SecondaryLock.Leave;
End;

procedure SP_UnregisterSecondary(AThread: TSP_BASICThread);
Begin
  SecondaryLock.Enter;
  SecondaryThreads.Remove(AThread);
  SecondaryLock.Leave;
End;

function SP_SecondaryCount: Integer;
Begin
  SecondaryLock.Enter;
  Result := SecondaryThreads.Count;
  SecondaryLock.Leave;
End;

procedure SP_WaitForSecondaries;
Begin
  While SP_SecondaryCount > 0 Do
    CB_Yield(1);
End;

procedure SP_LaunchSecondary(const APayload: aString);
Var
  ID:          Integer;
  Interpreter: TSP_BASICInterpreter;
  Thread:      TSP_BASICThread;
Begin
  {$IFDEF FPC}
  ID := InterlockedIncrement(NextInterpreterID);
  {$ELSE}
  ID := TInterlocked.Increment(NextInterpreterID);
  {$ENDIF}

  Interpreter := TSP_BASICInterpreter.Create(ID, APayload);
  Thread      := TSP_BASICThread.Create(Interpreter);
  Thread.Start;
End;

// ---------------------------------------------------------------------------

Initialization

  SecondaryLock     := TCriticalSection.Create;
  SecondaryThreads  := TList.Create;
  NextInterpreterID := 0;

Finalization

  SecondaryThreads.Free;
  SecondaryLock.Free;

end.
