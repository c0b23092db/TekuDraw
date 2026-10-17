# シミュレーション中のカメラ操作（Godot エディタの 3D ビューと同じ操作）と、位置の固定・解除
extends Node

const SceneStore := preload("res://script/core/SceneStore.gd")

const HELP := "右ドラッグ: 見回す\n右クリック + WASD: 移動\n右クリック + QE: 上下移動\n中ドラッグ: 回り込む\nShift　+　中ドラッグ: 平行移動\nホイール: 寄る・離れる\n+ / -: 時刻を 30 分進める・戻す\nEnter: 描画画面へ\nSpace: この表示と列の線のオン・オフ"

var cam: Camera3D
var refit: Callable          # 自動のカメラ位置に戻す処理
var focus_distance: float = 12.0
var fly_speed: float = 8.0
var _looking := false
var _orbiting := false
var _status := Label.new()
var _hour := Label.new()
var _layer := CanvasLayer.new()   # ボタン・操作説明（Space で表示切り替え）

func _init(camera: Camera3D, refit_camera: Callable) -> void:
    cam = camera
    refit = refit_camera

func _ready() -> void:
    add_child(_layer)
    var panel := PanelContainer.new()
    panel.position = Vector2(8, 8)
    _layer.add_child(panel)
    var box := VBoxContainer.new()
    panel.add_child(box)
    var row := HBoxContainer.new()
    box.add_child(row)
    var fix := Button.new()
    fix.text = "カメラ位置を固定"
    fix.pressed.connect(_on_fix_pressed)
    fix.focus_mode = Control.FOCUS_NONE  # フォーカスが残ると Space で押されてしまう
    row.add_child(fix)
    var auto := Button.new()
    auto.text = "自動に戻す"
    auto.pressed.connect(_on_auto_pressed)
    auto.focus_mode = Control.FOCUS_NONE
    row.add_child(auto)
    row.add_child(_status)
    row.add_child(_hour)
    var help := Label.new()
    help.text = HELP
    box.add_child(help)
    update_focus()

func set_status(fixed: bool) -> void:
    _status.text = "  固定中" if fixed else "  自動"

func set_hour(hour: float) -> void:
    _hour.text = "  時刻 %d:%02d" % [int(hour), int(round(fmod(hour, 1.0) * 60.0))]

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
        _layer.visible = not _layer.visible
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

func _focus_point() -> Vector3:
    return cam.position - cam.basis.z * focus_distance

func _orbit(rel: Vector2) -> void:
    var f := _focus_point()
    _turn(rel)
    cam.position = f + cam.basis.z * focus_distance

func _pan(rel: Vector2) -> void:
    cam.position += (-cam.basis.x * rel.x + cam.basis.y * rel.y) * focus_distance * 0.002

# 注視点はそのままで距離を factor 倍にする
func _zoom(factor: float) -> void:
    var f := _focus_point()
    focus_distance = maxf(focus_distance * factor, 1.0)
    cam.position = f + cam.basis.z * focus_distance

func _process(delta: float) -> void:
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
    cam.position += v.normalized() * speed * delta
