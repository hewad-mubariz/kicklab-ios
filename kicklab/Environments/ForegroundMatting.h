// Source-guided boundary refinement and motion-validated temporal coverage.
// Included by StadiumPreview.metal so preview/export and CLI use one library.
constexpr sampler matteSampler(coord::normalized,address::clamp_to_edge,filter::linear);

kernel void refineForegroundEdges(texture2d<float,access::sample> color [[texture(0)]],
                                  texture2d<float,access::sample> mask [[texture(1)]],
                                  texture2d<float,access::sample> oldColor [[texture(2)]],
                                  texture2d<float,access::sample> oldAlpha [[texture(3)]],
                                  texture2d<float,access::sample> flow [[texture(4)]],
                                  texture2d<half,access::write> outColor [[texture(5)]],
                                  texture2d<half,access::write> outAlpha [[texture(6)]],
                                  constant uint &hasHistory [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=color.get_width() || gid.y>=color.get_height())return;
    float2 texel=1.0/float2(color.get_width(),color.get_height()),uv=(float2(gid)+0.5)*texel;
    float a=mask.sample(matteSampler,uv).r;
    float3 rgb=color.sample(matteSampler,uv).rgb;
    float3 value=linearStudy(rgb),foreground=value;
    // Search only a narrow uncertainty band; opaque interiors stay untouched.
    float3 f=0,b=0;float fd=100,bd=100,refinementTrust=0;
    if(a>0.003) {
        for(int ring=1;ring<=5;ring++) {
            float distance=float(ring==1?1:ring==2?3:ring==3?5:ring==4?8:12);
            for(int i=0;i<8;i++) {
                float angle=float(i)*M_PI_F/4;
                float2 q=uv+float2(cos(angle),sin(angle))*distance*texel;
                if(any(q<0)||any(q>1))continue;
                float sampleAlpha=mask.sample(matteSampler,q).r;
                if(sampleAlpha<0.015 && distance<bd) {bd=distance;b=linearStudy(color.sample(matteSampler,q).rgb);}
            }
        }
        // A confidently opaque label can itself include foliage. Prefer a
        // nearby interior color that explains this pixel as F/B coverage and
        // is distinguishable from the sampled background, rather than blindly
        // taking the nearest opaque pixel (which can be the same fringe).
        if(bd<=5) {
            float best=1e6;
            for(int ring=1;ring<=4;ring++) for(int i=0;i<8;i++) {
                float distance=float(ring==1?3:ring==2?5:ring==3?8:12);
                float angle=float(i)*M_PI_F/4;
                float2 q=uv+float2(cos(angle),sin(angle))*distance*texel;
                if(any(q<0)||any(q>1))continue;
                float core=min(min(mask.sample(matteSampler,q+float2(4,0)*texel).r,mask.sample(matteSampler,q-float2(4,0)*texel).r),
                               min(mask.sample(matteSampler,q+float2(0,4)*texel).r,mask.sample(matteSampler,q-float2(0,4)*texel).r));
                if(core<0.985 || mask.sample(matteSampler,q).r<0.985)continue;
                float3 candidate=linearStudy(color.sample(matteSampler,q).rgb),delta=candidate-b;
                float separation=length(delta);
                if(separation<0.10)continue;
                float estimate=saturate(dot(value-b,delta)/max(0.001,dot(delta,delta)));
                float residual=length(value-mix(b,candidate,estimate));
                float score=residual+distance*0.002+abs(estimate-a)*0.01;
                if(score<best) {best=score;fd=distance;f=candidate;}
            }
        }
        if(fd<100 && bd<=5) {
            float3 delta=f-b;float separation=length(delta);
            float estimate=saturate(dot(value-b,delta)/max(0.001,dot(delta,delta)));
            float residual=length(value-mix(b,f,estimate));
            float trust=(1-smoothstep(0.045,0.18,residual))*smoothstep(0.10,0.25,separation);
            // Matching the old background is evidence to reduce even an
            // incorrectly opaque fringe; no global erosion or chroma key.
            a=mix(a,estimate,trust);
            refinementTrust=trust;
        }
    }
    if(hasHistory!=0) {
        float2 displacement=flow.sample(matteSampler,uv).rg/float2(flow.get_width(),flow.get_height());
        float2 previousUV=uv+displacement;
        if(all(previousUV>=0) && all(previousUV<=1)) {
            float3 previousRGB=oldColor.sample(matteSampler,previousUV).rgb;
            float previousAlpha=oldAlpha.sample(matteSampler,previousUV).r;
            float photo=1-smoothstep(0.025,0.12,length(rgb-previousRGB));
            float agreement=1-smoothstep(0.15,0.55,abs(a-previousAlpha));
            float low=mask.sample(matteSampler,uv).r,high=low;
            for(int i=0;i<8;i++) {
                float angle=float(i)*M_PI_F/4;
                float coverage=mask.sample(matteSampler,uv+float2(cos(angle),sin(angle))*2*texel).r;
                low=min(low,coverage);high=max(high,coverage);
            }
            float boundary=smoothstep(0.15,0.5,high-low);
            // Low-opacity history can agree numerically with empty alpha.
            // Without current support that agreement would spread a faint
            // old edge into the background, especially around moving hair.
            float support=smoothstep(0.005,0.06,high);
            // Disocclusions and disappearing objects cannot borrow opaque
            // history outside a two-pixel current boundary. Color agreement
            // and flow also reject the previous position of a moving limb.
            // Whole missing limbs are repaired from this frame's person guide.
            a=mix(a,previousAlpha,0.70*photo*support*mix(agreement,1.0,boundary*0.8));
        }
    }
    if(refinementTrust>0) {
        float3 recovered=saturate((value-(1-a)*b)/max(0.10,a));
        // Dividing very weak coverage amplifies color noise. A nearby
        // confident interior supplies the low-alpha color limit.
        recovered=mix(f,recovered,smoothstep(0.10,0.45,a));
        foreground=mix(value,recovered,refinementTrust);
    }
    if(a<0.003)a=0;
    // Store linear-premultiplied foreground, encoded for the SDR movie. The
    // old park cannot leak back through codec ringing in nominally empty alpha.
    outColor.write(half4(half3(displayStudy(foreground*a)),1),gid);
    outAlpha.write(half4(half3(a),1),gid);
}
