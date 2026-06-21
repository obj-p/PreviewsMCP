#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Simulator device state, mirroring CoreSimulator's SimDeviceState.
typedef NS_ENUM(NSInteger, SBDeviceState) {
  SBDeviceStateCreating = 0,
  SBDeviceStateShutdown = 1,
  SBDeviceStateBooting = 2,
  SBDeviceStateBooted = 3,
  SBDeviceStateShuttingDown = 4,
};

/// Wrapper around SimDevice providing safe access to CoreSimulator private
/// APIs.
@interface SBDevice : NSObject

@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSUUID *udid;
@property(nonatomic, readonly) SBDeviceState state;
@property(nonatomic, readonly) NSString *stateString;
@property(nonatomic, readonly, nullable) NSString *runtimeName;
@property(nonatomic, readonly, nullable) NSString *runtimeIdentifier;
@property(nonatomic, readonly, nullable) NSString *deviceTypeName;
@property(nonatomic, readonly) BOOL isAvailable;

- (BOOL)bootWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)shutdownWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)installAppAt:(NSString *)path
               error:(NSError *_Nullable *_Nullable)error;

/// Launch an app. Returns the PID on success, or -1 on failure.
- (NSInteger)launchAppWithBundleID:(NSString *)bundleID
                         arguments:(nullable NSArray<NSString *> *)args
                       environment:
                           (nullable NSDictionary<NSString *, NSString *> *)env
                             error:(NSError *_Nullable *_Nullable)error;

/// Spawn a process inside the device's boot session ("in-session"), the way
/// `simctl spawn` does (without `--standalone`). On a booted device this is the
/// default `SimDevice spawnWithPath:` behavior: the child shares the boot
/// session, including the host loopback network, so it can reach a TCP listener
/// on the host. (Setting the standalone option, by contrast, gives an isolated
/// process with no in-session networking.) Returns the PID on success, or -1 on
/// failure. `terminationHandler`, if given, is called with the child's exit
/// status when it exits.
- (NSInteger)spawnInSessionWithPath:(NSString *)path
                          arguments:(nullable NSArray<NSString *> *)args
                        environment:
                            (nullable NSDictionary<NSString *, NSString *> *)env
                 terminationHandler:(nullable void (^)(int status))handler
                              error:(NSError *_Nullable *_Nullable)error;

@end

/// Wrapper around SimRuntime.
@interface SBRuntime : NSObject

@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSString *identifier;
@property(nonatomic, readonly) NSString *versionString;
@property(nonatomic, readonly) BOOL isAvailable;

@end

/// Daemon-side HID input client. Injects events at the simulator digitizer via
/// SimulatorKit's SimDeviceLegacyHIDClient, independent of the in-app host
/// touch path (see the touch note in SimulatorBridge.m).
@interface SBHIDClient : NSObject
@end

/// Load CoreSimulator.framework at runtime. Safe to call multiple times.
BOOL SBLoadFramework(NSError *_Nullable *_Nullable error);

/// List all available simulator devices.
NSArray<SBDevice *> *_Nullable SBListDevices(
    NSError *_Nullable *_Nullable error);

/// List all available runtimes.
NSArray<SBRuntime *> *_Nullable SBListRuntimes(
    NSError *_Nullable *_Nullable error);

/// Find a device by its UDID string.
SBDevice *_Nullable SBFindDeviceByUDID(NSString *udidString,
                                       NSError *_Nullable *_Nullable error);

/// Find the first booted device.
SBDevice *_Nullable SBFindBootedDevice(NSError *_Nullable *_Nullable error);

/// Capture the framebuffer of a booted device as image data (JPEG or PNG).
/// Uses direct IOSurface access — no subprocess needed.
/// @param device A booted SBDevice.
/// @param jpegQuality JPEG quality 0.0–1.0. Values >= 1.0 produce PNG output.
/// @param error On failure, set to describe the problem.
/// @return Image data, or nil on failure.
NSData *_Nullable SBCaptureFramebuffer(SBDevice *device, double jpegQuality,
                                       NSError *_Nullable *_Nullable error);

/// Create a HID input client bound to a device. Loads SimulatorKit (separate
/// from CoreSimulator) on first use. Returns nil on failure.
SBHIDClient *_Nullable SBCreateHIDClient(SBDevice *device,
                                         NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
