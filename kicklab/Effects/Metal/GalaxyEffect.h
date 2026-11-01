#ifndef EFFECT_LAB_GALAXY
#define EFFECT_LAB_GALAXY
// Shared by the live simulator and footage renderer. All flow uses video time
// and recorded origins, so pausing/seeking does not reseed or erase the wake.
float gxHash(float n) { return fract(sin(n*127.1+311.7)*43758.5453); }
float gxHash3(float3 p) { return fract(sin(dot(p,float3(127.1,311.7,74.7)))*43758.5453); }
float gxNoise(float3 p) {
    float3 i=floor(p),f=fract(p); f=f*f*f*(f*(f*6-15)+10);
    return mix(mix(mix(gxHash3(i),gxHash3(i+float3(1,0,0)),f.x),mix(gxHash3(i+float3(0,1,0)),gxHash3(i+float3(1,1,0)),f.x),f.y),
               mix(mix(gxHash3(i+float3(0,0,1)),gxHash3(i+float3(1,0,1)),f.x),mix(gxHash3(i+float3(0,1,1)),gxHash3(i+float3(1,1,1)),f.x),f.y),f.z);
}
float gxFBM(float3 p) {
    float n=0,weight=0.57;
    for(uint i=0;i<4;i++) {n+=weight*gxNoise(p);p=float3(p.y+p.z*0.16,p.z-p.x*0.18,p.x+p.y*0.12)*2.03+float3(13.7,4.1,7.9);weight*=0.48;}
    return n;
}
float gxLine(float d,float w) {return exp(-d*d/max(w*w,0.000001));}
float2 gxCubic(float2 a,float2 b,float2 c,float2 d,float s) {
    float v=1-s;return a*v*v*v+b*3*v*v*s+c*3*v*s*s+d*s*s*s;
}
float4 gxHistory(float age,constant float4 *history) {
    float slot=clamp(age*40.0,0.0,32.0);uint i=min(uint(slot),31u);
    if(history[i].w<=0 || history[i+1].w<=0)return 0;
    return mix(history[i],history[i+1],slot-float(i));
}
// Each point is a parcel born on the recorded path. Older parcels carry an
// older launch direction; the root, middle and tip cannot move as one rigid fan.
float gxFlowLife(uint lane) {return lane==0 ? 0.28 : lane==1 ? 0.36 : lane==2 ? 0.42 : 0.78;}
float4 gxSmoothHistory(float age,constant float4 *history) {
    float4 e=gxHistory(age,history);if(e.w<=0)return 0;
    float4 before=gxHistory(min(0.8,age+0.025),history);
    float4 after=gxHistory(max(0.0,age-0.025),history);
    if(before.w>0 && after.w>0)e.xy=(e.xy*2+before.xy+after.xy)*0.25;
    return e;
}
float2 gxLocal(float s,uint lane,float birth) {
    float2 p;
    if(lane==0) p=gxCubic(float2(1.02,0.18),float2(1.65,-2.6),float2(-3.3,-3.4),float2(-5.0,-6.6),s);
    else if(lane==1) p=gxCubic(float2(-0.90,0.6),float2(-2.7,1.10),float2(-2.9,-3.0),float2(-1.1,-2.1),s);
    else p=gxCubic(float2(0.88,0.65),float2(2.5,1.2),float2(0.2,2.4),float2(0.6,3.3),s);
    float phase=float(lane)*2.31;
    float sweep=0.78*sin(birth*1.35+phase-0.8)+0.20*sin(birth*2.15+phase*0.71+0.9);
    float roll=s*(0.32*sin(birth*1.7+phase+s*3.2)+0.11*sin(birth*2.7+s*5.3));
    float angle=sweep+roll;
    float bend=sin(s*3.14159265);
    // Independent stretch and travelling bends change the silhouette itself,
    // rather than sliding a noise texture over a permanently fixed outline.
    p*=1+0.11*s*sin(birth*2.5+phase+s*4.2);
    p+=float2(sin(s*8.2-birth*2.8+phase),cos(s*7.3-birth*2.1+phase))*bend*(0.22+0.27*s);
    p+=float2(sin(birth*1.73+phase)*0.46,cos(birth*2.07+phase)*0.38)*s*s;
    return float2(p.x*cos(angle)-p.y*sin(angle),p.x*sin(angle)+p.y*cos(angle));
}
float4 gxCurve(float s,uint lane,float time,float4 ball,constant float4 *history) {
    float age=s*gxFlowLife(lane);
    float4 e=gxSmoothHistory(age,history);if(e.w<=0)return 0;
    float4 older=gxSmoothHistory(min(0.8,age+0.05),history);
    float2 velocity=older.w>0 ? clamp((e.xy-older.xy)/max(0.001,min(0.05,0.8-age))/max(1.0,e.z),-16.0,16.0):float2(0);
    float2 offset;
    if(lane<3) {
        offset=gxLocal(s,lane,time-age);
        // Released material retains a little momentum through each reversal.
        // The older tail stays behind instead of snapping to the latest kick.
        offset+=velocity*age*0.12;
    } else {
        float phase=(time-age)*1.75+age*6.5;
        offset=float2(cos(phase)*(1.12+age*0.4),sin(phase)*0.85-age*0.8);
    }
    return float4((e.xy-ball.xy+offset*e.z)/max(1.0,ball.z),e.z/max(1.0,ball.z),1);
}
// A short integral through turbulent density gives a transparent body with
// bright front folds and darker interior depth; it is not a flat ribbon fill.
float4 gxNebula(float2 q,float d,float s,float width,float fade,float lane,float t,float aa) {
    float v=d/max(width,0.01);
    if(abs(v)>2.9)return 0;
    float3 domain=float3(q*2.1+float2(-t*0.23,t*0.72)+lane*9.7,t*0.23);
    float warp=gxFBM(domain*0.67+float3(2.3,0,7.1))-0.5;
    float fine=gxFBM(domain*2.7+float3(warp*2,0,t*0.38));
    float shape=abs(v)-warp*1.25;
    float3 color=0;float opacity=0,transmission=1;
    for(uint slice=0;slice<4;slice++) {
        float z=-0.85+float(slice)*0.56;
        float3 bent=domain+float3(warp*1.7,warp*1.1,z*1.9+lane*3.7);
        float n=gxFBM(bent+float3(0,z*0.5,0));
        float density=gxLine(shape+z*warp*0.4,0.76+0.50*n)*exp(-z*z*1.4)*pow(smoothstep(0.33,0.71,n),1.9)*1.8;
        float hue=smoothstep(0.29,0.72,n+0.15*sin(s*9+lane*2.7-t*0.4));
        float3 tint=mix(float3(0.035,0.40,3.30),float3(0.68,0.13,3.0),hue);
        float light=0.48+0.52*smoothstep(0.38,0.73,n);
        color+=transmission*tint*density*light*1.18;
        float rim=pow(saturate((n-0.51)*4.7),2.2)*gxLine(shape,0.85);
        color+=transmission*float3(0.40,1.3,2.8)*rim*0.9;
        opacity+=transmission*density*0.19;
        transmission*=exp(-density*0.48);
    }
    // Broken folds travel at different speeds through the cloud. Their widths
    // are footprint-filtered so the tiny white cores do not flicker on export.
    for(uint strand=0;strand<3;strand++) {
        float id=float(strand),phase=s*(18+id*9)-t*(2.7+id*0.45)+lane*3.7+id*2.1;
        float wobble=0.22*sin(phase)+0.13*sin(phase*2.17+fine*3.4)+warp*0.65;
        float center=(id-1)*0.48+wobble;
        float w=(strand==1 ? 0.037 : 0.020)*width;
        float blur=sqrt(w*w+aa*aa*0.6);
        float line=gxLine(d-center*width,blur)*w/blur;
        float visible=smoothstep(0.28,0.66,gxNoise(float3(s*28-t*(2.2+id*0.5),lane*5.1+id*3.7,t*0.47)));
        float glow=gxLine(d-center*width,width*0.15)*0.20;
        float hue=pow(0.5+0.5*sin(s*10+lane*3+id*2-t*0.6),2.4);
        float3 tint=mix(float3(0.40,2.6,5.4),float3(2.9,0.65,4.9),hue);
        color+=(tint*(line*1.0+glow*0.8)+float3(2.5,3.0,3.2)*line*0.70)*visible;
        opacity+=line*visible*0.22;
    }
    float fringe=smoothstep(0.40,0.68,fine)*gxLine(shape,1.75)*0.44;
    color+=float3(0.24,0.30,2.6)*fringe;
    return float4(color,opacity+fringe*0.12)*fade;
}
float gxStardust(float2 p,float aa,float t) {
    float2 cell=floor(p),f=fract(p);float value=0;
    for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++) {
        float2 k=float2(x,y),id=cell+k;
        float seed=dot(id,float2(37.17,113.71));
        float chance=gxHash(seed+23);
        if(chance<0.34)continue;
        float2 delta=k+float2(gxHash(seed),gxHash(seed+31.7))-f;
        float size=0.045+pow(gxHash(seed+13.2),3.0)*0.105;
        float width2=size*size+aa*aa*0.32;
        float twinkle=0.57+0.43*sin(t*(1.4+gxHash(seed+7)*2)+seed)*sin(t*1.2+seed);
        value+=exp(-dot(delta,delta)/width2)*size*size/width2*twinkle;
    }
    return value;
}
float4 galaxyEffect(float2 pixel,float4 viewport,float4 ball,float4 motion,float contactAge,
                    constant float4 *history,float pixelStep) {
    float R=max(1.0,ball.z),t=viewport.z;
    float2 q=(pixel-ball.xy)/R;
    float aa=max(0.006,pixelStep/R*0.58);
    float mask=smoothstep(1.0,1.065,length(q));if(mask<=0)return 0;
    float contact=contactAge>=0 && contactAge<0.48 ? motion.z*exp(-contactAge*6.5):0;
    float4 light=0;float dustEnvelope=0;
    for(uint lane=0;lane<4;lane++) {
        float best=1e6,sd=0,along=0,scale=1;float2 previous=0;bool have=false;
        for(uint i=0;i<=40;i++) {
            float s=float(i)/40.0;
            float4 point=gxCurve(s,lane,t,ball,history);
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
    // Free stars keep their birth positions, briefly retain ball momentum, and
    // fade independently. A later touch never resets existing star lifetimes.
    for(uint i=0;i<30;i++) {
        float id=float(i),duration=0.46+gxHash(id+8)*0.30,phase=gxHash(id+13)*duration;
        float cycle=floor((t+phase)/duration),age=t-(cycle*duration-phase),seed=id+cycle*19.31;
        float4 born=gxHistory(age,history),older=gxHistory(min(0.8,age+0.025),history);
        if(born.w<=0 || older.w<=0)continue;
        float2 v=clamp((born.xy-older.xy)/0.025,-born.z*20,born.z*20);
        float angle=gxHash(seed+4)*6.2831853;
        float2 radial=float2(cos(angle),sin(angle));
        float s=0.08+gxHash(seed+2)*0.76;
        // Reserve history for the star's entire lifetime at birth. Its origin
        // must not slide forward when the star gets old or a new kick arrives.
        float streamAge=min(s*gxFlowLife(i%3),max(0.0,0.78-duration));
        float streamS=streamAge/gxFlowLife(i%3);
        float4 origin=gxSmoothHistory(age+streamAge,history);
        if(origin.w<=0)continue;
        float2 release=gxLocal(streamS,i%3,t-age-streamAge)+radial*(0.10+gxHash(seed+9)*0.38);
        float travel=(1-exp(-age*2.0))/2;
        float2 position=origin.xy+release*origin.z+(v*0.12+radial*origin.z*0.9)*travel;
        position+=float2(sin(age*4+seed)-sin(seed),-age*0.8)*born.z*0.22;
        float2 d=(pixel-position)/R;
        float life=age/duration,envelope=smoothstep(0.0,0.08,life)*(1-smoothstep(0.48,1.0,life));
        bool bright=i%7==0;
        float width=(bright ? 0.032 : 0.015)*born.z/R;
        float filter=sqrt(width*width+aa*aa);
        float core=gxLine(length(d),filter)*width/filter;
        float glow=gxLine(length(d),bright ? 0.11:0.048)*(bright ? 0.34:0.10);
        float cross=bright ? (gxLine(d.x,aa*0.65)*gxLine(d.y,0.092)+gxLine(d.y,aa*0.65)*gxLine(d.x,0.092))*0.12 : 0;
        float3 tint=mix(float3(0.6,2.8,4.9),float3(3.7,0.6,4.6),gxHash(seed+5));
        light.rgb+=(float3(4,4.8,5.6)*core*2.1+tint*(glow+cross))*envelope;
        light.a+=core*envelope*0.25;
    }
    return float4(light.rgb*mask,saturate(light.a)*mask);
}
#endif
