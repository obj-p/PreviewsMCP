#import <Foundation/Foundation.h>

@class VZVirtualMachine;

NS_ASSUME_NONNULL_BEGIN

/// Bridge over the private `_VZVNCServer` / `_VZVNCNoSecuritySecurityConfiguration`
/// classes in Virtualization.framework. We call them directly in
/// Obj-C to avoid Swift Unmanaged + objc_msgSend ceremony around the
/// 3-arg designated initializer.
///
/// The returned `serverHandle` is an opaque NSObject — keep it alive
/// for as long as the server should run. Call `+stop:` to tear down.
@interface PVMVNCBridge : NSObject

/// Start an in-process VNC server pointing at `virtualMachine`. Pass
/// `port = 0` to let the kernel pick one; the actual bound port is
/// written to `*outPort` on success. Returns the server handle, or
/// nil on failure (with `*error` populated).
+ (nullable NSObject *)startServerWithVirtualMachine:(VZVirtualMachine *)virtualMachine
                                                port:(NSUInteger)port
                                             outPort:(NSUInteger *)outPort
                                               error:(NSError *_Nullable *_Nullable)error;

/// Stop a previously-started server. No-op if `serverHandle` is nil.
+ (void)stop:(nullable NSObject *)serverHandle;

@end

NS_ASSUME_NONNULL_END
