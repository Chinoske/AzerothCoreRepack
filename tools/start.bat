@echo off
setlocal enabledelayedexpansion
title AzerothCore Portable
color 0A
for %%i in ("%~dp0..") do set "ROOT=%%~fi\"
set MYSQL_BIN=%ROOT%mysql\bin
set MYSQL_INI=%ROOT%mysql\my.ini
set MYSQL_DATA=%ROOT%mysql\data
set SERVER=%ROOT%server
cd /d "%ROOT%"

echo.
echo  =============================================
echo   AzerothCore Portable - Arrancando...
echo  =============================================
echo.

:: Crear my.ini con rutas absolutas del directorio actual
(
    echo [mysqld]
    echo basedir=%ROOT%mysql
    echo datadir=%MYSQL_DATA%
    echo port=3306
    echo max_allowed_packet=256M
    echo innodb_buffer_pool_size=1G
    echo log_error=%ROOT%mysql\mysql_error.log
    echo.
    echo [client]
    echo port=3306
) > "%MYSQL_INI%"

:: Inicializar MySQL si es la primera vez
if not exist "%MYSQL_DATA%\mysql" (
    echo  [>] Primera ejecucion: inicializando MySQL...
    echo      (puede tardar 60 segundos)
    start /wait /D "%MYSQL_BIN%" "%MYSQL_BIN%\mysqld.exe" --defaults-file="%MYSQL_INI%" --initialize-insecure
    echo  [+] MySQL inicializado
    echo.
)

:: Comprobar si MySQL ya corre
"%MYSQL_BIN%\mysqladmin.exe" -u root --connect-timeout=2 ping >nul 2>&1
if !errorlevel! neq 0 (
    echo  [>] Arrancando MySQL...
    start "MySQL Portable" /MIN /D "%MYSQL_BIN%" "%MYSQL_BIN%\mysqld.exe" --defaults-file="%MYSQL_INI%"
    echo  [>] Esperando a MySQL...
    :WAIT_MYSQL
    timeout /t 2 /nobreak >nul
    "%MYSQL_BIN%\mysqladmin.exe" -u root --connect-timeout=1 ping >nul 2>&1
    if !errorlevel! neq 0 goto :WAIT_MYSQL
)
echo  [+] MySQL corriendo

:: Crear usuario acore la primera vez
if not exist "%ROOT%mysql\acore_user.flag" (
    "%MYSQL_BIN%\mysql.exe" -u root -e "CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED BY 'acore'; GRANT ALL PRIVILEGES ON *.* TO 'acore'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;" >nul 2>&1
    echo. > "%ROOT%mysql\acore_user.flag"
    echo  [+] Usuario acore creado
)
echo.

:: Arrancar AuthServer
echo  [>] Arrancando AuthServer...
start "AuthServer" cmd /k "cd /d %SERVER% && authserver.exe"
timeout /t 3 /nobreak >nul

:: Arrancar WorldServer
echo  [>] Arrancando WorldServer...
start "WorldServer" cmd /k "cd /d %SERVER% && worldserver.exe"

echo.
echo  [OK] Servidor iniciado.
echo  Realmlist: set realmlist 127.0.0.1
echo.
pause
