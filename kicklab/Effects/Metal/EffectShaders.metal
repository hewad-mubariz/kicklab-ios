#include <metal_stdlib>
using namespace metal;

struct FXUniforms {
    float4 viewport; // width, height, animation time, intensity
    float4 ball;     // x, y, radius, visibility
    float4 motion;   // velocity x/y in radii per sec, impact, style
    float4 region;   // render rectangle in output pixels
    float4 control;  // history count, counter mode, burst age, seed
    float4 tint;
    float4 environment; // night grade, material layer enabled, contact-motion age, reserved
};
constant float TAU = 6.28318530718;
constexpr sampler noiseSampler(coord::normalized, address::repeat, filter::linear);
constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);

#include "ShotShaderMath.h"

float hashFX(float p) { return fract(sin(p * 127.1 + 311.7) * 43758.5453); }
float3 noiseFX(texture3d<float> noise, float3 p) { return noise.sample(noiseSampler, p / 32.0).rgb; }
float fbmFX(texture3d<float> noise, float3 p) {
    return noiseFX(noise,p).r * 0.57 + noiseFX(noise,p * 2.07 + 13.1).g * 0.29
         + noiseFX(noise,p * 4.17 + 7.4).b * 0.14;
}


float segmentDistanceFX(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = saturate(dot(p - a, ab) / max(dot(ab, ab), 0.0001));
    return length(p - a - ab * t);
}

// Each material owns its silhouette. History is shared, appearance is not.
float3 rainbowFX(float hue) {
    return clamp(abs(fract(hue+float3(0,2.0/3.0,1.0/3.0))*6-3)-1,0.0,1.0);
}

float2 orbitFX(float angle, float radius, float flatten, float tilt) {
    float2 p=float2(cos(angle),sin(angle)*flatten)*radius;
    return float2(p.x*cos(tilt)-p.y*sin(tilt),p.x*sin(tilt)+p.y*cos(tilt));
}
float animatedHashFX(float seed, float time) {
    float tick=floor(time), f=smoothstep(0.0,1.0,fract(time));
    return mix(hashFX(seed+tick*17.0),hashFX(seed+(tick+1)*17.0),f);
}

// Brightness is layered: saturated energy outside, a fine pale filament inside.


float4 wakeEmitterFX(float age,constant float4 *emitters) {
    float slot=clamp(age*40.0,0.0,32.0);
    if(slot>=32)return emitters[32];
    uint index=uint(slot);
    float4 a=emitters[index],b=emitters[index+1];
    if(a.w<=0 || b.w<=0)return 0;
    // Calm old detector jitter while keeping the current head exact. Do not
    // smooth or connect across a missing detection.
    if(index>0 && emitters[index-1].w>0)a.xy=(emitters[index-1].xy+a.xy*2+b.xy)*0.25;
    if(index<31 && emitters[index+2].w>0)b.xy=(emitters[index].xy+b.xy*2+emitters[index+2].xy)*0.25;
    return mix(a,b,fract(slot));
}

// Integer value noise shared by the procedural materials. Time is a noise
// axis, so pause, seek and export are deterministic.



// Ridged turbulence: the sharp bright filaments inside a flame sheet.
float fireRidge3(float3 p) {
    float s=abs(fireNoise3(p)*2-1)*0.5;
    p=p*2.1+float3(-5.5,8.3,3.7); s+=abs(fireNoise3(p)*2-1)*0.25;
    p=p*2.1+float3(9.2,-3.9,6.1); s+=abs(fireNoise3(p)*2-1)*0.125;
    return 1-s/0.875;
}
// Fire shading. Blackbody-style HDR ramp: red tips, orange edges, yellow
// body, white-hot deep inside. Tone-mapped in resolveFX.
float3 fireRamp(float h) {
    float3 red=float3(1.6,0.14,0.01);
    float3 orange=float3(3.4,0.85,0.05);
    float3 yellow=float3(4.8,2.7,0.4);
    float3 white=float3(6.5,5.8,3.6);
    return h<0.3 ? mix(red,orange,h/0.3)
         : h<0.7 ? mix(orange,yellow,(h-0.3)/0.4)
         : mix(yellow,white,saturate((h-0.7)/0.3));
}
// Two smooth octaves: contours stay long and curling instead of breaking
// into a crackle network.
float fireSmooth3(float3 p) {
    return fireNoise3(p)*0.7+fireNoise3(p*1.9+float3(11.3,-4.1,7.7))*0.3;
}
// Flame turbulence: near the ball it is radial (tongues leave the surface at
// every angle, travel outward and bend into the wind); further out it is a
// rising world-space field. Blended as fields, not coordinates, so shapes
// morph rather than tear.
float fireTongueField(float2 w,float2 q,float R,float S,float2 wd,float t,float2 warp) {
    float world=fireFBM3(float3(w.x*1.6+warp.x*1.8,w.y*0.7+t*2.8+warp.y*1.4,t*0.7));
    float r=max(length(q),0.001);
    float out=max(0.0,r-1.0);
    float2 dir=normalize(q/r+wd*out*1.1);
    float radial=fireFBM3(float3(dir*4.2+warp*1.1,(r-t*2.1)*2.0*R/S+20.0));
    return mix(world,radial,exp(-out/0.9));
}
// Fire v9: solid flame. A tight shell clings to the ball, thicker downwind
// where it leans away from the motion; a ribbon of flame stays on the
// recorded path. Turbulence erodes that envelope into crisp tongues, and
// each tongue is filled and coloured by its depth: red-orange at the edge,
// yellow inside, white-hot near the ball. Faint fold lines give the sheets
// internal structure. Some tongues cross the ball's rim and face.
// Noise lives in world space at a scale tied to the frame, not the detected
// radius, so detector jitter never slides the pattern.
float4 proceduralFireFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters,float texel) {
    float R=max(1.0,u.ball.z),t=u.viewport.z;
    float S=max(4.0,u.viewport.y*0.03);
    float2 w=pixel/S;
    float2 q=(pixel-u.ball.xy)/R;
    float r=length(q);

    // 1. Shell and lean: the relative wind is buoyancy plus the air the ball
    //    runs through.
    float2 lean=u.motion.xy*0.07;
    float leanLength=length(lean);
    if(leanLength>0.85)lean*=0.85/leanLength;
    float2 wd=normalize(float2(0,-1)-lean);
    float2 side=float2(-wd.y,wd.x);
    float h=dot(q,wd),x=dot(q,side);
    float tail=1.9+0.3*sin(t*2.3)+0.2*sin(t*3.7+1.0);
    float girth=1.5;
    float halfWidth=h<0 ? sqrt(max(0.0,girth*girth-h*h))
                        : girth*pow(saturate(1-h/tail),0.7);
    float shell=saturate((halfWidth-abs(x))/0.55)*saturate((girth+h)/0.45);
    float heat=exp(-max(0.0,r-1.0)/0.55);

    // 2. Ribbon: flame left on the recorded path, drifting up only slightly,
    //    narrowing and cooling with age. Nothing bridges a missing detection.
    float ribbon=0;
    for(uint i=1;i<32;++i) {
        float4 e=emitters[i];
        if(e.w<=0)continue;
        float age=float(i)*0.025,life=age/0.8;
        float birth=t-age;
        float2 c=(e.xy-u.ball.xy)/R+float2(sin(birth*4.1)*0.25*age,-(age*0.7+age*age*1.4));
        float2 d=q-c;
        float rad=0.95*pow(1-life,0.6)+0.12;
        float g=exp(-dot(d,d)/(rad*rad))*pow(1-life,0.7);
        ribbon=max(ribbon,g);
        heat=max(heat,g*(1-life)*0.7);
    }
    float envelope=max(shell,ribbon);
    if(envelope<0.01 && r>1.6)return 0;

    // 3. Tongues: crisp silhouettes where the envelope beats the turbulence.
    float3 P=float3(w.x,w.y*0.6+t*2.4,t*0.6);
    float2 warp=float2(fireFBM3(P*float3(0.55,0.55,1.0)+float3(5.2,1.3,0.0)),
                       fireFBM3(P*float3(0.55,0.55,1.0)+float3(-3.1,7.7,11.0)))-0.5;
    float n=fireTongueField(w,q,R,S,wd,t,warp);
    n=saturate(0.5+(n-0.5)*2.4);
    float F=envelope*1.2-n*mix(0.9,1.3,1-heat)-0.08;
    float edge=0.035*texel*S/R;
    float inside=smoothstep(-edge,edge,F);

    // 4. Folds: soft darker and brighter bands inside each sheet.
    float fold=fireSmooth3(float3(w.x*2.2+warp.x*2.4,w.y*0.8+t*3.2+warp.y*1.8,t*0.9));
    float bands=0.5+0.5*sin(fold*24.0);

    // 5. Colour by depth into the tongue and closeness to the ball.
    float depth=saturate(F/0.5);
    float temp=saturate(0.12+depth*0.42+heat*0.2+(bands-0.5)*0.34);
    float flicker=1.0+0.05*sin(t*19.0)+0.035*sin(t*31.7+1.0);
    float3 color=fireRamp(temp)*inside*(0.55+0.3*depth)*(0.72+0.28*bands)*flicker;
    float alpha=inside*(0.6+0.35*depth);
    // A thin bright rim where the flame meets the ball.
    float rim=exp(-pow((r-1.0)/0.06,2.0))*(0.5+0.5*n);
    color+=fireRamp(0.9)*rim*0.5;
    alpha=saturate(alpha+rim*0.35);

    // 6. The ball stays readable: only the outer rim and tongues that are
    //    strong enough cross its face, translucently.
    float face=smoothstep(0.62,1.0,r);
    float cross=smoothstep(0.08,0.3,F)*face;
    float mask=max(smoothstep(0.9,1.0,r),cross*0.6);
    color*=mask;alpha*=mask;
    // The fire lights the ball: a warm translucent glaze over its face.
    float glaze=(1-smoothstep(0.9,1.0,r))*(0.06+0.14*smoothstep(0.5,1.0,r))*flicker;
    color+=float3(1.0,0.42,0.08)*glaze*(1-alpha);
    alpha+=glaze*(1-alpha);
    return float4(color,alpha);
}

// ---------------------------------------------------------------------------
// Electric: gold lightning. Bolts are continuous jagged lines: a straight axis
// displaced sideways by piecewise-linear 1D noise (linear interpolation keeps
// the kinks sharp). Each bolt slot strikes on its own clock, flashes, decays
// and re-strikes with a new shape. One bolt also runs along the recorded path.
float jagFX(float x,float seed) {
    float i=floor(x);
    return mix(hashFX(i+seed),hashFX(i+1+seed),fract(x))-0.5;
}
float boltOffsetFX(float s,float len,float seed) {
    float o=jagFX(s*len*1.1+seed,seed)*0.6
           +jagFX(s*len*2.7+seed*3.1,seed+7.0)*0.28
           +jagFX(s*len*6.3+seed*5.7,seed+13.0)*0.12;
    // Pinned where it leaves the surface, free at the tip.
    return o*len*0.34*min(1.0,s*5.0);
}
// Returns (core, glow) line weights for one bolt from `o` along `dir`.
float2 boltFX(float2 q,float2 o,float2 dir,float len,float seed,float width) {
    float2 side=float2(-dir.y,dir.x),rel=q-o;
    float along=dot(rel,dir),perp=dot(rel,side);
    float s=along/len;
    if(s<-0.15||s>1.2)return 0;
    float off=boltOffsetFX(saturate(s),len,seed);
    float d=length(float2(max(0.0,max(-along,along-len)),perp-off));
    float taper=1.0-saturate(s)*0.55;
    return float2(lineFX(d,width*taper),lineFX(d,width*4.5*taper));
}
float4 electricFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters) {
    float R=max(1.0,u.ball.z),t=u.viewport.z;
    float2 q=(pixel-u.ball.xy)/R;
    float r=length(q),angle=atan2(q.y,q.x);
    float core=0,glow=0;
    // 1. Radial bolts: eight slots around the ball, each on its own clock.
    for(uint j=0;j<12;++j) {
        float id=float(j);
        float rate=3.5+hashFX(id*5.3)*3.0;
        float clock=t*rate+hashFX(id*9.1);
        float tick=floor(clock),age=fract(clock);
        float seed=id*41.7+tick*17.3;
        if(hashFX(seed+1.0)<0.3)continue; // this slot is quiet this strike
        float flash=pow(1.0-age,1.6)*(0.55+0.45*hashFX(seed+2.0));
        float a=id*0.5236+(hashFX(seed+3.0)-0.5)*0.7;
        // Discharges prefer the body line: lean the field toward vertical.
        float2 dir=normalize(float2(cos(a)*0.62,sin(a)));
        float len=(2.0+hashFX(seed+4.0)*2.8)*(0.75+0.5*abs(dir.y));
        float2 o=dir*1.02;
        float2 b=boltFX(q,o,dir,len,seed,0.034);
        // Branches fork off partway and run shorter and thinner.
        for(uint k=0;k<3;++k) {
            float sb=0.22+float(k)*0.25+hashFX(seed+20.0+float(k))*0.15;
            float2 side=float2(-dir.y,dir.x);
            float2 origin=o+dir*sb*len+side*boltOffsetFX(sb,len,seed);
            float sign=hashFX(seed+30.0+float(k))>0.5?1.0:-1.0;
            float rot=sign*(0.5+hashFX(seed+40.0+float(k))*0.6);
            float2 bd=float2(dir.x*cos(rot)-dir.y*sin(rot),dir.x*sin(rot)+dir.y*cos(rot));
            float blen=len*(0.3+hashFX(seed+50.0+float(k))*0.3);
            float bseed=seed+60.0+float(k)*9.0;
            b+=boltFX(q,origin,bd,blen,bseed,0.022)*0.85;
            // Second-level twig off each branch.
            float2 bside=float2(-bd.y,bd.x);
            float2 torigin=origin+bd*blen*0.5+bside*boltOffsetFX(0.5,blen,bseed);
            float trot=-sign*(0.5+hashFX(bseed+3.0)*0.5);
            float2 td=float2(bd.x*cos(trot)-bd.y*sin(trot),bd.x*sin(trot)+bd.y*cos(trot));
            b+=boltFX(q,torigin,td,blen*0.5,bseed+5.0,0.016)*0.7;
        }
        core=max(core,b.x*flash);glow=max(glow,b.y*flash);
    }
    // 2. Two long discharges running up and down the body line, with deeper
    //    kinks and their own branches. Slower clocks, stronger flashes.
    for(uint j=0;j<2;++j) {
        float id=float(j)+20.0;
        float clock=t*(2.2+float(j)*0.7)+hashFX(id*9.1);
        float tick=floor(clock),age=fract(clock);
        float seed=id*41.7+tick*17.3;
        if(hashFX(seed+1.0)<0.2)continue;
        float flash=pow(1.0-age,1.2)*(0.7+0.3*hashFX(seed+2.0));
        float a=(j==0?-1.5708:1.5708)+(hashFX(seed+3.0)-0.5)*0.7;
        float2 dir=float2(cos(a),sin(a));
        float len=(j==0?6.5:4.5)+hashFX(seed+4.0)*2.0;
        float2 o=dir*1.02;
        float2 b=boltFX(q,o,dir,len,seed,0.044);
        for(uint k=0;k<4;++k) {
            float sb=0.15+float(k)*0.2+hashFX(seed+20.0+float(k))*0.15;
            float2 side=float2(-dir.y,dir.x);
            float2 origin=o+dir*sb*len+side*boltOffsetFX(sb,len,seed);
            float sign=hashFX(seed+30.0+float(k))>0.5?1.0:-1.0;
            float rot=sign*(0.6+hashFX(seed+40.0+float(k))*0.7);
            float2 bd=float2(dir.x*cos(rot)-dir.y*sin(rot),dir.x*sin(rot)+dir.y*cos(rot));
            float blen=len*(0.25+hashFX(seed+50.0+float(k))*0.25);
            float bseed=seed+60.0+float(k)*9.0;
            b+=boltFX(q,origin,bd,blen,bseed,0.026)*0.85;
            float2 bside=float2(-bd.y,bd.x);
            float2 torigin=origin+bd*blen*0.55+bside*boltOffsetFX(0.55,blen,bseed);
            float trot=-sign*(0.5+hashFX(bseed+3.0)*0.5);
            float2 td=float2(bd.x*cos(trot)-bd.y*sin(trot),bd.x*sin(trot)+bd.y*cos(trot));
            b+=boltFX(q,torigin,td,blen*0.5,bseed+5.0,0.018)*0.7;
        }
        core=max(core,b.x*flash);glow=max(glow,b.y*flash);
    }
    // 3. A discharge that follows the recorded ball path: displaced emitter
    //    points joined by segments, fading with age, re-kinking each strike.
    {
        float tick=floor(t*7.0);
        float2 prev=0;bool havePrev=false;
        for(uint i=0;i<32;++i) {
            float4 e=emitters[i];
            if(e.w<=0){havePrev=false;continue;}
            float age=float(i)*0.025;
            float2 p=(e.xy-u.ball.xy)/R;
            float2 next=i+1<32?(emitters[i+1].xy-u.ball.xy)/R:p;
            float2 tangent=next-p;
            tangent=length(tangent)>0.01?normalize(tangent):float2(0,-1);
            float2 normal=float2(-tangent.y,tangent.x);
            p+=normal*jagFX(float(i)*0.9+tick*3.0,tick)*(0.25+age*0.9);
            if(havePrev && i>1) {
                float d=segmentDistanceFX(q,prev,p);
                float fade=pow(saturate(1-age/0.8),1.3);
                core=max(core,lineFX(d,0.032)*fade*0.9);
                glow=max(glow,lineFX(d,0.16)*fade*0.9);
            }
            prev=p;havePrev=true;
        }
    }
    // 4. Charge halo on the ball: a jagged corona and a wide gold glow.
    float flicker=0.8+0.2*pow(sin(t*31.0),2.0)+0.1*sin(t*53.7);
    float corona=lineFX(r-(1.06+jagFX(angle*4.0+floor(t*12.0)*5.0,3.0)*0.10),0.04);
    float halo=exp(-pow(max(0.0,r-1.0)/1.9,2.0));
    // Fine charged dust: tiny glints scattered through the glow volume.
    float3 DP=float3(pixel/R*14.0,floor(t*10.0)*0.37);
    float dust=pow(saturate((fireNoise3(DP)-0.62)/0.38),3.0)*saturate(glow*2.0+halo*0.9)*(0.5+0.5*hashFX(floor(t*10.0)+floor(DP.x)*3.1+floor(DP.y)*7.7));
    float3 color=float3(7.0,6.4,3.8)*core
                +float3(4.3,1.9,0.12)*(glow*0.42+corona*0.9*flicker)
                +float3(2.8,1.1,0.06)*halo*0.3*flicker
                +float3(6.0,3.9,0.9)*dust;
    float alpha=saturate(core*1.2+glow*0.4+corona*0.8+halo*0.22+dust);
    float mask=smoothstep(0.90,1.06,r);
    return float4(color*mask,alpha*mask);
}

// ---------------------------------------------------------------------------
// Neon: open, asymmetric energy strokes above the ball and a fading wake
// attached to recorded positions below it. Fine cores, saturated shoulders and
// local bloom replace the old uniformly thick spring and its broad green fog.
float4 neonStrokeFX(float d,float width,float strength,float aa) {
    float bodyWidth=sqrt(width*width+aa*aa);
    float coreWidth=sqrt(width*width*0.075+aa*aa);
    float body=lineFX(d,bodyWidth)*width/bodyWidth;
    float core=lineFX(d,coreWidth)*width*0.274/coreWidth;
    float glow=lineFX(d,width*3.8);
    float3 color=float3(0.075,3.4,0.48)*(body+glow*0.15)
                +float3(4.6,5.2,4.5)*core*1.15;
    return float4(color,body*0.72+core*0.42+glow*0.13)*strength;
}
float2 neonCubicFX(float2 a,float2 b,float2 c,float2 d,float s) {
    float v=1-s;
    return a*v*v*v+b*3*v*v*s+c*3*v*s*s+d*s*s*s;
}
// Contact response has its own short envelope. It is absent during ordinary
// fast flight, and its released crescent stays at the historical contact point.
float4 neonImpactFX(float2 q,constant FXUniforms &u,constant float4 *emitters,float aa) {
    float age=u.environment.z;
    if(age<0.0 || age>=0.42 || u.motion.z<=0.001)return 0;
    float4 birth=wakeEmitterFX(age,emitters);
    if(birth.w<=0)return 0;
    float R=max(1.0,u.ball.z),t=u.viewport.z;
    float envelope=smoothstep(0.035,0.085,age)*pow(saturate(1-age/0.42),1.25)*u.motion.z;
    float4 light=0;
    float angle=atan2(q.y,q.x),r=length(q);
    // The white-green wraps tighten around the ball, brighten at the hit and
    // open into uneven, fading arcs. No wash across the readable ball face.
    for(uint j=0;j<3;j++) {
        float lane=float(j),phase=t*3.0+lane*1.9;
        float rr=1.10+lane*0.17+age*0.55+0.035*sin(angle*4.0+phase);
        float gate=0.25+0.75*smoothstep(-0.6,0.65,sin(angle*1.5+phase));
        light+=neonStrokeFX(abs(r-rr),0.07-lane*0.012,envelope*gate*(3.2-lane*0.6),aa);
    }
    float2 origin=(birth.xy-u.ball.xy)/R;
    float2 p=q-origin;
    // A broad, open crescent peels away near the contact point, rather than a
    // permanent orbit. Expansion, thinning and fading use the same event age.
    float turn=-0.30+0.10*sin((t-age)*1.2);
    float2 v=float2(p.x*cos(turn)-p.y*sin(turn),p.x*sin(turn)+p.y*cos(turn));
    for(uint j=0;j<2;j++) {
        float lane=float(j),reach=1.10+age*6.3+lane*0.18;
        float2 oval=float2(v.x,v.y/(0.38+lane*0.035));
        float theta=atan2(oval.y,oval.x);
        float gate=smoothstep(-0.35,0.5,sin(theta+0.5+age*3.0+lane*0.18));
        float ripple=0.06*sin(theta*3.0-age*5.0);
        // Approximate distance to the flattened ellipse, keeping uniform width.
        float metric=length(float2(cos(theta),sin(theta)/(0.38+lane*0.035)));
        float d=abs(length(oval)-reach-ripple)/max(1.0,metric);
        light+=neonStrokeFX(d,(j==0?0.13:0.052)*(1-age),envelope*gate*(j==0?3.0:1.4),aa);
    }
    // Charged fragments leave the hit, instead of following the new ball centre.
    for(uint j=0;j<14;j++) {
        float id=float(j),theta=id*2.399963+sin((t-age)*0.7)*0.8;
        float2 dir=float2(cos(theta),sin(theta));
        float speed=3.0+hashFX(id+37.0)*5.0;
        float2 point=dir*(1.0+age*speed)+float2(0,-age*0.7+age*age*2.0);
        float d=segmentDistanceFX(p,point-dir*0.10,point);
        float sparkle=0.5+0.5*pow(sin(age*22.0+id),2.0);
        light+=neonStrokeFX(d,0.035+hashFX(id+18.0)*0.018,envelope*sparkle*1.2,aa);
    }
    // Soft local spill supports the cores, with no persistent green fog.
    float spill=lineFX(r-1.24,0.30)*envelope;
    light+=float4(float3(0.025,0.8,0.09)*spill,spill*0.12);
    return light;
}
float4 neonFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters,float pixelStep) {
    float R=max(1.0,u.ball.z),t=u.viewport.z;
    float2 q=(pixel-u.ball.xy)/R;
    float r=length(q),aa=max(0.007,pixelStep/R*0.55);
    float4 light=0;
    float lean=clamp(-u.motion.x*0.023,-0.45,0.45);
    // Two related, unequal open sweeps. Their ends taper to nothing and the
    // curves breathe slowly rather than spinning a rigid orbit around the ball.
    for(uint j=0;j<2;j++) {
        float lane=float(j),bestD=1e5,bestS=0;
        float2 prev=0;
        for(uint i=0;i<=44;i++) {
            float s=float(i)/44.0;
            float2 p=neonCubicFX(float2(0.65,-0.82),
                float2(-2.8-0.15*lane,-0.65),float2(-3.7+0.5*lane,-3.15),
                float2(-0.65+0.45*sin(t*0.63+lane),-4.85+lane*0.48),s);
            p.x+=lean*s+sin(s*9.0-t*1.6+lane*0.9)*sin(s*3.14159)*0.12;
            p.y+=sin(s*7.0+t*1.2+lane)*sin(s*3.14159)*0.12;
            p+=float2(lane*0.16*sin(s*10.0+t*0.6),lane*0.13*cos(s*9.0+t*0.8));
            if(i>0) {
                float2 ab=p-prev;
                float f=saturate(dot(q-prev,ab)/max(dot(ab,ab),0.0001));
                float d=length(q-prev-ab*f);
                if(d<bestD){bestD=d;bestS=(float(i)-1+f)/44.0;}
            }
            prev=p;
        }
        float taper=smoothstep(0.0,0.065,bestS)*(1-smoothstep(0.62,1.0,bestS));
        float pulse=pow(0.5+0.5*sin(bestS*16.0+t*3.2+lane),8.0);
        float width=(j==0?0.048:0.022)*(0.35+0.65*taper);
        light+=neonStrokeFX(bestD,width,taper*(j==0?1.0:0.55)*(0.62+pulse*1.0),aa);
        float bead=pow(0.5+0.5*sin(bestS*43.0-t*2.3+lane*4.0),36.0);
        light+=neonStrokeFX(bestD,0.075,taper*bead*(j==0?0.8:0.35),aa);
    }
    // The lower sweeps are emitted by the actual ball path. Old positions stay
    // in place as the ball moves on; a missing interval breaks the curve.
    for(uint j=0;j<2;j++) {
        float lane=float(j),bestD=1e5,bestS=0;
        float2 prev=0; bool have=false;
        for(uint i=0;i<=56;i++) {
            float s=float(i)/56.0,age=s*0.78;
            float4 e=wakeEmitterFX(age,emitters);
            if(e.w<=0){have=false;continue;}
            // Broaden the history filter only for the decorative wake. The
            // current ball and its tight filaments remain at the exact anchor.
            float4 earlier=wakeEmitterFX(max(0.0,age-0.045),emitters);
            float4 later=wakeEmitterFX(min(0.80,age+0.045),emitters);
            if(earlier.w>0 && later.w>0)
                e.xy=mix(e.xy,(earlier.xy+e.xy*2+later.xy)*0.25,smoothstep(0.0,0.10,age));
            float theta=0.65+t*0.85-s*9.4+lane*(0.42+0.22*sin(s*8.0+t));
            float reach=1.16+0.72*sin(s*3.14159)+0.14*sin(s*11.0-t*1.2);
            float2 offset=float2(cos(theta)*reach,sin(theta)*reach*(0.54+0.08*sin(t*0.8)));
            offset+=float2(-0.4*sin(s*3.14159)+lane*0.12,4.1*s+0.35*s*s);
            float2 p=(e.xy-u.ball.xy)/R+offset;
            if(have) {
                float2 ab=p-prev;
                float f=saturate(dot(q-prev,ab)/max(dot(ab,ab),0.0001));
                float d=length(q-prev-ab*f);
                if(d<bestD){bestD=d;bestS=(float(i)-1+f)/56.0;}
            }
            prev=p;have=true;
        }
        float taper=pow(saturate(1-bestS),0.65)*(1-smoothstep(0.88,1.0,bestS));
        float pulse=pow(0.5+0.5*sin(bestS*23.0+t*4.0+lane),10.0);
        float width=(j==0?0.058:0.024)*(0.4+0.6*taper);
        light+=neonStrokeFX(bestD,width,taper*(j==0?1.18:0.80)*(0.6+1.1*pulse),aa);
        float bead=pow(0.5+0.5*sin(bestS*55.0+t*3.0+lane*5.0),40.0);
        light+=neonStrokeFX(bestD,0.080,taper*bead*(j==0?0.85:0.35),aa);
    }
    // Irregular broken filaments hug the silhouette without painting the face.
    float angle=atan2(q.y,q.x);
    for(uint j=0;j<2;j++) {
        float lane=float(j);
        float reach=1.10+lane*0.12+0.035*sin(angle*5+t*2.4+lane)
            +0.021*sin(angle*9-t*1.6);
        float gate=smoothstep(-0.75,0.25,sin(angle*2-t*1.5+lane*2.1));
        light+=neonStrokeFX(abs(r-reach),j==0?0.045:0.026,gate*(j==0?1.0:0.52),aa);
    }
    light+=neonImpactFX(q,u,emitters,aa);
    float mask=smoothstep(0.95,1.06,r);
    return float4(light.rgb*mask,saturate(light.a)*mask);
}

// ---------------------------------------------------------------------------
// Rainbow owns a spectral ribbon material: ordered colours across a rolling
// sheet, finer luminous strands inside it, and highlights travelling lengthwise.
// There is no uniformly opaque rainbow band or white wash over the ball.
float4 spectralRibbonFX(float signedDistance,float along,float width,float fade,float lane,float t,float aa) {
    float v=signedDistance/max(width,0.02);
    float n=fireSmooth3(float3(along*11.0-t*0.75,v*1.1+lane*6.3,t*0.27));
    float ripple=sin(along*17.0-t*3.0+lane)*0.10+(n-0.5)*0.28;
    float across=v+ripple;
    float edge=1-smoothstep(0.76,1.10,abs(across));
    // Ordered red-to-violet colours bend together; a gentle turn rolls the
    // ribbon rather than cycling every pixel through unrelated hues.
    float hue=saturate(across*0.68+0.5)*0.80+0.005;
    float3 spectrum=rainbowFX(hue);
    spectrum=mix(spectrum,sqrt(spectrum),0.18);
    float strand=pow(0.5+0.5*cos((across+1)*3.0*TAU+0.45*n),12.0);
    float travelling=pow(0.5+0.5*sin(along*22.0-t*5.5+lane*2.0+across*2.1),4.0);
    float folds=0.40+0.60*smoothstep(0.16,0.82,n);
    float body=edge*(0.17+0.16*folds);
    float threads=edge*strand*(0.38+travelling*1.8)*folds;
    float reflection=lineFX(signedDistance-width*(sin(along*12.0-t*2.5+lane)*0.45),max(aa,width*0.045))*travelling*edge;
    float shoulder=lineFX(signedDistance,width*1.65)*0.15;
    float3 color=spectrum*(body*1.35+threads*4.6+shoulder)
        +mix(spectrum,float3(1.0),0.70)*(reflection*2.3+threads*travelling*0.16);
    return float4(color*fade,(body*0.20+threads*0.32+reflection*0.22+shoulder*0.15)*fade);
}
float4 rainbowFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters,float footprint) {
    float R=max(1.0,u.ball.z),t=u.viewport.z;
    float2 q=(pixel-u.ball.xy)/R;float r=length(q),aa=max(0.008,footprint/R*0.55);
    float4 light=0;
    // Unequal open sweeps curl above and below the head. Their changing width
    // is the roll of a ribbon, and both ends taper instead of ending in caps.
    for(uint j=0;j<2;j++) {
        float lane=float(j),best=1e6,sd=0,along=0;float2 prev=0;
        for(uint i=0;i<=44;i++) {
            float s=float(i)/44.0;
            float angle=(j==0?0.20:-2.65)+s*(j==0?-3.10:3.5)+0.15*sin(t*1.2+lane*1.7);
            float reach=1.08+s*0.30+s*s*(j==0?2.5:1.3);
            float2 p=float2(cos(angle)*reach,sin(angle)*reach*0.86);
            p+=float2(sin(s*9.0-t*1.9+lane)*s*0.34,s*s*(j==0?-3.0:1.4));
            p.x+=clamp(-u.motion.x*0.018,-0.3,0.3)*s;
            if(i>0) {
                float2 ab=p-prev;float f=saturate(dot(q-prev,ab)/max(dot(ab,ab),0.0001));
                float2 diff=q-prev-ab*f;float d=length(diff);
                if(d<best){best=d;sd=(ab.x*diff.y-ab.y*diff.x>=0?d:-d);along=(float(i)-1+f)/44.0;}
            }
            prev=p;
        }
        float taper=smoothstep(0.0,0.06,along)*pow(saturate(1-along),0.58);
        float roll=0.40+0.60*abs(cos(along*5.5-t*0.9+lane*2.0));
        float width=(j==0?0.50:0.31)*roll*(0.18+0.82*sqrt(saturate(1-along)));
        light+=spectralRibbonFX(sd,along,width,taper*(j==0?1.25:0.85),lane,t,aa);
    }
    // A folded wake follows the actual recorded flight. Disconnected history
    // leaves a gap; it cannot turn into a full-frame default-distance surface.
    for(uint j=0;j<2;j++) {
        float lane=float(j),best=1e6,sd=0,along=0;float2 prev=0;bool have=false;
        for(uint i=0;i<=40;i++) {
            float age=float(i)/40.0*0.80,s=age/0.80;float4 e=wakeEmitterFX(age,emitters);
            if(e.w<=0){have=false;continue;}
            float birth=t-age,phase=birth*1.45+s*5.5+lane*2.4;
            float reach=1.02+age*1.1;
            float2 p=(e.xy-u.ball.xy)/R+float2(cos(phase)*reach,sin(phase)*reach*0.58);
            p+=float2(sin(birth*1.5+age*6.0)*age*0.7,age*(1.35+age*0.7));
            if(have) {
                float2 ab=p-prev;float f=saturate(dot(q-prev,ab)/max(dot(ab,ab),0.0001));
                float2 diff=q-prev-ab*f;float d=length(diff);
                if(d<best){best=d;sd=(ab.x*diff.y-ab.y*diff.x>=0?d:-d);along=(float(i)-1+f)/40.0;}
            }
            prev=p;have=true;
        }
        if(best>1e5)continue;
        float fade=pow(saturate(1-along),0.75);
        float roll=0.42+0.58*abs(cos(along*6.0-t*1.0+lane));
        float width=(j==0?0.46:0.24)*roll*(0.30+0.70*sqrt(saturate(1-along)));
        light+=spectralRibbonFX(sd,along,width,fade*(j==0?1.45:0.75),lane+3,t,aa);
    }
    // Broken spectral rim ties the ribbons to the ball without covering it.
    float angle=atan2(q.y,q.x);
    float rim=lineFX(r-(1.055+0.026*sin(angle*5+t*2.3)),max(aa,0.040));
    float gate=0.22+0.78*pow(0.5+0.5*sin(angle*2.0-t*1.8),2.0);
    light.rgb+=rainbowFX(fract(angle/TAU+t*0.055))*rim*gate*1.65;
    light.a+=rim*gate*0.18;
    float wispyRadius=1.15+0.10*sin(angle*3-t*2.2)+0.045*sin(angle*7+t*3.0);
    float wisp=lineFX(r-wispyRadius,0.10)*(0.25+0.75*pow(0.5+0.5*sin(angle*4-t*2.7),3.0));
    float3 rimColor=rainbowFX(fract(angle/TAU-t*0.06));
    light.rgb+=rimColor*wisp*2.5+mix(rimColor,float3(1.0),0.65)*rim*gate*0.75;
    light.a+=wisp*0.16;
    float pulse=0;
    if(u.environment.z>=0 && u.environment.z<0.42)
        pulse=u.motion.z*smoothstep(0.035,0.085,u.environment.z)*pow(1-u.environment.z/0.42,1.3);
    light.rgb*=1+pulse*0.8;
    float mask=smoothstep(0.94,1.06,r);
    return float4(light.rgb*mask,saturate(light.a)*mask);
}

// ---------------------------------------------------------------------------
// Pixel: the ball dissolves into axis-aligned blocks on a fixed screen grid.
// A density field (dense shell on the ball, a wake where the ball was, and
// columns streaming upward) decides which cells light up. Cells blink on
// their own clocks so the cluster shimmers instead of sliding.
float pixelDensityFX(float2 mid,constant FXUniforms &u,constant float4 *emitters,float t) {
    float R=max(1.0,u.ball.z);
    float2 q=(mid-u.ball.xy)/R;
    float r=length(q);
    // Shell on the ball, thinning outward.
    float density=smoothstep(0.8,1.1,r)*exp(-max(0.0,r-1.1)*0.8)*0.9;
    // Wake: blocks linger where the ball was, dispersing upward with age.
    for(uint i=2;i<32;i+=2) {
        float4 e=emitters[i];
        if(e.w<=0)continue;
        float age=float(i)*0.025,life=age/0.8;
        float2 d=(mid-e.xy)/R+float2(0,age*2.5);
        density+=exp(-dot(d,d)/(1.6+age*2.0))*(1-life)*0.35;
    }
    // Columns: a few lanes above the ball carry blocks streaming up.
    float lane=floor(q.x/0.9);
    float laneOn=step(0.45,hashFX(lane*3.7+floor(t*0.6)*11.0));
    float up=-q.y;
    if(up>0.5 && up<8.0 && abs(q.x)<3.2) {
        float stream=fract(hashFX(lane*7.1)+up*0.22-t*0.9);
        density+=laneOn*smoothstep(0.55,0.9,stream)*(1-up/8.0)*(1-abs(q.x)/3.2)*0.6;
    }
    return density;
}
// One grid layer: returns (block weight, shade pick) for this pixel.
float2 pixelLayerFX(float2 pixel,float2 cell,float scale,float bias,constant FXUniforms &u,constant float4 *emitters,float t) {
    float2 id=floor(pixel/cell);
    float2 mid=(id+0.5)*cell;
    float density=pixelDensityFX(mid,u,emitters,t)*scale-bias;
    float rate=2.5+hashFX(id.x*13.0+id.y*37.0+cell.x)*4.5;
    float tick=floor(t*rate+hashFX(id.x*5.0+id.y*11.0));
    float pick=hashFX(id.x*13.0+id.y*37.0+tick*101.0+cell.x*3.0);
    float on=step(pick,saturate(density));
    float2 uv=abs(pixel-mid)/cell;
    float size=0.47*(0.65+0.35*saturate(density));
    float block=1-smoothstep(size-0.05,size,max(uv.x,uv.y));
    float pulse=0.7+0.3*pow(sin(t*4.0+pick*9.0),2.0);
    return float2(on*block*pulse,hashFX(id.x*17.0+id.y*29.0+tick*7.0+cell.y));
}
float4 pixelFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters) {
    float R=max(1.0,u.ball.z),t=u.viewport.z;
    // Fine grid everywhere, a coarse grid of larger blocks and rectangles.
    float2 fine=pixelLayerFX(pixel,float2(max(2.0,R*0.26)),0.75,0.0,u,emitters,t);
    float2 coarse=pixelLayerFX(pixel+float2(R*0.13,R*0.07),float2(max(3.0,R*0.52),max(3.0,R*0.42)),0.6,0.08,u,emitters,t);
    float2 wide=pixelLayerFX(pixel+float2(R*0.31,R*0.21),float2(max(4.0,R*1.0),max(3.0,R*0.36)),0.35,0.1,u,emitters,t);
    float3 color=0;float alpha=0;
    float3 cyan=float3(0.04,1.5,2.4),light=float3(0.5,2.5,3.2),white=float3(2.4,3.0,3.3);
    float3 tf=fine.y<0.55?cyan:fine.y<0.88?light:white;
    float3 tc=coarse.y<0.45?cyan:coarse.y<0.8?light:white;
    float3 tw=wide.y<0.5?cyan:white;
    color=tf*fine.x+tc*coarse.x*1.05+tw*wide.x*1.1;
    alpha=saturate(fine.x+coarse.x+wide.x)*0.95;
    // Soft cyan glow volume so the cluster reads as light, not confetti.
    float2 qp=(pixel-u.ball.xy)/R;float rp=length(qp);
    float halo=exp(-pow(max(0.0,rp-1.0)/1.5,2.0))*0.3;
    float mask=smoothstep(0.88,1.02,rp);
    color=color*mask+float3(0.05,1.1,1.8)*halo*mask;
    alpha=alpha*mask+halo*0.6*mask;
    return float4(color,alpha);
}

// ---------------------------------------------------------------------------
// A tapered sheet has a soft body, a narrow folded reflection and a coloured
// shoulder. Its texture runs along the curve instead of covering a Gaussian
// cloud with stationary noise. Both materials use this geometric primitive,
// but different silhouettes, widths, palettes and particles.
float4 flowingVeilFX(float d,float along,float width,float fade,float lane,float t,float aa,bool galaxy) {
    float v=d/max(width,0.01);
    float n=fireSmooth3(float3(along*7.0-t*0.65,v*0.8+lane*7.1,t*0.25));
    float fine=fireNoise3(float3(along*24.0-t*1.5,v*2.3+lane*7.1,t*0.6));
    float bend=sin(along*10.0-t*2.0+lane*2.4)*0.32+(n-0.5)*1.0+(fine-0.5)*(galaxy?0.36:0.12);
    float edge=1-smoothstep(0.48,1.35,abs(v)+(n-0.5)*0.34);
    float silk=lineFX(d-width*bend,max(aa,width*(galaxy?0.22:0.20)));
    float split=lineFX(d+width*(0.53+bend*0.35),max(aa,width*0.075));
    float travelling=0.30+0.70*pow(0.5+0.5*sin(along*15.0-t*4.6+lane*2.1),3.0);
    float gauze=edge*(0.12+0.28*n);
    float breaks=smoothstep(0.22,0.62,fine)*(galaxy?0.80:0.45)+(galaxy?0.20:0.55);
    float shine=(silk*(0.30+travelling*0.85)+split*0.26)*edge*breaks;
    float shoulder=lineFX(d,width*1.8)*0.10;
    float3 color;
    if(galaxy) {
        // Blue in the volume; lavender/pink only on selected bright folds.
        float hue=smoothstep(0.15,0.9,n+0.18*sin(along*7.0+lane*2.0));
        float3 body=mix(float3(0.035,0.30,3.8),float3(1.10,0.08,3.3),hue);
        float3 highlight=mix(float3(0.45,1.5,5.8),float3(4.0,0.60,4.6),hue);
        color=body*(gauze+shoulder)+highlight*shine*0.82
+float3(2.4,2.5,3.6)*silk*pow(travelling,4.0)*edge*0.23;
    } else {
        float3 pearl=mix(float3(0.55,1.15,1.8),float3(2.0,1.75,1.45),n);
        color=pearl*(gauze+shoulder)*0.7+float3(2.6,2.85,3.0)*shine
+float3(3.2,2.9,2.5)*split*travelling*0.20;
    }
    return float4(color*fade,(gauze*0.22+shine*0.32+shoulder*0.12)*fade);
}

// Aura: two unequal flowing scarves, with wider silver surfaces and moving
// specular folds. They are open curves, not stacks of closed orbit rings.
float4 auraFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters,float footprint) {
    float R=max(1.0,u.ball.z),t=u.viewport.z;
    float2 q=(pixel-u.ball.xy)/R;float r=length(q),aa=max(0.009,footprint/R*0.65);
    float4 light=0;
    for(uint j=0;j<2;j++) {
        float lane=float(j),best=1e6,sd=0,along=0;float2 prev=0;
        for(uint i=0;i<=36;i++) {
            float s=float(i)/36.0;
            float angle=(lane==0?2.0:-1.2)+s*(lane==0?-3.8:2.8)+0.22*sin(t*1.35+lane);
            float reach=1.10+s*s*(lane==0?2.2:1.10);
            float2 p=float2(cos(angle)*reach,sin(angle)*reach*0.84);
            p+=float2(sin(s*7.0-t*1.8+lane)*s*0.24,-s*s*(lane==0?1.5:1.0));
            if(i>0) {
                float2 ab=p-prev;float f=saturate(dot(q-prev,ab)/max(dot(ab,ab),0.0001));
                float2 diff=q-prev-ab*f;float d=length(diff);
                if(d<best){best=d;sd=(ab.x*diff.y-ab.y*diff.x>=0?d:-d);along=(float(i)-1+f)/36.0;}
            }
            prev=p;
        }
        if(best>1e5)continue;
        float fade=smoothstep(0.0,0.08,along)*pow(saturate(1-along),0.7);
        float width=(0.26+0.24*sin(along*3.14159))*(0.28+0.72*sqrt(saturate(1-along)));
        light+=flowingVeilFX(sd,along,width,fade*(j==0?1.35:0.70),lane,t,aa,false);
    }
    // A separate broad, tapering scarf stays on the observed flight path.
    for(uint j=0;j<2;j++) {
        float lane=float(j),best=1e6,sd=0,along=0;float2 prev=0;bool have=false;
        for(uint i=0;i<=32;i++) {
            float age=float(i)*0.025,s=age/0.8;float4 e=wakeEmitterFX(age,emitters);
            if(e.w<=0){have=false;continue;}
            float birth=t-age,phase=birth*1.1+age*5.8+lane*2.5;
            float2 p=(e.xy-u.ball.xy)/R+float2(cos(phase)*(0.95+s*0.45),sin(phase)*0.5);
            p+=float2(sin(birth*1.5+age*3.8)*age*0.4,-age*1.15);
            if(have) {
                float2 ab=p-prev;float f=saturate(dot(q-prev,ab)/max(dot(ab,ab),0.0001));
                float2 diff=q-prev-ab*f;float d=length(diff);
                if(d<best){best=d;sd=(ab.x*diff.y-ab.y*diff.x>=0?d:-d);along=(float(i)-1+f)/32.0;}
            }
            prev=p;have=true;
        }
        if(best>1e5)continue;
        float fade=pow(saturate(1-along),0.85);
        light+=flowingVeilFX(sd,along,(0.28+along*0.35),fade*1.4,lane+3,t,aa,false);
    }
    float angle=atan2(q.y,q.x),rim=1.04+0.035*sin(angle*3-t*2.1);
    light.rgb+=float3(0.70,1.05,1.45)*lineFX(r-rim,0.085)*(0.50+0.50*sin(angle-t*1.6)*sin(angle-t*1.6));
    float pulse=u.environment.z>=0 && u.environment.z<0.42 ? u.motion.z*pow(1-u.environment.z/0.42,1.5):0;
    light.rgb*=1+pulse*0.35;
    float mask=smoothstep(0.94,1.06,r);
    return float4(light.rgb*mask,saturate(light.a)*mask);
}

// Jittered powder stays finer than the separate sprite stars. It is lit only
// near the nebula strands, with a pixel footprint to avoid checker shimmer.
float galaxyDustFX(float2 p,float footprint) {
    float2 cell=floor(p),f=fract(p);float dust=0;
    for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++) {
        float2 offset=float2(x,y),id=cell+offset;
        float seed=id.x*37.17+id.y*113.71;
        float2 d=offset+float2(hashFX(seed),hashFX(seed+31.7))-f;
        float size=0.045+hashFX(seed+13.2)*0.075;
        float width2=size*size+footprint*footprint*0.22;
        dust+=exp(-dot(d,d)/width2)*(size*size/width2)*(0.25+hashFX(seed+6.1)*0.75);
    }
    return dust;
}
// Galaxy: luminous blue-violet nebula strands. Open curls flow around the
// ball, the wake stays on its recorded path, and detached stars drift away.
// Large areas between strands remain clear instead of becoming purple fog.
float4 galaxyFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters,float footprint) {
    float R=max(1.0,u.ball.z),t=u.viewport.z;
    float2 q=(pixel-u.ball.xy)/R,w=pixel/max(4.0,u.viewport.y*0.03);
    float r=length(q),aa=max(0.01,footprint/R*0.60);
    float4 light=0;float dustEnvelope=0;
    for(uint j=0;j<2;j++) {
        float lane=float(j),best=1e6,sd=0,along=0;float2 prev=0;
        for(uint i=0;i<=40;i++) {
            float s=float(i)/40.0;
            float angle=(lane==0?0.15:2.2)-s*(lane==0?2.85:4.1)+sin(t*0.85+lane)*0.23;
            float reach=1.14+s*s*(lane==0?3.5:2.3);
            float2 p=float2(cos(angle)*reach,sin(angle)*reach*0.86);
            p+=float2(sin(s*8.5-t*1.7+lane)*s*0.48,-s*s*(lane==0?2.9:1.6));
            if(i>0) {
                float2 ab=p-prev;float f=saturate(dot(q-prev,ab)/max(dot(ab,ab),0.0001));
                float2 diff=q-prev-ab*f;float d=length(diff);
                if(d<best){best=d;sd=(ab.x*diff.y-ab.y*diff.x>=0?d:-d);along=(float(i)-1+f)/40.0;}
            }
            prev=p;
        }
        if(best>1e5)continue;
        float fade=smoothstep(0.0,0.055,along)*pow(saturate(1-along),0.55);
        float width=(0.22+0.46*sin(along*3.14159))*(0.2+0.8*sqrt(saturate(1-along)));
        light+=flowingVeilFX(sd,along,width,fade*1.6,lane,t,aa,true);
        dustEnvelope=max(dustEnvelope,lineFX(best,width*2.4)*fade);
    }
    for(uint j=0;j<2;j++) {
        float lane=float(j),best=1e6,sd=0,along=0;float2 prev=0;bool have=false;
        for(uint i=0;i<=32;i++) {
            float age=float(i)*0.025;float4 e=wakeEmitterFX(age,emitters);
            if(e.w<=0){have=false;continue;}
            float birth=t-age,phase=birth*1.55+age*6.3+lane*2.1;
            float reach=1.06+age*1.35;
            float2 p=(e.xy-u.ball.xy)/R+float2(cos(phase)*reach,sin(phase)*reach*0.68);
            p+=float2(sin(birth*1.7+age*4)*age*0.65,-age*(1.3+age*0.8));
            if(have) {
                float2 ab=p-prev;float f=saturate(dot(q-prev,ab)/max(dot(ab,ab),0.0001));
                float2 diff=q-prev-ab*f;float d=length(diff);
                if(d<best){best=d;sd=(ab.x*diff.y-ab.y*diff.x>=0?d:-d);along=(float(i)-1+f)/32.0;}
            }
            prev=p;have=true;
        }
        if(best>1e5)continue;
        float fade=pow(saturate(1-along),0.7),width=0.36+along*0.42;
        light+=flowingVeilFX(sd,along,width,fade*1.7,lane+3,t,aa,true);
        dustEnvelope=max(dustEnvelope,lineFX(best,width*2)*fade);
    }
    float dust=galaxyDustFX(w*8.0+float2(t*0.20,-t*1.3),footprint/max(4.0,u.viewport.y*0.03)*8.0)*dustEnvelope;
    light.rgb+=float3(2.0,2.6,4.2)*dust*2.8;light.a+=dust*0.22;
    float angle=atan2(q.y,q.x);
    float rim=lineFX(r-(1.07+0.045*sin(angle*4-t*2.3)),0.065);
    float gate=0.3+0.7*pow(0.5+0.5*sin(angle*3-t*2.0),2.0);
    light.rgb+=mix(float3(0.20,0.75,3.4),float3(2.8,0.35,3.4),0.5+0.5*sin(angle*2+t))*rim*gate;
    float pulse=u.environment.z>=0 && u.environment.z<0.42 ? u.motion.z*pow(1-u.environment.z/0.42,1.2):0;
    light.rgb*=1+pulse*0.8;
    float mask=smoothstep(0.94,1.06,r);
    return float4(light.rgb*mask,saturate(light.a)*mask);
}

// ---------------------------------------------------------------------------
// Nature: a glowing green energy swirl around the ball with wispy tendrils
// and a soft wake of green light along the path. Leaves are particles.
float4 natureFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters) {
    float R=max(1.0,u.ball.z),t=u.viewport.z;
    float2 q=(pixel-u.ball.xy)/R;
    float r=length(q),angle=atan2(q.y,q.x);
    float2 w=pixel/R;
    float mask=smoothstep(0.9,1.05,r);
    // Swirl ring: bright band with turbulent tendrils spiralling outward.
    float3 P=float3(w*1.1,t*0.35);
    float n=fireFBM3(P+float3(0,t*0.6,0));
    float swirl=sin(angle*3.0+r*3.4-t*2.2+n*4.0);
    float band=exp(-pow((r-1.3-n*0.35)/0.28,2.0));
    float tendrils=pow(saturate(swirl),5.0)*exp(-pow(max(0.0,r-1.2)/1.5,2.0));
    float ridge=fireRidge3(float3(w*1.6+float2(0,t*0.8),t*0.5));
    float wisps=pow(saturate((ridge-0.5)/0.5),3.0)*exp(-pow(max(0.0,r-1.1)/1.6,2.0))*(0.3+0.7*saturate(swirl+0.5));
    // Wake: green light lingering on the path, lifting slowly.
    float wake=0;
    for(uint i=2;i<32;i+=2) {
        float4 e=emitters[i];
        if(e.w<=0)continue;
        float age=float(i)*0.025,life=age/0.8;
        float2 d=(pixel-e.xy)/R+float2(sin(t*1.3+age*3.0)*age*0.5,age*2.0);
        float rad=1.2+age*1.4;
        wake+=exp(-dot(d,d)/(rad*rad))*(1-life)*0.5;
    }
    wake=(1-exp(-wake))*saturate((n-0.35)*2.5);
    float glow=band*0.8+tendrils*0.45+wisps*0.9+wake*0.35;
    float halo=exp(-pow(max(0.0,r-1.0)/0.7,2.0))*0.3;
    float3 lime=float3(0.6,3.6,0.25),leaf=float3(0.18,2.2,0.08),pale=float3(2.2,4.2,1.2);
    float3 color=leaf*glow+lime*(band*0.6+wisps*0.7)+pale*pow(wisps,2.0)*0.5+float3(0.3,2.0,0.2)*halo;
    float alpha=saturate(glow*0.9+halo*0.6);
    return float4(color*mask,alpha*mask);
}

// ---------------------------------------------------------------------------
// Ice: an irregular frozen skin, fine blue-white fissures, cold vapour and
// small glass fragments. All motion is driven by video time and recorded births.
float2 iceCellFX(float2 p) {
    float2 cell=floor(p),f=fract(p);
    float first=10,second=10;
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x) {
        float2 offset=float2(x,y),id=cell+offset;
        float seed=id.x*19.37+id.y*71.13;
        float2 site=offset+float2(hashFX(seed),hashFX(seed+43.8))-f;
        float d=dot(site,site);
        if(d<first){second=first;first=d;}else second=min(second,d);
    }
    return float2(sqrt(first),sqrt(second)-sqrt(first));
}
// Stable frost grains with a pixel-sized footprint. Jittered sites avoid a
// visible grid; the antialiasing footprint keeps small grains from strobing.
float iceGrainsFX(float2 p,float footprint) {
    float2 cell=floor(p),f=fract(p);
    float sum=0;
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x) {
        float2 offset=float2(x,y),id=cell+offset;
        float seed=id.x*37.17+id.y*113.71;
        float2 delta=offset+float2(hashFX(seed),hashFX(seed+31.7))-f;
        float size=0.065+hashFX(seed+13.2)*0.095;
        float width2=size*size+footprint*footprint*0.22;
        sum+=exp(-dot(delta,delta)/width2)*(size*size/width2)
            *(0.4+hashFX(seed+6.1)*0.6);
    }
    return sum;
}
float4 iceFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters,float pixelFootprint) {
    float R=max(1.0,u.ball.z),t=u.viewport.z;
    float2 q=(pixel-u.ball.xy)/R;
    float r=length(q);
    float mask=smoothstep(0.94,1.025,r);
    float noise=fireFBM3(float3(q*3.1,t*0.27));
    float fine=fireNoise3(float3(q*14.0,t*0.35));
    float edgeRadius=1.055+(noise-0.5)*0.23;
    float edge=lineFX(r-edgeRadius,0.026)*(0.25+0.75*smoothstep(0.30,0.65,noise));
    float sheath=exp(-pow((r-1.08)/0.14,2.0));
    float2 cell=iceCellFX(q*7.3+(noise-0.5)*0.8);
    float cracks=(1-smoothstep(0.018,0.085,cell.y));
    float facets=cracks*exp(-pow((r-1.10)/0.24,2.0))*(0.45+noise*0.7);
    float frost=pow(saturate((fine-0.44)*2.5),2.0)*sheath;
    // Wispy cold air immediately outside the skin. Its density varies rather
    // than creating a solid blue disk or a regularly spaced crown of spikes.
    float ridge=fireRidge3(float3(q*2.5+float2(0,t*0.5),t*0.32));
    float wisps=pow(saturate((ridge-0.43)*2.3),2.2)
        *exp(-pow((r-1.20)/0.38,2.0));
    float halo=exp(-pow(max(0.0,r-1.04)/0.50,2.0));
    // A broad, curling cloud of frost follows historical ball positions. The
    // old two luminous guide-lines are gone: light comes from dense grains and
    // turbulent sheets, with a much softer cold-air body between them.
    float S=max(16.0,min(u.viewport.x,u.viewport.y)*0.055);
    float2 world=pixel/S;
    float3 flowP=float3(world*1.15+float2(0,-t*0.55),t*0.22);
    float2 warp=float2(fireFBM3(flowP),fireFBM3(flowP+float3(9.3,-4.7,2.1)))-0.5;
    float2 flowingQ=q+warp*0.85;
    float sheets=0,cloud=0;
    for(uint i=1;i<=21;++i) {
        float age=float(i)*0.035,prevAge=age-0.035;
        float4 a=wakeEmitterFX(prevAge,emitters),b=wakeEmitterFX(age,emitters);
        if(a.w<=0 || b.w<=0)continue;
        float2 segment=(b.xy-a.xy)/R;
        float travel=length(segment);
        if(travel<0.008 || travel>4.0)continue;
        float2 normal=float2(-segment.y,segment.x)/travel;
        float fade=pow(saturate(1-age/0.78),1.35)*smoothstep(0.008,0.09,travel);
        float2 A=(a.xy-u.ball.xy)/R,B=(b.xy-u.ball.xy)/R;
        A.y+=prevAge*prevAge*1.2;B.y+=age*age*1.2;
        for(uint lane=0;lane<2;++lane) {
            float side=lane==0?-1.0:1.0,phase=float(lane)*2.8;
            float oa=side*(0.65+(0.25+prevAge*0.7)*sin(prevAge*12-t*0.85+phase));
            float ob=side*(0.65+(0.25+age*0.7)*sin(age*12-t*0.85+phase));
            float d=segmentDistanceFX(flowingQ,A+normal*oa,B+normal*ob);
            float width=0.19+age*0.37;
            sheets=max(sheets,lineFX(d,width)*fade);
        }
        float d=segmentDistanceFX(flowingQ,A,B);
        cloud=max(cloud,lineFX(d,0.8+age*0.65)*fade);
    }
    // Cold flame: elongated, nested turbulence pulls the blue material into
    // irregular wisps. No orbit, polar arc or repeated band drives the shape.
    float2 lean=u.motion.xy*0.065;
    float leanLength=length(lean);
    if(leanLength>0.60)lean*=0.60/leanLength;
    float2 flow=normalize(float2(0.10,-1.0)-lean);
    float2 side=float2(-flow.y,flow.x);
    float3 P=float3(dot(world,side)*2.8,dot(world,flow)*0.85-t*1.1,t*0.24);
    float2 roll=float2(fireFBM3(P*float3(0.58,0.66,1)+float3(3.7,8.1,0)),
                      fireFBM3(P*float3(0.63,0.55,1)+float3(-7.3,2.1,4.5)))-0.5;
    float3 sheetP=P+float3(roll*2.6,0);
    float density=fireFBM3(sheetP);
    float fineFold=fireRidge3(sheetP*float3(2.0,1.5,1)+float3(roll*2.1,5.7));
    float veins=exp(-pow((density-0.49)/0.028,2.0))
        +exp(-pow((density-0.63)/0.018,2.0))*0.48;
    veins*=0.30+0.70*smoothstep(0.43,0.87,fineFold);
    float fieldBody=smoothstep(0.29,0.64,density);
    // The previous wake remains broad and soft, with pale icy material inside
    // it. Grains are a restrained finish, not the main luminous surface.
    float wakeEnvelope=max(sheets,cloud*0.32);
    float nearSkin=exp(-pow((r-1.16)/0.32,2.0));
    float2 plumeQ=q-flow*1.13+warp*0.30;
    float plume=exp(-pow(dot(plumeQ,side)/0.67,2.0)
                    -pow(dot(plumeQ,flow)/0.70,2.0));
    float headEnvelope=max(nearSkin,plume*0.72);
    float filmEnvelope=max(headEnvelope,wakeEnvelope);
    float icyFilm=filmEnvelope*fieldBody;
    float icyEdges=filmEnvelope*veins;
    float icyFolds=filmEnvelope*pow(smoothstep(0.50,0.91,fineFold),2.0);
    float mist=cloud*smoothstep(0.32,0.69,density);
    float2 grainP=(world+warp*0.35+float2(0,-t*0.32))*14.0;
    float grains=iceGrainsFX(grainP,pixelFootprint/S*14.0);
    float grainEnvelope=sheets*0.85+cloud*0.20+sheath*0.35+wisps*0.25;
    float snow=grains*grainEnvelope*0.75;
    float3 blue=float3(0.035,0.45,1.65),cyan=float3(0.22,1.55,2.65);
    float3 white=float3(2.15,3.15,3.75);
    float3 color=blue*(halo*0.075+sheath*0.22+mist*0.09+icyFilm*0.27)
        +cyan*(facets*0.42+wisps*0.30+frost*0.12+icyFilm*0.36+icyFolds*0.54)
        +white*(edge*0.34+facets*0.22+frost*0.14+snow*0.85+icyEdges*0.55);
    float alpha=saturate(edge*0.32+facets*0.24+sheath*0.12+wisps*0.10
        +frost*0.09+mist*0.035+icyFilm*0.17+icyFolds*0.10+icyEdges*0.25+snow*0.25);
    return float4(color*mask,alpha*mask);
}

// ---------------------------------------------------------------------------
// Shadow: heavy dark smoke. Puffs are released along the recorded path, rise
// slowly and swell; the volume is domain-warped FBM that curls with time.
// Purple light catches the curl edges and glows around the ball.
float4 shadowFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters) {
    float R=max(1.0,u.ball.z),t=u.viewport.z;
    float2 q=(pixel-u.ball.xy)/R;
    float r=length(q);
    float2 w=pixel/R;
    float2 qe=float2(q.x,q.y*0.7+0.4);
    float envelope=exp(-pow(max(0.0,length(qe)-0.9)/2.3,2.0))*0.8;
    for(uint i=1;i<32;++i) {
        float4 e=emitters[i];
        if(e.w<=0)continue;
        float age=float(i)*0.025,life=age/0.8;
        float2 d=(pixel-e.xy)/R+float2(sin(t*0.9+age*2.4)*age*0.8,age*3.0+age*age*2.5);
        d.y*=0.8;
        float rad=1.5+age*2.6;
        envelope+=exp(-dot(d,d)/(rad*rad))*(1-life)*0.3;
    }
    envelope=1-exp(-envelope*1.4);
    if(envelope<0.02 && r>1.2)return 0;
    // Curling smoke: warp the lookup with a rotating eddy field.
    float3 P=float3(w*0.75,t*0.18);
    float2 warp=float2(fireFBM3(P+float3(2.0,9.0,0.0)),fireFBM3(P+float3(-6.0,3.0,4.0)))-0.5;
    float ang=t*0.35;
    float2 rw=float2(warp.x*cos(ang)-warp.y*sin(ang),warp.x*sin(ang)+warp.y*cos(ang));
    float3 S=float3(w*1.1+rw*2.6+float2(0,t*0.5),t*0.22);
    float smoke=fireFBM3(S);
    float detail=fireFBM3(S*2.3+float3(5.0,1.0,3.0));
    float density=envelope*smoothstep(0.24,0.6,smoke*0.65+detail*0.45);
    density=saturate(density*1.6);
    // Edge light: ridges of the same field, strongest near the ball.
    float ridge=fireRidge3(S*1.4+float3(1.0,2.0,7.0));
    float edgeLight=pow(saturate((ridge-0.5)/0.5),3.0)*density*(0.35+0.65*exp(-max(0.0,r-1.0)*0.6));
    float heat=exp(-pow(max(0.0,r-1.0)/0.9,2.0));
    float3 ink=float3(0.035,0.012,0.06),purple=float3(0.75,0.12,1.3),violet=float3(0.3,0.05,0.7);
    // Billow edges catch grey ambient light; violet only near the ball.
    float3 grey=float3(0.26,0.24,0.32);
    float3 color=ink*density+grey*edgeLight*0.5+purple*edgeLight*0.45*exp(-max(0.0,r-1.0)*0.5)+violet*heat*density*0.45;
    float alpha=saturate(density*0.95+edgeLight*0.3);
    // Violet glow hugging the ball rim.
    float corona=exp(-pow((r-1.04)/0.14,2.0))*(0.5+0.5*ridge);
    color+=purple*corona*0.35;alpha=saturate(alpha+corona*0.4);
    float mask=smoothstep(0.9,1.04,r);
    return float4(color*mask,alpha*mask);
}

float4 distinctMaterialFX(float2 pixel, constant FXUniforms &u,
                          constant float4 *emitters, texture3d<float> noise) {
    float radius=max(1.0,u.ball.z), t=u.viewport.z, style=u.motion.w;
    float2 q=(pixel-u.ball.xy)/radius;
    float r=length(q), angle=atan2(q.y,q.x);
    float3 color=0; float alpha=0;
    float mask=smoothstep(0.93,1.085,r);
    float hit=saturate(u.motion.z);
    float3 world=float3(pixel/radius*3.3,t*0.45);
    float grain=fbmFX(noise,world);
    float fine=fbmFX(noise,world*2.17+float3(grain*4,0,t*0.2));

    if(style==2) {
        // Faceted frost, with uneven spires breaking the silhouette. The core
        // is icy glass, not the fire volume recolored blue.
        float sector=floor((angle+3.14159)*19.0);
        float fracture=hashFX(sector*7.13);
        float rimRadius=1.08+fracture*0.24+sin(angle*7+t)*0.04;
        float rim=lineFX(r-rimRadius,0.060);
        float edge=pow(saturate(cos(angle*19)),18.0);
        float crystal=edge*exp(-pow((r-1.25-fracture*0.45)*3.2,2.0));
        float mist=exp(-pow((r-1.48)*2.0,2.0))*smoothstep(0.3,0.72,grain);
        color=float3(0.13,1.4,3.0)*rim+float3(1.2,2.6,3.6)*crystal*(0.85+hit);
        color+=float3(0.04,0.42,0.95)*mist;
    } else if(style==3) {
        // Broad asymmetric green whips. Each arc has a tapering head, a hot
        // core, and a soft jacket; they do not form an atomic sticker.
        for(uint j=0;j<2;++j) {
            float lane=float(j), tilt=-0.2+lane*0.6;
            float c=cos(tilt),s=sin(tilt);
            float2 p=float2(q.x*c+q.y*s,-q.x*s+q.y*c);
            float a=atan2(p.y/0.79,p.x);
            float rad=1.27+lane*0.32+0.15*sin(a*2-t*1.8+lane);
            float d=abs(length(p/float2(1,0.79))-rad);
            float sweep=pow(0.5+0.5*cos(a-t*2.7-lane*2),0.65);
            float gate=smoothstep(0.08,0.55,sweep)*(0.35+0.65*sweep);
            color+=filamentFX(d,0.062+lane*0.008,float3(0.015,3.7,0.5),0.62)*gate;
        }
        color+=float3(0.01,0.6,0.09)*exp(-pow((r-1.35)*2.2,2.0))*0.45;
        // Detached loops are born at recorded ball positions, then fall and
        // open out. This is the reference's loose green coil beside the foot,
        // rather than a full-body helix or a jagged polyline behind the ball.
        for(uint j=0;j<3;++j) {
            float age=fract(t/0.26)*0.26+float(j)*0.26;
            if(age>t)continue;
            float4 birth=wakeEmitterFX(age,emitters);
            if(birth.w<=0)continue;
            float birthTime=t-age;
            float2 p=(pixel-birth.xy)/radius-float2(sin(birthTime*3)*age*1.3,age*4.8);
            float tilt=-0.3+sin(birthTime*2)*0.22;
            float c=cos(tilt),s=sin(tilt);
            p=float2(p.x*c+p.y*s,-p.x*s+p.y*c);
            float flatten=0.53+age*0.18;
            float a=atan2(p.y/flatten,p.x);
            float d=abs(length(p/float2(1,flatten))-(1.24+age*1.1));
            float fade=smoothstep(0.0,0.065,age)*pow(saturate(1-age/0.8),0.9);
            float gate=0.25+0.75*pow(0.5+0.5*cos(a-birthTime*4),0.7);
            color+=filamentFX(d,0.060,float3(0.015,3.8,0.52),0.45)*fade*gate*0.9;
        }
    } else if(style==4) {
        // An inclined vortex of turbulent plasma, with blue shadow and pink
        // hot dust. The outer arms dissolve into nebula instead of clean rings.
        float2 p=float2(q.x+q.y*0.24,q.y*1.13);
        float rr=length(p),a=atan2(p.y,p.x);
        float twist=a*3-rr*4.5+t*1.8+grain*2.7;
        float arms=pow(0.5+0.5*cos(twist),9.0);
        float envelope=smoothstep(0.88,1.12,rr)*exp(-max(0.0,rr-1.12)*1.15);
        float dust=smoothstep(0.25,0.72,fine);
        color=(float3(1.7,0.08,3.9)*arms+float3(0.3,0.03,1.1)*dust)*envelope;
        color+=float3(3.2,0.7,2.8)*pow(arms,2.0)*envelope*dust*0.9;
    } else if(style==5) {
        // Uneven discharge paths leave the ball tangentially, then split.
        // Arc lengths, directions and branches vary independently.
        float bolt=0,glow=0,branch=0,whiteCore=0;
        for(uint j=0;j<4;++j) {
            float id=float(j),seed=id*43.1;
            float a=id*2.39996+t*0.10;
            float2 direction=float2(cos(a),sin(a)),side=float2(-direction.y,direction.x);
            float2 previous=direction*1.03;
            float reach=0.28+hashFX(seed+2)*0.34;
            for(uint k=1;k<=8;++k) {
                float step=float(k),jitter=(animatedHashFX(seed+step*7,t*14)-0.5)*(0.45+step*0.05);
                float2 next=direction*(1.03+step*reach)+side*(jitter+sin(step*0.65+id)*step*0.12);
                float d=segmentDistanceFX(q,previous,next);
                float fade=1-step*0.055;
                bolt=max(bolt,lineFX(d,0.027)*fade);glow=max(glow,lineFX(d,0.12)*fade);
                whiteCore=max(whiteCore,lineFX(d,0.012)*fade);
                if(k==3 || k==5 || k==7) {
                    float sign=hashFX(seed+step)>0.5?1.0:-1.0;
                    float2 fork=next+direction*0.28+side*sign*(0.35+hashFX(seed+step*2)*0.65);
                    float2 tip=fork+direction*0.44-side*sign*0.12;
                    branch=max(branch,lineFX(segmentDistanceFX(q,next,fork),0.016)*fade);
                    branch=max(branch,lineFX(segmentDistanceFX(q,fork,tip),0.010)*fade);
                }
                previous=next;
            }
        }
        float flash=0.65+0.35*pow(sin(t*27),2.0);
        color=(float3(5.5,3.3,0.17)*bolt+float3(2.6,1.1,0.01)*(glow*0.36+branch))*flash;
        color+=float3(4.0,3.7,1.8)*whiteCore*flash;
        float corona=lineFX(r-(1.12+sin(angle*13+sin(angle*7+t*19)*2.0)*0.055+(grain-0.5)*0.20),0.045);
        color+=float3(3.8,1.9,0.08)*corona*(0.8+hit);
    } else if(style==6) {
        // Silver silk sweeps share a center but have separate open ends.
        for(uint j=0;j<4;++j) {
            float lane=float(j),a=angle+t*(0.7+lane*0.12)+lane*1.3;
            float rad=1.19+lane*0.20+sin(angle*2+t+lane)*0.11;
            float gate=pow(0.5+0.5*cos(a),1.4);
            color+=filamentFX(abs(r-rad),0.025+gate*0.035,float3(1.0,1.35,1.6),0.28)*gate;
        }
        color+=float3(0.27,0.42,0.55)*exp(-pow((r-1.38)*2.2,2.0))*0.20;
    } else if(style==7) {
        float curl=sin(angle*3-r*5.5+t*1.6+grain*5);
        float shell=exp(-pow((r-1.48)*1.8,2.0));
        float smoke=shell*smoothstep(0.25,0.66,grain)*(0.5+fine);
        float edge=pow(saturate(curl),9.0)*smoke;
        color=float3(0.025,0.007,0.047)*smoke+float3(0.56,0.08,0.94)*edge;
        alpha=smoke*1.35;
    } else if(style==8) {
        // One open spectral curl, with seven offset bands. No white additive
        // filament: the colors must survive the bright turns.
        float a=atan2(q.y/0.9,q.x);
        float gate=0.22+0.78*pow(0.5+0.5*cos(a-t*2),0.8);
        for(uint j=0;j<7;++j) {
            float lane=float(j),rad=1.18+lane*0.080+0.10*sin(a*2+t*1.4);
            float d=abs(length(q/float2(1,0.9))-rad);
            color+=rainbowFX(lane/7.0)*2.8*(lineFX(d,0.039)+lineFX(d,0.12)*0.11)*gate;
        }
    } else if(style==9) {
        float cellSize=0.27;
        float2 cell=floor(q/cellSize),middle=(cell+0.5)*cellSize;
        float rr=length(middle);
        float band=smoothstep(0.92,1.14,rr)*(1-smoothstep(1.55,2.2,rr));
        float pick=hashFX(cell.x*13+cell.y*37);
        float2 uv=abs(q-middle)/cellSize;
        float block=1-smoothstep(0.31,0.40,max(uv.x,uv.y));
        float pulse=0.4+0.6*pow(sin(t*3+pick*8),2.0);
        color=mix(float3(0.015,0.9,2.0),float3(0.5,2.8,3.4),pick)*band*step(0.43,pick)*block*pulse;
    } else if(style==10) {
        // A broken organic eddy and two winding stems. Leaves carry most of
        // the silhouette; the green light stays close to the ball and wake.
        float swirl=angle+r*2.6-t*1.7+grain*2;
        float leafLight=pow(saturate(sin(swirl*2)),6.0);
        float envelope=exp(-pow((r-1.38)*1.65,2.0));
        color=float3(0.22,1.6,0.035)*envelope*(leafLight*0.75+fine*0.10);
        for(uint j=0;j<2;++j) {
            float lane=float(j),rad=1.20+lane*0.3+0.15*sin(angle*3+t+lane*2);
            float gate=pow(0.5+0.5*cos(angle-t*1.3-lane*3),2.0);
            color+=float3(0.35,2.0,0.055)*lineFX(r-rad,0.027)*gate;
        }
    }

    // The only extended emitters are actual prior ball positions. Finite-age
    // material drifts after birth, leaving a wake through the space the ball
    // visited. No person box, ground line or stationary body field is used.
    float ribbon[7]={0,0,0,0,0,0,0};
    float ribbonGlow[7]={0,0,0,0,0,0,0};
    float density=0,edgeDensity=0;
    for(uint i=0;i<64;++i) {
        float ageA=float(i)*0.0125,ageB=ageA+0.0125;
        float4 a=wakeEmitterFX(ageA,emitters),b=wakeEmitterFX(ageB,emitters);
        if(a.w<=0 || b.w<=0)continue;
        float age=(ageA+ageB)*0.5,life=age/0.8;
        float fade=pow(1-life,1.2);
        float2 pa=(a.xy-u.ball.xy)/radius,pb=(b.xy-u.ball.xy)/radius;
        // Element-specific transport stretches the actual ball wake. The
        // younger, brighter head remains attached to the ball; old material
        // falls, rises or curls from its recorded birth position.
        if(style==3 || style==8 || style==6 || style==10) {
            float rise=style==3?6.4:style==8?6.8:style==6?-4.0:-3.8;
            float bend=style==8?9.0:0.0;
            pa+=float2(sin((t-ageA)*3.2+ageA*bend)*ageA*(style==8?2.8:1.8),ageA*rise);
            pb+=float2(sin((t-ageB)*3.2+ageB*bend)*ageB*(style==8?2.8:1.8),ageB*rise);
        }
        float2 tangent=pa-pb;
        tangent=length(tangent)>0.015?normalize(tangent):float2(0,-1);
        float2 normal=float2(-tangent.y,tangent.x);
        if(style==2 || style==4 || style==7) {
            float2 drift=float2(sin((t-age)*2.3+age*5)*age*1.7,age*(style==2?2.5:style==4?-5.0:-6.5));
            float2 p=q-(pa+pb)*0.5-drift;
            float spread=style==2?0.6+age*1.0:1.0+age*2.1;
            float cloud=exp(-dot(p,p)/(spread*spread))*fade;
            float n=fbmFX(noise,float3((pixel/radius-drift)*3.0,t*0.4-age));
            density+=cloud*smoothstep(0.28,0.69,n)*0.085;
            edgeDensity+=cloud*pow(saturate(1-abs(n-fine-0.06)*7),5.0)*0.0375;
        } else if(style!=9 && style!=3) {
            uint lanes=style==8?7:style==6?3:style==3?2:style==10?2:1;
            for(uint j=0;j<lanes;++j) {
                float lane=float(j),birthA=t-ageA,birthB=t-ageB;
                float2 oa,ob;
                float width;
                if(style==3) {
                    oa=orbitFX(birthA*10+lane*2.7,1.05+age*1.8,0.70,0.40);
                    ob=orbitFX(birthB*10+lane*2.7,1.05+(age+0.0125)*1.8,0.70,0.40);
                    width=0.072+fade*0.035;
                } else if(style==8) {
                    float offset=(lane-3)*0.11;
                    oa=normal*(offset+sin(birthA*5.5)*0.6);
                    ob=normal*(offset+sin(birthB*5.5)*0.6);
                    width=0.042;
                } else if(style==5) {
                    oa=normal*(animatedHashFX(float(i)*7.1,t*15)-0.5)*0.8;
                    ob=normal*(animatedHashFX(float(i+1)*7.1,t*15)-0.5)*0.8;
                    width=0.031;
                } else if(style==10) {
                    oa=normal*(sin(birthA*6+lane*3)*0.75+sin(birthA*13)*0.16);
                    ob=normal*(sin(birthB*6+lane*3)*0.75+sin(birthB*13)*0.16);
                    width=0.035;
                } else {
                    oa=normal*((lane-1)*0.19+sin(birthA*4+lane)*0.3);
                    ob=normal*((lane-1)*0.19+sin(birthB*4+lane)*0.3);
                    width=0.036+age*0.035;
                }
                float d=segmentDistanceFX(q,pa+oa,pb+ob);
                ribbon[j]=max(ribbon[j],lineFX(d,width)*fade);
                ribbonGlow[j]=max(ribbonGlow[j],lineFX(d,width*3.8)*fade);
            }
        }
    }
    if(style==2) {
        color+=float3(0.09,0.63,1.1)*density*0.65+float3(0.3,1.0,1.6)*edgeDensity*0.6;
    } else if(style==4) {
        color+=mix(float3(0.24,0.035,1.1),float3(1.3,0.07,2.1),grain)*density;
        color+=float3(1.6,0.25,2.2)*edgeDensity;
    } else if(style==7) {
        color+=float3(0.030,0.009,0.055)*density+float3(0.48,0.075,0.82)*edgeDensity;
        alpha+=density*1.5;
    } else {
        uint lanes=style==8?7:style==6?3:style==3?2:style==10?2:1;
        for(uint j=0;j<lanes;++j) {
            float3 tint=style==8?rainbowFX(float(j)/7.0)*2.8:style==3?float3(0.015,3.5,0.45)
                :style==6?float3(1.1,1.4,1.7):style==5?float3(4,2.0,0.08):float3(0.3,1.8,0.04);
            color+=tint*(ribbon[j]+ribbonGlow[j]*(style==8?0.13:0.24));
        }
    }
    return float4(color*mask,alpha*mask);
}

#include "EffectStudies.h"
#include "ShotTrails.h"

kernel void fxEmission(texture2d<half,access::write> out [[texture(0)]],
                       texture3d<float> noise [[texture(1)]],
                       constant FXUniforms &u [[buffer(0)]], constant float4 *trail [[buffer(1)]],
                       constant float4 *emitters [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x>=out.get_width() || gid.y>=out.get_height()) return;
    float2 pixel = u.region.xy + (float2(gid)+0.5)/float2(out.get_width(),out.get_height()) * u.region.zw;
    float4 result = 0;
    if (u.control.y > 0.5) {
        float2 p = (pixel-u.ball.xy) / u.ball.z;
        float age = u.control.z;
        float flash = exp(-max(0.0,age)*9.0);
        float halo = exp(-dot(p,p)*1.5) * (0.055+flash*0.14);
        float wave = exp(-pow((length(p)-0.7-age*2.5)*24,2.0)) * exp(-age*6) * 0.06;
        result = float4(u.tint.rgb*(halo+wave)*2.2,(halo+wave)*0.14);
    } else if (u.ball.w>0.005 && u.viewport.w>0.005 && u.motion.w>0.5) {
        result = u.motion.w>=20 ? shotTrailFX(pixel,u,trail,u.region.z/float(out.get_width()))
               : u.motion.w==1 ? proceduralFireFX(pixel,u,emitters,u.region.z/float(out.get_width()))
               : u.motion.w==11 ? labFlameFX(pixel,u,emitters,u.region.z/float(out.get_width()))
               : u.motion.w==12 ? glowTrailFX(pixel,u,emitters,u.region.z/float(out.get_width()))
               : u.motion.w==13 ? blueFlameFX(pixel,u,emitters,u.region.z/float(out.get_width()))
               : u.motion.w==14 ? emberWakeFX(pixel,u,emitters,u.region.z/float(out.get_width()))
               : u.motion.w==15 ? flameRibbonFX(pixel,u,emitters,u.region.z/float(out.get_width()))
               : u.motion.w==16 ? heatPulseFX(pixel,u,emitters,u.region.z/float(out.get_width()))
               : u.motion.w==5 ? electricFX(pixel,u,emitters)
               : u.motion.w==3 ? neonFX(pixel,u,emitters,u.region.z/float(out.get_width()))
               : u.motion.w==8 ? rainbowFX(pixel,u,emitters,u.region.z/float(out.get_width()))
               : u.motion.w==9 ? pixelFX(pixel,u,emitters)
               : u.motion.w==6 ? auraFX(pixel,u,emitters,u.region.z/float(out.get_width()))
               : u.motion.w==4 ? galaxyFX(pixel,u,emitters,u.region.z/float(out.get_width()))
               : u.motion.w==10 ? natureFX(pixel,u,emitters)
               : u.motion.w==2 ? iceFX(pixel,u,emitters,u.region.z/float(out.get_width()))
               : u.motion.w==7 ? shadowFX(pixel,u,emitters)
                               : distinctMaterialFX(pixel,u,emitters,noise);
        result *= u.ball.w * u.viewport.w;
    }
    out.write(half4(result),gid);
}

struct FXParticleOut { float4 position [[position]]; float2 uv; float3 color; float opacity; float kind [[flat]]; float2 ballOffset; float4 crystal [[flat]]; };
vertex FXParticleOut fxParticleVertex(uint vertexID [[vertex_id]], uint instance [[instance_id]],
                                     constant FXUniforms &u [[buffer(0)]], constant float4 *trail [[buffer(1)]],
                                     constant float4 *emitters [[buffer(2)]]) {
    constexpr float2 corners[6] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,-1),float2(1,1),float2(-1,1)};
    float id = float(instance), seed = id + u.control.w * 131;
    float2 corner = corners[vertexID];
    float2 center = u.ball.xy;
    float2 direction;
    float width, length, alpha;
    float3 color;
    float4 crystal=0; // stable shape seed, tumble phase, world rotation, shard/dust
    if (u.control.y>0.5) {
        float delay = hashFX(seed+5)*0.065;
        float age = max(0.0,u.control.z-delay);
        float angle = id * 2.39996323 + hashFX(seed+11)*0.26;
        direction = float2(cos(angle),sin(angle));
        float life = 0.46+hashFX(seed+7)*0.48;
        float progress = saturate(age/life);
        float travel = (0.58+hashFX(seed+3)*0.92)*u.ball.z;
        float eased = 1.0-exp(-progress*3.4);
        center += direction * (u.ball.z*0.47+travel*eased) * float2(1.1,0.87);
        bool bright = instance%9==0;
        width = bright ? 1.05+hashFX(seed+8)*0.7 : 0.35+hashFX(seed+9)*0.7;
        width *= u.ball.z/70;
        length = (bright?12.0:2.0+hashFX(seed+13)*5.0)*(1-progress)*u.ball.z/70;
        alpha = (1-smoothstep(0.18,1.0,progress))*smoothstep(0.0,0.025,age);
        color = mix(u.tint.rgb*3.0,float3(2.5,5.5,3.0),bright?0.7:0.15);
        if (u.control.z < 0 || u.control.z > 1.1) alpha=0;
    } else {
        float style=u.motion.w;
        float life=style==1?0.5+hashFX(seed+3)*0.7:style==2?0.64+hashFX(seed+3)*0.14:style==5?0.26+hashFX(seed+3)*0.3:0.48+hashFX(seed+3)*0.30;
        float clock=u.viewport.z/life+hashFX(seed+2);
        float age=fract(clock)*life;
        seed+=floor(clock)*37.13;
        float slot=clamp(age*40.0,0.0,31.0);
        uint index=uint(slot);
        float4 birth=mix(emitters[index],emitters[index+1],fract(slot));
        float2 inherited=(emitters[index].xy-emitters[index+1].xy)/0.025;
        float angle=hashFX(seed+11)*TAU;
        float2 radial=float2(cos(angle),sin(angle));
        center=birth.xy+radial*birth.z;
        center+=clamp(inherited,-u.ball.z*24.0,u.ball.z*24.0)*0.16*age;
        center+=float2(radial.x*age*1.8,-age*age*4.0)*birth.z;
        center+=float2(sin(age*4+seed)-sin(seed),cos(age*3+seed)-cos(seed))*birth.z*0.35;
        direction=normalize(radial*0.3+float2(0.1,-1.0-age*3));
        width=max(0.42,birth.z*(0.010+hashFX(seed+7)*0.012));
        length=width*(1.3+hashFX(seed+10)*2.0);
        alpha=smoothstep(0.0,0.055,age)*pow(saturate(1-age/life),1.6)*u.ball.w*u.viewport.w;
        if(style>1)alpha=smoothstep(0.0,0.045,age)*pow(saturate(1-age/life),0.85)*u.ball.w*u.viewport.w;
        if(emitters[index].w<=0 || emitters[index+1].w<=0)alpha=0;
        color=fireSpectrum(0.52+hashFX(seed+1)*0.25);
        if(style==1) {
            // Embers leave the hot sheath, ride the rising gas with turbulent
            // wobble, and flicker out. Every fourth one drifts far sideways.
            // Birth positions stay behind the ball.
            bool drifter=instance%4==0;
            float speed=2.4+hashFX(seed+21)*5.2;
            float lateral=(hashFX(seed+22)-0.5)*(drifter?6.0:2.4);
            float wobble=sin(age*6.0+seed*3.1)*0.3+sin(age*11.0+seed)*0.1;
            float2 carried=clamp(inherited,-u.ball.z*24.0,u.ball.z*24.0)*0.12;
            center=birth.xy+radial*birth.z*1.1;
            center+=carried*age;
            center.y-=(speed*age+1.6*age*age)*birth.z;
            center.x+=(lateral*age+wobble+radial.x*age*0.8)*birth.z;
            // Sparks streak along their own velocity, as if over a 1/60 s shutter.
            float wobbleRate=cos(age*6.0+seed*3.1)*1.8+cos(age*11.0+seed)*1.1;
            float2 velocity=carried+float2(lateral+wobbleRate+radial.x*0.8,-(speed+3.2*age))*birth.z;
            float pace=metal::length(velocity);
            direction=pace>0.001?velocity/pace:float2(0,-1);
            width=max(0.8,birth.z*(0.022+hashFX(seed+7)*0.026));
            length=width+pace/120.0; // half extent
            color=fireSpectrum(0.5+hashFX(seed+1)*0.38)*2.2;
            alpha*=1.8*(0.5+0.5*pow(sin(age*30.0+seed*5.0),2.0));
            if(radial.y>0.4)alpha*=0.3; // few embers escape downward
        } else if(style==2) {
            // Crystal fragments leave the recorded birth position. Air drag
            // slows the scatter while gravity bends it down; the ball can move on.
            bool chip=instance%4==0;
            float spread=1.4+hashFX(seed+19)*2.1;
            float dragTravel=(1-exp(-age*1.8))/1.8;
            float2 carried=clamp(inherited,-birth.z*18.0,birth.z*18.0)*0.055;
            center=birth.xy+radial*birth.z*1.08;
            center+=(carried+radial*birth.z*spread)*dragTravel;
            center.y+=birth.z*(-0.35*age+3.1*age*age);
            float spin=(hashFX(seed+15)>0.5?1.0:-1.0)*(1.1+hashFX(seed+14)*2.3);
            float tumble=angle+age*spin;
            float tilt=seed*1.7+age*(2.2+hashFX(seed+16)*2.4);
            direction=float2(cos(tumble),sin(tumble));
            width=birth.z*(chip?0.10+hashFX(seed+7)*0.09:0.012+hashFX(seed+7)*0.020);
            length=width*(chip?1.45+hashFX(seed+10)*0.65:1.0+hashFX(seed+10)*0.65);
            width*=0.55+0.45*abs(cos(tilt));
            color=chip?float3(0.10,1.05,2.8):float3(0.50,1.8,3.2);
            // Keep a readable rim through mid-flight, then fade before recycling.
            alpha=smoothstep(0.0,0.045,age)*(1-smoothstep(0.40,1.0,age/life))*u.ball.w*u.viewport.w;
            if(emitters[index].w<=0 || emitters[index+1].w<=0)alpha=0;
            alpha*=chip?1.0:0.52;
            crystal=float4(hashFX(seed+24),tilt,tumble,chip?1.0:0.0);
        } else if(style==3) {
            // Sparse charged flecks peel away from real birth positions.
            // A few larger mint glints punctuate the fine green dust.
            bool glint=instance%7==0;
            center+=radial*age*birth.z*2.8;
            width=max(0.65,birth.z*(glint?0.065:0.025+hashFX(seed+4)*0.018));
            length=width; direction=float2(0,1);
            color=glint?float3(2.3,4.0,2.2):float3(0.08,2.6,0.34);
            alpha*=(glint?1.2:0.8)*(0.55+0.45*pow(sin(age*12.0+seed),2.0));
        } else if(style==4) {
            // Blue/violet dust scatters independently of the moving head.
            // Larger white-core stars twinkle at different phases, not in unison.
            bool glint=instance%11==0;
            float turn=angle+age*(1.5+hashFX(seed+9)*2.0);
            float spread=1.1+age*(2.2+hashFX(seed+19)*2.6);
            center=birth.xy+float2(cos(turn),sin(turn)*0.8)*birth.z*spread;
            center+=clamp(inherited,-birth.z*20.0,birth.z*20.0)*0.045*age;
            center.y-=age*(1.2+age*0.8)*birth.z;
            direction=float2(cos(angle),sin(angle));
            width=max(glint?1.25:0.7,birth.z*(glint?0.16+hashFX(seed+7)*0.09:0.025+hashFX(seed+4)*0.035));length=width;
            float palette=hashFX(seed+4);
            color=palette<0.45?float3(0.20,1.3,4.7):palette<0.82?float3(1.5,0.35,4.5):float3(3.8,0.50,3.0);
            float twinkle=0.4+0.6*pow(0.5+0.5*sin(age*(13+hashFX(seed+8)*12)+seed),4.0);
            alpha*=(glint?1.5:1.0)*twinkle;
        } else if(style==5) {
            // Sparks: fast radial streaks that arc under gravity and strobe.
            float speed=3.0+hashFX(seed+21)*6.0;
            float2 v=radial*speed;
            center=birth.xy+radial*birth.z*1.05+(v*age+float2(0,2.5*age*age))*birth.z;
            center+=clamp(inherited,-u.ball.z*24.0,u.ball.z*24.0)*0.1*age;
            direction=normalize(v+float2(0,5.0*age));
            width=max(0.6,birth.z*(0.016+hashFX(seed+7)*0.02));
            length=width*(4.0+hashFX(seed+10)*5.0);
            color=mix(float3(5.0,3.0,0.2),float3(6.5,5.6,2.6),hashFX(seed+1));
            alpha*=1.4*(0.5+0.5*pow(sin(age*45+seed),2.0));
        } else if(style==6) {
            // Rare pearl flecks, with neither Galaxy's star field nor Neon sparks.
            center=birth.xy+radial*birth.z*(0.90+age*0.45);
            center.y-=age*birth.z*1.6;
            width=max(0.40,birth.z*(0.018+hashFX(seed+6)*0.020));length=width;
            color=float3(1.8,2.05,2.35);
            alpha*=0.20*(0.5+0.5*pow(sin(age*8.0+seed),2.0));
        } else if(style==7) {
            // Smoke puffs: slow, swelling, drifting up and out.
            center+=radial*birth.z*age*1.4;
            center.y-=birth.z*(age*1.8+age*age*1.5);
            width=birth.z*(0.45+age*1.3);length=width*1.3;
            color=float3(0.03,0.008,0.055);alpha*=0.55;
        } else if(style==8) {
            // Small spectral sparks shed from their historical birth position.
            // Their hue is stable over a lifetime; the trail does not blink
            // through all colours as a group or reuse Galaxy's star shapes.
            float spin=angle+age*(1.4+hashFX(seed+19)*1.8);
            float2 spread=float2(cos(spin),sin(spin)*0.7);
            float2 carried=clamp(inherited,-birth.z*18.0,birth.z*18.0)*0.10;
            center=birth.xy+spread*birth.z*(1.05+age*2.8)+carried*age;
            center.y+=birth.z*(age*0.45+age*age*1.1);
            float2 v=carried+spread*birth.z*2.8+float2(0,birth.z*(0.45+2.2*age));
            float speed=metal::length(v);direction=speed>0.001?v/speed:float2(0,1);
            width=max(0.55,birth.z*(0.026+hashFX(seed+7)*0.030));
            length=width*(1.7+hashFX(seed+10)*1.7)+speed/170.0;
            color=rainbowFX(hashFX(seed+1)*0.84)*4.1;
            alpha*=1.10*(0.50+0.50*pow(sin(age*10.0+seed),2.0));
        } else if(style==9) {
            float cell=max(2.0,birth.z*0.26);
            center=birth.xy+radial*birth.z*(1.0+age*3.7)+float2(0,-floor(age*9)*cell);
            center=(floor(center/cell)+0.5)*cell;
            direction=float2(0,1);width=cell*(0.30+hashFX(seed+4)*0.30);length=width;
            color=mix(float3(0.015,1.0,2.0),float3(0.6,2.5,3.0),hashFX(seed+6));
            alpha*=1-smoothstep(0.65,1.0,age/life);
        } else if(style==10) {
            // Leaves: large, tumbling, carried around the ball on the swirl
            // and then out and up. Every sixth sprite is a small green glint.
            bool glint=instance%6==0;
            float orbit=angle+age*(2.0+hashFX(seed+9)*1.5);
            float reach=1.4+age*(3.5+hashFX(seed+4)*4.5);
            center=birth.xy+float2(cos(orbit),sin(orbit)*0.7)*birth.z*reach;
            center+=float2((sin(age*5+seed)-sin(seed))*0.6,-age*age*2.5)*birth.z;
            center+=clamp(inherited,-u.ball.z*24.0,u.ball.z*24.0)*0.08*age;
            float spin=seed*3.0+age*(3.0+hashFX(seed+12)*4.0)*(hashFX(seed+13)>0.5?1.0:-1.0);
            direction=float2(cos(spin),sin(spin));
            if(glint) {
                width=birth.z*(0.05+hashFX(seed+5)*0.05);length=width;
                color=float3(1.6,4.0,0.9);
                alpha*=1.2*pow(0.5+0.5*sin(age*16+seed),2.0);
            } else {
                float sizeK=0.6+hashFX(seed+5)*0.9;
                width=birth.z*0.30*sizeK*(0.35+0.65*abs(cos(age*4+seed)));
                length=birth.z*0.62*sizeK;
                float shade=hashFX(seed+4);
                color=shade<0.4?float3(0.07,0.55,0.03):shade<0.8?float3(0.22,1.0,0.08):float3(0.6,1.5,0.22);
                alpha*=2.2;
            }
        }
        if(style>=11 && style<=16) {
            // Fine, sparse flecks born on the measured path. Ember Wake uses
            // more and longer sparks; the other studies retain their clear form.
            bool ember=style==14, cool=style==12 || style==13;
            // Embers keep more of the ball's own motion, so they streak along its path.
            float2 carried=clamp(inherited,-birth.z*20.0,birth.z*20.0)*(ember?0.13:0.065);
            float2 drift=radial*birth.z*(ember?1.4:1.2)+float2(0,-birth.z*(ember?0.55:1.3));
            center=birth.xy+radial*birth.z*1.08+(carried+drift)*age;
            center.y-=birth.z*age*age*1.1;
            float2 v=carried+drift+float2(0,-birth.z*age*2.2);
            float speed=metal::length(v);
            direction=speed>0.001?v/speed:float2(0,-1);
            // Ember Wake's sparks are its body: bigger, longer, hotter streaks.
            width=max(0.45,birth.z*(ember?0.017+hashFX(seed+7)*0.02:0.011+hashFX(seed+7)*0.014));
            length=width*(ember?4.2:1.4)+speed/(ember?48.0:190.0);
            color=cool?float3(0.10,2.3,4.5):studyWarmFX((ember?0.56:0.44)+hashFX(seed+9)*0.42);
            alpha*= (ember?2.0:0.75)*(0.55+0.45*pow(sin(age*17+seed),2.0));
            if(style==12)alpha*=0.7;
        }
        if(style==0)alpha=0;
    }
    float2 perpendicular=float2(-direction.y,direction.x);
    // Ice needs space outside its silhouette for each fragment's own glow.
    float haloExtent=(u.control.y<0.5 && u.motion.w==2)?1.8:1.0;
    float2 p=center+(perpendicular*corner.x*width+direction*corner.y*max(width,length))*haloExtent;
    float2 uv=(p-u.region.xy)/u.region.zw;
    FXParticleOut out;
    out.position=float4(uv.x*2-1,1-uv.y*2,0,1);
    out.ballOffset=u.control.y>0.5?float2(2):(p-u.ball.xy)/max(1.0,u.ball.z);
    out.crystal=crystal;
    out.uv=corner*haloExtent;out.color=color;out.opacity=alpha;out.kind=u.control.y>0.5?0:u.motion.w;
    return out;
}
fragment half4 fxParticleFragment(FXParticleOut in [[stage_in]]) {
    float shape=exp(-in.uv.x*in.uv.x*5.0)*pow(saturate(1-abs(in.uv.y)),0.6);
    if(in.kind==1){
        // Soft glowing ember with a small bright core.
        float d2=dot(in.uv,in.uv);
        shape=exp(-d2*4.5)*0.55+exp(-d2*16.0)*0.9;
    } else if(in.kind==2){
        float2 p=in.uv;
        float variation=in.crystal.x;
        float tilt=in.crystal.y;
        float turn=in.crystal.z;
        float ballMask=smoothstep(0.95,1.06,length(in.ballOffset));
        if(in.crystal.w<0.5) {
            // Tiny frost specks support the larger glass pieces without looking
            // like another population of identical diamond confetti.
            float d2=dot(p,p);
            float core=exp(-d2*12.0),halo=exp(-d2*2.5);
            float glint=0.65+0.35*pow(abs(cos(tilt)),6.0);
            float a=in.opacity*ballMask;
            return half4(half3((float3(2.7,3.8,4.3)*core+in.color*halo*0.20)*a*glint),half((core*0.65+halo*0.12)*a));
        }
        // Six unequal faces form a chipped prism, with an offset internal peak.
        // Shape is fixed for the fragment's life; only its lighting/tilt changes.
        float skew=(variation-0.5)*0.30;
        float cut=hashFX(variation*137.0+4.0);
        float shoulder=hashFX(variation*137.0+9.0);
        float2 v[6]={float2(-0.36+skew,-0.92),float2(0.32+cut*0.34,-0.66+shoulder*0.25),
                     float2(0.54+shoulder*0.22,0.06+cut*0.24),float2(-0.08+cut*0.37,0.90),
                     float2(-0.42-shoulder*0.20,0.30+cut*0.24),float2(-0.70+cut*0.12,-0.48+shoulder*0.23)};
        float2 peak=float2(skew*0.8,0.02+(variation-0.5)*0.32);
        float sd=-100.0;
        float seams=0.0,faceLight=0.0,rimLight=0.0;
        float2 lightDirection=float2(cos(turn+0.65),sin(turn+0.65));
        for(uint i=0;i<6;i++) {
            float2 a=v[i],b=v[(i+1)%6],e=b-a;
            float2 n=normalize(float2(e.y,-e.x));
            float d=dot(p-a,n);
            if(d>sd) {sd=d;rimLight=0.23+0.77*pow(abs(dot(n,lightDirection)),2.0);}
            // The triangular glass faces meet at a small off-centre ridge.
            float2 ap=a-peak,bp=b-peak,pp=p-peak;
            float crossA=ap.x*pp.y-ap.y*pp.x;
            float crossB=pp.x*bp.y-pp.y*bp.x;
            if(crossA>=0 && crossB>=0) {
                float tiltLight=dot(n,lightDirection)*cos(tilt);
                faceLight=0.08+0.70*pow(saturate(tiltLight*0.5+0.5),2.0);
            }
            // A few internal reflections, deliberately dimmer than the rim.
            float2 r=a-peak;
            float along=clamp(dot(p-peak,r)/dot(r,r),0.0,1.0);
            float seamDistance=length(p-peak-r*along);
            seams=max(seams,exp(-pow(seamDistance/(0.025+fwidth(p.x)*0.55),2.0))*(0.25+0.75*saturate(dot(n,lightDirection))));
        }
        float aa=max(fwidth(sd)*0.70,0.012);
        float body=1-smoothstep(-aa,aa,sd);
        float rim=exp(-pow(sd/(0.027+aa*0.48),2.0));
        float bevel=exp(-pow((sd+0.065)/0.052,2.0))*body;
        float halo=exp(-max(sd,0.0)*7.0)*(1-body);
        // Feather completely inside the expanded quad, so a bright shard never
        // exposes a rectangular sprite boundary during rotation.
        halo*=1-smoothstep(1.45,1.78,max(abs(p.x),abs(p.y)));
        float sparkle=pow(abs(cos(tilt)),10.0);
        float3 iceBody=mix(float3(0.05,0.55,2.3),float3(0.18,1.60,2.5),variation);
        float3 glass=iceBody*(0.40+faceLight*0.72)*body;
        float3 edgeLight=float3(2.5,4.2,5.5)*rim*rimLight*(0.65+0.55*sparkle);
        float3 reflection=float3(1.4,2.7,3.8)*(bevel*0.35+seams*body*0.50);
        float3 glow=float3(0.08,0.65,2.0)*halo*0.44;
        float a=in.opacity*ballMask;
        float coverage=body*0.38+rim*0.58+bevel*0.10+halo*0.10;
        return half4(half3((glass+edgeLight+reflection+glow)*a),half(coverage*a));
    } else if(in.kind==4) {
        float d2=dot(in.uv,in.uv);
        float core=exp(-d2*34);
        float starX=exp(-abs(in.uv.x)*24)*pow(saturate(1-abs(in.uv.y)),2.3);
        float starY=exp(-abs(in.uv.y)*24)*pow(saturate(1-abs(in.uv.x)),2.3);
        float halo=exp(-d2*4.8)*0.20;
        float a=in.opacity*smoothstep(0.92,1.06,length(in.ballOffset));
        float3 color=in.color*(halo+(starX+starY)*0.7)+float3(4.0,4.3,5.0)*core;
        return half4(half3(color*a),half((core+(starX+starY)*0.45+halo)*a*0.55));
    } else if(in.kind==8) {
        float body=exp(-in.uv.x*in.uv.x*9.0)*pow(saturate(1-abs(in.uv.y)),1.5);
        float core=exp(-dot(in.uv,in.uv)*28.0);
        float a=in.opacity*smoothstep(0.92,1.06,length(in.ballOffset));
        return half4(half3((in.color*body+float3(2.0)*core*0.24)*a),half((body*0.55+core*0.15)*a));
    } else if(in.kind==3 || in.kind==6) {
        shape=exp(-dot(in.uv,in.uv)*5);
    } else if(in.kind==7) {
        float swirl=sin(in.uv.x*9+sin(in.uv.y*8)*2)*sin(in.uv.y*11-in.uv.x*4);
        shape=exp(-dot(in.uv,in.uv)*2.8)*smoothstep(-0.6,0.45,swirl);
    } else if(in.kind==9) {
        shape=1-smoothstep(0.83,1.0,max(abs(in.uv.x),abs(in.uv.y)));
    } else if(in.kind==10) {
        // Pointed leaf: two arcs meeting at the tips, a central vein, side
        // ribs, and a lit half so it reads as a surface, not a blob.
        float y=in.uv.y;
        float halfWidth=0.78*sqrt(saturate(1-y*y))*(1-0.25*saturate(-y));
        float edge=1-smoothstep(halfWidth-0.12,halfWidth,abs(in.uv.x));
        float lit=0.55+0.45*smoothstep(-0.2,0.3,in.uv.x+y*0.3);
        float vein=exp(-abs(in.uv.x)*30)*(1-abs(y));
        float ribs=pow(saturate(cos(y*18-abs(in.uv.x)*7)),10.0)*(1-abs(y));
        shape=edge*(lit*(0.8+0.25*ribs)+vein*0.5);
    }
    float a=shape*in.opacity*smoothstep(0.92,1.06,length(in.ballOffset));
    return half4(half3(in.color*a),half(a*((in.kind==7||in.kind==10)?1.0:0.7)));
}

// Emission remains HDR until two spatial bloom bands have been accumulated.
// The output is premultiplied SDR, so the transparent view and export use the
// same source-over operation. Transparent pixels are always zero, never black.
float4 resolveFX(float4 sharp,float4 nearGlow,float4 farGlow,float2 pixel,constant FXUniforms &u) {
    if(u.control.y<0.5 && (u.motion.w<0.5 || u.viewport.w<=0.005 || u.ball.w<=0.005))return 0;
    if(u.control.y<0.5 && u.motion.w==1) {
        // Bloom stays off the ball face so its pattern remains readable.
        float face=smoothstep(0.7,1.0,length(pixel-u.ball.xy)/max(1.0,u.ball.z));
        float3 energy=sharp.rgb+(nearGlow.rgb*0.3+farGlow.rgb*0.3)*face;
        float3 mapped=1-exp(-energy*0.90);
        float alpha=clamp(max(max(mapped.r,max(mapped.g,mapped.b))*0.88,sharp.a),0.0,0.94);
        return float4(min(mapped,float3(alpha)),alpha);
    }
    if(u.control.y<0.5 && u.motion.w==2) {
        float face=smoothstep(0.92,1.06,length(pixel-u.ball.xy)/max(1.0,u.ball.z));
        float3 energy=sharp.rgb+(nearGlow.rgb*0.20+farGlow.rgb*0.08)*face;
        float3 mapped=1-exp(-energy*0.82);
        float alpha=clamp(max(max(mapped.r,max(mapped.g,mapped.b))*0.90,sharp.a),0.0,0.92)*face;
        return float4(min(mapped*face,float3(alpha)),alpha);
    }
    if(u.control.y<0.5 && u.motion.w==3) {
        // Small local optical bloom; preserve the ball even when an old stroke
        // crosses it. The distant green fog used to overwhelm daylight footage.
        float face=smoothstep(0.93,1.06,length(pixel-u.ball.xy)/max(1.0,u.ball.z));
        float3 energy=sharp.rgb+(nearGlow.rgb*0.22+farGlow.rgb*0.055)*face;
        float3 mapped=1-exp(-energy*0.9);
        float alpha=clamp(max(max(mapped.r,max(mapped.g,mapped.b))*0.93,sharp.a),0.0,0.96)*face;
        return float4(min(mapped*face,float3(alpha)),alpha);
    }
    if(u.control.y<0.5 && u.motion.w==8) {
        float face=smoothstep(0.93,1.06,length(pixel-u.ball.xy)/max(1.0,u.ball.z));
        float3 energy=sharp.rgb+(nearGlow.rgb*0.30+farGlow.rgb*0.13)*face;
        float3 mapped=1-exp(-energy*0.82);
        float alpha=clamp(max(max(mapped.r,max(mapped.g,mapped.b))*0.90,sharp.a),0.0,0.91)*face;
        return float4(min(mapped*face,float3(alpha)),alpha);
    }
    if(u.control.y<0.5 && (u.motion.w==4 || u.motion.w==6)) {
        bool galaxy=u.motion.w==4;
        float face=smoothstep(0.93,1.06,length(pixel-u.ball.xy)/max(1.0,u.ball.z));
        float3 energy=sharp.rgb+(nearGlow.rgb*(galaxy?0.18:0.16)+farGlow.rgb*0.055)*face;
        float3 mapped=1-exp(-energy*(galaxy?0.88:0.82));
        float alpha=clamp(max(max(mapped.r,max(mapped.g,mapped.b))*0.92,sharp.a),0.0,0.93)*face;
        return float4(min(mapped*face,float3(alpha)),alpha);
    }
    if(u.control.y<0.5 && ((u.motion.w>=11 && u.motion.w<=16) || u.motion.w>=20)) {
        // Bloom and particles must respect the same clear ball face as the field.
        float face=smoothstep(0.96,1.055,length(pixel-u.ball.xy)/max(1.0,u.ball.z));
        float3 energy=sharp.rgb+nearGlow.rgb*0.18+farGlow.rgb*0.045;
        float3 mapped=1-exp(-energy*0.90);
        float alpha=clamp(max(max(mapped.r,max(mapped.g,mapped.b)),sharp.a),0.0,0.96)*face;
        return float4(min(mapped*face,float3(alpha)),alpha);
    }
    float nearWeight = u.control.y>0.5 ? 0.72 : u.motion.w==1 ? 0.16 : u.motion.w==2 ? 0.26 : u.motion.w==4 ? 0.5 : u.motion.w==9 ? 0.22 : u.motion.w==7 ? 0.10 : u.motion.w==10 ? 0.14 : 0.32;
    float farWeight = u.control.y>0.5 ? 0.36 : u.motion.w==1 ? 0.07 : u.motion.w==2 ? 0.12 : u.motion.w==4 ? 0.3 : u.motion.w==9 ? 0.10 : u.motion.w==7 ? 0.04 : u.motion.w==10 ? 0.06 : 0.14;
    float3 energy=sharp.rgb+nearGlow.rgb*nearWeight+farGlow.rgb*farWeight;
    float peak=max(energy.r,max(energy.g,energy.b));
    float alpha=saturate(max(sharp.a,(1-exp(-peak*0.9))*0.92));
    float3 mapped=1-exp(-energy*0.9);
    mapped=min(mapped,float3(alpha));
    return float4(mapped,alpha);
}
kernel void fxResolve(texture2d<float,access::sample> sharp [[texture(0)]],
                      texture2d<float,access::sample> nearGlow [[texture(1)]],
                      texture2d<float,access::sample> farGlow [[texture(2)]],
                      texture2d<half,access::write> output [[texture(3)]],
                      constant FXUniforms &u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=output.get_width() || gid.y>=output.get_height()) return;
    float2 pixel=float2(gid)+0.5;
    float2 uv=(pixel-u.region.xy)/u.region.zw;
    if(any(uv<0)||any(uv>1)){output.write(half4(0),gid);return;}
    output.write(half4(resolveFX(sharp.sample(imageSampler,uv),nearGlow.sample(imageSampler,uv),farGlow.sample(imageSampler,uv),pixel,u)),gid);
}
kernel void fxComposite(texture2d<float,access::sample> sharp [[texture(0)]],
                        texture2d<float,access::sample> nearGlow [[texture(1)]],
                        texture2d<float,access::sample> farGlow [[texture(2)]],
                        texture2d<float,access::sample> source [[texture(3)]],
                        texture2d<half,access::write> output [[texture(4)]],
                        texture2d<float,access::sample> material [[texture(5)]],
                        constant FXUniforms &u [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=output.get_width() || gid.y>=output.get_height()) return;
    float2 pixel=float2(gid)+0.5;
    float2 uv=(pixel-u.region.xy)/u.region.zw;
    float2 dest=float2(output.get_width(),output.get_height());
    float2 src=float2(source.get_width(),source.get_height());
    float scale=max(dest.x/src.x,dest.y/src.y);
    float2 videoUV=(pixel-(dest-src*scale)*0.5)/(src*scale);
    bool inside=all(uv>=0)&&all(uv<=1);
    if(inside && u.control.y<0.5 && u.motion.w==1 && u.viewport.w>0.005 && u.ball.w>0.005) {
        // Heat shimmer: hot air around and above the flames refracts the video.
        float R=max(1.0,u.ball.z),t=u.viewport.z;
        float heat=farGlow.sample(imageSampler,uv).a*2.2+nearGlow.sample(imageSampler,uv).a*0.6;
        float3 P=float3(pixel.x/R*1.3,(pixel.y/R+t*5.5)*0.7,t*0.8);
        float2 wobble=float2(fireNoise3(P),fireNoise3(P+float3(41.0,17.0,9.0)))-0.5;
        // Refract the surrounding air, not the tracked ball underneath the
        // effect. Otherwise its visible edge moves while the fire anchor stays put.
        float outsideBall=smoothstep(1.02,1.25,length(pixel-u.ball.xy)/R);
        videoUV+=wobble*saturate(heat)*outsideBall*R*0.11/(src*scale);
    }
    float4 base=source.sample(imageSampler,videoUV),fx=0;
    if(u.environment.y>0.5){
        float4 layer=material.sample(imageSampler,pixel/dest);
        base.rgb=base.rgb*(1-layer.a)+layer.rgb;
    }
    if(u.environment.x>0.001){
        float luminance=dot(base.rgb,float3(0.2126,0.7152,0.0722));
        float3 cooler=mix(float3(luminance),base.rgb,0.78)*float3(0.34,0.46,0.59);
        float vignette=1.0-0.18*smoothstep(0.25,0.74,length(videoUV-0.5));
        float3 graded=pow(max(cooler,float3(0)),float3(1.06))*vignette+float3(0.003,0.008,0.014);
        base.rgb=mix(base.rgb,graded,u.environment.x);
    }
    if(inside) fx=resolveFX(sharp.sample(imageSampler,uv),nearGlow.sample(imageSampler,uv),farGlow.sample(imageSampler,uv),pixel,u);
    output.write(half4(float4(base.rgb*(1-fx.a)+fx.rgb,1)),gid);
}
