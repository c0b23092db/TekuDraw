# 列を横切るときの決まり: 列の人 w と、列に並んでいない人 o（ランダムに歩く人・並びに行く人）の位置関係と、どちらが先に通るか
# 並びに行く人も、列の向こう側の最後尾へ向かうときは列を横切る（一直線に突っ込むと、押し返されてその場で揺れ続ける）
extends RefCounted

const Sim := preload("res://script/SimulationManager3D.gd")
const Walker := preload("res://script/models/Walker.gd")
const State := Walker.State

# 長さの単位は m
const LOOK_AHEAD: float = 0.15      # 列の進む向きを、この距離だけ先の点で見る
const CROSS_NEAR: float = 1.0       # 横切る人は、列の人とのすき間が yield_distance + これより狭くなると遅くなり始める（待ち始めたら、これより広がるまで待つ）

var sim: Sim

func _init(s: Sim) -> void:
    sim = s

# 列の人 w の進む向き（中心線の向き。自分の位置から中心線の先の点へ向けると、左右にずれた人ほど横を向いてしまう）
func line_dir(w: Walker) -> Vector3:
    var line := sim.groups[w.group]
    return (line.pos(w.s + LOOK_AHEAD) - line.pos(w.s)).normalized()

# 体どうしのすき間（中心の距離だと、半径の合計より短い値では体が重なるまで気づかない）
func gap(w: Walker, o: Walker) -> float:
    return w.node.position.distance_to(o.node.position) - w.radius - o.radius

# o が w の前方にいるか。in_path なら、w の通り道（w と o の体の幅）の中にいるときだけ
func ahead(w: Walker, o: Walker, in_path: bool = false) -> bool:
    var my_dir := line_dir(w)
    var to_other := o.node.position - w.node.position
    to_other.y = 0.0
    return my_dir.dot(to_other) > 0.0 and (not in_path or absf(my_dir.cross(to_other).y) < w.radius + o.radius)

# o が w の前方を横切ろうとしているか（進む向きがほぼ直交している。すき間が reach より狭いときだけ）
# 自分より前を歩く列の人は止まらない。止まった人の前にすき間ができ、横切る人はそこを通れる
func is_crossing(w: Walker, o: Walker, reach: float) -> bool:
    if o.state == State.ON_LINE or o.heading == Vector3.ZERO or gap(w, o) >= reach:
        return false
    var my_dir := line_dir(w)
    return absf(my_dir.dot(o.heading)) < 0.7 and ahead(w, o)

# 優先度の高いほうが先に通る。同じなら列の人が先。待てる時間を過ぎた人は必ず先に通る
func cross_value(o: Walker) -> float:
    return INF if o.waited >= sim.groups[o.group].max_wait else o.cross_priority

# 列の人が止まるか: 優先度の高い人が前を横切るとき
# ponytail: 通り道にいる人のためにも止まると、横切る人が何人も集まった所で列が止まり、すき間が詰まって誰も抜けられなくなる。
#           通り道の中の人は止まらずに渡りきるので（crosser_speed）、ぶつかっても押されるのは一瞬
func line_must_yield(w: Walker) -> bool:
    for o in sim.walkers:
        if cross_value(o) > w.line_priority and is_crossing(w, o, sim.yield_distance):
            return true
    return false

# 横切る人の速さの倍率（0〜1）。先を譲る列の人が近づいてくるときは、すき間が yield_distance + CROSS_NEAR から近づくほど遅くし、
# yield_distance で止まる（全速で近づいていきなり止まると「一瞬止まる」。ゆっくり近づく間に列の人が通り過ぎれば止まらずに済む）
# 待つのは列の人の通り道の外だけ。もう通り道の中にいたら止まらずに渡りきる（通り道で止まると、近づく列の人にぶつかる）
# 横切ろうとして列のそばにいる間は waited を数える（先に通っている間も数え続け、列から離れたら 0 に戻す）
# 向き合っている間だけ数えると、列の人と人のすき間が来るたびに 0 に戻り、待てる時間を過ぎることがない
func crosser_speed(o: Walker, delta: float) -> float:
    var reach := sim.yield_distance + CROSS_NEAR
    var near := false
    var k := 1.0
    for w in sim.walkers:
        if w.state != State.ON_LINE:
            continue
        var g := gap(w, o)
        if g >= reach:
            continue
        var crossing := is_crossing(w, o, reach)
        near = near or crossing or o.waited > 0.0
        # 待ち始めた人は、前を横切る向きでなくても、近づいてくる人を待つ（小さなすき間へ踏み出しては止まるのをくり返さない）
        if (crossing or (o.waited > 0.0 and ahead(w, o))) and cross_value(o) <= w.line_priority and not ahead(w, o, true):
            k = minf(k, clampf((g - sim.yield_distance) / CROSS_NEAR, 0.0, 1.0))
    o.waited = o.waited + delta if near else 0.0
    return k

# 横切るのを待って遅くなっている間は、向きを変えずにまっすぐ止まる
# （動いている最後尾へ向き直りながらゆっくり進むと、その場で行ったり来たりして見える）
func wait_goal(w: Walker, goal: Vector3, k: float) -> Vector3:
    return goal if k >= 1.0 or w.heading == Vector3.ZERO else w.node.position + w.heading
