# シミュレーション設定の定義と ./.config/general.toml の読み書き
# FIELDS が唯一の定義。設定画面（SettingsDialog）もここから入力欄を作る
extends RefCounted

const TomlFile := preload("res://script/core/TomlFile.gd")

const DIR := "./.config"
const PATH := DIR + "/general.toml"

const SECTION_LABELS := {
    "simulation": "全体",
    "object": "動物体の初期値",
    "avoidance": "ぶつからない動き",
}

# key は全セクションで重複させない（値は1つの Dictionary に平たく入れる）
# "object" セクションは動物体ごとの設定。ここの値は新しい動物体の初期値
const FIELDS := [
	# 全体 #
    {"section": "simulation", "key": "random_seed", "label": "乱数のシード", "default": 0, "min": 0, "max": 2147483647, "step": 1, "hint": "0でランダム、0以外で固定再生"},
    {"section": "simulation", "key": "sun_hour", "label": "時刻", "default": 12.0, "min": 0.0, "max": 24.0, "step": 0.5, "suffix": "時", "hint": "太陽の位置を決める"},
    {"section": "simulation", "key": "spawn_half_x", "label": "出現範囲の横幅（半分）", "default": 16.0, "min": 0.5, "max": 100.0, "step": 0.5, "suffix": "m", "hint": "描画画面の全体: 32 m × 18 m（半分: 16 × 9）"},
    {"section": "simulation", "key": "spawn_half_z", "label": "出現範囲の奥行き（半分）", "default": 9.0, "min": 0.5, "max": 100.0, "step": 0.5, "suffix": "m"},
    {"section": "simulation", "key": "model_yaw_offset_deg", "label": "モデルの向き補正", "default": 0.0, "min": -180.0, "max": 180.0, "step": 1.0, "suffix": "度"},
    {"section": "simulation", "key": "obstacle_height", "label": "障害物の高さ", "default": 1.0, "min": 0.05, "max": 30.0, "step": 0.05, "suffix": "m"},
    {"section": "simulation", "key": "two_routes", "label": "二本の経路", "default": true, "hint": "Trueだと、列を横切るルートと直進するルートを探査する。Falseだと、直進経路を探査する"},
    {"section": "simulation", "key": "use_simple_model", "label": "軽量3Dモデル", "default": false, "hint": "人を軽いカプセルで表す。太さはぶつかる半径、高さは身長に合わせる"},
    {"section": "simulation", "key": "human_model_dir", "label": "3Dモデルのフォルダ", "default": "res://objects/mixamo", "dir": true, "hint": "`名前_Walking.fbx`、`名前_Idle.fbx`を1人分として使う"},
    {"section": "simulation", "key": "human_height", "label": "人の身長", "default": 1.7, "min": 0.1, "max": 5.0, "step": 0.05, "suffix": "m"},
    {"section": "simulation", "key": "floor_texture_path", "label": "床の画像", "default": "", "filters": ["*.png, *.jpg, *.jpeg, *.webp ; 画像"]},
    {"section": "simulation", "key": "camera_fov", "label": "カメラの画角", "default": 70.0, "min": 10.0, "max": 120.0, "step": 1.0, "suffix": "度", "hint": "縦の画角。出力する画像の写り方が変わる（カメラの位置はシミュレーションの中で動かして固定する）"},
    # 動物体の初期値 #
    {"section": "object", "key": "motion", "label": "動きのスクリプト", "default": "", "choices": "motion"},
    {"section": "object", "key": "join_nearest", "label": "空いた列には近い所から入る", "default": true, "hint": "列に誰もいないとき、線の一番近い所から入る。外すと、決められた列に並ぶ動き（線の始点まで行って並ぶ）。"},
    {"section": "object", "key": "pedestrian_count", "label": "人数", "default": 30, "min": 0, "max": 500, "step": 1, "suffix": "人"},
    {"section": "object", "key": "line_speed", "label": "列の進む速さ", "default": 1.25, "min": 0.0, "max": 10.0, "step": 0.05, "suffix": "m/秒"},
    {"section": "object", "key": "walk_speed", "label": "列に並んでいないときの速度", "default": 1.4, "min": 0.05, "max": 10.0, "step": 0.05, "suffix": "m/秒", "hint": "列の最後尾へ向かうときと、ランダムに歩くときの速さ"},
    {"section": "object", "key": "speed_jitter", "label": "歩く速さのばらつき", "default": 0.1, "min": 0.0, "max": 0.9, "step": 0.05, "hint": "列に並んでいないときの速さを、人ごとに ±この割合でばらつかせる。0.1 なら ±10%"},
    {"section": "object", "key": "spacing_min", "label": "前の人との間隔（最小）", "default": 0.6, "min": 0.1, "max": 5.0, "step": 0.05, "suffix": "m"},
    {"section": "object", "key": "spacing_max", "label": "前の人との間隔（最大）", "default": 1.9, "min": 0.1, "max": 5.0, "step": 0.05, "suffix": "m"},
    {"section": "object", "key": "line_priority_min", "label": "道を譲る場面の優先度（最小）", "default": 0.0, "min": 0.0, "max": 1.0, "step": 0.05, "hint": "列に並んでいる人の値。横切る人の値より高ければ、横切る人が列の手前で待つ。低ければ列の人が止まって譲る"},
    {"section": "object", "key": "line_priority_max", "label": "道を譲る場面の優先度（最大）", "default": 1.0, "min": 0.0, "max": 1.0, "step": 0.05},
    {"section": "object", "key": "cross_priority_min", "label": "列を横切る場面の優先度（最小）", "default": 0.0, "min": 0.0, "max": 1.0, "step": 0.05, "hint": "ランダムに歩く人が列を横切るときの値。列の人の値より高ければ、列の人が止まって譲る"},
    {"section": "object", "key": "cross_priority_max", "label": "列を横切る場面の優先度（最大）", "default": 1.0, "min": 0.0, "max": 1.0, "step": 0.05},
    {"section": "object", "key": "max_wait", "label": "横切るのを待てる時間", "default": 5.0, "min": 0.0, "max": 600.0, "step": 0.5, "suffix": "秒", "hint": "これより長く待つと、優先度に関係なく横切る（列の人が止まる）"},
    {"section": "object", "key": "size_jitter", "label": "人の大きさのばらつき", "default": 0.0, "min": 0.0, "max": 0.5, "step": 0.05, "hint": "人の大きさ（見た目とぶつかる半径）を ±この割合でばらつかせる"},
    {"section": "object", "key": "lateral_jitter", "label": "列の左右のぶれ幅", "default": 0.1, "min": 0.0, "max": 2.0, "step": 0.01, "suffix": "m", "hint": "列の中心線から左右にずれる最大の距離"},
    {"section": "object", "key": "cross_cost", "label": "列の通過コスト", "default": 5.0, "min": 0.0, "max": 100.0, "step": 0.5, "suffix": "m", "hint": "この列の人の間を通り抜けるとき、道のりにこの距離を足して比べる（全体の設定の「二本の経路」が有効なとき）。大きいほど列の端を回り込む"},
    {"section": "object", "key": "spawn_interval", "label": "出現の間隔", "default": 0.0, "min": 0.0, "max": 60.0, "step": 0.1, "suffix": "秒", "hint": "開始時に1人ずつこの間隔で現れる。0 なら全員同時"},
	# ぶつからない動き #
    {"section": "avoidance", "key": "body_radius", "label": "人の大きさ（半径）", "default": 0.2, "min": 0.05, "max": 2.0, "step": 0.01, "suffix": "m"},
    {"section": "avoidance", "key": "avoid_radius", "label": "避ける相手を探す距離", "default": 2.0, "min": 0.0, "max": 10.0, "step": 0.05, "suffix": "m", "hint": "これより遠い人は見ない。先読みするので、歩く速さ × 先読みの時間 × 2 より広くする"},
    {"section": "avoidance", "key": "avoid_strength", "label": "避ける強さ", "default": 3.0, "min": 0.0, "max": 10.0, "step": 0.1, "hint": "AVM の k。向かってくる人にはこの 2 倍、同じ向きに歩く人にはこの値で、横へそれる"},
    {"section": "avoidance", "key": "avoid_range", "label": "避ける力の届き方", "default": 0.1, "min": 0.01, "max": 2.0, "step": 0.01, "suffix": "m", "hint": "AVM の D。先読みしたすき間がこの距離だけ広がるごとに、避ける力が 1/e に弱まる"},
    {"section": "avoidance", "key": "anticipation_time", "label": "先読みの時間", "default": 1.0, "min": 0.0, "max": 5.0, "step": 0.05, "suffix": "秒", "hint": "AVM の t_a。周りの人がこの時間後にいる位置を見て避ける。0 なら今の位置だけを見る"},
    {"section": "avoidance", "key": "turn_time", "label": "向き直る時間", "default": 0.3, "min": 0.01, "max": 5.0, "step": 0.01, "suffix": "秒", "hint": "AVM の τ。大きいほどゆっくり向きを変える"},
    {"section": "avoidance", "key": "time_gap", "label": "前の人との時間間隔", "default": 1.06, "min": 0.05, "max": 5.0, "step": 0.01, "suffix": "秒", "hint": "AVM の T。進む向きにいる人とのすき間を、この時間で歩ける速さまで落とす"},
    {"section": "avoidance", "key": "yield_distance", "label": "列の人が道を譲る距離", "default": 0.5, "min": 0.0, "max": 5.0, "step": 0.05, "suffix": "m", "hint": "列の人と横切る人の体のすき間がこれより狭くなると、どちらかが止まる"},
]

static func fields_in(section: String) -> Array:
    return FIELDS.filter(func(f: Dictionary) -> bool: return f["section"] == section)

static func defaults() -> Dictionary:
    var d := {}
    for f in FIELDS:
        d[f["key"]] = f["default"]
    return d

# 型をそろえ、範囲外は丸める（手で書き換えたファイルも受け付けるため）
static func sanitize(f: Dictionary, v: Variant) -> Variant:
    var def: Variant = f["default"]
    if typeof(def) == TYPE_FLOAT and typeof(v) == TYPE_INT:
        v = float(v)
    elif typeof(def) == TYPE_INT and typeof(v) == TYPE_FLOAT:
        v = int(round(v))
    if typeof(v) != typeof(def):
        push_warning("設定 [%s] %s の型が違うため既定値を使います: %s" % [f["section"], f["key"], v])
        return def
    if f.has("min"):
        v = clamp(v, f["min"], f["max"])
    return v

# section の項目を cfg から読む（無い項目は既定値）
static func read_fields(cfg: TomlFile, section: String, file_section: String = section) -> Dictionary:
    var values := {}
    for f in fields_in(section):
        values[f["key"]] = sanitize(f, cfg.get_value(file_section, f["key"], f["default"]))
    return values

# general.toml を開く（無ければ空）。他のセクション（障害物・カメラ位置）を消さないよう、書くときは必ずこれを読んでから
static func open_general() -> TomlFile:
    var cfg := TomlFile.new()
    cfg.load(PATH)
    return cfg

static func save_general(cfg: TomlFile) -> void:
    DirAccess.make_dir_recursive_absolute(DIR)
    if cfg.save(PATH) != OK:
        push_warning("設定ファイルを保存できません: " + PATH)

# ファイルが無ければ既定値で作る。足りない項目は既定値で補う
static func load_values() -> Dictionary:
    if not FileAccess.file_exists(PATH):
        save_values(defaults())
    return read_values(open_general())

static func save_values(values: Dictionary) -> void:
    var cfg := open_general()
    write_values(cfg, values)
    save_general(cfg)

# 全項目の読み書き（general.toml とリプレイファイルで共通）
static func read_values(cfg: TomlFile) -> Dictionary:
    var values := {}
    for section in SECTION_LABELS:
        values.merge(read_fields(cfg, section))
    return values

static func write_values(cfg: TomlFile, values: Dictionary) -> void:
    for f in FIELDS:
        cfg.set_value(f["section"], f["key"], values.get(f["key"], f["default"]))

# 全体設定のうち「動物体の初期値」だけ
static func object_defaults(values: Dictionary) -> Dictionary:
    var d := {}
    for f in fields_in("object"):
        d[f["key"]] = values[f["key"]]
    return d
