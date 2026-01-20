#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deduplicates SDK assemblies and creates a tarball.

.DESCRIPTION
    This script copies the SDK layout, runs deduplication on it, and creates a tarball.

.PARAMETER SourceSdkPath
    Path to the source SDK installation (e.g., C:\Program Files\dotnet)

.PARAMETER OutputPath
    Path where the tarball will be created

.PARAMETER UseHardLinks
    Use hard links instead of symbolic links

.PARAMETER Verbose
    Enable verbose output

.EXAMPLE
    .\Deduplicate-And-Package.ps1 -SourceSdkPath "C:\Program Files\dotnet\sdk\10.0.100" -OutputPath "C:\output"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceSdkPath,

    [Parameter(Mandatory=$true)]
    [string]$OutputPath,

    [switch]$UseHardLinks,

    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# Resolve paths
$SourceSdkPath = Resolve-Path $SourceSdkPath
$OutputPath = Resolve-Path $OutputPath

Write-Host "=== SDK Deduplication and Packaging ===" -ForegroundColor Cyan
Write-Host "Source SDK: $SourceSdkPath"
Write-Host "Output: $OutputPath"
Write-Host ""

# Create a temporary working directory
$workDir = Join-Path $OutputPath "sdk-temp-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "Creating working directory: $workDir" -ForegroundColor Yellow
New-Item -Path $workDir -ItemType Directory -Force | Out-Null

try {
    # Copy SDK layout to working directory
    Write-Host "Copying SDK layout..." -ForegroundColor Yellow
    $copyDest = Join-Path $workDir "sdk"
    Copy-Item -Path $SourceSdkPath -Destination $copyDest -Recurse -Force
    Write-Host "Copy complete." -ForegroundColor Green

    # Get size before deduplication
    $sizeBefore = (Get-ChildItem -Path $copyDest -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Write-Host "Size before deduplication: $([math]::Round($sizeBefore / 1MB, 2)) MB"

    # Run deduplication
    Write-Host ""
    Write-Host "Running deduplication..." -ForegroundColor Yellow

    $dedupArgs = @($copyDest)
    if ($UseHardLinks) {
        $dedupArgs += "--hard-links"
    }
    if ($Verbose) {
        $dedupArgs += "--verbose"
    }

    $sdkDedupPath = Join-Path $PSScriptRoot "bin\Release\net10.0\sdkDedup.dll"
    if (-not (Test-Path $sdkDedupPath)) {
        # Try Debug build
        $sdkDedupPath = Join-Path $PSScriptRoot "bin\Debug\net10.0\sdkDedup.dll"
    }

    if (-not (Test-Path $sdkDedupPath)) {
        Write-Host "Building sdkDedup..." -ForegroundColor Yellow
        dotnet build $PSScriptRoot -c Release
        $sdkDedupPath = Join-Path $PSScriptRoot "bin\Release\net10.0\sdkDedup.dll"
    }

    & dotnet $sdkDedupPath @dedupArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Deduplication failed with exit code $LASTEXITCODE"
    }

    Write-Host "Deduplication complete." -ForegroundColor Green

    # Get size after deduplication
    $sizeAfter = (Get-ChildItem -Path $copyDest -Recurse -File | Measure-Object -Property Length -Sum).Sum
    $savings = $sizeBefore - $sizeAfter
    Write-Host "Size after deduplication: $([math]::Round($sizeAfter / 1MB, 2)) MB"
    Write-Host "Space saved: $([math]::Round($savings / 1MB, 2)) MB" -ForegroundColor Green

    # Create tarball
    Write-Host ""
    Write-Host "Creating tarball..." -ForegroundColor Yellow

    $sdkVersion = Split-Path $SourceSdkPath -Leaf
    $tarballName = "dotnet-sdk-$sdkVersion-deduplicated.tar.gz"
    $tarballPath = Join-Path $OutputPath $tarballName

    # Use tar to create the archive
    Push-Location $workDir
    try {
        & tar -czf $tarballPath -C . sdk

        if ($LASTEXITCODE -ne 0) {
            throw "Tar creation failed with exit code $LASTEXITCODE"
        }

        Write-Host "Tarball created: $tarballPath" -ForegroundColor Green

        $tarballSize = (Get-Item $tarballPath).Length
        Write-Host "Tarball size: $([math]::Round($tarballSize / 1MB, 2)) MB" -ForegroundColor Green
    }
    finally {
        Pop-Location
    }

    # Verify tarball
    Write-Host ""
    Write-Host "Verifying tarball..." -ForegroundColor Yellow
    & tar -tzf $tarballPath | Select-Object -First 10 | ForEach-Object {
        Write-Host "  $_"
    }
    Write-Host "  ..." -ForegroundColor Gray

    $entryCount = (& tar -tzf $tarballPath | Measure-Object).Count
    Write-Host "Total entries in tarball: $entryCount" -ForegroundColor Green

    Write-Host ""
    Write-Host "=== Process Complete ===" -ForegroundColor Cyan
    Write-Host "Output tarball: $tarballPath"

} finally {
    # Clean up working directory
    Write-Host ""
    Write-Host "Cleaning up working directory..." -ForegroundColor Yellow
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Cleanup complete." -ForegroundColor Green
}
