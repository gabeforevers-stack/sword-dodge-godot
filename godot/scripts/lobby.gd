extends Control
## Лобби комнаты: список подключившихся игроков, IP хоста, кнопка «НАЧАТЬ ИГРУ» (только для хоста).
## Хост держит ENet-сервер открытым; клиенты подключаются здесь же и ждут старта.

@onready var title_label: Label = $Center/Panel/VBox/TitleLbl
@onready var ip_label: Label = $Center/Panel/VBox/IpLabel
@onready var roster_box: VBoxContainer = $Center/Panel/VBox/RosterScroll/RosterList
@onready var count_label: Label = $Center/Panel/VBox/CountLabel
@onready var start_btn: Button = $Center/Panel/VBox/StartBtn
@onready var leave_btn: Button = $Center/Panel/VBox/LeaveBtn
@onready var status_label: Label = $Center/Panel/VBox/StatusLabel

var is_host := false
var my_peer := 1
var roster := []                # [{ "id": int, "name": String }]
var _refresh_acc := 0.0


func _ready() -> void:
	is_host = Net.is_host
	my_peer = 1 if is_host else multiplayer.get_unique_id()
	GameSession.in_lobby = true

	title_label.text = "◆ ЛОББИ КОМНАТЫ ◆" if is_host else "◆ ЛОББИ (ПОДКЛЮЧЕНО) ◆"
	start_btn.visible = is_host
	leave_btn.text = "ЗАКРЫТЬ КОМНАТУ" if is_host else "ВЫЙТИ ИЗ КОМНАТЫ"

	if is_host:
		var ips := _get_ip_list()
		ip_label.text = ("IP ХОСТА: %s\nПОРТ: %d — скажите друзьям ваш Hamachi IP"
			% [", ".join(ips) if ips.size() else "—", Net.PORT])
		_add_self(GameSession.player_name)
		multiplayer.peer_disconnected.connect(_on_peer_left)
	else:
		ip_label.text = "Ожидание списка игроков…"
		Net.connection_failed_sig.connect(_on_conn_failed)
		# Представиться хосту (повторно, на случай если RPC пришёл до готовности сцены).
		Net.lobby_send_hello(GameSession.player_name)
		get_tree().create_timer(0.5).timeout.connect(func(): Net.lobby_send_hello(GameSession.player_name))

	Net.game_started_sig.connect(_on_game_started)
	Net.server_disconnected_got.connect(_on_server_lost)

	start_btn.pressed.connect(_on_start_pressed)
	leave_btn.pressed.connect(_on_leave_pressed)
	_refresh_ui()


func _process(dt: float) -> void:
	# Хост периодически пересылает состав лобби (страховка от потери ненадёжных пакетов).
	if not is_host:
		return
	_refresh_acc += dt
	if _refresh_acc >= 0.5:
		_refresh_acc = 0.0
		_broadcast_roster()


# ---------- СОСТАВ ----------

func _add_self(pname: String) -> void:
	roster = [{"id": my_peer, "name": pname}]
	_refresh_ui()


func _upsert(id: int, pname: String) -> void:
	for e in roster:
		if e.id == id:
			e.name = pname
			_refresh_ui()
			return
	roster.append({"id": id, "name": pname})
	_refresh_ui()


func _remove(id: int) -> void:
	for i in roster.size():
		if roster[i].id == id:
			roster.remove_at(i)
			break
	_refresh_ui()


func _broadcast_roster() -> void:
	Net.lobby_send_roster(roster.duplicate(true))


func _refresh_ui() -> void:
	for c in roster_box.get_children():
		c.queue_free()
	var font: Font = ThemeDB.fallback_font
	for e in roster:
		var lbl := Label.new()
		var tag := " (ХОСТ)" if e.id == 1 else (" (ВЫ)" if e.id == my_peer else "")
		lbl.text = "⚔ %s%s" % [e.name, tag]
		lbl.add_theme_font_override("font", font)
		lbl.add_theme_color_override("font_color",
			Color("#f0c040") if e.id == 1 else Color("#d8dce8"))
		lbl.add_theme_font_size_override("font_size", 16)
		roster_box.add_child(lbl)
	count_label.text = "ИГРОКОВ В КОМНАТЕ: %d / %d" % [roster.size(), Const.MAX_PLAYERS]
	if is_host:
		start_btn.disabled = false  # можно начинать и одному


# ---------- RPC (лобби) ----------

@rpc("any_peer", "call_remote", "reliable")
func rpc_lobby_hello(player_name: String) -> void:
	if not is_host:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if roster.size() >= Const.MAX_PLAYERS:
		status_label.text = "КОМНАТА ЗАПОЛНЕНА (%d/%d)" % [roster.size(), Const.MAX_PLAYERS]
		return
	_upsert(sender, player_name)
	_broadcast_roster()


@rpc("any_peer", "call_remote", "unreliable_ordered")
func rpc_lobby_roster(new_roster: Array) -> void:
	if is_host:
		return
	roster = new_roster
	ip_label.text = "Хост запустил комнату. Ждите начала игры…"
	_refresh_ui()


@rpc("any_peer", "call_remote", "reliable")
func rpc_lobby_start() -> void:
	_on_game_started()


# ---------- КНОПКИ / СОБЫТИЯ ----------

func _on_start_pressed() -> void:
	if not is_host:
		return
	Net.lobby_send_start()
	_go_to_game()


func _on_game_started() -> void:
	if is_host:
		return  # хост сам переходит в игру после нажатия кнопки
	GameSession.in_lobby = false
	_go_to_game()


func _go_to_game() -> void:
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_leave_pressed() -> void:
	GameSession.in_lobby = false
	Net.close()
	GameSession.solo_mode = true
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


func _on_peer_left(id: int) -> void:
	_remove(id)
	_broadcast_roster()


func _on_conn_failed() -> void:
	if not is_inside_tree():
		return
	status_label.text = "СОЕДИНЕНИЕ С ХОСТОМ НЕ УСТАНОВЛЕНО"
	Net.close()
	GameSession.in_lobby = false
	GameSession.solo_mode = true
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


func _on_server_lost() -> void:
	if not GameSession.in_lobby or not is_inside_tree():
		return
	status_label.text = "СВЯЗЬ С ХОСТОМ ПОТЕРЯНА"
	Net.close()
	GameSession.in_lobby = false
	GameSession.solo_mode = true
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


func _get_ip_list() -> Array[String]:
	var ips: Array[String] = []
	for addr in IP.get_local_addresses():
		if addr.contains("."):
			ips.append(addr)
	return ips
