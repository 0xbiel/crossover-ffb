/* Offline tests for the DirectInput8 bridge core (host build, fake Win32). */
#include <assert.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CFB_TEST
#include "../observe.c"

unsigned char test_shm[SHM_FULL];
static unsigned char physics[TM_PHYSICS_BYTES];
const unsigned char *test_physics(void) { return physics; }
static unsigned char staticPage[512];
const unsigned char *test_static(void) { return staticPage; }
static U64 nowMs = 1000000, nowTicks = 5000;
static int allocations;
U64 test_unix_ms(void) { return nowMs; }
U32 test_pid(void) { return 4242; }
U64 test_ticks(void) { return nowTicks; }
void test_lock(UPTR *p) {
    while (__atomic_exchange_n(p, 1, __ATOMIC_ACQUIRE))
        sched_yield();
}
void test_unlock(UPTR *p) { __atomic_store_n(p, 0, __ATOMIC_RELEASE); }
void *test_alloc(U32 n) {
    allocations++;
    return calloc(1, n);
}
void test_free(void *p) {
    allocations--;
    free(p);
}
typedef struct { const char *method; U32 value; GUID guid; int hasGuid; } LogLine;
static LogLine logged[64];
static U32 loggedCount;
void test_log(const char *m, U32 v, const GUID *g) {
    if (loggedCount < 64) logged[loggedCount++] = (LogLine){m, v, g ? *g : (GUID){0}, g != 0};
}
static const LogLine *last_logged(const char *method) {
    for (U32 i = loggedCount; i-- > 0;)
        if (strcmp(logged[i].method, method) == 0) return &logged[i];
    return 0;
}

static void put32(U32 off, U32 v) { memcpy(test_shm + off, &v, 4); }
static void put64(U32 off, U64 v) { memcpy(test_shm + off, &v, 8); }
static U32 get32(U32 off) {
    U32 v;
    memcpy(&v, test_shm + off, 4);
    return v;
}
static void input(U32 connected, U32 steer, U32 gas, U32 brake, U32 clutch, U32 buttons, U32 hat) {
    put32(0, SHM_MAGIC);
    put32(4, SHM_VERSION);
    put32(8, SHM_SIZE);
    U32 seq = get32(SHM_IN) + 2;
    put32(SHM_IN + 4, connected);
    put64(SHM_IN + 8, nowMs);
    put32(SHM_IN + 16, steer);
    put32(SHM_IN + 20, gas);
    put32(SHM_IN + 24, brake);
    put32(SHM_IN + 28, clutch);
    put32(SHM_IN + 32, buttons);
    put32(SHM_IN + 36, hat);
    put32(SHM_IN, seq);
}
static U32 fx(U32 slot, U32 word) { return get32(SHM_FX + slot * SHM_FX_SIZE + word * 4); }

typedef struct {
    PTR *v;
} COM;
#define CALL(o, i, T, ...) (((T)((COM *)(o))->v[i])((o), ##__VA_ARGS__))
#define CALL0(o, i, T) (((T)((COM *)(o))->v[i])(o))

/* Equivalent of Windows c_dfDIJoystick2, including the repeated slider
 * offsets for the velocity/acceleration/force aliases. */
static ObjectFormat joy2[164];
static DataFormat joystick2(void) {
    U32 n = 0, base[] = {0, 176, 208, 240};
    const GUID *axes[] = {&guidX, &guidY, &guidZ, 0, 0, &guidRz};
    static const GUID rx = AXISGUID(0x14), ry = AXISGUID(0x15);
    axes[3] = &rx;
    axes[4] = &ry;
    for (U32 aspect = 0; aspect < 4; aspect++) {
        for (U32 a = 0; a < 6; a++)
            joy2[n++] = (ObjectFormat){axes[a], base[aspect] + a * 4, OPTIONAL | DIDFT_AXIS | ANYINSTANCE,
                                       aspect ? 0x100u * (aspect + 1) : 0};
        for (U32 s = 0; s < 2; s++)
            joy2[n++] = (ObjectFormat){&guidSlider, 24 + 4 * s, OPTIONAL | DIDFT_AXIS | ANYINSTANCE,
                                       aspect ? 0x100u * (aspect + 1) : 0};
        if (!aspect) {
            for (U32 p = 0; p < 4; p++)
                joy2[n++] = (ObjectFormat){&guidPov, 32 + 4 * p, OPTIONAL | DIDFT_POV | ANYINSTANCE, 0};
            for (U32 b = 0; b < 128; b++)
                joy2[n++] = (ObjectFormat){0, 48 + b, OPTIONAL | DIDFT_BUTTON | ANYINSTANCE, 0};
        }
    }
    assert(n == 164);
    return (DataFormat){sizeof(DataFormat), sizeof(ObjectFormat), 1, 272, n, joy2};
}

static void expect_wide(const U16 *actual, const char *expected) {
    for (; *expected; actual++, expected++)
        assert(*actual == (unsigned char)*expected);
    assert(*actual == 0);
}
static int capture_a(const InstanceA *info, PTR ctx) {
    *(InstanceA *)ctx = *info;
    return 1;
}
static int capture_w(const InstanceW *info, PTR ctx) {
    *(InstanceW *)ctx = *info;
    return 1;
}
static void expect_identity(Factory *f, Device *d, U32 id, const char *name, int attached) {
    /* Literal GUID expectations also guard saved binding compatibility. */
    const GUID instance = {0x43464231, 0x0923, 0x4001, {0x80, 0x01, 0x43, 0x46, 0x42, 0, 0, 1}};
    const GUID product = {id, 0, 0, {0, 0, 0x50, 0x49, 0x44, 0x56, 0x49, 0x44}};
    if (f->wide) {
        InstanceW info = {.size = sizeof(info)}, enumerated = {0};
        assert(d->v->GetDeviceInfo(d, &info) == OK);
        assert(same(&info.instance, &instance) && same(&info.ff, &instance));
        assert(same(&info.product, &product));
        expect_wide(info.name, name); expect_wide(info.productName, name);
        assert(f->v->EnumDevices(f, 4, (PTR)capture_w, &enumerated, 0) == OK);
        assert(memcmp(&info, &enumerated, sizeof(info)) == 0);
        zero(&enumerated, sizeof(enumerated));
        assert(f->v->EnumDevices(f, 4, (PTR)capture_w, &enumerated, 1) == OK);
        assert((enumerated.size != 0) == attached);
    } else {
        InstanceA info = {.size = sizeof(info)}, enumerated = {0};
        assert(d->v->GetDeviceInfo(d, &info) == OK);
        assert(same(&info.instance, &instance) && same(&info.ff, &instance));
        assert(same(&info.product, &product));
        assert(strcmp(info.name, name) == 0 && strcmp(info.productName, name) == 0);
        assert(f->v->EnumDevices(f, 4, (PTR)capture_a, &enumerated, 0) == OK);
        assert(memcmp(&info, &enumerated, sizeof(info)) == 0);
        zero(&enumerated, sizeof(enumerated));
        assert(f->v->EnumDevices(f, 4, (PTR)capture_a, &enumerated, 1) == OK);
        assert((enumerated.size != 0) == attached);
    }
    struct { Property header; U16 value[260]; } text = {{536, 16, 0, 0}, {0}};
    for (U64 prop = 13; prop <= 14; prop++) {
        assert(d->v->GetProperty(d, (const GUID *)prop, &text.header) == OK);
        expect_wide(text.value, name);
    }
    DwordProperty vidPid = {{sizeof(vidPid), 16, 0, 0}, 0};
    assert(d->v->GetProperty(d, (const GUID *)24, &vidPid.h) == OK);
    assert(vidPid.value == id);
    assert(f->v->GetDeviceStatus(f, &instance) == (attached ? OK : 1));
    assert(d->v->Initialize(d, 0, 0x800, &instance) == OK);
}
static void test_identity(void) {
    const char *g29 = "G29 Driving Force Racing Wheel", *g923 = "G923 Racing Wheel for PlayStation and PC";
    for (int wide = 0; wide < 2; wide++) {
        zero(test_shm, sizeof(test_shm));
        identityVidPid = 0xc266046d; /* independent DLL process */
        Factory *f = 0;
        Device *d = 0;
        assert(DirectInput8Create(0, 0x800, wide ? &iidW : &iidA, (void **)&f, 0) == OK);
        assert(f->v->CreateDevice(f, &virtualGuid, (void **)&d, 0) == OK);
        expect_identity(f, d, 0xc266046d, g923, 0); /* no app yet */
        input(3, 32768, 65535, 65535, 65535, 0, 8);
        put32(SHM_IN + 40, 0xc24f046d);
        expect_identity(f, d, 0xc24f046d, g29, 1); /* refresh same device */
        put32(SHM_IN + 4, 0);
        expect_identity(f, d, 0xc24f046d, g29, 0); /* unplug retains identity */
        input(3, 32768, 65535, 65535, 65535, 0, 8);
        expect_identity(f, d, 0xc24f046d, g29, 1); /* reconnect */
        put32(SHM_IN + 40, 0xc266046d);
        put32(SHM_IN, get32(SHM_IN) | 1);
        expect_identity(f, d, 0xc24f046d, g29, 0); /* torn model change */
        put32(SHM_IN, get32(SHM_IN) + 1);
        put32(4, SHM_VERSION + 1);
        expect_identity(f, d, 0xc24f046d, g29, 0); /* incompatible protocol */
        put32(4, SHM_VERSION);
        nowMs += INPUT_STALE_MS + 1;
        expect_identity(f, d, 0xc24f046d, g29, 0); /* stale change ignored */
        put64(SHM_IN + 8, nowMs + 2001);
        expect_identity(f, d, 0xc24f046d, g29, 0); /* future heartbeat */
        input(3, 70000, 65535, 65535, 65535, 0, 8);
        expect_identity(f, d, 0xc24f046d, g29, 0); /* invalid input */
        input(3, 32768, 65535, 65535, 65535, 0, 8);
        expect_identity(f, d, 0xc266046d, g923, 1); /* different supported model */
        put32(SHM_IN + 40, 0xc24f046d);
        expect_identity(f, d, 0xc24f046d, g29, 1);
        put32(SHM_IN + 4, 1); /* old writer leaves G29 bytes untouched */
        expect_identity(f, d, 0xc266046d, g923, 1);
        put32(SHM_IN + 4, 3);
        const U32 unknown[] = {0, 0xc26d046d, 0xc26e046d, 0xc262046d, 0xc260046d, 0xc24f1234};
        for (U32 i = 0; i < sizeof(unknown) / sizeof(*unknown); i++) {
            put32(SHM_IN + 40, unknown[i]);
            expect_identity(f, d, 0xc266046d, g923, 1);
        }
        assert(d->v->Release(d) == 0);
        assert(f->v->Release(f) == 0);
    }
    zero(test_shm, sizeof(test_shm));
    identityVidPid = 0xc266046d;
    puts("PASS identity: ANSI/Unicode metadata, properties, stable GUIDs, v2 compatibility, reconnects");
}

static int mockCount = 1, mockReleased, mockQueries, mockMalformed;
static HR mock_property(Device *d, const GUID *g, Property *p) {
    (void)d;
    assert((U64)g == 12); mockQueries++;
    GuidPathProperty *v = (void *)p;
    v->guid = guidX;
    nameW(v->path, "\\\\?\\hid#vid_046d&pid_c266#physical");
    if (mockMalformed) for (int i = 0; i < 260; i++) v->path[i] = 'x';
    return OK;
}
static U32 mock_release(Device *d) { (void)d; mockReleased++; return 0; }
static const DeviceVT mockDVT = {.Release = mock_release, .GetProperty = mock_property};
static Device mockDevice = {.v = &mockDVT};
static HR mock_create(Factory *f, const GUID *g, void **out, PTR outer) {
    (void)f; (void)g; assert(!outer); *out = &mockDevice; return OK;
}
static HR mock_enum(Factory *f, U32 kind, PTR callback, PTR ctx, U32 flags) {
    assert(kind == 4 && flags == 1);
    for (int i = 0; i < mockCount; i++) {
        if (f->wide) {
            InstanceW info; instance_info(&info, 1);
            ((int (*)(const void *, PTR))callback)(&info, ctx);
        } else {
            InstanceA info; instance_info(&info, 0);
            ((int (*)(const void *, PTR))callback)(&info, ctx);
        }
    }
    return OK;
}
static const FactoryVT mockFVT = {.CreateDevice = mock_create, .EnumDevices = mock_enum};
static void test_physical_path(void) {
    for (int wide = 0; wide < 2; wide++) {
        input(3, 32768, 65535, 65535, 65535, 0, 8);
        put32(SHM_IN + 40, 0xc266046d);
        Factory real = {.v = &mockFVT, .wide = wide};
        Factory f = {.real = &real, .wide = wide};
        Device d = {.pathFactory = &f};
        GuidPathProperty p = {.h = {sizeof(p), 16, 0, 0}};
        mockCount = 1; mockMalformed = 0; mockReleased = mockQueries = 0;
        assert(getprop(&d, (const GUID *)12, &p.h) == OK && p.path[0] == '\\');
        assert(mockReleased == 1 && mockQueries == 1);
        assert(setprop(&d, (const GUID *)12, &p.h) == UNSUPPORTED);
        p.h.how = 1; assert(getprop(&d, (const GUID *)12, &p.h) == INVALID); p.h.how = 0;
        p.h.size--; assert(getprop(&d, (const GUID *)12, &p.h) == INVALID); p.h.size++;
        mockCount = 2; assert(getprop(&d, (const GUID *)12, &p.h) == NOTFOUND && !p.path[0]);
        mockCount = 0; assert(getprop(&d, (const GUID *)12, &p.h) == NOTFOUND);
        mockCount = 1; mockMalformed = 1; assert(getprop(&d, (const GUID *)12, &p.h) == NOTFOUND);
        assert(mockReleased == 2);
        put32(SHM_IN + 40, 0xc24f046d); assert(getprop(&d, (const GUID *)12, &p.h) == NOTFOUND);
        put32(SHM_IN + 40, 0xc266046d); put32(SHM_IN + 4, 0);
        assert(getprop(&d, (const GUID *)12, &p.h) == NOTFOUND);
    }
    zero(test_shm, sizeof(test_shm)); identityVidPid = 0xc266046d;
    puts("PASS physical path: ANSI/Unicode, real metadata, ambiguity, disconnect, malformed ABI, balanced release");
}

/* The system backend reports the physical G29 once; the bridge hides it and offers its own. */
static HR mock_enum_physical_g29(Factory *f, U32 kind, PTR callback, PTR ctx, U32 flags) {
    (void)f, (void)kind, (void)flags;
    InstanceW info = {.size = sizeof(info), .product = {0xc24f046d, 0, 0, {0, 0, 0x50, 0x49, 0x44, 0x56, 0x49, 0x44}}};
    ((int (*)(const void *, PTR))callback)(&info, ctx);
    return OK;
}
static int count_offered(const InstanceW *info, PTR ctx) { (void)info; (*(int *)ctx)++; return 1; }
static void test_enumeration_log(void) {
    static const FactoryVT physicalFVT = {.EnumDevices = mock_enum_physical_g29};
    Factory real = {.v = &physicalFVT, .wide = 1};
    Factory f = {.real = &real, .wide = 1, .refs = 1};
    input(3, 32768, 65535, 65535, 65535, 0, 8);
    put32(SHM_IN + 40, 0xc24f046d);
    loggedCount = 0; enumLoggedKey = ~0u;
    int offered = 0;
    assert(enumerate(&f, 4, (PTR)count_offered, &offered, 1) == OK);
    assert(offered == 1);
    const LogLine *virtualLine = last_logged("EnumDevices_virtual");
    assert(virtualLine && virtualLine->value == 1 && virtualLine->hasGuid && virtualLine->guid.a == 0xc24f046d);
    assert(last_logged("EnumDevices_kind")->value == 4 && last_logged("EnumDevices_flags")->value == 1);
    assert(last_logged("EnumDevices_hiddenReal")->value == 1 && last_logged("EnumDevices_result")->value == OK);
    U32 lines = loggedCount;
    assert(enumerate(&f, 4, (PTR)count_offered, &offered, 1) == OK);
    assert(loggedCount == lines); /* unchanged answers are rate-limited */
    put32(SHM_IN + 4, 0); /* disconnected: attached-only enumeration offers nothing */
    assert(enumerate(&f, 4, (PTR)count_offered, &offered, 1) == OK);
    assert(last_logged("EnumDevices_virtual")->value == 0 && !last_logged("EnumDevices_virtual")->hasGuid);
    zero(test_shm, sizeof(test_shm)); identityVidPid = 0xc266046d;
    puts("PASS enumeration log: offered G29 identity, hidden physical wheel, rate limit, disconnect");
}

int main(void) {
    test_physical_path();
    test_enumeration_log();
    /* Experimental products must remain visible to the real backend. */
    const U32 untouched[] = {0xc26d046d, 0xc26e046d, 0xc272046d, 0xc276046d, 0xc268046d};
    for (U32 i = 0; i < sizeof(untouched) / sizeof(*untouched); i++) {
        GUID product = {untouched[i], 0, 0, {0, 0, 0x50, 0x49, 0x44, 0x56, 0x49, 0x44}};
        assert(!hidden_product(&product));
    }
    test_identity();
    COM *factory = 0, *device = 0, *constant = 0, *damper = 0;
    assert(DirectInput8Create(0, 0x800, &iidW, (void **)&factory, 0) == OK);
    assert(CALL(factory, 3, HR (*)(PTR, const GUID *, void **, PTR), &virtualGuid, (void **)&device, 0) == OK);

    DataFormat f = joystick2();
    assert(CALL(device, 11, HR (*)(PTR, const DataFormat *), &f) == OK);
    assert(CALL0(device, 7, HR (*)(PTR)) == INPUTLOST); /* app not sharing yet */

    input(1, 40000, 1000, 2000, 3000, 0x5, 8);
    assert(CALL0(device, 7, HR (*)(PTR)) == OK);
    unsigned char st[272];
    memset(st, 0xcc, sizeof(st));
    assert(CALL(device, 9, HR (*)(PTR, U32, PTR), 272, st) == OK);
    I32 *l = (I32 *)st;
    assert(l[0] == 40000 && l[1] == 1000 && l[5] == 2000 && l[6] == 3000);
    assert(l[2] == 0 && l[3] == 0 && l[4] == 0 && l[7] == 0);
    for (int p = 0; p < 4; p++)
        assert(l[8 + p] == -1); /* centered POVs: no phantom D-pad presses */
    assert(st[48] == 128 && st[49] == 0 && st[50] == 128 && st[51] == 0);
    for (int i = 176; i < 272; i++)
        assert(st[i] == 0);

    input(1, 32768, 65535, 65535, 65535, 0, 0);
    assert(CALL(device, 9, HR (*)(PTR, U32, PTR), 272, st) == OK && l[8] == 0);

    /* Constant force on X by offset, Cartesian. */
    U32 axis = 0;
    I32 dir = 1, magnitude = 5000;
    EffectParams e = {sizeof(EffectParams), 0x10 | 2, 0xffffffffu, 0, 10000, 0xffffffffu, 0, 1, &axis, &dir, 0, 4,
                      &magnitude, 0};
    assert(CALL(device, 18, HR (*)(PTR, const GUID *, const EffectParams *, void **, PTR), &constantGuid, &e,
                (void **)&constant, 0) == OK);
    assert(CALL(constant, 7, HR (*)(PTR, U32, U32), 1, 0) == OK);
    assert(get32(SHM_FF) % 2 == 0 && get32(SHM_FF + 4) == 4242 && get32(SHM_FF + 16) == 1);
    assert(fx(0, 0) == 1 && fx(0, 1) == 1 && fx(0, 2) == 1 && (I32)fx(0, 16) == 5000 && fx(0, 8) == 0);
    assert(fx(0, 6) == 0x10 && (I32)fx(0, 9) == 1);

    /* Per-frame magnitude updates must not restart the effect. */
    magnitude = -7000;
    assert(CALL(constant, 6, HR (*)(PTR, const EffectParams *, U32), &e, 0x100) == OK);
    assert((I32)fx(0, 16) == -7000 && fx(0, 2) == 1 && fx(0, 1) == 1);

    /* Damper, single condition block. */
    I32 cond[6] = {0, 4000, 3000, 10000, 10000, 100};
    EffectParams c = {sizeof(EffectParams), 0x10 | 2, 0xffffffffu, 0, 8000, 0xffffffffu, 0, 1, &axis, &dir, 0, 24,
                      cond, 0};
    assert(CALL(device, 18, HR (*)(PTR, const GUID *, const EffectParams *, void **, PTR), &damperGuid, &c,
                (void **)&damper, 0) == OK);
    assert(CALL(damper, 7, HR (*)(PTR, U32, U32), 0xffffffffu, 0) == OK);
    assert(fx(1, 0) == 9 && fx(1, 1) == 1 && fx(1, 5) == 8000 && fx(1, 17) == 4000 && fx(1, 21) == 100);
    assert(fx(1, 22) == 0xffffffffu);

    /* Actuators and pause are reported to the app. */
    assert(CALL(device, 22, HR (*)(PTR, U32), 0x4) == OK && (get32(SHM_FF + 24) & 1));
    assert(CALL(device, 22, HR (*)(PTR, U32), 0x8 | 0x10) == OK && get32(SHM_FF + 24) == 0);

    /* ACC physics page is mirrored on each new packetId. */
    staticPage[412] = 8200 & 0xff; staticPage[413] = 8200 >> 8;
    physics[0] = 7;
    memcpy(physics + 20, &(I32){6500}, 4); /* rpms */
    assert(CALL0(device, 25, HR (*)(PTR)) == OK);
    assert(get32(SHM_TM) % 2 == 0 && get32(SHM_TM + 4) == 1 && get32(SHM_TM + 8) == TM_PHYSICS_BYTES);
    assert(get32(SHM_TM + SHM_TM_DATA) == 7 && get32(SHM_TM + SHM_TM_DATA + 20) == 6500);
    assert(get32(SHM_TM + 24) == 8200); /* static maxRpm */
    U32 tseq = get32(SHM_TM);
    assert(CALL0(device, 25, HR (*)(PTR)) == OK && get32(SHM_TM) == tseq); /* unchanged packet: no copy */

    /* Stale input: lost, effects stop, buffer neutral. */
    nowMs += 600;
    memset(st, 0xcc, sizeof(st));
    assert(CALL(device, 9, HR (*)(PTR, U32, PTR), 272, st) == INPUTLOST);
    assert(l[0] == 32768 && l[8] == -1 && st[48] == 0);
    assert(fx(0, 1) == 0 && fx(1, 1) == 0 && get32(SHM_FF + 16) == 0);

    nowMs += 10;
    input(1, 32768, 65535, 65535, 65535, 0, 8);
    assert(CALL0(device, 7, HR (*)(PTR)) == OK);
    assert(CALL(constant, 7, HR (*)(PTR, U32, U32), 1, 0) == OK && fx(0, 2) == 2 && fx(0, 1) == 1);
    assert(CALL0(device, 8, HR (*)(PTR)) == OK && fx(0, 1) == 0);

    /* Standard 80-byte DIJOYSTATE. */
    DataFormat f1 = {sizeof(DataFormat), sizeof(ObjectFormat), 1, 80, 44, joy2};
    for (U32 i = 0; i < 44; i++)
        assert(joy2[i].offset < 80);
    assert(CALL(device, 11, HR (*)(PTR, const DataFormat *), &f1) == OK);

    assert(CALL0(constant, 2, U32 (*)(PTR)) == 0);
    assert(CALL0(damper, 2, U32 (*)(PTR)) == 0);
    assert(fx(0, 0) == 0 && fx(1, 0) == 0);
    assert(CALL0(device, 2, U32 (*)(PTR)) == 0);
    assert(CALL0(factory, 2, U32 (*)(PTR)) == 0);
    assert(allocations == 0 && DllCanUnloadNow() == 0);
    puts("PASS bridge core: joystick2 format, shared-memory input, effect mirroring, lifetimes");
    return 0;
}
