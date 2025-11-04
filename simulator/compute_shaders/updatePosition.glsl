#[compute]
#version 450

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform image2D pos_texture;
layout(rgba32f, set = 0, binding = 1) uniform image2D vel_texture;
layout(rgba32f, set = 0, binding = 2) uniform image2D collider_texture;

layout(push_constant, std140) uniform PushConstants {
    vec3 gravity;
    float damping;
    float dt;
    float num_colliders;
    float collider_texture_width;
    float flow_rate;

    // word-alignment padding
    //float _pad0;
} pc;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    vec4 pos = imageLoad(pos_texture, coord); // pos x, y, z + lifetime
    vec4 vel = imageLoad(vel_texture, coord); // vel x, y, z + frame delay
    
    int particle_id = coord.y * imageSize(pos_texture).x + coord.x;
    // If the particle is yet to be alive, decrement its frame delay and skip update
    if (vel.w > 0.0) {
        vel.w -= pc.flow_rate;
        imageStore(vel_texture, coord, vel);
        return;
    }

    // If the particle is dead, skip update
    if (pos.w <= 0.0) {
        return;
    }

    // Euler integration for gravity
    vel.y += pc.gravity.y * pc.dt;
    pos += vel * pc.dt;

    // Detect bounding box collisions
    for (int i = 0; i < int(pc.num_colliders); i++) {
        int i_min = i * 2;
        int i_max = i * 2 + 1;
        ivec2 min_uv = ivec2(i_min % int(pc.collider_texture_width), i_min / int(pc.collider_texture_width));
        ivec2 max_uv = ivec2(i_max % int(pc.collider_texture_width), i_max / int(pc.collider_texture_width));
        vec3 min_box = imageLoad(collider_texture, min_uv).xyz;
        vec3 max_box = imageLoad(collider_texture, max_uv).xyz;

        if (pos.x >= min_box.x && pos.x <= max_box.x &&
            pos.y >= min_box.y && pos.y <= max_box.y &&
            pos.z >= min_box.z && pos.z <= max_box.z)
        {
            // Collision detected
            vec3 pen_min = pos.xyz - min_box;
            vec3 pen_max = max_box - pos.xyz;

            // Find the axis of minimum penetration
            vec3 pen = min(pen_min, pen_max);
            float min_pen = min(pen.x, min(pen.y, pen.z));

            // Push particle out along the min penetration axis
            if (min_pen == pen.x) {
                pos.x += (pos.x < (min_box.x + max_box.x)/2.0) ? -pen_min.x : pen_max.x;
                vel.x *= pc.damping;
            } else if (min_pen == pen.y) {
                pos.y += (pos.y < (min_box.y + max_box.y)/2.0) ? -pen_min.y : pen_max.y;
                vel.y *= pc.damping;
            } else {
                pos.z += (pos.z < (min_box.z + max_box.z)/2.0) ? -pen_min.z : pen_max.z;
                vel.z *= pc.damping;
            }
        }
    }

    // Decrement particle lifetime
    pos.w -= pc.dt;

    // write back
    imageStore(pos_texture, coord, pos);
    imageStore(vel_texture, coord, vel);
}
