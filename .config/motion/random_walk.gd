# ランダムに歩く: 目的地を選んで歩き、着いたら消えて出現地から現れ直す
# 書き方は同じフォルダの README.md
extends RefCounted

const LABEL := "ランダムに歩く"
const FIELDS := [
    {"key": "goal_min_distance", "label": "目的地までの最短距離", "default": 4.0, "min": 0.0, "max": 100.0, "step": 0.5, "suffix": "m", "hint": "今いる所からこれより近い所は目的地にしない"},
    {"key": "arrive_radius", "label": "着いたとみなす距離", "default": 0.3, "min": 0.05, "max": 5.0, "step": 0.05, "suffix": "m"},
]

func step(me, world, rng: RandomNumberGenerator, delta: float) -> Dictionary:
    # 現れた直後に目的地を決める（目的地の線があればその上。障害物に囲まれていない所を 10 回まで探す）
    if not me.memory.has("goal"):
        var goal: Vector3 = world.random_goal(me, rng)
        for i in range(10):
            if goal.distance_to(me.position) >= me.param["goal_min_distance"] and world.reachable(me.position, goal):
                break
            goal = world.random_goal(me, rng)
        me.memory["goal"] = goal

    if me.position.distance_to(me.memory["goal"]) <= me.param["arrive_radius"]:
        return {"respawn": true}
    return {"goal": me.memory["goal"], "speed": me.speed}
