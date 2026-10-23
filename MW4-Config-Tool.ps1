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
    [string]$PlayersPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# ---------------------------------------------------------------------------------------------
#  Game constants - edit this block to support a future release
# ---------------------------------------------------------------------------------------------
$ToolName        = 'g1gGLe''z MW4 Performance Tool'
$ToolVersion     = '1.1.2'
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
    [pscustomobject]@{ Path = $Path; Lines = $lines; NewLine = $nl; Values = $values; Comments = $comments }
}

function Write-CodFile($File, $Changes) {
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
        if (Test-Path -LiteralPath $acc) { $files.Add((Read-CodFile $acc)) }
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
        HDR          = $false
        HighPriority = $true
        ReadOnly     = $false
    }
}

function Get-Plan($Hw, $Prefs) {
    $c = [ordered]@{}
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
    if ($Hw.HybridIntel) { $notes.Add("Intel hybrid CPU: using P-cores ($($Hw.Cores)) for the render thread count.") }

    # --- GPU memory
    $vram = $Hw.VramGB
    if (-not $vram) { $vram = 8; $notes.Add('Video memory not detected - assumed 8 GB. Fix it on the left if wrong.') }
    $c['VideoMemoryScaleMP@0'] = $(if ($vram -ge 12) { '0.900000' } elseif ($vram -ge 8) { '0.800000' } else { '0.700000' })

    if ($Prefs.Goal -eq 'Visibility') {
        $c['TextureQuality@0'] = $(if ($vram -ge 12) { '1' } elseif ($vram -ge 8) { '2' } else { '3' })
        $c['TextureFilter@0']  = 'aniso 8x'
        $c['BulletImpacts@0']  = 'true'
    } else {
        $c['TextureQuality@0'] = '3'
        $c['TextureFilter@0']  = 'aniso 2x'
        $c['BulletImpacts@0']  = 'false'
    }

    # --- Latency tech for the GPU vendor
    switch ($Hw.Vendor) {
        'NVIDIA' { $c['NvidiaReflex@0'] = 'Enabled'; $c['AmdAntilag2@0'] = 'false'; $c['IntelXeLL@0'] = 'false' }
        'AMD'    { $c['AmdAntilag2@0'] = 'true';     $c['IntelXeLL@0'] = 'false' }
        'Intel'  { $c['IntelXeLL@0'] = 'true';       $c['AmdAntilag2@0'] = 'false' }
        default  { $notes.Add('GPU vendor unknown - latency settings left as they are.') }
    }

    # --- Image: native SMAA + CAS sharpening, or the vendor's upscaler
    $image = $Prefs.Image
    if ($image -eq 'Auto') {
        if (($Hw.Width -and $Hw.Width -ge 3840) -or $vram -lt 8) { $image = 'Upscaler' } else { $image = 'Native' }
    }
    if ($image -eq 'Native') {
        $c['AATechniquePreferredMP@0'] = 'SMAA'
        $c['AMDFidelityFX@0'] = 'CAS'; $c['AMDFidelityFX@1'] = 'CAS'
        $c['AMDContrastAdaptiveSharpeningStrength@0'] = '1.000000'
    } else {
        $q = $(if (($Hw.Width -and $Hw.Width -ge 3840) -or $vram -lt 8) { 'Maximum Performance' } else { 'Balanced' })
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
    [pscustomobject]@{ Changes = $c; Notes = $notes }
}

function Get-PreviewRows($Files, $Changes) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($f in $Files) {
        $label = $(if ((Split-Path $f.Path -Leaf) -eq $SystemFileName) { 'Graphics' } else { 'Account' })
        foreach ($k in $Changes.Keys) {
            if (-not $f.Values.Contains($k)) { continue }
            $cur = $f.Values[$k]; $new = $Changes[$k]
            if ($cur -ceq $new) { continue }
            $ok = Test-CodValue $f.Comments[$k] $new
            $rows.Add([pscustomobject]@{
                File = $label; Setting = ($k -replace '@0$', ''); Key = $k
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

if ($Silent) {
    if (-not $Files) { Write-Host $NoGameMsg -ForegroundColor Yellow; exit 1 }
    $hw    = Get-HardwareInfo $Files[0]
    $prefs = New-DefaultPrefs
    $plan  = Get-Plan $hw $prefs
    $rows  = Get-PreviewRows $Files $plan.Changes
    Write-Host "$ToolName $ToolVersion" -ForegroundColor Cyan
    Write-Host ("CPU: {0} ({1} cores)  GPU: {2} [{3}, {4} GB]  Display: {5}x{6} @ {7} Hz  Drive: {8}" -f `
        $hw.CpuName, $hw.Cores, $hw.GpuName, $hw.Vendor, $hw.VramGB, $hw.Width, $hw.Height, $hw.RefreshHz, $hw.Drive)
    $rows | Format-Table File, Setting, Current, New, Status -AutoSize | Out-String -Width 200 | Write-Host
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

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$ToolName" Width="1240" Height="800" MinWidth="1060" MinHeight="660"
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
          <Border x:Name="Bd" Background="Transparent" BorderBrush="#1C2029" BorderThickness="0,0,0,1" Padding="0,5">
            <GridViewRowPresenter Columns="{TemplateBinding GridView.ColumnCollection}" Content="{TemplateBinding Content}"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1A1E26"/></Trigger>
            <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#22180F"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
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
      <Setter Property="Background" Value="#1A1E26"/><Setter Property="Foreground" Value="#ECEEF1"/><Setter Property="BorderBrush" Value="#FF5A1F"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <!-- ================= HEADER ================= -->
    <Border Grid.Row="0" Padding="24,18" BorderBrush="#FF5A1F" BorderThickness="0,0,0,2">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#2A1206" Offset="0"/>
          <GradientStop Color="#140C09" Offset="0.35"/>
          <GradientStop Color="#0B0D11" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <DockPanel LastChildFill="True">
        <Grid DockPanel.Dock="Left" Width="84" Height="84" Margin="0,0,16,0">
          <Border x:Name="logoFallback" CornerRadius="14" BorderBrush="#FF5A1F" BorderThickness="2">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#FF7B45" Offset="0"/><GradientStop Color="#B8320A" Offset="1"/></LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="FiTH" Foreground="White" FontWeight="Black" FontSize="20" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <Image x:Name="imgLogo" Stretch="Uniform" Visibility="Collapsed" RenderOptions.BitmapScalingMode="HighQuality"/>
        </Grid>

        <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center" HorizontalAlignment="Right">
          <TextBlock Text="JOIN THE SQUAD" Foreground="#8C94A3" FontSize="11" FontWeight="Bold" HorizontalAlignment="Right" Margin="0,0,0,8"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="lnkDiscord" Style="{StaticResource BtnBrand}" Background="#5865F2" BorderBrush="#5865F2" ToolTip="Join the FiTH Gaming Discord">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE8BD;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="DISCORD" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkYouTube" Style="{StaticResource BtnBrand}" Background="#FF0000" BorderBrush="#FF0000" ToolTip="FiTH Gaming on YouTube">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE714;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="YOUTUBE" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkFacebook" Style="{StaticResource BtnBrand}" Background="#1877F2" BorderBrush="#1877F2" ToolTip="FiTH Gaming on Facebook">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE716;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="FACEBOOK" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkSteam" Style="{StaticResource BtnBrand}" Background="#171A21" BorderBrush="#66C0F4" ToolTip="FiTH Gaming Steam group">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE7FC;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="STEAM" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkWeb" Style="{StaticResource BtnBrand}" Background="#FF5A1F" BorderBrush="#FF5A1F" ToolTip="fithgaming.co.uk">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE774;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="WEBSITE" Foreground="White"/></StackPanel>
            </Button>
          </StackPanel>
        </StackPanel>

        <Image x:Name="imgGame" DockPanel.Dock="Right" Width="72" Height="72" Margin="0,0,26,0" Visibility="Collapsed"
               RenderOptions.BitmapScalingMode="HighQuality" VerticalAlignment="Center"/>

        <StackPanel VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="g1gGLe'z " FontSize="26" FontWeight="Black" Foreground="#FF5A1F"/>
            <TextBlock Text="MW4 PERFORMANCE" FontSize="26" FontWeight="Black" Foreground="White"/>
            <Border Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" CornerRadius="10" Padding="8,2" Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="v$ToolVersion" Foreground="#FF7B45" FontSize="11" FontWeight="Bold"/>
            </Border>
          </StackPanel>
          <TextBlock Text="Call of Duty: Modern Warfare 4  &#183;  tuned to YOUR PC for max FPS, low latency and rock-solid frame times" Foreground="#B9BFCA" Margin="2,4,0,0"/>
          <TextBlock Text="FiTH GAMING  &#183;  FIRE IN THE HOLE" Foreground="#FF7B45" FontSize="11" FontWeight="Bold" Margin="2,6,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ================= BODY ================= -->
    <Grid Grid.Row="1" Margin="10,8,10,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="300"/><ColumnDefinition Width="310"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <Border Grid.Column="0" Style="{StaticResource CardBox}">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Style="{StaticResource CardTitle}" Text="YOUR RIG"/>
            <TextBlock Text="Detected automatically - edit anything that's wrong" Foreground="#8C94A3" FontSize="11"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,0,6,0">
            <TextBlock Style="{StaticResource Lbl}" Text="CPU"/>
            <TextBox x:Name="tbCpu" IsReadOnly="True"/>
            <TextBlock Style="{StaticResource Lbl}" Text="Physical cores (P-cores on Intel hybrid)"/>
            <TextBox x:Name="tbCores"/>
            <TextBlock Style="{StaticResource Lbl}" Text="Graphics card"/>
            <TextBox x:Name="tbGpu"/>
            <TextBlock Style="{StaticResource Lbl}" Text="GPU vendor"/>
            <ComboBox x:Name="cbVendor"><ComboBoxItem>NVIDIA</ComboBoxItem><ComboBoxItem>AMD</ComboBoxItem><ComboBoxItem>Intel</ComboBoxItem><ComboBoxItem>Unknown</ComboBoxItem></ComboBox>
            <TextBlock Style="{StaticResource Lbl}" Text="Video memory (GB)"/>
            <TextBox x:Name="tbVram"/>
            <TextBlock Style="{StaticResource Lbl}" Text="Resolution (e.g. 2560x1440)"/>
            <TextBox x:Name="tbRes"/>
            <TextBlock Style="{StaticResource Lbl}" Text="Refresh rate (Hz)"/>
            <TextBox x:Name="tbHz"/>
            <TextBlock Style="{StaticResource Lbl}" Text="Game drive"/>
            <ComboBox x:Name="cbDrive"><ComboBoxItem>SSD</ComboBoxItem><ComboBoxItem>HDD</ComboBoxItem></ComboBox>
            <TextBlock x:Name="tbRam" Style="{StaticResource Lbl}"/>
          </StackPanel></ScrollViewer>
        </DockPanel>
      </Border>

      <Border Grid.Column="1" Style="{StaticResource CardBox}">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Style="{StaticResource CardTitle}" Text="LOADOUT"/>
            <TextBlock Text="How you want the game to feel" Foreground="#8C94A3" FontSize="11"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,0,6,0">
            <TextBlock Style="{StaticResource Lbl}" Text="Goal"/>
            <WrapPanel><RadioButton x:Name="rbFps" GroupName="goal" Content="Max FPS"/><RadioButton x:Name="rbVis" GroupName="goal" Content="Visibility"/></WrapPanel>
            <TextBlock Style="{StaticResource Lbl}" Text="Image"/>
            <ComboBox x:Name="cbImage">
              <ComboBoxItem Tag="Auto">Auto (recommended)</ComboBoxItem>
              <ComboBoxItem Tag="Native">Native + SMAA + sharpening</ComboBoxItem>
              <ComboBoxItem Tag="Upscaler">Upscaler (DLSS / FSR / XeSS)</ComboBoxItem>
            </ComboBox>
            <TextBlock Style="{StaticResource Lbl}" Text="FPS cap"/>
            <ComboBox x:Name="cbCap">
              <ComboBoxItem Tag="Auto">Auto (refresh rate - 3)</ComboBoxItem>
              <ComboBoxItem Tag="Uncapped">Uncapped</ComboBoxItem>
              <ComboBoxItem Tag="Custom">Custom</ComboBoxItem>
            </ComboBox>
            <TextBox x:Name="tbCap" IsEnabled="False" Margin="0,6,0,0" ToolTip="Custom FPS cap (30-300)"/>
            <TextBlock Style="{StaticResource Lbl}" Text="Audio"/>
            <WrapPanel><RadioButton x:Name="rbHead" GroupName="aud" Content="Headphones"/><RadioButton x:Name="rbSpk" GroupName="aud" Content="Speakers"/></WrapPanel>
            <CheckBox x:Name="chkMusic" Content="Mute music and war tracks"/>
            <TextBlock x:Name="lblAnn" Style="{StaticResource Lbl}"/>
            <Slider x:Name="slAnn" Minimum="0" Maximum="100" TickFrequency="5" IsSnapToTickEnabled="True"/>
            <TextBlock x:Name="lblHit" Style="{StaticResource Lbl}"/>
            <Slider x:Name="slHit" Minimum="0" Maximum="100" TickFrequency="5" IsSnapToTickEnabled="True"/>
            <TextBlock Style="{StaticResource Lbl}" Text="Extras"/>
            <CheckBox x:Name="chkHdr" Content="HDR on (needs an HDR monitor)"/>
            <CheckBox x:Name="chkPrio" Content="High CPU priority for cod.exe" ToolTip="Sets cod.exe to High priority every launch. Asks for admin."/>
            <CheckBox x:Name="chkRO" Content="Lock graphics file (read-only)" ToolTip="Stops the game changing your graphics settings. Untick to change them in game."/>
          </StackPanel></ScrollViewer>
        </DockPanel>
      </Border>

      <Border Grid.Column="2" Style="{StaticResource CardBox}">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <DockPanel Grid.Row="0" Margin="0,0,0,10">
            <Border DockPanel.Dock="Right" Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" CornerRadius="10" Padding="10,3" VerticalAlignment="Center">
              <TextBlock x:Name="tbCount" Text="0" Foreground="#FF7B45" FontWeight="Bold" FontSize="12"/>
            </Border>
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="CHANGES TO APPLY"/>
              <TextBlock Text="Only these values are touched - everything else in your file stays as it is" Foreground="#8C94A3" FontSize="11"/>
            </StackPanel>
          </DockPanel>
          <ListView x:Name="lvPreview" Grid.Row="1" Background="#101318" BorderBrush="#272D38" BorderThickness="1" Foreground="#ECEEF1">
            <ListView.View><GridView>
              <GridViewColumn Header="FILE" Width="80"><GridViewColumn.CellTemplate><DataTemplate>
                <TextBlock Text="{Binding File}" Foreground="#8C94A3" Margin="4,0,0,0"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="SETTING" Width="210"><GridViewColumn.CellTemplate><DataTemplate>
                <TextBlock Text="{Binding Setting}" ToolTip="{Binding Setting}" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="NOW" Width="130"><GridViewColumn.CellTemplate><DataTemplate>
                <TextBlock Text="{Binding Current}" ToolTip="{Binding Current}" Foreground="#8C94A3" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="NEW" Width="130"><GridViewColumn.CellTemplate><DataTemplate>
                <TextBlock Text="{Binding New}" ToolTip="{Binding New}" Foreground="#FF7B45" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="STATUS" Width="80"><GridViewColumn.CellTemplate><DataTemplate>
                <TextBlock Text="{Binding Status}" ToolTip="{Binding Status}" Foreground="#3DDC97" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
            </GridView></ListView.View>
          </ListView>
          <Border Grid.Row="2" Background="#1A1E26" CornerRadius="8" Padding="12,10" Margin="0,10,0,0">
            <TextBlock x:Name="tbNotes" TextWrapping="Wrap" Foreground="#B9BFCA" FontSize="12"/>
          </Border>
        </Grid>
      </Border>
    </Grid>

    <!-- ================= FOOTER ================= -->
    <Border Grid.Row="2" Background="#101318" BorderBrush="#272D38" BorderThickness="0,1,0,0" Padding="20,12">
      <DockPanel LastChildFill="False">
        <TextBlock DockPanel.Dock="Left" Text="BACKUPS" VerticalAlignment="Center" Foreground="#8C94A3" FontSize="11" FontWeight="Bold"/>
        <ComboBox x:Name="cbBackups" DockPanel.Dock="Left" Width="200" Margin="10,0,0,0" VerticalAlignment="Center"/>
        <Button x:Name="btnRestore" DockPanel.Dock="Left" Style="{StaticResource BtnBase}" Content="Restore" Margin="8,0,0,0"/>
        <Button x:Name="btnFolder" DockPanel.Dock="Left" Style="{StaticResource BtnBase}" Content="Open settings folder" Margin="8,0,0,0"/>
        <Button x:Name="btnApply" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="APPLY"/>
        <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center" Margin="0,0,16,0">
          <TextBlock x:Name="tbStatus" HorizontalAlignment="Right" FontWeight="SemiBold"/>
          <TextBlock Text="made by g1gGLe  &#183;  FiTH Gaming" HorizontalAlignment="Right" Foreground="#5D6573" FontSize="11" Margin="0,2,0,0"/>
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
foreach ($n in 'tbCpu','tbCores','tbGpu','cbVendor','tbVram','tbRes','tbHz','cbDrive','tbRam',
               'rbFps','rbVis','cbImage','cbCap','tbCap','rbHead','rbSpk','chkMusic','lblAnn','slAnn','lblHit','slHit',
               'chkHdr','chkPrio','chkRO','lvPreview','tbNotes','tbCount','cbBackups','btnRestore','btnFolder','btnApply','tbStatus',
               'imgLogo','logoFallback','imgGame','lnkDiscord','lnkYouTube','lnkFacebook','lnkSteam','lnkWeb') {
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

function Show-Hardware($hw) {
    $ui.tbCpu.Text   = $hw.CpuName
    $ui.tbCores.Text = [string]$hw.Cores
    $ui.tbGpu.Text   = $hw.GpuName
    Select-ComboText $ui.cbVendor $hw.Vendor
    $ui.tbVram.Text  = [string]$hw.VramGB
    $ui.tbRes.Text   = $(if ($hw.Width) { "$($hw.Width)x$($hw.Height)" } else { '' })
    $ui.tbHz.Text    = [string]$hw.RefreshHz
    Select-ComboText $ui.cbDrive $hw.Drive
    $ui.tbRam.Text   = $(if ($hw.RamGB) { "System memory: $($hw.RamGB) GB" } else { '' })
}

function Read-Hardware {
    $hw = $script:Hw
    $cores = ConvertTo-PositiveInt $ui.tbCores.Text
    if ($cores) { $hw.Cores = $cores }
    $hw.GpuName   = $ui.tbGpu.Text
    $hw.Vendor    = [string]$ui.cbVendor.SelectedItem.Content
    $hw.VramGB    = ConvertTo-PositiveInt $ui.tbVram.Text
    $m = [regex]::Match($ui.tbRes.Text, '(\d+)\s*[xX]\s*(\d+)')
    if ($m.Success) { $hw.Width = [int]$m.Groups[1].Value; $hw.Height = [int]$m.Groups[2].Value } else { $hw.Width = $null; $hw.Height = $null }
    $hw.RefreshHz = ConvertTo-PositiveInt $ui.tbHz.Text
    $hw.Drive     = [string]$ui.cbDrive.SelectedItem.Content
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
        $ui.lblAnn.Text = "Announcer / dialogue volume: $([int]$ui.slAnn.Value)%"
        $ui.lblHit.Text = "Hit marker volume: $([int]$ui.slHit.Value)%"
        $ui.tbCap.IsEnabled = ([string]$ui.cbCap.SelectedItem.Tag -eq 'Custom')
        $plan = Get-Plan (Read-Hardware) (Read-Prefs)
        $script:Rows = Get-PreviewRows $script:Files $plan.Changes
        # A DataTable binds cleanly in Windows PowerShell 5.1 (a PowerShell array here throws "Argument types do not match").
        $dt = New-Object System.Data.DataTable
        foreach ($col in 'File', 'Setting', 'Current', 'New', 'Status') { [void]$dt.Columns.Add($col, [string]) }
        foreach ($r in $script:Rows) {
            $dr = $dt.NewRow()
            $dr['File'] = [string]$r.File; $dr['Setting'] = [string]$r.Setting
            $dr['Current'] = [string]$r.Current; $dr['New'] = [string]$r.New; $dr['Status'] = [string]$r.Status
            $dt.Rows.Add($dr)
        }
        $ui.lvPreview.ItemsSource = $dt.DefaultView
        $ui.tbNotes.Text = ($plan.Notes | ForEach-Object { "- $_" }) -join "`n"
        $n = @($script:Rows | Where-Object { $_.Status -eq 'change' }).Count
        $prioNow = Test-PriorityReg
        $extra = $(if ([bool]$ui.chkPrio.IsChecked -ne $prioNow) { ' + CPU priority' } else { '' })
        $ui.tbCount.Text = "$n"
        $ui.tbStatus.Text = $(if ($n -eq 0 -and -not $extra) { 'Already tuned - nothing to change.' } else { "$n settings will change$extra." })
    } catch { $ui.tbStatus.Foreground = [Windows.Media.Brushes]::OrangeRed; $ui.tbStatus.Text = "Error (line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)" }
}

# Initial state
$script:Ready = $false
$script:Hw = Get-HardwareInfo $Files[0]
$script:Rows = @()
Show-Hardware $script:Hw
$ui.rbFps.IsChecked = $true; $ui.rbHead.IsChecked = $true
$ui.cbImage.SelectedIndex = 0; $ui.cbCap.SelectedIndex = 0
$ui.chkMusic.IsChecked = $true; $ui.slAnn.Value = 40; $ui.slHit.Value = 50
$ui.chkHdr.IsChecked = $false; $ui.chkPrio.IsChecked = $true; $ui.chkRO.IsChecked = $false
Update-Backups

# Any change refreshes the preview
foreach ($n in 'tbCores','tbGpu','tbVram','tbRes','tbHz','tbCap') { $ui[$n].Add_LostFocus({ Update-Preview }) }
foreach ($n in 'cbVendor','cbDrive','cbImage','cbCap') { $ui[$n].Add_SelectionChanged({ Update-Preview }) }
foreach ($n in 'rbFps','rbVis','rbHead','rbSpk','chkMusic','chkHdr','chkPrio','chkRO') { $ui[$n].Add_Click({ Update-Preview }) }
foreach ($n in 'slAnn','slHit') { $ui[$n].Add_ValueChanged({ Update-Preview }) }

$ui.btnApply.Add_Click({
    try {
        Update-Preview
        $prefs = Read-Prefs
        $b = Invoke-Apply $script:Files $script:Rows $prefs.ReadOnly
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

$script:Ready = $true
Update-Preview
[void]$Window.ShowDialog()
