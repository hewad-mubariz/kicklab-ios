// The six approved effect studies. Included after the shared noise/geometry helpers.
// All geometry is ball-relative; trails use recorded births rather than screen-fixed emitters.

struct StudyPath {
    float distance;
    float signedDistance;
    float age;
    float2 tangent;
};

StudyPath studyPathFX(float2 pixel, constant FXUniforms &u, constant float4 *emitters,
                      float lifetime, float lane, float curl) {
    float R=max(1.0,u.ball.z),best=1e6,sd=0,ageAt=0;
    float2 tangent=float2(1,0),previous=0;bool have=false;
    for(uint i=0;i<=32;i++) {
        float age=float(i)*0.025;
        if(age>lifetime)break;
        float4 e=wakeEmitterFX(age,emitters);
        if(e.w<=0){have=false;continue;}
        float2 p=(e.xy-u.ball.xy)/R;
        if(curl>0) {
            float2 flow=normalize(u.motion.xy+float2(0.001,-0.001));
            float2 normal=float2(-flow.y,flow.x);
            p+=normal*(lane*(0.55+age*0.65)+sin(age*8.0-u.viewport.z*2.4+lane*1.9)*age*curl);
            p.y-=age*age*curl*0.3;
        }
        if(have) {
            float2 q=(pixel-u.ball.xy)/R,ab=p-previous;
            float fraction=saturate(dot(q-previous,ab)/max(dot(ab,ab),0.0001));
            float2 delta=q-previous-ab*fraction;float distance=length(delta);
            if(distance<best) {
                best=distance;sd=(ab.x*delta.y-ab.y*delta.x<0?-distance:distance);
                ageAt=(float(i)-1+fraction)*0.025;
                tangent=length(ab)>0.001?normalize(ab):float2(1,0);
            }
        }
        previous=p;have=true;
    }
    return {best,sd,ageAt,tangent};
}

float3 studyWarmFX(float heat) {
    return heat<0.45 ? mix(float3(1.7,0.06,0.001),float3(3.8,0.60,0.012),heat/0.45)
        : mix(float3(3.8,0.60,0.012),float3(5.8,3.4,0.65),saturate((heat-0.45)/0.55));
}

// Lab Flame: the Python study's hot rim and translucent licking plume, with a
// restrained warm wake. The original Fire (ID 1) keeps its own volume unchanged.
float4 labFlameFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters,float footprint) {
    float R=max(1.0,u.ball.z),t=u.viewport.z;
    float2 q=(pixel-u.ball.xy)/R;float r=length(q),aa=max(0.012,footprint/R*0.6);
    float2 back=normalize(-u.motion.xy*0.08+float2(0.001,-1));
    float2 normal=float2(-back.y,back.x);
    float along=dot(q,back),across=dot(q,normal);
    float3 field=float3(q*float2(3.8,2.4)-back*t*3.3,t*0.45);
    float n=fireFBM3(field),fine=fireNoise3(field*2.6+float3(9.1,5.4,t*0.4));
    float edge=1.025+(n-0.45)*0.21;
    float rim=lineFX(r-edge,max(aa,0.04))*(0.6+0.4*fine);
    float shell=exp(-pow((r-1.12-n*0.16)/0.22,2.0));
    float lengthK=1.7+min(1.5,length(u.motion.xy)*0.055);
    float flameWidth=max(0.08,0.93*(1-saturate((along-0.55)/lengthK)));
    float fold=across+sin(along*3.0-t*4.0)*0.11+(n-0.5)*0.36;
    float plume=(1-smoothstep(flameWidth*0.30,flameWidth,abs(fold)))
        *smoothstep(0.45,1.05,along)*(1-smoothstep(lengthK,lengthK+0.7,along));
    float hot=smoothstep(0.29,0.75,n+fine*0.22);
    float tongues=plume*pow(hot,1.7);
    float wisps=lineFX(abs(fold)-flameWidth*(0.4+n*0.35),0.04+aa)*plume*hot;

    StudyPath path=studyPathFX(pixel,u,emitters,0.65,0,0);
    float fade=pow(saturate(1-path.age/0.65),1.3);
    float width=0.12+0.67*fade;
    float texture=fireFBM3(float3(pixel/R*2.2+float2(0,t*3.2),t*0.55));
    float d=path.signedDistance+(texture-0.5)*(0.28+path.age*0.32);
    // A soft floor keeps the wake continuous; the noise only modulates it.
    float wake=lineFX(d,width)*(0.35+0.65*smoothstep(0.25,0.8,texture))*fade;
    float strands=lineFX(abs(d)-width*0.55,0.045+aa)*wake*1.7;
    float mask=smoothstep(0.96,1.055,r);
    // Fire only covers what it lights: hottest at the rim and plume roots, cooling
    // toward the tongue tips and the end of the wake. Coverage follows brightness,
    // so the cool edges fade out instead of reading as dark smoke.
    float plumeHeat=saturate(1-(along-0.55)/lengthK)*hot;
    float wakeHeat=fade*smoothstep(0.3,0.8,texture);
    // The body burns orange to yellow-white; only the very tips drop toward red.
    float3 color=studyWarmFX(saturate(0.72+0.28*hot))*(rim*0.95+shell*hot*0.4)
        +studyWarmFX(saturate(0.5+0.5*plumeHeat))*(tongues*1.15+wisps*0.7)
        +studyWarmFX(saturate(0.42+0.55*wakeHeat))*(wake*0.75+strands*0.95);
    float light=max(color.r,max(color.g,color.b));
    return float4(color*mask,saturate(light*0.2)*mask);
}

// The phone replay's cyan ribbon follows the measured trajectory. Only its
// glint breathes; there is no sine-wave deformation of the recorded path.
float4 glowTrailFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters,float footprint) {
    float R=max(1.0,u.ball.z),aa=max(0.010,footprint/R*0.55),t=u.viewport.z;
    float2 q=(pixel-u.ball.xy)/R;float r=length(q);
    StudyPath path=studyPathFX(pixel,u,emitters,0.55,0,0);
    float fade=pow(saturate(1-path.age/0.55),1.2);
    // Full width at the ball, tapering to a fine point.
    float width=max(aa,0.03+0.33*fade);
    float body=lineFX(path.distance,width)*fade;
    float core=lineFX(path.distance,max(aa,width*0.28))*fade;
    float halo=lineFX(path.distance,width*2.6+aa)*fade;
    float ring=lineFX(r-1.105,max(aa,0.018));
    float glint=pow(saturate(dot(normalize(q+0.0001),normalize(float2(-0.7,-1)))),24.0);
    float energy=0.92+0.08*sin(t*3.0-path.age*12);
    float3 color=float3(0.03,1.3,3.3)*body*0.8*energy+float3(0.02,0.55,1.7)*halo*0.32
        +float3(2.4,4.0,4.7)*core*0.95+float3(1.35,2.1,0.16)*ring*0.60
        +float3(2.5,3.5,2.3)*ring*glint*energy;
    float mask=smoothstep(0.98,1.045,r);
    return float4(color*mask,saturate(body*0.5+core*0.3+halo*0.1+ring*0.6)*mask);
}

// A forked, streaming flame: narrow cyan filaments and a compact cold crown.
float4 blueFlameFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters,float footprint) {
    float R=max(1.0,u.ball.z),t=u.viewport.z,aa=max(0.014,footprint/R*0.6);
    float2 q=(pixel-u.ball.xy)/R;float r=length(q);
    float angle=atan2(q.y,q.x);
    float noise=fireFBM3(float3(q*4+float2(t*2,t*3.1),t*0.6));
    float edge=1.07+noise*0.16+0.02*sin(angle*11-t*4);
    float rim=lineFX(r-edge,0.035+aa);
    float crown=lineFX(r-edge-0.10,0.15)*smoothstep(0.35,0.8,noise)*0.36;
    float filaments=0,glow=0,roots=0;
    for(int lane=-1;lane<=1;lane++) {
        StudyPath path=studyPathFX(pixel,u,emitters,0.775,float(lane)*0.78,1.15);
        float fade=pow(saturate(1-path.age/0.775),1.25);
        float flowNoise=fireNoise3(float3(pixel/R*3.4+float2(t*4,-t*3),float(lane)*4+t));
        float d=path.signedDistance+(flowNoise-0.5)*(0.22+path.age*0.26);
        float width=0.03+0.2*fade;
        float edgeWisp=lineFX(d,width+aa);
        filaments+=edgeWisp*fade*(0.28+flowNoise*0.55)*(1+fade*0.6);
        glow+=lineFX(d,width*2.8+aa)*fade*0.12;
        // A hot inner thread where each tongue leaves the ball.
        roots+=lineFX(d,width*0.32+aa)*fade*fade;
    }
    float mask=smoothstep(0.97,1.06,r);
    float3 color=float3(0.025,0.40,3.6)*(glow+crown*1.5)
        +float3(0.16,2.4,5.2)*(filaments+rim*0.5)
        +float3(1.6,4.0,5.2)*pow(saturate(filaments+rim*0.75),2.0)*0.55
        +float3(2.2,4.4,5.4)*roots*0.6;
    return float4(color*mask,saturate(filaments*0.58+rim*0.55+crown+roots*0.3)*mask);
}

// Most of this style comes from discrete ember births in the particle pass.
float4 emberWakeFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters,float footprint) {
    float R=max(1.0,u.ball.z),t=u.viewport.z,aa=max(0.012,footprint/R*0.5);
    float2 q=(pixel-u.ball.xy)/R;float r=length(q);
    float n=fireNoise3(float3(q*5.5+float2(0,t*2),t*0.7));
    float rim=lineFX(r-1.04-n*0.06,0.020+aa)*(0.35+n*0.9);
    float tinyFlames=lineFX(r-1.14-n*0.16,0.035+aa)*smoothstep(0.58,0.85,n)*0.45;
    StudyPath path=studyPathFX(pixel,u,emitters,0.5,0,0);
    float fade=pow(saturate(1-path.age/0.5),1.6);
    float wakeGlow=lineFX(path.distance,0.08+0.32*fade)*fade*0.22;
    float mask=smoothstep(0.97,1.06,r);
    float3 color=studyWarmFX(n*0.6+0.25)*(rim+tinyFlames)+studyWarmFX(0.35+fade*0.3)*wakeGlow;
    return float4(color*mask,(rim*0.5+tinyFlames*0.3+wakeGlow*0.35)*mask);
}

// Two warm ribbons curl along the path and open around the ball's sides.
float4 flameRibbonFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters,float footprint) {
    float R=max(1.0,u.ball.z),t=u.viewport.z,aa=max(0.013,footprint/R*0.55);
    float2 q=(pixel-u.ball.xy)/R;float r=length(q),angle=atan2(q.y,q.x);
    float3 color=0;float energy=0;
    for(int lane=-1;lane<=1;lane+=2) {
        StudyPath path=studyPathFX(pixel,u,emitters,0.775,float(lane)*1.6,2.25);
        float fade=pow(saturate(1-path.age/0.775),0.95);
        float width=0.020+0.050*fade;
        float flicker=0.82+0.18*sin(t*14+path.age*30+float(lane)*2.1);
        float core=lineFX(path.signedDistance,width+aa)*fade*flicker;
        float hot=lineFX(path.signedDistance,width*0.35+aa)*fade*fade;
        float glow=lineFX(path.signedDistance,width*6+aa)*fade*0.14;
        float silk=lineFX(path.signedDistance-float(lane)*0.09,width*2.6+aa)*fade*0.20;
        float satellite=lineFX(path.signedDistance+float(lane)*0.13,aa+0.016)*fade*0.27;
        float warm=lane==1?0.30:0.62;
        color+=studyWarmFX(warm)*(core+silk+satellite+glow)+studyWarmFX(0.95)*hot*0.7;
        energy+=core*0.7+silk+satellite*0.5+glow*0.4+hot*0.3;
    }
    float edge=1.10+0.045*sin(angle*3+t*1.6);
    float arc=lineFX(r-edge,aa+0.021)*(0.45+0.55*pow(abs(sin(angle+0.3)),2.0));
    color+=studyWarmFX(0.52)*arc*0.70;
    float mask=smoothstep(0.97,1.05,r);
    return float4(color*mask,saturate(energy+arc*0.6)*mask);
}

// Rings originate at the last confirmed touch, and remain there as the ball
// moves away. A gap in tracking suppresses the rings instead of guessing.
float4 heatPulseFX(float2 pixel,constant FXUniforms &u,constant float4 *emitters,float footprint) {
    float R=max(1.0,u.ball.z),t=u.viewport.z,aa=max(0.015,footprint/R*0.6);
    float2 q=(pixel-u.ball.xy)/R;float r=length(q);
    float n=fireFBM3(float3(q*4.5+float2(0,t*3.3),t*0.6));
    float rim=lineFX(r-1.05-n*0.1,0.032+aa);
    float flame=lineFX(r-1.12-n*0.24,0.07)*smoothstep(0.42,0.8,n)*0.55;
    float3 color=studyWarmFX(n*0.5+0.25)*(rim*0.65+flame);
    float energy=rim*0.48+flame*0.4;
    float age=u.environment.z;
    if(u.motion.z>0 && age>=0 && age<0.60) {
        float4 birth=wakeEmitterFX(age,emitters);
        if(birth.w>0) {
            float distance=length(pixel-birth.xy)/max(1.0,birth.z);
            for(int i=0;i<3;i++) {
                float ringAge=age-float(i)*0.055;
                if(ringAge<0)continue;
                float radius=1.16+ringAge*5.1;
                float fade=pow(saturate(1-ringAge/0.60),1.7)*smoothstep(0.0,0.028,ringAge);
                float strength=fade*(0.78-float(i)*0.16);
                float ring=lineFX(distance-radius,aa+0.014)*strength;
                float glow=lineFX(distance-radius,aa+0.09)*strength*0.28;
                color+=float3(4.6,1.6,0.16)*ring+float3(3.4,0.9,0.05)*glow;
                energy+=ring*0.62+glow*0.3;
            }
        }
    }
    float mask=smoothstep(0.97,1.055,r);
    return float4(color*mask,saturate(energy)*mask);
}
