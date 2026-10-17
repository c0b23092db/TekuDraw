# godot --headless --path . --script res://test/test_models.gd
# res://objects/mixamo の人のモデル: 身長がそろい、歩きと立ち止まりがあり、腰の前進が消えているか
# objects/ は git に入っていないので、無ければ飛ばす
extends SceneTree

const Mgr := preload("res://script/SimulationManager3D.gd")

func _initialize() -> void:
    var mgr: Node3D = Mgr.new()
    mgr.human_model_dir = "res://objects/mixamo"
    mgr.human_height = 1.7
    mgr._load_models()
    if mgr.models.is_empty():
        print("test_models: SKIP（", mgr.human_model_dir, " にモデルが無い）")
        mgr.free()
        quit(0)
        return
    var ok := true
    for m in mgr.models:
        var n: Node3D = m["scene"].instantiate()
        var h: float = mgr._model_bounds(n).size.y * m["scale"].y
        n.free()
        var lib: AnimationLibrary = m["lib"]
        var walk := lib.get_animation("walk") if lib else null
        var hips := -1
        if walk:
            for i in range(walk.get_track_count()):
                if walk.track_get_type(i) == Animation.TYPE_POSITION_3D and String(walk.track_get_path(i)).ends_with("Hips"):
                    hips = i
        var moved := Vector3.ZERO
        if hips >= 0:
            moved = walk.track_get_key_value(hips, walk.track_get_key_count(hips) - 1) - walk.track_get_key_value(hips, 0)
        var good: bool = absf(h - 1.7) < 0.01 and lib != null and lib.has_animation("idle") \
            and hips >= 0 and Vector2(moved.x, moved.z).length() < 0.001 and m["speed"] > 0.5 and m["speed"] < 3.0
        if not good:
            print("NG ", m["scene"].resource_path, " 身長=", h, " 歩く速さ=", m["speed"])
        ok = ok and good
    print("test_models: ", "OK" if ok else "FAIL", "（", mgr.models.size(), " 人）")
    mgr.free()
    quit(0 if ok else 1)
