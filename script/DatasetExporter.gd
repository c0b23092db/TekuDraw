extends Node

@export var target_objects: Array[Node3D]
var log_data: Array = []
var is_recording: bool = false

func start_recording() -> void:
	log_data.clear()
	is_recording = true

func stop_recording() -> void:
	is_recording = false
	save_to_json("user://dataset_ground_truth.json")

func _physics_process(_delta: float) -> void:
	if not is_recording:
		return

	var frame_data = {
		"timestamp": Time.get_ticks_msec(),
		"objects": []
	}

	for obj in target_objects:
		if is_instance_valid(obj):
			frame_data["objects"].append({
				"id": obj.name,
				"position": [obj.global_position.x, obj.global_position.y, obj.global_position.z], # 正確な位置[cite: 1]
				"rotation": [obj.global_rotation.x, obj.global_rotation.y, obj.global_rotation.z]  # 正確な姿勢[cite: 1]
			})

	log_data.append(frame_data)

func save_to_json(file_path: String) -> void:
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(log_data, "\t"))
		file.close()
		print("正解値データを保存しました: ", file_path)