#ifndef EFFECT_PATHS
#define EFFECT_PATHS
// Neon's and Galaxy's strands, sparks and stars depend on the frame, not the pixel, yet the lab's
// neonEffect and galaxyEffect rebuild them for every pixel. fxEffectPath evaluates them once per
// frame with the lab's own functions; neonEffectPath and galaxyEffectPath then shade each pixel
// from those points with the lab's arithmetic, unchanged.

// Neon: 4 curves × 65 points (xy, valid; the upper pair use 49), 33 accent points, 18 sparks
// (xy, width, strength; strength < 0 when the spark has no birth).
constant uint neonAccentBase=260,neonSparkBase=293,neonPathCount=311;
// Galaxy: 4 lanes × 41 gxCurve points, then 30 stars as (xy, size, envelope) and (tint, valid).
constant uint gxStarBase=164,gxPathCount=194;

void neonPath(uint id,float4 viewport,float4 ball,constant float4 *history,device float4 *path) {
    float R=max(1.0,ball.z),t=viewport.z;
    if(id<neonAccentBase) {
        uint curve=id/65,i=id%65;
        bool upper=curve<2;float lane=float(curve%2);
        uint steps=upper ? 48 : 64;
        float s=float(i)/float(steps);
        path[id]=0;
        if(i>steps)return;
        if(upper) {
            NeonUpperCurve top=neonReleasedUpper(lane,t,ball,history);
            if(top.valid)path[id]=float4(neonUpperPoint(top,s,lane,t),1,0);
        } else {
            float age=s*0.30;
            float4 e=neonSmoothHistory(age,history);
            if(e.w>0)path[id]=float4((e.xy-ball.xy)/R+neonLower(s,lane,t-age)*e.z/R,1,0);
        }
    } else if(id<neonSparkBase) {
        float s=float(id-neonAccentBase)/32.0;
        float2 p=neonCubic(float2(0.64,-1.50),float2(1.65,-0.75),float2(1.42,0.85),float2(0.58,1.35),s);
        p.x+=sin(t*0.9)*0.06*sin(s*3.14159265);
        path[id]=float4(p,0,0);
    } else if(id<neonPathCount) {
        uint i=id-neonSparkBase;
        float sid=float(i),duration=0.52+neonHash(sid+8)*0.23;
        float phase=neonHash(sid+13)*duration;
        float cycle=floor((t+phase)/duration),age=t-(cycle*duration-phase);
        float seed=sid+cycle*19.31;
        float4 birth=neonHistory(age,history),older=neonHistory(min(0.8,age+0.025),history);
        if(birth.w<=0 || older.w<=0){path[id]=float4(0,0,0,-1);return;}
        float2 v=clamp((birth.xy-older.xy)/0.025,-birth.z*20,birth.z*20);
        float angle=neonHash(seed+4)*6.28318530718;
        float2 radial=float2(cos(angle),sin(angle));
        float travel=(1-exp(-age*1.5))/1.5;
        float2 release=i%3==0 ? neonUpper(0.20+neonHash(seed+2)*0.66,0,t-age,0)
            : i%3==1 ? neonLower(0.12+neonHash(seed+2)*0.47,0,t-age)*0.78
            : radial*(1.25+neonHash(seed+2)*0.8);
        float2 point=birth.xy+release*birth.z
            +(v*0.13+radial*birth.z*0.8)*travel+float2(0,birth.z*age*age*2.0);
        float life=age/duration;
        float envelope=smoothstep(0.0,0.08,life)*(1-smoothstep(0.5,1.0,life));
        float width=(i%5==0 ? 0.043 : 0.023)*birth.z/R;
        path[id]=float4(point,width,envelope*(i%5==0 ? 1.65 : 0.95));
    }
}

float4 neonEffectPath(float2 pixel,float4 viewport,float4 ball,float4 motion,float contactAge,
                      constant float4 *path,float pixelStep) {
    float R=max(1.0,ball.z),t=viewport.z;
    float2 q=(pixel-ball.xy)/R;
    float aa=max(0.006,pixelStep/R*0.55);
    float contact=contactAge>=0 && contactAge<0.42 ? motion.z*exp(-contactAge*7.0) : 0;
    float4 light=0;
    for(uint curve=0;curve<4;curve++) {
        bool upper=curve<2;float lane=float(curve%2);
        float bestD=1e5,bestS=0;float2 previous=0;bool have=false;
        if(upper && path[curve*65].z<=0)continue;
        uint steps=upper ? 48 : 64;
        for(uint i=0;i<=steps;i++) {
            float4 point=path[curve*65+i];
            if(point.z<=0){have=false;continue;}
            float2 p=point.xy;
            if(have) {
                float2 ab=p-previous;
                float f=saturate(dot(q-previous,ab)/max(dot(ab,ab),0.000001));
                float d=length(q-previous-ab*f);
                if(d<bestD){bestD=d;bestS=(float(i)-1+f)/float(steps);}
            }
            previous=p;have=true;
        }
        float taper=smoothstep(0.0,0.05,bestS)*(1-smoothstep(0.35,1.0,bestS));
        float pulse=upper ? 0.84+0.16*pow(0.5+0.5*sin(bestS*14-t*5.2+lane),2.0)
            : 0.94+0.06*sin(bestS*13-t*2.7+lane);
        float width=(lane==0 ? 0.073 : 0.023)*(0.18+0.82*taper);
        float strength=(lane==0 ? 1.48 : 0.60)*taper*pulse*(1+contact*0.28);
        if(!upper)strength*=0.95;
        light+=neonFilament(bestD,width,strength,aa);
    }
    float best=1e5,along=0;float2 previous=0;
    for(uint i=0;i<=32;i++) {
        float2 p=path[neonAccentBase+i].xy;
        if(i>0){float2 ab=p-previous;float f=saturate(dot(q-previous,ab)/max(dot(ab,ab),0.000001));float d=length(q-previous-ab*f);if(d<best){best=d;along=(float(i)-1+f)/32;}}
        previous=p;
    }
    float accent=pow(max(0.0,sin(along*3.14159265)),1.1);
    light+=neonFilament(best,0.035*(0.3+accent*0.7),accent*(0.85+contact*0.35),aa);
    for(uint i=0;i<18;i++) {
        float4 spark=path[neonSparkBase+i];
        if(spark.w<0)continue;
        light+=neonFilament(length(pixel-spark.xy)/R,spark.z,spark.w,aa);
    }
    float mask=smoothstep(1.0,1.065,length(q));
    return float4(light.rgb*mask,saturate(light.a)*mask);
}

void galaxyPath(uint id,float4 viewport,float4 ball,constant float4 *history,device float4 *path) {
    float t=viewport.z;
    if(id<gxStarBase) {
        path[id]=gxCurve(float(id%41)/40.0,id/41,t,ball,history);
    } else if(id<gxPathCount) {
        uint i=id-gxStarBase;
        device float4 *star=path+gxStarBase+i*2;
        star[0]=0;star[1]=0;
        float sid=float(i),duration=0.46+gxHash(sid+8)*0.30,phase=gxHash(sid+13)*duration;
        float cycle=floor((t+phase)/duration),age=t-(cycle*duration-phase),seed=sid+cycle*19.31;
        float4 born=gxHistory(age,history),older=gxHistory(min(0.8,age+0.025),history);
        if(born.w<=0 || older.w<=0)return;
        float2 v=clamp((born.xy-older.xy)/0.025,-born.z*20,born.z*20);
        float angle=gxHash(seed+4)*6.2831853;
        float2 radial=float2(cos(angle),sin(angle));
        float s=0.08+gxHash(seed+2)*0.76;
        float streamAge=min(s*gxFlowLife(i%3),max(0.0,0.78-duration));
        float streamS=streamAge/gxFlowLife(i%3);
        float4 origin=gxSmoothHistory(age+streamAge,history);
        if(origin.w<=0)return;
        float2 release=gxLocal(streamS,i%3,t-age-streamAge)+radial*(0.10+gxHash(seed+9)*0.38);
        float travel=(1-exp(-age*2.0))/2;
        float2 position=origin.xy+release*origin.z+(v*0.12+radial*origin.z*0.9)*travel;
        position+=float2(sin(age*4+seed)-sin(seed),-age*0.8)*born.z*0.22;
        float life=age/duration,envelope=smoothstep(0.0,0.08,life)*(1-smoothstep(0.48,1.0,life));
        star[0]=float4(position,born.z,envelope);
        star[1]=float4(mix(float3(0.6,2.8,4.9),float3(3.7,0.6,4.6),gxHash(seed+5)),1);
    }
}

float4 galaxyEffectPath(float2 pixel,float4 viewport,float4 ball,float4 motion,float contactAge,
                        constant float4 *path,float pixelStep) {
    float R=max(1.0,ball.z),t=viewport.z;
    float2 q=(pixel-ball.xy)/R;
    float aa=max(0.006,pixelStep/R*0.58);
    float mask=smoothstep(1.0,1.065,length(q));if(mask<=0)return 0;
    float contact=contactAge>=0 && contactAge<0.48 ? motion.z*exp(-contactAge*6.5):0;
    float4 light=0;float dustEnvelope=0;
    for(uint lane=0;lane<4;lane++) {
        float best=1e6,sd=0,along=0,scale=1;float2 previous=0;bool have=false;
        for(uint i=0;i<=40;i++) {
            float4 point=path[lane*41+i];
            if(point.w<=0){have=false;continue;}
            if(have) {
                float2 ab=point.xy-previous;
                float f=saturate(dot(q-previous,ab)/max(dot(ab,ab),0.000001));
                float2 diff=q-previous-ab*f;float dist=length(diff);
                if(dist<best){best=dist;sd=(ab.x*diff.y-ab.y*diff.x>=0 ? dist:-dist);along=(float(i)-1+f)/40;scale=point.z;}
            }
            previous=point.xy;have=true;
        }
        if(best>1e5)continue;
        float fade=(1-smoothstep(0.56,1.0,along))*(0.82+0.18*sin(along*13-t*2+float(lane)));
        float width=(lane==0 ? 0.78 : lane==1 ? 0.65 : lane==2 ? 0.46 : 0.46)*scale*(0.48+0.52*sin(along*3.14159265));
        float strength=lane==3 ? 0.40 : lane==1 ? 0.85 : lane==2 ? 0.80 : 1.0;
        light+=gxNebula(q,sd,along,width,fade*strength*(1+contact*0.32),float(lane),t,aa);
        dustEnvelope=max(dustEnvelope,gxLine(best,width*2.15)*fade*strength);
    }
    float3 domain=float3(q*1.8+float2(0,t*0.37),t*0.24);
    float2 drift=float2(gxNoise(domain),gxNoise(domain+13.7))-0.5;
    float dust=gxStardust((q+drift*0.15)*7.5+float2(-t*0.18,t*0.65),aa*7.5,t)*dustEnvelope;
    light+=float4(float3(1.8,2.7,4.3)*dust*3.2,dust*0.12);
    for(uint i=0;i<30;i++) {
        float4 star=path[gxStarBase+i*2],look=path[gxStarBase+i*2+1];
        if(look.w<=0)continue;
        float2 d=(pixel-star.xy)/R;
        float envelope=star.w;
        bool bright=i%7==0;
        float width=(bright ? 0.032 : 0.015)*star.z/R;
        float filter=sqrt(width*width+aa*aa);
        float core=gxLine(length(d),filter)*width/filter;
        float glow=gxLine(length(d),bright ? 0.11:0.048)*(bright ? 0.34:0.10);
        float cross=bright ? (gxLine(d.x,aa*0.65)*gxLine(d.y,0.092)+gxLine(d.y,aa*0.65)*gxLine(d.x,0.092))*0.12 : 0;
        light.rgb+=(float3(4,4.8,5.6)*core*2.1+look.rgb*(glow+cross))*envelope;
        light.a+=core*envelope*0.25;
    }
    return float4(light.rgb*mask,saturate(light.a)*mask);
}
#endif
