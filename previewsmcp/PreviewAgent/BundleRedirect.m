#import "BundleRedirect.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/lock.h>

// Keep in sync with the BundleRedirect enum in
// previewsmcp/ios-host/agent/AgentApp.swift (the iOS agent's implementation
// of the same contract).
//
// The JIT recompiles target sources into the agent process, so their classes
// belong to no dyld image and +[NSBundle bundleForClass:] falls back to the
// main bundle. The hook redirects exactly that combination — imageless class
// resolved to the main bundle — to the target's on-disk framework wrapper.
// It lives in the agent binary, never in JIT-generated code, because bridge
// generations can be torn down while the swizzled IMP must stay valid for
// the life of the process (docs/jit-bundle-resolution.md).

static os_unfair_lock gWrapperLock = OS_UNFAIR_LOCK_INIT;
static NSString *gWrapperPath;

static NSString *currentWrapperPath(void) {
  os_unfair_lock_lock(&gWrapperLock);
  NSString *path = gWrapperPath;
  os_unfair_lock_unlock(&gWrapperLock);
  return path;
}

static NSBundle *(*gOriginalBundleForClass)(id, SEL, Class);

static NSBundle *PreviewsMCPBundleForClass(id self, SEL _cmd, Class cls) {
  NSBundle *original = gOriginalBundleForClass(self, _cmd, cls);
  NSString *wrapper = currentWrapperPath();
  if (wrapper == nil || cls == Nil) {
    return original;
  }
  if (original != [NSBundle mainBundle] || class_getImageName(cls) != NULL) {
    return original;
  }
  NSBundle *redirected = [NSBundle bundleWithPath:wrapper];
  return redirected ?: original;
}

__attribute__((used)) void previewsmcp_set_resource_wrapper(const char *path) {
  NSString *wrapper = path != NULL ? [NSString stringWithUTF8String:path] : nil;
  os_unfair_lock_lock(&gWrapperLock);
  gWrapperPath = wrapper;
  os_unfair_lock_unlock(&gWrapperLock);

  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Method method =
        class_getClassMethod([NSBundle class], @selector(bundleForClass:));
    gOriginalBundleForClass =
        (NSBundle * (*)(id, SEL, Class)) method_getImplementation(method);
    method_setImplementation(method, (IMP)PreviewsMCPBundleForClass);
  });
}
