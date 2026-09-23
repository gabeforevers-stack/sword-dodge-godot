extends Node
## Autoload "Net" — сетевой слой (ENet MultiplayerPeer).
## Онлайн работает по локальной сети ИЛИ через Hamachi:
## хост создаёт комнату на порту 7000, гости подключаются по IP из Hamachi.

signal player_connected(id: int)
signal player_disconnected(id: int)
signal server_disconnected_got()
signal chat_message(text: String)
signal connection_failed_sig()

const PORT := 7000
const MAX_CLIENTS := 8
const CHANNEL_STATE := 0        # ненадёжный канал состояния (60 Гц)
const CHANNEL_INPUT := 1        # ненадёжный канал ввода (30 Гц)
const CHANNEL_RELIABLE := 2     # надёжный канал событий

var is_host := false
var peer: ENetMultiplayerPeer = null


func is_online() -> bool:
	return peer != null and multiplayer.multiplayer_peer != null


func host_game() -> Error:
	close()
	is_host = true
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		push_error("Не удалось создать сервер на порту %d (код %s)" % [PORT, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(func(): pass)
	multiplayer.connection_failed.connect(func(): _emit_conn_failed())
	multiplayer.server_disconnected.connect(func(): server_disconnected_got.emit())
	print("Сервер запущен на порту ", PORT)
	return OK


func join_game(address: String, port: int = PORT) -> Error:
	close()
	is_host = false
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		push_error("create_client failed")
		return err
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(func(): pass)
	multiplayer.connection_failed.connect(func(): _emit_conn_failed())
	multiplayer.server_disconnected.connect(func(): server_disconnected_got.emit())
	print("Подключение к ", address, ":", port)
	return err


func _emit_conn_failed():
	connection_failed_sig.emit()


func close() -> void:
	if peer:
		peer.close()
	multiplayer.multiplayer_peer = null
	peer = null
	is_host = false


func _on_peer_connected(id: int) -> void:
	print("Игрок подключился: ", id)
	player_connected.emit(id)


func _on_peer_disconnected(id: int) -> void:
	print("Игрок отключился: ", id)
	player_disconnected.emit(id)


# ---------- Отправка (RPC объявлены на активной сцене игры, группа "game_root") ----------

func _scene() -> Node:
	var root: Node = get_tree().current_scene
	if root and root.is_in_group("game_root"):
		return root
	return null


func send_input(up: int, down: int, left: int, right: int) -> void:
	if is_host:
		return
	var s := _scene()
	if s:
		s.rpc_id(1, "rpc_client_input", up, down, left, right)


func send_state(state: Dictionary) -> void:
	if not is_host:
		return
	var s := _scene()
	if s:
		s.rpc("rpc_server_state", state)


func send_join(player_name: String) -> void:
	var s := _scene()
	if s:
		s.rpc_id(1, "rpc_join_request", player_name)
