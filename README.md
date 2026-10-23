# MW4 Config Tool

Tunes **Call of Duty: Modern Warfare 4** for maximum FPS and stability, based on the PC it runs on.

Instead of copying one fixed config onto every machine, the tool reads the game's own settings files,
detects your hardware, and changes only the values that should change. The lines the game uses to
recognise your PC (monitor, GPU, audio device, driver) are left untouched.

## How to use

1. Launch Call of Duty once, wait for the main menu, then close it (this creates the settings files).
2. Double-click **`Run MW4 Config Tool.bat`**.
3. Check the detected hardware on the left and fix anything that's wrong.
4. Pick your preferences, review the list of changes, and press **Apply**.
5. Open the game, go to **Graphics > Restart Shaders Pre-Loading**, then restart the game.
6. If the game asks to *"Set Optimal Settings & Run In Safe Mode"*, choose **No**.

Every Apply makes a backup first. Pick one from the **Backups** list and press **Restore** to put it back.
Backups are kept in `%LOCALAPPDATA%\MW4ConfigTool\backups`.

## What it sets

| Detected | Setting | Rule |
|---|---|---|
| CPU physical cores | Renderer worker count | cores - 1 (P-cores on Intel 12th-14th gen) |
| GPU vendor | Latency | NVIDIA Reflex / AMD Anti-Lag 2 / Intel XeLL |
| GPU, VRAM, resolution | Image | Native + SMAA + CAS sharpening; DLSS / FSR / XeSS for 4K or under 8 GB VRAM. GTX cards get FSR |
| VRAM | Video memory scale, textures | 12 GB+: 0.9 &middot; 8-11 GB: 0.8 &middot; under 8 GB: 0.7 |
| Refresh rate | FPS cap | refresh rate - 3 (uncapped above 300 Hz) |

Always: exclusive fullscreen, all blur and depth of field off, effects (blood, casings, decals, corpses) off,
lowest shadows / volumetrics / reflections / water / weather, ray tracing and frame generation off,
power-saving options off, shader pre-loading on, cloud settings sync off, resolution scale 100%.

Preferences:

- **Goal**: Max FPS, or Visibility (sharper textures and 8x filtering, scaled to your VRAM).
- **Audio**: Headphones (Embody Immerse on, THX speaker processing off, stereo) or Speakers.
- Mute music and war tracks, announcer volume, hit marker volume.
- HDR, High CPU priority for `cod.exe` (asks for admin), lock the graphics file read-only.

Every new value is checked against the allowed values the game writes next to each setting. Anything
that isn't valid in your game version is skipped and shown as skipped.

## Command line

```powershell
# Apply recommended settings with no window
powershell -ExecutionPolicy Bypass -File .\MW4-Config-Tool.ps1 -Silent

# Show what would change without writing anything
powershell -ExecutionPolicy Bypass -File .\MW4-Config-Tool.ps1 -Silent -DryRun
```

## Credits

The "turn it all off" baseline follows the pattern of
[FR33THY's Call of Duty configs](https://github.com/FR33THYFR33THY/Github-Game-Configs) for Black Ops 6 and 7,
which use the same settings format.
