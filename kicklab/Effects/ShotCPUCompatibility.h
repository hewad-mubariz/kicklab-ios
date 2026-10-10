// Metal's scalar/vector math mapped to Apple's CPU SIMD types.
#pragma once
#include <simd/simd.h>
#include <cmath>
#include <cstring>
using float2=simd_float2; using float3=simd_float3; using float4=simd_float4;
using int3=simd_int3; using uint3=simd_uint3; using uint=uint32_t;
static inline float3 makeFloat3(float x) { return {x,x,x}; }
static inline float3 makeFloat3(float x,float y,float z) { return {x,y,z}; }
static inline float3 makeFloat3(float2 xy,float z) { return {xy.x,xy.y,z}; }
static inline int3 makeInt3(float3 v) { return __builtin_convertvector(v,int3); }
static inline int3 makeInt3(int x,int y,int z) { return {x,y,z}; }
#define float2(...) simd_make_float2(__VA_ARGS__)
#define float3(...) makeFloat3(__VA_ARGS__)
#define float4(...) simd_make_float4(__VA_ARGS__)
#define int3(...) makeInt3(__VA_ARGS__)
#define constant const
static inline float min(float a,float b) { return fminf(a,b); }
static inline float max(float a,float b) { return fmaxf(a,b); }
static inline float clamp(float x,float a,float b) { return min(max(x,a),b); }
static inline float saturate(float x) { return clamp(x,0,1); }
static inline float fract(float x) { return x-floorf(x); }
static inline float3 fract(float3 x) { return {fract(x.x),fract(x.y),fract(x.z)}; }
static inline float3 floor(float3 x) { return {floorf(x.x),floorf(x.y),floorf(x.z)}; }
static inline float3 exp(float3 x) { return {expf(x.x),expf(x.y),expf(x.z)}; }
static inline float3 min(float3 a,float3 b) { return simd_min(a,b); }
static inline float dot(float2 a,float2 b) { return simd_dot(a,b); }
static inline float length(float2 a) { return simd_length(a); }
static inline float distance(float2 a,float2 b) { return simd_distance(a,b); }
static inline float smoothstep(float a,float b,float x) { float t=saturate((x-a)/(b-a)); return t*t*(3-2*t); }
template<class T> static inline T mix(T a,T b,float t) { return a+(b-a)*t; }
template<class T,class F> static inline T as_type(F v) { static_assert(sizeof(T)==sizeof(F)); T out; memcpy(&out,&v,sizeof(v)); return out; }
static inline bool all(simd_int2 v) { return v.x && v.y; }
