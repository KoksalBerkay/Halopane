#import "PrivateWebPortal.h"
#import <objc/message.h>

// All private UIKit calls live in this file. No private symbols are linked directly.
static void SetFlag(id object, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if ([object respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    }
}
UIView *VXRCreateWebPortal(UIView *source, NSString **detail) {
    @try {
        Class cls = NSClassFromString(@"_UIPortalView");
        if (!cls || ![cls isSubclassOfClass:[UIView class]]) {
            if (detail) {
                *detail = @"_UIPortalView unavailable on this runtime";
            }
            return nil;
        }
        UIView *portal = [(UIView *)[cls alloc] initWithFrame:source.bounds];
        SEL setSource = NSSelectorFromString(@"setSourceView:");
        if (![portal respondsToSelector:setSource]) {
            if (detail) {
                *detail = @"Portal has no source-view setter";
            }
            return nil;
        }
        SetFlag(portal, @"setMatchesPosition:", NO);
        SetFlag(portal, @"setMatchesTransform:", NO);
        SetFlag(portal, @"setMatchesAlpha:", NO);
        SetFlag(portal, @"setHidesSourceView:", NO);
        SetFlag(portal, @"setAllowsHitTesting:", NO);
        SetFlag(portal, @"setForwardsClientHitTestingToSourceView:", NO);
        ((void (*)(id, SEL, id))objc_msgSend)(portal, setSource, source);
        portal.userInteractionEnabled = NO;
        if (detail) {
            *detail = @"_UIPortalView created; visual and video replication unverified";
        }
        return portal;
    } @catch (NSException *exception) {
        if (detail) {
            *detail = [NSString stringWithFormat:@"Portal exception: %@", exception.reason];
        }
        return nil;
    }
}
