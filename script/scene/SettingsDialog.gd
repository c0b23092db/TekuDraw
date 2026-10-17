# 設定項目（Config.FIELDS と同じ形式）から入力欄を並べて編集するポップアップ
# 左: 分類（セクション）の一覧 / 右: 選んだ分類の項目。分類が1つなら左は出さない
# 数値は SpinBox（範囲・単位つき）、真偽値は CheckBox、"choices" は OptionButton、それ以外は LineEdit。説明（hint）はマウスを重ねると出る
# "choices": "motion" の項目（動き）を変えると、fields_for(今の値) で項目を作り直す（スクリプトごとの項目が入れ替わる）
# ダイアログを横に広げると入力欄が伸びる
extends AcceptDialog

const Motion := preload("res://script/core/Motion.gd")

var _sections := ItemList.new()
var _scroll := ScrollContainer.new()
var _pages := VBoxContainer.new()
var _inputs := {}   # key → 入力欄
var _on_ok: Callable
var _fields_for: Callable  # 今の値 → 項目の一覧（無ければ項目は変わらない）
var _values := {}          # 開いたときの値。作り直すときに、まだ画面に無い項目の値を残す
var _section_labels := {}

func _init() -> void:
    ok_button_text = "保存"
    add_cancel_button("キャンセル")
    var row := HBoxContainer.new()
    add_child(row)
    _sections.custom_minimum_size = Vector2(160, 0)
    _sections.item_selected.connect(_show_page)
    row.add_child(_sections)
    _scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    _scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _scroll.custom_minimum_size = Vector2(460, 360)
    _scroll.add_child(_pages)
    row.add_child(_scroll)
    _pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    confirmed.connect(func() -> void: _on_ok.call(_read_values()))

# section_labels: セクション名 → 左の一覧に出す名前（無いものはセクション名のまま）
# fields_for: 項目を値によって変えるとき（動物体の設定）。fields の代わりに fields_for.call(values) を使う
func open(title_text: String, fields: Array, values: Dictionary, on_ok: Callable, section_labels: Dictionary = {}, fields_for: Callable = Callable()) -> void:
    title = title_text
    _on_ok = on_ok
    _fields_for = fields_for
    _values = values.duplicate()
    _section_labels = section_labels
    _build(fields_for.call(_values) if fields_for.is_valid() else fields)
    popup_centered()

func _build(fields: Array) -> void:
    var page := maxi(0, _sections.get_selected_items()[0]) if _sections.is_anything_selected() else 0
    for c in _pages.get_children():
        c.free()
    _sections.clear()
    _inputs.clear()

    var grids := {}  # セクション → GridContainer（1ページ）
    for f in fields:
        var section: String = f["section"]
        if not grids.has(section):
            var grid := GridContainer.new()
            grid.columns = 2
            grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
            _pages.add_child(grid)
            grids[section] = grid
            _sections.add_item(_section_labels.get(section, section))
        _add_row(grids[section], f, _values.get(f["key"], f["default"]))

    _sections.visible = grids.size() > 1
    page = mini(page, grids.size() - 1)
    _sections.select(page)
    _show_page(page)

# 動きを変えたら項目を作り直す（入力中の値は残す）
func _rebuild() -> void:
    _values.merge(_read_values(), true)
    _build.call_deferred(_fields_for.call(_values))

func _add_row(grid: GridContainer, f: Dictionary, v: Variant) -> void:
    var hint: String = f.get("hint", "")
    var label := Label.new()
    label.text = f["label"] + ("（?）" if hint else "")
    label.tooltip_text = hint
    label.mouse_filter = Control.MOUSE_FILTER_PASS
    grid.add_child(label)

    var input: Control
    if f.has("choices"):
        var ob := OptionButton.new()
        var items: Array = Motion.choices() if f["choices"] == "motion" else f["choices"]
        for item in items:
            ob.add_item(item[1])
            ob.set_item_metadata(ob.item_count - 1, item[0])
            if item[0] == v:
                ob.select(ob.item_count - 1)
        if ob.selected < 0:  # 保存してあるスクリプトが今は無い
            ob.add_item("%s（見つかりません）" % v)
            ob.set_item_metadata(ob.item_count - 1, v)
            ob.select(ob.item_count - 1)
        if _fields_for.is_valid():
            ob.item_selected.connect(func(_i: int) -> void: _rebuild())
        input = ob
    elif typeof(f["default"]) == TYPE_BOOL:
        var cb := CheckBox.new()
        cb.button_pressed = v
        input = cb
    elif f.has("min"):
        var sb := SpinBox.new()
        sb.min_value = f["min"]
        sb.max_value = f["max"]
        sb.step = f["step"]
        sb.rounded = typeof(f["default"]) == TYPE_INT
        sb.suffix = f.get("suffix", "")
        sb.value = v
        sb.custom_minimum_size.x = 140
        input = sb
    else:
        var le := LineEdit.new()
        le.text = str(v)
        le.custom_minimum_size.x = 240
        input = le
    input.tooltip_text = hint
    input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _inputs[f["key"]] = input
    if f.has("filters") or f.get("dir", false):  # ファイル・フォルダを選ぶボタンを横に付ける
        var row := HBoxContainer.new()
        row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        row.add_child(input)
        var pick := Button.new()
        pick.text = "選ぶ…"
        pick.pressed.connect(_pick_file.bind(input, PackedStringArray(f.get("filters", [])), f.get("dir", false)))
        row.add_child(pick)
        input = row
    grid.add_child(input)

func _pick_file(le: LineEdit, filters: PackedStringArray, dir: bool) -> void:
    var fd := FileDialog.new()
    fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR if dir else FileDialog.FILE_MODE_OPEN_FILE
    fd.access = FileDialog.ACCESS_FILESYSTEM
    fd.filters = filters
    fd.use_native_dialog = true
    var pick := func(p: String) -> void:
        le.text = relative_path(p)
        fd.queue_free()
    fd.file_selected.connect(pick)
    fd.dir_selected.connect(pick)
    fd.canceled.connect(fd.queue_free)
    add_child(fd)
    fd.popup_centered_ratio(0.6)

# アプリ（開発中はプロジェクト）のフォルダの中なら ./ から始まる相対パスにする（フォルダごと別の PC に移しても同じ設定で動く）
static func relative_path(p: String) -> String:
    p = p.replace("\\", "/")
    var cwd := DirAccess.open(".").get_current_dir().replace("\\", "/").trim_suffix("/") + "/"
    return "./" + p.substr(cwd.length()) if p.to_lower().begins_with(cwd.to_lower()) else p

func _show_page(index: int) -> void:
    for i in range(_pages.get_child_count()):
        _pages.get_child(i).visible = i == index

func _read_values() -> Dictionary:
    var out := {}
    for key in _inputs:
        var c: Control = _inputs[key]
        if c is OptionButton:
            out[key] = c.get_item_metadata(c.selected)
        elif c is CheckBox:
            out[key] = c.button_pressed
        elif c is SpinBox:
            out[key] = int(c.value) if c.rounded else c.value
        else:
            out[key] = c.text
    return out
