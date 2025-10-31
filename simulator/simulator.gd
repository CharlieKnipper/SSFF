extends Node3D

@export var num_particles := 5000
@export var box_min := Vector3(-4, -3.9, -4)
@export var box_max := Vector3(4, 0, 4)
@export var gravity := Vector3(0, -9.81, 0)
@export var damping := -0.8

## Everything defining the compute shader pipeline
var rd : RenderingDevice
var comp_shader : RID
var pipeline : RID
var uniform_set : RID

## Everything defining the vertex shader pipeline
var vert_shader : Shader
var particle_mat : ShaderMaterial

## Everything we want sent to the gpu:
var texture_width : int
var pos_texture_rid : RID
var vel_texture_rid : RID
var pos_texture : Texture2DRD
var vel_texture : Texture2DRD

func _ready():
	# Initialize rendering device
	rd = RenderingServer.get_rendering_device()
	
	## -------------------- Texture Setup --------------------
	
	# Define the empty texture format
	texture_width = ceil(sqrt(num_particles)) # we define the textures to be a square that has a number of texels >= to num_particles
	
	var texture_format := RDTextureFormat.new()
	texture_format.width = texture_width
	texture_format.height = texture_width
	texture_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	texture_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | # for compute shader writes
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | # for vertex shader reads
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT # for CPU initialization
	)

	# Initialize each texture
	var pos_data := PackedFloat32Array()
	pos_data.resize(texture_width * texture_width * 4) # 4 floats per texel (rgba)
	var vel_data := PackedFloat32Array()
	vel_data.resize(texture_width * texture_width * 4)
	
	for i in range(num_particles):
		# Initial Position:
		pos_data[i * 4 + 0] = randf_range(box_min.x, box_max.x) # x
		pos_data[i * 4 + 1] = randf_range(box_min.y, box_max.y) # y
		pos_data[i * 4 + 2] = randf_range(box_min.z, box_max.z) # z
		pos_data[i * 4 + 3] = 0.0 # unused 4th value
		
		# Initial Velocity:
		vel_data[i * 4 + 0] = 0.0 # x
		vel_data[i * 4 + 1] = 0.0 # y
		vel_data[i * 4 + 2] = 0.0 # z
		vel_data[i * 4 + 3] = 0.0 # unused 4th value
	
	pos_texture_rid = rd.texture_create(texture_format, RDTextureView.new(), [pos_data.to_byte_array()])
	pos_texture = Texture2DRD.new()
	pos_texture.texture_rd_rid = pos_texture_rid

	vel_texture_rid = rd.texture_create(texture_format, RDTextureView.new(), [vel_data.to_byte_array()])
	vel_texture = Texture2DRD.new()
	vel_texture.texture_rd_rid = vel_texture_rid
	
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

	uniform_set = rd.uniform_set_create([pos_uniform, vel_uniform], comp_shader, 0)
	
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
	particle_mat.set_shader_parameter("texture_width", texture_width)
	
	## -------------------- Additional Setup --------------------
	
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
	add_child(m)
	
	# Clean RID objects that need to be freed manually on node removal
	connect("tree_exited", _clean_shader)

func _physics_process(delta):
	## Define the compute pipeline
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, _set_push_constants(delta), 64)
	
	## Dispatch compute shader
	rd.compute_list_dispatch(compute_list, texture_width, texture_width, 1)
	rd.compute_list_end()
	# we don't need to submit/sync because we're using the default rendering device; it will automatically handle any queued jobs

func _set_push_constants(delta) -> PackedByteArray:
	## Set push constants
	var pc := PackedByteArray()
	pc.resize(64)
	# gravity (vec3) @ offset 0
	pc.encode_float(0, gravity.x)
	pc.encode_float(4, gravity.y)
	pc.encode_float(8, gravity.z)
	# box_min (vec3) @ offset 16
	pc.encode_float(16, box_min.x)
	pc.encode_float(20, box_min.y)
	pc.encode_float(24, box_min.z)
	# box_max (vec3) @ offset 32
	pc.encode_float(32, box_max.x)
	pc.encode_float(36, box_max.y)
	pc.encode_float(40, box_max.z)
	# damping (float) @ offset 48
	pc.encode_float(48, damping)
	# dt (float) @ offset 52
	pc.encode_float(52, delta)
	# (bytes 56–63 remain as padding — vulkan word-aligns push constants?)
	
	return pc

func _clean_shader() -> void:
	## Free all RID objects manually on exit
	if pos_texture_rid: rd.free_rid(pos_texture_rid)
	if vel_texture_rid: rd.free_rid(vel_texture_rid)
	if comp_shader: rd.free_rid(comp_shader)
	if uniform_set: rd.free_rid(uniform_set)
	if pipeline: rd.free_rid(pipeline)
