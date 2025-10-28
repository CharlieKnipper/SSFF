extends Node3D

@export var num_particles := 1024
@export var box_min := Vector3(-5, 0, -5)
@export var box_max := Vector3(5, 5, 5)
@export var gravity := Vector3(0, -9.81, 0)
@export var damping := 0.5
@export var mesh := SphereMesh.new()

var rd : RenderingDevice
var shader : RID
var pipeline : RID
var buffer : RID
var multimesh : MultiMesh
var multimesh_instance : MultiMeshInstance3D

const LOCAL_SIZE_X := 128

func _ready():
	## Initialize rendering device
	rd = RenderingServer.create_local_rendering_device()

	## Load GLSL shader
	var shader_file := load("res://simulator/compute_shaders/updatePosition.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	
	## Initialize GPU buffer for particle data
	# Prepare our data. We use floats in the shader, so we need 32 bit.
	var pba = PackedByteArray()
	pba.resize(num_particles * 4 * 4) # 4 floats * 4 bytes each per particle

	for i in range(num_particles):
		var idx_b = i * 16 # bytes per particle
		var pos = Vector3(
			randf() * (box_max.x - box_min.x) + box_min.x,
			randf() * (box_max.y - box_min.y) + box_min.y,
			randf() * (box_max.z - box_min.z) + box_min.z
		)
		pba.encode_float(idx_b + 0, pos.x)
		pba.encode_float(idx_b + 4, pos.y)
		pba.encode_float(idx_b + 8, pos.z)
		pba.encode_float(idx_b + 12, 0.0) # w (unused)

	buffer = rd.storage_buffer_create(pba.size(), pba)
	
	## Precreate pipeline
	pipeline = rd.compute_pipeline_create(shader)

	## Set up the multimesh
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.instance_count = num_particles
	multimesh.mesh = mesh
	multimesh_instance = MultiMeshInstance3D.new()
	multimesh_instance.multimesh = multimesh
	add_child(multimesh_instance)
	
	## Clean RID objects that need to be freed manually on node removal
	connect("tree_exited", _clean_shader)

func _physics_process(delta):
	## Prepare the input data to be sent to the GPU
	# Create a uniform to assign the buffer to the rendering device
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0 # this needs to match the "binding" in our shader file
	uniform.add_id(buffer)
	var uniform_set := rd.uniform_set_create([uniform], shader, 0) # the last parameter (the 0) needs to match the "set" in our shader file

	## Define the compute pipeline
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
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
	rd.compute_list_set_push_constant(compute_list, pc, 64)
	
	## Dispatch compute shader
	var groups_x = int((num_particles + LOCAL_SIZE_X - 1) / LOCAL_SIZE_X)
	rd.compute_list_dispatch(compute_list, groups_x, 1, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	# Read back the data from the buffer
	var output_bytes := rd.buffer_get_data(buffer)
	var output := output_bytes.to_float32_array()
	
	## Transform the multimesh using the new positions
	_update_multimesh(output)

func _update_multimesh(data: PackedFloat32Array):
	for i in range(num_particles):
		var idx = i * 4
		var pos = Vector3(data[idx + 0], data[idx + 1], data[idx + 2])
		var t = Transform3D(Basis(), pos)
		multimesh.set_instance_transform(i, t)

func _clean_shader() -> void:
	## Free the shader buffer and pipeline manually
	if buffer: rd.free_rid(buffer)
	if pipeline: rd.free_rid(pipeline)
	if shader: rd.free_rid(shader)
