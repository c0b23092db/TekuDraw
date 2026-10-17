# 座標変換と障害物まわりの幾何計算（すべて static）
extends RefCounted

# 3D の長さの単位は m。描画画面の 1px が何 m か（1280x720 の画面が 32 m × 18 m）
const PX := 0.025

# 描画画面（1280x720）の座標 → 3D の XZ 平面（中心が原点）
static func to_world(p: Vector2) -> Vector3:
    return Vector3((p.x - 640.0) * PX, 0.0, (p.y - 360.0) * PX)

# 半径 radius の円が矩形（XZ）に重ならない位置まで押し出す
static func push_out_of_rects(pos: Vector3, radius: float, rects: Array[Rect2]) -> Vector3:
    var p := Vector2(pos.x, pos.z)
    for r in rects:
        var closest := p.clamp(r.position, r.end)
        if closest == p:
            # 中心が矩形内: 一番近い辺の外へ
            var outs: Array[Vector2] = [
                Vector2(r.position.x - radius, p.y), Vector2(r.end.x + radius, p.y),
                Vector2(p.x, r.position.y - radius), Vector2(p.x, r.end.y + radius)]
            var best := outs[0]
            for o in outs:
                if p.distance_squared_to(o) < p.distance_squared_to(best):
                    best = o
            p = best
        else:
            var d := p - closest
            if d.length() < radius:
                p = closest + d.normalized() * radius
    return Vector3(p.x, pos.y, p.y)

static func segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
    if r.has_point(a) or r.has_point(b):
        return true
    var c: Array[Vector2] = [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
    for i in range(4):
        if Geometry2D.segment_intersects_segment(a, b, c[i], c[(i + 1) % 4]) != null:
            return true
    return false

static func segment_clear(a: Vector2, b: Vector2, rects: Array[Rect2], radius: float) -> bool:
    for r in rects:
        if segment_hits_rect(a, b, r.grow(radius)):
            return false
    return true

# 経路探索用の格子。範囲は (-half) 〜 (+half)。障害物を radius だけ太らせて塗るので、空いている格子点なら人が立てる
# ponytail: 格子の細かさは radius。通れると保証できるすき間は 3 * radius 以上。
# 細かくするほど狭い所を通れるが、半分にすると探索が約3倍遅い（既定の範囲で1回 5ms → 17ms）
static func make_grid(rects: Array[Rect2], half: Vector2, radius: float) -> AStarGrid2D:
    var cell := radius
    var grid := AStarGrid2D.new()
    grid.cell_size = Vector2(cell, cell)
    grid.offset = -half
    grid.region = Rect2i(0, 0, ceili(half.x * 2.0 / cell) + 1, ceili(half.y * 2.0 / cell) + 1)
    grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES  # 角をかすめない
    grid.update()
    for r in rects:
        var g := r.grow(radius)
        var lo := Vector2i(((g.position + half) / cell).ceil())
        var hi := Vector2i(((g.end + half) / cell).floor())
        grid.fill_solid_region(Rect2i(lo, hi - lo + Vector2i.ONE))
    return grid

static func _to_id(grid: AStarGrid2D, p: Vector2) -> Vector2i:
    var id := Vector2i(((p - grid.offset) / grid.cell_size).round())
    return id.clamp(grid.region.position, grid.region.end - Vector2i.ONE)

# from → goal の経路（from は含まない）。ゴールが囲まれていたら、たどり着ける一番近い所まで
# 格子のカクカクは、見通せる限り点を飛ばして（rects を radius だけ太らせて判定）曲がり角だけにする
static func find_path(grid: AStarGrid2D, from: Vector2, goal: Vector2, rects: Array[Rect2], radius: float) -> PackedVector2Array:
    var start := _to_id(grid, from)
    # 壁ぎわに押し出された直後は格子点が塞がっているので、近くの空いた点から始める
    for ring in range(1, 4):
        if not grid.is_point_solid(start):
            break
        for d in [Vector2i(ring, 0), Vector2i(-ring, 0), Vector2i(0, ring), Vector2i(0, -ring),
                Vector2i(ring, ring), Vector2i(-ring, ring), Vector2i(ring, -ring), Vector2i(-ring, -ring)]:
            var id: Vector2i = start + d
            if grid.is_in_boundsv(id) and not grid.is_point_solid(id):
                start = id
                break
    var ids := grid.get_id_path(start, _to_id(grid, goal), true)
    var pts := PackedVector2Array()
    for i in range(ids.size()):
        # 終点と、進む向きが変わる点だけを候補にする（直線の途中は見通し判定しなくてよい）
        if i == ids.size() - 1 or (i > 0 and ids[i] - ids[i - 1] != ids[i + 1] - ids[i]):
            pts.append(grid.get_point_position(ids[i]))
    if not ids.is_empty() and ids[-1] == _to_id(grid, goal):
        pts[-1] = goal  # 格子点ではなく本当のゴールへ
    var path := PackedVector2Array()
    var anchor := from
    for i in range(pts.size() - 1):
        if not segment_clear(anchor, pts[i + 1], rects, radius):
            anchor = pts[i]
            path.append(anchor)
    if not pts.is_empty():
        path.append(pts[-1])
    return path

# path のうち from から見通せる一番先の点。どれも見えなければ最初の点
static func farthest_visible(from: Vector2, path: PackedVector2Array, rects: Array[Rect2], radius: float) -> Vector2:
    for i in range(path.size() - 1, 0, -1):
        if segment_clear(from, path[i], rects, radius):
            return path[i]
    return path[0] if not path.is_empty() else from
