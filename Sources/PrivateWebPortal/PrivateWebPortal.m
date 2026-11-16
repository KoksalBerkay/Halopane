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

// Turns on WebKit's modern and legacy EME, which FairPlay sites use. Returns
// each feature's state before and after, for the diagnostics report.
NSString *VXREnableEncryptedMedia(WKPreferences *preferences) {
    @try {
        SEL list = NSSelectorFromString(@"_features");
        SEL set = NSSelectorFromString(@"_setEnabled:forFeature:");
        SEL get = NSSelectorFromString(@"_isEnabledForFeature:");
        if (![WKPreferences respondsToSelector:list] || ![preferences respondsToSelector:set] ||
            ![preferences respondsToSelector:get]) {
            return @"WebKit feature switches unavailable";
        }
        NSArray *features = ((id (*)(id, SEL))objc_msgSend)([WKPreferences class], list);
        NSSet *wanted = [NSSet setWithArray:@[ @"EncryptedMediaAPIEnabled", @"LegacyEncryptedMediaAPIEnabled" ]];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id feature in features) {
            id key = [feature valueForKey:@"key"];
            if (![key isKindOfClass:[NSString class]] || ![wanted containsObject:key]) {
                continue;
            }
            BOOL before = ((BOOL (*)(id, SEL, id))objc_msgSend)(preferences, get, feature);
            ((void (*)(id, SEL, BOOL, id))objc_msgSend)(preferences, set, YES, feature);
            BOOL after = ((BOOL (*)(id, SEL, id))objc_msgSend)(preferences, get, feature);
            [parts addObject:[NSString stringWithFormat:@"%@ %@ to %@", key, before ? @"on" : @"off",
                                                        after ? @"on" : @"off"]];
        }
        if (parts.count == 0) {
            return @"EME features not found in this WebKit";
        }
        return [parts componentsJoinedByString:@", "];
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"EME switch exception: %@", exception.reason];
    }
}
