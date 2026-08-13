// Spike 2: activate the SPU accelerometer by setting ReportInterval, then
// measure the delivered sample rate. Also tries a direct poll as fallback.
// Build: clang -O2 -framework CoreFoundation -framework IOKit imuspike2.c -o imuspike2
// Usage: ./imuspike2 [report_interval_us]

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef void (*IOHIDEventSystemClientEventCallback)(void *target, void *refcon,
                                                    void *sender, IOHIDEventRef event);

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef,
                                                        IOHIDEventSystemClientEventCallback,
                                                        void *, void *);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
extern int32_t IOHIDEventGetType(IOHIDEventRef);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t field);
extern uint64_t IOHIDEventGetTimeStamp(IOHIDEventRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern Boolean IOHIDServiceClientSetProperty(IOHIDServiceClientRef, CFStringRef, CFTypeRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t type,
                                                 int32_t options, int64_t timeout);

#define EVT_ACCEL 13
#define FIELD(t, i) (((t) << 16) | (i))

static uint64_t g_count = 0, g_first_ts = 0, g_last_ts = 0;
static double mt_num = 1.0, mt_den = 1.0;
static double ns(uint64_t m) { return (double)m * mt_num / mt_den; }

static void on_event(void *t, void *r, void *s, IOHIDEventRef e) {
    if (IOHIDEventGetType(e) != EVT_ACCEL) return;
    uint64_t ts = IOHIDEventGetTimeStamp(e);
    if (g_count == 0) g_first_ts = ts;
    g_last_ts = ts;
    if (g_count < 6)
        printf("  cb sample %llu t=%.3fms  x=%+.6f y=%+.6f z=%+.6f\n", g_count,
               ns(ts - g_first_ts) / 1e6,
               IOHIDEventGetFloatValue(e, FIELD(EVT_ACCEL, 0)),
               IOHIDEventGetFloatValue(e, FIELD(EVT_ACCEL, 1)),
               IOHIDEventGetFloatValue(e, FIELD(EVT_ACCEL, 2)));
    g_count++;
}

static void done(CFRunLoopTimerRef t, void *info) {
    double secs = ns(g_last_ts - g_first_ts) / 1e9;
    printf("\n--- callback: %llu events in %.3f s => %.1f Hz ---\n", g_count, secs,
           secs > 0 ? (double)(g_count - 1) / secs : 0.0);
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static CFNumberRef num(int64_t v) { return CFNumberCreate(NULL, kCFNumberSInt64Type, &v); }

int main(int argc, char **argv) {
    int64_t interval_us = (argc > 1) ? atoll(argv[1]) : 1250;  // 1250us == 800Hz
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    mt_num = tb.numer; mt_den = tb.denom;

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    int page = 0xFF00, usage = 3;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *k[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *v[] = { p, u };
    CFDictionaryRef match = CFDictionaryCreate(NULL, k, v, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services || CFArrayGetCount(services) == 0) { fprintf(stderr, "no service\n"); return 2; }
    IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, 0);

    // Probe a set of properties that plausibly gate or describe the stream.
    const CFStringRef probe[] = { CFSTR("ReportInterval"), CFSTR("BatchInterval"),
                                  CFSTR("SampleInterval"), CFSTR("MaxFrequency"),
                                  CFSTR("SensorPerformanceMode"), CFSTR("Sensitivity"),
                                  CFSTR("MaxEventLatency") };
    for (size_t i = 0; i < sizeof probe / sizeof *probe; i++) {
        CFTypeRef val = IOHIDServiceClientCopyProperty(svc, probe[i]);
        CFStringRef d = CFStringCreateWithFormat(NULL, NULL, CFSTR("  before %@ = %@"), probe[i], val);
        char b[256]; CFStringGetCString(d, b, sizeof b, kCFStringEncodingUTF8);
        printf("%s\n", b); CFRelease(d); if (val) CFRelease(val);
    }

    CFNumberRef iv = num(interval_us);
    Boolean okReport = IOHIDServiceClientSetProperty(svc, CFSTR("ReportInterval"), iv);
    CFNumberRef zero = num(0);
    Boolean okBatch = IOHIDServiceClientSetProperty(svc, CFSTR("BatchInterval"), zero);
    printf("  set ReportInterval(%lldus)=%d  BatchInterval(0)=%d\n", interval_us, okReport, okBatch);

    CFTypeRef after = IOHIDServiceClientCopyProperty(svc, CFSTR("ReportInterval"));
    CFStringRef d = CFStringCreateWithFormat(NULL, NULL, CFSTR("  after ReportInterval = %@"), after);
    char b[256]; CFStringGetCString(d, b, sizeof b, kCFStringEncodingUTF8); printf("%s\n", b);

    // Direct poll fallback.
    IOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, EVT_ACCEL, 0, 0);
    if (ev) {
        printf("  poll: x=%+.6f y=%+.6f z=%+.6f\n",
               IOHIDEventGetFloatValue(ev, FIELD(EVT_ACCEL, 0)),
               IOHIDEventGetFloatValue(ev, FIELD(EVT_ACCEL, 1)),
               IOHIDEventGetFloatValue(ev, FIELD(EVT_ACCEL, 2)));
        CFRelease(ev);
    } else {
        printf("  poll: CopyEvent returned NULL\n");
    }

    IOHIDEventSystemClientRegisterEventCallback(client, on_event, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(client, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 3.0, 0, 0, 0, done, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    CFRunLoopRun();
    return g_count > 0 ? 0 : 3;
}
