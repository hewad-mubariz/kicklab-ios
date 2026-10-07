// World-space clearing and fixed tree planes. The foliage atlas supplies leaf
// detail; perspective, occlusion, lighting and ground shadows remain native.
constant float3 forestSun=float3(0.565,0.425,-0.707);
constexpr sampler forestSampler(coord::normalized,address::clamp_to_zero,filter::linear,mip_filter::linear);

struct ForestTree { float3 root; float height; float width; float3 normal; float species; };
ForestTree forestTree(int ring,int index) {
    float seed=hashStudy(float2(index,ring+51));
    float angle=(float(index)+seed*0.55)*6.283185/28;
    float radius=ring==0?24.0:ring==1?39.0:66.0;
    float3 root=float3(sin(angle)*radius,0,cos(angle)*radius*1.17-2);
    root.x+=(seed-0.5)*4;root.z+=(hashStudy(float2(index+21,ring))-0.5)*4;
    float height=ring==0?13+seed*11:ring==1?18+seed*13:24+seed*18;
    // Lower growth behind the centre line leaves a view of the mountain ridge.
    float opening=smoothstep(0.62,0.95,-cos(angle));
    height*=1-opening*(ring==0?0.52:ring==1?0.32:0.10);
    float species=ring==0 && (index%4==0 || index%7==0)?1:0;
    float width=height*(species>0.5?0.65:0.40);
    return {root,height,width,normalize(float3(-root.x,0,-root.z-2)),species};
}
float4 forestTreeSample(float3 eye,float3 rd,ForestTree tree,float pixel,texture2d<float> trees,thread float &t) {
    float denominator=dot(rd,tree.normal);
    if(abs(denominator)<0.001){t=1e4;return float4(0);}
    t=dot(tree.root-eye,tree.normal)/denominator;
    if(t<=0.01)return float4(0);
    float3 p=eye+rd*t-tree.root;
    float3 side=float3(tree.normal.z,0,-tree.normal.x);
    float2 uv=float2(dot(p,side)/tree.width+0.5,1-p.y/tree.height);
    if(any(uv<0)||any(uv>1))return float4(0);
    float lod=max(0.0,log2(max(0.001,t*pixel)*float(trees.get_height())/tree.height));
    return trees.sample(forestSampler,float2((uv.x+tree.species)*0.5,0.92-(1-uv.y)*(tree.species>0.5?0.77:0.82)),level(lod));
}
float3 forestAtmosphere(float3 color,float depth,float3 rd) {
    float sun=pow(max(0.0,dot(rd,forestSun)),8);
    float haze=1-exp(-depth*0.006);
    return mix(color,mix(float3(0.24,0.33,0.32),float3(0.76,0.62,0.36),sun),haze*0.48);
}
float3 forestSky(float3 rd) {
    float h=saturate(rd.y);
    float3 color=mix(float3(0.72,0.70,0.54),float3(0.20,0.39,0.58),sqrt(h));
    float2 cloud=rd.xz/max(0.2,rd.y+0.1)*3;
    float n=noiseStudy(cloud)*0.55+noiseStudy(cloud*3)*0.30+noiseStudy(cloud*9)*0.15;
    color=mix(color,float3(0.98,0.88,0.68),smoothstep(0.58,0.72,n)*0.8);
    float sun=max(0.0,dot(rd,forestSun));
    color+=float3(1.0,0.70,0.32)*pow(sun,40)*0.42;
    color+=float3(3.5,2.8,1.7)*smoothstep(0.9994,0.9998,sun);
    // Three ragged alpine ridges, layered with atmospheric distance.
    float angle=atan2(rd.x,-rd.z),elevation=rd.y/max(0.01,length(rd.xz));
    for(int layer=0;layer<3;layer++) {
        float peak=exp(-pow((angle+0.15+layer*0.11)/0.32,2));
        float ridge=0.04+peak*(0.30-layer*0.035)+noiseStudy(float2(angle*8+layer*13,3))*0.075;
        ridge+=noiseStudy(float2(angle*31,layer*8))*0.024;
        if(elevation<ridge) {
            float rock=noiseStudy(float2(angle*45,elevation*29))*0.6+noiseStudy(float2(angle*120,elevation*88))*0.4;
            float rill=noiseStudy(float2(angle*65+elevation*19,elevation*7));
            color=mix(float3(0.10,0.14,0.15),float3(0.30,0.31,0.26),rock)*(0.72+rill*0.35);
            color=mix(color,float3(0.38,0.44,0.43),0.24-float(layer)*0.06);
        }
    }
    return color;
}
float forestShadow(float3 p,float pixel,texture2d<float> trees) {
    float shadow=0;
    for(int index=0;index<28;index++) {
        ForestTree tree=forestTree(0,index);float t;
        if(dot(tree.root-p,forestSun)<0)continue;
        float4 leaf=forestTreeSample(p+float3(0,0.05,0),forestSun,tree,max(pixel,0.004),trees,t);
        shadow=max(shadow,leaf.a);
    }
    return 1-shadow*0.80;
}
float3 forestWood(float3 p,float3 normal) {
    float grain=noiseStudy(float2(p.x+p.z,p.y)*float2(23,2));
    float3 wood=mix(float3(0.095,0.060,0.028),float3(0.27,0.19,0.093),grain);
    return wood*(float3(0.24,0.32,0.34)+float3(1.3,1.00,0.56)*max(0.0,dot(normal,forestSun)));
}
float forestEllipsoid(float3 eye,float3 rd,float3 center,float3 radius,thread float3 &normal) {
    float3 o=(eye-center)/radius,v=rd/radius;
    float a=dot(v,v),b=dot(o,v),c=dot(o,o)-1,disc=b*b-a*c;
    if(disc<0)return 1e4;
    float t=(-b-sqrt(disc))/a;
    if(t<=0.001)return 1e4;
    normal=normalize((eye+rd*t-center)/(radius*radius));return t;
}
float3 forestFloor(float3 p,float3 rd,float distance,float pixel,constant StudyUniforms &u,texture2d<float> turf,texture2d<float> trees) {
    float aa=max(0.001,pixel*distance/max(0.12,-rd.y));
    constexpr sampler groundSampler(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
    float mip=max(0.0,log2(aa*float(turf.get_width())/1.5));
    float3 grass=turf.sample(groundSampler,p.xz/1.5,level(mip)).rgb;
    float macro=noiseStudy(p.xz*0.55),detail=noiseStudy(p.xz*28);
    float soil=smoothstep(0.56,0.71,macro*0.76+noiseStudy(p.xz*2.8)*0.24);
    soil*=0.45+0.55*smoothstep(0.6,4.0,abs(p.x));
    float3 base=grass*float3(0.72,0.74,0.35)*(0.7+macro*0.65);
    base=mix(base,float3(0.14,0.092,0.040)*(0.7+detail*0.65),soil);
    float circle=length(p.xz-float2(0,-4));
    float line=min(abs(circle-3.35),abs(p.x));
    if(p.z>=-18 && p.z<=14)line=min(line,abs(abs(p.x)-10));
    if(abs(p.x)<10)line=min(line,min(abs(p.z+18),abs(p.z-14)));
    float paint=strokeStudy(line,0.045,aa*0.65)*(0.55+detail*0.45);
    base=mix(base,float3(0.59,0.59,0.43)*(0.78+detail*0.22),paint*0.9);
    float shadow=forestShadow(p,pixel,trees);
    float3 illumination=float3(0.25,0.31,0.29)+float3(1.5,1.18,0.60)*shadow*forestSun.y;
    float3 color=base*illumination;
    // Dry fallen leaves and occasional fine pebbles nestle in the short turf.
    float2 cell=floor(p.xz*6),f=fract(p.xz*6)-0.5;
    float seed=hashStudy(cell+71);
    float leaf=arenaRect(float2(f.x+f.y*0.5,f.y),float2(0.07,0.16),aa*6)*step(0.979,seed);
    color=mix(color,float3(0.25,0.14,0.04)*illumination,leaf*(1-paint));
    // Resolved upright blades give the foreground silhouette and relief.
    if(distance<10 && soil<0.8) {
        float2 grid=floor(p.xz/0.045);float cover=0;float3 blade=color;
        for(int z=-1;z<=1;z++) for(int x=-1;x<=1;x++) {
            float2 id=grid+float2(x,z);float r=hashStudy(id),r2=hashStudy(id+19.7);
            float2 root=(id+float2(0.15+0.7*r,0.15+0.7*r2))*0.045;
            float3 side=float3(cos(r*6.283),0,sin(r*6.283)),n=float3(-side.z,0,side.x);
            float denom=dot(rd,n);if(abs(denom)<0.08)continue;
            float t=dot(float3(root.x,0,root.y)-u.eye.xyz,n)/denom;
            float3 q=u.eye.xyz+rd*t-float3(root.x,0,root.y);
            float v=q.y/(0.035+r2*0.045);
            if(t<=0 || t>distance || v<0 || v>1)continue;
            float a=strokeStudy(dot(q,side)-(r-0.5)*0.012*v*v,0.0035*(1-v),max(0.0008,pixel*t*0.6));
            if(a>cover){cover=a;blade=color*(0.65+v*0.75+r*0.2);}
        }
        color=mix(color,blade,cover*(1-soil)*(1-smoothstep(6.0,10.0,distance)));
    }
    float2 delta=p.xz-u.contact.xy;
    float2 tight=delta/float2(max(0.06,u.contact.z*0.70),0.095),soft=delta/float2(max(0.20,u.contact.z*1.6),0.3);
    color*=1-u.contact.w*(exp(-dot(tight,tight))*0.46+exp(-dot(soft,soft))*0.18);
    return forestAtmosphere(color,distance,rd);
}
float3 forestCourtStudy(float3 eye,float3 rd,constant StudyUniforms &u,float pixel,texture2d<float> turf,texture2d<float> trees,texture2d<float> signs) {
    float3 color=forestSky(rd);float nearest=1e4;
    if(rd.y< -0.0001) {
        float t=-eye.y/rd.y;
        if(t>0){nearest=t;color=forestFloor(eye+rd*t,rd,t,pixel,u,turf,trees);}
    }
    // Fixed radial planes surround the clearing in three depth layers.
    for(int ring=2;ring>=0;ring--) for(int index=0;index<28;index++) {
        ForestTree tree=forestTree(ring,index);float t;
        float4 sample=forestTreeSample(eye,rd,tree,pixel,trees,t);
        if(t>=nearest || t<=0.01 || sample.a<0.15)continue;
        float3 p=eye+rd*t;
        float variation=hashStudy(float2(index,ring+8));
        float3 foliage=sample.rgb*float3(0.82,0.92,0.67)*(0.50+variation*0.40);
        float backlight=pow(max(0.0,dot(rd,forestSun)),12);
        foliage+=sample.rgb*float3(1.1,0.8,0.24)*backlight*(0.25+0.35*saturate(p.y/tree.height));
        foliage=forestAtmosphere(foliage,t,rd);
        color=mix(color,foliage,smoothstep(0.15,0.8,sample.a));
        if(sample.a>0.75)nearest=t;
    }
    // Low mossy banks close the treeline beneath the elevated woodland.
    for(int i=0;i<9;i++) {
        float angle=float(i)*6.283185/9,seed=hashStudy(float2(i,99));
        float3 center=float3(sin(angle)*24,-1.3,cos(angle)*32-2),normal;
        float3 radius=float3(7.5+seed*3,2.6+seed*2.0,7.0+seed*2);
        float t=forestEllipsoid(eye,rd,center,radius,normal);
        if(t<nearest) {
            nearest=t;float3 p=eye+rd*t;
            float texture=noiseStudy(p.xz*21+p.y*7),patch=noiseStudy(p.xz*1.3);
            float3 moss=mix(float3(0.035,0.065,0.019),float3(0.17,0.19,0.09),patch)*(0.7+texture*0.5);
            color=forestAtmosphere(moss*(float3(0.22,0.29,0.24)+float3(1.2,0.96,0.50)*max(0.0,dot(normal,forestSun))),t,rd);
        }
    }
    // Rough boulders skirt the outside of the clearing, with larger outcrops left.
    for(int i=0;i<34;i++) {
        float seed=hashStudy(float2(i,76)),angle=(float(i)+seed*0.7)*6.283185/34;
        float3 center=float3(sin(angle)*15,0.15+seed*0.22,cos(angle)*23-2),normal;
        float3 radius=float3(0.4+seed*1.2,0.35+seed*0.75,0.55+seed*1.2);
        float t=forestEllipsoid(eye,rd,center,radius,normal);
        if(t<nearest) {
            nearest=t;float3 p=eye+rd*t;
            float fleck=noiseStudy(p.xz*31+p.y*17),rock=noiseStudy(p.xz*3+p.y);
            float3 bump=urbanSurfaceNoise(p.xz*5+p.y*3);
            normal=normalize(normal+float3(bump.y,rock-0.5,bump.z)*0.40);
            float3 stone=mix(float3(0.12,0.15,0.14),float3(0.32,0.32,0.26),rock)*(0.8+fleck*0.3);
            stone=mix(stone,float3(0.07,0.10,0.026),smoothstep(0.53,0.74,rock)*max(0.0,normal.y));
            color=forestAtmosphere(stone*(float3(0.22,0.29,0.31)+float3(1.25,0.98,0.57)*max(0.0,dot(normal,forestSun))),t,rd);
        }
    }
    // Timber rails and upright posts form an open enclosure around the pitch.
    for(int face=0;face<4;face++) for(int part=0;part<3;part++) {
        bool side=face<2;float plane=side?(face==0?-12:12):(face==2?-20:16);
        float denominator=side?rd.x:rd.z;if(abs(denominator)<0.00001)continue;
        float t=(plane-(side?eye.x:eye.z))/denominator;float3 p=eye+rd*t;
        if(t<=0.01 || t>=nearest || (side?(p.z< -20||p.z>16):abs(p.x)>12))continue;
        float across=side?p.z:p.x,aa=max(0.003,t*pixel);
        float coverage=part==0?stripeStudy(across,3.0,0.16,aa)*step(0.0,p.y)*step(p.y,1.08)
            :strokeStudy(p.y-(part==1?0.40:0.86),0.055,aa);
        if(coverage>0.01) {
            float3 n=side?float3(face==0?1:-1,0.2,0):float3(0,0.2,face==2?1:-1);
            color=mix(color,forestAtmosphere(forestWood(p,normalize(n)),t,rd),coverage);
            if(coverage>0.9)nearest=t;
        }
    }
    // Canvas banners on side rails; native signs stay attached to their panels.
    for(int side=0;side<2;side++) {
        float plane=side==0?-11.8:11.8;
        if(abs(rd.x)<0.00001)continue;
        float t=(plane-eye.x)/rd.x;float3 p=eye+rd*t;
        if(t<=0.01 || t>=nearest || p.z< -17.7 || p.z> -7.0 || p.y<1.25 || p.y>5.0)continue;
        nearest=t;float across=side==0?-p.z:p.z;
        float2 uv=float2((across-(side==0?12.35:-12.35))/10.7+0.5,1-(p.y-1.25)/3.75);
        float3 n=float3(side==0?1:-1,0,0);
        float fabric=noiseStudy(float2(across,p.y)*90);
        float3 panel=float3(0.032,0.041,0.036)*(0.75+fabric*0.3);
        float4 ink=signs.sample(arenaSignSampler,float2(uv.x,(uv.y+side)*0.5),level(max(0.0,log2(t*pixel*180))));
        panel=panel*(1-ink.a)+ink.rgb*0.82;
        color=panel*(float3(0.38,0.43,0.40)+float3(0.80,0.63,0.35)*max(0.0,dot(n,forestSun)));
    }
    // Rustic bench planks, supports and the tall banner uprights.
    for(int side=0;side<2;side++) for(int part=0;part<9;part++) {
        float x=side==0?-11.4:11.4;float3 normal,center,size;
        if(part<3){center=float3(x+(part-1)*0.19,0.48,-10.5);size=float3(0.095,0.075,3.0);}
        else if(part<7){center=float3(x+((part&1)?0.21:-0.21),0.23,-10.5+((part&2)?2.5:-2.5));size=float3(0.11,0.23,0.11);}
        else {center=float3(x,2.70,part==7?-17.8:-6.9);size=float3(0.11,2.7,0.11);}
        float t=urbanBox(eye,rd,center,size,normal);
        if(t<nearest){nearest=t;color=forestAtmosphere(forestWood(eye+rd*t,normal),t,rd);}
    }
    // Small shaded lamps on timber poles frame the two banners in daylight.
    for(int side=0;side<2;side++) for(int part=0;part<4;part++) {
        float x=side==0?-11.2:11.2;float3 normal,center,size;
        if(part==0){center=float3(x,3,-6.5);size=float3(0.08,3,0.08);}
        else if(part==1){center=float3(x-sign(x)*0.45,5.8,-6.5);size=float3(0.5,0.06,0.065);}
        else if(part==2){center=float3(x-sign(x)*0.88,5.61,-6.5);size=float3(0.025,0.19,0.025);}
        else {center=float3(x-sign(x)*0.88,5.40,-6.5);size=float3(0.28,0.08,0.22);}
        float t=urbanBox(eye,rd,center,size,normal);
        if(t<nearest) {
            nearest=t;float3 p=eye+rd*t;
            color=part==0?forestWood(p,normal):float3(0.022,0.028,0.025)*(0.4+max(0.0,dot(normal,forestSun)));
        }
    }
    // Gentle forward scattering carries sunlight into the clearing.
    float sunFacing=pow(max(0.0,dot(rd,forestSun)),32);
    color+=float3(0.28,0.19,0.075)*sunFacing*(1-exp(-min(nearest,85.0)*0.012));
    return displayStudy(max(color,0.0));
}
