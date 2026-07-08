class_name ConnectScreen
extends CanvasLayer
## First phase shown at boot, before the loadout screen: choose vs-AI (today's
## solo flow, unchanged) or vs-Player (host on this machine / join a host).
## Emits finished() once the match should proceed to the loadout phase(s).

## Named "finished" rather than "ready" since Node already has a built-in
## "ready" signal — redeclaring it would shadow that one.
signal finished

@onready var vs_ai_button: Button = $CenterContainer/PanelContainer/VBoxContainer/VsAiButton
@onready var host_button: Button = $CenterContainer/PanelContainer/VBoxContainer/HostRow/HostButton
@onready var port_input: LineEdit = $CenterContainer/PanelContainer/VBoxContainer/HostRow/PortInput
@onready var address_input: LineEdit = $CenterContainer/PanelContainer/VBoxContainer/JoinRow/AddressInput
@onready var join_button: Button = $CenterContainer/PanelContainer/VBoxContainer/JoinRow/JoinButton
@onready var status_label: Label = $CenterContainer/PanelContainer/VBoxContainer/StatusLabel


func _ready():
	vs_ai_button.pressed.connect(_on_vs_ai_pressed)
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)

	NetworkManager.peer_connected.connect(_on_peer_connected)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.server_disconnected.connect(_on_server_disconnected)


func show_screen():
	visible = true
	status_label.text = ""


func _on_vs_ai_pressed():
	NetworkManager.mode = NetworkManager.Mode.SOLO_VS_AI
	_finish()


func _on_host_pressed():
	var port := int(port_input.text) if port_input.text.is_valid_int() else NetworkManager.DEFAULT_PORT
	print("[ConnectScreen] Host pressed, port=%d" % port)
	var err := NetworkManager.host_game(port)
	if err != OK:
		print("[ConnectScreen] host_game returned error %d" % err)
		status_label.text = "Couldn't start hosting (error %d) — is that port already in use?" % err
		return
	_set_buttons_disabled(true)
	status_label.text = "Hosting on port %d. Waiting for player 2 to join..." % port


func _on_join_pressed():
	var address := address_input.text.strip_edges()
	if address == "":
		status_label.text = "Enter the host's address first"
		return
	var port := int(port_input.text) if port_input.text.is_valid_int() else NetworkManager.DEFAULT_PORT
	print("[ConnectScreen] Join pressed, address=%s port=%d" % [address, port])
	var err := NetworkManager.join_game(address, port)
	if err != OK:
		print("[ConnectScreen] join_game returned error %d" % err)
		status_label.text = "Couldn't connect (error %d)" % err
		return
	_set_buttons_disabled(true)
	status_label.text = "Connecting to %s:%d..." % [address, port]


func _on_peer_connected(_peer_id: int):
	# Fires on both sides once the join completes — for the host this means
	# player 2 arrived; for the client this means we reached the host.
	status_label.text = "Connected! Starting loadout..."
	_finish()


func _on_connection_failed():
	_set_buttons_disabled(false)
	status_label.text = "Connection failed — check the address/port and try again"


func _on_server_disconnected():
	_set_buttons_disabled(false)
	status_label.text = "Disconnected from host"


func _set_buttons_disabled(disabled: bool):
	vs_ai_button.disabled = disabled
	host_button.disabled = disabled
	join_button.disabled = disabled


func _finish():
	visible = false
	finished.emit()
