// Spike: read the Apple Silicon SPU accelerometer over the private
// IOHIDEventSystemClient interface. Prints sample rate and a few samples.
// Build: clang -O2 -framework CoreFoundation -framework IOKit imuspike.c -o imuspike

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdint.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef void (*IOHIDEventSystemClientEventCallback)(void *target, void *refcon,
                                                    void *sender, IOHIDEventRef event);

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef client,
                                                        IOHIDEventSystemClientEventCallback cb,
                                                        void *target, void *refcon);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef client,
                                                      CFRunLoopRef rl, CFStringRef mode);
extern int32_t IOHIDEventGetType(IOHIDEventRef event);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
extern uint64_t IOHIDEventGetTimeStamp(IOHIDEventRef event);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type,
                                                 int32_t options, int64_t timeout);

#define EVT_ACCEL 13
#define FIELD(type, idx) (((type) << 16) | (idx))

static uint64_t g_count = 0;
static uint64_t g_first_ts = 0, g_last_ts = 0;
static double mt_num = 1.0, mt_den = 1.0;

static double ns(uint64_t mach) { return (double)mach * mt_num / mt_den; }

static void on_event(void *target, void *refcon, void *sender, IOHIDEventRef event) {
    int32_t type = IOHIDEventGetType(event);
    if (type != EVT_ACCEL) return;
    uint64_t ts = IOHIDEventGetTimeStamp(event);
    if (g_count == 0) g_first_ts = ts;
    g_last_ts = ts;
    if (g_count < 8) {
        printf("sample %llu  t=%.6f ms  x=%+.6f y=%+.6f z=%+.6f\n", g_count,
               ns(ts - g_first_ts) / 1e6,
               IOHIDEventGetFloatValue(event, FIELD(EVT_ACCEL, 0)),
               IOHIDEventGetFloatValue(event, FIELD(EVT_ACCEL, 1)),
               IOHIDEventGetFloatValue(event, FIELD(EVT_ACCEL, 2)));
    }
    g_count++;
}

static void done(CFRunLoopTimerRef t, void *info) {
    double secs = ns(g_last_ts - g_first_ts) / 1e9;
    printf("\n--- %llu accel events in %.3f s => %.1f Hz ---\n", g_count, secs,
           secs > 0 ? (double)(g_count - 1) / secs : 0.0);
    CFRunLoopStop(CFRunLoopGetCurrent());
}

int main(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    mt_num = tb.numer; mt_den = tb.denom;

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) { fprintf(stderr, "IOHIDEventSystemClientCreate failed\n"); return 1; }

    int page = 0xFF00, usage = 3;
    CFNumberRef pageRef = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usageRef = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { pageRef, usageRef };
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    CFIndex n = services ? CFArrayGetCount(services) : 0;
    printf("matched services: %ld\n", (long)n);
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef prod = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
        CFTypeRef rate = IOHIDServiceClientCopyProperty(s, CFSTR("ReportInterval"));
        CFStringRef desc = CFStringCreateWithFormat(NULL, NULL, CFSTR("  [%ld] product=%@ reportInterval=%@"),
                                                    (long)i, prod, rate);
        char buf[512];
        CFStringGetCString(desc, buf, sizeof buf, kCFStringEncodingUTF8);
        printf("%s\n", buf);
        CFRelease(desc);
        if (prod) CFRelease(prod);
        if (rate) CFRelease(rate);
    }
    if (n == 0) {
        fprintf(stderr, "no accelerometer service matched (Input Monitoring permission?)\n");
        return 2;
    }

    IOHIDEventSystemClientRegisterEventCallback(client, on_event, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(client, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 3.0, 0, 0, 0, done, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    CFRunLoopRun();
    return g_count > 0 ? 0 : 3;
}
