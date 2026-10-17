# 描いた内容の保存と読み込み
#   動物体  : ./.config/objects/object_01.toml …（1体1ファイル。名前・線の座標・設定）
#   障害物  : ./.config/general.toml の [scene]
#   カメラ  : ./.config/general.toml の [camera_pose]（固定した位置。無ければ自動で合わせる）
#   リプレイ: ./.config/replay/*.toml（シミュレートするたびに1つ）
extends RefCounted

const Config := preload("res://script/core/Config.gd")
const TomlFile := Config.TomlFile
const Motion := preload("res://script/core/Motion.gd")

const POINT_KEYS := ["points", "spawn_points", "goal_points"]

const OBJECTS_DIR := Config.DIR + "/objects"
const REPLAY_DIR := Config.DIR + "/replay"

# 動物体: {"name": String, "points": 列の線, "spawn_points": 出現地の線, "goal_points": 目的地の線（どれも Vector2 の配列）, Config の "object" セクションの設定}
static func load_objects() -> Array[Dictionary]:
    var out: Array[Dictionary] = []
    var files := DirAccess.get_files_at(OBJECTS_DIR)  # 名前順
    for file in files:
        if not file.ends_with(".toml"):
            continue
        var cfg := TomlFile.new()
        if cfg.load(OBJECTS_DIR.path_join(file)) != OK:
            push_warning("動物体ファイルを読めません: " + file)
            continue
        out.append(_read_object(cfg, "object", file.get_basename()))
    return out

# Config の項目のほか、動きのスクリプトの設定値（数値・文字列・真偽値）もそのまま読む（型と範囲はシミュレーション開始時に Motion.params で直す）
static func _read_object(cfg: TomlFile, section: String, fallback_name: String) -> Dictionary:
    var obj := {}
    for key in cfg.get_section_keys(section):
        var v: Variant = cfg.get_value(section, key)
        if typeof(v) in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING]:
            obj[key] = v
    # 2026-10-18 より前のファイル: 「列に並ぶ」を外した動物体はランダムに歩く
    if not obj.has("motion") and obj.get("join_line", true) == false:
        obj["motion"] = "random_walk.gd"
    obj.erase("join_line")
    obj.merge(Config.read_fields(cfg, "object", section), true)
    obj["name"] = str(cfg.get_value(section, "name", fallback_name))
    for key in POINT_KEYS:
        obj[key] = _to_points(cfg.get_value(section, key, []))
    return obj

static func _write_object(cfg: TomlFile, section: String, obj: Dictionary) -> void:
    cfg.set_value(section, "name", obj["name"])
    for key in POINT_KEYS:
        var pts := []
        for p in obj.get(key, []):
            pts.append([p.x, p.y])
        cfg.set_value(section, key, pts)
    for f in Config.fields_in("object"):
        cfg.set_value(section, f["key"], obj.get(f["key"], f["default"]))
    # 動きのスクリプトの設定値
    for key in obj:
        if not key in POINT_KEYS and key != "name" and typeof(obj[key]) in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING]:
            cfg.set_value(section, key, obj[key])

# 全部書き直す（削除した動物体のファイルも消えるように、先に既存の .toml を消す）
static func save_objects(objects: Array[Dictionary]) -> void:
    DirAccess.make_dir_recursive_absolute(OBJECTS_DIR)
    for file in DirAccess.get_files_at(OBJECTS_DIR):
        if file.ends_with(".toml"):
            DirAccess.remove_absolute(OBJECTS_DIR.path_join(file))
    for i in range(objects.size()):
        var cfg := TomlFile.new()
        _write_object(cfg, "object", objects[i])
        if cfg.save(OBJECTS_DIR.path_join("object_%02d.toml" % (i + 1))) != OK:
            push_warning("動物体を保存できません: " + str(objects[i]["name"]))

# [[x, y], …] → Vector2 の配列。形が違う要素は捨てる
static func _to_points(v: Variant) -> Array:
    var out := []
    if v is Array:
        for p in v:
            if p is Array and p.size() == 2 and _is_num(p[0]) and _is_num(p[1]):
                out.append(Vector2(p[0], p[1]))
    return out

static func _is_num(v: Variant) -> bool:
    return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT

static func load_obstacles() -> Array[Rect2]:
    return _read_obstacles(Config.open_general())

static func save_obstacles(rects: Array[Rect2]) -> void:
    var cfg := Config.open_general()
    _write_obstacles(cfg, rects)
    Config.save_general(cfg)

static func _read_obstacles(cfg: TomlFile) -> Array[Rect2]:
    var out: Array[Rect2] = []
    var v: Variant = cfg.get_value("scene", "obstacles", [])
    if v is Array:
        for r in v:
            if r is Array and r.size() == 4 and r.all(_is_num):
                out.append(Rect2(r[0], r[1], r[2], r[3]))
    return out

static func _write_obstacles(cfg: TomlFile, rects: Array[Rect2]) -> void:
    var arr := []
    for r in rects:
        arr.append([r.position.x, r.position.y, r.size.x, r.size.y])
    cfg.set_value("scene", "obstacles", arr)

# --- リプレイ: ./.config/replay/*.toml ---
# 1ファイルに、シードと、シミュレート時点の設定・動物体・障害物をすべて入れる。同じコードで読めば同じ動きになる
#   [replay]      seed, commit（git のコミット。コードが違うと再現しない）, physics_ticks（刻みが違うと再現しない）
#   [simulation] など  全体設定（general.toml と同じ）
#   [scene]       obstacles
#   [object_01] …  動物体
#   [motion]      sources = [[スクリプト名, ソース], …]（あとでスクリプトを書き換えても、記録したときの動きで再生する）

# 次のシミュレーションで再生するリプレイファイル。描画画面で決めて、シミュレーション画面が読む
static var current_replay: String = ""

# シミュレート直前に呼ぶ。シードが 0（毎回ちがう）ならここで決めて書き込む。保存したパスを返す
static func save_replay(values: Dictionary, objects: Array[Dictionary], obstacles: Array[Rect2]) -> String:
    var cfg := TomlFile.new()
    var seed_value: int = values["random_seed"] if values["random_seed"] != 0 else randi_range(1, 2147483647)
    cfg.set_value("replay", "seed", seed_value)
    cfg.set_value("replay", "commit", code_version())
    cfg.set_value("replay", "physics_ticks", Engine.physics_ticks_per_second)
    Config.write_values(cfg, values)
    cfg.set_value("simulation", "random_seed", seed_value)
    _write_obstacles(cfg, obstacles)
    var sources := {}
    for i in range(objects.size()):
        _write_object(cfg, "object_%02d" % (i + 1), objects[i])
        var m: String = objects[i].get("motion", "")
        if m != "":
            sources[m] = Motion.source(m)
    cfg.set_value("motion", "sources", sources.keys().map(func(k: String) -> Array: return [k, sources[k]]))
    DirAccess.make_dir_recursive_absolute(REPLAY_DIR)
    # 名前順＝新しい順に並ぶよう日時から始める
    var path := REPLAY_DIR.path_join("%s_seed%d.toml" % [Time.get_datetime_string_from_system().replace(":", "").replace("T", "_"), seed_value])
    if cfg.save(path) != OK:
        push_warning("リプレイを保存できません: " + path)
    return path

# {"values": 設定（random_seed はシード）, "objects", "obstacles", "motions": スクリプト名 → ソース}。読めなければ空
static func load_replay(path: String) -> Dictionary:
    var cfg := TomlFile.new()
    if cfg.load(path) != OK:
        push_warning("リプレイを読めません: " + path)
        return {}
    var commit: String = str(cfg.get_value("replay", "commit", ""))
    var now := code_version()
    if commit != now or now.ends_with("-dirty"):
        push_warning("リプレイを作ったときとコードが違うかもしれないため、同じ動きにならないことがあります（%s → %s）" % [commit, now])
    if cfg.get_value("replay", "physics_ticks", 0) != Engine.physics_ticks_per_second:
        push_warning("物理の刻み（physics_ticks_per_second）が違うため、同じ動きになりません")
    var objects: Array[Dictionary] = []
    for section in cfg.get_sections():
        if section.begins_with("object_"):
            objects.append(_read_object(cfg, section, section))
    var motions := {}
    for pair in cfg.get_value("motion", "sources", []):
        if pair is Array and pair.size() == 2:
            motions[str(pair[0])] = str(pair[1])
    return {"values": Config.read_values(cfg), "objects": objects, "obstacles": _read_obstacles(cfg), "motions": motions}

# 新しい順のファイル名
static func list_replays() -> PackedStringArray:
    var files := Array(DirAccess.get_files_at(REPLAY_DIR)).filter(func(f: String) -> bool: return f.ends_with(".toml"))
    files.sort()
    files.reverse()
    return PackedStringArray(files)

# git のコミット（スクリプト・シーンに未コミットの変更があれば "-dirty" を付ける）。git が無ければ空
static func code_version() -> String:
    var root := ProjectSettings.globalize_path("res://")
    var out := []
    if OS.execute("git", ["-C", root, "rev-parse", "--short", "HEAD"], out) != 0:
        return ""
    var version: String = out[0].strip_edges()
    out.clear()
    OS.execute("git", ["-C", root, "status", "--porcelain", "--", "script", "scene", "project.godot"], out)
    return version + ("-dirty" if out[0].strip_edges() != "" else "")

# 固定したカメラ位置。無い・壊れているときは false
static func load_camera(cam: Camera3D) -> bool:
    var cfg := Config.open_general()
    var p: Variant = cfg.get_value("camera_pose", "position", [])
    var r: Variant = cfg.get_value("camera_pose", "rotation_deg", [])
    if not (p is Array and r is Array and p.size() == 3 and r.size() == 3 and p.all(_is_num) and r.all(_is_num)):
        return false
    cam.position = Vector3(p[0], p[1], p[2])
    cam.rotation_degrees = Vector3(r[0], r[1], r[2])
    return true

static func save_camera(cam: Camera3D) -> void:
    var cfg := Config.open_general()
    var p := cam.position
    var r := cam.rotation_degrees
    cfg.set_value("camera_pose", "position", [p.x, p.y, p.z])
    cfg.set_value("camera_pose", "rotation_deg", [r.x, r.y, r.z])
    Config.save_general(cfg)

static func clear_camera() -> void:
    var cfg := Config.open_general()
    if cfg.has_section("camera_pose"):
        cfg.erase_section("camera_pose")
    Config.save_general(cfg)
