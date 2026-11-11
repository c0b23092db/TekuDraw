# godot --headless --path . --script res://test/test_settings_dialog.gd
# 設定画面の「詳細」: オフなら詳細の項目を隠す。隠した項目は保存しても既定値に戻らず、開いたときの値のまま返る
extends SceneTree

const Dialog := preload("res://script/scene/SettingsDialog.gd")
const Config := preload("res://script/core/Config.gd")

func _initialize() -> void:
    var values := Config.defaults()
    values["turn_time"] = 1.23       # 詳細の項目（ぶつからない動き）
    values["pedestrian_count"] = 7   # 初心者にも出す項目
    var got := {}
    var d: AcceptDialog = Dialog.new()
    root.add_child(d)
    d.open("t", Config.FIELDS, values, func(v: Dictionary) -> void: got.merge(v), Config.SECTION_LABELS)

    var ok: bool = not d._inputs.has("turn_time") and d._inputs.has("pedestrian_count")
    d.confirmed.emit()
    ok = ok and got.get("turn_time") == 1.23 and got.get("pedestrian_count") == 7

    d._advanced.button_pressed = true  # toggled → _rebuild（call_deferred）
    await process_frame
    ok = ok and d._inputs.has("turn_time")

    print("PASS" if ok else "FAIL: %s" % got)
    quit(0 if ok else 1)
