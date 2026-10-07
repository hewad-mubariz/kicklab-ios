#include <metal_stdlib>
using namespace metal;
struct StudyUniforms {
    float4 eye; float4 right; float4 up; float4 forward;
    float4 camera; // aspect, tanHalfFOV, horizon, source distance
    float4 source; // source eye height, subject plane z, mode, time
    float4 contact; // supporting foot x/z, visible width, confidence
    float4 sourceRight, sourceUp, sourceForward, layout, crop; // packed, source FOV, source eye z, environment
};
constexpr sampler studySampler(coord::normalized,address::clamp_to_zero,filter::linear);
float3 linearStudy(float3 s){return select(s/12.92,pow((s+0.055)/1.055,float3(2.4)),s>0.04045);}
float3 displayStudy(float3 c){return select(c*12.92,1.055*pow(max(c,0.0),float3(1.0/2.4))-0.055,c>0.0031308);}
#include "ForegroundMatting.h"

// All lighting below is linear. World-space patterns and pixel footprints keep
// the turf, seats and net stable while the calibrated camera moves.
float hashStudy(float2 p) {
    float3 q=fract(float3(p.x,p.y,p.x)*0.1031);
    q+=dot(q,q.yzx+33.33);return fract((q.x+q.y)*q.z);
}
float noiseStudy(float2 p) {
    float2 i=floor(p),f=fract(p);f=f*f*(3-2*f);
    return mix(mix(hashStudy(i),hashStudy(i+float2(1,0)),f.x),
               mix(hashStudy(i+float2(0,1)),hashStudy(i+1),f.x),f.y);
}
float stripeStudy(float x,float period,float width,float aa) {
    float d=abs(fract(x/period+0.5)-0.5)*period;
    // Coverage tends to the average when the pattern becomes subpixel.
    return mix(1-smoothstep(width*0.5-aa,width*0.5+aa,d),width/period,saturate(aa/period));
}
float strokeStudy(float d,float width,float aa) {return 1-smoothstep(width-aa,width+aa,abs(d));}
float3 hazeStudy(float3 color,float depth) {
    return mix(color,float3(0.065,0.12,0.18),1-exp(-depth*0.0018));
}
float3 stadiumLight(float3 p,float3 n) {
    float3 light=float3(0.22,0.30,0.40)*(0.7+0.3*n.y);
    light+=float3(0.32,0.24,0.14)*max(0.0,dot(n,normalize(float3(-0.7,0.6,-0.3))));
    for(int i=0;i<4;i++) {
        float3 position=float3(((i&1)?-1:1)*((i&2)?22.0:10.2),17.7,(i&2)?12:-38);
        float3 delta=position-p;
        float r2=dot(delta,delta);
        float3 direction=delta*rsqrt(r2);
        float cone=smoothstep(0.64,0.96,dot(-direction,normalize(float3(0,0,-8)-position)));
        light+=float3(0.85,0.93,1.0)*max(0.0,dot(n,direction))*cone*((i&2)?360.0:1250.0)/(r2+110);
    }
    return light;
}
float3 skyStudy(float3 rd,float time) {
    float up=saturate(rd.y);
    float3 color=mix(float3(0.13,0.19,0.26),float3(0.007,0.026,0.077),pow(up,0.45));
    float warm=pow(saturate(dot(rd,normalize(float3(-0.7,0.12,-1)))),8.0);
    color+=float3(0.13,0.055,0.008)*warm*exp(-up*4);
    float2 cloud=rd.xz/max(0.12,rd.y+0.19)*float2(1.4,3.6)+float2(time*0.002,0);
    float n=noiseStudy(cloud)*0.58+noiseStudy(cloud*2.3)*0.28+noiseStudy(cloud*5.1)*0.14;
    float cover=smoothstep(0.44,0.72,n)*smoothstep(0.02,0.22,rd.y);
    color=mix(color,float3(0.12,0.16,0.23)*(0.65+0.5*n),cover*0.7);
    return color;
}
float pitchMarkStudy(float2 p,float aa) {
    // The visible end of a correctly proportioned pitch, with a penalty area,
    // goal area, penalty spot and arc. Paint inherits the turf's microtexture.
    float line=1e3;
    if(abs(p.x)<34.05)line=min(line,abs(p.y+19));
    if(p.y>=-19 && p.y<86)line=min(line,abs(abs(p.x)-34));
    if(p.y>=-19 && p.y<=-2.5)line=min(line,abs(abs(p.x)-20.16));
    if(abs(p.x)<=20.16)line=min(line,abs(p.y+2.5));
    if(p.y>=-19 && p.y<=-13.5)line=min(line,abs(abs(p.x)-9.16));
    if(abs(p.x)<=9.16)line=min(line,abs(p.y+13.5));
    if(p.y> -2.5)line=min(line,abs(length(p-float2(0,-8))-9.15));
    float mark=strokeStudy(line,0.055,aa);
    return max(mark,1-smoothstep(0.11-aa,0.11+aa,length(p-float2(0,-8))));
}
float3 turfStudy(float3 eye,float3 rd,float depth,float pixel,float time,constant StudyUniforms &u,texture2d<float> turf) {
    float3 p=eye+rd*depth;
    float footprint=max(0.001,pixel*depth/max(0.18,abs(rd.y)));
    float mowing=0.5+0.5*tanh(sin((p.z+19)*M_PI_F/5.5)*9);
    float macro=noiseStudy(p.xz*0.8)*0.6+noiseStudy(p.xz*3.8)*0.4;
    float fine=mix(noiseStudy(p.xz*125),0.5,smoothstep(0.003,0.035,footprint));
    float grain=0.73+macro*0.34+fine*0.22;
    float3 albedo=mix(float3(0.038,0.112,0.029),float3(0.047,0.138,0.034),mowing)*grain;
    float ink=max(pitchMarkStudy(p.xz,footprint*0.65),pitchMarkStudy(float2(p.x,67-p.z),footprint*0.65));
    if(abs(p.x)<34 && p.z> -19 && p.z<86) {
        ink=max(ink,strokeStudy(p.z-33.5,0.055,footprint*0.65));
        ink=max(ink,strokeStudy(length(p.xz-float2(0,33.5))-9.15,0.055,footprint*0.65));
    }
    albedo=mix(albedo,float3(0.64,0.67,0.53)*grain,ink*0.88);
    float3 illumination=stadiumLight(p,float3(0,1,0));
    constexpr sampler grassSampler(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
    float grassLOD=max(0.0,log2(footprint*float(turf.get_width())/1.5));
    float3 grass=turf.sample(grassSampler,p.xz/1.5,level(grassLOD)).rgb;
    // Neutral photographic blade color with world-space mowing and lighting.
    float3 color=grass*float3(0.78,0.92,0.72)*illumination*(0.86+0.13*mowing);
    color=mix(color,float3(0.56,0.63,0.48)*(0.82+0.18*fine),ink*0.85);
    // Short, tapered blades with real height. Only the resolved near field uses
    // blade intersections; distant grass converges to filtered turf albedo.
    float bladeLOD=1-smoothstep(7.0,12.0,depth);
    if(bladeLOD>0.001) {
        constexpr float cell=0.035;
        float2 grid=floor(p.xz/cell);
        float wind=sin(p.x*0.7+p.z*0.9+time*1.5)*0.003;
        float best=depth;
        float3 bladeColor=color;float cover=0;
        for(int z=-2;z<=2;z++) for(int x=-2;x<=2;x++) {
            float2 id=grid+float2(x,z);
            float r=hashStudy(id),r2=hashStudy(id+19.7);
            float2 root=(id+float2(0.15+0.7*r,0.15+0.7*r2))*cell;
            float theta=r*6.283185;
            float3 side=float3(cos(theta),0,sin(theta));
            float3 normal=float3(-side.z,0,side.x);
            float denom=dot(rd,normal);
            if(abs(denom)<0.08)continue;
            float t=dot(float3(root.x,0,root.y)-eye,normal)/denom;
            float3 q=eye+rd*t-float3(root.x,0,root.y);
            float h=0.028+r2*0.026;
            float v=q.y/h;
            if(t<=0 || t>best || v<0 || v>1)continue;
            float bend=(wind+(r-0.5)*0.013)*v*v;
            float local=dot(q,side)-bend;
            float width=0.0034*(1-v)*(0.7+r*0.6);
            float aa=max(0.0006,pixel*t*0.6);
            float a=strokeStudy(local,width,aa)*smoothstep(0.0,0.12,v);
            if(a>0.05) {
                best=t;cover=a;
                bladeColor=color*(0.57+v*0.64+r*0.24);
                bladeColor+=float3(0.015,0.025,0.004)*v;
            }
        }
        color=mix(color,bladeColor,cover*bladeLOD);
    }
    // Contact stays at the tracked visible sole. Grass never overlays the
    // foreground, so its new height cannot bury the player's shoes.
    float2 delta=p.xz-u.contact.xy;
    float2 tight=delta/float2(max(0.05,u.contact.z*0.58),0.075);
    float2 soft=delta/float2(max(0.15,u.contact.z*1.4),0.24);
    float2 cast=(delta-float2(0.13,0.50))/float2(max(0.18,u.contact.z*1.1),0.65);
    color*=1-u.contact.w*(exp(-dot(tight,tight))*0.40+exp(-dot(soft,soft))*0.14+exp(-dot(cast,cast))*0.10);
    // Soft shadow beneath and behind the goal's back frame.
    float goalShadow=exp(-pow((p.z+20.7)/0.5,2.0))*(1-smoothstep(3.6,4.1,abs(p.x)));
    color*=1-goalShadow*0.22;
    return hazeStudy(color,depth);
}
float bowlIntersection(float3 eye,float3 rd,float base,float slope) {
    float2 o=float2(eye.x/1.15,(eye.z-33.5)/1.85),v=float2(rd.x/1.15,rd.z/1.85);
    float r=base+slope*eye.y;
    float a=dot(v,v)-slope*slope*rd.y*rd.y;
    float b=dot(o,v)-r*slope*rd.y,c=dot(o,o)-r*r;
    float disc=b*b-a*c;
    if(disc<=0 || abs(a)<0.00001)return 1e4;
    float t=(-b+sqrt(disc))/a;
    return t>0?t:1e4;
}
float3 standsStudy(float3 p,float depth,float pixel) {
    float angle=atan2(p.x/1.15,p.z+8);
    float arc=angle*36;
    float aa=max(0.01,depth*pixel);
    float aisle=stripeStudy(arc,7.5,0.45,aa);
    float row=stripeStudy(p.y-0.25,0.48,0.095,aa*0.6);
    float seatX=stripeStudy(arc+floor(p.y/0.48)*0.25,0.50,0.41,aa);
    float seatY=stripeStudy(p.y-0.22,0.48,0.30,aa*0.6);
    float variation=hashStudy(float2(floor(arc/0.5),floor(p.y/0.48)));
    variation=mix(variation,0.5,smoothstep(0.09,0.35,aa));
    float3 seats=mix(float3(0.008,0.025,0.036),float3(0.018,0.060,0.077),variation);
    float3 color=mix(float3(0.006,0.010,0.017),seats,seatX*seatY);
    color=mix(color,float3(0.038,0.048,0.057)*(1-row*0.52),aisle);
    color*=0.46+0.40*saturate(1-abs(p.y-5)/9);
    color*=1-0.42*exp(-pow((p.y-10.8)/1.4,2.0));
    // Irregular occupied seats break up the perfect grid at a distance.
    float2 seatCell=float2(arc/0.5+floor(p.y/0.48)*0.5,p.y/0.48);
    float2 within=fract(seatCell)-float2(0.5,0.55);
    float crowd=step(0.30,hashStudy(floor(seatCell)+27));
    float body=1-smoothstep(0.16,0.30+aa,length(within*float2(1,0.8)));
    float3 shirt=mix(float3(0.013,0.017,0.022),float3(0.062,0.070,0.069),variation*variation);
    color=mix(color,shirt,body*crowd*(1-aisle)*0.65);
    color+=float3(0.022,0.026,0.028)*strokeStudy(p.y-5.27,0.065,aa);
    // A recessed concourse, slab edge, glass suites and warm interior light.
    if(p.y>5.4 && p.y<6.9) {
        float window=stripeStudy(arc,2.4,2.16,aa);
        float lit=0.12+0.88*pow(hashStudy(float2(floor(arc/2.4),17)),2.0);
        float interior=strokeStudy(p.y-6.17,0.42,aa);
        color=mix(float3(0.022,0.029,0.038),float3(0.23,0.135,0.058)*lit*(0.3+0.7*saturate((p.y-5.6)/1.2)),interior*window);
        color+=float3(0.6,0.33,0.12)*strokeStudy(p.y-6.62,0.022,aa)*window*0.50;
        float downlight=stripeStudy(arc+0.5,2.4,0.16,aa)*strokeStudy(p.y-6.43,0.035,aa);
        color+=float3(0.75,0.54,0.30)*downlight;
    }
    // Low pitch perimeter with small restrained LED panels and dark breaks.
    if(p.y<0.9) {
        color=float3(0.025,0.041,0.043);
        float panel=stripeStudy(arc,6.0,5.2,aa)*strokeStudy(p.y-0.42,0.19,aa);
        color=mix(color,float3(0.027,0.115,0.088),panel);
        color+=float3(0.09,0.18,0.14)*stripeStudy(arc+0.3,6.0,1.4,aa)*strokeStudy(p.y-0.42,0.022,aa);
    }
    return hazeStudy(color,depth);
}
void goalStudy(float3 eye,float3 rd,float pixel,thread float3 &color,float closest) {
    // Side and back net planes give the goal depth under lateral camera motion.
    for(int plane=0;plane<4;plane++) {
        float denom=plane==0?rd.z:(plane==3?rd.y:rd.x);
        if(abs(denom)<0.0001)continue;
        float t=plane==0?(-21.0-eye.z)/denom:(plane==3?(2.44-eye.y)/denom:((plane==1?-3.66:3.66)-eye.x)/denom);
        float3 q=eye+rd*t;
        bool inside=plane==0?(abs(q.x)<=3.66 && q.y>=0 && q.y<=2.44):
            (plane==3?(abs(q.x)<=3.66 && q.z>=-21 && q.z<=-19):(q.y>=0 && q.y<=2.44 && q.z>=-21 && q.z<=-19));
        if(t<=0 || t>=closest || !inside)continue;
        float2 net=plane==0?q.xy:(plane==3?q.xz:q.zy);
        float aa=max(0.003,pixel*t*0.65);
        float mesh=max(stripeStudy(net.x,0.145,0.006,aa),stripeStudy(net.y,0.145,0.006,aa));
        color=mix(color,hazeStudy(float3(0.35,0.40,0.39),t),mesh*0.29);
    }
    if(rd.z>=-0.0001)return;
    float t=(-19-eye.z)/rd.z;float3 g=eye+rd*t;
    float aa=max(0.007,pixel*t*0.65);
    if(t>0 && t<closest && abs(g.x)<3.66+0.09+aa && g.y>0 && g.y<2.44+0.09+aa) {
        float post=min(abs(abs(g.x)-3.66),abs(g.y-2.44));
        float coverage=strokeStudy(post,0.06,aa);
        float roundness=sqrt(saturate(1-pow(post/0.065,2.0)));
        float3 bar=float3(0.56,0.63,0.65)*(0.6+roundness*0.45);
        color=mix(color,hazeStudy(bar,t),coverage);
    }
}
constexpr sampler stadiumTextureSampler(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear,mip_filter::linear);
float3 stadiumTexture(float3 direction,texture2d<float> panorama) {
    float2 uv=float2(fract(0.5+atan2(direction.x,-direction.z)/M_PI_F),
        clamp(0.578-atan2(direction.y,length(direction.xz))*0.55,0.002,0.998));
    return panorama.sample(stadiumTextureSampler,uv).rgb;
}
float3 ledBoard(float2 uv,texture2d<float> boards,float depth,float pixel) {
    float mip=max(0.0,log2(max(0.001,pixel*depth)*256));
    float3 color=boards.sample(stadiumTextureSampler,uv,level(mip)).rgb;
    // Subpixel LED dots fade before they can shimmer on a moving camera.
    float dots=mix(0.87+0.13*sin(uv.x*2048*M_PI_F)*sin(uv.y*512*M_PI_F),1.0,saturate(pixel*depth*60));
    return color*dots*1.15;
}
float3 sceneStudy(float3 eye,float3 rd,constant StudyUniforms &u,float pixel,
                  texture2d<float> panorama,texture2d<float> boards,texture2d<float> turf) {
    float3 color=stadiumTexture(rd,panorama);
    float closest=1e4;
    float bowl=bowlIntersection(eye,rd,36,1.05);
    float3 hit=eye+rd*bowl;
    if(hit.y>=0 && hit.y<23) {
        closest=bowl;color=stadiumTexture(hit-float3(0,1.6,5),panorama);
        float angle=atan2(hit.x/1.15,-(hit.z-33.5)/1.85);
        // Continuous physical fascia around the bowl, readable in every direction.
        if(hit.y>5.0 && hit.y<6.15) {
            float2 uv=float2(fract(angle/(2*M_PI_F)*48+0.5),(6.15-hit.y)/1.15);
            color=ledBoard(uv,boards,bowl,pixel);
        }
    }
    if(rd.y< -0.0001) {
        float depth=-eye.y/rd.y;
        if(depth>0 && depth<closest) {closest=depth;color=turfStudy(eye,rd,depth,pixel,u.source.w,u,turf);}
    }
    // Pitch-side boards are a separate curved surface in front of the seats.
    float board=bowlIntersection(eye,rd,34.8,0);
    float3 b=eye+rd*board;
    if(board<closest && b.y>=0.02 && b.y<0.96) {
        float angle=atan2(b.x/1.15,-(b.z-33.5)/1.85);
        color=ledBoard(float2(fract(angle/(2*M_PI_F)*50+0.5),(0.96-b.y)/0.94),boards,board,pixel);
        closest=board;
    }
    // Two large screens, angled inward from the corners. Their perspective and
    // occlusion change with the camera, independently of the distant backdrop.
    for(int side=0;side<2;side++) {
        float sign=side==0?-1.0:1.0;
        float3 center=float3(sign*6.1,10.3,-28);
        float3 normal=normalize(float3(-sign*0.32,0,1));
        float denom=dot(rd,normal);
        if(abs(denom)<0.001)continue;
        float t=dot(center-eye,normal)/denom;
        float3 p=eye+rd*t-center;
        float x=dot(p,normalize(float3(1,0,sign*0.32)));
        if(t>0 && t<closest && abs(x)<2.8 && abs(p.y)<1.0) {
            float2 uv=float2(x/5.6+0.5,0.5-p.y/2.0);
            float border=step(abs(x),2.72)*step(abs(p.y),0.93);
            color=mix(float3(0.007,0.014,0.019),ledBoard(uv,boards,t,pixel),border);
            closest=t;
        }
    }
    goalStudy(eye,rd,pixel,color,closest);
    goalStudy(float3(eye.x,eye.y,67-eye.z),float3(rd.x,rd.y,-rd.z),pixel,color,closest);
    // Distant photographed architecture supplies material detail; the pitch,
    // signage, goal and contact shadow above are projected in native 3D.
    return displayStudy(max(color,0.0));
}
#include "IndoorArena.h"
#include "UrbanCourt.h"
#include "ForestCourt.h"
#include "SeasonalFields.h"

float4 foregroundSample(texture2d<float,access::sample> image,float2 uv,bool packed,bool mask,float4 crop) {
    if(packed)uv=(uv-crop.xy)/crop.zw;
    if(any(uv<0)||any(uv>1))return float4(0);
    if(packed) {
        float inset=0.5/float(image.get_width());
        uv.x=clamp(uv.x*0.5+(mask?0.5:0.0),(mask?0.5:0.0)+inset,(mask?1.0:0.5)-inset);
    }
    return image.sample(studySampler,uv);
}
float foregroundAlpha(texture2d<float,access::sample> matte,float2 uv,float layout,float4 crop) {
    if(layout<2.5)return foregroundSample(matte,uv,layout>0.5,true,crop).r;
    uv=(uv-crop.xy)/crop.zw;
    if(any(uv<0)||any(uv>1))return 0;
    return matte.sample(studySampler,uv).r;
}
// Decode premultiplied SDR color before interpolation. Interpolating encoded
// color first darkens subpixel hair/finger boundaries during reprojection.
float3 premultipliedForegroundSample(texture2d<float,access::sample> image,float2 uv,float4 crop) {
    uv=(uv-crop.xy)/crop.zw;
    if(any(uv<0)||any(uv>1))return float3(0);
    int2 size=int2(image.get_width()/2,image.get_height());
    float2 p=uv*float2(size)-0.5,weight=fract(p);
    int2 lo=int2(floor(p)),hi=lo+1;
    lo=clamp(lo,int2(0),size-1);hi=clamp(hi,int2(0),size-1);
    return mix(mix(linearStudy(image.read(uint2(lo)).rgb),linearStudy(image.read(uint2(hi.x,lo.y)).rgb),weight.x),
               mix(linearStudy(image.read(uint2(lo.x,hi.y)).rgb),linearStudy(image.read(uint2(hi)).rgb),weight.x),weight.y);
}
// An edge pixel in the source already contains some of the old background.
// Reusing that RGB with a new alpha creates green/bright fringes. Estimate the
// local old background outside the mask and unmix it, only at covered edges.
float3 cleanForegroundStudy(texture2d<float,access::sample> source,
                            texture2d<float,access::sample> matte,float2 uv,float alpha,float3 rgb,bool packed,float4 crop) {
    float3 original=linearStudy(rgb);
    if(alpha<0.08 || alpha>0.98)return original;
    float2 texel=(packed ? crop.zw:float2(1))/float2(source.get_width()/(packed?2:1),source.get_height());
    float3 background=0;float weight=0;
    for(int ring=1;ring<=3;ring++) for(int i=0;i<8;i++) {
        float angle=float(i)*M_PI_F/4;
        float2 q=uv+float2(cos(angle),sin(angle))*float(ring*2)*texel;
        if(any(q<0)||any(q>1))continue;
        float a=foregroundSample(matte,q,packed,true,crop).r;
        float w=(1-smoothstep(0.01,0.10,a))/float(ring*ring);
        background+=linearStudy(foregroundSample(source,q,packed,false,crop).rgb)*w;weight+=w;
    }
    if(weight<0.05)return original;
    float3 recovered=(original-(1-alpha)*background/weight)/max(0.15,alpha);
    // Restrict corrections where the estimated coverage disagrees with color.
    float trust=1-smoothstep(0.18,0.5,length(recovered-original));
    return mix(original,saturate(recovered),trust*0.85);
}
float3 arenaPersonReflection(float3 background,float3 rd,constant StudyUniforms &u,
                              texture2d<float,access::sample> source,texture2d<float,access::sample> matte) {
    if(rd.y>=-0.001 || abs(rd.z)<0.001)return background;
    float floorT=-u.eye.y/rd.y;
    float3 floorPoint=u.eye.xyz+rd*floorT;
    if(abs(floorPoint.x)>arenaHalfWidth || floorPoint.z<arenaBack || floorPoint.z>arenaFront)return background;
    float3 reflected=reflect(rd,float3(0,1,0));
    float t=(u.source.y-floorPoint.z)/reflected.z;
    if(t<=0)return background;
    float3 p=floorPoint+reflected*t;
    float3 delta=p-float3(0,u.source.x,u.layout.z);
    float depth=dot(delta,u.sourceForward.xyz);
    if(depth<=0 || p.y>2.3)return background;
    float2 uv=float2(0.5+dot(delta,u.sourceRight.xyz)/(depth*2*u.layout.y*u.camera.x),
        u.camera.z-dot(delta,u.sourceUp.xyz)/(depth*2*u.layout.y));
    bool packed=u.layout.x>0.5;
    float2 texel=(packed?u.crop.zw:float2(1))/float2(source.get_width()/(packed?2:1),source.get_height());
    float3 rgb=0;float alpha=0;
    // Rough-floor reflections soften with distance from the visible contact.
    // A fixed screen-space three-tap copy looked like a second cutout.
    float spread=2.5+min(2.0,max(0.0,p.y))*5.0;
    for(int i=0;i<5;i++) {
        float2 offset=i==0 ? float2(0):i==1 ? float2(-1,0):i==2 ? float2(1,0):i==3 ? float2(0,-0.6):float2(0,0.6);
        float weight=i==0 ? 2.0:1.0;
        float2 sampleUV=uv+offset*spread*texel;
        float a=foregroundAlpha(matte,sampleUV,u.layout.x,u.crop);
        rgb+=(u.layout.x>1.5 ? min(premultipliedForegroundSample(source,sampleUV,u.crop),float3(a))
            :linearStudy(foregroundSample(source,sampleUV,packed,false,u.crop).rgb)*a)*weight;alpha+=a*weight;
    }
    if(alpha<0.001)return background;
    float strength=0.14*exp(-max(0.0,p.y)*1.8);
    return displayStudy(mix(linearStudy(background),rgb/alpha,alpha/6*strength));
}

kernel void foregroundStudy(texture2d<float,access::sample> source [[texture(0)]],
                            texture2d<float,access::sample> matte [[texture(1)]],
                            texture2d<half,access::write> output [[texture(2)]],
                            texture2d<float> panorama [[texture(3)]], texture2d<float> boards [[texture(4)]], texture2d<float> turf [[texture(5)]],
                            texture2d<float> arenaSigns [[texture(6)]],
                            texture2d<float> arenaConcrete [[texture(7)]],
                            texture2d<float> urbanSigns [[texture(8)]],
                            texture2d<float> forestTrees [[texture(9)]],
                            texture2d<float> forestSigns [[texture(10)]],
                            texture2d<float> seasonalTrees [[texture(11)]],
                            texture2d<float> snowMountains [[texture(12)]],
                            constant StudyUniforms &u [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=output.get_width()||gid.y>=output.get_height())return;
    float2 uv=(float2(gid)+0.5)/float2(output.get_width(),output.get_height());
    float2 sourceUV=uv;
    float3 background;
    if(u.source.z<0.5) {
        float checker=fmod(floor(uv.x*18)+floor(uv.y*32),2.0);
        background=mix(float3(0.22,0.19,0.30),float3(0.36,0.31,0.44),checker);
    } else {
        float3 rd=normalize(u.forward.xyz+u.right.xyz*((uv.x-0.5)*2*u.camera.y*u.camera.x)
            +u.up.xyz*((u.camera.z-uv.y)*2*u.camera.y));
        float pixel=2*u.camera.y/float(output.get_height());
        background=u.layout.w>3.5 ? seasonalFieldStudy(u.eye.xyz,rd,u,pixel,u.layout.w<4.5,seasonalTrees,snowMountains,forestSigns)
            : u.layout.w>2.5 ? forestCourtStudy(u.eye.xyz,rd,u,pixel,turf,forestTrees,forestSigns)
            : u.layout.w>1.5 ? urbanCourtStudy(u.eye.xyz,rd,u,pixel,urbanSigns,arenaConcrete)
            : u.layout.w>0.5 ? indoorArenaStudy(u.eye.xyz,rd,u,pixel,arenaSigns,arenaConcrete)
            : sceneStudy(u.eye.xyz,rd,u,pixel,panorama,boards,turf);
        if(u.layout.w>0.5 && u.layout.w<1.5)background=arenaPersonReflection(background,rd,u,source,matte);
        float d=(u.source.y-u.eye.z)/rd.z;
        float3 hit=u.eye.xyz+rd*d;
        float3 sourceDelta=hit-float3(0,u.source.x,u.layout.z);
        float sourceDepth=dot(sourceDelta,u.sourceForward.xyz);
        sourceUV=float2(0.5+dot(sourceDelta,u.sourceRight.xyz)/(sourceDepth*2*u.layout.y*u.camera.x),
            u.camera.z-dot(sourceDelta,u.sourceUp.xyz)/(sourceDepth*2*u.layout.y));
        if(d<=0)sourceUV=float2(-1);
    }
    bool packed=u.layout.x>0.5;
    float4 original=foregroundSample(source,sourceUV,packed,false,u.crop);
    float alpha=foregroundAlpha(matte,sourceUV,u.layout.x,u.crop);
    float3 foreground=u.layout.x>1.5 ? premultipliedForegroundSample(source,sourceUV,u.crop)
        :cleanForegroundStudy(source,matte,sourceUV,alpha,original.rgb,packed,u.crop);
    if(u.layout.x>1.5)foreground=min(foreground,float3(saturate(alpha)));
    float3 color=displayStudy(u.layout.x>1.5 ? linearStudy(background)*(1-saturate(alpha))+foreground
        : mix(linearStudy(background),foreground,saturate(alpha)));
    output.write(half4(half3(color),1),gid);
}
