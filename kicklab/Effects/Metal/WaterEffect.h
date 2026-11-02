#ifndef EFFECT_LAB_WATER
#define EFFECT_LAB_WATER
struct WaterUniforms {float4 viewport,ball,options;};
struct WaterPart {float4 centerSize,shape,material,quadric0,quadric1;};
constexpr sampler waterSampler(coord::normalized,address::clamp_to_edge,filter::linear);
float2 wtRotate(float2 p,float angle) {float c=cos(angle),s=sin(angle);return float2(c*p.x-s*p.y,s*p.x+c*p.y);}
float3 wtBackdrop(float2 pixel,constant WaterUniforms &u,texture2d<float> source) {
    if(u.options.z>0.5)return source.sample(waterSampler,pixel/u.viewport.xy).rgb;
    float2 q=(pixel-u.ball.xy)/max(1.0,u.ball.z);
    float vignette=exp(-dot(q*0.12,q*0.12));
    float3 base=u.options.y>0.5 ? mix(float3(.40,.54,.64),float3(.86,.91,.93),vignette)
        : mix(float3(.018,.03,.04),float3(.08,.12,.16),vignette);
    // Fine background lines make refraction visible in the single-drop study.
    if(u.options.x<0.5) {
        float2 cell=abs(fract(pixel/(u.ball.z*.48))-.5);
        float grid=1-smoothstep(.01,.035,min(cell.x,cell.y));base*=1-grid*.13;
    } else if(dot(q,q)<1) {
        float3 n=float3(q,sqrt(max(0.0,1-dot(q,q))));float turn=u.viewport.z*.5;
        float3 p=float3(n.x*cos(turn)+n.z*sin(turn),n.y,-n.x*sin(turn)+n.z*cos(turn));
        float best=-10,second=-10;uint cell=0;
        for(uint i=0;i<32;i++) {float y=1-(float(i)+.5)/16,a=float(i)*2.399963;float3 dir=float3(sqrt(1-y*y)*cos(a),y,sqrt(1-y*y)*sin(a));float d=dot(p,dir);if(d>best){second=best;best=d;cell=i;}else second=max(second,d);}
        float seam=1-smoothstep(.002,.016,best-second);float shade=.30+.70*saturate(dot(n,normalize(float3(-.6,-.8,1.3))));
        base=(cell%5==0?float3(.06,.07,.075):float3(.87,.88,.85))*(1-seam*.65)*shade;
    }
    return base;
}
struct WaterHit {float3 normal;float depth,thickness,coverage,hue,rim,size,film;float2 refraction;};
float3 wtEnvironment(float3 direction) {
    float up=smoothstep(-.4,.5,-direction.y);
    float3 env=mix(float3(.12,.19,.10),float3(.44,.68,.98),up);
    float horizon=exp(-pow((direction.y+.05)/.09,2));env+=horizon*float3(.9,.94,1.0);
    float window=exp(-pow((direction.x+.37)/.14,4))*exp(-pow((direction.y+.48)/.32,4));
    env+=window*float3(2.5,2.6,2.7);
    float dark=exp(-pow((direction.x-.52)/.12,2))*exp(-pow((direction.y-.08)/.45,2));
    return env*(1-dark*.72);
}
float3 wtShade(WaterHit hit,float2 pixel,constant WaterUniforms &u,texture2d<float> source) {
    float3 n=hit.normal;
    float3 transmitted=wtBackdrop(pixel+hit.refraction,u,source);
    // Beer absorption tints thicker folds aqua; thin water stays clear.
    float thickness=hit.thickness;
    transmitted*=exp(-float3(1.35,.26,.09)*thickness);
    float fresnel=.0204+.9796*pow(1-saturate(n.z),5);
    float3 reflected=wtEnvironment(reflect(float3(0,0,-1),n));
    float weight=saturate(.055+fresnel*.82+hit.rim*.21);
    float3 color=mix(transmitted,reflected,weight);
    float specular=pow(saturate(dot(n,normalize(float3(-.55,-.65,1.05)))),110);
    color+=float3(1,.99,.97)*specular*1.8;
    color+=float3(.85,.95,1)*pow(1-saturate(n.z),4)*.16;
    return saturate(color);
}

// Water in a short airborne splash is mostly clear. Thickness modulates a
// restrained tint; bright reflections come from the sun/sky rather than an
// emissive rim. This material is separate from the earlier drop-only study.
float3 wtClearWater(WaterHit hit,float2 pixel,constant WaterUniforms &u,texture2d<float> source) {
    float3 n=hit.normal;
    float path=hit.thickness/max(.25,n.z);
    float bend=min(u.ball.z*.25,hit.size*(1.3+path*.65));
    float2 offset=-n.xy*bend;
    float3 transmission=wtBackdrop(pixel+offset,u,source);
    transmission*=exp(-float3(.50,.10,.045)*path);
    float fresnel=.0204+.9796*pow(1-saturate(n.z),5);
    float3 direction=reflect(float3(0,0,-1),n);
    float sky=smoothstep(-.25,.35,-direction.y);
    float3 environment=mix(float3(.07,.12,.10),float3(.18,.43,.60),sky);
    float horizon=exp(-pow((direction.y+.08)/.055,2));
    environment+=float3(.90,.98,1.0)*horizon;
    float3 color=mix(transmission,environment,saturate(.025+fresnel*.94));
    float sun=pow(saturate(dot(n,normalize(float3(-.55,-.65,1.05)))),160);
    float broad=pow(saturate(dot(n,normalize(float3(-.55,-.65,1.05)))),32);
    color+=float3(1,.98,.94)*(sun*1.55+broad*.05);
    // A weak transmitted-light modulation gives volume without outlining every
    // particle as a white ring. No time-varying noise drives the fluid shape.
    color*=1+.09*(1-n.z)*sky;
    return saturate(color);
}

// Density kernels are accumulated every frame. Connectivity is the level set
// of the transported fluid, not a stored polygon or animated splash cutout.
float4 waterEffect(float2 pixel,constant WaterUniforms &u,texture2d<float> field,texture2d<float> source) {
    float3 base=wtBackdrop(pixel,u,source);
    if(u.viewport.w<=0 || u.ball.w<=0)return float4(base,1);
    float outside=u.options.x<.5 ? 1:smoothstep(1.0,1.055,length(pixel-u.ball.xy)/max(1.0,u.ball.z));
    if(outside<=0)return float4(base,1);
    float2 uv=pixel/u.viewport.xy,du=1.0/u.viewport.xy;
    float4 f=field.sample(waterSampler,uv);
    const float threshold=.40;
    float4 l=field.sample(waterSampler,uv-float2(du.x,0)),r=field.sample(waterSampler,uv+float2(du.x,0));
    float4 t=field.sample(waterSampler,uv-float2(0,du.y)),b=field.sample(waterSampler,uv+float2(0,du.y));
    float aa=max(.035,length(float2(r.x-l.x,b.x-t.x))*.35);
    if(f.x<threshold-aa)return float4(base,1);
    float density=max(threshold+.001,f.x),R=f.w/max(.001,f.x);
    float root=sqrt(max(.005,log(density/threshold)));
    float2 slope=float2(r.x-l.x,b.x-t.x)*(.5*.95*R/(2*root*density));
    float interior=smoothstep(threshold,threshold+.3,min(min(l.x,r.x),min(t.x,b.x)));
    slope+=float2(r.y/max(.001,r.x)-l.y/max(.001,l.x),b.y/max(.001,b.x)-t.y/max(.001,t.x))*u.ball.z*.5*interior;
    float3 n=normalize(float3(-slope,1));
    float rim=pow(1-n.z,1.2);
    WaterHit hit={n,0,.08+.20*root,smoothstep(threshold-aa,threshold+aa,f.x),
        saturate(f.z/max(.001,f.x)),rim,R,1,-n.xy*R*(1.3+root*.7)};
    float3 surface=wtShade(hit,pixel,u,source);
    return float4(mix(base,surface,hit.coverage*outside*u.viewport.w*u.ball.w),1);
}
float4 waterVolumeEffect(float2 pixel,constant WaterUniforms &u,texture2d<float> field,texture2d<float> front,texture2d<float> source) {
    float2 uv=pixel/u.viewport.xy;
    uint2 ip=uint2(pixel),limit=uint2(front.get_width()-1,front.get_height()-1);
    float4 center=front.read(min(ip,limit));
    if(u.options.x<.5)return waterEffect(pixel,u,field,source);
    if(center.w<.5)return float4(wtBackdrop(pixel,u,source),1);
    float3 base=wtBackdrop(pixel,u,source);
    float outside=smoothstep(1.0,1.055,length(pixel-u.ball.xy)/max(1.0,u.ball.z));
    if(u.viewport.w<=0 || u.ball.w<=0 || outside<=0)return float4(base,1);
    float4 l=front.read(uint2(max(1u,ip.x)-1,ip.y)),r=front.read(min(ip+uint2(1,0),limit));
    float4 t=front.read(uint2(ip.x,max(1u,ip.y)-1)),b=front.read(min(ip+uint2(0,1),limit));
    float dx=l.w<.5 && r.w<.5 ? 0:l.w<.5 ? r.x-center.x:r.w<.5 ? center.x-l.x:(r.x-l.x)*.5;
    float dy=t.w<.5 && b.w<.5 ? 0:t.w<.5 ? b.x-center.x:b.w<.5 ? center.x-t.x:(b.x-t.x)*.5;
    float3 n=normalize(float3(-dx,-dy,1));
    float4 density=field.sample(waterSampler,uv);
    float coverage=smoothstep(.08,.30,density.x)*outside*u.viewport.w*u.ball.w;
    float thickness=.05+.16*min(12.0,density.x);
    WaterHit hit={n,center.x,thickness,coverage,0,pow(1-n.z,1.2),center.z,0,-n.xy*center.z*1.7};
    return float4(mix(base,wtClearWater(hit,pixel,u,source),coverage),1);
}
#endif
