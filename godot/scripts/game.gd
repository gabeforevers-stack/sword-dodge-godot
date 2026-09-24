extends Node2D
## Сцена игры. Хост авторитетен (симуляция + рассылка состояния ~30 Гц),
## клиенты шлют ввод и получают состояние. Рендер — процедурный пиксель-арт
## в базовом разрешении 320x240, scale 3 (окно 960x720).

const TILE := 16
const FONT_SIZE_NAME := 6
const FONT_SIZE_TIMER := 14

var game: GameLogic = null          # есть только у хоста / соло
var my_id: int = 1                  # на хосте локальный игрок = id 1; у клиента — его peer id
var mode := "solo"                  # solo | host | client
var last_state: Dictionary = {}     # сериализованное состояние для рендера
var acc := 0.0
var send_acc := 0.0
var spectating := false
var fx_timer := 0.0
var fx_intensity := 0.0
var prev_lives := {}
var dash_trails := {}           # id -> [{x, y, age}] — локальный визуальный след рывка
var banner := ""
var hud_text := ""
var waiting_for_peers := false
var net_lost := false


func _ready() -> void:
	scale = Vector2(Const.SCALE, Const.SCALE)   # апскейл 3x с резкими пикселями
	add_to_group("game_root")
	mode = "solo" if GameSession.solo_mode else ("host" if Net.is_host else "client")

	if mode == "client":
		# Мы могли прийти в игру напрямую из лобби или пропустить его —
		# реагируем на старт матча от хоста, снимая ожидание игроков.
		Net.game_started_sig.connect(_on_net_game_started)
		my_id = multiplayer.get_unique_id()
		waiting_for_peers = true
		multiplayer.peer_connected.connect(_on_client_peer)
		Net.server_disconnected_got.connect(func(): net_lost = true)
		_try_join()
		# Если хост недоступен — вернёмся в меню.
		Net.connection_failed_sig.connect(_on_conn_failed)
	else:
		my_id = 1
		game = GameLogic.new()
		game.add_player(1, GameSession.player_name)
		last_state = game.serialize()
		if mode == "host":
			waiting_for_peers = true
			multiplayer.peer_disconnected.connect(_on_peer_left)
			get_tree().create_timer(20.0).timeout.connect(func(): waiting_for_peers = false)


func _on_conn_failed() -> void:
	Net.close()
	GameSession.solo_mode = true
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


func _try_join() -> void:
	if Net.is_online():
		Net.send_join(GameSession.player_name)


func _on_client_peer(_id: int) -> void:
	_try_join()


# ---------- ВВОД ----------

func _read_input() -> Dictionary:
	return {
		"up": 1 if Input.is_action_pressed("move_up") else 0,
		"down": 1 if Input.is_action_pressed("move_down") else 0,
		"left": 1 if Input.is_action_pressed("move_left") else 0,
		"right": 1 if Input.is_action_pressed("move_right") else 0,
		"dash": 1 if Input.is_action_pressed(Const.DASH_KEY) else 0,
	}


func _unhandled_input(event: InputEvent) -> void:
	if is_local_dead():
		if Input.is_action_just_pressed("to_menu"):
			_return_to_menu()
		elif Input.is_action_just_pressed("spectate"):
			if can_spectate() and not spectating:
				spectating = true
	elif event is InputEventKey and event.pressed and not event.echo:
		var kc: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if kc == KEY_ESCAPE:
			_return_to_menu()


func is_local_dead() -> bool:
	if last_state.is_empty():
		return false
	for p in last_state.pl:
		if p.i == my_id:
			return p.a == 0
	return false


func can_spectate() -> bool:
	for p in last_state.pl:
		if p.i != my_id and p.a == 1:
			return true
	return false


func _return_to_menu() -> void:
	Net.close()
	GameSession.solo_mode = true
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


# ---------- СЕТЕВЫЕ RPC (объявлены здесь, вызываются через autoload Net) ----------

@rpc("any_peer", "call_remote", "reliable")
func rpc_join_request(player_name: String) -> void:
	if mode != "host":
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if game.players.has(sender):
		return
	if game.players.size() >= Const.MAX_PLAYERS:
		return
	game.add_player(sender, player_name)
	waiting_for_peers = false


# ---------- ЛОББИ-RPC (дублируем на сцене игры: Net шлёт их в current_scene) ----------

@rpc("any_peer", "call_remote", "reliable")
func rpc_lobby_hello(_player_name: String) -> void:
	pass


@rpc("any_peer", "call_remote", "unreliable_ordered")
func rpc_lobby_roster(roster: Array) -> void:
	Net.lobby_roster_updated.emit(roster)


@rpc("any_peer", "call_remote", "reliable")
func rpc_lobby_start() -> void:
	# Если клиент оказался на сцене игры раньше лобби — просто снимаем ожидание.
	waiting_for_peers = false
	Net.game_started_sig.emit()


func _on_net_game_started() -> void:
	# Хост нажал «НАЧАТЬ ИГРУ», пока мы были на сцене игры — просто снимаем ожидание.
	waiting_for_peers = false


@rpc("any_peer", "call_remote", "unreliable_ordered")
func rpc_client_input(up: int, down: int, left: int, right: int, dash: int) -> void:
	if mode != "host":
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if game.players.has(sender):
		game.players[sender].inp = {"up": up, "down": down, "left": left, "right": right, "dash": dash}


@rpc("any_peer", "call_remote", "unreliable_ordered")
func rpc_server_state(state: Dictionary) -> void:
	if mode != "client":
		return
	last_state = state
	waiting_for_peers = false
	_check_hits(state)


func _on_peer_left(id: int) -> void:
	if mode == "host" and game:
		game.remove_player(id)
		prev_lives.erase(id)


# ---------- FX ----------

func _check_hits(state: Dictionary) -> void:
	for p in state.pl:
		var cur_l: int = p.l
		if prev_lives.has(p.i) and cur_l < prev_lives[p.i]:
			_trigger_hit(p.i == my_id)
		prev_lives[p.i] = cur_l


func _trigger_hit(is_local: bool) -> void:
	var intensity: float = 1.0 if is_local else 0.5
	if fx_timer <= 0.0 or intensity > fx_intensity:
		fx_timer = Const.FX_DURATION
		fx_intensity = intensity
	else:
		fx_timer = maxf(fx_timer, Const.FX_DURATION * 0.6)


# ---------- ЦИКЛ ----------

func _process(dt: float) -> void:
	dt = minf(dt, 0.25)

	if fx_timer > 0.0:
		fx_timer = maxf(0.0, fx_timer - dt)
		if fx_timer == 0.0:
			fx_intensity = 0.0

	var inp: Dictionary = _read_input()

	if mode == "client":
		send_acc += dt
		if send_acc >= Const.SEND_INTERVAL:
			send_acc = 0.0
			Net.send_input(inp.up, inp.down, inp.left, inp.right, inp.dash)
	else:
		if game.players.has(my_id):
			game.players[my_id].inp = inp
		if not waiting_for_peers:
			acc += dt
			while acc >= Const.TICK:
				game.update(Const.TICK)
				acc -= Const.TICK
		send_acc += dt
		if mode == "host" and send_acc >= Const.SEND_INTERVAL:
			send_acc = 0.0
			var st: Dictionary = game.serialize()
			last_state = st
			_check_hits(st)
			Net.send_state(st)
		else:
			last_state = game.serialize()
			_check_hits(last_state)

	_update_dash_trails(dt)
	queue_redraw()


# ---------- СЛЕД РЫВКА (визуал) ----------

func _update_dash_trails(dt: float) -> void:
	# Для игроков с активным рывком добавляем точки следа; остальные затухают.
	for p in last_state.get("pl", []):
		var pid: int = p.i
		if p.a == 1 and int(p.get("d", 0)) == 1:
			if not dash_trails.has(pid):
				dash_trails[pid] = []
			dash_trails[pid].append({"x": p.x, "y": p.y})
			if dash_trails[pid].size() > 10:
				dash_trails[pid].pop_front()
		elif dash_trails.has(pid):
			# Рывок закончился — след быстро рассеивается
			var arr: Array = dash_trails[pid]
			if arr.is_empty():
				dash_trails.erase(pid)
			else:
				arr.pop_front()
				if arr.is_empty():
					dash_trails.erase(pid)


# ---------- РЕНДЕР (всё рисуется в _draw, базовое разрешение 320x240) ----------

func _draw() -> void:
	var now_ms: int = Time.get_ticks_msec()

	# Очистка
	draw_rect(Rect2(0, 0, Const.BASE_W, Const.BASE_H), Color("#05060c"))

	# --- Арена (со тряской) ---
	var shake_off := Vector2.ZERO
	if fx_timer > 0.0:
		var t := fx_timer / Const.FX_DURATION
		var amt := 5.0 * fx_intensity * t
		shake_off = Vector2(randf_range(-amt, amt), randf_range(-amt, amt)).round()

	draw_set_transform(shake_off, 0.0, Vector2.ONE)
	_draw_arena()
	if not last_state.is_empty():
		_draw_sword(last_state.sw)
		_draw_dash_trails()
		_draw_players(last_state.pl, now_ms)
		_draw_timer(last_state)

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_king_box(now_ms)

	# Баннер поверх всего
	_update_banner()
	if banner != "":
		_draw_banner()

	# HUD
	_draw_hud()

	# Экран поражения
	if is_local_dead() and not spectating and not last_state.is_empty():
		_draw_death(now_ms)

	# Красная вспышка
	if fx_timer > 0.0:
		var tt := fx_timer / Const.FX_DURATION
		draw_rect(Rect2(0, 0, Const.BASE_W, Const.BASE_H),
			Color(0.78, 0.08, 0.08, 0.35 * fx_intensity * tt))


func _draw_arena() -> void:
	var oy := Const.KING_BOX_H
	# Заливка арены
	draw_rect(Rect2(0, oy, Const.BASE_W, Const.H), Color("#1a1e30"))
	# Плитка пола (шахматный узор)
	for ty in range(0, Const.H, TILE):
		for tx in range(0, Const.W, TILE):
			var cx := int(tx / TILE)
			var cy := int(ty / TILE)
			if (cx + cy) % 2 == 0:
				draw_rect(Rect2(tx, oy + ty, TILE, TILE), Color("#1c2038"))
	# Тонкая сетка
	var grid := Color(0.235, 0.275, 0.392, 0.25)
	for x in range(0, Const.W + 1, TILE):
		draw_rect(Rect2(x, oy, 1, Const.H), grid)
	for y in range(oy, oy + Const.H + 1, TILE):
		draw_rect(Rect2(0, y, Const.W, 1), grid)
	# Тень от зала короля
	draw_rect(Rect2(0, oy, Const.W, 3), Color(0, 0, 0, 0.5))
	# Стены
	draw_rect(Rect2(0, oy, Const.W, 2), Color("#3a4060"))
	draw_rect(Rect2(0, oy + Const.H - 2, Const.W, 2), Color("#3a4060"))
	draw_rect(Rect2(0, oy, 2, Const.H), Color("#3a4060"))
	draw_rect(Rect2(Const.W - 2, oy, 2, Const.H), Color("#3a4060"))
	draw_rect(Rect2(0, oy, Const.W, 1), Color("#5a6488"))
	draw_rect(Rect2(0, oy, 1, Const.H), Color("#5a6488"))
	draw_rect(Rect2(0, oy + Const.H - 1, Const.W, 1), Color("#1e2438"))
	draw_rect(Rect2(Const.W - 1, oy, 1, Const.H), Color("#1e2438"))


func _pixel_line(from: Vector2, to: Vector2, color: Color, size: float) -> void:
	# Bresenham с квадратными «пикселями» размера size
	var x0 := int(round(from.x))
	var y0 := int(round(from.y))
	var x1 := int(round(to.x))
	var y1 := int(round(to.y))
	var dx := absi(x1 - x0)
	var dy := absi(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err := dx - dy
	var half := int(size / 2.0)
	for i in range(500):
		if size <= 1.0:
			draw_rect(Rect2(x0, y0, 1, 1), color)
		else:
			draw_rect(Rect2(x0 - half, y0 - half, size, size), color)
		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			x0 += sx
		if e2 < dx:
			err += dx
			y0 += sy


func _draw_sword(s: Dictionary) -> void:
	var oy := Const.KING_BOX_H
	var ang: float = s.get("an", 0.0)
	var center := Vector2(s.x, s.y + oy)

	# След
	var trail: Array = s.get("tr", [])
	for i in trail.size():
		var age := float(i + 1) / float(trail.size())
		var r := 1.0 + age
		var tp: Dictionary = trail[i]
		draw_rect(Rect2(tp.x - r / 2.0, tp.y + oy - r / 2.0, maxf(1.0, r), maxf(1.0, r)),
			Color(0.847, 0.91, 1.0, 0.03 + age * 0.12))

	# Клинок: середина меча = точка вращения
	var dirv := Vector2(cos(ang), sin(ang))
	var a := center - dirv * 8.0
	var bpt := center + dirv * 8.0
	_pixel_line(a, bpt, Color("#0a0c14"), 3)
	_pixel_line(a, bpt, Color("#c0c8d8"), 2)
	_pixel_line(a, bpt, Color("#ffffff"), 1)

	# Рукоять (за «хвостом» клинка)
	var hilt_c := center - dirv * 10.0
	_pixel_line(hilt_c, hilt_c, Color("#5a3818"), 3)
	_pixel_line(center - dirv * 10.0, center - dirv * 10.0, Color("#f0c040"), 1)

	# Острие
	var tip_c := center + dirv * 8.0
	_pixel_line(tip_c, tip_c, Color("#e04040"), 2)


func _draw_sprite(tex_str: Array, palette: Dictionary, px: int, py: int, modulate_a: float) -> void:
	for row in tex_str.size():
		var line: String = tex_str[row]
		for col in line.length():
			var ch := line[col]
			if ch == "." or not palette.has(ch):
				continue
			var c: Color = palette[ch]
			c.a = modulate_a
			draw_rect(Rect2(px + col, py + row, 1, 1), c)


func _draw_dash_trails() -> void:
	var oy := Const.KING_BOX_H
	for pid in dash_trails:
		var arr: Array = dash_trails[pid]
		var col: Color = Sprites.COLORS[int(pid) % Sprites.COLORS.size()]
		for i in arr.size():
			var t := float(i + 1) / float(arr.size())
			var pt: Dictionary = arr[i]
			var cx := int(round(pt.x))
			var cy := int(round(pt.y)) + oy
			# Затухающие пиксельные искры цвета игрока
			draw_rect(Rect2(cx - 2, cy - 1, 4, 3), Color(col.r, col.g, col.b, 0.35 * t))
			draw_rect(Rect2(cx - 1, cy - 3, 2, 6), Color(col.r, col.g, col.b, 0.25 * t))


func _draw_players(pl: Array, now_ms: int) -> void:
	var oy := Const.KING_BOX_H
	for p in pl:
		var col: Color = Sprites.COLORS[int(p.c) % Sprites.COLORS.size()]
		var pal := Sprites.knight_palette(col)
		var px := int(round(p.x)) - 5
		var py := int(round(p.y)) - 8 + oy
		var alpha := 1.0
		if p.a == 0:
			pal = Sprites.ghost_palette()
			alpha = 0.3
		elif p.v == 1 and int(now_ms / 150.0) % 2 == 0:
			alpha = 0.35

		# Тень на земле
		if p.a == 1:
			draw_rect(Rect2(px + 1, py + 12, 8, 2), Color(0, 0, 0, 0.45))

		_draw_sprite(Sprites.KNIGHT_SPRITE, pal, px, py, alpha)

		# Индикатор «я» + статус рывка
		if p.i == my_id and p.a == 1:
			var dashing := int(p.get("d", 0)) == 1
			var cd: float = float(p.get("c", 0.0))
			var corner_col: Color
			if dashing:
				corner_col = Color("#70d0ff")
			elif cd <= 0.0:
				corner_col = Color("#40f080")   # рывок готов
			else:
				corner_col = Color("#ffffff")
			for corner in [Vector2(px - 1, py - 1), Vector2(px + 10, py - 1),
					Vector2(px - 1, py + 12), Vector2(px + 10, py + 12)]:
				draw_rect(Rect2(corner, Vector2.ONE), corner_col)
			# Текст под ногами: READY или секунды перезарядки
			var dfont: Font = ThemeDB.fallback_font
			var dtxt := "РЫВОК!" if dashing else ("READY" if cd <= 0.0 else "%ds" % ceili(cd))
			var dcol := Color("#40f080") if (cd <= 0.0 or dashing) else Color("#8890a0")
			var dsz := dfont.get_string_size(dtxt, HORIZONTAL_ALIGNMENT_CENTER, -1, 5)
			draw_string(dfont, Vector2(int(round(p.x)) - dsz.x / 2.0, py + 18),
				dtxt, HORIZONTAL_ALIGNMENT_CENTER, -1, 5, dcol)

		# Сердечки жизней
		var hearts_y := int(round(p.y)) - 15 + oy
		var start_x := int(round(p.x)) - 5
		for k in Const.START_LIVES:
			var filled := k < int(p.l)
			var hc: Color = Color("#e02020") if filled else Color("#3a2030")
			var hx := start_x + k * 4
			for row in Sprites.HEART_SPRITE.size():
				var line: String = Sprites.HEART_SPRITE[row]
				for c2 in line.length():
					if line[c2] == "H":
						draw_rect(Rect2(hx + c2, hearts_y + row, 1, 1), hc)

		# Имя
		var font: Font = ThemeDB.fallback_font
		var name_col: Color = Color("#d8dce8") if p.a == 1 else Color("#606878")
		var sz := Vector2(font.get_string_size(str(p.n), HORIZONTAL_ALIGNMENT_CENTER, -1, FONT_SIZE_NAME))
		draw_string(font, Vector2(int(round(p.x)) - sz.x / 2.0, int(round(p.y)) - 18 + oy),
			str(p.n), HORIZONTAL_ALIGNMENT_CENTER, -1, FONT_SIZE_NAME, name_col)


func _draw_timer(state: Dictionary) -> void:
	if not state.has("rt"):
		return
	var total := int(floor(state.rt))
	var txt := "%02d:%02d" % [int(total / 60.0), total % 60]
	var font: Font = ThemeDB.fallback_font
	var y := Const.KING_BOX_H + 19
	draw_string(font, Vector2(Const.W / 2.0 - 30 + 1, y + 1), txt,
		HORIZONTAL_ALIGNMENT_CENTER, 60, FONT_SIZE_TIMER, Color("#000000"))
	draw_string(font, Vector2(Const.W / 2.0 - 30, y), txt,
		HORIZONTAL_ALIGNMENT_CENTER, 60, FONT_SIZE_TIMER, Color("#f0c040"))


func _update_banner() -> void:
	banner = ""
	if net_lost:
		banner = "СОЕДИНЕНИЕ ПОТЕРЯНО\nF — В МЕНЮ"
	elif waiting_for_peers and mode != "solo":
		banner = "ОЖИДАНИЕ ИГРОКОВ…"
	elif last_state.has("ph"):
		if last_state.ph == "roundover":
			var rnd_no := ceili(last_state.tm)
			banner = ("ПОБЕДА: %s\nРАУНД %d" % [last_state.wn, rnd_no]) \
				if last_state.wn != null else ("НИКТО НЕ ВЫЖИЛ\nРАУНД %d" % rnd_no)
		elif last_state.ph == "gameover":
			var t: float = last_state.st
			banner = "ВРЕМЯ: %02d:%02d\nF — В МЕНЮ" % [floori(t / 60.0), floori(fmod(t, 60.0))]

	var me_alive := not last_state.is_empty()
	for p in last_state.get("pl", []):
		if p.i == my_id:
			me_alive = p.a == 1
	if me_alive:
		spectating = false

	hud_text = "ИГРОКОВ: %d/%d · %s" % [last_state.get("pl", []).size(), Const.MAX_PLAYERS,
		"ХОСТ" if mode == "host" else ("КЛИЕНТ" if mode == "client" else "СОЛО")]
	if spectating:
		hud_text += " · НАБЛЮДЕНИЕ"


func _draw_banner() -> void:
	var font: Font = ThemeDB.fallback_font
	var lines := banner.split("\n")
	var y := Const.BASE_H * 0.58
	for i in lines.size():
		var sz := font.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_CENTER, -1, 12)
		draw_string(font, Vector2(Const.W / 2.0 - sz.x / 2.0 + 1, y + i * 16 + 1),
			lines[i], HORIZONTAL_ALIGNMENT_CENTER, -1, 12, Color("#5a1020"))
		draw_string(font, Vector2(Const.W / 2.0 - sz.x / 2.0, y + i * 16),
			lines[i], HORIZONTAL_ALIGNMENT_CENTER, -1, 12, Color("#f0c040"))


func _draw_hud() -> void:
	var font: Font = ThemeDB.fallback_font
	draw_string(font, Vector2(18, 96 + 1), hud_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color("#000000"))
	draw_string(font, Vector2(18, 96), hud_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color("#8890a0"))
	var me_cd := 0.0
	var me_dash := 0
	for p in last_state.get("pl", []):
		if p.i == my_id:
			me_cd = float(p.get("c", 0.0))
			me_dash = int(p.get("d", 0))
	var dash_hud := ""
	if me_dash == 1:
		dash_hud = " · РЫВОК АКТИВЕН"
	elif me_cd > 0.0:
		dash_hud = " · РЫВОК: %ds" % ceili(me_cd)
	else:
		dash_hud = " · РЫВОК ГОТОВ"
	hud_text += dash_hud
	draw_string(font, Vector2(18, Const.BASE_H - 8), "WASD/СТРЕЛКИ — движение · SPACE — рывок · F — меню · S — наблюдать",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 6, Color("#5a6280"))


func _draw_death(now_ms: int) -> void:
	var font: Font = ThemeDB.fallback_font
	var pulse := 1.0 + 0.06 * sin(float(now_ms) / 800.0 * TAU * 0.5)
	var sz := font.get_string_size("ПОРАЖЕНИЕ", HORIZONTAL_ALIGNMENT_CENTER, -1, 24)
	var pos := Vector2(Const.W / 2.0 - sz.x * pulse / 2.0, Const.KING_BOX_H + Const.H * 0.5)
	draw_string(font, pos, "ПОРАЖЕНИЕ", HORIZONTAL_ALIGNMENT_CENTER, -1,
		int(24 * pulse), Color("#e02020"))
	var hint: String = "F — В МЕНЮ   ·   S — НАБЛЮДАТЬ" if can_spectate() else "F — В МЕНЮ"
	draw_string(font, Vector2(0, pos.y + 22), hint, HORIZONTAL_ALIGNMENT_CENTER, Const.W, 8,
		Color("#e0e6f0"))


# ---------- ЗАЛ КОРОЛЯ ----------

func _draw_king_box(now_ms: int) -> void:
	# Фон зала — вертикальный градиент
	for y in Const.KING_BOX_H:
		var t := float(y) / Const.KING_BOX_H
		draw_rect(Rect2(0, y, Const.BASE_W, 1),
			Color8(clampi(int(26 + 4 * t), 0, 255), clampi(int(18 + 2 * t), 0, 255),
				clampi(int(48 - 16 * t), 0, 255), 255))

	# Арка за троном
	draw_rect(Rect2(148, 2, 24, Const.KING_BOX_H - 4), Color("#241840"))
	draw_rect(Rect2(148, 2, 24, 1), Color("#3a2860"))
	for i in 6:
		draw_rect(Rect2(148 + i * 4, 0, 2, 3), Color("#3a2860"))

	_draw_pillar(22)
	_draw_pillar(Const.W - 22)
	_draw_pillar(72)
	_draw_pillar(Const.W - 72)

	_draw_torch(46, 12, now_ms)
	_draw_torch(Const.W - 46, 12, now_ms)

	# Пол зала
	draw_rect(Rect2(0, Const.KING_BOX_H - 3, Const.BASE_W, 3), Color("#0a0818"))
	draw_rect(Rect2(0, Const.KING_BOX_H - 3, Const.BASE_W, 1), Color("#4a3a58"))

	_draw_throne(Const.W / 2.0, Const.KING_BOX_H - 4)
	_draw_sprite(Sprites.KING_SPRITE, Sprites.KING_PALETTE, int(Const.W / 2.0) - 7, 5, 1.0)


func _draw_torch(x: int, y: int, now_ms: int) -> void:
	draw_rect(Rect2(x, y, 1, 5), Color("#3a2818"))
	var flicker: int = 0 if sin(float(now_ms) / 90.0) > 0.0 else 1
	draw_rect(Rect2(x - 1, y - 3 - flicker, 3, 3 + flicker), Color("#ff8020"))
	draw_rect(Rect2(x, y - 2 - flicker, 1, 1), Color("#ffd060"))
	draw_rect(Rect2(x - 4, y - 7, 9, 9), Color(1.0, 0.55, 0.16, 0.08))


func _draw_pillar(x: int) -> void:
	var bottom_y := Const.KING_BOX_H - 3
	draw_rect(Rect2(x - 2, 3, 5, bottom_y - 3), Color("#2a1f40"))
	draw_rect(Rect2(x - 2, 3, 1, bottom_y - 3), Color("#4a3860"))
	draw_rect(Rect2(x + 2, 3, 1, bottom_y - 3), Color("#1a1028"))
	draw_rect(Rect2(x - 3, 3, 7, 1), Color("#4a3860"))
	draw_rect(Rect2(x - 3, bottom_y - 2, 7, 2), Color("#4a3860"))


func _draw_throne(cx: float, base_y: int) -> void:
	draw_rect(Rect2(cx - 11, base_y - 22, 23, 22), Color("#3a1020"))
	draw_rect(Rect2(cx - 11, base_y - 22, 23, 1), Color("#f0c040"))
	draw_rect(Rect2(cx - 11, base_y - 22, 1, 22), Color("#f0c040"))
	draw_rect(Rect2(cx + 11, base_y - 22, 1, 22), Color("#f0c040"))
	for i in 5:
		draw_rect(Rect2(cx - 9 + i * 4, base_y - 24, 1, 2), Color("#f0c040"))
	draw_rect(Rect2(cx - 12, base_y, 25, 1), Color("#2a0810"))
