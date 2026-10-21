# 二本の経路: 列の人の間を通り抜ける道と、列の端を回り込む道のうち、コストの小さいほうを通る
# コスト = 道のり + 通り抜ける列ごとの cross_cost（人の間を通るときだけ。人のいない線の部分は 0）
# 1 秒ごとに決め直す。回り込むときは列の端の先の点へ寄ってからゴールへ（端の点は列と一緒に動く）
# 今の道より ROUND_MARGIN 以上安くならないと乗り換えない（列が動くたびに道を替えて行ったり来たりしないように）
# ponytail: 道のりは直線距離で比べる（障害物の迂回は見ない）。回り込む点は1つだけ（S 字の列を何度も回り込む道は作らない）
extends RefCounted

const Sim := preload("res://script/SimulationManager3D.gd")
const Walker := preload("res://script/models/Walker.gd")
const State := Walker.State

const ROUND_MARGIN: float = 1.0    # m。列の端を回り込むときは、先頭・最後尾の人からこれだけ先の点を通る

var sim: Sim
var _spans: Array = []  # 列ごとの人がいる区間（_occupied）

func _init(s: Sim) -> void:
    sim = s

func route(w: Walker, goal: Vector3, delta: float) -> Vector3:
    if not sim.two_routes:
        return goal
    var pos := w.node.position
    var via: Variant = _via_point(w.via)
    if via == null or pos.distance_to(via) < ROUND_MARGIN * 0.5:
        if w.via.x >= 0:
            w.reroute = 0.0  # 回り込んだ（か、列の人が減って端が無くなった）。ここから決め直す
        w.via = Vector2i(-1, 0)
        via = null
    w.reroute -= delta
    if w.reroute <= 0.0:
        w.reroute = 1.0
        var best := _path_cost(pos, via, goal) - ROUND_MARGIN
        for c in [Vector2i(-1, 0)] + _ends():
            var cost := _path_cost(pos, _via_point(c), goal)
            if cost < best:
                best = cost
                w.via = c
        via = _via_point(w.via)
    return via if via != null else goal

func _path_cost(pos: Vector3, via: Variant, goal: Vector3) -> float:
    return leg_cost(pos, via) + leg_cost(via, goal) if via != null else leg_cost(pos, goal)

# 回り込む候補（人が2人以上いる列の、両端）
func _ends() -> Array[Vector2i]:
    var out: Array[Vector2i] = []
    for g in range(sim.groups.size()):
        if not _occupied(g).is_empty():
            out.append_array([Vector2i(g, 0), Vector2i(g, 1)])
    return out

# 回り込む点: 最後尾の後ろ・先頭の前へ ROUND_MARGIN + 左右のぶれ幅。まっすぐ（x = -1）や、2人未満の列なら null
func _via_point(c: Vector2i) -> Variant:
    if c.x < 0 or _occupied(c.x).is_empty():
        return null
    var span: Array = _occupied(c.x)
    var margin := ROUND_MARGIN + sim.groups[c.x].lateral_jitter
    var g := sim.groups[c.x]
    return g.pos(span[0] - margin - g.spacing_max if c.y == 0 else span[1] + margin)

# 列 g の人がいる区間 [最後尾の s, 先頭の s]。2人未満なら空（刻みごとに update_spans で作る）
func _occupied(g: int) -> Array:
    return _spans[g]

func update_spans() -> void:
    _spans.clear()
    for g in range(sim.groups.size()):
        var lo := INF
        var hi := -INF
        var n := 0
        for o in sim.walkers:
            if o.group == g and o.state == State.ON_LINE:
                lo = minf(lo, o.s)
                hi = maxf(hi, o.s)
                n += 1
        _spans.append([lo, hi] if n >= 2 else [])

func leg_cost(a: Vector3, b: Vector3) -> float:
    var cost := a.distance_to(b)
    var a2 := Vector2(a.x, a.z)
    var b2 := Vector2(b.x, b.z)
    for g in range(sim.groups.size()):
        var span := _occupied(g)
        if span.is_empty():
            continue
        # 人がいる区間の中心線を 0.5 m ごとの折れ線にして、列の幅（左右のぶれ + 体の半径）より近くを通るか調べる
        # （交わるかだけを見ると、列の端から中心線に沿って列の中を進む道を見逃す）
        var band := sim.groups[g].lateral_jitter + sim.body_radius
        var prev: Vector3 = sim.groups[g].pos(span[0])
        var s: float = span[0]
        while s < span[1]:
            s = minf(s + 0.5, span[1])
            var p: Vector3 = sim.groups[g].pos(s)
            var pq := Geometry2D.get_closest_points_between_segments(a2, b2, Vector2(prev.x, prev.z), Vector2(p.x, p.z))
            if pq[0].distance_to(pq[1]) < band:
                cost += sim.groups[g].cross_cost
                break
            prev = p
    return cost
