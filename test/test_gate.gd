# godot --headless --path . --script res://test/test_gate.gd
# 終点の開け閉め: 閉まっている間は先頭が終点で待ち、後ろの人も詰まって止まる。開いたら通る。受け入れ人数 / 受け入れ時間 の間隔で1人ずつ通る
extends SceneTree

const Mgr := preload("res://script/SimulationManager3D.gd")
const Config := preload("res://script/core/Config.gd")
const Walker := preload("res://script/models/Walker.gd")
const State = Walker.State

const DT := 1.0 / 60.0
var failed := false

func _initialize() -> void:
    # 横一直線の列（x = -8 〜 8 m、長さ 16 m）。開いている 1 秒・閉まっている 2 秒
    var values := Config.defaults()
    var line := Config.object_defaults(values)
    line["points"] = [Vector2(320, 360), Vector2(960, 360)]
    line["pedestrian_count"] = 0
    line["end_open_time"] = 1.0
    line["end_close_time"] = 2.0
    var mgr: Node3D = Mgr.new()
    for key in values:
        if key in mgr:
            mgr.set(key, values[key])
    mgr.use_simple_model = true
    mgr.random_seed = 3
    mgr.setup_simulation([line] as Array[Dictionary], [] as Array[Rect2])
    var g = mgr.groups[0]
    var a := _add(mgr, Vector3(7.9, 0, 0), 15.9)
    var b := _add(mgr, Vector3(7.0, 0, 0), 15.0)

    # 閉まっている（1.5 秒）: 先頭は終点で待ち、後ろの人は先頭の gap 後ろで止まる
    mgr.elapsed = 1.5
    for _i in range(120):
        mgr._update_line_member(a, DT, INF)
        mgr._update_line_member(b, DT, a.s)
    check(a.state == State.ON_LINE and is_equal_approx(a.s, g.length))
    check(is_equal_approx(b.s, g.length - b.gap))

    # 開いた（3 秒 = 次の周期の始め）: 先頭は通って現れ直す
    mgr.elapsed = 3.0
    mgr._update_line_member(a, DT, INF)
    check(a.state != State.ON_LINE)

    # 受け入れ 1 人 / 2 秒（ずっと開いている）: 1人通ると、2 秒たつまで次の人は終点で待つ
    g.end_close_time = 0.0
    g.accept_count = 1
    g.accept_time = 2.0
    b.s = g.length - 0.01
    mgr.elapsed = 10.0
    a.state = State.ON_LINE
    a.s = g.length - 0.001
    mgr._update_line_member(a, DT, INF)
    check(a.state != State.ON_LINE and is_equal_approx(g.next_exit, 12.0))
    mgr.elapsed = 11.9
    mgr._update_line_member(b, DT, INF)
    check(b.state == State.ON_LINE and is_equal_approx(b.s, g.length))
    mgr.elapsed = 12.0
    mgr._update_line_member(b, DT, INF)
    check(b.state != State.ON_LINE)

    for w in mgr.walkers.duplicate():
        mgr.walkers.erase(w)
        w.node.free()
    mgr.free()
    print("test_gate: ", "FAIL" if failed else "OK")
    quit(1 if failed else 0)

func _add(mgr: Node3D, pos: Vector3, s: float) -> Walker:
    var w: Walker = mgr._make_walker()
    w.group = 0
    w.state = State.ON_LINE
    w.radius = mgr.body_radius
    w.gap = 0.8
    w.s = s
    w.node.position = pos
    mgr.walkers.append(w)
    return w

func check(ok: bool) -> void:
    if not ok:
        failed = true
        push_error("check failed")
        print_stack()
