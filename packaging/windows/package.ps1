# Windows packages: zip and MSI. Needs WiX v4 (`dotnet tool install --global wix`).
#   packaging\windows\package.ps1 [-Version 1.2.3] [-BinDir zig-out\bin] [-Arch x86_64]
param(
    [string]$Version = "",
    [string]$BinDir = "zig-out\bin",
    [string]$Arch = "x86_64",
    [string]$Out = "dist"
)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..\..")
if (-not $Version) {
    $Version = (Select-String -Path build.zig.zon -Pattern '\.version = "([^"]+)"').Matches[0].Groups[1].Value
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# zip: the exe, WebView2Loader.dll if present, and the notices
$name = "lax-$Version-windows-$Arch"
$stage = Join-Path $Out $name
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item "$BinDir\lax.exe" $stage
if (Test-Path "$BinDir\WebView2Loader.dll") { Copy-Item "$BinDir\WebView2Loader.dll" $stage }
Copy-Item README.md, THIRD_PARTY_NOTICES.md $stage
Compress-Archive -Force -Path $stage -DestinationPath "$Out\$name.zip"

# msi: the version must be numeric (1.2.3), a prerelease suffix is dropped
$numeric = ($Version -split '[-+]')[0]
$defines = @("-d", "Version=$numeric", "-d", "BinDir=$BinDir")
if (Test-Path "$BinDir\WebView2Loader.dll") { $defines += @("-d", "WebView2Dll=1") }
$wixArch = if ($Arch -eq "aarch64") { "arm64" } else { "x64" }
wix build -arch $wixArch @defines -o "$Out\$name.msi" packaging\windows\lax.wxs
Write-Host "wrote $Out\$name.zip and $Out\$name.msi"
