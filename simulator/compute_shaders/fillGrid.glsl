#[compute]
#version 450

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform image2D pos_texture;
layout(rgba32f, set = 0, binding = 1) uniform image2D vel_texture;
layout(rgba32f, set = 0, binding = 3) uniform image2D grid_texture;

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

    float gas_constant;
    float rest_density;
    float particle_distance;
    float separation_strength;
    float separation_iters;

    // word-alignment padding if necessary
    //float _pad0;
} pc;

// For iterating over each texel of a given cell
ivec2 add_contiguous_uv(ivec2 uv, int offset, float width) {
    uv.x += offset;
    if (uv.x >= width) {
        uv.x = uv.x - int(width);
        uv.y += 1;
    }
    return uv;
}

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    int particle_id = coord.y * imageSize(pos_texture).x + coord.x;

    vec4 pos = imageLoad(pos_texture, coord);
    vec4 vel = imageLoad(vel_texture, coord);
    if (pos.w <= 0.0 || vel.w > 0.0) {
        // Dead particle or not yet alive; skip
        return;
    }

    // Get the particle's hashed cell index
    ivec3 cell = ivec3(floor((pos.xyz - pc.grid_min) / pc.smoothing_radius));

    // Compute the 1D index from 3D cell coordinates
    int cell_index = cell.x +
                     cell.y * int(pc.grid_texture_width) +
                     cell.z * int(pc.grid_texture_width) * int(pc.grid_texture_width);
    
    // Compute the 2D texture coordinates for the grid texture
    ivec2 grid_uv = ivec2(cell_index % int(pc.grid_texture_width),
                          cell_index / int(pc.grid_texture_width));
    
    // Atomically get the next open slot in this cell
    uint cell_slot = atomicAdd(count_data.counts[cell_index], 1);

    uint texel_offset = cell_slot / 4; // 4 particles per texel (rgba)
    uint channel_offset = cell_slot % 4; // which channel in the texel
    ivec2 target_uv = add_contiguous_uv(grid_uv, int(texel_offset), pc.grid_texture_width);

    // Store the particle ID in the appropriate channel
    vec4 grid_data = imageLoad(grid_texture, target_uv);
    grid_data[channel_offset] = float(particle_id);
    imageStore(grid_texture, target_uv, grid_data);
}