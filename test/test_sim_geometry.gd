# godot --headless --path . --script res://test/test_sim_geometry.gd
extends SceneTree

var Geo: GDScript

func _initialize() -> void:
    Geo = load("res://script/utils/Geometry.gd")
    var rects: Array[Rect2] = [Rect2(0, 0, 10, 4)]

    # 外側で離れている → そのまま
    check(Geo.push_out_of_rects(Vector3(-5, 0, 2), 1.0, rects) == Vector3(-5, 0, 2))
    # 辺に近い → 半径ぶん離れる
    check(Geo.push_out_of_rects(Vector3(-0.5, 0, 2), 1.0, rects).is_equal_approx(Vector3(-1, 0, 2)))
    # 中心が内側 → 一番近い辺（z=0 側）の外へ
    check(Geo.push_out_of_rects(Vector3(5, 0, 0.5), 1.0, rects).is_equal_approx(Vector3(5, 0, -1)))

    # 経路探索: コの字（右が開いた箱）の奥から、箱の左の外へ。最初の角を回っても次の壁がある配置
    var half := Vector2(20, 20)
    var u: Array[Rect2] = [Rect2(-5, -5, 10, 1), Rect2(-5, 4, 10, 1), Rect2(-5, -5, 1, 10)]
    var grid: AStarGrid2D = Geo.make_grid(u, half, 0.5)
    var from := Vector2(-2, 0)
    var goal := Vector2(-10, 0)
    var path: PackedVector2Array = Geo.find_path(grid, from, goal, u, 0.45)
    check(not path.is_empty() and path[-1] == goal)
    check(path.size() <= 4)  # 格子のカクカクは曲がり角だけに減る
    # 経路の各区間が障害物（半径ぶん太らせたもの）を貫通しない
    var prev := from
    for p in path:
        check(Geo.segment_clear(prev, p, u, 0.4))
        prev = p
    # 箱の中からはゴールは見えないので、見通せる経由点はゴール以外
    var wp: Vector2 = Geo.farthest_visible(from, path, u, 0.45)
    check(wp != goal and Geo.segment_clear(from, wp, u, 0.45))
    # 障害物が無ければ見通せる
    check(Geo.segment_clear(from, goal, [] as Array[Rect2], 0.5))

    # 閉じた箱の中のゴール → 途中まで（終点はゴールではない）
    var closed := u.duplicate()
    closed.append(Rect2(4, -5, 1, 10))
    var p2: PackedVector2Array = Geo.find_path(Geo.make_grid(closed, half, 0.5), Vector2(-10, 0), Vector2(0, 0), closed, 0.45)
    check(not p2.is_empty() and p2[-1] != Vector2(0, 0))

    # 設定ファイルの値の補正: 型をそろえる・範囲内に丸める・型違いは既定値
    var Cfg: GDScript = load("res://script/core/Config.gd")
    var f := {"section": "s", "key": "k", "default": 5.0, "min": 0.0, "max": 10.0}
    check(Cfg.sanitize(f, 3) is float and Cfg.sanitize(f, 3) == 3.0)
    check(Cfg.sanitize(f, 99.0) == 10.0)
    check(Cfg.sanitize(f, "abc") == 5.0)

    # 保存ファイルの線の座標: 形が違う要素は捨てる
    var Store: GDScript = load("res://script/core/SceneStore.gd")
    check(Store._to_points([[1, 2], [3], "x", [4.5, 6.0]]) == [Vector2(1, 2), Vector2(4.5, 6)])
    check(Store._to_points("壊れた値") == [])

    # TOML の書き出し→読み込みで値が戻る（文字列のエスケープ・小数・入れ子の配列）
    var Toml: GDScript = load("res://script/core/TomlFile.gd")
    var t: RefCounted = Toml.new()
    var sample := {"s": "日本語\"q\\\n", "f": 2.0, "i": 3, "b": true, "n": [[1.5, 2.0], []]}
    for k in sample:
        t.set_value("x", k, sample[k])
    t.save("user://test_toml.toml")
    var t2: RefCounted = Toml.new()
    check(t2.load("user://test_toml.toml") == OK)
    for k in sample:
        check(str(t2.get_value("x", k)) == str(sample[k]) and typeof(t2.get_value("x", k)) == typeof(sample[k]))
    DirAccess.remove_absolute("user://test_toml.toml")

    # 選んだファイルのパス: アプリのフォルダの中なら ./ からの相対パス、外ならそのまま
    var Dlg: GDScript = load("res://script/scene/SettingsDialog.gd")
    var cwd := DirAccess.open(".").get_current_dir()
    check(Dlg.relative_path(cwd + "/mixamo") == "./mixamo")
    check(Dlg.relative_path(cwd.to_upper().replace("/", "\\") + "\\PIC\\a.png") == "./PIC/a.png")
    check(Dlg.relative_path("Z:/elsewhere/a.png") == "Z:/elsewhere/a.png")

    print("test_sim_geometry: ", "FAIL" if failed else "OK")
    quit(1 if failed else 0)

var failed := false

func check(ok: bool) -> void:
    if not ok:
        failed = true
        push_error("check failed")
        print_stack()
