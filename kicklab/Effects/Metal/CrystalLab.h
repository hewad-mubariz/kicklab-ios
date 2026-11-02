#include <metal_stdlib>
using namespace metal;

constexpr sampler iceSampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
#ifdef ICE_FOOTAGE
#define FOOTAGE_PARAMETER , texture2d<float> footage
#define FOOTAGE_ARGUMENT , footage
#else
#define FOOTAGE_PARAMETER
#define FOOTAGE_ARGUMENT
#endif
struct Uniforms {
    float4 viewport, material, scene, ball;
#ifdef ICE_FOOTAGE
    float4 footageTransform; // tracked center in pixels, pixels per world unit
    float4 atmosphere; // puff count, dust count, confirmed-contact strength
#endif
};
struct Instance { float4 centerScale, rotationSeed, appearance; };
struct Varying { float4 position [[position]]; };
vertex Varying labVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * 2 - 1, 0, 1)};
}
float h1(float n) { return fract(sin(n * 127.1 + 311.7) * 43758.5453); }
float3 h3(float n) { return float3(h1(n), h1(n+19.7), h1(n+43.2)); }
float hashCell(int3 p) {
    uint3 q=as_type<uint3>(p); uint n=q.x*374761393u+q.y*668265263u+q.z*2246822519u;
    n=(n^(n>>13))*1274126177u; n^=n>>16; return float(n&0xFFFFFFu)/16777215.0;
}
float noise3(float3 p) {
    int3 c=int3(floor(p)); float3 f=fract(p); f=f*f*(3-2*f);
    return mix(mix(mix(hashCell(c),hashCell(c+int3(1,0,0)),f.x),mix(hashCell(c+int3(0,1,0)),hashCell(c+int3(1,1,0)),f.x),f.y),
               mix(mix(hashCell(c+int3(0,0,1)),hashCell(c+int3(1,0,1)),f.x),mix(hashCell(c+int3(0,1,1)),hashCell(c+int3(1,1,1)),f.x),f.y),f.z);
}
float3 gradient(float3 p) {
    float e=.025;
    return float3(noise3(p+float3(e,0,0))-noise3(p-float3(e,0,0)),noise3(p+float3(0,e,0))-noise3(p-float3(0,e,0)),noise3(p+float3(0,0,e))-noise3(p-float3(0,0,e)))/(2*e);
}
float3x3 rotation(float3 a) {
    float3 c=cos(a),s=sin(a);
    return float3x3(float3(c.z,s.z,0),float3(-s.z,c.z,0),float3(0,0,1))*
        float3x3(float3(c.y,0,-s.y),float3(0,1,0),float3(s.y,0,c.y))*
        float3x3(float3(1,0,0),float3(0,c.x,s.x),float3(0,-s.x,c.x));
}

float fresnel(float cosine,float eta) {
    cosine=saturate(abs(cosine)); float sin2=(1-cosine*cosine)/(eta*eta);
    if(sin2>=1) return 1;
    float ct=sqrt(1-sin2);
    float a=(eta*cosine-ct)/(eta*cosine+ct),b=(cosine-eta*ct)/(cosine+eta*ct);
    return (a*a+b*b)*.5;
}
float sphereZ(float2 p,constant Uniforms &u) {
    float2 d=p-u.ball.xy; float r=u.ball.z;
    return r>0 && dot(d,d)<r*r ? sqrt(r*r-dot(d,d)) : -100.0;
}
float3 backdrop(float2 p,constant Uniforms &u FOOTAGE_PARAMETER) {
#ifdef ICE_FOOTAGE
    constexpr sampler sourceSampler(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv=(u.footageTransform.xy+p*u.footageTransform.z)/u.viewport.xy;
    return pow(max(footage.sample(sourceSampler,uv).rgb,float3(0)),float3(2.2));
#else
    float glow=exp(-dot(p-float2(-.7,-.6),p-float2(-.7,-.6))*.25);
    float3 c=mix(float3(.055,.072,.094),float3(.18,.22,.27),glow);
    if(u.material.z>.5 && u.material.z<1.5) c=mix(float3(.64,.69,.73),float3(.88,.90,.91),glow);
    if(u.material.z>1.5) {
        float2 f=abs(fract(p*3)-.5);
        float line=smoothstep(.46,.49,max(f.x,f.y));
        c=mix(c,float3(.40,.45,.49),line*.45);
    }
    float z=sphereZ(p,u);
    if(z> -50) {
        float3 n=normalize(float3(p-u.ball.xy,z));
        float3 l=normalize(float3(-.6,-.8,1.3));
        float diffuse=.30+.70*saturate(dot(n,l));
        float3 albedo=float3(.45,.48,.50);
        if(u.material.w>.5) {
            // A procedural panelled placeholder; it does not use ball assets.
            float best=-10,second=-10;int index=0;
            for(uint i=0;i<32;i++) {
                float y=1-(float(i)+.5)/16, a=float(i)*2.399963;
                float3 q=float3(sqrt(1-y*y)*cos(a),y,sqrt(1-y*y)*sin(a));
                float d=dot(n,q);
                if(d>best){second=best;best=d;index=int(i);}else second=max(second,d);
            }
            float seam=1-smoothstep(.002,.014,best-second);
            albedo=mix(float3(.68,.70,.70),float3(.13,.16,.18),float(index%5==0));
            albedo*=1-seam*.55;
            albedo*=.94+.06*noise3(n*170);
        }
        float spec=pow(saturate(dot(n,normalize(l+float3(0,0,1)))),30.0)*.12;
        c=albedo*diffuse+spec;
    }
    return pow(max(c,float3(0)),float3(2.2));
#endif
}


struct Triangle { float4 a,b,c,na,nb,nc; };
struct BVHNode { float4 lower,upper,range; };
struct MeshHit { float t; float2 uv; uint id; bool found; };

bool boxHit(float3 ro,float3 rd,float3 lo,float3 hi,float limit) {
    float3 safe=select(float3(1e-8),rd,abs(rd)>1e-8);
    float3 a=(lo-ro)/safe,b=(hi-ro)/safe;
    float3 lower=min(a,b),upper=max(a,b);
    return max(max(lower.x,lower.y),max(lower.z,0.0))<=min(min(upper.x,upper.y),min(upper.z,limit));
}
MeshHit meshHit(float3 ro,float3 rd,uint root,device const Triangle *triangles,device const BVHNode *nodes) {
    MeshHit hit={1e5,float2(0),0,false};
    uint stack[32];uint size=1;stack[0]=root;
    while(size>0) {
        uint nodeID=stack[--size];
        BVHNode node=nodes[nodeID];
        if(!boxHit(ro,rd,node.lower.xyz,node.upper.xyz,hit.t))continue;
        if(node.range.y>0) {
            uint end=uint(node.range.x+node.range.y);
            for(uint i=uint(node.range.x);i<end;i++) {
                Triangle tri=triangles[i];
                float3 e1=tri.b.xyz-tri.a.xyz,e2=tri.c.xyz-tri.a.xyz;
                float3 q=cross(rd,e2);float det=dot(e1,q);
                if(abs(det)<1e-8)continue;
                float inv=1/det;float3 offset=ro-tri.a.xyz;
                float u=dot(offset,q)*inv;if(u<0 || u>1)continue;
                float3 r=cross(offset,e1);float v=dot(rd,r)*inv;if(v<0 || u+v>1)continue;
                float t=dot(e2,r)*inv;
                if(t>.00008 && t<hit.t)hit={t,float2(u,v),i,true};
            }
        } else {
            // Authoring validates that BVH depth stays below this stack budget.
            stack[size++]=uint(node.lower.w);stack[size++]=uint(node.upper.w);
        }
    }
    return hit;
}
float3 geometricNormal(Triangle t) { return normalize(cross(t.b.xyz-t.a.xyz,t.c.xyz-t.a.xyz)); }
float3 shadingNormal(Triangle t,float2 uv) { return normalize(t.na.xyz*(1-uv.x-uv.y)+t.nb.xyz*uv.x+t.nc.xyz*uv.y); }
float edgeDistance(Triangle t,float2 uv) { return t.a.w*(1-uv.x-uv.y)+t.b.w*uv.x+t.c.w*uv.y; }

constexpr sampler envSampler(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
float3 environment(float3 direction,texture2d<float> studio,float blue) {
    // The source is linear, unclipped Radiance HDR, not a tone-mapped photograph.
    float3 d=normalize(direction);
    float angle=.65;
    d.xz=float2(cos(angle)*d.x-sin(angle)*d.z,sin(angle)*d.x+cos(angle)*d.z);
    float2 uv=float2(atan2(d.z,d.x)/(2*M_PI_F)+.5,acos(clamp(-d.y,-1.0,1.0))/M_PI_F);
    float3 light=studio.sample(envSampler,uv,level(2.2)).rgb*1.65;
    // Surface reflections stay nearly neutral. The blue control primarily
    // affects transmission through the volume, not a blue coating on each face.
    float rim=pow(saturate(dot(d,normalize(float3(.85,.12,.34)))),24.0);
    float side=pow(abs(d.x),18.0);
    float white=smoothstep(1.2,6.0,dot(light,float3(.2126,.7152,.0722)));
    float3 ambientTint=mix(float3(.94,.99,1.06),float3(.65,.83,1.06),saturate(blue)*.30*(1-white));
    float cool=pow(saturate(dot(d,normalize(float3(-.20,-.38,.90)))),10.0);
    float3 coolLight=mix(float3(.5),float3(.50,1.7,3.4),saturate(blue))*3;
    return (light*ambientTint+float3(.016,.023,.032)+float3(2.0,2.25,2.6)*rim+float3(1.2,1.4,1.7)*side+coolLight*cool)*1.5;
}

// A bounded single-scattering estimate integrated over the actual refracted
// segment. Light-to-sample distance is measured against the closed mesh. This
// supplies depth-dependent lighting rather than a uniform blue surface coat.
float3 volumeLight(float3 origin,float3 direction,float length,float3 sigmaT,float sigmaS,
                   uint root,device const Triangle *triangles,device const BVHNode *nodes,
                   float3x3 rot,float blue) {
    float3 incoming=transpose(rot)*normalize(float3(-.58,.36,-.75));
    float3 midpoint=origin+direction*length*.5;
    MeshHit exit=meshHit(midpoint,incoming,root,triangles,nodes);
    if(!exit.found)return float3(0);
    float3 normal=shadingNormal(triangles[exit.id],exit.uv);
    float entry=1-fresnel(dot(incoming,normal),1.31);
    // A broad phase lobe avoids a narrow cyan hotspot when the shard turns.
    float phase=.9775/pow(1.0225-.30*dot(direction,incoming),1.5)/(4*M_PI_F);
    #ifdef ICE_FOOTAGE
    float3 light=mix(float3(4.5),float3(2.0,4.8,9.0),saturate(blue))*4.2;
#else
    float3 light=mix(float3(3.0),float3(3.0,5.5,9.0),saturate(blue))*3.3;
#endif
    float3 lightTransmission=exp(-sigmaT*exit.t)*entry;
    return light*lightTransmission*phase*sigmaS*(1-exp(-sigmaT*length))/sigmaT;
}
float3 outsideRadiance(float3 localPoint,float3 localDirection,float3x3 rot,constant Instance &object,
                       constant Uniforms &u,texture2d<float> studio FOOTAGE_PARAMETER) {
    float3 d=rot*localDirection;
    float3 p=rot*localPoint*object.centerScale.w+object.centerScale.xyz;
    // Off-camera studio cards are visible through refraction. Their finite
    // extent makes adjacent crystal faces catch different blue/white light.
    if(abs(d.x)>.05) {
        float t=((d.x<0?-2.8:2.8)-p.x)/d.x;
        float3 hit=p+d*t;
        if(t>0 && hit.z<-.05 && hit.z>-3.7 && abs(hit.y)<2.2) {
            float mask=(1-smoothstep(1.75,2.2,abs(hit.y)))*(1-smoothstep(3.2,3.7,-hit.z));
            float3 card=d.x<0?mix(float3(.9),float3(.16,.43,1.05),saturate(u.scene.w)):float3(1.15,1.4,1.7);
            return card*mask+backdrop(p.xy,u FOOTAGE_ARGUMENT)*(1-mask);
        }
    }
    if(d.z<-.035) {
        float travel=clamp((-1.4-p.z)/d.z,0.0,6.0);
        return backdrop(p.xy+d.xy*travel,u FOOTAGE_ARGUMENT);
    }
    return environment(d,studio,u.scene.w);
}

// Cracks are finite sheets inside the solid. Intersections are computed along
// the bent light path; they have depth/parallax and are never billboards.
float3 fractures(float3 origin,float3 direction,float distance,float seed,float aa,float3x3 rot,
                  constant Instance &object,constant Uniforms &uniforms,texture2d<float> studio,float blue FOOTAGE_PARAMETER) {
    float3 result=0;
    uint primaryCount=6,crackCount=9;
    float patternTurn=0,crackDepth=-.015;
#ifdef ICE_FOOTAGE
    // A birth-stable fracture layout per crystal, not one repeated star pattern.
    primaryCount=3+uint(h1(seed+87.2)*4);
    crackCount=primaryCount+1+uint(h1(seed+90.8)*3);
    patternTurn=h1(seed+92.1)*2*M_PI_F;
    crackDepth=(h1(seed+94.7)-.5)*.18;
#endif
    for(uint i=0;i<crackCount;i++) {
        float k=float(i);
        float2 shift=float2(h1(seed+16),h1(seed+31))*.14-.07;
#ifdef ICE_FOOTAGE
        shift=float2(h1(seed+16),h1(seed+31))*.38-.19;
#endif
        bool primary=i<primaryCount;
        float2 junction=(primary?float2(.015,-.04):float2(.40,.30))+shift;
        float crackLength=primary?1.0:.46;
        float angle=primary?k*(2*M_PI_F/float(primaryCount))+.24+(.5-h1(k*13+seed))*.28:(k-float(primaryCount))*2.1+.48;
        angle+=patternTurn;
#ifdef ICE_FOOTAGE
        crackLength*=.67+h1(seed+k*17.3+97.1)*.43;
#endif
        float2 along=float2(cos(angle),sin(angle)),across=float2(-along.y,along.x);
        float3 plane=normalize(float3(across*.18,1));
        float planeDen=dot(direction,plane);
        if(abs(planeDen)<1e-5)continue;
        float t=dot(float3(junction,crackDepth)-origin,plane)/planeDen;
        if(t<0 || t>distance)continue;
        float3 point=origin+direction*t;
        float2 q=point.xy-junction;
        float longitudinal=dot(q,along),lateral=dot(q,across);
        float position=longitudinal*25;
        float drift=(mix(h1(floor(position)+k*21),h1(floor(position)+1+k*21),fract(position))-.5)*.014;
        float width=max(.0014+.0024*pow(noise3(float3(longitudinal*100,k,seed)),3.0),aa*.28);
        float crack=exp(-pow((lateral+drift)/width,2.0));
        float halo=exp(-pow((lateral+drift)/(width*3),2.0))*.10;
        float extent=smoothstep(-.012,.016,longitudinal)*(1-smoothstep(crackLength*.65,crackLength*.99,longitudinal));
        float3 n=normalize(float3(across,.28));
        float3 reflected=outsideRadiance(point,reflect(direction,n),rot,object,uniforms,studio FOOTAGE_ARGUMENT);
        // Irregular reflective facets along a broken air/ice interface.
        float glint=.22+.78*noise3(point*75+seed);
        result+=(float3(.38,.58,.79)+min(reflected,float3(7))*.20)*(crack+halo)*extent*glint;
        // Short branching offshoots, tied to the same main crack.
        float branch=abs(lateral-(longitudinal-.34)*.53);
        float limb=exp(-pow(branch/(width*.55),2.0))*smoothstep(.28,.36,longitudinal)*(1-smoothstep(.46,.59,longitudinal));
        result+=float3(.22,.35,.48)*limb;
        // The air-filled wall beneath the hairline is a separate, finite
        // reflective interface. Oblique paths reveal its width and depth.
        float3 wallNormal=normalize(float3(across,.21+.12*h1(k+7)));
        float wallDen=dot(direction,wallNormal);
        float wallT=abs(wallDen)>1e-5?dot(float3(junction,crackDepth-.01)-origin,wallNormal)/wallDen:-1;
        if(wallT>0 && wallT<distance) {
            float3 wall=origin+direction*wallT-float3(junction,crackDepth-.01);
            float alongWall=dot(wall.xy,along);
            float extentWall=smoothstep(.015,.055,alongWall)*(1-smoothstep(crackLength*.67,crackLength*.89,alongWall));
            float height=1-smoothstep(.016,.038,abs(wall.z));
            float chipped=.35+.65*noise3(wall*90+k);
            float3 reflectWall=outsideRadiance(origin+direction*wallT,reflect(direction,wallNormal),rot,object,uniforms,studio FOOTAGE_ARGUMENT);
            float reflectance=fresnel(dot(direction,wallNormal),1/1.31);
            result+=min(reflectWall,float3(4.5))*reflectance*extentWall*height*chipped*.28;
        }
    }
    // Separate irregular air walls sit at different depths within the solid.
    // They reveal parallax and colored light behind the clear front surface.
    uint wallCount=14;
#ifdef ICE_FOOTAGE
    wallCount=6+uint(h1(seed+99.4)*9);
#endif
    for(uint i=0;i<wallCount;i++) {
        float k=float(i),f=(k+.5)/float(wallCount);
        float3 center=float3(mix(-.63,.72,f),mix(-.48,.48,f)+(h1(k+seed)-.5)*.26,(h1(k+seed+9)-.5)*.25);
        float angle=k*2.399963+seed;
        float3 normal=normalize(float3(cos(angle),sin(angle),.24+h1(k+seed+4)*.6));
        float denominator=dot(direction,normal);if(abs(denominator)<1e-5)continue;
        float t=dot(center-origin,normal)/denominator;
        if(t<0 || t>distance)continue;
        float3 tangent=normalize(cross(normal,float3(0,0,1))),bitangent=cross(normal,tangent);
        float3 point=origin+direction*t,offset=point-center;
        float x=dot(offset,tangent)/(.10+h1(k+seed+5)*.17);
        float y=dot(offset,bitangent)/(.065+h1(k+seed+7)*.10);
        float boundary=max(max(abs(x),abs(y)),(abs(x)+abs(y)*.4)/1.18);
        if(boundary>=1)continue;
        float reflectance=fresnel(dot(direction,normal),1/1.31);
        float3 light=outsideRadiance(point,reflect(direction,normal),rot,object,uniforms,studio FOOTAGE_ARGUMENT);
        float border=1-smoothstep(.87,1.0,boundary);
        float broken=.45+.55*noise3(point*53+seed);
        result+=min(light,float3(3.0))*reflectance*border*broken*.27;
    }
    return result;
}

float3 shadeIce(float2 screen,float3 ro,float3 rd,MeshHit first,uint root,
                device const Triangle *triangles,device const BVHNode *nodes,
                float3x3 rot,constant Instance &object,constant Uniforms &u,float aa,
                texture2d<float> normalTex,texture2d<float> detailTex,texture2d<float> roughTex,texture2d<float> studio FOOTAGE_PARAMETER) {
    Triangle tri=triangles[first.id];
    float3 point=ro+rd*first.t;
    float3 gn=geometricNormal(tri),normal=shadingNormal(tri,first.uv);
    float edge=edgeDistance(tri,first.uv),seed=object.rotationSeed.w;
    float grainScale=.43,fractureAmount=u.material.x;
    float2 grainPoint=point.xy,grainOffset=float2(.18,.24);
#ifdef ICE_FOOTAGE
    // All variation is in local material coordinates and seeded at birth.
    // Turning pieces reveal the same detail instead of shimmering noise.
    float grainTurn=h1(seed+102.3)*2*M_PI_F;
    grainScale=.31+h1(seed+105.7)*.22;
    grainPoint=float2(cos(grainTurn)*point.x+sin(grainTurn)*point.y,-sin(grainTurn)*point.x+cos(grainTurn)*point.y);
    grainOffset=float2(h1(seed+108.2),h1(seed+110.9))*3;
    float grainAmount=h1(seed+113.6);
    fractureAmount*=mix(.65,1.25,h1(seed+116.2));
#endif
    float2 uv=grainPoint*grainScale+grainOffset;
    float lod=max(0.0,log2(max(.001,aa*grainScale*float(normalTex.get_width()))));
    float3 bump=normalTex.sample(iceSampler,uv,level(lod)).xyz*2-1;
    float3 tangent=normalize(cross(abs(normal.y)<.85?float3(0,1,0):float3(1,0,0),normal));
    float3 bitangent=cross(normal,tangent);
    #ifdef ICE_FOOTAGE
    bump.xy=float2(cos(grainTurn)*bump.x-sin(grainTurn)*bump.y,sin(grainTurn)*bump.x+cos(grainTurn)*bump.y);
    float bumpStrength=.022*mix(.55,1.30,grainAmount);
#else
    float bumpStrength=.07;
#endif
    normal=normalize(normal+(tangent*bump.x-bitangent*bump.y)*bumpStrength*u.scene.z);
    if(dot(normal,rd)>-.02)normal=gn;
    float f=fresnel(dot(-rd,normal),1.31);
    float3 color=environment(rot*reflect(rd,normal),studio,u.scene.w)*f;
    float3 throughput=float3(1-f);
    float3 direction=refract(rd,normal,1/1.31);
    if(dot(direction,gn)>0)direction=refract(rd,gn,1/1.31);
    float3 origin=point+direction*.0004;
    for(uint bounce=0;bounce<5;bounce++) {
        MeshHit next=meshHit(origin,direction,root,triangles,nodes);
        if(!next.found)break;
        Triangle surface=triangles[next.id];
        float3 end=origin+direction*next.t;
        float3 n=shadingNormal(surface,next.uv);
        float3 geom=geometricNormal(surface);
        if(dot(n,direction)<.02)n=geom;
        // Artistic optical density at this miniature scale: long internal
        // paths become blue while direct surface reflections remain neutral.
        float3 absorption=mix(float3(.12),float3(3.0,.70,.10),saturate(u.scene.w));
        #ifdef ICE_FOOTAGE
        absorption=mix(float3(.12),float3(2.7,.64,.09),saturate(u.scene.w));
        absorption*=mix(.90,1.10,h1(seed+119.8));
        float scattering=.17*mix(.72,1.25,grainAmount);
#else
        float scattering=.04;
#endif
        float3 extinction=absorption+scattering;
        float3 attenuation=exp(-extinction*next.t);
        if(bounce<2)color+=throughput*volumeLight(origin,direction,next.t,extinction,scattering,root,triangles,nodes,rot,u.scene.w);
        color+=throughput*exp(-extinction*next.t*.5)*fractures(origin,direction,next.t,seed,aa,rot,object,u,studio,u.scene.w FOOTAGE_ARGUMENT)*fractureAmount;
        throughput*=attenuation;
        float exitF=fresnel(dot(direction,n),1/1.31);
        float3 escaping=refract(direction,-n,1.31);
        if(dot(escaping,escaping)>.01) {
            float3 escapeWeight=throughput*(1-exitF);
            color+=escapeWeight*outsideRadiance(end,escaping,rot,object,u,studio FOOTAGE_ARGUMENT);
        }
        throughput*=exitF;
        if(max(throughput.r,max(throughput.g,throughput.b))<.004)break;
        direction=reflect(direction,n);
        if(dot(direction,geom)>0)direction=reflect(direction,geom);
        origin=end+direction*.0004;
    }
    float frostAmount=clamp(u.material.y+(object.appearance.x>.5 && object.appearance.x<1.5?.4:0),0.0,1.0);
#ifdef ICE_FOOTAGE
    frostAmount*=mix(.60,1.50,grainAmount);
#endif
    float edgeBand=exp(-edge*34);
    float fine=detailTex.sample(iceSampler,uv,level(lod)).r;
    float rough=roughTex.sample(iceSampler,uv,level(lod)).r;
    // Subtle inclusions only: the shape and light now supply the large details.
    float poreScale=145,grainPatch=1;
#ifdef ICE_FOOTAGE
    poreScale=mix(96.0,174.0,h1(seed+122.4));
    grainPatch=(.45+.90*smoothstep(.30,.76,noise3(point*4.3+seed)))*mix(.55,1.30,grainAmount);
#endif
    float pores=smoothstep(.57,.84,noise3(point*poreScale+seed))*smoothstep(.47,.7,noise3(point*29+seed));
    float scatter=(pores*.050+pow(fine,3)*.025)*u.scene.z*grainPatch;
    float frost=pow(noise3(point*81+seed),3.0)*edgeBand*frostAmount*.5;
    color+=float3(.70,.78,.84)*(scatter+frost)*(1+rough*.25);
    #ifdef ICE_FOOTAGE
    return color*1.08; // Preserve separation between blue body faces and white reflections.
#else
    return mix(backdrop(screen,u),color,object.appearance.y);
#endif
}

float3 displayColor(float3 color) {
    // Linear lighting with a soft highlight shoulder, then display transfer.
    color=max(color,float3(0));
#ifdef ICE_FOOTAGE
    // Preserve detail in broad reflected faces instead of clipping them to
    // flat white; only the strongest narrow edge glints reach display white.
    color=color/(1+color*.60);
#else
    color=color/(1+color*.35);
#endif
    return pow(saturate(color),float3(1/2.2));
}
#ifdef ICE_FOOTAGE
struct FrostElement {float4 centerSize,appearance;};
float3 iceAtmosphere(float3 color,float2 p,float surfaceDepth,constant Uniforms &u,
                     constant FrostElement *mist,constant FrostElement *dust) {
    float density=0,litDensity=0;
    for(uint i=0;i<uint(u.atmosphere.x);i++) {
        constant FrostElement &puff=mist[i];
        float size=puff.centerSize.w;
        float2 delta=p-puff.centerSize.xy;
        float angle=puff.appearance.x*1.71+puff.appearance.w*.25;
        float2 local=float2(cos(angle)*delta.x+sin(angle)*delta.y,-sin(angle)*delta.x+cos(angle)*delta.y);
        // Overlapping, irregular volumes form vapor with a body, rather than
        // isolated needle-thin streaks. Each volume still leaves the ball.
        float2 extent=float2(size*puff.appearance.z*1.18,size*.70);
        float disk=dot(local/extent,local/extent);
        if(disk>=1)continue;
        float halfDepth=sqrt(1-disk)*size*.90;
        float nearZ=puff.centerSize.z+halfDepth;
        float farZ=max(surfaceDepth,puff.centerSize.z-halfDepth);
        if(nearZ<=farZ)continue;
        float step=(nearZ-farZ)/4;
        float seed=puff.appearance.x,age=puff.appearance.w;
        float3 shift=h3(seed)*13;
        for(uint k=0;k<4;k++) {
            float z=nearZ-(float(k)+.5)*step;
            float3 q=float3(local/extent,(z-puff.centerSize.z)/(size*.90));
            float taper=max(0.0,1-dot(q,q));
            float3 flow=q*1.8+shift+float3(age*.40,-age*.65,age*.22);
            float3 bend=float3(noise3(flow*.8+3.8),noise3(flow*.8+15.1),noise3(flow*.8+31.4))-.5;
            float n=noise3(flow+bend*1.35)*.72;
            n+=noise3(flow*2.23+5.1)*.23+noise3(flow*4.9+9.2)*.05;
            float sampleDensity=smoothstep(.25,.70,n)*taper*puff.appearance.y*step/size*1.45;
            float illumination=saturate(.52-dot(q,normalize(float3(.45,.65,-.6)))*.28);
            density+=sampleDensity;
            litDensity+=sampleDensity*illumination;
        }
    }
    // Cool blue body with a pale illuminated edge, not uniform white powder.
    // Optical depth and local illumination retain shape as volumes overlap.
    float opacity=.56*(1-exp(-density*1.35));
    float light=litDensity/max(density,.00001);
    float body=1-exp(-density*.65);
    float3 vapor=mix(float3(.42,.69,.94),float3(.68,.86,1.0),saturate(light*.90+(1-body)*.18));
    color=mix(color,vapor,opacity);
    // The ball-locked radial rim has been removed. All visible vapor now
    // comes from released, advected 3D wisps; no circular halo is drawn.
    for(uint i=0;i<uint(u.atmosphere.y);i++) {
        constant FrostElement &grain=dust[i];
        if(grain.centerSize.z<surfaceDepth)continue;
        float radius=max(grain.centerSize.w,.45/u.footageTransform.z);
        float2 q=p-grain.centerSize.xy;
        if(any(abs(q)>radius*1.5))continue;
        float footprint=.5/u.footageTransform.z;
        float coverage=1-smoothstep(max(0.0,radius-footprint),radius+footprint,length(q));
        float glint=.65+.35*sin(grain.appearance.x+grain.appearance.w*6.3);
        color=mix(color,float3(.77,.90,1),coverage*grain.appearance.y*glint*.51);
    }
    return color;
}
#endif

float4 icePixel(float2 pixel,constant Uniforms &u,constant Instance *objects,
                device const Triangle *triangles,device const BVHNode *nodes,constant float *roots,
                texture2d<float> normalTex,texture2d<float> detailTex,texture2d<float> roughTex,
                texture2d<float> studio FOOTAGE_PARAMETER) {
#ifdef ICE_FOOTAGE
    float unit=u.footageTransform.z;
    float2 p=(pixel-u.footageTransform.xy)/unit;
    float3 original=footage.read(uint2(pixel)).rgb;

#else
    float unit=min(u.viewport.x,u.viewport.y)/4;
    float2 p=(pixel-u.viewport.xy*.5)/unit;
    // Follow part of the trajectory so larger shards stay within the study
    // viewport. Their world positions, lag and relative motion are unchanged.
    if(u.viewport.w>2.5)p+=u.ball.xy*.70;
#endif
    float3 color=backdrop(p,u FOOTAGE_ARGUMENT);
    float best=sphereZ(p,u);int selected=-1;MeshHit nearest={0,float2(0),0,false};
    uint root=0;
    for(uint i=0;i<uint(u.scene.x);i++) {
        constant Instance &object=objects[i];
        uint objectRoot=uint(roots[uint(object.appearance.z)]);
        float scale=object.centerScale.w;
        if(any(abs(p-object.centerScale.xy)>scale*1.45))continue;
        float3x3 inv=transpose(rotation(object.rotationSeed.xyz));
        float3 ro=inv*(float3(p,4)-object.centerScale.xyz)/scale,rd=inv*float3(0,0,-1);
        MeshHit h=meshHit(ro,rd,objectRoot,triangles,nodes);
        if(!h.found)continue;
        float z=4-h.t*scale;
        if(z>best && object.appearance.y>.001){best=z;selected=int(i);nearest=h;root=objectRoot;}
    }
    if(selected>=0) {
        constant Instance &object=objects[selected];
        float3x3 rot=rotation(object.rotationSeed.xyz),inv=transpose(rot);
        float3 ro=inv*(float3(p,4)-object.centerScale.xyz)/object.centerScale.w,rd=inv*float3(0,0,-1);
        color=shadeIce(p,ro,rd,nearest,root,triangles,nodes,rot,object,u,1/(unit*object.centerScale.w),normalTex,detailTex,roughTex,studio FOOTAGE_ARGUMENT);
    }
#ifdef ICE_FOOTAGE
    if(selected<0)return float4(original,best);
    return float4(mix(original,displayColor(color),objects[selected].appearance.y),best);
#else
    return float4(displayColor(color),1);
#endif
}

fragment float4 labFragment(Varying in [[stage_in]],constant Uniforms &u [[buffer(0)]],
                            constant Instance *objects [[buffer(1)]],device const Triangle *triangles [[buffer(2)]],
                            device const BVHNode *nodes [[buffer(3)]],constant float *roots [[buffer(4)]],
                            texture2d<float> normalTex [[texture(0)]],texture2d<float> detailTex [[texture(1)]],
                            texture2d<float> roughTex [[texture(2)]],texture2d<float> studio [[texture(3)]]
#ifdef ICE_FOOTAGE
                            ,texture2d<float> footage [[texture(4)]],
                            constant FrostElement *mist [[buffer(5)]],constant FrostElement *dust [[buffer(6)]]
#endif
                            ) {
#ifdef ICE_FOOTAGE
    // Four independent rays filter silhouettes and sparkling internal facets
    // at football-video size, without blurring the original camera pixels.
    float3 color=0;
    float surfaceDepth=-100;
    for(uint j=0;j<4;j++) {
        float2 offset=float2((j&1)? .25:-.25,(j&2)? .25:-.25);
        float4 sample=icePixel(in.position.xy+offset,u,objects,triangles,nodes,roots,normalTex,detailTex,roughTex,studio,footage);
        color+=sample.rgb;surfaceDepth=max(surfaceDepth,sample.a);
    }
    float2 p=(in.position.xy-u.footageTransform.xy)/u.footageTransform.z;
    return float4(iceAtmosphere(color*.25,p,surfaceDepth,u,mist,dust),1);
#else
    return icePixel(in.position.xy,u,objects,triangles,nodes,roots,normalTex,detailTex,roughTex,studio);
#endif
}
