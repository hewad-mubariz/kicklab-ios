#include <metal_stdlib>
using namespace metal;
// Liquid Spectrum: particles splat into a density field, then the field is shaded over the video it
// refracts. Its particles now come from Water's motion stage (LiquidScene).
#include "LiquidEffect.h"
struct LiquidVertex {float4 position [[position]];};
vertex LiquidVertex liquidVertex(uint id [[vertex_id]]) {
    float2 p=id==0 ? float2(-1,-1):id==1 ? float2(3,-1):float2(-1,3);
    return {float4(p,0,1)};
}
struct LiquidSplat {
    float4 position [[position]];
    float2 local;
    float depth,hue,radius,weight;
};
vertex LiquidSplat liquidSplatVertex(uint id [[vertex_id]],uint instance [[instance_id]],
    constant LiquidUniforms &u [[buffer(0)]],device const LiquidPart *parts [[buffer(1)]]) {
    const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    LiquidPart p=parts[instance];float2 local=corners[id];
    float2 pixel=p.centerSize.xy+lqRotate(local*p.shape.xy*p.centerSize.w*2,p.shape.z);
    // Crown atoms (material.w 2) keep the same mass however their kernel is stretched, as in Water.
    float weight=p.material.w>1.5 ? 1.0/(p.shape.x*p.shape.y):1.0;
    return {float4(pixel/u.viewport.xy*float2(2,-2)+float2(-1,1),0,1),local,p.centerSize.z/max(1.0,u.ball.z),p.material.x,p.centerSize.w,weight};
}
fragment float4 liquidSplatFragment(LiquidSplat in [[stage_in]]) {
    float r2=dot(in.local,in.local);if(r2>1)discard_fragment();
    float w=(exp(-r2*4)-exp(-4.0))*1.25*in.weight;
    return float4(w,w*in.depth,w*in.hue,w*in.radius);
}
fragment float4 liquidFragment(LiquidVertex in [[stage_in]],constant LiquidUniforms &u [[buffer(0)]],
    texture2d<float> source [[texture(0)]],texture2d<float> field [[texture(1)]]) {
    float4 color=liquidEffect(in.position.xy,u,field,source);
    if(u.options.y>=0)return color;
    // Picker icons (options.y < 0): the liquid refracts a plain grey of level options.w and its own
    // coverage becomes opacity, premultiplied, so the tile shows through everywhere else.
    float d=field.sample(liquidSampler,in.position.xy/u.viewport.xy).x,aa=max(.025,fwidth(d)*.65);
    float outside=smoothstep(1.0,1.055,length(in.position.xy-u.ball.xy)/max(1.0,u.ball.z));
    float k=d<.40-aa ? 0:smoothstep(.40-aa,.40+aa,d)*outside*u.viewport.w*u.ball.w;
    return float4(max(float3(0),color.rgb-float3(u.options.w)*(1-k)),k);
}
