#[compute]
#version 450

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 4, std430) restrict buffer count_buffer {
    uint counts[];
} count_data;

layout(push_constant, std140) uniform PushConstants {
    // word 0
    vec4 gravity;

    // word 1
    float dt;
    float num_colliders;
    float collider_texture_width;
    float flow_rate;

    // word 2
    vec4 grid_min;

    // word 3
    vec4 grid_max;

    // word 4
    float grid_texture_width;
    float count_buffer_len;
    float texels_per_cell;
    float smoothing_radius;

    // word 5
    float particle_texture_width;
    float gas_constant;
    float rest_density;
    float max_accel;

    // word 6
    float max_density;
    float lifetime_multiplier;
    float damping;
    float _pad0;
} pc;

void main() {
    // Reset all counts to zero
    uint id = gl_GlobalInvocationID.x;
    if (id < pc.count_buffer_len) {
        count_data.counts[id] = 0;
    }
}