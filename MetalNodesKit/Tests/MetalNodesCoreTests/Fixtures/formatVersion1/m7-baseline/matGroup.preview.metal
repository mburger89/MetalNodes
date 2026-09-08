#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 p0;
    float3 p1;
    float4 p2;
    float3 p3;
    float2 resolution;
    float2 mouse;
    float time;
    float p4;
    float p5;
    float p6;
    float p7;
};

struct MeshVertex {
    float3 position;
    float3 normal;
    float4 tangent;
    float2 uv;
    float4 color;
};

struct CameraUniforms {
    float4x4 modelToWorld;
    float4x4 worldToView;
    float4x4 viewToProjection;
    float3x3 normalToWorld;
    float3 cameraPosition;
};

struct MNGeometry {
    MeshVertex v;
    constant CameraUniforms &cam;
    uint vid;
    float3 model_position() const { return v.position; }
    float3 world_position() const { return (cam.modelToWorld * float4(v.position, 1.0)).xyz; }
    float3 normal() const { return v.normal; }
    float3 bitangent() const { return cross(v.normal, v.tangent.xyz) * v.tangent.w; }
    float2 uv0() const { return v.uv; }
    float2 uv1() const { return v.uv; }
    float4 color() const { return v.color; }
    uint vertex_id() const { return vid; }
};

struct VertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 modelPosition;
    float3 normal;
    float3 tangent;
    float3 bitangent;
    float3 viewDirection;
    float2 uv;
    float4 color;
};

struct MNSurfaceGeometry {
    VertexOut in;
    float3 world_position() const { return in.worldPosition; }
    float3 model_position() const { return in.modelPosition; }
    float3 normal() const { return in.normal; }
    float3 tangent() const { return in.tangent; }
    float3 bitangent() const { return in.bitangent; }
    float2 uv0() const { return in.uv; }
    float2 uv1() const { return in.uv; }
    float4 color() const { return in.color; }
    float4 screen_position() const { return in.position; }
    float3 view_direction() const { return in.viewDirection; }
};
struct MNSurfaceUniforms {
    constant Uniforms &u;
    float time() const { return u.time; }
};
struct MNSurface {
    VertexOut in;
    constant CameraUniforms &cam;
    constant Uniforms &u;
    MNSurfaceGeometry geometry() const { return MNSurfaceGeometry{ in }; }
    MNSurfaceUniforms uniforms() const { return MNSurfaceUniforms{ u }; }
};
struct MNGeometryParams {
    constant Uniforms &u;
    MNSurfaceUniforms uniforms() const { return MNSurfaceUniforms{ u }; }
};

static inline float mn_ggx_distribution(float ndoth, float a) {
    float a2 = a * a;
    float d = ndoth * ndoth * (a2 - 1.0) + 1.0;
    return a2 / max(3.14159265 * d * d, 1e-6);
}

static inline float mn_smith_visibility(float ndotv, float ndotl, float a) {
    float a2 = a * a;
    float v = ndotl * sqrt(ndotv * ndotv * (1.0 - a2) + a2);
    float l = ndotv * sqrt(ndotl * ndotl * (1.0 - a2) + a2);
    return 0.5 / max(v + l, 1e-6);
}

static inline float3 mn_schlick_fresnel(float3 f0, float vdoth) {
    return f0 + (1.0 - f0) * pow(saturate(1.0 - vdoth), 5.0);
}

struct G_f367bf8a_Out {
    float out;
};

G_f367bf8a_Out mn_g_Pulse_f367bf8a(float2 uv, float time, float2 size, float2 mouse) {
    float v0;
    v0 = time;
    float v1;
    v1 = sin(v0);
    G_f367bf8a_Out out;
    out.out = v1;
    return out;
}

vertex VertexOut mn_meshVertex(uint vid [[vertex_id]],
                        device const MeshVertex *verts [[buffer(0)]],
                        constant CameraUniforms &cam [[buffer(1)]],
                        constant Uniforms &u [[buffer(2)]]) {
    MeshVertex vert = verts[vid];
    float3 offset = float3(0.0);
    offset = u.p3;
    float3 modelPosition = vert.position + offset;
    float4 world = cam.modelToWorld * float4(modelPosition, 1.0);
    VertexOut o;
    o.position = cam.viewToProjection * (cam.worldToView * world);
    o.worldPosition = world.xyz;
    o.modelPosition = modelPosition;
    float3x3 modelRotation = float3x3(cam.modelToWorld[0].xyz, cam.modelToWorld[1].xyz, cam.modelToWorld[2].xyz);
    o.normal = normalize(cam.normalToWorld * vert.normal);
    o.tangent = normalize(modelRotation * vert.tangent.xyz);
    o.bitangent = cross(o.normal, o.tangent) * vert.tangent.w;
    o.viewDirection = normalize(cam.cameraPosition - world.xyz);
    o.uv = vert.uv;
    o.color = vert.color;
    return o;
}

fragment float4 shaderMain(VertexOut in [[stage_in]],
                         constant Uniforms &u [[buffer(0)]],
                         constant CameraUniforms &cam [[buffer(1)]]) {
    MNSurface params = MNSurface{ in, cam, u };
    float4 v0;
    v0 = u.p0;
    G_f367bf8a_Out r1 = mn_g_Pulse_f367bf8a(params.geometry().uv0(), params.uniforms().time(), float2(1.0, 1.0), float2(0.0, 0.0));
    float v2;
    v2 = r1.out;
    float4 baseColor = v0;
    float4 emissive = u.p2;
    float opacity = u.p5;
    float3 tangentNormal = u.p1;
    float roughness = clamp(v2, 0.03, 1.0);
    float metallic = saturate(u.p4);
    float occlusion = saturate(u.p6);
    float specular = saturate(u.p7);
    float3x3 basis = float3x3(normalize(in.tangent), normalize(in.bitangent), normalize(in.normal));
    float3 n = normalize(basis * normalize(tangentNormal));
    float3 v = normalize(cam.cameraPosition - in.worldPosition);
    float3 l = normalize(float3(0.5, 0.8, 0.6));
    float3 h = normalize(v + l);
    float ndotl = saturate(dot(n, l));
    float ndotv = saturate(dot(n, v)) + 1e-5;
    float a = roughness * roughness;
    float3 f0 = mix(float3(0.08 * specular), baseColor.rgb, metallic);
    float3 spec = mn_schlick_fresnel(f0, saturate(dot(v, h)))
                * mn_ggx_distribution(saturate(dot(n, h)), a)
                * mn_smith_visibility(ndotv, ndotl, a);
    float3 diffuse = baseColor.rgb * (1.0 - metallic) / 3.14159265;
    float3 direct = (diffuse + spec) * ndotl * 3.0;
    float3 ambient = baseColor.rgb * (1.0 - metallic) * 0.12 * occlusion;
    return float4(direct + ambient + emissive.rgb, opacity);
}
