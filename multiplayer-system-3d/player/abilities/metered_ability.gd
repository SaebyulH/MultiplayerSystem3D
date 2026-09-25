class_name MeteredAbility
extends Ability

## An ability that drains a meter while it is running and refills it while it is
## not, turning itself off when the meter runs dry.
##
## A metered ability is a **toggle**: pressing its key turns it on, pressing it
## again turns it off, and running out of meter turns it off too.  The meter is
## measured in **seconds of use** — a full pool buys [member max_meter] seconds
## and an empty one refills over [member recharge_seconds], so using part of the
## pool costs proportionally less to recover from.
##
## ## All runtime state lives in AbilityManager
##
## An Ability is a Resource shared by every player holding it, so nothing here may
## be per-player (CLAUDE.md).  The pool, its timestamp and the on/off flag are
## AbilityManager's (`_meter`, `_meter_stamp_ms`, `_meter_active`); this class is
## pure configuration plus the two effect hooks.
##
## ## Cooldown is the toggle delay
##
## [member Ability.cooldown] keeps its usual meaning — seconds between casts —
## which for a toggle is the floor on how fast it can be switched on and off.
## [method _init] forces it to 1.0: with the default single charge the pool gate
## and the `_cooldowns` deadline expire at the same instant, so that one number is
## the entire anti-spam gate and no new one is needed.
##
## ## Forced settings
##
## A metered ability is an INSTANT-cast, single-charge, server-cast toggle, and
## _init() pins all three because each other value is silently broken:
##
##   - EQUIP is never cast from the ability key at all — AbilityManager only
##     toggles `equipped_index` for it — and _cast_equipped() would unequip it
##     the moment it turned on.
##   - `max_charges > 1` routes the gate through `charge_interval` instead of
##     `cooldown`, quietly changing the toggle delay.
##   - CLIENT runs activate()/deactivate() off-server, where the
##     StatusEffectManager calls they need are silent no-ops: the meter would
##     burn down and nothing would happen.

## Seconds of continuous use a full meter buys.
@export var max_meter: float = 5.0
## Seconds for an empty meter to refill all the way back to [member max_meter].
@export var recharge_seconds: float = 7.0
## Meter, in seconds, that must be in the pool before the ability can be turned
## **on**.  A press that turns it *off* is never gated by this.
##
## Do not set this below `recharge / (1 + recharge)` seconds of meter — about
## 0.42 s at the defaults.  Under that threshold a player tapping at the boundary
## settles into a permanent short-cycle flicker (on ~0.4 s, off ~0.6 s, forever)
## at the same average uptime as using it in one burst, which is *better* for
## dodging fire and so rewards exactly the play the meter exists to discourage.
@export var min_activate_meter: float = 1.0


func _init() -> void:
	cast_type = CastType.INSTANT
	cast_mode = CastMode.SERVER
	max_charges = 1
	cooldown = 1.0


## Called when the meter turns on.
func activate(player: Player) -> void:
	pass


## Called when it turns off — by the player toggling it, by the meter running
## out, or by a loadout/respawn reset.  Runs on the server only: activate() and
## deactivate() both touch server-authoritative state, which is why
## [member Ability.cast_mode] is pinned to SERVER above.
func deactivate(player: Player) -> void:
	pass
