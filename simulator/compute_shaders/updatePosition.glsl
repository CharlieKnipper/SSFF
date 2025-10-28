#[compute]
#version 450

layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;

// Must match the set/binding passed from GDScript:
layout(set = 0, binding = 0, std430) restrict buffer ParticleBuffer {
    vec4 particles[]; // x,y,z,w
} particles_buf;

layout(push_constant) uniform PushConstants {
    vec3 gravity;
    vec3 box_min;
    vec3 box_max;
    float damping;
    float dt;
} pc;

void main() {
    uint idx = gl_GlobalInvocationID.x;
    // bounds-check: don't access beyond array (dispatcher should be sized to cover it, but safe-guard)
    if (idx >= particles_buf.particles.length()) {
        return;
    }

    vec4 p = particles_buf.particles[idx];
    vec3 pos = p.xyz;

    // Here we treat particles_buf.particles[idx].w as a trailing velocity.y or similar only for demo:
    pos += pc.gravity * pc.dt;

    // keep inside box
    if (pos.x < pc.box_min.x) pos.x = pc.box_min.x;
    if (pos.y < pc.box_min.y) pos.y = pc.box_min.y;
    if (pos.z < pc.box_min.z) pos.z = pc.box_min.z;
    if (pos.x > pc.box_max.x) pos.x = pc.box_max.x;
    if (pos.y > pc.box_max.y) pos.y = pc.box_max.y;
    if (pos.z > pc.box_max.z) pos.z = pc.box_max.z;

    // write back
    particles_buf.particles[idx].xyz = pos;
}
