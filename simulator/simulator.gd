extends Node3D

@export var num_particles := 100000
@export var gravity := Vector3(0, -9.81, 0)
@export var damping := -0.7
@export var lifetime := 10.0 # particle lifetime in seconds
@export var initial_velocity := 5.0
@export var max_colliders := 50

## Where the particles are emitting from
var emission_point : Vector3

## Everything defining the compute shader pipeline
var rd : RenderingDevice
var comp_shader : RID
var pipeline : RID
var uniform_set : RID

## Everything defining the vertex shader pipeline
var vert_shader : Shader
var particle_mat : ShaderMaterial

## Everything we want sent to the gpu:
var particle_texture_width : int
var collider_texture_width : int
var num_colliders : int

# The position of each particle (1 texel = 1 particle)
var pos_texture_rid : RID
var pos_texture : Texture2DRD

# The velocity of each particle (1 texel = 1 particle)
var vel_texture_rid : RID
var vel_texture : Texture2DRD

# The axis aligned bounding boxes for all collidable objects (2 texels = 1 box)
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
	
	var particle_texture_format := RDTextureFormat.new()
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
	
	for i in range(num_particles):
		# Initial Position:
		pos_data[i * 4 + 0] = emission_point.x # x
		pos_data[i * 4 + 1] = emission_point.y # y
		pos_data[i * 4 + 2] = emission_point.z # z
		pos_data[i * 4 + 3] = randf_range(0.0, lifetime) # lifetime
		
		# Initial Velocity:
		vel_data[i * 4 + 0] = randf_range(-1.0 * initial_velocity, initial_velocity) # x
		vel_data[i * 4 + 1] = randf_range(-1.0 * initial_velocity, initial_velocity) # y
		vel_data[i * 4 + 2] = randf_range(-1.0 * initial_velocity, initial_velocity) # z
		vel_data[i * 4 + 3] = 0.0 # unused 4th value
	
	pos_texture_rid = rd.texture_create(particle_texture_format, RDTextureView.new(), [pos_data.to_byte_array()])
	pos_texture = Texture2DRD.new()
	pos_texture.texture_rd_rid = pos_texture_rid

	vel_texture_rid = rd.texture_create(particle_texture_format, RDTextureView.new(), [vel_data.to_byte_array()])
	vel_texture = Texture2DRD.new()
	vel_texture.texture_rd_rid = vel_texture_rid
	
	## Collider texture setup
	collider_texture_width = ceil(sqrt(max_colliders * 2)) # we define the textures to be a square that has a number of texels >= to max_colliders * 2
	
	var collider_texture_format := RDTextureFormat.new()
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
	
	## -------------------- Compute Shader Setup --------------------
	
	# Load the compute shader
	var shader_file := load("res://simulator/compute_shaders/updatePosition.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	comp_shader = rd.shader_create_from_spirv(shader_spirv)
	
	# Create bindings for each texture
	var pos_uniform := RDUniform.new()
	pos_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	pos_uniform.binding = 0  # layout(binding=0) in GLSL
	pos_uniform.add_id(pos_texture_rid)

	var vel_uniform := RDUniform.new()
	vel_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	vel_uniform.binding = 1  # layout(binding=1) in GLSL
	vel_uniform.add_id(vel_texture_rid)
	
	var collider_uniform := RDUniform.new()
	collider_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	collider_uniform.binding = 2  # layout(binding=2) in GLSL
	collider_uniform.add_id(collider_texture_rid)

	uniform_set = rd.uniform_set_create([pos_uniform, vel_uniform, collider_uniform], comp_shader, 0)
	
	# Precreate the compute pipeline
	pipeline = rd.compute_pipeline_create(comp_shader)
	
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
	
	# Define the vertices of the arraymesh
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

func _physics_process(delta):
	## Update all dynamic CPU-side data
	# Update the emitter's position
	#emission_point = self.global_position
	
	# Update the collidables texture
	rd.texture_update(collider_texture_rid, 0, _pack_collidables())
	
	## Define the compute pipeline
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	var push_constants = _pack_push_constants(delta)
	rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
	
	## Dispatch compute shader
	rd.compute_list_dispatch(compute_list, particle_texture_width, particle_texture_width, 1)
	rd.compute_list_end()
	# we don't need to submit/sync because we're using the default rendering device; it will automatically handle any queued jobs

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
	pc.resize(8) # This needs to be a multiple of 16 bytes (see below)
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
	# collider_texture_width
	pc[6] = float(collider_texture_width)
	# (padding — vulkan word-aligns push constants)
	pc[7] = 0.0
	
	return pc.to_byte_array()

func _clean_shader() -> void:
	## Free all RID objects manually on exit
	if pos_texture_rid: rd.free_rid(pos_texture_rid)
	if vel_texture_rid: rd.free_rid(vel_texture_rid)
	if collider_texture_rid: rd.free_rid(collider_texture_rid)
	
	if comp_shader: rd.free_rid(comp_shader)
	if uniform_set: rd.free_rid(uniform_set)
	if pipeline: rd.free_rid(pipeline)
