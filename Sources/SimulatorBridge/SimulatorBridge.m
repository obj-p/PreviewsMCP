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
