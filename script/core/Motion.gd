# 動きのスクリプト（./.config/motion/*.gd）の一覧・読み込みと、スクリプトに渡す World
# 書き方は ./.config/motion/README.md。動物体の「動き」が空なら組み込みの「列に並ぶ」
extends RefCounted

const Config := preload("res://script/core/Config.gd")

const DIR := Config.DIR + "/motion"
const LINE_LABEL := "列に並ぶ（組み込み）"

# ドロップダウンに出す [値, 表示名]。値 "" は組み込みの列
static func choices() -> Array:
    var out := [["", LINE_LABEL]]
    for name in DirAccess.get_files_at(DIR):
        if name.ends_with(".gd"):
            var s := compile(source(name), name)
            out.append([name, "%s（%s）" % [label(s), name] if s else name + "（読めません）"])
    return out

static func source(name: String) -> String:
    var path := DIR.path_join(name)
    return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""

# 文法の誤りがあれば null（誤りの行は Godot がコンソールに出す）
static func compile(src: String, name: String) -> GDScript:
    if src.is_empty():
        push_warning("動きのスクリプトがありません: " + DIR.path_join(name))
        return null
    var s := GDScript.new()
    s.set_meta("file", name)
    s.source_code = src
    if s.reload() != OK or not s.can_instantiate():
        push_warning("動きのスクリプトを読めません（文法の誤り）: " + name)
        return null
    return s

static func label(s: GDScript) -> String:
    return str(s.get_script_constant_map().get("LABEL", s.get_meta("file", "")))

# スクリプトの FIELDS（Config.FIELDS と同じ書き方）。設定画面では LABEL の分類に並べる
static func fields(s: GDScript) -> Array:
    var out := []
    if s == null:
        return out
    for f in s.get_script_constant_map().get("FIELDS", []):
        var f2: Dictionary = f.duplicate()
        f2["section"] = label(s)
        if Config.FIELDS.any(func(c: Dictionary) -> bool: return c["key"] == f2["key"]):
            push_warning("動きのスクリプトの項目名が全体の設定と同じです（別の名前にしてください）: " + f2["key"])
            continue
        out.append(f2)
    return out

# 動物体の値から、スクリプトの設定値（me.param）を作る。無い・型の違う値は既定値
static func params(s: GDScript, obj: Dictionary) -> Dictionary:
    var out := {}
    for f in fields(s):
        out[f["key"]] = Config.sanitize(f, obj.get(f["key"], f["default"]))
    return out


# スクリプトの step(me, world, rng, delta) に渡す、周りを調べる窓口
class World:
    var _sim: Node  # SimulationManager3D

    func _init(sim: Node) -> void:
        _sim = sim

    # 障害物の床面（XZ の矩形、m）
    var obstacles: Array[Rect2]:
        get: return _sim.obstacle_rects

    # 動いてよい範囲（出現範囲。XZ の矩形、m）
    var bounds: Rect2:
        get: return Rect2(-_sim.spawn_half_x, -_sim.spawn_half_z, _sim.spawn_half_x * 2.0, _sim.spawn_half_z * 2.0)

    # me から radius m 以内の人・動物（自分は除く）。近い順
    # 1つずつ {name: 動物体の名前, motion: 動きのスクリプト名（列なら ""）, position, velocity, in_line: 列に並んでいるか}
    # ponytail: 全員を調べる（人数の2乗）。500 人を超えて重くなったら格子で区切る
    func nearby(me, radius: float) -> Array:
        var out := []
        for o in _sim.walkers:
            if o != me and o.node.position.distance_to(me.position) <= radius:
                var g = _sim.groups[o.group]
                out.append({"name": g.name, "motion": g.motion, "position": o.node.position, "velocity": o.velocity, "in_line": o.state != _sim.State.SCRIPTED})
        out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["position"].distance_to(me.position) < b["position"].distance_to(me.position))
        return out

    # 点 p（m）が障害物の中か
    func is_blocked(p: Vector3) -> bool:
        return obstacles.any(func(r: Rect2) -> bool: return r.has_point(Vector2(p.x, p.z)))

    # from から to へ、障害物をよけてたどり着けるか
    func reachable(from: Vector3, to: Vector3) -> bool:
        return _sim._reachable(from, to)

    # 列（線のある動物体）の一覧。1つずつ {name, points: 中心線の点（m）, tail: 最後尾の人の位置, head: 先頭の人の位置（いなければ null）}
    func lines() -> Array:
        var out := []
        for gi in range(_sim.groups.size()):
            var g = _sim.groups[gi]
            if not g.join_line:
                continue
            var tail = _sim._get_tail(gi)
            var head = null
            for o in _sim.walkers:
                if o.group == gi and o.state == _sim.State.ON_LINE and (head == null or o.s > head.s):
                    head = o
            out.append({"name": g.name, "points": g.points, "tail": tail.node.position if tail else null, "head": head.node.position if head else null})
        return out

    # 次の目的地の候補: 自分の動物体に目的地の線があればその上、無ければ動いてよい範囲のどこか（障害物の中と列のそばを避ける）
    func random_goal(me, rng: RandomNumberGenerator) -> Vector3:
        var g = _sim.groups[me.group]
        return g.goal_at(rng.randf()) if g.goal_curve.point_count > 0 else _sim._random_point()
