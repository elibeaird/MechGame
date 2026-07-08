extends Node
## Autoload. Owns connection setup for 2-player matches: hosting (native
## build only — see class comment on why) or joining (native or HTML5/web
## build) over WebSocket, plus which mode this session is in.
##
## A browser tab can only be a WebSocket *client*, never a server (no
## listening-socket API in JS) — so host_game() is only meaningful from a
## native build. join_game() works from either a native or an HTML5 export.

signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)
signal connection_failed
signal server_disconnected

enum Mode { SOLO_VS_AI, HOST, CLIENT }

const DEFAULT_PORT := 9080
## Max clients for a match: host (1) + one joining player.
const MAX_PEERS := 1

var mode : Mode = Mode.SOLO_VS_AI

func _ready():
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func is_networked() -> bool:
	return mode != Mode.SOLO_VS_AI


func am_i_host() -> bool:
	return mode == Mode.HOST or mode == Mode.SOLO_VS_AI


## Starts listening on port for one joining player. Only meaningful from a
## native build (see class comment) — calling this from an HTML5 export
## will fail since browsers can't open a listening socket.
func host_game(port: int = DEFAULT_PORT) -> Error:
	print("[NetworkManager] host_game: starting server on port %d" % port)
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		print("[NetworkManager] host_game: create_server failed, error=%d" % err)
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	print("[NetworkManager] host_game: listening on port %d, waiting for a peer..." % port)
	return OK


## Connects to a host at address:port. Works from both native and HTML5
## builds. address should not include a scheme — "ws://" is added here.
func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	print("[NetworkManager] join_game: connecting to ws://%s:%d" % [address, port])
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client("ws://%s:%d" % [address, port])
	if err != OK:
		print("[NetworkManager] join_game: create_client failed immediately, error=%d" % err)
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	print("[NetworkManager] join_game: client created, attempt in progress (async — watch for peer_connected/connection_failed below)")
	return OK


## Tears down any active connection and returns to solo/vs-AI mode.
func disconnect_and_reset():
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	mode = Mode.SOLO_VS_AI


func _on_peer_connected(peer_id: int):
	print("[NetworkManager] peer_connected: peer_id=%d (mode=%s)" % [peer_id, Mode.keys()[mode]])
	peer_connected.emit(peer_id)

func _on_peer_disconnected(peer_id: int):
	print("[NetworkManager] peer_disconnected: peer_id=%d" % peer_id)
	peer_disconnected.emit(peer_id)

func _on_connection_failed():
	print("[NetworkManager] connection_failed — the join attempt did not reach the host")
	mode = Mode.SOLO_VS_AI
	connection_failed.emit()

func _on_server_disconnected():
	print("[NetworkManager] server_disconnected — lost connection to the host")
	mode = Mode.SOLO_VS_AI
	server_disconnected.emit()
