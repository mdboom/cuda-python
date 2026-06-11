@echo off

REM SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
REM SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

set "CUDA_HOME=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v%~1"

if not exist "%CUDA_HOME%\" (
  echo FATAL: NOT A DIRECTORY: "%CUDA_HOME%"
  echo USAGE HINT: %~nx0 13.1
  exit /b 1
)

echo CUDA_HOME="%CUDA_HOME%"
set "CUDA_PATH=%CUDA_HOME%"

set "TARGET_ARCH=%PROCESSOR_ARCHITECTURE%"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "TARGET_ARCH=ARM64"
echo TARGET_ARCH="%TARGET_ARCH%"
if /i "%TARGET_ARCH%"=="ARM64" (
  set "PYTHON_PLATFORM=win-arm64"
) else (
  set "PYTHON_PLATFORM=win-amd64"
)
echo PYTHON_PLATFORM="%PYTHON_PLATFORM%"

REM Keep going as much as possible
verify >nul

@echo on

nvidia-smi

reg query "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v HwSchMode

git --no-pager log -n 1
git --no-pager status
git --no-pager diff

call .\TestVenv\Scripts\activate.bat
python -VV
python -c "import sys, sysconfig; p = sysconfig.get_platform(); print('Python platform:', p); sys.exit(p != '%PYTHON_PLATFORM%')"
if errorlevel 1 (
  echo FATAL: TestVenv Python does not match target platform "%PYTHON_PLATFORM%".
  exit /b 1
)
pip list

cd cuda_pathfinder\
python -m pytest -ra -s -vv tests\
cd ..

cd cuda_bindings\
python -m pytest -ra -s -vv tests\
set CUDA_PYTHON_CUDA_PER_THREAD_DEFAULT_STREAM=1 && python -m pytest -ra -s -vv tests\ & set CUDA_PYTHON_CUDA_PER_THREAD_DEFAULT_STREAM=
python -m pytest -ra -s -vv tests\cython\
cd ..

cd cuda_core\
python -m pytest -ra -s -vv tests\
cd ..
