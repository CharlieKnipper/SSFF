shader_type spatial;
render_mode unshaded, depth_draw_never;

uniform sampler2D vel_texture;
uniform sampler2D pos_texture;
uniform int texture_width;

const float VELOCITY_THRESHOLD = 20.0; // m/s
vec3 velocity_to_color(vec4 v) {
    return vec3(v.x*v.x, v.y*v.y, v.z*v.z) / VELOCITY_THRESHOLD;
}

vec2 get_uv_from_id(int id) {
    int x = id % texture_width;
    int y = id / texture_width;
    return (vec2(float(x), float(y)) + 0.5) / float(texture_width);
}

void vertex() {
    int id = int(VERTEX_ID);
    UV.x = float(id);

    // Get the texture coordinates for this particle
    int x = id % texture_width;
    int y = id / texture_width;
    vec2 uv = get_uv_from_id(id);

    // Set the position accordingly
    vec4 pos = texture(pos_texture, uv); // pos.w = lifetime
    vec4 vel = texture(vel_texture, uv); // vel.w = frame delay
    
    if (vel.w > 0.0) {
        // Particle not yet alive
    } else if (pos.w <= 0.0) {
        // Dead particle
        VERTEX = vec3(0.0, -9999.0, 0.0); // Move dead particles out of view
    } else {
        // Alive particle
        VERTEX = pos.xyz;
    }

    POINT_SIZE = 16.0; // Set point size for rendering particles
}

void fragment() {
    // Sample particle data
    vec2 uv = get_uv_from_id(int(UV.x));
    vec4 p = texture(pos_texture, uv);
    if (p.w <= 0.0) {
        discard;
    }
    vec4 v = texture(vel_texture, uv);

    // POINT_COORD ranges 0..1 over the point sprite — make a circular mask
    vec2 pc = POINT_COORD - vec2(0.5);
    float dist = length(pc);

    // Soft circular shape: fully opaque near center, smooth falloff to edge
    const float INNER_RADIUS = 0.25;
    const float OUTER_RADIUS = 0.5;
    float mask = 1.0 - smoothstep(INNER_RADIUS, OUTER_RADIUS, dist);
    if (mask <= 0.01) {
        discard; // fully transparent at far edge
    }

    // Realistic water base color (slightly blue, mostly transparent)
    vec3 base_water = vec3(0.04, 0.18, 0.28);

    // Brightness modulated by particle speed for subtle variation
    float speed = length(v.xyz);
    float speed_norm = clamp(speed / VELOCITY_THRESHOLD, 0.0, 1.0);
        float brightness = mix(0.85, 1.05, speed_norm);

    // Slightly brighter, more desaturated center to simulate refraction
        float center_falloff = pow(mask, 1.6);
    vec3 center_tint = mix(base_water * 1.05, vec3(0.7, 0.82, 0.95), 0.12);
    vec3 color = mix(base_water * brightness, center_tint * brightness, center_falloff);

    // Small specular highlight (bright white-ish) near center for wet look
        float spec = pow(clamp(1.0 - dist / OUTER_RADIUS, 0.0, 1.0), 28.0);
        vec3 spec_tone = vec3(0.9, 0.95, 1.0);
        vec3 spec_color = spec_tone * (0.3 + 0.4 * speed_norm) * spec;

    // Top-lit sheen: particles catch light from above — stronger near top of the sprite
    float top_light = smoothstep(-0.5, -0.05, pc.y); // pc.y is negative at top
        vec3 top_tint = vec3(0.75, 0.9, 1.0) * 0.12 * top_light;

    // Compose final color with specular and top tint
    vec3 final_color = color + spec_color + top_tint;

        // Alpha: denser in the center, softer at edges; reduce overall alpha so droplets are more transparent
        ALBEDO = final_color;
        ALPHA = clamp(mask * 0.40 + spec * 0.20, 0.0, 1.0);

    // Slight emission to make droplets pop in an unshaded material
        // Reduced emission to avoid overly white/glowing droplets
        EMISSION = final_color * (mask * 0.20 + spec * 0.10);
}