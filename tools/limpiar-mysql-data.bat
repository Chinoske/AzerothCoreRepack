@echo off
echo Limpiando mysql\data\ ...
for /D %%d in ("C:\AzerothCore-Portable\mysql\data\*") do rmdir /S /Q "%%d"
del /Q "C:\AzerothCore-Portable\mysql\data\*" 2>nul
echo Listo - data\ vaciada.
pause
