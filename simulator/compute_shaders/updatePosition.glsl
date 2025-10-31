#[compute]
#version 450

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform image2D pos_tex;
layout(rgba32f, set = 0, binding = 1) uniform image2D vel_tex;

layout(push_constant, std140) uniform PushConstants {
    vec3 gravity; float _pad0;
    vec3 box_min; float _pad1;
    vec3 box_max; float _pad2;
    float damping;
    float dt;
} pc;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    vec4 pos = imageLoad(pos_tex, coord);
    vec4 vel = imageLoad(vel_tex, coord);

    // Euler integration for gravity with damping
    vel.y += pc.gravity.y * pc.dt;
    pos.y += vel.y * pc.dt;

    // Detect bounding box collision
    if (pos.y < pc.box_min.y) {
        pos.y = pc.box_min.y;
        vel.y *= pc.damping;
    }

    // write back
    imageStore(pos_tex, coord, pos);
    imageStore(vel_tex, coord, vel);
}
