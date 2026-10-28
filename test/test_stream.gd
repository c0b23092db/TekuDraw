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
    check(mgr.camera_json() == null)  # シーンに無いのでカメラも無い
    mgr.free()

    print("test_stream: ", "FAIL" if failed else "OK")
    quit(1 if failed else 0)

func check(ok: bool) -> void:
    if not ok:
        failed = true
        push_error("check failed")
        print_stack()
