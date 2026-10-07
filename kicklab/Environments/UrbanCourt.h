// A complete outdoor court. All geometry and markings live in world space.
// The wet floor uses lamp highlights without mirroring the surrounding scene.
constant float urbanHalfWidth=11.0, urbanBack=-19.0, urbanFront=15.0;

float urbanBox(float3 eye,float3 rd,float3 center,float3 halfSize,thread float3 &normal) {
    float3 safe=select(rd,float3(0.000001),abs(rd)<0.000001);
    float3 a=(center-halfSize-eye)/safe,b=(center+halfSize-eye)/safe;
    float3 lo=min(a,b),hi=max(a,b);
    float near=max(lo.x,max(lo.y,lo.z)),far=min(hi.x,min(hi.y,hi.z));
    if(near<=0.002 || near>far)return 1e4;
    normal=lo.x>lo.y && lo.x>lo.z ? float3(-sign(safe.x),0,0)
        :lo.y>lo.z ? float3(0,-sign(safe.y),0):float3(0,0,-sign(safe.z));
    return near;
}
float3 urbanSky(float3 rd) {
    float h=saturate(rd.y);
    float3 color=mix(float3(0.048,0.036,0.051),float3(0.006,0.016,0.043),pow(h,0.35));
    float2 uv=rd.xz/max(0.16,rd.y+0.20)*float2(3.5,7.0);
    float cloud=noiseStudy(uv)*0.50+noiseStudy(uv*2.8)*0.27+noiseStudy(uv*7)*0.15+noiseStudy(uv*16)*0.08;
    float cover=smoothstep(0.38,0.64,cloud);
    color=mix(color,float3(0.003,0.007,0.016),cover*0.87);
    return color;
}
float3 urbanLamp(int i) {
    return float3((i&1)?10.35:-10.35,7.0,(i&2)?11.5:-12.5);
}
float3 urbanLight(float3 p,float3 normal) {
    float3 light=float3(0.20,0.26,0.39);
    for(int i=0;i<4;i++) {
        float3 delta=urbanLamp(i)-p;
        float r2=dot(delta,delta);
        light+=float3(1.0,0.62,0.27)*max(0.0,dot(normal,delta*rsqrt(r2)))*85/(r2+8);
    }
    return light;
}
float urbanCrown(float2 p,float aa) {
    float d=arenaSegment(p,float2(-0.65,-0.35),float2(-0.85,0.55));
    d=min(d,arenaSegment(p,float2(-0.85,0.55),float2(-0.35,0.15)));
    d=min(d,arenaSegment(p,float2(-0.35,0.15),float2(0,0.85)));
    d=min(d,arenaSegment(p,float2(0,0.85),float2(0.35,0.15)));
    d=min(d,arenaSegment(p,float2(0.35,0.15),float2(0.85,0.55)));
    d=min(d,arenaSegment(p,float2(0.85,0.55),float2(0.65,-0.35)));
    d=min(d,arenaSegment(p,float2(-0.65,-0.35),float2(0.65,-0.35)));
    return strokeStudy(d,0.045,aa);
}
float3 urbanWall(float2 q,float3 p,float3 normal,int face,float aa,texture2d<float> signs) {
    float grain=noiseStudy(q*60),macro=noiseStudy(q*2.3);
    float joint=stripeStudy(q.x,3.4,0.021,aa);
    float3 base=float3(0.065,0.074,0.085)*(0.60+0.5*macro+grain*0.23);
    base*=1-joint*0.65;
    // Layered, chipped abstract street lettering on concrete panels.
    float2 tile=float2(q.x*0.68,q.y*0.85);
    float2 id=floor(tile);float2 f=fract(tile)-0.5;
    float seed=hashStudy(id+float2(face*17,2));
    float stroke=abs(f.x+(seed-0.5)*f.y*3.0+abs(f.y+0.1)*0.8-0.12);
    float paint=strokeStudy(stroke-0.13,0.12,aa)*(1-smoothstep(0.32,0.49,abs(f.y)));
    paint*=smoothstep(0.18,0.42,noiseStudy(q*17));
    base=mix(base,mix(float3(0.14,0.15,0.17),float3(0.035,0.047,0.057),step(0.55,seed)),paint*0.85);
    base*=0.7+0.3*smoothstep(0.0,0.5,q.y);
    // A central crown and the same carefully set native typography as the UI.
    float crown=urbanCrown((q-float2(0,1.40))/0.84,aa);
    base=mix(base,float3(0.015,0.34,0.26),crown*0.85);
    float center=face==0?-12.0:face==1?12.0:0.0;
    int label=face==0?0:face==1?2:1;
    float2 uv=float2((q.x-center)/9.0+0.5,0.5-(q.y-1.5)/2.4);
    if(face<2)uv.x=1-uv.x;
    if(face<2 && all(uv>=0) && all(uv<=1)) {
        float4 ink=signs.sample(arenaSignSampler,float2(uv.x,(uv.y+float(label))/4),level(max(0.0,log2(aa*230))));
        base=base*(1-ink.a*0.88)+ink.rgb*0.62*(0.74+0.26*grain);
    }
    if(face>=2) {
        float2 uv2=float2((q.x+6.4)/6.0+0.5,0.5-(q.y-1.5)/2.1);
        if(all(uv2>=0)&&all(uv2<=1)) {
            float4 ink=signs.sample(arenaSignSampler,float2(uv2.x,(uv2.y+1)/4),level(max(0.0,log2(aa*270))));
            base=base*(1-ink.a*0.9)+ink.rgb*0.56;
        }
    }
    return base*urbanLight(p,normal);
}
float3 urbanBuilding(float3 p,float3 normal,float seed,float aa) {
    float across=abs(normal.x)>0.5?p.z:p.x;
    float2 grid=float2(across/1.15,p.y/1.65),cell=floor(grid);
    float2 local=(fract(grid)-0.5)*float2(1.15,1.65);
    float window=arenaRect(local,float2(0.21,0.35),aa);
    float lit=hashStudy(cell+seed*53);
    float3 wall=mix(float3(0.010,0.014,0.021),float3(0.026,0.024,0.029),seed);
    float brick=max(stripeStudy(across+floor(p.y/0.23)*0.24,0.48,0.012,aa),stripeStudy(p.y,0.23,0.01,aa));
    wall*=1-brick*0.18;
    float3 glow=mix(float3(0.70,0.33,0.085),float3(0.35,0.52,0.73),step(0.91,lit));
    wall=mix(wall,float3(0.006,0.009,0.015)+glow*smoothstep(0.60,0.69,lit)*(0.35+0.65*hashStudy(cell+19)),window);
    float sill=arenaRect(local-float2(0,-0.39),float2(0.27,0.035),aa);
    return wall+float3(0.027,0.033,0.042)*sill;
}

float3 urbanShell(float3 eye,float3 rd,float pixel,float roughness,texture2d<float> signs,thread float &nearest) {
    float3 color=urbanSky(rd);nearest=1e4;
    // Staggered apartment blocks in a ring, with depth and independently lit windows.
    for(int side=0;side<4;side++) for(int index=0;index<9;index++) {
        float seed=hashStudy(float2(side*13,index*7));
        float across=(float(index)-4)*10.5+seed*3;
        float distance=53+hashStudy(float2(index,side+9))*22;
        float height=10+seed*21;
        float3 center=side<2 ? float3(across,height/2,(side==0?-1:1)*distance-2)
            :float3((side==2?-1:1)*distance,height/2,across-2);
        float3 normal;
        float t=urbanBox(eye,rd,center,float3(3.3+seed*1.9,height/2,3.5+seed*2),normal);
        if(t<nearest) {
            nearest=t;float3 p=eye+rd*t;
            color=urbanBuilding(p,normal,seed,max(0.012,t*pixel+roughness*0.08));
            color=mix(color,float3(0.017,0.024,0.038),1-exp(-t*0.002));
            // Recessed vertical bays and thin rooftop cornices give the blocks scale.
            float across=abs(normal.x)>0.5?p.z:p.x;
            color*=1-stripeStudy(across,4.6,0.11,max(0.01,t*pixel))*0.4;
            color+=float3(0.036,0.044,0.059)*strokeStudy(p.y-height+0.20,0.09,t*pixel);
            if(side==0 && (index==5 || index==7) && normal.z>0.5) {
                float2 uv=float2((p.x-center.x)/6.8+0.5,0.5-(p.y-height+3.6)/3.2);
                if(all(uv>=0)&&all(uv<=1)) {
                    float row=index==5?0.0:3.0;
                    float4 ink=signs.sample(arenaSignSampler,float2(uv.x,(uv.y+row)/4),level(max(0.0,log2(t*pixel*300))));
                    color=mix(color,float3(0.006,0.018,0.025),0.8)+ink.rgb*1.4;
                }
            }
        }
    }
    // Nearby brick flank buildings frame the court without sealing the sky.
    for(int side=0;side<2;side++) {
        float3 normal;
        float t=urbanBox(eye,rd,float3(side==0?-19:19,7,1),float3(4,7,12),normal);
        if(t<nearest) {nearest=t;color=urbanBuilding(eye+rd*t,normal,0.83,t*pixel)*float3(1.15,0.85,0.7);}
    }
    // Low solid rebound walls. Fence is composited afterward so the holes reveal the city.
    for(int face=0;face<4;face++) {
        bool side=face<2;
        float denom=side?rd.x:rd.z;
        if(abs(denom)<0.00001)continue;
        float plane=side?(face==0?-urbanHalfWidth:urbanHalfWidth):(face==2?urbanBack:urbanFront);
        float t=(plane-(side?eye.x:eye.z))/denom;
        float3 p=eye+rd*t;
        if(t<=0 || t>=nearest || p.y<0 || p.y>2.8 || (side?(p.z<urbanBack||p.z>urbanFront):abs(p.x)>urbanHalfWidth))continue;
        nearest=t;
        float across=side?p.z:p.x;if(face==1 || face==3)across=-across;
        float3 normal=side?float3(face==0?1:-1,0,0):float3(0,0,face==2?1:-1);
        color=urbanWall(float2(across,p.y),p,normal,face,max(0.002,t*pixel),signs);
        color+=float3(0.10,0.11,0.13)*strokeStudy(p.y-2.78,0.025,t*pixel);
    }
    // Benches with slatted timber seats and four dark steel legs.
    for(int side=0;side<2;side++) for(int part=0;part<7;part++) {
        float3 center=float3(side==0?-10.1:10.1,0.48,-5.4),size=float3(0.09,0.055,2.5);
        if(part<3)center.x+=(float(part)-1)*0.20;
        else {center.x+=(part&1)?0.22:-0.22;center.y=0.23;center.z+=(part&2)?2.1:-2.1;size=float3(0.035,0.23,0.045);}
        float3 normal;float t=urbanBox(eye,rd,center,size,normal);
        if(t<nearest) {nearest=t;color=(part<3?float3(0.16,0.105,0.06):float3(0.025,0.031,0.035))*urbanLight(eye+rd*t,normal);}
    }
    // Four upright floodlights: solid poles, inward arms, glowing undersides.
    for(int i=0;i<4;i++) for(int part=0;part<3;part++) {
        float3 lamp=urbanLamp(i),normal;
        float3 center=part==0?float3(lamp.x,3.5,lamp.z):part==1?lamp+float3(-sign(lamp.x)*0.3,0,0):lamp+float3(-sign(lamp.x)*0.65,-0.06,0);
        float3 size=part==0?float3(0.065,3.5,0.065):part==1?float3(0.36,0.045,0.05):float3(0.30,0.07,0.20);
        float t=urbanBox(eye,rd,center,size,normal);
        if(t<nearest) {nearest=t;color=part==2 && normal.y<0?float3(6.0,3.8,1.65):float3(0.024,0.031,0.039)*urbanLight(eye+rd*t,normal);}
    }
    for(int face=0;face<4;face++) {
        bool side=face<2;float denom=side?rd.x:rd.z;
        if(abs(denom)<0.00001)continue;
        float plane=side?(face==0?-urbanHalfWidth:urbanHalfWidth):(face==2?urbanBack:urbanFront);
        float t=(plane-(side?eye.x:eye.z))/denom;float3 p=eye+rd*t;
        if(t<=0 || t>nearest || p.y<2.8 || p.y>6.2 || (side?(p.z<urbanBack||p.z>urbanFront):abs(p.x)>urbanHalfWidth))continue;
        float across=side?p.z:p.x,aa=max(0.003,t*pixel);
        float mesh=max(stripeStudy(across+p.y,0.22,0.009,aa),stripeStudy(across-p.y,0.22,0.009,aa));
        float posts=stripeStudy(across+1,3.4,0.065,aa);
        float rails=max(strokeStudy(p.y-6.16,0.033,aa),strokeStudy(p.y-2.86,0.033,aa));
        float cover=max(mesh,max(posts,rails));
        float3 metal=float3(0.026,0.030,0.034)*urbanLight(p,normalize(float3(-p.x,0,-p.z)));
        color=mix(color,metal,cover*0.92);
    }
    // Small restrained halos, depth-tested against the enclosure and buildings.
    for(int i=0;i<4;i++) {
        float3 delta=urbanLamp(i)+float3(-sign(urbanLamp(i).x)*0.65,-0.13,0)-eye;
        float t=length(delta),alignment=max(0.0,dot(rd,delta/t));
        if(t<nearest+0.6)color+=float3(0.20,0.085,0.022)*pow(alignment,1600.0/(1+roughness*8));
    }
    return color;
}

// Value noise with its analytic slope. Lighting and reflection distortion use
// the same height field; unrelated noise in X/Z makes wet asphalt look metallic.
float3 urbanSurfaceNoise(float2 p) {
    float2 cell=floor(p),f=fract(p),w=f*f*(3-2*f),dw=6*f*(1-f);
    float a=hashStudy(cell),b=hashStudy(cell+float2(1,0));
    float c=hashStudy(cell+float2(0,1)),d=hashStudy(cell+1);
    return float3(mix(mix(a,b,w.x),mix(c,d,w.x),w.y),
        mix(b-a,d-c,w.y)*dw.x,mix(c-a,d-b,w.x)*dw.y);
}

// Sparse rain impacts displace the water normal, never draw white rings on it.
// Each event grows, decays and disappears before its cell starts another event.
float2 urbanRainSlope(float2 p,float time,float footprint) {
    constexpr float cellSize=0.78,interval=1.65;
    float2 cell=floor(p/cellSize),slope=0;
    float resolved=1-smoothstep(0.009,0.040,footprint);
    if(resolved<0.001)return slope;
    for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
        float2 id=cell+float2(x,y);
        float clock=time/interval+hashStudy(id+71.4);
        float event=floor(clock),age=fract(clock)*interval;
        float seed=hashStudy(id+event*13.7);
        if(seed>0.70 || age>1.1)continue;
        float2 center=(id+float2(0.18+0.64*hashStudy(id+event+3),0.18+0.64*hashStudy(id-event+19)))*cellSize;
        float2 delta=p-center;float radius=length(delta);
        if(radius>0.36 || radius<0.001)continue;
        float front=radius-age*0.29;
        float envelope=exp(-front*front/0.0024)*smoothstep(0.02,0.12,age)*(1-smoothstep(0.45,1.1,age));
        float derivative=cos(front*110)*0.018*envelope;
        slope+=delta/radius*derivative*resolved;
    }
    return slope;
}

float3 urbanCourtStudy(float3 eye,float3 rd,constant StudyUniforms &u,float pixel,texture2d<float> signs,texture2d<float> concrete) {
    float distance;float3 color=urbanShell(eye,rd,pixel,0,signs,distance);
    float floorT=rd.y< -0.00001 ? -eye.y/rd.y:1e4;
    if(floorT>0 && floorT<distance) {
        float3 p=eye+rd*floorT;
        float aa=max(0.001,pixel*floorT/max(0.14,-rd.y));
        constexpr sampler materialSampler(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
        float mip=max(0.0,log2(aa*float(concrete.get_width())/3));
        float grain=concrete.sample(materialSampler,p.xz/3,level(mip)).r;
        float macro=noiseStudy(p.xz*0.8),fine=mix(noiseStudy(p.xz*155),0.5,smoothstep(0.006,0.025,aa));
        // Uneven ground collects water in connected, irregular shallow hollows.
        float2 warp=float2(noiseStudy(p.xz*0.31),noiseStudy(p.zx*0.37+17))-0.5;
        float basin=noiseStudy(p.xz*0.48+warp*1.1)*0.52+noiseStudy(p.xz*1.65+warp)*0.30+noiseStudy(p.xz*6.2)*0.18;
        float puddle=smoothstep(0.55,0.59,basin);
        float damp=smoothstep(0.30,0.54,basin);
        float wetEdge=smoothstep(0.46,0.52,basin)*(1-puddle);
        float wear=0.55+0.45*smoothstep(0.20,0.45,noiseStudy(p.xz*29));
        float3 base=float3(0.039,0.047,0.058)*(0.40+grain*2.2+fine*0.55+macro*0.25);
        float circle=length(p.xz-float2(0,-4));
        float teal=(1-smoothstep(3.25-aa,3.25+aa,circle))*0.70;
        float slash=strokeStudy(p.x-p.z*0.72-6,1.2,aa);
        float slash2=strokeStudy(p.x+p.z*0.6+9,0.55,aa);
        teal=max(teal,max(slash,slash2)*0.85);
        base=mix(base,float3(0.018,0.16,0.135)*(0.55+grain*2),teal*wear);
        float line=min(abs(circle-3.25),abs(p.x));
        if(p.z>urbanBack+1 && p.z<urbanFront-1)line=min(line,abs(abs(p.x)-9.5));
        if(abs(p.x)<9.5)line=min(line,min(abs(p.z-(urbanBack+1)),abs(p.z-(urbanFront-1))));
        float endCircle=length(p.xz-float2(0,-17.7));
        if(p.z> -17.7)line=min(line,abs(endCircle-2.7));
        float paint=strokeStudy(line,0.045,aa*0.65)*wear;
        base=mix(base,float3(0.46,0.47,0.44)*(0.65+grain),paint*0.85);
        // Thin irregular cracks break up the ground without a repeating tile grid.
        float crack=strokeStudy(p.x+sin(p.z*0.9)*0.18+sin(p.z*3.1)*0.08-5.2,0.012,aa);
        base*=1-crack*0.55;
        // Water darkens porous aggregate; rough patches keep their granular relief.
        base*=mix(1.12,0.60,damp)*(0.68+fine*0.70);
        base*=1-wetEdge*0.12;
        float3 coarse=urbanSurfaceNoise(p.xz*9.0),aggregate=urbanSurfaceNoise(p.xz*85.0);
        float resolved=1-smoothstep(0.004,0.022,aa);
        float2 asphaltSlope=coarse.yz*0.018+aggregate.yz*0.11*resolved;
        float2 waterSlope=urbanRainSlope(p.xz,u.source.w,aa);
        float2 slope=mix(asphaltSlope,coarse.yz*0.003+aggregate.yz*0.004*resolved,puddle*0.99)+waterSlope*puddle;
        float3 normal=normalize(float3(-slope.x,1,-slope.y));
        color=base*urbanLight(p,normal);
        float roughness=mix(0.74,0.32,damp)*(0.90+0.20*macro);
        roughness=mix(roughness,0.095,puddle);
        float ndv=max(0.035,dot(normal,-rd));
        // Keep the wet sheen and rain response without reflected signage,
        // buildings, fences or walls. Only the lamps contribute specular light.
        for(int i=0;i<4;i++) {
            float3 lamp=urbanLamp(i)+float3(-sign(urbanLamp(i).x)*0.65,0,0);
            float3 delta=lamp-p;float r2=dot(delta,delta);
            float3 light=delta*rsqrt(r2),halfVector=normalize(light-rd);
            float ndl=max(0.0,dot(normal,light)),ndh=max(0.0,dot(normal,halfVector));
            float vdh=max(0.0,dot(-rd,halfVector));
            float alpha=max(0.035,roughness*roughness),alpha2=alpha*alpha;
            float denominator=ndh*ndh*(alpha2-1)+1;
            float distribution=alpha2/(M_PI_F*denominator*denominator);
            float k=(roughness+1)*(roughness+1)/8;
            float masking=(ndv/(ndv*(1-k)+k))*(ndl/(ndl*(1-k)+k));
            float f=0.028+0.972*pow(1-vdh,5);
            float specular=distribution*masking*f/(4*ndv+0.001);
            color+=float3(1.0,0.59,0.26)*specular*125/(r2+8)*(0.65+fine*0.5);
        }
        float2 delta=p.xz-u.contact.xy;
        float2 tight=delta/float2(max(0.065,u.contact.z*0.7),0.10),soft=delta/float2(max(0.20,u.contact.z*1.6),0.32);
        color*=1-u.contact.w*(exp(-dot(tight,tight))*0.48+exp(-dot(soft,soft))*0.18);
    }
    return displayStudy(max(color,0.0));
}
