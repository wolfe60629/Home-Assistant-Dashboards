#Requires -Version 5.1
<#
.SYNOPSIS
  Copies repo YAML, Lovelace .storage files, themes, and optional customizations into dev/ha-config.

.DESCRIPTION
  Run before or after `docker compose up`. Overwrites tracked YAML and lovelace* in .storage from the
  repo; other .storage files (e.g. onboarding auth) are left in place.

  For a full production mirror (including HACS, www, database, all .storage), run
  scripts\Pull-ProdToDev.cmd or:  Sync-HaConfig.ps1 PullDev  (with the dev stack stopped).

  For custom cards only: copy production custom_components and www into the repo, or pass -ExtraSource.

.EXAMPLE
  .\Prepare-DevConfig.ps1
  .\Prepare-DevConfig.ps1 -ExtraSource 'D:\backup\homeassistant-config'
#>
param(
    [string]$RepoRoot = '',

    # Folder that contains custom_components, www, and/or themes from production (same layout as /config).
    [string]$ExtraSource = '',

    [switch]$SkipRepoCustomizations
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$devRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else {
    [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $devRoot '..')).Path
} else {
    $RepoRoot = (Resolve-Path $RepoRoot).Path
}

$dest = Join-Path $devRoot 'ha-config'
$storageSrc = Join-Path $RepoRoot '.storage'
$storageDst = Join-Path $dest '.storage'

Write-Host "Repo: $RepoRoot" -ForegroundColor Cyan
Write-Host "Dev config dir: $dest" -ForegroundColor Cyan

New-Item -ItemType Directory -Path $dest -Force | Out-Null
New-Item -ItemType Directory -Path $storageDst -Force | Out-Null

foreach ($leaf in @('configuration.yaml', 'automations.yaml', 'scripts.yaml', 'scenes.yaml')) {
    $src = Join-Path $RepoRoot $leaf
    if (-not (Test-Path -LiteralPath $src)) {
        throw "Missing required file in repo: $src"
    }
    Copy-Item -LiteralPath $src -Destination (Join-Path $dest $leaf) -Force
    Write-Host "  Copied $leaf" -ForegroundColor Green
}

if (Test-Path -LiteralPath $storageSrc) {
    Get-ChildItem -LiteralPath $storageSrc -File | Where-Object { $_.Name -like 'lovelace*' } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $storageDst $_.Name) -Force
        Write-Host "  Copied .storage/$($_.Name)" -ForegroundColor Green
    }
} else {
    Write-Host "No repo .storage folder; Lovelace in dev will be empty until you pull Lovelace into the repo." -ForegroundColor DarkYellow
}

$themesRepo = Join-Path $RepoRoot 'themes'
$themesDest = Join-Path $dest 'themes'
if (Test-Path -LiteralPath $themesRepo) {
    Copy-Item -LiteralPath $themesRepo -Destination $themesDest -Recurse -Force
    Write-Host "  Copied themes/" -ForegroundColor Green
} else {
    New-Item -ItemType Directory -Path $themesDest -Force | Out-Null
    $minimalTheme = @'
minimal_dev:
  modes:
    light:
      primary-color: "#448aff"
'@
    $themePath = Join-Path $themesDest 'minimal_dev.yaml'
    Set-Content -LiteralPath $themePath -Value $minimalTheme -Encoding utf8
    Write-Host "  Created themes/minimal_dev.yaml (no themes/ in repo)" -ForegroundColor DarkYellow
}

$secretsSrc = Join-Path $RepoRoot 'secrets.yaml'
if (Test-Path -LiteralPath $secretsSrc) {
    Copy-Item -LiteralPath $secretsSrc -Destination (Join-Path $dest 'secrets.yaml') -Force
    Write-Host "  Copied secrets.yaml" -ForegroundColor Green
}

function Copy-CustomizationTree {
    param(
        [string]$SourceRoot,
        [string]$Label
    )
    foreach ($dir in @('custom_components', 'www', 'blueprints')) {
        $from = Join-Path $SourceRoot $dir
        if (-not (Test-Path -LiteralPath $from)) { continue }
        $to = Join-Path $dest $dir
        Copy-Item -LiteralPath $from -Destination $to -Recurse -Force
        Write-Host "  Copied $dir/ from $Label" -ForegroundColor Green
    }
    $themesFrom = Join-Path $SourceRoot 'themes'
    if (Test-Path -LiteralPath $themesFrom) {
        $themesTo = Join-Path $dest 'themes'
        New-Item -ItemType Directory -Path $themesTo -Force | Out-Null
        Get-ChildItem -LiteralPath $themesFrom -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $themesTo $_.Name) -Recurse -Force
        }
        Write-Host "  Merged themes/ from $Label" -ForegroundColor Green
    }
}

if (-not $SkipRepoCustomizations) {
    Copy-CustomizationTree -SourceRoot $RepoRoot -Label 'repo'
}

if (-not [string]::IsNullOrWhiteSpace($ExtraSource)) {
    $xs = (Resolve-Path -LiteralPath $ExtraSource).Path
    if (-not (Test-Path -LiteralPath $xs)) {
        throw "ExtraSource path not found: $ExtraSource"
    }
    Copy-CustomizationTree -SourceRoot $xs -Label 'ExtraSource'
}

Write-Host ""
Write-Host "Next (from dev folder):" -ForegroundColor Green
Write-Host '  docker compose restart' -ForegroundColor White
Write-Host '  Open http://localhost:8123 - hard-refresh the browser (Ctrl+F5) after Lovelace changes.' -ForegroundColor White
Write-Host ''
Write-Host 'Still missing pieces?' -ForegroundColor Cyan
Write-Host '  Integrations (Alexa, cloud, Z-Wave, etc.) do not copy from prod; entities may show unavailable in dev.' -ForegroundColor DarkGray
Write-Host '  Dashboard backgrounds use /api/image/... IDs from prod; re-upload in dev or ignore broken images.' -ForegroundColor DarkGray
Write-Host '  Copy prod custom_components + www into the repo, or pass -ExtraSource to this script (see .SYNOPSIS).' -ForegroundColor DarkGray
