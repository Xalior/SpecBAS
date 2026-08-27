//
// bass.c defines the BASS entry points SpecBAS's link needs, and no more.
//
// SpecBAS loads BASS by hand at start-up and runs silent when the load fails.
// There is no BASS build for this machine and no loader to open one with, so
// SP_SDL2Host sets SoundEnabled False and nothing below is ever called.
//
// The link still needs the symbols: Free Pascal emits a reference wherever a
// call is written, whatever guards it at run time. The desktop build answers
// that with an empty linker script and --unresolved-symbols=ignore-all; a
// bare-metal link has no such escape, and a link that ignores unresolved
// symbols ignores real ones too.
//
// Each answers failure in the terms BASS uses: FALSE, a zero handle, or
// BASS_ERROR_INIT. Arguments are declared for the record and never read.
//

#include <stdint.h>

// BASS's own types, as bass.pas declares them for this target: BOOL is
// LongBool (four bytes), DWORD and its handle aliases are unsigned 32-bit,
// QWORD is unsigned 64-bit.
typedef int32_t  BASS_BOOL;
typedef uint32_t BASS_DWORD;
typedef uint64_t BASS_QWORD;

#define BASS_FALSE       0
#define BASS_NO_HANDLE   0
#define BASS_ERROR_INIT  8

// --- the library, and what went wrong -------------------------------------

BASS_BOOL BASS_Init(int32_t device, BASS_DWORD freq, BASS_DWORD flags,
                    void *win, void *clsid)
{
    (void) device; (void) freq; (void) flags; (void) win; (void) clsid;
    return BASS_FALSE;
}

BASS_BOOL BASS_Free(void)
{
    return BASS_FALSE;
}

BASS_BOOL BASS_SetConfig(BASS_DWORD option, BASS_DWORD value)
{
    (void) option; (void) value;
    return BASS_FALSE;
}

BASS_BOOL BASS_GetInfo(void *info)
{
    (void) info;
    return BASS_FALSE;
}

int32_t BASS_ErrorGetCode(void)
{
    return BASS_ERROR_INIT;
}

// --- samples ---------------------------------------------------------------

BASS_DWORD BASS_SampleCreate(BASS_DWORD length, BASS_DWORD freq,
                             BASS_DWORD chans, BASS_DWORD max,
                             BASS_DWORD flags)
{
    (void) length; (void) freq; (void) chans; (void) max; (void) flags;
    return BASS_NO_HANDLE;
}

BASS_DWORD BASS_SampleLoad(BASS_BOOL mem, void *f, BASS_QWORD offset,
                           BASS_DWORD length, BASS_DWORD max, BASS_DWORD flags)
{
    (void) mem; (void) f; (void) offset; (void) length; (void) max; (void) flags;
    return BASS_NO_HANDLE;
}

BASS_BOOL BASS_SampleFree(BASS_DWORD handle)
{
    (void) handle;
    return BASS_FALSE;
}

BASS_BOOL BASS_SampleGetData(BASS_DWORD handle, void *buffer)
{
    (void) handle; (void) buffer;
    return BASS_FALSE;
}

BASS_BOOL BASS_SampleSetData(BASS_DWORD handle, void *buffer)
{
    (void) handle; (void) buffer;
    return BASS_FALSE;
}

BASS_BOOL BASS_SampleGetInfo(BASS_DWORD handle, void *info)
{
    (void) handle; (void) info;
    return BASS_FALSE;
}

BASS_BOOL BASS_SampleSetInfo(BASS_DWORD handle, void *info)
{
    (void) handle; (void) info;
    return BASS_FALSE;
}

BASS_DWORD BASS_SampleGetChannel(BASS_DWORD handle, BASS_BOOL onlynew)
{
    (void) handle; (void) onlynew;
    return BASS_NO_HANDLE;
}

BASS_BOOL BASS_SampleStop(BASS_DWORD handle)
{
    (void) handle;
    return BASS_FALSE;
}

// --- streams and modules ---------------------------------------------------

BASS_DWORD BASS_StreamCreateFile(BASS_BOOL mem, void *f, BASS_QWORD offset,
                                 BASS_QWORD length, BASS_DWORD flags)
{
    (void) mem; (void) f; (void) offset; (void) length; (void) flags;
    return BASS_NO_HANDLE;
}

BASS_BOOL BASS_StreamFree(BASS_DWORD handle)
{
    (void) handle;
    return BASS_FALSE;
}

BASS_DWORD BASS_MusicLoad(BASS_BOOL mem, void *f, BASS_QWORD offset,
                          BASS_DWORD length, BASS_DWORD flags, BASS_DWORD freq)
{
    (void) mem; (void) f; (void) offset; (void) length; (void) flags; (void) freq;
    return BASS_NO_HANDLE;
}

BASS_BOOL BASS_MusicFree(BASS_DWORD handle)
{
    (void) handle;
    return BASS_FALSE;
}

// --- channels --------------------------------------------------------------

BASS_BOOL BASS_ChannelPlay(BASS_DWORD handle, BASS_BOOL restart)
{
    (void) handle; (void) restart;
    return BASS_FALSE;
}

BASS_BOOL BASS_ChannelPause(BASS_DWORD handle)
{
    (void) handle;
    return BASS_FALSE;
}

BASS_BOOL BASS_ChannelStop(BASS_DWORD handle)
{
    (void) handle;
    return BASS_FALSE;
}

// BASS_ACTIVE_STOPPED is 0, which is the honest answer for every handle here.
BASS_DWORD BASS_ChannelIsActive(BASS_DWORD handle)
{
    (void) handle;
    return 0;
}

BASS_BOOL BASS_ChannelGetInfo(BASS_DWORD handle, void *info)
{
    (void) handle; (void) info;
    return BASS_FALSE;
}

BASS_DWORD BASS_ChannelFlags(BASS_DWORD handle, BASS_DWORD flags,
                             BASS_DWORD mask)
{
    (void) handle; (void) flags; (void) mask;
    return 0;
}

BASS_BOOL BASS_ChannelSetAttribute(BASS_DWORD handle, BASS_DWORD attrib,
                                   float value)
{
    (void) handle; (void) attrib; (void) value;
    return BASS_FALSE;
}

BASS_QWORD BASS_ChannelGetLength(BASS_DWORD handle, BASS_DWORD mode)
{
    (void) handle; (void) mode;
    return 0;
}

BASS_QWORD BASS_ChannelGetPosition(BASS_DWORD handle, BASS_DWORD mode)
{
    (void) handle; (void) mode;
    return 0;
}

BASS_BOOL BASS_ChannelSetPosition(BASS_DWORD handle, BASS_QWORD pos,
                                  BASS_DWORD mode)
{
    (void) handle; (void) pos; (void) mode;
    return BASS_FALSE;
}

// These two return in a floating-point register, so they are written as they
// are declared rather than folded in with the integer answers above: a stub
// returning an int would leave d0 holding whatever was in it.
double BASS_ChannelBytes2Seconds(BASS_DWORD handle, BASS_QWORD pos)
{
    (void) handle; (void) pos;
    return 0.0;
}

BASS_QWORD BASS_ChannelSeconds2Bytes(BASS_DWORD handle, double pos)
{
    (void) handle; (void) pos;
    return 0;
}
