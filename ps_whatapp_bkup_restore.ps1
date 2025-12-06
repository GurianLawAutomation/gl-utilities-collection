<#
.SYNOPSIS
  Backup and restore WhatsApp Desktop data on Windows.

.DESCRIPTION
  - Supports:
      * Microsoft Store version
        %LOCALAPPDATA%\Packages\5319275A.WhatsAppDesktop_cv1g1gvanyjgm
      * Standalone EXE version
        %APPDATA%\WhatsApp

  - Modes:
      * Backup (default)   : Creates timestamped backup directory
      * Restore            : Restores from a chosen or latest backup

.PARAMETER Action
  Backup or Restore. Default: Backup

.PARAMETER BackupRoot
  Root folder for backups. Default: $env:USERPROFILE\WhatsAppBackup

.PARAMETER BackupSet
  When restoring, specify a particular backup folder name (e.g. 20251205-215955).
  If omitted in Restore mode, the script uses the latest backup set.

.EXAMPLES
  # Run a backup with defaults
  .\Whatsapp-BackupRestore.ps1

  # Explicit backup root
  .\Whatsapp-BackupRestore.ps1 -Action Backup -BackupRoot "D:\Backups\WhatsApp"

  # Restore from latest backup
  .\Whatsapp-BackupRestore.ps1 -Action Restore

  # Restore a specific backup set
  .\Whatsapp-BackupRestore.ps1 -Action Restore -BackupSet "20251205-215955"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Backup', 'Restore')]
    [string]$Action = 'Backup',

    [Parameter(Mandatory = $false)]
    [string]$BackupRoot = "$env:USERPROFILE\WhatsAppBackup",

    [Parameter(Mandatory = $false)]
    [string]$BackupSet
)

# --- Config: Known WhatsApp locations ---
$StorePath    = Join-Path $env:LOCALAPPDATA 'Packages\5319275A.WhatsAppDesktop_cv1g1gvanyjgm'
$StandalonePath = Join-Path $env:APPDATA 'WhatsApp'

function Write-Info($msg) {
    Write-Host "[*] $msg"
}
function Write-Warn($msg) {
    Write-Host "[!] $msg" -ForegroundColor Yellow
}
function Write-Err($msg) {
    Write-Host "[X] $msg" -ForegroundColor Red
}

function Test-RobocopyAvailable {
    $rc = Get-Command robocopy -ErrorAction SilentlyContinue
    return -not -not $rc
}

function Copy-WithBestEffort {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination
    )

    if (-not (Test-Path $Source)) {
        Write-Warn "Source path does not exist: $Source"
        return
    }

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }

    if (Test-RobocopyAvailable) {
        Write-Info "Using robocopy to copy: '$Source' -> '$Destination'"
        $null = robocopy $Source $Destination /MIR /COPYALL /R:1 /W:1
    } else {
        Write-Info "robocopy not found. Falling back to Copy-Item (no ACL mirroring)."
        Copy-Item -Path $Source\* -Destination $Destination -Recurse -Force
    }
}

function Get-LatestBackup {
    param(
        [Parameter(Mandatory=$true)][string]$Root
    )

    if (-not (Test-Path $Root)) {
        return $null
    }

    $dirs = Get-ChildItem -Path $Root -Directory | Sort-Object Name
    if (-not $dirs) {
        return $null
    }

    return $dirs[-1]  # last one (latest timestamp by name)
}

function Stop-WhatsAppProcesses {
    Write-Info "Stopping WhatsApp processes if running..."
    $procNames = @('WhatsApp', 'WhatsAppBeta', 'WhatsAppDesktop')
    foreach ($p in $procNames) {
        Stop-Process -Name $p -ErrorAction SilentlyContinue
    }
}

function Backup-WhatsApp {
    param(
        [Parameter(Mandatory=$true)][string]$Root
    )

    if (-not (Test-Path $Root)) {
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $Root $timestamp

    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Write-Info "Created backup set: $backupDir"

    $somethingBackedUp = $false

    if (Test-Path $StorePath) {
        Write-Info "Detected WhatsApp Microsoft Store installation."
        $dest = Join-Path $backupDir 'StoreApp'
        Copy-WithBestEffort -Source $StorePath -Destination $dest
        $somethingBackedUp = $true
    } else {
        Write-Warn "WhatsApp Store path not found: $StorePath"
    }

    if (Test-Path $StandalonePath) {
        Write-Info "Detected WhatsApp standalone EXE installation."
        $dest = Join-Path $backupDir 'Standalone'
        Copy-WithBestEffort -Source $StandalonePath -Destination $dest
        $somethingBackedUp = $true
    } else {
        Write-Warn "WhatsApp standalone path not found: $StandalonePath"
    }

    if (-not $somethingBackedUp) {
        Write-Err "No WhatsApp data directories were found to back up. Aborting."
        Remove-Item -Recurse -Force $backupDir
        return
    }

    # Optionally compress backup set into a single zip
    $zipPath = "$backupDir.zip"
    Write-Info "Compressing backup to: $zipPath"
    try {
        Compress-Archive -Path $backupDir\* -DestinationPath $zipPath -Force
        Write-Info "Backup complete. Directory: $backupDir  |  Archive: $zipPath"
    } catch {
        Write-Warn "Failed to create ZIP archive: $($_.Exception.Message)"
        Write-Warn "Backup directory still exists here: $backupDir"
    }
}

function Restore-WhatsApp {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$false)][string]$SetName
    )

    if ($SetName) {
        $backupDir = Join-Path $Root $SetName
        if (-not (Test-Path $backupDir)) {
            Write-Err "Specified BackupSet not found: $backupDir"
            return
        }
    } else {
        $latest = Get-LatestBackup -Root $Root
        if (-not $latest) {
            Write-Err "No backup sets found under $Root"
            return
        }
        $backupDir = $latest.FullName
        $SetName = $latest.Name
        Write-Info "Using latest backup set: $SetName"
    }

    Stop-WhatsAppProcesses

    $storeBackup = Join-Path $backupDir 'StoreApp'
    $standaloneBackup = Join-Path $backupDir 'Standalone'

    if (-not (Test-Path $storeBackup) -and -not (Test-Path $standaloneBackup)) {
        Write-Err "Backup set does not contain StoreApp or Standalone folders: $backupDir"
        return
    }

    # Store current data as .old in case you want to revert
    if (Test-Path $StorePath) {
        $storeOld = "${StorePath}.old-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Info "Renaming existing Store data to: $storeOld"
        Rename-Item -Path $StorePath -NewName $storeOld
    }
    if (Test-Path $StandalonePath) {
        $standaloneOld = "${StandalonePath}.old-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Info "Renaming existing Standalone data to: $standaloneOld"
        Rename-Item -Path $StandalonePath -NewName $standaloneOld
    }

    if (Test-Path $storeBackup) {
        Write-Info "Restoring Store WhatsApp data..."
        Copy-WithBestEffort -Source $storeBackup -Destination $StorePath
    } else {
        Write-Warn "No StoreApp backup found in set: $SetName"
    }

    if (Test-Path $standaloneBackup) {
        Write-Info "Restoring Standalone WhatsApp data..."
        Copy-WithBestEffort -Source $standaloneBackup -Destination $StandalonePath
    } else {
        Write-Warn "No Standalone backup found in set: $SetName"
    }

    Write-Info "Restore completed from backup set: $SetName"
    Write-Info "You can now reinstall / start WhatsApp Desktop."
}

# --- Main flow ---

Write-Info "WhatsApp Backup/Restore Script"
Write-Info "Action     : $Action"
Write-Info "BackupRoot : $BackupRoot"
if ($BackupSet) { Write-Info "BackupSet  : $BackupSet" }

switch ($Action) {
    'Backup' {
        Backup-WhatsApp -Root $BackupRoot
    }
    'Restore' {
        Restore-WhatsApp -Root $BackupRoot -SetName $BackupSet
    }
    default {
        Write-Err "Unknown Action: $Action"
    }
}
