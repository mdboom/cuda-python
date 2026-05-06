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

set /a CUDA_PYTHON_PARALLEL_LEVEL=NUMBER_OF_PROCESSORS
if %CUDA_PYTHON_PARALLEL_LEVEL% GTR 61 set CUDA_PYTHON_PARALLEL_LEVEL=61
echo CUDA_PYTHON_PARALLEL_LEVEL="%CUDA_PYTHON_PARALLEL_LEVEL%"

REM Keep going as much as possible
verify >nul

@echo on

git --no-pager log -n 1
git --no-pager status
git --no-pager diff

python3 -VV
python3 -m venv TestVenv
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
