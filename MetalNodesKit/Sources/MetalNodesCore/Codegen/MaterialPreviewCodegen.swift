import Foundation

/// The 3D preview program (spec §23.5): a *generated* vertex stage so a geometry modifier is
/// visible, and a fragment stage that runs the surface statements and shades them with a
/// Cook-Torrance GGX approximation of RealityKit's `.lit` model.
///
/// The approximation is deliberate and documented: the preview shows the material's shape, not
/// RealityKit's exact output. One fixed key light plus a constant hemispheric ambient.
public enum MaterialPreviewCodegen {
    public static let vertexFunctionName = "mn_meshVertex"

    /// Mirrors `MetalNodesRender.MeshVertex` byte for byte: 16 + 16 + 16 + 8 (+8 pad) + 16 = 80,
    /// which is what `MeshBuilderTests` asserts for the Swift side. `float3` costs a full 16 bytes
    /// in MSL exactly as `SIMD3<Float>` does in Swift, so this field order agrees without padding.
    public static let meshVertexStruct = """
    struct MeshVertex {
        float3 position;
        float3 normal;
        float4 tangent;
        float2 uv;
        float4 color;
    };
    """

    /// Mirrors `MetalNodesRender.CameraUniforms`.
    public static let cameraStruct = """
    struct CameraUniforms {
        float4x4 modelToWorld;
        float4x4 worldToView;
        float4x4 viewToProjection;
        float3x3 normalToWorld;
        float3 cameraPosition;
    };
    """

    public static let interpolantsStruct = """
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
    """

    /// GGX distribution, Smith height-correlated visibility, Schlick Fresnel, Lambert diffuse.
    static let shadingHelpers = """
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
    """
}

extension MaterialPreviewCodegen {
    /// The generated vertex stage. It reads `MeshVertex` by `[[vertex_id]]` — no vertex descriptor —
    /// runs the geometry stage's statements, adds the resulting model-space offset, and interpolates
    /// everything the surface stage can read.
    static func vertexFunction(geometry: Emitter.Output, terminal: NodeID,
                               textures: [TextureSlot]) -> [(line: String, owner: NodeID?)] {
        var out: [(String, NodeID?)] = []
        func add(_ l: String, _ o: NodeID? = nil) { out.append((l, o)) }
        add("    MeshVertex vert = verts[vid];")
        add("    float3 offset = float3(0.0);")
        // The statements run against a local `geo` shim whose accessors are the mesh vertex's own
        // fields, so `EmitEnvironment.realityKitGeometry`'s `geo.…()` spellings compile unchanged.
        add("    MNGeometry geo = MNGeometry{ vert, cam, vid };")
        for (i, line) in geometry.bodyLines.enumerated() where geometry.lineOwners[i] != terminal {
            add("    " + line, geometry.lineOwners[i])
        }
        if let e = geometry.inputExpressions[terminal]?["positionOffset"] {
            add("    offset = \(e);", terminal)
        }
        add("    float3 modelPosition = vert.position + offset;")
        add("    float4 world = cam.modelToWorld * float4(modelPosition, 1.0);")
        add("    VertexOut o;")
        add("    o.position = cam.viewToProjection * (cam.worldToView * world);")
        add("    o.worldPosition = world.xyz;")
        add("    o.modelPosition = modelPosition;")
        add("    o.normal = normalize(cam.normalToWorld * vert.normal);")
        add("    o.tangent = normalize(cam.normalToWorld * vert.tangent.xyz);")
        add("    o.bitangent = cross(o.normal, o.tangent) * vert.tangent.w;")
        add("    o.viewDirection = normalize(cam.cameraPosition - world.xyz);")
        add("    o.uv = vert.uv;")
        add("    o.color = vert.color;")
        add("    return o;")
        return out.map { (line: $0.0, owner: $0.1) }
    }

    /// The shim the geometry statements read. Its accessor names match
    /// `EmitEnvironment.materialSys(for: .geometry)` exactly, so one emission serves both the
    /// export (where `geo` is RealityKit's) and the preview (where `geo` is this).
    ///
    /// Holds a reference member (`constant CameraUniforms &cam`), so it is only ever constructed
    /// with the brace initializer above, never default-constructed. If the Metal compiler rejects
    /// a reference member here (untested in this task — there is no GPU compile until Task 12),
    /// the fallback is `constant CameraUniforms *cam;` with call sites dereferencing it.
    static let geometryShim = """
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
    """
}

extension MaterialPreviewCodegen {
    /// The whole preview program.
    static func program(surface: Emitter.Output, geometry: Emitter.Output,
                        groupFunctions: [GroupFunction], terminal: NodeID,
                        layout: UniformLayout, lighting: MaterialLightingModel,
                        textures: [TextureSlot], viewerExpression: String? = nil) -> SourceBuilder {
        var b = SourceBuilder()
        b.add("#include <metal_stdlib>\nusing namespace metal;\n")
        b.add(layout.mslStruct + "\n")
        b.add(meshVertexStruct + "\n")
        b.add(cameraStruct + "\n")
        b.add(geometryShim + "\n")
        b.add(interpolantsStruct + "\n")
        b.add(surfaceShim + "\n")
        for f in MSLStdlib.resolve(surface.requiredStdlib + geometry.requiredStdlib
                                    + groupFunctions.flatMap(\.requiredStdlib)) {
            b.add(f.source + "\n")
        }
        if lighting == .lit { b.add(shadingHelpers + "\n") }
        for f in groupFunctions { b.add(f.source, map: f.lineMap) }

        // Vertex stage.
        var vertexParams = ["uint vid [[vertex_id]]",
                            "device const MeshVertex *verts [[buffer(0)]]",
                            "constant CameraUniforms &cam [[buffer(1)]]",
                            "constant Uniforms &u [[buffer(2)]]"]
        vertexParams += textures.map { "texture2d<float> \($0.fragmentName) [[texture(\($0.index))]]" }
        b.add("vertex VertexOut \(vertexFunctionName)(" + vertexParams.joined(separator: ",\n" + String(repeating: " ", count: 24)) + ") {")
        for s in vertexFunction(geometry: geometry, terminal: terminal, textures: textures) {
            b.add(s.line, owner: s.owner)
        }
        b.add("}\n")

        // Fragment stage.
        var fragmentParams = ["VertexOut in [[stage_in]]",
                              "constant Uniforms &u [[buffer(0)]]",
                              "constant CameraUniforms &cam [[buffer(1)]]"]
        fragmentParams += textures.map { "texture2d<float> \($0.fragmentName) [[texture(\($0.index))]]" }
        b.add("fragment float4 \(ShaderGenerator.fragmentFunctionName)(" + fragmentParams.joined(separator: ",\n" + String(repeating: " ", count: 25)) + ") {")
        for line in fragmentBody(surface: surface, terminal: terminal, lighting: lighting,
                                 viewerExpression: viewerExpression) {
            b.add(line.line, owner: line.owner)
        }
        b.add("}")
        return b
    }

    /// The surface statements, the eight material values, then the shading.
    ///
    /// `viewerExpression` is the widened viewed value (spec §19.3). It replaces the emissive term
    /// and arrives with `lighting` forced to `.unlit`, so the fragment stage returns the viewed
    /// value flat on the mesh (spec §23.5).
    static func fragmentBody(surface: Emitter.Output, terminal: NodeID,
                             lighting: MaterialLightingModel,
                             viewerExpression: String? = nil) -> [(line: String, owner: NodeID?)] {
        var out: [(String, NodeID?)] = []
        func add(_ l: String, _ o: NodeID? = nil) { out.append((l, o)) }
        // `params` in the surface environment is RealityKit's; here the same accessor names are
        // served by a shim built from the interpolants.
        add("    MNSurface params = MNSurface{ in, cam, u };")
        for (i, line) in surface.bodyLines.enumerated() where surface.lineOwners[i] != terminal {
            add("    " + line, surface.lineOwners[i])
        }
        let e = surface.inputExpressions[terminal] ?? [:]
        func value(_ socket: String, _ fallback: String) -> String { e[socket] ?? fallback }
        add("    float4 baseColor = \(value("baseColor", "float4(0.8, 0.8, 0.8, 1.0)"));", terminal)
        add("    float4 emissive = \(viewerExpression ?? value("emissive", "float4(0.0, 0.0, 0.0, 1.0)"));", terminal)
        add("    float opacity = \(value("opacity", "1.0"));", terminal)
        guard lighting == .lit else {
            add("    return float4(emissive.rgb, opacity);", terminal)
            return out.map { (line: $0.0, owner: $0.1) }
        }
        add("    float3 tangentNormal = \(value("normal", "float3(0.0, 0.0, 1.0)"));", terminal)
        add("    float roughness = clamp(\(value("roughness", "0.5")), 0.03, 1.0);", terminal)
        add("    float metallic = saturate(\(value("metallic", "0.0")));", terminal)
        add("    float occlusion = saturate(\(value("occlusion", "1.0")));", terminal)
        add("    float specular = saturate(\(value("specular", "0.5")));", terminal)
        add("    float3x3 basis = float3x3(normalize(in.tangent), normalize(in.bitangent), normalize(in.normal));")
        add("    float3 n = normalize(basis * normalize(tangentNormal));")
        add("    float3 v = normalize(cam.cameraPosition - in.worldPosition);")
        add("    float3 l = normalize(float3(0.5, 0.8, 0.6));")
        add("    float3 h = normalize(v + l);")
        add("    float ndotl = saturate(dot(n, l));")
        add("    float ndotv = saturate(dot(n, v)) + 1e-5;")
        add("    float a = roughness * roughness;")
        add("    float3 f0 = mix(float3(0.08 * specular), baseColor.rgb, metallic);")
        add("    float3 spec = mn_schlick_fresnel(f0, saturate(dot(v, h)))")
        add("                * mn_ggx_distribution(saturate(dot(n, h)), a)")
        add("                * mn_smith_visibility(ndotv, ndotl, a);")
        add("    float3 diffuse = baseColor.rgb * (1.0 - metallic) / 3.14159265;")
        add("    float3 direct = (diffuse + spec) * ndotl * 3.0;")
        add("    float3 ambient = baseColor.rgb * (1.0 - metallic) * 0.12 * occlusion;")
        add("    return float4(direct + ambient + emissive.rgb, opacity);", terminal)
        return out.map { (line: $0.0, owner: $0.1) }
    }

    /// The surface shim: RealityKit's `params.geometry().x()` accessors served from interpolants.
    static let surfaceShim = """
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
    """
}
