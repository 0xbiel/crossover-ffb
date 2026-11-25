/* Original MIT-licensed DirectInput8 bridge: a virtual G29/G923 fed by the native
 * crossover-ffb app over shared memory, whose force-feedback effects the app
 * plays on the real wheel. Other devices pass through to the system dinput8.
 * Win32/Win64 ABI declarations checked against public DirectInput interfaces; no
 * upstream implementation copied. */
typedef unsigned int U32;
typedef int HR;
typedef unsigned short U16;
typedef unsigned long long U64;
typedef __UINTPTR_TYPE__ UPTR;
typedef void *PTR;
#ifdef __i386__
#define STDCALL __attribute__((stdcall))
#else
#define STDCALL
#endif
#define INVALID_HANDLE ((PTR)(~(UPTR)0))
typedef struct {
    U32 a;
    U16 b, c;
    unsigned char d[8];
} GUID;
_Static_assert(sizeof(GUID) == 16 && sizeof(U32) == 4 && sizeof(PTR) == sizeof(UPTR) &&
                   (sizeof(PTR) == 4 || sizeof(PTR) == 8),
               "Win32/Win64 ABI");
static U64 udiv64(U64 n, U64 d) {
#ifdef __i386__
    U64 q = 0, r = 0;
    for (int i = 63; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) {
            r -= d;
            q |= 1ull << i;
        }
    }
    return q;
#else
    return n / d;
#endif
}
static long long sdiv64(long long n, long long d) {
#ifdef __i386__
    int neg = (n < 0) ^ (d < 0);
    U64 an = n < 0 ? 0ull - (U64)n : (U64)n;
    U64 ad = d < 0 ? 0ull - (U64)d : (U64)d;
    U64 q = udiv64(an, ad);
    return neg ? -(long long)q : (long long)q;
#else
    return n / d;
#endif
}
#define OK ((HR)0)
#define NOINTERFACE ((HR)0x80004002u)
#define POINTER ((HR)0x80004003u)
#define INVALID ((HR)0x80070057u)
#define UNSUPPORTED ((HR)0x80004001u)
#define NOAGGREGATION ((HR)0x80040110u)
static const GUID iidA = {0xbf798030, 0x483a, 0x4da2, {0xaa, 0x99, 0x5d, 0x64, 0xed, 0x36, 0x97, 0}};
static const GUID iidW = {0xbf798031, 0x483a, 0x4da2, {0xaa, 0x99, 0x5d, 0x64, 0xed, 0x36, 0x97, 0}};
static const GUID iidUnknown = {0, 0, 0, {0xc0, 0, 0, 0, 0, 0, 0, 0x46}};
static int same(const GUID *a, const GUID *b) {
    if (!a || !b)
        return 0;
    const unsigned char *x = (const void *)a, *y = (const void *)b;
    for (int i = 0; i < 16; i++)
        if (x[i] != y[i])
            return 0;
    return 1;
}
static U32 text(char *b, U32 n, const char *s) {
    while (*s && n < 470)
        b[n++] = *s++;
    return n;
}
static U32 hex(char *b, U32 n, U64 v, int digits) {
    const char *h = "0123456789abcdef";
    for (int i = digits - 1; i >= 0; i--)
        b[n++] = h[(v >> (i * 4)) & 15];
    return n;
}
#ifdef CFB_TEST
extern void test_log(const char *, U32, const GUID *);
#define event test_log
#else
#define IMPORT __declspec(dllimport)
IMPORT U32 STDCALL GetModuleFileNameW(PTR, U16 *, U32);
IMPORT PTR STDCALL CreateFileW(const U16 *, U32, U32, PTR, U32, U32, PTR);
IMPORT int STDCALL WriteFile(PTR, const void *, U32, U32 *, PTR);
IMPORT int STDCALL CloseHandle(PTR);
IMPORT int STDCALL GetFileSizeEx(PTR, long long *);
IMPORT U32 STDCALL GetCurrentProcessId(void);
IMPORT U64 STDCALL GetTickCount64(void);
IMPORT int STDCALL DisableThreadLibraryCalls(PTR);
IMPORT void STDCALL AcquireSRWLockExclusive(UPTR *);
IMPORT void STDCALL ReleaseSRWLockExclusive(UPTR *);
static PTR module;
int STDCALL DllMain(PTR h, U32 reason, PTR reserved) {
    (void)reserved;
    if (reason == 1) {
        module = h;
        DisableThreadLibraryCalls(h);
    }
    return 1;
}
static void event(const char *method, U32 value, const GUID *guid) {
    U16 path[768];
    U32 length = GetModuleFileNameW(module, path, 768);
    if (!length || length >= 700)
        return;
    while (length && path[length - 1] != '\\' && path[length - 1] != '/')
        length--;
    if (!length)
        return;
    const char *leaf = "crossover-ffb-observe.log";
    for (U32 i = 0;; i++) {
        path[length + i] = (U16)leaf[i];
        if (!leaf[i])
            break;
    }
    /* Only this adjacent regular log file is opened, never a device path. */
    PTR file = CreateFileW(path, 4 | 0x80, 3, 0, 4, 0x80, 0);
    if (file == INVALID_HANDLE)
        return;
    long long size = 0;
    if (!GetFileSizeEx(file, &size) || size > 4 * 1024 * 1024) {
        CloseHandle(file);
        return;
    }
    char b[512];
    U32 n = 0, written = 0;
    n = text(b, n, "cfb-bridge-v3 pid=");
    n = hex(b, n, GetCurrentProcessId(), 8);
    n = text(b, n, " ms=");
    n = hex(b, n, GetTickCount64(), 16);
    n = text(b, n, " method=");
    n = text(b, n, method);
    n = text(b, n, " value=0x");
    n = hex(b, n, value, 8);
    if (guid) {
        n = text(b, n, " guid=");
        n = hex(b, n, guid->a, 8);
        b[n++] = '-';
        n = hex(b, n, guid->b, 4);
        b[n++] = '-';
        n = hex(b, n, guid->c, 4);
        b[n++] = '-';
        for (int i = 0; i < 8; i++)
            n = hex(b, n, guid->d[i], 2);
    }
    n = text(b, n, "\r\n");
    WriteFile(file, b, n, &written, 0);
    CloseHandle(file);
}
#endif

#if !defined(CFB_TEST) && !defined(CFB_FAKEWIN)
/* Freestanding aggregate initialization support, no CRT or dynamic loader. */
void *memset(void *p, int value, UPTR n) {
    volatile unsigned char *q = p;
    while (n--)
        *q++ = (unsigned char)value;
    return p;
}
#endif
#include "shm.h"
#include "virtual_abi.h"
#include "virtual_core.h"
