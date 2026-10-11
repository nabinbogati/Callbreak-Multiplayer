extends Node

## App-wide sound (autoloaded as `Audio`): a looping background track plus
## one-shot card sounds. It mirrors the Settings toggles — flipping "Background
## music" or "Sound effects" takes effect immediately — and pauses the
## soundtrack while the app is in the background.
##
## The card sounds are uncompressed WAV, trimmed to start on their attack:
## a play is heard the frame it is asked for, with nothing to decode, on the
## slowest phone. Only the soundtrack streams from a compressed file.

const MUSIC := preload("res://assets/audio/music.mp3")
const CARD_SHOT := preload("res://assets/audio/card_thrown.wav")
const COLLECT := preload("res://assets/audio/woosh.wav")
const TRUMP := preload("res://assets/audio/trump_play.wav")
## Loops (set in its import options).
const TICK := preload("res://assets/audio/ticking-sound.wav")

## Background music sits well under the table's own sounds.
const MUSIC_DB := -8.0
## The clock tick is a nag, not an event.
const TICK_DB := -5.2
## The deal loop sits under the deal as a rhythm.
const DEAL_DB := -3.1
## The card sound is one swish; looped at its natural speed it lags the deal,
## so it plays faster to keep time.
const DEAL_RATE := 3.0
## Card sounds that may ring at once: a trick's four plays can overlap.
const SHOT_VOICES := 4

var _music: AudioStreamPlayer
var _tick: AudioStreamPlayer
var _deal: AudioStreamPlayer
var _shot: AudioStreamPlayer
var _collect: AudioStreamPlayer
var _trump: AudioStreamPlayer
var _paused_for_lifecycle := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var music: AudioStreamMP3 = MUSIC.duplicate()
	music.loop = true
	_music = _player(music, MUSIC_DB)
	_tick = _player(TICK, TICK_DB)
	_deal = _player(_looping(CARD_SHOT), DEAL_DB)
	_deal.pitch_scale = DEAL_RATE
	# One player per sound, each its own few voices: a play never waits on, or
	# cuts off, a different sound.
	_shot = _player(CARD_SHOT, 0.0, SHOT_VOICES)
	_collect = _player(COLLECT, 0.0, 2)
	_trump = _player(TRUMP, 0.0, 2)
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
	_one_shot(_shot)


## The winner-takes-the-trick collect sound. The table plays it as the trick
## sweeps off, so it never smothers a card still landing.
func play_collect() -> void:
	_one_shot(_collect)


## The flourish for a trump landing into a trick led by a side suit.
func play_trump() -> void:
	_one_shot(_trump)


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


func _one_shot(player: AudioStreamPlayer) -> void:
	if Settings.sfx_enabled:
		player.play()


func _player(stream: AudioStream, db: float, voices := 1) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = db
	p.max_polyphony = voices
	add_child(p)
	return p


## [param stream] looping end to end.
func _looping(stream: AudioStreamWAV) -> AudioStreamWAV:
	var s: AudioStreamWAV = stream.duplicate()
	s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	s.loop_begin = 0
	s.loop_end = int(round(s.get_length() * s.mix_rate))
	return s
