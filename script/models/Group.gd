# 動物体1つ分（歩行者のグループ）。join_line なら線（列）を持つ。motion が空なら組み込みの列に並ぶ、そうでなければ動きのスクリプト
extends RefCounted

const Geometry := preload("res://script/utils/Geometry.gd")

var curve := Curve3D.new()
var points: Array[Vector3] = []
var length: float = 0.0
var start: Vector3
var first_dir: Vector3 = Vector3.FORWARD
var last_dir: Vector3 = Vector3.FORWARD
var spawn_curve := Curve3D.new()  # 出現地の線（描画画面で右ドラッグ）。点が無ければ出現範囲のどこか
var goal_curve := Curve3D.new()   # 目的地の線（Shift+左ドラッグ）。スクリプトが world.random_goal() で使う
var join_line: bool = false       # 列の線がある
var script_obj: Object            # 動きのスクリプトのインスタンス（motion が空なら null）
var params := {}                  # 動きのスクリプトの設定値（me.param）
# 以下は Config の "object" セクションと同じキー
var name: String = ""
var motion: String = ""
var pedestrian_count: int = 30
var join_nearest: bool = true
var line_speed: float = 1.25
var walk_speed: float = 1.4
var spacing_min: float = 0.6
var spacing_max: float = 1.9
var line_priority_min: float = 0.0
var line_priority_max: float = 1.0
var cross_priority_min: float = 0.0
var cross_priority_max: float = 1.0
var max_wait: float = 5.0
var speed_jitter: float = 0.1
var size_jitter: float = 0.0
var lateral_jitter: float = 0.1
var spawn_interval: float = 0.0
var cross_cost: float = 5.0

# data: SceneStore.load_objects() の1要素（"points" は描画画面の座標）
func _init(data: Dictionary) -> void:
    curve.bake_interval = 0.05  # m。既定の 0.2 では曲がり角が粗い
    for f in data:
        if f != "points" and f in self:
            set(f, data[f])
    for p in data.get("spawn_points", []):
        spawn_curve.add_point(Geometry.to_world(p))
    for p in data.get("goal_points", []):
        goal_curve.add_point(Geometry.to_world(p))
    for p in data.get("points", []):
        var p3 := Geometry.to_world(p)
        curve.add_point(p3)
        points.append(p3)
    join_line = points.size() >= 2
    if not join_line:
        return
    length = curve.get_baked_length()
    start = points[0]
    var d := points[1] - points[0]
    first_dir = d.normalized() if d.length_squared() > 0.000001 else Vector3.FORWARD
    d = points[-1] - points[-2]
    last_dir = d.normalized() if d.length_squared() > 0.000001 else first_dir

# 乱数はシミュレーションのもの（シードで再現できるように）を受け取る
func random_gap(rng: RandomNumberGenerator) -> float:
    return _between(rng, spacing_min, spacing_max)

func random_line_priority(rng: RandomNumberGenerator) -> float:
    return _between(rng, line_priority_min, line_priority_max)

func random_cross_priority(rng: RandomNumberGenerator) -> float:
    return _between(rng, cross_priority_min, cross_priority_max)

# 最小と最大を逆に設定されても動くように
static func _between(rng: RandomNumberGenerator, a: float, b: float) -> float:
    return rng.randf_range(minf(a, b), maxf(a, b))

# 出現地・目的地の線の上の点（t は 0〜1、線の長さで均等）。点が1つならその点
func spawn_at(t: float) -> Vector3:
    return _on(spawn_curve, t)

func goal_at(t: float) -> Vector3:
    return _on(goal_curve, t)

static func _on(c: Curve3D, t: float) -> Vector3:
    return c.get_point_position(0) if c.point_count == 1 else c.sample_baked(t * c.get_baked_length())

# 列上の位置 s（始点より手前・終点より先は延長線上）から offset だけ右にずらした点
func pos(s: float, offset: float = 0.0) -> Vector3:
    var base_pos := Vector3.ZERO
    var dir := Vector3.FORWARD

    if s < 0.0:
        base_pos = start + first_dir * s
        dir = first_dir
    elif s > length:
        base_pos = points[-1] + last_dir * (s - length)
        dir = last_dir
    else:
        base_pos = curve.sample_baked(s)
        # 進行方向を取得して法線（左右）を計算
        var d := curve.sample_baked(s + 0.05) - base_pos
        d.y = 0.0
        if d.length_squared() > 0.000001:
            dir = d.normalized()

    base_pos.y = 0.0

    # 進行方向に対して垂直な右方向ベクトル (Y軸の外積)
    return base_pos + dir.cross(Vector3.UP).normalized() * offset
