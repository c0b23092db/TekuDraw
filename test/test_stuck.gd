# godot --headless --path . --script res://test/test_stuck.gd
# 動けなくなったら寄り道する: 当たり判定の太い止まった列（壁）に真正面からぶつかった人は、列の端を回り込んで着く
extends SceneTree

const Mgr := preload("res://script/SimulationManager3D.gd")
const Config := preload("res://script/core/Config.gd")
const Walker := preload("res://script/models/Walker.gd")
const Motion := preload("res://script/core/Motion.gd")
const State = Walker.State

var failed := false

func _initialize() -> void:
    # 横一直線の列（x = -8 〜 8 m、z = 0）。規制線をくぐる人が列の手前（z = -3）から向こう（z = 3）へ
    var values := Config.defaults()
    var line := Config.object_defaults(values)
    line["points"] = [Vector2(320, 360), Vector2(960, 360)]
    line["pedestrian_count"] = 0
    line["fence"] = true
    line["line_margin"] = 1.0
    line["line_speed"] = 0.0  # 止まった列
    var walker := Config.object_defaults(values)
    walker["points"] = []
    walker["spawn_points"] = [Vector2(640, 240)]
    walker["motion"] = "random_walk.gd"
    walker["pedestrian_count"] = 1
    walker["cross_fence"] = true
    var mgr: Node3D = Mgr.new()
    for key in values:
        if key in mgr:
            mgr.set(key, values[key])
    mgr.use_simple_model = true
    mgr.random_seed = 7
    mgr.setup_simulation([line, walker] as Array[Dictionary], [] as Array[Rect2])
    var src := "extends RefCounted
func step(me, world, rng, delta):
	return {\"goal\": Vector3(0, 0, 3), \"speed\": me.memory.get(\"speed\", me.speed)}
"
    mgr.groups[1].script_obj = Motion.compile(src, "goal.gd").new()
    # x = -3 〜 3 m に 0.9 m おき。当たり判定の円（半径 1.2 m）が重なり、人の間は抜けられない
    for i in range(7):
        var m := _add(mgr, 0, State.ON_LINE, Vector3(-2.7 + i * 0.9, 0, 0))
        m.s = 5.3 + i * 0.9
    var w: Walker = mgr.walkers[0]
    w.node.position = Vector3(0, 0, -3)

    # わざと立ち止まっている間（speed 0）は寄り道しない
    w.memory["speed"] = 0.0
    for _i in range(600):
        mgr._physics_process(1.0 / 60.0)
    check(w.detour_time == 0.0)
    w.memory.erase("speed")

    var arrived := false
    for _i in range(60 * 40):
        mgr._physics_process(1.0 / 60.0)
        if w.node.position.distance_to(Vector3(0, 0, 3)) < 0.5:
            arrived = true
            break
    check(arrived)
    mgr.free()

    print("test_stuck: ", "FAIL" if failed else "OK")
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
