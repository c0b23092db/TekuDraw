# 列に並んでいない人の一刻みの移動: 障害物の迂回と、ほかの人をよける動き。移動したあとの重なりの押し出し
extends RefCounted

const Sim := preload("res://script/SimulationManager3D.gd")
const Geometry := preload("res://script/utils/Geometry.gd")
const Walker := preload("res://script/models/Walker.gd")
const State := Walker.State

const LINE_CONTACT: float = 0.3     # m。列に並んでいない人は、列の人とのすき間がこれより狭いときだけよける

var sim: Sim

func _init(s: Sim) -> void:
    sim = s

# w を goal へ speed で一刻み進める。ignore はよけない人（並びに行く先の最後尾）
func steer(w: Walker, goal: Vector3, speed: float, delta: float, ignore: Walker) -> void:
    var pos := w.node.position
    # 障害物で塞がれていたら、経路のうち見通せる一番先の点へ。経路はゴールが動くので 1 秒ごとに引き直す
    var from := Vector2(pos.x, pos.z)
    var wp := Vector2(goal.x, goal.z)
    var clearance := w.radius * 0.9  # 押し出し直後の壁ぎわでも見通せるよう少し小さめ
    if Geometry.segment_clear(from, wp, sim.obstacle_rects, clearance):
        w.replan = 0.0
    else:
        w.replan -= delta
        if w.replan <= 0.0:
            w.path = Geometry.find_path(sim.nav_grid, from, wp, sim.obstacle_rects, clearance)
            w.replan = 1.0
        wp = Geometry.farthest_visible(from, w.path, sim.obstacle_rects, clearance)
    var to_goal := Vector3(wp.x, 0.0, wp.y) - pos
    to_goal.y = 0.0
    var dist := to_goal.length()
    var desired := Vector3.ZERO
    if dist > 0.001:
        w.heading = to_goal / dist
        desired = w.heading * speed

    var avoid := Vector3.ZERO
    for o in sim.walkers:
        if o == w or o == ignore:
            continue
        # 列に並んでいる人は、体が触れそうなときだけよける。列とのやりとりは横切りの決まり（Crossing）で決める
        # （遠くからよけると列が壁になり、横切りを判定する距離まで近づけないまま列に沿って流される。
        #   まったくよけないと、止まった列の人に真正面からぶつかったまま回り込めない）
        var reach := w.radius + o.radius + LINE_CONTACT if o.state == State.ON_LINE else sim.avoid_radius
        var off := pos - o.node.position
        off.y = 0.0
        var d := off.length()
        if d >= reach or d < 0.0001:
            continue

        var away := off / d
        var weight := pow(1.0 - d / reach, 2.0) # 近いほど急激に回避力を高める
        var tangent := Vector3(-away.z, 0.0, away.x)
        avoid += (away + tangent * 0.8) * weight

    desired += avoid * speed * sim.avoid_strength
    if desired.length() > speed:
        desired = desired.normalized() * speed

    w.velocity = w.velocity.lerp(desired, 1.0 - exp(-10.0 * delta))
    w.node.position += w.velocity * delta
    w.node.position.y = 0.0
    sim._face(w, w.velocity)

# --- 物理的重なりを解決する強力な補正（複数回イテレーション） ---
func resolve_all_overlaps() -> void:
    var walkers := sim.walkers
    # 3回繰り返すことで玉突き事故状のめり込みも解消
    for _iter in range(3):
        for i in range(walkers.size()):
            var w1 = walkers[i]
            for j in range(i + 1, walkers.size()):
                var w2 = walkers[j]
                var min_d = w1.radius + w2.radius
                var off = w1.node.position - w2.node.position
                off.y = 0.0
                var d = off.length()
                if d < min_d:
                    var push_dir = off.normalized() if d > 0.0001 else Vector3.RIGHT
                    var overlap = min_d - d

                    # どちらが動くべきか判定
                    if w1.state == State.ON_LINE and w2.state == State.ON_LINE:
                        # 両者列上の場合は前後関係を保つのみ
                        continue
                    elif w1.state == State.ON_LINE:
                        w2.node.position -= push_dir * overlap
                    elif w2.state == State.ON_LINE:
                        w1.node.position += push_dir * overlap
                    else:
                        # 自由歩行同士なら双方半々に押し出す
                        w1.node.position += push_dir * (overlap * 0.5)
                        w2.node.position -= push_dir * (overlap * 0.5)

    # 自由歩行者を障害物の外へ
    for w in walkers:
        if w.state != State.ON_LINE:
            w.node.position = Geometry.push_out_of_rects(w.node.position, w.radius, sim.obstacle_rects)
