#ifndef EFFECT_LAB_LIQUID
#define EFFECT_LAB_LIQUID
struct LiquidUniforms {float4 viewport,ball,options;};
struct LiquidPart {float4 centerSize,shape,material;};
constexpr sampler liquidSampler(coord::normalized,address::clamp_to_edge,filter::linear);
float2 lqRotate(float2 p,float angle) {float c=cos(angle),s=sin(angle);return float2(c*p.x-s*p.y,s*p.x+c*p.y);}
float3 lqSpectrum(float u) {
    const float3 c[7]={float3(1,.055,.015),float3(1,.39,.025),float3(1,.94,.07),float3(.06,1,.27),float3(.03,.83,1),float3(.08,.13,1),float3(.83,.06,1)};
    float x=saturate(u)*6;uint i=min(uint(x),5u);return mix(c[i],c[i+1],smoothstep(0.0,1.0,x-float(i)));
}
float3 lqBackdrop(float2 pixel,constant LiquidUniforms &u,texture2d<float> source) {
    if(u.options.z>0.5)return source.sample(liquidSampler,pixel/u.viewport.xy).rgb;
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
struct LiquidHit {float3 normal;float depth,thickness,coverage,hue,rim,size,film;float2 refraction;};
float3 lqEnvironment(float3 direction) {
    float up=smoothstep(-.4,.5,-direction.y);
    float3 env=mix(float3(.12,.19,.10),float3(.44,.68,.98),up);
    float horizon=exp(-pow((direction.y+.05)/.09,2));env+=horizon*float3(.9,.94,1.0);
    float window=exp(-pow((direction.x+.37)/.14,4))*exp(-pow((direction.y+.48)/.32,4));
    env+=window*float3(2.5,2.6,2.7);
    float dark=exp(-pow((direction.x-.52)/.12,2))*exp(-pow((direction.y-.08)/.45,2));
    return env*(1-dark*.72);
}
float3 lqShade(LiquidHit hit,float2 pixel,constant LiquidUniforms &u,texture2d<float> source) {
    float3 n=hit.normal,spectrum=lqSpectrum(hit.hue);
    float nearBall=u.options.x<.5 ? 0:1-smoothstep(1.15,2.75,length(pixel-u.ball.xy)/max(1.0,u.ball.z));
    float3 transmitted=lqBackdrop(pixel+hit.refraction,u,source);
    float3 absorption=float3(.015)+(1-spectrum)*(hit.film>.5?.88:.50+hit.rim*.50)*(1+.30*nearBall);
    transmitted*=exp(-absorption*hit.thickness*2.5);
    float f=.025+.975*pow(1-saturate(n.z),5);
    float3 reflected=lqEnvironment(reflect(float3(0,0,-1),n));
    reflected*=mix(float3(1),spectrum,hit.film>.5?.12+.28*hit.rim+.10*nearBall:.10+.55*hit.rim);
    float reflectWeight=saturate(hit.film>.5 ? .03+f*.85+hit.rim*.22 : f*.88+hit.rim*.28+.04);
    float3 color=mix(transmitted,reflected,reflectWeight);
    float highlight=pow(saturate(dot(n,normalize(float3(-.55,-.65,1.05)))),85);
    color+=float3(1.0,.98,.93)*highlight*(1.65+hit.rim*.9);
    // A narrow grazing reflection keeps the thinnest moving rims readable.
    color+=float3(.82,.92,1.0)*pow(1-saturate(n.z),4)*.20;
    return saturate(color);
}

// Density kernels are accumulated every frame. Connectivity is the level set
// of the transported fluid, not a stored polygon or animated splash cutout.
float4 liquidEffect(float2 pixel,constant LiquidUniforms &u,texture2d<float> field,texture2d<float> source) {
    float3 base=lqBackdrop(pixel,u,source);
    if(u.viewport.w<=0 || u.ball.w<=0)return float4(base,1);
    float outside=u.options.x<.5 ? 1:smoothstep(1.0,1.055,length(pixel-u.ball.xy)/max(1.0,u.ball.z));
    if(outside<=0)return float4(base,1);
    float2 uv=pixel/u.viewport.xy,du=1.0/u.viewport.xy;
    float4 f=field.sample(liquidSampler,uv);
    const float threshold=.40;
    float aa=max(.025,fwidth(f.x)*.65);
    if(f.x<threshold-aa)return float4(base,1);
    float4 l=field.sample(liquidSampler,uv-float2(du.x,0)),r=field.sample(liquidSampler,uv+float2(du.x,0));
    float4 t=field.sample(liquidSampler,uv-float2(0,du.y)),b=field.sample(liquidSampler,uv+float2(0,du.y));
    float density=max(threshold+.001,f.x),R=f.w/max(.001,f.x);
    float root=sqrt(max(.005,log(density/threshold)));
    float2 slope=float2(r.x-l.x,b.x-t.x)*(.5*.65*R/(2*root*density));
    if(min(min(l.x,r.x),min(t.x,b.x))>threshold) {
        slope+=float2(r.y/r.x-l.y/l.x,b.y/b.x-t.y/t.x)*u.ball.z*.5;
    }
    float3 n=normalize(float3(-slope,1));
    float rim=pow(1-n.z,1.2);
    LiquidHit hit={n,0,.10+.22*root,smoothstep(threshold-aa,threshold+aa,f.x),
        saturate(f.z/max(.001,f.x)),rim,R,1,-n.xy*R*(1.3+root*.7)};
    float3 surface=lqShade(hit,pixel,u,source);
    return float4(mix(base,surface,hit.coverage*outside*u.viewport.w*u.ball.w),1);
}
#endif
