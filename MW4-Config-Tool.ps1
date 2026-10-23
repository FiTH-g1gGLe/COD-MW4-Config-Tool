<#
.SYNOPSIS
    MW4 Config Tool - tunes Call of Duty: Modern Warfare 4 (cod26) settings for the PC it runs on.

.DESCRIPTION
    Reads the game's own settings files, detects this PC's hardware, and patches only the values
    that should change (it never replaces the whole file, so the game's own hardware detection
    lines are kept). Every apply makes a timestamped backup that can be restored from the window.

    Run once with the game closed, after the game has been launched at least once.

.PARAMETER Silent
    No window. Detects hardware, applies the recommended settings, prints a summary.

.PARAMETER DryRun
    With -Silent: show what would change without writing anything.

.PARAMETER PlayersPath
    Override the game's players folder (default: %LOCALAPPDATA%\Activision\Call of Duty\players).
#>
[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$DryRun,
    [switch]$NoUpdateCheck,
    [string]$PlayersPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# ---------------------------------------------------------------------------------------------
#  Game constants - edit this block to support a future release
# ---------------------------------------------------------------------------------------------
$ToolName        = 'g1gGLe''z MW4 Performance Tool'
$ToolVersion     = '1.6.1'
$ReleaseApi = 'https://api.github.com/repos/FiTH-g1gGLe/COD-MW4-Config-Tool/releases/latest'
$ReleaseZip = 'MW4-Performance-Tool.zip'
$Links = @{
    Discord  = 'https://discord.gg/Br7z7zBvFb'
    YouTube  = 'https://www.youtube.com/user/FiTHGAMINGOFFICIAL'
    Facebook = 'https://www.facebook.com/FiTHGAMINGOFFICIAL/'
    Steam    = 'https://steamcommunity.com/groups/FiTHOFFICIAL'
    Website  = 'http://fithgaming.co.uk/'
}
$SystemFileName  = 's.1.0.cod26.txt'      # graphics / display / system settings (per PC)
$AccountFileName = 'g.cod26.1.0.l.txt'    # audio / mouse / FOV settings (per account, in a sub folder)
$GameProcess     = 'cod'                  # cod.exe
$PriorityKey     = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\cod.exe\PerfOptions'

$LocalAppData = $env:LOCALAPPDATA
if (-not $LocalAppData) { $LocalAppData = [IO.Path]::GetTempPath() }
if (-not $PlayersPath)  { $PlayersPath = Join-Path $LocalAppData 'Activision\Call of Duty\players' }
$BackupRoot = Join-Path $LocalAppData 'MW4ConfigTool\backups'

$Inv = [Globalization.CultureInfo]::InvariantCulture
function F6([double]$x) { $x.ToString('0.000000', $Inv) }   # game float format, always '.' decimals

# ---------------------------------------------------------------------------------------------
#  Settings file reading / writing
# ---------------------------------------------------------------------------------------------
# A setting line looks like:   Name@0;12345;67890 = value // optional comment with allowed range
$LineRegex = '^(?<key>[^/\s][^@]*@\d+)(?<mid>;\d+;\d+\s*=\s*)(?<val>.*?)(?<cmt>\s*//.*)?$'

function Read-CodFile([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $nl = "`n"; if ($text.Contains("`r`n")) { $nl = "`r`n" }
    $lines = $text -split "`r?`n"
    $values = [ordered]@{}; $comments = @{}
    foreach ($l in $lines) {
        $m = [regex]::Match($l, $LineRegex)
        if ($m.Success) {
            $values[$m.Groups['key'].Value]   = $m.Groups['val'].Value
            $comments[$m.Groups['key'].Value] = $m.Groups['cmt'].Value
        }
    }
    [pscustomobject]@{ Kind = 'Text'; Path = $Path; Lines = $lines; NewLine = $nl; Values = $values; Comments = $comments }
}

# ---------------------------------------------------------------------------------------------
#  Binary account settings (minimap, HUD colours...)
#  Layout: 1-byte header, records, short trailer.
#  Record: [UInt32 id][Byte index][UInt16 type][UInt16 type2][Byte kind][Byte length][value]
#  kind 9 = text (NUL-terminated), 6 = Int32, 8 = float, 1 = bool. Ids were mapped by changing
#  each option in game and comparing the file before and after.
# ---------------------------------------------------------------------------------------------
$BinSettings = @(
    [pscustomobject]@{ Name = 'MinimapShape@0'; File = 'g.cod26.pm.1.0.b'; Id = [uint32]3438256713; Index = 0; Kind = 9
                       Map = [ordered]@{ 'style' = 'Square'; 'none' = 'Round' } }
    [pscustomobject]@{ Name = 'MinimapRotation@1'; File = 'g.cod26.1.0.b'; Id = [uint32]3438256713; Index = 1; Kind = 9
                       Map = [ordered]@{ 'none' = 'On'; 'rotation_disabled' = 'Off' } }
    [pscustomobject]@{ Name = 'EnemyColor@0'; File = 'g.cod26.1.0.b'; Id = [uint32]1535289133; Index = 0; Kind = 6
                       Map = [ordered]@{ '-2' = 'Default red'; '45' = 'Magenta' } }
)

function ConvertTo-CodBinBytes($File) {
    $ms = New-Object System.IO.MemoryStream
    $ms.WriteByte($File.Header)
    foreach ($r in $File.Records) {
        $ms.Write($r.Head, 0, $r.Head.Length)
        $ms.WriteByte([byte]$r.Raw.Length)
        $ms.Write($r.Raw, 0, $r.Raw.Length)
    }
    $ms.Write($File.Trailer, 0, $File.Trailer.Length)
    return ,$ms.ToArray()
}

function Read-CodBinFile([string]$Path) {
    try {
        $b = [IO.File]::ReadAllBytes($Path)
        if ($b.Length -lt 12) { return $null }
        $recs = New-Object System.Collections.Generic.List[object]
        $i = 1
        while (($i + 11) -le $b.Length) {
            $flag = [int]$b[$i + 4]; $len = [int]$b[$i + 10]
            if ($flag -gt 15 -or ($i + 11 + $len) -gt $b.Length) { break }
            $head = New-Object byte[] 10; [Array]::Copy($b, $i, $head, 0, 10)
            $raw  = New-Object byte[] $len; [Array]::Copy($b, $i + 11, $raw, 0, $len)
            $recs.Add([pscustomobject]@{ Id = [BitConverter]::ToUInt32($b, $i); Index = $flag; Kind = [int]$b[$i + 9]; Head = $head; Raw = $raw })
            $i += 11 + $len
        }
        $trailer = New-Object byte[] ($b.Length - $i); [Array]::Copy($b, $i, $trailer, 0, $b.Length - $i)
        $file = [pscustomobject]@{ Kind = 'Bin'; Path = $Path; Header = $b[0]; Records = $recs; Trailer = $trailer
                                   Values = [ordered]@{}; Comments = @{}; Defs = @{} }
        # Only touch files we can rebuild byte-for-byte
        if ($trailer.Length -gt 32) { return $null }
        $check = ConvertTo-CodBinBytes $file
        if ($check.Length -ne $b.Length) { return $null }
        for ($j = 0; $j -lt $b.Length; $j++) { if ($check[$j] -ne $b[$j]) { return $null } }

        $leaf = Split-Path $Path -Leaf
        foreach ($def in @($BinSettings | Where-Object { $_.File -eq $leaf })) {
            $rec = $null
            foreach ($r in $recs) { if ($r.Id -eq $def.Id -and $r.Index -eq $def.Index -and $r.Kind -eq $def.Kind) { $rec = $r; break } }
            if (-not $rec) { continue }
            if ($def.Kind -eq 9) { $rawText = [Text.Encoding]::ASCII.GetString($rec.Raw).TrimEnd([char]0) }
            else { $rawText = [string][BitConverter]::ToInt32($rec.Raw, 0) }
            $shown = "Custom ($rawText)"
            if ($def.Map.Contains($rawText)) { $shown = $def.Map[$rawText] }
            $file.Values[$def.Name]   = $shown
            $file.Comments[$def.Name] = '// one of ' + (@($def.Map.Values) -join ', ')
            $file.Defs[$def.Name]     = [pscustomobject]@{ Def = $def; Rec = $rec }
        }
        if ($file.Values.Count -eq 0) { return $null }
        return $file
    } catch { return $null }
}

function Write-CodBinFile($File, $Changes) {
    foreach ($name in @($Changes.Keys)) {
        if (-not $File.Defs.ContainsKey($name)) { continue }
        $d = $File.Defs[$name]; $rawText = $null
        foreach ($k in $d.Def.Map.Keys) { if ($d.Def.Map[$k] -eq $Changes[$name]) { $rawText = $k } }
        if ($null -eq $rawText) { continue }
        if ($d.Def.Kind -eq 9) { $d.Rec.Raw = [Text.Encoding]::ASCII.GetBytes($rawText + [char]0) }
        else { $d.Rec.Raw = [BitConverter]::GetBytes([int]$rawText) }
    }
    [IO.File]::WriteAllBytes($File.Path, (ConvertTo-CodBinBytes $File))
}

function Write-CodFile($File, $Changes) {
    if ($File.Kind -eq 'Bin') { Write-CodBinFile $File $Changes; return }
    $out = foreach ($l in $File.Lines) {
        $m = [regex]::Match($l, $LineRegex)
        if ($m.Success -and $Changes.Contains($m.Groups['key'].Value)) {
            $m.Groups['key'].Value + $m.Groups['mid'].Value + $Changes[$m.Groups['key'].Value] + $m.Groups['cmt'].Value
        } else { $l }
    }
    # The game writes UTF-8 without BOM; keep its line endings.
    [IO.File]::WriteAllText($File.Path, ($out -join $File.NewLine), (New-Object Text.UTF8Encoding $false))
}

# Checks a new value against the game's own "// one of ..." or "// x to y" comment for that line.
function ConvertTo-PositiveInt($Text) {
    if ($null -eq $Text) { return $null }
    $s = ([string]$Text).Trim()
    if ($s -notmatch '^\d{1,9}$') { return $null }
    $n = [int]$s
    if ($n -gt 0) { return $n }
    return $null
}

function Test-CodValue([string]$Comment, [string]$Value) {
    if (-not $Comment) { return $true }
    $m = [regex]::Match($Comment, '//\s*one of (.+)$')
    if ($m.Success) { return (($m.Groups[1].Value.Trim() -split ',\s*') -ccontains $Value) }
    $m = [regex]::Match($Comment, '//\s*(-?[\d.]+) to (-?[\d.]+)')
    if ($m.Success) {
        # No TryParse/[ref] here: Windows PowerShell 5.1 can fail with "Argument types do not match" on it.
        if ($Value -notmatch '^\s*-?\d+(\.\d+)?\s*$') { return $false }
        $d = [double]::Parse($Value, $Inv)
        return ($d -ge [double]::Parse($m.Groups[1].Value, $Inv) -and $d -le [double]::Parse($m.Groups[2].Value, $Inv))
    }
    return $true
}

function Get-CodFiles {
    $files = New-Object System.Collections.Generic.List[object]
    $sys = Join-Path $PlayersPath $SystemFileName
    if (-not (Test-Path -LiteralPath $sys)) { return $null }
    $files.Add((Read-CodFile $sys))
    foreach ($d in @(Get-ChildItem -LiteralPath $PlayersPath -Directory -ErrorAction SilentlyContinue)) {
        $acc = Join-Path $d.FullName $AccountFileName
        if (-not (Test-Path -LiteralPath $acc)) { continue }   # not an account folder (e.g. a backup copy)
        $files.Add((Read-CodFile $acc))
        # Binary settings may sit in a sub folder (SteamCloud on Steam)
        foreach ($binName in @($BinSettings | ForEach-Object { $_.File } | Select-Object -Unique)) {
            $bin = Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Filter $binName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($bin) {
                $bf = Read-CodBinFile $bin.FullName
                if ($bf) { $files.Add($bf) }
            }
        }
    }
    return ,$files
}

# ---------------------------------------------------------------------------------------------
#  Hardware detection (each step falls back to what the game itself recorded)
# ---------------------------------------------------------------------------------------------
function Get-VramGB([string]$GpuName) {
    $best = 0
    try {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        foreach ($k in @(Get-ChildItem -Path $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
            $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $q = $p.PSObject.Properties['HardwareInformation.qwMemorySize']
            if (-not $q -or $null -eq $q.Value) { continue }
            $desc = ''; if ($p.PSObject.Properties['DriverDesc']) { $desc = [string]$p.DriverDesc }
            if ($GpuName -and $desc -and $desc -ne $GpuName) { continue }
            $bytes = if ($q.Value -is [byte[]]) { [BitConverter]::ToUInt64($q.Value, 0) } else { [uint64]$q.Value }
            if ($bytes -gt $best) { $best = $bytes }
        }
    } catch { }
    if ($best -gt 0) { return [int][math]::Round($best / 1GB) }
    try {   # NVIDIA fallback
        $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
        if ($smi) {
            $mib = & $smi.Source --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
            if ($mib) { return [int][math]::Round([double]$mib / 1024) }
        }
    } catch { }
    return $null
}

function Get-GpuVendor([string]$Name) {
    if ($Name -match 'NVIDIA|GeForce|RTX|GTX')        { return 'NVIDIA' }
    if ($Name -match 'AMD|Radeon')                     { return 'AMD' }
    if ($Name -match 'Intel|Arc')                      { return 'Intel' }
    return 'Unknown'
}

function Get-HardwareInfo($SysFile) {
    $v = $SysFile.Values
    $hw = [ordered]@{
        CpuName = ''; Cores = $null; Threads = $null; HybridIntel = $false
        GpuName = ''; Vendor = 'Unknown'; VramGB = $null
        Width = $null; Height = $null; RefreshHz = $null
        Drive = 'SSD'; RamGB = $null
    }

    # CPU - physical cores. On Intel hybrid chips with Hyper-Threading, P-cores = threads - cores.
    try {
        $cpu = @(Get-CimInstance Win32_Processor)
        $hw.CpuName = ([string]$cpu[0].Name).Trim()
        $hw.Cores   = [int](($cpu | Measure-Object NumberOfCores -Sum).Sum)
        $hw.Threads = [int](($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
    } catch { }
    if (-not $hw.Threads) { $hw.Threads = [Environment]::ProcessorCount }
    if (-not $hw.Cores)   { $hw.Cores = $hw.Threads }
    if ($hw.CpuName -match 'Intel' -and $hw.CpuName -match 'i\d-1[2-4]\d{3}|Core\(TM\) Ultra|Core Ultra') {
        $hw.HybridIntel = $true
        if ($hw.Threads -gt $hw.Cores) { $hw.Cores = $hw.Threads - $hw.Cores }   # P-cores only
    }

    # GPU - the game's own pick first
    if ($v.Contains('GPUName@0') -and $v['GPUName@0']) { $hw.GpuName = $v['GPUName@0'] }
    if (-not $hw.GpuName) {
        try {
            $g = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Virtual|Parsec|Remote|Meta' })
            $pick = $g | Where-Object { $_.Name -match 'NVIDIA|GeForce|Radeon|Arc' } | Select-Object -First 1
            if (-not $pick) { $pick = $g | Select-Object -First 1 }
            if ($pick) { $hw.GpuName = [string]$pick.Name }
        } catch { }
    }
    $hw.Vendor = Get-GpuVendor $hw.GpuName
    $hw.VramGB = Get-VramGB $hw.GpuName

    # Display - the game records the monitor it uses, e.g. "Auto:2560x1440" and "Auto:239.992"
    if ($v.Contains('Resolution@0')) {
        $m = [regex]::Match($v['Resolution@0'], '(\d+)x(\d+)')
        if ($m.Success) { $hw.Width = [int]$m.Groups[1].Value; $hw.Height = [int]$m.Groups[2].Value }
    }
    if ($v.Contains('RefreshRate@0')) {
        $m = [regex]::Match($v['RefreshRate@0'], '(\d+(\.\d+)?)')
        if ($m.Success) { $hw.RefreshHz = [int][math]::Round([double]::Parse($m.Groups[1].Value, $Inv)) }
    }
    if (-not $hw.Width -or -not $hw.RefreshHz) {
        try {
            $vc = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
            if ($vc) {
                if (-not $hw.Width)     { $hw.Width = [int]$vc.CurrentHorizontalResolution; $hw.Height = [int]$vc.CurrentVerticalResolution }
                if (-not $hw.RefreshHz) { $hw.RefreshHz = [int]$vc.CurrentRefreshRate }
            }
        } catch { }
    }

    if ($v.Contains('LastSavedDriveType@0') -and $v['LastSavedDriveType@0'] -eq 'hdd') { $hw.Drive = 'HDD' }
    if ($v.Contains('DetectedMemoryAmountMB@0')) {
        $mb = ConvertTo-PositiveInt $v['DetectedMemoryAmountMB@0']
        if ($mb) { $hw.RamGB = [int][math]::Round($mb / 1024) }
    }
    return $hw
}

# ---------------------------------------------------------------------------------------------
#  Rules: hardware + preferences -> the values to set
# ---------------------------------------------------------------------------------------------
function Get-HudPullDefault($Files) {
    foreach ($f in $Files) {
        if ($f.Kind -ne 'Text' -or -not $f.Values.Contains('HUDHorizBound@0')) { continue }
        $v = [string]$f.Values['HUDHorizBound@0']
        if ($v -notmatch '^\s*-?\d+(\.\d+)?\s*$') { continue }
        $d = [double]::Parse($v, $Inv)
        if ($d -ge 0.999) { return 15 }            # still at the game default: suggest a small pull-in
        return [int][math]::Round((1 - $d) * 100)  # keep what the player already chose
    }
    return 15
}

function New-DefaultPrefs {
    [ordered]@{
        Goal         = 'FPS'          # FPS | Visibility
        Image        = 'Auto'         # Auto | Native | Upscaler
        Cap          = 'Auto'         # Auto | Uncapped | Custom
        CapValue     = 0
        Audio        = 'Headphones'   # Headphones | Speakers
        MuteMusic    = $true
        Announcer    = 40             # percent
        HitMarkers   = 50             # percent
        HudPull      = 15             # percent toward the centre (0 = game default edge)
        HDR          = $false
        HighPriority = $true
        ReadOnly     = $false
    }
}

# ---------------------------------------------------------------------------------------------
#  Settings knowledge base - powers the tooltips in the change list
#  Format: Key | Friendly name | Impact | What it does | Why this value
# ---------------------------------------------------------------------------------------------
$SettingInfoText = @'
ResolutionMultiplier|Render Resolution|BIG FPS|Percentage of your screen resolution the 3D world is drawn at. Lower values look blurry and make far-away enemies hard to spot.|100% keeps the image sharp. If you need more FPS, an upscaler (DLSS/FSR/XeSS) gives far better results than lowering this.
DynamicSceneResolution|Dynamic Resolution|STABILITY|Drops resolution on the fly when the GPU is busy, so the image softens mid-fight.|Off, so the picture stays consistently sharp. The FPS cap keeps things stable instead.
DisplayMode|Display Mode|LATENCY|How the game owns your screen: windowed, borderless or exclusive fullscreen.|Exclusive Fullscreen gives the game direct control of the display for the lowest input lag.
PreferredDisplayMode|Preferred Display Mode|LATENCY|The display mode the game falls back to when it starts.|Matches Display Mode so the game always starts in exclusive Fullscreen.
VSync|V-Sync (in game)|LATENCY|Locks frames to your refresh rate to stop tearing, but adds noticeable input lag.|Off. The FPS cap plus Reflex/Anti-Lag gives smooth frames without the lag. Use G-Sync/FreeSync if your monitor has it.
VSyncInMenu|V-Sync (menus)|SMALL FPS|V-Sync while in menus only.|Off. Menus already have their own frame cap.
FocusedMode|Focused Mode|COMFORT|Dims everything outside the game window.|Off. Not needed when the game is fullscreen.
MotionBlur|Motion Blur|CLARITY|Smears the screen when you turn or move.|Off. Blur hides enemies during fast flicks and costs frames.
WeaponMotionBlur|Weapon Motion Blur|CLARITY|Blurs your gun when moving.|Off, for a clean view of your sights.
EnableVelocityBasedBlur|Velocity Blur|CLARITY|Radial blur around the edges of the screen when you sprint or slide.|Off. It narrows your effective view at the worst moments.
DofEnable|Depth of Field|CLARITY|Blurs things that are not in focus, like the background when aiming.|Off, so everything at every distance stays readable.
DofWorldDisable|World Depth of Field|CLARITY|Depth of field applied to the world around you.|Disabled for a clear background when aiming.
DofWeaponDisable|Weapon Depth of Field|CLARITY|Depth of field applied to your weapon.|Disabled for a crisp weapon and sights.
DepthOfFieldQuality|Depth of Field Quality|SMALL FPS|Quality of the blur filter if depth of field is used anywhere.|Low, the cheapest option, as depth of field is off anyway.
BloodLimit|Blood Limit|SMALL FPS|Limits how often blood effects can stack up.|On, to stop blood effects piling up in busy fights.
BloodLimitInterval|Blood Limit Interval|SMALL FPS|Minimum time between blood effects when Blood Limit is on.|2000 ms, the maximum, for the fewest blood effects.
ShowBlood|Blood Effects|CLARITY|Blood splatter on hits and on the screen.|Off. Less visual noise covering targets.
ShowBrass|Ejected Brass|SMALL FPS|Spent bullet casings flying out of guns.|Off. Pure eye candy that costs a little CPU in firefights.
MarksEntsPlayerOnly|Bullet Marks|SMALL FPS|Bullet marks on players and objects.|Only from your own shots, so other players' fire doesn't add clutter.
CorpseLimit|Corpse Limit|SMALL FPS|Maximum number of AI bodies left lying around (campaign and zombies).|0, so bodies disappear and free up CPU and GPU time.
CorpsesCullingThreshold|Corpse Culling|SMALL FPS|How aggressively bodies are removed.|0.5, the most aggressive setting.
PersistentDamageLayer|Persistent Damage|FPS|Keeps bullet holes and damage on walls and objects for the whole match.|Off. Decals pile up over a match and slowly cost frames.
SubdivisionLevel|Surface Subdivision|FPS|Extra geometry detail on curved surfaces.|0. Hard to notice in a fight, but costs GPU time.
ReflectionProbeRelighting|Reflection Relighting|SMALL FPS|How many stages are used to update reflections when lighting changes.|1, the cheapest. Reflections barely matter for gameplay.
ReflectionProbeHalfResolution|Half-Res Reflections|SMALL FPS|Draws reflection probes at half resolution.|On. Saves GPU time with no real visual loss.
StaticSunshadowClipmapResolution|Static Sun Shadows|FPS|Resolution of the pre-baked sun shadow map.|0, the lowest. Shadows are one of the most expensive effects.
CinematicEmissive|In-Game Cinematics|COMFORT|Plays full in-engine cinematics.|Off, for faster and lighter cutscenes.
CinematicQuality|Fallback Movies|COMFORT|Uses lighter pre-rendered movies for cutscenes.|On. Lighter to play and loads faster.
ModelQuality|Model Quality|FPS|Detail of characters, weapons and objects.|Low. Enemies keep the same shape and outline, but they're cheaper to draw.
ParticleQuality|Particle Quality|FPS|Detail of smoke, sparks, explosions and dust.|Very low. Thinner smoke and effects are easier to see through.
ShadowQuality|Shadow Quality|BIG FPS|Resolution and detail of shadows.|Very Low. Shadows are one of the biggest FPS costs in the game.
ShadowFilteringQuality|Shadow Filtering|FPS|Softening of shadow edges.|Low. Sharp shadow edges cost less.
ScreenSpaceShadowQuality|Screen Space Shadows|FPS|Extra fine contact shadows.|Off. Expensive for very little visible difference.
ShadingQuality|Shading Quality|FPS|Precision of lighting calculations on surfaces.|Low for more FPS.
ShaderQuality|Shader Quality|STABILITY|Complexity of the shaders the game compiles.|Low. Lighter shaders mean shorter shader compiling and fewer hitches.
SSRQuality|Screen Space Reflections|FPS|Real-time reflections on floors, water and glass.|Off. Costly, and reflections can show fake movement.
VolumetricQuality|Volumetric Lighting|FPS|Light shafts, fog and haze.|Low. Less fog means better visibility and more FPS.
WaterCausticsMode|Water Caustics|SMALL FPS|Rippling light patterns under water.|Off. Eye candy only.
WaterWaveWetness|Wave Wetness|SMALL FPS|Wet look on surfaces hit by waves.|Off. Eye candy only.
WeatherGridVolumesQuality|Weather Volumes|FPS|Detail of rain, snow and weather effects.|Off. Less screen clutter and more FPS.
AmbientLightingQuality|Ambient Lighting|FPS|Extra indirect lighting in the world.|Off. Can make dark corners darker, but costs a lot of GPU time.
TerrainQuality|Terrain Quality|FPS|Detail of the ground and landscape.|Very Low for more FPS.
Tessellation|Tessellation|FPS|Adds geometry detail to surfaces up close or everywhere.|Off. Heavy on the GPU for small detail.
DeferredPhysics|Deferred Physics|SMALL FPS|Quality of background physics like debris.|Low Quality. Debris barely matters in a gunfight.
WorldStreamingQuality|World Streaming|STABILITY|How much detail is streamed in as you move around the map.|Low, to reduce streaming stutter and memory use.
DxrMode|Ray Tracing|BIG FPS|Hardware ray-traced lighting and reflections.|Off. Ray tracing is a huge FPS cost in competitive play.
VRS|Variable Rate Shading|FPS|Shades less important parts of the screen at lower detail.|On. Free FPS with almost no visible difference.
DLSSFrameGeneration|DLSS Frame Generation|LATENCY|Inserts AI-generated frames between real ones.|Off. It adds input lag, and generated frames don't help you aim.
FSRFrameInterpolation|FSR Frame Generation|LATENCY|AMD's version of generated in-between frames.|Off, for the same reason as DLSS Frame Generation.
IntelXeFG|XeSS Frame Generation|LATENCY|Intel's version of generated in-between frames.|Off, for the same reason as DLSS Frame Generation.
SustainabilityMenuSceneResolution|Menu Power Saving|COMFORT|Lowers resolution in menus to save power.|Off, so menus and the lobby stay sharp.
SustainabilityReduceQualityIdle|Idle Power Saving|STABILITY|Lowers quality when you are idle for a while.|Off, so quality never changes underneath you.
SustainabilityPauseRendering|Pause Rendering|COMFORT|Stops drawing the game when paused or out of focus.|Off, so alt-tabbing back is instant.
UserEcoLowBatteryModeUI|Low Battery Mode|STABILITY|Reduces quality to save battery on laptops.|Off. Plug in and get full performance.
EnableOfflineGameUpdater|Shader Pre-Loading|STABILITY|Compiles shaders ahead of time instead of during matches.|On. The number one fix for stutter in Call of Duty.
ConfigCloudStorageEnabled|Cloud Config Sync|STABILITY|Syncs your settings files with the cloud.|Off, so the cloud can't overwrite your tuned settings.
DisableHWChangeDetection|Hardware Change Reset|STABILITY|Resets settings when the game sees new hardware or a new driver.|Disabled, so a driver update doesn't wipe your tuning. Run this tool again after a new GPU.
SkipIntro|Skip Intro|COMFORT|Skips the intro movie on launch.|On. Faster start-up.
SkipSeasonIntroVideo|Skip Season Intro|COMFORT|Skips the season intro video.|On. Faster start-up.
SkipSeasonVideo|Skip Season Video|COMFORT|Skips repeat season videos.|On. Faster start-up.
MaxFpsInMenu|Menu FPS Limit|COMFORT|Frame cap while in menus.|120. Keeps menus smooth without heating up your GPU for nothing.
MaxFpsOutOfFocus|Background FPS Limit|COMFORT|Frame cap when the game isn't the focused window.|30. Frees your PC for Discord, browser or OBS while tabbed out.
RendererWorkerCount|Render Threads|FPS|Number of CPU threads the renderer uses for its job queue.|Physical cores minus one leaves a core free for Windows, Discord and audio, which keeps frame times steady.
VideoMemoryScaleMP|Video Memory Budget|STABILITY|How much of your graphics card's memory the game is allowed to use.|Scaled to your VRAM: enough for streaming without running out and stuttering.
TextureQuality|Texture Quality|CLARITY|Resolution of surface textures. In this file, a higher number means lower quality.|Set from your goal and VRAM. Textures cost video memory more than FPS.
TextureFilter|Texture Filtering|CLARITY|Sharpness of surfaces viewed at an angle, like floors and walls.|2x for max FPS, 8x for visibility. 8x is almost free on modern GPUs.
BulletImpacts|Bullet Impacts|CLARITY|Shows where bullets hit.|Max FPS: off. Visibility: on, so you can see where your shots land.
NvidiaReflex|NVIDIA Reflex|LATENCY|Cuts the render queue so your clicks reach the screen faster.|Enabled. Lower input lag with no FPS cost.
AmdAntilag2|AMD Anti-Lag 2|LATENCY|AMD's in-game latency reduction.|On for AMD graphics cards. Lower input lag.
IntelXeLL|Intel XeLL|LATENCY|Intel's low latency mode.|On for Intel Arc graphics cards. Lower input lag.
AATechniquePreferredMP|Anti-Aliasing / Upscaler|CLARITY|How edges are smoothed, and whether an upscaler is used.|Native SMAA keeps the sharpest image when your GPU can handle it; DLSS/FSR/XeSS when you need the headroom.
AMDFidelityFX|AMD FidelityFX|CLARITY|AMD sharpening (CAS) or FSR upscaling. Works on any graphics card.|CAS with native SMAA restores crispness; FSR when an upscaler is needed.
AMDContrastAdaptiveSharpeningStrength|CAS Sharpening|CLARITY|Strength of the AMD CAS sharpening filter.|Full strength to cancel out SMAA softness and make edges pop.
DLSSPerfModeMP|DLSS Mode|FPS|How low DLSS renders before upscaling.|Balanced normally; Maximum Performance at 4K or on low-memory cards.
DLSSModelUI|DLSS Model|CLARITY|The AI model DLSS uses to rebuild the image.|Transformer on RTX 40/50 for a sharper image; CNN on older RTX cards, where it's cheaper.
XeSSQuality|XeSS Mode|FPS|How low XeSS renders before upscaling.|Balanced normally; Maximum Performance at 4K or on low-memory cards.
AMDSuperResolution2Quality|FSR Mode|FPS|How low FSR renders before upscaling.|Balanced normally; Maximum Performance at 4K or on low-memory cards.
CapFps|FPS Limit|STABILITY|Turns the in-game frame cap on or off.|On, just under your refresh rate, for even frame pacing; off above 300 Hz.
MaxFpsInGame|In-Game FPS Cap|STABILITY|Maximum frames per second in matches.|A few frames under your refresh rate keeps G-Sync/FreeSync active and frame times smooth.
HDR|HDR|CLARITY|High dynamic range output on HDR monitors.|Off by default for consistent, predictable brightness. Turn on if you have a good HDR monitor.
ThxLssEnabled|THX Spatial (Speakers)|AUDIO|THX 3D processing designed for loudspeakers.|Off on headphones, so it doesn't fight the headphone 3D audio. On for speakers.
ImmerseSpatialAudio|Embody Immerse|AUDIO|3D audio for headphones, so you can tell where sounds come from.|On for headphones: the best footstep direction and distance.
WindowsSonicEnable|Windows Sonic|AUDIO|Windows' own 3D audio for headphones.|Off, so sound isn't processed for 3D twice.
AudioWantedChannelsNumber|Audio Channels|AUDIO|Number of output channels the game mixes for.|2 (stereo) for headphones, which Immerse needs. System default for speakers.
MonoSound|Mono Audio|AUDIO|Mixes everything into one channel.|Off. Mono destroys left/right direction.
MusicVolume|Music Volume|AUDIO|Menu and in-match music.|Muted, so it never covers footsteps.
WarTracksVolume|War Tracks|AUDIO|Music played by War Tracks in vehicles.|Muted for clean audio.
TelescopeVolume|News Feed Audio|AUDIO|Audio from in-game news and messages of the day.|Muted.
CinematicVolume|Cinematic Volume|AUDIO|Cutscene and cinematic audio.|Muted for multiplayer focus.
MuteLicensedMusic|Licensed Music|AUDIO|Licensed songs in bundles and menus.|Muted. Also safer if you stream.
VoiceVolume|Announcer / Dialogue|AUDIO|Announcer callouts and character voice lines.|Lower than full, so you still hear UAV and killstreak callouts without them covering footsteps.
MinimapShape|Minimap Shape|CLARITY|Square or round minimap.|Square shows the corners a round minimap cuts off: about 27% more of the map at a glance.
MinimapRotation|Minimap Rotation|CLARITY|Whether the minimap turns with you or stays fixed north-up.|On: what's ahead of you on the minimap is always ahead of you on screen, so you read threats instantly without turning the map in your head.
EnemyColor|Enemy Colour|CLARITY|Colour used for enemies on the minimap, nameplates and pings.|Magenta almost never appears on CoD maps, so enemy markers pop instead of blending into red and orange lighting. Only changed if you were still on the default red.
HUDHorizBound|HUD Position (left/right)|CLARITY|How far the minimap, ammo counter and killfeed sit from the left and right screen edges. 1.0 is the edge, lower pulls them toward the centre.|Set from your HUD position slider.
HUDVertBound|HUD Position (top/bottom)|CLARITY|How far the HUD sits from the top and bottom screen edges. 1.0 is the edge, lower pulls it toward the centre.|Set from your HUD position slider.
HitMarkersVolume|Hit Marker Volume|AUDIO|Volume of the hit marker sound.|Half volume. Clear feedback that doesn't drown out footsteps mid-fight.
'@

$SettingInfo = @{}
foreach ($line in ($SettingInfoText -split "`r?`n")) {
    $p = $line -split '\|'
    if ($p.Count -ge 5) { $SettingInfo[$p[0].Trim()] = [pscustomobject]@{ Title = $p[1]; Impact = $p[2]; Info = $p[3]; Why = $p[4] } }
}

function Get-SettingInfo([string]$Key) {
    $name = $Key -replace '@\d+$', ''
    if ($SettingInfo.ContainsKey($name)) { return $SettingInfo[$name] }
    return [pscustomobject]@{ Title = $name; Impact = ''; Info = 'Game setting.'; Why = 'Part of the max-FPS baseline.' }
}

function Get-Plan($Hw, $Prefs) {
    $c = [ordered]@{}
    $why = @{}
    $notes = New-Object System.Collections.Generic.List[string]

    # --- Everything that costs FPS or clutters the screen, off (same pattern as FR33THY's BO6/BO7 configs)
    $base = [ordered]@{
        'ResolutionMultiplier@0' = '100';            'DynamicSceneResolution@0' = 'false'
        'DisplayMode@0' = 'Fullscreen';              'PreferredDisplayMode@0' = 'Fullscreen'
        'VSync@0' = 'disabled';                      'VSyncInMenu@0' = 'disabled';  'FocusedMode@0' = 'false'
        'MotionBlur@0' = 'Off';                      'WeaponMotionBlur@0' = 'false'; 'EnableVelocityBasedBlur@0' = 'false'
        'DofEnable@0' = 'Off';                       'DofWorldDisable@0' = 'true';  'DofWeaponDisable@0' = 'true'
        'DepthOfFieldQuality@0' = 'Low'
        'BloodLimit@0' = 'true';                     'BloodLimitInterval@0' = '2000'
        'ShowBlood@0' = 'false';                     'ShowBrass@0' = 'false';       'MarksEntsPlayerOnly@0' = 'true'
        'CorpseLimit@0' = '0';                       'CorpsesCullingThreshold@0' = '0.500000'
        'PersistentDamageLayer@0' = 'false';         'SubdivisionLevel@0' = '0'
        'ReflectionProbeRelighting@0' = '1';         'ReflectionProbeHalfResolution@0' = 'true'
        'StaticSunshadowClipmapResolution@0' = '0'
        'CinematicEmissive@0' = 'false';             'CinematicQuality@0' = 'true'
        'ModelQuality@0' = 'Low Quality';            'ParticleQuality@0' = 'very low'
        'ShadowQuality@0' = 'Very_Low';              'ShadowFilteringQuality@0' = 'Low'
        'ScreenSpaceShadowQuality@0' = 'Off';        'ShadingQuality@0' = 'Low';    'ShaderQuality@0' = 'Low'
        'SSRQuality@0' = 'Off';                      'SSRQuality@1' = 'Off'
        'VolumetricQuality@0' = 'QUALITY_LOW';       'VolumetricQuality@1' = 'QUALITY_LOW'
        'WaterCausticsMode@0' = 'Off';               'WaterWaveWetness@0' = 'false'
        'WeatherGridVolumesQuality@0' = 'Off';       'AmbientLightingQuality@0' = 'Off'
        'TerrainQuality@0' = 'Very Low';             'Tessellation@0' = '0_Off'
        'DeferredPhysics@0' = 'Low Quality';         'WorldStreamingQuality@0' = 'Low'
        'DxrMode@0' = 'Off';                         'DxrMode@1' = 'Off';           'VRS@0' = 'true'
        'DLSSFrameGeneration@0' = 'false';           'FSRFrameInterpolation@0' = 'false'; 'IntelXeFG@0' = 'false'
        'SustainabilityMenuSceneResolution@0' = 'off'; 'SustainabilityReduceQualityIdle@0' = 'off'
        'SustainabilityPauseRendering@0' = 'false';  'UserEcoLowBatteryModeUI@0' = 'false'
        'EnableOfflineGameUpdater@0' = 'true'
        'ConfigCloudStorageEnabled@0' = 'false';     'DisableHWChangeDetection@0' = 'true'
        'SkipIntro@1' = 'true';                      'SkipSeasonIntroVideo@0' = 'true'; 'SkipSeasonVideo@0' = 'true'
        'MaxFpsInMenu@0' = '120';                    'MaxFpsOutOfFocus@0' = '30'
    }
    foreach ($k in $base.Keys) { $c[$k] = $base[$k] }

    # --- CPU: render worker threads = physical cores - 1
    $cores = [int]$Hw.Cores
    if ($cores -lt 2) { $cores = 2 }
    $c['RendererWorkerCount@0'] = [string]([math]::Min(16, $cores - 1))
    $why['RendererWorkerCount@0'] = "Your CPU has $cores cores, so $($c['RendererWorkerCount@0']) render threads leaves one core free for Windows, Discord and audio."
    if ($Hw.HybridIntel) { $notes.Add("Intel hybrid CPU: using P-cores ($($Hw.Cores)) for the render thread count.") }

    # --- GPU memory
    $vram = $Hw.VramGB
    if (-not $vram) { $vram = 8; $notes.Add('Video memory not detected - assumed 8 GB. Fix it on the left if wrong.') }
    $c['VideoMemoryScaleMP@0'] = $(if ($vram -ge 12) { '0.900000' } elseif ($vram -ge 8) { '0.800000' } else { '0.700000' })
    $pct = $(if ($vram -ge 12) { 90 } elseif ($vram -ge 8) { 80 } else { 70 })
    $why['VideoMemoryScaleMP@0'] = "Your card has $vram GB of video memory. Letting the game use $pct% gives it room to stream textures with headroom to spare."

    if ($Prefs.Goal -eq 'Visibility') {
        $c['TextureQuality@0'] = $(if ($vram -ge 12) { '1' } elseif ($vram -ge 8) { '2' } else { '3' })
        $c['TextureFilter@0']  = 'aniso 8x'
        $c['BulletImpacts@0']  = 'true'
        $why['TextureQuality@0'] = "Visibility goal with $vram GB of video memory: the sharpest textures your card can hold without stutter (0 is best, 3 is lowest)."
    } else {
        $c['TextureQuality@0'] = '3'
        $c['TextureFilter@0']  = 'aniso 2x'
        $c['BulletImpacts@0']  = 'false'
        $why['TextureQuality@0'] = 'Max FPS goal: lowest textures (3) for the most frame rate and the least video memory use.'
    }

    # --- Latency tech for the GPU vendor
    switch ($Hw.Vendor) {
        'NVIDIA' { $why['NvidiaReflex@0'] = "You have an NVIDIA card ($($Hw.GpuName)): Reflex cuts input lag at no FPS cost."; $c['NvidiaReflex@0'] = 'Enabled'; $c['AmdAntilag2@0'] = 'false'; $c['IntelXeLL@0'] = 'false' }
        'AMD'    { $why['AmdAntilag2@0'] = "You have an AMD card ($($Hw.GpuName)): Anti-Lag 2 cuts input lag."; $c['AmdAntilag2@0'] = 'true';     $c['IntelXeLL@0'] = 'false' }
        'Intel'  { $why['IntelXeLL@0'] = "You have an Intel Arc card ($($Hw.GpuName)): XeLL cuts input lag."; $c['IntelXeLL@0'] = 'true';       $c['AmdAntilag2@0'] = 'false' }
        default  { $notes.Add('GPU vendor unknown - latency settings left as they are.') }
    }

    # --- Image: native SMAA + CAS sharpening, or the vendor's upscaler
    $image = $Prefs.Image
    if ($image -eq 'Auto') {
        if (($Hw.Width -and $Hw.Width -ge 3840) -or $vram -lt 8) { $image = 'Upscaler' } else { $image = 'Native' }
    }
    $resText = $(if ($Hw.Width) { "$($Hw.Width)x$($Hw.Height)" } else { 'your resolution' })
    if ($image -eq 'Native') {
        $why['AATechniquePreferredMP@0'] = "Your $($Hw.GpuName) with $vram GB can drive $resText natively, so SMAA plus CAS sharpening gives the sharpest image."
        $c['AATechniquePreferredMP@0'] = 'SMAA'
        $c['AMDFidelityFX@0'] = 'CAS'; $c['AMDFidelityFX@1'] = 'CAS'
        $c['AMDContrastAdaptiveSharpeningStrength@0'] = '1.000000'
    } else {
        $q = $(if (($Hw.Width -and $Hw.Width -ge 3840) -or $vram -lt 8) { 'Maximum Performance' } else { 'Balanced' })
        $why['AATechniquePreferredMP@0'] = "At $resText with $vram GB of video memory, an upscaler gives you the FPS headroom. Quality set to $q."
        $upVendor = $Hw.Vendor
        if ($upVendor -eq 'NVIDIA' -and $Hw.GpuName -notmatch 'RTX') { $upVendor = 'Other' }   # GTX cards have no DLSS
        switch ($upVendor) {
            'NVIDIA' {
                $c['AATechniquePreferredMP@0'] = 'DLSS'; $c['DLSSPerfModeMP@0'] = $q
                $c['DLSSModelUI@0'] = $(if ($Hw.GpuName -match 'RTX\s*(40|50)\d{2}') { 'TRANSFORMER' } else { 'CNN' })
                $c['AMDFidelityFX@0'] = 'Off'; $c['AMDFidelityFX@1'] = 'Off'
            }
            'Intel' {
                $c['AATechniquePreferredMP@0'] = 'XeSS'; $c['XeSSQuality@0'] = $q
                $c['AMDFidelityFX@0'] = 'Off'; $c['AMDFidelityFX@1'] = 'Off'
            }
            default {
                $c['AATechniquePreferredMP@0'] = 'FSR AA'; $c['AMDSuperResolution2Quality@0'] = $q
                $c['AMDFidelityFX@0'] = 'FSR 3'; $c['AMDFidelityFX@1'] = 'FSR 3'
                $notes.Add('FSR selected: open Graphics > Quality once in game and check upscaling shows FSR.')
            }
        }
    }

    # --- FPS cap: just under the refresh rate keeps frame pacing smooth
    switch ($Prefs.Cap) {
        'Uncapped' { $c['CapFps@0'] = 'false' }
        'Custom'   {
            $v = [int]$Prefs.CapValue
            if ($v -lt 30) { $v = 30 } elseif ($v -gt 300) { $v = 300 }
            $c['CapFps@0'] = 'true'; $c['MaxFpsInGame@0'] = [string]$v
        }
        default {
            if ($Hw.RefreshHz -and $Hw.RefreshHz -ge 60 -and $Hw.RefreshHz -le 300) {
                $c['CapFps@0'] = 'true'; $c['MaxFpsInGame@0'] = [string]([math]::Max(30, $Hw.RefreshHz - 3))
                $why['MaxFpsInGame@0'] = "Your monitor runs at $($Hw.RefreshHz) Hz. Capping at $($c['MaxFpsInGame@0']) keeps G-Sync/FreeSync active and frame times even."
                $why['CapFps@0'] = $why['MaxFpsInGame@0']
            } else {
                $c['CapFps@0'] = 'false'
            }
        }
    }

    $c['HDR@0'] = $(if ($Prefs.HDR) { 'Automatic' } else { 'Off' })

    # --- Audio (keys exist in both files; each file only gets the ones it has)
    if ($Prefs.Audio -eq 'Headphones') {
        $c['ThxLssEnabled@0'] = 'false'; $c['ImmerseSpatialAudio@0'] = 'true'
        $c['WindowsSonicEnable@0'] = 'false'; $c['AudioWantedChannelsNumber@0'] = '2'; $c['MonoSound@0'] = 'false'
    } else {
        $c['ThxLssEnabled@0'] = 'true'; $c['ImmerseSpatialAudio@0'] = 'false'
        $c['WindowsSonicEnable@0'] = 'false'; $c['AudioWantedChannelsNumber@0'] = '0'
    }
    if ($Prefs.MuteMusic) {
        foreach ($k in 'MusicVolume@0', 'WarTracksVolume@0', 'TelescopeVolume@0', 'CinematicVolume@0') { $c[$k] = '0.000000' }
        $c['MuteLicensedMusic@0'] = 'true'
    }
    $c['VoiceVolume@0']      = F6 ([double]$Prefs.Announcer / 100)
    $c['HitMarkersVolume@0'] = F6 ([double]$Prefs.HitMarkers / 100)

    $notes.Add('After applying: open the game, Graphics > Restart Shaders Pre-Loading, then restart the game.')
    $notes.Add("If the game asks to 'Set Optimal Settings & Run In Safe Mode', choose No.")
    # --- HUD: square minimap and magenta enemies for everyone; HUD position from the slider
    $c['MinimapShape@0'] = 'Square'
    $c['MinimapRotation@1'] = 'On'
    $c['EnemyColor@0']   = 'Magenta'
    $onlyIf = @{ 'EnemyColor@0' = 'Default red' }   # never override a colour the player picked
    $pull = [int]$Prefs.HudPull
    if ($pull -lt 0) { $pull = 0 } elseif ($pull -gt 100) { $pull = 100 }
    $hud = F6 (1 - ($pull / 100.0))
    $c['HUDHorizBound@0'] = $hud; $c['HUDVertBound@0'] = $hud
    $hudWhy = "Your HUD position slider is at $pull%. Pulling the minimap and HUD toward your crosshair means less eye travel mid-fight."
    if ($pull -eq 0) { $hudWhy = 'HUD position slider is at 0%: the game default, right at the screen edges.' }
    $why['HUDHorizBound@0'] = $hudWhy; $why['HUDVertBound@0'] = $hudWhy

    [pscustomobject]@{ Changes = $c; Notes = $notes; Why = $why; OnlyIf = $onlyIf }
}

function Get-PreviewRows($Files, $Changes, $Why, $OnlyIf) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($f in $Files) {
        $label = 'Account'
        if ((Split-Path $f.Path -Leaf) -eq $SystemFileName) { $label = 'Graphics' }
        if ($f.Kind -eq 'Bin') { $label = 'HUD' }
        foreach ($k in $Changes.Keys) {
            if (-not $f.Values.Contains($k)) { continue }
            $cur = $f.Values[$k]; $new = $Changes[$k]
            if ($cur -ceq $new) { continue }
            if ($OnlyIf -and $OnlyIf.ContainsKey($k) -and $cur -ne $OnlyIf[$k]) { continue }
            $fileLabel = $label
            if ($k -like 'HUD*Bound@*') { $fileLabel = 'HUD' }
            $ok = Test-CodValue $f.Comments[$k] $new
            $info = Get-SettingInfo $k
            $reason = $info.Why
            if ($Why -and $Why.ContainsKey($k)) { $reason = $Why[$k] }
            $rows.Add([pscustomobject]@{
                File = $fileLabel; Setting = $info.Title; Key = $k
                Info = $info.Info; Impact = $info.Impact; Why = $reason
                Current = $cur; New = $new; Path = $f.Path
                Status = $(if ($ok) { 'change' } else { 'skipped (not valid in this version)' })
            })
        }
    }
    return ,$rows
}

# ---------------------------------------------------------------------------------------------
#  Backup / apply / restore / priority
# ---------------------------------------------------------------------------------------------
function New-Backup([string[]]$Paths) {
    $dir = Join-Path $BackupRoot (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    foreach ($p in $Paths) {
        $rel  = $p.Substring($PlayersPath.Length).TrimStart('\', '/')
        $dest = Join-Path $dir $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        Copy-Item -LiteralPath $p -Destination $dest -Force
    }
    return $dir
}

function Get-Backups {
    if (Test-Path -LiteralPath $BackupRoot) { @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object Name -Descending) } else { @() }
}

function Restore-Backup([string]$Dir) {
    if (Get-Process -Name $GameProcess -ErrorAction SilentlyContinue) { throw 'Call of Duty is running. Close the game first.' }
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File)) {
        $rel  = $f.FullName.Substring($Dir.Length).TrimStart('\', '/')
        $dest = Join-Path $PlayersPath $rel
        if (Test-Path -LiteralPath $dest) { (Get-Item -LiteralPath $dest).IsReadOnly = $false }
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
    }
}

function Invoke-Apply($Files, $Rows, [bool]$ReadOnly) {
    if (Get-Process -Name $GameProcess -ErrorAction SilentlyContinue) { throw 'Call of Duty is running. Close the game first, then apply.' }
    $backup = New-Backup @($Files | ForEach-Object { $_.Path })
    foreach ($f in $Files) {
        $ch = [ordered]@{}
        foreach ($r in $Rows) { if ($r.Path -eq $f.Path -and $r.Status -eq 'change') { $ch[$r.Key] = $r.New } }
        $item = Get-Item -LiteralPath $f.Path
        if ($item.IsReadOnly) { $item.IsReadOnly = $false }
        if ($ch.Count -gt 0) { Write-CodFile $f $ch }
        # Only the graphics file gets locked, so mouse/FOV changes made in game still save.
        if ($ReadOnly -and (Split-Path $f.Path -Leaf) -eq $SystemFileName) { (Get-Item -LiteralPath $f.Path).IsReadOnly = $true }
    }
    return $backup
}

function Test-PriorityReg {
    try {
        $p = Get-ItemProperty -Path ('Registry::' + $PriorityKey) -Name CpuPriorityClass -ErrorAction Stop
        return ($p.CpuPriorityClass -eq 3)
    } catch { return $false }
}

function Set-PriorityReg([bool]$Enable) {
    if ($Enable -eq (Test-PriorityReg)) { return $true }
    $regArgs = $(if ($Enable) { "add `"$PriorityKey`" /v CpuPriorityClass /t REG_DWORD /d 3 /f" } else { "delete `"$PriorityKey`" /f" })
    try {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($admin) { $p = Start-Process reg.exe -ArgumentList $regArgs -Wait -PassThru -WindowStyle Hidden }
        else        { $p = Start-Process reg.exe -ArgumentList $regArgs -Wait -PassThru -WindowStyle Hidden -Verb RunAs }
        return ($p.ExitCode -eq 0)
    } catch { return $false }   # admin prompt cancelled
}

# ---------------------------------------------------------------------------------------------
#  Silent mode
# ---------------------------------------------------------------------------------------------
$Files = Get-CodFiles
$NoGameMsg = "Couldn't find $SystemFileName in:`n$PlayersPath`n`nLaunch Call of Duty once, wait for the main menu, close it, then run this tool again."

# ---------------------------------------------------------------------------------------------
#  Updates - checks GitHub for a newer release and installs it in place
# ---------------------------------------------------------------------------------------------
$UpdateCheckScript = {
    param($Url, $ZipName)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod -Uri $Url -Headers @{ 'User-Agent' = 'MW4-Config-Tool' } -TimeoutSec 8 -UseBasicParsing
        $asset = @($r.assets | Where-Object { $_.name -eq $ZipName }) | Select-Object -First 1
        $dl = ''; if ($asset) { $dl = [string]$asset.browser_download_url }
        [pscustomobject]@{ Tag = [string]$r.tag_name; Url = $dl; Page = [string]$r.html_url }
    } catch { $null }
}

function Test-NewerVersion([string]$Remote, [string]$Local) {
    $r = $Remote.Trim().TrimStart('v', 'V')
    if ($r -notmatch '^\d+(\.\d+){1,3}$' -or $Local -notmatch '^\d+(\.\d+){1,3}$') { return $false }
    return ([version]$r -gt [version]$Local)
}

function Install-Update($Info) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('MW4Tool_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp $ReleaseZip
        Invoke-WebRequest -Uri $Info.Url -OutFile $zip -UseBasicParsing -Headers @{ 'User-Agent' = 'MW4-Config-Tool' } -TimeoutSec 120
        $out = Join-Path $tmp 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $out -Force
        $main = Get-ChildItem -LiteralPath $out -Recurse -File -Filter 'MW4-Config-Tool.ps1' | Select-Object -First 1
        if (-not $main) { throw 'The downloaded update looks incomplete. Nothing was changed.' }
        $root = $main.DirectoryName
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File)) {
            $rel  = $f.FullName.Substring($root.Length).TrimStart('\', '/')
            $dest = Join-Path $PSScriptRoot $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
            # The launcher .bat is still running - only replace it if it actually changed
            if ($f.Extension -eq '.bat' -and (Test-Path -LiteralPath $dest)) {
                if ((Get-FileHash -LiteralPath $dest).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash) { continue }
            }
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            try { Unblock-File -LiteralPath $dest } catch { }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Silent) {
    if (-not $Files) { Write-Host $NoGameMsg -ForegroundColor Yellow; exit 1 }
    $hw    = Get-HardwareInfo $Files[0]
    $prefs = New-DefaultPrefs
    $prefs.HudPull = Get-HudPullDefault $Files
    $plan  = Get-Plan $hw $prefs
    $rows  = Get-PreviewRows $Files $plan.Changes $plan.Why $plan.OnlyIf
    Write-Host "$ToolName $ToolVersion" -ForegroundColor Cyan
    if (-not $NoUpdateCheck) {
        $u = & $UpdateCheckScript $ReleaseApi $ReleaseZip
        if ($u -and (Test-NewerVersion $u.Tag $ToolVersion)) { Write-Host "Update available: $($u.Tag) - run the tool without -Silent to update, or download: $($u.Page)" -ForegroundColor Yellow }
    }
    Write-Host ("CPU: {0} ({1} cores)  GPU: {2} [{3}, {4} GB]  Display: {5}x{6} @ {7} Hz  Drive: {8}" -f `
        $hw.CpuName, $hw.Cores, $hw.GpuName, $hw.Vendor, $hw.VramGB, $hw.Width, $hw.Height, $hw.RefreshHz, $hw.Drive)
    $rows | Format-Table File, Setting, Key, Current, New, Status -AutoSize | Out-String -Width 200 | Write-Host
    $n = @($rows | Where-Object { $_.Status -eq 'change' }).Count
    if ($DryRun) { Write-Host "Dry run: $n settings would change. Nothing written."; exit 0 }
    $b = Invoke-Apply $Files $rows $prefs.ReadOnly
    $prio = Set-PriorityReg $prefs.HighPriority
    Write-Host "Applied $n changes. Backup: $b" -ForegroundColor Green
    if (-not $prio) { Write-Host 'High CPU priority was not set (admin prompt declined).' -ForegroundColor Yellow }
    $plan.Notes | ForEach-Object { Write-Host "- $_" }
    exit 0
}

# ---------------------------------------------------------------------------------------------
#  Window
# ---------------------------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not $Files) {
    [Windows.MessageBox]::Show($NoGameMsg, $ToolName, 'OK', 'Warning') | Out-Null
    exit 1
}

# Rich tooltip builder for the window's controls
function ConvertTo-XmlText([string]$s) { [Security.SecurityElement]::Escape($s) }

function New-TipXaml([string]$Title, [string]$Impact, [string]$Body, [string]$Rec) {
    $pill = ''
    if ($Impact) {
        $pill = '<Border DockPanel.Dock="Right" CornerRadius="9" Padding="8,2" Margin="12,0,0,0" Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" VerticalAlignment="Top">' +
                '<TextBlock Text="' + (ConvertTo-XmlText $Impact) + '" Foreground="#FF7B45" FontSize="10" FontWeight="Bold"/></Border>'
    }
    $recXaml = ''
    if ($Rec) {
        $recXaml = '<Border Margin="0,10,0,0" Padding="10,7" CornerRadius="7" Background="#0E2A1F" BorderBrush="#1F5E43" BorderThickness="1">' +
                   '<TextBlock TextWrapping="Wrap" FontSize="12" Foreground="#3DDC97"><Run FontWeight="Bold" Text="Recommended: "/><Run Text="' + (ConvertTo-XmlText $Rec) + '"/></TextBlock></Border>'
    }
    return '<StackPanel Width="320">' +
           '<DockPanel Margin="0,0,0,6">' + $pill + '<TextBlock Text="' + (ConvertTo-XmlText $Title) + '" FontWeight="Bold" FontSize="14" Foreground="White" TextWrapping="Wrap"/></DockPanel>' +
           '<TextBlock Text="' + (ConvertTo-XmlText $Body) + '" TextWrapping="Wrap" FontSize="12" Foreground="#C9CED6" LineHeight="18"/>' +
           $recXaml + '</StackPanel>'
}

$Tips = @{
    tbCpu    = New-TipXaml 'CPU' 'DETECTED' 'Your processor, as reported by Windows.' 'Nothing to change here.'
    tbCores  = New-TipXaml 'Physical cores' 'FPS' 'Sets how many render threads the game uses: cores minus one, leaving a core free for Windows, Discord and audio. On Intel 12th-14th gen, count only the performance (P) cores.' 'Detected from Windows. Nothing to change here.'
    tbGpu    = New-TipXaml 'Graphics card' '' 'Used to pick the right upscaler (DLSS, FSR or XeSS) and the DLSS model for your card.' 'Detected from the game. If this shows integrated graphics, disable it in Device Manager or BIOS.'
    cbVendor = New-TipXaml 'GPU vendor' 'LATENCY' 'Picks the latency tech for your card: NVIDIA Reflex, AMD Anti-Lag 2 or Intel XeLL.' 'Should match your graphics card.'
    tbVram   = New-TipXaml 'Video memory' 'STABILITY' 'Decides the video memory budget, texture quality in Visibility mode, and whether an upscaler is needed.' 'Check Task Manager > Performance > GPU > Dedicated GPU memory.'
    tbRes    = New-TipXaml 'Resolution' 'FPS' 'The resolutions your monitor supports, read from Windows. The tool uses it to decide between native SMAA and an upscaler (at 4K, Auto picks an upscaler). It does not change your in-game resolution.' 'Your monitor''s native resolution (selected by default).'
    tbRam    = New-TipXaml 'System memory' 'STABILITY' 'Installed RAM, as detected by the game. 16 GB is the practical minimum for modern CoD; 32 GB gives headroom for Discord, browser and OBS.' 'Nothing to change here.'
    launch   = New-TipXaml 'Steam launch options' '' 'Steam: Library > right-click Call of Duty > Properties > General > Launch Options. Modern CoD starts through a launcher, so classic options like -high never reach the game. The High CPU priority option in LOADOUT does that job properly.' 'Leave Launch Options empty for now.'
    tbHz     = New-TipXaml 'Refresh rate' 'STABILITY' 'Sets the FPS cap: refresh rate minus 3, which keeps G-Sync/FreeSync active and frame times even.' 'Your monitor''s maximum refresh rate. Check it is set in Windows Settings > Display > Advanced display.'
    cbDrive  = New-TipXaml 'Game drive' 'STABILITY' 'Read from the game. Hard drives stream maps more slowly and stutter more.' 'Install Call of Duty on an SSD if you can.'
    rbFps    = New-TipXaml 'Max FPS' 'BIG FPS' 'Lowest textures and 2x filtering, with every expensive effect off, for the highest frame rate.' 'Best for competitive play and high refresh rate monitors.'
    rbVis    = New-TipXaml 'Visibility' 'CLARITY' 'Sharper textures scaled to your video memory, 8x filtering and bullet impacts on. Costs very little FPS on cards with 12 GB or more.' 'Great on strong GPUs: enemies and surfaces read better at range.'
    cbImage  = New-TipXaml 'Image' 'CLARITY' 'Auto uses native SMAA with sharpening on most PCs, and switches to DLSS, FSR or XeSS at 4K or with under 8 GB of video memory.' 'Leave on Auto.'
    cbCap    = New-TipXaml 'FPS cap' 'STABILITY' 'Auto caps 3 FPS under your refresh rate for smooth frame pacing. Uncapped gives the most FPS but less even frame times.' 'Auto.'
    tbCap    = New-TipXaml 'Custom FPS cap' '' 'Your own frame limit between 30 and 300. Only used when FPS cap is set to Custom.' 'A few frames under your refresh rate.'
    rbHead   = New-TipXaml 'Headphones' 'AUDIO' 'Embody Immerse 3D headphone audio on, THX speaker processing off, stereo output.' 'Best footstep direction. Also turn off Windows Sonic or Dolby Atmos for Headphones in Windows sound settings.'
    rbSpk    = New-TipXaml 'Speakers' 'AUDIO' 'THX loudspeaker spatial audio on, headphone 3D off, channel count from Windows.' 'Only if you play on speakers or a soundbar.'
    chkMusic = New-TipXaml 'Mute music' 'AUDIO' 'Mutes menu and match music, war tracks, licensed music, news feed audio and cinematics.' 'On, for clean footsteps.'
    slAnn    = New-TipXaml 'Announcer and dialogue' 'AUDIO' 'Volume of announcer callouts (UAV, killstreaks) and character voice lines.' '30-50%: callouts stay clear without masking footsteps.'
    slHud    = New-TipXaml 'HUD position' 'CLARITY' 'Pulls the minimap, ammo counter and killfeed in from the screen corners toward your crosshair. 0% is the game default (screen edge), 100% is as close to the centre as the game allows. Square minimap and magenta enemies are set for you automatically.' 'Around 15% for most players. Go much higher if you never glance at the corner minimap mid-fight.'
    slHit    = New-TipXaml 'Hit markers' 'AUDIO' 'Volume of the hit marker sound when your shots land.' '40-60%: clear feedback that doesn''t drown out footsteps.'
    chkHdr   = New-TipXaml 'HDR' 'CLARITY' 'Turns on HDR output. Only works on an HDR monitor with HDR switched on in Windows.' 'Off, unless you have a proper HDR monitor (OLED or 600+ nits).'
    chkPrio  = New-TipXaml 'High CPU priority' 'FPS' 'Windows always starts cod.exe at High priority, so background apps can''t steal CPU time from the game. Asks for admin once.' 'On. A small but real boost to 1% lows.'
    chkRO    = New-TipXaml 'Lock graphics file' 'STABILITY' 'Makes the graphics settings file read-only, so the game can''t change or reset it.' 'Off, unless the game keeps resetting your settings. While locked, graphics changes made in game won''t save.'
    cbBackups = New-TipXaml 'Backups' 'SAFETY' 'Every Apply saves your previous settings files here, newest first.' 'Pick one and press Restore to roll back.'
    btnApply = New-TipXaml 'Apply' '' 'Backs up your current files, writes the changes and sets CPU priority. Close the game first.' 'Afterwards, in game: Graphics > Restart Shaders Pre-Loading, then restart.'
}

# Tooltip for each row of the change list (bound to the row's data)
$RowTip = @'
<StackPanel Width="340">
  <DockPanel Margin="0,0,0,6">
    <Border DockPanel.Dock="Right" CornerRadius="9" Padding="8,2" Margin="12,0,0,0" Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" VerticalAlignment="Top">
      <TextBlock Text="{Binding Impact}" Foreground="#FF7B45" FontSize="10" FontWeight="Bold"/>
    </Border>
    <TextBlock Text="{Binding Setting}" FontWeight="Bold" FontSize="14" Foreground="White" TextWrapping="Wrap"/>
  </DockPanel>
  <TextBlock Text="{Binding Info}" TextWrapping="Wrap" FontSize="12" Foreground="#C9CED6" LineHeight="18"/>
  <Border Margin="0,10,0,0" Padding="10,7" CornerRadius="7" Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1">
    <TextBlock TextWrapping="Wrap" FontSize="12">
      <Run Text="{Binding Current, Mode=OneWay}" Foreground="#8C94A3"/><Run Text="   &#x2192;   " Foreground="#5D6573"/><Run Text="{Binding New, Mode=OneWay}" Foreground="#FF7B45" FontWeight="Bold"/>
    </TextBlock>
  </Border>
  <Border Margin="0,6,0,0" Padding="10,7" CornerRadius="7" Background="#0E2A1F" BorderBrush="#1F5E43" BorderThickness="1">
    <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="#3DDC97"><Run FontWeight="Bold" Text="Why: "/><Run Text="{Binding Why, Mode=OneWay}"/></TextBlock>
  </Border>
  <TextBlock Foreground="#5D6573" FontSize="10" Margin="0,8,0,0" TextWrapping="Wrap"><Run Text="{Binding Key, Mode=OneWay}"/><Run Text="   |   "/><Run Text="{Binding Status, Mode=OneWay}"/></TextBlock>
</StackPanel>
'@

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$ToolName" Width="1320" Height="940" MinWidth="1200" MinHeight="720"
        WindowStartupLocation="CenterScreen" Background="#0B0D11" FontFamily="Segoe UI" FontSize="13"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg"      Color="#0B0D11"/>
    <SolidColorBrush x:Key="Card"    Color="#13161C"/>
    <SolidColorBrush x:Key="Field"   Color="#1A1E26"/>
    <SolidColorBrush x:Key="Line"    Color="#272D38"/>
    <SolidColorBrush x:Key="Ink"     Color="#ECEEF1"/>
    <SolidColorBrush x:Key="Muted"   Color="#8C94A3"/>
    <SolidColorBrush x:Key="Accent"  Color="#FF5A1F"/>
    <SolidColorBrush x:Key="AccentHi" Color="#FF7B45"/>
    <SolidColorBrush x:Key="Good"    Color="#3DDC97"/>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>

    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Ink}"/></Style>
    <Style x:Key="Lbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12"/><Setter Property="Margin" Value="0,10,0,4"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Accent}"/><Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="Bold"/><Setter Property="Margin" Value="0,0,0,2"/>
    </Style>
    <Style x:Key="CardBox" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Card}"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18,16"/><Setter Property="Margin" Value="8"/>
    </Style>

    <!-- Text boxes -->
    <Style TargetType="TextBox">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="Bd" Background="{StaticResource Field}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="7" Padding="9,6">
            <ScrollViewer x:Name="PART_ContentHost" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#3A4250"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            <Trigger Property="IsReadOnly" Value="True"><Setter TargetName="Bd" Property="Background" Value="#151920"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Combo boxes -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ComboBoxItem">
          <Border x:Name="Bd" Background="Transparent" Padding="10,7" CornerRadius="5" Margin="3,1">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#262C37"/></Trigger>
            <Trigger Property="IsSelected" Value="True"><Setter Property="Foreground" Value="{StaticResource Accent}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ComboBox">
          <Grid>
            <ToggleButton Focusable="False" ClickMode="Press"
                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
              <ToggleButton.Template>
                <ControlTemplate TargetType="ToggleButton">
                  <Border x:Name="Bd" Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="7">
                    <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"
                          Data="M0,0 L5,5 L10,0" Stroke="#8C94A3" StrokeThickness="1.6"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#FF5A1F"/></Trigger>
                    <Trigger Property="IsChecked" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#FF5A1F"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </ToggleButton.Template>
            </ToggleButton>
            <ContentPresenter IsHitTestVisible="False" Margin="10,7,30,7" VerticalAlignment="Center"
                              Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
            <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
              <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="8" Margin="0,4,0,0" Padding="0,3"
                      MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="320">
                <ScrollViewer><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
              </Border>
            </Popup>
          </Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Check boxes and radio buttons -->
    <Style TargetType="CheckBox">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Margin" Value="0,5"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <StackPanel Orientation="Horizontal" Background="Transparent">
            <Border x:Name="Box" Width="18" Height="18" CornerRadius="5" Background="#1A1E26" BorderBrush="#3A4250" BorderThickness="1.5" VerticalAlignment="Center">
              <Path x:Name="Tick" Data="M3,9 L7,13 L15,4" Stroke="White" StrokeThickness="2.2" Visibility="Collapsed"/>
            </Border>
            <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Box" Property="Background" Value="#FF5A1F"/><Setter TargetName="Box" Property="BorderBrush" Value="#FF5A1F"/>
              <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#FF7B45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Margin" Value="0,4,18,4"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <StackPanel Orientation="Horizontal" Background="Transparent">
            <Grid Width="18" Height="18" VerticalAlignment="Center">
              <Ellipse x:Name="Ring" Stroke="#3A4250" StrokeThickness="1.5" Fill="#1A1E26"/>
              <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#FF5A1F" Visibility="Collapsed"/>
            </Grid>
            <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Ring" Property="Stroke" Value="#FF5A1F"/><Setter TargetName="Dot" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Ring" Property="Stroke" Value="#FF7B45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Sliders -->
    <Style x:Key="SliderRail" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RepeatButton">
          <Grid Background="Transparent"><Border Background="{TemplateBinding Background}" Height="4" CornerRadius="2"/></Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="Slider">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Height" Value="24"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Slider">
          <Track x:Name="PART_Track">
            <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource SliderRail}" Background="#FF5A1F" Command="{x:Static Slider.DecreaseLarge}"/></Track.DecreaseRepeatButton>
            <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource SliderRail}" Background="#272D38" Command="{x:Static Slider.IncreaseLarge}"/></Track.IncreaseRepeatButton>
            <Track.Thumb>
              <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
                <Ellipse Width="16" Height="16" Fill="White" Stroke="#FF5A1F" StrokeThickness="3"/>
              </ControlTemplate></Thumb.Template></Thumb>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Buttons -->
    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Background" Value="#1A1E26"/>
      <Setter Property="BorderBrush" Value="#272D38"/><Setter Property="Padding" Value="16,8"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#FF5A1F"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.8"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#FF5A1F"/><Setter Property="BorderBrush" Value="#FF5A1F"/>
      <Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="34,10"/>
      <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF7B45"/></Trigger></Style.Triggers>
    </Style>
    <Style x:Key="BtnSocial" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#1C1512"/><Setter Property="BorderBrush" Value="#3A2418"/>
      <Setter Property="Padding" Value="12,7"/><Setter Property="Margin" Value="6,0,0,0"/>
    </Style>

    <Style x:Key="BtnBrand" TargetType="Button">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="6,0,0,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="12,8">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Bd" Property="Effect"><Setter.Value><DropShadowEffect BlurRadius="14" ShadowDepth="0" Opacity="0.45" Color="White"/></Setter.Value></Setter>
              <Setter TargetName="Bd" Property="RenderTransformOrigin" Value="0.5,0.5"/>
              <Setter TargetName="Bd" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="1.05" ScaleY="1.05"/></Setter.Value></Setter>
            </Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Change list -->
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="GridViewColumnHeader">
          <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="0,0,0,1" Padding="10,8">
            <ContentPresenter TextElement.Foreground="#8C94A3" TextElement.FontSize="12" TextElement.FontWeight="SemiBold"/>
          </Border>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ListViewItem">
          <Border x:Name="Bd" Background="Transparent" BorderBrush="#1C2029" BorderThickness="0,0,0,1" Padding="0,5"
                  ToolTipService.InitialShowDelay="250" ToolTipService.ShowDuration="60000" ToolTipService.Placement="Mouse">
            <Border.ToolTip><ToolTip>$RowTip</ToolTip></Border.ToolTip>
            <GridViewRowPresenter Columns="{TemplateBinding GridView.ColumnCollection}" Content="{TemplateBinding Content}"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1A1E26"/></Trigger>
            <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#22180F"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Apply}" Value="False"><Setter Property="Opacity" Value="0.42"/></DataTrigger>
      </Style.Triggers>
    </Style>

    <!-- Slim scroll bars -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/><Setter Property="MinWidth" Value="8"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True">
            <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#343B47" CornerRadius="4" Margin="1"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/><Setter Property="MinHeight" Value="8"/>
          <Setter Property="Template"><Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Track x:Name="PART_Track" Orientation="Horizontal" IsDirectionReversed="False">
                <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#343B47" CornerRadius="4" Margin="1"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
              </Track>
            </ControlTemplate>
          </Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="HasDropShadow" Value="False"/>
      <Setter Property="Placement" Value="Right"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ToolTip">
          <Border Margin="6,6,18,18" Background="#161A21" BorderBrush="#3A2418" BorderThickness="1" CornerRadius="12">
            <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="5" Opacity="0.6" Color="Black"/></Border.Effect>
            <Grid>
              <Border Width="4" HorizontalAlignment="Left" CornerRadius="12,0,0,12" Background="#FF5A1F"/>
              <ContentPresenter Margin="18,14,16,14" TextElement.Foreground="#ECEEF1" TextElement.FontSize="12"/>
            </Grid>
          </Border>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <!-- ================= HEADER ================= -->
    <Border Grid.Row="0" Padding="26,16,26,16" BorderBrush="#FF5A1F" BorderThickness="0,0,0,2">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
          <GradientStop Color="#2E1407" Offset="0"/>
          <GradientStop Color="#160D09" Offset="0.45"/>
          <GradientStop Color="#0B0D11" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <DockPanel LastChildFill="True">
        <!-- FiTH logo -->
        <Grid DockPanel.Dock="Left" Width="96" Height="96" Margin="0,0,18,0">
          <Border x:Name="logoFallback" CornerRadius="16" BorderBrush="#FF5A1F" BorderThickness="2">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#FF7B45" Offset="0"/><GradientStop Color="#B8320A" Offset="1"/></LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="FiTH" Foreground="White" FontWeight="Black" FontSize="22" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <Image x:Name="imgLogo" Stretch="Uniform" Visibility="Collapsed" RenderOptions.BitmapScalingMode="HighQuality"/>
        </Grid>

        <!-- Game badge -->
        <Border DockPanel.Dock="Right" VerticalAlignment="Center" Background="#AA0B0D11" BorderBrush="#3A2418" BorderThickness="1" CornerRadius="16" Padding="14,10,22,10">
          <StackPanel Orientation="Horizontal">
            <Grid Width="70" Height="70" Margin="0,0,14,0">
              <Ellipse Stroke="#FF5A1F" StrokeThickness="2" Opacity="0.7">
                <Ellipse.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="0" Opacity="0.8" Color="#FF5A1F"/></Ellipse.Effect>
              </Ellipse>
              <Image x:Name="imgGame" Margin="3" Visibility="Collapsed" RenderOptions.BitmapScalingMode="HighQuality"/>
            </Grid>
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="GAME" Foreground="#8C94A3" FontSize="10" FontWeight="Bold"/>
              <TextBlock Text="Modern Warfare 4" Foreground="White" FontSize="17" FontWeight="Bold" Margin="0,1,0,4"/>
              <StackPanel Orientation="Horizontal">
                <Ellipse Width="8" Height="8" Fill="#3DDC97" VerticalAlignment="Center" Margin="0,0,7,0">
                  <Ellipse.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="0" Opacity="0.9" Color="#3DDC97"/></Ellipse.Effect>
                </Ellipse>
                <TextBlock x:Name="tbGameStatus" Text="Settings found" Foreground="#3DDC97" FontSize="12" FontWeight="SemiBold"/>
              </StackPanel>
            </StackPanel>
          </StackPanel>
        </Border>

        <!-- Title -->
        <StackPanel VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="g1gGLe'z " FontSize="30" FontWeight="Black" Foreground="#FF5A1F"/>
            <TextBlock Text="MW4 PERFORMANCE" FontSize="30" FontWeight="Black" Foreground="White"/>
          </StackPanel>
          <TextBlock Text="Tuned to YOUR rig  &#183;  max FPS  &#183;  low latency  &#183;  smooth frame times" Foreground="#B9BFCA" FontSize="13" Margin="2,2,0,10"/>
          <StackPanel Orientation="Horizontal">
            <Border Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" CornerRadius="10" Padding="10,2" Margin="2,0,8,0">
              <TextBlock Text="FiTH GAMING" Foreground="#FF7B45" FontSize="10" FontWeight="Bold"/>
            </Border>
            <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="10" Padding="10,2" Margin="0,0,8,0">
              <TextBlock x:Name="tbVersion" Text="v$ToolVersion" Foreground="#B9BFCA" FontSize="10" FontWeight="Bold"/>
            </Border>
            <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="10" Padding="10,2">
              <TextBlock Text="FIRE IN THE HOLE" Foreground="#B9BFCA" FontSize="10" FontWeight="Bold"/>
            </Border>
          </StackPanel>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ================= UPDATE BAR ================= -->
    <Border x:Name="updateBar" Grid.Row="1" Visibility="Collapsed" Margin="20,14,20,0" Padding="16,10" CornerRadius="10" BorderBrush="#FF5A1F" BorderThickness="1">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#3A1A08" Offset="0"/><GradientStop Color="#13161C" Offset="1"/></LinearGradientBrush>
      </Border.Background>
      <DockPanel>
        <Button x:Name="btnUpdateLater" DockPanel.Dock="Right" Style="{StaticResource BtnBase}" Content="Later" Margin="8,0,0,0"/>
        <Button x:Name="btnUpdate" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Padding="22,8" FontSize="13" Content="UPDATE NOW"/>
        <Grid DockPanel.Dock="Left" Width="36" Height="36" Margin="0,0,14,0">
          <Ellipse Fill="#2A1206" Stroke="#FF5A1F" StrokeThickness="1.5"/>
          <TextBlock FontFamily="{StaticResource Icons}" Text="&#xE896;" Foreground="#FF7B45" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="tbUpdateTitle" Text="Update available" Foreground="White" FontWeight="Bold" FontSize="14"/>
          <TextBlock x:Name="tbUpdateInfo" Foreground="#B9BFCA" FontSize="12" Margin="0,2,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ================= BODY ================= -->
    <Grid Grid.Row="2" Margin="12,10,12,4">
      <Grid.ColumnDefinitions><ColumnDefinition Width="320"/><ColumnDefinition Width="320"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <!-- YOUR RIG -->
      <Border Grid.Column="0" Style="{StaticResource CardBox}">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,4">
            <TextBlock Style="{StaticResource CardTitle}" Text="YOUR RIG"/>
            <TextBlock Text="Detected automatically from your PC and game" Foreground="#8C94A3" FontSize="11"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,0,4,0">
            <TextBlock Style="{StaticResource Lbl}" Text="CPU"/>
            <TextBox x:Name="tbCpu" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbCpu'])</ToolTip></TextBox.ToolTip></TextBox>
            <TextBlock Style="{StaticResource Lbl}" Text="Graphics card"/>
            <TextBox x:Name="tbGpu" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbGpu'])</ToolTip></TextBox.ToolTip></TextBox>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Grid.Column="0">
                <TextBlock Style="{StaticResource Lbl}" Text="GPU vendor"/>
                <TextBox x:Name="tbVendor" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['cbVendor'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="0" Grid.Column="2">
                <TextBlock Style="{StaticResource Lbl}" Text="Video memory"/>
                <TextBox x:Name="tbVram" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbVram'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="1" Grid.Column="0">
                <TextBlock Style="{StaticResource Lbl}" Text="CPU cores"/>
                <TextBox x:Name="tbCores" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbCores'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="1" Grid.Column="2">
                <TextBlock Style="{StaticResource Lbl}" Text="System memory"/>
                <TextBox x:Name="tbRam" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbRam'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="2" Grid.Column="0">
                <TextBlock Style="{StaticResource Lbl}" Text="Game drive"/>
                <TextBox x:Name="tbDrive" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['cbDrive'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="2" Grid.Column="2">
                <TextBlock Style="{StaticResource Lbl}" Text="Refresh rate (Hz)"/>
                <TextBox x:Name="tbHz"><TextBox.ToolTip><ToolTip>$($Tips['tbHz'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
            </Grid>
            <TextBlock Style="{StaticResource Lbl}" Text="Resolution"/>
            <ComboBox x:Name="cbRes"><ComboBox.ToolTip><ToolTip>$($Tips['tbRes'])</ToolTip></ComboBox.ToolTip></ComboBox>

            <!-- Steam launch options -->
            <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="10" Padding="14,12" Margin="0,18,0,0">
              <Border.ToolTip><ToolTip>$($Tips['launch'])</ToolTip></Border.ToolTip>
              <StackPanel>
                <DockPanel>
                  <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE756;" Foreground="#FF7B45" VerticalAlignment="Center" Margin="0,0,10,0"/>
                  <TextBlock Text="STEAM LAUNCH OPTIONS" Foreground="#FF5A1F" FontWeight="Bold" FontSize="12" VerticalAlignment="Center"/>
                </DockPanel>
                <Border Background="#101318" BorderBrush="#272D38" BorderThickness="1" CornerRadius="6" Padding="10,7" Margin="0,10,0,8">
                  <TextBlock x:Name="tbLaunch" Text="None needed" Foreground="#3DDC97" FontFamily="Consolas" FontSize="12"/>
                </Border>
                <TextBlock TextWrapping="Wrap" Foreground="#8C94A3" FontSize="11" LineHeight="16"
                           Text="Popular ones like -high, -threads or -USEALLAVAILABLECORES don't reach the game on modern CoD. CPU priority is handled by this tool instead. Proven options will appear here."/>
              </StackPanel>
            </Border>
          </StackPanel></ScrollViewer>
        </DockPanel>
      </Border>

      <!-- LOADOUT -->
      <Border Grid.Column="1" Style="{StaticResource CardBox}">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,4">
            <TextBlock Style="{StaticResource CardTitle}" Text="LOADOUT"/>
            <TextBlock Text="How you want the game to feel" Foreground="#8C94A3" FontSize="11"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,0,4,0">
            <TextBlock Style="{StaticResource Lbl}" Text="Goal"/>
            <UniformGrid Columns="2">
              <RadioButton x:Name="rbFps" GroupName="goal" Content="Max FPS"><RadioButton.ToolTip><ToolTip>$($Tips['rbFps'])</ToolTip></RadioButton.ToolTip></RadioButton>
              <RadioButton x:Name="rbVis" GroupName="goal" Content="Visibility"><RadioButton.ToolTip><ToolTip>$($Tips['rbVis'])</ToolTip></RadioButton.ToolTip></RadioButton>
            </UniformGrid>
            <TextBlock Style="{StaticResource Lbl}" Text="Image"/>
            <ComboBox x:Name="cbImage"><ComboBox.ToolTip><ToolTip>$($Tips['cbImage'])</ToolTip></ComboBox.ToolTip>
              <ComboBoxItem Tag="Auto">Auto (recommended)</ComboBoxItem>
              <ComboBoxItem Tag="Native">Native + SMAA + sharpening</ComboBoxItem>
              <ComboBoxItem Tag="Upscaler">Upscaler (DLSS / FSR / XeSS)</ComboBoxItem>
            </ComboBox>
            <TextBlock Style="{StaticResource Lbl}" Text="FPS cap"/>
            <ComboBox x:Name="cbCap"><ComboBox.ToolTip><ToolTip>$($Tips['cbCap'])</ToolTip></ComboBox.ToolTip>
              <ComboBoxItem Tag="Auto">Auto (refresh rate - 3)</ComboBoxItem>
              <ComboBoxItem Tag="Uncapped">Uncapped</ComboBoxItem>
              <ComboBoxItem Tag="Custom">Custom</ComboBoxItem>
            </ComboBox>
            <TextBox x:Name="tbCap" Visibility="Collapsed" Margin="0,6,0,0"><TextBox.ToolTip><ToolTip>$($Tips['tbCap'])</ToolTip></TextBox.ToolTip></TextBox>
            <TextBlock Style="{StaticResource Lbl}" Text="Audio"/>
            <UniformGrid Columns="2">
              <RadioButton x:Name="rbHead" GroupName="aud" Content="Headphones"><RadioButton.ToolTip><ToolTip>$($Tips['rbHead'])</ToolTip></RadioButton.ToolTip></RadioButton>
              <RadioButton x:Name="rbSpk" GroupName="aud" Content="Speakers"><RadioButton.ToolTip><ToolTip>$($Tips['rbSpk'])</ToolTip></RadioButton.ToolTip></RadioButton>
            </UniformGrid>
            <CheckBox x:Name="chkMusic" Content="Mute music and war tracks"><CheckBox.ToolTip><ToolTip>$($Tips['chkMusic'])</ToolTip></CheckBox.ToolTip></CheckBox>
            <DockPanel Margin="0,10,0,0">
              <TextBlock x:Name="lblAnn" DockPanel.Dock="Right" Foreground="#FF7B45" FontWeight="Bold" FontSize="12"/>
              <TextBlock Text="Announcer / dialogue" Foreground="#8C94A3" FontSize="12"/>
            </DockPanel>
            <Slider x:Name="slAnn" Minimum="0" Maximum="100" TickFrequency="5" IsSnapToTickEnabled="True"><Slider.ToolTip><ToolTip>$($Tips['slAnn'])</ToolTip></Slider.ToolTip></Slider>
            <DockPanel Margin="0,6,0,0">
              <TextBlock x:Name="lblHit" DockPanel.Dock="Right" Foreground="#FF7B45" FontWeight="Bold" FontSize="12"/>
              <TextBlock Text="Hit markers" Foreground="#8C94A3" FontSize="12"/>
            </DockPanel>
            <Slider x:Name="slHit" Minimum="0" Maximum="100" TickFrequency="5" IsSnapToTickEnabled="True"><Slider.ToolTip><ToolTip>$($Tips['slHit'])</ToolTip></Slider.ToolTip></Slider>
            <DockPanel Margin="0,6,0,0">
              <TextBlock x:Name="lblHud" DockPanel.Dock="Right" Foreground="#FF7B45" FontWeight="Bold" FontSize="12"/>
              <TextBlock Text="HUD position (edge to centre)" Foreground="#8C94A3" FontSize="12"/>
            </DockPanel>
            <Slider x:Name="slHud" Minimum="0" Maximum="100" TickFrequency="5" IsSnapToTickEnabled="True"><Slider.ToolTip><ToolTip>$($Tips['slHud'])</ToolTip></Slider.ToolTip></Slider>
            <Border Height="1" Background="#272D38" Margin="0,12,0,6"/>
            <CheckBox x:Name="chkPrio" Content="High CPU priority for cod.exe"><CheckBox.ToolTip><ToolTip>$($Tips['chkPrio'])</ToolTip></CheckBox.ToolTip></CheckBox>
            <CheckBox x:Name="chkHdr" Content="HDR (needs an HDR monitor)"><CheckBox.ToolTip><ToolTip>$($Tips['chkHdr'])</ToolTip></CheckBox.ToolTip></CheckBox>
            <CheckBox x:Name="chkRO" Content="Lock graphics file (read-only)"><CheckBox.ToolTip><ToolTip>$($Tips['chkRO'])</ToolTip></CheckBox.ToolTip></CheckBox>
          </StackPanel></ScrollViewer>
        </DockPanel>
      </Border>

      <!-- CHANGES -->
      <Border Grid.Column="2" Style="{StaticResource CardBox}">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <DockPanel Grid.Row="0" Margin="0,0,0,12">
            <Border DockPanel.Dock="Right" Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" CornerRadius="12" Padding="12,4" VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="tbCount" Text="0" Foreground="#FF7B45" FontWeight="Black" FontSize="13"/>
                <TextBlock Text=" CHANGES" Foreground="#FF7B45" FontWeight="Bold" FontSize="11" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="CHANGES TO APPLY"/>
              <TextBlock Text="Hover any row to see what it does and why" Foreground="#8C94A3" FontSize="11"/>
            </StackPanel>
          </DockPanel>

          <Grid Grid.Row="1">
            <ListView x:Name="lvPreview" Background="#101318" BorderBrush="#272D38" BorderThickness="1" Foreground="#ECEEF1">
              <ListView.View><GridView>
                <GridViewColumn Width="46">
                  <GridViewColumn.Header><CheckBox x:Name="chkAll" IsChecked="True" Margin="2,0,0,0" ToolTip="Tick or untick every change"/></GridViewColumn.Header>
                  <GridViewColumn.CellTemplate><DataTemplate>
                    <CheckBox IsChecked="{Binding Apply, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanApply}" Margin="6,0,0,0"/>
                  </DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="FILE" Width="74"><GridViewColumn.CellTemplate><DataTemplate>
                  <TextBlock Text="{Binding File}" Foreground="#8C94A3" Margin="4,0,0,0"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
                <GridViewColumn Header="SETTING" Width="200"><GridViewColumn.CellTemplate><DataTemplate>
                  <TextBlock Text="{Binding Setting}" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
                <GridViewColumn Header="NOW" Width="126"><GridViewColumn.CellTemplate><DataTemplate>
                  <TextBlock Text="{Binding Current}" Foreground="#8C94A3" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
                <GridViewColumn Header="NEW" Width="126"><GridViewColumn.CellTemplate><DataTemplate>
                  <TextBlock Text="{Binding New}" Foreground="#FF7B45" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              </GridView></ListView.View>
            </ListView>
            <!-- shown when there's nothing to change -->
            <Border x:Name="emptyState" Background="#101318" BorderBrush="#272D38" BorderThickness="1" Visibility="Collapsed">
              <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                <Grid Width="84" Height="84" HorizontalAlignment="Center">
                  <Ellipse Fill="#0E2A1F" Stroke="#3DDC97" StrokeThickness="2">
                    <Ellipse.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.55" Color="#3DDC97"/></Ellipse.Effect>
                  </Ellipse>
                  <Path Data="M24,43 L37,56 L61,30" Stroke="#3DDC97" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                </Grid>
                <TextBlock Text="LOCKED AND LOADED" Foreground="White" FontSize="20" FontWeight="Black" HorizontalAlignment="Center" Margin="0,18,0,4"/>
                <TextBlock Text="Your config already matches this loadout. Nothing to change." Foreground="#8C94A3" FontSize="13" HorizontalAlignment="Center"/>
                <TextBlock Text="Change an option on the left to see what it would do." Foreground="#5D6573" FontSize="12" HorizontalAlignment="Center" Margin="0,4,0,0"/>
              </StackPanel>
            </Border>
          </Grid>

          <Border Grid.Row="2" Background="#1A1E26" CornerRadius="8" Padding="12,10" Margin="0,12,0,0">
            <DockPanel>
              <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE946;" Foreground="#FF7B45" VerticalAlignment="Top" Margin="0,2,10,0"/>
              <TextBlock x:Name="tbNotes" TextWrapping="Wrap" Foreground="#B9BFCA" FontSize="12" LineHeight="18"/>
            </DockPanel>
          </Border>

          <DockPanel Grid.Row="3" Margin="0,12,0,0" LastChildFill="False">
            <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE81C;" Foreground="#8C94A3" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock DockPanel.Dock="Left" Text="BACKUPS" VerticalAlignment="Center" Foreground="#8C94A3" FontSize="11" FontWeight="Bold"/>
            <ComboBox x:Name="cbBackups" DockPanel.Dock="Left" Width="190" Margin="12,0,0,0" VerticalAlignment="Center"><ComboBox.ToolTip><ToolTip>$($Tips['cbBackups'])</ToolTip></ComboBox.ToolTip></ComboBox>
            <Button x:Name="btnRestore" DockPanel.Dock="Left" Style="{StaticResource BtnBase}" Content="Restore" Margin="8,0,0,0"/>
            <Button x:Name="btnFolder" DockPanel.Dock="Right" Style="{StaticResource BtnBase}" Content="Open folder" ToolTip="Open the game settings folder"/>
          </DockPanel>
        </Grid>
      </Border>
    </Grid>

    <!-- ================= FOOTER ================= -->
    <Border Grid.Row="3" Background="#0E1015" BorderBrush="#272D38" BorderThickness="0,1,0,0" Padding="24,14">
      <DockPanel LastChildFill="False">
        <StackPanel DockPanel.Dock="Left" VerticalAlignment="Center">
          <TextBlock Text="JOIN THE SQUAD" Foreground="#8C94A3" FontSize="10" FontWeight="Bold" Margin="0,0,0,7"/>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="lnkDiscord" Style="{StaticResource BtnBrand}" Background="#5865F2" BorderBrush="#5865F2" Margin="0,0,6,0" ToolTip="Join the FiTH Gaming Discord">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE8BD;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="DISCORD" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkYouTube" Style="{StaticResource BtnBrand}" Background="#FF0000" BorderBrush="#FF0000" Margin="0,0,6,0" ToolTip="FiTH Gaming on YouTube">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE714;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="YOUTUBE" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkFacebook" Style="{StaticResource BtnBrand}" Background="#1877F2" BorderBrush="#1877F2" Margin="0,0,6,0" ToolTip="FiTH Gaming on Facebook">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE716;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="FACEBOOK" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkSteam" Style="{StaticResource BtnBrand}" Background="#171A21" BorderBrush="#66C0F4" Margin="0,0,6,0" ToolTip="FiTH Gaming Steam group">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE7FC;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="STEAM" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkWeb" Style="{StaticResource BtnBrand}" Background="#FF5A1F" BorderBrush="#FF5A1F" Margin="0" ToolTip="fithgaming.co.uk">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE774;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="WEBSITE" Foreground="White"/></StackPanel>
            </Button>
          </StackPanel>
        </StackPanel>

        <Button x:Name="btnApply" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" VerticalAlignment="Center" Padding="40,13" FontSize="15">
          <Button.ToolTip><ToolTip>$($Tips['btnApply'])</ToolTip></Button.ToolTip>
          <StackPanel Orientation="Horizontal">
            <TextBlock FontFamily="{StaticResource Icons}" Text="&#xE945;" Foreground="White" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <TextBlock Text="APPLY" Foreground="White"/>
          </StackPanel>
        </Button>
        <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center" Margin="0,0,18,0">
          <TextBlock x:Name="tbStatus" HorizontalAlignment="Right" FontWeight="SemiBold" FontSize="13"/>
          <TextBlock Text="made by g1gGLe  &#183;  FiTH Gaming" HorizontalAlignment="Right" Foreground="#5D6573" FontSize="11" Margin="0,3,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>
  </Grid>
</Window>
"@

try {
    $Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
} catch {
    $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
    [Windows.MessageBox]::Show("The window failed to load:`n`n$($inner.Message)", $ToolName, 'OK', 'Error') | Out-Null
    exit 1
}
$ui = @{}
foreach ($n in 'tbCpu','tbCores','tbGpu','tbVendor','tbVram','cbRes','tbHz','tbDrive','tbRam','tbLaunch',
               'rbFps','rbVis','cbImage','cbCap','tbCap','rbHead','rbSpk','chkMusic','lblAnn','slAnn','lblHit','slHit','lblHud','slHud',
               'chkHdr','chkPrio','chkRO','lvPreview','chkAll','tbNotes','tbCount','cbBackups','btnRestore','btnFolder','btnApply','tbStatus',
               'imgLogo','logoFallback','imgGame','emptyState','tbGameStatus','updateBar','tbVersion','btnUpdate','btnUpdateLater','tbUpdateTitle','tbUpdateInfo','lnkDiscord','lnkYouTube','lnkFacebook','lnkSteam','lnkWeb') {
    $ui[$n] = $Window.FindName($n)
}

# Branding images next to the script: assets\logo.png (header + window icon), assets\game.png (optional game icon)
function Get-AssetImage([string]$Name) {
    $path = Join-Path $PSScriptRoot "assets\$Name"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.UriSource = New-Object Uri($path); $bmp.EndInit()
        return $bmp
    } catch { return $null }
}
$logo = Get-AssetImage 'logo.png'
if ($logo) {
    $ui.imgLogo.Source = $logo; $ui.imgLogo.Visibility = 'Visible'; $ui.logoFallback.Visibility = 'Collapsed'
    $Window.Icon = $logo
}
$accCount = @($Files | Where-Object { $_.Kind -eq 'Text' -and (Split-Path $_.Path -Leaf) -ne $SystemFileName }).Count
$ui.tbGameStatus.Text = $(if ($accCount -gt 0) { "Settings found  /  $accCount account" } else { 'Settings found' })
# Fit the window on smaller / scaled screens
$work = [System.Windows.SystemParameters]::WorkArea
if ($Window.Height -gt $work.Height - 20) { $Window.Height = [math]::Max($Window.MinHeight, $work.Height - 20) }
if ($Window.Width  -gt $work.Width  - 20) { $Window.Width  = [math]::Max($Window.MinWidth,  $work.Width  - 20) }
$game = Get-AssetImage 'game.png'
if ($game) { $ui.imgGame.Source = $game; $ui.imgGame.Visibility = 'Visible' }

# Community links
$ui.lnkDiscord.Tag  = $Links.Discord;  $ui.lnkYouTube.Tag = $Links.YouTube; $ui.lnkFacebook.Tag = $Links.Facebook
$ui.lnkSteam.Tag    = $Links.Steam;    $ui.lnkWeb.Tag     = $Links.Website
foreach ($n in 'lnkDiscord','lnkYouTube','lnkFacebook','lnkSteam','lnkWeb') {
    $ui[$n].Add_Click({ param($s, $e) try { Start-Process ([string]$s.Tag) } catch { } })
}

function Select-ComboText($Combo, [string]$Text) {
    foreach ($i in $Combo.Items) { if ([string]$i.Content -eq $Text) { $Combo.SelectedItem = $i; return } }
    $Combo.SelectedIndex = $Combo.Items.Count - 1
}

# Resolutions the monitor supports, straight from Windows (falls back to a common list)
function Get-DisplayResolutions {
    $list = New-Object System.Collections.Generic.List[string]
    try {
        if (-not ('MW4Tool.Display' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace MW4Tool {
    public static class Display {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DEVMODE {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
            public int dmFields; public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
            public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
            public int dmDisplayFlags; public int dmDisplayFrequency; public int dmICMMethod; public int dmICMIntent;
            public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2;
            public int dmPanningWidth; public int dmPanningHeight;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
        public static string[] Modes() {
            List<string> seen = new List<string>();
            DEVMODE dm = new DEVMODE();
            dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            for (int i = 0; EnumDisplaySettings(null, i, ref dm); i++) {
                string m = dm.dmPelsWidth + "x" + dm.dmPelsHeight;
                if (!seen.Contains(m)) { seen.Add(m); }
            }
            return seen.ToArray();
        }
    }
}
'@
        }
        foreach ($m in [MW4Tool.Display]::Modes()) { $list.Add($m) }
    } catch { }
    if ($list.Count -eq 0) {
        foreach ($m in '3840x2160','3440x1440','2560x1440','2560x1080','1920x1200','1920x1080','1680x1050','1600x900','1366x768','1280x720') { $list.Add($m) }
    }
    # Keep 720p and up, biggest first
    $sorted = $list | Where-Object { $_ -match '^(\d+)x(\d+)$' -and [int]$Matches[1] -ge 1280 -and [int]$Matches[2] -ge 720 } |
              Sort-Object { $p = $_ -split 'x'; [int]$p[0] * [int]$p[1] } -Descending
    return @($sorted)
}

function Show-Hardware($hw) {
    $ui.tbCpu.Text    = $hw.CpuName
    $ui.tbCores.Text  = [string]$hw.Cores
    $ui.tbGpu.Text    = $hw.GpuName
    $ui.tbVendor.Text = $hw.Vendor
    if ($hw.VramGB) { $ui.tbVram.Text = "$($hw.VramGB) GB" } else { $ui.tbVram.Text = 'Unknown (8 GB assumed)' }
    if ($hw.RamGB)  { $ui.tbRam.Text  = "$($hw.RamGB) GB" }  else { $ui.tbRam.Text  = 'Unknown' }
    $ui.tbDrive.Text  = $hw.Drive
    $ui.tbHz.Text     = [string]$hw.RefreshHz
    $ui.cbRes.Items.Clear()
    $current = ''
    if ($hw.Width) { $current = "$($hw.Width)x$($hw.Height)" }
    $modes = Get-DisplayResolutions
    if ($current -and -not ($modes -contains $current)) { [void]$ui.cbRes.Items.Add($current) }
    foreach ($m in $modes) { [void]$ui.cbRes.Items.Add($m) }
    if ($current) { $ui.cbRes.SelectedItem = $current } elseif ($ui.cbRes.Items.Count -gt 0) { $ui.cbRes.SelectedIndex = 0 }
}

function Read-Hardware {
    $hw = $script:Hw
    $m = [regex]::Match([string]$ui.cbRes.SelectedItem, '(\d+)\s*[xX]\s*(\d+)')
    if ($m.Success) { $hw.Width = [int]$m.Groups[1].Value; $hw.Height = [int]$m.Groups[2].Value }
    $hz = ConvertTo-PositiveInt $ui.tbHz.Text
    if ($hz) { $hw.RefreshHz = $hz }
    return $hw
}

function Read-Prefs {
    $p = New-DefaultPrefs
    $p.Goal       = $(if ($ui.rbVis.IsChecked) { 'Visibility' } else { 'FPS' })
    $p.Image      = [string]$ui.cbImage.SelectedItem.Tag
    $p.Cap        = [string]$ui.cbCap.SelectedItem.Tag
    $capValue = ConvertTo-PositiveInt $ui.tbCap.Text
    if ($capValue) { $p.CapValue = $capValue }
    $p.Audio      = $(if ($ui.rbSpk.IsChecked) { 'Speakers' } else { 'Headphones' })
    $p.MuteMusic  = [bool]$ui.chkMusic.IsChecked
    $p.Announcer  = [int]$ui.slAnn.Value
    $p.HitMarkers = [int]$ui.slHit.Value
    $p.HudPull    = [int]$ui.slHud.Value
    $p.HDR        = [bool]$ui.chkHdr.IsChecked
    $p.HighPriority = [bool]$ui.chkPrio.IsChecked
    $p.ReadOnly   = [bool]$ui.chkRO.IsChecked
    return $p
}

function Update-Backups {
    $ui.cbBackups.Items.Clear()
    foreach ($b in (Get-Backups)) { [void]$ui.cbBackups.Items.Add($b.Name) }
    if ($ui.cbBackups.Items.Count) { $ui.cbBackups.SelectedIndex = 0 }
    $ui.btnRestore.IsEnabled = ($ui.cbBackups.Items.Count -gt 0)
}

function Update-Preview {
    if (-not $script:Ready) { return }
    try {
        $ui.lblAnn.Text = "$([int]$ui.slAnn.Value)%"
        $ui.lblHit.Text = "$([int]$ui.slHit.Value)%"
        $hudPct = [int]$ui.slHud.Value
        if ($hudPct -ge 100) { $ui.lblHud.Text = 'CENTRE' } elseif ($hudPct -le 0) { $ui.lblHud.Text = 'EDGE' } else { $ui.lblHud.Text = "$hudPct% in" }
        if ([string]$ui.cbCap.SelectedItem.Tag -eq 'Custom') { $ui.tbCap.Visibility = [System.Windows.Visibility]::Visible }
        else { $ui.tbCap.Visibility = [System.Windows.Visibility]::Collapsed }
        $plan = Get-Plan (Read-Hardware) (Read-Prefs)
        $script:Rows = Get-PreviewRows $script:Files $plan.Changes $plan.Why $plan.OnlyIf
        # A DataTable binds cleanly in Windows PowerShell 5.1 (a PowerShell array here throws "Argument types do not match").
        $dt = New-Object System.Data.DataTable
        $cols = 'File', 'Setting', 'Key', 'Current', 'New', 'Status', 'Info', 'Impact', 'Why'
        foreach ($col in $cols) { [void]$dt.Columns.Add($col, [string]) }
        [void]$dt.Columns.Add('Id', [string]); [void]$dt.Columns.Add('Apply', [bool]); [void]$dt.Columns.Add('CanApply', [bool])
        foreach ($r in $script:Rows) {
            $dr = $dt.NewRow()
            foreach ($col in $cols) { $dr[$col] = [string]$r.$col }
            $id = [string]$r.Path + '|' + [string]$r.Key
            $can = ($r.Status -eq 'change')
            $dr['Id'] = $id; $dr['CanApply'] = $can
            $dr['Apply'] = ($can -and -not $script:Unticked.Contains($id))
            $dt.Rows.Add($dr)
        }
        # Remember what the player unticks, so refreshing the list keeps their choices
        $dt.Add_ColumnChanged({
            param($sender, $e)
            if ($e.Column.ColumnName -ne 'Apply') { return }
            $rid = [string]$e.Row['Id']
            if ([bool]$e.Row['Apply']) { [void]$script:Unticked.Remove($rid) } else { [void]$script:Unticked.Add($rid) }
            Update-Counts
        })
        $script:Dt = $dt
        $ui.lvPreview.ItemsSource = $dt.DefaultView
        $ui.tbNotes.Text = ($plan.Notes | ForEach-Object { "- $_" }) -join "`n"
        # Plain if/else: Windows PowerShell 5.1 throws "Argument types do not match" on @(...).Count inside $(if ...)
        $rowCount = $dt.Rows.Count
        if ($rowCount -eq 0) { $ui.emptyState.Visibility = [System.Windows.Visibility]::Visible }
        else { $ui.emptyState.Visibility = [System.Windows.Visibility]::Collapsed }
        Update-Counts
    } catch { $ui.tbStatus.Foreground = [Windows.Media.Brushes]::OrangeRed; $ui.tbStatus.Text = "Error (line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)" }
}

function Get-SelectedRows {
    $sel = New-Object System.Collections.Generic.List[object]
    if (-not $script:Dt) { return ,$sel }
    for ($i = 0; $i -lt $script:Dt.Rows.Count; $i++) {
        if ([bool]$script:Dt.Rows[$i]['Apply']) { $sel.Add($script:Rows[$i]) }
    }
    return ,$sel
}

function Update-Counts {
    $total = 0; $picked = 0
    if ($script:Dt) {
        foreach ($row in $script:Dt.Rows) {
            if ([bool]$row['CanApply']) { $total++ }
            if ([bool]$row['Apply']) { $picked++ }
        }
    }
    $ui.tbCount.Text = "$picked"
    $script:SyncingAll = $true
    if ($total -gt 0 -and $picked -eq $total) { $ui.chkAll.IsChecked = $true }
    elseif ($picked -eq 0) { $ui.chkAll.IsChecked = $false }
    else { $ui.chkAll.IsChecked = $null }
    $script:SyncingAll = $false
    $extra = ''
    if ([bool]$ui.chkPrio.IsChecked -ne (Test-PriorityReg)) { $extra = ' + CPU priority' }
    $ui.tbStatus.Foreground = [Windows.Media.Brushes]::White
    if ($total -eq 0 -and -not $extra) { $ui.tbStatus.Text = 'Already tuned - nothing to change.' }
    elseif ($picked -eq $total) { $ui.tbStatus.Text = "$picked settings will change$extra." }
    else { $ui.tbStatus.Text = "$picked of $total changes selected$extra." }
}

# Initial state
$script:Unticked = New-Object 'System.Collections.Generic.HashSet[string]'
$script:Dt = $null
$script:SyncingAll = $false
$script:Ready = $false
$script:Hw = Get-HardwareInfo $Files[0]
$script:Rows = @()
Show-Hardware $script:Hw
$ui.rbFps.IsChecked = $true; $ui.rbHead.IsChecked = $true
$ui.cbImage.SelectedIndex = 0; $ui.cbCap.SelectedIndex = 0
$ui.chkMusic.IsChecked = $true; $ui.slAnn.Value = 40; $ui.slHit.Value = 50
$ui.slHud.Value = Get-HudPullDefault $Files
$ui.chkHdr.IsChecked = $false; $ui.chkPrio.IsChecked = $true; $ui.chkRO.IsChecked = $false
Update-Backups

# Any change refreshes the preview
foreach ($n in 'tbHz','tbCap') { $ui[$n].Add_LostFocus({ Update-Preview }) }
foreach ($n in 'cbRes','cbImage','cbCap') { $ui[$n].Add_SelectionChanged({ Update-Preview }) }
foreach ($n in 'rbFps','rbVis','rbHead','rbSpk','chkMusic','chkHdr','chkPrio','chkRO') { $ui[$n].Add_Click({ Update-Preview }) }
foreach ($n in 'slAnn','slHit','slHud') { $ui[$n].Add_ValueChanged({ Update-Preview }) }

$ui.chkAll.Add_Click({
    if (-not $script:Dt) { return }
    $want = ($ui.chkAll.IsChecked -eq $true)
    foreach ($row in $script:Dt.Rows) { if ([bool]$row['CanApply']) { $row['Apply'] = $want } }
    Update-Counts
})

$ui.btnApply.Add_Click({
    try {
        Update-Preview
        $prefs = Read-Prefs
        $selected = Get-SelectedRows
        $prioChange = ([bool]$prefs.HighPriority -ne (Test-PriorityReg))
        if ($selected.Count -eq 0 -and -not $prioChange) {
            [Windows.MessageBox]::Show('Nothing is ticked. Tick the changes you want, then press Apply.', $ToolName, 'OK', 'Information') | Out-Null
            return
        }
        $b = Invoke-Apply $script:Files $selected $prefs.ReadOnly
        $prioOk = Set-PriorityReg $prefs.HighPriority
        $script:Files = Get-CodFiles
        Update-Backups
        Update-Preview
        $msg = "Done. Your previous settings were backed up ($(Split-Path $b -Leaf)).`n`n" +
               "Next: open the game, Graphics > Restart Shaders Pre-Loading, then restart the game.`n" +
               "If asked to 'Set Optimal Settings & Run In Safe Mode', choose No."
        if (-not $prioOk) { $msg += "`n`nCPU priority was not changed (admin prompt declined)." }
        [Windows.MessageBox]::Show($msg, $ToolName, 'OK', 'Information') | Out-Null
    } catch {
        [Windows.MessageBox]::Show($_.Exception.Message, $ToolName, 'OK', 'Error') | Out-Null
    }
})

$ui.btnRestore.Add_Click({
    $name = [string]$ui.cbBackups.SelectedItem
    if (-not $name) { return }
    $ok = [Windows.MessageBox]::Show("Put back the settings from $name ?", $ToolName, 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }
    try {
        Restore-Backup (Join-Path $BackupRoot $name)
        $script:Files = Get-CodFiles
        Update-Preview
        [Windows.MessageBox]::Show("Restored settings from $name.", $ToolName, 'OK', 'Information') | Out-Null
    } catch {
        [Windows.MessageBox]::Show($_.Exception.Message, $ToolName, 'OK', 'Error') | Out-Null
    }
})

$ui.btnFolder.Add_Click({ Start-Process explorer.exe $PlayersPath })

# Update check runs in the background so the window opens instantly (offline = silently skipped)
$ui.btnUpdateLater.Add_Click({ $ui.updateBar.Visibility = [System.Windows.Visibility]::Collapsed })
$ui.btnUpdate.Add_Click({
    if (-not $script:UpdateInfo) { return }
    $ui.btnUpdate.IsEnabled = $false; $ui.btnUpdateLater.IsEnabled = $false
    $ui.tbUpdateInfo.Text = 'Downloading and installing... this only takes a few seconds.'
    $ui.updateBar.Dispatcher.Invoke([Action]{ }, [System.Windows.Threading.DispatcherPriority]::Render)
    try {
        Install-Update $script:UpdateInfo
        [Windows.MessageBox]::Show("Updated to $($script:UpdateInfo.Tag). The tool will now restart.", $ToolName, 'OK', 'Information') | Out-Null
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"" -WindowStyle Hidden
        $Window.Close()
    } catch {
        $ui.btnUpdate.IsEnabled = $true; $ui.btnUpdateLater.IsEnabled = $true
        $ui.tbUpdateInfo.Text = "Update failed: $($_.Exception.Message)"
    }
})
if (-not $NoUpdateCheck) {
    try {
        $script:UpdPs = [powershell]::Create().AddScript($UpdateCheckScript).AddArgument($ReleaseApi).AddArgument($ReleaseZip)
        $script:UpdHandle = $script:UpdPs.BeginInvoke()
        $script:UpdTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:UpdTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $script:UpdTimer.Add_Tick({
            if (-not $script:UpdHandle.IsCompleted) { return }
            $script:UpdTimer.Stop()
            try {
                $res = $script:UpdPs.EndInvoke($script:UpdHandle)
                $script:UpdPs.Dispose()
                $info = $null
                foreach ($item in $res) { if ($item) { $info = $item } }
                if ($info -and $info.Tag -and -not (Test-NewerVersion $info.Tag $ToolVersion)) {
                    $ui.tbVersion.Text = "v$ToolVersion  |  UP TO DATE"
                    $ui.tbVersion.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(61, 220, 151))
                }
                if ($info -and $info.Url -and (Test-NewerVersion $info.Tag $ToolVersion)) {
                    $script:UpdateInfo = $info
                    $ui.tbVersion.Text = "v$ToolVersion  |  UPDATE READY"
                    $ui.tbVersion.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 123, 69))
                    $ui.tbUpdateTitle.Text = "Update available: $($info.Tag)"
                    $ui.tbUpdateInfo.Text = "You have v$ToolVersion. One click updates the tool and restarts it - your game settings and backups stay as they are."
                    $ui.updateBar.Visibility = [System.Windows.Visibility]::Visible
                }
            } catch { }
        })
        $script:UpdTimer.Start()
    } catch { }
}

$script:Ready = $true
Update-Preview
[void]$Window.ShowDialog()
