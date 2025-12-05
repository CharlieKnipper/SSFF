#[compute]
#version 450

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform image2D pos_texture;
layout(rgba32f, set = 0, binding = 1) uniform image2D vel_texture;
layout(rgba32f, set = 0, binding = 2) uniform image2D param_texture;
layout(rgba32f, set = 0, binding = 3) uniform image2D grid_texture;
layout(rgba32f, set = 0, binding = 5) uniform image2D collider_texture;

layout(set = 0, binding = 4, std430) restrict buffer count_buffer {
    uint counts[];
} count_data;

layout(push_constant, std140) uniform PushConstants {
    vec3 gravity;
    float damping;
    float dt;
    float num_colliders;
    float collider_texture_width;
    float flow_rate;

    vec3 grid_min;
    vec3 grid_max;
    float grid_texture_width;
    float count_buffer_len;
    float texels_per_cell;
    float smoothing_radius;
    float particle_texture_width;

    // word-alignment padding if necessary
    //float _pad0;
} pc;

const int COUNT_PER_TEXEL = 4; // number of particle indices stored per texel

// Kernel constant for poly6 smoothing kernel
// https://www.cs.cornell.edu/courses/cs5643/2015sp/stuff/BridsonFluidsCourseNotes_SPH_pp83-86.pdf
float W_poly6(float r2, float h)
{
    float h2 = h * h;
    if (r2 >= h2) return 0.0; // particles outside the smoothing radius are still ignored

    float d = h2 - r2;
    float c = 315.0 / (64.0 * 3.14159265 * pow(h, 9));
    return c * d*d*d;
}

// For sequential iteration over a texture
ivec2 iterate_uv(ivec2 uv, float tex_width) {
    uv.x += 1;
    if (uv.x >= int(tex_width)) {
        uv.x = 0;
        uv.y += 1;
    }
    return uv;
}

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    int particle_id = coord.y * imageSize(pos_texture).x + coord.x;

    vec4 pos = imageLoad(pos_texture, coord);
    vec4 vel = imageLoad(vel_texture, coord);
    vec4 param = imageLoad(param_texture, coord);
    if (pos.w <= 0.0 || vel.w > 0.0) {
        // Dead particle or not yet alive; skip
        return;
    }

    // Reset the density and pressure accumulators
    param.x = 0.0;
    param.y = 0.0;

    // Loop over the 3x3x3 neighbor cells surrounding this particle's cell
    ivec3 cell = ivec3(floor((pos.xyz - pc.grid_min) / pc.smoothing_radius));
    for (int z = -1; z <= 1; z++)
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        // Get the coordinates of the neighbor cell
        ivec3 neighbor_cell = cell + ivec3(x, y, z);

        // Check bounds
        if (neighbor_cell.x < 0 || neighbor_cell.y < 0 || neighbor_cell.z < 0 ||
            neighbor_cell.x >= int(pc.grid_texture_width) ||
            neighbor_cell.y >= int(pc.grid_texture_width) ||
            neighbor_cell.z >= int(pc.grid_texture_width)) continue;
        
        // Flatten the index
        int neighbor_cell_index =   neighbor_cell.x +
                                    neighbor_cell.y * int(pc.grid_texture_width) +
                                    neighbor_cell.z * int(pc.grid_texture_width) * int(pc.grid_texture_width);

        // Convert to uv
        ivec2 neighbor_uv = ivec2(neighbor_cell_index % int(pc.grid_texture_width),
                                    neighbor_cell_index / int(pc.grid_texture_width));
        
        // Loop over each particle in the neighbor cell
        uint cell_count = count_data.counts[neighbor_cell_index];
        if (cell_count == 0) continue; // we can skip empty cells

        for (int slot = 0; slot < cell_count; slot++) {
            uint texel_offset = slot / COUNT_PER_TEXEL;
            uint channel_offset = slot % COUNT_PER_TEXEL;

            vec4 texel = imageLoad(grid_texture, neighbor_uv);
            int neighbor_id_flat = int(texel[channel_offset]);
            ivec2 neighbor_id = ivec2(neighbor_id_flat % int(pc.particle_texture_width),
                                    neighbor_id_flat / int(pc.particle_texture_width));

            // Get the neighboring cell's position
            vec4 neighbor_pos = imageLoad(pos_texture, neighbor_id);

            vec3 r_ij = pos.xyz - neighbor_pos.xyz;
            float r2 = dot(r_ij, r_ij);

            // Evaluate density contribution
            param.x += param.z * W_poly6(r2, pc.smoothing_radius); // param.x = density; param.z = mass

            neighbor_uv = iterate_uv(neighbor_uv, pc.grid_texture_width);
        }
    }

    // Compute pressure from equation of state
    float stiffness = 200.0;
    float rest_density = 1000.0;
    param.y = stiffness * (param.x - rest_density);

    // write back
    imageStore(param_texture, coord, param);
}