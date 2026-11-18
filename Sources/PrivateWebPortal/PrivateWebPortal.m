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

// Sets one WebKit feature switch by its key. Returns its state before and
// after, for the diagnostics report.
NSString *VXRSetWebFeature(WKPreferences *preferences, NSString *key, BOOL enabled) {
    @try {
        SEL list = NSSelectorFromString(@"_features");
        SEL set = NSSelectorFromString(@"_setEnabled:forFeature:");
        SEL get = NSSelectorFromString(@"_isEnabledForFeature:");
        if (![WKPreferences respondsToSelector:list] || ![preferences respondsToSelector:set] ||
            ![preferences respondsToSelector:get]) {
            return [key stringByAppendingString:@" switch unavailable"];
        }
        NSArray *features = ((id (*)(id, SEL))objc_msgSend)([WKPreferences class], list);
        for (id feature in features) {
            id name = [feature valueForKey:@"key"];
            if (![name isKindOfClass:[NSString class]] || ![name isEqualToString:key]) {
                continue;
            }
            BOOL before = ((BOOL (*)(id, SEL, id))objc_msgSend)(preferences, get, feature);
            ((void (*)(id, SEL, BOOL, id))objc_msgSend)(preferences, set, enabled, feature);
            BOOL after = ((BOOL (*)(id, SEL, id))objc_msgSend)(preferences, get, feature);
            return [NSString stringWithFormat:@"%@ %@ to %@", key, before ? @"on" : @"off", after ? @"on" : @"off"];
        }
        return [key stringByAppendingString:@" not found in this WebKit"];
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@ switch exception: %@", key, exception.reason];
    }
}

// Turns on WebKit's modern and legacy EME, which FairPlay sites use.
NSString *VXREnableEncryptedMedia(WKPreferences *preferences) {
    NSString *modern = VXRSetWebFeature(preferences, @"EncryptedMediaAPIEnabled", YES);
    NSString *legacy = VXRSetWebFeature(preferences, @"LegacyEncryptedMediaAPIEnabled", YES);
    return [NSString stringWithFormat:@"%@, %@", modern, legacy];
}

// Core Animation's private mesh transform. The layouts below match QuartzCore's
// CAMeshVertex and CAMeshFace; a Mac check confirmed them.
typedef struct {
    CGFloat x, y, z;
} VXRPoint3D;
typedef struct {
    CGPoint from;
    VXRPoint3D to;
} VXRMeshVertex;
typedef struct {
    unsigned int indices[4];
    float w[4];
} VXRMeshFace;

NSString *VXRSetLayerMesh(CALayer *layer, const VXRMeshPoint *points, NSInteger pointCount, const uint32_t *quads,
                          NSInteger quadCount) {
    @try {
        Class cls = NSClassFromString(@"CAMeshTransform");
        SEL make = NSSelectorFromString(@"meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:");
        SEL set = NSSelectorFromString(@"setMeshTransform:");
        if (!cls || ![cls respondsToSelector:make] || ![layer respondsToSelector:set]) {
            return @"CAMeshTransform unavailable on this runtime";
        }
        if (pointCount <= 0 || quadCount <= 0) {
            return @"Empty mesh";
        }
        NSMutableData *vertexData = [NSMutableData dataWithLength:sizeof(VXRMeshVertex) * (NSUInteger)pointCount];
        NSMutableData *faceData = [NSMutableData dataWithLength:sizeof(VXRMeshFace) * (NSUInteger)quadCount];
        VXRMeshVertex *vertices = vertexData.mutableBytes;
        VXRMeshFace *faces = faceData.mutableBytes;
        for (NSInteger index = 0; index < pointCount; index++) {
            VXRMeshPoint point = points[index];
            vertices[index].from = CGPointMake(point.fromX, point.fromY);
            vertices[index].to = (VXRPoint3D){point.toX, point.toY, 0};
        }
        for (NSInteger index = 0; index < quadCount; index++) {
            for (int corner = 0; corner < 4; corner++) {
                uint32_t vertex = quads[index * 4 + corner];
                if (vertex >= (uint32_t)pointCount) {
                    return @"Mesh face points outside the mesh";
                }
                faces[index].indices[corner] = vertex;
                faces[index].w[corner] = 0;
            }
        }
        id mesh = ((id (*)(id, SEL, NSUInteger, VXRMeshVertex *, NSUInteger, VXRMeshFace *, NSString *))objc_msgSend)(
            cls, make, (NSUInteger)pointCount, vertices, (NSUInteger)quadCount, faces, @"none");
        if (!mesh) {
            return @"CAMeshTransform refused the mesh";
        }
        ((void (*)(id, SEL, id))objc_msgSend)(layer, set, mesh);
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"Mesh exception: %@", exception.reason];
    }
}

void VXRClearLayerMesh(CALayer *layer) {
    SEL set = NSSelectorFromString(@"setMeshTransform:");
    if ([layer respondsToSelector:set]) {
        ((void (*)(id, SEL, id))objc_msgSend)(layer, set, nil);
    }
}
