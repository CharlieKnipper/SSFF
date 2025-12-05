#[compute]
#version 450

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

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

    // word-alignment padding if necessary
    //float _pad0;
} pc;

void main() {
    // Reset all counts to zero
    uint id = gl_GlobalInvocationID.x;
    if (id < pc.count_buffer_len) {
        count_data.counts[id] = 0;
    }
}