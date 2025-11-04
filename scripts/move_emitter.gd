extends Node3D

@export var radius : float = 1.0 # Distance from starting point (+/-)
@export var speed : float = 0.01 # Distance covered per frame
@export var controller : CheckButton
var initial_position : Vector3
var max_position : Vector3
var min_position : Vector3
var direction : float
var can_move : bool = false

func _ready() -> void:
	initial_position = self.position
	max_position = initial_position + Vector3(0.0, 0.0, radius)
	min_position = initial_position - Vector3(0.0, 0.0, radius)
	direction = 1.0
	
	controller.toggled.connect(_enable)

func _enable(status: bool) -> void:
	can_move = status

func _process(_delta: float) -> void:
	if can_move:
		var p = self.position + (direction * Vector3(0.0, 0.0, speed))
		if p.z > max_position.z:
			p = max_position
			direction = -1.0
		elif p.z < min_position.z:
			p = min_position
			direction = 1.0

		self.position = p
