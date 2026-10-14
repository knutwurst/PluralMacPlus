//
//  PMPPreferences.m
//  PreferencesShim
//
//  Created by Knutwurst on 14.10.26.
//
//  Injected into an instance via DYLD_INSERT_LIBRARIES. cfprefsd ignores HOME and
//  CFFIXED_USER_HOME, so without this all instances of an app share one preferences file.
//  When PMP_PREFERENCES_FILE is set, +[NSUserDefaults standardUserDefaults] returns defaults
//  backed by that plist (an absolute path is a valid preferences domain for cfprefsd).
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSUserDefaults *PMPInstanceDefaults;

@implementation NSUserDefaults (PMPInstancePreferences)

+ (NSUserDefaults *)pmp_standardUserDefaults {
    return PMPInstanceDefaults;
}

@end

__attribute__((constructor))
static void PMPRedirectStandardUserDefaults(void) {
    @autoreleasepool {
        NSString *path = NSProcessInfo.processInfo.environment[@"PMP_PREFERENCES_FILE"];
        if (path.length == 0) {
            return;
        }

        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];

        PMPInstanceDefaults = [[NSUserDefaults alloc] initWithSuiteName:path];
        if (PMPInstanceDefaults == nil) {
            return;
        }

        Method original = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        Method replacement = class_getClassMethod(NSUserDefaults.class, @selector(pmp_standardUserDefaults));
        method_exchangeImplementations(original, replacement);
    }
}
