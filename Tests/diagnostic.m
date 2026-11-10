// Exercise the bounded memory log and request/reply using a private notification center.
#include <assert.h>
#include <unistd.h>
#import <Foundation/Foundation.h>

#define CFNotificationCenterGetDistributedCenter CFNotificationCenterGetLocalCenter
#import "../Sources/Agent/DiagnosticLog.h"
#undef CFNotificationCenterGetDistributedCenter

#ifdef BALANCEKEEPER_DIAGNOSTIC_LOG
static void resetLog(void) {
    for (NSUInteger i = 0; i < 500; i++) gDiagnosticEntries[i] = nil;
    gDiagnosticHead = gDiagnosticCount = 0;
}

static void testRing(void) {
    resetLog();
    for (int i = 0; i < 750; i++) DIAG(@"event %d", i);
    NSArray *entries = diagnosticRead();
    assert(entries.count == 500);
    assert([entries.firstObject[@"text"] isEqual:@"event 250"]);
    assert([entries.lastObject[@"text"] isEqual:@"event 749"]);
    for (NSUInteger i = 1; i < entries.count; i++)
        assert([entries[i - 1][@"timestamp"] doubleValue] <= [entries[i][@"timestamp"] doubleValue]);

    // The oldest entry expires on read, even without another event.
    gDiagnosticEntries[gDiagnosticHead] = @{@"timestamp": @(CFAbsoluteTimeGetCurrent() - 301), @"text": @"expired"};
    assert(diagnosticRead().count == 499);
    assert(gDiagnosticEntries[(gDiagnosticHead + 499) % 500] == nil);

    // Expired entries are also removed on add.
    resetLog();
    gDiagnosticEntries[0] = @{@"timestamp": @(CFAbsoluteTimeGetCurrent() - 301), @"text": @"expired"};
    gDiagnosticCount = 1;
    DIAG(@"fresh");
    entries = diagnosticRead();
    assert(entries.count == 1 && [entries.firstObject[@"text"] isEqual:@"fresh"]);
    assert(gDiagnosticEntries[0] == nil);

    resetLog();
    gDiagnosticEntries[0] = @{@"timestamp": @400, @"text": @"boundary"};
    gDiagnosticCount = 1;
    diagnosticPrune(700);
    assert(gDiagnosticCount == 1);
    diagnosticPrune(700.001);
    assert(gDiagnosticCount == 0 && gDiagnosticEntries[0] == nil);
}

static void testReply(void) {
    resetLog();
    DIAG(@"agent start");
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    NSArray *entries = nil;
    CFNotificationCenterAddObserver(center, NULL, diagnosticRequested, LOG_REQUEST, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, &entries, diagnosticReceived, LOG_REPLY, CFSTR("test-token"),
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterPostNotification(center, LOG_REQUEST, NULL, NULL, true);
    assert(entries == nil);
    CFNotificationCenterPostNotification(center, LOG_REQUEST, CFSTR("different-token"), NULL, true);
    assert(entries == nil);
    CFNotificationCenterPostNotification(center, LOG_REQUEST, CFSTR("test-token"), NULL, true);
    assert(entries.count == 1 && [entries.firstObject[@"text"] isEqual:@"agent start"]);
    resetLog();
    entries = nil;
    CFNotificationCenterPostNotification(center, LOG_REQUEST, CFSTR("test-token"), NULL, true);
    assert(entries != nil && entries.count == 0);
    CFNotificationCenterRemoveEveryObserver(center, NULL);
    CFNotificationCenterRemoveEveryObserver(center, &entries);
}

static void testPrint(void) {
    resetLog();
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    CFNotificationCenterAddObserver(center, NULL, diagnosticRequested, LOG_REQUEST, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    FILE *output = tmpfile();
    assert(output);
    fflush(stderr);
    int saved = dup(STDERR_FILENO);
    assert(saved >= 0 && dup2(fileno(output), STDERR_FILENO) >= 0);
    assert(diagnosticPrint() == 0);
    DIAG(@"agent start");
    assert(diagnosticPrint() == 0);
    CFNotificationCenterRemoveEveryObserver(center, NULL);
    assert(diagnosticPrint() == 1);
    fflush(stderr);
    assert(dup2(saved, STDERR_FILENO) >= 0);
    close(saved);
    rewind(output);
    char text[2048] = {0};
    assert(fread(text, 1, sizeof(text) - 1, output) > 0);
    assert(strstr(text, "Diagnostic log (local times, oldest first):\n"));
    assert(strstr(text, "No entries in the last 5 minutes.\n"));
    assert(strstr(text, " agent start\n"));
    assert(strstr(text, "balancekeeperd: diagnostic agent did not answer\n"));
    fclose(output);
}
#endif

int main(void) {
    @autoreleasepool {
#ifdef BALANCEKEEPER_DIAGNOSTIC_LOG
        testRing();
        testReply();
        testPrint();
        puts("PASS: diagnostic ring, expiry, request/reply and command output");
#else
        int evaluated = 0;
        DIAG(@"event %d", ++evaluated);
        assert(evaluated == 0);
        puts("PASS: release DIAG does not evaluate arguments");
#endif
    }
    return 0;
}
