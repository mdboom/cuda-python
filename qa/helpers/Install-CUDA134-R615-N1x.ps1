<# 
.SYNOPSIS
Downloads/copies the CUDA 13.4-compatible R615 N1x WoA driver, then optionally
installs the Windows ARM64 CUDA 13.4 Toolkit.

.NOTES
Source references from Confluence:
- N1X: GPU driver 615.58, build 6.1.14-r615_00-260607
- CeleritOS 2.80.0: CUDA 13.4.0/006 and R615 BSP references

Run examples:
  powershell -ExecutionPolicy Bypass -File .\Install-CUDA134-R615-N1x.ps1 -Platform Yukon
  powershell -ExecutionPolicy Bypass -File .\Install-CUDA134-R615-N1x.ps1 -Platform Minos -InstallDriver -DownloadCtk
  powershell -ExecutionPolicy Bypass -File .\Install-CUDA134-R615-N1x.ps1 -Platform Yukon -InstallDriver -InstallCudaArm64 -VerifyInstall
  powershell -ExecutionPolicy Bypass -File .\Install-CUDA134-R615-N1x.ps1 -Platform Yukon -SkipDriver -InstallCudaArm64
  powershell -ExecutionPolicy Bypass -File .\Install-CUDA134-R615-N1x.ps1 -Platform Yukon -InstallDriver -InstallCudaArm64 -PromptForArtifactoryCredential
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Yukon", "Minos")]
    [string]$Platform = "Yukon",

    [string]$WorkDir = "$env:USERPROFILE\Downloads\cuda-13.4-r615-n1x",

    [string]$BspZipPath,

    [switch]$InstallDriver,

    [switch]$SkipDriver,

    [switch]$NoBspFallback,

    [System.Management.Automation.PSCredential]$ArtifactoryCredential,

    [switch]$PromptForArtifactoryCredential,

    [switch]$DownloadCtk,

    [switch]$RunCtkInstaller,

    [switch]$InstallCudaArm64,

    [switch]$VerifyInstall
)

$ErrorActionPreference = "Stop"

$DriverBuild = "6.1.14-r615_00-260607"
$DriverShareRoot = "\\builds\Prerelease\NV\n1x-bsp-winnext-aarch64-dch\$DriverBuild"
$CtkInstallerUrl = "https://kitmaker-web.nvidia.com/kitpicks/cuda-r13-4/13.4.0/006/local_installers/cuda_13.4.0_windows_arm64.exe"
$CudaVersion = "13.4"
$CudaInstallRoot = "${env:ProgramFiles}\NVIDIA GPU Computing Toolkit\CUDA\v$CudaVersion"

$platformConfig = @{
    Yukon = @{
        DriverSubdir = "Reference_WoA\N1x_GPU_Drivers\Disk1"
        BspZipUrl = "https://artifactory.nvidia.com/artifactory/sw-woa-generic-local/Reference_WoA/6.1.14-r615_00-260607.zip"
    }
    Minos = @{
        DriverSubdir = "Surface\N1x_GPU_Drivers\Disk1"
        BspZipUrl = "https://artifactory.nvidia.com/artifactory/sw-woa-generic-local/SurfaceBSP/Surface-6.1.14-r615_00-260607.zip"
    }
}

function Require-Admin {
    param(
        [string]$Action = "This operation"
    )

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "$Action requires an elevated PowerShell window. Re-run as Administrator."
    }
}

function Require-Arm64Windows {
    $isArm64 = ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") -or ($env:PROCESSOR_ARCHITEW6432 -eq "ARM64")
    if (-not $isArm64) {
        throw "The CUDA installer selected by this script is Windows ARM64. Current PROCESSOR_ARCHITECTURE=$env:PROCESSOR_ARCHITECTURE."
    }
}

function Copy-Directory {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Driver source path is not reachable: $Source"
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    robocopy $Source $Destination /MIR /R:2 /W:5 /NFL /NDL /NP | Out-Host

    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }
}

function Find-DriverInstallFolder {
    param(
        [Parameter(Mandatory)][string[]]$Roots
    )

    foreach ($root in ($Roots | Where-Object { $_ } | Select-Object -Unique)) {
        Write-Host "Checking driver candidate: $root"

        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        $setupExe = Join-Path $root "setup.exe"
        if (Test-Path -LiteralPath $setupExe) {
            return $root
        }

        $disk1 = Get-ChildItem -LiteralPath $root -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "N1x_GPU_Drivers\\Disk1$" } |
            Select-Object -First 1

        if ($disk1) {
            $disk1Setup = Join-Path $disk1.FullName "setup.exe"
            if ((Test-Path -LiteralPath $disk1Setup) -or
                (Get-ChildItem -LiteralPath $disk1.FullName -Filter "*.inf" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                return $disk1.FullName
            }
        }

        $preferredSetup = Get-ChildItem -LiteralPath $root -Filter "setup.exe" -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "N1x_GPU_Drivers|Display|Driver|Reference_WoA|Surface" } |
            Select-Object -First 1

        if ($preferredSetup) {
            return $preferredSetup.DirectoryName
        }

        $preferredInf = Get-ChildItem -LiteralPath $root -Filter "*.inf" -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "N1x_GPU_Drivers|Display|Driver|Reference_WoA|Surface" } |
            Select-Object -First 1

        if ($preferredInf) {
            return $preferredInf.DirectoryName
        }
    }

    return $null
}

function Get-DriverCandidateRoots {
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $withoutDisk1 = $Config.DriverSubdir -replace "\\Disk1$", ""

    @(
        (Join-Path $DriverShareRoot $Config.DriverSubdir),
        (Join-Path $DriverShareRoot $withoutDisk1),
        (Join-Path $DriverShareRoot "N1x_GPU_Drivers\Disk1"),
        (Join-Path $DriverShareRoot "N1x_GPU_Drivers"),
        (Join-Path $DriverShareRoot "Display.Driver"),
        (Join-Path $DriverShareRoot "release\Display.Driver"),
        $DriverShareRoot
    )
}

function Download-File {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [System.Management.Automation.PSCredential]$Credential
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Write-Host "Downloading $Url"

    $request = @{
        Uri = $Url
        OutFile = $Destination
        UseBasicParsing = $true
    }

    if ($Credential) {
        $request.Credential = $Credential
    }

    Invoke-WebRequest @request
}

function Resolve-BspZipPath {
    param(
        [Parameter(Mandatory)][string]$ExpectedZipPath,
        [Parameter(Mandatory)][string]$BspDir
    )

    if ($BspZipPath) {
        if (Test-Path -LiteralPath $BspZipPath) {
            return (Get-Item -LiteralPath $BspZipPath).FullName
        }

        throw "BSP zip specified by -BspZipPath does not exist: $BspZipPath"
    }

    if (Test-Path -LiteralPath $ExpectedZipPath) {
        return $ExpectedZipPath
    }

    if (-not (Test-Path -LiteralPath $BspDir)) {
        return $null
    }

    $patterns = @(
        "*$Platform*$DriverBuild*.zip",
        "*$DriverBuild*.zip",
        "*.zip"
    )

    foreach ($pattern in $patterns) {
        $match = Get-ChildItem -LiteralPath $BspDir -File -Filter $pattern -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 0 } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($match) {
            return $match.FullName
        }
    }

    return $null
}

function Resolve-DriverPayload {
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $candidateRoots = Get-DriverCandidateRoots -Config $Config
    $driverFolder = Find-DriverInstallFolder -Roots $candidateRoots
    if ($driverFolder) {
        return $driverFolder
    }

    if ($NoBspFallback) {
        throw "No usable driver folder was found under the expected UNC build path, and BSP zip fallback is disabled."
    }

    $bspDir = Join-Path $WorkDir "bsp"
    $bspZip = Join-Path $bspDir ("{0}-{1}.zip" -f $Platform, $DriverBuild)
    $extractDir = Join-Path $bspDir ("{0}-{1}" -f $Platform, $DriverBuild)
    $existingBspZip = Resolve-BspZipPath -ExpectedZipPath $bspZip -BspDir $bspDir

    if ($existingBspZip) {
        $bspZip = $existingBspZip
        Write-Host "Using existing BSP zip: $bspZip"
    }
    else {
        if (-not $ArtifactoryCredential -and $PromptForArtifactoryCredential) {
            $script:ArtifactoryCredential = Get-Credential -Message "Enter NVIDIA/Artifactory credentials for $($Config.BspZipUrl)"
        }

        try {
            Download-File -Url $Config.BspZipUrl -Destination $bspZip -Credential $ArtifactoryCredential
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -eq 401 -and -not $ArtifactoryCredential) {
                Write-Warning "Artifactory returned 401 Unauthorized. Prompting for NVIDIA/Artifactory credentials and retrying once."
                $script:ArtifactoryCredential = Get-Credential -Message "Enter NVIDIA/Artifactory credentials for $($Config.BspZipUrl)"
                Download-File -Url $Config.BspZipUrl -Destination $bspZip -Credential $ArtifactoryCredential
            }
            else {
                throw
            }
        }
    }

    if (-not (Test-Path -LiteralPath $extractDir)) {
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        Write-Host "Extracting $bspZip"
        Expand-Archive -LiteralPath $bspZip -DestinationPath $extractDir -Force
    }
    else {
        Write-Host "BSP zip already extracted: $extractDir"
    }

    $driverFolder = Find-DriverInstallFolder -Roots @($extractDir)
    if ($driverFolder) {
        return $driverFolder
    }

    throw "No usable driver setup folder was found in the UNC build path or extracted BSP zip."
}

function Invoke-CudaArm64Installer {
    param(
        [Parameter(Mandatory)][string]$InstallerPath
    )

    Require-Admin -Action "CUDA Toolkit installation"
    Require-Arm64Windows

    if (-not (Test-Path -LiteralPath $InstallerPath)) {
        throw "CUDA Toolkit ARM64 installer was not found at: $InstallerPath"
    }

    if ($PSCmdlet.ShouldProcess($InstallerPath, "Run CUDA 13.4 Windows ARM64 Toolkit installer")) {
        Write-Host "Starting CUDA 13.4 Windows ARM64 Toolkit installer..."
        Write-Host "Follow the installer prompts. Keep the default toolkit components unless your test recipe requires otherwise."
        Start-Process -FilePath $InstallerPath -WorkingDirectory (Split-Path -Parent $InstallerPath) -Wait
    }
}

function Invoke-DriverInstall {
    param(
        [Parameter(Mandatory)][string]$DriverPath
    )

    Require-Admin -Action "Driver setup"

    $setupExe = Join-Path $DriverPath "setup.exe"
    if (Test-Path -LiteralPath $setupExe) {
        if ($PSCmdlet.ShouldProcess($setupExe, "Run NVIDIA driver setup")) {
            Write-Host "Starting driver setup..."
            Start-Process -FilePath $setupExe -WorkingDirectory $DriverPath -Wait
        }

        return
    }

    $infFile = Get-ChildItem -LiteralPath $DriverPath -Filter "*.inf" -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $infFile) {
        throw "Driver setup.exe was not found and no INF files were found under: $DriverPath"
    }

    $infPattern = Join-Path $DriverPath "*.inf"
    if ($PSCmdlet.ShouldProcess($DriverPath, "Install driver INF files with pnputil")) {
        Write-Host "setup.exe was not found. Installing driver INF files with pnputil..."
        & pnputil.exe /add-driver $infPattern /subdirs /install
        if ($LASTEXITCODE -ne 0) {
            throw "pnputil failed with exit code $LASTEXITCODE"
        }
    }
}

function Test-CudaInstall {
    $cudaBin = Join-Path $CudaInstallRoot "bin"
    $nvccExe = Join-Path $cudaBin "nvcc.exe"

    Write-Host ""
    Write-Host "Verifying CUDA and driver installation..."

    if (Test-Path -LiteralPath $nvccExe) {
        & $nvccExe --version
    }
    else {
        Write-Warning "nvcc.exe was not found at expected path: $nvccExe"
    }

    $nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($nvidiaSmi) {
        & $nvidiaSmi.Source
    }
    else {
        $candidateSmi = "${env:ProgramFiles}\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
        if (Test-Path -LiteralPath $candidateSmi) {
            & $candidateSmi
        }
        else {
            Write-Warning "nvidia-smi.exe was not found in PATH or the default NVIDIA NVSMI folder."
        }
    }
}

$config = $platformConfig[$Platform]
$driverLocal = Join-Path $WorkDir "driver\$Platform\$DriverBuild\Disk1"
$ctkInstaller = Join-Path $WorkDir "cuda_13.4.0_windows_arm64.exe"

if ($InstallCudaArm64) {
    $DownloadCtk = $true
    $RunCtkInstaller = $true
}

Write-Host "CUDA 13.4 R615 N1x setup"
Write-Host "Platform:       $Platform"
Write-Host "Driver build:   $DriverBuild"
Write-Host "Driver share:   $DriverShareRoot"
Write-Host "CUDA installer: $CtkInstallerUrl"
Write-Host "Local work dir: $WorkDir"
Write-Host ""

$driverReady = $false
if ($SkipDriver) {
    Write-Warning "Skipping driver copy/install because -SkipDriver was specified."
}
else {
    try {
        $driverSource = Resolve-DriverPayload -Config $config
        Write-Host "Resolved driver source: $driverSource"
        Copy-Directory -Source $driverSource -Destination $driverLocal
        Write-Host "Driver copied to: $driverLocal"
        $driverReady = $true
    }
    catch {
        Write-Warning $_.Exception.Message
        if (-not ($DownloadCtk -or $RunCtkInstaller -or $InstallCudaArm64)) {
            throw
        }
        Write-Warning "Continuing with CUDA Toolkit steps. Re-run later without -SkipDriver after driver source access is fixed."
    }
}

if ($DownloadCtk -or $RunCtkInstaller) {
    if (-not (Test-Path -LiteralPath $ctkInstaller)) {
        Download-File -Url $CtkInstallerUrl -Destination $ctkInstaller
    }
    else {
        Write-Host "CTK installer already exists: $ctkInstaller"
    }
}

if ($InstallDriver -and $driverReady) {
    Invoke-DriverInstall -DriverPath $driverLocal
}
elseif ($InstallDriver -and -not $driverReady) {
    Write-Warning "Driver setup was requested, but no local driver payload is available."
}
else {
    Write-Host "Driver setup was not started. Add -InstallDriver to run setup.exe."
}

if ($RunCtkInstaller) {
    Invoke-CudaArm64Installer -InstallerPath $ctkInstaller
}
elseif ($DownloadCtk) {
    Write-Host "CTK installer downloaded to: $ctkInstaller"
    Write-Host "Add -InstallCudaArm64 or -RunCtkInstaller to start it after download."
}

if ($VerifyInstall) {
    Test-CudaInstall
}

Write-Host ""
Write-Host "Done."
