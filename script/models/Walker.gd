# 歩行者1人分の状態
extends RefCounted

enum State { TO_LINE, ON_LINE, SCRIPTED }  # SCRIPTED: 動きのスクリプトが行き先を決める

var node: Node3D
var state: State = State.TO_LINE
var speed: float = 1.4
var velocity: Vector3 = Vector3.ZERO
var group: int = 0              # 所属する動物体（groups の添字）
var s: float = 0.0              # 列上の位置
var gap: float = 1.0            # 前の人との間隔
var lateral_offset: float = 0.0 # 列の中心線からの左右のズレ
var line_priority: float = 0.0  # 列に並んでいるとき、横切る人より高ければ譲らない
var cross_priority: float = 0.0 # 列を横切るとき、列の人より高ければ先に通る
var memory := {}                # 動きのスクリプトが自由に使う記憶（現れ直すと空になる）
var param := {}                 # 動きのスクリプトの設定値（動物体ごと）
var position: Vector3:          # スクリプト向け（読むだけ）
    get: return node.position
var heading: Vector3 = Vector3.ZERO # 向かおうとしている向き（止まって待つ間も保つ）
var direction: Vector3 = Vector3.ZERO # 今進んでいる向き。よけるときは heading からずれ、少しずつ向き直る（止まっている間も保つ）
var waited: float = 0.0         # 横切ろうとして列のそばにいる時間
var radius: float = 0.2        # ぶつかる半径（人ごとにばらつく）
var spawn_delay: float = 0.0    # 開始から現れるまでの残り秒数
var path := PackedVector2Array() # 障害物を迂回する経路（XZ）
var replan: float = 0.0          # 経路を引き直すまでの残り秒数
var via := Vector2i(-1, 0)       # 列の端を回り込むとき (列の添字, 0: 最後尾側 / 1: 先頭側)。x = -1 ならまっすぐ
var reroute: float = 0.0         # 回り込むかを決め直すまでの残り秒数
# 以下は見た目だけ（動きの計算には使わない）
var anim: AnimationPlayer        # モデルにアニメーションが無ければ null
var anim_speed: float = 0.0      # 歩くアニメーションを等速で流したときの歩く速さ（大きさ 1 のとき）
var anim_phase: float = 0.0      # 全員の足がそろわないよう、最初の再生位置をずらす（0〜1）
var anim_v: float = 0.0          # 最近の移動の速さ（なめらかにしたもの）
var last_pos: Vector3 = Vector3.ZERO
