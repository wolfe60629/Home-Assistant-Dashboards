#Requires -Version 5.1
<#
.SYNOPSIS
  Refreshes dev/ha-config from the repo, applies the Non-Prod dashboard, restarts the dev stack.

.DESCRIPTION
  From repo: docker compose down (dev) -> Prepare-DevConfig -> Apply-NonprodDashboard -> docker compose up -d
#>
$ErrorActionPreference = 'Stop'
$devRoot = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $devRoot '..')).Path

Write-Host "Repo: $repoRoot" -ForegroundColor Cyan
Set-Location $devRoot

Write-Host "`ndocker compose down ..." -ForegroundColor Cyan
& docker compose down

Write-Host "`nPrepare-DevConfig.ps1 ..." -ForegroundColor Cyan
& (Join-Path $devRoot 'Prepare-DevConfig.ps1') -RepoRoot $repoRoot

Write-Host "`nApply-NonprodDashboard.ps1 ..." -ForegroundColor Cyan
& (Join-Path $devRoot 'Apply-NonprodDashboard.ps1') -RepoRoot $repoRoot

Write-Host "`ndocker compose up -d ..." -ForegroundColor Cyan
& docker compose up -d

Write-Host ''
Write-Host 'Open http://localhost:8123 and open the sidebar entry "Non-Prod" (built-in cards only).' -ForegroundColor Green
Write-Host 'Other views may still show custom-card errors until you run a full Pull-ProdToDev.' -ForegroundColor Green
