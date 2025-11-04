extends MeshInstance3D

@export var radius : float = 2.0 # Distance from starting point (+/-)
@export var speed : float = 0.01 # Distance covered per frame
@export var controller : CheckButton
var initial_position : Vector3
var max_position : Vector3
var min_position : Vector3
var direction : float
var can_move : bool = false

func _ready() -> void:
	initial_position = self.position
	max_position = initial_position + Vector3(radius, 0.0, 0.0)
	min_position = initial_position - Vector3(radius, 0.0, 0.0)
	direction = 1.0
	
	controller.toggled.connect(_enable)

func _enable(status: bool) -> void:
	can_move = status

func _process(_delta: float) -> void:
	if can_move:
		var p = self.position + (direction * Vector3(speed, 0.0, 0.0))
		if p.x > max_position.x:
			p = max_position
			direction = -1.0
		elif p.x < min_position.x:
			p = min_position
			direction = 1.0

		self.position = p
