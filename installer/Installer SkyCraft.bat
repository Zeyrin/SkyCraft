@echo off
rem Installateur SkyCraft pour joueurs (fenetre graphique). Extrais tout le zip avant de le lancer.
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0SkyCraft-Installer.ps1"
