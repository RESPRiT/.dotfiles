#requires -Version 7.0
# Windows installer for the dotfiles powershell/ side. Counterpart to ../install.sh.
# Idempotent: safe to re-run. Symlinks the profile, installs tools via winget,
# tracks declined prompts in ../.state/decisions (shared with install.sh).

[CmdletBinding()]
param(
    # Re-prompt every optional install by clearing stored "no" decisions.
    # Already-installed checks still skip, so the script stays idempotent.
    [switch]$Fresh
)

$ErrorActionPreference = 'Stop'

# Colors mirror install.sh's ANSI palette so output looks consistent.
$Esc          = [char]27
$PromptColor  = "${Esc}[1;38;5;117m"  # bold light blue
$YesColor     = "${Esc}[1;38;5;120m"  # light green
$NColor       = "${Esc}[1;38;5;210m"  # light red
$SkipColor    = "${Esc}[38;5;240m"    # dark grey
$Reset        = "${Esc}[0m"

$Dotfiles = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
$StateDir = Join-Path $Dotfiles '.state'
$DecisionsFile = Join-Path $StateDir 'decisions'
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

if ($Fresh -and (Test-Path -LiteralPath $DecisionsFile)) {
    Remove-Item -LiteralPath $DecisionsFile -Force
    Write-Host "${PromptColor}--fresh: cleared stored decisions${Reset}"
}

function Skip-Msg([string]$Msg) { Write-Host "${SkipColor}${Msg}${Reset}" }

function Was-Declined([string]$Key) {
    if (-not (Test-Path -LiteralPath $DecisionsFile)) { return $false }
    return (Get-Content -LiteralPath $DecisionsFile) -contains $Key
}

function Record-Decline([string]$Key) {
    if (Was-Declined $Key) { return }
    Add-Content -LiteralPath $DecisionsFile -Value $Key
}

# y/[N] prompt that records "no" so we don't re-ask declined items on every run.
function Confirm-YN([string]$Prompt, [string]$Key) {
    if (Was-Declined $Key) { Skip-Msg "$Key already declined"; return $false }
    $ans = Read-Host "${PromptColor}${Prompt} y/${NColor}[N]${PromptColor}${Reset}"
    if ($ans -match '^[Yy]$') {
        Write-Host "${YesColor}(Selected y)${Reset}"
        return $true
    }
    Record-Decline $Key
    Skip-Msg "$Key declined"
    return $false
}

# Symlink with idempotent semantics matching install.sh's link():
#   - already-correct symlink:    skip
#   - wrong symlink:              replace
#   - real file at destination:   move to <dst>.bak (error if .bak exists)
function Link([string]$Src, [string]$Dst) {
    $item = Get-Item -LiteralPath $Dst -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq 'SymbolicLink' -and $item.Target -eq $Src) {
        Skip-Msg "$Dst already linked"
        return
    }
    if ($item -and $item.LinkType -eq 'SymbolicLink') {
        Remove-Item -LiteralPath $Dst -Force
    } elseif ($item) {
        $bak = "$Dst.bak"
        if (Test-Path -LiteralPath $bak) {
            throw "${bak} already exists. Reconcile manually before installing."
        }
        Write-Host "Backing up existing $Dst -> $bak"
        Move-Item -LiteralPath $Dst -Destination $bak
    }
    New-Item -ItemType SymbolicLink -Path $Dst -Target $Src -Force | Out-Null
    Write-Host "Linked $Dst -> $Src"
}

# Like Link, but if a real file exists at $Dst on first install, move it into
# $Local instead of backing up to .bak. Seeds an empty $Local if missing.
# Mirrors install.sh's link_shell() — used for files that source a sibling
# *.local for per-machine overrides.
function Link-Shell([string]$Src, [string]$Dst, [string]$Local) {
    $item = Get-Item -LiteralPath $Dst -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq 'SymbolicLink' -and $item.Target -eq $Src) {
        Skip-Msg "$Dst already linked"
        return
    }
    if ($item -and $item.LinkType -eq 'SymbolicLink') {
        Remove-Item -LiteralPath $Dst -Force
    } elseif ($item) {
        if (Test-Path -LiteralPath $Local) {
            throw "$Local already exists. Remove it manually before installing."
        }
        Move-Item -LiteralPath $Dst -Destination $Local
        Write-Host "Moved existing $Dst -> $Local"
    }
    New-Item -ItemType SymbolicLink -Path $Dst -Target $Src -Force | Out-Null
    Write-Host "Linked $Dst -> $Src"
    if (-not (Test-Path -LiteralPath $Local)) {
        '# Machine-specific PowerShell configuration for this host' | Set-Content -LiteralPath $Local
        Write-Host "Created $Local"
    }
}

# Self-elevate if we can't create symlinks (no Developer Mode, not admin).
# Symlinks are the only operation here that needs admin; everything else
# (winget per-user installs, registry under HKCU) runs fine as the user.
function Test-CanSymlink {
    $probe = Join-Path $env:TEMP "dotfiles-symlink-probe-$(Get-Random)"
    $target = Join-Path $env:TEMP "dotfiles-symlink-target-$(Get-Random).txt"
    'probe' | Set-Content -LiteralPath $target
    try {
        New-Item -ItemType SymbolicLink -Path $probe -Target $target -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $probe, $target -Force
        return $true
    } catch {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        return $false
    }
}

if (-not (Test-CanSymlink)) {
    Write-Host "${PromptColor}Symlink creation needs admin (Developer Mode is off). Re-launching elevated...${Reset}"
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if ($Fresh) { $argList += '-Fresh' }
    Start-Process pwsh -Verb RunAs -Wait -ArgumentList $argList
    return
}

# === PowerShell profile ===
$profileDir = Split-Path $PROFILE.CurrentUserAllHosts -Parent
New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
Link-Shell `
    (Join-Path $Dotfiles 'powershell\profile.ps1') `
    $PROFILE.CurrentUserAllHosts `
    (Join-Path $profileDir 'profile.local.ps1')

# === winget tool installs ===
function Install-Winget([string]$DisplayName, [string]$Id, [string]$DeclineKey, [string]$ProbeCommand) {
    if (Get-Command $ProbeCommand -ErrorAction SilentlyContinue) {
        Skip-Msg "$DisplayName already installed"
        return
    }
    if (-not (Confirm-YN "Install $DisplayName?" $DeclineKey)) { return }
    $proc = Start-Process winget `
        -ArgumentList @('install','--id',$Id,'--exact','--silent','--accept-source-agreements','--accept-package-agreements') `
        -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Host "${NColor}winget install $Id failed (exit $($proc.ExitCode))${Reset}"
        return
    }
    Write-Host "Installed $DisplayName"
}

Install-Winget -DisplayName 'zoxide'  -Id 'ajeetdsouza.zoxide' -DeclineKey 'zoxide'  -ProbeCommand 'zoxide'
Install-Winget -DisplayName 'atuin'   -Id 'Atuinsh.Atuin'      -DeclineKey 'atuin'   -ProbeCommand 'atuin'
Install-Winget -DisplayName 'neovim'  -Id 'Neovim.Neovim'      -DeclineKey 'neovim'  -ProbeCommand 'nvim'
Install-Winget -DisplayName 'gh CLI'  -Id 'GitHub.cli'         -DeclineKey 'gh'      -ProbeCommand 'gh'
Install-Winget -DisplayName 'eza'     -Id 'eza-community.eza'  -DeclineKey 'eza'     -ProbeCommand 'eza'

# === Seed migration tracker so post-merge.sh doesn't replay old migrations
# the first time someone pulls on a fresh Windows clone. We don't run the
# bash migrations from here — they're POSIX and most aren't relevant on
# Windows (e.g. tpm = tmux package manager).
$migrated = Join-Path $StateDir 'migrated'
if (-not (Test-Path -LiteralPath $migrated)) {
    $maxN = 0
    $migrationsDir = Join-Path $Dotfiles 'migrations'
    if (Test-Path -LiteralPath $migrationsDir) {
        Get-ChildItem -LiteralPath $migrationsDir -Filter '*.sh' | ForEach-Object {
            if ($_.Name -match '^(\d+)-') {
                $n = [int]$matches[1]
                if ($n -gt $maxN) { $maxN = $n }
            }
        }
    }
    Set-Content -LiteralPath $migrated -Value $maxN
    Write-Host "Seeded $migrated to $maxN (skipping bash migrations on Windows)"
}

Write-Host ""
Write-Host "Done! Machine-specific config goes in $profileDir\profile.local.ps1"
Write-Host "Reload this session: . `$PROFILE  (or open a new pwsh)"
