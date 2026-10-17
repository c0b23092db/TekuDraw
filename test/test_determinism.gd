# godot --headless --path . --script res://test/test_determinism.gd
# 同じシード・同じ設定なら、何度動かしても同じ位置になるか（リプレイの前提）
# リプレイファイルに保存→読み込みしても同じ動きになるか
extends SceneTree

const Mgr := preload("res://script/SimulationManager3D.gd")
const Config := preload("res://script/core/Config.gd")
const SceneStore := preload("res://script/core/SceneStore.gd")

func _initialize() -> void:
    # 障害物・列・ランダム歩行者がそろったシナリオ
    var values := Config.defaults()
    var obj := Config.object_defaults(values)
    var line := obj.duplicate()
    line["name"] = "列"
    line["points"] = [Vector2(300, 300), Vector2(900, 300)]
    line["spawn_interval"] = 0.2
    var walker := obj.duplicate()
    walker["name"] = "散歩"
    walker["points"] = []
    walker["motion"] = "random_walk.gd"
    walker["size_jitter"] = 0.2
    var objects: Array[Dictionary] = [line, walker]
    var obstacles: Array[Rect2] = [Rect2(500, 350, 100, 100)]

    var a := run(values, 123, objects, obstacles)
    var ok := a.size() > 0
    ok = ok and a == run(values, 123, objects, obstacles)
    ok = ok and a != run(values, 456, objects, obstacles)

    # シード 0 で保存 → シードが決まって書き込まれ、読み込んだ内容で同じ動きになる
    var path := SceneStore.save_replay(values, objects, obstacles)
    var r := SceneStore.load_replay(path)
    DirAccess.remove_absolute(path)  # テストで作ったファイル
    var seed_value: int = r["values"]["random_seed"]
    ok = ok and seed_value != 0 and r["objects"].size() == 2 and r["obstacles"] == obstacles
    # 動きのスクリプトはリプレイに保存したソースで動く（./.config/motion を読まない）
    ok = ok and r["motions"].has("random_walk.gd") and r["objects"][1]["motion"] == "random_walk.gd"
    ok = ok and run(r["values"], seed_value, r["objects"], r["obstacles"], r["motions"]) == run(values, seed_value, objects, obstacles)
    # スクリプトの人もちゃんと歩いている（0 秒と 5 秒で位置が違う）
    ok = ok and run(values, 123, objects, obstacles, {}, 0) != a

    print("test_determinism: ", "OK" if ok else "FAIL")
    quit(0 if ok else 1)

# steps 刻み（既定 5 秒）進めて全員の位置を返す
func run(values: Dictionary, seed_value: int, objects: Array[Dictionary], obstacles: Array[Rect2], motions: Dictionary = {}, steps: int = 300) -> Array:
    var mgr: Node3D = Mgr.new()  # ツリーに入れない（_ready で .config を読ませない）
    for key in values:
        if key in mgr:
            mgr.set(key, values[key])
    mgr.random_seed = seed_value
    mgr.setup_simulation(objects, obstacles, motions)
    for _i in range(steps):
        mgr._physics_process(1.0 / 60.0)
    var out := []
    for w in mgr.walkers:
        out.append(w.node.position)
    mgr.free()
    return out
