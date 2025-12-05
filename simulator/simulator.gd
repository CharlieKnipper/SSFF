extends Node3D

# Particle parameters
@export var num_particles := 5000
@export var gravity := Vector3(0, -9.81, 0)
@export var damping := -0.7
@export var flow_rate := 100
@export var lifetime := 10.0
@export var mass := 1.0
@export var viscosity := 0.1
@export var gas_constant := 200.0
@export var rest_density := 1000.0
# SPH parameters
@export var smoothing_radius := 0.5
@export var texels_per_cell := 9 # optimally, this should be a perfect square
@export var SPH_grid_min := Vector3(-25, -25, -25)
@export var SPH_grid_max := Vector3(25, 25, 25)

# Sim parameters
@export var initial_velocity := Vector3(0.0, 0.0, 1.0)
@export var max_colliders := 50
@export var reload_controller : Button

## Demo variables
var particles_spawned := 0
@onready var particle_label = get_node("/root/Main/UI/NumParticles")

## Where the particles are emitting from
var emission_point : Vector3

## Everything defining the compute shader pipelines
var rd : RenderingDevice

var reset_shader : RID
var fill_shader : RID
var solve_shader : RID
var update_shader : RID

var reset_uniform : RID
var fill_uniform : RID
var solve_uniform : RID
var update_uniform : RID

var reset_pipeline : RID
var fill_pipeline : RID
var solve_pipeline : RID
var update_pipeline : RID

## Everything defining the vertex shader pipeline
var vert_shader : Shader
var particle_mat : ShaderMaterial

## Everything we want sent to the gpu:
var particle_texture_width : int
var particle_texture_format : RDTextureFormat

var grid_texture_width : int
var grid_texture_format : RDTextureFormat

# This needs to be a buffer to support integers to support atomic ops
var count_buffer_len : int
var count_buffer : RID

var collider_texture_width : int
var collider_texture_format : RDTextureFormat
var num_colliders : int

# The position of each particle (1 texel = 1 particle)
# r = pos.x
# g = pos.y
# b = pos.z
# a = lifetime
var pos_texture_rid : RID
var pos_texture : Texture2DRD

# The velocity of each particle (1 texel = 1 particle)
# r = vel.x
# g = vel.y
# b = vel.z
# a = frame delay
var vel_texture_rid : RID
var vel_texture : Texture2DRD

# The parameters of each particle (1 texel = 1 particle)
# r = density
# g = pressure
# b = mass
var param_texture_rid : RID
var param_texture : Texture2DRD

# The neighbor search textures
# The set of cells comprising the acceleration grid (texels_per_cell texel = 1 cell)
# r = particle uid 1
# g = particle uid 2
# b = particle uid 3
# a = particle uid 4
# ...
var grid_texture_rid : RID
var grid_texture : Texture2DRD
# The number of particles filled in each cell (1 texel = 1 cell)
# r = current cell count
var count_texture_rid : RID
var count_texture : Texture2DRD

# The axis aligned bounding boxes for all collidable objects (2 texels = 1 box)
# r1 = min.x	r2 = max.x
# g1 = min.y	g2 = max.y
# b1 = min.z	b2 = max.z
var collider_texture_rid : RID
var collider_texture : Texture2DRD

func _ready():
	## -------------------- Initial Setup --------------------
	# Initialize rendering device
	rd = RenderingServer.get_rendering_device()
	
	# Get the world coordinate emitter position vector
	emission_point = self.global_position
	
	# Clean RID objects that need to be freed manually on node removal
	connect("tree_exited", _clean_shader)
	
	## -------------------- Texture Setup --------------------
	## Particle textures setup
	# Define the empty texture format
	particle_texture_width = ceil(sqrt(num_particles)) # we define the textures to be a square that has a number of texels >= to num_particles
	
	particle_texture_format = RDTextureFormat.new()
	particle_texture_format.width = particle_texture_width
	particle_texture_format.height = particle_texture_width
	particle_texture_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	particle_texture_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | # for compute shader writes
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | # for vertex shader reads
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT # for CPU initialization
	)

	# Initialize each texture
	var pos_data := PackedFloat32Array()
	pos_data.resize(particle_texture_width * particle_texture_width * 4) # 4 floats per texel (rgba)
	var vel_data := PackedFloat32Array()
	vel_data.resize(particle_texture_width * particle_texture_width * 4)
	var param_data := PackedFloat32Array()
	param_data.resize(particle_texture_width * particle_texture_width * 4)
	
	for i in range(num_particles):
		# Initial Position:
		pos_data[i * 4 + 0] = emission_point.x # x
		pos_data[i * 4 + 1] = emission_point.y # y
		pos_data[i * 4 + 2] = emission_point.z # z
		pos_data[i * 4 + 3] = lifetime # lifetime
		
		# Initial Velocity:
		vel_data[i * 4 + 0] = initial_velocity.x + randf() # x
		vel_data[i * 4 + 1] = initial_velocity.y + randf() # y
		vel_data[i * 4 + 2] = initial_velocity.z + randf() # z
		vel_data[i * 4 + 3] = i # frame delay
		
		# Other parameters
		param_data[i * 4 + 0] = 0 # initial density
		param_data[i * 4 + 1] = 0 # initial pressure
		param_data[i * 4 + 2] = mass # particle mass
		param_data[i * 4 + 3] = viscosity # viscosity
	
	pos_texture_rid = rd.texture_create(particle_texture_format, RDTextureView.new(), [pos_data.to_byte_array()])
	pos_texture = Texture2DRD.new()
	pos_texture.texture_rd_rid = pos_texture_rid

	vel_texture_rid = rd.texture_create(particle_texture_format, RDTextureView.new(), [vel_data.to_byte_array()])
	vel_texture = Texture2DRD.new()
	vel_texture.texture_rd_rid = vel_texture_rid
	
	param_texture_rid = rd.texture_create(particle_texture_format, RDTextureView.new(), [param_data.to_byte_array()])
	param_texture = Texture2DRD.new()
	param_texture.texture_rd_rid = param_texture_rid
	
	## Collider texture setup
	collider_texture_width = ceil(sqrt(max_colliders * 2)) # we define the textures to be a square that has a number of texels >= to max_colliders * 2
	
	collider_texture_format = RDTextureFormat.new()
	collider_texture_format.width = collider_texture_width
	collider_texture_format.height = collider_texture_width
	collider_texture_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	collider_texture_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	var collider_data = _pack_collidables()
	collider_texture_rid = rd.texture_create(collider_texture_format, RDTextureView.new(), [collider_data])
	collider_texture = Texture2DRD.new()
	collider_texture.texture_rd_rid = collider_texture_rid
	
	## Neighbor Search texture setup
	var num_cells = pow(ceil(sqrt(num_particles * 2)), 2) # we define the number of cells to be a square that has a number of cells >= to num_particles * 2 for hash purposes
	grid_texture_width = int(sqrt(texels_per_cell * num_cells)) # guaranteed to be a square as long as texels_per_cell is a perfect square
	count_buffer_len = int(num_cells)
	
	# Grid texture setup	
	grid_texture_format = RDTextureFormat.new()
	grid_texture_format.width = grid_texture_width
	grid_texture_format.height = grid_texture_width
	grid_texture_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	grid_texture_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Initialize grid data
	var grid_data := PackedFloat32Array()
	grid_data.resize(grid_texture_width * grid_texture_width * 4)
	
	for i in range(grid_texture_width * grid_texture_width): # (texels_per_cell * num_cells)^2
		# Initialize all particle IDs to -1
		grid_data[i * 4 + 0] = -1
		grid_data[i * 4 + 1] = -1
		grid_data[i * 4 + 2] = -1
		grid_data[i * 4 + 3] = -1
	
	grid_texture_rid = rd.texture_create(grid_texture_format, RDTextureView.new(), [grid_data.to_byte_array()])
	grid_texture = Texture2DRD.new()
	grid_texture.texture_rd_rid = grid_texture_rid
	
	# Count buffer setup
	var count_data := PackedInt32Array()
	count_data.resize(count_buffer_len)
	var count_data_byte := count_data.to_byte_array()
	
	count_buffer = rd.storage_buffer_create(count_data_byte.size(), count_data_byte)
	
	## -------------------- Compute Shader Setup --------------------
	
	# Load the compute shaders
	var reset_file := load("res://simulator/compute_shaders/resetCount.glsl")
	var fill_file := load("res://simulator/compute_shaders/fillGrid.glsl")
	var solve_file := load("res://simulator/compute_shaders/solveDensity.glsl")
	var update_file := load("res://simulator/compute_shaders/updatePosition.glsl")
	
	reset_shader = rd.shader_create_from_spirv(reset_file.get_spirv())
	fill_shader = rd.shader_create_from_spirv(fill_file.get_spirv())
	solve_shader = rd.shader_create_from_spirv(solve_file.get_spirv())
	update_shader = rd.shader_create_from_spirv(update_file.get_spirv())
	
	# Create bindings for each texture
	var pos_uniform := RDUniform.new()
	pos_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	pos_uniform.binding = 0 # layout(binding=0) in GLSL
	pos_uniform.add_id(pos_texture_rid)

	var vel_uniform := RDUniform.new()
	vel_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	vel_uniform.binding = 1 # layout(binding=1) in GLSL
	vel_uniform.add_id(vel_texture_rid)
	
	var param_uniform := RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	param_uniform.binding = 2 # layout(binding=2) in GLSL
	param_uniform.add_id(param_texture_rid)
	
	var grid_uniform := RDUniform.new()
	grid_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	grid_uniform.binding = 3 # layout(binding=3) in GLSL
	grid_uniform.add_id(grid_texture_rid)
	
	var count_uniform := RDUniform.new()
	count_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	count_uniform.binding = 4 # layout(binding=4) in GLSL
	count_uniform.add_id(count_buffer)
	
	var collider_uniform := RDUniform.new()
	collider_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	collider_uniform.binding = 5 # layout(binding=5) in GLSL
	collider_uniform.add_id(collider_texture_rid)
	
	# Assign each uniform
	reset_uniform = rd.uniform_set_create([count_uniform], reset_shader, 0)
	fill_uniform = rd.uniform_set_create([pos_uniform, vel_uniform, grid_uniform, count_uniform], fill_shader, 0)
	solve_uniform = rd.uniform_set_create([pos_uniform, vel_uniform, param_uniform, grid_uniform, count_uniform, collider_uniform], solve_shader, 0)
	update_uniform = rd.uniform_set_create([pos_uniform, vel_uniform, param_uniform, grid_uniform, count_uniform, collider_uniform], update_shader, 0)
	
	# Precreate the compute pipeline
	reset_pipeline = rd.compute_pipeline_create(reset_shader)
	fill_pipeline = rd.compute_pipeline_create(fill_shader)
	solve_pipeline = rd.compute_pipeline_create(solve_shader)
	update_pipeline = rd.compute_pipeline_create(update_shader)
	
	## -------------------- Vertex Shader Setup --------------------
	
	# Load the vertex shader
	vert_shader = load("res://simulator/shaders/renderParticles.gdshader")
	particle_mat = ShaderMaterial.new()
	particle_mat.shader = vert_shader
	
	# Pass the relevant textures (and any other data) to the shader as uniforms
	particle_mat.set_shader_parameter("pos_texture", pos_texture)
	particle_mat.set_shader_parameter("vel_texture", vel_texture)
	particle_mat.set_shader_parameter("texture_width", particle_texture_width)
	
	## -------------------- Mesh Setup --------------------
	
	# Define the vertices of the ArrayMesh
	var vertices = PackedVector3Array()
	for i in range(num_particles):
		vertices.append(Vector3.ZERO)

	# Initialize the ArrayMesh
	var arr_mesh = ArrayMesh.new()
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices

	# Create and add the Mesh
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	var m = MeshInstance3D.new()
	m.mesh = arr_mesh
	m.material_override = particle_mat
	m.global_transform = Transform3D.IDENTITY # Ensure the mesh has an identity global transform so world space vertex coords map correctly
	get_tree().root.add_child.call_deferred(m)
	
	# Connect to UI elements
	reload_controller.pressed.connect(_reload_simulation)

func _physics_process(delta):
	_update_counter()
	## Update all dynamic CPU-side data
	# Update the emitter's position
	emission_point = self.global_position
	
	# Update the collidables texture
	rd.texture_update(collider_texture_rid, 0, _pack_collidables())
	
	## Define and dispatch the compute pipeline
	
	var compute_list := rd.compute_list_begin()
	var push_constants = _pack_push_constants(delta)
	
	# Reset counts
	rd.compute_list_bind_compute_pipeline(compute_list, reset_pipeline) # Make sure to bind the compute pipeline before anything else with the compute list
	rd.compute_list_bind_uniform_set(compute_list, reset_uniform, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
	rd.compute_list_dispatch(compute_list, count_buffer_len, 1, 1)
	# Fill grid
	rd.compute_list_bind_compute_pipeline(compute_list, fill_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, fill_uniform, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
	rd.compute_list_dispatch(compute_list, grid_texture_width, grid_texture_width, 1)
	# Solve density
	rd.compute_list_bind_compute_pipeline(compute_list, solve_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, solve_uniform, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
	rd.compute_list_dispatch(compute_list, particle_texture_width, particle_texture_width, 1)
	# Update positions
	rd.compute_list_bind_compute_pipeline(compute_list, update_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, update_uniform, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
	rd.compute_list_dispatch(compute_list, particle_texture_width, particle_texture_width, 1)
	
	rd.compute_list_end()
	# we don't need to submit/sync because we're using the default rendering device; it will automatically handle any queued jobs

func _rebind_textures() -> void:
	## Compute shader uniform
	# Create bindings for each texture
	var pos_uniform := RDUniform.new()
	pos_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	pos_uniform.binding = 0 # layout(binding=0) in GLSL
	pos_uniform.add_id(pos_texture_rid)

	var vel_uniform := RDUniform.new()
	vel_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	vel_uniform.binding = 1 # layout(binding=1) in GLSL
	vel_uniform.add_id(vel_texture_rid)
	
	var param_uniform := RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	param_uniform.binding = 2 # layout(binding=2) in GLSL
	param_uniform.add_id(param_texture_rid)
	
	var grid_uniform := RDUniform.new()
	grid_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	grid_uniform.binding = 3 # layout(binding=3) in GLSL
	grid_uniform.add_id(grid_texture_rid)
	
	var count_uniform := RDUniform.new()
	count_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	count_uniform.binding = 4 # layout(binding=4) in GLSL
	count_uniform.add_id(count_buffer)
	
	var collider_uniform := RDUniform.new()
	collider_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	collider_uniform.binding = 5 # layout(binding=5) in GLSL
	collider_uniform.add_id(collider_texture_rid)
	
	# Assign each uniform
	reset_uniform = rd.uniform_set_create([count_uniform], reset_shader, 0)
	fill_uniform = rd.uniform_set_create([pos_uniform, vel_uniform, grid_uniform, count_uniform], fill_shader, 0)
	solve_uniform = rd.uniform_set_create([pos_uniform, vel_uniform, param_uniform, grid_uniform, count_uniform, collider_uniform], solve_shader, 0)
	update_uniform = rd.uniform_set_create([pos_uniform, vel_uniform, param_uniform, grid_uniform, count_uniform, collider_uniform], update_shader, 0)
	
	# Precreate the compute pipeline
	reset_pipeline = rd.compute_pipeline_create(reset_shader)
	fill_pipeline = rd.compute_pipeline_create(fill_shader)
	solve_pipeline = rd.compute_pipeline_create(solve_shader)
	update_pipeline = rd.compute_pipeline_create(update_shader)
	
	## Vertex shader material
	particle_mat.set_shader_parameter("pos_texture", pos_texture)
	particle_mat.set_shader_parameter("vel_texture", vel_texture)

func _pack_collidables() -> PackedByteArray:
	# Get the axis aligned bounding box for all collidable objects in the scene
	var colliders = get_tree().get_nodes_in_group("collidable")
	var boxes = []
	for node in colliders:
		if node is MeshInstance3D:
			var aabb = node.get_aabb()
			var global_min = node.global_transform * aabb.position
			var global_max = node.global_transform * (aabb.position + aabb.size)
			boxes.append([global_min, global_max])

	# Update the number of colliders to pass to the gpu
	num_colliders = boxes.size()
	#print(boxes)

	# Pack the aabbs into a texture
	var collider_data := PackedFloat32Array()
	collider_data.resize(max_colliders * 2 * 4) # 2 texels per box, 4 floats per texel
	
	for i in range(boxes.size()):
		# aabb min:
		collider_data[(i * 2 + 0) * 4 + 0] = boxes[i][0].x
		collider_data[(i * 2 + 0) * 4 + 1] = boxes[i][0].y
		collider_data[(i * 2 + 0) * 4 + 2] = boxes[i][0].z
		collider_data[(i * 2 + 0) * 4 + 3] = 0.0
		
		# aabb max:
		collider_data[(i * 2 + 1) * 4 + 0] = boxes[i][1].x
		collider_data[(i * 2 + 1) * 4 + 1] = boxes[i][1].y
		collider_data[(i * 2 + 1) * 4 + 2] = boxes[i][1].z
		collider_data[(i * 2 + 1) * 4 + 3] = 0.0
	
	return collider_data.to_byte_array()

func _pack_push_constants(delta) -> PackedByteArray:
	## Set push constants
	var pc := PackedFloat32Array()
	pc.resize(24) # This needs to be a multiple of 16 bytes; each float is 4 bytes (see below)
	# gravity (vec3)
	pc[0] = gravity.x
	pc[1] = gravity.y
	pc[2] = gravity.z
	# damping (float)
	pc[3] = damping
	# dt (float)
	pc[4] = delta
	# num_colliders (int)
	pc[5] = float(num_colliders)
	# collider_texture_width (int)
	pc[6] = float(collider_texture_width)
	# flow_rate (int)
	pc[7] = float(flow_rate)
	# SPH grid min (vec3)
	pc[8] = SPH_grid_min.x
	pc[9] = SPH_grid_min.y
	pc[10] = SPH_grid_min.z
	# SPH grid max (vec3)
	pc[11] = SPH_grid_max.x
	pc[12] = SPH_grid_max.y
	pc[13] = SPH_grid_max.z
	# SPH grid texture width (int)
	pc[14] = float(grid_texture_width)
	# SPH count buffer length (int)
	pc[15] = float(count_buffer_len)
	# SPH texels per cell (int)
	pc[16] = float(texels_per_cell)
	# SPH smoothing kernel
	pc[17] = smoothing_radius
	# particle texture width (int)
	pc[18] = particle_texture_width
	# pressure gas constant (float)
	pc[19] = gas_constant
	# pressure rest density (float)
	pc[20] = rest_density
	# (padding — vulkan word-aligns push constants)
	#pc[...] = 0.0
	
	return pc.to_byte_array()

## Simulation demo functions:---------------------------------------------------
func _reload_simulation() -> void:
	particles_spawned = 0
	_update_parameters()
	_reset_particle_textures()

func _update_parameters() -> void:
	var ui = get_node("/root/Main/UI/Parameters")
	# Initial Velocity Offsets
	initial_velocity.x = ui.get_child(1).value
	initial_velocity.y = ui.get_child(2).value
	initial_velocity.z = ui.get_child(3).value
	# Damping
	damping = ui.get_child(4).value
	# Flow Rate
	flow_rate = ui.get_child(5).value
	# Lifetime
	lifetime = ui.get_child(6).value

func _reset_particle_textures() -> void:
	# Ensure the emitter position is updated
	emission_point = self.global_position
	
	# Reset and update the position/velocity textures
	var pos_data := PackedFloat32Array()
	pos_data.resize(particle_texture_width * particle_texture_width * 4) # 4 floats per texel (rgba)
	var vel_data := PackedFloat32Array()
	vel_data.resize(particle_texture_width * particle_texture_width * 4)
	
	for i in range(num_particles):
		# Initial Position:
		pos_data[i * 4 + 0] = emission_point.x # x
		pos_data[i * 4 + 1] = emission_point.y # y
		pos_data[i * 4 + 2] = emission_point.z # z
		pos_data[i * 4 + 3] = lifetime # lifetime
		
		# Initial Velocity:
		vel_data[i * 4 + 0] = initial_velocity.x + randf() # x
		vel_data[i * 4 + 1] = initial_velocity.y + randf() # y
		vel_data[i * 4 + 2] = initial_velocity.z + randf() # z
		vel_data[i * 4 + 3] = i # frame delay
	
	# Update the existing textures
	rd.texture_update(pos_texture_rid, 0, pos_data.to_byte_array())
	rd.texture_update(vel_texture_rid, 0, vel_data.to_byte_array())

	# Propogate the change to the shader pipelines
	_rebind_textures()

func _update_counter() -> void:
	particles_spawned += flow_rate
	if particles_spawned > num_particles:
		particles_spawned = num_particles
	particle_label.set_text("Particles:\n%d /\n%d" % [particles_spawned, num_particles])

func _clean_shader() -> void:
	## Free all RID objects manually on exit
	if pos_texture_rid: rd.free_rid(pos_texture_rid)
	if vel_texture_rid: rd.free_rid(vel_texture_rid)
	if param_texture_rid: rd.free_rid(param_texture_rid)
	if grid_texture_rid: rd.free_rid(grid_texture_rid)
	if count_texture_rid: rd.free_rid(count_texture_rid)
	if collider_texture_rid: rd.free_rid(collider_texture_rid)
	
	if reset_shader: rd.free_rid(reset_shader)
	if fill_shader: rd.free_rid(fill_shader)
	if solve_shader: rd.free_rid(solve_shader)
	if update_shader: rd.free_rid(update_shader)

	if reset_uniform: rd.free_rid(reset_uniform)
	if fill_uniform: rd.free_rid(fill_uniform)
	if solve_uniform: rd.free_rid(solve_uniform)
	if update_uniform: rd.free_rid(update_uniform)

	if reset_pipeline: rd.free_rid(reset_pipeline)
	if fill_pipeline: rd.free_rid(fill_pipeline)
	if solve_pipeline: rd.free_rid(solve_pipeline)
	if update_pipeline: rd.free_rid(update_pipeline)
