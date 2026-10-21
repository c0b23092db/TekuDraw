# 範囲（中心が原点、XZ の半幅 half_x / half_z）の四隅が収まる距離までカメラを引く
extends RefCounted

# カメラを固定していないときの最初の位置（と「自動に戻す」）だけに使う。見たい位置はシミュレーションの中で動かして固定する
const PITCH_DEG := 60.0  # 見下ろす角度（90 で真上から）
const MARGIN := 1.05     # 範囲より少し広く写す倍率

static func fit(cam: Camera3D, half_x: float, half_z: float, fov: float) -> void:
    cam.fov = fov
    var dir := Vector3(0.0, sin(deg_to_rad(PITCH_DEG)), cos(deg_to_rad(PITCH_DEG)))
    var up := Vector3.UP
    var corners: Array[Vector3] = []
    for sx in [-1.0, 1.0]:
        for sz in [-1.0, 1.0]:
            corners.append(Vector3(sx * half_x, 0.0, sz * half_z) * MARGIN)
    # 二分探索: 全部の角が視錐台に入る最小の距離
    var lo := 1.0
    var hi := 2000.0
    for _i in range(30):
        var mid := (lo + hi) * 0.5
        cam.look_at_from_position(dir * mid, Vector3.ZERO, up)
        var ok := true
        for c in corners:
            if not cam.is_position_in_frustum(c):
                ok = false
                break
        if ok:
            hi = mid
        else:
            lo = mid
    cam.look_at_from_position(dir * hi, Vector3.ZERO, up)
    cam.far = maxf(cam.far, hi * 2.0)
