# build-engine-local.ps1: builds ONLY the Windows engine (mk8d-engine.exe) on this PC, from the pinned suyu fork plus patches/suyu/*.patch.
# No Linux, Android, launcher or exporter targets, and no CI. Output: <Work>\engine (the folder that replaces <game folder>\engine).
#
#   powershell -ExecutionPolicy Bypass -File packaging\windows\build-engine-local.ps1 [-Work D:\k] [-Glslang <folder with glslangValidator.exe>]
#
# Needs: Visual Studio with the C++ workload (its bundled CMake and Ninja are used), git, Git Bash, and glslangValidator.exe
# (the Vulkan SDK's Bin folder, or a glslang release unpacked anywhere: pass -Glslang). Keep -Work short: the fork's externals have very long paths.
param(
    [string]$Work = 'D:\k',
    [string]$Glslang = '',
    [string]$MsvcVersion = '14.40' # the toolset the CI uses (VS 2022); a newer one may not build this fork
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$fork = Join-Path $Work 'fork'
$build = Join-Path $Work 'build'
$stage = Join-Path $Work 'engine'

# --- tools -------------------------------------------------------------------------------------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'vswhere.exe not found: install Visual Studio with the C++ workload.' }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'No Visual Studio with the C++ x64 tools was found.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$cmakeDir = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake'
$cmake = Join-Path $cmakeDir 'CMake\bin\cmake.exe'
$ninjaDir = Join-Path $cmakeDir 'Ninja'
$bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
foreach ($p in $vcvars, $cmake, (Join-Path $ninjaDir 'ninja.exe'), $bash) { if (-not (Test-Path $p)) { throw "Missing: $p" } }

if (-not $Glslang -and $env:VULKAN_SDK) { $Glslang = Join-Path $env:VULKAN_SDK 'Bin' }
if (-not $Glslang -or -not (Test-Path (Join-Path $Glslang 'glslangValidator.exe'))) {
    throw 'glslangValidator.exe not found. Install the Vulkan SDK, or unpack a glslang release and pass -Glslang <its bin folder>.'
}

# --- the MSVC environment (the same toolset as the CI) -------------------------------------------------------------------
Write-Host "MSVC environment: $vcvars (toolset $MsvcVersion)"
$envDump = cmd /c "`"$vcvars`" -vcvars_ver=$MsvcVersion >nul && set"
foreach ($line in $envDump) {
    if ($line -match '^([^=]+)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] }
}
$env:PATH = "$Glslang;$ninjaDir;$(Split-Path $cmake);$env:PATH"

# --- the fork with our patches ------------------------------------------------------------------------------------------------
# long paths and no CRLF conversion for this process only (nothing in your git configuration changes)
$env:GIT_CONFIG_COUNT = '2'
$env:GIT_CONFIG_KEY_0 = 'core.longpaths'; $env:GIT_CONFIG_VALUE_0 = 'true'
$env:GIT_CONFIG_KEY_1 = 'core.autocrlf'; $env:GIT_CONFIG_VALUE_1 = 'false'
if (-not (Test-Path (Join-Path $fork 'CMakeLists.txt'))) {
    New-Item -ItemType Directory -Force $Work | Out-Null
    $bashFork = ($fork -replace '\\', '/')
    & $bash -c "cd '$($repo -replace '\\','/')' && packaging/windows/fetch-fork.sh '$bashFork'"
    if ($LASTEXITCODE -ne 0) { throw 'fetch-fork.sh failed (a patch did not apply?).' }
} else {
    Write-Host "Reusing $fork (delete it to fetch the fork and apply the patches again)."
}

# --- configure and build the engine only ------------------------------------------------------------------------------------
$version = (Get-Content (Join-Path $repo 'packaging\windows\engine-version.pin') -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $version) {
    # the stamp is sha256 of the patch bytes in order (the CI formula)
    $sha = [Security.Cryptography.SHA256]::Create()
    $all = New-Object IO.MemoryStream
    Get-ChildItem (Join-Path $repo 'patches\suyu\*.patch') | Sort-Object Name | ForEach-Object { $b = [IO.File]::ReadAllBytes($_.FullName); $all.Write($b, 0, $b.Length) }
    $version = (($sha.ComputeHash($all.ToArray()) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 10) + '-abi6'
}
$version = $version.Trim()
Write-Host "Engine version stamp: $version"

& $cmake -S $fork -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release -DENABLE_QT=OFF -DYUZU_TESTS=OFF -DENABLE_WEB_SERVICE=OFF `
    -DSUYU_NO_JIT=ON -DKARTRECOMP_ENGINE=ON "-DKARTRECOMP_ENGINE_VERSION=$version"
if ($LASTEXITCODE -ne 0) { throw 'cmake configure failed.' }
& $cmake --build $build --target mk8d-engine
if ($LASTEXITCODE -ne 0) { throw 'cmake build failed.' }

# --- stage -----------------------------------------------------------------------------------------------------------------------
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $stage 'plugins') | Out-Null
Copy-Item (Join-Path $build 'bin\mk8d-engine.exe') $stage
Get-ChildItem (Join-Path $build 'bin') -Filter *.dll -ErrorAction SilentlyContinue | Copy-Item -Destination $stage
Set-Content -Path (Join-Path $stage 'ENGINE_VERSION') -Value $version -NoNewline
$mimalloc = Get-ChildItem (Join-Path $build '_deps') -Recurse -Filter LICENSE -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'mimalloc' } | Select-Object -First 1
if ($mimalloc) { Copy-Item $mimalloc.FullName (Join-Path $stage 'mimalloc-LICENSE.txt') }
Write-Host "Done: $stage"
Write-Host 'Copy mk8d-engine.exe (and any .dll next to it) over <game folder>\engine\ to use it.'
