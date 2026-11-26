#import "Updater.h"
#include <string.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 1;
        if (strcmp(argv[1], "--check") == 0) return updaterRun(NO, NO);
        if (strcmp(argv[1], "--install") == 0) return updaterRun(YES, NO);
        if (strcmp(argv[1], "--scheduled") == 0) return updaterRun(NO, YES);
        return 1;
    }
}
