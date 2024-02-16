extends Camera2D

signal round_change_ended
@export var _shop_scene: PackedScene
@export var _move_layer: PackedScene
@export var _move_arrow: PackedScene
@export var _capture_particles: PackedScene
@export var _floating_info: PackedScene

@onready var _selection_decal: Sprite2D = $"../SelectionDecal"
@onready var _action_panel: ActionPanel = $"../../../Interface/ActionPanel"
@onready var _input_timer: Timer = $"../InputTimer"
@onready var _round_button: Button = %RoundButton
@onready var _escape_panel: Control = %EscapePanel
@onready var _map_slot: Node = %MapSlot
@onready var _cursor_collider: Area2D = %CursorCollider
@onready var _round_label: RoundLabel = %RoundLabel
@onready var _round_rect: Polygon2D = %RoundRect
@onready var _round_number_label: Label = %RoundNumberLabel
@onready var _money_label: Label = %MoneyLabel
@onready var _animation_player: AnimationPlayer = %AnimationPlayer

var state: GameConst.State:
	set(value):
		print_debug("State changed from %s to %s" % [GameConst.State.keys()[state], GameConst.State.keys()[value]])
		state = value

var event: GameConst.Event = GameConst.Event.NONE:
	set(value):
		if value != event:
			print_debug("Event %s" % GameConst.Event.keys()[value])
			event = value
			
var input: GameConst.InputType = GameConst.InputType.HUMAN:
	set(value):
		print_debug("Input changed from %s to %s" % [GameConst.InputType.keys()[input], GameConst.InputType.keys()[value]])
		input = value

var ai_phase: int = 0

var last_selected_unit: Unit
var last_selected_terrain: Terrain				# holding last clicked terrain
var last_action_terrain: Terrain				# holding terrain for action (so clicking while in action has no effect like in last_selected_terrain)
var last_mouse_terrain: Terrain
var last_selected_action: GameConst.Actions
var last_shop: Shop
var last_bought_unit: PackedScene
var moveable_terrains: Array[Terrain]
var attackable_terrains: Array[Terrain]
var refill_terrains: Array[Terrain]
var enter_terrains: Array[Terrain]
var deploy_terrains: Array[Terrain]
var join_terrains: Array[Terrain]
var _move_arrow_node: MoveArrow
var map: Map
var player_turns: Array[Player]
var turn_round: int = 0
var target_camera_zoom: Vector2
var mouse_position: Vector2
var camera_move_speed: float
var camera_zoom_speed: float
var camera_max_zoom: float
var camera_min_zoom: float
var own_player_id: int

var _state_event_id: int = 0
var _action_panel_just_released: bool = false
var _shop_panel_just_released: bool = false
var _map_loaded: bool = false
var _fsm_blocked: bool = false
var _input_blocked: bool = false
var _last_state: GameConst.State
var _last_event: GameConst.Event
var _random_luck: Array[int]	# luck number between 0 and 9
var _simulated_first_click: bool = false
var _ai_on_way_capture_terrains: Array[Terrain] = []	# a way for the ai to remember which far terrains get already captured (so not the hole infantery runs there)
var _sound: GlobalSound = Sound
var _multiplayer: GlobalMultiplayer = Multiplayer
var _messages: GlobalMessages = Messages
var _global: GlobalGlobal = Global
var _types: GlobalTypes = Types

func _ready() -> void:
	if _multiplayer.client_role == _multiplayer.ClientRole.NONE:
		randomize()
	else:
		seed(_multiplayer.random_seed)
		_multiplayer.nakama_presence_changed.connect(_on_presence_changed)
	# generate 100 deterministic "random" luck numbers (between 0 and 9)
	for i: int in range(100):
		_random_luck.append(randi_range(0, 9))
	
	_move_arrow_node = _move_arrow.instantiate()
	_move_arrow_node.hide()
	get_parent().call_deferred("add_child", _move_arrow_node)
	target_camera_zoom = zoom
	
	camera_move_speed = ProjectSettings.get_setting("global/camera_move_speed")
	camera_zoom_speed = ProjectSettings.get_setting("global/camera_zoom_speed")
	camera_max_zoom = ProjectSettings.get_setting("global/camera_max_zoom")
	camera_min_zoom = ProjectSettings.get_setting("global/camera_min_zoom")
	
	_round_button.disabled = true

func _process(delta: float) -> void:
	if _map_loaded:
		_handle_camera_input(delta)
		if not _fsm_blocked:
			_fsm_blocked = true
			match(input):
				GameConst.InputType.HUMAN:
					await _process_human(delta)
				GameConst.InputType.AI:
					await _process_ai(delta)
				GameConst.InputType.NETWORK:
					await _process_network(delta)
			_fsm_blocked = false
		
func _process_human(delta: float) -> void:
	if _selection_decal:
		mouse_position = get_global_mouse_position()
		
		if not _input_blocked and not _escape_panel.visible:
			if Input.is_action_just_released("select_first") or _simulated_first_click:
				_simulated_first_click = false
				# ignore clicked event when button round was pressed
				if event != GameConst.Event.CLICKED_END_ROUND:
					last_mouse_terrain = null 	# to force terrain interface update 
					if _cursor_collider.has_overlapping_areas():
						last_selected_terrain = _cursor_collider.get_overlapping_areas()[0]
						event = GameConst.Event.CLICKED_LEFT
						_input_blocked = true
						_input_timer.start()

			if Input.is_action_just_released("select_second"):
				event = GameConst.Event.CLICKED_RIGHT
				_input_blocked = true
				_input_timer.start()
			
		if _action_panel_just_released:
			event = GameConst.Event.CLICKED_ACTION
			_action_panel_just_released = false
			
		if _shop_panel_just_released:
			event = GameConst.Event.CLICKED_SHOP
			_shop_panel_just_released = false

	if _multiplayer.client_role != _multiplayer.ClientRole.NONE:
		_remove_network_own_fsm_round()
		# send only fsm round when state or event has changed
		if _last_state != state or _last_event != event:
			_last_state = state
			_last_event = event
			_multiplayer.nakama_send_match_state(_multiplayer.OpCodes.FSM_ROUND, _stringify_network_fsm_round())
	
	match(state):
		GameConst.State.EARNING:
			await _do_state_earning()
		GameConst.State.REPAIRING:
			_selection_decal.show()
			await _do_state_repairing()
		GameConst.State.SELECTING:
			match(event):
				GameConst.Event.CLICKED_LEFT:
					_do_state_selecting_clicked_left()
				GameConst.Event.CLICKED_RIGHT:
					_do_state_selecting_clicked_right()
				GameConst.Event.CLICKED_END_ROUND:
					state = GameConst.State.ENDING
				GameConst.Event.NONE:
					_update_ui()
					_round_button.disabled = false
		GameConst.State.COMMANDING:
			match(event):
				GameConst.Event.CLICKED_LEFT:
					_do_state_commanding_clicked_left()
				GameConst.Event.CLICKED_RIGHT:
					_do_state_commanding_clicked_right()
				GameConst.Event.NONE:
					_update_ui(true)
					_round_button.disabled = true
		GameConst.State.ACTION:
			match(event):
				GameConst.Event.CLICKED_ACTION:
					await _do_state_action_clicked_action()
				GameConst.Event.CLICKED_RIGHT:
					_do_state_action_clicked_right()
				GameConst.Event.NONE:
					_round_button.disabled = true
		GameConst.State.ATTACKING:
			match(event):
				GameConst.Event.CLICKED_LEFT:
					await _do_state_attacking_clicked_left()
				GameConst.Event.CLICKED_RIGHT:
					_do_state_attacking_clicked_right()
				GameConst.Event.NONE:
					_update_ui()
					_round_button.disabled = true
		GameConst.State.REFILLING:
			match(event):
				GameConst.Event.CLICKED_LEFT:
					await _do_state_refilling_clicked_left()
				GameConst.Event.CLICKED_RIGHT:
					_do_state_refilling_clicked_right()
				GameConst.Event.NONE:
					_update_ui()
					_round_button.disabled = true
		GameConst.State.DEPLOYING:
			match(event):
				GameConst.Event.CLICKED_LEFT:
					await _do_state_deploying_clicked_left()
				GameConst.Event.CLICKED_RIGHT:
					_do_state_deploying_clicked_right()
				GameConst.Event.NONE:
					_update_ui()
					_round_button.disabled = true
		GameConst.State.BUYING:
			match(event):
				GameConst.Event.CLICKED_LEFT:
					pass
				GameConst.Event.CLICKED_RIGHT:
					last_shop.queue_free()
					_sound.play("Deselect")
					_round_button.disabled = false
					state = GameConst.State.SELECTING
				GameConst.Event.CLICKED_SHOP:
					await _do_state_bying_clicked_shop()
				GameConst.Event.NONE:
					_round_button.disabled = true
		GameConst.State.ENDING:
			_round_button.disabled = true
			await _do_state_ending()
	event = GameConst.Event.NONE
	
func _process_ai(delta: float) -> void:
	match(state):
		GameConst.State.EARNING:
			await _do_state_earning()
			ai_phase = 0
			_ai_on_way_capture_terrains = []
		GameConst.State.REPAIRING:
			await _do_state_repairing()
		GameConst.State.SELECTING:
			match(ai_phase):
				0:
					# try capture nearest buildings
					var unit_for_action_found: bool = false
					for unit: Unit in _get_group_unit():
						if "Infantry" in unit.name and unit.player_owned == player_turns[0] and not unit.get_unit_stats().round_over:
							last_selected_unit = unit
							_create_and_set_move_area(unit, false)
							unit_for_action_found = false
							for terrain: Terrain in moveable_terrains:
								if _types.terrains[terrain.id]["can_capture"] and terrain.player_owned != player_turns[0] and (not terrain.has_unit() or terrain.get_unit() == unit):
									last_action_terrain = terrain
									last_selected_action = GameConst.Actions.CAPTURE
									unit_for_action_found = true
									break
							if unit_for_action_found:
								state = GameConst.State.COMMANDING
								break
							# unit look for nearest building to move to for capturing (capturing out of range)
							var terrain_paths: Array[PackedVector2Array] = []
							var path_to_terrain_dict: Dictionary = {}
							for terrain: Terrain in _get_group_terrain():
								# only one infantry should go there
								if terrain in _ai_on_way_capture_terrains:
									continue
								if _types.terrains[terrain.id]["can_capture"] and terrain.player_owned != player_turns[0] and not terrain.has_unit():
									terrain_paths.append(_get_path(unit.get_terrain(), terrain, unit))
									path_to_terrain_dict[terrain_paths.back()] = terrain
							if len(terrain_paths) > 0:
								terrain_paths.sort_custom(func(a: PackedVector2Array, b: PackedVector2Array) -> bool: return len(a) < len(b))
								last_action_terrain = path_to_terrain_dict[terrain_paths[0]]
								last_selected_action = GameConst.Actions.MOVE
								unit_for_action_found = true
								state = GameConst.State.COMMANDING
								_ai_on_way_capture_terrains.append(last_action_terrain)
								break
					if not unit_for_action_found:
						ai_phase += 1
				1:
					# try to attack with range units
					for unit: Unit in _get_group_unit():
						_unattack()
						if _types.units[unit.id]["max_range"] > 1 and unit.player_owned == player_turns[0] and not unit.get_unit_stats().round_over:
							_unattack()
							_create_and_set_attack_area(unit, unit.get_terrain(), false)
							if len(attackable_terrains) > 0:
								_ai_sort_attackable_terrain_most_valuable(unit)
								last_selected_unit = unit
								last_selected_terrain = attackable_terrains[0]
								last_action_terrain = unit.get_terrain()
								last_selected_action = GameConst.Actions.ATTACK
								state = GameConst.State.COMMANDING
								break
					ai_phase += 1
				2:
					# try to attack with direct units
					var unit_for_action_found: bool = false
					for unit: Unit in _get_group_unit():
						if unit.player_owned == player_turns[0] and not unit.get_unit_stats().round_over:
							_create_and_set_move_area(unit, false)
							_ai_sort_moveable_terrain_nearest(unit)
							for terrain: Terrain in moveable_terrains:
								if terrain.has_unit():
									continue
								_unattack()
								_create_and_set_attack_area(unit, terrain, false)
								if len(attackable_terrains) > 0:
									_ai_sort_attackable_terrain_most_valuable(unit)
									last_selected_unit = unit
									last_selected_terrain = attackable_terrains[0]
									last_action_terrain = terrain
									last_selected_action = GameConst.Actions.ATTACK
									state = GameConst.State.COMMANDING
									unit_for_action_found = true
									break
							if unit_for_action_found:
								break
					if not unit_for_action_found:
						ai_phase += 1
				3:
					# try to position direct units (pushing to enemy qg)
					var unit_for_action_found: bool = false
					for unit: Unit in _get_group_unit():
						if unit.player_owned == player_turns[0] and _types.units[unit.id]["max_range"] == 1 and not unit.get_unit_stats().round_over:
							# get enemy qg
							_create_and_set_move_area(unit, false)
							var qg: Terrain
							for terrain: Terrain in _get_group_terrain():
								if "QG" in terrain.name and terrain.player_owned != player_turns[0]:
									qg = terrain
							if qg:
								last_action_terrain = qg
								last_selected_unit = unit
								last_selected_action = GameConst.Actions.MOVE
								state = GameConst.State.COMMANDING
								unit_for_action_found = true
								break
					if not unit_for_action_found:
						ai_phase += 1
				4:
					# try to position range units on strategic good places
					var unit_for_action_found: bool = false
					for unit: Unit in _get_group_unit():
						if unit.player_owned == player_turns[0] and _types.units[unit.id]["max_range"] > 1 and not unit.get_unit_stats().round_over:
							_create_and_set_move_area(unit, false)
							_ai_sort_moveable_terrain_nearest(unit)
							for terrain: Terrain in moveable_terrains:
								_unattack()
								_create_and_set_attack_area(unit, terrain, false, false)
								if len(attackable_terrains) > 0:
									_ai_sort_attackable_terrain_most_valuable(unit)
									last_action_terrain = terrain
									last_selected_unit = unit
									last_selected_action = GameConst.Actions.MOVE
									state = GameConst.State.COMMANDING
									unit_for_action_found = true
									break
							if unit_for_action_found:
								break
					if not unit_for_action_found:
						ai_phase += 1
				5:
					# try to position range units (pushing to enemy qg)
					var unit_for_action_found: bool = false
					for unit: Unit in _get_group_unit():
						if unit.player_owned == player_turns[0] and _types.units[unit.id]["max_range"] > 1 and not unit.get_unit_stats().round_over:
							# get enemy qg
							_create_and_set_move_area(unit, false)
							var qg: Terrain
							for terrain: Terrain in _get_group_terrain():
								if "QG" in terrain.name and terrain.player_owned != player_turns[0]:
									qg = terrain
							if qg:
								last_action_terrain = qg
								last_selected_unit = unit
								last_selected_action = GameConst.Actions.MOVE
								state = GameConst.State.COMMANDING
								unit_for_action_found = true
								break
					if not unit_for_action_found:
						ai_phase += 1
				6:
					# Build 200% infantry based on base counts
					var bases: Array[Terrain] = _get_free_own_bases()
					var infantry_count: int = 0
					for unit: Unit in _get_group_unit():
						if "Infantry" in unit.name and unit.player_owned == player_turns[0]:
							infantry_count += 1
					if len(bases) > 0 and infantry_count <= len(bases) * 2:
						last_selected_terrain = bases[0]
						last_bought_unit = load("res://logic/game/units/infantry.tscn")
						state = GameConst.State.BUYING
					else:
						ai_phase += 1
				7:
					# build most expensive units on free base terrains
					var bases: Array[Terrain] = _get_free_own_bases()
					if len(bases) > 0:
						var unit_scenes: Array[PackedScene] = bases[0].shop_units.duplicate()
						# TODO: reverse() of an Array seems to be bugged...
						for i: int in range(len(unit_scenes) - 1, 0, -1):
							var unit: Unit = unit_scenes[i].instantiate()
							# enough money and not APC
							if player_turns[0].money >= _types.units[unit.id]["cost"] and len(_types.units[unit.id]["weapons"]) > 0:
								last_selected_terrain = bases[0]
								last_bought_unit = unit_scenes[i]
								state = GameConst.State.BUYING
								break
							else:
								unit.free()
					ai_phase += 1
				8:
					# end round
					state = GameConst.State.ENDING
		GameConst.State.COMMANDING:
			_ai_create_and_filter_move_curve(last_action_terrain)
			state = GameConst.State.ACTION
		GameConst.State.ACTION:
			await _do_state_action_clicked_action()
		GameConst.State.ATTACKING:
			await _do_state_attacking_clicked_left()
		GameConst.State.REFILLING:
			pass
		GameConst.State.DEPLOYING:
			pass
		GameConst.State.BUYING:
			await _do_state_bying_clicked_shop()
		GameConst.State.ENDING:
			await _do_state_ending()
	event = GameConst.Event.NONE
	
func _process_network(delta: float) -> void:
	await _parse_network_fsm_round()
	match(state):
		GameConst.State.EARNING:
			await _do_state_earning(false)
		GameConst.State.REPAIRING:
			await _do_state_repairing(false)
		GameConst.State.SELECTING:
			match(event):
				GameConst.Event.CLICKED_LEFT:
					pass
				GameConst.Event.CLICKED_RIGHT:
					pass
				GameConst.Event.CLICKED_END_ROUND:
					pass
		GameConst.State.COMMANDING:
			match(event):
				GameConst.Event.CLICKED_LEFT:
					pass
				GameConst.Event.CLICKED_RIGHT:
					pass
		GameConst.State.ACTION:
			match(event):
				GameConst.Event.CLICKED_ACTION:
					_update__move_arrow_none_ui_input(last_action_terrain)
					await _do_state_action_clicked_action(false)
				GameConst.Event.CLICKED_RIGHT:
					pass
		GameConst.State.ATTACKING:
			match(event):
				GameConst.Event.CLICKED_LEFT:
					_update__move_arrow_none_ui_input(last_action_terrain) # needed for direct attack
					_create_and_set_attack_area(last_selected_unit, last_action_terrain, false) # needed for direct attack
					await _do_state_attacking_clicked_left(false)
				GameConst.Event.CLICKED_RIGHT:
					pass
		GameConst.State.REFILLING:
			match(event):
				GameConst.Event.CLICKED_LEFT:
					await _do_state_refilling_clicked_left(false)
				GameConst.Event.CLICKED_RIGHT:
					pass
		GameConst.State.DEPLOYING:
			match(event):
				GameConst.Event.CLICKED_LEFT:
					await _do_state_deploying_clicked_left(false)
				GameConst.Event.CLICKED_RIGHT:
					pass
		GameConst.State.BUYING:
			match(event):
				GameConst.Event.CLICKED_SHOP:
					await _do_state_bying_clicked_shop(false)
				GameConst.Event.CLICKED_RIGHT:
					pass
		GameConst.State.NETWORK_WAITING:
			pass
		GameConst.State.ENDING:
			await _do_state_ending(false)

func _handle_camera_input(delta: float) -> void:
	if not _escape_panel.visible:
		if Input.is_action_pressed("move_up"):
			global_translate(Vector2.UP * delta * camera_move_speed)
		if Input.is_action_pressed("move_down"):
			global_translate(Vector2.DOWN * delta * camera_move_speed)
		if Input.is_action_pressed("move_left"):
			global_translate(Vector2.LEFT * delta * camera_move_speed * 1.5)
		if Input.is_action_pressed("move_right"):
			global_translate(Vector2.RIGHT * delta * camera_move_speed * 1.5)
		if target_camera_zoom.x > camera_min_zoom and Input.is_action_just_released("zoom_out"):
			if state != GameConst.State.BUYING:
				var tween: Tween = create_tween()
				target_camera_zoom = zoom - delta * camera_zoom_speed * Vector2.ONE
				tween.tween_property(self, "zoom", target_camera_zoom, 0.1)
		if target_camera_zoom.x < camera_max_zoom and Input.is_action_just_released("zoom_in"):
			if state != GameConst.State.BUYING:
				var tween: Tween = create_tween()
				target_camera_zoom = zoom + delta * camera_zoom_speed * Vector2.ONE
				tween.tween_property(self, "zoom", target_camera_zoom, 0.1)

### States
# EARNING
func _do_state_earning(local: bool = true) -> void:
	var money_sum: int = 0
	for terrain: Terrain in _get_group_terrain():
		if terrain.player_owned == player_turns[0]:
			money_sum += _types.terrains[terrain.id]["funds"]
	await _add_money_on_current_player(money_sum, true)
	# TODO: daylie fuel consumption
	if local:
		state = GameConst.State.REPAIRING

# REPAIRING
func _do_state_repairing(local: bool = true) -> void:
	for unit: Unit in _get_group_unit():
		var terrain: Terrain = unit.get_terrain()
		if unit.is_on_terrain() and unit.player_owned == player_turns[0] and terrain.player_owned == player_turns[0] \
				and _types.terrains[terrain.id]["can_capture"]:
			# repair
			if unit.get_unit_stats().is_unit_damaged():
				var unit_max_health: int = ProjectSettings.get_setting("global/unit_max_health")
				var damage_to_repair: int = unit_max_health - unit.get_unit_stats().health
				var max_repair_points: int = ProjectSettings.get_setting("global/terrain_repair_health_points")
				var repair_points: int = max_repair_points if damage_to_repair > max_repair_points else damage_to_repair
				var cost_to_repair: int = _types.units[unit.id]["cost"] * repair_points / unit_max_health
				if player_turns[0].money >= cost_to_repair:
					unit.repair(repair_points)
					_add_money_on_current_player(-cost_to_repair)
					# create floating repair info
					var info_repair: FloatingInfo = _floating_info.instantiate()
					info_repair.text = str(abs(unit.get_unit_stats().get_last_damage_as_float()))
					info_repair.color = ProjectSettings.get_setting("global/refill_color")
					unit.get_terrain().add_child(info_repair)
					await info_repair.finished
			# refill
			if unit.get_unit_stats().can_be_refilled():
				var info_refill: FloatingInfo = _floating_info.instantiate()
				info_refill.text = tr("REFILLED")
				info_refill.color = ProjectSettings.get_setting("global/refill_color")
				unit.get_terrain().add_child(info_refill)
				unit.refill()
				await info_refill.finished
	if local:
		state = GameConst.State.SELECTING

# SELECTING
func _do_state_selecting_clicked_left() -> void:
	if last_selected_terrain: 
		if last_selected_terrain.has_unit():
			var unit: Unit = last_selected_terrain.get_unit()
			if unit.player_owned == player_turns[0] and not unit.get_unit_stats().round_over:
				_sound.play("Click2")
				_deselect_unit()
				_deselect_unit()
				_unattack()
				_undeploy()
				_unenter()
				last_selected_unit = last_selected_terrain.get_unit()
				state = GameConst.State.COMMANDING
				_create_and_set_move_area(last_selected_unit)
				return
		elif last_selected_terrain.shop_units.size() > 0 and last_selected_terrain.player_owned == player_turns[0]:
			last_shop = _shop_scene.instantiate()
			last_shop.units = last_selected_terrain.shop_units
			last_shop.element_selected.connect(_on_panel_shop_selected)
			%ShopPlace.add_child(last_shop)
			_round_button.disabled = true
			last_shop.show()
			_sound.play("Click2")
			_deselect_unit()
			_deselect_unit()
			_unattack()
			_undeploy()
			_unenter()
			state = GameConst.State.BUYING
			return
	state = GameConst.State.SELECTING
		
func _do_state_selecting_clicked_right() -> void:
	_sound.play("Deselect")
	_deselect_unit()
	_unattack()
	_undeploy()
	_unenter()
	state = GameConst.State.SELECTING

# COMMANDING
func _do_state_commanding_clicked_left() -> void:
	if last_selected_terrain:
		# do command with action panel
		if last_selected_terrain in moveable_terrains:
			_sound.play("Click2")
			var actions: Array[GameConst.Actions] = []
			if not (last_selected_terrain.has_unit() and last_selected_terrain.get_unit() != last_selected_unit):
				actions.append(GameConst.Actions.MOVE)
				if _types.units[last_selected_unit.id]["can_capture"]:
					if _types.terrains[last_selected_terrain.id]["can_capture"] and last_selected_terrain.player_owned != player_turns[0]:
						actions.append(GameConst.Actions.CAPTURE)
				_unattack()
				_create_and_set_attack_area(last_selected_unit, last_selected_terrain)
				if len(attackable_terrains) > 0:
					actions.append(GameConst.Actions.ATTACK)
				_create_and_set_refill_area(last_selected_unit, last_selected_terrain)
				if len(refill_terrains) > 0:
					actions.append(GameConst.Actions.REFILL)
				_create_and_set_deploy_area(last_selected_unit, last_selected_terrain)
				if len(deploy_terrains) > 0:
					actions.append(GameConst.Actions.DEPLOY)
			_create_and_set_enter_area(last_selected_unit, last_selected_terrain)
			if last_selected_terrain in enter_terrains:
				actions.append(GameConst.Actions.ENTER)
			_create_and_set_join_area(last_selected_unit, last_selected_terrain)
			if last_selected_terrain in join_terrains:
				actions.append(GameConst.Actions.JOIN)
			if len(actions) > 0:
				_action_panel.set_buttons(actions)
				_action_panel.position = get_viewport().get_mouse_position()
				_action_panel.show()
				_selection_decal.hide()
				state = GameConst.State.ACTION
				# to prevent changing terrain while selecting action (by clicking on terrain instead of panel)
				last_action_terrain = last_selected_terrain
				return
		# do direct attack (direct clicking on attackable unit)
		elif last_selected_terrain in attackable_terrains and _types.units[last_selected_unit.id]["can_move_and_attack"]:
			if _move_arrow_node.curve.point_count > 0:
				await get_tree().create_timer(0.1).timeout
				var end_curve_terrain: Terrain = last_selected_unit.get_terrain_on_point(_move_arrow_node.curve.get_point_position(_move_arrow_node.curve.point_count - 1))
				last_action_terrain = end_curve_terrain
				if last_selected_terrain and last_selected_terrain.is_neighbor(end_curve_terrain):
					# block direct attack, when path end has a unit, except when it's the unit itself (eg. attacking other unit next to it)
					if not (end_curve_terrain.has_unit() and end_curve_terrain.get_unit() != last_selected_unit):
						state = GameConst.State.ATTACKING
						# to fire left click event
						_simulated_first_click = true
						_deselect_unit()
						_unattack()
						_unrefill()
						_unenter()
						_undeploy()
						_unjoin()
						_create_and_set_attack_area(last_selected_unit, last_action_terrain)
						return
	_sound.play("Deselect")
	state = GameConst.State.SELECTING
	_deselect_unit()
	_unattack()
	_unenter()
	_unjoin()

func _do_state_commanding_clicked_right() -> void:
	_sound.play("Deselect")
	_deselect_unit()
	_unattack()
	_unenter()
	_unjoin()
	state = GameConst.State.SELECTING

# ATTACKING
func _do_state_attacking_clicked_left(local: bool = true) -> void:
	_deselect_unit()
	_unenter()
	_selection_decal.hide()
	if last_selected_terrain in attackable_terrains:
		_unattack()
		_sound.play("Click2")
		if last_selected_unit.is_capturing():
			last_selected_unit.uncapture()
		last_selected_unit.move_curve = _move_arrow_node.curve
		var attacking_unit: Unit = last_selected_unit
		var defending_unit: Unit = last_selected_terrain.get_unit()
		await attacking_unit.unit_moved
		var attacking_transform: Transform2D = attacking_unit.global_transform
		var defending_transform: Transform2D = defending_unit.global_transform
		attacking_unit.damage_animated.connect(defending_unit.play_damage)
		defending_unit.damage_animated.connect(attacking_unit.play_damage)
		attacking_unit.look_at_plane_global_tween(defending_unit.get_terrain().global_position)
		defending_unit.look_at_plane_global_tween(attacking_unit.get_terrain().global_position)
		var distance: int = _get_unit_distance(attacking_unit, defending_unit)
		# attacking unit turn
		attacking_unit.play_attack()
		await attacking_unit.attack_animation_done
		var damage: Vector2 = Vector2.ZERO
		damage = _calculate_damage(attacking_unit, defending_unit)
		defending_unit.get_unit_stats().health -= int(damage.x)
		# create floating damage info
		var info: FloatingInfo = _floating_info.instantiate()
		info.text = str(defending_unit.get_unit_stats().get_last_damage_as_float())
		info.color = ProjectSettings.get_setting("global/attack_color")
		defending_unit.get_terrain().add_child(info)
		# take one ammo if it was primary weapon
		if attacking_unit.get_unit_stats().ammo > 0 and damage.y == 0:
			attacking_unit.get_unit_stats().ammo -= 1
		# defending unit turn
		if defending_unit.get_unit_stats().health > 0:
			# check if unit is next to it and defending unit can attack something next to it
			if distance <= 1 and _types.units[defending_unit.id]["min_range"] < 2:
				damage = _calculate_damage(defending_unit, attacking_unit)
				# check if defending unit can attack with weapon (> 0)
				if damage.x > 0:
					await get_tree().create_timer(0.2).timeout
					defending_unit.play_attack()
					await defending_unit.attack_animation_done
					attacking_unit.get_unit_stats().health -= int(damage.x)
					# create floating damage info
					info = _floating_info.instantiate()
					info.text = str(attacking_unit.get_unit_stats().get_last_damage_as_float())
					info.color = ProjectSettings.get_setting("global/attack_color")
					attacking_unit.get_terrain().add_child(info)
					# take one ammo if it was primary weapon
					if defending_unit.get_unit_stats().ammo > 0 and damage.y == 0:
						defending_unit.get_unit_stats().ammo -= 1
					if attacking_unit.get_unit_stats().health <= 0:
						# since attacking_unit gets freed, last_selected_unit (which is attacking unit) should be null (specially for networking)
						last_selected_unit = null
						attacking_unit.play_die()
						await attacking_unit.died
						attacking_unit.queue_free()
						await attacking_unit.tree_exited
						_calculate_all_unit_possible_move_terrain()
		else:
			defending_unit.play_die()
			await defending_unit.died
			if defending_unit.is_capturing():
				defending_unit.uncapture()
			defending_unit.queue_free()
			await defending_unit.tree_exited
			_calculate_all_unit_possible_move_terrain()
		attacking_unit.damage_animated.disconnect(defending_unit.play_damage)
		defending_unit.damage_animated.disconnect(attacking_unit.play_damage)
		if attacking_unit.is_inside_tree():
			attacking_unit.look_at_plane_global_tween(attacking_transform * Vector2.UP)
			attacking_unit.get_unit_stats().round_over = true
		if defending_unit.is_inside_tree():
			defending_unit.look_at_plane_global_tween(defending_transform * Vector2.UP)
	else:
		_sound.play("Deselect")
	_selection_decal.show()
	_unattack()
	if local:
		state = GameConst.State.SELECTING

func _do_state_attacking_clicked_right() -> void:
	_sound.play("Deselect")
	_unattack()
	state = GameConst.State.SELECTING

# REFILLING
func _do_state_refilling_clicked_left(local: bool = true) -> void:
	_selection_decal.hide()
	if last_selected_terrain in refill_terrains:
		_unrefill()
		_sound.play("Click2")
		last_selected_unit.move_curve = _move_arrow_node.curve
		var donor_unit: Unit = last_selected_unit
		var receiver_unit: Unit = last_selected_terrain.get_unit()
		await donor_unit.unit_moved
		var donor_unit_transform: Transform2D = donor_unit.global_transform
		donor_unit.look_at_plane_global_tween(receiver_unit.get_terrain().global_position)
		# refilling
		var info: FloatingInfo = _floating_info.instantiate()
		info.text = tr("REFILLED")
		info.color = ProjectSettings.get_setting("global/refill_color")
		receiver_unit.get_terrain().add_child(info)
		donor_unit.play_refill()
		receiver_unit.refill()
		receiver_unit.calculate_possible_terrains_to_move()
		await donor_unit.refill_animation_done
		if donor_unit.is_inside_tree():
			donor_unit.look_at_plane_global_tween(donor_unit_transform * Vector2.UP)
		donor_unit.get_unit_stats().round_over = true
	else:
		_sound.play("Deselect")
	_selection_decal.show()
	_unrefill()
	if local:
		state = GameConst.State.SELECTING

func _do_state_refilling_clicked_right() -> void:
	_sound.play("Deselect")
	_unrefill()
	state = GameConst.State.SELECTING

# DEPLOYING
func _do_state_deploying_clicked_left(local: bool = true) -> void:
	_selection_decal.hide()
	if last_selected_terrain in deploy_terrains:
		_undeploy()
		_sound.play("Click2")
		last_selected_unit.move_curve = _move_arrow_node.curve
		var carrying_unit: Unit = last_selected_unit
		var deploying_unit: Unit = carrying_unit.cargo.get_child(0)
		await carrying_unit.unit_moved
		# deploying
		## info text
		var info: FloatingInfo = _floating_info.instantiate()
		info.text = tr("DEPLOYED")
		info.color = ProjectSettings.get_setting("global/enter_color")
		carrying_unit.get_terrain().add_child(info)
		# place unit from cargo
		carrying_unit.cargo.remove_child(deploying_unit)
		last_selected_terrain.add_child(deploying_unit)
		deploying_unit.global_position = last_selected_terrain.get_move_on_global_position()
		deploying_unit.show()
		carrying_unit.get_unit_stats().round_over = true
		deploying_unit.get_unit_stats().round_over = true
		_sound.play("Entering")
		_calculate_all_unit_possible_move_terrain()
	else:
		_sound.play("Deselect")
	_selection_decal.show()
	_undeploy()
	if local:
		state = GameConst.State.SELECTING

func _do_state_deploying_clicked_right() -> void:
	_sound.play("Deselect")
	_undeploy()
	state = GameConst.State.SELECTING

# ACTION
func _do_state_action_clicked_action(local: bool = true) -> void:
	_selection_decal.show()
	# cancle capturing when moving away
	if last_selected_unit.is_capturing() and _move_arrow_node.curve.point_count > 1:
		last_selected_unit.uncapture()
	match(last_selected_action):
		GameConst.Actions.MOVE:
			_deselect_unit()
			_unattack()
			_unrefill()
			_unenter()
			_undeploy()
			_unjoin()
			last_selected_unit.move_curve = _move_arrow_node.curve
			await last_selected_unit.unit_moved
			last_selected_unit.get_unit_stats().round_over = true
		GameConst.Actions.ATTACK:
			await get_tree().create_timer(0.1).timeout
			if local:
				state = GameConst.State.ATTACKING
			_deselect_unit()
			_unattack()
			_unrefill()
			_unenter()
			_undeploy()
			_unjoin()
			_create_and_set_attack_area(last_selected_unit, last_action_terrain)
			return
		GameConst.Actions.ENTER:
			_deselect_unit()
			_unattack()
			_unrefill()
			_unenter()
			_undeploy()
			_unjoin()
			last_selected_unit.move_curve = _move_arrow_node.curve
			var entering_unit: Unit = last_selected_unit
			var carrying_unit: Unit = last_action_terrain.get_unit()
			await entering_unit.unit_moved
			# entering
			## info text
			var info: FloatingInfo = _floating_info.instantiate()
			info.text = tr("ENTERED")
			info.color = ProjectSettings.get_setting("global/enter_color")
			carrying_unit.get_terrain().add_child(info)
			## removing unit from field and add it to cargo of carrying unit
			entering_unit.hide()
			entering_unit.get_terrain().remove_child(entering_unit)
			carrying_unit.cargo.add_child(entering_unit)
			_sound.play("Entering")
		GameConst.Actions.JOIN:
			_deselect_unit()
			_unattack()
			_unrefill()
			_unenter()
			_undeploy()
			_unjoin()
			last_selected_unit.move_curve = _move_arrow_node.curve
			var source_unit: Unit = last_selected_unit
			var target_unit: Unit = last_action_terrain.get_unit()
			await source_unit.unit_moved
			# fusion
			## info text
			var info: FloatingInfo = _floating_info.instantiate()
			info.text = tr("JOINED")
			info.color = ProjectSettings.get_setting("global/refill_color")
			target_unit.get_terrain().add_child(info)
			## join unit together
			var max_health: int = ProjectSettings.get_setting("global/unit_max_health")
			var over_health: int = target_unit.get_unit_stats().health + source_unit.get_unit_stats().health - max_health
			var over_money: int = _types.units[source_unit.id]["cost"] / max_health * over_health
			target_unit.get_unit_stats().health += source_unit.get_unit_stats().health
			target_unit.get_unit_stats().ammo += source_unit.get_unit_stats().ammo
			target_unit.get_unit_stats().fuel += source_unit.get_unit_stats().fuel
			source_unit.queue_free()
			_sound.play("Fusion")
			target_unit.get_unit_stats().round_over = true
			await _add_money_on_current_player(over_money, true)
		GameConst.Actions.DEPLOY:
			if local:
				state = GameConst.State.DEPLOYING
			_deselect_unit()
			_unattack()
			_unrefill()
			_unenter()
			_undeploy()
			_unjoin()
			_create_and_set_deploy_area(last_selected_unit, last_selected_terrain)
			return
		GameConst.Actions.REFILL:
			if local:
				state = GameConst.State.REFILLING
			_deselect_unit()
			_unattack()
			_unrefill()
			_unenter()
			_undeploy()
			_unjoin()
			_create_and_set_refill_area(last_selected_unit, last_selected_terrain)
			return
		GameConst.Actions.CAPTURE:
			_deselect_unit()
			_unattack()
			_unrefill()
			_unenter()
			_undeploy()
			_unjoin()
			last_selected_unit.move_curve = _move_arrow_node.curve
			await last_selected_unit.unit_moved
			if last_selected_unit.capture():
				var particles: Node3D = _capture_particles.instantiate()
				_map_slot.add_child(particles)
				particles.global_transform = last_selected_unit.global_transform
				_sound.play("Capturing")
				_check_ending_condition()
			last_selected_unit.get_unit_stats().round_over = true
	# to prevent selecting a unit after action is pressed
	await get_tree().create_timer(0.1).timeout
	if local:
		state = GameConst.State.SELECTING
	_deselect_unit()
	_unattack()
	_unrefill()
	_unenter()
	_undeploy()
	_unjoin()

func _do_state_action_clicked_right() -> void:
	_sound.play("Deselect")
	_deselect_unit()
	_unattack()
	_unrefill()
	_unenter()
	_undeploy()
	_unjoin()
	state = GameConst.State.SELECTING
	_action_panel.hide()

#BUYING
func _do_state_bying_clicked_shop(local: bool = true) -> void:
	if is_instance_valid(last_shop):
		last_shop.queue_free()
	if last_bought_unit:
		var unit: Unit = last_bought_unit.instantiate()
		var cost: int = _types.units[unit.id]["cost"]
		if cost <= player_turns[0].money:
			unit.player_owned = player_turns[0]
			last_selected_terrain.add_child(unit)
			unit.get_unit_stats().round_over = true
			await _add_money_on_current_player(-cost)
		else:
			_sound.play("Deselect")
	else:
		_sound.play("Deselect")
	if local:
		state = GameConst.State.SELECTING
	_selection_decal.show()

#ENDING
func _do_state_ending(local: bool = true) -> void:
	_selection_decal.hide()
	var player: Player = player_turns.pop_front()
	player_turns.append(player)
	_deselect_unit()
	_unattack()
	_unrefill()
	_unenter()
	_undeploy()
	turn_round += 1
	# TODO: change players not to be packed scenes, so they don't have to be instantiated to get some information (maybe a pool of already instantiated players...)
	_round_label.player_name = str(player_turns[0].player_number)
	_round_rect.color.r = player_turns[0].color.r
	_round_rect.color.g = player_turns[0].color.g
	_round_rect.color.b = player_turns[0].color.b
	_round_number_label.text = str(turn_round)
	_round_number_label.add_theme_color_override("font_color", player_turns[0].color)
	_money_label.text = str(player_turns[0].money)
	_money_label.add_theme_color_override("font_color", player_turns[0].color)
	_animation_player.play("round_change")
	for unit: Unit in _get_group_unit():
		unit.get_unit_stats().round_over = false
	_calculate_all_unit_possible_move_terrain()
	await round_change_ended
	# changing to input type (human, ai or network)
	input = player_turns[0].input_type
	# has to check with input (local doesn't work) since it's still in the network state machine
	if input != GameConst.InputType.NETWORK:
		state = GameConst.State.EARNING

# updates selecting decal and, if true, moving arrow
func _update_ui(update__move_arrow: bool = false) -> void:
	_cursor_collider.position = mouse_position
	if(_cursor_collider.has_overlapping_areas()):
		var terrain: Terrain =  _cursor_collider.get_overlapping_areas()[0]
		# only update when mouse terrain has changed
		if terrain and last_mouse_terrain != terrain:
			var tween: Tween = create_tween()
			tween.tween_property(_selection_decal, "position", terrain.position, 0.05)
			if update__move_arrow:
				_update_move_arrow_ui_input(terrain)
			else:
				_move_arrow_node.hide()
		last_mouse_terrain = terrain
	
# ui input gets only paths inside movable range
func _update_move_arrow_ui_input(end_terrain: Terrain) -> void:
	# convert curve in packed vector 3 array since it is better to handle and backed points have wrong points in between
	var curve: PackedVector2Array = []
	for i: int in _move_arrow_node.curve.point_count:
		curve.append(_move_arrow_node.curve.get_point_position(i))
	# check if the additional terrain would be a possible path. if not, create path by path finding
	if _is_path_possible(curve, end_terrain, last_selected_unit):
		_move_arrow_node.curve.add_point(end_terrain.position)
		_move_arrow_node.create_arrow()
	else:
		# keep arrow when pointing on attackable unit for direct attack
		if curve.size() > 0:
			var last_terrain: Terrain = last_selected_unit.get_terrain_on_point(curve[-1])
			if end_terrain in attackable_terrains and end_terrain.is_neighbor(last_terrain):
				pass
			else:
				_path_finding_move_arrow(end_terrain, true)
				_move_arrow_node.create_arrow()
		else:
			_path_finding_move_arrow(end_terrain, true)
			_move_arrow_node.create_arrow()
	_move_arrow_node.show()
	
# none ui gets paths outside of moveable range (eg. finding path to hq)
func _update__move_arrow_none_ui_input(end_terrain: Terrain) -> void:
	_path_finding_move_arrow(end_terrain, false)
	_move_arrow_node.hide()
	
func _path_finding_move_arrow(end_terrain: Terrain, only_in_movable: bool = true) -> void:
	_move_arrow_node.curve.clear_points()
	for point: Vector2 in _get_path(last_selected_unit.get_parent() as Terrain, end_terrain, last_selected_unit, only_in_movable):
		_move_arrow_node.curve.add_point(point)

# returns how many fields it's away (ignoring diagonal and "not movable terrains")
func _get_unit_distance(start: Unit, end: Unit) -> int:
	return _get_terrain_distance(start.get_terrain(), end.get_terrain())
	
# returns how many fields it's away (ignoring diagonal and "not movable terrains")
func _get_terrain_distance(start: Terrain, end: Terrain) -> int:
	var distance: Vector2 = end.global_position - start.global_position
	distance /= ProjectSettings.get_setting("global/grid_size")
	var value: float = abs(distance.x) + abs(distance.y)
	return round(value)

func _is_path_possible(current_path: PackedVector2Array, additional_terrain: Terrain, unit: Unit) -> bool:
	if not additional_terrain:
		return false
	if not additional_terrain in moveable_terrains:
		return false
	if current_path.size() == 0:
		return false
	# check if start point is on unit (eg. when unit got moved and next round gets clicked on)
	if not unit.get_terrain_on_point(current_path[0]) == unit.get_terrain():
		return false
	# check if additional terrain is a neighbor of last terrain (eg. when mouse moves diagonal)
	var last_terrain: Terrain = unit.get_terrain_on_point(current_path[-1])
	if not last_terrain.is_neighbor(additional_terrain):
		return false
	# check if new terrain not already exist in path (eg. going back)
	for point: Vector2 in current_path:
		if point.x == additional_terrain.position.x and point.y == additional_terrain.position.y:
			return false
	# check cost
	var cost: int = 0
	for point: Vector2 in current_path:
		# skip first terrain where unit sits on since it's not used in cost calculation
		if point == current_path[0]:
			continue
		var terrain: Terrain = unit.get_terrain_on_point(point)
		cost += _types.movements[terrain.id]["CLEAR"][_types.units[unit.id]["movement_type"]]
	cost += _types.movements[additional_terrain.id]["CLEAR"][_types.units[unit.id]["movement_type"]]
	if cost > _types.units[unit.id]["mp"]:
		return false
	return true

# if check_moveable is false the path finding returns paths outside of moveable range 
func _get_path(start: Terrain, end: Terrain, unit: Unit, check_moveable: bool = true) -> PackedVector2Array:
	var astar: AStar2D = AStar2D.new()
	var terrains: Array[Terrain]
	if check_moveable:
		terrains = moveable_terrains
		if not end in terrains:
			return PackedVector2Array()
	else:
		terrains = _get_group_terrain()
		# filter terrains with enemy units on it
		terrains = terrains.filter(func(a: Terrain) -> bool: return not (a.has_unit() and a.get_unit().player_owned != unit.player_owned))
		# add end back in list even when a enemy unit is there (so long distance moves are possible)
		if not end in terrains:
			terrains.append(end)
	var index: int = 0
	var points: Dictionary = {}
	for i: Terrain in terrains:
		var terrain: Terrain = i as Terrain
		var weight: int = _types.movements[terrain.id]["CLEAR"][_types.units[unit.id]["movement_type"]]
		if weight >= 0:
			points[terrain] = index
			astar.add_point(index, terrain.position, weight)
		index += 1
	for terrain: Terrain in points.keys():
		var p1: int = points[terrain]
		if terrain.get_up() in points:
			var p2: int = points[terrain.get_up()]
			astar.connect_points(p1, p2)
		if terrain.get_down() in points:
			var p2: int = points[terrain.get_down()]
			astar.connect_points(p1, p2)
		if terrain.get_left() in points:
			var p2: int = points[terrain.get_left()]
			astar.connect_points(p1, p2)
		if terrain.get_right() in points:
			var p2: int = points[terrain.get_right()]
			astar.connect_points(p1, p2)
			
	var start_point: int = points[start]
	var end_point: int = points[end]
	var result: PackedVector2Array = astar.get_point_path(start_point, end_point)
	return result

func _get_random_luck() -> int:
	var number: int = _random_luck.pop_front()
	_random_luck.append(number)
	return number

func _deselect_unit() -> void:
	moveable_terrains = []
	var areas: Array[Sprite2D] = _get_group_decal("move_area")
	for i: Sprite2D in areas:
		(i.get_parent() as Terrain).layer = null
		i.queue_free()
		
	_move_arrow_node.hide()
	
func _unattack() -> void:
	attackable_terrains = []
	var areas: Array[Sprite2D] = _get_group_decal("attack_area")
	for i: Sprite2D in areas:
		(i.get_parent() as Terrain).layer = null
		i.queue_free()
		
func _unrefill() -> void:
	refill_terrains = []
	var areas: Array[Sprite2D] = _get_group_decal("refill_area")
	for i: Sprite2D in areas:
		(i.get_parent() as Terrain).layer = null
		i.queue_free()
		
func _unenter() -> void:
	enter_terrains = []
	var areas: Array[Sprite2D] = _get_group_decal("enter_area")
	for i: Sprite2D in areas:
		(i.get_parent() as Terrain).layer = null
		i.queue_free()
		
func _undeploy() -> void:
	deploy_terrains = []
	var areas: Array[Sprite2D] = _get_group_decal("deploy_area")
	for i: Sprite2D in areas:
		(i.get_parent() as Terrain).layer = null
		i.queue_free()

func _unjoin() -> void:
	join_terrains = []
	var areas: Array[Sprite2D] = _get_group_decal("join_area")
	for i: Sprite2D in areas:
		(i.get_parent() as Terrain).layer = null
		i.queue_free()

func _create_and_set_move_area(unit: Unit, visibility: bool = true) -> void:
	moveable_terrains = await unit.get_possible_terrains_to_move()
	for i: Terrain in moveable_terrains:
		if i and visibility:
			var layer: DecalLayer = _move_layer.instantiate()
			layer.type = DecalLayer.Type.MOVE
			layer.add_to_group("move_area")
			i.layer = layer
		_create_and_set_enter_area(unit, i)
		_create_and_set_attack_area(unit, i)
		_create_and_set_join_area(unit, i)
			
func _create_and_set_attack_area(unit: Unit, target_terrain: Terrain, visibility: bool = true, check_move_and_attack: bool = true) -> void:
	# if unit moved and is not allowed to attack
	if check_move_and_attack:
		if _get_terrain_distance(unit.get_terrain(), target_terrain) > 0:
			if not _types.units[unit.id]["can_move_and_attack"]:
				return
	var terrains: Array[Terrain] = unit.get_possible_terrains_to_attack_from_terrain(target_terrain)
	for i: Terrain in terrains:
		if i and i.has_unit() and i.get_unit().player_owned != unit.player_owned:
			if visibility:
				var layer: DecalLayer = _move_layer.instantiate() as Sprite2D
				layer.type = DecalLayer.Type.ATTACK
				layer.add_to_group("attack_area")
				i.layer = layer
			attackable_terrains.append(i)

func _create_and_set_refill_area(unit: Unit, target_terrain: Terrain, visibility: bool = true) -> void:
	if not _types.units[unit.id]["can_supply"]:
		return
	var terrains: Array[Terrain] = unit.get_neighbors_from_terrain(target_terrain)
	for i: Terrain in terrains:
		if i and i.has_unit() and i.get_unit().player_owned == unit.player_owned and i.get_unit() != unit:
			if visibility:
				var layer: DecalLayer = _move_layer.instantiate() as Sprite2D
				layer.type = DecalLayer.Type.REFILL
				layer.add_to_group("refill_area")
				i.layer = layer
			refill_terrains.append(i)
			
# find terrains which contains carrying vehicles to join
func _create_and_set_enter_area(unit: Unit, target_terrain: Terrain, visibility: bool = true) -> void:
	enter_terrains = []
	var terrains: Array[Terrain] = [target_terrain]
	for i: Terrain in terrains:
		if i and i.has_unit() and i.get_unit().player_owned == unit.player_owned and i.get_unit() != unit:
			var target_unit: Unit = i.get_unit()
			if _types.units[target_unit.id]["can_carry"] and unit.id in _types.units[target_unit.id]["carrying_types"] \
			and target_unit.cargo.get_child_count() < _types.units[target_unit.id]["carrying_size"]:
				if visibility:
					var layer: DecalLayer = _move_layer.instantiate() as Sprite2D
					layer.type = DecalLayer.Type.ENTER
					layer.add_to_group("enter_area")
					i.layer = layer
				enter_terrains.append(i)
				
func _create_and_set_deploy_area(unit: Unit, target_terrain: Terrain, visibility: bool = true) -> void:
	deploy_terrains = []
	if not _types.units[unit.id]["can_carry"] or unit.cargo.get_child_count() == 0:
		return
	var terrains: Array[Terrain] = unit.get_neighbors_from_terrain(target_terrain)
	for i: Terrain in terrains:
		if i and not i.has_unit():
			for deploy_unit: Unit in unit.cargo.get_children():
				if _types.movements[i.id]["CLEAR"][_types.units[unit.id]["movement_type"]] >= 0:
					if visibility:
						var layer: DecalLayer = _move_layer.instantiate() as Sprite2D
						layer.type = DecalLayer.Type.DEPLOY
						layer.add_to_group("deploy_area")
						i.add_child(layer)
					deploy_terrains.append(i)

func _create_and_set_join_area(unit: Unit, target_terrain: Terrain, visibility: bool = true) -> void:
	join_terrains = []
	var terrains: Array[Terrain] = [target_terrain]
	for i: Terrain in terrains:
		if i and i.has_unit() and i.get_unit().player_owned == unit.player_owned and i.get_unit() != unit:
			var target_unit: Unit = i.get_unit()
			var max_health: int = ProjectSettings.get_setting("global/unit_max_health")
			if target_unit.id == unit.id \
			and (target_unit.get_unit_stats().health < max_health or unit.get_unit_stats().health < max_health):
				if visibility:
					var layer: DecalLayer = _move_layer.instantiate() as Sprite2D
					layer.type = DecalLayer.Type.JOIN
					layer.add_to_group("join_area")
					i.layer = layer
				join_terrains.append(i)

func _add_money_on_current_player(value: int, sound: bool = false) -> void:
	var last_money: int = player_turns[0].money
	player_turns[0].money += value
	var tween: Tween = create_tween()
	tween.tween_method(_set_money_label, last_money, player_turns[0].money, ProjectSettings.get_setting("global/count_money_duration") as float).set_ease(Tween.EASE_IN_OUT)
	if sound:
		_sound.play("Coin")
	await tween.finished

func _on_panel_action_selected() -> void:
	_sound.play("Click")
	last_selected_action = _action_panel.action_pressed
	_action_panel_just_released = true
	
func _on_panel_shop_selected(unit_scene: PackedScene) -> void:
	_sound.play("Click")
	last_bought_unit = unit_scene
	_round_button.disabled = false
	_shop_panel_just_released = true
	
func _on_round_button_pressed() -> void:
	_sound.play("Click")
	_round_button.disabled = true
	event = GameConst.Event.CLICKED_END_ROUND

func _on_input_timer_timeout() -> void:
	_input_blocked = false

func _on_game_map_loaded() -> void:
	map = %MapSlot.get_child(0)
	# get player list
	for p: Player in map.players:
		player_turns.append(p)
	# set network players, so one network player is human
	_set_network_player_stats()
	# at the beginning the state starts with end game (for animation aso.)
	if player_turns[0].input_type == GameConst.InputType.NETWORK:
		input = player_turns[0].input_type
	else:
		state = GameConst.State.ENDING
	# set first player back so it starts with first player with a turn
	var player: Player = player_turns.pop_front()
	player_turns.append(player)
	_map_loaded = true
		
func _on_presence_changed() -> void:
	if len(_multiplayer.presences) < 2:
		_multiplayer.nakama_disconnect_from_match()
		_messages.spawn(tr("MESSAGE_TITLE_PLAYER_LEFT"), tr("MESSAGE_TEXT_PLAYER_LEFT"), true)

# Workaround for casting Array Type
func _get_group_terrain() -> Array[Terrain]:
	var group: Array[Node] = get_tree().get_nodes_in_group("terrain")
	var terrains: Array[Terrain] = []
	for i: Terrain in group:
		terrains.append(i)
	return terrains
	
# Workaround for casting Array Type
func _get_group_decal(group_name: String) -> Array[Sprite2D]:
	var group: Array[Node] = get_tree().get_nodes_in_group(group_name)
	var decals: Array[Sprite2D] = []
	for i: Sprite2D in group:
		decals.append(i)
	return decals
	
func _get_group_unit() -> Array[Unit]:
	var group: Array[Node] = get_tree().get_nodes_in_group("unit")
	var units: Array[Unit] = []
	for i: Unit in group:
		units.append(i)
	return units
	
func _get_unit_position_on_screen() -> Dictionary:
	var units: Array[Unit] = _get_group_unit()
	var positions: Dictionary = {}
	for unit: Unit in units:
		positions[unit] = to_local(unit.global_position)
	return positions
	
# returns Vector: x = -1 when no damage can be done (e.g. no possible weapons), y represents weapon type (primary -> 0, secondary -> 1)
func _calculate_damage(attacking_unit: Unit, defending_unit: Unit, random_luck: bool = true) -> Vector2:
	var base_damage: int = 0
	var weapon_type: int = -1
	var primary_damage: int = _types.primary_damage[attacking_unit.id][defending_unit.id]
	var secondary_damage: int = _types.secondary_damage[attacking_unit.id][defending_unit.id]
	# when attacking unit has enough ammo for primary weapon
	if (attacking_unit.get_unit_stats().ammo > 0 or attacking_unit.get_unit_stats().ammo == -1) \
			# and defending unit "accepts" primary weapon
			and primary_damage > 0:
		base_damage = primary_damage
		weapon_type = 0
	else:
		# check if defending unit "accepts" secondary weapon
		if secondary_damage > 0:
			base_damage = secondary_damage
			weapon_type = 1
		else:
			# no weapons means no damage possible
			return Vector2(-1, -1)
	
	var luck: int = 0
	if random_luck:
		# get deterministic "random" number between 0 and 9
		luck = _get_random_luck()
	else:
		luck = 5
		
	var attack_factor: float = (base_damage + luck) / 100.0
	var defense_factor: float = (100 - defending_unit.get_unit_stats().star_number * defending_unit.get_unit_stats().health / 10.0) / 100.0
	var total_damage: int = int(attacking_unit.get_unit_stats().health * attack_factor * defense_factor)
	return Vector2(total_damage, weapon_type)

func _calculate_all_unit_possible_move_terrain() -> void:
	var units: Array[Unit] = _get_group_unit()
	for unit: Unit in units:
		if unit.player_owned == player_turns[0]:
			unit.calculate_possible_terrains_to_move()
		
func _set_money_label(value: int) -> void:
	_money_label.text = str(value)
	
func _get_free_own_bases() -> Array[Terrain]:
	var bases: Array[Terrain] = []
	for terrain: Terrain in _get_group_terrain():
		if "Base" in terrain.name and terrain.player_owned == player_turns[0] and not terrain.has_unit():
			bases.append(terrain)
	return bases
	
# This function filters all terrains which are not movable. It is meant for AI calculation, since the player input is already filtered by the UI.
func _ai_create_and_filter_move_curve(target_terrain: Terrain) -> void:
	_update__move_arrow_none_ui_input(target_terrain)
	var unit: Unit = last_selected_unit
	var curve: Curve2D = _move_arrow_node.curve
	# remove all terrains reverse until it's in moveable terrain
	for i: int in range(curve.point_count - 1, 0, -1):
		var current_terrain: Terrain = unit.get_terrain_on_point(curve.get_point_position(i))
		if current_terrain in moveable_terrains:
			break
		curve.remove_point(i)
	
	# remove all terrains reverse until there is no unit on it or the terrain is not a HQ and unit is not infantery
	for i: int in range(curve.point_count - 1, 0, -1):
		var current_terrain: Terrain = unit.get_terrain_on_point(curve.get_point_position(i))
		if current_terrain.has_unit() or (not "Infantry" in unit.name and "QG" in current_terrain.name):
			curve.remove_point(i)
		else:
			break
	
func _ai_sort_attackable_terrain_most_valuable(attacking_unit: Unit) -> void:
	attackable_terrains.sort_custom(func(a: Terrain, b: Terrain) -> bool:
		var value_a: Vector2 = _calculate_damage(attacking_unit, a.get_unit()) * _types.units[a.get_unit().id]["cost"]
		var value_b: Vector2 = _calculate_damage(attacking_unit, b.get_unit()) * _types.units[b.get_unit().id]["cost"]
		return value_a > value_b)
	
func _ai_sort_moveable_terrain_nearest(unit: Unit) -> void:
	moveable_terrains.sort_custom(func(a: Terrain, b: Terrain) -> bool:
		var value_a: int = _get_terrain_distance(unit.get_terrain(), a)
		var value_b: int = _get_terrain_distance(unit.get_terrain(), b)
		return value_a < value_b)
	
func _check_ending_condition() -> void:
	for player: Player in player_turns:
		var has_qg: bool = false
		for terrain: Terrain in _get_group_terrain():
			if "QG" in terrain.name and terrain.player_owned == player:
				has_qg = true
				break
		if not has_qg:
			player_turns.erase(player)
			_global.last_player_won_name = str(player_turns[0].player_number)
			_global.last_player_won_color = player_turns[0].color
			_animation_player.play("end_game")
			# disconnect from presence changes so after the animation the player can leave without activating left player message
			if _multiplayer.client_role != _multiplayer.ClientRole.NONE:
				_multiplayer.nakama_presence_changed.disconnect(_on_presence_changed)

func _set_network_player_stats() -> void:
	if player_turns[0].input_type == GameConst.InputType.NETWORK:
		if _multiplayer.client_role == _multiplayer.ClientRole.HOST:
			player_turns[0].input_type = GameConst.InputType.HUMAN
			own_player_id = player_turns[0].player_number
	if player_turns[1].input_type == GameConst.InputType.NETWORK:
		if _multiplayer.client_role == _multiplayer.ClientRole.CLIENT:
			player_turns[1].input_type = GameConst.InputType.HUMAN
			own_player_id = player_turns[1].player_number

func _stringify_network_fsm_round() -> String:
	var data: Dictionary = {}
	data['type'] = _multiplayer.OpCodes.FSM_ROUND
	data['player_id'] = own_player_id
	data['state_event_id'] = player_turns[0].player_number * 10000 + _state_event_id
	_state_event_id += 1
	data['network_state'] = state
	data['network_event'] = event
	if last_selected_unit and is_instance_valid(last_selected_unit):
		data['network_selected_unit'] = last_selected_unit.get_path()
	if last_selected_terrain:
		data['network_selected_terrain'] = last_selected_terrain.get_path()
	if last_selected_action:
		data['network_selected_action'] = last_selected_action
	if last_action_terrain:
		data['network_action_terrain'] = last_action_terrain.get_path()
	if last_mouse_terrain:
		data['network_mouse_terrain'] = last_mouse_terrain.get_path()
	if last_bought_unit:
		data['network_bought_unit'] = last_bought_unit.resource_path
	else:
		# shop unit can be null when shop gets closed
		data['network_bought_unit'] = null
	return JSON.stringify(data)
	
func _remove_network_own_fsm_round() -> void:
	var new_list: Array[String] = _multiplayer.network_fsm_round_queue.filter(func(x: String) -> bool: return JSON.parse_string(x)['player_id'] != own_player_id)
	_multiplayer.network_fsm_round_queue = new_list
	new_list = _multiplayer.network_fsm_round_queue.filter(func(x: String) -> bool: return JSON.parse_string(x)['player_id'] != own_player_id)
	_multiplayer.network_fsm_round_queue = new_list
	
func _parse_network_fsm_round() -> void:
	# when broadcasting nakama states, the sender will receive it too
	_remove_network_own_fsm_round()
	# wait until a state change arrives
	while len(_multiplayer.network_fsm_round_queue) == 0:
		await get_tree().create_timer(0.1).timeout
	# TODO sort list by state_event_id
	if len(_multiplayer.network_fsm_round_queue) > 0:
		var data: String = _multiplayer.network_fsm_round_queue.pop_front()
		var parsed: Dictionary = JSON.parse_string(data)
		var _type: int = parsed['type']
		var _player_id: int = parsed['player_id']
		state = parsed['network_state']
		event = parsed['network_event']
		if parsed.has('network_selected_unit'):
			var network_selected_unit: NodePath =  parsed['network_selected_unit']
			last_selected_unit = get_node(network_selected_unit)
		if parsed.has('network_selected_terrain'):
			var network_selected_terrain: NodePath = parsed['network_selected_terrain']
			last_selected_terrain = get_node(network_selected_terrain)
		if parsed.has('network_selected_action'):
			last_selected_action = parsed['network_selected_action']
		if parsed.has('network_action_terrain'):
			var network_action_terrain: NodePath = parsed['network_action_terrain']
			last_action_terrain = get_node(network_action_terrain)
		if parsed.has('network_mouse_terrain'):
			var network_mouse_terrain: NodePath = parsed['network_mouse_terrain']
			last_mouse_terrain = get_node(network_mouse_terrain)
		if parsed.has('network_bought_unit'):
			if parsed['network_bought_unit']:
				var network_bought_unit: String = parsed['network_bought_unit']
				last_bought_unit = load(network_bought_unit)
			else:
				# shop unit can be null when shop gets closed
				last_bought_unit = null