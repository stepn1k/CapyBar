#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridge to the private `MenuBarClientCore` framework (macOS 27+).
///
/// The only lever MenuBarAgent offers a third-party app: an "assessment mode"
/// visibility restriction. While an assertion is active, the menu bar draws only the
/// status items of the listed bundle identifiers (plus the listed system items).
/// The assertion dies with the process, so a crash or quit always gives every icon back.
///
/// Everything is resolved at runtime (dlopen + NSClassFromString). If Apple renames or
/// removes the classes, or changes the type encoding of a method we call, `isAvailable`
/// is NO and nothing is hidden.
NS_SWIFT_NAME(MenuBarPrivate)
@interface CBMenuBarPrivate : NSObject

/// YES when the framework loads and every class and method we use exists with the
/// type encoding verified on macOS 27.2.1.
@property (class, readonly) BOOL isAvailable;

/// Activates a new assertion. Returns the assertion object synchronously (the token to
/// pass to `invalidate:` later) or nil if the API is unavailable. `completion` runs on
/// an arbitrary queue once MenuBarAgent confirms (nil) or rejects (an error).
+ (nullable NSObject *)activateAllowingBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                                             systemItems:(NSArray<NSNumber *> *)systemItems
                                              completion:(void (^NS_SWIFT_SENDABLE)(NSError *_Nullable error))completion
    NS_SWIFT_NAME(activate(allowing:systemItems:completion:));

/// Releases an assertion previously returned by `activate…`. Safe to call with nil and
/// more than once.
+ (void)invalidate:(nullable NSObject *)assertion;

@end

NS_ASSUME_NONNULL_END
