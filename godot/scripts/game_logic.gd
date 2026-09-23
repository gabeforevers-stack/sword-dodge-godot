class_name GameLogic
extends RefCounted
## Чистая игровая логика — перенос класса Game из HTML-версии.
## Хост авторитетен: здесь считаются движение, отскоки меча, жизни и фазы раунда.


class PlayerData:
	extends RefCounted
	var id: int = 0
	var name: String = "P"
	var color_idx: int = 0
	var x: float = 0.0
	var y: float = 0.0
	var inp := {"up": 0, "down": 0, "left": 0, "right": 0}
	var alive: bool = true
	var lives: int = Const.START_LIVES
	var invuln: float = 0.0

	func _init(p_id: int, p_name: String) -> void:
		id = p_id
		name = p_name if p_name != "" else ("P%d" % p_id)
		color_idx = abs(id) % Sprites.COLORS.size()


var players := {}                       # id -> PlayerData
var sword := {"x": 0.0, "y": 0.0, "vx": 0.0, "vy": 0.0, "angle": 0.0, "trail": []}
var phase := "playing"                  # playing | roundover | gameover
var timer := 0.0
var round_time := 0.0
var winner = null
var solo_time := 0.0
var solo_best := 0.0


func _init() -> void:
	reset_round()


func spawn_pos(id: int) -> Vector2:
	var ang := (90.0 + float(id) * 72.0) * PI / 180.0
	return Vector2(Const.W / 2.0 + cos(ang) * 63.0, Const.H / 2.0 + sin(ang) * 50.0)


func add_player(id: int, pname: String) -> PlayerData:
	var p := PlayerData.new(id, pname)
	var pos := spawn_pos(id)
	p.x = pos.x
	p.y = pos.y
	p.invuln = 1.5
	players[id] = p
	return p


func remove_player(id: int) -> void:
	players.erase(id)


func reset_round() -> void:
	phase = "playing"
	timer = 0.0
	round_time = 0.0
	winner = null
	for p in players.values():
		var pos := spawn_pos(p.id)
		p.x = pos.x
		p.y = pos.y
		p.alive = true
		p.lives = Const.START_LIVES
		p.invuln = 1.5
	var s := sword
	s.x = Const.W / 2.0
	s.y = Const.H / 2.0
	var ang := randf() * TAU
	s.vx = cos(ang) * Const.SWORD_BASE_SPEED
	s.vy = sin(ang) * Const.SWORD_BASE_SPEED
	s.angle = randf() * TAU
	s.trail = []


func update(dt: float) -> void:
	if phase == "playing":
		_update_playing(dt)
	elif phase == "roundover":
		timer -= dt
		if timer <= 0.0:
			reset_round()


func _update_playing(dt: float) -> void:
	round_time += dt

	for p in players.values():
		if p.invuln > 0.0:
			p.invuln = maxf(0.0, p.invuln - dt)
		if not p.alive:
			continue
		var dx: float = (1.0 if p.inp.right else 0.0) - (1.0 if p.inp.left else 0.0)
		var dy: float = (1.0 if p.inp.down else 0.0) - (1.0 if p.inp.up else 0.0)
		if dx != 0.0 and dy != 0.0:
			dx *= 0.7071
			dy *= 0.7071
		p.x += dx * Const.PLAYER_SPEED * dt
		p.y += dy * Const.PLAYER_SPEED * dt
		p.x = clampf(p.x, Const.PLAYER_R, Const.W - Const.PLAYER_R)
		p.y = clampf(p.y, Const.PLAYER_R, Const.H - Const.PLAYER_R)

	var s := sword
	s.x += s.vx * dt
	s.y += s.vy * dt

	var bounced := false
	if s.x < Const.SWORD_HIT_R:
		s.x = Const.SWORD_HIT_R
		s.vx = absf(s.vx)
		bounced = true
	elif s.x > Const.W - Const.SWORD_HIT_R:
		s.x = Const.W - Const.SWORD_HIT_R
		s.vx = -absf(s.vx)
		bounced = true
	if s.y < Const.SWORD_HIT_R:
		s.y = Const.SWORD_HIT_R
		s.vy = absf(s.vy)
		bounced = true
	elif s.y > Const.H - Const.SWORD_HIT_R:
		s.y = Const.H - Const.SWORD_HIT_R
		s.vy = -absf(s.vy)
		bounced = true

	if bounced:
		var sp: float = minf(sqrt(s.vx * s.vx + s.vy * s.vy) * Const.SWORD_SPEEDUP, Const.SWORD_MAX_SPEED)
		var ang: float = atan2(s.vy, s.vx) + randf_range(-0.22, 0.22)
		s.vx = cos(ang) * sp
		s.vy = sin(ang) * sp

	# Меч непрерывно вращается вокруг своей середины.
	var sword_speed: float = sqrt(s.vx * s.vx + s.vy * s.vy)
	s.angle += (3.5 + sword_speed * 0.055) * dt
	s.trail.append({"x": s.x, "y": s.y})
	if s.trail.size() > 14:
		s.trail.pop_front()

	var hit_r2 := (Const.PLAYER_R + Const.SWORD_HIT_R) * (Const.PLAYER_R + Const.SWORD_HIT_R)
	for p in players.values():
		if not p.alive or p.invuln > 0.0:
			continue
		var ddx := p.x - s.x
		var ddy := p.y - s.y
		if ddx * ddx + ddy * ddy < hit_r2:
			p.lives -= 1
			if p.lives <= 0:
				p.lives = 0
				p.alive = false
			else:
				p.invuln = Const.HIT_INVULN
				var len_ := sqrt(ddx * ddx + ddy * ddy)
				if len_ == 0.0:
					len_ = 1.0
				p.x = clampf(p.x + ddx / len_ * 10.0, Const.PLAYER_R, Const.W - Const.PLAYER_R)
				p.y = clampf(p.y + ddy / len_ * 10.0, Const.PLAYER_R, Const.H - Const.PLAYER_R)

	var alive_arr := []
	for p in players.values():
		if p.alive:
			alive_arr.append(p)

	if players.size() >= 2:
		if alive_arr.size() <= 1:
			phase = "roundover"
			timer = Const.RESPAWN_DELAY
			winner = alive_arr[0].name if alive_arr.size() == 1 else null
	elif players.size() == 1 and alive_arr.is_empty():
		solo_time = round_time
		solo_best = maxf(solo_best, round_time)
		phase = "gameover"
		timer = 0.0
		winner = null


## Сериализация состояния для отправки клиентам (словарь с короткими ключами).
func serialize() -> Dictionary:
	var pl_arr := []
	for p in players.values():
		pl_arr.append({
			"i": p.id, "n": p.name, "c": p.color_idx,
			"x": roundi(p.x * 10.0) / 10.0,
			"y": roundi(p.y * 10.0) / 10.0,
			"a": 1 if p.alive else 0,
			"v": 1 if p.invuln > 0.0 else 0,
			"l": p.lives,
		})
	var tr_arr := []
	for t in sword.trail:
		tr_arr.append({"x": roundi(t.x * 10.0) / 10.0, "y": roundi(t.y * 10.0) / 10.0})
	return {
		"t": "state",
		"ph": phase,
		"tm": roundi(timer * 10.0) / 10.0,
		"rt": roundi(round_time * 10.0) / 10.0,
		"st": roundi(solo_time * 10.0) / 10.0,
		"sb": roundi(solo_best * 10.0) / 10.0,
		"wn": winner,
		"sw": {
			"x": roundi(sword.x * 10.0) / 10.0,
			"y": roundi(sword.y * 10.0) / 10.0,
			"vx": roundi(sword.vx),
			"vy": roundi(sword.vy),
			"an": roundi(sword.angle * 1000.0) / 1000.0,
			"tr": tr_arr,
		},
		"pl": pl_arr,
	}
