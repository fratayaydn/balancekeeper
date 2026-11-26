// All responses and preferences stay in memory. The executable path points to a private bundle fixture.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <assert.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

static NSMutableDictionary *preferences;
static NSString *executablePath;
static NSDictionary *releaseFixture;
static NSString *savedVersion;
static NSDictionary *savedPreferences;
static int requests, downloads;
static NSInteger responseStatus = 200;
static BOOL allowInstall;

static CFPropertyListRef fixtureCopy(CFStringRef key, CFStringRef app) {
    assert([(__bridge NSString *)app isEqual:@"io.github.fratayaydn.balancekeeper"]);
    return CFBridgingRetain(preferences[(__bridge NSString *)key]);
}

static Boolean fixtureSynchronize(CFStringRef app) {
    assert([(__bridge NSString *)app isEqual:@"io.github.fratayaydn.balancekeeper"]);
    return true;
}

static void fixtureSet(CFStringRef key, CFPropertyListRef value, CFStringRef app) {
    assert([(__bridge NSString *)app isEqual:@"io.github.fratayaydn.balancekeeper"]);
    assert(([@[@"LatestVersion", @"LastUpdateCheck", @"LastUpdateCheckOSBuild"] containsObject:(__bridge NSString *)key]));
    preferences[(__bridge NSString *)key] = (__bridge id)value;
}

static int fixtureSysctl(const char *name, void *value, size_t *size, void *newValue, size_t newSize) {
    assert(strcmp(name, "kern.osversion") == 0 && *size >= sizeof("25A123"));
    memcpy(value, "25A123", sizeof("25A123"));
    *size = sizeof("25A123");
    return 0;
}

static OSStatus fixtureCreateCode(CFURLRef path, SecCSFlags flags, SecStaticCodeRef *code) {
    assert(allowInstall);
    *code = (SecStaticCodeRef)CFRetain(CFSTR("fixture"));
    return errSecSuccess;
}

static OSStatus fixtureCheckCode(SecStaticCodeRef code, SecCSFlags flags, SecRequirementRef requirement) {
    assert(allowInstall && code && requirement);
    return errSecSuccess;
}

// Simulate mounting and copying a signed release inside the private fixture directory.
@interface FixtureTool : NSObject
@property(copy) NSURL *executableURL;
@property(copy) NSArray<NSString *> *arguments;
@property(strong) id standardInput, standardOutput, standardError;
@property(copy) void (^terminationHandler)(FixtureTool *);
@property BOOL running;
@property NSTaskTerminationReason terminationReason;
@property int terminationStatus;
@end
@implementation FixtureTool
- (BOOL)launchAndReturnError:(NSError **)error {
    assert(allowInstall);
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([self.executableURL.path isEqual:@"/usr/bin/hdiutil"]) {
        if ([self.arguments.firstObject isEqual:@"attach"]) {
            NSString *volume = [self.arguments[5] stringByAppendingPathComponent:@"release"];
            assert([fm createDirectoryAtPath:volume withIntermediateDirectories:NO attributes:nil error:NULL]);
            NSString *source = executablePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
            NSString *app = [volume stringByAppendingPathComponent:@"BalanceKeeper.app"];
            assert([fm copyItemAtPath:source toPath:app error:NULL]);
            NSString *plist = [app stringByAppendingPathComponent:@"Contents/Info.plist"];
            NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:plist];
            info[@"CFBundleShortVersionString"] = @"1.2.3";
            assert([info writeToFile:plist atomically:YES]);
        } else {
            assert([self.arguments.firstObject isEqual:@"detach"]);
            assert([fm removeItemAtPath:self.arguments.lastObject error:NULL]);
        }
    } else {
        assert([self.executableURL.path isEqual:@"/usr/bin/ditto"]);
        assert([fm copyItemAtPath:self.arguments[0] toPath:self.arguments[1] error:NULL]);
    }
    self.terminationReason = NSTaskTerminationReasonExit;
    return YES;
}
- (void)waitUntilExit {}
- (void)terminate { assert(NO); }
@end

static int fixtureExecutablePath(char *buffer, uint32_t *size) {
    const char *path = executablePath.fileSystemRepresentation;
    uint32_t needed = (uint32_t)strlen(path) + 1;
    if (*size < needed) { *size = needed; return -1; }
    memcpy(buffer, path, needed);
    return 0;
}

@interface FixtureTask : NSObject
@property(copy) void (^complete)(void);
@property(copy) NSURLRequest *originalRequest;
@end
@implementation FixtureTask
- (void)resume { self.complete(); }
@end

@interface FixtureSession : NSObject
@end
@implementation FixtureSession
+ (instancetype)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    assert(configuration.URLCache == nil && configuration.HTTPCookieStorage == nil);
    assert(configuration.URLCredentialStorage == nil && !configuration.HTTPShouldSetCookies);
    return [self new];
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    requests++;
    assert([request.URL.absoluteString isEqual:@"https://api.github.com/repos/fratayaydn/balancekeeper/releases/latest"]);
    assert([request valueForHTTPHeaderField:@"Authorization"] == nil);
    assert([[request valueForHTTPHeaderField:@"User-Agent"] isEqual:@"BalanceKeeper/1.0.0"]);
    assert(request.HTTPBody == nil);
    FixtureTask *task = [FixtureTask new];
    task.complete = ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:releaseFixture options:0 error:NULL];
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:responseStatus HTTPVersion:@"HTTP/1.1" headerFields:nil];
        completion(data, response, nil);
    };
    return (NSURLSessionDataTask *)task;
}
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completion {
    downloads++;
    assert([request.URL.absoluteString isEqual:@"https://github.com/fratayaydn/balancekeeper/releases/download/v1.2.3/BalanceKeeper-1.2.3.dmg"]);
    FixtureTask *task = [FixtureTask new];
    task.complete = ^{
        if (allowInstall) {
            NSURL *file = [NSURL fileURLWithPath:[executablePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"download"]];
            assert([[NSMutableData dataWithLength:123] writeToURL:file atomically:YES]);
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
            completion(file, response, nil);
        } else {
            completion(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
        }
    };
    return (NSURLSessionDownloadTask *)task;
}
- (void)invalidateAndCancel {}
@end

#define CFPreferencesAppSynchronize fixtureSynchronize
#define CFPreferencesCopyAppValue fixtureCopy
#define CFPreferencesSetAppValue fixtureSet
#define _NSGetExecutablePath fixtureExecutablePath
#define sysctlbyname fixtureSysctl
#define SecStaticCodeCreateWithPath fixtureCreateCode
#define SecStaticCodeCheckValidity fixtureCheckCode
#define NSTask FixtureTool
#define NSURLSession FixtureSession
#import "../Sources/Updater/Updater.m"
#undef NSURLSession
#undef NSTask
#undef SecStaticCodeCheckValidity
#undef SecStaticCodeCreateWithPath
#undef sysctlbyname
#undef _NSGetExecutablePath
#undef CFPreferencesSetAppValue
#undef CFPreferencesCopyAppValue
#undef CFPreferencesAppSynchronize
#define main updaterMain
#import "../Sources/Updater/main.m"
#undef main

static int command(const char *mode) {
    requests = downloads = 0;
    [preferences removeAllObjects];
    if (savedPreferences) [preferences addEntriesFromDictionary:savedPreferences];
    if (savedVersion) preferences[@"LatestVersion"] = savedVersion;
    const char *argv[] = {"balancekeeper-update", mode};
    return updaterMain(mode ? 2 : 1, argv);
}

int main(void) {
    @autoreleasepool {
        ReleaseSessionDelegate *delegate = [ReleaseSessionDelegate new];
        NSURLRequest *redirect = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://example.invalid/redirect"]];
        for (NSString *host in @[@"api.github.com", @"github.com"]) {
            FixtureTask *task = [FixtureTask new];
            task.originalRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:[@"https://" stringByAppendingString:host]]];
            __block BOOL called = NO;
            [delegate URLSession:(id)[FixtureSession new] task:(NSURLSessionTask *)task
                willPerformHTTPRedirection:[[NSHTTPURLResponse alloc] initWithURL:task.originalRequest.URL statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:nil] newRequest:redirect
                completionHandler:^(NSURLRequest *request) {
                    called = YES;
                    assert([host isEqual:@"api.github.com"] ? request == nil : request == redirect);
                }];
            assert(called);
        }
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *directory = [fm.currentDirectoryPath stringByAppendingPathComponent:[@".build/updater-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *contents = [directory stringByAppendingPathComponent:@"BalanceKeeper.app/Contents"];
        NSString *macOS = [contents stringByAppendingPathComponent:@"MacOS"];
        assert([fm createDirectoryAtPath:macOS withIntermediateDirectories:YES attributes:nil error:NULL]);
        executablePath = [macOS stringByAppendingPathComponent:@"balancekeeper-update"];
        assert([NSData.data writeToFile:executablePath atomically:YES]);
        NSDictionary *info = @{@"CFBundleIdentifier": @"io.github.fratayaydn.balancekeeper", @"CFBundleShortVersionString": @"1.0.0"};
        assert([info writeToFile:[contents stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
        preferences = [NSMutableDictionary dictionary];
        releaseFixture = @{@"tag_name": @"v1.2.3", @"draft": @NO, @"prerelease": @NO,
            @"assets": @[@{@"name": @"BalanceKeeper-1.2.3.dmg", @"size": @123,
                @"browser_download_url": @"https://github.com/fratayaydn/balancekeeper/releases/download/v1.2.3/BalanceKeeper-1.2.3.dmg"}]};
        assert(command("--check") == 0);
        assert(requests == 1 && downloads == 0);
        assert([preferences[@"LatestVersion"] isEqual:@"1.2.3"]);
        assert([preferences[@"LastUpdateCheck"] isKindOfClass:NSDate.class]);
        assert([preferences[@"LastUpdateCheckOSBuild"] isEqual:@"25A123"]);
        assert([[NSDictionary dictionaryWithContentsOfFile:[contents stringByAppendingPathComponent:@"Info.plist"]] isEqual:info]);
        assert(command("--install") != 0); // The fixture refuses the download before verification or installation.
        assert(requests == 1 && downloads == 1);
        assert([preferences[@"LatestVersion"] isEqual:@"1.2.3"]);
        savedPreferences = @{@"AutomaticallyInstallUpdates": @YES};
        assert(command("--check") == 0 && requests == 1 && downloads == 0);
        savedPreferences = @{@"AutomaticallyInstallUpdates": @NO};
        assert(command("--scheduled") == 0 && requests == 0 && downloads == 0);
        assert(preferences.count == 1);
        savedPreferences = @{@"LastUpdateCheck": NSDate.date, @"LastUpdateCheckOSBuild": @"25A123"};
        assert(command("--scheduled") == 0 && requests == 0 && downloads == 0);
        assert(preferences.count == 2);
        for (NSDictionary *state in @[@{},
            @{@"LastUpdateCheck": [NSDate dateWithTimeIntervalSinceNow:-20 * 60 * 60], @"LastUpdateCheckOSBuild": @"25A123"},
            @{@"LastUpdateCheck": NSDate.date, @"LastUpdateCheckOSBuild": @"old-build"}]) {
            savedPreferences = state;
            allowInstall = YES;
            assert(command("--scheduled") == 0 && requests == 1 && downloads == 1);
            assert([preferences[@"LatestVersion"] isEqual:@"1.2.3"]);
            assert([preferences[@"LastUpdateCheck"] isKindOfClass:NSDate.class]);
            assert([preferences[@"LastUpdateCheckOSBuild"] isEqual:@"25A123"]);
            assert([[NSDictionary dictionaryWithContentsOfFile:[contents stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleShortVersionString"] isEqual:@"1.2.3"]);
            assert([info writeToFile:[contents stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
            allowInstall = NO;
        }
        savedPreferences = @{@"AutomaticallyInstallUpdates": @NO};
        allowInstall = YES;
        assert(command("--install") == 0 && requests == 1 && downloads == 1);
        assert([preferences[@"LastUpdateCheck"] isKindOfClass:NSDate.class]);
        assert([preferences[@"LastUpdateCheckOSBuild"] isEqual:@"25A123"]);
        assert([info writeToFile:[contents stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
        allowInstall = NO;
        savedPreferences = nil;
        int lock = open([contents stringByDeletingLastPathComponent].fileSystemRepresentation, O_RDONLY);
        assert(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0);
        assert(command("--scheduled") == 0 && requests == 0 && downloads == 0);
        assert(command("--check") != 0 && requests == 0 && downloads == 0);
        assert(command("--install") != 0 && requests == 0 && downloads == 0);
        assert(flock(lock, LOCK_UN) == 0 && close(lock) == 0);
        for (NSString *mode in @[@"--automatic", @"--force", @"--notify-update", @""]) {
            assert(command(mode.UTF8String) != 0);
            assert(requests == 0 && downloads == 0 && preferences.count == 0);
        }
        assert(command(NULL) != 0 && requests == 0 && downloads == 0);
        releaseFixture = @{@"tag_name": @"v1.0.0", @"draft": @NO, @"prerelease": @NO};
        assert(command("--check") == 0 && requests == 1 && downloads == 0);
        assert(command("--install") != 0 && requests == 1 && downloads == 0);
        savedVersion = @"1.2.3";
        assert(command("--install") != 0 && downloads == 0);
        assert([preferences[@"LatestVersion"] isEqual:@"1.0.0"]);
        assert(command("--check") == 0 && downloads == 0);
        assert([preferences[@"LatestVersion"] isEqual:@"1.0.0"]);
        savedVersion = nil;
        responseStatus = 404;
        assert(command("--check") == 0 && requests == 1 && downloads == 0);
        assert(command("--install") != 0 && requests == 1 && downloads == 0);
        responseStatus = 500;
        assert(command("--check") != 0 && preferences.count == 0);
        assert([fm removeItemAtPath:directory error:NULL]);
        puts("PASS: scheduled updates obey preferences, due time, OS build and busy locks; manual checks never install; requested and scheduled installs replace the fixture bundle");
    }
    return 0;
}
