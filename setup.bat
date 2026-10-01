@echo off
rem SkyCraft setup: installs the build tools, builds SkyCraft and installs it into Mod Organizer 2.
rem   setup.bat          release build (what players get)
rem   setup.bat -Dev     developer setup (Skyrim starts the dev Minecraft from fabric\)
rem See tools\setup.ps1 for all options.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\setup.ps1" %*
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)
pause
