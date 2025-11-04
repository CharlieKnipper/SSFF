extends Button

var cameras : Array[Camera3D]
var active_cam : Camera3D
var active_index : int

func _ready() -> void:
	var nodes = get_tree().get_nodes_in_group("camera")
	for node in nodes:
		if node is Camera3D:
			cameras.append(node)

	active_cam = get_viewport().get_camera_3d()
	active_index = cameras.find(active_cam)
	
	connect("pressed", _switch_camera)

func _switch_camera() -> void:
	if active_index == (cameras.size() - 1):
		active_index = 0
	else:
		active_index += 1
	
	active_cam = cameras[active_index]
	active_cam.set_current(true)
