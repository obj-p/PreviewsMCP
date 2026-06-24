#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

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
/// touch path (see the touch note in SimulatorBridge.m). Coordinates are
/// normalized 0..1 across the device screen. Gestures run asynchronously on a
/// private serial queue; the BOOL reports only whether the HID symbol resolved.
@interface SBHIDClient : NSObject

/// Tap at a normalized point.
- (BOOL)tapAtX:(double)x y:(double)y;

/// Drag from one normalized point to another over `steps` interpolated moves
/// (a value < 1 uses a default of 10).
- (BOOL)dragFromX:(double)fromX
            fromY:(double)fromY
              toX:(double)toX
              toY:(double)toY
            steps:(NSInteger)steps;
@end

/// Daemon-side event-driven framebuffer streamer. Registers screen callbacks on
/// the device's framebuffer display descriptor(s) — which is what wires the
/// display pipeline to this client and populates a live `framebufferSurface` —
/// then encodes a fresh frame only when the surface's IOSurface seed changes,
/// caching the most recent one. Unlike `SBCaptureFramebuffer` (a one-shot pull
/// that walks the IO ports on every call), this holds the pipeline open and is
/// meant to back a hot stream. Must be created and used from the same process
/// that owns the device's display (the daemon that launched the apps).
@interface SBFramebufferStreamer : NSObject

/// Optional sink invoked on the capture queue with each newly captured
/// (seed-changed) display surface, alongside the cached JPEG. Used to feed an
/// H.264 encoder. The surface is valid only for the duration of the call, so a
/// consumer that encodes asynchronously must copy or retain it synchronously.
@property(nonatomic, copy, nullable) void (^onFrameSurface)
    (IOSurfaceRef surface);

/// The most recently encoded frame, or nil before the first frame arrives.
- (nullable NSData *)latestFrame;

/// Stop streaming and unregister callbacks. Idempotent; also called on dealloc.
- (void)stop;

@end

/// Create an event-driven framebuffer streamer bound to a booted device. Loads
/// CoreSimulator on first use. The display pipeline wires up lazily, so
/// `latestFrame` may return nil for a short while (and indefinitely if no app
/// has launched a display). Returns nil only if the device IO client is
/// unavailable.
/// @param device A booted SBDevice.
/// @param jpegQuality JPEG quality 0.0–1.0 (values >= 1.0 produce PNG).
SBFramebufferStreamer *_Nullable SBCreateFramebufferStreamer(
    SBDevice *device, double jpegQuality, NSError *_Nullable *_Nullable error);

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
