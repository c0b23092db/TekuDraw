extends Node3D

const Config := preload("res://script/core/Config.gd")
const Geometry := preload("res://script/utils/Geometry.gd")
const CameraFit := preload("res://script/utils/CameraFit.gd")
const SceneStore := preload("res://script/core/SceneStore.gd")
const CameraController := preload("res://script/scene/CameraController.gd")
const Walker := preload("res://script/models/Walker.gd")
const Group := preload("res://script/models/Group.gd")
const Motion := preload("res://script/core/Motion.gd")
const Crossing := preload("res://script/walk/Crossing.gd")
const Routes := preload("res://script/walk/Routes.gd")
const Steering := preload("res://script/walk/Steering.gd")
const State := Walker.State

const DRAW_SCENE_PATH := "res://scene/draw.tscn"
const SIMPLE_MODEL_PATH := "res://objects/sukuea.tscn"  # 「3Dモデルを使わない」ときのカプセル
# 長さの単位は m
const JOIN_RADIUS: float = 1.0      # 最後尾の後ろの位置にこの距離まで近づいたら列に合流
const CATCH_UP: float = 1.3         # 列に並びに行く人は、少なくとも列の速さのこの倍で歩く
const LINE_CLEAR: float = 1.5      # ランダムに歩く人の目的地・現れる所は、列の線（左右のぶれ幅の外側）からこれ以上離す
const FENCE_SIZE: float = 0.2      # 規制線の当たりの矩形の一辺（並べる間隔も同じ）
const FENCE_COLOR := Color(1.0, 0.8, 0.1)

# 以下は ./.config/general.toml（Config.FIELDS）から読み込む。意味は Config.gd のラベルを参照
var use_simple_model: bool
var human_model_dir: String
var human_height: float
var floor_texture_path: String
var sun_hour: float
var spawn_half_x: float
var spawn_half_z: float
var model_yaw_offset_deg: float
var obstacle_height: float
var body_radius: float
var avoid_radius: float
var avoid_strength: float
var avoid_range: float
var anticipation_time: float
var turn_time: float
var time_gap: float
var yield_distance: float
var camera_fov: float
var random_seed: int
var two_routes: bool
var json_interval: float

# 乱数はすべてこれから取る。同じシード・同じ設定・同じコードなら、毎回同じ動きになる
var rng := RandomNumberGenerator.new()
# 見た目だけの乱数（モデルの選択など）。rng から取ると動きの乱数の順番がずれるので分ける
var vis_rng := RandomNumberGenerator.new()
var is_simulating: bool = false
var walkers: Array[Walker] = []
var pending: Array[Walker] = []         # 出現の間隔待ちで、まだ現れていない人
var groups: Array[Group] = []
var obstacle_rects: Array[Rect2] = []   # 障害物の床面（XZ）
var nav_grid: AStarGrid2D               # 障害物を迂回する経路探索用
var models: Array[Dictionary] = []      # _load_models() を参照
static var _scenes := {}                # パス → PackedScene（_load_scene の読み込み済み）。アプリを閉じるまで残す
var _controller: CameraController
var _env: Environment
var _debug_lines: Array[Node3D] = []  # 列の線。データセットに映らないよう Space で消せる
# 歩き方（./walk）。列を横切るときの決まり・二本の経路・よける動き
var crossing := Crossing.new(self)
var routes := Routes.new(self)
var steering := Steering.new(self)
var _world: Motion.World  # 動きのスクリプトに渡す窓口
var _step_warned := {}    # 動物体 → step() の戻り値がおかしいと一度だけ警告した
var elapsed: float = 0.0  # 始めてからの秒数（JSON の t）
var _next_id: int = 0     # 次に現れる人の番号
var _json_wait: float = 0.0
var _last_camera: Variant = null  # 最後に JSON に出したカメラ。動かしたら出し直す

func _ready() -> void:
    # 描画画面から来たときはリプレイファイル（設定・シード・動物体・障害物）で動かす。シーンを直接開いたときは .config から
    var replay := SceneStore.load_replay(SceneStore.current_replay) if SceneStore.current_replay else {}
    var config: Dictionary = replay.get("values", Config.load_values())
    for key in config:
        if key in self:
            set(key, config[key])
    _apply_floor()
    _env = Environment.new()
    _env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    _env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    var world := WorldEnvironment.new()
    world.environment = _env
    add_child(world)
    var cam := get_viewport().get_camera_3d()
    var panel := get_node_or_null("../CanvasLayer/Panel") as Control
    if cam and panel:
        var fixed := SceneStore.load_camera(cam)
        if fixed:
            cam.fov = camera_fov
        else:
            _fit_camera(cam)
        _controller = CameraController.new(cam, _fit_camera.bind(cam), panel)
        add_child(_controller)
        _controller.set_status(fixed)
    _apply_sun()
    if replay:
        print("リプレイ: ", SceneStore.current_replay)
        setup_simulation(replay["objects"], replay["obstacles"], replay.get("motions", {}))
    else:
        setup_simulation(SceneStore.load_objects(), SceneStore.load_obstacles())

func _fit_camera(cam: Camera3D) -> void:
    CameraFit.fit(cam, spawn_half_x, spawn_half_z, camera_fov)

# 床（シーンの Plane）に設定の画像を貼る。res:// でなければプロジェクトの外のファイルとして読む
# 画像が空・読めないときは、シーンのままの白い床
func _apply_floor() -> void:
    var plane := get_node_or_null("../Plane") as MeshInstance3D
    if plane == null or floor_texture_path.is_empty():
        return
    var tex: Texture2D
    if floor_texture_path.begins_with("res://"):
        tex = load(floor_texture_path) as Texture2D if ResourceLoader.exists(floor_texture_path) else null
    else:
        var img := Image.load_from_file(floor_texture_path) if FileAccess.file_exists(floor_texture_path) else null
        tex = ImageTexture.create_from_image(img) if img else null
    if tex == null:
        push_warning("床の画像を読み込めないため、白い床にします: " + floor_texture_path)
        return
    var mat := StandardMaterial3D.new()
    mat.albedo_texture = tex
    plane.material_override = mat

# 時刻 sun_hour から太陽（シーンの DirectionalLight3D）と周りの明るさを決める。季節は考えない
func _apply_sun() -> void:
    var light := get_node_or_null("../DirectionalLight3D") as DirectionalLight3D
    if light == null:
        return
    var t := (sun_hour - 6.0) / 12.0   # 6 時に 0（東）、12 時に 0.5（南中）、18 時に 1（西）
    var h := sin(PI * t)                # 太陽の高さ。夜は負
    var day := clampf(h / 0.15, 0.0, 1.0)  # 地平線の近くで明るさを落とし、夜は 0
    light.rotation = Vector3(-deg_to_rad(maxf(h * 70.0, 3.0)), PI / 2.0 - PI * t, 0.0)
    light.light_color = Color(1.0, 0.55, 0.3).lerp(Color(1.0, 0.97, 0.92), clampf(h / 0.5, 0.0, 1.0))
    light.light_energy = day
    light.visible = day > 0.0
    light.shadow_enabled = true
    light.directional_shadow_max_distance = 80.0
    if _env:
        _env.ambient_light_color = Color(0.25, 0.3, 0.5).lerp(Color(0.75, 0.8, 0.9), day)
        _env.ambient_light_energy = lerpf(0.15, 0.35, day)
    if _controller:
        _controller.set_hour(sun_hour)

## objects: SceneStore.load_objects() の形式。obstacles: 描画画面の座標の矩形
## motions: 動きのスクリプト名 → ソース（リプレイに保存したもの）。無いものは ./.config/motion から読む
## 動きのスクリプトが読めなければ始めない（false を返す）
func setup_simulation(objects: Array[Dictionary], obstacles: Array[Rect2], motions: Dictionary = {}) -> bool:
    # シード 0 は毎回ちがう動き。使ったシードを表示するので、気に入った回は設定に書けば再現できる
    rng.seed = random_seed if random_seed != 0 else randi_range(1, 2147483647)
    print("シード: ", rng.seed)
    vis_rng.seed = rng.seed + 1  # リプレイでは見た目も同じになる
    groups.clear()
    _world = Motion.World.new(self)
    for data in objects:
        var g := Group.new(data)
        groups.append(g)
        if g.join_line:
            _draw_3d_line(g.points)
        if g.motion != "":
            var s := Motion.compile(motions[g.motion] if motions.has(g.motion) else Motion.source(g.motion), g.motion)
            if s == null:
                print("エラー: %s の動きのスクリプト %s を読めないため、始めません" % [g.name, g.motion])
                return false
            g.script_obj = s.new()
            g.params = Motion.params(s, data)
        elif not g.join_line and g.pedestrian_count > 0:
            print("注意: %s は列の線が無いため、人を出しません" % g.name)
            g.pedestrian_count = 0

    if groups.is_empty():
        return false
    elapsed = 0.0
    _next_id = 0
    _json_wait = 0.0
    _spawn_obstacles(obstacles)
    _spawn_pedestrians()
    is_simulating = true
    if json_interval > 0.0:
        _last_camera = camera_json()
        _emit({"type": "meta", "seed": rng.seed, "interval": json_interval, "camera": _last_camera})
    return true

# --- JSON の出力: 1行1つの JSON を標準出力へ。Godot の起動表示なども標準出力に出るので、受け取る側は "{" で始まる行だけを読む ---
# meta  : 始めに1回。シードと、カメラ（動かしたら "camera" の行を出し直す）
# frame : json_interval ごと。t は始めてからの秒数。x・z は床（XZ 平面、m）、yaw は +Z から +X へ回る向き（ラジアン、-π〜π）
func _emit(d: Dictionary) -> void:
    print(JSON.stringify(d))

func frame_json() -> Dictionary:
    var list := []
    for w in walkers:
        var yaw := wrapf(w.node.rotation.y - deg_to_rad(model_yaw_offset_deg), -PI, PI)  # モデルの向き補正は除く
        list.append({"id": w.id, "x": snappedf(w.node.position.x, 0.001), "z": snappedf(w.node.position.z, 0.001), "yaw": snappedf(yaw, 0.001)})
    return {"type": "frame", "t": snappedf(elapsed, 0.001), "walkers": list}

# pos は m、rot は回転（ラジアン、Godot の YXZ の順）、fov は縦の画角（度）、size は画面のピクセル数。カメラが無ければ null
func camera_json() -> Variant:
    var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
    if cam == null:
        return null
    var p := cam.global_position
    var r := cam.global_rotation
    var size := get_viewport().get_visible_rect().size
    return {"pos": [snappedf(p.x, 0.001), snappedf(p.y, 0.001), snappedf(p.z, 0.001)],
        "rot": [snappedf(r.x, 0.0001), snappedf(r.y, 0.0001), snappedf(r.z, 0.0001)],
        "fov": snappedf(cam.fov, 0.01), "size": [int(size.x), int(size.y)]}

func _stream(delta: float) -> void:
    _json_wait -= delta
    if _json_wait > 0.0:
        return
    _json_wait += json_interval
    var cam: Variant = camera_json()
    if cam != _last_camera:
        _last_camera = cam
        _emit({"type": "camera", "t": snappedf(elapsed, 0.001), "camera": cam})
    _emit(frame_json())

func _spawn_obstacles(rects_2d: Array[Rect2]) -> void:
    obstacle_rects.clear()
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.45, 0.45, 0.5)
    for r in rects_2d:
        var p := Geometry.to_world(r.position)
        var size := Vector3(r.size.x * Geometry.PX, obstacle_height, r.size.y * Geometry.PX)
        obstacle_rects.append(Rect2(p.x, p.z, size.x, size.z))

        var body := StaticBody3D.new()
        body.position = p + size * 0.5
        var box := BoxMesh.new()
        box.size = size
        var mesh := MeshInstance3D.new()
        mesh.mesh = box
        mesh.material_override = material
        var box_shape := BoxShape3D.new()
        box_shape.size = size
        var shape := CollisionShape3D.new()
        shape.shape = box_shape
        body.add_child(mesh)
        body.add_child(shape)
        add_child(body)
    for g in groups:
        if g.fence and g.join_line:
            _spawn_fence(g)
    # 一番大きい人が通れる所だけを通れることにする
    var max_jitter := 0.0
    for g in groups:
        max_jitter = maxf(max_jitter, g.size_jitter)
    nav_grid = Geometry.make_grid(obstacle_rects, Vector2(spawn_half_x, spawn_half_z), body_radius * (1.0 + max_jitter))

# 規制線: 列の線の左右（ぶれ幅 + 一番大きい人の半径の外）。見た目は列の線と同じ床の線（Space で消える）
# 当たりは小さな矩形を重ねて並べた障害物で、迂回・押し出しが効く。列の人は障害物に押し出されないので、中を進める。始点と終点は開いている
# shortcut: 終点が開いているので、列に沿って歩く人は終点から規制線の中を通り抜けられる。気になれば終点に矩形を並べて塞ぐ
# shortcut: 矩形の並び（20 m の列で約 200 個）で、segment_clear が矩形の数に比例して重い。遅ければ線分の障害物にする
# shortcut: 曲がりの半径が規制線の幅より小さい所では、内側の規制線が列に食い込む。急な曲がりの列を使うなら線分で引き直す
func _spawn_fence(g: Group) -> void:
    var off := g.lateral_jitter + body_radius * (1.0 + g.size_jitter) + FENCE_SIZE
    for side in [-1.0, 1.0]:
        var pts: Array[Vector3] = []
        # 間隔を矩形の一辺と同じにして重ねる（斜めの線でもすき間ができない）
        # pos(s) は終点から 0.05 m 以内だと向きが取れない（中心線の上に乗る）ので、そこまで
        for i in range(int((g.length - 0.05) / FENCE_SIZE) + 1):
            var p := g.pos(i * FENCE_SIZE, side * off)
            pts.append(p)
            obstacle_rects.append(Rect2(p.x - FENCE_SIZE * 0.5, p.z - FENCE_SIZE * 0.5, FENCE_SIZE, FENCE_SIZE))
        _draw_3d_line(pts, FENCE_COLOR)

# 当たり判定の半径。列に並んでいる人は動物体の line_margin だけ太い
func hit_radius(w: Walker) -> float:
    return w.radius + groups[w.group].line_margin if w.state == State.ON_LINE else w.radius

# models に1人分ずつ {scene, scale, lift, lib, speed} を入れる
# - scale・lift: 身長を human_height にそろえ、足を y = 0 に置く。カプセルは太さもぶつかる半径に合わせる
# - lib: "walk"・"idle" の入った AnimationLibrary（無ければ null）。speed: walk を等速で流したときの歩く速さ
func _load_models() -> void:
    models.clear()
    var paths: Array[String] = []
    if use_simple_model:
        paths.append(SIMPLE_MODEL_PATH)
    else:
        # res:// はプロジェクトに取り込んだもの。それ以外（./mixamo など）は FBX ファイルをそのまま読む
        var model_dir := DirAccess.open(human_model_dir)
        if model_dir == null:
            paths.append(SIMPLE_MODEL_PATH)
        else:
            var files := ResourceLoader.list_directory(human_model_dir) if human_model_dir.begins_with("res://") else DirAccess.get_files_at(human_model_dir)
            for f in files:
                if f.get_basename().ends_with("_Walking") and f.get_extension().to_lower() == "fbx":
                    paths.append(human_model_dir.path_join(f))
    for path in paths:
        var scene := _load_scene(path)
        if scene == null:
            continue
        var probe: Node = scene.instantiate()
        var box := _model_bounds(probe)
        var m := {"scene": scene, "scale": Vector3.ONE, "lift": 0.0, "lib": null, "speed": 0.0}
        if box.size.y > 0.0:
            var k := human_height / box.size.y
            m["scale"] = Vector3(body_radius * 2.0 / box.size.x, k, body_radius * 2.0 / box.size.z) if use_simple_model else Vector3.ONE * k
            m["lift"] = -box.position.y * k
        var walk := _mixamo_anim(path)
        var idle := _mixamo_anim(path.get_basename().trim_suffix("_Walking") + "_Idle." + path.get_extension())
        if walk and idle:
            m["speed"] = _strip_root_motion(walk) * m["scale"].y
            var lib := AnimationLibrary.new()
            lib.add_animation("walk", walk)
            lib.add_animation("idle", idle)
            m["lib"] = lib
        probe.free()
        models.append(m)

# res:// なら取り込んだシーン、それ以外は FBX ファイルを実行中に読む（Godot に取り込まなくてよい。書き出したアプリでも使える）
# ponytail: FBX を実行中に読むのは1ファイル約 1.5 秒。読むのはアプリを起動して最初の1回だけ（2回目からは _scenes を使う）。
# アプリを開いたまま FBX を差し替えても読み直さない。起動のたびに読むのが遅ければ .scn に書き出して使う
func _load_scene(path: String) -> PackedScene:
    if not _scenes.has(path):
        var scene: PackedScene = null
        if path.begins_with("res://"):
            scene = load(path) as PackedScene if ResourceLoader.exists(path) else null
        elif FileAccess.file_exists(path):
            var doc := FBXDocument.new()
            var state := FBXState.new()
            if doc.append_from_file(path, state) == OK:
                var root := doc.generate_scene(state)
                if root:
                    scene = PackedScene.new()
                    scene.pack(root)
                    root.free()
        if scene == null:
            push_warning("3Dモデルを読み込めません: " + path)
        _scenes[path] = scene
    return _scenes[path]

# Mixamo の FBX は動きが "mixamo_com" に入っている（"Take 001" は T ポーズ）
func _mixamo_anim(path: String) -> Animation:
    if path.get_extension().to_lower() != "fbx":
        return null
    var scene := _load_scene(path)
    var n: Node = scene.instantiate() if scene else null
    var ap := n.get_node_or_null("AnimationPlayer") as AnimationPlayer if n else null
    var anim: Animation = ap.get_animation("mixamo_com").duplicate() if ap and ap.has_animation("mixamo_com") else null
    if n:
        n.free()
    if anim:
        anim.loop_mode = Animation.LOOP_LINEAR
    return anim

# 歩くアニメーションは腰が前へ進む。位置はシミュレーションが決めるので、腰の前後左右の動きを消す
# 戻り値: 消した動きの速さ（モデルの単位/秒）
func _strip_root_motion(anim: Animation) -> float:
    for i in range(anim.get_track_count()):
        if anim.track_get_type(i) != Animation.TYPE_POSITION_3D or not String(anim.track_get_path(i)).ends_with("Hips"):
            continue
        var n := anim.track_get_key_count(i)
        var first: Vector3 = anim.track_get_key_value(i, 0)
        var moved: Vector3 = anim.track_get_key_value(i, n - 1) - first
        for k in range(n):
            var v: Vector3 = anim.track_get_key_value(i, k)
            anim.track_set_key_value(i, k, Vector3(first.x, v.y, first.z))
        return Vector2(moved.x, moved.z).length() / anim.length
    return 0.0

# モデルの全メッシュを囲む箱（モデルの根元の座標で）。ツリーの外でも測れるよう親をたどる
func _model_bounds(root: Node) -> AABB:
    var box := AABB()
    for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
        var t := mi.transform
        var p := mi.get_parent()
        while p != root and p is Node3D:
            t = (p as Node3D).transform * t
            p = p.get_parent()
        var b := t * mi.get_aabb()
        box = b if box.size == Vector3.ZERO else box.merge(b)
    return box

func _make_walker() -> Walker:
    var w := Walker.new()
    w.node = Node3D.new()
    add_child(w.node)

    var m: Dictionary = models[vis_rng.randi() % models.size()]
    var inst: Node3D = m["scene"].instantiate()
    inst.scale = m["scale"]
    inst.position.y = m["lift"]
    w.node.add_child(inst)
    if m["lib"]:
        w.anim = inst.get_node("AnimationPlayer")
        w.anim.add_animation_library("sim", m["lib"])
        w.anim_speed = m["speed"]
        w.anim_phase = vis_rng.randf()
    return w

func _spawn_pedestrians() -> void:
    for w in walkers + pending:
        w.node.queue_free()
    walkers.clear()
    pending.clear()

    _load_models()
    if models.is_empty():
        print("エラー: 3Dモデルが見つかりません -> ", human_model_dir)
        return

    for gi in range(groups.size()):
        for i in range(groups[gi].pedestrian_count):
            var w := _make_walker()
            w.group = gi
            w.spawn_delay = i * groups[gi].spawn_interval
            if w.spawn_delay > 0.0:
                w.node.visible = false
                pending.append(w)
            else:
                _respawn(w)
                walkers.append(w)

# 出現の間隔が来た人を登場させる
func _spawn_pending(delta: float) -> void:
    for w in pending.duplicate():
        w.spawn_delay -= delta
        if w.spawn_delay <= 0.0:
            pending.erase(w)
            _respawn(w)
            w.node.visible = true
            walkers.append(w)

# 出現範囲のどこか。障害物の中と列のそば（そこで消えたり現れたりしないように）を避ける
func _random_point() -> Vector3:
    var p := Vector3.ZERO
    for _i in range(30):
        p = Vector3(rng.randf_range(-spawn_half_x, spawn_half_x), 0.0, rng.randf_range(-spawn_half_z, spawn_half_z))
        if Geometry.push_out_of_rects(p, body_radius, obstacle_rects) == p and _far_from_lines(p):
            break
    return p

func _far_from_lines(p: Vector3) -> bool:
    for g in groups:
        if g.join_line and g.curve.get_closest_point(p).distance_to(p) < g.lateral_jitter + LINE_CLEAR:
            return false
    return true

# 動物体に出現する場所の線があればその上、無ければ出現範囲のどこか。ほかの人と重ならない所を探す
func _find_spawn_point(me: Walker) -> Vector3:
    var g := groups[me.group]
    var p := Vector3.ZERO
    for _i in range(30):
        p = g.spawn_at(rng.randf()) if g.spawn_curve.point_count > 0 else _random_point()
        var ok := true
        for o in walkers:
            if o != me and o.node.position.distance_to(p) < body_radius * 3.0:
                ok = false
                break
        if ok:
            return p
    return p

# 所属する動物体が「列に並ぶ」なら列へ、そうでなければ動きのスクリプトへ
func _respawn(w: Walker) -> void:
    w.id = _next_id
    _next_id += 1
    w.node.position = _find_spawn_point(w)
    w.last_pos = w.node.position  # 移り先までの移動を歩く速さと見なさない
    w.velocity = Vector3.ZERO
    w.s = 0.0
    w.path.clear()
    w.replan = 0.0
    w.heading = Vector3.ZERO
    w.direction = Vector3.ZERO
    w.waited = 0.0
    w.via = Vector2i(-1, 0)
    w.reroute = 0.0

    var g := groups[w.group]
    w.line_priority = g.random_line_priority(rng)
    w.cross_priority = g.random_cross_priority(rng)
    w.speed = g.walk_speed * (1.0 + rng.randf_range(-g.speed_jitter, g.speed_jitter))
    var size := 1.0 + rng.randf_range(-g.size_jitter, g.size_jitter)
    w.radius = body_radius * size
    w.node.scale = Vector3.ONE * size  # 見た目も同じ割合で
    w.gap = g.random_gap(rng)  # スクリプトの人も {"line": true} で列に並べる
    w.lateral_offset = rng.randf_range(-g.lateral_jitter, g.lateral_jitter)
    w.memory = {}
    w.param = g.params
    w.state = State.SCRIPTED if g.script_obj else State.TO_LINE

# 障害物に囲まれていない（経路の終点がゴールそのもの）
func _reachable(from: Vector3, to: Vector3) -> bool:
    var path := Geometry.find_path(nav_grid, Vector2(from.x, from.z), Vector2(to.x, to.z), obstacle_rects, body_radius * 0.9)
    return not path.is_empty() and path[-1] == Vector2(to.x, to.z)

func _get_tail(group: int) -> Walker:
    var tail: Walker = null
    for o in walkers:
        if o.state == State.ON_LINE and o.group == group and (tail == null or o.s < tail.s):
            tail = o
    return tail

func _face(w: Walker, dir: Vector3) -> void:
    dir.y = 0.0
    if dir.length_squared() > 0.000001:
        w.node.rotation.y = atan2(dir.x, dir.z) + deg_to_rad(model_yaw_offset_deg)

# ahead_s: 列で自分のすぐ前の人の位置（いなければ INF）。その人の gap 後ろより前へは進まない
# （前の人が道を譲って止まったとき、後ろの人が通り抜けて重ならないように）
func _update_line_member(w: Walker, delta: float, ahead_s: float) -> void:
    var line := groups[w.group]  # 所属する動物体の列
    # 規制線の列では、前の人とのあいだが空いていれば歩く速さで詰める（始点から入った人が、離れた最後尾まで列の速さで進み続けないように）
    # 規制線の無い列では詰めない（最後尾が速く動くと、並びに行く人が追いかけてウロウロする）
    var current_speed := 0.0 if crossing.line_must_yield(w) else (maxf(line.line_speed, w.speed) if line.fence and ahead_s < INF else line.line_speed)

    w.s = maxf(w.s, minf(w.s + current_speed * delta, ahead_s - w.gap))  # 下がりはしない
    if w.s >= line.length:
        _respawn(w)
        return

    # 自分の lateral_offset を適用した座標へ。列に入った直後のずれは、歩く速さで詰める（瞬間移動しない）
    # velocity は実際に動いた分（ほかの人が先読みに使う）
    var p := line.pos(w.s, w.lateral_offset)
    var before := w.node.position
    w.node.position = w.node.position.move_toward(p, (current_speed + w.speed) * delta)
    w.velocity = (w.node.position - before) / delta

    # 向きは中心線（オフセットなし）の進行方向を向かせる
    _face(w, crossing.line_dir(w))

func _update_joiner(w: Walker, delta: float) -> void:
    var line := groups[w.group]  # 所属する動物体の列
    var tail := _get_tail(w.group)
    var slot_s := 0.0
    if line.fence:
        # イベント会場の並び: 必ず始点から入る（横から割り込まない）。最後尾が始点より手前まで伸びていれば、その後ろ
        slot_s = minf(0.0, tail.s - w.gap) if tail else 0.0
    else:
        # 店に入る並び: 最後尾の後ろ。列が空なら始点、join_nearest なら一番近い所から入る（店の扉に入るような動き）
        slot_s = tail.s - w.gap if tail else (line.curve.get_closest_offset(w.node.position) if line.join_nearest else 0.0)

    # 最後尾の後ろの近くまで来たら列に入る。ずれは列に入ってから歩いて詰める（_update_line_member）
    # （ぴったりの位置まで来ないと入れないと、動いている最後尾に寄りきれない人がたまって団子になる）
    # 最後尾より後ろにいるときだけ（横や前から入ると、詰めるときに最後尾の人を通り抜ける）
    var slot := line.pos(slot_s, w.lateral_offset)
    var behind := tail == null or (w.node.position - tail.node.position).dot(crossing.line_dir(tail)) <= -(w.radius + tail.radius)
    # 障害物越し（規制線の外の入口の脇など）には入らない。列の人は押し出されないので、入ると柵をすり抜ける
    var from := Vector2(w.node.position.x, w.node.position.z)
    if behind and w.node.position.distance_to(slot) <= JOIN_RADIUS and Geometry.segment_clear(from, Vector2(slot.x, slot.z), obstacle_rects, w.radius * 0.9):
        w.state = State.ON_LINE
        w.s = slot_s
        return

    # 最後尾は列の速さで遠ざかる。それより速く歩かないと追いつけない。列を横切るときは優先度で待つ
    var k := crossing.crosser_speed(w, delta)
    steering.steer(w, crossing.wait_goal(w, crossing.aim(w, routes.route(w, slot, delta)), k), maxf(w.speed, line.line_speed * CATCH_UP) * k, delta, tail)

# 動きのスクリプトの step() が行き先と速さを決める。列を横切るときの待ち・譲り、二本の経路、よける動き、障害物の迂回は本体が受け持つ
# 戻り値: {"goal": Vector3, "speed": float}（speed を省くと me.speed）/ {"line": true} 列に並ぶ / {"respawn": true} 消えて出現地から現れ直す
func _update_scripted(w: Walker, delta: float) -> void:
    var g := groups[w.group]
    var r: Variant = g.script_obj.step(w, _world, rng, delta)
    if not r is Dictionary:
        if not _step_warned.has(w.group):
            _step_warned[w.group] = true
            push_warning("%s の %s の step() が Dictionary を返していません（その場で止めます）: %s" % [g.name, g.motion, r])
        r = {"goal": w.node.position, "speed": 0.0}
    if r.get("respawn", false):
        _respawn(w)
        return
    if r.get("line", false) and g.join_line:
        w.state = State.TO_LINE
        return
    var goal: Vector3 = r.get("goal", w.node.position)
    goal.y = 0.0
    # 列の人のほうが優先度が高ければ、列の手前で止まって待つ（向かう向きは保つ）
    var k := crossing.crosser_speed(w, delta)
    steering.steer(w, crossing.wait_goal(w, crossing.aim(w, routes.route(w, goal, delta)), k), float(r.get("speed", w.speed)) * k, delta, null)

func _draw_3d_line(points_3d: Array[Vector3], color := Color(1.0, 0.1, 0.1)) -> void:
    var line_mesh_instance := MeshInstance3D.new()
    var immediate_mesh = ImmediateMesh.new()
    var material = StandardMaterial3D.new()

    material.albedo_color = color
    material.emission_enabled = true
    material.emission = color
    material.emission_energy_multiplier = 3.0
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

    immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, material)
    for p in points_3d:
        immediate_mesh.surface_add_vertex(Vector3(p.x, 0.02, p.z))
    immediate_mesh.surface_end()

    line_mesh_instance.mesh = immediate_mesh
    add_child(line_mesh_instance)
    _debug_lines.append(line_mesh_instance)

# 物理の刻み（既定 1/60 秒）で進める。描画のフレームレートに左右されないので、シードで再現できる
func _physics_process(delta: float) -> void:
    if not is_simulating:
        return
    _spawn_pending(delta)

    # 1. 列の人は先頭から順に動かす（後ろの人が前の人の位置を見られるように）
    for gi in range(groups.size()):
        var members := walkers.filter(func(w: Walker) -> bool: return w.group == gi and w.state == State.ON_LINE)
        members.sort_custom(func(a: Walker, b: Walker) -> bool: return a.s > b.s)
        var ahead_s := INF
        for w: Walker in members:
            _update_line_member(w, delta, ahead_s)
            if w.state == State.ON_LINE:  # 列の終わりで現れ直した人は、もう前の人ではない
                ahead_s = w.s

    # 2. 列に並んでいない人の移動
    routes.update_spans()
    for w in walkers:
        match w.state:
            State.TO_LINE:
                _update_joiner(w, delta)
            State.SCRIPTED:
                _update_scripted(w, delta)

    # 3. 移動後に全歩行者同士の接触・めり込みを1括補正
    steering.resolve_all_overlaps()
    _animate(delta)
    elapsed += delta
    if json_interval > 0.0:
        _stream(delta)

# 見た目だけ: 1刻みで動いた距離から歩く速さを出し、足の動きを合わせる。止まったら立ち止まりへ
func _animate(delta: float) -> void:
    for w in walkers:
        if w.anim == null or not w.anim.is_inside_tree():
            continue
        var off := w.node.position - w.last_pos
        off.y = 0.0
        w.last_pos = w.node.position
        w.anim_v = lerpf(w.anim_v, off.length() / delta, 0.2)  # 押し出しによるがたつきをならす
        var stride := w.anim_speed * w.node.scale.x  # 大きい人は歩幅も大きい
        # 歩き始めと止まりの境目を少しずらし、境目の速さで切り替わり続けないようにする
        var walking := w.anim_v > stride * (0.1 if w.anim.current_animation == "sim/walk" else 0.2)
        var anim_name := "sim/walk" if walking else "sim/idle"
        if w.anim.current_animation != anim_name:
            var first := not w.anim.is_playing()
            w.anim.play(anim_name, 0.0 if first else 0.3)
            if first:
                w.anim.seek(w.anim_phase * w.anim.current_animation_length, true)
        w.anim.speed_scale = w.anim_v / stride if walking and stride > 0.0 else 1.0

func _unhandled_input(event: InputEvent) -> void:
    if not (event is InputEventKey and event.pressed):
        return
    # + と - で時刻を 30 分ずつ（押し続けると連続で）。日本語配列の「;」キー（Shift で +）でも進む
    var c := char(event.unicode)
    if c in ["+", ";", "="] or event.keycode == KEY_KP_ADD:
        sun_hour = fposmod(sun_hour + 0.5, 24.0)
        _apply_sun()
    elif c == "-" or event.keycode == KEY_KP_SUBTRACT:
        sun_hour = fposmod(sun_hour - 0.5, 24.0)
        _apply_sun()
    elif not event.echo and event.keycode == KEY_SPACE:  # 操作説明のパネル（CameraController）と一緒に切り替わる
        for n in _debug_lines:
            n.visible = not n.visible
    elif not event.echo and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
        get_tree().change_scene_to_file(DRAW_SCENE_PATH)
