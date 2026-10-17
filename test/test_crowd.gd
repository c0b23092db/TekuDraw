# godot --headless --path . --script res://test/test_crowd.gd
# 曲がった列に並びに行く人が、最後尾の後ろにたまらず（団子にならず）並べるか。ウロウロ（その場で行ったり来たり）しないか
# 列の人どうしが重ならないか。誰かが動けなくなって列が止まり続けないか
extends SceneTree

const Mgr := preload("res://script/SimulationManager3D.gd")
const Config := preload("res://script/core/Config.gd")
const State = preload("res://script/models/Walker.gd").State

func _initialize() -> void:
    var values := Config.defaults()
    values["avoid_radius"] = 1.5
    values["avoid_strength"] = 3.0
    values["yield_distance"] = 0.5
    var line := Config.object_defaults(values)
    line["points"] = []
    for i in range(41):  # S 字の列（描画画面の座標）
        var t := i / 40.0
        line["points"].append(Vector2(450 + 500 * t, 400 - 150 * sin(TAU * t)))
    line["pedestrian_count"] = 20
    line["spawn_interval"] = 0.5
    var walker := Config.object_defaults(values)
    walker["points"] = []
    walker["motion"] = "random_walk.gd"
    walker["pedestrian_count"] = 10
    var objects: Array[Dictionary] = [line, walker]

    var mgr: Node3D = Mgr.new()
    for key in values:
        if key in mgr:
            mgr.set(key, values[key])
    mgr.use_simple_model = true
    mgr.random_seed = 42
    mgr.setup_simulation(objects, [] as Array[Rect2])
    var dt := 1.0 / 60.0
    var joining := {}   # 並びに行っている人 → 経過秒数
    var longest := 0.0
    var joined := 0
    var track := {}     # 人 → 0.25 秒ごとの [位置, 状態]
    var overlap := 0.0  # 列の人どうしの一番深い重なり
    var still := {}     # 人 → 動いていない秒数
    var last := {}
    var longest_still := 0.0
    for step in range(60 * 90):
        mgr._physics_process(dt)
        for w in mgr.walkers:
            still[w] = still.get(w, 0.0) + dt if last.has(w) and w.node.position.distance_to(last[w]) < 0.002 else 0.0
            last[w] = w.node.position
            longest_still = maxf(longest_still, still[w])
            if w.state == State.ON_LINE:
                for o in mgr.walkers:
                    if o != w and o.state == State.ON_LINE and o.group == w.group:
                        overlap = maxf(overlap, w.radius + o.radius - w.node.position.distance_to(o.node.position))
            if w.state == State.TO_LINE:
                joining[w] = joining.get(w, 0.0) + dt
                longest = maxf(longest, joining[w])
            elif joining.has(w):
                joined += 1
                joining.erase(w)
            if step % 15 == 0:
                if not track.has(w):
                    track[w] = []
                track[w].append([w.node.position, w.state])
    # ウロウロ: 4 秒で 1.5 m 以上歩いたのに、30% も進んでいない（列に並んでいる間・現れ直した瞬間は除く）
    var wander := 0
    for w in track:
        var h: Array = track[w]
        for i in range(h.size() - 16):
            if h[i][1] == State.ON_LINE or h[i][1] != h[i + 16][1]:
                continue
            var d := 0.0
            var jump := false
            for j in range(i, i + 16):
                var step_len: float = (h[j + 1][0] - h[j][0]).length()
                d += step_len
                jump = jump or step_len > 1.0
            if not jump and d > 1.5 and (h[i + 16][0] - h[i][0]).length() < 0.3 * d and h[i][1] == State.TO_LINE:
                wander += 1
    mgr.free()
    # 並ぶまでの最長には、列を横切るのを待つ時間（max_wait 5 秒）も入る。重なりは列に入った直後に詰めている間の分だけ許す
    var ok := joined >= 30 and longest < 25.0 and wander == 0 and overlap < 0.2 and longest_still < 5.0
    print("test_crowd: ", "OK" if ok else "FAIL", "（並んだ回数 %d、並ぶまで最長 %.1f 秒、ウロウロ %d、列の重なり %.2f m、止まったまま最長 %.1f 秒）" % [joined, longest, wander, overlap, longest_still])
    quit(0 if ok else 1)
