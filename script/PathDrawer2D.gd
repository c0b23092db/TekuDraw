extends Node2D

signal edited  # 線・障害物を描いた・消した（保存のきっかけ）

enum Mode { OBSTACLE, OBJECT }

const OBJECT_COLORS: Array[Color] = [Color.BLUE, Color.ORANGE, Color.MAGENTA, Color.DARK_CYAN, Color.OLIVE]

@export var line_width: float = 5.0
@export var start_color: Color = Color.RED
@export var end_color: Color = Color.GREEN
@export var point_radius: float = 8.0
@export var obstacle_color: Color = Color(0.3, 0.3, 0.3, 0.8)

var is_drawing: bool = false
var mode: Mode = Mode.OBJECT
var obstacles: Array[Rect2] = []
var objects: Array[Dictionary] = []   # SceneStore.load_objects() と同じ形式
var selected: int = -1              # OBJECT モードで描く対象
var drag_start: Vector2
var drawing_key := "points"         # OBJECT モードで描いている線（左ドラッグ: 列 points、右ドラッグ: 出現地 spawn_points、Shift+左ドラッグ: 目的地 goal_points）

func _unhandled_input(event: InputEvent) -> void:
	if mode == Mode.OBJECT and selected < 0:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and mode == Mode.OBSTACLE:
		for i in range(obstacles.size() - 1, -1, -1):
			if obstacles[i].has_point(event.position):
				obstacles.remove_at(i)
				edited.emit()
				queue_redraw()
				break
		return

	var draw_button: bool = event is InputEventMouseButton and (event.button_index == MOUSE_BUTTON_LEFT or (event.button_index == MOUSE_BUTTON_RIGHT and mode == Mode.OBJECT))
	if draw_button:
		if event.pressed and not is_drawing:
			is_drawing = true
			drag_start = event.position
			if mode == Mode.OBJECT:
				drawing_key = "spawn_points" if event.button_index == MOUSE_BUTTON_RIGHT else ("goal_points" if event.shift_pressed else "points")
				objects[selected][drawing_key] = [event.position]
			queue_redraw()
		elif not event.pressed and is_drawing:
			is_drawing = false
			if mode == Mode.OBSTACLE:
				var r := Rect2(drag_start, event.position - drag_start).abs()
				if r.size.x > 5.0 and r.size.y > 5.0:
					obstacles.append(r)
			edited.emit()
			queue_redraw()

	elif event is InputEventMouseMotion and is_drawing:
		if mode == Mode.OBJECT:
			var pts: Array = objects[selected][drawing_key]
			if pts.is_empty() or pts[-1].distance_to(event.position) > 10.0:
				pts.append(event.position)
		queue_redraw()

func _draw() -> void:
	for r in obstacles:
		draw_rect(r, obstacle_color)
	if is_drawing and mode == Mode.OBSTACLE:
		draw_rect(Rect2(drag_start, get_local_mouse_position() - drag_start).abs(), obstacle_color, false, 2.0)

	for i in range(objects.size()):
		# 出現地は長い破線、目的地は短い点線（列の線と見分ける）。点1つならその場所に小さな丸
		for key in ["spawn_points", "goal_points"]:
			var extra: Array = objects[i].get(key, [])
			var c := OBJECT_COLORS[i % OBJECT_COLORS.size()]
			if extra.size() == 1:
				draw_circle(extra[0], point_radius * 0.6, c)
			for j in range(extra.size() - 1):
				draw_dashed_line(extra[j], extra[j + 1], c, line_width * 0.6, 8.0 if key == "spawn_points" else 2.5)
		var pts: Array = objects[i]["points"]
		if pts.size() > 1:
			var w := line_width * (2.0 if i == selected else 1.0)
			draw_polyline(PackedVector2Array(pts), OBJECT_COLORS[i % OBJECT_COLORS.size()], w)
		if pts.size() > 0:
			draw_circle(pts[0], point_radius, start_color)
		if pts.size() > 1:
			draw_circle(pts[-1], point_radius, end_color)
