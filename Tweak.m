// YTControl — MFi controller support for the YouTube iOS app.
// Same idea as FControl (GameController -> actions inside the target app), but
// for YouTube. Left stick moves an on-screen pointer, A taps at the pointer
// (synthetic touch, same technique FControl used via IOHIDEvent), and the rest
// of the buttons drive the player.
//
// NOTE: written without access to a device/SDK — test on-device. YouTube
// updates can rename internal selectors; every call is guarded with
// respondsToSelector:, so a miss just does nothing instead of crashing.

#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

#pragma mark - Private API declarations

@interface UITouch (YTC)
- (void)setWindow:(UIWindow *)w;
- (void)setView:(UIView *)v;
- (void)setTapCount:(NSUInteger)c;
- (void)setIsTap:(BOOL)b;
- (void)setTimestamp:(NSTimeInterval)t;
- (void)setPhase:(UITouchPhase)p;
- (void)setGestureView:(UIView *)v;
- (void)_setLocationInWindow:(CGPoint)p resetPrevious:(BOOL)r;
- (void)_setIsFirstTouchForView:(BOOL)b;
- (void)_setHidEvent:(void *)e;
@end

@interface UIEvent (YTC)
- (void)_setHIDEvent:(void *)e;
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)t forDelayedDelivery:(BOOL)d;
@end

@interface UIApplication (YTC)
- (UIEvent *)_touchesEvent;
@end

#pragma mark - IOHID (resolved at runtime, no IOKit link needed)

typedef void *HIDEvent;
static HIDEvent (*pCreateHand)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                               double, double, double, double, double, Boolean, Boolean, uint32_t);
static HIDEvent (*pCreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                 double, double, double, double, double, double, double,
                                 double, double, double, Boolean, Boolean, uint32_t);
static void (*pAppend)(HIDEvent, HIDEvent, uint32_t);
static void (*pSetInt)(HIDEvent, uint32_t, int64_t);

#if !defined(__LP64__)
static BOOL loadHID(void) { return NO; }
static HIDEvent makeHIDEvent(CGPoint p, UITouchPhase phase) { return NULL; }
#else
static BOOL loadHID(void) {
    static BOOL ok = NO, tried = NO;
    if (tried) return ok;
    tried = YES;
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) return NO;
    pCreateHand   = dlsym(h, "IOHIDEventCreateDigitizerEvent");
    pCreateFinger = dlsym(h, "IOHIDEventCreateDigitizerFingerEventWithQuality");
    pAppend       = dlsym(h, "IOHIDEventAppendEvent");
    pSetInt       = dlsym(h, "IOHIDEventSetIntegerValue");
    ok = pCreateHand && pCreateFinger && pAppend && pSetInt;
    return ok;
}

static HIDEvent makeHIDEvent(CGPoint p, UITouchPhase phase) {
    uint64_t ts = mach_absolute_time();
    BOOL touching = (phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled);
    uint32_t mask = (phase == UITouchPhaseMoved) ? 0x4 : 0x3; // position | range|touch
    HIDEvent hand = pCreateHand(kCFAllocatorDefault, ts, 3, 0, 0, mask, 0, 0, 0, 0, 0, 0, touching, touching, 0);
    pSetInt(hand, 0xb0019, 1); // display integrated
    HIDEvent finger = pCreateFinger(kCFAllocatorDefault, ts, 1, 2, mask, p.x, p.y, 0, 0, 0, 0.04, 0.04,
                                    1, 1, 1, touching, touching, 0);
    pAppend(hand, finger, 0);
    CFRelease(finger);
    return hand;
}

#endif

#pragma mark - Helpers

static UIWindow *keyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *w = app.keyWindow;
    if (!w) w = app.windows.lastObject;
    return w;
}

static void sendTouch(UIWindow *w, UIView *hit, CGPoint pt, UITouchPhase phase, UITouch *touch) {
    UIApplication *app = UIApplication.sharedApplication;
    [touch setPhase:phase];
    [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
    [touch _setLocationInWindow:pt resetPrevious:(phase == UITouchPhaseBegan)];
    UIEvent *ev = [app _touchesEvent];
    [ev _clearTouches];
    HIDEvent he = NULL;
    // iOS 8 doesn't need (or have) the HID plumbing; only use it where UIKit exposes it.
    if (loadHID() && [touch respondsToSelector:@selector(_setHidEvent:)] && [ev respondsToSelector:@selector(_setHIDEvent:)]) {
        he = makeHIDEvent(pt, phase);
        [touch _setHidEvent:he];
        [ev _setHIDEvent:he];
    }
    [ev _addTouch:touch forDelayedDelivery:NO];
    [app sendEvent:ev];
    if (he) CFRelease(he);
}

static void tapAt(CGPoint pt) {
    UIWindow *w = keyWindow();
    if (!w) return;
    UIView *hit = [w hitTest:pt withEvent:nil];
    if (!hit) return;
    UITouch *t = [[UITouch alloc] init];
    [t setWindow:w];
    [t setTapCount:1];
    if ([t respondsToSelector:@selector(setIsTap:)]) [t setIsTap:YES];
    [t setView:hit];
    if ([t respondsToSelector:@selector(_setIsFirstTouchForView:)]) [t _setIsFirstTouchForView:YES];
    if ([t respondsToSelector:@selector(setGestureView:)]) [t setGestureView:hit];
    sendTouch(w, hit, pt, UITouchPhaseBegan, t);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        sendTouch(w, hit, pt, UITouchPhaseEnded, t);
    });
}

// --- view / VC walking ---

static void walkViews(UIView *v, BOOL (^block)(UIView *)) {
    if (!v || v.isHidden) return;
    if (block(v)) return;
    for (UIView *s in v.subviews.copy) walkViews(s, block);
}

static UIViewController *findVC(UIViewController *vc, Class cls) {
    if (!vc) return nil;
    if ([vc isKindOfClass:cls]) return vc;
    for (UIViewController *c in vc.childViewControllers) {
        UIViewController *r = findVC(c, cls); if (r) return r;
    }
    return findVC(vc.presentedViewController, cls);
}

static id playerVC(void) {
    static __weak id cached;
    if (cached) return cached;
    Class cls = NSClassFromString(@"YTPlayerViewController");
    if (!cls) return nil;
    UIViewController *r = findVC(keyWindow().rootViewController, cls);
    cached = r;
    return r;
}

static BOOL trySel(id o, NSString *name) {
    SEL s = NSSelectorFromString(name);
    if (o && [o respondsToSelector:s]) { ((void (*)(id, SEL))objc_msgSend)(o, s); return YES; }
    return NO;
}
static double getDouble(id o, NSString *name, double def) {
    SEL s = NSSelectorFromString(name);
    if (o && [o respondsToSelector:s]) return ((double (*)(id, SEL))objc_msgSend)(o, s);
    return def;
}

// Press a button in YouTube's UI by accessibility label (language-tolerant keyword match).
static BOOL pressButton(NSArray<NSString *> *keywords) {
    UIWindow *w = keyWindow();
    __block BOOL found = NO;
    walkViews(w, ^BOOL(UIView *v) {
        if (![v isKindOfClass:UIControl.class]) return NO;
        NSString *l = v.accessibilityLabel.lowercaseString;
        if (!l.length) return NO;
        for (NSString *k in keywords) {
            if ([l containsString:k.lowercaseString]) {
                [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
                found = YES; return YES;
            }
        }
        return NO;
    });
    return found;
}

#pragma mark - Actions

static BOOL isPlaying(void) {
    id p = playerVC();
    SEL s = NSSelectorFromString(@"isPlaying");
    if (p && [p respondsToSelector:s]) return ((BOOL (*)(id, SEL))objc_msgSend)(p, s);
    NSNumber *rate = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate];
    return rate.doubleValue > 0;
}

static void actPlayPause(void) {
    id p = playerVC();
    if (isPlaying()) { if (!trySel(p, @"pauseVideo")) pressButton(@[@"pause"]); }
    else             { if (!trySel(p, @"playVideo"))  pressButton(@[@"play"]); }
}

static void actSeek(double delta) {
    id p = playerVC();
    SEL s = NSSelectorFromString(@"seekToTime:");
    if (!p || ![p respondsToSelector:s]) return;
    double cur = getDouble(p, @"currentVideoMediaTime", 0);
    double total = getDouble(p, @"currentVideoTotalMediaTime", DBL_MAX);
    double target = MAX(0, MIN(total, cur + delta));
    ((void (*)(id, SEL, double))objc_msgSend)(p, s, target);
}

static void actVolume(float delta) {
    static MPVolumeView *vv;
    if (!vv) {
        vv = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 10, 10)];
        [keyWindow() addSubview:vv];
    }
    UISlider *sl = nil;
    for (UIView *v in vv.subviews) if ([v isKindOfClass:UISlider.class]) sl = (UISlider *)v;
    if (!sl) return;
    sl.value = MAX(0, MIN(1, sl.value + delta));
    [sl sendActionsForControlEvents:UIControlEventValueChanged];
}

static void actFullscreen(void) { pressButton(@[@"full screen", @"fullscreen", @"ملء الشاشة"]); }
static void actNext(void)       { if (!trySel(playerVC(), @"nextVideo")) pressButton(@[@"next", @"التالي"]); }
static void actPrev(void)       { if (!trySel(playerVC(), @"previousVideo")) pressButton(@[@"previous", @"السابق"]); }
static void actCaptions(void)   { pressButton(@[@"captions", @"subtitles", @"closed caption", @"الترجمة"]); }
static void actBack(void) {
    if (pressButton(@[@"minimize", @"exit full screen", @"exit fullscreen", @"back", @"close", @"رجوع", @"تصغير"])) return;
    UIViewController *top = keyWindow().rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:UINavigationController.class]) [(UINavigationController *)top popViewControllerAnimated:YES];
    else [top dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Pointer + controller manager

@interface YTCManager : NSObject
@property (nonatomic) CGPoint pointer;
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, weak) GCExtendedGamepad *pad;
@property (nonatomic) float lx, ly, rx, ry;
@property (nonatomic) int dpadH;          // -1 / 0 / +1 held
@property (nonatomic) CFTimeInterval lastRepeat;
@property (nonatomic) BOOL pointerVisible;
+ (instancetype)shared;
- (void)start;
@end

@implementation YTCManager
+ (instancetype)shared { static YTCManager *m; static dispatch_once_t o; dispatch_once(&o, ^{ m = [YTCManager new]; }); return m; }

- (void)start {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(connected:) name:GCControllerDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(disconnected:) name:GCControllerDidDisconnectNotification object:nil];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
    for (GCController *c in GCController.controllers) [self bind:c];
    self.pointerVisible = YES;
}

- (void)connected:(NSNotification *)n { [self bind:n.object]; }
- (void)disconnected:(NSNotification *)n {
    [self.dot removeFromSuperview]; [self.link invalidate]; self.link = nil; self.pad = nil;
}

- (void)ensureOverlay {
    if (self.dot) return;
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    dot.userInteractionEnabled = NO;
    dot.layer.cornerRadius = 11;
    dot.layer.borderWidth = 2;
    dot.layer.borderColor = UIColor.whiteColor.CGColor;
    dot.backgroundColor = [UIColor colorWithRed:1 green:0 blue:0 alpha:0.55];
    self.dot = dot;
    CGRect b = keyWindow().bounds;
    self.pointer = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
}

- (void)bind:(GCController *)c {
    GCExtendedGamepad *g = c.extendedGamepad;
    if (!g) return;
    self.pad = g;
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [ws ensureOverlay];
        if (!ws.link) {
            ws.link = [CADisplayLink displayLinkWithTarget:ws selector:@selector(tick:)];
            [ws.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        }
    });

    void (^on)(GCControllerButtonInput *, void (^)(void)) = ^(GCControllerButtonInput *b, void (^blk)(void)) {
        b.pressedChangedHandler = ^(GCControllerButtonInput *btn, float v, BOOL pressed) {
            if (pressed) dispatch_async(dispatch_get_main_queue(), blk);
        };
    };

    // ---- Button mapping (edit freely) ----
    on(g.buttonA,        ^{ tapAt(ws.pointer); });          // click at pointer
    on(g.buttonB,        ^{ actBack(); });                  // back / minimize
    on(g.buttonX,        ^{ actPlayPause(); });             // play / pause
    on(g.buttonY,        ^{ actFullscreen(); });            // fullscreen
    on(g.leftShoulder,   ^{ actPrev(); });                  // previous video
    on(g.rightShoulder,  ^{ actNext(); });                  // next video
    on(g.leftTrigger,    ^{ actSeek(-30); });               // -30s
    on(g.rightTrigger,   ^{ actSeek(+30); });               // +30s
    on(g.dpad.up,        ^{ actVolume(+0.0625f); });        // volume up
    on(g.dpad.down,      ^{ actVolume(-0.0625f); });        // volume down
    c.controllerPausedHandler = ^(GCController *ctl) {   // Menu / Start
        dispatch_async(dispatch_get_main_queue(), ^{ ws.pointerVisible = !ws.pointerVisible; });
    };

    g.dpad.left.pressedChangedHandler  = ^(GCControllerButtonInput *b, float v, BOOL p) {
        if (p) { ws.dpadH = -1; dispatch_async(dispatch_get_main_queue(), ^{ actSeek(-10); ws.lastRepeat = CACurrentMediaTime(); }); }
        else if (ws.dpadH == -1) ws.dpadH = 0;
    };
    g.dpad.right.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) {
        if (p) { ws.dpadH = 1; dispatch_async(dispatch_get_main_queue(), ^{ actSeek(10); ws.lastRepeat = CACurrentMediaTime(); }); }
        else if (ws.dpadH == 1) ws.dpadH = 0;
    };

    g.leftThumbstick.valueChangedHandler  = ^(GCControllerDirectionPad *d, float x, float y) { ws.lx = x; ws.ly = y; };
    g.rightThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *d, float x, float y) { ws.rx = x; ws.ry = y; };
}

- (void)tick:(CADisplayLink *)l {
    const float dz = 0.15f;
    CGRect b = keyWindow().bounds;

    // Left stick -> pointer
    if (fabsf(self.lx) > dz || fabsf(self.ly) > dz) {
        CGFloat speed = 14;
        CGPoint p = self.pointer;
        p.x = MAX(0, MIN(b.size.width,  p.x + self.lx * speed));
        p.y = MAX(0, MIN(b.size.height, p.y - self.ly * speed));
        self.pointer = p;
    }
    UIWindow *kw = keyWindow();
    if (self.dot.superview != kw) [kw addSubview:self.dot];
    [kw bringSubviewToFront:self.dot];
    self.dot.hidden = !self.pointerVisible;
    self.dot.center = self.pointer;

    // Right stick Y -> scroll the scroll view under the pointer
    if (fabsf(self.ry) > dz) {
        UIWindow *w = keyWindow();
        UIView *v = [w hitTest:self.pointer withEvent:nil];
        while (v && !([v isKindOfClass:UIScrollView.class] && ((UIScrollView *)v).scrollEnabled
                      && ((UIScrollView *)v).contentSize.height > v.bounds.size.height + 1)) v = v.superview;
        UIScrollView *sv = (UIScrollView *)v;
        if (sv) {
            CGFloat minY = -sv.contentInset.top;
            CGFloat maxY = MAX(minY, sv.contentSize.height - sv.bounds.size.height + sv.contentInset.bottom);
            CGFloat y = MAX(minY, MIN(maxY, sv.contentOffset.y - self.ry * 22));
            [sv setContentOffset:CGPointMake(sv.contentOffset.x, y) animated:NO];
        }
    }

    // Right stick X -> scrub (throttled)
    CFTimeInterval now = CACurrentMediaTime();
    if (fabsf(self.rx) > 0.6f && now - self.lastRepeat > 0.25) {
        actSeek(self.rx > 0 ? 5 : -5); self.lastRepeat = now;
    }
    // Held D-pad left/right -> repeat seek
    if (self.dpadH != 0 && now - self.lastRepeat > 0.35) {
        actSeek(self.dpadH * 10); self.lastRepeat = now;
    }
}
@end

#pragma mark - Entry

__attribute__((constructor))
static void ytc_init(void) {
    @autoreleasepool {
        NSLog(@"YTControl: loaded");
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            static dispatch_once_t once;
            dispatch_once(&once, ^{ [[YTCManager shared] start]; });
        }];
    }
}
