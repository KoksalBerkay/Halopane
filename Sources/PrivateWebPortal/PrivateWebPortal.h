#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
NS_ASSUME_NONNULL_BEGIN
UIView *_Nullable VXRCreateWebPortal(UIView *source, NSString *_Nullable *_Nullable detail);
NSString *VXREnableEncryptedMedia(WKPreferences *preferences);
NSString *VXRSetWebFeature(WKPreferences *preferences, NSString *key, BOOL enabled);
/// Lists WebKit feature switches whose keys contain any of `fragments`, with their states.
NSString *VXRWebFeatureSummary(WKPreferences *preferences, NSArray<NSString *> *fragments);
/// One mesh point: where it samples the layer and where it is drawn, both in the layer's unit square.
typedef struct {
    float fromX, fromY, toX, toY;
} VXRMeshPoint;
/// Warps a layer's drawing through a mesh. `quads` holds four point indices per face.
/// Returns nil on success, or why the mesh could not be set.
NSString *_Nullable VXRSetLayerMesh(CALayer *layer, const VXRMeshPoint *points, NSInteger pointCount,
                                    const uint32_t *quads, NSInteger quadCount);
void VXRClearLayerMesh(CALayer *layer);
NS_ASSUME_NONNULL_END
#import "PrivateTouchProbe.h"
