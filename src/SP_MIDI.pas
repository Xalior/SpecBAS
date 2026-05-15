unit SP_MIDI;

// MIDI output support for SpecBAS.
//
// Windows (Delphi and FPC): uses Windows MIDI Mapper via MMSystem.
// Linux (FPC):              uses ALSA raw MIDI via libasound (dynamically loaded).
// macOS (FPC):              stubbed - CoreMIDI support to be added later.
//
// Locking uses TRTLCriticalSection (FPC System unit) to avoid SyncObjs
// visibility issues across platform-conditional compilation blocks.

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$INCLUDE SpecBAS.inc}

interface

Procedure OpenMIDI;
Procedure SendMIDIBytes(Bytes: Array of Byte);
Procedure CloseMIDI;

Var
  MidiOpen: Boolean = False;

implementation

Uses
  SysUtils
  {$IFNDEF FPC}, SyncObjs{$ENDIF}
  {$IFDEF MSWINDOWS}
  , {$IFDEF FPC}Windows, MMSystem{$ELSE}WinAPI.Windows, MMSystem{$ENDIF}
  {$ENDIF}
  {$IFDEF LINUX}
  , dynlibs
  {$ENDIF}
  ;

// TRTLCriticalSection is in FPC's System unit - no extra Uses needed.
// InitCriticalSection / EnterCriticalSection / LeaveCriticalSection /
// DoneCriticalSection are also in System.

Var
  {$IFDEF FPC}
  MIDILock: TRTLCriticalSection;
  {$ELSE}
  MIDILock: TCriticalSection;
  {$ENDIF}

{$IFDEF MSWINDOWS}
// =============================================================================
// Windows - MIDI Mapper via MMSystem (Delphi and FPC identical API)
// =============================================================================

Var
  MidiHandle: HMIDIOUT;

Procedure OpenMIDI;
Var
  Res: Integer;
Begin
  {$IFDEF FPC}
  EnterCriticalSection(MIDILock);
  {$ELSE}
  MIDILock.Enter;
  {$ENDIF}
  Try
    If MidiOpen Then Exit;
    If midiOutGetNumDevs > 0 Then Begin
      Res := midiOutOpen(@MidiHandle, MIDI_MAPPER, 0, 0, CALLBACK_NULL);
      If Res = MMSYSERR_NOERROR Then
        MidiOpen := True;
    End;
  Finally
    {$IFDEF FPC}
    LeaveCriticalSection(MIDILock);
    {$ELSE}
    MIDILock.Leave;
    {$ENDIF}
  End;
End;

Procedure CloseMIDI;
Begin
  {$IFDEF FPC}
  EnterCriticalSection(MIDILock);
  {$ELSE}
  MIDILock.Enter;
  {$ENDIF}
  Try
    If Not MidiOpen Then Exit;
    midiOutClose(MidiHandle);
    MidiOpen := False;
  Finally
    {$IFDEF FPC}
    LeaveCriticalSection(MIDILock);
    {$ELSE}
    MIDILock.Leave;
    {$ENDIF}
  End;
End;

Procedure SendMIDIBytes(Bytes: Array of Byte);
Begin
  If Not MidiOpen Then Exit;
  {$IFDEF FPC}
  EnterCriticalSection(MIDILock);
  {$ELSE}
  MIDILock.Enter;
  {$ENDIF}
  Try
    If MidiOpen Then
      midiOutShortMsg(MidiHandle, pLongWord(@Bytes[0])^);
  Finally
    {$IFDEF FPC}
    LeaveCriticalSection(MIDILock);
    {$ELSE}
    MIDILock.Leave;
    {$ENDIF}
  End;
End;

{$ELSE}
{$IFDEF LINUX}
// =============================================================================
// Linux - ALSA raw MIDI via libasound, dynamically loaded.
// Install with: sudo apt install libasound2
// =============================================================================

Type
  Tsnd_rawmidi_open  = Function(inp, outp: PPointer;
                                name: PAnsiChar;
                                mode: Integer): Integer; cdecl;
  Tsnd_rawmidi_write = Function(rawmidi: Pointer;
                                buffer: Pointer;
                                size: NativeUInt): NativeInt; cdecl;
  Tsnd_rawmidi_drain = Function(rawmidi: Pointer): Integer; cdecl;
  Tsnd_rawmidi_close = Function(rawmidi: Pointer): Integer; cdecl;

Var
  AlsaLib:           TLibHandle = NilHandle;
  AlsaOut:           Pointer    = nil;
  snd_rawmidi_open:  Tsnd_rawmidi_open  = nil;
  snd_rawmidi_write: Tsnd_rawmidi_write = nil;
  snd_rawmidi_drain: Tsnd_rawmidi_drain = nil;
  snd_rawmidi_close: Tsnd_rawmidi_close = nil;

Procedure OpenMIDI;
Begin
  EnterCriticalSection(MIDILock);
  Try
    If MidiOpen Then Exit;
    AlsaLib := LoadLibrary('libasound.so.2');
    If AlsaLib = NilHandle Then
      AlsaLib := LoadLibrary('libasound.so');
    If AlsaLib = NilHandle Then Exit;
    snd_rawmidi_open  := GetProcedureAddress(AlsaLib, 'snd_rawmidi_open');
    snd_rawmidi_write := GetProcedureAddress(AlsaLib, 'snd_rawmidi_write');
    snd_rawmidi_drain := GetProcedureAddress(AlsaLib, 'snd_rawmidi_drain');
    snd_rawmidi_close := GetProcedureAddress(AlsaLib, 'snd_rawmidi_close');
    If Not (Assigned(snd_rawmidi_open) And
            Assigned(snd_rawmidi_write) And
            Assigned(snd_rawmidi_close)) Then Begin
      UnloadLibrary(AlsaLib);
      AlsaLib := NilHandle;
      Exit;
    End;
    If snd_rawmidi_open(nil, @AlsaOut, 'default', 0) < 0 Then
      If snd_rawmidi_open(nil, @AlsaOut, 'hw:0,0', 0) < 0 Then Begin
        UnloadLibrary(AlsaLib);
        AlsaLib := NilHandle;
        AlsaOut := nil;
        Exit;
      End;
    MidiOpen := True;
  Finally
    LeaveCriticalSection(MIDILock);
  End;
End;

Procedure CloseMIDI;
Begin
  EnterCriticalSection(MIDILock);
  Try
    If Not MidiOpen Then Exit;
    If Assigned(snd_rawmidi_drain) And (AlsaOut <> nil) Then
      snd_rawmidi_drain(AlsaOut);
    If Assigned(snd_rawmidi_close) And (AlsaOut <> nil) Then
      snd_rawmidi_close(AlsaOut);
    AlsaOut := nil; MidiOpen := False;
    snd_rawmidi_open := nil; snd_rawmidi_write := nil;
    snd_rawmidi_drain := nil; snd_rawmidi_close := nil;
    If AlsaLib <> NilHandle Then Begin
      UnloadLibrary(AlsaLib); AlsaLib := NilHandle;
    End;
  Finally
    LeaveCriticalSection(MIDILock);
  End;
End;

Procedure SendMIDIBytes(Bytes: Array of Byte);
Begin
  If Not MidiOpen Then Exit;
  EnterCriticalSection(MIDILock);
  Try
    If MidiOpen And Assigned(snd_rawmidi_write) And (AlsaOut <> nil) Then
      snd_rawmidi_write(AlsaOut, @Bytes[0], Length(Bytes));
  Finally
    LeaveCriticalSection(MIDILock);
  End;
End;

{$ELSE}
// =============================================================================
// macOS / all other platforms - stubs
// =============================================================================

Procedure OpenMIDI;   Begin End;
Procedure CloseMIDI;  Begin End;
Procedure SendMIDIBytes(Bytes: Array of Byte); Begin End;

{$ENDIF} // LINUX
{$ENDIF} // WINDOWS

// =============================================================================
// Shared initialisation / finalisation
// =============================================================================

Initialization
  {$IFDEF FPC}
  InitCriticalSection(MIDILock);
  {$ELSE}
  MIDILock := TCriticalSection.Create;
  {$ENDIF}

Finalization
  If MidiOpen Then CloseMIDI;
  {$IFDEF FPC}
  DoneCriticalSection(MIDILock);
  {$ELSE}
  MIDILock.Free;
  {$ENDIF}

end.

