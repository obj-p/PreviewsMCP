// Producer half of the #254 macOS cross-process layer-hosting spike.
// Stands in for the preview AGENT: it owns a render layer (red background with
// a spinning blue box), vends it over a CAContext, and writes the context id to
// a file so the consumer (the shell) can host it via CALayerHost. Private
// QuartzCore SPI (CAContext) declared inline; resolved at runtime from
// QuartzCore.
//
// Build: see build.sh. Run: ./producer ./ctxid

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

@interface CAContext : NSObject
+ (CAContext *)remoteContextWithOptions:(NSDictionary *)options;
@property(readonly) uint32_t contextId;
@property(strong) CALayer *layer;
@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "usage: %s <ctxid-file>\n", argv[0]);
      return 1;
    }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    CALayer *root = [CALayer layer];
    root.frame = CGRectMake(0, 0, 400, 300);
    root.backgroundColor = NSColor.systemRedColor.CGColor;

    CALayer *box = [CALayer layer];
    box.frame = CGRectMake(150, 100, 100, 100);
    box.backgroundColor = NSColor.systemBlueColor.CGColor;
    [root addSublayer:box];

    CABasicAnimation *spin =
        [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @0;
    spin.toValue = @(2 * M_PI);
    spin.duration = 2.0;
    spin.repeatCount = HUGE_VALF;
    [box addAnimation:spin forKey:@"spin"];

    CAContext *ctx = [CAContext remoteContextWithOptions:@{}];
    ctx.layer = root;

    FILE *f = fopen(argv[1], "w");
    if (f) {
      fprintf(f, "%u", ctx.contextId);
      fclose(f);
    }
    fprintf(stderr, "producer contextId=%u\n", ctx.contextId);

    [NSApp run];
  }
  return 0;
}
