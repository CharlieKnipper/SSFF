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

func _ready():
	## Initialize rendering device
	rd = RenderingServer.create_local_rendering_device()

	## Load GLSL shader
	var shader_file := load("res://simulator/compute_shaders/updatePosition.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	
	## Initialize GPU buffer for particle data
	# Prepare our data. We use floats in the shader, so we need 32 bit.
	var input := PackedFloat32Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
	print(multimesh.get_instance_transform(0))
	var input_bytes := input.to_byte_array()

	# Create a storage buffer that can hold our float values.
	# Each float has 4 bytes (32 bit) so 10 x 4 = 40 bytes
	buffer = rd.storage_buffer_create(input_bytes.size(), input_bytes)

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
	pipeline = rd.compute_pipeline_create(shader)
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, 5, 1, 1)
	rd.compute_list_end()
	
	## Dispatch compute shader
	rd.submit()
	rd.sync()
	
	# Read back the data from the buffer
	var output_bytes := rd.buffer_get_data(buffer)
	var output := output_bytes.to_float32_array()
	
	## Transform the multimesh using the new positions
	_update_multimesh(output)

func _update_multimesh(data: PackedFloat32Array):
	#var stride = 6
	#for i in num_particles:
		#var idx = i * stride
		#var pos = Vector3(data[idx + 0], data[idx + 1], data[idx + 2])
		#var t = Transform3D(Basis(), pos)
		#multimesh.set_instance_transform(i, t)
	#print(data)
	return

func _clean_shader() -> void:
	## Free the shader buffer and pipeline manually
	rd.free_rid(buffer)
	rd.free_rid(pipeline)
