# 歩いては立ち止まる: 目的地へ歩く途中で、ときどき数秒立ち止まる（スマホを見る・待ち合わせ など）。着いたら消えて出現地から現れ直す
# 書き方は同じフォルダの README.md
extends RefCounted

const LABEL := "歩いては立ち止まる"
const FIELDS := [
    {"key": "walk_min", "label": "立ち止まるまで歩く時間（最小）", "default": 3.0, "min": 0.1, "max": 600.0, "step": 0.5, "suffix": "秒"},
    {"key": "walk_max", "label": "立ち止まるまで歩く時間（最大）", "default": 10.0, "min": 0.1, "max": 600.0, "step": 0.5, "suffix": "秒"},
    {"key": "stop_min", "label": "立ち止まる時間（最小）", "default": 1.0, "min": 0.0, "max": 600.0, "step": 0.5, "suffix": "秒"},
    {"key": "stop_max", "label": "立ち止まる時間（最大）", "default": 5.0, "min": 0.0, "max": 600.0, "step": 0.5, "suffix": "秒"},
    {"key": "line_clear", "label": "立ち止まらない列からの距離", "default": 1.5, "min": 0.0, "max": 10.0, "step": 0.1, "suffix": "m", "hint": "列の線からこれより近い所では立ち止まらず、離れるまで歩き続ける（列の人の通り道で止まると、列が止まったままになる）"},
    {"key": "goal_min_distance", "label": "目的地までの最短距離", "default": 4.0, "min": 0.0, "max": 100.0, "step": 0.5, "suffix": "m", "hint": "今いる所からこれより近い所は目的地にしない"},
    {"key": "arrive_radius", "label": "着いたとみなす距離", "default": 0.3, "min": 0.05, "max": 5.0, "step": 0.05, "suffix": "m"},
]

func step(me, world, rng: RandomNumberGenerator, delta: float) -> Dictionary:
    # 現れた直後に目的地と、最初に立ち止まるまでの時間を決める
    if not me.memory.has("goal"):
        var goal: Vector3 = world.random_goal(me, rng)
        for i in range(10):
            if goal.distance_to(me.position) >= me.param["goal_min_distance"] and world.reachable(me.position, goal):
                break
            goal = world.random_goal(me, rng)
        me.memory["goal"] = goal
        me.memory["walk"] = _between(rng, me.param["walk_min"], me.param["walk_max"])
        me.memory["stop"] = 0.0

    if me.position.distance_to(me.memory["goal"]) <= me.param["arrive_radius"]:
        return {"respawn": true}

    # 立ち止まっている間は、目的地のほうを向いたまま速さ 0
    if me.memory["stop"] > 0.0:
        me.memory["stop"] -= delta
        if me.memory["stop"] <= 0.0:
            me.memory["walk"] = _between(rng, me.param["walk_min"], me.param["walk_max"])
        return {"goal": me.memory["goal"], "speed": 0.0}

    # 歩く時間が過ぎたら立ち止まる。列のそばなら、離れるまで歩き続ける
    me.memory["walk"] -= delta
    if me.memory["walk"] <= 0.0 and not _near_line(me, world):
        me.memory["stop"] = _between(rng, me.param["stop_min"], me.param["stop_max"])
    return {"goal": me.memory["goal"], "speed": me.speed}

# 列の中心線から line_clear より近いか
func _near_line(me, world) -> bool:
    var p := Vector2(me.position.x, me.position.z)
    for line in world.lines():
        var pts: Array = line["points"]
        for i in range(pts.size() - 1):
            var a := Vector2(pts[i].x, pts[i].z)
            var b := Vector2(pts[i + 1].x, pts[i + 1].z)
            if p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)) < me.param["line_clear"]:
                return true
    return false

# 最小と最大を逆に設定されても動くように
func _between(rng: RandomNumberGenerator, a: float, b: float) -> float:
    return rng.randf_range(minf(a, b), maxf(a, b))
