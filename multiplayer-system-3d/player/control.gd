extends Control
#
#@export var base_sound: AudioStream  # a clean E note works best
#
#var id: String
#
#@onready var label: Label = $Label
#var play_token: int = 0
## Semitone offsets from E → multiplier = 2^(n/12)
#const PITCH_E  := pow(2.0, 0.0 / 12.0)
#const PITCH_FS := pow(2.0, 2.0 / 12.0)
#const PITCH_G  := pow(2.0, 3.0 / 12.0)
#const PITCH_A  := pow(2.0, 5.0 / 12.0)
#
#func _ready() -> void:
	#$Label.text = "flkasdjfkljka;s"
	#id = get_parent().name
	#Leaderboard.killstreak_changed.connect(_on_killstreak_changed)
#func _on_killstreak_changed(killer: String) -> void:
#
	#if killer != id:
		#return
	#
	#play_token += 1
	#var current_token := play_token
	#
	#var ks: int = Leaderboard.get_killstreak(id)
	#label.text = str(ks)
	#label.show()
	#
	#var sequence: Array[float] = _get_pitch_sequence(ks)
	#await _play_sequence_ordered(sequence)
	#
	## only the latest call is allowed to hide the label
	#if current_token == play_token:
		#label.hide()
		#
		#
#func _show_kill_label(ks: int) -> void:
	#var lbl := Label.new()
	#lbl.text = str(ks)
	#lbl.position = Vector2(0, -40) # adjust as needed
	#add_child(lbl)
	#
	## auto remove after short delay (visual lifetime)
	#get_tree().create_timer(1.0).timeout.connect(func():
		#lbl.queue_free()
	#)
		#
#func _play_sequence_ordered(seq: Array[float]) -> void:
	#for pitch in seq:
		#var p := AudioStreamPlayer.new()
		#p.stream = base_sound
		#p.pitch_scale = pitch
		#add_child(p)
		#
		#p.play()
		#p.finished.connect(func(): p.queue_free())
		#
		#await get_tree().create_timer(0.08).timeout
#func _get_pitch_sequence(ks: int) -> Array[float]:
	#match ks:
		#1:
			#return [PITCH_E]
		#2:
			#return [PITCH_FS]
		#3:
			#return [PITCH_G]
		#4:
			#return [PITCH_A]
		#5:
			#return [PITCH_E, PITCH_E, PITCH_E, PITCH_G]
		#_:
			#return [PITCH_E, PITCH_E, PITCH_E, PITCH_G]
#
#func _play_sequence_parallel(seq: Array[float]) -> void:
	#for pitch in seq:
		#var p := AudioStreamPlayer.new()
		#p.volume_db
		#p.stream = base_sound
		#p.pitch_scale = pitch
		#add_child(p)
		#
		#p.play()
		#
		## auto-cleanup after finishing
		#p.finished.connect(func(): p.queue_free())
#
#func _estimate_duration() -> float:
	#if base_sound == null:
		#return 0.5
	#return base_sound.get_length()
