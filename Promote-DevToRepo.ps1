#Requires -Version 5.1
<#
.SYNOPSIS
  Copies selected Home Assistant files from dev/ha-config into this repo (for commits / PRs).

.DESCRIPTION
  Use after you edited dashboards or YAML in the Docker dev instance and want the same content
  in version control. Default copies: configuration.yaml, automations.yaml, scripts.yaml,
  scenes.yaml, and all .storage/lovelace* files except lovelace.nonprod (Docker-only). Optional: themes/.

  Always review: git diff before committing.

.PARAMETER DryRun
  List what would be copied without writing files.

.EXAMPLE
  .\Promote-DevToRepo.ps1 -DryRun
  .\Promote-DevToRepo.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',

    [switch]$DryRun,

    # Also copy themes/ from dev mirror when that folder exists
    [switch]$IncludeThemes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $PSScriptRoot
    } else {
        [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
    }
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$devRoot = Join-Path $RepoRoot 'dev/ha-config'

if (-not (Test-Path -LiteralPath $devRoot)) {
    throw "dev/ha-config not found at: $devRoot`nRun scripts\Pull-ProdToDev.cmd (or Prepare-DevConfig.ps1) first."
}

function Copy-OneIfExists([string]$RelativePath, [string]$Label) {
    $from = Join-Path $devRoot $RelativePath
    $to = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $from)) {
        Write-Host "  Skip (missing in dev): $Label" -ForegroundColor DarkYellow
        return
    }
    $parent = [System.IO.Path]::GetDirectoryName($to)
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        if ($DryRun) {
            Write-Host "  [DryRun] Would create directory: $parent" -ForegroundColor Cyan
        } else {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }
    if ($DryRun) {
        Write-Host "  [DryRun] Would copy: $Label -> $to" -ForegroundColor Cyan
        return
    }
    Copy-Item -LiteralPath $from -Destination $to -Force
    Write-Host "  Promoted: $Label" -ForegroundColor Green
}

Write-Host "Dev mirror: $devRoot" -ForegroundColor Cyan
Write-Host "Repo root:  $RepoRoot" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host 'Dry run: no files will be modified.' -ForegroundColor DarkYellow
}
Write-Host ''

foreach ($leaf in @('configuration.yaml', 'automations.yaml', 'scripts.yaml', 'scenes.yaml')) {
    Copy-OneIfExists $leaf $leaf
}

$storSrc = Join-Path $devRoot '.storage'
if (Test-Path -LiteralPath $storSrc) {
    $storDst = Join-Path $RepoRoot '.storage'
    $lovelaceFiles = @(Get-ChildItem -LiteralPath $storSrc -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like 'lovelace*' -and $_.Name -ne 'lovelace.nonprod'
        })
    if ($lovelaceFiles.Count -eq 0) {
        Write-Host '  No lovelace* files under dev/ha-config/.storage' -ForegroundColor DarkYellow
    }
    foreach ($f in $lovelaceFiles) {
        $rel = Join-Path '.storage' $f.Name
        Copy-OneIfExists $rel ".storage/$($f.Name)"
    }
} else {
    Write-Host '  Skip: dev/ha-config/.storage not found' -ForegroundColor DarkYellow
}

if ($IncludeThemes) {
    $themesSrc = Join-Path $devRoot 'themes'
    if (Test-Path -LiteralPath $themesSrc) {
        $themesDst = Join-Path $RepoRoot 'themes'
        if ($DryRun) {
            Write-Host "  [DryRun] Would mirror themes/ -> $themesDst" -ForegroundColor Cyan
        } else {
            New-Item -ItemType Directory -Path $themesDst -Force | Out-Null
            Copy-Item -Path (Join-Path $themesSrc '*') -Destination $themesDst -Recurse -Force
            Write-Host '  Promoted: themes/' -ForegroundColor Green
        }
    } else {
        Write-Host '  Skip -IncludeThemes: no themes/ under dev mirror' -ForegroundColor DarkYellow
    }
}

if (-not $DryRun) {
    $dbRepo = Join-Path $RepoRoot '.storage/lovelace_dashboards'
    if (Test-Path -LiteralPath $dbRepo) {
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $dj = [System.IO.File]::ReadAllText($dbRepo, $utf8) | ConvertFrom-Json
        $before = $dj.data.items.Count
        $dj.data.items = @($dj.data.items | Where-Object { $_.id -ne 'nonprod' })
        if ($dj.data.items.Count -lt $before) {
            $out = ($dj | ConvertTo-Json -Depth 30)
            if (-not $out.EndsWith("`n")) { $out += "`n" }
            [System.IO.File]::WriteAllText($dbRepo, $out, $utf8)
            Write-Host "  Removed dev-only Non-Prod entry from repo lovelace_dashboards" -ForegroundColor Green
        }
        $npFile = Join-Path $RepoRoot '.storage/lovelace.nonprod'
        if (Test-Path -LiteralPath $npFile) {
            Remove-Item -LiteralPath $npFile -Force
            Write-Host '  Removed repo .storage/lovelace.nonprod (dev-only)' -ForegroundColor Green
        }
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host 'Run without -DryRun to apply. Then: git diff' -ForegroundColor Green
} else {
    Write-Host 'Next: git diff - commit on a feature branch if the diff looks correct.' -ForegroundColor Green
}
