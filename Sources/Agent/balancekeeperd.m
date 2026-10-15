// balancekeeperd: keeps the audio balance (left/right) at the lock point, centered by default.
// Event-driven: wakes only when macOS reports a balance or output device change; does nothing while idle (no polling).
//
// The lock point lives in the "io.github.fratayaydn.balancekeeper" preferences domain; BalanceKeeper.app writes it
// and posts SETTINGS_CHANGED_NOTIFICATION. Each correction is counted there too, so the app can show how often the
// balance actually drifts.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioServices.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>

#define PREFS_DOMAIN                  CFSTR("io.github.fratayaydn.balancekeeper")
#define SETTINGS_CHANGED_NOTIFICATION CFSTR("io.github.fratayaydn.balancekeeper.SettingsChanged")
#define STATUS_CHANGED_NOTIFICATION   CFSTR("io.github.fratayaydn.balancekeeper.StatusChanged")
#define KEY_LOCK_POINT                CFSTR("LockPoint")       // 0 = full left, 0.5 = center, 1 = full right
#define KEY_FIX_COUNT                 CFSTR("CorrectionCount")
#define KEY_LAST_FIX                  CFSTR("LastCorrection")  // date
#define AGENT_PLIST                   @"io.github.fratayaydn.balancekeeper.agent.plist"

// ServiceManagement is loaded only when the app is removed, so it costs no memory while running.
@interface NSObject (SMAppService)
+ (id)agentServiceWithPlistName:(NSString *)name;
- (BOOL)unregisterAndReturnError:(NSError **)error;
@end

static Float32 gLockPoint = 0.5f;
static BOOL gCountFixes = YES;  // NO while applying a new lock point or a new output: not a drift
static AudioDeviceID gDevice = kAudioObjectUnknown;
static dispatch_queue_t gQueue;
static AudioObjectPropertyListenerBlock gDeviceListener;
static dispatch_source_t gBundleWatch;
static char gExecutable[PATH_MAX];  // our path inside BalanceKeeper.app, to see if a new copy replaced it

static AudioObjectPropertyAddress addr(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, AudioObjectPropertyElement el) {
    return (AudioObjectPropertyAddress){ sel, scope, el };
}

static BOOL getFloat(AudioDeviceID d, AudioObjectPropertyAddress a, Float32 *v) {
    UInt32 sz = sizeof(*v);
    return AudioObjectHasProperty(d, &a) && AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, v) == noErr;
}

static BOOL settable(AudioDeviceID d, AudioObjectPropertyAddress a) {
    Boolean s = false;
    return AudioObjectHasProperty(d, &a) && AudioObjectIsPropertySettable(d, &a, &s) == noErr && s;
}

static NSString *deviceName(AudioDeviceID d) {
    AudioObjectPropertyAddress a = addr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    CFStringRef name = NULL;
    UInt32 sz = sizeof(name);
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &name) != noErr || !name) return @"?";
    return (__bridge_transfer NSString *)name;
}

#pragma mark - Settings and status

static void loadSettings(void) {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    CFPropertyListRef v = CFPreferencesCopyAppValue(KEY_LOCK_POINT, PREFS_DOMAIN);
    double d = 0.5;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberDoubleType, &d);
    if (v) CFRelease(v);
    gLockPoint = d < 0 ? 0 : d > 1 ? 1 : (Float32)d;
}

// Written only when a correction happens: shows how often the drift actually occurs.
static void recordFix(const char *what, Float32 from, Float32 to) {
    if (!gCountFixes) return;
    fprintf(stderr, "balancekeeperd: %s: %s %.3f -> %.3f\n", deviceName(gDevice).UTF8String, what, from, to);
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    CFPropertyListRef v = CFPreferencesCopyAppValue(KEY_FIX_COUNT, PREFS_DOMAIN);
    long count = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &count);
    if (v) CFRelease(v);
    count++;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberLongType, &count);
    CFDateRef now = CFDateCreate(NULL, CFAbsoluteTimeGetCurrent());
    CFPreferencesSetAppValue(KEY_FIX_COUNT, n, PREFS_DOMAIN);
    CFPreferencesSetAppValue(KEY_LAST_FIX, now, PREFS_DOMAIN);
    CFRelease(n);
    CFRelease(now);
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(), STATUS_CHANGED_NOTIFICATION, NULL, NULL, true);
}

#pragma mark - Balance

static void enforce(void) {
    AudioDeviceID d = gDevice;
    if (d == kAudioObjectUnknown) return;

    // 1) Built-in speakers and most devices: balance is a single "pan" value.
    AudioObjectPropertyAddress pan = addr(kAudioDevicePropertyStereoPan, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain);
    Float32 p;
    if (settable(d, pan) && getFloat(d, pan, &p)) {
        if (fabsf(p - gLockPoint) > 0.001f) {
            AudioObjectSetPropertyData(d, &pan, 0, NULL, sizeof(gLockPoint), &gLockPoint);
            recordFix("balance", p, gLockPoint);
        }
        return;
    }

    // 2) Bluetooth headphones (e.g. AirPods) and many USB devices: the system's virtual balance control.
    AudioObjectPropertyAddress vb = addr(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain);
    Float32 b;
    if (settable(d, vb) && getFloat(d, vb, &b)) {
        if (fabsf(b - gLockPoint) > 0.001f) {
            AudioObjectSetPropertyData(d, &vb, 0, NULL, sizeof(gLockPoint), &gLockPoint);
            recordFix("balance", b, gLockPoint);
        }
        return;
    }

    // 3) Devices with only separate left and right channel volumes: raise the lowered channel to match.
    // (Only for a centered lock point; there is no balance value to lock elsewhere.)
    if (fabsf(gLockPoint - 0.5f) > 0.001f) return;
    AudioObjectPropertyAddress l = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 1);
    AudioObjectPropertyAddress r = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 2);
    Float32 lv, rv;
    if (settable(d, l) && settable(d, r) && getFloat(d, l, &lv) && getFloat(d, r, &rv) && fabsf(lv - rv) > 0.001f) {
        Float32 v = fmaxf(lv, rv);
        AudioObjectSetPropertyData(d, lv < rv ? &l : &r, 0, NULL, sizeof(v), &v);
        recordFix(lv < rv ? "left channel" : "right channel", fminf(lv, rv), v);
    }
}

static AudioObjectPropertyAddress gWatched[4];

static void watchDevice(AudioDeviceID d) {
    if (gDevice != kAudioObjectUnknown)
        for (int i = 0; i < 4; i++)
            AudioObjectRemovePropertyListenerBlock(gDevice, &gWatched[i], gQueue, gDeviceListener);
    gDevice = d;
    if (d == kAudioObjectUnknown) return;
    for (int i = 0; i < 4; i++)
        if (AudioObjectHasProperty(d, &gWatched[i]))
            AudioObjectAddPropertyListenerBlock(d, &gWatched[i], gQueue, gDeviceListener);
    // Check right away on a device switch (headphones plugged/unplugged). Each output keeps its own balance, so
    // bringing a newly selected one to the lock point is not a drift and is not counted.
    gCountFixes = NO;
    enforce();
    gCountFixes = YES;
}

static AudioDeviceID defaultOutput(void) {
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    AudioDeviceID d = kAudioObjectUnknown;
    UInt32 sz = sizeof(d);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &d);
    return d;
}

static void settingsChanged(CFNotificationCenterRef c, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
    loadSettings();
    gCountFixes = NO;
    enforce();
    gCountFixes = YES;
}

#pragma mark - App bundle

static BOOL selfPath(char *path, uint32_t size) {
    return _NSGetExecutablePath(path, &size) == 0;
}

// Remove our login item, as turning off "Enable BalanceKeeper" does, so nothing is left in Login Items and
// launchd does not start another copy of BalanceKeeper at the next login.
static void unregisterLoginItem(void) {
    if (!dlopen("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement", RTLD_NOW)) return;
    Class cls = NSClassFromString(@"SMAppService");
    NSError *error = nil;
    if (![[cls agentServiceWithPlistName:AGENT_PLIST] unregisterAndReturnError:&error])
        fprintf(stderr, "balancekeeperd: could not remove the login item: %s\n", error.localizedDescription.UTF8String);
}

// BalanceKeeper.app was moved to the Trash or replaced by an update. An update puts a new copy at the same path
// within moments: exit with an error so launchd starts the new agent. Otherwise the app is gone: remove the login
// item and exit for good (a successful exit is not restarted).
static void appMoved(void) {
    dispatch_source_cancel(gBundleWatch);
    for (int i = 0; i < 10; i++) {
        sleep(1);
        struct stat st;
        if (stat(gExecutable, &st) == 0) {
            fprintf(stderr, "balancekeeperd: BalanceKeeper.app was updated, restarting\n");
            exit(1);
        }
    }
    fprintf(stderr, "balancekeeperd: BalanceKeeper.app was removed, exiting\n");
    unregisterLoginItem();  // launchd may stop us right here
    exit(0);
}

// Watch the app bundle through the kernel's event queue: no polling, no wakeups until it moves.
static void watchAppBundle(void) {
    char path[PATH_MAX], resolved[PATH_MAX];
    if (!selfPath(path, sizeof(path)) || !realpath(path, resolved)) return;
    strlcpy(gExecutable, resolved, sizeof(gExecutable));
    char *contents = strstr(resolved, "/Contents/MacOS/");
    if (!contents) return;  // not running from an app bundle
    *contents = 0;
    int fd = open(resolved, O_EVTONLY);
    if (fd < 0) return;
    gBundleWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
                                          DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE,
                                          dispatch_get_main_queue());
    dispatch_source_set_event_handler(gBundleWatch, ^{ appMoved(); });
    dispatch_source_set_cancel_handler(gBundleWatch, ^{ close(fd); });
    dispatch_resume(gBundleWatch);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--status")) {  // for scripts and debugging
            AudioDeviceID d = defaultOutput();
            AudioObjectPropertyAddress pan = addr(kAudioDevicePropertyStereoPan, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain);
            AudioObjectPropertyAddress vb = addr(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain);
            Float32 p;
            if (getFloat(d, pan, &p) || getFloat(d, vb, &p))
                printf("output: %s, balance: %.3f (0.5 = center)\n", deviceName(d).UTF8String, p);
            else
                printf("output: %s, no balance control\n", deviceName(d).UTF8String);
            return 0;
        }

        loadSettings();
        watchAppBundle();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, settingsChanged,
                                        SETTINGS_CHANGED_NOTIFICATION, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        gQueue = dispatch_get_main_queue();
        gWatched[0] = addr(kAudioDevicePropertyStereoPan, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain);
        gWatched[1] = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 1);
        gWatched[2] = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 2);
        gWatched[3] = addr(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain);
        gDeviceListener = ^(UInt32 n, const AudioObjectPropertyAddress *a) { enforce(); };

        AudioObjectPropertyAddress def = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &def, gQueue,
            ^(UInt32 n, const AudioObjectPropertyAddress *a) { watchDevice(defaultOutput()); });
        watchDevice(defaultOutput());

        CFRunLoopRun();  // also serves the main queue (CoreAudio listeners) and distributed notifications
    }
    return 0;
}
