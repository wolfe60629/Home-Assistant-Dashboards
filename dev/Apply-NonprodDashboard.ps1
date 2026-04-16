#Requires -Version 5.1
<#
.SYNOPSIS
  Adds a "Non-Prod" Lovelace dashboard (built-in cards only) under dev/ha-config/.storage.

.DESCRIPTION
  Run after Prepare-DevConfig.ps1. Patches dev/ha-config/.storage/lovelace_dashboards and writes
  lovelace.nonprod. Does not modify the repo (Docker dev only).
#>
param(
    [string]$RepoRoot = ''
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

$storage = Join-Path $devRoot 'ha-config\.storage'
if (-not (Test-Path -LiteralPath $storage)) {
    throw "Missing $storage - run Prepare-DevConfig.ps1 first."
}

$dashPath = Join-Path $storage 'lovelace_dashboards'
if (-not (Test-Path -LiteralPath $dashPath)) {
    throw "Missing $dashPath - copy Lovelace from repo or run Prepare-DevConfig.ps1."
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$raw = [System.IO.File]::ReadAllText($dashPath, $utf8)
$j = $raw | ConvertFrom-Json
$items = [System.Collections.ArrayList]@($j.data.items)
$has = $false
foreach ($it in $items) {
    if ($it.id -eq 'nonprod') { $has = $true; break }
}
if (-not $has) {
    [void]$items.Add([pscustomobject]@{
            id               = 'nonprod'
            icon             = 'mdi:docker'
            title            = 'Non-Prod'
            url_path         = 'nonprod'
            mode             = 'storage'
            show_in_sidebar  = $true
            require_admin    = $false
        })
    $j.data.items = @($items)
    $out = ($j | ConvertTo-Json -Depth 30)
    if (-not $out.EndsWith("`n")) { $out += "`n" }
    [System.IO.File]::WriteAllText($dashPath, $out, $utf8)
    Write-Host "  Registered Non-Prod dashboard in lovelace_dashboards" -ForegroundColor Green
} else {
    Write-Host "  Non-Prod dashboard already registered" -ForegroundColor DarkGray
}

$nonprodLovelace = @'
{
  "version": 1,
  "minor_version": 1,
  "key": "lovelace.nonprod",
  "data": {
    "config": {
      "views": [
        {
          "title": "Non-Prod",
          "path": "overview",
          "type": "sections",
          "theme": "minimal_dev",
          "sections": [
            {
              "type": "grid",
              "cards": [
                {
                  "type": "markdown",
                  "content": "## Docker non-production\nThis view uses **built-in cards only** (no HACS / custom card JS). Your full dashboard is still under the default views; for a full prod clone run **scripts/Pull-ProdToDev.cmd** (entire /config mirror)."
                },
                {
                  "type": "weather-forecast",
                  "entity": "weather.home",
                  "show_current": true,
                  "forecast_type": "daily"
                },
                {
                  "type": "entities",
                  "title": "Quick links",
                  "entities": [
                    "person.jeremy_wolfe"
                  ]
                }
              ]
            }
          ],
          "cards": [],
          "header": {},
          "badges": []
        }
      ]
    }
  }
}
'@

$lp = Join-Path $storage 'lovelace.nonprod'
[System.IO.File]::WriteAllText($lp, $nonprodLovelace.TrimStart() + "`n", $utf8)
Write-Host "  Wrote lovelace.nonprod (built-in cards)" -ForegroundColor Green
