#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>

typedef struct {
    unsigned int val[8];
} pvm_audit_token_t;
#ifndef LOCAL_PEERTOKEN
#define LOCAL_PEERTOKEN 0x006
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

static NSString *argval(NSString *key, NSString *def) {
    NSArray *a = NSProcessInfo.processInfo.arguments;
    for (NSUInteger i = 0; i + 1 < a.count; i++)
        if ([a[i] isEqualToString:key]) return a[i + 1];
    return def;
}

@interface ShellSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) id host;
@property(nonatomic, strong) id fgAssertion;
@property(nonatomic, strong) UIViewController *hostedVC;
@property(nonatomic, copy) NSString *agentSock;
@property(nonatomic, assign) int agentFD;
@property(nonatomic, strong) UIImage *cachedFrame;
@property(nonatomic, strong) UIView *overlay;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UIImageView *disconnectedIcon;
@property(nonatomic, copy) dispatch_block_t spinnerBlock;
@property(nonatomic, copy) dispatch_block_t disconnectBlock;
@property(nonatomic, strong) dispatch_source_t deathSource;
@property(nonatomic, strong) dispatch_source_t snapTimer;
@property(nonatomic, assign) BOOL wasBackgrounded;
- (void)showSpinner;
- (void)showDisconnected;
@end

@implementation ShellSceneDelegate
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)opts {
    UIWindowScene *ws = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:ws];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    self.agentSock = argval(@"--agent-sock", @"");
    self.agentFD = -1;
    [self connectAndHost];
}

// Connect to the agent's UDS (retrying — on respawn the new agent binds it
// asynchronously), read its audit token, then host its scene on the main queue.
// The held connection doubles as the death detector (watchAgentDeath).
- (void)connectAndHost {
    NSString *sock = self.agentSock;
    if (sock.length == 0) {
        NSLog(@"[SHELL] no --agent-sock");
        return;
    }
    [NSThread detachNewThreadWithBlock:^{
        int fd = -1;
        for (int i = 0; i < 300; i++) {
            fd = socket(AF_UNIX, SOCK_STREAM, 0);
            struct sockaddr_un a;
            memset(&a, 0, sizeof a);
            a.sun_family = AF_UNIX;
            strncpy(a.sun_path, sock.UTF8String, sizeof(a.sun_path) - 1);
            if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) break;
            close(fd);
            fd = -1;
            usleep(100 * 1000);
        }
        if (fd < 0) {
            NSLog(@"[SHELL] agent UDS connect failed; retrying");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self connectAndHost];
            });
            return;
        }
        pvm_audit_token_t tok;
        socklen_t len = sizeof tok;
        if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &tok, &len) != 0) {
            NSLog(@"[SHELL] LOCAL_PEERTOKEN errno=%d", errno);
            close(fd);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.agentFD = fd;
            [self hostWithToken:tok];
            [self watchAgentDeath:fd];
            [self startSnapshotCache];
            [self hideOverlay];
        });
    }];
}

// Resolve the agent's audit token into a routable FrontBoard scene identity.
- (id)clientIdentityForToken:(pvm_audit_token_t)tok {
    dlopen("/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard", RTLD_NOW);
    Class FBPM = NSClassFromString(@"FBProcessManager");
    id mgr = [FBPM performSelector:@selector(sharedInstance)];
    id fbproc = ((id (*)(id, SEL, pvm_audit_token_t))objc_msgSend)(
        mgr, @selector(registerProcessForAuditToken:), tok);
    id procIdentity = fbproc ? [fbproc performSelector:@selector(identity)] : nil;
    if (!procIdentity) {
        NSLog(@"[SHELL] registerProcessForAuditToken failed");
        return nil;
    }
    Class ClientId = NSClassFromString(@"FBSSceneClientIdentity");
    return [ClientId performSelector:@selector(identityForProcessIdentity:) withObject:procIdentity];
}

- (void)hostWithToken:(pvm_audit_token_t)tok {
    id clientId = [self clientIdentityForToken:tok];
    if (!clientId) return;
    Class AdvCfg = NSClassFromString(@"_UISceneHostingControllerAdvancedConfiguration");
    Class HostC = NSClassFromString(@"_UISceneHostingController");
    Class SpecC = NSClassFromString(@"UIApplicationSceneSpecification");
    id adv = [[AdvCfg alloc] performSelector:@selector(initWithClientIdentity:) withObject:clientId];
    id spec = [[SpecC alloc] init];
    [adv performSelector:@selector(setSceneSpecification:) withObject:spec];
    void (^settingsUpdater)(id) = ^(id settings) {
        if ([settings respondsToSelector:@selector(setDeactivationReasons:)])
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(
                settings, @selector(setDeactivationReasons:), 0ULL);
        if ([settings respondsToSelector:@selector(setForeground:)])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, @selector(setForeground:), YES);
        if ([settings respondsToSelector:@selector(setBackgrounded:)])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, @selector(setBackgrounded:), NO);
    };
    if ([adv respondsToSelector:@selector(setInitialSettingsUpdater:)])
        [adv performSelector:@selector(setInitialSettingsUpdater:) withObject:settingsUpdater];
    self.host = [[HostC alloc] performSelector:@selector(initWithAdvancedConfiguration:)
                                    withObject:adv];
    UIViewController *root = self.window.rootViewController;
    id svc = [self.host performSelector:@selector(sceneViewController)];
    if ([svc isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = svc;
        self.hostedVC = vc;
        [root addChildViewController:vc];
        UIView *vv = vc.view;
        vv.frame = self.window.bounds;
        vv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        vv.backgroundColor = [UIColor clearColor];
        // Insert below any held-frame overlay so the live scene appears only
        // once we drop the overlay.
        [root.view insertSubview:vv atIndex:0];
        [vc didMoveToParentViewController:root];
    }
    [self activateHosted];
    NSLog(@"[SHELL] hosted agent");
}

// (Re)assert the hosted scene's foreground activation. Called at host time and
// again on every foreground transition — the hosted scene loses its foreground
// activation when the shell backgrounds and would otherwise come back blank.
- (void)activateHosted {
    if (!self.host) return;
    id comp = [self.host performSelector:@selector(activationStateComponent)];
    @try {
        // Invalidate any prior assertion before replacing it (a BaseBoard
        // assertion traps in -dealloc if released while still active).
        if (self.fgAssertion) {
            if ([self.fgAssertion respondsToSelector:@selector(invalidate)])
                ((void (*)(id, SEL))objc_msgSend)(self.fgAssertion, @selector(invalidate));
            self.fgAssertion = nil;
        }
        self.fgAssertion = [comp performSelector:@selector(foregroundAssertionForReason:)
                                      withObject:@"previewsmcp-shell"];
        ((void (*)(id, SEL, id))objc_msgSend)(comp, @selector(activate:), ^{
            NSLog(@"[SHELL] activate done");
        });
    } @catch (NSException *e) {
        NSLog(@"[SHELL] EXC activate: %@", e);
    }
}


// Cache the live hosted frame ~1x/sec so a recent frame is available to hold
// across an agent respawn. The hosted view goes black the instant the agent
// dies, so the cache must be taken while it is alive (afterScreenUpdates:YES
// rasterizes the cross-process scene — proven by the derisk probe).
- (void)startSnapshotCache {
    [self stopSnapshotCache];
    dispatch_source_t t = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                              (uint64_t)(1.0 * NSEC_PER_SEC), (uint64_t)(0.3 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        typeof(self) self2 = weakSelf;
        if (!self2 || !self2.window || self2.overlay) return;
        UIView *v = self2.window;
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:v.bounds];
        self2.cachedFrame = [r imageWithActions:^(UIGraphicsImageRendererContext *_Nonnull ctx) {
            (void)ctx;
            [v drawViewHierarchyInRect:v.bounds afterScreenUpdates:YES];
        }];
    });
    dispatch_resume(t);
    self.snapTimer = t;
}

- (void)stopSnapshotCache {
    if (self.snapTimer) {
        dispatch_source_cancel(self.snapTimer);
        self.snapTimer = nil;
    }
}

// Watch the held agent UDS for EOF: when the agent process dies the socket
// becomes readable and recv() returns 0. That is the flash-free respawn trigger.
- (void)watchAgentDeath:(int)fd {
    dispatch_source_t s = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(s, ^{
        char buf[64];
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n > 0) return;  // unexpected data from the agent; ignore
        typeof(self) self2 = weakSelf;
        if (!self2 || self2.agentFD != fd) return;
        [self2 onAgentDeath];
    });
    dispatch_resume(s);
    self.deathSource = s;
}

// Agent died: freeze the cached frame + spinner over the dead scene, tear the
// dead host down, and reconnect to the same sock (retrying) to re-host the new
// agent. No shell restart, so the device display never blanks (flash-free).
// Tear down the current hosting so a fresh connectAndHost can rebuild it.
- (void)teardownHost {
    [self stopSnapshotCache];
    if (self.deathSource) {
        dispatch_source_cancel(self.deathSource);
        self.deathSource = nil;
    }
    if (self.agentFD >= 0) {
        close(self.agentFD);
        self.agentFD = -1;
    }
    if (self.hostedVC) {
        [self.hostedVC willMoveToParentViewController:nil];
        [self.hostedVC.view removeFromSuperview];
        [self.hostedVC removeFromParentViewController];
        self.hostedVC = nil;
    }
    // A BaseBoard assertion traps in -dealloc if released while still active,
    // so invalidate it before dropping the reference.
    if (self.fgAssertion) {
        @try {
            if ([self.fgAssertion respondsToSelector:@selector(invalidate)])
                ((void (*)(id, SEL))objc_msgSend)(self.fgAssertion, @selector(invalidate));
        } @catch (NSException *e) {
            NSLog(@"[SHELL] fgAssertion invalidate: %@", e);
        }
        self.fgAssertion = nil;
    }
    self.host = nil;
}

- (void)rehost {
    [self showOverlay];
    [self teardownHost];
    [self connectAndHost];
}

- (void)onAgentDeath {
    NSLog(@"[SHELL] agent died; holding cached frame + spinner, re-hosting");
    [self rehost];
}

// The cross-process hosted scene loses its content when the shell backgrounds
// and does not recover by itself, so re-host on return. Stop caching while
// backgrounded so the last good frame stays in the overlay.
- (void)sceneDidEnterBackground:(UIScene *)scene {
    self.wasBackgrounded = YES;
    [self stopSnapshotCache];
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    if (self.host && self.wasBackgrounded) {
        self.wasBackgrounded = NO;
        NSLog(@"[SHELL] foreground after background; re-hosting");
        [self rehost];
    }
}

// Hold the cached frame under a dim scrim immediately (flash-free), then escalate:
// a spinner appears only if the respawn is slow, and a disconnected icon replaces
// it if the agent never comes back. A successful re-host calls hideOverlay, which
// cancels both pending transitions.
- (void)showOverlay {
    if (self.overlay) return;
    UIView *root = self.window.rootViewController.view;
    UIView *ov = [[UIView alloc] initWithFrame:root.bounds];
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ov.backgroundColor = [UIColor blackColor];
    if (self.cachedFrame) {
        UIImageView *iv = [[UIImageView alloc] initWithFrame:ov.bounds];
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.image = self.cachedFrame;
        [ov addSubview:iv];
    }
    // Subtle dim scrim so the held frame reads as "reloading" and the spinner
    // stays visible over any background color.
    UIView *scrim = [[UIView alloc] initWithFrame:ov.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];
    [ov addSubview:scrim];
    [root addSubview:ov];
    self.overlay = ov;

    __weak typeof(self) weakSelf = self;
    dispatch_block_t spin = dispatch_block_create(0, ^{
        [weakSelf showSpinner];
    });
    dispatch_block_t disc = dispatch_block_create(0, ^{
        [weakSelf showDisconnected];
    });
    self.spinnerBlock = spin;
    self.disconnectBlock = disc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), spin);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), disc);
}

- (UIActivityIndicatorView *)centeredSpinner {
    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spin.color = [UIColor whiteColor];
    spin.center = CGPointMake(self.overlay.bounds.size.width / 2.0,
                              self.overlay.bounds.size.height / 2.0);
    spin.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                            UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    return spin;
}

- (void)showSpinner {
    if (!self.overlay || self.spinner) return;
    UIActivityIndicatorView *spin = [self centeredSpinner];
    [spin startAnimating];
    [self.overlay addSubview:spin];
    self.spinner = spin;
}

- (void)showDisconnected {
    if (!self.overlay || self.disconnectedIcon) return;
    if (self.spinner) {
        [self.spinner removeFromSuperview];
        self.spinner = nil;
    }
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:48];
    UIImage *img = [UIImage systemImageNamed:@"wifi.slash" withConfiguration:cfg];
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.tintColor = [UIColor whiteColor];
    iv.contentMode = UIViewContentModeCenter;
    [iv sizeToFit];
    iv.center = CGPointMake(self.overlay.bounds.size.width / 2.0,
                            self.overlay.bounds.size.height / 2.0);
    iv.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                          UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.overlay addSubview:iv];
    self.disconnectedIcon = iv;
}

- (void)hideOverlay {
    if (self.spinnerBlock) {
        dispatch_block_cancel(self.spinnerBlock);
        self.spinnerBlock = nil;
    }
    if (self.disconnectBlock) {
        dispatch_block_cancel(self.disconnectBlock);
        self.disconnectBlock = nil;
    }
    self.spinner = nil;
    self.disconnectedIcon = nil;
    if (!self.overlay) return;
    [self.overlay removeFromSuperview];
    self.overlay = nil;
}
@end

@interface ShellAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ShellAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)app
    configurationForConnectingSceneSession:(UISceneSession *)s
                                   options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [UISceneConfiguration configurationWithName:@"Default"
                                                             sessionRole:s.role];
    c.delegateClass = [ShellSceneDelegate class];
    return c;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([ShellAppDelegate class]));
    }
}
#pragma clang diagnostic pop
