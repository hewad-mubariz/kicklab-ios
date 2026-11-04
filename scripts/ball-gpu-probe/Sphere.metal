#include <metal_stdlib>
using namespace metal;

// Experimental translation of BallSkinSphereRenderer. No app target includes this file.
struct Params { float4 pose; uint4 options; };
float3 rotateQ(float4 q, float3 v) { return v + 2 * cross(q.xyz, cross(q.xyz, v) + q.w * v); }
float steel(float3 n) {
    float3 r = 2 * n.z * n - float3(0,0,1);
    return .055f + smoothstep(-.6f,.9f,r.y)*.17f
        + pow(max(0.f,dot(r,normalize(float3(-.7,.7,.35)))),5.f)*1.65f
        + pow(max(0.f,dot(r,normalize(float3(.9,.25,.1)))),7.f)*1.15f
        + pow(max(0.f,dot(r,normalize(float3(-.9,-.15,-.2)))),12.f)*.8f;
}
float3 shade(uint skin, float3 rgb, float gap, float3 n, float3 view) {
    float3 light = float3(-.45,.65,.612372), halfLight = normalize(light+float3(0,0,1));
    float diffuse = .16f+.84f*max(0.f,dot(n,light));
    float spec = pow(max(0.f,dot(n,halfLight)),32.f), rim = pow(1-view.z,4.f);
    if (skin == 10) return rgb*rgb*steel(n)+rim*.16f; // metal
    if (skin == 11) {
        float crack=1-smoothstep(.003f,.013f,gap), glow=1-smoothstep(.008f,.036f,gap);
        return rgb*rgb*diffuse*(1-crack*.9f) + float3(1.4,.24,.008)*crack
            + float3(.42,.045,.002)*glow + spec*.07f*(1-glow);
    }
    if (skin == 12) {
        float groove=1-smoothstep(.002f,.014f,gap), bevel=exp(-pow((gap-.019f)/.008f,2.f))*.065f;
        float narrow=pow(max(0.f,dot(view,normalize(float3(.65,.3,1.8)))),100.f);
        return rgb*rgb*((.24f+diffuse*.76f)*(1-groove*.5f)+bevel)
            + spec*.35f+narrow*.06f+rim*.045f + float3(.045,.025,.06)*pow(1-view.z,1.3f);
    }
    if (skin == 13) {
        float groove=1-smoothstep(.018f,.030f,gap), bevel=exp(-pow((gap-.040f)/.009f,2.f))*.075f;
        return (rgb*rgb*(1-groove)+float3(.016,.023,.013)*groove)*(.14f+diffuse*.86f)
            +rgb*bevel+spec*.065f+rim*.012f;
    }
    float lambert=max(0.f,dot(n,light)), highlight=pow(max(0.f,dot(n,halfLight)),36.f);
    float groove=1-smoothstep(.002f,.011f,gap), bevel=exp(-pow((gap-.015f)/.007f,2.f))*.025f;
    float metallic=skin==7 ? .8f : (skin==3 ? smoothstep(.10f,.38f,rgb.x-rgb.z)*.85f : 0.f);
    diffuse=.30f+.70f*lambert;
    float specular=.065f, edge=.018f, emission=0;
    if(skin==1){specular=.014f;edge=.030f;}
    if(skin==2){specular=.045f;emission=max(0.f,rgb.y-max(rgb.x,rgb.z))*.14f;}
    if(skin==3 || skin==7) specular=.10f;
    if(skin==4){specular=.14f;edge=.026f;}
    if(skin==6){
        diffuse=.20f+.72f*max(0.f,dot(n,normalize(float3(-.28,.48,.832))))+.08f*view.z;
        specular=.035f;edge=.0042f;
        emission=max(0.f,dot(rgb,float3(.2126,.7152,.0722))-.45f)*.15f;
    }
    if(skin==9) specular=.095f;
    float lighting=metallic>0 ? diffuse*(1-metallic*.65f)+steel(n)*metallic*.65f : diffuse;
    return rgb*rgb*((lighting+emission)*(1-groove*.60f)+bevel)
        +(float3(1-metallic*.5f)+rgb*metallic*.5f)*(highlight*specular+rim*edge)*(1-groove*.75f);
}
float3 normalAt(device const uchar* values, uint i) {
    return float3(values[i*3],values[i*3+1],values[i*3+2])/127.5f-1;
}
kernel void sphere(device const uchar4* colors [[buffer(0)]], device const uchar* normals [[buffer(1)]],
                   device uchar4* output [[buffer(2)]], constant Params& p [[buffer(3)]], uint2 xy [[thread_position_in_grid]]) {
    uint side=p.options.x, skin=p.options.y;
    if(any(xy>=side)) return;
    uint index=xy.y*side+xy.x;
    float nx=(float(xy.x)+.5f)/float(side)*2-1, ny=1-(float(xy.y)+.5f)/float(side)*2;
    float rr=nx*nx+ny*ny;
    if(rr>=1){output[index]=uchar4(0);return;}
    float3 view=float3(nx,ny,sqrt(max(0.f,1-rr)));
    float alpha=min(1.f,(1-sqrt(rr))*float(side)*.5f);
    float3 obj=rotateQ(float4(-p.pose.xyz,p.pose.w),view);
    float u=(atan2(obj.x,obj.z)/(2*M_PI_F)+.5f)*1024-.5f;
    float v=clamp((.5f-asin(clamp(obj.y,-1.f,1.f))/M_PI_F)*512-.5f,0.f,511.f);
    int bx=int(floor(u)), by=int(v), x0=(bx+1024)%1024,x1=(x0+1)%1024,y1=min(511,by+1);
    float fx=u-bx,fy=v-by;
    float4 weights=float4((1-fx)*(1-fy),fx*(1-fy),(1-fx)*fy,fx*fy);
    uint4 i=uint4(by*1024+x0,by*1024+x1,y1*1024+x0,y1*1024+x1);
    float4 tex=float4(colors[i.x])*weights.x+float4(colors[i.y])*weights.y
        +float4(colors[i.z])*weights.z+float4(colors[i.w])*weights.w;
    float3 n=normalize(normalAt(normals,i.x)*weights.x+normalAt(normals,i.y)*weights.y
        +normalAt(normals,i.z)*weights.z+normalAt(normals,i.w)*weights.w);
    float3 lit=shade(skin,tex.xyz/255.f,tex.w/2550.f,rotateQ(p.pose,n),view);
    output[index]=uchar4(uchar3(floor(clamp(sqrt(max(float3(0),lit)),0.f,1.f)*alpha*255+.5f)),uchar(floor(alpha*255+.5f)));
}
