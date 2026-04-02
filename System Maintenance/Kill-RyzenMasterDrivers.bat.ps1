#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Post-update driver maintenance script for ROG Flow X13 (Work_laptop).
    Run after any AMD, ASUS, or Windows update that touches drivers.

.DESCRIPTION
    This is a living repository of driver/service fixes for services that
    recur after updates. Add new problem drivers here as they are discovered.
    Do not create separate scripts — keep everything here.

    OUTPUTS (per run, timestamped):
      1. Action log  — what was found and killed
      2. State dump  — full kernel driver/service snapshot for incongruency review

    WHY THE DUMP EXISTS:
    AMD/ASUS/Microsoft can rename problem services on future updates (e.g., V31→V32,
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
#>

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$dateStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath  = "C:\Users\edwar\ryzenmaster_kill_log_$dateStamp.txt"
$dumpPath = "C:\Users\edwar\driver_state_dump_$dateStamp.txt"
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
# SECTION 1 — TARGETED KILLS (known problem drivers by name)
# Add new entries here as new problem drivers are discovered.
# ============================================================

Log "=== RyzenMaster Driver Kill Script ==="
Log "Run at: $timestamp"
Log "Action log:  $logPath"
Log "State dump:  $dumpPath"
Log ""

# --- Known problem service name patterns ---
# Extend this list when new problem drivers are identified.
$knownBadPatterns = @(
    "*ryzenmaster*"
    # Add future patterns here, e.g.:
    # "*amdpowerprofile*"
    # "*asusdriver*"
)

Log "--- [TARGETED] Checking for known problem kernel services ---"

foreach ($pattern in $knownBadPatterns) {
    $drivers = Get-WmiObject Win32_SystemDriver | Where-Object {
        $_.Name -like $pattern -or $_.PathName -like $pattern
    }

    if (-not $drivers) {
        Log "  [OK] No services matching '$pattern' found."
    } else {
        foreach ($drv in $drivers) {
            $anyAction = $true
            Log "  [FOUND] $($drv.Name)"
            Log "    State:   $($drv.State)"
            Log "    Path:    $($drv.PathName)"
            Log "    StartMode: $($drv.StartMode)"

            $stopResult = sc.exe stop $drv.Name 2>&1
            Log "    Stop:    $($stopResult -join ' ')"

            $cfgResult = sc.exe config $drv.Name start= disabled 2>&1
            Log "    Disable: $($cfgResult -join ' ')"

            $delResult = sc.exe delete $drv.Name 2>&1
            Log "    Delete:  $($delResult -join ' ')"
        }
    }
}

Log ""

# --- Known problem .sys file paths ---
# Add new paths here when new problem .sys files are found.
Log "--- [TARGETED] Checking for known problem .sys files ---"

$knownBadSysPatterns = @(
    @{ Dir = "C:\WINDOWS\system32\drivers"; Filter = "AMDRyzenMaster*.sys" },
    @{ Dir = "C:\WINDOWS\system32";         Filter = "AMDRyzenMaster*.sys" }
    # Add future entries here
)

foreach ($entry in $knownBadSysPatterns) {
    $sysFiles = Get-ChildItem -Path $entry.Dir -Filter $entry.Filter -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq ".sys" }

    foreach ($f in $sysFiles) {
        $anyAction = $true
        Log "  [FOUND] $($f.FullName) - $($f.LastWriteTime)"
        takeown /f $f.FullName | Out-Null
        icacls $f.FullName /grant "administrators:F" | Out-Null
        $newName = $f.Name -replace "\.sys$", ".sys.disabled_$dateStamp"
        try {
            Rename-Item $f.FullName $newName -ErrorAction Stop
            Log "    Renamed to: $newName"
        } catch {
            Log "    [ERROR] Could not rename: $_"
        }
    }

    $already = Get-ChildItem -Path $entry.Dir -Filter ($entry.Filter -replace "\*\.sys", "*.disabled*") -ErrorAction SilentlyContinue
    foreach ($f in $already) {
        Log "  [SKIP]  Already disabled: $($f.Name)"
    }
}

Log ""

# --- PnP device nodes ---
Log "--- [TARGETED] Checking for known problem PnP device nodes ---"

$pnpNodes = Get-PnpDevice | Where-Object { $_.InstanceId -like "*RyzenMaster*" }
if (-not $pnpNodes) {
    Log "  [OK] No RyzenMaster PnP device nodes found."
} else {
    foreach ($node in $pnpNodes) {
        $anyAction = $true
        Log "  [FOUND] $($node.FriendlyName) — $($node.Status) — $($node.InstanceId)"
        Log "  ACTION NEEDED: Manually remove via Device Manager (View > Show Hidden Devices)"
    }
}

Log ""

# --- Action summary ---
Log "--- Action Summary ---"
if ($anyAction) {
    Log "  [!] Problem components were found and neutralized. Review output above."
    Log "      Reboot recommended. Re-run after reboot to confirm clean state."
} else {
    Log "  [OK] No known problem drivers or .sys files found."
}
Log ""

# Save action log
$actionLines | Out-File -FilePath $logPath -Encoding UTF8
Log "Action log saved: $logPath"


# ============================================================
# SECTION 2 — STATE DUMP (full snapshot for incongruency review)
# Compare dumps before/after updates to catch renamed/new entries.
# ============================================================

Write-Host ""
Write-Host "--- Building state dump for incongruency review ---"

Dump "=== DRIVER STATE DUMP ==="
Dump "Generated: $timestamp"
Dump "Compare this file against a pre-update dump to catch renamed or new problem drivers."
Dump "Key things to look for:"
Dump "  - New entries in 'Running kernel drivers' that weren't there before"
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
        Dump ("  {0,-45} {1,-10} {2,-12} {3}" -f $_.Name, $_.State, $_.StartMode, $_.PathName)
    }
Dump ""

# Running kernel drivers only
Dump "--- Running kernel drivers only ---"
Get-WmiObject Win32_SystemDriver | Where-Object { $_.State -eq "Running" } |
    Sort-Object Name |
    ForEach-Object {
        Dump ("  {0,-45} {1}" -f $_.Name, $_.PathName)
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
        Dump ("  [NON-STANDARD] {0,-40} {1,-10} {2}" -f $_.Name, $_.State, $_.PathName)
    }
} else {
    Dump "  [OK] All registered kernel drivers are in standard paths."
}
Dump ""

# Recently modified .sys files (last 14 days)
Dump "--- .sys files modified in last 14 days (system32\drivers + system32) ---"
$cutoff = (Get-Date).AddDays(-14)
$recentSys = @()
foreach ($dir in @("C:\WINDOWS\system32\drivers", "C:\WINDOWS\system32")) {
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

# AMD and ASUS services inventory (all, not just bad ones)
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

# Save dump
$dumpLines | Out-File -FilePath $dumpPath -Encoding UTF8
Write-Host "State dump saved: $dumpPath"
Write-Host ""
Write-Host "Done. Both files written to C:\Users\edwar\"
