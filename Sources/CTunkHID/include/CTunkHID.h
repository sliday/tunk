// Declarations for the private IOHIDEventSystemClient API used to read the
// Apple Silicon SPU accelerometer, plus small C helpers for things Swift cannot
// express directly.
//
// These symbols live in IOKit.framework but are not in any public header. They
// have been stable across macOS releases and are what macimu / spank use. All
// calls are guarded at runtime: if a symbol or the service is missing, TunkIMU
// reports a clean failure rather than crashing.

#ifndef CTUNKHID_H
#define CTUNKHID_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef struct __IOHIDEvent *TunkHIDEventRef;
typedef struct __IOHIDServiceClient *TunkHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *TunkHIDEventSystemClientRef;

typedef void (*TunkHIDEventCallback)(void *target, void *refcon, void *sender,
                                     TunkHIDEventRef event);

extern TunkHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(TunkHIDEventSystemClientRef client,
                                              CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(TunkHIDEventSystemClientRef client);
extern void IOHIDEventSystemClientRegisterEventCallback(TunkHIDEventSystemClientRef client,
                                                        TunkHIDEventCallback callback,
                                                        void *target, void *refcon);
extern void IOHIDEventSystemClientUnregisterEventCallback(TunkHIDEventSystemClientRef client,
                                                          TunkHIDEventCallback callback,
                                                          void *target, void *refcon);
extern void IOHIDEventSystemClientScheduleWithRunLoop(TunkHIDEventSystemClientRef client,
                                                      CFRunLoopRef runLoop, CFStringRef mode);
extern void IOHIDEventSystemClientUnscheduleFromRunLoop(TunkHIDEventSystemClientRef client,
                                                        CFRunLoopRef runLoop, CFStringRef mode);
extern void IOHIDEventSystemClientScheduleWithDispatchQueue(TunkHIDEventSystemClientRef client,
                                                            dispatch_queue_t queue);
extern void IOHIDEventSystemClientUnscheduleFromDispatchQueue(TunkHIDEventSystemClientRef client,
                                                              dispatch_queue_t queue);

extern int32_t IOHIDEventGetType(TunkHIDEventRef event);
extern double IOHIDEventGetFloatValue(TunkHIDEventRef event, int32_t field);
extern uint64_t IOHIDEventGetTimeStamp(TunkHIDEventRef event);

extern CFTypeRef IOHIDServiceClientCopyProperty(TunkHIDServiceClientRef service, CFStringRef key);
extern Boolean IOHIDServiceClientSetProperty(TunkHIDServiceClientRef service, CFStringRef key,
                                             CFTypeRef value);

/// `kIOHIDEventTypeAccelerometer`. Verified on this machine: the accel service
/// delivers events of this type and no other.
static const int32_t kTunkEventTypeAccelerometer = 13;

/// Field selector for accelerometer axis `axis` (0 = x, 1 = y, 2 = z).
static inline int32_t TunkAccelField(int32_t axis) {
    return (kTunkEventTypeAccelerometer << 16) | axis;
}

/// `PrimaryUsagePage` / `PrimaryUsage` that select the accelerometer service.
static const int32_t kTunkAccelUsagePage = 0xFF00;
static const int32_t kTunkAccelUsage = 3;

#endif /* CTUNKHID_H */
