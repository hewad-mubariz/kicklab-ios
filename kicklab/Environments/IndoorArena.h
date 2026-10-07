// Native room, lights and reflections. No camera-facing backdrop is used.
// Included after the shared linear-color and world-pattern helpers.
struct ArenaHit { float t; float3 p; int face; };
constant float arenaHalfWidth=10.0, arenaBack=-26.0, arenaFront=16.0, arenaHeight=8.8;
constexpr sampler arenaSignSampler(coord::normalized,address::clamp_to_zero,filter::linear,mip_filter::linear);

float arenaPeriodicDistance(float x,float period) {return abs(fract(x/period+0.5)-0.5)*period;}
float arenaRect(float2 p,float2 halfSize,float aa) {
    float2 q=abs(p)-halfSize;
    float d=length(max(q,0.0))+min(max(q.x,q.y),0.0);
    return 1-smoothstep(-aa,aa,d);
}
float arenaSegment(float2 p,float2 a,float2 b) {
    float2 d=b-a;return length(p-a-d*clamp(dot(p-a,d)/dot(d,d),0.0,1.0));
}
ArenaHit arenaRoomHit(float3 eye,float3 rd) {
    ArenaHit hit={1e4,float3(0),0};
    // 0 floor, 1 ceiling, 2/3 side walls, 4/5 end walls.
    for(int face=0;face<6;face++) {
        float d=face<2?rd.y:(face<4?rd.x:rd.z);
        float origin=face<2?eye.y:(face<4?eye.x:eye.z);
        float plane=face==0?0:(face==1?arenaHeight:(face==2?-arenaHalfWidth:(face==3?arenaHalfWidth:(face==4?arenaBack:arenaFront))));
        if(abs(d)<0.00001)continue;
        float t=(plane-origin)/d;float3 p=eye+rd*t;
        if(t>0.002 && t<hit.t && abs(p.x)<=arenaHalfWidth+0.001 && p.y>=-0.001 && p.y<=arenaHeight+0.001 && p.z>=arenaBack-0.001 && p.z<=arenaFront+0.001)
            hit={t,p,face};
    }
    return hit;
}

float3 arenaWall(float3 p,int face,float aa,texture2d<float> signs) {
    bool end=face>=4;
    float across=end?p.x:p.z+5;
    float bay=arenaPeriodicDistance(across,4.0);
    float seam=max(stripeStudy(across,1.0,0.018,aa),stripeStudy(p.y,2.2,0.015,aa));
    float texture=noiseStudy(float2(across,p.y)*46);
    float macro=noiseStudy(float2(across,p.y)*1.8);
    float3 material=float3(0.014,0.019,0.024)*(0.72+0.24*macro+0.16*texture);
    float wallFloorAO=smoothstep(0.0,0.65,p.y)*0.34+0.66;
    float ceilingAO=0.65+0.35*smoothstep(0.0,1.8,arenaHeight-p.y);
    float3 color=material*float3(0.68,0.79,0.94)*(1-seam*0.55)*wallFloorAO*ceilingAO;
    float overhead=exp(-pow(arenaPeriodicDistance(across,6.0)/1.1,2.0));
    color+=float3(0.012,0.021,0.033)*overhead*exp(-pow((p.y-7.1)/2.0,2.0));

    // Recessed amber wall lights on the same structural bay lattice.
    float dx=arenaPeriodicDistance(across-2.0,4.0);
    float below=3.0-p.y;
    float spread=0.16+max(0.0,below)*0.32;
    float pool=exp(-pow(dx/spread,2.0))*exp(-max(0.0,below)*0.75)*smoothstep(-0.10,0.10,below);
    color+=float3(0.25,0.125,0.043)*pool*(0.70+0.3*texture);
    float lamp=arenaRect(float2(dx,p.y-3.05),float2(0.18,0.023),aa);
    float lampGlow=exp(-dx*dx/0.08-pow((p.y-3.05)/0.12,2.0));
    color+=float3(3.8,2.2,0.9)*lamp+float3(0.25,0.12,0.035)*lampGlow;

    // Continuous fascia and thin indirect coves wrap all four walls.
    float fascia=arenaRect(float2(0,p.y-3.62),float2(100,0.43),aa);
    color=mix(color,float3(0.008,0.012,0.016),fascia);
    color+=float3(1.35,0.76,0.29)*(strokeStudy(p.y-3.17,0.012,aa)+strokeStudy(p.y-0.23,0.009,aa))*0.65;
    color+=float3(0.045,0.025,0.01)*exp(-pow((p.y-0.24)/0.16,2.0));
    // Steel columns stand proud; highlight one flange and darken the recess.
    float column=1-smoothstep(0.080-aa,0.080+aa,bay);
    if(end && abs(across)<0.2)column=0;
    color=mix(color,float3(0.008,0.013,0.018),column);
    if(!end || abs(across)>0.2)color+=float3(0.020,0.028,0.035)*strokeStudy(bay-0.074,0.009,aa);
    color*=1-0.35*exp(-pow((bay-0.115)/0.045,2.0));

    if(end) {
        // A large painted wordmark, not a video screen or repeated billboard.
        float2 uv=float2(p.x/7.8+0.5,0.5-(p.y-5.65)/1.95);
        if(face==5)uv.x=1-uv.x;
        if(all(uv>=0)&&all(uv<=1)) {
            float4 ink=signs.sample(arenaSignSampler,float2(uv.x,uv.y*0.5),level(max(0.0,log2(aa*300))));
            color=color*(1-ink.a)+ink.rgb*1.05;
        }
        // Quiet service doors at the rear give a turned view believable scale.
        if(face==5) {
            float door=arenaRect(float2(abs(p.x)-6,p.y-1.08),float2(0.75,1.08),aa);
            color=mix(color,float3(0.015,0.025,0.028),door);
            float edge=strokeStudy(abs(abs(p.x)-6)-0.75,0.015,aa)*step(p.y,2.16);
            color+=float3(0.035,0.045,0.05)*edge;
            color+=float3(0.04,0.8,0.43)*arenaRect(float2(abs(p.x)-6,p.y-2.40),float2(0.18,0.045),aa);
        }
    } else {
        float z=fract((p.z-3)/20+0.5)*20-10;
        float2 uv=float2(z/12+0.5,0.5-(p.y-3.64)/3.0);
        if(face==2)uv.x=1-uv.x;
        if(all(uv>=0)&&all(uv<=1)) {
            float4 ink=signs.sample(arenaSignSampler,float2(uv.x,0.5+uv.y*0.5),level(max(0.0,log2(aa*220))));
            color=color*(1-ink.a)+ink.rgb*0.48;
        }
    }
    return color;
}

float3 arenaCeiling(float3 p,float aa) {
    float rib=stripeStudy(p.x,0.26,0.045,aa);
    float joist=max(stripeStudy(p.x,2,0.075,aa),stripeStudy(p.z+5,5,0.10,aa));
    float3 color=float3(0.005,0.008,0.012)*(0.76+0.28*noiseStudy(p.xz*9));
    color*=1-rib*0.30;return mix(color,float3(0.003,0.006,0.01),joist);
}

float3 arenaShell(float3 eye,float3 rd,float pixel,float roughness,texture2d<float> signs,thread float &distance) {
    ArenaHit hit=arenaRoomHit(eye,rd);distance=hit.t;
    float aa=max(0.002,hit.t*(pixel+roughness*0.008));
    float3 color=hit.face==1?arenaCeiling(hit.p,aa):arenaWall(hit.p,hit.face,aa,signs);
    if(hit.face==0)color=float3(0.025,0.03,0.035);

    // Two-height roof chords and recessed fixture housings have their own
    // intersection depths; roof structure changes perspective under rotation.
    if(rd.y>0.00001) {
        for(int layer=0;layer<2;layer++) {
            if(roughness>0.01)continue;
            float y=layer==0?7.92:8.64;
            float t=(y-eye.y)/rd.y;float3 p=eye+rd*t;
            if(t<=0 || t>=distance || abs(p.x)>arenaHalfWidth || p.z<arenaBack || p.z>arenaFront)continue;
            float edge=max(0.004,t*pixel);
            float cross=stripeStudy(p.z+5,5,layer==0?0.14:0.10,edge);
            float rail=stripeStudy(p.x,2,0.06,edge);
            float cover=max(cross,rail*(layer==1?1.0:0.0));
            if(cover>0.001) {
                color=mix(color,float3(0.009,0.015,0.023)*(0.75+0.35*cross),cover);
                if(cover>0.8)distance=t;
            }
        }
        // Suspended cool-white twin luminaires, three rows across the court.
        float t=(8.28-eye.y)/rd.y;float3 p=eye+rd*t;
        if(t>0 && t<distance && abs(p.x)<8.5 && p.z>arenaBack+1 && p.z<arenaFront-1) {
            float2 local=float2(arenaPeriodicDistance(p.x,6.0),arenaPeriodicDistance(p.z+3,6.0));
            float edge=max(0.006,t*pixel+roughness*t*0.018);
            float housing=arenaRect(local,float2(0.22,0.98),max(0.007,t*pixel));
            color=mix(color,float3(0.022,0.030,0.039),housing);
            float twin=abs(local.x-0.095);
            float core=arenaRect(float2(twin,local.y),float2(0.045,0.88),edge);
            float halo=exp(-pow(max(0.0,local.x-0.18)/(0.15+edge*2),2.0)-pow(max(0.0,local.y-0.86)/(0.26+edge*3),2.0));
            color+=float3(4.4,4.8,5.1)*core+float3(0.06,0.085,0.12)*halo;
            if(housing>0.8)distance=t;
        }
    }
    // Diagonal steel webs on the repeated vertical truss planes.
    if(abs(rd.z)>0.0001 && roughness<0.01) {
        for(int row=0;row<8;row++) {
            float z=-25+float(row)*5;float t=(z-eye.z)/rd.z;
            float3 p=eye+rd*t;
            if(t<=0 || t>=distance || abs(p.x)>arenaHalfWidth || p.y<7.9 || p.y>8.7)continue;
            float x=fract((p.x+10)/2)*2;
            float diagonal=min(arenaSegment(float2(x,p.y),float2(0,7.96),float2(1,8.60)),
                               arenaSegment(float2(x,p.y),float2(1,8.60),float2(2,7.96)));
            float coverage=strokeStudy(diagonal,0.027,max(0.003,t*pixel));
            color=mix(color,float3(0.012,0.021,0.032),coverage);
            if(coverage>0.8)distance=t;
        }
    }
    return color;
}

float arenaCourtMark(float2 p,float aa) {
    float line=abs(length(p-float2(0,-5))-3.0);
    if(abs(p.x)<8)line=min(line,abs(p.y+5));
    if(p.y>=-24 && p.y<=14)line=min(line,abs(abs(p.x)-8));
    if(abs(p.x)<=8)line=min(line,min(abs(p.y+24),abs(p.y-14)));
    float center=1-smoothstep(0.10-aa,0.10+aa,length(p-float2(0,-5)));
    return max(center,strokeStudy(line,0.032,aa));
}

float3 indoorArenaStudy(float3 eye,float3 rd,constant StudyUniforms &u,float pixel,texture2d<float> signs,texture2d<float> concrete) {
    float distance;
    float3 color=arenaShell(eye,rd,pixel,0,signs,distance);
    ArenaHit hit=arenaRoomHit(eye,rd);
    if(hit.face==0) {
        float3 p=hit.p;
        float footprint=max(0.001,pixel*hit.t/max(0.12,abs(rd.y)));
        float broad=noiseStudy(p.xz*0.7);
        float grain=mix(noiseStudy(p.xz*160),0.5,smoothstep(0.005,0.03,footprint));
        constexpr sampler floorSampler(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
        float mip=max(0.0,log2(footprint*float(concrete.get_width())/3.0));
        float3 material=concrete.sample(floorSampler,p.xz/3.0,level(mip)).rgb;
        float3 base=material*float3(0.27,0.32,0.39)*(0.72+broad*0.24+grain*0.1);
        float joint=max(stripeStudy(p.x,4,0.009,footprint),stripeStudy(p.z+5,4,0.009,footprint));
        base*=1-joint*0.28;
        float mark=arenaCourtMark(p.xz,footprint*0.7);
        base=mix(base,float3(0.25,0.30,0.33)*(0.8+material.r),mark*0.8);
        float pool=exp(-pow(arenaPeriodicDistance(p.x,6)/2.8,2.0)-pow(arenaPeriodicDistance(p.z+3,6)/3.1,2.0));
        color=base*(0.50+0.60*pool);

        // Planar reflections follow the actual room and lights, with a small
        // roughness cone and restrained world-space surface irregularity.
        float dx=(concrete.sample(floorSampler,p.xz/3.0+float2(0.002,0),level(mip)).r-material.r)*0.35;
        float dz=(concrete.sample(floorSampler,p.xz/3.0+float2(0,0.002),level(mip)).r-material.r)*0.35;
        float3 reflected=reflect(rd,normalize(float3(dx,1,dz)));
        float unused;
        float3 reflection=arenaShell(p+float3(0,0.015,0),reflected,pixel*1.5,0.65,signs,unused);
        float fresnel=0.095+0.15*pow(1-saturate(-rd.y),5.0);
        color=mix(color,reflection,fresnel*(0.45+0.55*saturate(material.r*7))*(1-mark*0.5));
        // Soft local warm light from the lower wall coves.
        float wallDistance=min(arenaHalfWidth-abs(p.x),min(p.z-arenaBack,arenaFront-p.z));
        color+=float3(0.095,0.051,0.019)*exp(-wallDistance*1.25);
        float2 delta=p.xz-u.contact.xy;
        float2 contact=delta/float2(max(0.065,u.contact.z*0.72),0.10);
        float2 soft=delta/float2(max(0.22,u.contact.z*1.6),0.34);
        color*=1-u.contact.w*(exp(-dot(contact,contact))*0.45+exp(-dot(soft,soft))*0.18);
    }
    // A slight cool air lift retains structure in the far roof without washing
    // the dark panels into gray. Static world noise avoids temporal shimmer.
    color=mix(color,float3(0.008,0.014,0.023),1-exp(-hit.t*0.0025));
    return displayStudy(max(color,0.0));
}
