// Touch setup informed by KIF and EarlGrey. See ThirdParty/KIF-NOTICE.txt.
// This module creates event metadata and delivers only to this app's WKWebView/window.
// It never dispatches HID events to the system or accesses a hardware HID device.
#import "PrivateTouchProbe.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>

typedef struct {
    uint32_t hi;
    uint32_t lo;
} VXRTime;
typedef CFTypeRef (*HandFn)(CFAllocatorRef, VXRTime, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double,
                            double, double, double, Boolean, Boolean, uint32_t);
typedef CFTypeRef (*FingerFn)(CFAllocatorRef, VXRTime, uint32_t, uint32_t, uint32_t, double, double, double, double,
                              double, double, double, double, double, double, Boolean, Boolean, uint32_t);
typedef void (*AppendFn)(CFTypeRef, CFTypeRef);
typedef void (*IntegerFn)(CFTypeRef, uint32_t, CFIndex);
static HandFn handCreate;
static FingerFn fingerCreate;
static AppendFn appendEvent;
static IntegerFn setInteger;
static BOOL busy;
static void ResolveHID(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
        void *scope = handle ?: RTLD_DEFAULT;
        handCreate = (HandFn)dlsym(scope, "IOHIDEventCreateDigitizerEvent");
        fingerCreate = (FingerFn)dlsym(scope, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        appendEvent = (AppendFn)dlsym(scope, "IOHIDEventAppendEvent");
        setInteger = (IntegerFn)dlsym(scope, "IOHIDEventSetIntegerValue");
    });
}
static BOOL Has(id object, NSString *selector) {
    return [object respondsToSelector:NSSelectorFromString(selector)];
}
static void Object(id o, NSString *s, id v) {
    ((void (*)(id, SEL, id))objc_msgSend)(o, NSSelectorFromString(s), v);
}
static void Number(id o, NSString *s, NSUInteger v) {
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(o, NSSelectorFromString(s), v);
}
static void Flag(id o, NSString *s, BOOL v) {
    if (Has(o, s)) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(o, NSSelectorFromString(s), v);
    }
}
static void Timestamp(id o, NSString *s) {
    ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(o, NSSelectorFromString(s),
                                                      NSProcessInfo.processInfo.systemUptime);
}
static void Location(id o, CGPoint p, BOOL reset) {
    ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(o, NSSelectorFromString(@"_setLocationInWindow:resetPrevious:"), p,
                                                     reset);
}
static void Hid(id o, NSString *s, CFTypeRef value) {
    ((void (*)(id, SEL, CFTypeRef))objc_msgSend)(o, NSSelectorFromString(s), value);
}

@interface UITouch (VXRPrivateInit)
- (instancetype)initVXRProbeTouch;
@end
@implementation UITouch (VXRPrivateInit)
- (instancetype)initVXRProbeTouch {
    return [super init];
}
@end

NSString *VXRInputCapabilities(void) {
    ResolveHID();
    Class event = NSClassFromString(@"UITouchesEvent");
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *s in @[
             @"setWindow:", @"setView:", @"setPhase:", @"setTimestamp:", @"setTapCount:",
             @"_setLocationInWindow:resetPrevious:", @"_setHidEvent:"
         ]) {
        if (![UITouch instancesRespondToSelector:NSSelectorFromString(s)]) {
            [missing addObject:s];
        }
    }
    for (NSString *s in @[ @"_clearTouches", @"_addTouch:forDelayedDelivery:", @"_setHIDEvent:" ]) {
        if (![event instancesRespondToSelector:NSSelectorFromString(s)]) {
            [missing addObject:[@"event." stringByAppendingString:s]];
        }
    }
    if (!handCreate || !fingerCreate || !appendEvent || !setInteger) {
        [missing addObject:@"HID metadata constructors"];
    }
    return missing.count ? [@"Unavailable: " stringByAppendingString:[missing componentsJoinedByString:@", "]]
                         : @"Constructors/selectors present; delivery and web trust are unverified";
}
static CFTypeRef MakeHID(CGPoint p, UITouchPhase phase) {
    uint64_t clock = mach_absolute_time();
    VXRTime time = {(uint32_t)(clock >> 32), (uint32_t)clock};
    BOOL active = phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled;
    uint32_t mask = phase == UITouchPhaseMoved ? 4 : 3;
    CFTypeRef hand = handCreate(kCFAllocatorDefault, time, 3, 0, 0, 2, 0, 0, 0, 0, 0, 0, false, true, 0);
    if (!hand) {
        return NULL;
    }
    CFTypeRef finger =
        fingerCreate(kCFAllocatorDefault, time, 1, 2, mask, p.x, p.y, 0, 0, 0, 5, 5, 1, 1, 0, active, active, 0);
    if (!finger) {
        CFRelease(hand);
        return NULL;
    }
    const uint32_t displayIntegrated = (11u << 16) + 25;
    setInteger(hand, displayIntegrated, 1);
    setInteger(finger, displayIntegrated, 1);
    appendEvent(hand, finger);
    CFRelease(finger);
    return hand;
}

@interface VXRGestureSession : NSObject
@property(nonatomic, strong) UIView *target;
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UITouch *touch;
@property(nonatomic) CGPoint start, end, beganWindowPoint;
@property(nonatomic) double tapTravel;
@property(nonatomic) BOOL pan, appRoute, finished, isolatedEvent, holdEnd, deferredEnd;
@property(nonatomic) CGPoint lastLocal;
@property(nonatomic) NSInteger steps, sent;
@property(nonatomic) NSTimeInterval resultDelay;
@property(nonatomic, copy) NSString *hitDescription;
@property(nonatomic, copy) NSString *eventFactory;
@property(nonatomic, copy) void (^completion)(NSString *);
- (void)step:(NSInteger)index;
- (void)dispatchPhase:(UITouchPhase)phase point:(CGPoint)local;
@end
@implementation VXRGestureSession
- (void)finish:(NSString *)detail {
    if (self.finished) {
        return;
    }
    self.finished = YES;
    busy = NO;
    NSString *result = [NSString
        stringWithFormat:@"%@ | route=%@ role=%@ key=%d interaction=%d | %@ | head-motion drift=%.1fpt | phases=%ld",
                         detail, self.appRoute ? @"UIApplication" : @"UIWindow", self.window.windowScene.session.role,
                         self.window.isKeyWindow, self.window.userInteractionEnabled,
                         [self.hitDescription
                             stringByAppendingFormat:@" eventFactory=%@", self.eventFactory ?: @"none"],
                         self.tapTravel, (long)self.sent];
    [NSUserDefaults.standardUserDefaults setObject:result forKey:@"viture.xr.input.lastAction.v1"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.resultDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       self.completion(result);
                   });
}
- (void)step:(NSInteger)index {
    if (self.finished || self.deferredEnd) {
        return;
    }
    @try {
        if (self.target.window != self.window ||
            UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            // Cancel to the original app window if the view is still there; otherwise stop.
            if (self.target.window == self.window && self.sent > 0) {
                [self dispatchPhase:UITouchPhaseCancelled point:self.end];
            }
            [self finish:@"Stopped: source moved window or app left foreground"];
            return;
        }
        float progress = (float)index / (float)self.steps;
        CGPoint local = CGPointMake(self.start.x + (self.end.x - self.start.x) * progress,
                                    self.start.y + (self.end.y - self.start.y) * progress);
        // The first step begins the touch, the last ends it, and the rest move it.
        UITouchPhase phase = UITouchPhaseMoved;
        if (index == 0) {
            phase = UITouchPhaseBegan;
        } else if (index == self.steps) {
            phase = UITouchPhaseEnded;
        }
        [self dispatchPhase:phase point:local];
        if (index == self.steps) {
            [self finish:@"Dispatch calls completed; inspect page telemetry for delivery/trust"];
        }
    } @catch (NSException *exception) {
        // A physical touch began mid-swipe. Never abandon a touch WebKit has
        // already seen: hold it still and end it once the fingers lift.
        if (self.holdEnd && self.sent > 0 && [exception.name isEqualToString:@"VXRPhysicalTouch"]) {
            self.deferredEnd = YES;
            [self endAfterPhysicalLift:0];
            return;
        }
        [self finish:[@"Input exception: " stringByAppendingString:exception.reason ?: exception.name]];
    }
}
- (void)endAfterPhysicalLift:(NSInteger)attempt {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.finished) {
            return;
        }
        if (self.target.window != self.window ||
            UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            [self finish:@"Stopped: source moved window or app left foreground during deferred end"];
            return;
        }
        @try {
            [self dispatchPhase:UITouchPhaseEnded point:self.lastLocal];
            [self finish:[NSString stringWithFormat:@"Dispatch calls completed; end deferred %.0f ms until physical "
                                                    @"lift; inspect page telemetry for delivery/trust",
                                                    attempt * 16.0]];
        } @catch (NSException *exception) {
            if ([exception.name isEqualToString:@"VXRPhysicalTouch"] && attempt < 600) {
                [self endAfterPhysicalLift:attempt + 1];
                return;
            }
            [self finish:[@"Input exception during deferred end: "
                             stringByAppendingString:exception.reason ?: exception.name]];
        }
    });
}
- (void)dispatchPhase:(UITouchPhase)phase point:(CGPoint)local {
    CGPoint point = [self.target convertPoint:local toView:self.window];
    if (!self.pan) {
        if (phase == UITouchPhaseBegan) {
            self.beganWindowPoint = point;
        } else {
            self.tapTravel = hypot(point.x - self.beganWindowPoint.x, point.y - self.beganWindowPoint.y);
            point = self.beganWindowPoint;
        }
    }
    Location(self.touch, point, phase == UITouchPhaseBegan);
    Number(self.touch, @"setPhase:", phase);
    Timestamp(self.touch, @"setTimestamp:");
    Flag(self.touch, @"_setIsFirstTouchForView:", phase == UITouchPhaseBegan);
    CFTypeRef hid = MakeHID(point, phase);
    if (!hid) {
        [NSException raise:@"VXRInput" format:@"HID metadata allocation failed"];
    }
    @try {
        Hid(self.touch, @"_setHidEvent:", hid);
        UIApplication *app = UIApplication.sharedApplication;
        UIEvent *event = nil;
        if (!self.isolatedEvent && Has(app, @"_touchesEventForWindow:")) {
            event =
                ((id (*)(id, SEL, id))objc_msgSend)(app, NSSelectorFromString(@"_touchesEventForWindow:"), self.window);
            self.eventFactory = @"UIApplication._touchesEventForWindow";
        }
        if (!self.isolatedEvent && !event && Has(app, @"_touchesEvent")) {
            event = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"_touchesEvent"));
            self.eventFactory = @"UIApplication._touchesEvent";
        }
        if (!event) {
            Class eventClass = NSClassFromString(@"UITouchesEvent");
            event = [eventClass new];
            self.eventFactory = @"fresh UITouchesEvent";
        }
        if (!event) {
            [NSException raise:@"VXRInput" format:@"No touch event object available"];
        }
        for (UITouch *existing in event.allTouches) {
            if (existing != self.touch && existing.phase != UITouchPhaseEnded &&
                existing.phase != UITouchPhaseCancelled) {
                [NSException raise:@"VXRPhysicalTouch"
                            format:@"Physical touch still active; lift fingers before trying again"];
            }
        }
        ((void (*)(id, SEL))objc_msgSend)(event, NSSelectorFromString(@"_clearTouches"));
        if (Has(event, @"_setTimestamp:")) {
            Timestamp(event, @"_setTimestamp:");
        }
        Hid(event, @"_setHIDEvent:", hid);
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, NSSelectorFromString(@"_addTouch:forDelayedDelivery:"),
                                                    self.touch, NO);
        if (![event.allTouches containsObject:self.touch]) {
            [NSException raise:@"VXRInput" format:@"Event did not retain the constructed touch"];
        }
        if (self.appRoute) {
            [UIApplication.sharedApplication sendEvent:event];
        } else {
            [self.window sendEvent:event];
        }
        self.sent += 1;
        self.lastLocal = local;
    } @finally {
        CFRelease(hid);
    }
}
@end

static void Inject(UIView *view, CGPoint start, CGPoint end, NSTimeInterval duration, BOOL pan, BOOL appRoute,
                   BOOL isolatedEvent, BOOL requireWindowHit, BOOL holdEnd, BOOL (^stillValid)(void),
                   NSTimeInterval initialDelay, NSTimeInterval resultDelay, void (^completion)(NSString *)) {
    // Run after the physical phone gesture callback has returned.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(initialDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                if (!stillValid()) {
                    completion(@"Cancelled: tap context changed");
                    return;
                }
                [NSUserDefaults.standardUserDefaults
                    setObject:[NSString stringWithFormat:@"%@ requested %@ in %@ via %@", NSDate.date,
                                                         pan ? @"pan" : @"tap", view.window.windowScene.session.role,
                                                         appRoute ? @"UIApplication" : @"UIWindow"]
                       forKey:@"viture.xr.input.lastAction.v1"];
                NSString *cap = VXRInputCapabilities();
                if ([cap hasPrefix:@"Unavailable"]) {
                    completion(cap);
                    return;
                }
                if (busy) {
                    completion(@"Busy: another synthetic gesture is active");
                    return;
                }
                UIWindow *window = view.window;
                if (![view isKindOfClass:NSClassFromString(@"WKWebView")] || !window ||
                    ![window isKindOfClass:UIWindow.class]) {
                    completion(@"Rejected: target is not this app's attached WKWebView");
                    return;
                }
                if (!isfinite(start.x) || !isfinite(start.y) || !isfinite(end.x) || !isfinite(end.y) ||
                    !CGRectContainsPoint(view.bounds, start) || !CGRectContainsPoint(view.bounds, end)) {
                    completion(@"Rejected: source coordinates outside web bounds");
                    return;
                }
                CGPoint point = [view convertPoint:start toView:window];
                if (!CGRectContainsPoint(window.bounds, point)) {
                    completion(@"Rejected: projected target is outside source window; not a window-delivery verdict");
                    return;
                }
                CGPoint back = [view convertPoint:point fromView:window];
                double roundTrip = hypot(back.x - start.x, back.y - start.y);
                if (!isfinite(roundTrip) || roundTrip > 1.0) {
                    completion(@"Rejected: coordinate round-trip mismatch; not a window-delivery verdict");
                    return;
                }
                UIView *windowHit = [window hitTest:point withEvent:nil];
                if (requireWindowHit && (!windowHit || ![windowHit isDescendantOfView:view])) {
                    completion(@"Rejected: selected screen is outside view or covered by another screen");
                    return;
                }
                UIView *hit = [view hitTest:start withEvent:nil];
                if (!hit) {
                    completion(@"Web-view hit test returned nil");
                    return;
                }
                UITouch *touch = [[UITouch alloc] initVXRProbeTouch];
                Object(touch, @"setWindow:", window);
                Object(touch, @"setView:", hit);
                Number(touch, @"setTapCount:", 1);
                Flag(touch, @"setIsTap:", !pan);
                if (Has(touch, @"setGestureView:")) {
                    Object(touch, @"setGestureView:", hit);
                }
                VXRGestureSession *session = [VXRGestureSession new];
                session.target = view;
                session.window = window;
                session.touch = touch;
                session.start = start;
                session.end = end;
                session.resultDelay = resultDelay;
                session.pan = pan;
                session.holdEnd = holdEnd && pan;
                session.appRoute = appRoute;
                session.isolatedEvent = isolatedEvent;
                session.completion = completion;
                session.steps = pan ? MAX(2, (NSInteger)(MAX(0.15, MIN(duration, 1.0)) * 60)) : 1;
                session.hitDescription = [NSString
                    stringWithFormat:@"windowHit=%@ targetHit=%@ point=(%.1f,%.1f) roundTrip=%.3f sceneListed=%d",
                                     windowHit ? NSStringFromClass(windowHit.class) : @"nil",
                                     NSStringFromClass(hit.class), point.x, point.y, roundTrip,
                                     [UIApplication.sharedApplication.connectedScenes
                                         containsObject:window.windowScene]];
                busy = YES;
                NSTimeInterval interval = pan ? MAX(0.15, MIN(duration, 1.0)) / session.steps : 0.065;
                for (NSInteger i = 0; i <= session.steps; i++) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * i * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                                       if (i == 0 && !stillValid()) {
                                           [session finish:@"Cancelled: tap context changed"];
                                           return;
                                       }
                                       if (i > 0 && pan && !stillValid() && !session.finished) {
                                           @try {
                                               if (session.sent > 0 && session.target.window == session.window) {
                                                   [session dispatchPhase:UITouchPhaseCancelled point:session.start];
                                               }
                                           } @catch (NSException *e) {
                                           }
                                           [session finish:@"Cancelled: swipe context changed"];
                                           return;
                                       }
                                       [session step:i];
                                   });
                }
            } @catch (NSException *e) {
                busy = NO;
                completion([@"Setup exception: " stringByAppendingString:e.reason ?: e.name]);
            }
        });
}

void VXRInjectGesture(UIView *view, CGPoint start, CGPoint end, NSTimeInterval duration, BOOL pan, BOOL appRoute,
                      BOOL isolatedEvent, void (^completion)(NSString *)) {
    Inject(
        view, start, end, duration, pan, appRoute, isolatedEvent, NO, NO,
        ^BOOL {
            return YES;
        },
        0.08, 0.18, completion);
}

void VXRInjectQueuedTap(UIView *view, CGPoint point, BOOL appRoute, BOOL requireWindowHit, BOOL (^stillValid)(void),
                        void (^completion)(NSString *)) {
    Inject(view, point, point, 0.065, NO, appRoute, NO, requireWindowHit, NO, stillValid, 0.02, 0.02, completion);
}

void VXRInjectQueuedSwipe(UIView *view, CGPoint start, CGPoint end, BOOL appRoute, BOOL requireWindowHit,
                          BOOL holdEndUntilLift, BOOL (^stillValid)(void), void (^completion)(NSString *)) {
    Inject(view, start, end, 0.28, YES, appRoute, NO, requireWindowHit, holdEndUntilLift, stillValid, 0.02, 0.02,
           completion);
}
