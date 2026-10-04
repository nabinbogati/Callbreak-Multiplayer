class_name Sessions
extends RefCounted

## Builds sessions from the current settings, and keeps the player's identity
## and "Rejoin your game?" record in step with networked ones.


static func local(hands: int) -> LocalSession:
	return LocalSession.new(Settings.player_name, Settings.difficulty, hands, Settings.animation_scale())


## A seat at a table on the game server (or a LAN host). Identity rides along
## so the server keeps the same player id and credits games to this account.
static func remote(server_url: String, room: String, mode: String, hands := 0, creating := false,
		resume_token := "", player_name := "") -> RemoteSession:
	var s := RemoteSession.new(server_url, room, player_name if not player_name.is_empty() else Settings.player_name, mode)
	s.difficulty = Settings.difficulty
	s.hands_per_game = hands
	s.creating = creating
	s.resume_token = resume_token
	s.guest_token = Settings.identity.guest_token
	s.device_id = Settings.identity.device_id
	if mode != "lan":
		wire_active_game(s)
	return s


## Persists what this seat would need to reclaim itself after the process
## dies: the active-table record is written on every reissued resume token and
## cleared the moment the session reaches a terminal state. It is scoped to the
## session's own room — a session must not erase a record some other table
## wrote.
static func wire_active_game(session: RemoteSession) -> void:
	var persisted := {"token": ""}
	session.changed.connect(func():
		var identity := Settings.identity
		identity.guest_token = session.guest_token
		var terminal := session.status == GameSession.CLOSED or session.status == GameSession.ERROR \
				or (session.view != null and session.view.phase == GameView.GAME_OVER)
		if terminal:
			var stored := identity.active_game()
			if not stored.is_empty() and stored["serverUrl"] == session.server_url \
					and stored["roomCode"] == session.room_code:
				identity.clear_active_game()
			return
		var token := session.resume_token
		if not token.is_empty() and token != persisted["token"]:
			persisted["token"] = token
			identity.save_active_game({
				"serverUrl": session.server_url, "roomCode": session.room_code, "mode": session.mode,
				"resumeToken": token, "playerName": session.player_name,
			}))
