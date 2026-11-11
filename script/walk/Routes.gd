# 二本の経路: 列の人の間を通り抜ける道と、列の端を回り込む道のうち、コストの小さいほうを通る
# コスト = 道のり + 通り抜ける列ごとの cross_cost（人の間を通るときだけ。人のいない線の部分は 0）
# 1 秒ごとに決め直す。回り込むときは列の端の先の点へ寄ってからゴールへ（端の点は列と一緒に動く）
# 今の道より ROUND_MARGIN 以上安くならないと乗り換えない（列が動くたびに道を替えて行ったり来たりしないように）
# ponytail: 道のりは直線距離で比べる（障害物の迂回は見ない）。回り込む点は1つだけ（S 字の列を何度も回り込む道は作らない）
extends RefCounted

const Sim := preload("res://script/SimulationManager3D.gd")
const Walker := preload("res://script/models/Walker.gd")
const Geometry := preload("res://script/utils/Geometry.gd")
const State := Walker.State

const ROUND_MARGIN: float = 1.0    # m。列の端を回り込むときは、先頭・最後尾の人からこれだけ先の点を通る
# 動けなくなったときの寄り道（watch_stuck）
const STUCK_MOVE: float = 0.5      # m。歩こうとしているのに、STUCK_TIME 秒でこれだけも動けなければ動けないと見なす
const STUCK_TIME: float = 5.0      # 秒。横切るのを待てる時間（max_wait）を過ぎても動けないときだけ寄り道するよう、それより長め
const DETOUR_TIME: float = 15.0    # 秒。寄り道の道を通るのはこの時間まで（着けなくても元の道へ戻る）
const SQUEEZE_TIME: float = 5.0    # 秒。列の人の間をすり抜けるのはこの時間（列の太さの外へ出てから数える）

var sim: Sim
var _spans: Array = []  # 列ごとの人がいる区間（_occupied）

func _init(s: Sim) -> void:
    sim = s

func route(w: Walker, goal: Vector3, delta: float) -> Vector3:
    var pos := w.node.position
    if w.detour_time > 0.0:
        w.detour_time -= delta
        while not w.detour.is_empty() and Vector2(pos.x, pos.z).distance_to(w.detour[0]) < ROUND_MARGIN * 0.5:
            w.detour.remove_at(0)
        if not w.detour.is_empty():
            return Vector3(w.detour[0].x, 0.0, w.detour[0].y)
        w.detour_time = 0.0
    if not sim.two_routes:
        return goal
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

# 歩こうとしているのに STUCK_TIME 秒たっても STUCK_MOVE 動けなければ、寄り道の点を決める（moving: 歩こうとしているか）
# 列の人と向かい合ったまま動けないとき（列の当たり判定 line_margin が太いと、止まった列は人の間を抜けられない壁になる）など
# 寄り道の道がゴールに届かないか、寄り道しても動けなければ、列の人の間をすり抜ける（squeeze）
func watch_stuck(w: Walker, goal: Vector3, moving: bool, delta: float) -> void:
    # 列の人の太さの内側にいる間はすり抜けを終えない（終えると押し出しで一気に飛ぶ）
    if w.squeeze > 0.0 and sim.walkers.all(func(o: Walker) -> bool: return o.state != State.ON_LINE or sim.crossing.gap(o, w) >= 0.0):
        w.squeeze = maxf(w.squeeze - delta, 0.0)
    if not moving or w.node.position.distance_to(w.stuck_at) > STUCK_MOVE:
        w.stuck_at = w.node.position
        w.stuck_time = 0.0
        return
    w.stuck_time += delta
    if w.stuck_time < STUCK_TIME:
        return
    w.stuck_time = 0.0
    var path := _detour(w, goal)
    # 道がゴールに届かない（ゴールが列の太さの中にある・列に囲まれている）か、寄り道の途中でまた動けなくなった
    if path.is_empty() or path[-1] != Vector2(goal.x, goal.z) or w.detour_time > 0.0:
        w.squeeze = SQUEEZE_TIME
        w.detour.clear()
        w.detour_time = 0.0
    else:
        w.detour = path
        w.detour_time = DETOUR_TIME

# 寄り道の道: 今いるほかの人（列の人は当たり判定の太さで）も障害物と見なして、ゴールまでの経路を探す
# 止まった列が壁になっていれば、その端を回り込む道になる（U 字の列でも）
# shortcut: ほかの人は今の位置で止まっていると見なす（動く人は先読みしない）。人を正方形で塗るので、斜めのすき間は実際より狭く見る
func _detour(w: Walker, goal: Vector3) -> PackedVector2Array:
    var rects: Array[Rect2] = sim.rects_for(w).duplicate()
    for o in sim.walkers:
        if o != w:
            var r := sim.hit_radius(o)
            rects.append(Rect2(o.node.position.x - r, o.node.position.z - r, r * 2.0, r * 2.0))
    var grid := Geometry.make_grid(rects, Vector2(sim.spawn_half_x, sim.spawn_half_z), w.radius)
    return Geometry.find_path(grid, Vector2(w.node.position.x, w.node.position.z), Vector2(goal.x, goal.z), rects, w.radius)

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
        # 規制線の列は空と見なす（通り抜けられないので、回り込みは障害物の経路探索に任せる）
        # shortcut: 規制線をくぐる人も、規制線の列の通過コストを見ずにまっすぐ進む。くぐる人が回り込む道も比べたくなれば、区間を人ごとに分ける
        _spans.append([lo, hi] if n >= 2 and not sim.groups[g].fence else [])

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
