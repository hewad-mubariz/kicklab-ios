#include "ShotCPUBridge.h"
#include "ShotCPUCompatibility.h"
#include <dispatch/dispatch.h>
#include <vector>

namespace {
struct FXUniforms { float4 viewport,ball,motion,region,control,tint,environment; };
struct ShotCameraUniforms { float4 viewport,crop,lens,guide,inset,layout; };
#include "Metal/ShotShaderMath.h"
#include "Metal/ShotTrails.h"

struct CPUTexture {
    const uint8_t *bytes; int width,height,stride;
    int get_width() const { return width; }
    int get_height() const { return height; }
    float4 pixel(int x,int y) const {
        auto p=bytes+int(clamp(y,0,height-1))*stride+int(clamp(x,0,width-1))*4;
        return float4(p[2]/255.f,p[1]/255.f,p[0]/255.f,p[3]/255.f);
    }
    float4 sample(int, float2 uv) const {
        float x=uv.x*width-.5f,y=uv.y*height-.5f; int ix=floorf(x),iy=floorf(y);
        return mix(mix(pixel(ix,iy),pixel(ix+1,iy),fract(x)),mix(pixel(ix,iy+1),pixel(ix+1,iy+1),fract(x)),fract(y));
    }
};
constexpr int linear=0;
#define SHOT_TEXTURE CPUTexture
#include "Metal/ShotCameraPixel.h"
using Tile=std::vector<float4>;
static Tile blur(const Tile &in,int w,int h,float sigma) {
    int radius=int(ceilf(sigma*3)); std::vector<float> weights(radius*2+1); float sum=0;
    for(int k=-radius;k<=radius;k++) { float v=expf(-.5f*k*k/(sigma*sigma));weights[k+radius]=v;sum+=v; }
    for(auto &v:weights)v/=sum;
    Tile scratch(w*h),out(w*h); auto src=in.data();auto mid=scratch.data();auto dst=out.data();auto kernel=weights.data();
    dispatch_apply(h,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t y){
        for(int x=0;x<w;x++){float4 v=0;for(int k=-radius;k<=radius;k++)if(x+k>=0&&x+k<w)v+=src[y*w+x+k]*kernel[k+radius];mid[y*w+x]=v;}
    });
    dispatch_apply(h,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t y){
        for(int x=0;x<w;x++){float4 v=0;for(int k=-radius;k<=radius;k++)if(int(y)+k>=0&&int(y)+k<h)v+=mid[(int(y)+k)*w+x]*kernel[k+radius];dst[y*w+x]=v;}
    });return out;
}
static float4 sample(const float4 *a,int w,int h,float2 uv) {
    float x=clamp(uv.x*w-.5f,0,w-1),y=clamp(uv.y*h-.5f,0,h-1);int ix=x,iy=y,jx=min(ix+1,w-1),jy=min(iy+1,h-1);
    return mix(mix(a[iy*w+ix],a[iy*w+jx],fract(x)),mix(a[jy*w+ix],a[jy*w+jx],fract(x)),fract(y));
}
static void store(uint8_t *p,float4 c) { p[0]=lroundf(saturate(c.z)*255);p[1]=lroundf(saturate(c.y)*255);p[2]=lroundf(saturate(c.x)*255);p[3]=255; }
}

bool KLRenderShotCPU(CVPixelBufferRef pixels,const void *uniforms,const simd_float4 *trail,
                     const void *camera,const simd_float4 *path,bool effects,bool cameraActive) {
    if(CVPixelBufferGetPixelFormatType(pixels)!=kCVPixelFormatType_32BGRA || CVPixelBufferLockBaseAddress(pixels,0)!=kCVReturnSuccess)return false;
    auto bytes=(uint8_t *)CVPixelBufferGetBaseAddress(pixels);
    if(!bytes){CVPixelBufferUnlockBaseAddress(pixels,0);return false;}
    int w=(int)CVPixelBufferGetWidth(pixels),h=(int)CVPixelBufferGetHeight(pixels),stride=(int)CVPixelBufferGetBytesPerRow(pixels);
    auto u=*(const FXUniforms *)uniforms;auto cam=*(const ShotCameraUniforms *)camera;
    std::vector<uint8_t> original;
    if(cameraActive)original.assign(bytes,bytes+stride*h);
    if(effects && u.region.z>0 && u.region.w>0){
        float scale=min(1,1024/max(u.region.z,u.region.w));
        int tw=max(16,ceilf(u.region.z*scale/16)*16),th=max(16,ceilf(u.region.w*scale/16)*16);
        Tile emission(tw*th);auto sharp=emission.data();
        dispatch_apply(th,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t y){
            for(int x=0;x<tw;x++){
                float2 pixel=u.region.xy+float2((x+.5f)/tw,(y+.5f)/th)*u.region.zw;
                sharp[y*tw+x]=shotTrailFX(pixel,u,trail,u.region.z/tw)*u.ball.w*u.viewport.w;
            }
        });
        float radius=max(1,roundf(u.ball.z*scale*.065f));
        auto near=blur(emission,tw,th,radius),far=blur(emission,tw,th,radius*3.5f);auto n=near.data(),f=far.data();
        dispatch_apply(h,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t y){
            for(int x=0;x<w;x++){
                float2 pixel=float2(x+.5f,y+.5f),uv=(pixel-u.region.xy)/u.region.zw;
                if(uv.x<0||uv.x>1||uv.y<0||uv.y>1)continue;
                float4 s=sample(sharp,tw,th,uv),a=sample(n,tw,th,uv),b=sample(f,tw,th,uv);
                float face=smoothstep(.96,1.055,length(pixel-u.ball.xy)/max(1,u.ball.z));
                float3 mapped=1-exp(-(s.rgb+a.rgb*.18f+b.rgb*.045f)*.90f);
                float alpha=clamp(max(max(mapped.r,max(mapped.g,mapped.b)),s.a),0,.96)*face;
                auto p=bytes+y*stride+x*4;float3 base=float3(p[2]/255.f,p[1]/255.f,p[0]/255.f);
                store(p,float4(base*(1-alpha)+min(mapped*face,float3(alpha)),1));
            }
        });
    }
    if(cameraActive){
        std::vector<uint8_t> composited(bytes,bytes+stride*h);
        CPUTexture source{composited.data(),w,h,stride},raw{original.data(),w,h,stride};
        dispatch_apply(h,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t y){
            for(int x=0;x<w;x++)store(bytes+y*stride+x*4,shotCameraPixel(source,raw,cam,path,float2(x+.5f,y+.5f)));
        });
    }
    CVPixelBufferUnlockBaseAddress(pixels,0);return true;
}
