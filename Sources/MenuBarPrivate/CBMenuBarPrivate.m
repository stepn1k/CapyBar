#import "CBMenuBarPrivate.h"

#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <string.h>

static const char *const kFrameworkPath =
    "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";

NS_ASSUME_NONNULL_BEGIN

// Shapes of the private classes, declared as protocols so that calls go through normal
// Objective-C dispatch and ARC applies its usual rules (an -init… that returns nil or
// another object must not be released twice, which a raw objc_msgSend cast would do).
@protocol CBAssessmentModeConfiguration <NSObject>
- (nullable instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)systemItems
                            allowedBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers;
@end

@protocol CBAssessmentModeAssertion <NSObject>
- (void)activateWithConfiguration:(id<CBAssessmentModeConfiguration>)configuration
                completionHandler:(void (^)(NSError *_Nullable error))handler;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END

// Objective-C type encodings verified on macOS 27.2.1 (26B131). They pin argument and
// return kinds, not the block's parameters (`@?` is any block). If Apple changes one,
// the API is treated as unavailable instead of being called with the wrong ABI.
static BOOL HasMethod(Class cls, NSString *selector, const char *encoding) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(selector));
    if (method == NULL) { return NO; }
    const char *actual = method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, encoding) == 0;
}

@implementation CBMenuBarPrivate

+ (BOOL)isAvailable {
    static BOOL available = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (dlopen(kFrameworkPath, RTLD_NOW | RTLD_LOCAL) == NULL) { return; }
        Class config = NSClassFromString(@"MBAssessmentModeConfiguration");
        Class assertion = NSClassFromString(@"MBAssessmentModeAssertion");
        available = config != Nil && assertion != Nil
            && HasMethod(config, @"initWithAllowedSystemItems:allowedBundleIdentifiers:", "@32@0:8@16@24")
            && HasMethod(assertion, @"init", "@16@0:8")
            && HasMethod(assertion, @"activateWithConfiguration:completionHandler:", "v32@0:8@16@?24")
            && HasMethod(assertion, @"invalidate", "v16@0:8");
    });
    return available;
}

+ (nullable NSObject *)activateAllowingBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                                             systemItems:(NSArray<NSNumber *> *)systemItems
                                              completion:(void (^)(NSError *_Nullable))completion {
    if (!self.isAvailable) { return nil; }

    // The framework expects NSArray (an NSSet throws), so copy defensively.
    id<CBAssessmentModeConfiguration> config =
        [(id<CBAssessmentModeConfiguration>)[NSClassFromString(@"MBAssessmentModeConfiguration") alloc]
            initWithAllowedSystemItems:[systemItems copy]
              allowedBundleIdentifiers:[bundleIdentifiers copy]];
    if (config == nil) { return nil; }

    NSObject<CBAssessmentModeAssertion> *assertion =
        (NSObject<CBAssessmentModeAssertion> *)[[NSClassFromString(@"MBAssessmentModeAssertion") alloc] init];
    if (assertion == nil) { return nil; }

    [assertion activateWithConfiguration:config completionHandler:[completion copy]];
    return assertion;
}

+ (void)invalidate:(nullable NSObject *)assertion {
    if (assertion == nil || ![assertion respondsToSelector:@selector(invalidate)]) { return; }
    [(id<CBAssessmentModeAssertion>)assertion invalidate];
}

@end
