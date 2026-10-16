@echo off
rem DriveGuard: APAGA tudo o que o projeto criou na conta AWS (pede confirmacao).
rem O bucket do state (driveguard-tfstate-<conta>) fica, para o proximo subir.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\subir.ps1" -Desligar %*
set "DG_CODIGO=%ERRORLEVEL%"
echo.
pause
exit /b %DG_CODIGO%
