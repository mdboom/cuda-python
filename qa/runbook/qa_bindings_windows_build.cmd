@echo off

REM SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
REM SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

REM HINT to get started:
REM     git clone --branch ctk-next https://github.com/rwgk/cuda-python-private.git ctk-next
REM     cd ctk-next\

set "CUDA_HOME=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v%~1"
set "CUDA_PATH=%CUDA_HOME%"

if not exist "%CUDA_HOME%\" (
  echo FATAL: NOT A DIRECTORY: "%CUDA_HOME%"
  echo USAGE HINT: %~nx0 13.1
  exit /b 1
)

echo CUDA_HOME="%CUDA_HOME%"

set "TARGET_ARCH=%PROCESSOR_ARCHITECTURE%"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "TARGET_ARCH=ARM64"
if /i "%TARGET_ARCH%"=="ARM64" (
  set "VCVARS_ARCH=arm64"
  set "PYTHON_CMD=py -3.13-arm64"
  set "PYTHON_PLATFORM=win-arm64"
) else (
  set "VCVARS_ARCH=x64"
  set "PYTHON_CMD=python3"
  set "PYTHON_PLATFORM=win-amd64"
)

echo TARGET_ARCH="%TARGET_ARCH%"
echo PYTHON_CMD=%PYTHON_CMD%

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo FATAL: vswhere.exe not found: "%VSWHERE%"
  exit /b 1
)

for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -property installationPath`) do set "VSINSTALL=%%I"
if not defined VSINSTALL (
  echo FATAL: Visual Studio installation not found.
  exit /b 1
)

call "%VSINSTALL%\VC\Auxiliary\Build\vcvarsall.bat" %VCVARS_ARCH%
if errorlevel 1 exit /b 1

set /a CUDA_PYTHON_PARALLEL_LEVEL=NUMBER_OF_PROCESSORS
if %CUDA_PYTHON_PARALLEL_LEVEL% GTR 61 set CUDA_PYTHON_PARALLEL_LEVEL=61
echo CUDA_PYTHON_PARALLEL_LEVEL="%CUDA_PYTHON_PARALLEL_LEVEL%"

REM Keep going as much as possible
verify >nul

@echo on

git --no-pager log -n 1
git --no-pager status
git --no-pager diff

%PYTHON_CMD% -VV
%PYTHON_CMD% -c "import sys, sysconfig; p = sysconfig.get_platform(); print('Python platform:', p); sys.exit(p != '%PYTHON_PLATFORM%')"
if errorlevel 1 (
  echo FATAL: selected Python does not match target platform "%PYTHON_PLATFORM%".
  echo        Set PYTHON_CMD explicitly, for example:
  echo        set "PYTHON_CMD=py -3.13-arm64"
  exit /b 1
)
%PYTHON_CMD% -m venv TestVenv
call .\TestVenv\Scripts\activate.bat
python -VV
python -m pip install --upgrade pip

cd cuda_pathfinder\
pip install -v -e . --group test
cd ..

cd cuda_bindings\
pip install -v -e . --group test
call tests\cython\build_tests.bat
cd ..

cd cuda_core\
pip install -v -e . --group test
cd ..
