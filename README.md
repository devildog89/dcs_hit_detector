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

### Still to verify in DCS before event use

- `SetImmortal` is honored for client (human) groups.
- `PLAYER_SOUND` plays via `outSoundForUnit` (may need the file packed into the .miz).
- The CSV lands in `Saved Games\DCS...\Logs\` on a server with io/lfs un-sanitized.
