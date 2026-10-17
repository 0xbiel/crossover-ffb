/* Shared-memory contract v2 between the native app and this DLL. Layout is
 * documented in bridge/SHARED-MEMORY.md and mirrored by
 * Sources/WheelCore/SharedBridge.swift. All fields little-endian. Each block
 * is guarded by a seqlock counter (odd while its writer is mid-update). */
#define SHM_SIZE 4096u
#define SHM_MAGIC 0x32424643u /* "CFB2" */
#define SHM_VERSION 2u
#define SHM_IN 64u   /* native -> DLL input block */
#define SHM_FF 256u  /* DLL -> native force header */
#define SHM_FX 320u  /* DLL -> native effect records */
#define SHM_FX_SIZE 96u
#define SHM_FX_COUNT 32u
#define INPUT_STALE_MS 500u
#define SHM_FULL 8192u /* app files of this size also carry the telemetry block */
#define SHM_TM 4096u   /* DLL -> native game telemetry block */
#define SHM_TM_DATA 32u
#define SHM_TM_MAX 2048u
_Static_assert(SHM_FX + SHM_FX_SIZE * SHM_FX_COUNT <= SHM_SIZE, "shm layout");

typedef struct {
    U32 axis[4], buttons, hat;
    U64 sequence;
} Snapshot;
static U32 le32(const unsigned char *p) {
    return (U32)p[0] | ((U32)p[1] << 8) | ((U32)p[2] << 16) | ((U32)p[3] << 24);
}
static U64 le64(const unsigned char *p) { return (U64)le32(p) | ((U64)le32(p + 4) << 32); }
static U32 ld32(volatile unsigned char *p) { return __atomic_load_n((volatile U32 *)p, __ATOMIC_ACQUIRE); }
static void st32(volatile unsigned char *p, U32 v) { __atomic_store_n((volatile U32 *)p, v, __ATOMIC_RELAXED); }
static void st64(volatile unsigned char *p, U64 v) { __atomic_store_n((volatile U64 *)p, v, __ATOMIC_RELEASE); }

#ifdef CFB_TEST
extern unsigned char test_shm[SHM_FULL];
static U32 shmBytes = SHM_FULL;
extern U64 test_unix_ms(void);
extern U32 test_pid(void);
static volatile unsigned char *shm_map(void) { return test_shm; }
#define unix_ms test_unix_ms
#define process_id test_pid
#else
IMPORT void GetSystemTimeAsFileTime(U64 *);
IMPORT PTR CreateFileMappingW(PTR, PTR, U32, U32, U32, const U16 *);
IMPORT PTR MapViewOfFile(PTR, U32, U32, U32, U64);
#define process_id GetCurrentProcessId
static U64 unix_ms(void) {
    U64 clock = 0;
    GetSystemTimeAsFileTime(&clock);
    return clock >= 116444736000000000ull ? (clock - 116444736000000000ull) / 10000 : 0;
}
#ifndef CFB_USER_ID
#define CFB_USER_ID 0
#endif
#define CFB_STRING_(x) #x
#define CFB_STRING(x) CFB_STRING_(x)
/* The app's installer rewrites the digits after "CFBUID=" with the Mac user's uid
 * (NUL-padded), so one DLL build works for every user. */
static volatile char uidSlot[24] = "CFBUID=" CFB_STRING(CFB_USER_ID);
static volatile unsigned char *shmView;
static U32 shmBytes; /* SHM_SIZE, or SHM_FULL when the app made room for telemetry */
static U64 shmRetryAt, shmLock;
/* Map the native app's file once. Wine maps writable file views MAP_SHARED, so
 * both processes see each other's stores directly. Retries at most every 500 ms
 * while the app has not created the file yet. */
static volatile unsigned char *shm_map(void) {
    volatile unsigned char *view = __atomic_load_n(&shmView, __ATOMIC_ACQUIRE);
    if (view)
        return view;
    AcquireSRWLockExclusive(&shmLock);
    view = shmView;
    U64 now = GetTickCount64();
    if (!view && now >= shmRetryAt) {
        shmRetryAt = now + 500;
        static const char head[] = "Z:\\tmp\\crossover-ffb-", tail[] = "\\ffb-v2.bin";
        U16 path[128];
        U32 n = 0;
        for (U32 i = 0; head[i]; i++)
            path[n++] = (U16)head[i];
        for (U32 i = 7; i < 17 && uidSlot[i] >= '0' && uidSlot[i] <= '9'; i++)
            path[n++] = (U16)uidSlot[i];
        for (U32 i = 0; i < sizeof(tail); i++)
            path[n++] = (U16)tail[i];
        PTR f = CreateFileW(path, 0xC0000000u, 7, 0, 3, 0x80, 0);
        if (f != (PTR)(~(U64)0)) {
            long long size = 0;
            U32 bytes = GetFileSizeEx(f, &size) ? (size >= SHM_FULL ? SHM_FULL : size >= SHM_SIZE ? SHM_SIZE : 0) : 0;
            PTR mapping = bytes ? CreateFileMappingW(f, 0, 4, 0, bytes, 0) : 0;
            CloseHandle(f);
            if (mapping) {
                view = MapViewOfFile(mapping, 6, 0, 0, bytes);
                CloseHandle(mapping); /* the view keeps the section alive */
                if (view) {
                    shmBytes = bytes;
                    __atomic_store_n(&shmView, view, __ATOMIC_RELEASE);
                    event("SharedMemory_MAPPED", bytes, 0);
                }
            }
        }
    }
    ReleaseSRWLockExclusive(&shmLock);
    return view;
}
#endif

/* Reason codes: 1 no mapping, 2 bad header/torn read, 4 disconnected,
 * 5 clock ahead, 6 stale, 7 invalid payload. */
static int read_snapshot_status(Snapshot *out, U32 *reason) {
    volatile unsigned char *p = shm_map();
    *reason = 1;
    if (!p)
        return 0;
    *reason = 2;
    if (ld32(p) != SHM_MAGIC || ld32(p + 4) != SHM_VERSION)
        return 0;
    unsigned char b[48];
    U32 s1 = 1, s2 = 0;
    for (int tries = 0; tries < 64; tries++) {
        s1 = ld32(p + SHM_IN);
        if (s1 & 1)
            continue;
        for (U32 i = 0; i < sizeof(b); i++)
            b[i] = p[SHM_IN + i];
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        s2 = ld32(p + SHM_IN);
        if (s1 == s2)
            break;
    }
    if (s1 != s2 || (s1 & 1))
        return 0;
    U64 now = unix_ms(), stamp = le64(b + 8);
    if (!le32(b + 4)) {
        *reason = 4;
        return 0;
    }
    if (stamp > now && stamp - now > 2000) {
        *reason = 5;
        return 0;
    }
    if (stamp <= now && now - stamp > INPUT_STALE_MS) {
        *reason = 6;
        return 0;
    }
    Snapshot s;
    for (int i = 0; i < 4; i++)
        s.axis[i] = le32(b + 16 + 4 * i);
    s.buttons = le32(b + 32);
    s.hat = le32(b + 36);
    s.sequence = s1;
    *reason = 7;
    if (s.axis[0] > 65535 || s.axis[1] > 65535 || s.axis[2] > 65535 || s.axis[3] > 65535 ||
        (s.buttons & ~0x1ffffffu) || s.hat > 8)
        return 0;
    *reason = 0;
    *out = s;
    return 1;
}
static int read_snapshot(Snapshot *out) {
    U32 reason;
    return read_snapshot_status(out, &reason);
}

/* Game telemetry for simulated TrueForce: the Kunos physics page is copied raw
 * into the telemetry block whenever its packetId changes. Source 1 = AC/ACC
 * Local\acpmf_physics, 2 = AC EVO Local\acevo_pmf_physics (same 800-byte
 * layout; word 198 is road instead of g vibration). */
#define TM_PHYSICS_BYTES 800u
/* SPageFileStatic.maxRpm (after five 33-wchar name fields, packed to 4 bytes), copied
 * to SHM_TM + 24 so the app can scale the wheel's rev lights. 0 when unknown. */
#define TM_STATIC_MAXRPM 412u
#ifdef CFB_TEST
extern const unsigned char *test_physics(void);
extern const unsigned char *test_static(void);
static U32 physicsSource = 1;
#define physics_view test_physics
#define static_view test_static
#else
IMPORT PTR OpenFileMappingW(U32, int, const U16 *);
static const unsigned char *physicsView;
static U32 physicsSource;
static U64 physicsRetryAt;
static const unsigned char *physics_view(void) {
    if (physicsView)
        return physicsView;
    U64 now = GetTickCount64();
    if (now < physicsRetryAt)
        return 0;
    physicsRetryAt = now + 2000;
    static const char *const names[] = {"Local\\acpmf_physics", "Local\\acevo_pmf_physics"};
    PTR mapping = 0;
    U32 source = 0;
    for (U32 n = 0; n < 2 && !mapping; n++) {
        U16 wide[32];
        U32 i = 0;
        for (; names[n][i]; i++)
            wide[i] = (U16)names[n][i];
        wide[i] = 0;
        mapping = OpenFileMappingW(4, 0, wide);
        source = n + 1;
    }
    if (!mapping)
        return 0;
    const unsigned char *view = MapViewOfFile(mapping, 4, 0, 0, TM_PHYSICS_BYTES);
    CloseHandle(mapping);
    if (view) {
        physicsSource = source;
        physicsView = view;
        event("Telemetry_PHYSICS_SOURCE", source, 0);
    }
    return view;
}
static const unsigned char *staticView;
static U64 staticRetryAt;
static const unsigned char *static_view(void) {
    if (staticView || !physicsSource)
        return staticView;
    U64 now = GetTickCount64();
    if (now < staticRetryAt)
        return 0;
    staticRetryAt = now + 2000;
    const char *name = physicsSource == 2 ? "Local\\acevo_pmf_static" : "Local\\acpmf_static";
    U16 wide[32];
    U32 i = 0;
    for (; name[i]; i++)
        wide[i] = (U16)name[i];
    wide[i] = 0;
    PTR mapping = OpenFileMappingW(4, 0, wide);
    if (!mapping)
        return 0;
    staticView = MapViewOfFile(mapping, 4, 0, 0, TM_STATIC_MAXRPM + 4);
    CloseHandle(mapping);
    if (staticView)
        event("Telemetry_STATIC", physicsSource, 0);
    return staticView;
}
#endif
static U32 lastPhysicsPacket = 0xffffffffu;
static void copy_telemetry(volatile unsigned char *p) {
    if (shmBytes < SHM_FULL)
        return;
    const unsigned char *src = physics_view();
    if (!src)
        return;
    U32 packet = le32(src);
    if (packet == lastPhysicsPacket)
        return;
    lastPhysicsPacket = packet;
    U32 seq = (ld32(p + SHM_TM) + 1) | 1;
    st32(p + SHM_TM, seq);
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    st32(p + SHM_TM + 4, physicsSource);
    st32(p + SHM_TM + 8, TM_PHYSICS_BYTES);
    st64(p + SHM_TM + 16, unix_ms());
    const unsigned char *info = static_view();
    U32 maxRpm = info ? le32(info + TM_STATIC_MAXRPM) : 0;
    static U32 loggedMaxRpm;
    if (maxRpm != loggedMaxRpm) {
        loggedMaxRpm = maxRpm;
        event("Telemetry_MAXRPM", maxRpm, 0);
    }
    st32(p + SHM_TM + 24, maxRpm);
    for (U32 i = 0; i < TM_PHYSICS_BYTES; i += 4)
        st32(p + SHM_TM + SHM_TM_DATA + i, le32(src + i));
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    __atomic_store_n((volatile U32 *)(p + SHM_TM), seq + 1, __ATOMIC_RELEASE);
}
