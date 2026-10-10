// Shared camera mapping for preview and CPU background export.
#pragma once
float2 shotCameraUV(float2 pixel, float2 panel, constant ShotCameraUniforms &u) {
    float2 size = u.viewport.xy;
    float fit = max(panel.x / size.x, panel.y / size.y);
    float2 q = (pixel - panel * .5f) / (fit * u.crop.z);
    float c = cos(u.crop.w), s = sin(u.crop.w);
    q = float2(c*q.x + s*q.y, -s*q.x + c*q.y);
    return q / size + u.crop.xy;
}
float shotCameraSegment(float2 p, float2 a, float2 b) {
    float2 ab = b-a;
    return length(p-a-ab*clamp(dot(p-a,ab)/max(.001f,dot(ab,ab)),0.f,1.f));
}


float4 shotCameraPixel(SHOT_TEXTURE source, SHOT_TEXTURE original,
                      constant ShotCameraUniforms &u, constant float4 *path, float2 p) {
    float2 size = u.viewport.xy;
    int mode = int(u.viewport.z);
    float4 color = source.sample(linear, shotCameraUV(p, size, u));
    if (mode == 6) {
        bool stacked = u.layout.x > .5f;
        float2 panel = stacked ? float2(size.x,size.y*u.layout.y) : float2(size.x*u.layout.y,size.y);
        bool wide = stacked ? p.y < panel.y : p.x < panel.x;
        if (wide) {
            float fit = min(panel.x/size.x,panel.y/size.y);
            float2 uv = (p-panel*.5f)/(size*fit)+.5f;
            color = all(uv>=0.f) && all(uv<=1.f) ? source.sample(linear,uv) : float4(.025f,.045f,.035f,1);
        } else {
            float2 offset = stacked ? float2(0,panel.y) : float2(panel.x,0);
            float2 detail = stacked ? float2(size.x,size.y-panel.y) : float2(size.x-panel.x,size.y);
            color = source.sample(linear,shotCameraUV(p-offset,detail,u));
        }
        if (abs(stacked ? p.y-panel.y : p.x-panel.x)<max(1.f,size.x*.002f)) color=float4(.025f,.045f,.035f,1);
    }
    if (mode == 4 && u.lens.w > 0) {
        float r = min(size.x,size.y)*u.inset.z;
        float2 center=u.inset.xy*size;
        float distance=length(p-center);
        float stroke=max(1.f,size.x*.003f);
        if (distance<r) {
            float fit=max(size.x/original.get_width(),size.y/original.get_height());
            float2 uv=u.lens.xy+(p-center)/(float2(original.get_width(),original.get_height())*fit*u.lens.z);
            color=original.sample(linear,uv);
        }
        if (abs(distance-r)<stroke) color=float4(.80f,1,.43f,1);
    }
    if (mode == 5) {
        float line=max(1.f,size.x*.0028f), distance=100000.f;
        for (int i=1;i<int(u.viewport.w);i++) {
            if (path[i].z>.5f) distance=min(distance,shotCameraSegment(p,path[i-1].xy*size,path[i].xy*size));
        }
        if (length(u.guide.zw)>.5f) {
            float2 a=u.guide.xy*size, dir=u.guide.zw, tip=a+dir*min(size.x,size.y)*.12f;
            float2 side=float2(-dir.y,dir.x);
            float arrow=min(size.x,size.y)*.025f;
            distance=min(distance,shotCameraSegment(p,a,tip));
            distance=min(distance,shotCameraSegment(p,tip,tip-dir*arrow+side*arrow*.55f));
            distance=min(distance,shotCameraSegment(p,tip,tip-dir*arrow-side*arrow*.55f));
        }
        float alpha=1-smoothstep(line,line+1.5f,distance);
        color=mix(color,float4(.80f,1,.43f,1),alpha*.95f);
    }
    return float4(color.rgb,1);
}
