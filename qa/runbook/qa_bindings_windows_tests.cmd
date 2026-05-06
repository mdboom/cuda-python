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
