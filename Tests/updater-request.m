// All responses and preferences stay in memory. The executable path points to a private bundle fixture.
#import <Foundation/Foundation.h>
#include <assert.h>
#include <sys/stat.h>

static NSMutableDictionary *preferences;
static NSString *executablePath;
static NSDictionary *releaseFixture;
static NSString *savedVersion;
static int requests, downloads;
static NSInteger responseStatus = 200;

static Boolean fixtureSynchronize(CFStringRef app) {
    assert([(__bridge NSString *)app isEqual:@"io.github.fratayaydn.balancekeeper"]);
    return true;
}

static CFPropertyListRef fixtureCopy(CFStringRef key, CFStringRef app) {
    assert([(__bridge NSString *)app isEqual:@"io.github.fratayaydn.balancekeeper"]);
    assert([(__bridge NSString *)key isEqual:@"LatestVersion"]);
    id value = preferences[(__bridge NSString *)key];
    return value ? CFRetain((__bridge CFTypeRef)value) : NULL;
}

static void fixtureSet(CFStringRef key, CFPropertyListRef value, CFStringRef app) {
    assert([(__bridge NSString *)app isEqual:@"io.github.fratayaydn.balancekeeper"]);
    assert([(__bridge NSString *)key isEqual:@"LatestVersion"]);
    preferences[(__bridge NSString *)key] = (__bridge id)value;
}

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
    task.complete = ^{ completion(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]); };
    return (NSURLSessionDownloadTask *)task;
}
- (void)invalidateAndCancel {}
@end

#define CFPreferencesCopyAppValue fixtureCopy
#define CFPreferencesAppSynchronize fixtureSynchronize
#define CFPreferencesSetAppValue fixtureSet
#define _NSGetExecutablePath fixtureExecutablePath
#define NSURLSession FixtureSession
#import "../Sources/Updater/Updater.m"
#undef NSURLSession
#undef _NSGetExecutablePath
#undef CFPreferencesSetAppValue
#undef CFPreferencesAppSynchronize
#undef CFPreferencesCopyAppValue
#define main updaterMain
#import "../Sources/Updater/main.m"
#undef main

static int command(const char *mode) {
    requests = downloads = 0;
    [preferences removeAllObjects];
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
        assert([[NSDictionary dictionaryWithContentsOfFile:[contents stringByAppendingPathComponent:@"Info.plist"]] isEqual:info]);
        assert(command("--install") != 0); // The fixture refuses the download before verification or installation.
        assert(requests == 1 && downloads == 1);
        assert([preferences[@"LatestVersion"] isEqual:@"1.2.3"]);
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
        assert([preferences[@"LatestVersion"] isEqual:@"1.2.3"]);
        assert(command("--check") == 0 && downloads == 0);
        assert([preferences[@"LatestVersion"] isEqual:@"1.2.3"]);
        savedVersion = nil;
        responseStatus = 404;
        assert(command("--check") == 0 && requests == 1 && downloads == 0);
        assert(command("--install") != 0 && requests == 1 && downloads == 0);
        responseStatus = 500;
        assert(command("--check") != 0 && preferences.count == 0);
        assert([fm removeItemAtPath:directory error:NULL]);
        puts("PASS: check stores LatestVersion without download or install; only --install reaches installation; failures and invalid modes are rejected");
    }
    return 0;
}
