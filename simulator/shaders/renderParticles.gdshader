shader_type spatial;
render_mode unshaded;

uniform sampler2D vel_texture;
uniform sampler2D pos_texture;
uniform int texture_width;

void vertex() {
    int id = int(VERTEX_ID);

    // Get the texture coordinates for this particle
    int x = id % texture_width;
    int y = id / texture_width;
    vec2 uv = (vec2(float(x), float(y)) + 0.5) / float(texture_width);

    // Set the position accordingly
    vec3 pos = texture(pos_texture, uv).xyz;
    UV = vec2(0.0, texture(vel_texture, uv).y);

    VERTEX = pos;
    POINT_SIZE = 6.0; // Set point size for rendering particles
}

void fragment() {
    ALBEDO = vec3(UV, 0.0); // debug uv mapping
}