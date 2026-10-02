# Publishes a Stratlab release: builds the installer, commits and tags the source, pushes it and creates a
# GitHub release with the installer and its checksum attached (that is what the in-app "Update" pill reads).
#   powershell -ExecutionPolicy Bypass -File tools\release.ps1                      # release the version in version.json
#   powershell -ExecutionPolicy Bypass -File tools\release.ps1 -Version 1.0.1       # bump version.json first
#   powershell -ExecutionPolicy Bypass -File tools\release.ps1 -Version 1.0.1 -Notes "Fixed the overlay flicker"
# Needs git and the GitHub CLI signed in once (`gh auth login --web`). Free: winget install Git.Git GitHub.cli
param([string]$Version, [string]$Notes)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
foreach ($tool in 'git', 'gh') { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not installed. winget install Git.Git GitHub.cli" } }
$vj = Get-Content 'version.json' -Raw | ConvertFrom-Json
if (-not $vj.repo) { throw 'version.json has no "repo" (owner/name)' }
# releases can also come from GitHub (Actions > Release) or another computer: stop before building
# anything when GitHub has commits this copy does not, instead of failing halfway at the push
if (Test-Path '.git') {
    git fetch -q origin 2>$null
    $behind = git rev-list --count 'HEAD..origin/main' 2>$null
    if ($LASTEXITCODE -eq 0 -and [int]$behind -gt 0) { throw "GitHub has $behind newer commit(s). Run  git pull --rebase  first, then release again." }
}
if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "version must be x.y.z (got '$Version')" }
    $vj.version = $Version
    $vj | ConvertTo-Json | Set-Content 'version.json' -Encoding ASCII
}
$ver = $vj.version; $tag = "v$ver"
if (git tag -l $tag) { throw "tag $tag already exists; pick a new -Version" }
gh auth status 2>$null | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not signed in: run  gh auth login --web' }
gh auth setup-git 2>$null | Out-Null   # git pushes with the CLI's sign-in, no separate password prompt
if (-not (git config user.name)) { git config --global user.name (gh api user --jq .login) }
if (-not (git config user.email)) { git config --global user.email ((gh api user --jq '.id').Trim() + '+' + (gh api user --jq .login) + '@users.noreply.github.com') }

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build_installer.ps1'); if ($LASTEXITCODE -ne 0) { throw 'build failed' }
$exe = "dist\Stratlab-Setup-$ver.exe"; $sum = "$exe.sha256"
if (-not (Test-Path $exe) -or -not (Test-Path $sum)) { throw "missing $exe or $sum" }

# first run: turn the folder into a repository pointed at GitHub
if (-not (Test-Path '.git')) {
    git init -b main | Out-Null
    git remote add origin "https://github.com/$($vj.repo).git"
}
git add -A
git diff --cached --quiet; if ($LASTEXITCODE -ne 0) { git commit -q -m "Stratlab $tag" -m 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>' }
git tag -a $tag -m "Stratlab $tag"
git push -u origin main; if ($LASTEXITCODE -ne 0) { throw 'push failed' }
git push origin $tag; if ($LASTEXITCODE -ne 0) { throw 'tag push failed' }

if (-not $Notes) { $Notes = "Stratlab $tag. Download Stratlab-Setup-$ver.exe to install or update (Windows may show a SmartScreen warning: More info, Run anyway)." }
gh release create $tag $exe $sum --title "Stratlab $tag" --notes $Notes --latest; if ($LASTEXITCODE -ne 0) { throw 'release failed' }
Write-Host "released ${tag}: https://github.com/$($vj.repo)/releases/tag/$tag"
