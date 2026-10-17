/* Original minimal Win64 ABI declarations. Public interface facts checked against
 * Wine include/dinput.h; no implementation copied. Windows x64 has one calling convention. */
typedef signed int I32;
typedef struct {
    U32 size, flags, type, axes, buttons, povs, sample, resolution, firmware, hardware, driver;
} Caps;
typedef struct {
    U32 size;
    GUID instance, product;
    U32 type;
    char name[260], productName[260];
    GUID ff;
    U16 usagePage, usage;
} InstanceA;
typedef struct {
    U32 size;
    GUID instance, product;
    U32 type;
    U16 name[260], productName[260];
    GUID ff;
    U16 usagePage, usage;
} InstanceW;
typedef struct {
    U32 size;
    GUID type;
    U32 offset, objectType, flags;
    char name[260];
    U32 maxForce, resolution;
    U16 collection, designator, usagePage, usage;
    U32 dimension;
    U16 exponent, report;
} ObjectA;
typedef struct {
    U32 size;
    GUID type;
    U32 offset, objectType, flags;
    U16 name[260];
    U32 maxForce, resolution;
    U16 collection, designator, usagePage, usage;
    U32 dimension;
    U16 exponent, report;
} ObjectW;
typedef struct {
    const GUID *guid;
    U32 offset, type, flags;
} ObjectFormat;
typedef struct {
    U32 size, objectSize, flags, dataSize, count;
    ObjectFormat *objects;
} DataFormat;
typedef struct {
    U32 size, headerSize, object, how;
} Property;
typedef struct {
    Property h;
    U32 value;
} DwordProperty;
typedef struct {
    Property h;
    I32 min, max;
} RangeProperty;
typedef struct {
    U32 offset, data, timestamp, sequence;
    U64 appData;
} DeviceEvent;
typedef struct {
    U32 size, attackLevel, attackTime, fadeLevel, fadeTime;
} Envelope;
typedef struct {
    U32 size, flags, duration, samplePeriod, gain, trigger, repeat, axes;
    U32 *axisIDs;
    I32 *directions;
    Envelope *envelope;
    U32 paramBytes;
    void *params;
    U32 startDelay;
} EffectParams;
typedef struct {
    U32 size;
    GUID guid;
    U32 type, staticParams, dynamicParams;
    char name[260];
} EffectInfoA;
typedef struct {
    U32 size;
    GUID guid;
    U32 type, staticParams, dynamicParams;
    U16 name[260];
} EffectInfoW;
_Static_assert(sizeof(Caps) == 44 && sizeof(InstanceA) == 580 && sizeof(InstanceW) == 1100,
               "device info ABI");
_Static_assert(sizeof(ObjectA) == 316 && sizeof(ObjectW) == 576 && sizeof(ObjectFormat) == 24 &&
                   sizeof(DataFormat) == 32,
               "object ABI");
_Static_assert(sizeof(DeviceEvent) == 24 && sizeof(EffectParams) == 80, "effect ABI");
#define INPUTLOST ((HR)0x8007001eu)
#define NOTACQUIRED ((HR)0x8007000cu)
#define ACQUIRED ((HR)0x800700aau)
#define NOTFOUND ((HR)0x80070002u)
#define MORE_DATA ((HR)0x80040202u)
#define NOTBUFFERED ((HR)0x80040207u)
#define OUTOFMEMORY ((HR)0x8007000eu)
#define NOTINITIALIZED ((HR)0x80070015u)
#define INCOMPLETE ((HR)0x80040206u)
#define DIDFT_AXIS 3u
#define DIDFT_BUTTON 12u
#define DIDFT_POV 16u
#define ANYINSTANCE 0xffff00u
#define OPTIONAL 0x80000000u
#define ABSAXIS 2u
#define PUSHBUTTON 4u
#define AXISGUID(n) {0xa36d02e0u + (n), 0xc9f3, 0x11cf, {0xbf, 0xc7, 0x44, 0x45, 0x53, 0x54, 0, 0}}
static const GUID guidX = AXISGUID(0), guidY = AXISGUID(1), guidZ = AXISGUID(2), guidRz = AXISGUID(3),
                  guidSlider = AXISGUID(4), guidButton = AXISGUID(0x10), guidPov = AXISGUID(0x12);
static const GUID virtualGuid = {0x43464231, 0x0923, 0x4001, {0x80, 0x01, 0x43, 0x46, 0x42, 0, 0, 1}};
static const GUID productGuid = {0xc266046d, 0, 0, {0, 0, 0x50, 0x49, 0x44, 0x56, 0x49, 0x44}};
static const GUID iidDevA = {0x54d41080, 0xdc15, 0x4833, {0xa4, 0x1b, 0x74, 0x8f, 0x73, 0xa3, 0x81, 0x79}};
static const GUID iidDevW = {0x54d41081, 0xdc15, 0x4833, {0xa4, 0x1b, 0x74, 0x8f, 0x73, 0xa3, 0x81, 0x79}};
static const GUID iidEffect = {0xe7e1f7c0, 0x88d2, 0x11d0, {0x9a, 0xd0, 0, 0xa0, 0xc9, 0xa0, 0x6e, 0x35}};
/* GUID_ConstantForce ... GUID_Friction are consecutive: 13541c20 + n. */
#define EFFECTGUID(n) {0x13541c20u + (n), 0x8e33, 0x11d0, {0x9a, 0xd0, 0, 0xa0, 0xc9, 0xa0, 0x6e, 0x35}}
static const GUID effectGuids[11] = {EFFECTGUID(0), EFFECTGUID(1), EFFECTGUID(2), EFFECTGUID(3),
                                     EFFECTGUID(4), EFFECTGUID(5), EFFECTGUID(6), EFFECTGUID(7),
                                     EFFECTGUID(8), EFFECTGUID(9), EFFECTGUID(10)};
#define constantGuid (effectGuids[0])
#define damperGuid (effectGuids[8])
