# godot --headless --path . --script res://test/test_line_obstacle.gd
# 列の線が障害物を通るとき: 始める時に障害物を回り込む線に引き直し、列の人は障害物を通らない
extends SceneTree

const Mgr := preload("res://script/SimulationManager3D.gd")
const Config := preload("res://script/core/Config.gd")
const Geometry := preload("res://script/utils/Geometry.gd")
const Walker := preload("res://script/models/Walker.gd")
const State = Walker.State

var failed := false

func _initialize() -> void:
    # 横一直線の列（x = -8 〜 8 m、z = 0）を手描きのように 20 px（0.5 m）ごとの点で。真ん中に障害物（x = -1 〜 1、z = -0.75 〜 0.75）
    var values := Config.defaults()
    var line := Config.object_defaults(values)
    var pts := []
    for x in range(320, 961, 20):
        pts.append(Vector2(x, 360))
    line["points"] = pts
    line["pedestrian_count"] = 1
    var mgr: Node3D = Mgr.new()
    for key in values:
        if key in mgr:
            mgr.set(key, values[key])
    mgr.use_simple_model = true
    mgr.random_seed = 5
    mgr.setup_simulation([line] as Array[Dictionary], [Rect2(600, 330, 80, 60)] as Array[Rect2])
    var g = mgr.groups[0]
    var rects: Array[Rect2] = mgr.wall_rects
    var clear: float = g.lateral_jitter + mgr.body_radius

    # 始点・終点はそのまま。どの区間も障害物から列の幅だけ離れている。回り込む分だけ長い
    check(g.points[0].is_equal_approx(Vector3(-8, 0, 0)) and g.points[-1].is_equal_approx(Vector3(8, 0, 0)))
    for i in range(1, g.points.size()):
        check(Geometry.segment_clear(Vector2(g.points[i - 1].x, g.points[i - 1].z), Vector2(g.points[i].x, g.points[i].z), rects, clear * 0.99))
    check(g.length > 16.5)

    # 列の人は線をたどって終点まで、障害物の中を通らない
    var w: Walker = mgr.walkers[0]
    w.state = State.ON_LINE
    w.s = 0.0
    w.node.position = g.pos(0.0)
    var passed := false
    for _i in range(1800):
        mgr._update_line_member(w, 1.0 / 60.0, INF)
        if w.state != State.ON_LINE:
            passed = true
            break
        check(Geometry.push_out_of_rects(w.node.position, mgr.body_radius, rects) == w.node.position)
    check(passed)

    # 障害物にかからない線はそのまま（点の数も変わらない）
    var straight := Config.object_defaults(values)
    straight["points"] = [Vector2(320, 600), Vector2(960, 600)]
    straight["pedestrian_count"] = 0
    mgr.setup_simulation([straight] as Array[Dictionary], [Rect2(600, 330, 80, 60)] as Array[Rect2])
    check(mgr.groups[0].points.size() == 2)

    for m in mgr.walkers.duplicate():
        mgr.walkers.erase(m)
        m.node.free()
    mgr.free()
    print("test_line_obstacle: ", "FAIL" if failed else "OK")
    quit(1 if failed else 0)

func check(ok: bool) -> void:
    if not ok:
        failed = true
        push_error("check failed")
        print_stack()
