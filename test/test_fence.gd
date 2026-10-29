# godot --headless --path . --script res://test/test_fence.gd
# 列を邪魔しない: 規制線（柵を回り込み、列の人は止まらない）と、列の人の当たり判定の太さ
extends SceneTree

const Mgr := preload("res://script/SimulationManager3D.gd")
const Config := preload("res://script/core/Config.gd")
const Walker := preload("res://script/models/Walker.gd")
const Motion := preload("res://script/core/Motion.gd")
const State = Walker.State

var failed := false

func _initialize() -> void:
    # 横一直線の列（x = -8 〜 8 m、z = 0）に規制線。列の手前（z = -3）から向こう（z = 3）へ歩く人が1人
    var values := Config.defaults()
    var line := Config.object_defaults(values)
    line["points"] = [Vector2(320, 360), Vector2(960, 360)]
    line["pedestrian_count"] = 0
    line["fence"] = true
    line["line_speed"] = 0.3
    var walker := Config.object_defaults(values)
    walker["points"] = []
    walker["spawn_points"] = [Vector2(640, 240)]
    walker["motion"] = "random_walk.gd"
    walker["pedestrian_count"] = 1
    var mgr: Node3D = Mgr.new()
    for key in values:
        if key in mgr:
            mgr.set(key, values[key])
    mgr.use_simple_model = true
    mgr.random_seed = 7
    mgr.setup_simulation([line, walker] as Array[Dictionary], [] as Array[Rect2])
    check(mgr.obstacle_rects.size() > 100)  # 16 m の両側に 0.2 m ごと

    var goal := "extends RefCounted
func step(me, world, rng, delta):
	return {\"goal\": Vector3(0, 0, 3)}
"
    mgr.groups[1].script_obj = Motion.compile(goal, "goal.gd").new()
    for i in range(10):
        var m := _add(mgr, 0, State.ON_LINE, Vector3(-4.0 + i * 0.9, 0, 0))
        m.s = 4.0 + i * 0.9
        m.cross_priority = 0.0
        m.line_priority = 0.0  # 柵が無ければ、横切る人に必ず道を譲る
    var w: Walker = mgr.walkers[0]
    w.cross_priority = 1.0
    # 柵の内側（列の線から柵まで）へ入らず回り込んで着く。列の人は一度も止まらない
    var inner: float = mgr.groups[0].lateral_jitter + mgr.body_radius
    var yielded := false
    for _i in range(1800):
        mgr._physics_process(1.0 / 60.0)
        var p := w.node.position
        check(not (absf(p.x) < 7.5 and absf(p.z) < inner))
        for m in mgr.walkers:
            if m.state == State.ON_LINE and mgr.crossing.line_must_yield(m):
                yielded = true
    check(not yielded)
    check(w.node.position.distance_to(Vector3(0, 0, 3)) < 0.5)

    # 規制線は列の線の左右だけ（始点・終点は開いている）
    var off: float = inner + Mgr.FENCE_SIZE
    var side := 0
    for r in mgr.obstacle_rects:
        if absf(absf(r.get_center().y) - off) < 0.01:
            side += 1
    check(side == 160 and mgr.obstacle_rects.size() == 160)  # 16 m の両側に 0.2 m ごと

    # 規制線の外の入口の脇からは列に入らない。入口の後ろからは入る
    for m in mgr.walkers.duplicate():
        if m != w:
            mgr.walkers.erase(m)
            m.node.free()
    var tail := _add(mgr, 0, State.ON_LINE, Vector3(-6, 0, 0))
    tail.s = 2.0  # 最後尾は始点から離れている
    var j := _add(mgr, 0, State.TO_LINE, Vector3(-7.6, 0, -0.8))
    mgr._update_joiner(j, 1.0 / 60.0)
    check(j.state == State.TO_LINE)
    j.node.position = Vector3(-8.5, 0, 0)
    mgr._update_joiner(j, 1.0 / 60.0)
    check(j.state == State.ON_LINE)

    # 当たり判定の太さ: 列の人と重なった人は、半径の和 + line_margin まで押し出される
    mgr.groups[0].line_margin = 0.5
    var a := tail
    w.node.position = a.node.position + Vector3(0, 0, 0.3)
    mgr.steering.resolve_all_overlaps()
    check(w.node.position.distance_to(a.node.position) >= w.radius + a.radius + 0.5 - 0.001)
    mgr.free()

    print("test_fence: ", "FAIL" if failed else "OK")
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
