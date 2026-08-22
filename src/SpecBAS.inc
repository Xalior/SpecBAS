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
// Off Windows the window, the buffer present, the event queue and the frame
// clock come from SDL2 instead of from Lazarus.
{$IF DEFINED(FPC) AND NOT DEFINED(WINDOWS)}
  {$DEFINE SDL2}
{$ENDIF}
// SpecBAS reads K_CONTROL for copy, cut, paste and select-all. macOS puts
// those on Command, so Command delivers K_CONTROL as well and both keys
// work. Undefine to have Command deliver K_LWIN and K_RWIN instead.
{$IFDEF DARWIN}
  {$DEFINE MAC_COMMAND_IS_CONTROL}
{$ENDIF}
//{$DEFINE RUNTIMEONLY}  // passed on command line to build "rt"
//{$DEFINE DEBUGPAYLOAD} // Debugging the compiler
//{$DEFINE RefreshThread}

