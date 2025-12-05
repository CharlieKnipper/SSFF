shader_type spatial;
render_mode unshaded, depth_draw_opaque, blend_mix;

uniform sampler2D vel_texture;
uniform sampler2D pos_texture;
uniform int texture_width;

uniform vec4 color : source_color = vec4(0.2, 0.4, 1.0, 1.0);

// const float VELOCITY_THRESHOLD = 20.0; // m/s
// vec3 velocity_to_color(vec4 v) {
//     return vec3(v.x*v.x, v.y*v.y, v.z*v.z) / VELOCITY_THRESHOLD;
// }

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

    POINT_SIZE = 4.0; // Set point size for rendering particles
}

void fragment() {
    if (texture(pos_texture, get_uv_from_id(int(UV.x))).w <= 0.0) {
        discard; // Do not render dead particles
    }
    
    ALBEDO = color.rgb;
    ALPHA = color.a;
}