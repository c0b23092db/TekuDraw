# ConfigFile と同じ使い方で TOML を読み書きする（読むのは addons/toml の TOML.parse_string）
# 書くのは [section] と key = 値（数値・文字列・真偽値・配列）だけ。このプロジェクトの設定はそれで足りる
extends RefCounted

var _data := {}  # セクション → {key → 値}

func load(path: String) -> Error:
    _data.clear()
    if not FileAccess.file_exists(path):
        return ERR_FILE_NOT_FOUND
    var parsed: Variant = TOML.parse_string(FileAccess.get_file_as_string(path))
    if not parsed is Dictionary:
        # 読めないまま上書き保存すると中身が消えるので、元のファイルを残しておく
        DirAccess.copy_absolute(path, path + ".broken")
        push_warning("TOML として読めません（%s.broken に残しました）: %s" % [path, path])
        return ERR_PARSE_ERROR
    for section in parsed:
        if parsed[section] is Dictionary:
            var table := {}
            for key in parsed[section]:
                table[String(key)] = parsed[section][key]
            _data[String(section)] = table
    return OK

func save(path: String) -> Error:
    var out := ""
    for section in _data:
        out += "[%s]\n\n" % section
        for key in _data[section]:
            out += "%s = %s\n" % [key, _value(_data[section][key])]
        out += "\n"
    var f := FileAccess.open(path, FileAccess.WRITE)
    if f == null:
        return FileAccess.get_open_error()
    f.store_string(out)
    return OK

func get_value(section: String, key: String, default: Variant = null) -> Variant:
    return _data.get(section, {}).get(key, default)

func set_value(section: String, key: String, value: Variant) -> void:
    if not _data.has(section):
        _data[section] = {}
    _data[section][key] = value

func get_section_keys(section: String) -> PackedStringArray:
    return PackedStringArray(_data.get(section, {}).keys())

func has_section(section: String) -> bool:
    return _data.has(section)

func erase_section(section: String) -> void:
    _data.erase(section)

func get_sections() -> PackedStringArray:
    return PackedStringArray(_data.keys())

static func _value(v: Variant) -> String:
    match typeof(v):
        TYPE_BOOL:
            return "true" if v else "false"
        TYPE_INT:
            return str(v)
        TYPE_FLOAT:
            var s := str(v)  # 16.0 → "16.0"、1e+20 → "1e+20"。どちらも TOML の小数として読める
            return s if "." in s or "e" in s or "inf" in s or "nan" in s else s + ".0"
        TYPE_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
            return "[" + ", ".join(Array(v).map(_value)) + "]"
        _:
            return JSON.stringify(str(v))  # 文字列。" と \ と改行をエスケープする（TOML の基本文字列と同じ書き方）
