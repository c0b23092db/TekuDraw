extends Node3D

const Config := preload("res://script/core/Config.gd")
const Geometry := preload("res://script/utils/Geometry.gd")
const CameraFit := preload("res://script/utils/CameraFit.gd")
const SceneStore := preload("res://script/core/SceneStore.gd")
const CameraController := preload("res://script/scene/CameraController.gd")
const Walker := preload("res://script/models/Walker.gd")
const Group := preload("res://script/models/Group.gd")
const Motion := preload("res://script/core/Motion.gd")
const State := Walker.State

const DRAW_SCENE_PATH := "res://scene/draw.tscn"
const SIMPLE_MODEL_PATH := "res://objects/sukuea.tscn"  # 「3Dモデルを使わない」ときのカプセル
# 長さの単位は m
const JOIN_RADIUS: float = 1.0      # 最後尾の後ろの位置にこの距離まで近づいたら列に合流
const LOOK_AHEAD: float = 0.15      # 列の進む向きを、この距離だけ先の点で見る
const CATCH_UP: float = 1.3         # 列に並びに行く人は、少なくとも列の速さのこの倍で歩く
const LINE_CONTACT: float = 0.3     # 列に並んでいない人は、列の人とのすき間がこれより狭いときだけよける
const LINE_CLEAR: float = 1.5      # ランダムに歩く人の目的地・現れる所は、列の線（左右のぶれ幅の外側）からこれ以上離す
const ROUND_MARGIN: float = 1.0    # 列の端を回り込むときは、先頭・最後尾の人からこれだけ先の点を通る
const CROSS_NEAR: float = 1.0       # 横切る人は、列の人とのすき間が yield_distance + これより狭くなると遅くなり始める（待ち始めたら、これより広がるまで待つ）

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
var yield_distance: float
var camera_pitch_deg: float
var camera_fov: float
var camera_margin: float
var random_seed: int
var two_routes: bool

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
var _scenes := {}                       # パス → PackedScene（_load_scene の読み込み済み）
var _controller: CameraController
var _env: Environment
var _debug_lines: Array[Node3D] = []  # 列の線。データセットに映らないよう Space で消せる
var _spans: Array = []  # 列ごとの人がいる区間（_occupied）
var _world: Motion.World  # 動きのスクリプトに渡す窓口
var _step_warned := {}    # 動物体 → step() の戻り値がおかしいと一度だけ警告した

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
    if cam:
        var fixed := SceneStore.load_camera(cam)
        if fixed:
            cam.fov = camera_fov
        else:
            _fit_camera(cam)
        _controller = CameraController.new(cam, _fit_camera.bind(cam))
        add_child(_controller)
        _controller.set_status(fixed)
    _apply_sun()
    if replay:
        print("リプレイ: ", SceneStore.current_replay)
        setup_simulation(replay["objects"], replay["obstacles"], replay.get("motions", {}))
    else:
        setup_simulation(SceneStore.load_objects(), SceneStore.load_obstacles())

func _fit_camera(cam: Camera3D) -> void:
    CameraFit.fit(cam, spawn_half_x, spawn_half_z, camera_pitch_deg, camera_fov, camera_margin)

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
    _spawn_obstacles(obstacles)
    _spawn_pedestrians()
    is_simulating = true
    return true

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
    # 一番大きい人が通れる所だけを通れることにする
    var max_jitter := 0.0
    for g in groups:
        max_jitter = maxf(max_jitter, g.size_jitter)
    nav_grid = Geometry.make_grid(obstacle_rects, Vector2(spawn_half_x, spawn_half_z), body_radius * (1.0 + max_jitter))

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
# ponytail: FBX を実行中に読むのは1ファイル約 1.5 秒。人数ではなくモデルの数だけかかる
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
    w.node.position = _find_spawn_point(w)
    w.last_pos = w.node.position  # 移り先までの移動を歩く速さと見なさない
    w.velocity = Vector3.ZERO
    w.s = 0.0
    w.path.clear()
    w.replan = 0.0
    w.heading = Vector3.ZERO
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

# --- 物理的重なりを解決する強力な補正（複数回イテレーション） ---
func _resolve_all_overlaps() -> void:
    # 3回繰り返すことで玉突き事故状のめり込みも解消
    for _iter in range(3):
        for i in range(walkers.size()):
            var w1 = walkers[i]
            for j in range(i + 1, walkers.size()):
                var w2 = walkers[j]
                var min_d = w1.radius + w2.radius
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
            w.node.position = Geometry.push_out_of_rects(w.node.position, w.radius, obstacle_rects)

# --- 列の人 w と、列に並んでいない人 o（ランダムに歩く人・並びに行く人）の位置関係 ---
# 並びに行く人も、列の向こう側の最後尾へ向かうときは列を横切る（一直線に突っ込むと、押し返されてその場で揺れ続ける）

# 列の人 w の進む向き（中心線の向き。自分の位置から中心線の先の点へ向けると、左右にずれた人ほど横を向いてしまう）
func _line_dir(w: Walker) -> Vector3:
    var line := groups[w.group]
    return (line.pos(w.s + LOOK_AHEAD) - line.pos(w.s)).normalized()

# 体どうしのすき間（中心の距離だと、半径の合計より短い値では体が重なるまで気づかない）
func _gap(w: Walker, o: Walker) -> float:
    return w.node.position.distance_to(o.node.position) - w.radius - o.radius

# o が w の前方にいるか。in_path なら、w の通り道（w と o の体の幅）の中にいるときだけ
func _ahead(w: Walker, o: Walker, in_path: bool = false) -> bool:
    var my_dir := _line_dir(w)
    var to_other := o.node.position - w.node.position
    to_other.y = 0.0
    return my_dir.dot(to_other) > 0.0 and (not in_path or absf(my_dir.cross(to_other).y) < w.radius + o.radius)

# o が w の前方を横切ろうとしているか（進む向きがほぼ直交している。すき間が reach より狭いときだけ）
# 自分より前を歩く列の人は止まらない。止まった人の前にすき間ができ、横切る人はそこを通れる
func _is_crossing(w: Walker, o: Walker, reach: float) -> bool:
    if o.state == State.ON_LINE or o.heading == Vector3.ZERO or _gap(w, o) >= reach:
        return false
    var my_dir := _line_dir(w)
    return absf(my_dir.dot(o.heading)) < 0.7 and _ahead(w, o)

# 優先度の高いほうが先に通る。同じなら列の人が先。待てる時間を過ぎた人は必ず先に通る
func _cross_value(o: Walker) -> float:
    return INF if o.waited >= groups[o.group].max_wait else o.cross_priority

# 列の人が止まるか: 優先度の高い人が前を横切るとき
# ponytail: 通り道にいる人のためにも止まると、横切る人が何人も集まった所で列が止まり、すき間が詰まって誰も抜けられなくなる。
#           通り道の中の人は止まらずに渡りきるので（_crosser_speed）、ぶつかっても押されるのは一瞬
func _line_must_yield(w: Walker) -> bool:
    for o in walkers:
        if _cross_value(o) > w.line_priority and _is_crossing(w, o, yield_distance):
            return true
    return false

# 横切る人の速さの倍率（0〜1）。先を譲る列の人が近づいてくるときは、すき間が yield_distance + CROSS_NEAR から近づくほど遅くし、
# yield_distance で止まる（全速で近づいていきなり止まると「一瞬止まる」。ゆっくり近づく間に列の人が通り過ぎれば止まらずに済む）
# 待つのは列の人の通り道の外だけ。もう通り道の中にいたら止まらずに渡りきる（通り道で止まると、近づく列の人にぶつかる）
# 横切ろうとして列のそばにいる間は waited を数える（先に通っている間も数え続け、列から離れたら 0 に戻す）
# 向き合っている間だけ数えると、列の人と人のすき間が来るたびに 0 に戻り、待てる時間を過ぎることがない
func _crosser_speed(o: Walker, delta: float) -> float:
    var reach := yield_distance + CROSS_NEAR
    var near := false
    var k := 1.0
    for w in walkers:
        if w.state != State.ON_LINE:
            continue
        var gap := _gap(w, o)
        if gap >= reach:
            continue
        var crossing := _is_crossing(w, o, reach)
        near = near or crossing or o.waited > 0.0
        # 待ち始めた人は、前を横切る向きでなくても、近づいてくる人を待つ（小さなすき間へ踏み出しては止まるのをくり返さない）
        if (crossing or (o.waited > 0.0 and _ahead(w, o))) and _cross_value(o) <= w.line_priority and not _ahead(w, o, true):
            k = minf(k, clampf((gap - yield_distance) / CROSS_NEAR, 0.0, 1.0))
    o.waited = o.waited + delta if near else 0.0
    return k

# ahead_s: 列で自分のすぐ前の人の位置（いなければ INF）。その人の gap 後ろより前へは進まない
# （前の人が道を譲って止まったとき、後ろの人が通り抜けて重ならないように）
func _update_line_member(w: Walker, delta: float, ahead_s: float) -> void:
    var line := groups[w.group]  # 所属する動物体の列
    var current_speed := 0.0 if _line_must_yield(w) else line.line_speed

    w.s = maxf(w.s, minf(w.s + current_speed * delta, ahead_s - w.gap))  # 下がりはしない
    if w.s >= line.length:
        _respawn(w)
        return

    # 自分の lateral_offset を適用した座標へ。列に入った直後のずれは、歩く速さで詰める（瞬間移動しない）
    var p := line.pos(w.s, w.lateral_offset)
    w.node.position = w.node.position.move_toward(p, (current_speed + w.speed) * delta)

    # 向きは中心線（オフセットなし）の進行方向を向かせる
    _face(w, _line_dir(w))

func _steer(w: Walker, goal: Vector3, speed: float, delta: float, ignore: Walker) -> void:
    var pos := w.node.position
    # 障害物で塞がれていたら、経路のうち見通せる一番先の点へ。経路はゴールが動くので 1 秒ごとに引き直す
    var from := Vector2(pos.x, pos.z)
    var wp := Vector2(goal.x, goal.z)
    var clearance := w.radius * 0.9  # 押し出し直後の壁ぎわでも見通せるよう少し小さめ
    if Geometry.segment_clear(from, wp, obstacle_rects, clearance):
        w.replan = 0.0
    else:
        w.replan -= delta
        if w.replan <= 0.0:
            w.path = Geometry.find_path(nav_grid, from, wp, obstacle_rects, clearance)
            w.replan = 1.0
        wp = Geometry.farthest_visible(from, w.path, obstacle_rects, clearance)
    var to_goal := Vector3(wp.x, 0.0, wp.y) - pos
    to_goal.y = 0.0
    var dist := to_goal.length()
    var desired := Vector3.ZERO
    if dist > 0.001:
        w.heading = to_goal / dist
        desired = w.heading * speed

    var avoid := Vector3.ZERO
    for o in walkers:
        if o == w or o == ignore:
            continue
        # 列に並んでいる人は、体が触れそうなときだけよける。列とのやりとりは横切りの決まり（_crosser_speed・_line_must_yield）で決める
        # （遠くからよけると列が壁になり、横切りを判定する距離まで近づけないまま列に沿って流される。
        #   まったくよけないと、止まった列の人に真正面からぶつかったまま回り込めない）
        var reach := w.radius + o.radius + LINE_CONTACT if o.state == State.ON_LINE else avoid_radius
        var off := pos - o.node.position
        off.y = 0.0
        var d := off.length()
        if d >= reach or d < 0.0001:
            continue

        var away := off / d
        var weight := pow(1.0 - d / reach, 2.0) # 近いほど急激に回避力を高める
        var tangent := Vector3(-away.z, 0.0, away.x)
        avoid += (away + tangent * 0.8) * weight

    desired += avoid * speed * avoid_strength
    if desired.length() > speed:
        desired = desired.normalized() * speed

    w.velocity = w.velocity.lerp(desired, 1.0 - exp(-10.0 * delta))
    w.node.position += w.velocity * delta
    w.node.position.y = 0.0
    _face(w, w.velocity)

func _update_joiner(w: Walker, delta: float) -> void:
    var line := groups[w.group]  # 所属する動物体の列
    var tail := _get_tail(w.group)
    # 列が空なら、始点から並ぶ。join_nearest なら一番近い所から入る（店の扉に入るような動き）
    var slot_s := tail.s - w.gap if tail else (line.curve.get_closest_offset(w.node.position) if line.join_nearest else 0.0)

    # 最後尾の後ろの近くまで来たら列に入る。ずれは列に入ってから歩いて詰める（_update_line_member）
    # （ぴったりの位置まで来ないと入れないと、動いている最後尾に寄りきれない人がたまって団子になる）
    # 最後尾より後ろにいるときだけ（横や前から入ると、詰めるときに最後尾の人を通り抜ける）
    var slot := line.pos(slot_s, w.lateral_offset)
    var behind := tail == null or (w.node.position - tail.node.position).dot(_line_dir(tail)) <= -(w.radius + tail.radius)
    if behind and w.node.position.distance_to(slot) <= JOIN_RADIUS:
        w.state = State.ON_LINE
        w.s = slot_s
        return

    # 最後尾は列の速さで遠ざかる。それより速く歩かないと追いつけない。列を横切るときは優先度で待つ
    var k := _crosser_speed(w, delta)
    _steer(w, _wait_goal(w, _route(w, slot, delta), k), maxf(w.speed, line.line_speed * CATCH_UP) * k, delta, tail)

# --- 二本の経路: 列の人の間を通り抜ける道と、列の端を回り込む道のうち、コストの小さいほうを通る ---
# コスト = 道のり + 通り抜ける列ごとの cross_cost（人の間を通るときだけ。人のいない線の部分は 0）
# 1 秒ごとに決め直す。回り込むときは列の端の先の点へ寄ってからゴールへ（端の点は列と一緒に動く）
# 今の道より ROUND_MARGIN 以上安くならないと乗り換えない（列が動くたびに道を替えて行ったり来たりしないように）
# ponytail: 道のりは直線距離で比べる（障害物の迂回は見ない）。回り込む点は1つだけ（S 字の列を何度も回り込む道は作らない）
func _route(w: Walker, goal: Vector3, delta: float) -> Vector3:
    if not two_routes:
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
    return _leg_cost(pos, via) + _leg_cost(via, goal) if via != null else _leg_cost(pos, goal)

# 回り込む候補（人が2人以上いる列の、両端）
func _ends() -> Array[Vector2i]:
    var out: Array[Vector2i] = []
    for g in range(groups.size()):
        if not _occupied(g).is_empty():
            out.append_array([Vector2i(g, 0), Vector2i(g, 1)])
    return out

# 回り込む点: 最後尾の後ろ・先頭の前へ ROUND_MARGIN + 左右のぶれ幅。まっすぐ（x = -1）や、2人未満の列なら null
func _via_point(c: Vector2i) -> Variant:
    if c.x < 0 or _occupied(c.x).is_empty():
        return null
    var span: Array = _occupied(c.x)
    var margin := ROUND_MARGIN + groups[c.x].lateral_jitter
    var g := groups[c.x]
    return g.pos(span[0] - margin - g.spacing_max if c.y == 0 else span[1] + margin)

# 列 g の人がいる区間 [最後尾の s, 先頭の s]。2人未満なら空（刻みごとに _update_spans で作る）
func _occupied(g: int) -> Array:
    return _spans[g]

func _update_spans() -> void:
    _spans.clear()
    for g in range(groups.size()):
        var lo := INF
        var hi := -INF
        var n := 0
        for o in walkers:
            if o.group == g and o.state == State.ON_LINE:
                lo = minf(lo, o.s)
                hi = maxf(hi, o.s)
                n += 1
        _spans.append([lo, hi] if n >= 2 else [])

func _leg_cost(a: Vector3, b: Vector3) -> float:
    var cost := a.distance_to(b)
    var a2 := Vector2(a.x, a.z)
    var b2 := Vector2(b.x, b.z)
    for g in range(groups.size()):
        var span := _occupied(g)
        if span.is_empty():
            continue
        # 人がいる区間の中心線を 0.5 m ごとの折れ線にして、列の幅（左右のぶれ + 体の半径）より近くを通るか調べる
        # （交わるかだけを見ると、列の端から中心線に沿って列の中を進む道を見逃す）
        var band := groups[g].lateral_jitter + body_radius
        var prev: Vector3 = groups[g].pos(span[0])
        var s: float = span[0]
        while s < span[1]:
            s = minf(s + 0.5, span[1])
            var p: Vector3 = groups[g].pos(s)
            var pq := Geometry2D.get_closest_points_between_segments(a2, b2, Vector2(prev.x, prev.z), Vector2(p.x, p.z))
            if pq[0].distance_to(pq[1]) < band:
                cost += groups[g].cross_cost
                break
            prev = p
    return cost

# 横切るのを待って遅くなっている間は、向きを変えずにまっすぐ止まる
# （動いている最後尾へ向き直りながらゆっくり進むと、その場で行ったり来たりして見える）
func _wait_goal(w: Walker, goal: Vector3, k: float) -> Vector3:
    return goal if k >= 1.0 or w.heading == Vector3.ZERO else w.node.position + w.heading

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
    var k := _crosser_speed(w, delta)
    _steer(w, _wait_goal(w, _route(w, goal, delta), k), float(r.get("speed", w.speed)) * k, delta, null)

func _draw_3d_line(points_3d: Array[Vector3]) -> void:
    var line_mesh_instance := MeshInstance3D.new()
    var immediate_mesh = ImmediateMesh.new()
    var material = StandardMaterial3D.new()

    material.albedo_color = Color(1.0, 0.1, 0.1)
    material.emission_enabled = true
    material.emission = Color(1.0, 0.1, 0.1)
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
    _update_spans()
    for w in walkers:
        match w.state:
            State.TO_LINE:
                _update_joiner(w, delta)
            State.SCRIPTED:
                _update_scripted(w, delta)

    # 3. 移動後に全歩行者同士の接触・めり込みを1括補正
    _resolve_all_overlaps()
    _animate(delta)

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
    elif not event.echo and event.keycode == KEY_SPACE:  # 操作説明（CameraController）と一緒に切り替わる
        for n in _debug_lines:
            n.visible = not n.visible
    elif not event.echo and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
        get_tree().change_scene_to_file(DRAW_SCENE_PATH)
