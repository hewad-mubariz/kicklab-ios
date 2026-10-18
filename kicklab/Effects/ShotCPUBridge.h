#ifndef JUGGLE_DUDE_SHOT_CPU_BRIDGE_H
#define JUGGLE_DUDE_SHOT_CPU_BRIDGE_H
#include <CoreVideo/CoreVideo.h>
#include <simd/simd.h>
#ifdef __cplusplus
extern "C" {
#endif
bool KLRenderShotCPU(CVPixelBufferRef _Nonnull pixels, const void * _Nonnull uniforms,
                     const simd_float4 * _Nonnull trail, const void * _Nonnull camera,
                     const simd_float4 * _Nonnull path, const simd_float4 * _Nonnull stamps,
                     const uint8_t * _Nullable atlasBytes, int atlasWidth, int atlasHeight,
                     bool effects, bool cameraActive);
#ifdef __cplusplus
}
#endif

#endif // JUGGLE_DUDE_SHOT_CPU_BRIDGE_H
