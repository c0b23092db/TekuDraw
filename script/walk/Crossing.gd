# 列を横切るときの決まり: 列の人 w と、列に並んでいない人 o（ランダムに歩く人・並びに行く人）の位置関係と、どちらが先に通るか
# 並びに行く人も、列の向こう側の最後尾へ向かうときは列を横切る（一直線に突っ込むと、押し返されてその場で揺れ続ける）
extends RefCounted

const Sim := preload("res://script/SimulationManager3D.gd")
const Walker := preload("res://script/models/Walker.gd")
const Group := preload("res://script/models/Group.gd")
const State := Walker.State

# 長さの単位は m
const LOOK_AHEAD: float = 0.15      # 列の進む向きを、この距離だけ先の点で見る
const CROSS_NEAR: float = 1.0       # 横切る人は、列の人とのすき間が yield_distance + これより狭くなると遅くなり始める（待ち始めたら、これより広がるまで待つ）
const AIM_DISTANCE: float = 6.0     # 列までこれより近づいたら、すき間を狙う
const AIM_SIDE: float = 3.0         # すき間を探す範囲（まっすぐ横切る所から左右へ）
const AIM_STEP: float = 0.1         # すき間を探す刻み
const AIM_ENOUGH: float = 1.5       # すき間（体どうし）がこれだけあれば十分。それより広い所を探して遠回りしない
const AIM_DETOUR: float = 0.3       # 横へ 1 m ずれるごとに、すき間をこれだけ狭いと見なす（近いすき間を選ぶ）
const AIM_PAST: float = 0.3         # 狙う点は、列の幅（左右のぶれ + 体の半径）からさらにこれだけ向こう

var sim: Sim

func _init(s: Sim) -> void:
    sim = s

# 列の人 w の進む向き（中心線の向き。自分の位置から中心線の先の点へ向けると、左右にずれた人ほど横を向いてしまう）
func line_dir(w: Walker) -> Vector3:
    var line := sim.groups[w.group]
    return (line.pos(w.s + LOOK_AHEAD) - line.pos(w.s)).normalized()

# 体どうしのすき間（中心の距離だと、半径の合計より短い値では体が重なるまで気づかない）
func gap(w: Walker, o: Walker) -> float:
    return w.node.position.distance_to(o.node.position) - sim.hit_radius(w) - sim.hit_radius(o)

# o が w の前方にいるか。in_path なら、w の通り道（w と o の体の幅）の中にいるときだけ
func ahead(w: Walker, o: Walker, in_path: bool = false) -> bool:
    var my_dir := line_dir(w)
    var to_other := o.node.position - w.node.position
    to_other.y = 0.0
    return my_dir.dot(to_other) > 0.0 and (not in_path or absf(my_dir.cross(to_other).y) < w.radius + o.radius)

# o が w の前方を横切ろうとしているか（進む向きがほぼ直交している。すき間が reach より狭いときだけ）
# 自分より前を歩く列の人は止まらない。止まった人の前にすき間ができ、横切る人はそこを通れる
func is_crossing(w: Walker, o: Walker, reach: float) -> bool:
    if o.state == State.ON_LINE or o.heading == Vector3.ZERO or gap(w, o) >= reach:
        return false
    var my_dir := line_dir(w)
    return absf(my_dir.dot(o.heading)) < 0.7 and ahead(w, o)

# o が列の人 w の中心線を越えて、向かう側にいるか（列から離れていくところ）
func _past(w: Walker, o: Walker) -> bool:
    var n := line_dir(w).cross(Vector3.UP)
    return (o.node.position - w.node.position).dot(n) * o.heading.dot(n) > 0.0

# 優先度の高いほうが先に通る。同じなら列の人が先。待てる時間を過ぎた人は必ず先に通る
func cross_value(o: Walker) -> float:
    return INF if o.waited >= sim.groups[o.group].max_wait else o.cross_priority

# 列の人が止まるか: 優先度の高い人が前を横切るとき
# ponytail: 通り道にいる人のためにも止まると、横切る人が何人も集まった所で列が止まり、すき間が詰まって誰も抜けられなくなる。
#           通り道の中の人は止まらずに渡りきるので（crosser_speed）、ぶつかっても押されるのは一瞬
func line_must_yield(w: Walker) -> bool:
    if sim.groups[w.group].fence:  # 規制線の列は誰も横切らない（柵のそばを回り込む人のために止まらない）
        return false
    for o in sim.walkers:
        if cross_value(o) > w.line_priority and is_crossing(w, o, sim.yield_distance):
            return true
    return false

# 横切る人の速さの倍率（0〜1）。先を譲る列の人が近づいてくるときは、すき間が yield_distance + CROSS_NEAR から近づくほど遅くし、
# yield_distance で止まる（全速で近づいていきなり止まると「一瞬止まる」。ゆっくり近づく間に列の人が通り過ぎれば止まらずに済む）
# 待つのは列の人の通り道の外だけ。もう通り道の中にいたら止まらずに渡りきる（通り道で止まると、近づく列の人にぶつかる）
# 横切ろうとして列のそばにいる間は waited を数える（先に通っている間も数え続け、列から離れたら 0 に戻す）
# 向き合っている間だけ数えると、列の人と人のすき間が来るたびに 0 に戻り、待てる時間を過ぎることがない
func crosser_speed(o: Walker, delta: float) -> float:
    var reach := sim.yield_distance + CROSS_NEAR
    var near := false
    var k := 1.0
    for w in sim.walkers:
        if w.state != State.ON_LINE or sim.groups[w.group].fence:
            continue
        var g := gap(w, o)
        if g >= reach:
            continue
        var crossing := is_crossing(w, o, reach)
        near = near or crossing or o.waited > 0.0
        if _past(w, o):  # もう列の向こう側。止まると列の端に立ちふさがり、同じすき間を狙う後ろの人が通れない
            continue
        # 待ち始めた人は、前を横切る向きでなくても、近づいてくる人を待つ（小さなすき間へ踏み出しては止まるのをくり返さない）
        if (crossing or (o.waited > 0.0 and ahead(w, o))) and cross_value(o) <= w.line_priority and not ahead(w, o, true):
            k = minf(k, clampf((g - sim.yield_distance) / CROSS_NEAR, 0.0, 1.0))
    o.waited = o.waited + delta if near else 0.0
    return k

# --- すき間を狙う: 列を横切る前に、着くころの列の人の位置を先読みして、すき間の空く所へ向かう ---
# goal へまっすぐ向かうと人の列にぶつかるとき、列の向こう側の、すき間の真ん中を抜ける点を返す（ぶつからなければ goal のまま）
# 候補は「着くまでに横へ動ける距離」の範囲を AIM_STEP ごとに見て、すき間（AIM_ENOUGH まで）が広く、まっすぐの所から近い所を選ぶ
# 毎刻み選び直す（すき間は列と一緒に動くので、狙う点もそれについて動く）
# ponytail: 列の人は今の速さのまま進むと見なす（止まる・詰まるは先読みしない）。見るのは一番近くで交わる列の1本だけ
func aim(w: Walker, goal: Vector3) -> Vector3:
    var pos := w.node.position
    var best_t := INF
    var cross: Array = []  # [列の添字, 交わる点の s]
    for g in range(sim.groups.size()):
        var line := sim.groups[g]
        if not line.join_line or line.fence or (g == w.group and w.state == State.TO_LINE):  # 並びに行く列は横切らない（行き先が列の上）。規制線の列は経路探索で回り込む
            continue
        var hit: Variant = _crossing_point(line, pos, goal)
        if hit != null and pos.distance_to(line.pos(hit)) < best_t:
            best_t = pos.distance_to(line.pos(hit))
            cross = [g, hit]
    if cross.is_empty() or best_t > AIM_DISTANCE:
        return goal
    var line := sim.groups[cross[0]]
    var band := line.lateral_jitter + w.radius + AIM_PAST
    if best_t < band:  # もう列の幅の中。止まらずに渡りきる
        return goal
    var t := best_t / maxf(w.speed, 0.1)  # 列に着くまでの秒数
    var ahead_s: Array[float] = []  # 着くころの列の人の位置 s と半径
    var radii: Array[float] = []
    for o in sim.walkers:
        if o.group == cross[0] and o.state == State.ON_LINE:
            ahead_s.append(o.s + o.velocity.length() * t)
            radii.append(sim.hit_radius(o))
    if ahead_s.is_empty():
        return goal
    var reach := minf(AIM_SIDE, w.speed * t * 0.7)  # 着くまでに横へ動ける距離（前へも進むので 7 割）
    var best_s: float = cross[1]
    var best_score := -INF
    var s: float = cross[1] - reach
    while s <= cross[1] + reach:
        var clear := INF
        for i in range(ahead_s.size()):
            clear = minf(clear, absf(s - ahead_s[i]) - w.radius - radii[i])
        var score := minf(clear, AIM_ENOUGH) - AIM_DETOUR * absf(s - cross[1])
        if score > best_score:
            best_score = score
            best_s = s
        s += AIM_STEP
    # すき間の点から、列の向こう側（goal の側）へ列の幅だけ出た点
    var p := line.pos(best_s)
    var d := line.pos(best_s + LOOK_AHEAD) - p
    var n := d.cross(Vector3.UP).normalized()
    if n.dot(goal - p) < 0.0:
        n = -n
    return p + n * band

# pos から goal へまっすぐ進むと列の線と交わるか。交われば一番近い点の s、交わらなければ null
func _crossing_point(line: Group, pos: Vector3, goal: Vector3) -> Variant:
    var a := Vector2(pos.x, pos.z)
    var b := Vector2(goal.x, goal.z)
    var best: Variant = null
    var best_d := INF
    for i in range(line.points.size() - 1):
        var p: Vector3 = line.points[i]
        var q: Vector3 = line.points[i + 1]
        var hit: Variant = Geometry2D.segment_intersects_segment(a, b, Vector2(p.x, p.z), Vector2(q.x, q.z))
        if hit != null and a.distance_to(hit) < best_d:
            best_d = a.distance_to(hit)
            best = line.curve.get_closest_offset(Vector3(hit.x, 0.0, hit.y))
    return best

# 横切るのを待って遅くなっている間は、向きを変えずにまっすぐ止まる
# （動いている最後尾へ向き直りながらゆっくり進むと、その場で行ったり来たりして見える）
func wait_goal(w: Walker, goal: Vector3, k: float) -> Vector3:
    return goal if k >= 1.0 or w.heading == Vector3.ZERO else w.node.position + w.heading
