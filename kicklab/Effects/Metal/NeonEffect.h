#ifndef EFFECT_LAB_NEON
#define EFFECT_LAB_NEON

// Shared by the simulator study and the original-footage renderer. No textures,
// prerecorded animation, closed rings or frame-accumulated simulation state.
float neonHash(float n) { return fract(sin(n*127.1+311.7)*43758.5453); }
float neonLine(float d,float w) { return exp(-d*d/max(w*w,0.000001)); }
float2 neonCubic(float2 a,float2 b,float2 c,float2 d,float s) {
    float v=1-s; return a*v*v*v+3*b*v*v*s+3*c*v*s*s+d*s*s*s;
}
float4 neonHistory(float age,constant float4 *history) {
    float slot=clamp(age*40.0,0.0,32.0);
    uint i=min(uint(slot),31u);
    float4 a=history[i],b=history[i+1];
    if(a.w<=0 || b.w<=0)return 0;
    return mix(a,b,slot-float(i));
}
float4 neonSmoothHistory(float age,constant float4 *history) {
    float4 e=neonHistory(age,history);
    if(e.w<=0)return 0;
    float2 sum=e.xy*4;float weight=4;
    for(int i=-2;i<=2;i++) {
        if(i==0)continue;
        float4 p=neonHistory(clamp(age+float(i)*0.025,0.0,0.8),history);
        // Missing observations break a strand; smoothing must not bridge them.
        if(p.w<=0)return 0;
        float w=abs(i)==1 ? 2.0 : 1.0;sum+=p.xy*w;weight+=w;
    }
    e.xy=mix(e.xy,sum/weight,smoothstep(0.0,0.10,age));return e;
}
float4 neonFilament(float d,float width,float strength,float aa) {
    float bodyWidth=sqrt(width*width+aa*aa);
    float coreWidth=sqrt(width*width*0.11+aa*aa);
    float body=neonLine(d,bodyWidth)*width/bodyWidth;
    float core=neonLine(d,coreWidth)*width*0.33/coreWidth;
    float glow=neonLine(d,width*3.3);
    float3 light=float3(0.025,3.3,0.43)*(body+glow*0.12)
                +float3(4.2,5.1,4.5)*core*1.15;
    return float4(light,body*0.67+core*0.40+glow*0.10)*strength;
}
struct NeonUpperCurve { float2 a,b,c,d; bool valid; };
NeonUpperCurve neonUpperControls(float time,float lane) {
    float p1=(time-0.075)*2.35-lane*0.55;
    float p2=(time-0.16)*2.35-lane*0.55;
    float p3=(time-0.26)*2.35-lane*0.55;
    float curl2=0.62*sin(p2*0.71)+0.24*sin(p2*1.19+0.8);
    float curl3=0.62*sin(p3*0.71)+0.24*sin(p3*1.19+0.8);
    return {float2(0.08,-0.95),
        float2(-3.15+0.34*sin(p1),-1.75+0.18*cos(p1*0.8)),
        float2(-3.35+curl2*0.70,-3.60+0.34*cos(p2*0.83+0.3)),
        float2(-0.95+curl3,-4.85+0.34*cos(p3*0.83+0.3)+lane*0.20),true};
}
float2 neonUpperPoint(NeonUpperCurve c,float s,float lane,float time) {
    float2 p=neonCubic(c.a,c.b,c.c,c.d,s);
    float bend=sin(s*3.14159265);
    p.x+=0.17*bend*sin(s*6.0-time*3.4+lane*0.6)+lane*0.14*bend;
    p.y+=lane*0.12*bend;return p;
}
float2 neonUpper(float s,float lane,float time,float lean) {
    NeonUpperCurve c=neonUpperControls(time,lane);
    c.b.x+=lean*0.3;c.c.x+=lean*0.7;c.d.x+=lean;
    return neonUpperPoint(c,s,lane,time);
}
NeonUpperCurve neonReleasedUpper(float lane,float time,float4 ball,constant float4 *history) {
    // Control points carry progressively older positions, so a kick reaches
    // the tip after the root. Evaluate the history once per curve, not per pixel
    // segment. Keep vertical control order to avoid knots at hard reversals.
    NeonUpperCurve c=neonUpperControls(time,lane);
    float R=max(1.0,ball.z);
    float4 b=neonSmoothHistory(0.075,history),m=neonSmoothHistory(0.16,history),tip=neonSmoothHistory(0.26,history);
    c.valid=b.w>0 && m.w>0 && tip.w>0;
    if(!c.valid)return c;
    c.b=(b.xy-ball.xy)/R+c.b*b.z/R;
    c.c=(m.xy-ball.xy)/R+c.c*m.z/R;
    c.d=(tip.xy-ball.xy)/R+c.d*tip.z/R;
    c.b.y=min(c.b.y,c.a.y-0.45);
    c.c.y=min(c.c.y,c.b.y-0.65);
    c.d.y=min(c.d.y,c.c.y-0.75);
    return c;
}
float2 neonLower(float s,float lane,float birthTime) {
    float2 p=s<0.42
        ? neonCubic(float2(-0.97,0.32),float2(-1.05,1.55),float2(1.95,1.35),float2(0.65,2.90),s/0.42)
        : neonCubic(float2(0.65,2.90),float2(-0.35,4.10),float2(-1.80,5.70),float2(-1.15,6.75),(s-0.42)/0.58);
    float bend=sin(s*3.14159265);
    p.x+=0.14*bend*sin(birthTime*1.2+s*4)+lane*0.22*bend;
    p.y+=lane*0.15*bend;return p;
}
float4 neonEffect(float2 pixel,float4 viewport,float4 ball,float4 motion,float contactAge,
                  constant float4 *history,float pixelStep) {
    float R=max(1.0,ball.z),t=viewport.z;
    float2 q=(pixel-ball.xy)/R;
    float aa=max(0.006,pixelStep/R*0.55);
    float contact=contactAge>=0 && contactAge<0.42 ? motion.z*exp(-contactAge*7.0) : 0;
    float4 light=0;
    for(uint curve=0;curve<4;curve++) {
        bool upper=curve<2;float lane=float(curve%2);
        float bestD=1e5,bestS=0;float2 previous=0;bool have=false;
        NeonUpperCurve top;
        if(upper){top=neonReleasedUpper(lane,t,ball,history);if(!top.valid)continue;}
        uint steps=upper ? 48 : 64;
        for(uint i=0;i<=steps;i++) {
            float s=float(i)/float(steps);float2 p;
            if(upper) {
                p=neonUpperPoint(top,s,lane,t);
            } else {
                float age=s*0.30;
                float4 e=neonSmoothHistory(age,history);
                if(e.w<=0){have=false;continue;}
                p=(e.xy-ball.xy)/R+neonLower(s,lane,t-age)*e.z/R;
            }
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
    // A short, open accent on the right. Its endpoints never join into a ring.
    float best=1e5,along=0;float2 previous=0;
    for(uint i=0;i<=32;i++) {
        float s=float(i)/32.0;
        float2 p=neonCubic(float2(0.64,-1.50),float2(1.65,-0.75),float2(1.42,0.85),float2(0.58,1.35),s);
        p.x+=sin(t*0.9)*0.06*sin(s*3.14159265);
        if(i>0){float2 ab=p-previous;float f=saturate(dot(q-previous,ab)/max(dot(ab,ab),0.000001));float d=length(q-previous-ab*f);if(d<best){best=d;along=(float(i)-1+f)/32;}}
        previous=p;
    }
    float accent=pow(max(0.0,sin(along*3.14159265)),1.1);
    light+=neonFilament(best,0.035*(0.3+accent*0.7),accent*(0.85+contact*0.35),aa);

    // Independent births retain their recorded origin and momentum. A new
    // contact cannot reset the existing sparks, and seeking remains repeatable.
    for(uint i=0;i<18;i++) {
        float id=float(i),duration=0.52+neonHash(id+8)*0.23;
        float phase=neonHash(id+13)*duration;
        float cycle=floor((t+phase)/duration),age=t-(cycle*duration-phase);
        float seed=id+cycle*19.31;
        float4 birth=neonHistory(age,history),older=neonHistory(min(0.8,age+0.025),history);
        if(birth.w<=0 || older.w<=0)continue;
        float2 v=clamp((birth.xy-older.xy)/0.025,-birth.z*20,birth.z*20);
        float angle=neonHash(seed+4)*6.28318530718;
        float2 radial=float2(cos(angle),sin(angle));
        float travel=(1-exp(-age*1.5))/1.5;
        float2 release=i%3==0 ? neonUpper(0.20+neonHash(seed+2)*0.66,0,t-age,0)
            : i%3==1 ? neonLower(0.12+neonHash(seed+2)*0.47,0,t-age)*0.78
            : radial*(1.25+neonHash(seed+2)*0.8);
        float2 point=birth.xy+release*birth.z
            +(v*0.13+radial*birth.z*0.8)*travel+float2(0,birth.z*age*age*2.0);
        float d=length(pixel-point)/R;
        float life=age/duration;
        float envelope=smoothstep(0.0,0.08,life)*(1-smoothstep(0.5,1.0,life));
        float width=(i%5==0 ? 0.043 : 0.023)*birth.z/R;
        light+=neonFilament(d,width,envelope*(i%5==0 ? 1.65 : 0.95),aa);
    }
    float mask=smoothstep(1.0,1.065,length(q));
    return float4(light.rgb*mask,saturate(light.a)*mask);
}
#endif
