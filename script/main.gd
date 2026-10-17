extends CanvasLayer

const PathDrawer := preload("res://script/PathDrawer2D.gd")
const Config := preload("res://script/core/Config.gd")
const SceneStore := preload("res://script/core/SceneStore.gd")
const SettingsDialog := preload("res://script/scene/SettingsDialog.gd")
const Motion := preload("res://script/core/Motion.gd")

@onready var simulate_button: Button = $Panel/VBoxContainer/SimulateButton
@onready var replay_button: Button = $Panel/VBoxContainer/ReplayButton
@onready var obstacle_button: Button = $"Panel/VBoxContainer/障害物"
@onready var add_button: Button = $"Panel/VBoxContainer/Object/基本動作/Add"
@onready var delete_button: Button = $"Panel/VBoxContainer/Object/基本動作/Delete"
@onready var edit_button: Button = $"Panel/VBoxContainer/Object/基本動作/Edit"
@onready var clear_line_button: Button = $"Panel/VBoxContainer/Object/削除/列削除"
@onready var clear_spawn_button: Button = $"Panel/VBoxContainer/Object/削除/出現削除"
@onready var clear_goal_button: Button = $"Panel/VBoxContainer/Object/削除/目的地削除"
@onready var object_list: ItemList = $Panel/VBoxContainer/ItemList
@onready var setting_button: Button = $Panel/VBoxContainer/Config
@onready var path_drawer: Node2D = $"../PathDrawer2D"

var dialog := SettingsDialog.new()
var replay_dialog := AcceptDialog.new()  # 再生するリプレイファイルを選ぶ
var replay_list := ItemList.new()
var next_number: int = 1

func _ready() -> void:
    add_child(dialog)
    replay_dialog.title = "リプレイを選ぶ"
    replay_dialog.ok_button_text = "再生"
    replay_dialog.add_cancel_button("キャンセル")
    replay_list.custom_minimum_size = Vector2(420, 320)
    replay_list.item_activated.connect(func(_i: int) -> void: _play_selected_replay())  # ダブルクリック
    replay_dialog.add_child(replay_list)
    replay_dialog.confirmed.connect(_play_selected_replay)
    add_child(replay_dialog)
    simulate_button.pressed.connect(_on_simulate_button_pressed)
    replay_button.pressed.connect(_on_replay_pressed)
    obstacle_button.pressed.connect(_on_obstacle_pressed)
    add_button.pressed.connect(_on_add_pressed)
    delete_button.pressed.connect(_on_delete_pressed)
    edit_button.pressed.connect(func() -> void: _edit_object(path_drawer.selected))
    clear_line_button.pressed.connect(_clear_points.bind("points"))
    clear_spawn_button.pressed.connect(_clear_points.bind("spawn_points"))
    clear_goal_button.pressed.connect(_clear_points.bind("goal_points"))
    object_list.item_selected.connect(_select)
    object_list.item_activated.connect(_edit_object)  # ダブルクリック
    setting_button.pressed.connect(_on_setting_pressed)
    path_drawer.edited.connect(_save)

    # 保存してある動物体・障害物を読み込む。無ければ「動物体1」を用意
    path_drawer.obstacles = SceneStore.load_obstacles()
    for obj in SceneStore.load_objects():
        _add_object(obj)
    if path_drawer.objects.is_empty():
        _on_add_pressed()
    else:
        _select(0)

func _save() -> void:
    SceneStore.save_objects(path_drawer.objects)
    SceneStore.save_obstacles(path_drawer.obstacles)

func _select(index: int) -> void:
    path_drawer.mode = PathDrawer.Mode.OBJECT
    path_drawer.selected = index
    if index >= 0:
        object_list.select(index)
    path_drawer.queue_redraw()

func _on_obstacle_pressed() -> void:
    path_drawer.mode = PathDrawer.Mode.OBSTACLE
    path_drawer.selected = -1
    object_list.deselect_all()
    path_drawer.queue_redraw()

func _add_object(obj: Dictionary) -> void:
    if not obj.has("name"):
        obj["name"] = "動物体%d" % next_number
    next_number += 1
    path_drawer.objects.append(obj)
    object_list.add_item(obj["name"])
    _select(path_drawer.objects.size() - 1)

# 新しい動物体の設定は全体設定の「動物体の初期値」から
func _on_add_pressed() -> void:
    var obj := Config.object_defaults(Config.load_values())
    obj["points"] = []
    obj["spawn_points"] = []
    obj["goal_points"] = []
    _add_object(obj)
    _save()

func _on_delete_pressed() -> void:
    var i: int = path_drawer.selected
    if i < 0:
        return
    path_drawer.objects.remove_at(i)
    object_list.remove_item(i)
    _select(mini(i, path_drawer.objects.size() - 1))
    _save()

# 選んでいる動物体の線（列 points・出現地 spawn_points・目的地 goal_points）を消す
func _clear_points(key: String) -> void:
    if path_drawer.selected < 0:
        print("エラー: 動物体が選択されていません")
        return
    path_drawer.objects[path_drawer.selected][key] = []
    path_drawer.queue_redraw()
    _save()

# 動物体ごとの設定（動き・人数・速さ など）。動きのスクリプトの項目は、左の一覧にスクリプトの名前で出る
func _edit_object(index: int) -> void:
    if index < 0:
        print("エラー: 動物体が選択されていません")
        return
    var obj: Dictionary = path_drawer.objects[index]
    dialog.open("%s の設定" % obj["name"], [], obj,
        func(values: Dictionary) -> void:
            obj.merge(values, true)
            _save(),
        {"object": "動物体"},
        func(values: Dictionary) -> Array:
            var m: String = values.get("motion", "")
            return Config.fields_in("object") + (Motion.fields(Motion.compile(Motion.source(m), m)) if m != "" else []))

# 全体設定（./.config/general.toml）
func _on_setting_pressed() -> void:
    dialog.open("全体の設定", Config.FIELDS, Config.load_values(),
        func(values: Dictionary) -> void: Config.save_values(values), Config.SECTION_LABELS)

func _on_simulate_button_pressed() -> void:
    var ok := false
    for obj in path_drawer.objects:
        if obj["pedestrian_count"] > 0:
            ok = true
        var m: String = obj.get("motion", "")
        if m == "" and obj["points"].size() < 2 and obj["pedestrian_count"] > 0:
            print("注意: %s は列の線が無いため、人を出しません（左ドラッグで列を引くか、動きを変えてください）" % obj["name"])
        if m != "" and Motion.compile(Motion.source(m), m) == null:
            print("エラー: %s の動きのスクリプト %s を読めません（上に出た誤りの行を直してください）" % [obj["name"], m])
            return
    if not ok:
        print("エラー: 歩く人がいません（どの動物体も人数が 0 です）")
        return
    _save()
    # シードを決めて、今の設定・動物体・障害物と一緒にリプレイファイルへ。シミュレーションはこのファイルで動く
    _start(SceneStore.save_replay(Config.load_values(), path_drawer.objects, path_drawer.obstacles))

func _on_replay_pressed() -> void:
    replay_list.clear()
    for f in SceneStore.list_replays():
        replay_list.add_item(f)
    if replay_list.item_count == 0:
        print("リプレイがありません（シミュレートすると ./.config/replay に保存されます）")
        return
    replay_list.select(0)
    replay_dialog.popup_centered()

func _play_selected_replay() -> void:
    var sel := replay_list.get_selected_items()
    if sel.is_empty():
        return
    replay_dialog.hide()
    _start(SceneStore.REPLAY_DIR.path_join(replay_list.get_item_text(sel[0])))

func _start(replay_path: String) -> void:
    SceneStore.current_replay = replay_path
    get_tree().change_scene_to_file("res://scene/simulation.tscn")
