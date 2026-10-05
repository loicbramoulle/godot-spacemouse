@echo off
title SpaceMouse Bridge (COM debug)
setlocal
set "PYCMD="
py -3 --version >nul 2>&1 && set "PYCMD=py -3"
if not defined PYCMD (python --version >nul 2>&1 && set "PYCMD=python")
if not defined PYCMD (python3 --version >nul 2>&1 && set "PYCMD=python3")
if not defined PYCMD (
    echo No working Python 3 found. Run install_requirements.bat for help.
    pause
    exit /b 1
)
echo Move the SpaceMouse when the live-values section starts.
%PYCMD% "%~dp0spacemouse_udp_bridge.py" --debug-com
pause
