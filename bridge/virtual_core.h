/* Original MIT virtual DirectInput8 wheel. Input comes from the native app via
 * shared memory (shm.h); force-feedback effects created by the game are
 * mirrored into the same mapping, where the native app plays them on the real
 * wheel. Every other device (keyboard, mouse, other controllers) is forwarded
 * to the system dinput8.dll when it can be loaded. */
static void zero(void *p, U32 n) {
    unsigned char *q = p;
    while (n--)
        *q++ = 0;
}
static void copy(void *d, const void *s, U32 n) {
    unsigned char *x = d;
    const unsigned char *y = s;
    while (n--)
        *x++ = *y++;
}
#ifdef CFB_TEST
extern void *test_alloc(U32);
extern void test_free(void *);
#define allocate test_alloc
#define dispose test_free
extern void test_lock(U64 *);
extern void test_unlock(U64 *);
extern U64 test_ticks(void);
#define lock_word test_lock
#define unlock_word test_unlock
#define ticks test_ticks
#else
IMPORT PTR GetProcessHeap(void);
IMPORT PTR HeapAlloc(PTR, U32, U64);
IMPORT int HeapFree(PTR, U32, PTR);
static void *allocate(U32 n) { return HeapAlloc(GetProcessHeap(), 8, n); }
static void dispose(void *p) { HeapFree(GetProcessHeap(), 0, p); }
IMPORT void AcquireSRWLockExclusive(U64 *);
IMPORT void ReleaseSRWLockExclusive(U64 *);
#define lock_word AcquireSRWLockExclusive
#define unlock_word ReleaseSRWLockExclusive
#define ticks GetTickCount64
#endif
static U32 liveObjects;
static U32 retain(U32 *r) { return __atomic_add_fetch(r, 1, __ATOMIC_RELAXED); }
static U32 decrement(U32 *r) { return __atomic_sub_fetch(r, 1, __ATOMIC_ACQ_REL); }
static void born(void) { retain(&liveObjects); }
static void died(void) { decrement(&liveObjects); }
static void nameA(char *out, const char *in) {
    U32 n = 0;
    while (*in && n < 259)
        out[n++] = *in++;
    out[n] = 0;
}
static void nameW(U16 *out, const char *in) {
    U32 n = 0;
    while (*in && n < 259)
        out[n++] = (U16)*in++;
    out[n] = 0;
}
/* Same product name and VID/PID GUID as the Logitech driver exposes, so games
 * that ship G923 presets (ACC, AMS2, rF2, ...) recognise the virtual wheel. */
#define PRODUCT_NAME "G923 Racing Wheel for PlayStation and PC"
#define DEVICE_TYPE (0x10000u | 0x400u | 0x16u) /* HID, driving, three pedals */
static void instance_info(void *out, int wide) {
    if (wide) {
        InstanceW *p = out;
        zero(p, sizeof(*p));
        p->size = sizeof(*p);
        p->instance = virtualGuid;
        p->product = productGuid;
        p->type = DEVICE_TYPE;
        p->ff = virtualGuid;
        p->usagePage = 1;
        p->usage = 4;
        nameW(p->name, PRODUCT_NAME);
        nameW(p->productName, PRODUCT_NAME);
    } else {
        InstanceA *p = out;
        zero(p, sizeof(*p));
        p->size = sizeof(*p);
        p->instance = virtualGuid;
        p->product = productGuid;
        p->type = DEVICE_TYPE;
        p->ff = virtualGuid;
        p->usagePage = 1;
        p->usage = 4;
        nameA(p->name, PRODUCT_NAME);
        nameA(p->productName, PRODUCT_NAME);
    }
}
typedef struct Device Device;
typedef struct Effect Effect;
typedef struct {
    HR (*QueryInterface)(Device *, const GUID *, void **);
    U32 (*AddRef)(Device *);
    U32 (*Release)(Device *);
    HR (*GetCapabilities)(Device *, Caps *);
    HR (*EnumObjects)(Device *, PTR, PTR, U32);
    HR (*GetProperty)(Device *, const GUID *, Property *);
    HR (*SetProperty)(Device *, const GUID *, const Property *);
    HR (*Acquire)(Device *);
    HR (*Unacquire)(Device *);
    HR (*GetDeviceState)(Device *, U32, PTR);
    HR (*GetDeviceData)(Device *, U32, DeviceEvent *, U32 *, U32);
    HR (*SetDataFormat)(Device *, const DataFormat *);
    HR (*SetEventNotification)(Device *, PTR);
    HR (*SetCooperativeLevel)(Device *, PTR, U32);
    HR (*GetObjectInfo)(Device *, PTR, U32, U32);
    HR (*GetDeviceInfo)(Device *, PTR);
    HR (*RunControlPanel)(Device *, PTR, U32);
    HR (*Initialize)(Device *, PTR, U32, const GUID *);
    HR (*CreateEffect)(Device *, const GUID *, const EffectParams *, Effect **, PTR);
    HR (*EnumEffects)(Device *, PTR, PTR, U32);
    HR (*GetEffectInfo)(Device *, PTR, const GUID *);
    HR (*GetForceFeedbackState)(Device *, U32 *);
    HR (*SendForceFeedbackCommand)(Device *, U32);
    HR (*EnumCreatedEffectObjects)(Device *, PTR, PTR, U32);
    HR (*Escape)(Device *, PTR);
    HR (*Poll)(Device *);
    HR (*SendDeviceData)(Device *, U32, const DeviceEvent *, U32 *, U32);
    HR (*EnumEffectsInFile)(Device *, const void *, PTR, PTR, U32);
    HR (*WriteEffectToFile)(Device *, const void *, U32, PTR, U32);
    HR (*BuildActionMap)(Device *, PTR, const void *, U32);
    HR (*SetActionMap)(Device *, PTR, const void *, U32);
    HR (*GetImageInfo)(Device *, PTR);
} DeviceVT;
typedef struct {
    U32 offset, source, width;
} Mapping;
#define SRC_ZERO 30u
#define SRC_NOPOV 31u
struct Device {
    const DeviceVT *v;
    U32 refs;
    U64 lock;
    int wide, acquired, paused, actuatorsOff;
    U32 formatSize, mapCount, bufferSize, queueHead, queueCount, overflow;
    Mapping maps[512];
    I32 min[4], max[4];
    U32 deadzone[4], saturation[4], calibration[4], gain, autocenter;
    U32 diagSeen, diagResult[16], diagProperty;
    U64 diagAt[16];
    U32 last[30], seen;
    U64 lastSequence;
    DeviceEvent queue[128];
    Effect *effects[32];
};
/* One result on transition, then at most one reminder/5s per method. Caller
 * owns lock. */
static int diagnostic(Device *d, U32 slot, const char *method, HR result) {
    U64 now = ticks();
    U32 bit = 1u << slot;
    if (!(d->diagSeen & bit) || d->diagResult[slot] != (U32)result || now - d->diagAt[slot] >= 5000) {
        d->diagSeen |= bit;
        d->diagResult[slot] = (U32)result;
        d->diagAt[slot] = now;
        event(method, (U32)result, 0);
        return 1;
    }
    return 0;
}
/* Sources: 0 X steering, 1 Y throttle, 2 Rz brake, 3 Slider0 clutch, 4 POV,
 * 5..29 buttons. This matches what the Logitech Windows driver exposes. */
static const GUID *sourceGuid(U32 s) {
    return s == 0   ? &guidX
           : s == 1 ? &guidY
           : s == 2 ? &guidRz
           : s == 3 ? &guidSlider
           : s == 4 ? &guidPov
                    : &guidButton;
}
static U32 sourceInstance(U32 s) {
    static const U32 axes[] = {0, 1, 5, 6};
    return s < 4 ? axes[s] : s == 4 ? 0 : s - 5;
}
static U32 sourceType(U32 s) {
    U32 kind = s < 4 ? ABSAXIS : s == 4 ? DIDFT_POV : PUSHBUTTON;
    return kind | (sourceInstance(s) << 8) | (s == 0 ? 0x01000000u : 0);
}
static U32 defaultOffset(U32 s) {
    static const U32 axes[] = {0, 4, 20, 24};
    return s < 4 ? axes[s] : s == 4 ? 32 : 48 + s - 5;
}
static U32 sourceUsage(U32 s) {
    static const U32 axes[] = {0x30, 0x31, 0x35, 0x36};
    return s < 4 ? axes[s] : s == 4 ? 0x39 : s - 4;
}
static const char *sourceName(U32 s) {
    return s == 0   ? "Wheel axis"
           : s == 1 ? "Accelerator"
           : s == 2 ? "Brake"
           : s == 3 ? "Clutch"
           : s == 4 ? "D-pad"
                    : "Button";
}
static U32 mappedOffset(Device *d, U32 s) {
    for (U32 i = 0; i < d->mapCount; i++)
        if (d->maps[i].source == s)
            return d->maps[i].offset;
    return defaultOffset(s);
}
#define OBJECT_INFO(p)                                                                                       \
    do {                                                                                                     \
        zero(p, sizeof(*p));                                                                                 \
        p->size = sizeof(*p);                                                                                \
        p->type = *sourceGuid(s);                                                                            \
        p->offset = mappedOffset(d, s);                                                                      \
        p->objectType = sourceType(s);                                                                       \
        p->flags = 0x8000u | (s < 4 ? 0x100u : 0) | (s == 0 ? 1u : 0u);                                      \
        p->usagePage = s >= 5 ? 9 : 1;                                                                       \
        p->usage = sourceUsage(s);                                                                           \
        p->maxForce = s == 0 ? 10000 : 0;                                                                    \
        p->resolution = s < 4 ? 65535 : 0;                                                                   \
    } while (0)
static void object_info(Device *d, PTR out, U32 s) {
    if (d->wide) {
        ObjectW *p = out;
        OBJECT_INFO(p);
        nameW(p->name, sourceName(s));
    } else {
        ObjectA *p = out;
        OBJECT_INFO(p);
        nameA(p->name, sourceName(s));
    }
}
static HR dq(Device *d, const GUID *i, void **out) {
    if (!out)
        return POINTER;
    *out = 0;
    if (same(i, &iidUnknown) || same(i, d->wide ? &iidDevW : &iidDevA)) {
        *out = d;
        retain(&d->refs);
        return OK;
    }
    return NOINTERFACE;
}
static U32 da(Device *d) { return retain(&d->refs); }
static void publish_released(Device *d);
static U32 dr(Device *d) {
    U32 r = decrement(&d->refs);
    if (!r) {
        publish_released(d);
        dispose(d);
        died();
    }
    return r;
}
static HR caps(Device *d, Caps *p) {
    (void)d;
    if (!p || p->size != sizeof(*p))
        return INVALID;
    zero(p, sizeof(*p));
    p->size = sizeof(*p);
    Snapshot snapshot;
    /* polled, polled format, FF with attack/fade/saturation/posneg/deadband/delay */
    p->flags = 2 | 8 | 0x100 | 0x200 | 0x400 | 0x800 | 0x1000 | 0x2000 | 0x4000 | 0x8000 |
               (read_snapshot(&snapshot) ? 1u : 0u);
    p->type = DEVICE_TYPE;
    p->axes = 4;
    p->buttons = 25;
    p->povs = 1;
    p->sample = 1000;
    p->resolution = 1000;
    p->driver = 1;
    return OK;
}
static HR objects(Device *d, PTR cb, PTR context, U32 flags) {
    if (!cb)
        return INVALID;
    da(d);
    for (U32 s = 0; s < 30; s++) {
        U32 type = sourceType(s);
        if ((flags & 0xff) && !(flags & type & 0xff))
            continue;
        if ((flags & 0x01000000u) && s != 0)
            continue;
        if (flags & 0x12000000u)
            continue;
        int more;
        if (d->wide) {
            ObjectW o;
            lock_word(&d->lock);
            object_info(d, &o, s);
            unlock_word(&d->lock);
            more = ((int (*)(const ObjectW *, PTR))cb)(&o, context);
        } else {
            ObjectA o;
            lock_word(&d->lock);
            object_info(d, &o, s);
            unlock_word(&d->lock);
            more = ((int (*)(const ObjectA *, PTR))cb)(&o, context);
        }
        if (!more)
            break;
    }
    dr(d);
    return OK;
}
/* how: 1 by offset, 2 by ID, 3 by usage (MAKELONG(usage, page)). */
static int find_source(Device *d, U32 obj, U32 how) {
    for (U32 s = 0; s < 30; s++) {
        if (how == 1 && mappedOffset(d, s) == obj)
            return (int)s;
        if (how == 2 && ((sourceType(s) >> 8) & 0xffff) == ((obj >> 8) & 0xffff) && (sourceType(s) & obj & 0xff))
            return (int)s;
        if (how == 3 && (obj & 0xffff) == sourceUsage(s) && (obj >> 16) == (s >= 5 ? 9u : 1u))
            return (int)s;
    }
    return -1;
}
static int valid_property(const Property *p, U32 size) {
    return p && p->headerSize == 16 && p->size == size && p->how <= 3;
}
static void publish(Device *d);
static HR property(Device *d, const GUID *g, Property *p, int set) {
    U64 id = (U64)g;
    if (id > 0xffff || !p)
        return INVALID;
    if (set && d->acquired && (id == 1 || id == 2))
        return ACQUIRED;
    if (id == 4) {
        if (!valid_property(p, sizeof(RangeProperty)))
            return INVALID;
        RangeProperty *r = (void *)p;
        int s = p->how ? find_source(d, p->object, p->how) : -1;
        if (p->how && (s < 0 || s >= 4))
            return NOTFOUND;
        if (set) {
            if (r->min >= r->max)
                return INVALID;
            for (int a = 0; a < 4; a++)
                if (s < 0 || s == a) {
                    d->min[a] = r->min;
                    d->max[a] = r->max;
                }
        } else {
            r->min = d->min[s < 0 ? 0 : s];
            r->max = d->max[s < 0 ? 0 : s];
        }
        return OK;
    }
    if ((id == 13 || id == 14) && !set) { /* instance / product name, DIPROPSTRING */
        if (!p || p->headerSize != 16 || p->size != 16 + 520)
            return INVALID;
        nameW((U16 *)((unsigned char *)p + 16), PRODUCT_NAME);
        return OK;
    }
    if (!valid_property(p, sizeof(DwordProperty)))
        return INVALID;
    DwordProperty *r = (void *)p;
    int s = p->how ? find_source(d, p->object, p->how) : -1;
    if (id == 10) {
        if (!p->how && p->object)
            return INVALID;
        if (p->how && (s < 0 || s >= 4))
            return NOTFOUND;
        if (set) {
            if (r->value > 1)
                return INVALID;
            for (int a = 0; a < 4; a++)
                if (s < 0 || s == a)
                    d->calibration[a] = r->value;
            d->seen = 0;
        } else
            r->value = d->calibration[s < 0 ? 0 : s];
        return OK;
    }
    if (id == 5 || id == 6) {
        if (p->how && (s < 0 || s >= 4))
            return NOTFOUND;
        if (set) {
            if (r->value > 10000)
                return INVALID;
            for (int a = 0; a < 4; a++)
                if (s < 0 || s == a) {
                    if (id == 5)
                        d->deadzone[a] = r->value;
                    else
                        d->saturation[a] = r->value ? r->value : 10000;
                }
        } else
            r->value = id == 5 ? d->deadzone[s < 0 ? 0 : s] : d->saturation[s < 0 ? 0 : s];
        return OK;
    }
    U32 *target = id == 1 ? &d->bufferSize : id == 7 ? &d->gain : id == 9 ? &d->autocenter : 0;
    if (target) {
        if (set) {
            U32 value = id == 1 && r->value > 128 ? 128 : r->value; /* games often ask for more */
            if ((id == 7 && value > 10000) || (id == 9 && value > 1))
                return INVALID;
            *target = value;
            if (id == 1)
                d->queueHead = d->queueCount = d->overflow = 0;
            else
                publish(d);
        } else
            r->value = *target;
        return OK;
    }
    if (id == 2) {
        if (set && r->value)
            return UNSUPPORTED;
        r->value = 0;
        return OK;
    }
    if (!set && (id == 3 || id == 8 || id == 15 || id == 24)) {
        r->value = id == 3 ? 1 : id == 24 ? 0xc266046d : 0;
        return OK;
    }
    return UNSUPPORTED;
}
static HR getprop(Device *d, const GUID *g, Property *p) { return property(d, g, p, 0); }
static HR setprop(Device *d, const GUID *g, const Property *p) { return property(d, g, (Property *)p, 1); }
/* c_dfDIJoystick2 lists velocity/acceleration/force aliases (and repeats the
 * slider offsets 24/28 for them). Objects we do not have are optional and
 * read as zero, so overlapping offsets among them are legal. */
static HR format_work(Device *d, const DataFormat *f, Mapping *proposed) {
    if (d->acquired)
        return ACQUIRED;
    if (!f || f->size != sizeof(*f) || f->objectSize != sizeof(ObjectFormat) || f->dataSize > 4096 ||
        !f->dataSize || f->count > 512 || (f->count && !f->objects) || (f->flags & ~3u))
        return INVALID;
    unsigned char used[30] = {0};
    U32 count = 0;
    for (U32 i = 0; i < f->count; i++) {
        ObjectFormat *o = &f->objects[i];
        U32 kind = o->type & 0xff, width = (kind & DIDFT_BUTTON) ? 1 : 4;
        U32 aspect = o->flags & 0xf00;
        int found = -1;
        for (U32 s = 0; s < 30 && (!aspect || aspect == 0x100); s++) {
            if (used[s])
                continue;
            U32 t = sourceType(s);
            if (!(kind & t & 0xff))
                continue;
            if ((o->type & ANYINSTANCE) != ANYINSTANCE && ((o->type >> 8) & 0xffff) != ((t >> 8) & 0xffff))
                continue;
            if (o->guid && !same(o->guid, sourceGuid(s)))
                continue;
            found = (int)s;
            break;
        }
        if (o->offset > f->dataSize || width > f->dataSize - o->offset)
            return INVALID;
        if (found < 0) {
            if (!(o->type & OPTIONAL))
                return NOTFOUND;
            proposed[count++] = (Mapping){o->offset, (kind & DIDFT_POV) ? SRC_NOPOV : SRC_ZERO, width};
            continue;
        }
        used[found] = 1;
        proposed[count++] = (Mapping){o->offset, (U32)found, width};
    }
    copy(d->maps, proposed, count * sizeof(Mapping));
    d->mapCount = count;
    d->formatSize = f->dataSize;
    d->seen = 0;
    d->queueHead = d->queueCount = d->overflow = 0;
    return OK;
}
static HR format(Device *d, const DataFormat *f) {
    Mapping *scratch = allocate(512 * sizeof(Mapping));
    if (!scratch)
        return OUTOFMEMORY;
    HR hr = format_work(d, f, scratch);
    dispose(scratch);
    if (diagnostic(d, 0, "SetDataFormat_result", hr) && f) {
        event("Format_dataSize", f->dataSize, 0);
        event("Format_objectCount", f->count, 0);
    }
    return hr;
}
static void stop_effects(Device *d);
static HR acquire(Device *d) {
    Snapshot s;
    if (!d->formatSize)
        return NOTINITIALIZED;
    U32 snapshotReason = 0;
    if (!read_snapshot_status(&s, &snapshotReason)) {
        diagnostic(d, 14, "Snapshot_failure_reason", (HR)snapshotReason);
        if (d->acquired) {
            d->acquired = 0;
            stop_effects(d);
        }
        return INPUTLOST;
    }
    if (d->acquired)
        return 1;
    d->acquired = 1;
    d->seen = 0;
    d->queueHead = d->queueCount = d->overflow = 0;
    publish(d);
    return OK;
}
static HR unacquire(Device *d) {
    int was = d->acquired;
    stop_effects(d);
    d->acquired = 0;
    d->seen = 0;
    d->queueHead = d->queueCount = 0;
    publish(d);
    return was ? OK : 1;
}
static U32 scaled(Device *d, const Snapshot *s, U32 a) {
    if (d->calibration[a])
        return s->axis[a];
    long long raw = s->axis[a];
    if (!d->deadzone[a] && d->saturation[a] == 10000)
        return (U32)((long long)d->min[a] + raw * ((long long)d->max[a] - d->min[a]) / 65535);
    long long delta = raw - 32768, mag = delta < 0 ? -delta : delta;
    long long dead = (long long)d->deadzone[a] * 32768 / 10000,
              sat = (long long)d->saturation[a] * 32768 / 10000;
    if (mag <= dead)
        raw = 32768;
    else if (mag >= sat || sat <= dead)
        raw = delta < 0 ? 0 : 65535;
    else {
        long long value = (mag - dead) * 32767 / (sat - dead);
        raw = 32768 + (delta < 0 ? -value : value);
    }
    long long span = (long long)d->max[a] - d->min[a];
    return (U32)((long long)d->min[a] + raw * span / 65535);
}
static void values(Device *d, const Snapshot *s, U32 out[30]) {
    for (U32 i = 0; i < 4; i++)
        out[i] = scaled(d, s, i);
    out[4] = s->hat == 8 ? 0xffffffffu : s->hat * 4500;
    for (U32 i = 5; i < 30; i++)
        out[i] = (s->buttons & (1u << (i - 5))) ? 128 : 0;
}
static void heartbeat(void) {
    volatile unsigned char *p = shm_map();
    if (p) {
        st64(p + SHM_FF + 8, unix_ms());
        copy_telemetry(p);
    }
}
static HR sample(Device *d, U32 out[30]) {
    if (!d->acquired)
        return NOTACQUIRED;
    Snapshot s;
    U32 snapshotReason = 0;
    if (!read_snapshot_status(&s, &snapshotReason)) {
        diagnostic(d, 14, "Snapshot_failure_reason", (HR)snapshotReason);
        d->acquired = 0;
        stop_effects(d);
        publish(d);
        d->queueHead = d->queueCount = 0;
        return INPUTLOST;
    }
    heartbeat();
    values(d, &s, out);
    if (d->seen && s.sequence != d->lastSequence && d->bufferSize) {
        for (U32 i = 0; i < d->mapCount; i++) {
            Mapping *m = &d->maps[i];
            if (m->source >= 30 || out[m->source] == d->last[m->source])
                continue;
            if (d->queueCount == d->bufferSize) {
                d->queueHead = (d->queueHead + 1) % 128;
                d->queueCount--;
                d->overflow = 1;
            }
            U32 tail = (d->queueHead + d->queueCount) % 128;
            d->queue[tail] = (DeviceEvent){m->offset, out[m->source], (U32)ticks(), (U32)s.sequence, 0};
            d->queueCount++;
        }
    }
    copy(d->last, out, sizeof(d->last));
    d->lastSequence = s.sequence;
    d->seen = 1;
    return OK;
}
/* Write only through the format accepted from this caller. Missing objects
 * stay zero (buffer is cleared first); missing POVs read centered (-1). */
static void write_state(Device *d, U32 size, PTR out, const U32 data[30]) {
    zero(out, size);
    for (U32 i = 0; i < d->mapCount; i++) {
        Mapping *m = &d->maps[i];
        if (m->source == SRC_ZERO)
            continue;
        unsigned char *p = (unsigned char *)out + m->offset;
        U32 value = m->source == SRC_NOPOV ? 0xffffffffu : data[m->source];
        for (U32 b = 0; b < m->width; b++)
            p[b] = (unsigned char)(value >> (b * 8));
    }
}
static HR state(Device *d, U32 size, PTR out) {
    if (!out)
        return POINTER;
    if (!d->formatSize)
        return NOTINITIALIZED;
    if (size != d->formatSize)
        return INVALID;
    Snapshot neutral = {{32768, 65535, 65535, 65535}, 0, 8, 0};
    U32 data[30];
    values(d, &neutral, data);
    write_state(d, size, out, data);
    HR hr = sample(d, data);
    if (hr)
        return hr;
    write_state(d, size, out, data);
    return OK;
}
static HR poll(Device *d) {
    U32 data[30];
    return sample(d, data);
}
static HR data(Device *d, U32 bytes, DeviceEvent *out, U32 *count, U32 flags) {
    if (!count)
        return POINTER;
    U32 wanted = *count;
    *count = 0;
    if ((bytes != sizeof(DeviceEvent) && bytes != 16) || flags > 1)
        return INVALID;
    if (!d->bufferSize)
        return NOTBUFFERED;
    U32 v[30];
    HR hr = sample(d, v);
    if (hr)
        return hr;
    U32 n = wanted < d->queueCount ? wanted : d->queueCount;
    for (U32 i = 0; out && i < n; i++)
        copy((unsigned char *)out + i * bytes, &d->queue[(d->queueHead + i) % 128], bytes);
    *count = n;
    HR result = d->overflow ? 1 : OK;
    if (!(flags & 1)) {
        d->queueHead = (d->queueHead + n) % 128;
        d->queueCount -= n;
        d->overflow = 0;
    }
    return result;
}
static HR notification(Device *d, PTR h) {
    (void)d;
    return h ? 2 : OK; /* DI_POLLEDDEVICE: the event is never signalled */
}
static HR cooperative(Device *d, PTR hwnd, U32 flags) {
    (void)hwnd;
    (void)flags;
    if (d->acquired)
        return ACQUIRED;
    return OK;
}
static HR getobject(Device *d, PTR out, U32 obj, U32 how) {
    if (!out)
        return POINTER;
    U32 size = *(U32 *)out;
    if (size != (d->wide ? sizeof(ObjectW) : sizeof(ObjectA)))
        return INVALID;
    int s = find_source(d, obj, how);
    if (s < 0)
        return NOTFOUND;
    object_info(d, out, (U32)s);
    return OK;
}
static HR getinfo(Device *d, PTR out) {
    if (!out)
        return POINTER;
    if (*(U32 *)out != (d->wide ? sizeof(InstanceW) : sizeof(InstanceA)))
        return INVALID;
    instance_info(out, d->wide);
    return OK;
}
static HR devicepanel(Device *d, PTR w, U32 f) {
    (void)d;
    (void)w;
    (void)f;
    return OK;
}
static HR deviceinit(Device *d, PTR h, U32 version, const GUID *g) {
    (void)d;
    (void)h;
    return version >= 0x700 && same(g, &virtualGuid) ? OK : INVALID;
}
typedef struct {
    HR (*QueryInterface)(Effect *, const GUID *, void **);
    U32 (*AddRef)(Effect *);
    U32 (*Release)(Effect *);
    HR (*Initialize)(Effect *, PTR, U32, const GUID *);
    HR (*GetEffectGuid)(Effect *, GUID *);
    HR (*GetParameters)(Effect *, EffectParams *, U32);
    HR (*SetParameters)(Effect *, const EffectParams *, U32);
    HR (*Start)(Effect *, U32, U32);
    HR (*Stop)(Effect *);
    HR (*GetEffectStatus)(Effect *, U32 *);
    HR (*Download)(Effect *);
    HR (*Unload)(Effect *);
    HR (*Escape)(Effect *, PTR);
} EffectVT;
struct Effect {
    const EffectVT *v;
    U32 refs;
    Device *device;
    GUID guid;
    U32 kind; /* 1 constant .. 11 friction, index into effectGuids + 1 */
    EffectParams p;
    U32 axes[4];
    I32 directions[4];
    Envelope env;
    unsigned char params[96];
    U32 present, downloaded, playing, starts, iterations;
    U64 startAt, endAt;
};
static U32 effect_kind(const GUID *g) {
    for (U32 i = 0; i < 11; i++)
        if (same(g, &effectGuids[i]))
            return i + 1;
    return 0;
}
/* DIEFT_* class: 1 constant, 2 ramp, 3 periodic, 4 condition. */
static U32 effect_class(U32 kind) { return kind == 1 ? 1 : kind == 2 ? 2 : kind <= 7 ? 3 : 4; }
static void stop_effects(Device *d) {
    for (U32 i = 0; i < 32; i++)
        if (d->effects[i]) {
            d->effects[i]->playing = 0;
            d->effects[i]->downloaded = 0;
        }
}
static U32 playing_now(Effect *e) {
    U64 now = ticks();
    if (e->playing && e->endAt && now >= e->endAt)
        e->playing = 0;
    return e->playing && now >= e->startAt;
}
/* Index of the steering axis in the effect's axis list, or 0 for a one-axis
 * effect whose axis we cannot identify (a wheel only has one FF axis). */
static U32 x_index(Device *d, Effect *e) {
    for (U32 j = 0; j < e->p.axes && j < 4; j++) {
        U32 a = e->axes[j];
        if ((e->p.flags & 3) == 2 && a == mappedOffset(d, 0))
            return j;
        if ((e->p.flags & 3) == 1 && (a & 3) && ((a >> 8) & 0xffff) == 0)
            return j;
    }
    return e->p.axes <= 1 ? 0 : 0xffffffffu;
}
static Device *publisher;
static void write_record(Device *d, volatile unsigned char *r, Effect *e) {
    U32 words[24] = {0};
    if (e && e->kind) {
        U32 xi = x_index(d, e);
        words[0] = e->kind;
        words[1] = e->playing && e->downloaded;
        words[2] = e->starts;
        words[3] = e->p.duration;
        words[4] = e->p.startDelay;
        words[5] = e->p.gain;
        words[6] = e->p.flags & 0x70;
        words[7] = e->p.axes;
        words[8] = xi;
        words[9] = (U32)e->directions[0];
        words[10] = (U32)(e->p.axes > 1 ? e->directions[1] : 0);
        words[11] = e->p.envelope ? 1 : 0;
        words[12] = e->env.attackLevel;
        words[13] = e->env.attackTime;
        words[14] = e->env.fadeLevel;
        words[15] = e->env.fadeTime;
        U32 block = 0;
        if (effect_class(e->kind) == 4 && e->p.paramBytes > 24 && xi < 4)
            block = xi * 24;
        U32 n = effect_class(e->kind) == 1 ? 4 : effect_class(e->kind) == 2 ? 8 : effect_class(e->kind) == 3 ? 16 : 24;
        if (e->p.paramBytes >= block + n)
            copy(&words[16], e->params + block, n);
        words[22] = e->iterations;
    }
    for (U32 i = 0; i < 24; i++)
        st32(r + 4 * i, words[i]);
}
static U64 publishLock;
/* Mirror this device's force state into shared memory (seqlock writer). */
static void publish(Device *d) {
    volatile unsigned char *p = shm_map();
    if (!p)
        return;
    lock_word(&publishLock);
    publisher = d;
    U32 seq = (ld32(p + SHM_FF) + 1) | 1;
    st32(p + SHM_FF, seq);
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    st32(p + SHM_FF + 4, process_id());
    st64(p + SHM_FF + 8, unix_ms());
    st32(p + SHM_FF + 16, (U32)d->acquired);
    st32(p + SHM_FF + 20, d->gain);
    st32(p + SHM_FF + 24, (d->paused ? 1u : 0) | (d->actuatorsOff ? 2u : 0) | (d->autocenter ? 4u : 0));
    st32(p + SHM_FF + 28, SHM_FX_COUNT);
    for (U32 i = 0; i < SHM_FX_COUNT; i++)
        write_record(d, p + SHM_FX + i * SHM_FX_SIZE, d->effects[i]);
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    __atomic_store_n((volatile U32 *)(p + SHM_FF), seq + 1, __ATOMIC_RELEASE);
    unlock_word(&publishLock);
}
static void publish_released(Device *d) {
    if (__atomic_load_n(&publisher, __ATOMIC_ACQUIRE) != d)
        return;
    static Device empty; /* zeroed: no effects, not acquired */
    publish(&empty);
    publisher = 0;
}
static U32 ea(Effect *e) { return retain(&e->refs); }
static U32 er(Effect *e) {
    Device *d = e->device;
    lock_word(&d->lock);
    U32 r = decrement(&e->refs);
    if (!r) {
        for (U32 i = 0; i < 32; i++)
            if (d->effects[i] == e)
                d->effects[i] = 0;
        publish(d);
    }
    unlock_word(&d->lock);
    if (!r) {
        dispose(e);
        died();
        dr(d);
    }
    return r;
}
static HR eq(Effect *e, const GUID *g, void **out) {
    if (!out)
        return POINTER;
    *out = 0;
    if (same(g, &iidUnknown) || same(g, &iidEffect)) {
        *out = e;
        ea(e);
        return OK;
    }
    return NOINTERFACE;
}
static HR ei(Effect *e, PTR h, U32 version, const GUID *g) {
    (void)h;
    return version >= 0x700 && same(g, &e->guid) ? OK : INVALID;
}
static HR eg(Effect *e, GUID *g) {
    if (!g)
        return POINTER;
    *g = e->guid;
    return OK;
}
static HR estart(Effect *e, U32 repeat, U32 flags) {
    if (flags & ~0x80000001u)
        return INVALID;
    if (!e->device->acquired)
        return NOTACQUIRED;
    if (!(e->present & 0x100))
        return INCOMPLETE;
    if (flags & 1)
        for (U32 i = 0; i < 32; i++)
            if (e->device->effects[i])
                e->device->effects[i]->playing = 0;
    if (!repeat)
        repeat = 1;
    e->downloaded = 1;
    e->playing = 1;
    e->starts++;
    e->iterations = repeat;
    e->startAt = ticks() + e->p.startDelay / 1000;
    e->endAt = e->p.duration == 0xffffffffu || repeat == 0xffffffffu
                   ? 0
                   : e->startAt + ((U64)e->p.duration * repeat + 999) / 1000;
    return OK;
}
static HR estop(Effect *e) {
    e->playing = 0;
    return OK;
}
static HR estat(Effect *e, U32 *out) {
    if (!out)
        return POINTER;
    *out = playing_now(e) ? 1 : 0;
    return OK;
}
static HR edownload(Effect *e) {
    if (!e->device->acquired)
        return NOTACQUIRED;
    e->downloaded = 1;
    return OK;
}
static HR eunload(Effect *e) {
    e->downloaded = e->playing = 0;
    return OK;
}
static HR eescape(Effect *e, PTR p) {
    (void)e;
    (void)p;
    return UNSUPPORTED;
}
static int effect_size(const EffectParams *p) { return p && (p->size == sizeof(*p) || p->size == 72); }
static HR eset(Effect *e, const EffectParams *p, U32 flags) {
    if (!effect_size(p) || flags & ~0xe00003ffu)
        return INVALID;
    U32 f = flags & 0x3ff;
    if ((f & 4) && p->gain > 10000)
        return INVALID;
    U32 axes = (f & 0x20) ? p->axes : e->p.axes;
    if ((f & 0x20) && (!axes || axes > 4 || !p->axisIDs))
        return INVALID;
    if ((f & 0x40) && (!axes || axes > 4 || !p->directions))
        return INVALID;
    if ((f & 0x80) && p->envelope && p->envelope->size != sizeof(Envelope))
        return INVALID;
    U32 cls = effect_class(e->kind);
    U32 needed = cls == 1 ? 4 : cls == 2 ? 8 : cls == 3 ? 16 : (p->paramBytes == 24 ? 24 : 24 * (axes ? axes : 1));
    if ((f & 0x100) && (p->paramBytes != needed || needed > sizeof(e->params) || !p->params))
        return INVALID;
    if ((f & 0x200) && p->size != sizeof(*p))
        f &= ~0x200u;
    if (f & 1)
        e->p.duration = p->duration;
    if (f & 2)
        e->p.samplePeriod = p->samplePeriod;
    if (f & 4)
        e->p.gain = p->gain;
    if (f & 8)
        e->p.trigger = p->trigger;
    if (f & 0x10)
        e->p.repeat = p->repeat;
    if (f & 0x20) {
        e->p.axes = axes;
        copy(e->axes, p->axisIDs, axes * 4);
        e->p.flags = (e->p.flags & ~3u) | (p->flags & 3);
    }
    if (f & 0x40) {
        copy(e->directions, p->directions, axes * 4);
        e->p.flags = (e->p.flags & ~0x70u) | (p->flags & 0x70);
    }
    if (f & 0x80) {
        if (p->envelope) {
            e->env = *p->envelope;
            e->p.envelope = &e->env;
        } else
            e->p.envelope = 0;
    }
    if (f & 0x100) {
        e->p.paramBytes = needed;
        copy(e->params, p->params, needed);
    }
    if (f & 0x200)
        e->p.startDelay = p->startDelay;
    e->present |= f;
    if (!(flags & 0x80000000u))
        e->downloaded = 1;
    if (flags & 0x20000000u)
        return estart(e, 1, 0);
    return OK;
}
static HR eget(Effect *e, EffectParams *p, U32 flags) {
    if (!effect_size(p) || flags & ~0x3ffu)
        return INVALID;
    U32 capacity = p->axes, paramCapacity = p->paramBytes;
    if ((flags & (0x20 | 0x40)) && capacity < e->p.axes) {
        p->axes = e->p.axes;
        return MORE_DATA;
    }
    if ((flags & 0x100) && paramCapacity < e->p.paramBytes) {
        p->paramBytes = e->p.paramBytes;
        return MORE_DATA;
    }
    if ((flags & 0x20) && e->p.axes && !p->axisIDs)
        return POINTER;
    if ((flags & 0x40) && e->p.axes && !p->directions)
        return POINTER;
    if ((flags & 0x80) && e->p.envelope && (!p->envelope || p->envelope->size != sizeof(Envelope)))
        return POINTER;
    if ((flags & 0x100) && e->p.paramBytes && !p->params)
        return POINTER;
    if ((flags & 0x200) && p->size != sizeof(*p))
        return INVALID;
    p->flags = e->p.flags;
    if (flags & 1)
        p->duration = e->p.duration;
    if (flags & 2)
        p->samplePeriod = e->p.samplePeriod;
    if (flags & 4)
        p->gain = e->p.gain;
    if (flags & 8)
        p->trigger = e->p.trigger;
    if (flags & 0x10)
        p->repeat = e->p.repeat;
    if (flags & 0x20)
        copy(p->axisIDs, e->axes, e->p.axes * 4);
    if (flags & 0x40)
        copy(p->directions, e->directions, e->p.axes * 4);
    if (flags & (0x20 | 0x40))
        p->axes = e->p.axes;
    if (flags & 0x80) {
        if (e->p.envelope)
            *p->envelope = e->env;
        else
            p->envelope = 0;
    }
    if (flags & 0x100) {
        copy(p->params, e->params, e->p.paramBytes);
        p->paramBytes = e->p.paramBytes;
    }
    if (flags & 0x200)
        p->startDelay = e->p.startDelay;
    return OK;
}
#define EWRAP0(name, mirror)                                                                                 \
    static HR locked_##name(Effect *e) {                                                                     \
        lock_word(&e->device->lock);                                                                         \
        HR h = name(e);                                                                                      \
        if (mirror)                                                                                          \
            publish(e->device);                                                                              \
        unlock_word(&e->device->lock);                                                                       \
        return h;                                                                                            \
    }
#define EWRAP1(name, T, a, mirror)                                                                           \
    static HR locked_##name(Effect *e, T a) {                                                                \
        lock_word(&e->device->lock);                                                                         \
        HR h = name(e, a);                                                                                   \
        if (mirror)                                                                                          \
            publish(e->device);                                                                              \
        unlock_word(&e->device->lock);                                                                       \
        return h;                                                                                            \
    }
#define EWRAP2(name, T, a, V, b, mirror)                                                                     \
    static HR locked_##name(Effect *e, T a, V b) {                                                           \
        lock_word(&e->device->lock);                                                                         \
        HR h = name(e, a, b);                                                                                \
        if (mirror)                                                                                          \
            publish(e->device);                                                                              \
        unlock_word(&e->device->lock);                                                                       \
        return h;                                                                                            \
    }
EWRAP0(estop, 1)
EWRAP0(edownload, 1)
EWRAP0(eunload, 1)
EWRAP1(estat, U32 *, p, 0)
EWRAP2(estart, U32, n, U32, f, 1)
EWRAP2(eset, const EffectParams *, p, U32, f, 1)
EWRAP2(eget, EffectParams *, p, U32, f, 0)
static const EffectVT evt = {eq,
                             ea,
                             er,
                             ei,
                             eg,
                             locked_eget,
                             locked_eset,
                             locked_estart,
                             locked_estop,
                             locked_estat,
                             locked_edownload,
                             locked_eunload,
                             eescape};
static HR effect_create(Device *d, const GUID *g, const EffectParams *p, Effect **out, PTR outer) {
    if (!out)
        return POINTER;
    *out = 0;
    if (outer)
        return NOAGGREGATION;
    U32 kind = effect_kind(g);
    if (!kind) {
        event("CreateEffect_UNSUPPORTED", 0, g);
        return UNSUPPORTED;
    }
    U32 slot;
    for (slot = 0; slot < 32 && d->effects[slot]; slot++) {
    }
    if (slot == 32)
        return OUTOFMEMORY;
    Effect *e = allocate(sizeof(*e));
    if (!e)
        return OUTOFMEMORY;
    zero(e, sizeof(*e));
    e->v = &evt;
    e->refs = 1;
    e->device = d;
    e->guid = *g;
    e->kind = kind;
    e->p.size = sizeof(e->p);
    e->p.gain = 10000;
    e->p.duration = 0xffffffffu;
    e->p.trigger = 0xffffffffu;
    if (p) {
        HR hr = eset(e, p, (p->size == 72 ? 0x1ffu : 0x3ffu) | 0x80000000u);
        if (hr) {
            dispose(e);
            return hr;
        }
        e->downloaded = d->acquired;
    }
    da(d);
    born();
    d->effects[slot] = e;
    *out = e;
    event("CreateEffect", kind, g);
    publish(d);
    return OK;
}
static const char *effect_name(U32 kind) {
    static const char *names[] = {"Constant Force", "Ramp Force", "Square", "Sine", "Triangle", "Sawtooth Up",
                                  "Sawtooth Down",  "Spring",     "Damper", "Inertia", "Friction"};
    return names[kind - 1];
}
static U32 effect_type_flags(U32 kind) {
    U32 cls = effect_class(kind);
    return cls == 4 ? 4 | 0x800 | 0x1000 | 0x2000 | 0x4000 : cls | 0x200 | 0x400 | 0x8000;
}
static void effect_info(Device *d, PTR out, U32 kind) {
    if (d->wide) {
        EffectInfoW *p = out;
        zero(p, sizeof(*p));
        p->size = sizeof(*p);
        p->guid = effectGuids[kind - 1];
        p->type = effect_type_flags(kind);
        p->staticParams = p->dynamicParams = 0x3ff;
        nameW(p->name, effect_name(kind));
    } else {
        EffectInfoA *p = out;
        zero(p, sizeof(*p));
        p->size = sizeof(*p);
        p->guid = effectGuids[kind - 1];
        p->type = effect_type_flags(kind);
        p->staticParams = p->dynamicParams = 0x3ff;
        nameA(p->name, effect_name(kind));
    }
}
static HR enum_effects(Device *d, PTR cb, PTR ctx, U32 type) {
    if (!cb)
        return INVALID;
    da(d);
    for (U32 kind = 1; kind <= 11; kind++) {
        if ((type & 0xff) && (type & 0xff) != effect_class(kind))
            continue;
        int result;
        if (d->wide) {
            EffectInfoW p;
            effect_info(d, &p, kind);
            result = ((int (*)(const EffectInfoW *, PTR))cb)(&p, ctx);
        } else {
            EffectInfoA p;
            effect_info(d, &p, kind);
            result = ((int (*)(const EffectInfoA *, PTR))cb)(&p, ctx);
        }
        if (!result)
            break;
    }
    dr(d);
    return OK;
}
static HR effect_info_get(Device *d, PTR out, const GUID *g) {
    if (!out)
        return POINTER;
    if (*(U32 *)out != (d->wide ? sizeof(EffectInfoW) : sizeof(EffectInfoA)))
        return INVALID;
    U32 kind = effect_kind(g);
    if (!kind)
        return NOTFOUND;
    effect_info(d, out, kind);
    return OK;
}
static HR ffstate(Device *d, U32 *out) {
    if (!out)
        return POINTER;
    U32 count = 0, active = 0;
    for (U32 i = 0; i < 32; i++)
        if (d->effects[i]) {
            count++;
            if (playing_now(d->effects[i]))
                active = 1;
        }
    *out = (!count ? 1u : 0u) | (!active ? 2u : 0u) | (d->paused ? 4u : 0u) | (d->actuatorsOff ? 0x20u : 0x10u) |
           0x40u | 0x100u | 0x400u | (!d->acquired ? 0x80000000u : 0u);
    return OK;
}
static HR command(Device *d, U32 flags) {
    if (!flags || (flags & ~0x3fu))
        return INVALID;
    if (flags & 1) { /* reset */
        stop_effects(d);
        d->paused = 0;
        d->actuatorsOff = 0;
    }
    if (flags & 2)
        for (U32 i = 0; i < 32; i++)
            if (d->effects[i])
                d->effects[i]->playing = 0;
    if (flags & 4)
        d->paused = 1;
    if (flags & 8)
        d->paused = 0;
    if (flags & 0x10)
        d->actuatorsOff = 0;
    if (flags & 0x20)
        d->actuatorsOff = 1;
    publish(d);
    return OK;
}
static HR enum_created(Device *d, PTR cb, PTR ctx, U32 flags) {
    if (!cb || flags)
        return INVALID;
    Effect *list[32];
    U32 count = 0;
    da(d);
    lock_word(&d->lock);
    for (U32 i = 0; i < 32; i++)
        if (d->effects[i]) {
            list[count++] = d->effects[i];
            ea(d->effects[i]);
        }
    unlock_word(&d->lock);
    int more = 1;
    for (U32 i = 0; i < count; i++) {
        if (more)
            more = ((int (*)(Effect *, PTR))cb)(list[i], ctx);
        er(list[i]);
    }
    dr(d);
    return OK;
}
static HR escape(Device *d, PTR p) {
    (void)d;
    (void)p;
    return UNSUPPORTED;
}
static HR senddata(Device *d, U32 size, const DeviceEvent *p, U32 *n, U32 flags) {
    (void)d;
    (void)size;
    (void)p;
    (void)flags;
    if (n)
        *n = 0;
    return UNSUPPORTED;
}
static HR effectsfile(Device *d, const void *name, PTR cb, PTR ctx, U32 f) {
    (void)d;
    (void)name;
    (void)cb;
    (void)ctx;
    (void)f;
    return UNSUPPORTED;
}
static HR writefile(Device *d, const void *name, U32 n, PTR p, U32 f) {
    (void)d;
    (void)name;
    (void)n;
    (void)p;
    (void)f;
    return UNSUPPORTED;
}
static HR actionmap(Device *d, PTR p, const void *n, U32 f) {
    (void)d;
    (void)p;
    (void)n;
    (void)f;
    return UNSUPPORTED;
}
static HR imageinfo(Device *d, PTR p) {
    (void)d;
    (void)p;
    return UNSUPPORTED;
}
/* Serialize mutable virtual input/effect state. Never hold this lock across
 * callbacks. */
#define WRAP0(name, slot)                                                                                    \
    static HR locked_##name(Device *d) {                                                                     \
        lock_word(&d->lock);                                                                                 \
        HR h = name(d);                                                                                      \
        diagnostic(d, slot, #name "_result", h);                                                             \
        unlock_word(&d->lock);                                                                               \
        return h;                                                                                            \
    }
#define WRAP1(name, T, a, slot)                                                                              \
    static HR locked_##name(Device *d, T a) {                                                                \
        lock_word(&d->lock);                                                                                 \
        HR h = name(d, a);                                                                                   \
        diagnostic(d, slot, #name "_result", h);                                                             \
        unlock_word(&d->lock);                                                                               \
        return h;                                                                                            \
    }
#define WRAP2(name, T, a, V, b, slot)                                                                        \
    static HR locked_##name(Device *d, T a, V b) {                                                           \
        lock_word(&d->lock);                                                                                 \
        HR h = name(d, a, b);                                                                                \
        diagnostic(d, slot, #name "_result", h);                                                             \
        unlock_word(&d->lock);                                                                               \
        return h;                                                                                            \
    }
WRAP0(acquire, 1)
WRAP0(unacquire, 2)
WRAP0(poll, 3)
WRAP1(format, const DataFormat *, f, 0)
WRAP1(caps, Caps *, p, 4)
WRAP1(ffstate, U32 *, p, 5)
WRAP1(command, U32, f, 6)
WRAP1(getinfo, PTR, p, 7)
WRAP2(getprop, const GUID *, g, Property *, p, 9)
WRAP2(cooperative, PTR, window, U32, f, 10)
static HR locked_state(Device *d, U32 n, PTR p) {
    lock_word(&d->lock);
    HR h = state(d, n, p);
    if (diagnostic(d, 8, "GetDeviceState_result", h)) {
        event("State_requestedBytes", n, 0);
        if (h == OK) {
            event("State_steering", d->last[0], 0);
            event("State_throttle", d->last[1], 0);
            event("State_brake", d->last[2], 0);
            event("State_clutch", d->last[3], 0);
        }
    }
    unlock_word(&d->lock);
    return h;
}
static HR locked_setprop(Device *d, const GUID *g, const Property *p) {
    lock_word(&d->lock);
    HR h = setprop(d, g, p);
    if (d->diagProperty != (U32)(U64)g) {
        d->diagProperty = (U32)(U64)g;
        d->diagSeen &= ~(1u << 11);
    }
    if (diagnostic(d, 11, "SetProperty_result", h))
        event("Property_id", (U32)(U64)g, 0);
    unlock_word(&d->lock);
    return h;
}
static HR locked_data(Device *d, U32 n, DeviceEvent *p, U32 *c, U32 f) {
    lock_word(&d->lock);
    HR h = data(d, n, p, c, f);
    diagnostic(d, 12, "GetDeviceData_result", h);
    unlock_word(&d->lock);
    return h;
}
static HR locked_getobject(Device *d, PTR p, U32 o, U32 how) {
    lock_word(&d->lock);
    HR h = getobject(d, p, o, how);
    unlock_word(&d->lock);
    return h;
}
static HR locked_effect_create(Device *d, const GUID *g, const EffectParams *p, Effect **out, PTR outer) {
    lock_word(&d->lock);
    HR h = effect_create(d, g, p, out, outer);
    unlock_word(&d->lock);
    return h;
}
static const DeviceVT dvt = {dq,
                             da,
                             dr,
                             locked_caps,
                             objects,
                             locked_getprop,
                             locked_setprop,
                             locked_acquire,
                             locked_unacquire,
                             locked_state,
                             locked_data,
                             locked_format,
                             notification,
                             locked_cooperative,
                             locked_getobject,
                             locked_getinfo,
                             devicepanel,
                             deviceinit,
                             locked_effect_create,
                             enum_effects,
                             effect_info_get,
                             locked_ffstate,
                             locked_command,
                             enum_created,
                             escape,
                             locked_poll,
                             senddata,
                             effectsfile,
                             writefile,
                             actionmap,
                             actionmap,
                             imageinfo};
typedef struct Factory Factory;
typedef struct {
    HR (*QueryInterface)(Factory *, const GUID *, void **);
    U32 (*AddRef)(Factory *);
    U32 (*Release)(Factory *);
    HR (*CreateDevice)(Factory *, const GUID *, void **, PTR);
    HR (*EnumDevices)(Factory *, U32, PTR, PTR, U32);
    HR (*GetDeviceStatus)(Factory *, const GUID *);
    HR (*RunControlPanel)(Factory *, PTR, U32);
    HR (*Initialize)(Factory *, PTR, U32);
    HR (*FindDevice)(Factory *, const GUID *, const void *, GUID *);
    HR (*EnumDevicesBySemantics)(Factory *, const void *, PTR, PTR, PTR, U32);
    HR (*ConfigureDevices)(Factory *, PTR, PTR, U32, PTR);
} FactoryVT;
struct Factory {
    const FactoryVT *v;
    U32 refs;
    int wide;
    Factory *real; /* system dinput8 factory for every other device, may be 0 */
};
static U32 fa(Factory *f) { return retain(&f->refs); }
static U32 fr(Factory *f) {
    U32 r = decrement(&f->refs);
    if (!r) {
        if (f->real)
            f->real->v->Release(f->real);
        dispose(f);
        died();
    }
    return r;
}
static HR fq(Factory *f, const GUID *i, void **out) {
    if (!out)
        return POINTER;
    *out = 0;
    if (same(i, &iidUnknown) || same(i, f->wide ? &iidW : &iidA)) {
        *out = f;
        fa(f);
        return OK;
    }
    return NOINTERFACE;
}
static HR create(Factory *f, const GUID *g, void **out, PTR outer) {
    if (!out)
        return POINTER;
    *out = 0;
    if (!same(g, &virtualGuid))
        return f->real ? f->real->v->CreateDevice(f->real, g, out, outer) : NOTFOUND;
    event("CreateDevice_VIRTUAL", 0, g);
    if (outer)
        return NOAGGREGATION;
    Device *d = allocate(sizeof(*d));
    if (!d)
        return OUTOFMEMORY;
    zero(d, sizeof(*d));
    d->v = &dvt;
    d->refs = 1;
    d->wide = f->wide;
    d->gain = 10000;
    for (int i = 0; i < 4; i++) {
        d->max[i] = 65535;
        d->saturation[i] = 10000;
    }
    born();
    *out = d;
    return OK;
}
/* Real Logitech wheels the system backend would also report. Hidden so the
 * game sees one wheel: ours, which has working force feedback. */
static int hidden_product(const GUID *product) {
    static const U32 ids[] = {0xc266046d, 0xc267046d, 0xc26d046d, 0xc26e046d, 0xc24f046d, 0xc262046d};
    for (U32 i = 0; i < sizeof(ids) / sizeof(*ids); i++)
        if (product->a == ids[i] && same(&(GUID){ids[i], 0, 0, {0, 0, 0x50, 0x49, 0x44, 0x56, 0x49, 0x44}}, product))
            return 1;
    return 0;
}
typedef struct {
    PTR cb, ctx;
} EnumContext;
static int enum_filter(const unsigned char *info, PTR c) {
    EnumContext *e = c;
    if (hidden_product((const GUID *)(info + 20)))
        return 1;
    return ((int (*)(const void *, PTR))e->cb)(info, e->ctx);
}
static HR enumerate(Factory *f, U32 kind, PTR cb, PTR ctx, U32 flags) {
    if (!cb)
        return INVALID;
    int more = 1;
    /* All devices, game controllers, or driving devices. */
    if (!kind || kind == 4 || (kind & 0xff) == 0x16) {
        Snapshot snapshot;
        if (!(flags & 1) || read_snapshot(&snapshot)) {
            fa(f);
            if (f->wide) {
                InstanceW info;
                instance_info(&info, 1);
                more = ((int (*)(const InstanceW *, PTR))cb)(&info, ctx);
            } else {
                InstanceA info;
                instance_info(&info, 0);
                more = ((int (*)(const InstanceA *, PTR))cb)(&info, ctx);
            }
            fr(f);
        }
    }
    if (more && f->real) {
        EnumContext e = {cb, ctx};
        return f->real->v->EnumDevices(f->real, kind, (PTR)enum_filter, &e, flags);
    }
    return OK;
}
static HR status(Factory *f, const GUID *g) {
    if (!same(g, &virtualGuid))
        return f->real ? f->real->v->GetDeviceStatus(f->real, g) : NOTFOUND;
    Snapshot s;
    return read_snapshot(&s) ? OK : 1; /* DI_NOTATTACHED */
}
static HR panel(Factory *f, PTR h, U32 flags) { return f->real ? f->real->v->RunControlPanel(f->real, h, flags) : OK; }
static HR initialize(Factory *f, PTR h, U32 version) {
    (void)h;
    (void)f;
    return version == 0x800 ? OK : INVALID;
}
static HR find(Factory *f, const GUID *g, const void *n, GUID *out) {
    if (f->real)
        return f->real->v->FindDevice(f->real, g, n, out);
    if (out)
        zero(out, 16);
    return NOTFOUND;
}
static HR semantics(Factory *f, const void *n, PTR fmt, PTR cb, PTR ctx, U32 flags) {
    return f->real ? f->real->v->EnumDevicesBySemantics(f->real, n, fmt, cb, ctx, flags) : OK;
}
static HR configure(Factory *f, PTR cb, PTR p, U32 flags, PTR ctx) {
    return f->real ? f->real->v->ConfigureDevices(f->real, cb, p, flags, ctx) : UNSUPPORTED;
}
static const FactoryVT fvt = {fq,    fa,         fr,   create,    enumerate, status,
                              panel, initialize, find, semantics, configure};
#ifdef CFB_TEST
static Factory *real_factory(PTR h, U32 version, const GUID *i) {
    (void)h, (void)version, (void)i;
    return 0;
}
#else
IMPORT U32 GetSystemDirectoryW(U16 *, U32);
IMPORT PTR LoadLibraryW(const U16 *);
IMPORT PTR GetProcAddress(PTR, const char *);
typedef HR (*CreateFn)(PTR, U32, const GUID *, void **, PTR);
static CreateFn realCreate;
static int realTried;
/* Loaded lazily (never under the loader lock). Failure only disables
 * passthrough of non-wheel devices. */
static Factory *real_factory(PTR h, U32 version, const GUID *i) {
    if (!__atomic_exchange_n(&realTried, 1, __ATOMIC_ACQ_REL)) {
        U16 path[300];
        U32 n = GetSystemDirectoryW(path, 280);
        const char *leaf = "\\dinput8.dll";
        if (n && n < 280) {
            for (U32 k = 0;; k++) {
                path[n + k] = (U16)leaf[k];
                if (!leaf[k])
                    break;
            }
            PTR lib = LoadLibraryW(path);
            if (lib && lib != module)
                __atomic_store_n(&realCreate, (CreateFn)GetProcAddress(lib, "DirectInput8Create"), __ATOMIC_RELEASE);
        }
        event(realCreate ? "Passthrough_LOADED" : "Passthrough_UNAVAILABLE", n, 0);
    }
    CreateFn fn = __atomic_load_n(&realCreate, __ATOMIC_ACQUIRE);
    void *real = 0;
    if (fn && fn(h, version, i, &real, 0) != OK)
        real = 0;
    return real;
}
#endif
HR DirectInput8Create(PTR h, U32 version, const GUID *i, void **out, PTR outer) {
    event("DirectInput8Create", version, i);
    if (!out)
        return POINTER;
    *out = 0;
    if (outer)
        return NOAGGREGATION;
    if (version < 0x800)
        return INVALID;
    if (!same(i, &iidA) && !same(i, &iidW))
        return NOINTERFACE;
    Factory *f = allocate(sizeof(*f));
    if (!f)
        return OUTOFMEMORY;
    zero(f, sizeof(*f));
    f->v = &fvt;
    f->refs = 1;
    f->wide = same(i, &iidW);
    f->real = real_factory(h, version, i);
    born();
    *out = f;
    return OK;
}
HR DllCanUnloadNow(void) { return __atomic_load_n(&liveObjects, __ATOMIC_RELAXED) ? 1 : 0; }
HR DllGetClassObject(const GUID *c, const GUID *i, void **out) {
    (void)c;
    (void)i;
    if (out)
        *out = 0;
    return 0x80040111u; /* CLASS_E_CLASSNOTAVAILABLE */
}
HR DllRegisterServer(void) { return OK; }
HR DllUnregisterServer(void) { return OK; }
