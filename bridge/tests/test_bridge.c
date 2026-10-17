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
void test_lock(U64 *p) {
    while (__atomic_exchange_n(p, 1, __ATOMIC_ACQUIRE))
        sched_yield();
}
void test_unlock(U64 *p) { __atomic_store_n(p, 0, __ATOMIC_RELEASE); }
void *test_alloc(U32 n) {
    allocations++;
    return calloc(1, n);
}
void test_free(void *p) {
    allocations--;
    free(p);
}
void test_log(const char *m, U32 v, const GUID *g) { (void)m, (void)v, (void)g; }

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

int main(void) {
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
