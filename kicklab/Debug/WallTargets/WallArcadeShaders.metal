#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;
namespace WallFire {
#include "../../Effects/Metal/FireField.h"
}
using namespace WallFire;

float arcadeHash(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453); }
float arcadeNoise(float2 p) {
    float2 i=floor(p),f=fract(p);f=f*f*(3-2*f);
    return mix(mix(arcadeHash(i),arcadeHash(i+float2(1,0)),f.x),
               mix(arcadeHash(i+float2(0,1)),arcadeHash(i+1),f.x),f.y);
}

float runeStoneDistance(float2 p,float2 halfSize) {
    float2 q=abs(p)-halfSize;
    return max(max(q.x,q.y),(q.x+q.y+0.085)*0.7071);
}
float arcadeSegment(float2 p,float2 a,float2 b) {
    float2 ab=b-a;
    return length(p-a-ab*saturate(dot(p-a,ab)/max(0.00001,dot(ab,ab))));
}

// Cut stone, an inset polished face and a thick raised rim. Local material
// shading never changes the shared target geometry or the calibration.
[[ stitchable ]] half4 wallMemoryStone(float2 position,half4 input,float2 size,half4 tint,float seed,float lit) {
    float2 uv=position/size;
    float aspect=size.x/size.y;
    float2 p=(uv-0.5)*float2(aspect,1),halfSize=float2(aspect*0.46,0.43);
    float d=runeStoneDistance(p,halfSize);
    float side=runeStoneDistance(p-float2(0.018,0.035),halfSize);
    float3 base=float3(tint.rgb);
    float glow=exp(-abs(d)*65)*(0.12+lit*0.78);
    float3 color=base*glow;
    float alpha=saturate(glow);
    if(side<0) { color=base*0.24+float3(0.025);alpha=1; }
    if(d<0) {
        float macro=arcadeNoise(p*13+seed*9),grain=arcadeNoise(p*130+seed);
        float surface=0.27+macro*0.12+grain*0.04+lit*0.48;
        color=base*surface;
        float bevel=1-smoothstep(0.018,0.055,-d);
        float2 e=float2(0.001,0);
        float2 normal=normalize(float2(runeStoneDistance(p+e,halfSize)-runeStoneDistance(p-e,halfSize),
                                      runeStoneDistance(p+e.yx,halfSize)-runeStoneDistance(p-e.yx,halfSize))+0.00001);
        float light=saturate(dot(normal,normalize(float2(-0.5,-0.8)))*0.5+0.5);
        color=mix(color,base*(0.34+light*0.8)+float3(0.14)*light,bevel);
        // A few angular fractures entering from the edges; no repeating cells.
        float crack=10;
        for(int line=0;line<4;line++) {
            float n=arcadeHash(float2(line,seed));
            float2 start=float2((n-0.5)*aspect*0.75,line&1?0.44:-0.44);
            float2 end=start+float2((arcadeHash(float2(line+9,seed))-0.5)*0.30,(line&1?-1:1)*(0.13+n*0.16));
            float2 previous=start;
            for(int part=1;part<=4;part++) {
                float2 next=mix(start,end,float(part)/4);
                next.x+=(arcadeHash(float2(line*7+part,seed+11))-0.5)*0.07;
                crack=min(crack,arcadeSegment(p,previous,next));previous=next;
            }
        }
        float fissure=1-smoothstep(0.0015,0.0045,crack);
        color*=1-fissure*0.65;
        color+=base*exp(-abs(crack-0.007)*500)*0.22;
        float rim=exp(-abs(d+0.012)*350);
        float inset=exp(-abs(d+0.066)*270);
        color+=base*(rim*(0.55+lit*1.5)+inset*0.20)+float3(0.6)*rim*(0.10+lit*0.9);
        float edgeWear=step(0.83,arcadeNoise(p*61))*bevel;
        color+=float3(0.10,0.12,0.15)*edgeWear;
        alpha=1;
    }
    return half4(half3(color),half(alpha));
}

// The same curling field and HDR temperature ramp as Juggle Dude's Fire v9.
// Wall adaptation: wider filled tongues, a slanted wake, explicit LDR resolve,
// and large embers. The fire is decorative; only the rock is a scoring target.
inline half4 wallMeteorFlame(float2 position,float2 size,float seed,float time) {
    float2 uv=position/size;
    // Sprite dimensions are 2.4 by 3.6 rock diameters. The root surrounds the
    // rock, rather than ending in a straight line at its upper edge.
    float2 q=(uv-float2(0.5,0.78))*float2(4.8,7.2);
    float t=time+seed*0.71,r=length(q);
    float2 back=normalize(float2(-0.24,-1)),side=float2(-back.y,back.x);
    float along=dot(q,back),across=dot(q,side);
    if(abs(across)>1.95 || along < -1.5 || along > 5.3)return half4(0);
    float tail=4.5+0.22*sin(t*2.3),girth=1.5;
    float halfWidth=along<0?sqrt(max(0.0,girth*girth-along*along)):
        girth*pow(saturate(1-along/tail),0.72);
    float shell=saturate((halfWidth-abs(across))/0.6)*saturate((girth+along)/0.42);
    float heat=exp(-max(0.0,r-0.8)/1.15);
    float2 w=q*1.55;
    float3 P=float3(w.x,w.y*0.6+t*2.4,t*0.6);
    float2 warp=float2(fireFBM3(P*float3(0.55,0.55,1)+float3(5.2,1.3,0)),
                       fireFBM3(P*float3(0.55,0.55,1)+float3(-3.1,7.7,11)))-0.5;
    float n=fireTongueField(w,q,1,0.65,back,t,warp);
    n=saturate(0.5+(n-0.5)*2.4);
    float F=shell*1.18-n*mix(0.88,1.38,1-heat)-0.08;
    float aa=max(0.015,4.8/size.x);
    float inside=smoothstep(-aa,aa,F);
    float fold=fireSmooth3(float3(w.x*2.2+warp.x*2.4,w.y*0.8+t*3.2+warp.y*1.8,t*0.9));
    float bands=0.5+0.5*sin(fold*18);
    float depth=saturate(F/0.6);
    float temp=saturate(0.10+depth*0.40+heat*0.22+(bands-0.5)*0.13);
    float3 hdr=fireRamp(temp)*inside*(0.60+depth*0.4)*(0.8+bands*0.2);
    // Broad warm halo supports the hard flame silhouette on a lit wall.
    float aura=exp(-abs(across)*abs(across)/1.8)*exp(-max(0.0,along)*0.48)
        *smoothstep(-1.5,-0.6,along)*(1-smoothstep(4.6,5.2,along));
    hdr+=float3(1.4,0.32,0.015)*aura*0.42;
    // Discrete hot fragments, not subpixel noise, climb through the wake.
    float sparks=0;
    for(int i=0;i<10;i++) {
        float birth=fract(t*(0.38+float(i%3)*0.05)+float(i)*0.137);
        float x=(fireValue3(int3(i,int(seed),9))-0.5)*(0.5+birth*2.5);
        float y=0.5+birth*4.4;
        float2 delta=float2(across-x,along-y);
        float width=0.035+float(i%3)*0.012;
        sparks+=exp(-dot(delta*float2(1,0.40),delta*float2(1,0.40))/(width*width))*(1-birth);
    }
    hdr+=fireRamp(0.86)*sparks*1.1;
    float alpha=saturate(inside*(0.72+depth*0.28)+aura*0.22+sparks);
    float3 resolved=1-exp(-hdr*0.75);
    // Premultiplied, finite SDR colour. Background blacks stay transparent.
    return half4(half3(resolved*alpha),half(alpha));
}

// Broad raised lava plates, shaded as a rotating 3D surface. Dark fissures in
// the earlier version disappeared on the wall; these are incandescent seams
// with readable amber rock between them, using the app's Fire colour ramp.
inline half4 wallArcadeMeteor(float2 position,float2 size,float seed,float time) {
    float2 p=(position/size-0.5)*2;
    float r=length(p),angle=atan2(p.y,p.x);
    if(r>1)return half4(0);
    float boundary=0.94+0.018*sin(angle*7+seed)+0.018*sin(angle*11-seed*2);
    float edge=r-boundary,alpha=1-smoothstep(-0.012,0.012,edge);
    float z=sqrt(max(0.001,1-dot(p,p)));
    float3 normal=normalize(float3(p.x,-p.y,z));
    float a=time*0.16+seed,cs=cos(a),sn=sin(a);
    float3 q=float3(normal.x*cs+normal.z*sn,normal.y,-normal.x*sn+normal.z*cs);
    q=normalize(q+(float3(fireNoise3(q*11+seed),fireNoise3(q*11+seed+7),fireNoise3(q*11+seed+19))-0.5)*0.065);
    float best=-2,second=-2,plate=0;float3 plateNormal=normal;
    // Fibonacci sites give a few broad broken plates on the visible hemisphere.
    for(int i=0;i<18;i++) {
        float y=1-(float(i)+0.5)/9,rad=sqrt(1-y*y),phi=float(i)*2.399963;
        float3 site=float3(cos(phi)*rad,y,sin(phi)*rad);
        float d=dot(q,site);
        if(d>best) { second=best;best=d;plate=float(i);plateNormal=site; }
        else second=max(second,d);
    }
    float gap=best-second;
    float fine=fireNoise3(q*45+seed),coarse=fireNoise3(q*13+seed);
    float molten=1-smoothstep(0.012,0.048,gap+(fine-0.5)*0.014);
    float bevel=1-smoothstep(0.03,0.11,gap);
    float3 facet=float3(plateNormal.x*cs-plateNormal.z*sn,plateNormal.y,plateNormal.x*sn+plateNormal.z*cs);
    float3 n=normalize(mix(normal,facet,0.48)+(coarse-0.5)*0.16);
    float light=0.23+0.77*max(0.0,dot(n,normalize(float3(-0.55,0.65,0.9))));
    float tone=0.55+fireValue3(int3(int(plate),int(seed),2))*0.45;
    float3 rock=mix(float3(0.34,0.075,0.018),float3(0.93,0.38,0.09),tone)*light*(0.80+fine*0.30);
    rock+=float3(0.30,0.085,0.012)*bevel*light;
    float3 hot=fireRamp(0.72+0.18*coarse)*molten;
    hot+=fireRamp(0.4)*exp(-gap*17)*0.35;
    float rim=exp(-abs(edge)*70);
    hot+=fireRamp(0.82)*rim*0.65;
    float3 color=1-exp(-(rock*1.5+hot)*0.85);
    return half4(half3(color*alpha),half(alpha));
}

struct WallMeteorVertex { float4 position [[position]]; float2 uv; };
vertex WallMeteorVertex wallMeteorVertex(uint id [[vertex_id]]) {
    float2 p=float2((id<<1)&2,id&2);
    return {float4(p*2-1,0,1),float2(p.x,1-p.y)};
}
fragment half4 wallMeteorFragment(WallMeteorVertex v [[stage_in]],constant float4 &u [[buffer(0)]]) {
    float2 size=u.xy,position=v.uv*size;
    half4 fire=wallMeteorFlame(position,size,u.z,u.w);
    float2 rockSize=size/float2(2.4,3.6);
    float2 local=position-size*float2(0.5,0.78)+rockSize*0.5;
    half4 rock=half4(0);
    if(all(local>=0)&&all(local<=rockSize)) {
        rock=wallArcadeMeteor(local,rockSize,u.z,u.w);
    }
    return rock+fire*(1-rock.a);
}
