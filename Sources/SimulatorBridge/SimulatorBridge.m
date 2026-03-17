#import "SimulatorBridge.h"
#import <objc/runtime.h>

#pragma mark - Private API Protocols

// These protocols declare the CoreSimulator methods we call at runtime.
// No headers or build-time linking needed — classes are resolved via objc_lookUpClass.

@protocol _SimServiceContext
+ (instancetype)sharedServiceContextForDeveloperDir:(NSString *)dir error:(NSError **)error;
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
- (BOOL)isAvailable;
- (BOOL)bootWithOptions:(NSDictionary *)options error:(NSError **)error;
- (BOOL)shutdownWithError:(NSError **)error;
- (BOOL)installApplication:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error;
- (int)launchApplicationWithID:(NSString *)bundleID options:(NSDictionary *)options error:(NSError **)error;
- (int)spawnWithPath:(NSString *)path
             options:(NSDictionary *)options
    terminationQueue:(dispatch_queue_t)queue
  terminationHandler:(void(^)(int status))handler
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

#pragma mark - Framework State

static BOOL _frameworkLoaded = NO;
static Class _SimServiceContextClass = Nil;
static dispatch_once_t _loadOnce;

static NSString *_developerDir(void) {
    static NSString *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSPipe *pipe = [NSPipe pipe];
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/xcode-select";
        task.arguments = @[@"-p"];
        task.standardOutput = pipe;
        task.standardError = [NSFileHandle fileHandleWithNullDevice];

        @try {
            [task launch];
            [task waitUntilExit];
            if (task.terminationStatus == 0) {
                NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
                NSString *path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                cached = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        } @catch (NSException *e) {
            NSLog(@"SimulatorBridge: xcode-select failed: %@", e.reason);
        }

        if (!cached) {
            cached = @"/Applications/Xcode.app/Contents/Developer";
        }
    });
    return cached;
}

static NSError *_makeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"SimulatorBridge" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static id _sharedContext(NSError **error) {
    NSString *devDir = _developerDir();
    return [(id<_SimServiceContext>)_SimServiceContextClass
            sharedServiceContextForDeveloperDir:devDir error:error];
}

static id _defaultDeviceSet(NSError **error) {
    id context = _sharedContext(error);
    if (!context) return nil;
    return [(id<_SimServiceContext>)context defaultDeviceSetWithError:error];
}

#pragma mark - SBDevice

@interface SBDevice ()
@property (nonatomic, strong) id simDevice;
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
    if (!runtime) return nil;
    return [(id<_SimRuntime>)runtime name];
}

- (NSString *)runtimeIdentifier {
    id runtime = [(id<_SimDevice>)_simDevice runtime];
    if (!runtime) return nil;
    return [(id<_SimRuntime>)runtime identifier];
}

- (NSString *)deviceTypeName {
    id deviceType = [(id<_SimDevice>)_simDevice deviceType];
    if (!deviceType) return nil;
    return [(id<_SimDeviceType>)deviceType name];
}

- (BOOL)isAvailable {
    // isAvailable may not exist on all CoreSimulator versions / may be in a category.
    // Try isAvailable, then available, then default to YES.
    if ([_simDevice respondsToSelector:@selector(isAvailable)]) {
        return [(id<_SimDevice>)_simDevice isAvailable];
    }
    if ([_simDevice respondsToSelector:NSSelectorFromString(@"available")]) {
        return [[_simDevice valueForKey:@"available"] boolValue];
    }
    // If neither exists, check if the device has a valid runtime as a proxy.
    return self.runtimeName != nil;
}

- (BOOL)bootWithError:(NSError **)error {
    @try {
        return [(id<_SimDevice>)_simDevice bootWithOptions:nil error:error];
    } @catch (NSException *exception) {
        if (error) {
            *error = _makeError(10, [NSString stringWithFormat:@"Boot exception: %@", exception.reason]);
        }
        return NO;
    }
}

- (BOOL)shutdownWithError:(NSError **)error {
    @try {
        return [(id<_SimDevice>)_simDevice shutdownWithError:error];
    } @catch (NSException *exception) {
        if (error) {
            *error = _makeError(11, [NSString stringWithFormat:@"Shutdown exception: %@", exception.reason]);
        }
        return NO;
    }
}

- (BOOL)installAppAt:(NSString *)path error:(NSError **)error {
    @try {
        NSURL *url = [NSURL fileURLWithPath:path];
        return [(id<_SimDevice>)_simDevice installApplication:url withOptions:nil error:error];
    } @catch (NSException *exception) {
        if (error) {
            *error = _makeError(12, [NSString stringWithFormat:@"Install exception: %@", exception.reason]);
        }
        return NO;
    }
}

- (NSInteger)launchAppWithBundleID:(NSString *)bundleID
                         arguments:(NSArray<NSString *> *)args
                       environment:(NSDictionary<NSString *, NSString *> *)env
                             error:(NSError **)error {
    @try {
        NSMutableDictionary *options = [NSMutableDictionary dictionary];
        if (args) options[@"arguments"] = args;
        if (env) options[@"environment"] = env;

        int pid = [(id<_SimDevice>)_simDevice launchApplicationWithID:bundleID
                                                              options:options
                                                                error:error];
        return (NSInteger)pid;
    } @catch (NSException *exception) {
        if (error) {
            *error = _makeError(13, [NSString stringWithFormat:@"Launch exception: %@", exception.reason]);
        }
        return -1;
    }
}

- (NSInteger)spawnProcess:(NSString *)path
                arguments:(NSArray<NSString *> *)args
              environment:(NSDictionary<NSString *, NSString *> *)env
                    error:(NSError **)error {
    @try {
        NSMutableDictionary *options = [NSMutableDictionary dictionary];
        if (args) options[@"arguments"] = args;
        if (env) options[@"environment"] = env;

        int pid = [(id<_SimDevice>)_simDevice spawnWithPath:path
                                                    options:options
                                           terminationQueue:nil
                                         terminationHandler:nil
                                                      error:error];
        return (NSInteger)pid;
    } @catch (NSException *exception) {
        if (error) {
            *error = _makeError(14, [NSString stringWithFormat:@"Spawn exception: %@", exception.reason]);
        }
        return -1;
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<SBDevice: %@ (%@) %@ — %@>",
            self.name, self.udid.UUIDString, self.stateString, self.runtimeName ?: @"no runtime"];
}

@end

#pragma mark - SBRuntime

@interface SBRuntime ()
@property (nonatomic, strong) id simRuntime;
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
    return [NSString stringWithFormat:@"<SBRuntime: %@ (%@) %@>",
            self.name, self.versionString, self.isAvailable ? @"available" : @"unavailable"];
}

@end

#pragma mark - Public Functions

BOOL SBLoadFramework(NSError **error) {
    // Fast path: already loaded.
    if (_frameworkLoaded) return YES;

    // Thread-safe one-time initialization.
    __block NSError *loadError = nil;
    dispatch_once(&_loadOnce, ^{
        NSBundle *bundle = [NSBundle bundleWithPath:
            @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework"];
        if (!bundle) {
            loadError = _makeError(1, @"CoreSimulator.framework not found at /Library/Developer/PrivateFrameworks/");
            return;
        }

        NSError *bundleError = nil;
        if (![bundle loadAndReturnError:&bundleError]) {
            loadError = bundleError;
            return;
        }

        _SimServiceContextClass = objc_lookUpClass("SimServiceContext");
        if (!_SimServiceContextClass) {
            loadError = _makeError(2, @"SimServiceContext class not found after loading CoreSimulator");
            return;
        }

        _frameworkLoaded = YES;
    });

    if (!_frameworkLoaded) {
        if (error && loadError) *error = loadError;
        return NO;
    }
    return YES;
}

NSArray<SBDevice *> *SBListDevices(NSError **error) {
    if (!_frameworkLoaded && !SBLoadFramework(error)) return nil;

    id deviceSet = _defaultDeviceSet(error);
    if (!deviceSet) return nil;

    NSArray *simDevices = [(id<_SimDeviceSet>)deviceSet availableDevices];
    NSMutableArray<SBDevice *> *result = [NSMutableArray arrayWithCapacity:simDevices.count];

    for (id simDevice in simDevices) {
        [result addObject:[[SBDevice alloc] initWithSimDevice:simDevice]];
    }

    return result;
}

NSArray<SBRuntime *> *SBListRuntimes(NSError **error) {
    if (!_frameworkLoaded && !SBLoadFramework(error)) return nil;

    id context = _sharedContext(error);
    if (!context) return nil;

    if (![context respondsToSelector:@selector(supportedRuntimes)]) {
        if (error) *error = _makeError(3, @"supportedRuntimes method not available on SimServiceContext");
        return nil;
    }

    NSArray *runtimes = [(id<_SimServiceContext>)context supportedRuntimes];
    NSMutableArray<SBRuntime *> *result = [NSMutableArray arrayWithCapacity:runtimes.count];

    for (id rt in runtimes) {
        [result addObject:[[SBRuntime alloc] initWithSimRuntime:rt]];
    }

    return result;
}

SBDevice *SBFindDeviceByUDID(NSString *udidString, NSError **error) {
    NSArray<SBDevice *> *devices = SBListDevices(error);
    if (!devices) return nil;

    for (SBDevice *device in devices) {
        if ([device.udid.UUIDString.lowercaseString isEqualToString:udidString.lowercaseString]) {
            return device;
        }
    }

    if (error) *error = _makeError(4, [NSString stringWithFormat:@"No device with UDID: %@", udidString]);
    return nil;
}

SBDevice *SBFindBootedDevice(NSError **error) {
    NSArray<SBDevice *> *devices = SBListDevices(error);
    if (!devices) return nil;

    for (SBDevice *device in devices) {
        if (device.state == SBDeviceStateBooted) {
            return device;
        }
    }

    if (error) *error = _makeError(5, @"No booted simulator device found");
    return nil;
}

#pragma mark - Touch Events via SimulatorKit

#import <AppKit/AppKit.h>
#import <dlfcn.h>

// Opaque struct — layout managed by SimulatorKit
typedef struct IndigoHIDMessageStruct IndigoHIDMessageStruct;

// Function pointer types for SimulatorKit C functions
typedef IndigoHIDMessageStruct *(*IndigoHIDMessageForMouseNSEventFn)(
    CGPoint *point1, CGPoint *point2, uint32_t target,
    NSEventType type, NSSize displaySize, uint32_t edge);

typedef uint32_t (*IndigoHIDTargetForScreenFn)(void);

// SimDeviceLegacyHIDClient protocol (Swift class, but send may be @objc)
@protocol _SimDeviceLegacyHIDClient
- (BOOL)sendWithMessage:(void *)message
           freeWhenDone:(BOOL)freeWhenDone
        completionQueue:(dispatch_queue_t _Nullable)queue
             completion:(void (^ _Nullable)(NSError * _Nullable))completion
                  error:(NSError **)error;
@end

static BOOL _simKitLoaded = NO;
static dispatch_once_t _simKitOnce;
static IndigoHIDMessageForMouseNSEventFn _indigoMouseEvent = NULL;
static IndigoHIDTargetForScreenFn _indigoTarget = NULL;
static Class _hidClientClass = Nil;

static BOOL _loadSimulatorKit(NSError **error) {
    __block NSError *loadError = nil;
    dispatch_once(&_simKitOnce, ^{
        // Find SimulatorKit in Xcode
        NSString *devDir = _developerDir();
        NSString *simKitPath = [devDir stringByAppendingPathComponent:
            @"../SharedFrameworks/SimulatorKit.framework"];
        // Normalize path
        simKitPath = [simKitPath stringByStandardizingPath];

        NSBundle *bundle = [NSBundle bundleWithPath:simKitPath];
        if (!bundle) {
            // Try alternate location
            simKitPath = [devDir stringByAppendingPathComponent:
                @"Library/PrivateFrameworks/SimulatorKit.framework"];
            bundle = [NSBundle bundleWithPath:simKitPath];
        }
        if (!bundle) {
            loadError = _makeError(20, [NSString stringWithFormat:
                @"SimulatorKit.framework not found near %@", devDir]);
            return;
        }

        NSError *bundleError = nil;
        if (![bundle loadAndReturnError:&bundleError]) {
            loadError = bundleError;
            return;
        }

        void *handle = dlopen(simKitPath.UTF8String, RTLD_NOW);
        if (!handle) handle = dlopen(bundle.executablePath.UTF8String, RTLD_NOW);

        if (handle) {
            _indigoMouseEvent = (IndigoHIDMessageForMouseNSEventFn)dlsym(handle, "IndigoHIDMessageForMouseNSEvent");
            _indigoTarget = (IndigoHIDTargetForScreenFn)dlsym(handle, "IndigoHIDTargetForScreen");
        }

        _hidClientClass = objc_lookUpClass("_TtC12SimulatorKit24SimDeviceLegacyHIDClient");

        if (!_indigoMouseEvent) {
            loadError = _makeError(21, @"IndigoHIDMessageForMouseNSEvent not found in SimulatorKit");
            return;
        }
        if (!_hidClientClass) {
            loadError = _makeError(22, @"SimDeviceLegacyHIDClient class not found in SimulatorKit");
            return;
        }

        _simKitLoaded = YES;
    });

    if (!_simKitLoaded && error && loadError) *error = loadError;
    return _simKitLoaded;
}

static id _createHIDClient(id simDevice, NSError **error) {
    // Try ObjC-style alloc/init patterns the Swift class might expose
    SEL initSel = NSSelectorFromString(@"initWithDevice:sessionResetQueue:sessionResetHandler:");
    if ([_hidClientClass instancesRespondToSelector:initSel]) {
        id client = [_hidClientClass alloc];
        NSMethodSignature *sig = [client methodSignatureForSelector:initSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:client];
            [inv setSelector:initSel];
            [inv setArgument:&simDevice atIndex:2];
            dispatch_queue_t nilQueue = nil;
            [inv setArgument:&nilQueue atIndex:3];
            id nilHandler = nil;
            [inv setArgument:&nilHandler atIndex:4];
            @try {
                [inv invoke];
                id result = nil;
                [inv getReturnValue:&result];
                return result;
            } @catch (NSException *e) {
                NSLog(@"SimulatorBridge: HID client init exception: %@", e.reason);
            }
        }
    }

    // Fallback: try simpler init
    SEL simpleSel = NSSelectorFromString(@"initWithDevice:error:");
    if ([_hidClientClass instancesRespondToSelector:simpleSel]) {
        id client = [_hidClientClass alloc];
        @try {
            return [client performSelector:simpleSel withObject:simDevice withObject:nil];
        } @catch (NSException *e) {
            NSLog(@"SimulatorBridge: HID client simple init exception: %@", e.reason);
        }
    }

    if (error) *error = _makeError(23, @"Failed to create SimDeviceLegacyHIDClient — no compatible init found");
    return nil;
}

static BOOL _sendMouseEvent(SBDevice *device, NSEventType eventType,
                            double x, double y, double displayWidth, double displayHeight,
                            NSError **error) {
    if (!_simKitLoaded && !_loadSimulatorKit(error)) return NO;

    id client = _createHIDClient(device.simDevice, error);
    if (!client) return NO;

    CGPoint point = CGPointMake(x, y);
    uint32_t target = _indigoTarget ? _indigoTarget() : 0;
    NSSize displaySize = NSMakeSize(displayWidth, displayHeight);

    IndigoHIDMessageStruct *msg = _indigoMouseEvent(&point, &point, target, eventType, displaySize, 0);
    if (!msg) {
        if (error) *error = _makeError(24, @"IndigoHIDMessageForMouseNSEvent returned nil");
        return NO;
    }

    // Try sending via the client
    SEL sendSel = NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:error:");
    if ([client respondsToSelector:sendSel]) {
        BOOL freeWhenDone = YES;
        dispatch_queue_t nilQueue = nil;
        id nilCompletion = nil;
        NSError *sendError = nil;

        NSMethodSignature *sig = [client methodSignatureForSelector:sendSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:client];
        [inv setSelector:sendSel];
        [inv setArgument:&msg atIndex:2];
        [inv setArgument:&freeWhenDone atIndex:3];
        [inv setArgument:&nilQueue atIndex:4];
        [inv setArgument:&nilCompletion atIndex:5];
        [inv setArgument:&sendError atIndex:6];

        @try {
            [inv invoke];
            BOOL success = NO;
            [inv getReturnValue:&success];
            if (!success && error) *error = sendError ?: _makeError(25, @"send returned NO");
            return success;
        } @catch (NSException *e) {
            if (error) *error = _makeError(25, [NSString stringWithFormat:@"send exception: %@", e.reason]);
            return NO;
        }
    }

    // Fallback: try simple send
    SEL simpleSend = NSSelectorFromString(@"sendWithMessage:");
    if ([client respondsToSelector:simpleSend]) {
        @try {
            NSMethodSignature *sig = [client methodSignatureForSelector:simpleSend];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:client];
            [inv setSelector:simpleSend];
            [inv setArgument:&msg atIndex:2];
            [inv invoke];
            return YES;
        } @catch (NSException *e) {
            if (error) *error = _makeError(25, [NSString stringWithFormat:@"sendWithMessage exception: %@", e.reason]);
            return NO;
        }
    }

    if (error) *error = _makeError(26, @"No compatible send method found on HID client");
    return NO;
}

BOOL SBSendTouchDown(SBDevice *device, double x, double y,
                     double displayWidth, double displayHeight, NSError **error) {
    return _sendMouseEvent(device, NSEventTypeLeftMouseDown, x, y, displayWidth, displayHeight, error);
}

BOOL SBSendTouchUp(SBDevice *device, double x, double y,
                   double displayWidth, double displayHeight, NSError **error) {
    return _sendMouseEvent(device, NSEventTypeLeftMouseUp, x, y, displayWidth, displayHeight, error);
}
