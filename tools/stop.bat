@echo off
for %%i in ("%~dp0..") do set "ROOT=%%~fi\"
set MYSQL_BIN=%ROOT%mysql\bin
set MYSQL_INI=%ROOT%mysql\my.ini
echo  [>] Deteniendo WorldServer y AuthServer...
taskkill /F /IM worldserver.exe /IM authserver.exe >nul 2>&1
echo  [>] Deteniendo MySQL...
"%MYSQL_BIN%\mysqladmin.exe" "--defaults-file=%MYSQL_INI%" -u root shutdown >nul 2>&1
echo  [+] Todo detenido.
pause
