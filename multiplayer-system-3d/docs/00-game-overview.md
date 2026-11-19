# MultiplayerSystem3D — Game Synopsis

A human-readable description of what the game is: its pitch, cast, tone, modes and match flow. This page is deliberately non-technical. For how the systems work, start at [`README.md`](README.md).

## In one paragraph

**MultiplayerSystem3D** is a class-based team shooter in the TF2 tradition, built around a cast of exaggerated, low-poly characters who each carry a small kit of loud abilities. Two colour-coded factions — **SPI** in red and **SCI** in teal — fight over castles, courtyards and compact arena maps in objective modes like Escort, Domination and King of the Hill, with a free-for-all Deathmatch mode for players who want the roster turned loose on each other. The shooting is quick and movement-driven, the presentation is a tactical, high-contrast interface wrapped around a deliberately absurd cast, and a full 3D lobby lets players walk around, try their guns and host a match without ever leaving the game world.

## The pitch

> A tactical team shooter where a Soviet general, a hacker, an umbrella-carrying governess and a woman with a jetpack-grade air-strafe fight over the same castle.

The game is a hero shooter without the self-seriousness: three classes, eight distinct characters, and a weapon pool that ranges from a service rifle and a bow to a minigun, a nuke and a rocket launcher that can be steered in flight. Characters are defined less by a rigid role than by a couple of strong ideas — the general is enormous and unstoppable, the hacker cheats, the assassin class trades health for speed and debuffs — and the loadout screen lets a player tune the same character toward direct fire, explosives or support.

## Setting and tone

There is no story campaign. The setting is a stylised, semi-modern military world rendered in painted-toon shading: stone keeps with battlements, brick courtyards, industrial catwalks, alpine arenas and a few deliberately abstract blockout maps. The character art is low-poly and hand-authored, with sun-bleached uniforms, leather flight caps, oversized hats and the occasional glowing lab coat.

The tone sits between tactical and comic. The interface is severe — ink-black panels, hard corners, thin rules, one red action colour and one teal selection colour, Anton display type over Switzer UI text — while the characters are named things like **Gyenyeral Boldbaatar**, **Dr. Schweizerstein** and **BlackHat**, and one of them can draw a calligraphy character in the air and throw the element it represents at someone. The result reads as a serious-looking game about ridiculous people.

Teams are identified by colour and name everywhere: **SPI** is red, **SCI** is teal, and free-for-all is amber. The models themselves are not team-tinted; colours live in the HUD, roster, scoreboard and objective widgets. The two factions are otherwise symmetric — the same roster is available to both sides.

## The cast

Characters are grouped into three classes. A class determines the weapon pool; the character chosen within it determines the body, the stat profile and the ability kit.

### Assault

The direct-combat class. Assault characters get the explosives and heavy guns: rocket launchers, grenade launchers, a minigun, the AK-47.

- **Gyenyeral Boldbaatar** — a broad, moustached general in a green dress uniform. The tank of the roster: three times normal health, slow on foot, no air jumps at all. His kit is entirely physical — a large self-heal, a lunging **Bashdown** that pins an enemy to the floor, a wall-slam **Shoulder Charge**, and **Size Change**, which makes him bigger and tougher. He is the character you pick when you want to walk through a fight rather than around it.
- **FlyGirl** — a flight-capped pilot in a rust-red suit, built for explosion jumping. Low gravity, five stamina bars, two air jumps and two air dashes give her extraordinary time in the air; her kit includes **Low Gravity** as a passive, a **Carpet Bomb** volley fired from the rocket launcher at reduced per-rocket damage, and **Davy Crockett**, which drops a nuke beneath her. She is the most mobile character in the game and the one most likely to be somewhere she should not be.
- **Governess** — a severe figure under an enormous black wide-brim hat, with a white shirt and black tie. Twice normal health, a short-cooldown self-heal, and a **Carpet Bomb** rocket burst. Her description frames the umbrella as a shield; visually she is the prim, ominous counterpoint to the rest of the assault line.

### Assistance

The support class. Assistance characters carry healing and utility weapons — syringe guns, heal grenade launchers, medpack launchers — alongside ordinary sidearms.

- **Dr. Schweizerstein** — a bald, green-lit scientist in round sunglasses and a lab coat. A medic with bonus health, innate lifesteal and the ability to see enemy health. Her kit is **Poison Cloud**, a **Rejuvenation** heal-over-time that restores an enormous amount very quickly, **Shrink Enemy** (halves a target's size and health for five seconds), and **Field Dressing**, a charged ally heal.
- **Nerd** — a hooded figure with streaks of green and orange hair. A springy support character with two air jumps and a high jump, but slightly reduced damage and reload speed. His entire kit is **Calligraphy**: raise a canvas showing a character, trace it, and throw the element you drew. The better the trace, the harder the throw lands. It is the most unusual ability in the game and the clearest expression of the roster's sense of humour.
- **BlackHat** — a blue beanie, thick glasses, a cigarette and a tank top. The joke is that he plays a different game: **Teleport** blinks him a short distance, **Wallhacks** reveals enemies through walls, **Aimbot** grants a brief cone of aim assistance, and **Cheat Death** skips the respawn timer entirely — it can be used while dead. He has above-average health and no pretence of fairness.

### Assassin

The precision class. Assassin characters carry rifles, a sniper rifle, a heavy rifle, a bow, a revolver and a fowling piece, with shurikens and a derringer as sidearms.

- **Ghost** — a pale figure in a black bob and red top. The speed character: 35% faster, seven stamina bars, four times normal air acceleration, 60% lifesteal and a passive read on enemy health. Her kit is **Wallhack**, **Teleport**, **Invisibility** and **Noclip**, which lets her pass through walls and players and deals massive damage to anyone she exits inside of. She has no health bonus, so the whole character is "do not get hit".
- **Stalker** — a monochrome, glitch-like presence in a hood. A fast-firing attrition shooter: five times reload speed, four times fire rate, but only a quarter of normal damage per shot, backed by 30% lifesteal. Her kit is a charged **Smite** (ten casts), **Bleed**, **Burn** and **Eradicate**, a 360-degree burst that deals 1000 damage to every nearby enemy. She wins by applying pressure and never letting a wounded target reset.

## Weapons and loadouts

Every class has its own primary, secondary and melee pool, and the loadout screen lets the player pick one from each before locking in. The pools are archetype-driven rather than realistic:

- **Assault** primaries: rocket launcher, redirectable rocket launcher, gravity rocket launcher, grenade launcher, AK-47, minigun. Secondaries include an SMG, pistol, machine pistol, mine layer, MRE and knife; melee includes a knife and a molotov.
- **Assistance** primaries: syringe gun, heal grenade launcher, medpack launcher. Secondaries include pistol, machine pistol, sawed-off shotgun and a ball gun; melee is a syringe or knife.
- **Assassin** primaries: rifle, sniper rifle, heavy rifle, bow, revolver, fowling piece. Secondaries are shurikens or a derringer; melee is a katana or a backstab knife.

Weapons are visibly held and animated, with first-person and remote models shaded in the same painted-toon style as the characters. Some are straight upgrades in one dimension and liabilities in another — the minigun is heavy, the sniper is unforgiving, the bow rewards a full draw, the gravity rocket changes how a fight moves — which is what makes the loadout choice meaningful without a rigid class-lock.

## Movement and abilities

The movement is the foundation of the game. It is Quake/Source-style: fast acceleration, air-strafing, bunny-hop-adjacent momentum, crouch-sliding, a dash and dash-jump, double jumps on some characters, and stamina as the limiter. Characters diverge sharply here — Boldbaatar cannot jump in mid-air at all, FlyGirl can cross a courtyard without touching the ground, Ghost turns every corner into a launch — so movement is as much a part of the character identity as the gun.

Abilities sit on cooldowns and are the loud, readable layer on top. Most are instant and self-contained: a heal, a blink, a shield-break, a volley of rockets, a nuke, a wallhack, a debuff on whoever is under the crosshair. A few are sequences or channels — the calligraphy drawing, the shoulder charge, noclip — and those take over the character's presentation for their duration, hiding the weapon and switching the HUD to a countdown ring. Health regenerates after a delay by default; kills, lifesteal and healing abilities are the ways to stay in a fight.

## Modes

- **Deathmatch** — free-for-all, first to 20 kills. The only mode that does not split players into SPI and SCI.
- **Escort** — push a payload cart along a route to the end. The cart rolls back when nobody is on it, and some route sections are authored as rollback or roll-forward stretches.
- **Domination** — hold the most control points to score.
- **King of the Hill** — hold the single point, best of a set number of rounds.
- **Hybrid** — capture the point first, then escort the payload.
- **Control** — best of three, hold the point.

Matches run through a shared phase structure — waiting, setup, objective unlocked, active, overtime, round end, match end — and every mode uses the same HUD language: a mode-specific top panel, a kill feed, a leaderboard, and objective widgets that read the same way whether the objective is a cart or a point.

## Maps

The map list falls into three families.

- **The castle family** — `castle`, `esc_castle`, `dom_castle`, `koth_castle` and `hyb_castle`. Stone keeps, courtyards, battlements and rail lines, with the payload route and capture points laid out for the objective modes. `esc_castle` is the most complete: textured brick walls, grass, stone paving and a red-marked payload path; `dom_castle` lays its capture points out around a central keep.
- **The death arenas** — `death_castle`, `death_courtyard2`, `death_mountain`, `death_pit`, `death_rocket` and `death_stairs`. Compact free-for-all maps built for constant contact. `death_stairs` is the showpiece: a brick-walled dungeon with wooden beams, a central pit and a swinging spiked ball overhead.
- **The blockouts** — `2fort`, `bind` and `courtyard`. Deliberately untextured test maps, some in orange-and-white checker style, used for layout and netcode work rather than final art.

Every map is authored in TrenchBroom through func_godot and can carry brush-entity logic: moving platforms, rotating hazards, buttons and doors, capture volumes and payload routes. Health packs respawn on a timer and are consumed only by players who actually need them.

## The lobby and match flow

The game boots into a **3D lobby** rather than a flat menu — a normal playable map with a hosting terminal and a timed target range. A one-time title gate reads **CLICK TO DEPLOY**, then the player is dropped into the lobby with their stored loadout already applied.

From there:

1. Walk to the **HostServer** terminal and press E to open the **Match Menu**.
2. **START MATCH** shows a grid of map thumbnails with mode descriptions and a briefing preview. Picking one creates the match and opens the **staging room**.
3. The staging room uses the chosen map's thumbnail as its background and shows the roster for both teams (or a single FFA list for Deathmatch). Players pick an agent from a class-grouped strip, can open the full loadout editor, and mark themselves ready with **LOCK IN**. The host starts the match.
4. **FIND MATCH** lists LAN servers discovered automatically, plus a direct IP/join-code row. There is no external service required; a host can also run a dedicated server or be listed through an optional central browser.
5. During a match, Esc opens a pause menu; when the match ends, a results screen shows the scoreboard and returns everyone to the lobby.

Bots fill empty slots and are configurable — team, skill and individual traits — so a match can be played solo, co-op against bots, or with a mix of humans and bots.

## Presentation

The visual identity is "tactical interface, comic world". Character models use authored painted-toon materials with a rim-light pass; weapons are re-shaded to match whoever is holding them. Portraits are rendered square and used everywhere a character appears — roster, HUD, staging, results. Map thumbnails are generated 16:9 overviews, never cropped screenshots.

The HUD is built from the same design system as the menus: ink panels, uppercase tracked labels, a health bar that turns red below 30%, stamina cells, ability discs with cooldown pies, a kill feed and a leaderboard with team-coloured accent strips and ping colouring. Ability icons come from the game-icons.net library, credited in the loadout screen.

Audio is functional and characterful: per-character death sounds, distinct weapon reports, explosion and impact effects, and a siren before a nuke lands.

## Who it is for

Players who like TF2-style class dynamics, Quake-style movement and hero-shooter abilities in the same match. It is designed to be legible in a LAN setting — walk in, pick a character, understand your gun in ten seconds, and discover the depth in movement and ability timing. The roster is small enough to learn and varied enough that the same map plays differently depending on who is on it.

## State of the build

This is an actively developed prototype, not a finished retail game. Some maps are fully textured and some are deliberate greybox blockouts; the roster, weapon pools and modes are still being tuned; and the matchmaking/networking layer is being migrated from local hosting toward dedicated servers and an optional central browser. The synopsis above describes the intended game as it currently plays, not a locked feature list.
