#include <metal_stdlib>
// Gold Polish ball skin, accepted in the Effects Lab on 1 November 2026; the lab's shader, with
// one change at the rim (see goldFragment).
using namespace metal;
struct GoldUniforms {float4 viewport,ball,orientation,options;};
struct GoldVertex {float4 position [[position]];};
vertex GoldVertex goldVertex(uint id [[vertex_id]]) {
    float2 p=id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3);
    return {float4(p,0,1)};
}
constexpr sampler goldSampler(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
constexpr sampler goldEnvironmentSampler(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear,mip_filter::linear);
float3 goldRotate(float4 q,float3 v) {return v+2*cross(q.xyz,cross(q.xyz,v)+q.w*v);}
float3 goldACES(float3 x) {return saturate((x*(2.51*x+.03))/(x*(2.43*x+.59)+.14));}
// Object-space polish variations: analytic height derivatives, filtered at the
// pixel footprint so the fine surface does not crawl on the small footage ball.
float4 goldWaves(float3 p) {
    float3 a=float3(1.4,2.2,-.8),b=float3(-2,1.3,1.9),c=float3(2.6,-1.1,1.2);
    float x=dot(p,a),y=dot(p,b)+1.7,z=dot(p,c)+4.1;
    return float4(a*cos(x)*sin(y)*sin(z)+b*sin(x)*cos(y)*sin(z)+c*sin(x)*sin(y)*cos(z),sin(x)*sin(y)*sin(z));
}
float goldHash(float2 p) {float3 v=fract(float3(p.xyx)*.1031);v+=dot(v,v.yzx+33.33);return fract((v.x+v.y)*v.z);}
float3 goldScratches(float2 uv,float pixelWidth) {
    float2 cell=floor(uv*40),p=fract(uv*40)-.5;
    float seed=goldHash(cell),angle=seed*6.283185;
    float2 axis=float2(cos(angle),sin(angle)),across=float2(-axis.y,axis.x);
    float d=dot(p,across),along=dot(p,axis);
    float width=.027+pixelWidth*40*.35;
    float end=1-smoothstep(.16,.41,abs(along));
    float aa=1-smoothstep(.25,.7,pixelWidth*40);
    float profile=exp(-d*d/(width*width))*end*step(.55,seed)*aa;
    return float3(across*(-2*d/(width*width))*profile*40,profile);
}
float3 goldStudio(float3 r,float roughness,texture2d<float> environment) {
    // Tilt the window environment so a broad highlight reaches the upper-left
    // panels, leaving lower gold midtones readable instead of uniformly pale.
    r=float3(r.x,.258819*r.y-.965926*r.z,.965926*r.y+.258819*r.z);
    float2 uv=float2(atan2(r.x,r.z)/(2*M_PI_F)+.64,acos(clamp(r.y,-1.0,1.0))/M_PI_F);
    float3 value=environment.sample(goldEnvironmentSampler,uv,level(roughness*10+.7)).rgb;
    return mix(float3(dot(value,float3(.2126,.7152,.0722))),value,.55);
}
float3 goldOutdoor(float3 r,float roughness,texture2d<float> environment) {
    float sky=smoothstep(-.08,.12,r.y);
    float3 ground=mix(float3(.07,.10,.025),float3(.27,.32,.08),smoothstep(-1.0,0.0,r.y));
    float3 blue=mix(float3(.55,.72,.95),float3(.10,.28,.64),smoothstep(0.0,1.0,r.y));
    float3 base=mix(ground,blue,sky);
    // A horizon and dark foreground provide readable curvature. This is an
    // approximate lighting environment, not a reconstruction of unseen scenery.
    float silhouette=exp(-pow((r.x+.15)/.26,4))*exp(-pow((r.y+.02)/.34,4))*smoothstep(.0,.5,r.z);
    base*=1-silhouette*.86;
    float cloud=exp(-pow((r.y-.22)/.12,2))*exp(-pow((r.x+.48)/.38,2));
    base+=cloud*.55;
    return base*.65+goldStudio(r,roughness,environment)*.10;
}
fragment float4 goldFragment(GoldVertex in [[stage_in]],constant GoldUniforms &u [[buffer(0)]],
    device const float4 *panels [[buffer(1)]],texture2d<float> source [[texture(0)]],texture2d<float> environment [[texture(1)]]) {
    float2 pixel=in.position.xy,uv=pixel/u.viewport.xy;
    float3 backdrop=u.options.z>.5 ? source.sample(goldSampler,uv).rgb : mix(float3(.025,.031,.035),float3(.075,.080,.085),exp(-dot((uv-.5)*1.5,(uv-.5)*1.5)));
    float2 xy=float2(pixel.x-u.ball.x,u.ball.y-pixel.y)/max(1.0,u.ball.z);
    float rr=dot(xy,xy),aa=1/max(1.0,u.ball.z);
    // Pixels just outside the ball stay in the flow (coverage hides them) so the rim's dfdx and
    // fwidth read defined neighbours; the lab's early return here left them varying between runs.
    if(u.ball.w<=0 || u.viewport.w<=0)return float4(backdrop,1);
    float3 sphere=float3(xy,sqrt(max(0.000001,1-rr)));
    float4 inverse=float4(-u.orientation.xyz,u.orientation.w);
    float3 object=goldRotate(inverse,sphere);
    float first=-2,second=-2;uint closest=0,next=0;
    for(uint i=0;i<32;i++) {
        float d=dot(object,panels[i].xyz);
        if(d>first){second=first;next=closest;first=d;closest=i;}else if(d>second){second=d;next=i;}
    }
    float3 edge=panels[closest].xyz-panels[next].xyz;
    float edgeLength=max(.001,length(edge));
    float gap=(first-second)/edgeLength;
    // Smooth rounded panel interior, with local bevels at every nearby edge.
    // Using only the second-closest site for the whole panel creates false
    // triangular ridges whenever that second site changes.
    float3 gradient=.58*(panels[closest].xyz-object*first);
    for(uint i=0;i<32;i++) {if(i!=closest) {
        float3 delta=panels[closest].xyz-panels[i].xyz;
        float len=max(.001,length(delta)),distance=(first-dot(object,panels[i].xyz))/len;
        float t=saturate((distance-.001)/.044);
        float slope=distance>.001 && distance<.045 ? .019*6*t*(1-t)/.044:0;
        gradient+=(delta-object*dot(object,delta))*(slope/len);
    }}
    float footprint=max(length(dfdx(object)),length(dfdy(object)));
    float4 roll=goldWaves(object*12),polish=goldWaves(object*37),fine=goldWaves(object*95);
    float3 variation=roll.xyz*.002+polish.xyz*.0015*(1-smoothstep(.5,1.8,footprint*37))+fine.xyz*.0008*(1-smoothstep(.5,1.8,footprint*95));
    float3 site=panels[closest].xyz;
    float3 tangent=normalize(cross(site,abs(site.y)<.9 ? float3(0,1,0):float3(1,0,0))),bitangent=cross(site,tangent);
    float3 scratch=goldScratches(float2(dot(object,tangent),dot(object,bitangent))+float(closest)*.723,footprint);
    float3 scratchSlope=(tangent*scratch.x+bitangent*scratch.y)*.000010;
    gradient+=(variation-object*dot(object,variation)+scratchSlope)*smoothstep(.006,.045,gap);
    float3 nObject=normalize(object-gradient*u.options.y);
    float3 n=goldRotate(u.orientation,nObject);
    float3 reflection=reflect(float3(0,0,-1),n);
    float roughness=clamp(u.options.x+.020*polish.w+.015*roll.w+scratch.z*.07,.08,.5);
    float3 lighting=u.options.z>.5 ? goldOutdoor(reflection,roughness,environment):goldStudio(reflection,roughness,environment);
    if(u.options.z>.5)lighting=mix(float3(dot(lighting,float3(.2126,.7152,.0722))),lighting,.60);
    float3 f0=float3(1.0,.59,.18);
    float3 fresnel=f0+(1-f0)*pow(1-saturate(n.z),5);
    float groove=1-smoothstep(.003,.012+min(.004,fwidth(gap)),gap);
    float3 color=lighting*fresnel*(1-groove*.76)*(1-scratch.z*.14);
    float3 halfVector=normalize(normalize(float3(-.48,.65,1.2))+float3(0,0,1));
    float exponent=mix(620.0,80.0,saturate((roughness-.08)/.42));
    float spec=pow(saturate(dot(n,halfVector)),exponent);
    color+=spec*f0*(u.options.z>.5 ? 3.0:.8);
    color+=f0*.008*(1-groove*.8);
    color=pow(goldACES(color*.75),float3(1/2.2));
    float coverage=smoothstep(0.0,aa,1-sqrt(rr))*u.ball.w*u.viewport.w;
    return float4(mix(backdrop,color,coverage),1);
}
