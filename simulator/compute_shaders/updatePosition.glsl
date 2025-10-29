#[compute]
#version 450

layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;

// Must match the set/binding passed from GDScript:
layout(set = 0, binding = 0, std430) restrict buffer ParticleBuffer {
    vec4 particles[]; // x,y,z,w
} particles_buf;

layout(push_constant, std430) uniform PushConstants {
    vec3 gravity; float _pad0;
    vec3 box_min; float _pad1;
    vec3 box_max; float _pad2;
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
    float vy = p.w;

    // Euler integration for gravity with damping (w is used for velocity, but this will be changed later)
    vy += pc.gravity.y * pc.dt;
    pos.y += vy * pc.dt;

    // Detect bounding box collision
    if (pos.y < pc.box_min.y) {
        pos.y = pc.box_min.y;
        vy *= pc.damping;
    }

    // write back
    particles_buf.particles[idx] = vec4(pos, vy);
}
