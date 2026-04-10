<#
.SYNOPSIS
    Enhanced Automated Sprint — Version-Aware Self-Installer

.DESCRIPTION
    Installs the /enhanced-automated-sprint skill into any Claude Code project.
    Auto-detects BMAD version from _bmad/_config/manifest.yaml and installs
    the matching version of the script.

.PARAMETER Global
    Install to %USERPROFILE%\.claude\ (available in ALL projects).
    Uses .claude\commands\ for BMAD pre-6.2, .claude\skills\ for 6.2+.

.PARAMETER Force
    Overwrite existing installation without prompting

.PARAMETER Uninstall
    Remove the skill

.PARAMETER Version
    Force a specific BMAD version instead of auto-detecting

.PARAMETER List
    List available versions

.EXAMPLE
    ./install-enhanced-sprint.ps1
    # Auto-detect BMAD version and install locally

.EXAMPLE
    ./install-enhanced-sprint.ps1 -Global -Force
    # Force install globally for all projects

.EXAMPLE
    ./install-enhanced-sprint.ps1 -Version 6.2.0
    # Install scripts for a specific BMAD version

.EXAMPLE
    ./install-enhanced-sprint.ps1 -Uninstall
    # Remove the skill from the current project

.EXAMPLE
    irm https://raw.githubusercontent.com/sidtheone/BMAD-OVERRIDE-CLAUDE-SCRIPTS/main/install-enhanced-sprint.ps1 | iex
    # Remote install — downloads and executes the script directly.
    # WARNING: irm | iex bypasses signature verification. Only use with trusted URLs.
    # For production, download and inspect the script first.

.NOTES
    When run via irm | iex, version auto-detection still works but local versioned
    folder lookup is unavailable. Specify -Version explicitly or accept the latest default.
#>

[CmdletBinding()]
param(
    [switch]$Global,
    [switch]$Force,
    [switch]$Uninstall,
    [string]$Version = "",
    [switch]$List
)

$ErrorActionPreference = 'Stop'

$SkillName = "enhanced-automated-sprint"
$SkillFile = "$SkillName.md"
$RepoRaw = "https://raw.githubusercontent.com/sidtheone/BMAD-OVERRIDE-CLAUDE-SCRIPTS/main"
$CompatUrl = "$RepoRaw/compatibility.json"

# --- Helper Functions ---

function Find-ProjectRoot {
    $current = Get-Item -LiteralPath (Get-Location)
    while ($null -ne $current) {
        $claudeDir = Join-Path $current.FullName ".claude"
        $bmadDir = Join-Path $current.FullName "_bmad"
        if ((Test-Path $claudeDir) -or (Test-Path $bmadDir)) {
            return $current.FullName
        }
        $parent = $current.Parent
        if ($null -eq $parent -or $parent.FullName -eq $current.FullName) {
            break
        }
        $current = $parent
    }
    return $null
}

function Get-BmadVersion {
    param([string]$ProjectRoot)

    $manifest = Join-Path (Join-Path (Join-Path $ProjectRoot "_bmad") "_config") "manifest.yaml"
    if (-not (Test-Path $manifest)) {
        return ""
    }

    $content = Get-Content $manifest -Raw
    if ($content -match 'version:\s*[''"]?(\d+\.\d+\.\d+)[''"]?') {
        return $matches[1]
    }
    return ""
}

function Test-VersionGte {
    param([string]$V1, [string]$V2)
    return ([version]$V1 -ge [version]$V2)
}

function Find-BestVersion {
    param([string]$Target, [PSCustomObject]$Compat)

    if ([string]::IsNullOrEmpty($Target)) {
        return $Compat.latest
    }

    $versions = $Compat.versions.PSObject.Properties.Name

    # Exact match
    if ($Target -in $versions) {
        return $Target
    }

    # Find closest lower version
    $targetVer = [version]$Target
    $lower = $versions |
        Where-Object { [version]$_ -le $targetVer } |
        Sort-Object { [version]$_ } -Descending

    if ($lower) {
        return ($lower | Select-Object -First 1)
    }

    # Fallback to latest
    return $Compat.latest
}

# --- List Mode ---
if ($List) {
    Write-Host "Fetching available versions..."

    $compat = Invoke-RestMethod -Uri $CompatUrl

    Write-Host "Available versions:"
    Write-Host ""

    $latest = $compat.latest
    foreach ($prop in $compat.versions.PSObject.Properties | Sort-Object Name) {
        $ver = $prop.Name
        $info = $prop.Value
        $marker = if ($ver -eq $latest) { " (latest)" } else { "" }
        $scripts = ($info.scripts -join ", ")
        $changelog = $info.changelog

        Write-Host "  $ver$marker"
        Write-Host "    Scripts: $scripts"
        Write-Host "    Changes: $changelog"
        Write-Host ""
    }

    # Also detect local BMAD version if in a project
    $projectRoot = Find-ProjectRoot
    if ($projectRoot) {
        $localVer = Get-BmadVersion -ProjectRoot $projectRoot
        if ($localVer) {
            Write-Host "Your BMAD version: $localVer"
        }
    }
    exit 0
}

# --- Find Project Root ---
if ($Global) {
    $ProjectRoot = ""
} else {
    $ProjectRoot = Find-ProjectRoot
    if (-not $ProjectRoot) {
        Write-Host "Error: Not inside a Claude Code project (no .claude/ or _bmad/ directory found)."
        Write-Host "Run from your project root, or use -Global to install for all projects."
        exit 1
    }
}

# --- Detect BMAD Version ---
if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        Write-Host "Error: Invalid version format '$Version'. Expected X.Y.Z (e.g., 6.2.0)"
        exit 1
    }
    $BmadVersion = $Version
    Write-Host "Using forced version: $BmadVersion"
} elseif ($ProjectRoot) {
    $BmadVersion = Get-BmadVersion -ProjectRoot $ProjectRoot
    if ($BmadVersion) {
        Write-Host "Detected BMAD version: $BmadVersion"
    } else {
        Write-Host "Warning: Could not detect BMAD version (no manifest.yaml found)."
        Write-Host "Will use latest available version."
        $BmadVersion = ""
    }
} else {
    Write-Host "Global install - will use latest available version."
    $BmadVersion = ""
}

# --- Determine Install Architecture ---
$UseSkills = $false
if ($BmadVersion -and (Test-VersionGte $BmadVersion "6.2.0")) {
    $UseSkills = $true
}

# --- Determine Target Directory ---
$HomeDir = $env:USERPROFILE
if (-not $HomeDir) { $HomeDir = $env:HOME }

if ($UseSkills) {
    if ($Global) {
        $TargetDir = Join-Path (Join-Path (Join-Path $HomeDir ".claude") "skills") $SkillName
    } else {
        $TargetDir = Join-Path (Join-Path (Join-Path $ProjectRoot ".claude") "skills") $SkillName
    }
    $TargetPath = Join-Path $TargetDir "SKILL.md"

    # Check for legacy installation
    $LegacyPath = ""
    $legacyCommands = if ($Global) { Join-Path (Join-Path (Join-Path $HomeDir ".claude") "commands") $SkillFile }
                      else { if ($ProjectRoot) { Join-Path (Join-Path (Join-Path $ProjectRoot ".claude") "commands") $SkillFile } else { "" } }
    if ($legacyCommands -and (Test-Path $legacyCommands)) {
        $LegacyPath = $legacyCommands
    }
} else {
    if ($Global) {
        $TargetDir = Join-Path (Join-Path $HomeDir ".claude") "commands"
    } else {
        $TargetDir = Join-Path (Join-Path $ProjectRoot ".claude") "commands"
    }
    $TargetPath = Join-Path $TargetDir $SkillFile
    $LegacyPath = ""
}

# --- Uninstall ---
if ($Uninstall) {
    $removed = $false

    if (Test-Path $TargetPath) {
        Remove-Item $TargetPath
        Write-Host "Removed: $TargetPath"
        # Clean up empty skill directory
        if ($UseSkills -and (Test-Path $TargetDir) -and
            @(Get-ChildItem $TargetDir -Force).Count -eq 0) {
            Remove-Item $TargetDir
        }
        $removed = $true
    }

    if ($LegacyPath -and (Test-Path $LegacyPath)) {
        Remove-Item $LegacyPath
        Write-Host "Removed legacy: $LegacyPath"
        $removed = $true
    }

    if (-not $removed) {
        Write-Host "Not installed at: $TargetPath"
    }
    exit 0
}

# --- Check Existing ---
if ((Test-Path $TargetPath) -and -not $Force) {
    Write-Host "Already installed at: $TargetPath"
    $confirm = Read-Host "Overwrite? [y/N]"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "Cancelled."
        exit 0
    }
}

# --- Create Directory ---
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

# --- Determine Source ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Installed = $false
$MatchVersion = ""

# Try local versioned folder first
if ($ScriptDir -and $BmadVersion) {
    $localVersioned = Join-Path (Join-Path $ScriptDir $BmadVersion) $SkillFile
    if (Test-Path $localVersioned) {
        Copy-Item $localVersioned $TargetPath -Force
        Write-Host "Installed from local ($BmadVersion): $localVersioned"
        $Installed = $true
    }
}

# Try local root fallback
if (-not $Installed -and $ScriptDir) {
    $localRoot = Join-Path $ScriptDir $SkillFile
    if ((Test-Path $localRoot) -and ($localRoot -ne $TargetPath)) {
        Copy-Item $localRoot $TargetPath -Force
        Write-Host "Installed from local (root): $localRoot"
        $Installed = $true
    }
}

# Download from GitHub (version-aware)
if (-not $Installed) {
    Write-Host "Downloading compatibility manifest..."

    $compat = Invoke-RestMethod -Uri $CompatUrl
    $MatchVersion = Find-BestVersion -Target $BmadVersion -Compat $compat

    if (-not $MatchVersion) {
        Write-Host "Error: No compatible version found for BMAD $BmadVersion."
        Write-Host "Run with -List to see available versions."
        exit 1
    }

    if ($BmadVersion -and $MatchVersion -ne $BmadVersion) {
        Write-Host "Note: No exact match for $BmadVersion. Using closest: $MatchVersion"
    }

    $versionedUrl = "$RepoRaw/$MatchVersion/$SkillFile"
    Write-Host "Downloading from: $versionedUrl"

    try {
        Invoke-WebRequest -Uri $versionedUrl -OutFile $TargetPath -UseBasicParsing
    } catch {
        # Versioned file not found, fall back to root
        Write-Host "Versioned file not found, falling back to root..."
        $fallbackUrl = "$RepoRaw/$SkillFile"
        Invoke-WebRequest -Uri $fallbackUrl -OutFile $TargetPath -UseBasicParsing
        Write-Host "Downloaded from: $fallbackUrl (fallback)"
        $MatchVersion = ""
    }

    if ($MatchVersion) {
        Write-Host "Downloaded version $MatchVersion"
    }
}

# --- Verify ---
if (-not (Test-Path $TargetPath)) {
    Write-Host "Error: Installation failed - file not created."
    exit 1
}

# Sanity check — frontmatter present?
$firstLine = Get-Content $TargetPath -First 1
if ($firstLine -ne "---") {
    Write-Host "Warning: File may be corrupted (missing frontmatter). Check: $TargetPath"
    exit 1
}

# --- Success Output ---
Write-Host ""
Write-Host "Installed: $TargetPath"
if ($MatchVersion) {
    $bmadLabel = if ($BmadVersion) { $BmadVersion } else { "latest" }
    Write-Host "Version:   $MatchVersion (for BMAD $bmadLabel)"
}
if ($UseSkills) {
    Write-Host "Format:    .claude/skills/ (BMAD 6.2+)"
} else {
    Write-Host "Format:    .claude/commands/ (pre-6.2)"
}
Write-Host ""
Write-Host "Usage in Claude Code:"
Write-Host "  /enhanced-automated-sprint 5              # All stories in Epic 5"
Write-Host "  /enhanced-automated-sprint 5 5-1 5-2      # Specific stories"
Write-Host "  /enhanced-automated-sprint 5 --parallel 2  # Parallel execution"
Write-Host ""
if ($Global) {
    Write-Host "Scope: Global (available in all projects)"
} else {
    Write-Host "Scope: Project ($ProjectRoot)"
}

# --- Legacy Path Warning ---
if ($LegacyPath -and (Test-Path $LegacyPath)) {
    Write-Host ""
    Write-Host "WARNING: Old installation found at: $LegacyPath" -ForegroundColor Yellow
    Write-Host "  BMAD 6.2+ uses .claude/skills/ instead of .claude/commands/"
    Write-Host "  The old file may shadow the new installation."
    Write-Host "  Remove it with: Remove-Item '$LegacyPath'"
}
