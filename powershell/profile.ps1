# PowerShell profile — counterpart to shellrc/zshrc/bashrc.
# Symlinked to $PROFILE.CurrentUserAllHosts ($HOME\Documents\PowerShell\profile.ps1)
# so it loads in every host (pwsh CLI, ISE, VS Code terminal, etc.).
# Per-machine config goes in profile.local.ps1 next to this file (sourced last).

# Prepend to PATH only if not already present (avoids stacking on reload)
function Add-PathPrepend([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    $sep = [IO.Path]::PathSeparator
    $parts = $env:PATH -split [regex]::Escape($sep)
    if ($parts -notcontains $Dir) { $env:PATH = "$Dir$sep$env:PATH" }
}

# Resolve the dotfiles repo by following the profile symlink, like shellrc does
# with ~/.shellrc. Falls back to ~\.dotfiles if profile isn't a symlink.
$script:DotfilesDir = $null
$_pf = Get-Item -LiteralPath $PROFILE.CurrentUserAllHosts -Force -ErrorAction SilentlyContinue
if ($_pf -and $_pf.LinkType -eq 'SymbolicLink' -and $_pf.Target) {
    $_target = if ([IO.Path]::IsPathRooted($_pf.Target)) { $_pf.Target } else { Join-Path (Split-Path $_pf.FullName -Parent) $_pf.Target }
    $script:DotfilesDir = (Get-Item -LiteralPath (Split-Path $_target -Parent)).Parent.FullName
}
if (-not $script:DotfilesDir) { $script:DotfilesDir = Join-Path $HOME '.dotfiles' }

# === PSReadLine — bash/zsh-like line editing ===
# Pwsh ships an older PSReadLine; prefer the newest installed for predictions
# and modern key handlers. Predictions/list view need a real VT-capable host;
# they error out under output redirection — guard each call so a non-interactive
# child pwsh (e.g. CI, captured stdout) still loads the rest of the profile.
if (Get-Module -ListAvailable PSReadLine) {
    $_psr = Get-Module -ListAvailable PSReadLine | Sort-Object Version -Descending | Select-Object -First 1
    Import-Module PSReadLine -RequiredVersion $_psr.Version
    function _try-psr { try { & $args[0] } catch { } }
    _try-psr { Set-PSReadLineOption -EditMode Emacs }
    _try-psr { Set-PSReadLineOption -PredictionSource HistoryAndPlugin }
    _try-psr { Set-PSReadLineOption -PredictionViewStyle InlineView }
    _try-psr { Set-PSReadLineOption -HistoryNoDuplicates }
    _try-psr { Set-PSReadLineOption -HistorySearchCursorMovesToEnd }
    _try-psr { Set-PSReadLineOption -MaximumHistoryCount 10000 }
    _try-psr { Set-PSReadLineOption -BellStyle None }
    _try-psr { Set-PSReadLineKeyHandler -Key Tab        -Function MenuComplete }
    _try-psr { Set-PSReadLineKeyHandler -Key 'Ctrl+r'   -Function ReverseSearchHistory }
    _try-psr { Set-PSReadLineKeyHandler -Key 'Ctrl+w'   -Function BackwardKillWord }
    _try-psr { Set-PSReadLineKeyHandler -Key UpArrow    -Function HistorySearchBackward }
    _try-psr { Set-PSReadLineKeyHandler -Key DownArrow  -Function HistorySearchForward }
    Remove-Item Function:_try-psr
    Remove-Variable _psr
    # Note: while a menu is active (Tab pressed), Shift+Tab cycles backwards
    # natively — no key handler needed. Older PSReadLine builds lack
    # ReverseMenuComplete as a standalone function.
}

# === Aliases & functions (mirror shellrc) ===
# Prefer eza over Get-ChildItem when available — colored, gridded, humanized.
# `ls` is a built-in alias for Get-ChildItem; replace globally so it's eza too.
if (Get-Command eza -ErrorAction SilentlyContinue) {
    Remove-Item Alias:ls -Force -ErrorAction SilentlyContinue
    function global:ls { eza --group-directories-first @args }
    function ll { eza --group-directories-first -lah --git @args }
    function l  { eza --group-directories-first -l   @args }
} else {
    function ll { Get-ChildItem -Force @args }
    function l  { Get-ChildItem @args }
}
function gs { git status @args }
function path { $env:PATH -split [IO.Path]::PathSeparator }
# *nix-style which: print the resolved path for executables, or kind/name for
# functions/aliases. Multi-resolution prints all matches in PATH order.
function which {
    foreach ($c in (Get-Command @args -All -ErrorAction SilentlyContinue)) {
        if ($c.Source) { $c.Source } else { "$($c.CommandType): $($c.Name) -> $($c.Definition)" }
    }
}
function reload {
    foreach ($p in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost)) {
        if (Test-Path -LiteralPath $p) { . $p }
    }
}

# touch: create empty file, or update mtime if it already exists
function touch {
    foreach ($f in $args) {
        if (Test-Path -LiteralPath $f) { (Get-Item -LiteralPath $f).LastWriteTime = Get-Date }
        else { New-Item -ItemType File -Path $f -Force | Out-Null }
    }
}

# head / tail with -n N (default 10). tail -f follows like the *nix tool.
function head {
    param([int]$n = 10, [Parameter(ValueFromRemainingArguments)][string[]]$Files)
    foreach ($file in $Files) { Get-Content -LiteralPath $file -TotalCount $n }
}
function tail {
    param([int]$n = 10, [switch]$f, [Parameter(ValueFromRemainingArguments)][string[]]$Files)
    foreach ($file in $Files) {
        if ($f) { Get-Content -LiteralPath $file -Tail $n -Wait }
        else    { Get-Content -LiteralPath $file -Tail $n }
    }
}

# tree: prefer eza --tree (colors, .gitignore-aware); fall back to Windows tree.com
function tree {
    if (Get-Command eza -ErrorAction SilentlyContinue) {
        eza --tree --group-directories-first @args
    } else {
        & "$env:SystemRoot\System32\tree.com" @args
    }
}

# Free up `curl` so it calls real curl.exe (in System32) instead of PowerShell's
# Invoke-WebRequest alias, which has totally different syntax than *nix curl.
Remove-Item Alias:curl -Force -ErrorAction SilentlyContinue

function extract {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "extract: '$Path' is not a file"; return
    }
    switch -Regex ($Path) {
        '\.zip$'             { Expand-Archive -LiteralPath $Path -DestinationPath . -Force; break }
        '\.(tar\.gz|tgz)$'   { tar -xzf $Path; break }
        '\.(tar\.bz2|tbz2)$' { tar -xjf $Path; break }
        '\.(tar\.xz|txz)$'   { tar -xJf $Path; break }
        '\.tar$'             { tar -xf $Path; break }
        '\.7z$'              { 7z x $Path; break }
        '\.rar$'             { unrar x $Path; break }
        default              { Write-Error "extract: unsupported format '$Path'" }
    }
}

# === Prompt: user@host cwd(_git_branch_info) > ===
# Mirrors the bash/zsh prompt: light blue local, light green over SSH,
# git branch with dirty marker (210 dirty / 218 main|master / 2 other).
function script:_git_branch_info {
    $branch = & git symbolic-ref --short HEAD 2>$null
    if (-not $branch) { return '' }
    $dirty = ''
    & git diff --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { $dirty = '*' }
    if (-not $dirty) {
        $untracked = & git ls-files --others --exclude-standard 2>$null
        if ($untracked) { $dirty = '*' }
    }
    $color = if ($dirty)                        { 210 }
             elseif ($branch -in 'main','master') { 218 }
             else                                { 2 }
    $esc = [char]27
    return " ${esc}[38;5;${color}m($dirty$branch)${esc}[0m"
}

function global:prompt {
    $u = $env:USERNAME
    $h = $env:COMPUTERNAME
    $userColor = if ($env:SSH_CONNECTION) { 114 } else { 177 }

    $cwd = $PWD.Path
    if ($cwd.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) {
        $cwd = '~' + $cwd.Substring($HOME.Length)
    }
    # Last 2 segments only (mimic zsh %2~). Keep leading '~' or drive root.
    $parts = $cwd -split '[\\/]'
    if ($parts.Count -gt 3) {
        $cwd = ($parts[-2..-1]) -join '\'
    }

    $git = script:_git_branch_info
    $esc = [char]27
    "${esc}[38;5;${userColor}m$u@$h${esc}[0m $cwd$git> "
}

# === Tool inits ===
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    # --cmd cd makes `cd` the smart command (matches `alias cd=z` in shellrc)
    Invoke-Expression (& { (zoxide init powershell --cmd cd | Out-String) })
    function global:.. { z .. }
    function global:... { z ../.. }
}

# posh-git: import for tab completion only (the prompt half is hand-rolled above)
if (Get-Module -ListAvailable posh-git) {
    Import-Module posh-git -ErrorAction SilentlyContinue
}

# === Local override (sibling to symlink, not in repo) ===
$_local = Join-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) 'profile.local.ps1'
if (Test-Path -LiteralPath $_local) { . $_local }
