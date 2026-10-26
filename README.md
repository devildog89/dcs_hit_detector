# RedFlag Hit Detector

DCS World mission script for Red Flag-style training: player aircraft are made
immortal, and when a player is hit they get a private "Knock it off" message and
sound, the white cell sees a `[HIT]` broadcast, and the hit is logged to CSV.

Single file: [`redflag_hit_detector.lua`](redflag_hit_detector.lua). Install and
configuration notes are in the header and `CONFIG` block of that file.

## Versions

| Tag | Notes |
|-----|-------|
| `v1` | First draft. Never registers its event handler, so it does nothing in-game. |
| `v2` | Adds white-cell message and immortality. Syntax error on line 35, does not load. |
| `v3` | Single-file rewrite with config, filters, cooldown, CSV log. Several runtime bugs. |
| `v4` | Fixes the v3 bugs (one commit each, see `git log v3..v4`). Passes the offline harness. |

## Testing

The offline harness mocks the DCS scripting API and drives events through the
script. It checks logic only. **It does not replace testing in the mission editor.**

DCS uses Lua 5.1, so run it with Lua 5.1 or LuaJIT:

```sh
lua5.1 tests/test_hit_detector.lua            # or: luajit tests/test_hit_detector.lua
```

No local Lua? Run it in a throwaway container from the repo root (Docker, Lua 5.1.5):

```sh
docker run --rm -v "${PWD}:/src:ro" -w /src alpine:3.20 sh -c "apk add --no-cache lua5.1 >/dev/null && lua5.1 tests/test_hit_detector.lua"
```

To check the harness still catches a fixed bug, pass an older script as the argument
(e.g. `git show <rev>:redflag_hit_detector.lua > /tmp/old.lua`, mount it, and run
`lua5.1 tests/test_hit_detector.lua /path/to/old.lua`).

### Verified in DCS (single-player, mission editor, 2026-10-26)

- Missile hits (Tor `SA9M330`, AI `AIM_120C`) and gun hits (23 mm / 57 mm AAA,
  M61) are detected, labeled `Missile` / `Shell`, and logged with the shooter's
  unit name and the weapon type.
- The 15 s cooldown holds under sustained gun fire.
- `SetImmortal` protects a Player-skill aircraft: health unchanged after two Tor
  missile hits. (Not measured on the AAA run.)
- The CSV lands in `Saved Games\DCS\Logs\`, and a second mission load appends
  to it without repeating the header.
- The script runs from a DO SCRIPT FILE trigger with the file packed into the .miz.

### Still to verify before event use

- `SetImmortal` is honored for **Client** slots on a hosted multiplayer server.
- `PLAYER_SOUND` plays via `outSoundForUnit` (may need the file packed into the .miz).
  Not tested yet: the test machine was used over Remote Desktop, with no DCS audio.
