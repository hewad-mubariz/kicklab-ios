#include <metal_stdlib>
// Water, accepted in the Effects Lab on 1 November 2026: the lab's own passes, copied unchanged.
using namespace metal;
#include "WaterEffect.h"
struct WaterVertex {float4 position [[position]];};
vertex WaterVertex waterVertex(uint id [[vertex_id]]) {
    float2 p=id==0 ? float2(-1,-1):id==1 ? float2(3,-1):float2(-1,3);
    return {float4(p,0,1)};
}
struct WaterSplat {
    float4 position [[position]];
    float2 local;
    float depth,hue,radius,spray;
};
vertex WaterSplat waterSplatVertex(uint id [[vertex_id]],uint instance [[instance_id]],
    constant WaterUniforms &u [[buffer(0)]],device const WaterPart *parts [[buffer(1)]]) {
    const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    WaterPart p=parts[instance];float2 local=corners[id];
    float2 pixel=p.centerSize.xy+wtRotate(local*p.shape.xy*p.centerSize.w*2,p.shape.z);
    return {float4(pixel/u.viewport.xy*float2(2,-2)+float2(-1,1),0,1),local,p.centerSize.z/max(1.0,u.ball.z),p.material.w>1.5 ? 1.0/(p.shape.x*p.shape.y):p.material.x,p.centerSize.w,p.material.w};
}
fragment float4 waterSplatFragment(WaterSplat in [[stage_in]]) {
    float r2=dot(in.local,in.local);if(r2>1 || (in.spray>.5 && in.spray<1.5))discard_fragment();
    float w=(exp(-r2*4)-exp(-4.0))*1.25*(in.spray>1.5 ? in.hue:1.0);
    return float4(w,w*in.depth,w*in.hue,w*in.radius);
}
fragment float4 waterFragment(WaterVertex in [[stage_in]],constant WaterUniforms &u [[buffer(0)]],
    texture2d<float> source [[texture(0)]],texture2d<float> field [[texture(1)]],texture2d<float> front [[texture(2)]]) {
    return waterVolumeEffect(in.position.xy,u,field,front,source);
}

// Separable reconstruction keeps fluid continuous while softening voxel-sized ridges.
kernel void waterSmooth(texture2d<float,access::read> src [[texture(0)]],
                        texture2d<float,access::write> dst [[texture(1)]],
                        constant float4 &data [[buffer(0)]],constant uint2 &origin [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint2 p=gid+origin;
    if(p.x>=dst.get_width() || p.y>=dst.get_height()) return;
    float4 value=0;float total=0;float sigma=data.y;
    int radius=min(8,int(ceil(sigma*2.5)));
    for(int i=-radius;i<=radius;i++) {
        int2 q=clamp(int2(p)+(data.x<.5?int2(i,0):int2(0,i)),int2(0),int2(src.get_width()-1,src.get_height()-1));
        float weight=exp(-float(i*i)/(2*sigma*sigma));
        value+=src.read(uint2(q))*weight;total+=weight;
    }
    dst.write(value/total,p);
}

// Resolve the very fine spray separately: smoothing the main sheet would erase
// subpixel drops. These are simulated/ballistic particles, never image sprites.
vertex WaterSplat waterDropVertex(uint id [[vertex_id]],uint instance [[instance_id]],
    constant WaterUniforms &u [[buffer(0)]],device const WaterPart *parts [[buffer(1)]]) {
    const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    WaterPart p=parts[instance];float2 local=corners[id];
    float2 pixel=p.centerSize.xy+wtRotate(local*p.shape.xy*p.centerSize.w,p.shape.z);
    return {float4(pixel/u.viewport.xy*float2(2,-2)+float2(-1,1),0,1),local,p.centerSize.z/max(1.0,u.ball.z),p.material.x,p.centerSize.w,p.material.w};
}
fragment float4 waterDropFragment(WaterSplat in [[stage_in]],constant WaterUniforms &u [[buffer(0)]],
    texture2d<float> source [[texture(0)]]) {
    float r2=dot(in.local,in.local);
    if((in.spray<.5 || in.spray>1.5) || r2>=1 || u.viewport.w<=0 || u.ball.w<=0) discard_fragment();
    float outside=u.options.x<.5 ? 1:smoothstep(1.0,1.055,length(in.position.xy-u.ball.xy)/max(1.0,u.ball.z));
    float3 n=normalize(float3(in.local,sqrt(max(.001,1-r2))));
    float coverage=1-smoothstep(.78,1.0,r2);
    WaterHit hit={n,0,.08+.18*n.z,coverage,in.hue,pow(1-n.z,1.2),in.radius,0,-n.xy*in.radius*1.3};
    return float4(wtClearWater(hit,in.position.xy,u,source),coverage*outside*u.viewport.w*u.ball.w);
}

struct WaterSurfaceVertex {float4 positionThickness,normal,material;};
struct WaterSurfaceVarying {
    float4 position [[position]];float3 normal;float thickness,coverage,kind;float3 world;float2 uv;
};
vertex WaterSurfaceVarying waterSurfaceVertex(uint id [[vertex_id]],
    constant WaterUniforms &u [[buffer(0)]],device const WaterSurfaceVertex *vertices [[buffer(1)]]) {
    WaterSurfaceVertex v=vertices[id];float3 p=v.positionThickness.xyz;
    return {float4(p.xy/u.viewport.xy*float2(2,-2)+float2(-1,1),clamp(.5-p.z/(max(1.0,u.ball.z)*24),.01,.99),1),v.normal.xyz,v.positionThickness.w,v.material.x,v.material.y,p,float2(v.normal.w,v.material.w)};
}
float wtRippleNoise(float2 p) {
    float2 i=floor(p),f=fract(p);f=f*f*(3-2*f);
    float4 k=float4(dot(i,float2(127.1,311.7)),dot(i+float2(1,0),float2(127.1,311.7)),dot(i+float2(0,1),float2(127.1,311.7)),dot(i+1,float2(127.1,311.7)));
    float4 h=fract(sin(k)*43758.5453);
    return mix(mix(h.x,h.y,f.x),mix(h.z,h.w,f.x),f.y);
}
float wtRippleHeight(float2 uv) {
    return .055*wtRippleNoise(uv*float2(39,19))+.022*wtRippleNoise(uv*float2(87,43)+17.3);
}
fragment float4 waterSurfaceFragment(WaterSurfaceVarying in [[stage_in]],constant WaterUniforms &u [[buffer(0)]],
    texture2d<float> source [[texture(0)]]) {
    float outside=u.options.x<.5 ? 1:smoothstep(1.0,1.055,length(in.position.xy-u.ball.xy)/max(1.0,u.ball.z));
    if(outside<=0 || in.coverage<.001 || u.viewport.w<=0 || u.ball.w<=0)discard_fragment();
    float3 n=normalize(in.normal);if(n.z<0)n=-n;
    // Capillary-scale ripples travel with the film's material coordinates.
    // They change the optical normal, not the silhouette or source image.
    if(in.kind<.5) {
        float h=.001;
        float du=(wtRippleHeight(in.uv+float2(h,0))-wtRippleHeight(in.uv-float2(h,0)))/(2*h*5.5);
        float dv=(wtRippleHeight(in.uv+float2(0,h))-wtRippleHeight(in.uv-float2(0,h)))/(2*h*1.5);
        float3 tangent=normalize(cross(n,abs(n.y)<.9 ? float3(0,1,0):float3(1,0,0)));
        float3 bitangent=cross(n,tangent);
        n=normalize(n+tangent*du+bitangent*dv);
    }
    float grazing=pow(1-saturate(n.z),3);
    float path=in.thickness/max(.14,n.z);
    float3 transmitted=wtBackdrop(in.position.xy-n.xy*u.ball.z*(.05+path*.9),u,source);
    transmitted*=exp(-float3(2.8,.48,.13)*path*3.0);
    float fresnel=.0204+.9796*pow(1-saturate(n.z),5);
    float3 reflection=wtEnvironment(reflect(float3(0,0,-1),n))*float3(.82,.96,1.02);
    float3 color=mix(transmitted,reflection,saturate(.16+fresnel*.84+grazing*.22));
    float sun=pow(saturate(dot(n,normalize(float3(-.56,-.64,1.0)))),120);
    float ribbon=pow(saturate(dot(n,normalize(float3(.72,.11,.58)))),80);
    color+=float3(1,.99,.96)*(sun*2.7+ribbon*.65);
    color+=float3(.75,.93,1)*grazing*.16;
    return float4(saturate(color),saturate(in.coverage*outside*u.viewport.w*u.ball.w));
}

// Visible sphere front is selected by MAX blending; depth is never averaged
// across front and back layers. This is the screen-space fluid pipeline
// described by Simon Green (GDC 2010), with separable bilateral filtering.
struct WaterFront {
    float4 position [[position]];float2 local;float depth,radius,kind;float4 q0,q1;
};
vertex WaterFront waterFrontVertex(uint id [[vertex_id]],uint instance [[instance_id]],
    constant WaterUniforms &u [[buffer(0)]],device const WaterPart *parts [[buffer(1)]]) {
    const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    WaterPart p=parts[instance];float2 local=corners[id]*sqrt(p.quadric1.zw);
    float radius=p.centerSize.w*1.85;
    float2 pixel=p.centerSize.xy+local*radius;
    return {float4(pixel/u.viewport.xy*float2(2,-2)+float2(-1,1),0,1),local,p.centerSize.z,radius,p.material.w,p.quadric0,p.quadric1};
}
fragment float4 waterFrontFragment(WaterFront in [[stage_in]]) {
    if(in.kind<1.5)discard_fragment();
    float2 p=in.local;
    float a=in.q1.y,b=in.q0.z*p.x+in.q1.x*p.y;
    float c=in.q0.x*p.x*p.x+2*in.q0.y*p.x*p.y+in.q0.w*p.y*p.y-1;
    float discriminant=b*b-a*c;
    if(discriminant<=0)discard_fragment();
    float z=(-b+sqrt(discriminant))/a;
    return float4(in.depth+z*in.radius,1,in.radius,1);
}
kernel void waterBilateral(texture2d<float,access::read> src [[texture(0)]],
                           texture2d<float,access::write> dst [[texture(1)]],
                           constant float4 &data [[buffer(0)]],constant uint2 &origin [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint2 p=gid+origin;
    if(p.x>=dst.get_width() || p.y>=dst.get_height())return;
    float4 center=src.read(p);
    if(center.w<.5) {dst.write(center,p);return;}
    float sum=0,total=0;
    int radius=min(12,int(ceil(data.y*2.5)));
    for(int i=-radius;i<=radius;i++) {
        int2 q=clamp(int2(p)+(data.x<.5 ? int2(i,0):int2(0,i)),int2(0),int2(src.get_width()-1,src.get_height()-1));
        float4 v=src.read(uint2(q));if(v.w<.5)continue;
        float d=(v.x-center.x)/data.z;
        float weight=exp(-float(i*i)/(2*data.y*data.y)-d*d*.5);
        sum+=v.x*weight;total+=weight;
    }
    center.x=sum/max(.0001,total);dst.write(center,p);
}
