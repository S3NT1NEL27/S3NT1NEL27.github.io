# Self-elevation: relaunch as admin if not already elevated
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ELEVATION] Relaunching as Administrator..."
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

<#
.SYNOPSIS
    Post-update driver and service maintenance script for ROG Flow X13 (Work_laptop).
    Run after any AMD, ASUS, or Windows update that touches drivers or services.

.DESCRIPTION
    This is a living repository of driver/service fixes for components that
    recur after updates. Add new problem drivers here as they are discovered.
    Do not create separate scripts - keep everything here.

    TIER STRUCTURE:
    - Tier 1 (Kill):      Pure telemetry/bloat. Stop + disable. Safe to remove.
    - Tier 2 (Disable):  Kernel drivers or overhead services. Stop + set Disabled,
                          leave .sys in place. Do NOT delete - re-enable path kept open.
    - Tier 3 (Monitor):   Hardware-serving components. Log to dump only. Do not touch.

    OUTPUTS (per run, timestamped):
      1. Action log  - what was found and killed
      2. State dump  - full kernel driver/service snapshot for incongruency review

    WHY THE DUMP EXISTS:
    AMD/ASUS/Microsoft can rename problem services on future updates (e.g., V31->V32,
    or an entirely different name). Name-based detection alone is not sufficient.
    Compare state dumps before and after any update to catch renamed or new entries.
    Look for: new Running kernel drivers, drivers in unusual paths, recently modified
    .sys files, and Device Manager errors.

    KNOWN PROBLEM HISTORY:
    - AMDRyzenMasterDriverV19: found loaded, service DEMAND_START (Session 5, 2026-03-31)
      .sys: C:\WINDOWS\system32\drivers\AMDRyzenMasterDriver.sys (7/1/2021)
      Produces 0xFF IRQL memory corruption -> IRQL_NOT_LESS_OR_EQUAL BSODs
    - AMDRyzenMasterDriverV31: found RUNNING (Session 10, 2026-04-02)
      .sys: C:\WINDOWS\system32\AMDRyzenMasterDriver.sys (3/3/2026)
      Installed silently by AMD Adrenalin 26.3.1 / iGPU driver update (3/31/2026)
      Same 0xFF IRQL corruption pattern as V19
    Both versions: ntoskrnl.exe is victim, not cause. RyzenMaster writes garbage
    into kernel memory structures -> scatter-pattern BSODs across multiple bugcheck codes.

    EXPANSION HISTORY (Session 12):
    - AMD Crash Defender Service / amdfendr / amdfendrmgr: Tier 2 (disable, no delete)
      amdfendr.sys has documented BSOD failure bucket (LKD_0xA1000005)
    - AMD External Events Utility: Tier 1 (stop + disable, no delete)
      FreeSync/hotkeys - zero value on AI workload. To re-enable:
        sc.exe config AMDExternalEventsUtility start= demand
    - AmdPpkg / AmdPpkgSvc: Tier 3 Monitor (do not touch)
      Delivers AMD-tuned power profiles to 6900HS - serves the workload
    - ASUSSystemAnalysis / ASUSSystemDiagnosis / AsusAppService / ASUSSoftwareManager / ASUSSwitch: Tier 1 (stop + delete)
    - AsusSAIO.sys / ROGKB.sys / ASUSOptimization: Tier 2 (stop + disable, no delete)
    - ATKWMIACPIIO.sys: Tier 3 Monitor (do not touch)
      Fn key ACPI interception - removing kills brightness/fan hotkeys
#>

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$dateStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath  = "C:\Users\edwar\service_kill_log_$dateStamp.txt"
$dumpPath = "C:\Users\edwar\service_state_dump_$dateStamp.txt"
$actionLines = @()
$dumpLines   = @()
$anyAction   = $false

function Log($msg) {
    Write-Host $msg
    $script:actionLines += $msg
}

function Dump($msg) {
    $script:dumpLines += $msg
}

# ============================================================
# SECTION 1 - KERNEL DRIVERS (known problem by name)
# Tier 2: stop + disable, no delete (PnP/INF registered drivers)
# ============================================================

Log "=== Service & Driver Maintenance Script ==="
Log "Run at: $timestamp"
Log "Tier 1: stop + disable (delete not attempted)"
Log "Tier 2: stop + set Disabled (no delete - re-enable path preserved)"
Log "Tier 3: Monitor only (no action taken)"
Log "Action log:  $logPath"
Log "State dump:  $dumpPath"
Log ""

# --- AMD Crash Defender kernel drivers (Tier 2 - disable only) ---
Log "--- [TIER 2] AMD Crash Defender stack ---"
Log "  amdfendr.sys: documented BSOD failure bucket LKD_0xA1000005"
Log "  amdfendrmgr.sys: same risk, must be paired"

$amdfendrSvc = "amdfendr"
$amdfendrmgrSvc = "amdfendrmgr"

foreach ($svc in @($amdfendrSvc, $amdfendrmgrSvc)) {
    $state = sc.exe query $svc 2>&1
    if ($state -match "does not exist") {
        Log "  [OK] $svc service not found."
    } else {
        $stopResult = sc.exe stop $svc 2>&1
        Log "  [STOP] $svc : $($stopResult -join ' ')"
        $cfgResult = sc.exe config $svc start= disabled 2>&1
        Log "  [DISABLE] $svc : $($cfgResult -join ' ')"
        Log "  [NOTE] Service entry retained - re-enable if needed via sc.exe config $svc start= demand"
        $script:anyAction = $true
    }
}
Log ""

# --- amdfendr / amdfendrmgr .sys files (Tier 2 - disable only) ---
Log "--- [TIER 2] AMD Crash Defender .sys files ---"

$amdfendrSysPatterns = @(
    @{ Dir = "C:\WINDOWS\System32\drivers"; Filter = "amdfendr*.sys" },
    @{ Dir = "C:\WINDOWS\System32\drivers"; Filter = "amdfendrmgr*.sys" }
)

foreach ($entry in $amdfendrSysPatterns) {
    $sysFiles = Get-ChildItem -Path $entry.Dir -Filter $entry.Filter -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq ".sys" }

    foreach ($f in $sysFiles) {
        $script:anyAction = $true
        Log "  [FOUND] $($f.FullName) - $($f.LastWriteTime)"
        takeown /f $f.FullName | Out-Null
        icacls $f.FullName /grant "administrators:F" | Out-Null
        $newName = $f.Name -replace "\.sys$", ".sys.disabled_$dateStamp"
        try {
            Rename-Item $f.FullName $newName -ErrorAction Stop
            Log "    Renamed to: $newName"
        } catch {
            Log "    [WARN] Could not rename (may be loaded): $_"
            Log "    Service disabled above - will not load on next boot"
        }
    }

    $already = Get-ChildItem -Path $entry.Dir -Filter ($entry.Filter -replace "\*\.sys", "*.disabled*") -ErrorAction SilentlyContinue
    foreach ($f in $already) {
        Log "  [SKIP]  Already disabled: $($f.Name)"
    }
}
Log ""

# ============================================================
# SECTION 2 - RYZENMASTER KERNEL DRIVERS
# Tier 2: stop + disable, no delete (INF-registered drivers)
# ============================================================

Log "--- [TIER 2] RyzenMaster kernel services ---"

$knownBadPatterns = @(
    "*ryzenmaster*"
)

foreach ($pattern in $knownBadPatterns) {
    $drivers = Get-WmiObject Win32_SystemDriver | Where-Object {
        $_.Name -like $pattern -or $_.PathName -like $pattern
    }

    if (-not $drivers) {
        Log "  [OK] No services matching '$pattern' found."
    } else {
        foreach ($drv in $drivers) {
            $script:anyAction = $true
            Log "  [FOUND] $($drv.Name)"
            Log "    State:   $($drv.State)"
            Log "    Path:    $($drv.PathName)"
            Log "    StartMode: $($drv.StartMode)"

            $stopResult = sc.exe stop $drv.Name 2>&1
            Log "    Stop:    $($stopResult -join ' ')"

            $cfgResult = sc.exe config $drv.Name start= disabled 2>&1
            Log "    Disable: $($cfgResult -join ' ')"
            Log "    [NOTE] Service entry retained - re-enable via sc.exe config $($drv.Name) start= demand"
        }
    }
}
Log ""

# --- RyzenMaster .sys files (Tier 2 - disable only) ---
Log "--- [TIER 2] RyzenMaster .sys files ---"

$knownBadSysPatterns = @(
    @{ Dir = "C:\WINDOWS\System32\drivers"; Filter = "AMDRyzenMaster*.sys" },
    @{ Dir = "C:\WINDOWS\System32";         Filter = "AMDRyzenMaster*.sys" }
)

foreach ($entry in $knownBadSysPatterns) {
    $sysFiles = Get-ChildItem -Path $entry.Dir -Filter $entry.Filter -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq ".sys" }

    foreach ($f in $sysFiles) {
        $script:anyAction = $true
        Log "  [FOUND] $($f.FullName) - $($f.LastWriteTime)"
        takeown /f $f.FullName | Out-Null
        icacls $f.FullName /grant "administrators:F" | Out-Null
        $newName = $f.Name -replace "\.sys$", ".sys.disabled_$dateStamp"
        try {
            Rename-Item $f.FullName $newName -ErrorAction Stop
            Log "    Renamed to: $newName"
        } catch {
            Log "    [WARN] Could not rename (may be loaded): $_"
            Log "    Service disabled above - will not load on next boot"
        }
    }

    $already = Get-ChildItem -Path $entry.Dir -Filter ($entry.Filter -replace "\*\.sys", "*.disabled*") -ErrorAction SilentlyContinue
    foreach ($f in $already) {
        Log "  [SKIP]  Already disabled: $($f.Name)"
    }
}
Log ""

# ============================================================
# SECTION 3 - AMD USERSpace SERVICES
# ============================================================

Log "--- [TIER 1] AMD External Events Utility ---"
Log "  FreeSync / display hotplug / AMD hotkeys. Zero value on AI workload."
Log "  To re-enable: sc.exe config AMDExternalEventsUtility start= demand"

$amdExtSvc = "AMDExternalEventsUtility"
$state = sc.exe query $amdExtSvc 2>&1
if ($state -match "does not exist") {
    Log "  [OK] $amdExtSvc service not found."
} else {
    $stopResult = sc.exe stop $amdExtSvc 2>&1
    Log "  [STOP] $amdExtSvc : $($stopResult -join ' ')"
    $cfgResult = sc.exe config $amdExtSvc start= disabled 2>&1
    Log "  [DISABLE] $amdExtSvc : $($cfgResult -join ' ')"
    $script:anyAction = $true
}
Log ""

Log "--- [TIER 3 - MONITOR] AmdPpkg / AmdPpkgSvc ---"
Log "  Delivers AMD-tuned power profiles to 6900HS."
Log "  Do not touch - this serves the AI agent workload."
Log "  Skipping action."
Log ""

# ============================================================
# SECTION 4 - ASUS USERSpace SERVICES (Tier 1 - stop + delete)
# ============================================================

Log "--- [TIER 1] ASUS userspace services (stop + delete) ---"

$tier1AsusServices = @(
    "ASUSSystemAnalysis",
    "ASUSSystemDiagnosis",
    "AsusAppService",
    "ASUSSoftwareManager",
    "ASUSSwitch"
)

foreach ($svc in $tier1AsusServices) {
    $state = sc.exe query $svc 2>&1
    if ($state -match "does not exist") {
        Log "  [OK] $svc not found."
    } else {
        $script:anyAction = $true
        Log "  [FOUND] $svc"
        $stopResult = sc.exe stop $svc 2>&1
        Log "  [STOP] $svc : $($stopResult -join ' ')"
        $cfgResult = sc.exe config $svc start= disabled 2>&1
        Log "  [DISABLE] $svc : $($cfgResult -join ' ')"
        $delResult = sc.exe delete $svc 2>&1
        Log "  [DELETE] $svc : $($delResult -join ' ')"
    }
}
Log ""

# ============================================================
# SECTION 5 - ASUS KERNEL DRIVERS (Tier 2 - disable, no delete)
# ============================================================

Log "--- [TIER 2] ASUS kernel services (stop + disable, no delete) ---"
Log "  AsusSAIO: same driver family as AsUpIO.sys - documented BSOD history"
Log "  ROGKB: already dead - formalizing Disabled state"
Log "  ASUSOptimization: Fn hotkey action executor - Tier 2 (no brightness/fan hotkeys used)"

$tier2AsusKernel = @(
    "AsusSAIO",
    "ROGKB",
    "ASUSOptimization"
)

foreach ($svc in $tier2AsusKernel) {
    $state = sc.exe query $svc 2>&1
    if ($state -match "does not exist") {
        Log "  [OK] $svc not found."
    } else {
        $stopResult = sc.exe stop $svc 2>&1
        Log "  [STOP] $svc : $($stopResult -join ' ')"
        $cfgResult = sc.exe config $svc start= disabled 2>&1
        Log "  [DISABLE] $svc : $($cfgResult -join ' ')"
        Log "  [NOTE] Service entry retained - re-enable via sc.exe config $svc start= demand"
        $script:anyAction = $true
    }
}
Log ""

# --- ATKWMIACPIIO.sys (Tier 3 - Monitor only) ---
Log "--- [TIER 3 - MONITOR] ATKWMIACPIIO.sys ---"
Log "  Fn key ACPI event interception."
Log "  Do not touch - removing kills brightness/fan hotkeys."
Log "  Skipping action."
Log ""

# ============================================================
# SECTION 6 - PNP DEVICE NODES (RyzenMaster ghost nodes)
# ============================================================

Log "--- PnP device nodes ---"

$pnpNodes = Get-PnpDevice | Where-Object { $_.InstanceId -like "*RyzenMaster*" }
if (-not $pnpNodes) {
    Log "  [OK] No RyzenMaster PnP device nodes found."
} else {
    foreach ($node in $pnpNodes) {
        $script:anyAction = $true
        Log "  [FOUND] $($node.FriendlyName) - $($node.Status) - $($node.InstanceId)"
        Log "  ACTION NEEDED: Remove via Device Manager (View > Show Hidden Devices)"
    }
}
Log ""

# ============================================================
# ACTION SUMMARY
# ============================================================

Log "--- Action Summary ---"
if ($anyAction) {
    Log "  [!] Components were found and neutralized. Review output above."
    Log "      Reboot recommended. Re-run after reboot to confirm clean state."
} else {
    Log "  [OK] No problem components found."
}
Log ""

# Save action log
$actionLines | Out-File -FilePath $logPath -Encoding UTF8
Log "Action log saved: $logPath"


# ============================================================
# SECTION 7 - STATE DUMP (full snapshot for incongruency review)
# ============================================================

Write-Host ""
Write-Host "--- Building state dump for incongruency review ---"

Dump "=== SERVICE STATE DUMP ==="
Dump "Generated: $timestamp"
Dump "Compare this file against a pre-update dump to catch renamed or new problem drivers."
Dump "Key things to look for:"
Dump "  - New entries in 'Running kernel drivers' that were not there before"
Dump "  - Kernel drivers with paths outside C:\WINDOWS\System32\drivers\ (suspicious)"
Dump "  - Recently modified .sys files (LastWriteTime matching the update date)"
Dump "  - New Device Manager errors (ERROR or DEGRADED status)"
Dump "  - New AMD/ASUS services that are Running or set to Auto start"
Dump ""

# All registered kernel drivers
Dump "--- All registered kernel drivers (name / state / startmode / path) ---"
Get-WmiObject Win32_SystemDriver |
    Sort-Object Name |
    ForEach-Object {
        Dump ("  {0,-50} {1,-10} {2,-12} {3}" -f $_.Name, $_.State, $_.StartMode, $_.PathName)
    }
Dump ""

# Running kernel drivers only
Dump "--- Running kernel drivers only ---"
Get-WmiObject Win32_SystemDriver | Where-Object { $_.State -eq "Running" } |
    Sort-Object Name |
    ForEach-Object {
        Dump ("  {0,-50} {1}" -f $_.Name, $_.PathName)
    }
Dump ""

# Kernel drivers NOT in standard path (potential anomaly)
Dump "--- Kernel drivers with non-standard paths (NOT in \System32\drivers\) ---"
$nonStandard = Get-WmiObject Win32_SystemDriver | Where-Object {
    $_.PathName -notlike "*\System32\drivers\*" -and
    $_.PathName -notlike "*\SystemRoot\System32\drivers\*" -and
    $_.PathName -ne $null -and $_.PathName -ne ""
}
if ($nonStandard) {
    $nonStandard | Sort-Object Name | ForEach-Object {
        Dump ("  [NON-STANDARD] {0,-45} {1,-10} {2}" -f $_.Name, $_.State, $_.PathName)
    }
} else {
    Dump "  [OK] All registered kernel drivers are in standard paths."
}
Dump ""

# Recently modified .sys files (last 14 days)
Dump "--- .sys files modified in last 14 days (system32\drivers + system32) ---"
$cutoff = (Get-Date).AddDays(-14)
$recentSys = @()
foreach ($dir in @("C:\WINDOWS\System32\drivers", "C:\WINDOWS\System32")) {
    $recentSys += Get-ChildItem -Path $dir -Filter "*.sys" -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -gt $cutoff }
}
if ($recentSys) {
    $recentSys | Sort-Object LastWriteTime -Descending | ForEach-Object {
        Dump ("  {0}  {1}" -f $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm"), $_.FullName)
    }
} else {
    Dump "  None found in last 14 days."
}
Dump ""

# Device Manager errors
Dump "--- Device Manager: ERROR or DEGRADED devices ---"
$badDevices = Get-PnpDevice | Where-Object { $_.Status -eq "Error" -or $_.Status -eq "Degraded" }
if ($badDevices) {
    $badDevices | Sort-Object Status | ForEach-Object {
        Dump ("  [{0}] {1}" -f $_.Status, $_.InstanceId)
        Dump ("         {0}" -f $_.FriendlyName)
    }
} else {
    Dump "  [OK] No ERROR or DEGRADED devices found."
}
Dump ""

# AMD and ASUS services inventory
Dump "--- AMD and ASUS services inventory (all) ---"
Dump "  Review for new entries after updates. Running + Auto = worth scrutinizing."
Get-WmiObject Win32_SystemDriver | Where-Object {
    $_.Name -like "*amd*" -or $_.Name -like "*asus*" -or $_.Name -like "*rog*"
} | Sort-Object Name | ForEach-Object {
    Dump ("  {0,-50} {1,-10} {2,-12} {3}" -f $_.Name, $_.State, $_.StartMode, $_.PathName)
}
Dump ""

Get-Service | Where-Object {
    $_.Name -like "*amd*" -or $_.Name -like "*asus*" -or $_.Name -like "*rog*"
} | Sort-Object Name | ForEach-Object {
    Dump ("  [SVC] {0,-45} {1,-10} {2}" -f $_.Name, $_.Status, $_.StartType)
}
Dump ""

# Tier 3 status check (informational only)
Dump "--- Tier 3 Monitor status (informational) ---"
$tier3 = @("AmdPpkg", "AmdPpkgSvc", "ATKWMIACPIIO")
foreach ($svc in $tier3) {
    $svcObj = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($svcObj) {
        Dump ("  [MONITOR] {0,-45} {1,-10} {2}" -f $svcObj.Name, $svcObj.Status, $svcObj.StartType)
    } else {
        Dump ("  [MONITOR] {0,-45} {1,-10} {2}" -f $svc, "Not Found", "N/A")
    }
}
Dump ""

# Save dump
$dumpLines | Out-File -FilePath $dumpPath -Encoding UTF8
Write-Host "State dump saved: $dumpPath"
Write-Host ""
Write-Host "Done. Both files written to C:\Users\edwar\"
