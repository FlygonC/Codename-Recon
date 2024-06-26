extends Control

var _multiplayer: GlobalMultiplayer = Multiplayer

@onready var escape_menu: Control = $EscapeMenu
@onready var settings_menu: Control = $SettingsMenu


func _ready() -> void:
	hide()


func _on_exit_button_pressed() -> void:
	if _multiplayer.client_role != _multiplayer.ClientRole.NONE:
		_multiplayer.nakama_disconnect_from_match()
	get_tree().change_scene_to_file("res://levels/menu.tscn")


func _on_back_button_pressed() -> void:
	visible = !visible
	escape_menu.show()


func _on_game_input_input_escape() -> void:
	visible = !visible
	escape_menu.show()
	settings_menu.hide()
