$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$launcherProject = Join-Path $repoRoot "Source_Codes\launcher\O-C.Launcher.csproj"
$launcherProgram = Join-Path $repoRoot "Source_Codes\launcher\Program.cs"
$buildScript = Join-Path $repoRoot "Source_Codes\build\Build-O-C-Release.ps1"
$buildBat = Join-Path $repoRoot "Build-O-C-Release.bat"
$debugBat = Join-Path $repoRoot "Debug-O-C.bat"
$safeMenuBat = Join-Path $repoRoot "O-C-Menu.bat"

foreach ($path in @($launcherProject, $launcherProgram, $buildScript, $buildBat, $debugBat, $safeMenuBat)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing packaging file: $path"
    }
}

$program = Get-Content -LiteralPath $launcherProgram -Raw
foreach ($needle in @(
    "Source_Codes",
    "CodexUnifiedSwitcher.ps1",
    "logs",
    "launcher.log",
    "WindowStyle = ProcessWindowStyle.Hidden",
    "UseShellExecute = false"
)) {
    if (-not $program.Contains($needle)) {
        throw "Launcher missing expected behavior: $needle"
    }
}

$build = Get-Content -LiteralPath $buildScript -Raw
foreach ($needle in @(
    "csc.exe",
    "/target:winexe",
    "O-C.exe",
    "Debug-O-C.bat",
    "O-C-Menu.bat",
    "Compress-Archive"
)) {
    if (-not $build.Contains($needle)) {
        throw "Build script missing expected behavior: $needle"
    }
}

Write-Host "O-C packaging checks passed."
