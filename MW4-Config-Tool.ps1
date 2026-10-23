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
$ToolName        = 'MW4 Config Tool'
$ToolVersion     = '1.0.1'
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
        Title="$ToolName" Width="1180" Height="720" MinWidth="980" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#F3F4F6" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="GroupBox">
      <Setter Property="Margin" Value="8"/><Setter Property="Padding" Value="10"/>
      <Setter Property="Background" Value="White"/><Setter Property="BorderBrush" Value="#D9DCE1"/>
    </Style>
    <Style TargetType="TextBox"><Setter Property="Margin" Value="0,2,0,6"/><Setter Property="Padding" Value="4,3"/></Style>
    <Style TargetType="ComboBox"><Setter Property="Margin" Value="0,2,0,6"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Margin" Value="0,4"/></Style>
    <Style TargetType="RadioButton"><Setter Property="Margin" Value="0,2,14,2"/></Style>
    <Style x:Key="Lbl" TargetType="TextBlock"><Setter Property="Foreground" Value="#4B5563"/><Setter Property="Margin" Value="0,4,0,0"/></Style>
    <Style TargetType="Button"><Setter Property="Padding" Value="14,6"/><Setter Property="Margin" Value="6,0,0,0"/></Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#14161B" Padding="18,12">
      <StackPanel>
        <TextBlock Text="$ToolName" Foreground="White" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock Text="Call of Duty: Modern Warfare 4 - tuned to this PC for max FPS and stability. Close the game before applying." Foreground="#A7ADB8"/>
      </StackPanel>
    </Border>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="300"/><ColumnDefinition Width="300"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <GroupBox Grid.Column="0" Header="Your PC (detected - edit if wrong)">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel>
          <TextBlock Style="{StaticResource Lbl}" Text="CPU"/>
          <TextBox x:Name="tbCpu" IsReadOnly="True" Background="#F3F4F6"/>
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
      </GroupBox>

      <GroupBox Grid.Column="1" Header="Preferences">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel>
          <TextBlock Style="{StaticResource Lbl}" Text="Goal"/>
          <WrapPanel><RadioButton x:Name="rbFps" GroupName="goal" Content="Max FPS"/><RadioButton x:Name="rbVis" GroupName="goal" Content="Visibility (clearer textures)"/></WrapPanel>
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
          <TextBox x:Name="tbCap" IsEnabled="False"/>
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
          <CheckBox x:Name="chkRO" Content="Lock graphics file (read-only)"/>
        </StackPanel></ScrollViewer>
      </GroupBox>

      <GroupBox Grid.Column="2" Header="Changes to apply">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <ListView x:Name="lvPreview" Grid.Row="0" BorderBrush="#E5E7EB">
            <ListView.View><GridView>
              <GridViewColumn Header="File" Width="70" DisplayMemberBinding="{Binding File}"/>
              <GridViewColumn Header="Setting" Width="190" DisplayMemberBinding="{Binding Setting}"/>
              <GridViewColumn Header="Now" Width="95" DisplayMemberBinding="{Binding Current}"/>
              <GridViewColumn Header="New" Width="95" DisplayMemberBinding="{Binding New}"/>
              <GridViewColumn Header="Status" Width="70" DisplayMemberBinding="{Binding Status}"/>
            </GridView></ListView.View>
          </ListView>
          <TextBlock x:Name="tbNotes" Grid.Row="1" TextWrapping="Wrap" Foreground="#4B5563" Margin="0,8,0,0"/>
        </Grid>
      </GroupBox>
    </Grid>

    <Border Grid.Row="2" Background="White" BorderBrush="#D9DCE1" BorderThickness="0,1,0,0" Padding="14,10">
      <DockPanel LastChildFill="False">
        <TextBlock DockPanel.Dock="Left" Text="Backups:" VerticalAlignment="Center" Foreground="#4B5563"/>
        <ComboBox x:Name="cbBackups" DockPanel.Dock="Left" Width="190" Margin="8,0,0,0" VerticalAlignment="Center"/>
        <Button x:Name="btnRestore" DockPanel.Dock="Left" Content="Restore"/>
        <Button x:Name="btnFolder" DockPanel.Dock="Left" Content="Open settings folder"/>
        <Button x:Name="btnApply" DockPanel.Dock="Right" Content="Apply" Background="#2563EB" Foreground="White" FontWeight="SemiBold" Padding="26,6"/>
        <TextBlock x:Name="tbStatus" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="0,0,12,0" Foreground="#111827"/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
"@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'tbCpu','tbCores','tbGpu','cbVendor','tbVram','tbRes','tbHz','cbDrive','tbRam',
               'rbFps','rbVis','cbImage','cbCap','tbCap','rbHead','rbSpk','chkMusic','lblAnn','slAnn','lblHit','slHit',
               'chkHdr','chkPrio','chkRO','lvPreview','tbNotes','cbBackups','btnRestore','btnFolder','btnApply','tbStatus') {
    $ui[$n] = $Window.FindName($n)
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
        $ui.lvPreview.ItemsSource = $null
        $ui.lvPreview.ItemsSource = @($script:Rows)
        $ui.tbNotes.Text = ($plan.Notes | ForEach-Object { "- $_" }) -join "`n"
        $n = @($script:Rows | Where-Object { $_.Status -eq 'change' }).Count
        $prioNow = Test-PriorityReg
        $extra = $(if ([bool]$ui.chkPrio.IsChecked -ne $prioNow) { ' + CPU priority' } else { '' })
        $ui.tbStatus.Text = $(if ($n -eq 0 -and -not $extra) { 'Already tuned - nothing to change.' } else { "$n settings will change$extra." })
    } catch { $ui.tbStatus.Text = "Error (line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)" }
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
