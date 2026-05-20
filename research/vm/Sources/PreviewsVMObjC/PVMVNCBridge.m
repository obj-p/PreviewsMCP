#import "PVMVNCBridge.h"
#import <Virtualization/Virtualization.h>

// Forward declarations of the private classes we'll call into. The
// runtime lookup (NSClassFromString) is still what binds at startup —
// these only exist so the compiler accepts the call sites.
//
// `_VZVNCNoSecuritySecurityConfiguration` is the "no auth" subclass of
// `_VZVNCSecurityConfiguration`. The other subclass —
// `_VZVNCAuthenticationSecurityConfiguration` — wants a password.
@interface _VZVNCSecurityConfiguration : NSObject
@end

@interface _VZVNCNoSecuritySecurityConfiguration : _VZVNCSecurityConfiguration
- (instancetype)init;
@end

@interface _VZVNCServer : NSObject
- (instancetype)initWithPort:(NSUInteger)port
                       queue:(dispatch_queue_t)queue
       securityConfiguration:(_VZVNCSecurityConfiguration *)securityConfig;
- (void)start;
- (void)stop;
@property (nonatomic) NSUInteger port;
@property (nonatomic, retain) VZVirtualMachine *virtualMachine;
@end

@implementation PVMVNCBridge

+ (NSObject *)startServerWithVirtualMachine:(VZVirtualMachine *)virtualMachine
                                       port:(NSUInteger)port
                                    outPort:(NSUInteger *)outPort
                                      error:(NSError **)error {
    Class secClass = NSClassFromString(@"_VZVNCNoSecuritySecurityConfiguration");
    Class serverClass = NSClassFromString(@"_VZVNCServer");
    if (!secClass || !serverClass) {
        if (error) {
            NSString *missing = !secClass
                ? @"_VZVNCNoSecuritySecurityConfiguration"
                : @"_VZVNCServer";
            *error = [NSError errorWithDomain:@"PVMVNCBridge"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                        @"private SPI class not found: %@ (Virtualization.framework version?)",
                        missing]
            }];
        }
        return nil;
    }

    _VZVNCSecurityConfiguration *secConfig = [[secClass alloc] init];
    if (!secConfig) {
        if (error) {
            *error = [NSError errorWithDomain:@"PVMVNCBridge"
                                         code:2
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    @"failed to alloc/init _VZVNCNoSecuritySecurityConfiguration"
            }];
        }
        return nil;
    }

    // Use a background queue for the server's internal bookkeeping —
    // we call into this bridge from the main thread, so binding the
    // server's queue to main would deadlock its async `start`.
    dispatch_queue_t serverQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    _VZVNCServer *server = [[serverClass alloc] initWithPort:port
                                                       queue:serverQueue
                                       securityConfiguration:secConfig];
    if (!server) {
        if (error) {
            *error = [NSError errorWithDomain:@"PVMVNCBridge"
                                         code:3
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    @"_VZVNCServer initWithPort:queue:securityConfiguration: returned nil"
            }];
        }
        return nil;
    }

    [server setVirtualMachine:virtualMachine];
    [server start];

    // `start` is async — `port` reads 0 until the listener has bound.
    // Poll for up to 5s; the runloop pump lets any main-queue
    // bookkeeping run while we wait.
    NSUInteger bound = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([deadline timeIntervalSinceNow] > 0) {
        bound = server.port;
        if (bound > 0) break;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (bound == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"PVMVNCBridge"
                                         code:4
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    @"_VZVNCServer did not bind to a port within 5s of start"
            }];
        }
        [server stop];
        return nil;
    }

    if (outPort) {
        *outPort = bound;
    }
    return server;
}

+ (void)stop:(NSObject *)serverHandle {
    if (!serverHandle) return;
    _VZVNCServer *server = (_VZVNCServer *)serverHandle;
    [server stop];
}

@end
