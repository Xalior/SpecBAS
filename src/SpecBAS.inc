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
// macOS puts copy, cut, paste and select-all on Command where the rest of the
// world puts them on Control, and SpecBAS reads K_CONTROL for all of them. So
// the Command key arrives as K_CONTROL and the shortcuts work as a Mac user
// expects; the Control key still arrives as K_CONTROL as well, so both do.
// Undefine this to map Command literally to K_LWIN / K_RWIN instead.
{$IFDEF DARWIN}
  {$DEFINE MAC_COMMAND_IS_CONTROL}
{$ENDIF}
//{$DEFINE RUNTIMEONLY}  // passed on command line to build "rt"
//{$DEFINE DEBUGPAYLOAD} // Debugging the compiler
//{$DEFINE RefreshThread}

