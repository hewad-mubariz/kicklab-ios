#include <metal_stdlib>
using namespace metal;

// Stationary world-space geometry. The MTKView submits only on layout/theme
// changes; there is no background animation or per-frame ray-marching loop.
struct ArcadeSceneVertex { float4 position [[position]]; float2 uv; };
vertex ArcadeSceneVertex wallArcadeSceneVertex(uint id [[vertex_id]]) {
    float2 p=float2((id<<1)&2,id&2);
    return {float4(p*2-1,0,1),float2(p.x,1-p.y)};
}
float sceneHash(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453); }
float sceneNoise(float2 p) {
    float2 i=floor(p),f=fract(p); f=f*f*(3-2*f);
    return mix(mix(sceneHash(i),sceneHash(i+float2(1,0)),f.x),
               mix(sceneHash(i+float2(0,1)),sceneHash(i+1),f.x),f.y);
}
float sceneCloud(float2 p) {
    return sceneNoise(p)*0.55+sceneNoise(p*2.1+7)*0.28+sceneNoise(p*4.3+19)*0.17;
}
float sceneBox(float3 eye,float3 ray,float3 center,float3 halfSize,thread float3 &normal) {
    float3 safe=select(ray,float3(0.00001),abs(ray)<0.00001);
    float3 a=(center-halfSize-eye)/safe,b=(center+halfSize-eye)/safe,lo=min(a,b),hi=max(a,b);
    float near=max(lo.x,max(lo.y,lo.z)),far=min(hi.x,min(hi.y,hi.z));
    if(near<0.001||near>far)return 1e5;
    normal=lo.x>lo.y&&lo.x>lo.z?float3(-sign(ray.x),0,0):
        lo.y>lo.z?float3(0,-sign(ray.y),0):float3(0,0,-sign(ray.z));
    return near;
}
float sceneSphere(float3 eye,float3 ray,float3 center,float radius) {
    float3 o=eye-center; float b=dot(o,ray),d=b*b-dot(o,o)+radius*radius;
    return d>0?max(0.0,-b-sqrt(d)):1e5;
}
float3 arcadeSky(float2 uv,float aspect) {
    float cloud=sceneCloud(uv*float2(4,7)+float2(2,9));
    float nebula=pow(saturate(1-abs(uv.y-0.38+sin(uv.x*6)*0.09)*2),3);
    float3 color=mix(float3(0.004,0.010,0.027),float3(0.018,0.055,0.105),uv.y);
    color+=float3(0.010,0.034,0.060)*cloud*nebula;
    // Small blue stars have neither the size nor the white circular silhouette
    // of the four tracking markers.
    for(int layer=0;layer<2;layer++) {
        float2 grid=uv*float2(aspect,1)*(layer==0?90:47),cell=floor(grid),f=fract(grid);
        float seed=sceneHash(cell+layer*41),radius=layer==0?0.055:0.07;
        float star=(1-smoothstep(radius*0.25,radius,length(f-float2(sceneHash(cell+4),sceneHash(cell+8)))));
        color+=float3(0.22,0.44,0.68)*star*step(layer==0?0.95:0.975,seed);
    }
    float2 p=(uv-float2(0.84,0.28))*float2(aspect,1)/0.105;
    float r=length(p);
    color+=float3(0.01,0.06,0.12)*exp(-abs(r-1)*12);
    if(r<1) {
        float z=sqrt(1-r*r),terrain=sceneCloud(p*5+2);
        float light=max(0.0,dot(float3(p.x,-p.y,z),normalize(float3(-0.8,0.4,0.6))));
        color=float3(0.012,0.06,0.13)*(0.20+terrain*0.8)*(0.3+light*1.8)
            +float3(0.015,0.20,0.38)*pow(r,16)*light;
    }
    return color;
}

float3 cityMaterial(float3 p,float3 n,float3 center,float3 halfSize,float seed) {
    float side=abs(n.x)>0.5?p.z-center.z:p.x-center.x;
    float across=side+(abs(n.x)>0.5?halfSize.z:halfSize.x);
    float light=0.25+0.75*max(0.0,dot(n,normalize(float3(-0.6,0.8,0.6))));
    float3 stone=float3(0.045,0.13,0.20)*light;
    if(n.y>0.5) {
        float seam=step(0.92,fract(p.x*1.6))+step(0.94,fract(p.z*1.8));
        return float3(0.08,0.23,0.32)*(1-seam*0.22);
    }
    float2 grid=float2(across*2.3,p.y*2.1),cell=floor(grid),f=fract(grid);
    float window=step(0.20,f.x)*step(f.x,0.70)*step(0.20,f.y)*step(f.y,0.66);
    float lit=step(0.33,sceneHash(cell+seed*71));
    float3 lamps=mix(float3(0.06,0.48,0.72),float3(1,0.60,0.22),step(0.88,sceneHash(cell+seed)));
    stone+=lamps*window*lit*(0.45+seed*0.45);
    float edge=min(across,2*(abs(n.x)>0.5?halfSize.z:halfSize.x)-across);
    float rim=1-smoothstep(0.025,0.095,abs(edge));
    float crown=1-smoothstep(0.03,0.15,abs(p.y-center.y-halfSize.y));
    stone+=float3(0.08,0.60,0.85)*(rim*0.65+crown*0.8);
    float floorLine=1-smoothstep(0.02,0.06,abs(fract(p.y*0.7)-0.5));
    return stone+float3(0.015,0.08,0.12)*floorLine;
}

float3 arcadeCity(float2 uv,float aspect) {
    float3 color=arcadeSky(uv,aspect);
    float3 eye=float3(0,9,12),ray=normalize(float3((uv.x-0.5)*aspect*1.4,(0.56-uv.y)*1.4,-1));
    float nearest=1e5;
    // Three staggered rows. Actual ray/box intersections expose roofs and side
    // faces and handle occlusion, rather than drawing flat window rectangles.
    for(int row=0;row<3;row++)for(int i=0;i<17;i++) {
        float seed=sceneHash(float2(i*3,row+8));
        float x=(float(i)-8)*4.6+(row&1?2.1:0);
        float height=2.6+seed*5.0+(row==2?1.8:0);
        float3 center=float3(x,height*0.5,-9-row*9),halfSize=float3(1.15+seed*0.6,height*0.5,1.4);
        float3 n;float t=sceneBox(eye,ray,center,halfSize,n);
        if(t<nearest) {
            nearest=t;
            color=cityMaterial(eye+ray*t,n,center,halfSize,seed);
            color=mix(color,float3(0.02,0.08,0.14),float(row)*0.13);
        }
    }
    // Distinct stepped landmark towers and their cyan antennae.
    for(int tower=0;tower<5;tower++)for(int tier=0;tier<4;tier++) {
        float x=(tower-2)*11.5+2,base=tower==2?8.0:5.5;
        float bottom=tier==0?0:base+(tier-1)*1.7;
        float height=tier==0?base:tier==3?3.6:1.7;
        float width=tier==3?0.055:1.35-float(tier)*0.36;
        float3 center=float3(x,bottom+height/2,-15),halfSize=float3(width,height/2,width);
        float3 n;float t=sceneBox(eye,ray,center,halfSize,n);
        if(t<nearest) {
            nearest=t;
            color=tier==3?float3(0.12,0.8,1):cityMaterial(eye+ray*t,n,center,halfSize,0.67);
        }
    }
    // Glass energy domes at the waterfront.
    for(int i=0;i<5;i++) {
        float3 center=float3((i-2)*11,0,-5);
        float t=sceneSphere(eye,ray,center,2.5);
        if(t>0&&t<nearest) {
            float3 p=eye+ray*t,n=normalize(p-center);
            if(p.y>0) {
                nearest=t;
                float ribs=pow(abs(sin(atan2(n.x,n.z)*10)),42);
                float rings=pow(abs(sin(asin(n.y)*14)),38);
                color=float3(0.018,0.16,0.25)+float3(0.02,0.65,0.95)*(ribs+rings)*0.7;
                color+=float3(0.12,0.7,1)*pow(1-abs(dot(-ray,n)),4);
            }
        }
    }
    if(ray.y<0) {
        float t=-eye.y/ray.y;
        if(t<nearest) {
            float3 p=eye+ray*t;
            float bank=1-smoothstep(0.0,0.7,abs(p.z+4));
            float water=p.z>-4?1:0;
            float ripple=sceneNoise(float2(p.x*3,p.z*25));
            float streak=pow(sceneNoise(float2(p.x*1.7,3)),4)*(0.4+ripple);
            float reflection=exp(-abs(p.z+4)*0.14)*water;
            float3 ground=float3(0.008,0.024,0.04)+float3(0.015,0.38,0.52)*streak*reflection
                +float3(0.06,0.65,0.87)*bank;
            color=mix(color,ground,exp(-max(0.0,t-60)*0.02));
        }
    }
    return color;
}

float3 arcadeRuins(float2 uv,float aspect) {
    float3 color=arcadeSky(uv,aspect)*0.55;
    float3 eye=float3(0,3.6,12),ray=normalize(float3((uv.x-0.5)*aspect*1.25,(0.44-uv.y)*1.25,-1));
    float nearest=1e5;
    // Broken columns at each side of the four rune stones. Stone blocks have
    // real thickness, joint shadows and warm torch lighting in world space.
    for(int side=0;side<2;side++)for(int row=0;row<8;row++)for(int col=0;col<2;col++) {
        float seed=sceneHash(float2(side*13+row,col+9));
        if(row==7&&col==(side==0?0:1))continue;
        float3 center=float3((side==0?-1:1)*(aspect*7.25+col*1.45),row*0.83+0.42,-1.5+col*0.4);
        center.x+=(seed-0.5)*0.12;
        float3 halfSize=float3(0.69,0.39,0.75),n;
        float t=sceneBox(eye,ray,center,halfSize,n);
        if(t<nearest) {
            nearest=t;float3 p=eye+ray*t;
            float grain=sceneCloud(float2(p.x+p.z,p.y)*8);
            float light=0.35+max(0.0,dot(n,normalize(float3(-0.4,0.8,0.5))));
            float3 local=abs(p-center)/halfSize;
            float edge=pow(min(1.0,max(min(local.x,local.y),min(local.y,local.z))),14);
            color=float3(0.12,0.16,0.20)*light*(0.55+grain*0.7)+float3(0.08,0.11,0.13)*edge;
            float torch=exp(-length(p-float3((side==0?-1:1)*aspect*7.2,1.7,0))*0.7);
            color+=float3(0.60,0.22,0.045)*torch;
            float moss=smoothstep(0.62,0.78,sceneCloud(p.xy*3+p.z))*smoothstep(0.6,0.9,grain);
            color=mix(color,float3(0.03,0.11,0.055),moss*0.65);
        }
    }
    if(ray.y<0) {
        float t=-eye.y/ray.y;
        if(t<nearest) {
            float3 p=eye+ray*t;
            float2 tile=float2(p.x+floor(p.z/1.2)*0.7,p.z)/float2(1.5,1.2);
            float2 seam=min(fract(tile),1-fract(tile));
            float joint=1-smoothstep(0.015,0.045,min(seam.x,seam.y));
            color=float3(0.045,0.07,0.10)*(0.65+sceneNoise(p.xz*6)*0.45)*(1-joint*0.65);
            color+=float3(0.01,0.07,0.10)*exp(-abs(p.x)*0.4);
        }
    }
    return color;
}

fragment half4 wallArcadeSceneFragment(ArcadeSceneVertex in [[stage_in]],constant float4 &u [[buffer(0)]]) {
    float aspect=u.x/max(1.0,u.y);
    float3 color=u.z>0.5?arcadeCity(in.uv,aspect):arcadeRuins(in.uv,aspect);
    // The independent corner-dot layer always has its own black moat.
    float edge=smoothstep(0.0,0.025,min(min(in.uv.x,1-in.uv.x),min(in.uv.y,1-in.uv.y)));
    return half4(half3(saturate(color)*edge),1);
}
