#include <metal_stdlib>
// Prism, Wave and Night Pulse ball skins, accepted in the Effects Lab on 1 November 2026; the lab's shader, unchanged.
using namespace metal;
struct SkinUniforms{float4 viewport,ball,orientation,options;};
struct SkinVertex{float4 position [[position]];};
vertex SkinVertex surfaceSkinVertex(uint id [[vertex_id]]){return {float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),0,1)};}
constexpr sampler skinSample(coord::normalized,address::clamp_to_edge,filter::linear);
constexpr sampler skinEnvSample(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear,mip_filter::linear);
float3 skinRotate(float4 q,float3 v){return v+2*cross(q.xyz,cross(q.xyz,v)+q.w*v);}
float3 skinACES(float3 x){return saturate((x*(2.51*x+.03))/(x*(2.43*x+.59)+.14));}
float3 skinTurnY(float3 p,float a){return float3(cos(a)*p.x+sin(a)*p.z,p.y,-sin(a)*p.x+cos(a)*p.z);}
float3 skinTurnZ(float3 p,float a){return float3(cos(a)*p.x-sin(a)*p.y,sin(a)*p.x+cos(a)*p.y,p.z);}
float skinHash(float3 p){p=fract(p*.1031);p+=dot(p,p.yzx+33.33);return fract((p.x+p.y)*p.z);}
float skinNoise(float3 p){
    float3 i=floor(p),f=fract(p);f=f*f*(3-2*f);
    return mix(mix(mix(skinHash(i),skinHash(i+float3(1,0,0)),f.x),mix(skinHash(i+float3(0,1,0)),skinHash(i+float3(1,1,0)),f.x),f.y),mix(mix(skinHash(i+float3(0,0,1)),skinHash(i+float3(1,0,1)),f.x),mix(skinHash(i+float3(0,1,1)),skinHash(i+float3(1,1,1)),f.x),f.y),f.z);
}
struct SkinField{float seam;float ink;float accent;float id;float bulge;};
// A spherical star field uses local tangent frames aligned to neighbouring
// icosahedron sites. There is no texture projection seam or polar pinching.
SkinField skinPrism(float3 p,device const float4* sites,float aa){
    float distance=10;float id=0;
    for(uint i=0;i<12;i++){
        float3 center=sites[i].xyz;
        float alignment=dot(p,center);
        if(alignment<.45)continue;
        float3 anchor=sites[(i+1)%12].xyz;
        // Choose a neighbouring vertex to establish each star's orientation.
        for(uint j=0;j<12;j++){if(j!=i && dot(center,sites[j].xyz)>.4){anchor=sites[j].xyz;break;}}
        float3 tx=normalize(anchor-center*dot(anchor,center)),ty=cross(center,tx);
        float2 v=float2(dot(p,tx),dot(p,ty))/max(.15,alignment);
        float angle=atan2(v.y,v.x);
        float sector=abs(fract(angle/(2*M_PI_F/5)+.5)-.5)*(2*M_PI_F/5);
        float outer=.615,inner=.265;
        float radius=outer*inner*sin(M_PI_F/5)/(inner*sin(M_PI_F/5-sector)+outer*sin(sector));
        float d=(length(v)-radius)*.68;
        if(d<distance){distance=d;id=float(i);}
    }
    float ink=1-smoothstep(-aa,aa,distance);
    float edge=abs(distance);
    return {edge,ink,0,id,0};
}
// Smooth sphere warping bends the panel boundaries and their inset colour
// bands together. All coordinates remain in object space as the ball turns.
SkinField skinFlow(float3 p,int skin,device const float4* sites,float aa){
    float3 q=skinTurnZ(p,skin==1?2.15*p.y+.55*p.z:1.55*p.y-.65*p.z);
    q=skinTurnY(q,skin==1?1.10*sin(q.y*2.2)+.4*q.x:.85*sin(q.y*2.2)-.5*q.x);
    float first=-2,second=-2;uint closest=0,next=0;
    // Wave uses broad curved regions; Night Pulse uses a denser panel layout.
    uint count=skin==1?12:32;
    for(uint i=0;i<count;i++){
        float d=dot(q,sites[i].xyz);
        if(d>first){second=first;next=closest;first=d;closest=i;}else if(d>second){second=d;next=i;}
    }
    float gap=(first-second)/max(.01,length(sites[closest].xyz-sites[next].xyz));
    float3 center=sites[closest].xyz;
    float3 tangent=normalize(cross(center,abs(center.y)<.9?float3(0,1,0):float3(1,0,0)));
    float3 bitangent=cross(center,tangent);
    float x=dot(q,tangent),y=dot(q,bitangent);
    // A tapered, off-centre band gives each panel a sweeping shape.
    float band=gap-((skin==1?.128:.068)+(skin==1?.040:.018)*sin(y*8+x*5+float(closest)*.7));
    float width=(skin==1?.108:.053)*(.45+.55*smoothstep(-.32,.16,x+y*.35));
    float ink=(1-smoothstep(width-aa,width+aa,abs(band)))*smoothstep(.016,.035,gap);
    float accent=(1-smoothstep(.003+aa,.008+aa,abs(abs(band)-width-.013)))*smoothstep(.018,.04,gap);
    return {gap,ink,accent,float(closest),first};
}
SkinField skinField(float3 p,int skin,device const float4* sites,float aa){return skin==0?skinPrism(p,sites,aa):skinFlow(p,skin,sites,aa);}
float skinHeight(SkinField f){return .012*smoothstep(.002,.030,f.seam)+.055*f.bulge;}
float3 skinEnvironment(float3 r,float roughness,texture2d<float> env,bool outdoor){
    float3 v=float3(r.x,.258819*r.y-.965926*r.z,.965926*r.y+.258819*r.z);
    float2 uv=float2(atan2(v.x,v.z)/(2*M_PI_F)+.64,acos(clamp(v.y,-1.0,1.0))/M_PI_F);
    float3 studio=env.sample(skinEnvSample,uv,level(roughness*9+1.1)).rgb;
    studio=mix(float3(dot(studio,float3(.2126,.7152,.0722))),studio,.25);
    if(!outdoor)return studio*.25;
    float3 sky=mix(float3(.44,.56,.69),float3(.17,.31,.51),saturate(r.y));
    float3 ground=mix(float3(.055,.08,.025),float3(.20,.23,.11),saturate(r.y+1));
    float3 world=mix(ground,sky,smoothstep(-.1,.1,r.y));
    world*=1-.65*exp(-pow((r.x+.2)/.27,4))*exp(-pow((r.y+.02)/.4,4))*smoothstep(0.0,.5,r.z);
    return world+studio*.045;
}
fragment float4 surfaceSkinFragment(SkinVertex in [[stage_in]],constant SkinUniforms &u [[buffer(0)]],device const float4* sites [[buffer(1)]],texture2d<float> source [[texture(0)]],texture2d<float> environment [[texture(1)]]){
    float2 pixel=in.position.xy,uv=pixel/u.viewport.xy;
    bool outdoor=u.options.z>.5;
    float3 backdrop=outdoor?source.sample(skinSample,uv).rgb:mix(float3(.025,.031,.035),float3(.085,.091,.098),exp(-dot((uv-.5)*1.7,(uv-.5)*1.7)));
    float2 xy=float2(pixel.x-u.ball.x,u.ball.y-pixel.y)/max(1.0,u.ball.z);
    float rr=dot(xy,xy);
    if(rr>=1||u.ball.w<=0||u.viewport.w<=0)return float4(backdrop,1);
    float3 sphere=float3(xy,sqrt(max(.000001,1-rr))),p=skinRotate(float4(-u.orientation.xyz,u.orientation.w),sphere);
    int skin=int(u.options.w+.5);
    // Analytic sphere footprint stays defined at the clipped limb, where
    // derivative helper lanes can be inactive on a subsequent draw.
    float footprint=1/(max(1.0,u.ball.z)*max(.12,sphere.z)),aa=max(.0008,footprint*.55);
    SkinField f=skinField(p,skin,sites,aa);
    float3 tx=normalize(cross(p,abs(p.y)<.9?float3(0,1,0):float3(1,0,0))),ty=cross(p,tx);
    const float epsilon=.0015;
    float dx=(skinHeight(skinField(normalize(p+tx*epsilon),skin,sites,aa))-skinHeight(skinField(normalize(p-tx*epsilon),skin,sites,aa)))/(2*epsilon);
    float dy=(skinHeight(skinField(normalize(p+ty*epsilon),skin,sites,aa))-skinHeight(skinField(normalize(p-ty*epsilon),skin,sites,aa)))/(2*epsilon);
    // Filtered irregular microrelief, visible in studio and fading in video.
    float microAA=1-smoothstep(.5,1.8,footprint*190);
    float3 grain=p*245;
    const float ge=.12;
    float3 micro=.055*microAA*float3(skinNoise(grain+float3(ge,0,0))-skinNoise(grain-float3(ge,0,0)),skinNoise(grain+float3(0,ge,0))-skinNoise(grain-float3(0,ge,0)),skinNoise(grain+float3(0,0,ge))-skinNoise(grain-float3(0,0,ge)));
    float3 nObject=normalize(p-(tx*dx+ty*dy)*u.options.y+micro);
    float3 n=skinRotate(u.orientation,nObject);
    float3 reflection=reflect(float3(0,0,-1),n);
    float3 base=skin==2?float3(.009,.012,.017):float3(.64,.67,.70);
    float3 ink;float metallic=0,roughness=.36;
    if(skin==0){
        float phase=sin(dot(n,normalize(float3(-.7,.25,1)))*8+dot(p,float3(2,1,3))*.6);
        ink=mix(float3(.015,.42,.62),float3(.60,.67,.73),smoothstep(-.4,.75,phase));
        ink=mix(ink,float3(.36,.035,.32),pow(saturate(-phase),4)*.65);
        metallic=f.ink*.86;roughness=mix(.43,.26,f.ink);
    }else{
        int id=int(f.id)%3;
        if(skin==1)ink=id==0?float3(.60,.018,.028):id==1?float3(.015,.075,.43):float3(.008,.25,.16);
        else ink=id==0?float3(.57,.009,.23):id==1?float3(.008,.40,.59):float3(.115,.018,.26);
        roughness=mix(skin==2?.55:.43,.29,f.ink);metallic=f.ink*(skin==1?.22:.34);
    }
    base=mix(base,ink,f.ink);
    base*=1+microAA*(skinNoise(grain)-.5)*.12;
    float3 accent=skin==1?float3(.52,.31,.11):float3(.48,.58,.66);
    base=mix(base,accent,f.accent*.8);
    metallic=max(metallic,f.accent*.7);
    float groove=1-smoothstep(.003,.011+aa,f.seam);
    base=mix(base,float3(.008,.011,.016),groove*.97);
    float3 l=normalize(float3(-.55,.82,.85)),v=float3(0,0,1),halfVector=normalize(l+v);
    float diffuse=.085+.90*saturate(dot(n,l))+.035*saturate(dot(n,normalize(float3(.7,-.2,.4))));
    float3 color=base*diffuse*(1-metallic*.82);
    float3 f0=mix(float3(.04),base,metallic),F=f0+(1-f0)*pow(1-saturate(n.z),5);
    color+=skinEnvironment(reflection,roughness,environment,outdoor)*F*(1-groove*.75);
    float exponent=mix(210.0,35.0,roughness);
    color+=pow(saturate(dot(n,halfVector)),exponent)*F*(outdoor?2.0:1.3);
    color*=1-.30*(1-smoothstep(.003,.045,f.seam));
    color=pow(skinACES(color*(outdoor?.90:1.05)),float3(1/2.2));
    float coverage=smoothstep(0.0,1/max(1.0,u.ball.z),1-sqrt(rr))*u.ball.w*u.viewport.w;
    return float4(mix(backdrop,color,coverage),1);
}
