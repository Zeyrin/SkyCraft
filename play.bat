@echo off
rem Starts Skyrim through Mod Organizer 2 + SKSE. SkyCraft starts Minecraft by itself.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\play.ps1" %*
if errorlevel 1 pause
