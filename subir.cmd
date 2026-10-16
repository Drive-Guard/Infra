@echo off
rem DriveGuard: sobe o projeto inteiro. Duplo clique.
rem
rem Antes: no Learner Lab, Start Lab e copie o bloco de AWS Details > AWS CLI.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\subir.ps1" %*
set "DG_CODIGO=%ERRORLEVEL%"
echo.
pause
exit /b %DG_CODIGO%
