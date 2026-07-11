// Consumer half of the #254 macOS cross-process layer-hosting spike.
// Stands in for the preview SHELL: it owns a persistent NSWindow and hosts the
// producer's (agent's) layer cross-process via CALayerHost, rebinding the
// context id whenever the producer is (re)launched. The window never closes
// across a producer kill/respawn; the WindowServer holds the last frame in the
// gap. Private QuartzCore SPI (CALayerHost) declared inline; resolved at
// runtime.
//
// Build: see build.sh. Run: ./consumer ./ctxid  (windowNumber printed to
// stderr)

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

@interface CALayerHost : CALayer
@property uint32_t contextId;
@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "usage: %s <ctxid-file>\n", argv[0]);
      return 1;
    }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(100, 100, 400, 300)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.title = @"layerhost consumer";
    win.releasedWhenClosed = NO;

    NSView *content = win.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = NSColor.systemGreenColor.CGColor;

    CALayerHost *host = [CALayerHost layer];
    host.frame = content.bounds;
    host.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [content.layer addSublayer:host];

    [win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    fprintf(stderr, "consumer windowNumber=%ld\n", (long)win.windowNumber);

    NSString *path = [NSString stringWithUTF8String:argv[1]];
    __block uint32_t current = 0;
    [NSTimer
        scheduledTimerWithTimeInterval:0.25
                               repeats:YES
                                 block:^(NSTimer *t) {
                                   NSString *s = [NSString
                                       stringWithContentsOfFile:path
                                                       encoding:
                                                           NSUTF8StringEncoding
                                                          error:nil];
                                   uint32_t cid =
                                       s ? (uint32_t)strtoul(s.UTF8String, NULL,
                                                             10)
                                         : 0;
                                   if (cid != 0 && cid != current) {
                                     current = cid;
                                     host.contextId = cid;
                                     fprintf(stderr,
                                             "consumer bound contextId=%u\n",
                                             cid);
                                   }
                                 }];

    [NSApp run];
  }
  return 0;
}
