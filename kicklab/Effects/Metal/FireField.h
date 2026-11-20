// Shared by Juggle Dude fire and wall-game meteor materials.
#pragma once
#include "ShotShaderMath.h"

// Ridged turbulence: the sharp bright filaments inside a flame sheet.
float fireRidge3(float3 p) {
    float s=abs(fireNoise3(p)*2-1)*0.5;
    p=p*2.1+float3(-5.5,8.3,3.7); s+=abs(fireNoise3(p)*2-1)*0.25;
    p=p*2.1+float3(9.2,-3.9,6.1); s+=abs(fireNoise3(p)*2-1)*0.125;
    return 1-s/0.875;
}
// Fire shading. Blackbody-style HDR ramp: red tips, orange edges, yellow
// body, white-hot deep inside. Tone-mapped in resolveFX.
float3 fireRamp(float h) {
    float3 red=float3(1.6,0.14,0.01);
    float3 orange=float3(3.4,0.85,0.05);
    float3 yellow=float3(4.8,2.7,0.4);
    float3 white=float3(6.5,5.8,3.6);
    return h<0.3 ? mix(red,orange,h/0.3)
         : h<0.7 ? mix(orange,yellow,(h-0.3)/0.4)
         : mix(yellow,white,saturate((h-0.7)/0.3));
}
// Two smooth octaves: contours stay long and curling instead of breaking
// into a crackle network.
float fireSmooth3(float3 p) {
    return fireNoise3(p)*0.7+fireNoise3(p*1.9+float3(11.3,-4.1,7.7))*0.3;
}
// Flame turbulence: near the ball it is radial (tongues leave the surface at
// every angle, travel outward and bend into the wind); further out it is a
// rising world-space field. Blended as fields, not coordinates, so shapes
// morph rather than tear.
float fireTongueField(float2 w,float2 q,float R,float S,float2 wd,float t,float2 warp) {
    float world=fireFBM3(float3(w.x*1.6+warp.x*1.8,w.y*0.7+t*2.8+warp.y*1.4,t*0.7));
    float r=max(length(q),0.001);
    float out=max(0.0,r-1.0);
    float2 dir=normalize(q/r+wd*out*1.1);
    float radial=fireFBM3(float3(dir*4.2+warp*1.1,(r-t*2.1)*2.0*R/S+20.0));
    return mix(world,radial,exp(-out/0.9));
}
