// The last two environments share the court layout, while lighting, terrain,
// planting, weather and the horizon distinguish winter from the coast.
constant float3 fieldSun=float3(0.38,0.14,-0.914330);
float3 fieldSky(float3 rd,bool snow) {
    float up=saturate(rd.y),sun=max(0.0,dot(rd,fieldSun));
    float warm=pow(sun,11);
    float3 horizon=snow?float3(0.23,0.27,0.36):float3(0.72,0.29,0.075);
    float3 zenith=snow?float3(0.033,0.060,0.13):float3(0.17,0.23,0.31);
    float3 color=mix(horizon,zenith,pow(up,0.45));
    float2 uv=rd.xz/max(0.14,rd.y+0.19)*float2(4,7);
    float cloud=noiseStudy(uv)*0.51+noiseStudy(uv*2.7)*0.29+noiseStudy(uv*8.1)*0.20;
    float cover=smoothstep(0.43,0.67,cloud);
    float3 cloudColor=mix(snow?float3(0.05,0.08,0.14):float3(0.18,0.10,0.08),float3(0.68,0.33,0.13),warm*0.7);
    color=mix(color,cloudColor,cover*0.72);
    color+=float3(0.95,0.49,0.13)*warm*(snow?0.35:0.65);
    color+=float3(3.2,2.3,1.0)*smoothstep(0.9993,0.99975,sun);
    return color;
}
float3 fieldHaze(float3 color,float t,bool snow) {
    return mix(color,snow?float3(0.13,0.19,0.29):float3(0.40,0.28,0.16),min(0.6,1-exp(-t*(snow?0.006:0.003))));
}
float3 fieldLight(float3 p,float3 normal,bool snow) {
    float3 light=snow?float3(0.25,0.36,0.62):float3(0.23,0.25,0.30);
    light+=(snow?float3(0.48,0.27,0.14):float3(2.1,1.1,0.38))*max(0.0,dot(normal,fieldSun));
    for(int i=0;i<2;i++) {
        float3 delta=float3(i==0?-10.8:10.8,8,-11)-p;float r2=dot(delta,delta);
        light+=(snow?float3(0.72,0.85,1.0):float3(1.0,0.72,0.35))*max(0.0,dot(normal,delta*rsqrt(r2)))*90/(r2+20);
    }
    return light;
}
float3 fieldWood(float3 p,float3 normal,bool snow) {
    float grain=noiseStudy(float2(p.x+p.z,p.y)*float2(23,2));
    float3 wood=mix(float3(0.070,0.044,0.022),float3(0.25,0.15,0.061),grain);
    if(snow)wood=mix(wood,float3(0.65,0.76,0.87),smoothstep(0.35,0.7,normal.y));
    return wood*fieldLight(p,normal,snow);
}
float fieldCourtMark(float2 p,float aa) {
    float line=min(abs(length(p-float2(0,-4))-3.35),abs(p.x));
    if(p.y>=-18 && p.y<=14)line=min(line,abs(abs(p.x)-10));
    if(abs(p.x)<10)line=min(line,min(abs(p.y+18),abs(p.y-14)));
    return strokeStudy(line,0.052,aa);
}
float3 fieldGround(float3 p,float3 rd,float t,float pixel,constant StudyUniforms &u,bool snow) {
    float aa=max(0.001,pixel*t/max(0.13,-rd.y));
    float3 macro=urbanSurfaceNoise(p.xz*2.8),lumps=urbanSurfaceNoise(p.xz*11),grain=urbanSurfaceNoise(p.xz*65);
    float resolved=1-smoothstep(0.007,0.032,aa);
    // Wind-sculpted ripples and compacted granular relief, with soft foot scuffs.
    float ripple=sin(p.z*47+sin(p.x*3)*2+noiseStudy(p.xz*2)*8);
    float2 slope=macro.yz*0.14+lumps.yz*0.19+grain.yz*0.075*resolved;
    slope.y+=ripple*0.035*resolved;
    float2 id=floor(p.xz/0.85),q=fract(p.xz/0.85)-0.5;
    float seed=hashStudy(id+51),angle=seed*6.283;
    q=float2(q.x*cos(angle)-q.y*sin(angle),q.x*sin(angle)+q.y*cos(angle));
    q.x+=(hashStudy(id+7)-0.5)*0.18;
    float imprint=exp(-dot(q/float2(0.115,0.24),q/float2(0.115,0.24)))*step(0.66,seed);
    slope+=q*imprint*1.0;
    float3 n=normalize(float3(-slope.x,1,-slope.y));
    float detail=0.80+0.18*macro.x+0.12*lumps.x+0.08*grain.x*resolved;
    float3 base=(snow?float3(0.72,0.81,0.94):float3(0.62,0.50,0.33))*detail;
    base*=1-imprint*(snow?0.13:0.18);
    float wear=snow?0.58+0.42*smoothstep(0.3,0.7,lumps.x):0.78+0.22*lumps.x;
    float mark=fieldCourtMark(p.xz,aa*0.7)*wear;
    base=mix(base,snow?float3(0.075,0.115,0.18):float3(0.026,0.055,0.074),mark*(snow?0.62:0.90));
    float3 color=base*fieldLight(p,n,snow);
    if(snow) {
        float sparkle=pow(saturate(grain.x),26)*resolved*pow(max(0.0,dot(reflect(rd,n),normalize(float3(-0.7,0.7,0.1)))),14);
        color+=float3(0.32,0.42,0.58)*sparkle;
    } else {
        // Soft palm frond shadows keep the sand matte and give the clearing scale.
        float stem=strokeStudy(p.x*0.8+p.z*0.35+4,0.12,aa);
        float frond=(1-smoothstep(0.0,3.5,abs(p.x+p.z*0.25+5)))*stripeStudy(p.z-p.x*0.18,0.47,0.16,max(aa,0.05));
        color*=1-max(stem,frond)*0.28;
    }
    float2 d=p.xz-u.contact.xy;
    float2 tight=d/float2(max(0.065,u.contact.z*0.7),0.10),soft=d/float2(max(0.20,u.contact.z*1.6),0.32);
    color*=1-u.contact.w*(exp(-dot(tight,tight))*0.44+exp(-dot(soft,soft))*0.17);
    return fieldHaze(color,t,snow);
}
float3 beachOcean(float3 p,float3 rd,float time) {
    float shore=-27+sin(p.x*0.05)*1.2;
    float depth=shore-p.z;
    float wave=sin(p.z*2.5+time*1.15+sin(p.x*0.2))*0.6+sin(p.z*6.1-time*1.4+p.x*0.13)*0.25;
    float3 color=mix(float3(0.13,0.19,0.22),float3(0.065,0.10,0.14),smoothstep(0,90.0,depth));
    float2 slope=float2(sin(p.x*0.7+p.z*3+time)*0.045,wave*0.08);
    float3 normal=normalize(float3(slope.x,1,slope.y));
    float sun=pow(max(0.0,dot(reflect(rd,normal),fieldSun)),230);
    color+=float3(2.4,1.10,0.28)*sun*(0.5+noiseStudy(p.xz*2));
    float breakLine=abs(depth-(1.0+0.5*sin(time*0.9)));
    float foam=1-smoothstep(0.12,0.55,breakLine+noiseStudy(p.xz*4)*0.3);
    foam=max(foam,stripeStudy(depth+sin(p.x*0.3)*0.6+time*0.8,8,0.2,0.10)*exp(-depth*0.06));
    color=mix(color,float3(0.58,0.47,0.30),foam*0.7);
    return color;
}
ForestTree seasonalTree(bool snow,int ring,int index) {
    if(snow) {
        ForestTree tree=forestTree(ring,index);tree.species=0;
        tree.width=tree.height*0.43;return tree;
    }
    float seed=hashStudy(float2(index,ring+102));
    // The seaward centre is open; palms frame both sides and the landward view.
    float angle=(float(index)+0.5+seed*0.35)*6.283185/14;
    float radius=ring==0?19.0:33.0;
    float3 root=float3(sin(angle)*radius,0,cos(angle)*radius-1);
    float height=12+seed*7;
    return {root,height,height*0.67,normalize(float3(-root.x,0,-root.z-1)),1};
}
float4 seasonalTreeSample(float3 eye,float3 rd,ForestTree tree,float pixel,texture2d<float> trees,thread float &t) {
    float denom=dot(rd,tree.normal);if(abs(denom)<0.001){t=1e4;return float4(0);}
    t=dot(tree.root-eye,tree.normal)/denom;
    if(t<=0.01)return float4(0);
    float3 p=eye+rd*t-tree.root,side=float3(tree.normal.z,0,-tree.normal.x);
    float2 uv=float2(dot(p,side)/tree.width+0.5,p.y/tree.height);
    if(any(uv<0)||any(uv>1))return float4(0);
    float lod=max(0.0,log2(max(0.001,t*pixel)*float(trees.get_height())/tree.height));
    // Keep the two sprites separated even at mip boundaries.
    float x=clamp(uv.x,0.005,0.995);
    return trees.sample(forestSampler,float2((x+tree.species)*0.5,0.94-uv.y*0.885),level(lod));
}
void fieldProps(float3 eye,float3 rd,float pixel,bool snow,texture2d<float> signs,thread float3 &color,thread float &nearest) {
    // Open rails in winter, sagging rope rails along the beach.
    for(int face=0;face<4;face++) {
        bool side=face<2;float plane=side?(face==0?-12:12):(face==2?-20:16);
        float denom=side?rd.x:rd.z;if(abs(denom)<0.00001)continue;
        float t=(plane-(side?eye.x:eye.z))/denom;float3 p=eye+rd*t;
        if(t<=0.01 || t>=nearest || (side?(p.z< -20||p.z>16):abs(p.x)>12))continue;
        float across=side?p.z:p.x,aa=max(0.003,t*pixel);
        float post=stripeStudy(across,3,0.16,aa)*step(0.0,p.y)*step(p.y,1.06);
        float sag=snow?0:0.20*(1-pow(fract(across/3)*2-1,2));
        float rail=strokeStudy(p.y-0.85+sag,snow?0.045:0.025,aa);
        if(snow)rail=max(rail,strokeStudy(p.y-0.35,0.035,aa));
        float coverage=max(post,rail);
        if(coverage>0.01) {
            float3 normal=side?float3(face==0?1:-1,0,0):float3(0,0,face==2?1:-1);
            float3 wood=fieldWood(p,normal,snow);
            if(snow)wood=mix(wood,float3(0.40,0.53,0.72),strokeStudy(p.y-0.895,0.019,aa));
            color=mix(color,wood,coverage);if(coverage>0.9)nearest=t;
        }
    }
    // Side banners carry the same native typography across the outdoor scenes.
    for(int side=0;side<2;side++) {
        if(abs(rd.x)<0.0001)continue;
        float t=((side==0?-11.8:11.8)-eye.x)/rd.x;float3 p=eye+rd*t;
        if(t<=0.01 || t>=nearest || p.z< -17.7 || p.z> -7 || p.y<1.0 || p.y>4.8)continue;
        nearest=t;float across=side==0?-p.z:p.z;
        float2 uv=float2((across-(side==0?12.35:-12.35))/10.7+0.5,1-(p.y-1.0)/3.8);
        float3 panel=float3(0.021,0.029,0.033)*(0.8+0.3*noiseStudy(float2(across,p.y)*73));
        float4 ink=signs.sample(arenaSignSampler,float2(uv.x,(uv.y+side)*0.5),level(max(0.0,log2(t*pixel*180))));
        panel=panel*(1-ink.a)+ink.rgb*0.76;
        color=panel*(snow?float3(0.44,0.57,0.76):float3(0.90,0.58,0.27));
        if(snow)color=mix(color,float3(0.53,0.65,0.82),smoothstep(4.64+noiseStudy(float2(p.z*8,9))*0.12,4.80,p.y));
    }
    for(int side=0;side<2;side++) for(int part=0;part<9;part++) {
        float x=side==0?-11.4:11.4;float3 normal,center,size;
        if(part<3){center=float3(x+(part-1)*0.19,0.48,-10.5);size=float3(0.095,0.075,3);}
        else if(part<7){center=float3(x+((part&1)?0.21:-0.21),0.23,-10.5+((part&2)?2.5:-2.5));size=float3(0.10,0.23,0.10);}
        else {center=float3(x,2.5,part==7?-17.8:-6.9);size=float3(0.10,2.5,0.10);}
        float t=urbanBox(eye,rd,center,size,normal);
        if(t<nearest){nearest=t;color=fieldWood(eye+rd*t,normal,snow);}
    }
    // Elevated arrays of small floodlights, with visible metal housings.
    for(int side=0;side<2;side++) for(int part=0;part<8;part++) {
        float x=side==0?-10.8:10.8;float3 normal,center,size;
        if(part==0){center=float3(x,4,-11);size=float3(0.065,4,0.065);}
        else if(part==1){center=float3(x,8,-11);size=float3(0.43,0.57,0.065);}
        else {int light=part-2;center=float3(x+(light%2-0.5)*0.38,8+(light/2-1)*0.34,-10.92);size=float3(0.14,0.12,0.025);}
        float t=urbanBox(eye,rd,center,size,normal);
        if(t<nearest){nearest=t;color=part<2?float3(0.018,0.027,0.042):(snow?float3(3.1,3.5,4.0):float3(3.4,2.1,0.9));}
        if(part==1) {
            float3 delta=center-eye;float d=length(delta);
            if(d<nearest+0.8)color+=(snow?float3(0.15,0.20,0.32):float3(0.20,0.11,0.03))*pow(max(0.0,dot(rd,delta/d)),1800);
        }
    }
    // Cabin / beach hut with planked walls, a pitched roof and warm windows.
    float hutZ=snow ? -25.0 : -18.5;
    float hutHeight=snow?2.25:2.70;
    float3 hutCenter=float3(-17.5,hutHeight,hutZ),normal;
    float hutT=urbanBox(eye,rd,hutCenter,float3(3.3,hutHeight,5.5),normal);
    if(hutT<nearest) {
        nearest=hutT;float3 p=eye+rd*hutT;
        float across=abs(normal.x)>0.5?p.z:p.x;
        float seam=stripeStudy(p.y,0.30,0.027,max(0.003,hutT*pixel));
        color=fieldWood(p,normal,snow)*(1-seam*0.5);
        float2 q=float2(arenaPeriodicDistance(across+11,3.0),p.y-2.2);
        float window=arenaRect(q,float2(0.49,0.60),hutT*pixel);
        float bars=max(strokeStudy(q.x,0.025,hutT*pixel),strokeStudy(q.y,0.025,hutT*pixel));
        color=mix(color,float3(1.4,0.59,0.12)*(1-bars*0.92),window);
    }
    for(int slope=0;slope<2;slope++) {
        float k=slope==0?0.48:-0.48;
        float denom=rd.y-k*rd.x;if(abs(denom)<0.0001)continue;
        float t=((snow?5.8:6.7)+k*(eye.x+17.5)-eye.y)/denom;float3 p=eye+rd*t;
        if(t<=0.01 || t>=nearest || abs(p.x+17.5)>3.8 || abs(p.z-hutZ)>6.0 || (slope==0?p.x> -17.5:p.x< -17.5))continue;
        nearest=t;float grain=noiseStudy(p.xz*35);
        color=snow?float3(0.40,0.53,0.75)*(0.80+0.2*grain):float3(0.16,0.09,0.026)*(0.60+grain*0.6);
        if(!snow)color*=1-stripeStudy(p.z,0.14,0.023,max(0.002,t*pixel))*0.3;
    }
    if(!snow) {
        // Two simple weathered boards and a short line of warm hut bulbs.
        for(int side=0;side<2;side++) {
            float3 center=float3(side==0?-10.5:10.7,1.35,-7.8),n;
            float t=forestEllipsoid(eye,rd,center,float3(0.29,1.35,0.075),n);
            if(t<nearest){nearest=t;float3 p=eye+rd*t;color=mix(float3(0.016,0.19,0.21),float3(0.65,0.42,0.12),stripeStudy(p.x,0.18,0.05,t*pixel))*fieldLight(p,n,false);}
        }
        for(int bulb=0;bulb<12;bulb++) {
            float3 n,center=float3(-13.6,4.45-0.15*sin(float(bulb)*0.3),-16+bulb*0.91);
            float t=forestEllipsoid(eye,rd,center,float3(0.055,0.08,0.055),n);
            if(t<nearest){nearest=t;color=float3(3.4,1.8,0.5);}
        }
    }
}
float3 fieldSnowfall(float3 color,float3 eye,float3 rd,float nearest,float pixel,float time) {
    // World-space falling points on staggered depth planes, occluded by scenery.
    bool alongZ=abs(rd.z)>abs(rd.x);
    float direction=alongZ?rd.z:rd.x;
    if(abs(direction)<0.001)return color;
    for(int layer=0;layer<11;layer++) {
        float plane=-19+layer*3.8;
        float t=(plane-(alongZ?eye.z:eye.x))/direction;if(t<=0.02 || t>=nearest)continue;
        float3 p=eye+rd*t;float cell=1.15;
        float2 uv=float2((alongZ?p.x:p.z)+time*0.12,p.y+time*(0.45+layer*0.017))/cell;
        float2 id=floor(uv);float seed=hashStudy(id+layer*21.1);
        float2 center=float2(0.18+hashStudy(id+8+layer)*0.64,0.18+hashStudy(id+13+layer)*0.64);
        float2 d=(fract(uv)-center)*cell;
        float size=0.006+seed*0.010;
        float flake=1-smoothstep(size,max(size+0.003,t*pixel),length(d*float2(1,0.72)));
        color=mix(color,float3(0.69,0.78,0.94),flake*0.48*step(0.43,seed));
    }
    return color;
}
float3 seasonalFieldStudy(float3 eye,float3 rd,constant StudyUniforms &u,float pixel,bool snow,texture2d<float> trees,texture2d<float> mountains,texture2d<float> signs) {
    float3 color=fieldSky(rd,snow);float nearest=1e4;
    if(snow) {
        float azimuth=atan2(rd.x,-rd.z);
        float elevation=rd.y/max(0.01,length(rd.xz));
        float2 uv=float2(fract(azimuth/3.141593+0.5),0.97-elevation*2.0);
        if(uv.y>=0 && uv.y<=1) {
            float4 ridge=mountains.sample(forestSampler,uv,level(0));
            color=mix(color,ridge.rgb*float3(0.57,0.69,0.94),smoothstep(0.4,0.98,ridge.a));
        }
    } else {
        // Low distant headlands leave the sunset and water horizon unobstructed.
        float angle=atan2(rd.x,-rd.z),elevation=rd.y/max(0.01,length(rd.xz));
        float ridge=0.015+exp(-pow((angle+0.8)/0.35,2))*0.12;
        ridge+=noiseStudy(float2(angle*20,9))*0.020;
        if(elevation<ridge && rd.y>0)color=float3(0.11,0.10,0.11)*(0.85+noiseStudy(float2(angle*60,elevation*65))*0.3);
    }
    if(rd.y< -0.0001) {
        float t=-eye.y/rd.y;float3 p=eye+rd*t;
        if(t>0) {
            nearest=t;
            if(!snow && p.z< -27+sin(p.x*0.05)*1.2)color=beachOcean(p,rd,u.source.w);
            else color=fieldGround(p,rd,t,pixel,u,snow);
        }
    }
    for(int ring=snow?2:1;ring>=0;ring--) for(int index=0;index<(snow?28:14);index++) {
        ForestTree tree=seasonalTree(snow,ring,index);
        if(!snow && tree.root.z< -13 && abs(tree.root.x)<13)continue;
        float t;float4 leaf=seasonalTreeSample(eye,rd,tree,pixel,trees,t);
        if(t<=0.01 || t>=nearest || leaf.a<0.18)continue;
        float3 foliage=leaf.rgb*(snow?float3(0.34,0.47,0.72):float3(0.72,0.51,0.20));
        if(!snow)foliage+=leaf.rgb*float3(0.42,0.23,0.04)*pow(max(0.0,dot(rd,fieldSun)),6);
        color=mix(color,fieldHaze(foliage,t,snow),smoothstep(0.18,0.8,leaf.a));
        if(leaf.a>0.75)nearest=t;
    }
    // Rounded banks outside the playable area, covered in powder or dry sand.
    for(int i=0;i<12;i++) {
        float angle=float(i)*6.283185/12,seed=hashStudy(float2(i,98));
        float3 center=float3(sin(angle)*19,-0.6,cos(angle)*27-2),normal;
        if(!snow && center.z< -16)continue;
        float t=forestEllipsoid(eye,rd,center,float3(3+seed*2,1.1+seed,3.5+seed*2),normal);
        if(t<nearest){nearest=t;float3 p=eye+rd*t;color=(snow?float3(0.58,0.70,0.91):float3(0.40,0.26,0.12))*fieldLight(p,normal,snow)*(0.9+noiseStudy(p.xz*25)*0.15);}
    }
    if(!snow && rd.z< -0.001) {
        for(int boat=0;boat<2;boat++) {
            float z=boat==0?-105.0:-150.0,x=boat==0?24.0:-23.0;
            float t=(z-eye.z)/rd.z;float3 p=eye+rd*t;
            if(t<=0 || t>=nearest || p.y<0 || p.y>4.5)continue;
            float2 q=float2(p.x-x,p.y);float aa=max(0.004,t*pixel);
            float mast=strokeStudy(q.x,0.035,aa);
            float sail=step(0.12,q.x)*step(q.x,(4.2-q.y)*0.50)*step(0.45,q.y)*step(q.y,4.15);
            float hull=arenaRect(q-float2(0,0.15),float2(1.2,0.13),aa);
            float coverage=max(mast,max(sail,hull));
            color=mix(color,mix(float3(0.08,0.06,0.04),float3(0.69,0.52,0.27),sail),coverage);
            if(coverage>0.9)nearest=t;
        }
    }
    fieldProps(eye,rd,pixel,snow,signs,color,nearest);
    if(snow)color=fieldSnowfall(color,eye,rd,nearest,pixel,u.source.w);
    return displayStudy(max(color,0.0));
}
