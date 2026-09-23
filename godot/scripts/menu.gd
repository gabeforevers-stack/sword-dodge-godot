extends Control
## Меню: одиночная игра / создать комнату (хост) / подключиться по IP (Hamachi).

@onready var name_edit: LineEdit = $Center/Panel/VBox/NameRow/NameEdit
@onready var ip_edit: LineEdit = $Center/Panel/VBox/IpRow/IpEdit
@onready var btn_solo: Button = $Center/Panel/VBox/SoloBtn
@onready var btn_host: Button = $Center/Panel/VBox/HostBtn
@onready var btn_join: Button = $Center/Panel/VBox/IpRow/JoinBtn
@onready var status_label: Label = $Center/Panel/VBox/StatusLabel
@onready var info_label: Label = $Center/Panel/VBox/InfoLabel


func _ready() -> void:
	Net.connection_failed_sig.connect(_on_conn_failed)
	Net.server_disconnected_got.connect(_on_server_lost)
	btn_solo.pressed.connect(_on_solo_pressed)
	btn_host.pressed.connect(_on_host_pressed)
	btn_join.pressed.connect(_on_join_pressed)
	ip_edit.text_submitted.connect(func(_t): _on_join_pressed())
	name_edit.text = GameSession.player_name if GameSession.player_name != "Рыцарь" else ""
	info_label.text = ""


func _solo_name() -> String:
	var n := name_edit.text.strip_edges()
	return n if n != "" else "Рыцарь"


func _on_solo_pressed() -> void:
	Net.close()
	GameSession.solo_mode = true
	GameSession.player_name = _solo_name()
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_host_pressed() -> void:
	var err := Net.host_game()
	if err != OK:
		status_label.text = "НЕ УДАЛОСЬ СОЗДАТЬ КОМНАТУ (порт занят?)"
		return
	GameSession.solo_mode = false
	GameSession.player_name = _solo_name()
	info_label.text = "Комната создана! Порт %d.\nПередайте друзьям ваш Hamachi IP —\nони вводят его в поле «Подключиться».\nЗаходите в игру — друзья подключатся сами." % Net.PORT
	# Хост сразу уходит в игру; клиенты подтянутся через join_request.
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_join_pressed() -> void:
	var ip := ip_edit.text.strip_edges()
	if ip == "":
		status_label.text = "ВВЕДИТЕ IP ХОСТА"
		return
	var err := Net.join_game(ip)
	if err != OK:
		status_label.text = "ОШИБКА ПОДКЛЮЧЕНИЯ"
		return
	GameSession.solo_mode = false
	GameSession.player_name = _solo_name()
	info_label.text = "Подключение к %s…" % ip
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_conn_failed() -> void:
	if not is_inside_tree():
		return
	status_label.text = "СОЕДИНЕНИЕ НЕ УСТАНОВЛЕНО. Проверьте IP и что хост уже в игре."
	Net.close()


func _on_server_lost() -> void:
	if not is_inside_tree():
		return
	status_label.text = "СОЕДИНЕНИЕ С ХОСТОМ ПОТЕРЯНО"
	Net.close()
