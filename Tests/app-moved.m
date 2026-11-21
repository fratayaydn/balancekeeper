#include <assert.h>

#define main balancekeeperMain
#import "../Sources/Agent/balancekeeperd.m"
#undef main

int main(void) {
    @autoreleasepool {
        assert(shouldCountFix(0, 100));
        assert(!shouldCountFix(100, 101));
        assert(!shouldCountFix(100, 102));
        assert(shouldCountFix(100, 103));
        assert(shouldCountFix(100, 99));
        puts("PASS: correction burst counting decisions");

        assert(appMoveAction(YES, nil) == AppMoveRestart);
        assert(appMoveAction(YES, @"/Users/test/.Trash/BalanceKeeper.app") == AppMoveRestart);
        assert(appMoveAction(NO, nil) == AppMoveRemoveAndExit);
        assert(appMoveAction(NO, @"/Users/test/.Trash/BalanceKeeper.app") == AppMoveRemoveAndExit);
        assert(appMoveAction(NO, @"/Volumes/Disk/.Trashes/501/BalanceKeeper.app") == AppMoveRemoveAndExit);
        assert(appMoveAction(NO, @"/Applications/Utilities/BalanceKeeper.app") == AppMoveKeepRunning);
        assert(appMoveAction(NO, @"/Applications/Renamed.app") == AppMoveKeepRunning);
        assert(appMoveAction(NO, @"/Applications/.Trash Tools/BalanceKeeper.app") == AppMoveKeepRunning);
        assert(appMoveAction(NO, @"/Applications/.TrashesBackup/BalanceKeeper.app") == AppMoveKeepRunning);
        puts("PASS: app move restart, keep running and removal decisions");
    }
    return 0;
}
