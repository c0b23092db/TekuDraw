# godot --headless --path . --script res://test/test_soak.gd
# 今の設定（./.config）のまま 10 分動かす。列に並びに行く人が固まらないか（STILL_TIME 秒で STILL_MOVE も動けない）
# シードは引数で変えられる: ... --script res://test/test_soak.gd -- 3
extends SceneTree

const Mgr := preload("res://script/SimulationManager3D.gd")
const Config := preload("res://script/core/Config.gd")
const SceneStore := preload("res://script/core/SceneStore.gd")
const State = preload("res://script/models/Walker.gd").State

const DT := 1.0 / 60.0
const STILL_TIME := 20.0
const STILL_MOVE := 0.5

func _initialize() -> void:
    var values := Config.load_values()
    var mgr: Node3D = Mgr.new()
    for key in values:
        if key in mgr:
            mgr.set(key, values[key])
    mgr.use_simple_model = true
    mgr.json_interval = 0.0
    var args := OS.get_cmdline_user_args()
    mgr.random_seed = int(args[0]) if args.size() > 0 else 1
    mgr.setup_simulation(SceneStore.load_objects(), SceneStore.load_obstacles())

    var at := {}     # 人 → [基準の位置, 動けていない秒数]
    var frozen := 0
    var worst := 0.0
    for step in range(int(600.0 / DT)):
        mgr._physics_process(DT)
        for w in mgr.walkers:
            if w.state != State.TO_LINE or not at.has(w) or w.node.position.distance_to(at[w][0]) > STILL_MOVE:
                at[w] = [w.node.position, 0.0]
                continue
            at[w][1] += DT
            worst = maxf(worst, at[w][1])
            if is_equal_approx(at[w][1], STILL_TIME):
                frozen += 1
                var tail = mgr._get_tail(w.group)
                print("固まった t=%.0f id=%d pos=%s 最後尾=%s s=%s" % [mgr.elapsed, w.id, w.node.position, tail.node.position if tail else null, tail.s if tail else null])
    mgr.free()
    print("test_soak: ", "OK" if frozen == 0 else "FAIL", "（固まった回数 %d、動けない最長 %.1f 秒）" % [frozen, worst])
    quit(0 if frozen == 0 else 1)
