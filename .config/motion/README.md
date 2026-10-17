# 動きのスクリプトの書き方

このフォルダ（`./.config/motion/`）に `.gd` ファイルを置くと、描画画面の動物体の設定「動き」で選べるようになります。
Godot でのコンパイルは不要です。書き出したアプリでも、exe の隣の `.config/motion/` に置けば使えます。

言語は GDScript（Godot のスクリプト言語）です。書き方は Python に近く、インデントでブロックを作ります。
見本は [random_walk.gd](random_walk.gd)（ランダムに歩く）です。AI に書かせるときは、このファイルと見本を渡してください。

## 最小の形

```gdscript
extends RefCounted

const LABEL := "敵"   # 設定画面に出る名前

# 設定画面に出す項目（無くてもよい）。動物体ごとに値を変えられ、step() では me.param["key"] で読む
const FIELDS := [
    {"key": "flee_distance", "label": "逃げ始める距離", "default": 5.0, "min": 0.0, "max": 30.0, "step": 0.5, "suffix": "m", "hint": "マウスを重ねると出る説明"},
    {"key": "shy", "label": "臆病", "default": true},
]

# 1 刻み（1/60 秒）ごとに、1 匹ずつ呼ばれる
func step(me, world, rng: RandomNumberGenerator, delta: float) -> Dictionary:
    return {"goal": me.position + Vector3(1, 0, 0), "speed": me.speed}
```

## FIELDS の書き方
| キー | 意味 |
|---|---|
| `key` | 値の名前（英数字と `_`）。全体の設定の項目名（`walk_speed` など）と同じ名前は使えない |
| `label` | 設定画面に出す名前 |
| `default` | 既定値。型（小数 `5.0`・整数 `5`・真偽値 `true`・文字列 `"a"`）で入力欄が決まる |
| `min`, `max`, `step`, `suffix` | 数値の範囲・刻み・単位（数値のとき。`min` があると数値の入力欄になる） |
| `hint` | 説明（省略可） |

## step() に渡るもの
座標は m。床は XZ 平面で、y は常に 0。`Vector3(x, 0, z)` で表します。

### me（自分）
| 名前 | 意味 |
|---|---|
| `me.position` | 今の位置（読むだけ） |
| `me.velocity` | 今の速度（m/秒） |
| `me.speed` | この個体の歩く速さ（動物体の「列に並んでいないときの速度」に、速さのばらつきをかけたもの） |
| `me.radius` | ぶつかる半径（m） |
| `me.param` | FIELDS の値（`me.param["flee_distance"]`） |
| `me.memory` | 自由に使える記憶（Dictionary）。現れ直すと空になる。状態（`"mode"` など）や目的地を入れておく |
| `me.group` | 所属する動物体の番号 |

### world（周り）
| 名前 | 戻り値 |
|---|---|
| `world.nearby(me, 距離)` | `距離` m 以内のほかの個体の一覧（近い順）。1つずつ `{"name": 動物体の名前, "motion": スクリプト名（列に並ぶ動物体は ""）, "position", "velocity", "in_line": 列に並んでいる・並びに行っているか}` |
| `world.obstacles` | 障害物の床面の一覧（`Rect2`。x と z の矩形） |
| `world.is_blocked(点)` | 点が障害物の中なら `true` |
| `world.reachable(から, まで)` | 障害物をよけてたどり着けるなら `true` |
| `world.lines()` | 列の一覧。1つずつ `{"name", "points": 中心線の点の配列, "tail": 最後尾の人の位置, "head": 先頭の人の位置}`（並んでいる人がいなければ `tail`・`head` は `null`） |
| `world.bounds` | 動いてよい範囲（全体の設定の出現範囲。`Rect2`、x と z） |
| `world.random_goal(me, rng)` | 目的地の候補。動物体に目的地の線（描画画面で Shift+左ドラッグ）があればその上の点、無ければ範囲内のどこか（障害物の中と列のそばを避ける） |

### rng, delta
- `rng`: 乱数。**乱数は必ずこれから取る**（`rng.randf()`、`rng.randf_range(a, b)`、`rng.randi_range(a, b)`）。`randf()` などを使うと、同じシードでも毎回ちがう動きになり、リプレイが再現しません。
- `delta`: 1 刻みの秒数（1/60）。時間を数えるときに足す（`me.memory["t"] += delta`）。

## step() が返すもの
| 戻り値 | 動き |
|---|---|
| `{"goal": 点, "speed": 速さ}` | 点へ向かって歩く。`speed` を省くと `me.speed`。`0.0` なら止まる |
| `{"line": true}` | 自分の動物体の列（描画画面で左ドラッグした線）に並ぶ。列の先頭まで行くと現れ直す |
| `{"respawn": true}` | 消えて、出現地（右ドラッグした線。無ければ範囲内のどこか）から現れ直す |

本体が受け持つので、スクリプトで書かなくてよいこと:
- ほかの個体をよける、障害物を回り込む（`goal` が障害物の向こうでも、経路を探して進む）
- 列を横切るときの待ち・譲り合い（動物体の優先度と待てる時間）、列の端を回り込むか（全体の設定「二本の経路」）
- 歩くアニメーション

## 条件で動きを変える例

```gdscript
func step(me, world, rng: RandomNumberGenerator, delta: float) -> Dictionary:
    # 近くに「発射物」という名前の動物体があれば逃げる
    for o in world.nearby(me, me.param["flee_distance"]):
        if o["name"] == "発射物":
            me.memory["mode"] = "flee"
            me.memory["from"] = o["position"]

    match me.memory.get("mode", "walk"):
        "flee":
            var away: Vector3 = (me.position - me.memory["from"]).normalized()
            if me.position.distance_to(me.memory["from"]) > me.param["flee_distance"] * 2.0:
                me.memory["mode"] = "walk"
            return {"goal": me.position + away * 5.0, "speed": me.speed * 3.0}
        _:
            if not me.memory.has("goal"):
                me.memory["goal"] = world.random_goal(me, rng)
            if me.position.distance_to(me.memory["goal"]) < 0.3:
                me.memory.erase("goal")
            return {"goal": me.memory.get("goal", me.position)}
```

## 誤りがあるとき
- 文法の誤り: 設定画面のドロップダウンに「（読めません）」と出ます。シミュレートを押すと、誤りの行がコンソールに出て、始まりません。
- `step()` が Dictionary 以外を返したとき: その個体はその場で止まり、コンソールに一度だけ警告が出ます。

## リプレイ
シミュレートするたびに、使ったスクリプトの中身もリプレイファイルに保存されます。あとでスクリプトを書き換えても、リプレイは記録したときの動きで再生されます。
