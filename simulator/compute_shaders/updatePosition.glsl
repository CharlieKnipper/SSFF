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

    float gas_constant;
    float rest_density;

    // word-alignment padding if necessary
    //float _pad0;
} pc;

const int COUNT_PER_TEXEL = 4; // number of particle indices stored per texel

// Spiky gradient constant = -45 / (pi * h^6)
float spiky_const(float h) {
    return -45.0 / (3.14159265 * pow(h, 6.0));
}

// Viscosity Laplacian constant = 45 / (pi * h^6)
float visc_laplacian_const(float h) {
    return 45.0 / (3.14159265 * pow(h, 6.0));
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
    vec4 pos = imageLoad(pos_texture, coord); // pos x, y, z + lifetime
    vec4 vel = imageLoad(vel_texture, coord); // vel x, y, z + frame delay
    vec4 param = imageLoad(param_texture, coord); // density, pressure, mass, viscosity
    
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

    // For more readable forces later
    float density_i = param.x;
    float pressure_i = param.y;
    float mass_i = param.z;
    float viscosity = param.w;
    float h = pc.smoothing_radius;
    float h2 = h * h;
    vec3 force = vec3(0.0); // total accumulated SPH forces
    
    // We iterate over the 3x3x3 grid of cells surrounding this particle's cell
    //  this lets us find all particles within the smoothing radius without iterating over every cell
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
            
            // We don't consider the effects from this particle on itself
            if (neighbor_id == coord) {
                neighbor_uv = iterate_uv(neighbor_uv, pc.grid_texture_width);
                continue;
            }

            // Get the neighboring cell's conditions
            vec4 neighbor_pos = imageLoad(pos_texture, neighbor_id);
            vec4 neighbor_vel = imageLoad(vel_texture, neighbor_id);
            vec4 neighbor_param = imageLoad(param_texture, neighbor_id);

            // For more readable forces
            float density_j = neighbor_param.x;
            float pressure_j = neighbor_param.y;
            float mass_j = neighbor_param.z;

            vec3 r_ij = pos.xyz - neighbor_pos.xyz;
            float r2 = dot(r_ij, r_ij);

            /*-------------------------------------------------------*/
            /*                   Temp Force Debugging                */
            density_i = clamp(density_i, 0.1, 2000.0);
            density_j = clamp(density_j, 0.1, 2000.0);
            /*-------------------------------------------------------*/

            // If this particle is within smoothing kernel range (and not itself), apply forces
            if (r2 < h2 && r2 > 0.0) {
                float r = sqrt(r2);
                r = max(r, 0.001); // clamp r to > 0 to avoid NaN values

                // Pressure force
                float spiky = spiky_const(h) * pow(h - r, 2.0);
                vec3 gradW = spiky * (r_ij / r);

                force += -1.0 * mass_j * (pressure_i + pressure_j) / (2.0 * density_j) * gradW;

                // Viscosity force
                float lapW = visc_laplacian_const(h) * (h - r);

                force += viscosity * mass_j * (neighbor_vel.xyz - vel.xyz) / density_j * lapW;
            }

            neighbor_uv = iterate_uv(neighbor_uv, pc.grid_texture_width);
        }
    }

    // Add gravity
    force += pc.gravity;

    // Acceleration
    vec3 accel = force / density_i;
    accel = clamp(accel, -50.0, 50.0);

    // Integrate forces
    vel.xyz += accel * pc.dt;
    pos.xyz += vel.xyz * pc.dt;

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
    //pos.w -= pc.dt;

    // write back
    imageStore(pos_texture, coord, pos);
    imageStore(vel_texture, coord, vel);
}
