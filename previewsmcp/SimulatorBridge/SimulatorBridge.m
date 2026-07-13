#import "SimulatorBridge.h"
#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurface.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <unistd.h>

#pragma mark - Private API Protocols

@protocol _SimServiceContext
+ (instancetype)sharedServiceContextForDeveloperDir:(NSString *)dir
                                              error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (NSArray *)supportedRuntimes;
@end

@protocol _SimDeviceSet
- (NSArray *)availableDevices;
@end

@protocol _SimDevice
- (NSString *)name;
- (NSUUID *)UDID;
- (unsigned long long)state;
- (NSString *)stateString;
- (id)runtime;
- (id)deviceType;
- (id)io;
- (BOOL)isAvailable;
- (BOOL)bootWithOptions:(NSDictionary *)options error:(NSError **)error;
- (BOOL)shutdownWithError:(NSError **)error;
- (BOOL)installApplication:(NSURL *)url
               withOptions:(NSDictionary *)options
                     error:(NSError **)error;
- (int)launchApplicationWithID:(NSString *)bundleID
                       options:(NSDictionary *)options
                         error:(NSError **)error;
- (int)spawnWithPath:(NSString *)path
               options:(NSDictionary *)options
      terminationQueue:(dispatch_queue_t)queue
    terminationHandler:(void (^)(int status))handler
                 error:(NSError **)error;
@end

@protocol _SimRuntime
- (NSString *)name;
- (NSString *)identifier;
- (NSString *)versionString;
- (BOOL)isAvailable;
@end

@protocol _SimDeviceType
- (NSString *)name;
- (NSString *)identifier;
@end

@protocol _SimDeviceLegacyHIDClient
- (instancetype)initWithDevice:(id)device error:(NSError **)error;
- (void)sendWithMessage:(void *)message
           freeWhenDone:(BOOL)freeWhenDone
        completionQueue:(dispatch_queue_t)queue
             completion:(void (^)(void))completion;
@end

#pragma mark - Framework State

static BOOL _frameworkLoaded = NO;
static Class _SimServiceContextClass = Nil;
static dispatch_once_t _loadOnce;

static Class _SimDeviceLegacyHIDClientClass = Nil;
static dispatch_once_t _hidLoadOnce;

static NSString *_developerDir(void) {
  static NSString *cached = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSString *envDir = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
    if (envDir.length > 0) {
      cached = envDir;
      return;
    }

    NSPipe *pipe = [NSPipe pipe];
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/xcode-select";
    task.arguments = @[ @"-p" ];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    @try {
      [task launch];
      [task waitUntilExit];
      if (task.terminationStatus == 0) {
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *path = [[NSString alloc] initWithData:data
                                               encoding:NSUTF8StringEncoding];
        cached = [path stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      }
    } @catch (NSException *e) {
      NSLog(@"SimulatorBridge: xcode-select failed: %@", e.reason);
    }

    if (cached.length == 0) {
      NSString *fallback = @"/Applications/Xcode.app/Contents/Developer";
      if ([[NSFileManager defaultManager] fileExistsAtPath:fallback]) {
        cached = fallback;
      } else {
        cached = nil;
      }
    }
  });
  return cached;
}

static NSError *_makeError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:@"SimulatorBridge"
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

static id _sharedContext(NSError **error) {
  NSString *devDir = _developerDir();
  if (!devDir) {
    if (error)
      *error = _makeError(6, @"Could not locate Xcode developer directory. Set "
                             @"DEVELOPER_DIR or run xcode-select -s.");
    return nil;
  }
  return [(id<_SimServiceContext>)_SimServiceContextClass
      sharedServiceContextForDeveloperDir:devDir
                                    error:error];
}

static id _defaultDeviceSet(NSError **error) {
  id context = _sharedContext(error);
  if (!context)
    return nil;
  return [(id<_SimServiceContext>)context defaultDeviceSetWithError:error];
}

// SimDeviceLegacyHIDClient lives in SimulatorKit, which ships inside Xcode and
// moved from PrivateFrameworks (Xcode 26 and older) to SharedFrameworks (Xcode
// 27+). Loaded lazily and separately from CoreSimulator so non-HID callers
// never pay for it or fail if SimulatorKit moved.
static Class _loadSimulatorKitHIDClass(NSError **error) {
  dispatch_once(&_hidLoadOnce, ^{
    NSString *dev = _developerDir();
    if (!dev)
      return;
    NSArray<NSString *> *candidates = @[
      [dev stringByAppendingPathComponent:
               @"Library/PrivateFrameworks/SimulatorKit.framework"],
      [dev stringByAppendingPathComponent:
               @"../SharedFrameworks/SimulatorKit.framework"],
    ];
    for (NSString *path in candidates) {
      NSBundle *bundle = [NSBundle bundleWithPath:path];
      if (bundle && [bundle loadAndReturnError:NULL])
        break;
    }
    _SimDeviceLegacyHIDClientClass =
        objc_lookUpClass("_TtC12SimulatorKit24SimDeviceLegacyHIDClient");
  });

  if (!_SimDeviceLegacyHIDClientClass && error) {
    *error = _makeError(30, @"SimDeviceLegacyHIDClient unavailable (could not "
                            @"load SimulatorKit from this Xcode)");
  }
  return _SimDeviceLegacyHIDClientClass;
}

#pragma mark - SBDevice

@interface SBDevice ()
@property(nonatomic, strong) id simDevice;
@end

@implementation SBDevice

- (instancetype)initWithSimDevice:(id)simDevice {
  self = [super init];
  if (self) {
    _simDevice = simDevice;
  }
  return self;
}

- (NSString *)name {
  return [(id<_SimDevice>)_simDevice name];
}

- (NSUUID *)udid {
  return [(id<_SimDevice>)_simDevice UDID];
}

- (SBDeviceState)state {
  unsigned long long raw = [(id<_SimDevice>)_simDevice state];
  return (SBDeviceState)raw;
}

- (NSString *)stateString {
  return [(id<_SimDevice>)_simDevice stateString] ?: @"Unknown";
}

- (NSString *)runtimeName {
  id runtime = [(id<_SimDevice>)_simDevice runtime];
  if (!runtime)
    return nil;
  return [(id<_SimRuntime>)runtime name];
}

- (NSString *)runtimeIdentifier {
  id runtime = [(id<_SimDevice>)_simDevice runtime];
  if (!runtime)
    return nil;
  return [(id<_SimRuntime>)runtime identifier];
}

- (NSString *)deviceTypeName {
  id deviceType = [(id<_SimDevice>)_simDevice deviceType];
  if (!deviceType)
    return nil;
  return [(id<_SimDeviceType>)deviceType name];
}

- (BOOL)isAvailable {
  if ([_simDevice respondsToSelector:@selector(isAvailable)]) {
    return [(id<_SimDevice>)_simDevice isAvailable];
  }
  if ([_simDevice respondsToSelector:NSSelectorFromString(@"available")]) {
    return [[_simDevice valueForKey:@"available"] boolValue];
  }
  return self.runtimeName != nil;
}

- (BOOL)bootWithError:(NSError **)error {
  @try {
    return [(id<_SimDevice>)_simDevice bootWithOptions:nil error:error];
  } @catch (NSException *exception) {
    if (error) {
      *error = _makeError(10, [NSString stringWithFormat:@"Boot exception: %@",
                                                         exception.reason]);
    }
    return NO;
  }
}

- (BOOL)shutdownWithError:(NSError **)error {
  @try {
    return [(id<_SimDevice>)_simDevice shutdownWithError:error];
  } @catch (NSException *exception) {
    if (error) {
      *error =
          _makeError(11, [NSString stringWithFormat:@"Shutdown exception: %@",
                                                    exception.reason]);
    }
    return NO;
  }
}

- (BOOL)installAppAt:(NSString *)path error:(NSError **)error {
  @try {
    NSURL *url = [NSURL fileURLWithPath:path];
    return [(id<_SimDevice>)_simDevice installApplication:url
                                              withOptions:nil
                                                    error:error];
  } @catch (NSException *exception) {
    if (error) {
      *error =
          _makeError(12, [NSString stringWithFormat:@"Install exception: %@",
                                                    exception.reason]);
    }
    return NO;
  }
}

- (NSInteger)launchAppWithBundleID:(NSString *)bundleID
                         arguments:(NSArray<NSString *> *)args
                       environment:(NSDictionary<NSString *, NSString *> *)env
                         suspended:(BOOL)suspended
                             error:(NSError **)error {
  @try {
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    if (args)
      options[@"arguments"] = args;
    if (env)
      options[@"environment"] = env;
    if (suspended)
      options[@"activate_suspended"] = @YES;

    int pid = [(id<_SimDevice>)_simDevice launchApplicationWithID:bundleID
                                                          options:options
                                                            error:error];
    return (NSInteger)pid;
  } @catch (NSException *exception) {
    if (error) {
      *error =
          _makeError(13, [NSString stringWithFormat:@"Launch exception: %@",
                                                    exception.reason]);
    }
    return -1;
  }
}

- (NSInteger)spawnInSessionWithPath:(NSString *)path
                          arguments:(NSArray<NSString *> *)args
                        environment:(NSDictionary<NSString *, NSString *> *)env
                 terminationHandler:(void (^)(int status))handler
                              error:(NSError **)error {
  @try {
    // Default options (no kSimDeviceSpawnStandalone) → in-session spawn on a
    // booted device, matching `simctl spawn` without `--standalone`. The
    // SimLaunchHostClient `spawnInSession:` API is not used: it requires the
    // device's bootSessionUUID, which is set only in the process that performed
    // the boot and is nil for a device booted elsewhere.
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    if (args)
      options[@"arguments"] = args;
    if (env)
      options[@"environment"] = env;

    int pid = [(id<_SimDevice>)_simDevice
             spawnWithPath:path
                   options:options
          terminationQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,
                                                     0)
        terminationHandler:handler
                     error:error];
    return (NSInteger)pid;
  } @catch (NSException *exception) {
    if (error) {
      *error = _makeError(14, [NSString stringWithFormat:@"Spawn exception: %@",
                                                         exception.reason]);
    }
    return -1;
  }
}

- (NSString *)description {
  return [NSString stringWithFormat:@"<SBDevice: %@ (%@) %@ — %@>", self.name,
                                    self.udid.UUIDString, self.stateString,
                                    self.runtimeName ?: @"no runtime"];
}

@end

#pragma mark - SBRuntime

@interface SBRuntime ()
@property(nonatomic, strong) id simRuntime;
@end

@implementation SBRuntime

- (instancetype)initWithSimRuntime:(id)simRuntime {
  self = [super init];
  if (self) {
    _simRuntime = simRuntime;
  }
  return self;
}

- (NSString *)name {
  return [(id<_SimRuntime>)_simRuntime name];
}

- (NSString *)identifier {
  return [(id<_SimRuntime>)_simRuntime identifier];
}

- (NSString *)versionString {
  return [(id<_SimRuntime>)_simRuntime versionString];
}

- (BOOL)isAvailable {
  if ([_simRuntime respondsToSelector:@selector(isAvailable)]) {
    return [(id<_SimRuntime>)_simRuntime isAvailable];
  }
  if ([_simRuntime respondsToSelector:NSSelectorFromString(@"available")]) {
    return [[_simRuntime valueForKey:@"available"] boolValue];
  }
  return YES;
}

- (NSString *)description {
  return [NSString
      stringWithFormat:@"<SBRuntime: %@ (%@) %@>", self.name,
                       self.versionString,
                       self.isAvailable ? @"available" : @"unavailable"];
}

@end

#pragma mark - Public Functions

BOOL SBLoadFramework(NSError **error) {
  if (_frameworkLoaded)
    return YES;

  __block NSError *loadError = nil;
  dispatch_once(&_loadOnce, ^{
    NSBundle *bundle = [NSBundle
        bundleWithPath:
            @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework"];
    if (!bundle) {
      loadError = _makeError(1, @"CoreSimulator.framework not found at "
                                @"/Library/Developer/PrivateFrameworks/");
      return;
    }

    NSError *bundleError = nil;
    if (![bundle loadAndReturnError:&bundleError]) {
      loadError = bundleError;
      return;
    }

    _SimServiceContextClass = objc_lookUpClass("SimServiceContext");
    if (!_SimServiceContextClass) {
      loadError = _makeError(
          2, @"SimServiceContext class not found after loading CoreSimulator");
      return;
    }

    _frameworkLoaded = YES;
  });

  if (!_frameworkLoaded) {
    if (error && loadError)
      *error = loadError;
    return NO;
  }
  return YES;
}

NSArray<SBDevice *> *SBListDevices(NSError **error) {
  if (!_frameworkLoaded && !SBLoadFramework(error))
    return nil;

  id deviceSet = _defaultDeviceSet(error);
  if (!deviceSet)
    return nil;

  NSArray *simDevices = [(id<_SimDeviceSet>)deviceSet availableDevices];
  NSMutableArray<SBDevice *> *result =
      [NSMutableArray arrayWithCapacity:simDevices.count];

  for (id simDevice in simDevices) {
    [result addObject:[[SBDevice alloc] initWithSimDevice:simDevice]];
  }

  return result;
}

NSArray<SBRuntime *> *SBListRuntimes(NSError **error) {
  if (!_frameworkLoaded && !SBLoadFramework(error))
    return nil;

  id context = _sharedContext(error);
  if (!context)
    return nil;

  if (![context respondsToSelector:@selector(supportedRuntimes)]) {
    if (error)
      *error = _makeError(
          3, @"supportedRuntimes method not available on SimServiceContext");
    return nil;
  }

  NSArray *runtimes = [(id<_SimServiceContext>)context supportedRuntimes];
  NSMutableArray<SBRuntime *> *result =
      [NSMutableArray arrayWithCapacity:runtimes.count];

  for (id rt in runtimes) {
    [result addObject:[[SBRuntime alloc] initWithSimRuntime:rt]];
  }

  return result;
}

SBDevice *SBFindDeviceByUDID(NSString *udidString, NSError **error) {
  NSArray<SBDevice *> *devices = SBListDevices(error);
  if (!devices)
    return nil;

  for (SBDevice *device in devices) {
    if ([device.udid.UUIDString.lowercaseString
            isEqualToString:udidString.lowercaseString]) {
      return device;
    }
  }

  if (error)
    *error = _makeError(
        4, [NSString stringWithFormat:@"No device with UDID: %@", udidString]);
  return nil;
}

SBDevice *SBFindBootedDevice(NSError **error) {
  NSArray<SBDevice *> *devices = SBListDevices(error);
  if (!devices)
    return nil;

  for (SBDevice *device in devices) {
    if (device.state == SBDeviceStateBooted) {
      return device;
    }
  }

  if (error)
    *error = _makeError(5, @"No booted simulator device found");
  return nil;
}

// In-app touch injection is handled by the iOS agent app using the Hammer
// approach: IOHIDEvent + BKSHIDEventSetDigitizerInfo +
// UIApplication._enqueueHIDEvent: See IOSAgentAppSource.swift for the
// implementation. That path is independent of the daemon-side HID client below,
// which injects at the simulator digitizer for streamed/agent sessions.

#pragma mark - HID Input Client

// IndigoHIDMessageForMouseNSEvent(const CGPoint *, const CGPoint *,
//   IndigoHIDTarget, NSEventType, NSSize, IndigoHIDEdge) -> IndigoMessage *.
// Apple's Simulator.app always passes NSSize(1,1), so the Indigo ratio reduces
// to the point itself, i.e. our normalized 0..1 coordinate. Resolved once from
// the simulator frameworks loaded for the HID client.
typedef void *(*SBIndigoMouseFunc)(const CGPoint *, const CGPoint *, uint32_t,
                                   int32_t, CGFloat, CGFloat, uint32_t);
static SBIndigoMouseFunc _mouseFunc = NULL;
static dispatch_once_t _mouseFuncOnce;

static SBIndigoMouseFunc _loadMouseFunc(void) {
  dispatch_once(&_mouseFuncOnce, ^{
    _mouseFunc = (SBIndigoMouseFunc)dlsym(RTLD_DEFAULT,
                                          "IndigoHIDMessageForMouseNSEvent");
  });
  return _mouseFunc;
}

@interface SBHIDClient ()
@property(nonatomic, strong) id hidClient;
@property(nonatomic, strong) dispatch_queue_t inputQueue;
- (instancetype)initWithHIDClient:(id)client;
@end

@implementation SBHIDClient

- (instancetype)initWithHIDClient:(id)client {
  self = [super init];
  if (self) {
    _hidClient = client;
    _inputQueue = dispatch_queue_create("com.previewsmcp.hid-input",
                                        DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

// 0x32 = digitizer target. eventType 1 = down (begin and move), 2 = up. Must
// run on `inputQueue` so concurrent gestures never interleave on the shared
// client.
//
// `deliveredLabel` (issue #368 attribution): when non-NULL, the SimulatorKit
// send completion logs "<label> delivered". The completion fires only if the
// underlying HID connection is alive, so a gesture whose dispatch was logged
// but whose delivered line never appears pins a dead/stale HID client —
// distinguishing dropped input from a frozen display in flake specimens.
- (void)_sendEventType:(int32_t)eventType
                     x:(double)x
                     y:(double)y
        deliveredLabel:(const char *)deliveredLabel {
  SBIndigoMouseFunc mouse = _loadMouseFunc();
  if (!mouse)
    return;
  CGPoint pt = CGPointMake(x, y);
  void *msg = mouse(&pt, NULL, 0x32, eventType, 1.0, 1.0, 0);
  if (!msg)
    return;
  void (^completion)(void) = nil;
  dispatch_queue_t completionQueue = NULL;
  if (deliveredLabel) {
    NSString *label = [NSString stringWithUTF8String:deliveredLabel];
    // Send-time marker (#368 (b1) splitter): logged inline before dispatch, so
    // the down->up gap here reflects the real inter-event hold. The "delivered"
    // completion below runs on inputQueue *after* the usleep holds between the
    // sends, so its timestamps batch together and can't measure the hold — this
    // one can.
    NSLog(@"SimulatorBridge: hid %@ sent at (%.4f, %.4f)", label, x, y);
    completionQueue = self.inputQueue;
    completion = ^{
      NSLog(@"SimulatorBridge: hid %@ delivered at (%.4f, %.4f)", label, x, y);
    };
  }
  [(id<_SimDeviceLegacyHIDClient>)self.hidClient sendWithMessage:msg
                                                    freeWhenDone:YES
                                                 completionQueue:completionQueue
                                                      completion:completion];
}

- (BOOL)tapAtX:(double)x y:(double)y {
  if (!_loadMouseFunc())
    return NO;
  dispatch_async(self.inputQueue, ^{
    // A moveless down->up occasionally (~8% on a healed runner) fails app-side
    // tap recognition (#368): the input is delivered and the capture stays live
    // (frame numbers advance), yet the framebuffer never changes — the tap
    // reaches the digitizer but SwiftUI never flips the toggle. Re-sampling the
    // held touch during the hold makes it register reliably (forced-fire went
    // 2/24 -> 0/100). The leading explanation is that the extra type-1 sends
    // keep the touch spanning enough HID samples for a distinct began->ended,
    // mirroring the drag path below (which never flaked); the empirical result
    // holds whether the operative cause is sample count or the send timing.
    [self _sendEventType:1 x:x y:y deliveredLabel:"tap down"];
    usleep(20000);
    [self _sendEventType:1 x:x y:y deliveredLabel:NULL];
    usleep(20000);
    [self _sendEventType:1 x:x y:y deliveredLabel:NULL];
    usleep(20000);
    [self _sendEventType:2 x:x y:y deliveredLabel:"tap up"];
  });
  return YES;
}

- (BOOL)dragFromX:(double)fromX
            fromY:(double)fromY
              toX:(double)toX
              toY:(double)toY
            steps:(NSInteger)steps {
  if (!_loadMouseFunc())
    return NO;
  NSInteger n = steps < 1 ? 10 : steps;
  dispatch_async(self.inputQueue, ^{
    [self _sendEventType:1 x:fromX y:fromY deliveredLabel:"drag down"];
    usleep(8000);
    for (NSInteger i = 1; i <= n; i++) {
      double t = (double)i / (double)n;
      [self _sendEventType:1
                         x:fromX + (toX - fromX) * t
                         y:fromY + (toY - fromY) * t
            deliveredLabel:NULL];
      usleep(16000);
    }
    [self _sendEventType:2 x:toX y:toY deliveredLabel:"drag up"];
  });
  return YES;
}

@end

SBHIDClient *SBCreateHIDClient(SBDevice *device, NSError **error) {
  if (!_frameworkLoaded && !SBLoadFramework(error))
    return nil;

  Class hidClass = _loadSimulatorKitHIDClass(error);
  if (!hidClass)
    return nil;

  id simDevice = device.simDevice;
  if (!simDevice) {
    if (error)
      *error = _makeError(31, @"SBDevice has no underlying SimDevice");
    return nil;
  }

  NSError *initError = nil;
  id<_SimDeviceLegacyHIDClient> raw = [hidClass alloc];
  id client = [raw initWithDevice:simDevice error:&initError];
  if (!client) {
    if (error)
      *error =
          initError
              ?: _makeError(32, @"Failed to create SimDeviceLegacyHIDClient");
    return nil;
  }

  return [[SBHIDClient alloc] initWithHIDClient:client];
}

#pragma mark - Framebuffer Capture

@protocol _SimDeviceIOPort
- (id)ioPortDescriptor;
@end

@protocol _SimDeviceIOClient
- (NSArray *)ioPorts;
@end

@protocol _SimDisplayIOSurfaceRenderable
- (IOSurfaceRef)ioSurface;
@end

static CIContext *_sharedCIContext(void) {
  static CIContext *ctx = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @NO}];
  });
  return ctx;
}

static NSData *_encodeImage(CGImageRef cgImage, double jpegQuality) {
  BOOL usePNG = (jpegQuality >= 1.0);
  CFStringRef utType = usePNG ? (__bridge CFStringRef)UTTypePNG.identifier
                              : (__bridge CFStringRef)UTTypeJPEG.identifier;

  NSMutableData *data = [NSMutableData data];
  CGImageDestinationRef dest = CGImageDestinationCreateWithData(
      (__bridge CFMutableDataRef)data, utType, 1, NULL);
  if (!dest)
    return nil;

  if (!usePNG) {
    NSDictionary *props = @{
      (__bridge NSString *)
      kCGImageDestinationLossyCompressionQuality : @(jpegQuality)
    };
    CGImageDestinationAddImage(dest, cgImage, (__bridge CFDictionaryRef)props);
  } else {
    CGImageDestinationAddImage(dest, cgImage, NULL);
  }

  BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  return ok ? [data copy] : nil;
}

// Lock a display IOSurface, render it to a CGImage via the shared CIContext,
// and encode at `jpegQuality` (PNG when >= 1.0). Returns nil if the surface
// cannot be rendered. Shared by the streamer's cached-frame and on-demand
// capture paths.
static NSData *_encodeSurface(IOSurfaceRef surface, double jpegQuality) {
  IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
  CIImage *ciImage = [CIImage imageWithIOSurface:surface];
  CGImageRef cgImage = NULL;
  if (ciImage)
    cgImage = [_sharedCIContext() createCGImage:ciImage
                                       fromRect:ciImage.extent];
  IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
  if (!cgImage)
    return nil;

  NSData *data = _encodeImage(cgImage, jpegQuality);
  CGImageRelease(cgImage);
  return data;
}

NSData *SBCaptureFramebuffer(SBDevice *device, double jpegQuality,
                             NSError **error) {
  if (!_frameworkLoaded && !SBLoadFramework(error))
    return nil;

  id simDevice = device.simDevice;

  if (![simDevice respondsToSelector:@selector(io)]) {
    if (error)
      *error = _makeError(20, @"SimDevice does not respond to -io (Xcode "
                              @"version may be unsupported)");
    return nil;
  }

  id ioClient = nil;
  @try {
    ioClient = [simDevice valueForKey:@"io"];
  } @catch (NSException *e) {
    if (error)
      *error = _makeError(
          21, [NSString stringWithFormat:@"Failed to access SimDevice.io: %@",
                                         e.reason]);
    return nil;
  }

  if (!ioClient || ![ioClient respondsToSelector:@selector(ioPorts)]) {
    if (error)
      *error =
          _makeError(22, @"SimDeviceIOClient does not respond to -ioPorts");
    return nil;
  }

  NSArray *ports = [(id<_SimDeviceIOClient>)ioClient ioPorts];
  IOSurfaceRef surface = NULL;

  for (id port in ports) {
    if (![port respondsToSelector:@selector(ioPortDescriptor)])
      continue;

    id descriptor = nil;
    @try {
      descriptor = [(id<_SimDeviceIOPort>)port ioPortDescriptor];
    } @catch (NSException *e) {
      continue;
    }
    if (!descriptor)
      continue;

    if ([descriptor respondsToSelector:@selector(ioSurface)]) {
      @try {
        surface = [(id<_SimDisplayIOSurfaceRenderable>)descriptor ioSurface];
      } @catch (NSException *e) {
        continue;
      }
      if (surface)
        break;
    }
  }

  if (!surface) {
    if (error)
      *error = _makeError(23, @"No IOSurface found on any display port (device "
                              @"may not be booted or have no display)");
    return nil;
  }

  IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);

  CIImage *ciImage = [CIImage imageWithIOSurface:surface];
  CGImageRef cgImage = NULL;

  if (ciImage) {
    cgImage = [_sharedCIContext() createCGImage:ciImage
                                       fromRect:ciImage.extent];
  }

  IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

  if (!ciImage) {
    if (error)
      *error = _makeError(24, @"Failed to create CIImage from IOSurface");
    return nil;
  }

  if (!cgImage) {
    if (error)
      *error = _makeError(25, @"Failed to render CIImage to CGImage");
    return nil;
  }

  NSData *result = _encodeImage(cgImage, jpegQuality);
  CGImageRelease(cgImage);

  if (!result) {
    if (error)
      *error = _makeError(26, @"Failed to encode image data");
    return nil;
  }

  return result;
}

#pragma mark - Framebuffer Streamer

@protocol _SBStreamIOClient
- (void)updateIOPorts;
- (NSArray *)ioPorts;
@end

@protocol _SBStreamPort
- (NSString *)portIdentifier;
- (id)descriptor;
- (id)ioPortDescriptor;
@end

@protocol _SBStreamDescriptor
- (IOSurfaceRef)framebufferSurface;
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid
                          callbackQueue:(dispatch_queue_t)queue
                          frameCallback:(void (^)(void))frameCallback
                surfacesChangedCallback:(void (^)(void))surfacesChangedCallback
              propertiesChangedCallback:
                  (void (^)(void))propertiesChangedCallback;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
@end

// Marks our capture queue so `stop` can detect a re-entrant call (dealloc fired
// from a capture-queue block) and avoid a dispatch_sync self-deadlock.
static const void *const kFBStreamerQueueKey = &kFBStreamerQueueKey;

@implementation SBFramebufferStreamer {
  id _ioClient;
  double _jpegQuality;
  dispatch_queue_t _captureQueue;
  NSMutableArray *_descriptors;
  NSMutableDictionary<NSNumber *, NSUUID *> *_callbackUUIDs;
  NSMutableDictionary<NSNumber *, NSNumber *> *_lastSeeds;
  NSData *_latestFrame;
  unsigned long long _frameCounter;
  CFAbsoluteTime _lastFrameTime;
  BOOL _hasFrame;
  dispatch_source_t _healTimer;
  BOOL _stopRequested;
  BOOL _stopped;
}

- (instancetype)initWithIOClient:(id)ioClient jpegQuality:(double)jpegQuality {
  if ((self = [super init])) {
    _ioClient = ioClient;
    _jpegQuality = jpegQuality;
    _captureQueue = dispatch_queue_create("com.previewsmcp.fb-streamer",
                                          DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_captureQueue, kFBStreamerQueueKey,
                                (__bridge void *)_captureQueue, NULL);
    _descriptors = [NSMutableArray array];
    _callbackUUIDs = [NSMutableDictionary dictionary];
    _lastSeeds = [NSMutableDictionary dictionary];
    dispatch_async(_captureQueue, ^{
      [self wireUpFramebuffer];
    });
    [self startHealTimer];
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

// Find every framebuffer display descriptor that supports the screen-callback
// SPI. The simulator exposes more than one `com.apple.framebuffer.display`
// port (main screen plus secondary planes/overlays); we listen on all and let
// `captureFrame` pick whichever currently has the largest live surface.
- (NSArray *)findFramebufferDescriptors {
  id io = _ioClient;
  if ([io respondsToSelector:@selector(updateIOPorts)]) {
    @try {
      [(id<_SBStreamIOClient>)io updateIOPorts];
    } @catch (NSException *e) {
    }
  }

  NSArray *ports = nil;
  @try {
    ports = [io valueForKey:@"deviceIOPorts"];
  } @catch (NSException *e) {
  }
  if (![ports isKindOfClass:[NSArray class]] &&
      [io respondsToSelector:@selector(ioPorts)]) {
    @try {
      ports = [(id<_SBStreamIOClient>)io ioPorts];
    } @catch (NSException *e) {
    }
  }
  if (![ports isKindOfClass:[NSArray class]])
    return @[];

  NSMutableArray *result = [NSMutableArray array];
  for (id port in ports) {
    if ([port respondsToSelector:@selector(portIdentifier)]) {
      NSString *pid = nil;
      @try {
        pid = [(id<_SBStreamPort>)port portIdentifier];
      } @catch (NSException *e) {
      }
      if (pid && ![[NSString stringWithFormat:@"%@", pid]
                     isEqualToString:@"com.apple.framebuffer.display"])
        continue;
    }

    id desc = nil;
    @try {
      if ([port respondsToSelector:@selector(descriptor)])
        desc = [(id<_SBStreamPort>)port descriptor];
      else if ([port respondsToSelector:@selector(ioPortDescriptor)])
        desc = [(id<_SBStreamPort>)port ioPortDescriptor];
    } @catch (NSException *e) {
    }
    if (!desc)
      continue;

    if ([desc respondsToSelector:@selector(framebufferSurface)] &&
        [desc respondsToSelector:@selector
              (registerScreenCallbacksWithUUID:
                                 callbackQueue:frameCallback
                                              :surfacesChangedCallback
                                              :propertiesChangedCallback:)]) {
      [result addObject:desc];
    }
  }
  return result;
}

// Register callbacks on the current descriptors. Registering is what causes
// SimulatorKit to wire the display pipeline to us and populate
// `framebufferSurface`. Runs on the capture queue; safe to re-call to recover
// from a stale descriptor set.
- (void)wireUpFramebuffer {
  if (_stopped || _stopRequested)
    return;

  for (id old in _descriptors) {
    NSUUID *uuid = _callbackUUIDs[@((uintptr_t)old)];
    if (uuid && [old respondsToSelector:@selector
                     (unregisterScreenCallbacksWithUUID:)]) {
      @try {
        [(id<_SBStreamDescriptor>)old unregisterScreenCallbacksWithUUID:uuid];
      } @catch (NSException *e) {
      }
    }
  }
  [_callbackUUIDs removeAllObjects];
  [_lastSeeds removeAllObjects];

  NSArray *candidates = [self findFramebufferDescriptors];
  [_descriptors setArray:candidates];

  for (id desc in candidates) {
    NSUUID *uuid = [NSUUID UUID];
    _callbackUUIDs[@((uintptr_t)desc)] = uuid;
    __weak SBFramebufferStreamer *weakSelf = self;
    void (^onChange)(void) = ^{
      SBFramebufferStreamer *strongSelf = weakSelf;
      if (!strongSelf)
        return;
      dispatch_async(strongSelf->_captureQueue, ^{
        [strongSelf captureFrame];
      });
    };
    @try {
      [(id<_SBStreamDescriptor>)desc
          registerScreenCallbacksWithUUID:uuid
                            callbackQueue:_captureQueue
                            frameCallback:onChange
                  surfacesChangedCallback:onChange
                propertiesChangedCallback:^{
                }];
    } @catch (NSException *e) {
    }
  }

  [self captureFrame];
}

// Pick the descriptor whose live surface has the largest area, returning that
// surface in `outSurface` so the caller need not re-fetch it. Secondary
// planes/overlays are typically smaller than the main screen.
- (id<_SBStreamDescriptor>)pickBestDescriptor:(IOSurfaceRef *)outSurface {
  id<_SBStreamDescriptor> best = nil;
  IOSurfaceRef bestSurface = NULL;
  size_t bestArea = 0;
  for (id<_SBStreamDescriptor> desc in _descriptors) {
    IOSurfaceRef surface = NULL;
    @try {
      surface = [desc framebufferSurface];
    } @catch (NSException *e) {
      continue;
    }
    if (!surface)
      continue;
    size_t area = IOSurfaceGetWidth(surface) * IOSurfaceGetHeight(surface);
    if (area > bestArea) {
      best = desc;
      bestSurface = surface;
      bestArea = area;
    }
  }
  if (outSurface)
    *outSurface = bestSurface;
  return best;
}

// Runs on the capture queue. Re-encodes only when the surface seed changed
// since the last encode (seed-skip), so duplicate or vsync-rate callbacks on
// static content cost nothing.
- (void)captureFrame {
  if (_stopped || _stopRequested)
    return;

  IOSurfaceRef surface = NULL;
  id<_SBStreamDescriptor> desc = [self pickBestDescriptor:&surface];
  if (!desc || !surface)
    return;

  NSNumber *key = @((uintptr_t)desc);
  uint32_t seed = IOSurfaceGetSeed(surface);
  NSNumber *last = _lastSeeds[key];
  if (_hasFrame && last && last.unsignedIntValue == seed)
    return;
  _lastSeeds[key] = @(seed);

  size_t w = IOSurfaceGetWidth(surface);
  size_t h = IOSurfaceGetHeight(surface);
  if (w == 0 || h == 0)
    return;

  void (^frameSink)(IOSurfaceRef) = self.onFrameSurface;
  if (frameSink)
    frameSink(surface);

  NSData *jpeg = _encodeSurface(surface, _jpegQuality);
  if (!jpeg)
    return;

  @synchronized(self) {
    _latestFrame = jpeg;
    _frameCounter += 1;
    _lastFrameTime = CFAbsoluteTimeGetCurrent();
  }

  // Frames are flowing: the heal timer's only job (re-wire while we have none)
  // is done, so stop its 1 Hz wakeups for the life of the streamer.
  if (!_hasFrame) {
    _hasFrame = YES;
    if (_healTimer)
      dispatch_source_cancel(_healTimer);
  }
}

// Re-wire periodically until frames start flowing. A freshly created streamer
// often races display attach; an app may also not have a display yet. The tick
// is a no-op once any frame has been captured.
- (void)startHealTimer {
  _healTimer =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _captureQueue);
  dispatch_source_set_timer(_healTimer,
                            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                            NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
  __weak SBFramebufferStreamer *weakSelf = self;
  dispatch_source_set_event_handler(_healTimer, ^{
    SBFramebufferStreamer *self = weakSelf;
    if (!self || self->_stopped || self->_stopRequested)
      return;
    if (!self->_hasFrame)
      [self wireUpFramebuffer];
  });
  dispatch_resume(_healTimer);
}

- (NSData *)latestFrame {
  @synchronized(self) {
    return _latestFrame;
  }
}

- (void)getFrameCount:(unsigned long long *)count
           ageSeconds:(double *)ageSeconds {
  @synchronized(self) {
    *count = _frameCounter;
    *ageSeconds = _frameCounter == 0
                      ? INFINITY
                      : CFAbsoluteTimeGetCurrent() - _lastFrameTime;
  }
}

- (NSData *)captureFrameAtQuality:(double)jpegQuality {
  NSData * (^capture)(void) = ^NSData * {
    if (_stopped || _stopRequested)
      return nil;
    IOSurfaceRef surface = NULL;
    id<_SBStreamDescriptor> desc = [self pickBestDescriptor:&surface];
    if (!desc || !surface)
      return nil;
    if (IOSurfaceGetWidth(surface) == 0 || IOSurfaceGetHeight(surface) == 0)
      return nil;
    // #368 attribution: a snapshot sequence whose surface ID and seed never
    // move distinguishes "display content genuinely static" (dropped input)
    // from "reading a detached surface" (seed frozen while the sim renders
    // elsewhere, the #269 display-port class).
    // size= is the sim's pixel resolution (#368 (b2) splitter): a sane WxH
    // confirms the normalized tap coords map to the expected pixel; a
    // degenerate/rotated size under churn would point at coord/scaling-off.
    NSLog(@"SimulatorBridge: fb capture surface=%u seed=%u size=%zux%zu",
          IOSurfaceGetID(surface), IOSurfaceGetSeed(surface),
          IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface));
    return _encodeSurface(surface, jpegQuality);
  };

  // pickBestDescriptor reads `_descriptors`, which is mutated only on the
  // capture queue, so the encode must run there too. Guard against a
  // re-entrant call from a capture-queue block (matching `stop`).
  if (dispatch_get_specific(kFBStreamerQueueKey))
    return capture();

  // Bound the cross-queue hop. `_captureQueue` is serial and is also driven by
  // the vsync-rate screen callbacks, so a single encode stuck inside
  // SimulatorKit / `IOSurfaceLock` / CoreImage against a degraded display port
  // blocks the queue. An unbounded `dispatch_sync` here would then wedge the
  // snapshot — and the whole daemon — indefinitely (observed as a 60s+ silent
  // hang on `preview_snapshot` under full-suite simulator load). Abandon after
  // a short deadline and return nil so the Swift caller falls through to the
  // independent, already-bounded one-shot capture (`SBCaptureFramebuffer`) and
  // simctl paths. A late-running block is harmless: `result` is heap-promoted
  // `__block` storage, so its write lands safely and is simply ignored.
  __block NSData *result = nil;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  dispatch_async(_captureQueue, ^{
    result = capture();
    dispatch_semaphore_signal(done);
  });
  if (dispatch_semaphore_wait(
          done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0)
    return nil;
  return result;
}

- (void)stop {
  @synchronized(self) {
    if (_stopRequested)
      return;
    _stopRequested = YES;
  }

  dispatch_source_t timer = _healTimer;
  _healTimer = nil;
  if (timer)
    dispatch_source_cancel(timer);

  void (^teardown)(void) = ^{
    if (_stopped)
      return;
    _stopped = YES;
    for (id desc in _descriptors) {
      NSUUID *uuid = _callbackUUIDs[@((uintptr_t)desc)];
      if (uuid && [desc respondsToSelector:@selector
                        (unregisterScreenCallbacksWithUUID:)]) {
        @try {
          [(id<_SBStreamDescriptor>)desc
              unregisterScreenCallbacksWithUUID:uuid];
        } @catch (NSException *e) {
        }
      }
    }
    [_descriptors removeAllObjects];
    [_callbackUUIDs removeAllObjects];
    [_lastSeeds removeAllObjects];
  };

  // If stop is re-entered on the capture queue (dealloc fired from one of its
  // blocks), run teardown inline; dispatch_sync onto the current queue would
  // deadlock.
  if (dispatch_get_specific(kFBStreamerQueueKey))
    teardown();
  else {
    // Match captureFrameAtQuality's bounded cross-queue hop. If a prior capture
    // block is wedged inside SimulatorKit / IOSurface, an unbounded
    // dispatch_sync here just moves the hang from snapshot to cleanup. Queue
    // teardown so it still runs if the capture queue recovers, but let stop
    // return promptly.
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_captureQueue, ^{
      teardown();
      dispatch_semaphore_signal(done);
    });
    (void)dispatch_semaphore_wait(
        done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
  }
}

@end

SBFramebufferStreamer *SBCreateFramebufferStreamer(SBDevice *device,
                                                   double jpegQuality,
                                                   NSError **error) {
  if (!_frameworkLoaded && !SBLoadFramework(error))
    return nil;

  id simDevice = device.simDevice;
  if (![simDevice respondsToSelector:@selector(io)]) {
    if (error)
      *error = _makeError(40, @"SimDevice does not respond to -io (Xcode "
                              @"version may be unsupported)");
    return nil;
  }

  id ioClient = nil;
  @try {
    ioClient = [simDevice valueForKey:@"io"];
  } @catch (NSException *e) {
    if (error)
      *error = _makeError(
          41, [NSString stringWithFormat:@"Failed to access SimDevice.io: %@",
                                         e.reason]);
    return nil;
  }
  if (!ioClient) {
    if (error)
      *error =
          _makeError(42, @"SimDevice.io is nil (device may not be booted)");
    return nil;
  }

  return [[SBFramebufferStreamer alloc] initWithIOClient:ioClient
                                             jpegQuality:jpegQuality];
}
