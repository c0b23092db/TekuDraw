# godot --headless --path . --script res://test/test_stream.gd
# JSON の出力: 番号（現れ直すと新しい番号）、経過秒、床の位置、向き
extends SceneTree

const Mgr := preload("res://script/SimulationManager3D.gd")
const Config := preload("res://script/core/Config.gd")
const Walker := preload("res://script/models/Walker.gd")
const State = Walker.State

var failed := false

func _initialize() -> void:
    # 横一直線の列（x = -8 〜 8 m、z = 0、+X へ進む）に 3 人
    var values := Config.defaults()
    var line := Config.object_defaults(values)
    line["points"] = [Vector2(320, 360), Vector2(960, 360)]
    line["pedestrian_count"] = 3
    line["spawn_interval"] = 0.0
    var mgr: Node3D = Mgr.new()
    for key in values:
        if key in mgr:
            mgr.set(key, values[key])
    mgr.use_simple_model = true
    mgr.random_seed = 7
    mgr.json_interval = 0.5
    mgr.setup_simulation([line] as Array[Dictionary], [] as Array[Rect2])

    var ids: Array = mgr.walkers.map(func(w: Walker) -> int: return w.id)
    check(ids == [0, 1, 2])
    mgr._respawn(mgr.walkers[0])
    check(mgr.walkers[0].id == 3)  # 現れ直すと別の人

    for _i in range(60):
        mgr._physics_process(1.0 / 60.0)
    var f: Dictionary = JSON.parse_string(JSON.stringify(mgr.frame_json()))
    check(f["type"] == "frame" and is_equal_approx(f["t"], 1.0) and f["walkers"].size() == 3)
    for i in range(3):
        var w: Walker = mgr.walkers[i]
        var o: Dictionary = f["walkers"][i]
        check(int(o["id"]) == w.id and absf(o["x"] - w.node.position.x) < 0.001 and absf(o["z"] - w.node.position.z) < 0.001)

    # 向き: +X へ進む列の人は π/2。モデルの向き補正は含めない
    var m: Walker = mgr.walkers[1]
    m.state = State.ON_LINE
    m.s = 4.0
    mgr.model_yaw_offset_deg = 90.0
    mgr._update_line_member(m, 1.0 / 60.0, INF)
    var yaw: float = mgr.frame_json()["walkers"][1]["yaw"]
    check(absf(yaw - PI / 2.0) < 0.01)

    # 列の正解: 並んでいる人だけ on_line。group は動物体の番号
    mgr.walkers[0].state = State.TO_LINE
    var ws: Array = JSON.parse_string(JSON.stringify(mgr.frame_json()))["walkers"]
    check(ws[1]["on_line"] == true and ws[0]["on_line"] == false and int(ws[1]["group"]) == 0)
    check(mgr.camera_json() == null)  # シーンに無いのでカメラも無い
    check(not ws[1].has("bbox"))       # カメラが無ければ枠も無い

    # 画像の上の枠と見えている割合: 高さ 0.85 m、10 m 手前から -Z 向きに見る
    var cam := Camera3D.new()
    root.add_child(cam)
    await process_frame  # root がシーンに入るのを待つ
    cam.position = Vector3(0.0, 0.85, 10.0)
    cam.fov = 70.0
    for w: Walker in mgr.walkers:
        w.node.scale = Vector3.ONE
        w.radius = 0.2
    mgr.walkers[0].node.position = Vector3.ZERO              # 1 の後ろに隠れる
    mgr.walkers[1].node.position = Vector3(0.0, 0.0, 5.0)
    mgr.walkers[2].node.position = Vector3(5.0, 0.0, 0.0)    # 右に 5 m。隠れない
    # ヘッドレスでは画像が 4×4 px しか無いので、画像の大きさは見かけの画面と同じにして渡す
    var size: Vector2 = root.get_visible_rect().size
    var truth := func() -> Array:
        return mgr.walkers.map(func(w: Walker) -> Dictionary: return mgr.screen_truth(w, cam, mgr.occluders(), size))
    ws = truth.call()
    var px := size.y * 0.5 / tan(deg_to_rad(35.0)) / 10.0   # 10 m 先の 1 m が何 px か
    var b: Array = ws[2]["bbox"]
    check(absf(b[0] + b[2] * 0.5 - (size.x * 0.5 + 5.0 * px)) < 3.0)       # 枠の中心の横位置
    check(absf(b[1] + b[3] * 0.5 - size.y * 0.5) < 3.0)                    # 目の高さが体の真ん中
    check(b[3] > mgr.human_height * px and b[3] < mgr.human_height * px * 1.05)  # 高さは身長ぶん（手前の面のぶん少し大きい）
    check(ws[2]["vis"] == 1.0 and ws[1]["vis"] == 1.0 and ws[0]["vis"] == 0.0)
    mgr.walkers[2].node.position = Vector3(0.0, 0.0, 20.0)  # カメラの後ろ
    check(truth.call()[2].is_empty())
    check(mgr.frame_json(cam)["f"] == mgr.frame_no)  # カメラを渡しても落ちない
    # 障害物の陰: 高さ 1 m の箱の後ろでは、体の軸の 5 点（0.17〜1.53 m）のうち下の 3 点が隠れる
    mgr.walkers[2].node.position = Vector3(5.0, 0.0, 0.0)
    mgr.obstacle_height = 1.0
    mgr.wall_rects = [Rect2(4.0, 1.0, 2.0, 0.5)] as Array[Rect2]
    check(is_equal_approx(truth.call()[2]["vis"], 0.4))
    cam.free()
    mgr.free()

    print("test_stream: ", "FAIL" if failed else "OK")
    quit(1 if failed else 0)

func check(ok: bool) -> void:
    if not ok:
        failed = true
        push_error("check failed")
        print_stack()
