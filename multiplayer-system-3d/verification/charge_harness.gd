extends Node

## Throwaway verification harness for the charged-weapon (bow) feature.
##
##   "C:/tools/godot/godot_console.exe" --path . res://verification/charge_harness.tscn
##
## Exit code is the number of failed checks.  Drives the real Player /
## WeaponController / Weapon resources directly (no ENet peer) — the same shape
## the damage-amp verification used.  Delete after use.

var _checks: int = 0
var _fails: int = 0

func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("PASS  ", label)
	else:
		_fails += 1
		print("FAIL  ", label, "   ", detail)


func _eq(label: String, got, want) -> void:
	_check(label, is_equal_approx(float(got), float(want)) if (got is float or got is int) and (want is float or want is int) else got == want,
		"got %s want %s" % [got, want])


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	var bow: Weapon = load("res://weapon/assassin_weapons/bow.tres")
	var arrow_scene: PackedScene = load("res://weapon/projectiles/scenes/arrow.tscn")

	_test_resource_config(bow)
	_test_validate_property()

	var player: Player = await _make_player(bow)
	if player == null:
		print("SUMMARY: could not build a Player — aborting")
		get_tree().quit(1)
		return
	var wc: WeaponController = player.weapon_controller

	_test_ratio_api(wc, bow)
	_test_ramp_math(wc, bow)
	_test_ordering_invariant(wc, bow)
	_test_min_charge(wc, bow)
	_test_movement_mult(wc, bow)
	# Must be awaited: it yields to let queue_free'd arrows actually leave the
	# tree, and a suspended coroutine would otherwise interleave with — and
	# pollute — every test after it.
	await _test_projectile_application(wc, bow, arrow_scene)
	_test_spread(wc, bow)
	_test_input_loop(wc)
	_test_stun_guard(wc)
	_test_bot(wc)
	await _test_hud()

	print("SUMMARY: %d/%d passed" % [_checks - _fails, _checks])
	get_tree().quit(_fails)


# --------------------------------------------------------------------------
# 1. The bow resource itself
# --------------------------------------------------------------------------
func _test_resource_config(bow: Weapon) -> void:
	_eq("bow.charged", bow.charged, true)
	_eq("bow.charge_time", bow.charge_time, 1.0)
	_eq("bow.min_charge", bow.min_charge, 0.0)
	_eq("bow.uncharged_damage_mult", bow.uncharged_damage_mult, 0.5)
	_eq("bow.uncharged_projectile_speed_mult", bow.uncharged_projectile_speed_mult, 0.2)
	_eq("bow.uncharged_extra_spread", bow.uncharged_extra_spread, 5.0)
	_eq("bow.charge_move_speed_mult", bow.charge_move_speed_mult, 0.5)
	_check("bow has a SHOOT fire", bow.has_shoot_fire())
	var shoot: WeaponFire = bow.weapon_fires[0]
	_eq("bow SHOOT fire is not automatic", shoot.automatic, false)
	_eq("bow SHOOT fire has no pre_shoot_delay", shoot.pre_shoot_delay, 0.0)


# --------------------------------------------------------------------------
# 2. Editor-only visibility rules over every weapon resource in the project
# --------------------------------------------------------------------------
func _test_validate_property() -> void:
	var charge_props: Array[String] = [
		"charge_time", "min_charge", "uncharged_damage_mult",
		"uncharged_projectile_speed_mult", "uncharged_extra_spread",
		"charge_move_speed_mult", "auto_fire_at_full_charge",
	]
	var dir := DirAccess.open("res://weapon")
	_check("weapon dir opened", dir != null)
	if dir == null:
		return
	var files: Array[String] = []
	_scan_tres(dir, "res://weapon", files)
	_check("found weapon resources", files.size() > 20, "found %d" % files.size())

	var hidden_ok := 0
	var charged_seen := 0
	var greyed_ok := 0
	for path in files:
		var w: Weapon = load(path)
		if w == null:
			continue
		for prop in charge_props:
			var d := {"name": prop, "usage": 0}
			w._validate_property(d)
			var hidden: bool = (d["usage"] & PROPERTY_USAGE_NO_EDITOR) != 0
			if hidden == not w.charged:
				hidden_ok += 1
		if w.charged:
			charged_seen += 1
		var dc := {"name": "charged", "usage": 0}
		w._validate_property(dc)
		var greyed: bool = (dc["usage"] & PROPERTY_USAGE_READ_ONLY) != 0
		if greyed == not w.has_shoot_fire():
			greyed_ok += 1
	_check("charge props hidden iff not charged (%d resources)" % files.size(), hidden_ok == files.size() * charge_props.size(),
		"%d/%d" % [hidden_ok, files.size() * charge_props.size()])
	_check("`charged` greyed iff no SHOOT fire", greyed_ok == files.size(), "%d/%d" % [greyed_ok, files.size()])
	_eq("exactly one weapon is charged (the bow)", charged_seen, 1)


func _scan_tres(dir: DirAccess, base: String, out: Array[String]) -> void:
	for sub in dir.get_directories():
		var child := DirAccess.open(base + "/" + sub)
		if child:
			_scan_tres(child, base + "/" + sub, out)
	for f in dir.get_files():
		if f.ends_with(".tres"):
			out.append(base + "/" + f)


# --------------------------------------------------------------------------
# 3. The two ratio readers, and the gating difference between them
# --------------------------------------------------------------------------
func _test_ratio_api(wc: WeaponController, bow: Weapon) -> void:
	wc._clear_charge_local()
	wc._charge_time = 0.0
	_eq("get_charge_ratio() is 0 when idle", wc.get_charge_ratio(), 0.0)
	# The ungated reader is what fire_intent scores from — it must report the
	# elapsed draw even with the flag down, or a cancel landing first would
	# downgrade the shot (this is the invariant test below, stated directly).
	_eq("get_charge_ratio_for() is ungated", wc.get_charge_ratio_for(bow), 0.0)

	wc._charge_time = 0.6
	_eq("ratio_for reads _charge_time alone", wc.get_charge_ratio_for(bow), 0.6)
	_eq("gated reader still 0 while idle", wc.get_charge_ratio(), 0.0)

	wc._charge_active = true
	_eq("gated reader follows once drawing", wc.get_charge_ratio(), 0.6)
	wc._charge_time = 99.0
	_eq("ratio clamps at 1.0", wc.get_charge_ratio_for(bow), 1.0)
	wc._clear_charge_local()


# --------------------------------------------------------------------------
# 4. The three ramps, at zero / partial / full charge
# --------------------------------------------------------------------------
func _test_ramp_math(wc: WeaponController, bow: Weapon) -> void:
	# NB: mutate `wc._weapons[...]`, not the `bow` we loaded — set_weapons()
	# deep-copies, so the controller holds its own instance.
	var shoot: WeaponFire = wc._weapons[0].weapon_fires[0]
	shoot.multishot_data = []   # keep fire_intent a pure state op
	shoot = wc._weapons[0].weapon_fires[0]

	for ratio in [0.0, 0.6, 1.0]:
		var mag_before: int = bow.mag_current
		wc._charge_time = ratio * bow.charge_time
		wc._charge_active = true
		wc.fire_intent(0, 0)
		var tag := "ratio %.1f" % ratio
		_eq("%s: damage mult" % tag, wc._charge_damage_mult(), lerpf(0.5, 1.0, ratio))
		_eq("%s: projectile speed mult" % tag, wc._charge_projectile_speed_mult(), lerpf(0.2, 1.0, ratio))
		_eq("%s: charge ratio captured" % tag, wc._current_charge_ratio, ratio)
		_check("%s: draw consumed" % tag, not wc._charge_active)
		_eq("%s: _charge_time reset after scoring" % tag, wc._charge_time, 0.0)
		_eq("%s: cooldown started" % tag, wc._fire_cooldown > 0.0, ratio >= bow.min_charge)
		_eq("%s: ammo unchanged (infinite)" % tag, bow.mag_current, mag_before)
		wc._fire_cooldown = 0.0
		wc._is_firing = false

	# The "full charge is byte-identical to an ordinary weapon" property.
	wc._charge_time = bow.charge_time
	wc._charge_active = true
	wc.fire_intent(0, 0)
	_eq("full charge damage mult is exactly 1.0", wc._charge_damage_mult(), 1.0)
	_eq("full charge speed mult is exactly 1.0", wc._charge_projectile_speed_mult(), 1.0)
	wc._fire_cooldown = 0.0
	wc._is_firing = false

	# A stale ratio must not leak onto a weapon that isn't charged.
	wc._current_charge_ratio = 0.0
	var other: Weapon = load("res://weapon/shared/revolver.tres")
	_check("revolver is not charged", not other.charged)
	wc.set_weapons([other, bow])
	_eq("non-charged weapon ignores a stale ratio (damage)", wc._charge_damage_mult(), 1.0)
	_eq("non-charged weapon ignores a stale ratio (speed)", wc._charge_projectile_speed_mult(), 1.0)
	wc.set_weapons([bow])
	wc._current_charge_ratio = 1.0
	shoot = wc._weapons[0].weapon_fires[0]
	shoot.multishot_data = []


# --------------------------------------------------------------------------
# 5. THE invariant: cancel-vs-fire arrival order cannot change the shot
# --------------------------------------------------------------------------
func _test_ordering_invariant(wc: WeaponController, bow: Weapon) -> void:
	var shoot: WeaponFire = wc._weapons[0].weapon_fires[0]
	shoot.multishot_data = []

	# Order A: cancel lands, then the fire does.
	wc._clear_charge_local()
	wc._charge_time = 0.6
	wc._charge_active = true
	wc._cancel_charge_synced()
	_eq("cancel does not zero _charge_time", wc._charge_time, 0.6)
	wc.fire_intent(0, 0)
	var a: float = wc._current_charge_ratio
	wc._fire_cooldown = 0.0
	wc._is_firing = false

	# Order B: the fire lands, then the cancel does.
	wc._clear_charge_local()
	wc._charge_time = 0.6
	wc._charge_active = true
	wc.fire_intent(0, 0)
	var b: float = wc._current_charge_ratio
	wc._cancel_charge_synced()
	wc._fire_cooldown = 0.0
	wc._is_firing = false

	_eq("fire-then-cancel scores 0.6", a, 0.6)
	_eq("cancel-then-fire scores 0.6", b, 0.6)
	_eq("both orders score identically", a, b)
	_eq("...and the multiplier is the partial one", wc._charge_damage_mult(), lerpf(0.5, 1.0, 0.6))


# --------------------------------------------------------------------------
# 6. min_charge is an authoritative gate, not a client courtesy
# --------------------------------------------------------------------------
func _test_min_charge(wc: WeaponController, bow: Weapon) -> void:
	var shoot: WeaponFire = wc._weapons[0].weapon_fires[0]
	shoot.multishot_data = []

	# Mutate the controller's own copy, not the loaded resource (deep-copied by
	# set_weapons).
	var live: Weapon = wc._weapons[0]
	var saved: float = live.min_charge
	live.min_charge = 0.5

	wc._clear_charge_local()
	wc._charge_time = 0.4          # below the minimum
	wc._charge_active = true
	wc._fire_cooldown = 0.0
	wc._is_firing = false
	var mag_before: int = live.mag_current
	var ratio_before: float = wc._current_charge_ratio
	wc.fire_intent(0, 0)
	_eq("sub-minimum fire starts no cooldown", wc._fire_cooldown, 0.0)
	_check("sub-minimum fire did not start the fire cycle", not wc._is_firing)
	_eq("sub-minimum fire left the scored ratio untouched", wc._current_charge_ratio, ratio_before)
	_eq("sub-minimum fire cost no ammo", live.mag_current, mag_before)

	wc._charge_time = 0.6          # above the minimum
	wc._charge_active = true
	wc.fire_intent(0, 0)
	_check("at/above the minimum the shot goes through", wc._fire_cooldown > 0.0)
	_eq("...scored at 0.6", wc._current_charge_ratio, 0.6)

	live.min_charge = saved
	wc._fire_cooldown = 0.0
	wc._is_firing = false
	shoot.multishot_data = []
	wc._current_charge_ratio = 1.0


# --------------------------------------------------------------------------
# 7. Movement penalty, and that it compounds with the fire cycle's own mult
# --------------------------------------------------------------------------
func _test_movement_mult(wc: WeaponController, bow: Weapon) -> void:
	wc._clear_charge_local()
	wc._is_firing = false
	_eq("idle speed mult is 1.0", wc.get_active_fire_speed_mult(), 1.0)

	wc._charge_active = true
	_eq("drawing applies the weapon's charge_move_speed_mult", wc.get_active_fire_speed_mult(), 0.5)

	# Compound with move_speed_mult_while_shooting: 2.0 * 0.5 == 1.0.
	var shoot: WeaponFire = wc._weapons[0].weapon_fires[0]
	var saved: float = shoot.move_speed_mult_while_shooting
	shoot.move_speed_mult_while_shooting = 2.0
	wc._firing_fire_index = 0
	wc._is_firing = true
	_eq("draw (0.5) x fire cycle (2.0) compounds to 1.0", wc.get_active_fire_speed_mult(), 1.0)
	wc._clear_charge_local()
	_eq("fire cycle alone is 2.0", wc.get_active_fire_speed_mult(), 2.0)
	wc._is_firing = false
	shoot.move_speed_mult_while_shooting = saved

	wc._clear_charge_local()
	wc._fire_cooldown = 0.0
	wc._is_firing = false
	wc._current_charge_ratio = 1.0


# --------------------------------------------------------------------------
# 8. The spawned arrow actually carries the scaled speed and damage
# --------------------------------------------------------------------------
func _test_projectile_application(wc: WeaponController, bow: Weapon, arrow_scene: PackedScene) -> void:
	var shoot: WeaponFire = wc._weapons[0].weapon_fires[0]
	shoot.projectile_scene = arrow_scene

	for ratio in [0.0, 1.0]:
		wc._parent_player.velocity = Vector3.ZERO
		wc._current_charge_ratio = ratio
		var dir := Vector3(0, 0, -1)
		wc._spawn_projectile(shoot, dir, "harness-shooter", Player.Team.SPI)
		var arrow: Node3D = _last_projectile()
		var tag := "ratio %.1f" % ratio
		if arrow == null:
			_check("%s: arrow spawned" % tag, false)
			continue
		var want_speed: float = 60.0 * lerpf(0.2, 1.0, ratio)
		_eq("%s: arrow speed" % tag, arrow.linear_velocity.length(), want_speed)
		var hb: HitboxComponent = arrow.get_node_or_null("HitboxComponent")
		if hb == null:
			_check("%s: arrow has a HitboxComponent" % tag, false)
			continue
		# amp resolves to 1.0 (shooter not found) * charge damage mult
		_eq("%s: arrow damage" % tag, hb.health_delta, -100.0 * lerpf(0.5, 1.0, ratio))
		arrow.queue_free()
		await get_tree().process_frame

	wc._current_charge_ratio = 1.0


func _last_projectile() -> Node3D:
	var parent: Node3D = GameManager.projectile_parent
	if parent == null or parent.get_child_count() == 0:
		return null
	return parent.get_child(parent.get_child_count() - 1) as Node3D


# --------------------------------------------------------------------------
# 9. Spread: the extra degrees show up when uncharged, and vanish when full
# --------------------------------------------------------------------------
func _test_spread(wc: WeaponController, bow: Weapon) -> void:
	var shoot: WeaponFire = wc._weapons[0].weapon_fires[0]
	# Hitscan with a melee-short range: no muzzle-flash RPC, and an empty harness
	# world means the ray hits nothing, so this exercises the spread block alone.
	var saved_type: int = shoot.bullet_type
	var saved_range: float = shoot.hitscan_range
	shoot.bullet_type = WeaponFire.BulletType.HITSCAN
	shoot.hitscan_range = 5.0

	for ratio in [0.0, 1.0]:
		wc._current_spread = 0.0
		wc._current_charge_ratio = ratio
		wc._shot_was_scoped = true          # keep unscoped_spread out of it
		var want: float = 5.0 * (1.0 - ratio)
		# _fire_single_shot floors _current_spread at eff_min_spread, which the
		# charge term is folded into.
		wc._fire_single_shot(wc._weapons[0], 0, Vector3(0, 0, -1), null, false)
		_check("ratio %.1f: spread floor is %.1f deg" % [ratio, want],
			is_equal_approx(wc._current_spread, want), "got %f want %f" % [wc._current_spread, want])

	shoot.bullet_type = saved_type
	shoot.hitscan_range = saved_range
	wc._current_spread = 0.0
	wc._current_charge_ratio = 1.0


# --------------------------------------------------------------------------
# 10. The hold -> release loop, driven through _process_fire exactly as the
#     owning peer drives it.  This is the part the player actually feels.
# --------------------------------------------------------------------------
func _test_input_loop(wc: WeaponController) -> void:
	_prepare_fire(wc)
	var parent: Node3D = GameManager.projectile_parent
	_eq("the harness starts with no arrows in flight", parent.get_child_count(), 0)

	# Hold.  _sim runs _tick_timers before _process_fire, so the frame that
	# *starts* the draw cannot also accumulate into it — the ratio is still 0.
	_player.player_input.primary_fire_held = true
	_sim(wc, 1)
	_check("holding starts a draw", wc.is_charging_weapon())
	_eq("a draw starts at zero", wc.get_charge_ratio(), 0.0)

	_sim(wc, 2)
	_check("the draw accumulates while held",
		wc.get_charge_ratio() > 0.0 and wc.get_charge_ratio() < 1.0,
		"ratio %f" % wc.get_charge_ratio())

	_sim(wc, 70)
	_eq("a held draw reaches full charge", wc.get_charge_ratio(), 1.0)
	_eq("holding looses no arrow", parent.get_child_count(), 0)
	_check("still drawing at full charge", wc.is_charging_weapon())

	# Release.
	_player.player_input.primary_fire_held = false
	_sim(wc, 1)
	_eq("release looses exactly one arrow", parent.get_child_count(), 1)
	_check("release ends the draw", not wc.is_charging_weapon())
	_check("release started the cooldown", wc._fire_cooldown > 0.0)
	if parent.get_child_count() > 0:
		var arrow: Node3D = parent.get_child(0)
		_eq("the full-charge arrow flies at the authored speed", arrow.linear_velocity.length(), 60.0)

	# Holding through the post-shoot cooldown starts the next draw by itself —
	# the payoff for not latching `_fired_this_press` on charged fires.
	_player.player_input.primary_fire_held = true
	_sim(wc, 40)
	_check("no second draw while the cooldown is still running", not wc.is_charging_weapon())
	_sim(wc, 80)
	_check("holding through the cooldown re-starts the draw with no re-press",
		wc.is_charging_weapon(), "ratio %f cooldown %f" % [wc.get_charge_ratio(), wc._fire_cooldown])

	_player.player_input.primary_fire_held = false
	_sim(wc, 1)


# --------------------------------------------------------------------------
# 11. A stun / action block mid-draw must DROP the shot, not loose it.
#     PlayerInput force-clears the fire flags while blocked, which reaches the
#     release branch looking exactly like a deliberate release.
# --------------------------------------------------------------------------
func _test_stun_guard(wc: WeaponController) -> void:
	_prepare_fire(wc)
	var parent: Node3D = GameManager.projectile_parent
	var sem: StatusEffectManager = _player.status_effect_manager

	_player.player_input.primary_fire_held = true
	_sim(wc, 30)
	_check("drawing before the stun lands", wc.is_charging_weapon())
	var ratio_at_stun: float = wc.get_charge_ratio()

	var saved: int = sem._client_blocking_count
	sem._client_blocking_count = 1
	_player.player_input.primary_fire_held = false   # what PlayerInput does when blocked
	_sim(wc, 1)

	_eq("a stun mid-draw looses no arrow", parent.get_child_count(), 0)
	_eq("a stun mid-draw starts no cooldown", wc._fire_cooldown, 0.0)
	_check("a stun mid-draw ends the draw", not wc.is_charging_weapon())
	_check("...and it was a real draw (ratio %.2f)" % ratio_at_stun, ratio_at_stun > 0.0)
	sem._client_blocking_count = saved

	_player.player_input.primary_fire_held = false
	_sim(wc, 1)


# --------------------------------------------------------------------------
# 12. Bots.  A bot holding a charged weapon must draw to full and loose it,
#     rather than holding the trigger forever without ever firing.
# --------------------------------------------------------------------------
func _test_bot(wc: WeaponController) -> void:
	_prepare_fire(wc)
	var parent: Node3D = GameManager.projectile_parent
	var bot: BotController = _player.get_node("BotController")

	bot._chosen_fire_index = 0
	bot._try_fire_current_weapon(wc)
	_check("bot presses the trigger to begin a draw",
		_player.player_input.primary_fire_held)

	# The bot thinks at 20 Hz; drive one think per frame here so the loop is
	# deterministic.  It must release on the frame the draw completes.
	# charge_time is 1.0 s = 60 frames at this rate, so a working bot looses at
	# roughly frame 60; one that held the trigger forever would never loose at all.
	var loosed_at := -1
	for i in 400:
		wc._tick_timers(FRAME)
		wc._process_fire()
		bot._try_fire_current_weapon(wc)
		if parent.get_child_count() > 0:
			loosed_at = i
			break
	_check("bot loosed an arrow", loosed_at >= 0)
	_check("bot drew to full before loosing (frame %d, expected ~%d)" % [loosed_at, 60],
		loosed_at >= 55 and loosed_at <= 70)

	if parent.get_child_count() > 0:
		var arrow: Node3D = parent.get_child(0)
		_eq("the bot's arrow is a full-power one", arrow.linear_velocity.length(), 60.0)
	# Having loosed, the bot immediately re-presses and waits out the post-shoot
	# cooldown — no draw is active on this frame (the cooldown has just started),
	# which is the same "hold through the cooldown" cycle the human path proved.
	_check("bot re-presses for the next shot", _player.player_input.primary_fire_held)
	var arrows_before: int = parent.get_child_count()
	var repeated := false
	for i in 250:
		wc._tick_timers(FRAME)
		wc._process_fire()
		bot._try_fire_current_weapon(wc)
		if parent.get_child_count() > arrows_before:
			repeated = true
			break
	_check("bot looses a second arrow (the whole cycle repeats)", repeated)

	bot._clear_fire_inputs()
	wc._clear_charge_local()


# --------------------------------------------------------------------------
# 13. HUD.  PlayerUI only builds for a non-bot authority player (player_ui.gd
#     gates on that), so this needs its own player.  A mirrored-offset sign error
#     is invisible in gameplay tests and only shows up on screen.
# --------------------------------------------------------------------------
func _test_hud() -> void:
	var scene: PackedScene = load("res://player/player.tscn")
	var p: Player = scene.instantiate()
	p.is_bot = false
	p.name = "1"          # == multiplayer.get_unique_id() in a peerless run
	add_child(p)
	await get_tree().process_frame

	var ui: PlayerBodyUI = p.get_node_or_null("Body/PlayerUI") as PlayerBodyUI
	if ui == null:
		_check("HUD built a PlayerBodyUI", false)
		return
	_check("HUD built a PlayerBodyUI", true)

	var bar: ProgressBar = ui._charge_bar
	var label: Label = ui._charge_label
	var tick: ColorRect = ui._charge_min_tick
	if bar == null or label == null or tick == null:
		_check("HUD built the charge bar, label and threshold tick", false)
		return
	_check("HUD built the charge bar, label and threshold tick", true)

	# Mirrored against the scoped bar: +14..+114 becomes -114..-14.
	_eq("charge bar sits left of the crosshair (left)", bar.offset_left, -114.0)
	_eq("charge bar sits left of the crosshair (right)", bar.offset_right, -14.0)
	_eq("charge bar is vertically centred", bar.offset_top, -5.0)
	_eq("charge bar has the same height as the scoped one", bar.offset_bottom, 5.0)
	_eq("charge label sits further left", label.offset_left, -192.0)
	_eq("charge label sits further left (right edge)", label.offset_right, -122.0)
	_check("charge readout is right-aligned (it mirrors the scoped one)",
		label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT)
	_eq("charge bar is a 0..1 fraction", bar.max_value, 1.0)
	_check("charge bar starts hidden", not bar.visible)
	_check("charge label starts hidden", not label.visible)

	# The threshold tick must be a child of the bar so its fractional anchors
	# resolve against the bar's rect rather than the whole screen.
	_check("threshold tick is parented to the charge bar", tick.get_parent() == bar)
	_check("threshold tick starts hidden", not tick.visible)

	# min_charge 0 (the bow) -> no tick; a non-zero min_charge -> tick at that
	# fraction.
	p.weapon_controller.set_weapons([load("res://weapon/assassin_weapons/bow.tres")])
	p.weapon_controller._charge_active = true
	ui._update_charge_ui()
	_check("a draw shows the bar", bar.visible)
	_check("no threshold tick when min_charge is 0", not tick.visible)

	var live: Weapon = p.weapon_controller._weapons[0]
	live.min_charge = 0.5
	ui._update_charge_ui()
	_check("a non-zero min_charge shows the threshold tick", tick.visible)
	_eq("the tick is anchored at min_charge along the bar", tick.anchor_left, 0.5)

	p.weapon_controller._charge_active = false
	ui._update_charge_ui()
	_check("the bar hides when the draw ends", not bar.visible)

	p.queue_free()
	await get_tree().process_frame


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
const FRAME: float = 1.0 / 60.0

var _player: Player

## Drive one frame of the owning peer's fire path.
func _sim(wc: WeaponController, frames: int) -> void:
	for i in frames:
		wc._tick_timers(FRAME)
		wc._process_fire()


## Put the controller into a clean, firable state and re-arm a real projectile
## so the tests exercise the spawn path rather than a stubbed multishot list.
func _prepare_fire(wc: WeaponController) -> void:
	var live: Weapon = wc._weapons[0]
	var shoot: WeaponFire = live.weapon_fires[0]
	shoot.multishot_data = [Vector3(0, 0, -1)]
	shoot.projectile_scene = load("res://weapon/projectiles/scenes/arrow.tscn")
	shoot.bullet_type = WeaponFire.BulletType.PROJECTILE
	shoot.pre_shoot_delay = 0.0

	wc._switch_phase = WeaponController.SwitchPhase.IDLE
	wc._switch_timer = 0.0
	wc._fire_cooldown = 0.0
	wc._fire_cooldown = 0.0
	wc._is_reloading = false
	wc._is_firing = false
	wc._firing_remaining = 0.0
	wc._pending_fire = false
	wc._ability_fire_interrupt = false
	wc._current_spread = 0.0
	wc._current_charge_ratio = 1.0
	wc._clear_charge_local()
	wc._charge_time = 0.0
	wc._fired_this_press.clear()
	wc._any_fire_was_held = false
	_player.player_input.primary_fire_held = false
	_player.player_input.secondary_fire_held = false
	_player.player_input.tertiary_fire_held = false
	_clear_projectiles()


## Free everything in flight.  Safe to free immediately rather than queue_free:
## no frame elapses inside these tests, so a deferred free would leave the node
## visible to the next assertion.
func _clear_projectiles() -> void:
	var parent: Node3D = GameManager.projectile_parent
	if parent == null:
		return
	for child in parent.get_children():
		parent.remove_child(child)
		child.free()


# --------------------------------------------------------------------------
# Player construction
# --------------------------------------------------------------------------
func _make_player(bow: Weapon) -> Player:
	var world := Node3D.new()
	world.name = "HarnessWorld"
	add_child(world)
	# Projectiles get their own node — the real project does the same (the world's
	# ProjectilesParent).  Sharing one node with the Player made `get_child_count()`
	# off by one on every "did it fire?" assertion, which is exactly the kind of
	# harness bug that reads as a product bug.
	var projectiles := Node3D.new()
	projectiles.name = "ProjectilesParent"
	world.add_child(projectiles)
	GameManager.projectile_parent = projectiles
	GameManager.spawn_parent = world

	var scene: PackedScene = load("res://player/player.tscn")
	var player: Player = scene.instantiate()
	# Set before add_child: Player._enter_tree wires per-child authority off is_bot.
	player.is_bot = true
	player.name = "1"
	world.add_child(player)
	await get_tree().process_frame

	player.spawned = true
	player.weapon_controller.set_weapons([bow])
	player.weapon_controller.spawn_weapon_model()
	await get_tree().process_frame

	if not player.weapon_controller._is_ready():
		push_error("harness: WeaponController._is_ready() is false")
		return null
	_player = player
	# The switch animation started by set_weapons() would otherwise gate
	# _process_fire via is_switching() for the first few frames of every test.
	player.weapon_controller._switch_phase = WeaponController.SwitchPhase.IDLE
	player.weapon_controller._switch_timer = 0.0
	return player
