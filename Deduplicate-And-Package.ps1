#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deduplicates SDK assemblies and creates a tarball.

.DESCRIPTION
    This script copies the entire dotnet installation, runs deduplication on the sdk folder, and creates a tarball.

.PARAMETER SourceSdkPath
    Path to the source dotnet installation root (e.g., C:\Program Files\dotnet)

.PARAMETER OutputPath
    Path where the tarball will be created

.PARAMETER UseHardLinks
    Use hard links instead of symbolic links

.PARAMETER VerboseOutput
    Enable verbose output

.EXAMPLE
    .\Deduplicate-And-Package.ps1 -SourceSdkPath "C:\Program Files\dotnet" -OutputPath "C:\output" -UseHardLinks
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceSdkPath,

    [Parameter(Mandatory=$true)]
    [string]$OutputPath,

    [switch]$UseHardLinks,

    [switch]$VerboseOutput
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

# Display environment information
Write-Host "=== ENVIRONMENT INFO ===" -ForegroundColor Cyan

# OS Information
Write-Host "OS: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
Write-Host "OS Architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
Write-Host "OS Version: $([System.Environment]::OSVersion)"
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)"

# Windows-specific information
if ($IsWindows -or $env:OS -eq "Windows_NT") {
    try {
        $buildInfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
        
        if ($buildInfo.ProductName) { Write-Host "Windows Product: $($buildInfo.ProductName)" }
        if ($buildInfo.EditionID) { Write-Host "Windows Edition: $($buildInfo.EditionID)" }
        if ($buildInfo.CurrentBuild) { Write-Host "Windows Build: $($buildInfo.CurrentBuild)" }
        if ($buildInfo.ReleaseId) { Write-Host "Windows Release: $($buildInfo.ReleaseId)" }
        if ($buildInfo.DisplayVersion) { Write-Host "Windows Display Version: $($buildInfo.DisplayVersion)" }
        
        # Detailed build information for patch level identification
        if ($buildInfo.CurrentBuild -and $buildInfo.UBR) { 
            Write-Host "Full Build Version: $($buildInfo.CurrentBuild).$($buildInfo.UBR)" -ForegroundColor Green
        }
        if ($buildInfo.BuildBranch) { Write-Host "Build Branch: $($buildInfo.BuildBranch)" }
        if ($buildInfo.BuildLab) { Write-Host "Build Lab: $($buildInfo.BuildLab)" }
        if ($buildInfo.BuildLabEx) { Write-Host "Build Lab Ex: $($buildInfo.BuildLabEx)" }
        if ($buildInfo.UBR) { Write-Host "UBR (Update Build Revision): $($buildInfo.UBR)" -ForegroundColor Cyan }
        
        # Check installed Windows updates
        Write-Host "`nRecent Windows Updates:" -ForegroundColor Yellow
        try {
            $recentUpdates = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5
            if ($recentUpdates) {
                $recentUpdates | ForEach-Object {
                    Write-Host "  $($_.HotFixID) - $($_.Description) - $($_.InstalledOn)" -ForegroundColor White
                }
            } else {
                Write-Host "  No hotfix information available" -ForegroundColor Gray
            }
        }
        catch {
            Write-Host "  Could not retrieve hotfix information: $_" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Could not retrieve Windows registry information: $_" -ForegroundColor Yellow
    }
}

# Display tar version
Write-Host ""
Write-Host "Tar version:" -ForegroundColor Yellow
& tar --version | Select-Object -First 1 | ForEach-Object { Write-Host "  $_" }

Write-Host "=== END ENVIRONMENT INFO ===" -ForegroundColor Cyan
Write-Host ""

# Create a temporary working directory
$workDir = Join-Path $OutputPath "sdk-temp-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "Creating working directory: $workDir" -ForegroundColor Yellow
New-Item -Path $workDir -ItemType Directory -Force | Out-Null

try {
    # Copy entire dotnet installation to working directory
    Write-Host "Copying dotnet installation..." -ForegroundColor Yellow
    $copyDest = Join-Path $workDir "dotnet"
    Copy-Item -Path $SourceSdkPath -Destination $copyDest -Recurse -Force
    Write-Host "Copy complete." -ForegroundColor Green

    # Target the sdk folder within the dotnet installation for deduplication
    $sdkFolder = Join-Path $copyDest "sdk"
    if (-not (Test-Path $sdkFolder)) {
        throw "SDK folder not found at: $sdkFolder"
    }

    # Run deduplication on the sdk folder only
    Write-Host ""
    Write-Host "Running deduplication on sdk folder..." -ForegroundColor Yellow

    $dedupArgs = @($sdkFolder)
    if ($UseHardLinks) {
        $dedupArgs += "--hard-links"
    }
    if ($VerboseOutput) {
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

    # Capture deduplication output to parse space savings
    $dedupOutput = & dotnet $sdkDedupPath @dedupArgs 2>&1 | Out-String
    Write-Host $dedupOutput

    if ($LASTEXITCODE -ne 0) {
        throw "Deduplication failed with exit code $LASTEXITCODE"
    }

    # Parse the space savings from the deduplication output
    # Output format: "Deduplication complete: X files replaced with hard links, saving Y.YY MB."
    if ($dedupOutput -match 'saving\s+([\d.]+)\s+MB') {
        $spaceSavedMB = [decimal]$matches[1]
        Write-Host ""
        Write-Host "Space saved by deduplication: $spaceSavedMB MB" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "Could not parse space savings from deduplication output" -ForegroundColor Yellow
    }

    # Get total dotnet installation size
    $totalSize = (Get-ChildItem -Path $copyDest -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Write-Host "Total dotnet installation size: $([math]::Round($totalSize / 1MB, 2)) MB"

    # Create tarball
    Write-Host ""
    Write-Host "Creating tarball..." -ForegroundColor Yellow

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $tarballName = "dotnet-deduplicated-$timestamp.tar.gz"
    $tarballPath = Join-Path $OutputPath $tarballName

    # Use tar to create the archive
    Push-Location $workDir
    try {
        & tar -czf $tarballPath -C . dotnet

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
