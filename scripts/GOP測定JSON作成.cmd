@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
set "PYTHONUTF8=1"
python -c "import sys; assert sys.version_info.major == 3" >nul 2>nul
if errorlevel 1 goto use_py
python "%~dp0gop_drop.py" %*
set "gop_exit=%errorlevel%"
goto finished
:use_py
py -3 -c "import sys" >nul 2>nul
if errorlevel 1 goto no_python
py -3 "%~dp0gop_drop.py" %*
set "gop_exit=%errorlevel%"
goto finished
:no_python
echo Python 3 could not be started. Please install Python 3 or check its PATH.
set "gop_exit=1"
:finished
echo.
pause
exit /b %gop_exit%
