<div align="center">

<img src="assets/banner.svg" alt="g1gGLe'z MW4 Performance Tool" width="100%"/>

<img src="assets/game.png" alt="Call of Duty: Modern Warfare 4" width="120"/>

<br/>

<a href="https://github.com/FiTH-g1gGLe/COD-MW4-Config-Tool/releases/latest/download/MW4-Performance-Tool.zip"><img src="https://img.shields.io/badge/DOWNLOAD-LATEST-FF5A1F?style=for-the-badge&logo=github&logoColor=white" alt="Download"/></a>
<a href="https://discord.gg/Br7z7zBvFb"><img src="https://img.shields.io/badge/JOIN-DISCORD-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Discord"/></a>

<a href="https://github.com/FiTH-g1gGLe/COD-MW4-Config-Tool/releases/latest"><img src="https://img.shields.io/github/v/release/FiTH-g1gGLe/COD-MW4-Config-Tool?style=flat-square&color=FF5A1F&label=version" alt="Version"/></a>
<img src="https://img.shields.io/github/downloads/FiTH-g1gGLe/COD-MW4-Config-Tool/total?style=flat-square&color=FF5A1F&label=downloads&logo=github" alt="Downloads"/>
<img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0B0D11?style=flat-square&logo=windows&logoColor=white" alt="Windows"/>
<img src="https://img.shields.io/badge/PowerShell-5.1%2B-0B0D11?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell"/>
<img src="https://img.shields.io/badge/Call%20of%20Duty-Modern%20Warfare%204-0B0D11?style=flat-square" alt="Modern Warfare 4"/>

### Max FPS. Low latency. Smooth frame times. Tuned to *your* rig, not someone else's.

</div>

---

## 📸 In action

<div align="center">

<img src="assets/screenshot-changes.png" alt="Every change listed before you apply, with tooltips explaining each one" width="100%"/>

<sub><b>See every change before it happens.</b> Hover any row to learn what it does and why it suits your rig.</sub>

<br/><br/>

<img src="assets/screenshot-tuned.png" alt="Locked and loaded - config already tuned" width="100%"/>

<sub><b>Locked and loaded.</b> Run it again any time to check your config is still tuned.</sub>

</div>

---

## ⚡ Why this one is different

Most config packs copy one person's file onto every PC. That overwrites your monitor, GPU, audio device and driver
info with theirs, and ignores what your hardware can actually do.

This tool **reads your own config, detects your rig, and only changes the values that matter.**
Everything else in your file stays exactly as the game wrote it.

<table>
<tr>
<td width="33%" valign="top">

### 🎯 Built for your rig
CPU cores, GPU, video memory, resolution and refresh rate decide the settings, from a GTX 1650 to an RTX 5090.

</td>
<td width="33%" valign="top">

### 🔍 See every change
A live list shows each setting, what it is now and what it will become, *before* anything is written. Hover any row to see what it does and **why** that value suits your PC.

</td>
<td width="33%" valign="top">

### 🛡️ One-click undo
Every apply makes a timestamped backup. Pick one and hit **Restore** to roll back instantly.

</td>
</tr>
<tr>
<td valign="top">

### ✅ Game-checked values
Each value is checked against the allowed values the game writes next to that setting. Anything invalid is skipped, never forced.

</td>
<td valign="top">

### 🎧 Hear them first
Headphone mode cuts music and speaker processing and keeps 3D headphone audio, so footsteps come through clean.

</td>
<td valign="top">

### 🚀 Extra headroom
Optional High CPU priority for `cod.exe`, shader pre-loading on, cloud sync off so your settings stick.

</td>
</tr>
</table>

---

## 🚀 Quick start

> [!IMPORTANT]
> Launch Call of Duty **once** first and get to the main menu, then close it. That creates the settings files the tool tunes.

1. **[Download the latest release](https://github.com/FiTH-g1gGLe/COD-MW4-Config-Tool/releases/latest/download/MW4-Performance-Tool.zip)** and unzip it anywhere.
2. Double-click **`Run MW4 Config Tool.bat`**.
3. Check **YOUR RIG** on the left and fix anything that's wrong. Hover any option for an explanation and a recommendation.
4. Set your **LOADOUT**, review **CHANGES TO APPLY**, and hit **APPLY**.
5. In game: **Graphics → Restart Shaders Pre-Loading**, then restart the game.

> [!TIP]
> If the game asks to *"Set Optimal Settings & Run In Safe Mode"*, always choose **No**. It would undo your tuning.

> [!NOTE]
> **Auto-updates:** the tool checks for a new version every time it opens. If there is one, hit **UPDATE NOW** and it updates and restarts itself. No re-downloading.

---

## 🧠 How it reads your rig

| Your hardware | What it controls | Rule |
|---|---|---|
| 🧩 **CPU cores** | Render worker threads | physical cores − 1 (P-cores on Intel 12th–14th gen) |
| 🎮 **GPU vendor** | Latency | NVIDIA **Reflex** · AMD **Anti-Lag 2** · Intel **XeLL** |
| 🖼️ **GPU + VRAM + resolution** | Image mode | Native **SMAA + CAS** sharpening; **DLSS / FSR / XeSS** for 4K or under 8 GB VRAM (GTX cards get FSR) |
| 💾 **Video memory** | VRAM budget + textures | 12 GB+ → 0.9 · 8–11 GB → 0.8 · under 8 GB → 0.7 |
| 🖥️ **Refresh rate** | FPS cap | refresh − 3 for smooth frame pacing (uncapped above 300 Hz) |

### Loadout options

| Option | Choices |
|---|---|
| **Goal** | **Max FPS** (lowest textures, 2× filtering) or **Visibility** (sharper textures and 8× filtering, scaled to your VRAM) |
| **Image** | Auto · Native + SMAA + sharpening · Upscaler |
| **FPS cap** | Auto · Uncapped · Custom |
| **Audio** | Headphones or Speakers · mute music · announcer and hit marker volume |
| **HUD position** | Slide the minimap and HUD from the screen edge toward your crosshair |
| **Extras** | HDR · High CPU priority · lock graphics file read-only |

<details>
<summary><b>📋 Everything the baseline turns off or down (click to expand)</b></summary>

<br/>

- **Display:** exclusive Fullscreen, 100% resolution scale, V-Sync off in game and menus, dynamic resolution off
- **Blur:** motion blur, weapon blur, velocity blur and depth of field all off
- **Clutter:** blood, bullet casings, persistent damage decals and corpses off, bullet marks from your shots only
- **Quality:** lowest shadows, models, particles, shading, volumetrics, reflections, water, weather, terrain, tessellation
- **Heavy features:** ray tracing, frame generation and surface subdivision off
- **Power saving:** every "sustainability" and low-battery option off
- **Stability:** shader pre-loading on, cloud settings sync off, hardware-change reset off
- **Menus:** 120 FPS in menus, 30 FPS when the game is in the background, intro videos skipped
- **HUD:** square, rotating minimap (about 27% more map), magenta enemies if you're still on default red, HUD pulled in from the screen edges

</details>

---

## 🛡️ Safe by design

- **Never replaces your file.** It patches values in place, so the game's own detection lines stay correct.
- **Backups every time** in `%LOCALAPPDATA%\MW4ConfigTool\backups`, restorable from the window.
- **Won't write while the game is running.**
- **Admin only when needed.** CPU priority is the only thing that asks, and you can untick it.
- **Mouse, sensitivity, FOV and keybinds are never touched.**
- **Updates itself** from this page's releases with one click, keeping your settings and backups.

---

## ⌨️ Command line

```powershell
# Apply the recommended settings with no window
powershell -ExecutionPolicy Bypass -File .\MW4-Config-Tool.ps1 -Silent

# Show what would change without writing anything
powershell -ExecutionPolicy Bypass -File .\MW4-Config-Tool.ps1 -Silent -DryRun
```

<details>
<summary><b>❓ FAQ</b></summary>

<br/>

**It says it can't find the settings file.**
Launch the game once, reach the main menu, close it, then run the tool again.

**The game reset some of my settings.**
Run the tool again, or tick **Lock graphics file (read-only)** so the game can't change them.

**How do I undo everything?**
Pick the oldest backup in the **Backups** list and hit **Restore**.

**Will this get me banned?**
It only edits the game's own settings text files, the same ones the in-game menus write to.
It doesn't touch game files, memory or anti-cheat. As with any tweak, use it at your own risk.

</details>

---

## 🔗 Join the squad

<div align="center">

<a href="https://discord.gg/Br7z7zBvFb"><img src="https://img.shields.io/badge/Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Discord"/></a>
<a href="https://www.youtube.com/user/FiTHGAMINGOFFICIAL"><img src="https://img.shields.io/badge/YouTube-FF0000?style=for-the-badge&logo=youtube&logoColor=white" alt="YouTube"/></a>
<a href="https://www.facebook.com/FiTHGAMINGOFFICIAL/"><img src="https://img.shields.io/badge/Facebook-1877F2?style=for-the-badge&logo=facebook&logoColor=white" alt="Facebook"/></a>
<a href="https://steamcommunity.com/groups/FiTHOFFICIAL"><img src="https://img.shields.io/badge/Steam-171A21?style=for-the-badge&logo=steam&logoColor=white" alt="Steam"/></a>
<a href="http://fithgaming.co.uk/"><img src="https://img.shields.io/badge/fithgaming.co.uk-FF5A1F?style=for-the-badge&logo=googlechrome&logoColor=white" alt="Website"/></a>

**Be part of something ep1c.**

</div>

---

## 🙏 Credits

The "turn it all off" baseline follows the pattern of
[FR33THY's Call of Duty configs](https://github.com/FR33THYFR33THY/Github-Game-Configs) for Black Ops 6 and 7,
which use the same settings format.

<div align="center">
<br/>
<sub>Made by <b>g1gGLe</b> · <b>FiTH Gaming</b> · Fire in the Hole 🔥</sub>
<br/>
<sub>Unofficial fan-made tool. Not affiliated with or endorsed by Activision. Call of Duty and Modern Warfare are trademarks of Activision Publishing, Inc.</sub>
</div>
