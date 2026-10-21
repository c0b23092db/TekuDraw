# godot --headless --path . --script res://test/test_routes.gd
# 二本の経路（列の通過コストで回り込むか）、出現する場所の線、列が空のときの入り方、ランダムに歩く人の目的地
extends SceneTree

const Mgr := preload("res://script/SimulationManager3D.gd")
const Config := preload("res://script/core/Config.gd")
const Walker := preload("res://script/models/Walker.gd")
const Motion := preload("res://script/core/Motion.gd")
const State = Walker.State

var failed := false

func _initialize() -> void:
    # 横一直線の列（x = -8 〜 8 m、z = 0）に 10 人。ランダムに歩く人の動物体には出現する場所の線（z = -6 m の横線）
    var values := Config.defaults()
    var line := Config.object_defaults(values)
    line["points"] = [Vector2(320, 360), Vector2(960, 360)]
    line["pedestrian_count"] = 0
    var walker := Config.object_defaults(values)
    walker["points"] = []
    walker["spawn_points"] = [Vector2(400, 120), Vector2(880, 120)]
    walker["goal_points"] = [Vector2(640, 600)]  # 目的地は1点（x = 0, z = 6 m）
    walker["motion"] = "random_walk.gd"
    walker["pedestrian_count"] = 20
    var mgr: Node3D = Mgr.new()
    for key in values:
        if key in mgr:
            mgr.set(key, values[key])
    mgr.use_simple_model = true
    mgr.random_seed = 7
    mgr.setup_simulation([line, walker] as Array[Dictionary], [] as Array[Rect2])

    # 出現地の線の上に現れる。random_walk.gd が選ぶ目的地は列のそばにならず、歩き出す
    var start := {}
    for w in mgr.walkers:
        check(absf(w.node.position.z - -6.0) < 0.01 and absf(w.node.position.x) <= 6.0 + 0.01)
        start[w] = w.node.position
    for _i in range(60):
        mgr._physics_process(1.0 / 60.0)
    for w in mgr.walkers:
        check(w.memory["goal"].is_equal_approx(Vector3(0, 0, 6)))
        check(w.node.position.distance_to(start[w]) > 0.5)

    # 目的地の線が無ければ、目的地は列のそばにならない
    mgr.groups[1].goal_curve.clear_points()
    for w in mgr.walkers:
        mgr._respawn(w)
    mgr._physics_process(1.0 / 60.0)
    for w in mgr.walkers:
        var goal: Vector3 = w.memory["goal"]
        check(mgr.groups[0].curve.get_closest_point(goal).distance_to(goal) >= mgr.groups[0].lateral_jitter + Mgr.LINE_CLEAR - 0.01)

    # step() が {"line": true} を返したら組み込みの列へ。Dictionary 以外を返したらその場で止まる
    var to_line := "extends RefCounted
func step(me, world, rng, delta):
	return {\"line\": true} if me.memory.get(\"go\", false) else 0
"
    mgr.groups[1].script_obj = Motion.compile(to_line, "to_line.gd").new()
    mgr.groups[1].points = mgr.groups[0].points
    mgr.groups[1].curve = mgr.groups[0].curve
    mgr.groups[1].join_line = true
    var s: Walker = mgr.walkers[0]
    mgr._update_scripted(s, 1.0 / 60.0)
    check(s.state == State.SCRIPTED and s.velocity.length() < 0.5)
    s.memory["go"] = true
    mgr._update_scripted(s, 1.0 / 60.0)
    check(s.state == State.TO_LINE)
    for w in mgr.walkers.duplicate():
        mgr.walkers.erase(w)
        w.node.free()

    # 列が空なら、並びに行く人は線の始点ではなく一番近い所を目指す
    var j := _add(mgr, 0, State.TO_LINE, Vector3(5.0, 0, 2.0))
    mgr.routes.update_spans()
    mgr._update_joiner(j, 1.0 / 60.0)
    check(j.velocity.length() > 0.0 and j.velocity.normalized().z < -0.9)  # 始点（x = -8）へ戻らず、まっすぐ線へ
    mgr.groups[0].join_nearest = false  # 決められた列に並ぶ動き: 始点へ向かう
    j.velocity = Vector3.ZERO
    mgr._update_joiner(j, 1.0 / 60.0)
    check(j.velocity.normalized().x < -0.9)
    mgr.groups[0].join_nearest = true
    mgr.walkers.erase(j)
    j.node.free()

    # 列に人を並べる（x = -4 〜 4 m）
    for i in range(10):
        var m := _add(mgr, 0, State.ON_LINE, Vector3(-4.0 + i * 0.9, 0, 0))
        m.s = 4.0 + i * 0.9
    mgr.routes.update_spans()
    var w: Walker = mgr.walkers[0]
    w.node.position = Vector3(0, 0, -3)
    var goal := Vector3(0, 0, 3)  # 列の真向かい
    mgr.groups[0].cross_cost = 50.0
    w.reroute = 0.0
    var via: Vector3 = mgr.routes.route(w, goal, 1.0 / 60.0)
    check(w.via.x == 0 and absf(via.x) > 4.0)  # 通り抜けるより回り込むほうが安い
    mgr.groups[0].cross_cost = 0.0
    w.reroute = 0.0
    check(mgr.routes.route(w, goal, 1.0 / 60.0) == goal and w.via.x == -1)  # コスト 0 ならまっすぐ
    mgr.two_routes = false
    mgr.groups[0].cross_cost = 50.0
    w.reroute = 0.0
    check(mgr.routes.route(w, goal, 1.0 / 60.0) == goal)  # 「二本の経路」が無効ならまっすぐ
    # 列の端から中心線に沿って列の中を進む道も、通り抜けと数える
    check(mgr.routes.leg_cost(Vector3(-6, 0, 0), Vector3(6, 0, 0)) > 12.0 + 49.0)
    check(is_equal_approx(mgr.routes.leg_cost(Vector3(-6, 0, -3), Vector3(6, 0, -3)), 12.0))
    mgr.free()

    print("test_routes: ", "FAIL" if failed else "OK")
    quit(1 if failed else 0)

func _add(mgr: Node3D, group: int, state: State, pos: Vector3) -> Walker:
    var w: Walker = mgr._make_walker()
    w.group = group
    w.state = state
    w.radius = mgr.body_radius
    w.node.position = pos
    mgr.walkers.append(w)
    return w

func check(ok: bool) -> void:
    if not ok:
        failed = true
        push_error("check failed")
        print_stack()
