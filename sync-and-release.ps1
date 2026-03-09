# sync-and-release.ps1
# Syncs with upstream vrcx-team/VRCX, re-applies fork patches, pushes, and builds a release.

param(
    [switch]$BuildRelease,   # Pass -BuildRelease to also run the full build + installer
    [switch]$Publish,        # Pass -Publish to create a GitHub release and upload artifacts (implies -BuildRelease)
    [switch]$Force           # Pass -Force to sync and patch even if no upstream changes
)

if ($Publish) { $BuildRelease = $true }

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$UpstreamUrl  = 'https://github.com/vrcx-team/VRCX.git'
$ForkBranch   = 'master'
$UpstreamRef  = "upstream/$ForkBranch"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Ensure upstream remote exists
# ─────────────────────────────────────────────────────────────────────────────
$remotes = git remote
if ($remotes -notcontains 'upstream') {
    Write-Host "> Adding upstream remote: $UpstreamUrl" -ForegroundColor Cyan
    git remote add upstream $UpstreamUrl
} else {
    Write-Host "> upstream remote already configured" -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Fetch upstream
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "> Fetching upstream..." -ForegroundColor Cyan
git fetch upstream

# ─────────────────────────────────────────────────────────────────────────────
# 3. Check if there are new commits on upstream
# ─────────────────────────────────────────────────────────────────────────────
$localHead    = git rev-parse HEAD
$upstreamHead = git rev-parse $UpstreamRef
$newCommits   = git log --oneline "HEAD..$UpstreamRef"

if (-not $newCommits -and -not $Force) {
    Write-Host "> Already up to date with upstream. Use -Force to re-patch anyway." -ForegroundColor Green
    exit 0
}

if ($newCommits) {
    Write-Host "> New upstream commits:" -ForegroundColor Yellow
    $newCommits | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Merge upstream changes
# ─────────────────────────────────────────────────────────────────────────────
if ($newCommits) {
    Write-Host "> Merging upstream/$ForkBranch..." -ForegroundColor Cyan
    git merge $UpstreamRef --no-edit
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Merge conflict detected. Resolve conflicts manually, then re-run the script." -ForegroundColor Red
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Re-apply fork patches
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "> Verifying / re-applying fork patches..." -ForegroundColor Cyan

$patchApplied = $false

## Patch A: isLocalUserVrcPlusSupporter always returns true
$userJsPath = "src\stores\user.js"
$userJsContent = Get-Content $userJsPath -Raw

# Detect if the patch is already in place
if ($userJsContent -match 'isLocalUserVrcPlusSupporter\s*=\s*computed\(\s*\(\)\s*=>\s*true\s*\)') {
    Write-Host "  [SKIP] $userJsPath – patch already applied" -ForegroundColor Gray
} else {
    Write-Host "  [PATCH] $userJsPath – removing VRC+ gate" -ForegroundColor Yellow
    # Replace the computed expression (handles any variation of the original line)
    $userJsContent = $userJsContent -replace `
        'const isLocalUserVrcPlusSupporter\s*=\s*computed\([^)]*\)(?:\s*\))?;', `
        'const isLocalUserVrcPlusSupporter = computed(() => true);'
    Set-Content $userJsPath $userJsContent -NoNewline -Encoding UTF8
    $patchApplied = $true
}

## Patch B: release channel URLs point to this fork
$settingsPath = "src\shared\constants\settings.js"
$settingsContent = Get-Content $settingsPath -Raw

if ($settingsContent -match 'kikookraft/VRCX') {
    Write-Host "  [SKIP] $settingsPath – patch already applied" -ForegroundColor Gray
} else {
    Write-Host "  [PATCH] $settingsPath – redirecting release channel to fork" -ForegroundColor Yellow

    # Replace Stable branch URLs
    $settingsContent = $settingsContent -replace `
        "urlReleases:\s*'https://api0\.vrcx\.app/releases/stable'", `
        "urlReleases: 'https://api.github.com/repos/kikookraft/VRCX/releases'"
    $settingsContent = $settingsContent -replace `
        "urlLatest:\s*'https://api0\.vrcx\.app/releases/stable/latest'", `
        "urlLatest: 'https://api.github.com/repos/kikookraft/VRCX/releases/latest'"

    # Replace Nightly branch URLs
    $settingsContent = $settingsContent -replace `
        "urlReleases:\s*'https://api0\.vrcx\.app/releases/nightly'", `
        "urlReleases: 'https://api.github.com/repos/kikookraft/VRCX/releases'"
    $settingsContent = $settingsContent -replace `
        "urlLatest:\s*'https://api0\.vrcx\.app/releases/nightly/latest'", `
        "urlLatest: 'https://api.github.com/repos/kikookraft/VRCX/releases/latest'"

    Set-Content $settingsPath $settingsContent -NoNewline -Encoding UTF8
    $patchApplied = $true
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Commit patches if anything changed
# ─────────────────────────────────────────────────────────────────────────────
$dirty = git status --porcelain
if ($dirty) {
    Write-Host "> Committing re-applied patches..." -ForegroundColor Cyan
    git add $userJsPath $settingsPath
    $upstreamVersion = Get-Content Version -Raw | ForEach-Object { $_.Trim() }
    git commit -m "chore: apply fork patches on top of upstream $upstreamVersion"
} elseif ($patchApplied) {
    Write-Host "> Patches applied but nothing to commit (already staged?)" -ForegroundColor Gray
} else {
    Write-Host "> No patch changes - nothing to commit" -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Push to fork
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "> Pushing to origin/$ForkBranch..." -ForegroundColor Cyan
git push origin $ForkBranch
Write-Host "> Push complete." -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────
# 8. Build release (optional — pass -BuildRelease to enable)
# ─────────────────────────────────────────────────────────────────────────────
if (-not $BuildRelease) {
    Write-Host ""
    Write-Host "Sync done. To also build release artifacts, re-run with -BuildRelease." -ForegroundColor Cyan
    exit 0
}

Write-Host "> Starting full release build..." -ForegroundColor Cyan

# Set up VS Dev Shell (required for dotnet build with MSBuild)
$vsWhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vsWhere) {
    $installPath = & $vsWhere -latest -property installationPath
    $devShellDll  = Join-Path $installPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
    Import-Module $devShellDll
    Enter-VsDevShell -VsInstallPath $installPath -SkipAutomaticLocation
}

## 8a. Build .NET (CEF)
Write-Host "> Building .NET (CEF)..." -ForegroundColor Cyan
dotnet build Dotnet\VRCX-Cef.csproj `
    -p:Configuration=Release -p:WarningLevel=0 -p:Platform=x64 `
    -p:RestorePackagesConfig=true -t:"Restore;Clean;Build" -m --self-contained

## 8b. Build Node.js front-end
Write-Host "> Building Node.js..." -ForegroundColor Cyan
Remove-Item -Path "node_modules" -Force -Recurse -ErrorAction SilentlyContinue
npm ci --loglevel=error
$ErrorActionPreference = 'Continue'
npm run prod
$ErrorActionPreference = 'Stop'

# Create junction so the CEF build can find the HTML output
Remove-Item -Path "build\Cef\html" -Force -Recurse -ErrorAction SilentlyContinue
New-Item -ItemType Junction -Path "build\Cef\html" -Target "build\html"

## 8c. Update Version file to today's date and derive output names
$version = Get-Date -Format 'yyyy.MM.dd'
$currentVersion = (Get-Content Version -Raw).Trim()
if ($version -ne $currentVersion) {
    Write-Host "> Updating Version file: $currentVersion -> $version" -ForegroundColor Cyan
    Set-Content Version $version -NoNewline -Encoding UTF8
    git add Version
    git commit -m "chore: bump version to $version"
    git push origin $ForkBranch
} else {
    Write-Host "> Version already up to date: $version" -ForegroundColor Gray
}
$ZipName   = "VRCX_$($version -replace '\.', '-').zip"
$SetupName = "VRCX_$($version -replace '\.', '-')_Setup.exe"

## 8d. Create ZIP
Write-Host "> Creating ZIP: $ZipName" -ForegroundColor Cyan

# Locate 7-Zip (PATH or default install locations)
$7zExe = Get-Command '7z' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $7zExe) {
    $candidates = @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe'
    )
    $7zExe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $7zExe) {
    Write-Host "ERROR: 7-Zip not found. Install it from https://www.7-zip.org/ or add it to PATH." -ForegroundColor Red
    exit 1
}

Push-Location "build\Cef"
& $7zExe a -tzip $ZipName * -mx=7 '-xr0!*.log' '-xr0!*.pdb'
Move-Item $ZipName ..\..\$ZipName -Force
Pop-Location

## 8e. Create installer
Write-Host "> Creating installer: $SetupName" -ForegroundColor Cyan
Push-Location Installer
Out-File -FilePath "version_define.nsh" -Encoding UTF8 `
    -InputObject "!define PRODUCT_VERSION_FROM_FILE `"$version.0`""
$nsisPath = "C:\Program Files (x86)\NSIS\makensis.exe"
& $nsisPath installer.nsi
Start-Sleep -Seconds 1
Move-Item VRCX_Setup.exe ..\$SetupName -Force
Pop-Location

## 8f. SHA256 checksums
Write-Host "> Computing SHA256 checksums..." -ForegroundColor Cyan
$lines = @()
foreach ($artifact in @($ZipName, $SetupName)) {
    if (Test-Path $artifact) {
        $h = (Get-FileHash $artifact -Algorithm SHA256).Hash
        $lines += "$h  $artifact"
    }
}
$lines | Set-Content "SHA256SUMS.txt" -Encoding ASCII

Write-Host ""
Write-Host "Release build complete!" -ForegroundColor Green
Write-Host "  Artifacts: $ZipName, $SetupName, SHA256SUMS.txt" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────────────────────────
# 9. Publish GitHub release (only with -Publish)
# ─────────────────────────────────────────────────────────────────────────────
if (-not $Publish) {
    Write-Host ""
    Write-Host "To also publish a GitHub release, re-run with -Publish." -ForegroundColor Cyan
    exit 0
}

Write-Host "> Publishing GitHub release $version..." -ForegroundColor Cyan

# Verify gh CLI is available
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: GitHub CLI (gh) is not installed or not in PATH." -ForegroundColor Red
    Write-Host "Install it from https://cli.github.com/ and run 'gh auth login' once." -ForegroundColor Red
    exit 1
}

# Collect artifacts to upload
$artifacts = @()
foreach ($f in @($ZipName, $SetupName, 'SHA256SUMS.txt')) {
    if (Test-Path $f) { $artifacts += $f }
}

# Build release notes from the last git log entry on upstream that isn't already in a release
$releaseNotes = git log --pretty=format:'%s' "$UpstreamRef" -1

# Tag name e.g. v2026.02.11
$tagName = "v$version"

# Check if a release with this tag already exists
# Use Continue temporarily so gh's stderr output doesn't become a terminating error
$ErrorActionPreference = 'Continue'
$null = gh release view $tagName --repo kikookraft/VRCX 2>&1
$releaseExists = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = 'Stop'

if ($releaseExists) {
    Write-Host "  Release $tagName already exists - uploading / overwriting assets only." -ForegroundColor Yellow
    foreach ($artifact in $artifacts) {
        Write-Host "  Uploading: $artifact" -ForegroundColor Gray
        gh release upload $tagName $artifact --repo kikookraft/VRCX --clobber
    }
} else {
    Write-Host "  Creating new release: $tagName" -ForegroundColor Gray
    $ghArgs = @(
        'release', 'create', $tagName,
        '--repo', 'kikookraft/VRCX',
        '--title', "VRCX $version",
        '--notes', $releaseNotes
    ) + $artifacts
    & gh @ghArgs
}

Write-Host ""
Write-Host "GitHub release published: https://github.com/kikookraft/VRCX/releases/tag/$tagName" -ForegroundColor Green
