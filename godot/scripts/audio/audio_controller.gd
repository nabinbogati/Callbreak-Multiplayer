extends Node

## App-wide sound (autoloaded as `Audio`): a looping background track plus
## one-shot card sounds. It mirrors the Settings toggles — flipping "Background
## music" or "Sound effects" takes effect immediately — and pauses the
## soundtrack while the app is in the background.

const MUSIC := preload("res://assets/audio/music.mp3")
const CARD_SHOT := preload("res://assets/audio/card_thrown.mp3")
const COLLECT := preload("res://assets/audio/woosh.mp3")
const TRUMP := preload("res://assets/audio/trump_play.mp3")
const TICK := preload("res://assets/audio/ticking-sound.ogg")

## Background music sits well under the table's own sounds.
const MUSIC_DB := -8.0
## The clock tick is a nag, not an event.
const TICK_DB := -5.2
## The deal loop sits under the deal as a rhythm.
const DEAL_DB := -3.1
## The card sound is one swish; looped at its natural speed it lags a
## 55ms-per-card deal, so it plays faster to keep time.
const DEAL_RATE := 3.0
const ONE_SHOT_VOICES := 6

var _music: AudioStreamPlayer
var _tick: AudioStreamPlayer
var _deal: AudioStreamPlayer
var _voices: Array[AudioStreamPlayer] = []
var _next_voice := 0
var _paused_for_lifecycle := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_music = _player(_looping(MUSIC), MUSIC_DB)
	_tick = _player(_looping(TICK), TICK_DB)
	_deal = _player(_looping(CARD_SHOT), DEAL_DB)
	_deal.pitch_scale = DEAL_RATE
	for i in ONE_SHOT_VOICES:
		_voices.append(_player(null, 0.0))
	Settings.changed.connect(_sync)
	_sync()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT:
			# Off-screen, a looping soundtrack would play to nothing (or into
			# the player's next app).
			if _music != null and _music.playing:
				_paused_for_lifecycle = true
				_music.stream_paused = true
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN:
			if _paused_for_lifecycle:
				_paused_for_lifecycle = false
				_music.stream_paused = false


func _sync() -> void:
	if Settings.music_enabled:
		if not _music.playing:
			_music.play()
	else:
		_music.stop()
	if not Settings.sfx_enabled:
		stop_tick()
		stop_deal()


## The card-hits-the-table sound.
func play_shot() -> void:
	_one_shot(CARD_SHOT)


## The winner-takes-the-trick collect sound, slightly delayed so it never
## smothers a card still landing.
func play_collect() -> void:
	if not Settings.sfx_enabled:
		return
	get_tree().create_timer(0.11).timeout.connect(func(): _one_shot(COLLECT))


## The flourish for a trump landing into a trick led by a side suit.
func play_trump() -> void:
	_one_shot(TRUMP)


## Starts the dealing loop; [method stop_deal] ends it.
func play_deal() -> void:
	if Settings.sfx_enabled and not _deal.playing:
		_deal.play()


func stop_deal() -> void:
	_deal.stop()


## Starts the turn clock's ticking loop for the alarm window.
func start_tick() -> void:
	if Settings.sfx_enabled and not _tick.playing:
		_tick.play()


func stop_tick() -> void:
	_tick.stop()


func _one_shot(stream: AudioStream) -> void:
	if not Settings.sfx_enabled:
		return
	var voice := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	voice.stream = stream
	voice.play()


func _player(stream: AudioStream, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = db
	add_child(p)
	return p


func _looping(stream: AudioStream) -> AudioStream:
	var s: AudioStream = stream.duplicate()
	if s is AudioStreamMP3:
		(s as AudioStreamMP3).loop = true
	elif s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = true
	return s
