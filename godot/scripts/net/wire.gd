class_name Wire
extends RefCounted

## Helpers for data that arrives from outside the app.


## Parses JSON from a socket, a datagram or an HTTP body. Returns null for
## anything malformed — quietly, because a stray packet on the LAN or a proxy's
## HTML error page is not worth an error in the log.
static func parse_json(text: String) -> Variant:
	if text.strip_edges().is_empty():
		return null
	var json := JSON.new()
	return json.data if json.parse(text) == OK else null


## Unix seconds for an RFC 3339 stamp (fractional seconds and offsets
## allowed), or 0 when it cannot be read.
static func parse_iso(stamp: String) -> int:
	var re := RegEx.create_from_string("^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d+)?(Z|[+-]\\d{2}:?\\d{2})?$")
	var m := re.search(stamp.strip_edges())
	if m == null:
		return 0
	var unix := Time.get_unix_time_from_datetime_dict({
		"year": int(m.get_string(1)), "month": int(m.get_string(2)), "day": int(m.get_string(3)),
		"hour": int(m.get_string(4)), "minute": int(m.get_string(5)), "second": int(m.get_string(6)),
	})
	var tz := m.get_string(7)
	if tz.length() >= 5:
		var sign_value := -1 if tz[0] == "-" else 1
		var digits := tz.substr(1).replace(":", "")
		unix -= sign_value * (int(digits.substr(0, 2)) * 3600 + int(digits.substr(2, 2)) * 60)
	return unix
