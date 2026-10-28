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
    if dist <= 0.001:
        w.velocity = Vector3.ZERO
        return
    w.heading = to_goal / dist
    if w.direction == Vector3.ZERO:
        w.direction = w.heading
    w.direction = _turn(w, _avoid_direction(w, ignore), delta)
    var v := minf(minf(speed, _free_distance(w, ignore) / sim.time_gap), dist / delta)  # ゴールを通り過ぎない
    w.velocity = w.direction * maxf(v, 0.0)
    w.node.position += w.velocity * delta
    w.node.position.y = 0.0
    sim._face(w, w.direction)

# --- Anticipation Velocity Model（Xu, Chraibi, Seyfried 2021, arXiv:2107.00624）---
# 向き（式1〜7）: 周りの人の t_a 秒後の位置を先読みして横へそれる。速さ（式8〜10）: 進む向きにいる人とのすき間で決める
# 論文との違い: 半径は人ごと（2r → 2人の半径の和）。見る相手は avoid_radius 以内だけ。列の人は体が触れそうなときだけ見る

# 式1〜6: よけたあとの向き（大きさ 1）
func _avoid_direction(w: Walker, ignore: Walker) -> Vector3:
    var e0 := w.heading
    var side := Vector3(-e0.z, 0.0, e0.x)  # e0 に直交する向き
    var pos := w.node.position
    var me_a := pos + w.velocity * sim.anticipation_time
    var ed := e0
    for o in sim.walkers:
        if o == w or o == ignore:
            continue
        var off := o.node.position - pos
        off.y = 0.0
        var d := off.length()
        var r2 := sim.hit_radius(w) + sim.hit_radius(o)
        # 列に並んでいる人は、体が触れそうなときだけよける。列とのやりとりは横切りの決まり（Crossing）で決める
        # （遠くからよけると列が壁になり、横切りを判定する距離まで近づけないまま列に沿って流される。
        #   まったくよけないと、止まった列の人に真正面からぶつかったまま回り込めない）
        var reach := r2 + LINE_CONTACT if o.state == State.ON_LINE else sim.avoid_radius
        if d >= reach or d < 0.0001:
            continue
        var e_ij := off / d
        if w.direction.dot(e_ij) <= 0.0 and e0.dot(e_ij) <= 0.0:  # 式1: 後ろの人は見ない
            continue
        var o_a := o.node.position + o.velocity * sim.anticipation_time
        var s_a := maxf(r2, (o_a - me_a).dot(e_ij))  # 式2: 先読みした2人のすき間
        var alpha := sim.avoid_strength * (1.0 + (1.0 - e0.dot(o.velocity.normalized())) / 2.0)  # 式4: 向かってくる人ほど強く
        var r := alpha * exp((r2 - s_a) / sim.avoid_range)  # 式3
        var lr := (o_a - pos).dot(side)
        if lr == 0.0:  # 式5: 真正面なら左右はランダム
            lr = 1.0 if sim.rng.randf() < 0.5 else -1.0
        ed -= signf(lr) * side * r
    return ed.normalized() if ed.length_squared() > 0.000001 else w.direction

# 式7: 今の向きから、よけたあとの向きへ turn_time かけて向き直る
func _turn(w: Walker, ed: Vector3, delta: float) -> Vector3:
    var e := w.direction + (ed - w.direction) * minf(delta / sim.turn_time, 1.0)
    return e.normalized() if e.length_squared() > 0.000001 else ed

# 式8・9: 進む向きにいる人（体の幅の中）との一番狭いすき間
# 列に並んでいる人は見ない。列とのやりとりは横切りの決まり（Crossing）で決める
# （列の人は線の上を進むので、押し出しで体が触れたままになる。触れた人が前にいると速さ 0 から動けず、
#   その人が道を譲って止まっていると、どちらも動けなくなる）
func _free_distance(w: Walker, ignore: Walker) -> float:
    var pos := w.node.position
    var s := INF
    for o in sim.walkers:
        if o == w or o == ignore or o.state == State.ON_LINE:
            continue
        var off := o.node.position - pos
        off.y = 0.0
        var r2 := w.radius + o.radius
        if w.direction.dot(off) >= 0.0 and absf(w.direction.cross(off).y) <= r2:
            s = minf(s, off.length() - r2)
    return s

# --- 物理的重なりを解決する強力な補正（複数回イテレーション） ---
func resolve_all_overlaps() -> void:
    var walkers := sim.walkers
    # 3回繰り返すことで玉突き事故状のめり込みも解消
    for _iter in range(3):
        for i in range(walkers.size()):
            var w1 = walkers[i]
            for j in range(i + 1, walkers.size()):
                var w2 = walkers[j]
                var min_d = sim.hit_radius(w1) + sim.hit_radius(w2)
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
