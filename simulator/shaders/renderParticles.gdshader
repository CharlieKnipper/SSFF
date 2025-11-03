shader_type spatial;
render_mode unshaded;

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
    vec4 pos = texture(pos_texture, uv);
    
    if (pos.w > 0.0) {
        // Alive particle
        VERTEX = pos.xyz;
    } else {
        // Dead particle
        VERTEX = vec3(0.0, -9999.0, 0.0); // Move dead particles out of view
    }

    POINT_SIZE = 4.0; // Set point size for rendering particles
}

void fragment() {
    if (texture(pos_texture, get_uv_from_id(int(UV.x))).w <= 0.0) {
        discard; // Do not render dead particles
    }

    vec3 v = velocity_to_color(texture(vel_texture, get_uv_from_id(int(UV.x))));
    ALBEDO = v; // debug particle velocity
}