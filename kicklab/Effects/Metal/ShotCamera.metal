#include <metal_stdlib>
using namespace metal;

struct ShotCameraUniforms {
    float4 viewport;
    float4 crop;
    float4 lens;
    float4 guide;
    float4 inset;
    float4 layout;
};

#define SHOT_TEXTURE texture2d<float, access::sample>
constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
#include "ShotCameraPixel.h"

kernel void fxShotCamera(texture2d<float, access::sample> source [[texture(0)]],
                         texture2d<float, access::write> output [[texture(1)]],
                         texture2d<float, access::sample> original [[texture(2)]],
                         constant ShotCameraUniforms &u [[buffer(0)]],
                         constant float4 *path [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    output.write(shotCameraPixel(source, original, u, path, float2(gid) + .5),gid);
}
