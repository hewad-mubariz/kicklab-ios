// Shared by Metal and the background CPU renderer. Keep material math identical.
#pragma once
float3 fireSpectrum(float heat) {
    float3 red = float3(1.8f, 0.025f, 0.001f);
    float3 orange = float3(4.0f, 0.34f, 0.007f);
    float3 yellow = float3(6.5f, 2.3f, 0.14f);
    float3 white = float3(8.0f, 6.7f, 2.8f);
    return heat < 0.4f ? mix(red, orange, heat / 0.4f)
         : heat < 0.76f ? mix(orange, yellow, (heat - 0.4f) / 0.36f)
         : mix(yellow, white, (heat - 0.76f) / 0.24f);
}
float3 iceSpectrum(float cold) {
    float3 deep = float3(0.05f, 0.35f, 1.35f);
    float3 cyan = float3(0.25f, 1.35f, 2.55f);
    float3 frost = float3(1.15f, 2.05f, 2.85f);
    float3 white = float3(2.4f, 2.85f, 3.2f);
    return cold < 0.4f ? mix(deep, cyan, cold / 0.4f)
         : cold < 0.76f ? mix(cyan, frost, (cold - 0.4f) / 0.36f)
         : mix(frost, white, (cold - 0.76f) / 0.24f);
}
float lineFX(float distance, float width) {
    return exp(-pow(distance/max(width,0.002f),2.0f));
}
float3 filamentFX(float d,float width,float3 tint,float core) {
    return tint*(lineFX(d,width)*1.55f+lineFX(d,width*3.2f)*0.22f)
        +float3(2.4f,2.5f,2.4f)*lineFX(d,width*0.26f)*core;
}
float fireValue3(int3 cell) {
    uint3 p=as_type<uint3>(cell);
    uint n=p.x*374761393u+p.y*668265263u+p.z*2246822519u;
    n=(n^(n>>13))*1274126177u;
    n^=n>>16;
    return float(n&0xFFFFFFu)/16777215.0f;
}
float fireNoise3(float3 p) {
    int3 c=int3(floor(p));
    float3 f=fract(p);
    f=f*f*f*(f*(f*6-15)+10);
    float x00=mix(fireValue3(c),fireValue3(c+int3(1,0,0)),f.x);
    float x10=mix(fireValue3(c+int3(0,1,0)),fireValue3(c+int3(1,1,0)),f.x);
    float x01=mix(fireValue3(c+int3(0,0,1)),fireValue3(c+int3(1,0,1)),f.x);
    float x11=mix(fireValue3(c+int3(0,1,1)),fireValue3(c+int3(1,1,1)),f.x);
    return mix(mix(x00,x10,f.y),mix(x01,x11,f.y),f.z);
}
float fireFBM3(float3 p) {
    float s=fireNoise3(p)*0.5f;
    p=p*2.02f+float3(13.7f,-9.1f,5.3f); s+=fireNoise3(p)*0.25f;
    p=p*2.03f+float3(-7.3f,19.1f,2.1f); s+=fireNoise3(p)*0.125f;
    p=p*2.01f+float3(31.1f,4.7f,-8.9f); s+=fireNoise3(p)*0.0625f;
    return s/0.9375f;
}
