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

/// Wrapper around SimDevice providing safe access to CoreSimulator private APIs.
@interface SBDevice : NSObject

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSUUID *udid;
@property (nonatomic, readonly) SBDeviceState state;
@property (nonatomic, readonly) NSString *stateString;
@property (nonatomic, readonly, nullable) NSString *runtimeName;
@property (nonatomic, readonly, nullable) NSString *runtimeIdentifier;
@property (nonatomic, readonly, nullable) NSString *deviceTypeName;
@property (nonatomic, readonly) BOOL isAvailable;

- (BOOL)bootWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)shutdownWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)installAppAt:(NSString *)path error:(NSError *_Nullable *_Nullable)error;

/// Launch an app. Returns the PID on success, or -1 on failure.
- (NSInteger)launchAppWithBundleID:(NSString *)bundleID
                         arguments:(nullable NSArray<NSString *> *)args
                       environment:(nullable NSDictionary<NSString *, NSString *> *)env
                             error:(NSError *_Nullable *_Nullable)error;

/// Spawn a process inside the simulator. Returns the PID on success, or -1 on failure.
- (NSInteger)spawnProcess:(NSString *)path
                arguments:(nullable NSArray<NSString *> *)args
              environment:(nullable NSDictionary<NSString *, NSString *> *)env
                    error:(NSError *_Nullable *_Nullable)error;

@end

/// Wrapper around SimRuntime.
@interface SBRuntime : NSObject

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly) NSString *versionString;
@property (nonatomic, readonly) BOOL isAvailable;

@end

/// Load CoreSimulator.framework at runtime. Safe to call multiple times.
BOOL SBLoadFramework(NSError *_Nullable *_Nullable error);

/// List all available simulator devices.
NSArray<SBDevice *> *_Nullable SBListDevices(NSError *_Nullable *_Nullable error);

/// List all available runtimes.
NSArray<SBRuntime *> *_Nullable SBListRuntimes(NSError *_Nullable *_Nullable error);

/// Find a device by its UDID string.
SBDevice *_Nullable SBFindDeviceByUDID(NSString *udidString, NSError *_Nullable *_Nullable error);

/// Find the first booted device.
SBDevice *_Nullable SBFindBootedDevice(NSError *_Nullable *_Nullable error);

/// Send a touch (tap) to a booted device at the given point coordinates.
/// x, y are in points (matching the device's screen coordinate space).
/// displayWidth, displayHeight are the device's screen size in points.
BOOL SBSendTouchDown(SBDevice *device, double x, double y,
                     double displayWidth, double displayHeight,
                     NSError *_Nullable *_Nullable error);

BOOL SBSendTouchUp(SBDevice *device, double x, double y,
                   double displayWidth, double displayHeight,
                   NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
