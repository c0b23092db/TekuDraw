# godot --headless --path . --script res://test/test_avoidance.gd
# 先読みしてよけるか（AVM）: 正面から向かい合う2人が、ぶつかる前によけ始め、重ならずにすれ違ってそれぞれの目的地に着くか
# 先読みをやめる（anticipation_time = 0）と、よけ始めるのが遅くなるか
extends SceneTree

const Mgr := preload("res://script/SimulationManager3D.gd")
const Config := preload("res://script/core/Config.gd")
const Motion := preload("res://script/core/Motion.gd")

# memory["goal"] へまっすぐ歩くだけの動き
const GO := "extends RefCounted
func step(me, world, rng, delta):
	return {\"goal\": me.memory[\"goal\"]}
"

func _initialize() -> void:
    var a := run(1.0)
    var b := run(0.0)
    var ok: bool = a["min_gap"] > -0.02 and a["arrived"] and a["swerve_gap"] > 1.0 and b["swerve_gap"] < a["swerve_gap"]
    print("test_avoidance: ", "OK" if ok else "FAIL", "（よけ始めたときのすき間 %.2f m、先読みなし %.2f m、一番近いとき %.2f m）" % [a["swerve_gap"], b["swerve_gap"], a["min_gap"]])
    quit(0 if ok else 1)

# x = -5 と x = 5 から向かい合って歩く。少しだけ z をずらす（真正面だと左右はランダムで決まる）
func run(ta: float) -> Dictionary:
    var values := Config.defaults()
    values["anticipation_time"] = ta
    var obj := Config.object_defaults(values)
    obj["points"] = []
    obj["motion"] = "go.gd"
    obj["pedestrian_count"] = 2
    var mgr: Node3D = Mgr.new()
    for key in values:
        if key in mgr:
            mgr.set(key, values[key])
    mgr.use_simple_model = true
    mgr.random_seed = 1
    mgr.setup_simulation([obj] as Array[Dictionary], [] as Array[Rect2], {"go.gd": GO})
    var p: Array = mgr.walkers
    for i in range(2):
        var x := -5.0 if i == 0 else 5.0
        p[i].node.position = Vector3(x, 0, 0.02 * (1 - 2 * i))
        p[i].memory["goal"] = Vector3(-x, 0, 0)
        p[i].speed = 1.4
    var min_gap := INF
    var swerve_gap := -1.0  # どちらかが目的地の向きから 5 度以上それたときのすき間
    for _i in range(600):
        mgr._physics_process(1.0 / 60.0)
        var gap: float = p[0].node.position.distance_to(p[1].node.position) - p[0].radius - p[1].radius
        min_gap = minf(min_gap, gap)
        if swerve_gap < 0.0 and p[0].node.position.x < p[1].node.position.x:
            for w in p:
                if w.direction.angle_to(w.heading) > deg_to_rad(5.0):
                    swerve_gap = gap
    var arrived: bool = p[0].node.position.distance_to(Vector3(5, 0, 0)) < 0.3 and p[1].node.position.distance_to(Vector3(-5, 0, 0)) < 0.3
    mgr.free()
    return {"min_gap": min_gap, "swerve_gap": swerve_gap, "arrived": arrived}
