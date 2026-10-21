# シミュレーション中のカメラ操作（Godot エディタの 3D ビューと同じ操作）と、位置の固定・解除
extends Node

const SceneStore := preload("res://script/core/SceneStore.gd")

var cam: Camera3D
var refit: Callable          # 自動のカメラ位置に戻す処理
var panel: Control           # シーンの CanvasLayer/Panel（ボタン・操作説明。Space で表示切り替え）
var focus_distance: float = 12.0
var fly_speed: float = 8.0
var _looking := false
var _orbiting := false
var _fixed := false          # 保存した位置がある
var _moved := false          # 固定・初期化のあとに動かした
var _hour := ""

func _init(camera: Camera3D, refit_camera: Callable, ui: Control) -> void:
    cam = camera
    refit = refit_camera
    panel = ui

func _ready() -> void:
    var fix := panel.get_node("VBoxContainer/HBoxContainer/位置固定") as Button
    var reset := panel.get_node("VBoxContainer/HBoxContainer/初期化") as Button
    fix.pressed.connect(_on_fix_pressed)
    reset.pressed.connect(_on_auto_pressed)
    fix.focus_mode = Control.FOCUS_NONE  # フォーカスが残ると Space で押されてしまう
    reset.focus_mode = Control.FOCUS_NONE
    update_focus()

func set_status(fixed: bool) -> void:
    _fixed = fixed
    _moved = false
    _show_status()

func _show_status() -> void:
    var state := "未保存" if _moved else "固定" if _fixed else "初期位置"
    (panel.get_node("VBoxContainer/カメラ状態") as Label).text = "カメラ状態：" + state

func _moved_by_user() -> void:
    if not _moved:
        _moved = true
        _show_status()

func set_hour(hour: float) -> void:
    _hour = "時刻 %d:%02d" % [int(hour), int(round(fmod(hour, 1.0) * 60.0))]

# 画面中央の先にある地面までの距離を注視距離にする（回り込み・ズームの中心）
func update_focus() -> void:
    var forward := -cam.global_basis.z
    if forward.y < -0.01:
        focus_distance = maxf(cam.global_position.y / -forward.y, 1.0)

func _on_fix_pressed() -> void:
    SceneStore.save_camera(cam)
    set_status(true)

func _on_auto_pressed() -> void:
    SceneStore.clear_camera()
    refit.call()
    update_focus()
    set_status(false)

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
        panel.visible = not panel.visible
        return
    if event is InputEventMouseButton:
        match event.button_index:
            MOUSE_BUTTON_RIGHT:
                _looking = event.pressed
                Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _looking else Input.MOUSE_MODE_VISIBLE
            MOUSE_BUTTON_MIDDLE:
                _orbiting = event.pressed
            MOUSE_BUTTON_WHEEL_UP:
                if event.pressed:
                    _zoom(0.9)
            MOUSE_BUTTON_WHEEL_DOWN:
                if event.pressed:
                    _zoom(1.0 / 0.9)
    elif event is InputEventMouseMotion:
        if _looking:
            _turn(event.relative)
        elif _orbiting:
            if event.shift_pressed:
                _pan(event.relative)
            else:
                _orbit(event.relative)

func _turn(rel: Vector2) -> void:
    var r := cam.rotation
    r.y -= rel.x * 0.005
    r.x = clampf(r.x - rel.y * 0.005, -PI / 2 + 0.01, PI / 2 - 0.01)
    r.z = 0.0
    cam.rotation = r
    _moved_by_user()

func _focus_point() -> Vector3:
    return cam.position - cam.basis.z * focus_distance

func _orbit(rel: Vector2) -> void:
    var f := _focus_point()
    _turn(rel)
    cam.position = f + cam.basis.z * focus_distance

func _pan(rel: Vector2) -> void:
    cam.position += (-cam.basis.x * rel.x + cam.basis.y * rel.y) * focus_distance * 0.002
    _moved_by_user()

# 注視点はそのままで距離を factor 倍にする
func _zoom(factor: float) -> void:
    var f := _focus_point()
    focus_distance = maxf(focus_distance * factor, 1.0)
    cam.position = f + cam.basis.z * focus_distance
    _moved_by_user()

func _process(delta: float) -> void:
    (panel.get_node("VBoxContainer/FPS") as Label).text = "FPS: %d　%s" % [Engine.get_frames_per_second(), _hour]
    if not _looking:
        return
    var v := Vector3.ZERO
    if Input.is_physical_key_pressed(KEY_W):
        v -= cam.basis.z
    if Input.is_physical_key_pressed(KEY_S):
        v += cam.basis.z
    if Input.is_physical_key_pressed(KEY_A):
        v -= cam.basis.x
    if Input.is_physical_key_pressed(KEY_D):
        v += cam.basis.x
    if Input.is_physical_key_pressed(KEY_E):
        v += Vector3.UP
    if Input.is_physical_key_pressed(KEY_Q):
        v -= Vector3.UP
    var speed := fly_speed * (3.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
    if v != Vector3.ZERO:
        cam.position += v.normalized() * speed * delta
        _moved_by_user()
