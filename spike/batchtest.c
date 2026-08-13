#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdint.h>
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef void (*CB)(void*,void*,void*,IOHIDEventRef);
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef, CB, void*, void*);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
extern int32_t IOHIDEventGetType(IOHIDEventRef);
extern uint64_t IOHIDEventGetTimeStamp(IOHIDEventRef);
extern Boolean IOHIDServiceClientSetProperty(IOHIDServiceClientRef, CFStringRef, CFTypeRef);
static double nm=1,dn=1; static uint64_t prev_arr=0; static int n=0;
static double gaps[8000]; static double lag[8000];
static void cb(void*a,void*b,void*c,IOHIDEventRef e){
  if(IOHIDEventGetType(e)!=13) return;
  uint64_t arr=mach_absolute_time(), ts=IOHIDEventGetTimeStamp(e);
  if(n<8000){ gaps[n]= prev_arr? (double)(arr-prev_arr)*nm/dn/1e6 : 0; lag[n]=(double)(arr-ts)*nm/dn/1e6; }
  prev_arr=arr; n++;
}
static int cmpd(const void*x,const void*y){double a=*(double*)x,b=*(double*)y;return a<b?-1:a>b;}
static void done(CFRunLoopTimerRef t,void*i){
  int m=n<8000?n:8000; double g[8000],l[8000];
  for(int j=1;j<m;j++){g[j-1]=gaps[j];l[j-1]=lag[j];}
  qsort(g,m-1,sizeof(double),cmpd); qsort(l,m-1,sizeof(double),cmpd);
  printf("n=%d  arrival-gap ms: p50=%.3f p95=%.3f max=%.3f\n",m,g[(m-1)/2],g[(int)((m-1)*0.95)],g[m-2]);
  printf("        event->arrival lag ms: p50=%.3f p95=%.3f max=%.3f\n",l[(m-1)/2],l[(int)((m-1)*0.95)],l[m-2]);
  CFRunLoopStop(CFRunLoopGetCurrent());
}
int main(){
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); nm=tb.numer; dn=tb.denom;
  IOHIDEventSystemClientRef c=IOHIDEventSystemClientCreate(kCFAllocatorDefault);
  int pg=0xFF00,us=3; CFNumberRef p=CFNumberCreate(NULL,kCFNumberIntType,&pg),u=CFNumberCreate(NULL,kCFNumberIntType,&us);
  const void*k[]={CFSTR("PrimaryUsagePage"),CFSTR("PrimaryUsage")}; const void*v[]={p,u};
  IOHIDEventSystemClientSetMatching(c,CFDictionaryCreate(NULL,k,v,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks));
  CFArrayRef s=IOHIDEventSystemClientCopyServices(c);
  IOHIDServiceClientRef sv=(IOHIDServiceClientRef)CFArrayGetValueAtIndex(s,0);
  int64_t iv=1250,z=0;
  IOHIDServiceClientSetProperty(sv,CFSTR("ReportInterval"),CFNumberCreate(NULL,kCFNumberSInt64Type,&iv));
  IOHIDServiceClientSetProperty(sv,CFSTR("BatchInterval"),CFNumberCreate(NULL,kCFNumberSInt64Type,&z));
  IOHIDEventSystemClientRegisterEventCallback(c,cb,NULL,NULL);
  IOHIDEventSystemClientScheduleWithRunLoop(c,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(),CFRunLoopTimerCreate(NULL,CFAbsoluteTimeGetCurrent()+5.0,0,0,0,done,NULL),kCFRunLoopDefaultMode);
  CFRunLoopRun(); return 0;
}
