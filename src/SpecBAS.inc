{$UNDEF LOG}
{$UNDEF RASPI}
{$DEFINE SOUND}
{$IFDEF WIN64}
  {$DEFINE CPU64}
{$ENDIF}
{$IFDEF RELEASE}
  {$WEAKLINKRTTI ON}
{$ENDIF}
{$IFNDEF FPC}
{$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}
{$ENDIF}
{$IF DEFINED(WINDOWS) AND DEFINED(FPC)}
  {$DEFINE OPENGL}
{$ENDIF}
// The SDL2 backend supplies the window, the buffer present, the event queue
// and the frame clock on every target that is not Windows. Windows keeps the
// Lazarus/OpenGL path unchanged.
{$IF DEFINED(FPC) AND NOT DEFINED(WINDOWS)}
  {$DEFINE SDL2}
{$ENDIF}
//{$DEFINE RUNTIMEONLY}  // passed on command line to build "rt"
//{$DEFINE DEBUGPAYLOAD} // Debugging the compiler
//{$DEFINE RefreshThread}

