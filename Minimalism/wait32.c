#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* GameMaker Studio expects an x86 C function returning a double. */
__declspec(dllexport) double __cdecl minimalism_wait(void)
{
    Sleep(1);
    return 0.0;
}
