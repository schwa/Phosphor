#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float time;
    float frame;
    float2 resolution;
    float2 mouse;
};

// Iterative trigonometric pattern
float4 iterativeTrig(float2 gl_FragCoord, float time) {
    float4 p = float4(gl_FragCoord.xy / 4e2, 0, -4);

    for(int i = 0; i < 9; ++i) {
        p += float4(
            sin(-(p.x + time * 0.2)) + atan(p.y * p.w),
            cos(-p.x) + atan(p.z * p.w),
            cos(-(p.x + sin(time * 0.8))) + atan(p.z * p.w),
            0
        );
    }
    
    return p;
}

// Fractal kaleidoscope pattern
float4 fractalKaleidoscope(float2 gl_FragCoord, float2 resolution, float2 mouse, float time) {
    float2 r = resolution;
    float2 p = (gl_FragCoord.xy * 2.0 - r) / min(r.x, r.y) - mouse;
    
    for(int i = 0; i < 8; ++i) {
        p.xy = abs(p) / dot(p, p) - float2(0.9 + cos(time * 0.2) * 0.4);
    }
    
    return float4(p.x, p.x, p.y, 1.0);
}

// Raymarched turbulent ring - BROKEN: shows gray or laser effect
float4 turbulentRing(float2 gl_FragCoord, float2 resolution, float time) {
    // In twigl, coordinates work differently - let's normalize them
    float2 uv = (gl_FragCoord - resolution * 0.5) / min(resolution.x, resolution.y);
    float4 o = float4(0);
    
    float i = 0.0, z = 0.0, d = 0.0;
    
    for(; i < 80.0; i++) {
        // Create ray direction from normalized coordinates
        float3 p = z * normalize(float3(uv, 0.7));
        float3 a = normalize(cos(float3(4, 2, 0) + time - d * 8.0));
        
        p.z += 5.0;
        a = a * dot(a, p) - cross(a, p);
        
        for(d = 1.0; d < 9.0; d++) {
            a += sin(a * d + time).yzx / d;
        }
        
        d = 0.05 * abs(length(p) - 3.0) + 0.04 * abs(a.y);
        z += d;
        
        o += (cos(d / 0.1 + float4(0, 2, 4, 0)) + 1.0) / d * z;
    }
    
    o = tanh(o / 1e4);
    return o;
}

// Geometric flow shader - BROKEN: laser show effect
float4 geometricFlow(float2 gl_FragCoord, float2 resolution, float time) {
    float2 r = resolution;
    float2 FC = gl_FragCoord;
    float4 o = float4(0);
    
    float i = 0.0, z = 0.0, d = 0.0;
    
    for(; i < 100.0; i++) {
        // Ray direction using twigl convention - FC.rgb with vec2 becomes (x,y,0)
        float3 p = z * normalize(float3(FC.x, FC.y, 0) * 2.0 - float3(r.x, r.y, r.y));
        float3 a = normalize(cos(float3(4, 2, 0) + time - d / 0.1));
        
        p.z += 8.0;
        a = a * dot(a, p) - cross(a, p);
        
        for(d = 1.0; d < 5.0; d++) {
            a += sin(a * d + time).yzx / d;
        }
        
        d = abs(length(a) - 5.0) / 6.0;
        z += d;
        
        o += float4(3, 8, z, 0) / d / 9e4;
    }
    
    return o;
}

// Fast simplex noise (fsnoise in twigl)
float fsnoise(float2 v) {
    const float2 C = float2(0.366025403784439, 0.211324865405187);
    float2 i = floor(v + dot(v, C.xx));
    float2 x0 = v - i + dot(i, C.yy);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 x1 = x0 - i1 + C.y;
    float2 x2 = x0 - 1.0 + 2.0 * C.y;
    i = fmod(i, 289.0);
    float3 p = fmod((i.y + float3(0.0, i1.y, 1.0)) * 289.0 + i.x + float3(0.0, i1.x, 1.0), 289.0);
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x1, x1), dot(x2, x2)), 0.0);
    m = m * m * m * m;
    float3 x = fract(p / 41.0) * 2.0 - 1.0;
    float3 a = abs(x) - 0.5;
    float3 h = 1.0 - abs(x);
    float3 b = float3(x.x + x.y, x.y + x.z, x.z + x.x);
    float3 g = step(float3(0), b) * a.xyz + (1.0 - step(float3(0), b)) * float3(-a.y, -a.z, -a.x);
    return 130.0 * dot(m, g);
}

// 2D simplex noise function
float snoise2D(float2 v) {
    const float4 C = float4(0.211324865405187,  // (3.0-sqrt(3.0))/6.0
                           0.366025403784439,  // 0.5*(sqrt(3.0)-1.0)
                          -0.577350269189626,  // -1.0 + 2.0 * C.x
                           0.024390243902439); // 1.0 / 41.0
    
    float2 i  = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    
    i = fmod(i, 289.0);
    float3 p = fmod((i.y + float3(0.0, i1.y, 1.0)) * 289.0 + i.x + float3(0.0, i1.x, 1.0), 289.0);
    
    float3 m = max(0.5 - float3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
    m = m*m;
    m = m*m;
    
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    
    m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);
    
    float3 g;
    g.x  = a0.x  * x0.x  + h.x  * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// Helper function to convert HSV to RGB
float3 hsv(float h, float s, float v) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(float3(h) + K.xyz) * 6.0 - K.www);
    return v * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), s);
}

// Helper function for 2D rotation
float2x2 rotate2D(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return float2x2(c, -s, s, c);
}

// Helper function for 3D rotation around arbitrary axis
float3x3 rotate3D(float angle, float3 axis) {
    float c = cos(angle);
    float s = sin(angle);
    float t = 1.0 - c;
    
    float3 n = normalize(axis);
    float x = n.x, y = n.y, z = n.z;
    
    return float3x3(
        t*x*x + c,    t*x*y - s*z,  t*x*z + s*y,
        t*x*y + s*z,  t*y*y + c,    t*y*z - s*x,
        t*x*z - s*y,  t*y*z + s*x,  t*z*z + c
    );
}

// Pulsing heart muscle shader

float4 pulsingHeart(float2 gl_FragCoord, float2 resolution, float time) {
    float2 r = resolution;
    float2 p = (gl_FragCoord.xy * 2.0 - r) / r.y;
    float2 n = float2(0), N = float2(0), q;
    float4 o = float4(0);
    float S = 5.0, a = 0.0, j = 0.0;
    float t = time;
    
    float2x2 m = rotate2D(5.0);
    
    for(; j < 30.0; j++) {
        p = p * m;
        n = n * m;
        q = p * S + j + n + t * 4.0 + sin(t * 4.0) * 0.8;
        a += dot(cos(q) / S, r / r);
        q = sin(q);
        n += q;
        N += q / (S + 20.0);
        S *= 1.2;
    }
    
    o += 0.1 - a * 0.1;
    o.r *= 5.0;
    o += min(0.7, 0.001 / length(N));
    o -= o * dot(p, p) * 0.7;
    
    return o;
}

// Terrain river shader
float4 terrainRiver(float2 gl_FragCoord, float2 resolution, float time) {
    float2 r = resolution;
    float2 FC = gl_FragCoord;
    float4 o = float4(0);
    float t = time;
    
    float i = 0.0, e = 0.0, g = 0.0, s = 0.0;
    
    for(; i < 100.0; i++) {
        float3 p = float3((FC.xy - 0.5 * r) / r.y * g, g - 5.0);
        p.y -= p.z * 0.6;
        p.z += t;
        
        e = p.y - tanh(abs(p.x + sin(p.z) * 0.5));
        
        for(s = 2.0; s < 1000.0; s += s) {
            float2 xz = p.xz * rotate2D(s);
            p.x = xz.x;
            p.z = xz.y;
            e += abs(dot(sin(p.xz * s), r / r / s / 4.0));
        }
        
        e = min(e, p.y) - 1.3;
        
        // FC.zzwz in twigl with 2D coords becomes (0,0,1,0)
        float4 zzwz = float4(0, 0, 1, 0);
        o += 0.01 - 0.01 / exp(e * 1e3 - sign(p.y - 1.31) * zzwz * 0.1);
        
        g += e * 0.4;
    }
    
    return o;
}

// Fractal plant shader - SEMI-BROKEN: produces plant-like structures
float4 fractalPlant(float2 gl_FragCoord, float2 resolution, float time) {
    float2 r = resolution;
    float2 FC = gl_FragCoord;
    float4 o = float4(0);
    float t = time;
    
    float i = 0.0, e = 0.0, g = 0.0, v = 0.0, u = 0.0;
    
    for(; i < 80.0; i++) {
        float3 p = float3((0.5 * r - FC.xy) / r.y * g, g - 4.0);
        p.xz = p.xz * rotate2D(t * 0.2);
        
        e = 2.0;
        v = 2.0;
        
        for(int j = 0; j < 12; j++) {
            if(j > 3) {
                u = dot(p, p);
                e = min(e, length(p.xz + length(p) / u * 0.557) / v);
                p.xz = abs(p.xz) - 0.7;
            } else {
                p = abs(p) - 0.9;
            }
            
            u = dot(p, p);
            v /= u;
            p /= u;
            p.y = 1.7 - p.y;
        }
        
        g += e;
        o.rgb += 0.01 - hsv(-0.4 / u, 0.3, 0.02) / exp(e * 60.0);
    }
    
    return o;
}

// Cityscape shader - SEMI-BROKEN: renders but with artifacts
float4 cityscape(float2 gl_FragCoord, float2 resolution, float time) {
    float2 r = resolution;
    float2 FC = gl_FragCoord;
    float4 o = float4(0);
    float t = time;
    
    float i = 0.0, s = 0.0, e = 0.0, m = 0.0;
    float3 d, w = float3(0), q, p;
    
    // FC.rgb with 2D coords becomes (x, y, 0)
    d = float3(FC.x, FC.y, 0) / r.y - 1.0;
    w += 4.0;
    
    for(; i < 200.0; i++) {
        s = 2.0;
        p = w + d * e;
        p.xz = p.xz * rotate2D(t * 0.2);
        
        q = round(p);
        p -= q;
        m = fsnoise(q.zx) * 4.0;
        p.y = w.y - m;
        
        for(int j = 0; j < 9; j++) {
            e = min(dot(p, p), 0.4) + 0.1;
            s /= e;
            p = abs(p) / e - 0.2;
            p.y -= m;
        }
        
        e = clamp(length(p) / s - m / s, w.y - m, 0.2) + i / 1e6;
        
        if(i > 100.0) {
            d /= d;  // This creates NaN/inf intentionally
            o = o;
        } else {
            o += exp(-e * 5e3);
        }
        
        w += d * e;
    }
    
    o *= e / 20.0;
    
    return o;
}

// Fractal structure shader - BROKEN: produces artifacts
float4 fractalStructure(float2 gl_FragCoord, float2 resolution, float time) {
    float2 r = resolution;
    float2 FC = gl_FragCoord;
    float4 o = float4(0);
    float t = time;
    
    float l = 0.0, i = 0.0, e = 0.0;
    float3 q, p;
    
    // FC.qpp with 2D coords in twigl becomes (x, y, y)
    p = float3(FC.x, FC.y, FC.y);
    p.xz -= t;
    
    for(; i < 150.0; i++) {
        p.xz = fmod(p.xz + 4.0, 8.0) - 4.0;
        
        // FC.stp with 2D coords becomes (x, 0, y)
        float3 stp = float3(FC.x, 0, FC.y);
        float3 dir = normalize(stp * 2.0 - float3(r.x, r.y, r.y)) * e * 0.2;
        p += dir;
        q = p;
        
        e = 1.0;
        for(l = 1.0; l > 0.2; l *= 0.8) {
            q = abs(q * 1.2);
            q.y -= 1.5;
            e = min(e, max(q.y - 0.1, q.x + q.z - l * 0.2));
            
            // FC.qqp with 2D coords becomes (x, x, y)
            float3 qqp = float3(FC.x, FC.x, FC.y) - 0.75;
            q = q * rotate3D(l, qqp);
        }
        
        e = min(e, p.y + q.z * 0.1);
        o += e / 2e2;
    }
    
    // FC.pq with 2D coords becomes (y, x)
    o.gb -= q.y / i * float2(FC.y, FC.x);
    
    return o;
}

// Complex terrain shader - BROKEN: produces white pixels
float4 complexTerrain(float2 gl_FragCoord, float2 resolution, float time) {
    float2 r = resolution;
    float2 FC = gl_FragCoord;
    float4 o = float4(0);
    float t = time;
    
    float e = 0.0, i = 0.0, a = 0.0, w = 0.0, x = 0.0, g = 0.0;
    
    for(; i < 100.0; i++) {
        float3 p = float3((FC.xy - 0.5 * r) / r.y * g, g - 3.0);
        
        // Rotate ZY plane
        float2 zy = p.zy * rotate2D(0.6);
        p.z = zy.x;
        p.y = zy.y;
        
        // Add small epsilon to avoid singularities
        if(i < 100.0) {
            p += 1e-4;
        }
        
        e = p.y;
        
        for(a = 0.8; a > 0.003; a *= 0.8) {
            // Rotate XZ plane
            float2 xz = p.xz * rotate2D(5.0);
            p.x = xz.x;
            p.z = xz.y;
            
            p.x += 1.0;
            x = (p.x + p.z) / a + t + t;
            w = exp(sin(x) - 2.5) * a;
            o.gb += w / 4e2;
            p.xz -= w * cos(x);
            e -= w;
        }
        
        g += e;
    }
    
    o += min(e * e * 4e6, 1.0 / g) + g * g / 2e2;
    
    return o;
}

// HSV raymarching shader
float4 hsvRaymarch(float2 gl_FragCoord, float2 resolution, float time) {
    float2 r = resolution;
    float2 FC = gl_FragCoord;
    float4 o = float4(0);
    float t = time;
    
    float i = 0.0, g = 0.0, e = 0.0, R = 0.0, S = 0.0;
    
    for(; i < 100.0; i++) {
        S = 1.0;
        float3 p = float3((FC.xy / r - 0.5) * g, g - 0.3) - i / 2e5;
        
        // Rotate YZ plane
        float2 yz = p.yz * rotate2D(0.3);
        p.y = yz.x;
        p.z = yz.y;
        
        R = length(p);
        e = asin(-p.z / R) - 0.1 / R;
        p = float3(log(R) - t, e, atan2(p.x, p.y) * 3.0);
        
        for(S = 1.0; S < 100.0; S += S) {
            e += pow(abs(dot(sin(p.yxz * S), cos(p * S))), 0.2) / S;
        }
        
        g += e * R * 0.1;
        
        // Calculate color contribution
        float maxE = max(e * R * 1e4, 0.7);
        o.rgb += hsv(0.4 - 0.02 / R, maxE, 0.03 / exp(maxE));
    }
    
    return o;
}

// Noise flow shader
float4 noiseFlow(float2 gl_FragCoord, float2 resolution, float time) {
    float2 r = resolution;
    float2 FC = gl_FragCoord;
    float4 o = float4(0);
    float t = time;
    
    float3 d = float3(FC.xy * 2.0 - r, r.x) / r.x;
    float3 p = float3(0);
    
    for(float i = 0.0, s = 0.0; i < 200.0; i++) {
        s = exp(fmod(i, 5.0));
        p += d * (p.y + 0.2 - 0.2 * snoise2D((p.xz * 0.6 + t * 0.2) * s)) / s;
    }
    
    float3 temp = d + 0.03 * (d + 1.0) / length(d.xy - 1.3) - 0.7 / (p.z + 1.0) - min(0.2 + p + p, float3(0)).y;
    o.grb = 0.5 * temp;
    
    return o;
}


// Compute shader that processes current frame with previous frame
kernel void computeMain(texture2d<float, access::write> outTexture [[texture(0)]],
                       texture2d<float, access::read> previousTexture [[texture(1)]],
                       constant Uniforms& uniforms [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    // Get resolution
    float2 resolution = uniforms.resolution;
    
    // Classic mode - pass fragment coordinates and time
    float2 gl_FragCoord = float2(gid);
    // Choose which shader to use
    // float4 color = iterativeTrig(gl_FragCoord, uniforms.time);
    // float4 color = fractalKaleidoscope(gl_FragCoord, uniforms.resolution, uniforms.mouse, uniforms.time);
    // float4 color = turbulentRing(gl_FragCoord, uniforms.resolution, uniforms.time); // BROKEN
    // float4 color = geometricFlow(gl_FragCoord, uniforms.resolution, uniforms.time); // BROKEN
    // float4 color = noiseFlow(gl_FragCoord, uniforms.resolution, uniforms.time);
    // float4 color = hsvRaymarch(gl_FragCoord, uniforms.resolution, uniforms.time);
     float4 color = pulsingHeart(gl_FragCoord, uniforms.resolution, uniforms.time);
    // float4 color = complexTerrain(gl_FragCoord, uniforms.resolution, uniforms.time); // BROKEN
    // float4 color = pulsingHeart(gl_FragCoord, uniforms.resolution, uniforms.time);
    // float4 color = terrainRiver(gl_FragCoord, uniforms.resolution, uniforms.time);
    // float4 color = fractalStructure(gl_FragCoord, uniforms.resolution, uniforms.time); // BROKEN
    // float4 color = terrainRiver(gl_FragCoord, uniforms.resolution, uniforms.time);
    // float4 color = cityscape(gl_FragCoord, uniforms.resolution, uniforms.time); // SEMI-BROKEN
    // float4 color = terrainRiver(gl_FragCoord, uniforms.resolution, uniforms.time);
    // float4 color = fractalPlant(gl_FragCoord, uniforms.resolution, uniforms.time); // SEMI-BROKEN
//    float4 color = terrainRiver(gl_FragCoord, uniforms.resolution, uniforms.time);

    outTexture.write(color, gid);
}
