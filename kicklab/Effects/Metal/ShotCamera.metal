#include <metal_stdlib>
using namespace metal;

/// Mirrors ShotCameraFrame.uniforms (ShotCameraPlan.swift): 24 float4, see ShotCameraPixel.h.
struct ShotCameraUniforms {
    float4 v[24];
};

#define SHOT_TEXTURE texture2d<float, access::sample>
constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
#include "ShotCameraPixel.h"

kernel void fxShotCamera(texture2d<float, access::sample> source [[texture(0)]],
                         texture2d<float, access::write> output [[texture(1)]],
                         texture2d<float, access::sample> original [[texture(2)]],
                         texture2d<float, access::sample> atlas [[texture(3)]],
                         texture2d<float, access::sample> blurred [[texture(4)]],
                         constant ShotCameraUniforms &u [[buffer(0)]],
                         constant float4 *path [[buffer(1)]],
                         constant float4 *stamps [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    output.write(shotCameraPixel(source, original, atlas, blurred, u, path, stamps, float2(gid) + .5), gid);
}
