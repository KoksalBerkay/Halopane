#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
NSString *VXRInputCapabilities(void);
void VXRInjectGesture(UIView *webView, CGPoint start, CGPoint end, NSTimeInterval duration, BOOL isPan,
                      BOOL useApplicationRoute, BOOL isolatedEvent, void (^completion)(NSString *result));
void VXRInjectQueuedTap(UIView *webView, CGPoint point, BOOL useApplicationRoute, BOOL requireWindowHit,
                        BOOL (^stillValid)(void), void (^completion)(NSString *result));
// holdEndUntilLift: if a physical touch begins mid-swipe, keep the synthetic touch
// still and send its Ended phase after the fingers lift, instead of abandoning it.
void VXRInjectQueuedSwipe(UIView *webView, CGPoint start, CGPoint end, BOOL useApplicationRoute, BOOL requireWindowHit,
                          BOOL holdEndUntilLift, BOOL (^stillValid)(void), void (^completion)(NSString *result));
NS_ASSUME_NONNULL_END
