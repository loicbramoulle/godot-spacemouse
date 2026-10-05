@echo off
title SpaceMouse Bridge - install requirements
setlocal
set "PYCMD="
py -3 --version >nul 2>&1 && set "PYCMD=py -3"
if not defined PYCMD (python --version >nul 2>&1 && set "PYCMD=python")
if not defined PYCMD (python3 --version >nul 2>&1 && set "PYCMD=python3")
if not defined PYCMD (
    echo No working Python 3 was found from this window.
    echo.
    echo Having Python open in another window is not enough: this script
    echo needs Python reachable from the command line.
    echo.
    echo Easiest fix: install Python 3 from python.org and tick
    echo "Add python.exe to PATH" on the first installer screen.
    echo An existing Python install is simply upgraded, nothing is lost.
    pause
    exit /b 1
)
echo Using Python command: %PYCMD%
%PYCMD% --version
%PYCMD% -m pip install --upgrade pywin32 hidapi
if errorlevel 1 (
    echo.
    echo pip install failed. Check your internet connection and try again.
) else (
    echo.
    echo Done. You can now run run_bridge.bat
)
pause
