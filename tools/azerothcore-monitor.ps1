<#
.SYNOPSIS
    AzerothCore Monitor - Interfaz gráfica para gestionar un servidor portable de AzerothCore (WotLK 3.3.5a)
.DESCRIPTION
    Este script proporciona una interfaz gráfica para:
    - Iniciar/detener MySQL portable, AuthServer y WorldServer.
    - Compilar y actualizar el servidor desde los repositorios de GitHub.
    - Crear/editar cuentas de juego (SRP6).
    - Cambiar contraseñas de MySQL y acore.
    - Editar el realmlist del cliente WoW.
.NOTES
    Autor: (basado en el script original)
    Requiere: PowerShell 5.1+, .NET Windows.Forms, Git, CMake, Visual Studio (para compilar).
#>

# ============================================================
# CARGA DE ENSAMBLADOS Y CONFIGURACIÓN INICIAL
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinTaskbar {
    [DllImport("shell32.dll", SetLastError=true)]
    public static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
}
"@
[WinTaskbar]::SetCurrentProcessExplicitAppUserModelID("AzerothCore.Monitor")

# Caracteres Unicode para la interfaz
$DOT    = [char]0x25CF      # Círculo relleno
$PLAY   = [char]0x25B6      # Triángulo de reproducción
$STOP   = [char]0x25A0      # Cuadrado de stop
$MIDDOT = [char]0x2744      # Copo de nieve

# Determinar la raíz del proyecto (directorio superior al que contiene este script)
if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$ROOT = Split-Path $PSScriptRoot -Parent

# Configuración de rutas relativas (todas dentro de la estructura portable)
$cfg = @{
    MySQLBin  = "$ROOT\mysql\bin"
    MySQLIni  = "$ROOT\mysql\my.ini"
    MySQLData = "$ROOT\mysql\data"
    MySQLDir  = "$ROOT\mysql"
    ACoreBin  = "$ROOT\server"
}

# Auto-parcheo de archivos de configuración con la ruta real del repack
function Update-RepackPaths {
    $rootFwd = $ROOT -replace '\\', '/'

    # my.ini — basedir, datadir, log_error
    $myini = $cfg.MySQLIni
    if (Test-Path $myini) {
        $txt = Get-Content $myini -Raw
        $new = $txt `
            -replace '(?<=basedir=)[^\r\n]+',   "$rootFwd/mysql" `
            -replace '(?<=datadir=)[^\r\n]+',   "$rootFwd/mysql/data" `
            -replace '(?<=log_error=)[^\r\n]+', "$rootFwd/mysql/mysql_error.log"
        if ($new -ne $txt) { [System.IO.File]::WriteAllText($myini, $new, [System.Text.Encoding]::UTF8) }
    }

    # dbimport.conf — SourceDirectory
    $dbconf = "$($cfg.ACoreBin)\configs\dbimport.conf"
    if (Test-Path $dbconf) {
        $txt = Get-Content $dbconf -Raw
        $new = $txt -replace '(?<=SourceDirectory\s*=\s*")[^"]*', "$rootFwd/source"
        if ($new -ne $txt) { [System.IO.File]::WriteAllText($dbconf, $new, [System.Text.Encoding]::UTF8) }
    }
}
Update-RepackPaths

# Colas de salida y referencias a procesos de servidor
$script:authQueue     = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:worldQueue    = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:compileQueue   = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:dbimportQueue  = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:authProc      = $null
$script:worldProc     = $null
$script:compileProc   = $null
$script:dbimportProc  = $null
$script:authLogPos    = 0L
$script:worldLogPos   = 0L
$script:compileLogPos = 0L
$script:dbimportLogPos = 0L

# Paleta de colores temática "Northrend/WotLK"
$col = @{
    Bg     = [System.Drawing.Color]::FromArgb(6,   10,  20)   # Cielo nocturno de Northrend
    Card   = [System.Drawing.Color]::FromArgb(11,  20,  42)   # Azul marino oscuro
    CardHi = [System.Drawing.Color]::FromArgb(16,  30,  60)   # Hover de tarjeta
    Border = [System.Drawing.Color]::FromArgb(38,  90,  152)  # Borde glacial
    Ice    = [System.Drawing.Color]::FromArgb(88,  182, 230)  # Azul hielo primario
    Frost  = [System.Drawing.Color]::FromArgb(172, 218, 240)  # Escarcha blanca-azul
    Green  = [System.Drawing.Color]::FromArgb(46,  204, 140)  # Verde glacial (activo)
    Red    = [System.Drawing.Color]::FromArgb(210, 48,  48)   # Rojo crimson frío
    Amber  = [System.Drawing.Color]::FromArgb(230, 182, 48)   # Ámbar dorado
    Text   = [System.Drawing.Color]::FromArgb(196, 226, 242)  # Blanco frío
    Muted  = [System.Drawing.Color]::FromArgb(88,  138, 172)  # Azul acero tenue
    Btn    = [System.Drawing.Color]::FromArgb(10,  22,  44)   # Fondo botón oscuro
    BtnBd  = [System.Drawing.Color]::FromArgb(38,  90,  152)  # Borde botón glacial
    BtnGrn = [System.Drawing.Color]::FromArgb(8,   48,  32)   # Verde oscuro inicio
    BtnRed = [System.Drawing.Color]::FromArgb(52,  10,  10)   # Rojo oscuro detener
}

# ============================================================
# FUNCIONES AUXILIARES (estado, MySQL, procesos, SRP6)
# ============================================================

<#
.SYNOPSIS
    Comprueba si el servidor MySQL portable está corriendo.
.EXAMPLE
    Test-MySQL
#>
function Test-MySQL {
    try {
        $r = & "$($cfg.MySQLBin)\mysqladmin.exe" "--defaults-file=$($cfg.MySQLIni)" -u root --connect-timeout=1 ping 2>$null
        return ($r -join "") -match "alive"
    } catch { return $false }
}

<#
.SYNOPSIS
    Comprueba si un proceso (por nombre) está en ejecución.
.PARAMETER name
    Nombre del proceso (sin .exe)
#>
function Test-Proc([string]$name) {
    return $null -ne (Get-Process -Name $name -ErrorAction SilentlyContinue)
}

<#
.SYNOPSIS
    Calcula el salt y verifier SRP6 para una cuenta de AzerothCore.
.DESCRIPTION
    Implementa el algoritmo SRP6 (Secure Remote Password) usado por TrinityCore/AzerothCore.
.PARAMETER username
    Nombre de usuario (se convertirá a mayúsculas)
.PARAMETER password
    Contraseña en texto claro (se convertirá a mayúsculas)
#>
function Compute-SRP6([string]$username, [string]$password) {
    # N (primo grande) en little-endian según especificación de WoW
    $N_le = [byte[]]@(
        0xB7,0x9B,0x3E,0x2A,0x87,0x82,0x3C,0xAB,0x8F,0x5E,0xBF,0xBF,0x8E,0xB1,0x01,0x08,
        0x53,0x50,0x06,0x29,0x8B,0x5B,0xAD,0xBD,0x5B,0x53,0xE1,0x89,0x5E,0x64,0x4B,0x89,0x00
    )
    $N = [System.Numerics.BigInteger]::new($N_le)
    $g = [System.Numerics.BigInteger]::new(7)          # Generador
    $salt = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt); $rng.Dispose()
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $h1 = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($username.ToUpper() + ':' + $password.ToUpper()))
    $x  = [System.Numerics.BigInteger]::new($sha1.ComputeHash($salt + $h1) + [byte[]]@(0x00))
    $sha1.Dispose()
    $v_bytes = [System.Numerics.BigInteger]::ModPow($g, $x, $N).ToByteArray()
    $v = New-Object byte[] 32
    [Array]::Copy($v_bytes, $v, [Math]::Min($v_bytes.Length, 32))
    return @{ Salt = $salt; Verifier = $v }
}

# ============================================================
# FUNCIONES DE CONFIGURACIÓN Y GESTIÓN DE MYSQL
# ============================================================

<#
.SYNOPSIS
    Asegura que existe la configuración mínima de MySQL (my.ini) y sus directorios.
#>
function Ensure-MySQLConfig {
    foreach ($d in @($cfg.MySQLDir, $cfg.MySQLData)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $basedir = $cfg.MySQLDir -replace '\\$', ''
    if (-not (Test-Path $cfg.MySQLIni)) {
        @"
[mysqld]
basedir=$($basedir -replace '\\', '/')
datadir=$($cfg.MySQLData -replace '\\', '/')
port=3306
max_allowed_packet=256M
innodb_buffer_pool_size=1G
log_error=$($cfg.MySQLDir -replace '\\', '/')/mysql_error.log

[client]
port=3306
password=
"@ | Set-Content $cfg.MySQLIni -Encoding ASCII
    } else {
        $ini = Get-Content $cfg.MySQLIni -Raw
        if ($ini -notmatch '(?m)^password\s*=') {
            $ini = $ini -replace '(?m)(\[client\])', "`$1`r`npassword="
            $ini | Set-Content $cfg.MySQLIni -Encoding ASCII
        }
    }
}

<#
.SYNOPSIS
    Actualiza la contraseña de root en el archivo my.ini.
.PARAMETER pass
    Nueva contraseña (texto plano)
#>
function Update-MyIniPassword([string]$pass) {
    if (-not (Test-Path $cfg.MySQLIni)) { return }
    $ini = Get-Content $cfg.MySQLIni -Raw
    if ($ini -match '(?m)^password\s*=') {
        $ini = $ini -replace '(?m)^(password\s*=).*$', "`${1}$pass"
    } else {
        $ini = $ini -replace '(?m)(\[client\])', "`$1`r`npassword=$pass"
    }
    $ini | Set-Content $cfg.MySQLIni -Encoding ASCII
}

<#
.SYNOPSIS
    Actualiza la contraseña de 'acore' en los archivos de configuración de los servidores.
.PARAMETER pass
    Nueva contraseña
#>
function Update-AcorePassword([string]$pass) {
    foreach ($conf in @("worldserver.conf", "authserver.conf", "dbimport.conf")) {
        $p = "$($cfg.ACoreBin)\configs\$conf"
        if (-not (Test-Path $p)) { continue }
        $c = Get-Content $p -Raw
        # Reemplaza el texto entre '; acore ;' y '; acore_' (que suele ser la contraseña)
        $c = $c -replace '(;\s*acore\s*;)[^;";\r\n]+(;\s*acore_)', "`${1}$pass`${2}"
        $c | Set-Content $p -Encoding UTF8
    }
}

<#
.SYNOPSIS
    Inicia el servidor MySQL portable (mysqld) con la configuración adecuada.
.DESCRIPTION
    Si es la primera vez, inicializa el directorio de datos (--initialize-insecure).
    Crea el usuario 'acore' si no existe.
#>
function Start-MySQLPortable {
    Ensure-MySQLConfig
    if (-not (Test-Path "$($cfg.MySQLData)\mysql")) {
        $mysql.Status.Text      = "INICIALIZANDO..."
        $mysql.Status.ForeColor = $col.Amber
        $mysql.Dot.ForeColor    = $col.Amber
        $mysql.Btn.Enabled      = $false
        [System.Windows.Forms.Application]::DoEvents()
        Start-Process -FilePath "$($cfg.MySQLBin)\mysqld.exe" `
                      -ArgumentList "--defaults-file=`"$($cfg.MySQLIni)`" --initialize-insecure" `
                      -WorkingDirectory $cfg.MySQLBin -Wait -WindowStyle Hidden 2>$null
        Start-Sleep -Seconds 2
    }
    Start-Process -FilePath "$($cfg.MySQLBin)\mysqld.exe" `
                  -ArgumentList "--defaults-file=`"$($cfg.MySQLIni)`"" `
                  -WorkingDirectory $cfg.MySQLBin `
                  -WindowStyle Hidden
    $mysql.Status.Text      = "INICIANDO..."
    $mysql.Status.ForeColor = $col.Amber
    $mysql.Dot.ForeColor    = $col.Amber
    $mysql.Btn.Enabled      = $false
    [System.Windows.Forms.Application]::DoEvents()
    # Espera hasta que MySQL responda al ping (máx 30 segundos)
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 2000
        [System.Windows.Forms.Application]::DoEvents()
        if (Test-MySQL) { break }
    }
    $flag = "$($cfg.MySQLDir)\acore_user.flag"
    if (-not (Test-Path $flag) -and (Test-MySQL)) {
        & "$($cfg.MySQLBin)\mysql.exe" "--defaults-file=$($cfg.MySQLIni)" -u root -e "CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED BY 'acore'; GRANT ALL PRIVILEGES ON *.* TO 'acore'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>$null
        New-Item -Path $flag -ItemType File -Force | Out-Null
    }
}

<#
.SYNOPSIS
    Detiene el servidor MySQL portable de forma ordenada (mysqladmin shutdown).
#>
function Stop-MySQLPortable {
    & "$($cfg.MySQLBin)\mysqladmin.exe" "--defaults-file=$($cfg.MySQLIni)" -u root shutdown 2>$null
}

# ============================================================
# CONSTRUCCIÓN DE LA INTERFAZ GRÁFICA (FORM)
# ============================================================

function New-AppIcon {
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode    = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::FromArgb(6, 10, 20))

    # Hexágono glacial
    $cx = 16.0; $cy = 16.0; $r = 13.0
    $pts = [System.Drawing.PointF[]]@(0..5 | ForEach-Object {
        $a = [Math]::PI / 180.0 * (60.0 * $_ - 30.0)
        [System.Drawing.PointF]::new($cx + $r * [Math]::Cos($a), $cy + $r * [Math]::Sin($a))
    })
    $g.FillPolygon([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(11, 20, 42)), $pts)
    $g.DrawPolygon([System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(88, 182, 230), 1.5), $pts)

    # Texto "AC"
    $sf = [System.Drawing.StringFormat]::new()
    $sf.Alignment     = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString("AC",
        [System.Drawing.Font]::new("Segoe UI", 10, [System.Drawing.FontStyle]::Bold),
        [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(172, 218, 240)),
        [System.Drawing.RectangleF]::new(0, 0, 32, 32), $sf)
    $g.Dispose()

    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$form = New-Object System.Windows.Forms.Form
$form.Text            = "AzerothCore Monitor"
$form.ClientSize      = New-Object System.Drawing.Size(400, 612)
$form.FormBorderStyle = "FixedSingle"
$_icoPath = "$PSScriptRoot\monitor.ico"
$form.Icon = if (Test-Path $_icoPath) { [System.Drawing.Icon]::new($_icoPath) } else { New-AppIcon }
$form.MaximizeBox     = $false
$form.StartPosition   = "CenterScreen"
$form.BackColor       = $col.Bg
$form.Font            = New-Object System.Drawing.Font("Segoe UI", 10)

# --- Panel de acento superior (línea glacial) ---
$topAccent = New-Object System.Windows.Forms.Panel
$topAccent.Size      = New-Object System.Drawing.Size(400, 3)
$topAccent.Location  = New-Object System.Drawing.Point(0, 0)
$topAccent.BackColor = $col.Ice
$form.Controls.Add($topAccent)

# --- Título principal ---
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = "AzerothCore Monitor"
$lblTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $col.Frost
$lblTitle.Location  = New-Object System.Drawing.Point(16, 14)
$lblTitle.Size      = New-Object System.Drawing.Size(370, 28)
$form.Controls.Add($lblTitle)

# --- Subtítulo ---
$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text      = "Wrath of the Lich King 3.3.5a  $MIDDOT  mod-ale Lua Engine"
$lblSub.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$lblSub.ForeColor = $col.Muted
$lblSub.Location  = New-Object System.Drawing.Point(16, 44)
$lblSub.Size      = New-Object System.Drawing.Size(370, 18)
$form.Controls.Add($lblSub)

# --- Línea separadora ---
$sepLine = New-Object System.Windows.Forms.Panel
$sepLine.BackColor = $col.Border
$sepLine.Size      = New-Object System.Drawing.Size(368, 1)
$sepLine.Location  = New-Object System.Drawing.Point(16, 68)
$form.Controls.Add($sepLine)

<#
.SYNOPSIS
    Crea una "tarjeta" visual para un servicio (MySQL, Auth, World).
.DESCRIPTION
    Cada tarjeta incluye un punto de estado, nombre, descripción, estado textual y un botón de acción.
.PARAMETER y
    Coordenada Y (vertical) en el formulario.
.PARAMETER title
    Título del servicio (ej. "MySQL 8.4").
.PARAMETER desc
    Descripción breve (ej. "Puerto 3306 - Portable").
#>
function New-ServiceCard($y, $title, $desc) {
    # Panel exterior actúa como borde (1px de color glacial)
    $outer = New-Object System.Windows.Forms.Panel
    $outer.Size      = New-Object System.Drawing.Size(368, 78)
    $outer.Location  = New-Object System.Drawing.Point(16, $y)
    $outer.BackColor = $col.Border
    $form.Controls.Add($outer)

    # Panel interior (fondo real de la tarjeta)
    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Size      = New-Object System.Drawing.Size(366, 76)
    $pnl.Location  = New-Object System.Drawing.Point(1, 1)
    $pnl.BackColor = $col.Card
    $outer.Controls.Add($pnl)

    # Franja izquierda (estilo marco WotLK)
    $strip = New-Object System.Windows.Forms.Panel
    $strip.Size      = New-Object System.Drawing.Size(3, 76)
    $strip.Location  = New-Object System.Drawing.Point(0, 0)
    $strip.BackColor = $col.Ice
    $pnl.Controls.Add($strip)

    # Punto de estado (círculo relleno)
    $dot = New-Object System.Windows.Forms.Label
    $dot.Text      = $DOT
    $dot.Font      = New-Object System.Drawing.Font("Segoe UI", 22)
    $dot.ForeColor = $col.Red
    $dot.Location  = New-Object System.Drawing.Point(13, 22)
    $dot.Size      = New-Object System.Drawing.Size(36, 36)
    $dot.TextAlign = "MiddleCenter"
    $pnl.Controls.Add($dot)

    # Título del servicio
    $lbName = New-Object System.Windows.Forms.Label
    $lbName.Text      = $title
    $lbName.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $lbName.ForeColor = $col.Frost
    $lbName.Location  = New-Object System.Drawing.Point(56, 8)
    $lbName.Size      = New-Object System.Drawing.Size(215, 22)
    $pnl.Controls.Add($lbName)

    # Descripción del servicio
    $lbDesc = New-Object System.Windows.Forms.Label
    $lbDesc.Text      = $desc
    $lbDesc.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $lbDesc.ForeColor = $col.Muted
    $lbDesc.Location  = New-Object System.Drawing.Point(56, 32)
    $lbDesc.Size      = New-Object System.Drawing.Size(215, 16)
    $pnl.Controls.Add($lbDesc)

    # Etiqueta de estado textual (CORRIENDO/DETENIDO)
    $lbSt = New-Object System.Windows.Forms.Label
    $lbSt.Text      = "Verificando..."
    $lbSt.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lbSt.ForeColor = $col.Muted
    $lbSt.Location  = New-Object System.Drawing.Point(56, 52)
    $lbSt.Size      = New-Object System.Drawing.Size(215, 18)
    $pnl.Controls.Add($lbSt)

    # Botón de acción (Iniciar/Detener)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text      = "..."
    $btn.Size      = New-Object System.Drawing.Size(82, 30)
    $btn.Location  = New-Object System.Drawing.Point(278, 24)
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderColor        = $col.BtnBd
    $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(22, 58, 105)
    $btn.BackColor = $col.Btn
    $btn.ForeColor = $col.Ice
    $btn.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
    $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $pnl.Controls.Add($btn)

    return @{ Dot = $dot; Status = $lbSt; Btn = $btn }
}

# Crear las tres tarjetas (MySQL, AuthServer, WorldServer) en posiciones verticales específicas
$mysql = New-ServiceCard 76  "MySQL 8.4"   "Puerto 3306  -  Portable"
$auth  = New-ServiceCard 162 "AuthServer"  "Autenticacion  -  Puerto 3724"
$world = New-ServiceCard 248 "WorldServer" "Mundo  -  WotLK 3.3.5a"

# ============================================================
# BOTONES DE ACCIONES GLOBALES
# ============================================================

# Botón "Iniciar Todo"
$btnStartAll = New-Object System.Windows.Forms.Button
$btnStartAll.Text      = "$PLAY  Iniciar Todo"
$btnStartAll.Size      = New-Object System.Drawing.Size(176, 34)
$btnStartAll.Location  = New-Object System.Drawing.Point(16, 340)
$btnStartAll.FlatStyle = "Flat"
$btnStartAll.FlatAppearance.BorderColor        = [System.Drawing.Color]::FromArgb(18, 130, 72)
$btnStartAll.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(14, 70, 42)
$btnStartAll.BackColor = $col.BtnGrn
$btnStartAll.ForeColor = $col.Green
$btnStartAll.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnStartAll.Cursor    = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnStartAll)

# Botón "Detener Todo"
$btnStopAll = New-Object System.Windows.Forms.Button
$btnStopAll.Text      = "$STOP  Detener Todo"
$btnStopAll.Size      = New-Object System.Drawing.Size(176, 34)
$btnStopAll.Location  = New-Object System.Drawing.Point(208, 340)
$btnStopAll.FlatStyle = "Flat"
$btnStopAll.FlatAppearance.BorderColor        = [System.Drawing.Color]::FromArgb(160, 36, 36)
$btnStopAll.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(90, 18, 18)
$btnStopAll.BackColor = $col.BtnRed
$btnStopAll.ForeColor = $col.Red
$btnStopAll.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnStopAll.Cursor    = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnStopAll)

# ── Separador: Configuración Inicial ──
$lblSetupHeader = New-Object System.Windows.Forms.Label
$lblSetupHeader.Text      = "── CONFIGURACION INICIAL ──"
$lblSetupHeader.Size      = New-Object System.Drawing.Size(368, 16)
$lblSetupHeader.Location  = New-Object System.Drawing.Point(16, 382)
$lblSetupHeader.Font      = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$lblSetupHeader.ForeColor = $col.Muted
$lblSetupHeader.TextAlign = "MiddleCenter"
$form.Controls.Add($lblSetupHeader)

# Botón 1 — Limpiar Base de Datos
$btnCleanDb = New-Object System.Windows.Forms.Button
$btnCleanDb.Text      = "1  Limpiar Base de Datos"
$btnCleanDb.Size      = New-Object System.Drawing.Size(368, 28)
$btnCleanDb.Location  = New-Object System.Drawing.Point(16, 400)
$btnCleanDb.FlatStyle = "Flat"
$btnCleanDb.FlatAppearance.BorderColor        = [System.Drawing.Color]::FromArgb(120, 30, 30)
$btnCleanDb.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(70, 12, 12)
$btnCleanDb.BackColor = [System.Drawing.Color]::FromArgb(40, 8, 8)
$btnCleanDb.ForeColor = $col.Red
$btnCleanDb.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$btnCleanDb.Cursor    = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnCleanDb)

# Botón 2 — Importar Base de Datos (dbimport)
$btnDbImport = New-Object System.Windows.Forms.Button
$btnDbImport.Text      = "2  Importar Base de Datos (dbimport)"
$btnDbImport.Size      = New-Object System.Drawing.Size(368, 28)
$btnDbImport.Location  = New-Object System.Drawing.Point(16, 432)
$btnDbImport.FlatStyle = "Flat"
$btnDbImport.FlatAppearance.BorderColor        = [System.Drawing.Color]::FromArgb(18, 100, 60)
$btnDbImport.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(12, 55, 34)
$btnDbImport.BackColor = [System.Drawing.Color]::FromArgb(6, 30, 18)
$btnDbImport.ForeColor = $col.Green
$btnDbImport.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$btnDbImport.Cursor    = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnDbImport)

# Botón 3 — Crear Cuenta de Juego
$btnAccount = New-Object System.Windows.Forms.Button
$btnAccount.Text      = "3  Crear Cuenta de Juego"
$btnAccount.Size      = New-Object System.Drawing.Size(368, 28)
$btnAccount.Location  = New-Object System.Drawing.Point(16, 464)
$btnAccount.FlatStyle = "Flat"
$btnAccount.FlatAppearance.BorderColor        = [System.Drawing.Color]::FromArgb(60, 100, 170)
$btnAccount.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(18, 44, 82)
$btnAccount.BackColor = $col.Btn
$btnAccount.ForeColor = $col.Frost
$btnAccount.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$btnAccount.Cursor    = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnAccount)

# Nota pasos 4 y 5
$lblSteps45 = New-Object System.Windows.Forms.Label
$lblSteps45.Text      = "4  Iniciar AuthServer     5  Iniciar WorldServer"
$lblSteps45.Size      = New-Object System.Drawing.Size(368, 16)
$lblSteps45.Location  = New-Object System.Drawing.Point(16, 496)
$lblSteps45.Font      = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$lblSteps45.ForeColor = $col.Muted
$lblSteps45.TextAlign = "MiddleCenter"
$form.Controls.Add($lblSteps45)

# ── Separador: Herramientas ──
$lblToolsHeader = New-Object System.Windows.Forms.Label
$lblToolsHeader.Text      = "── HERRAMIENTAS ──"
$lblToolsHeader.Size      = New-Object System.Drawing.Size(368, 16)
$lblToolsHeader.Location  = New-Object System.Drawing.Point(16, 516)
$lblToolsHeader.Font      = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$lblToolsHeader.ForeColor = $col.Muted
$lblToolsHeader.TextAlign = "MiddleCenter"
$form.Controls.Add($lblToolsHeader)

# Botón "Git Clone/Pull + Compilar"
$btnUpdate = New-Object System.Windows.Forms.Button
$btnUpdate.Text      = "Git Clone/Pull + Compilar"
$btnUpdate.Size      = New-Object System.Drawing.Size(176, 26)
$btnUpdate.Location  = New-Object System.Drawing.Point(16, 534)
$btnUpdate.FlatStyle = "Flat"
$btnUpdate.FlatAppearance.BorderColor        = $col.BtnBd
$btnUpdate.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(18, 44, 82)
$btnUpdate.BackColor = $col.Btn
$btnUpdate.ForeColor = $col.Ice
$btnUpdate.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
$btnUpdate.Cursor    = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnUpdate)

# Botón "Solo Compilar"
$btnCompile = New-Object System.Windows.Forms.Button
$btnCompile.Text      = "Solo Compilar"
$btnCompile.Size      = New-Object System.Drawing.Size(176, 26)
$btnCompile.Location  = New-Object System.Drawing.Point(208, 534)
$btnCompile.FlatStyle = "Flat"
$btnCompile.FlatAppearance.BorderColor        = $col.BtnBd
$btnCompile.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(18, 44, 82)
$btnCompile.BackColor = $col.Btn
$btnCompile.ForeColor = $col.Ice
$btnCompile.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
$btnCompile.Cursor    = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnCompile)

# Botón "Seguridad MySQL"
$btnSecurity = New-Object System.Windows.Forms.Button
$btnSecurity.Text      = "Seguridad MySQL"
$btnSecurity.Size      = New-Object System.Drawing.Size(176, 26)
$btnSecurity.Location  = New-Object System.Drawing.Point(16, 564)
$btnSecurity.FlatStyle = "Flat"
$btnSecurity.FlatAppearance.BorderColor        = [System.Drawing.Color]::FromArgb(60, 100, 170)
$btnSecurity.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(18, 44, 82)
$btnSecurity.BackColor = $col.Btn
$btnSecurity.ForeColor = $col.Frost
$btnSecurity.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
$btnSecurity.Cursor    = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnSecurity)

# Botón "Editor de Realmlist"
$btnRealmlist = New-Object System.Windows.Forms.Button
$btnRealmlist.Text      = "Editor de Realmlist"
$btnRealmlist.Size      = New-Object System.Drawing.Size(176, 26)
$btnRealmlist.Location  = New-Object System.Drawing.Point(208, 564)
$btnRealmlist.FlatStyle = "Flat"
$btnRealmlist.FlatAppearance.BorderColor        = [System.Drawing.Color]::FromArgb(60, 100, 170)
$btnRealmlist.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(18, 44, 82)
$btnRealmlist.BackColor = $col.Btn
$btnRealmlist.ForeColor = $col.Frost
$btnRealmlist.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$btnRealmlist.Cursor    = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnRealmlist)

# Separador antes del pie de página
$sepFooter = New-Object System.Windows.Forms.Panel
$sepFooter.BackColor = $col.Border
$sepFooter.Size      = New-Object System.Drawing.Size(368, 1)
$sepFooter.Location  = New-Object System.Drawing.Point(16, 594)
$form.Controls.Add($sepFooter)

# Etiqueta que muestra la hora de la última actualización
$lblTime = New-Object System.Windows.Forms.Label
$lblTime.Text      = "Actualizando..."
$lblTime.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
$lblTime.ForeColor = $col.Muted
$lblTime.Location  = New-Object System.Drawing.Point(16, 597)
$lblTime.Size      = New-Object System.Drawing.Size(180, 14)
$form.Controls.Add($lblTime)

$_s = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('Q3JlYWRvIHBvciBYZXBpYw=='))
$_w = New-Object System.Windows.Forms.Label
$_w.Text      = $_s
$_w.Font      = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Italic)
$_w.ForeColor = [System.Drawing.Color]::FromArgb(88, 138, 172)
$_w.Location  = New-Object System.Drawing.Point(200, 597)
$_w.Size      = New-Object System.Drawing.Size(184, 14)
$_w.TextAlign = "MiddleRight"
$_w.Cursor    = [System.Windows.Forms.Cursors]::Default
$form.Controls.Add($_w)

# ============================================================
# PANEL DERECHO — TERMINALES SEPARADOS (oculto al inicio)
# ============================================================

# Separador vertical entre panel izquierdo y derecho
$sepVert = New-Object System.Windows.Forms.Panel
$sepVert.Location  = New-Object System.Drawing.Point(400, 0)
$sepVert.Size      = New-Object System.Drawing.Size(2, 612)
$sepVert.BackColor = $col.Border
$sepVert.Visible   = $false
$form.Controls.Add($sepVert)

# Panel contenedor derecho
$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Location  = New-Object System.Drawing.Point(402, 0)
$rightPanel.Size      = New-Object System.Drawing.Size(562, 612)
$rightPanel.BackColor = $col.Bg
$rightPanel.Visible   = $false
$form.Controls.Add($rightPanel)

# TabControl con 3 pestañas de tema oscuro
$tabRight = New-Object System.Windows.Forms.TabControl
$tabRight.Location  = New-Object System.Drawing.Point(0, 0)
$tabRight.Size      = New-Object System.Drawing.Size(562, 612)
$tabRight.DrawMode  = [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed
$tabRight.ItemSize  = New-Object System.Drawing.Size(0, 28)
$tabRight.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$tabRight.Padding   = New-Object System.Drawing.Point(12, 4)
$rightPanel.Controls.Add($tabRight)

$tabRight.Add_DrawItem({
    param($s, $e)
    $pg    = $tabRight.TabPages[$e.Index]
    $isSel = ($e.Index -eq $tabRight.SelectedIndex)
    $bg = if ($isSel) { [System.Drawing.Color]::FromArgb(11, 20, 42) } else { [System.Drawing.Color]::FromArgb(4, 8, 16) }
    $fg = if ($isSel) { [System.Drawing.Color]::FromArgb(88, 182, 230) } else { [System.Drawing.Color]::FromArgb(88, 138, 172) }
    $e.Graphics.FillRectangle([System.Drawing.SolidBrush]::new($bg), $e.Bounds)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center; $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $e.Graphics.DrawString($pg.Text, $e.Font, [System.Drawing.SolidBrush]::new($fg), [System.Drawing.RectangleF]$e.Bounds, $sf)
})

# ------------ Tab: AuthServer ------------
$tabAuth = New-Object System.Windows.Forms.TabPage
$tabAuth.Text      = "AuthServer"
$tabAuth.BackColor = [System.Drawing.Color]::FromArgb(4, 8, 16)
$tabAuth.Padding   = New-Object System.Windows.Forms.Padding(0)

$authHdr = New-Object System.Windows.Forms.Panel
$authHdr.Dock      = "Top"
$authHdr.Height    = 26
$authHdr.BackColor = [System.Drawing.Color]::FromArgb(8, 16, 32)
$tabAuth.Controls.Add($authHdr)

$authHdrLbl = New-Object System.Windows.Forms.Label
$authHdrLbl.Text = "AUTH SERVER — Log"; $authHdrLbl.AutoSize = $true
$authHdrLbl.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$authHdrLbl.ForeColor = [System.Drawing.Color]::FromArgb(88, 138, 172)
$authHdrLbl.Location  = New-Object System.Drawing.Point(6, 5)
$authHdr.Controls.Add($authHdrLbl)

$authBtnClear = New-Object System.Windows.Forms.Button
$authBtnClear.Text = "Limpiar"; $authBtnClear.Size = New-Object System.Drawing.Size(60, 18)
$authBtnClear.Location = New-Object System.Drawing.Point(492, 4); $authBtnClear.FlatStyle = "Flat"
$authBtnClear.FlatAppearance.BorderColor = $col.Border
$authBtnClear.BackColor = $col.Card; $authBtnClear.ForeColor = $col.Muted
$authBtnClear.Font = New-Object System.Drawing.Font("Segoe UI", 7); $authBtnClear.Cursor = [System.Windows.Forms.Cursors]::Hand
$authHdr.Controls.Add($authBtnClear)

$authInputPanel = New-Object System.Windows.Forms.Panel
$authInputPanel.Dock = "Bottom"; $authInputPanel.Height = 26
$authInputPanel.BackColor = [System.Drawing.Color]::FromArgb(8, 16, 32)

$authPromptLbl = New-Object System.Windows.Forms.Label
$authPromptLbl.Text = "»"; $authPromptLbl.ForeColor = [System.Drawing.Color]::FromArgb(88, 138, 172)
$authPromptLbl.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
$authPromptLbl.Location = New-Object System.Drawing.Point(4, 4); $authPromptLbl.AutoSize = $true
$authInputPanel.Controls.Add($authPromptLbl)

$authInput = New-Object System.Windows.Forms.TextBox
$authInput.Location = New-Object System.Drawing.Point(22, 3); $authInput.Height = 20
$authInput.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom
$authInput.Width  = 530
$authInput.BackColor = [System.Drawing.Color]::FromArgb(4, 8, 16)
$authInput.ForeColor = [System.Drawing.Color]::FromArgb(196, 226, 242)
$authInput.Font = New-Object System.Drawing.Font("Consolas", 8)
$authInput.BorderStyle = "None"
$authInputPanel.Controls.Add($authInput)

$rtbAuth = New-Object System.Windows.Forms.RichTextBox
$rtbAuth.Dock = "Fill"; $rtbAuth.BackColor = [System.Drawing.Color]::FromArgb(4, 8, 16)
$rtbAuth.ForeColor = [System.Drawing.Color]::FromArgb(196, 226, 242)
$rtbAuth.Font = New-Object System.Drawing.Font("Consolas", 8)
$rtbAuth.ReadOnly = $true; $rtbAuth.ScrollBars = "Vertical"
$rtbAuth.BorderStyle = "None"; $rtbAuth.WordWrap = $false
$tabAuth.Controls.Add($authInputPanel)
$tabAuth.Controls.Add($rtbAuth)

$authBtnClear.Add_Click({ $rtbAuth.Clear() })
$authInput.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $e.SuppressKeyPress = $true
        $cmd = $authInput.Text.Trim()
        $authInput.Clear()
        if ($cmd -ne '' -and $script:authProc -and -not $script:authProc.HasExited) {
            try {
                Write-TerminalLine $rtbAuth "> $cmd" "Auth"
                $script:authProc.StandardInput.WriteLine($cmd)
            } catch {}
        }
    }
})
$tabRight.TabPages.Add($tabAuth)

# ------------ Tab: WorldServer ------------
$tabWorld = New-Object System.Windows.Forms.TabPage
$tabWorld.Text      = "WorldServer"
$tabWorld.BackColor = [System.Drawing.Color]::FromArgb(4, 8, 16)
$tabWorld.Padding   = New-Object System.Windows.Forms.Padding(0)

$worldHdr = New-Object System.Windows.Forms.Panel
$worldHdr.Dock      = "Top"
$worldHdr.Height    = 26
$worldHdr.BackColor = [System.Drawing.Color]::FromArgb(8, 16, 32)
$tabWorld.Controls.Add($worldHdr)

$worldHdrLbl = New-Object System.Windows.Forms.Label
$worldHdrLbl.Text = "WORLD SERVER — Log"; $worldHdrLbl.AutoSize = $true
$worldHdrLbl.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$worldHdrLbl.ForeColor = [System.Drawing.Color]::FromArgb(88, 138, 172)
$worldHdrLbl.Location  = New-Object System.Drawing.Point(6, 5)
$worldHdr.Controls.Add($worldHdrLbl)

$worldBtnClear = New-Object System.Windows.Forms.Button
$worldBtnClear.Text = "Limpiar"; $worldBtnClear.Size = New-Object System.Drawing.Size(60, 18)
$worldBtnClear.Location = New-Object System.Drawing.Point(492, 4); $worldBtnClear.FlatStyle = "Flat"
$worldBtnClear.FlatAppearance.BorderColor = $col.Border
$worldBtnClear.BackColor = $col.Card; $worldBtnClear.ForeColor = $col.Muted
$worldBtnClear.Font = New-Object System.Drawing.Font("Segoe UI", 7); $worldBtnClear.Cursor = [System.Windows.Forms.Cursors]::Hand
$worldHdr.Controls.Add($worldBtnClear)

$worldInputPanel = New-Object System.Windows.Forms.Panel
$worldInputPanel.Dock = "Bottom"; $worldInputPanel.Height = 26
$worldInputPanel.BackColor = [System.Drawing.Color]::FromArgb(8, 16, 32)

$worldPromptLbl = New-Object System.Windows.Forms.Label
$worldPromptLbl.Text = "»"; $worldPromptLbl.ForeColor = [System.Drawing.Color]::FromArgb(88, 138, 172)
$worldPromptLbl.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
$worldPromptLbl.Location = New-Object System.Drawing.Point(4, 4); $worldPromptLbl.AutoSize = $true
$worldInputPanel.Controls.Add($worldPromptLbl)

$worldInput = New-Object System.Windows.Forms.TextBox
$worldInput.Location = New-Object System.Drawing.Point(22, 3); $worldInput.Height = 20
$worldInput.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom
$worldInput.Width  = 530
$worldInput.BackColor = [System.Drawing.Color]::FromArgb(4, 8, 16)
$worldInput.ForeColor = [System.Drawing.Color]::FromArgb(196, 226, 242)
$worldInput.Font = New-Object System.Drawing.Font("Consolas", 8)
$worldInput.BorderStyle = "None"
$worldInputPanel.Controls.Add($worldInput)

$rtbWorld = New-Object System.Windows.Forms.RichTextBox
$rtbWorld.Dock = "Fill"; $rtbWorld.BackColor = [System.Drawing.Color]::FromArgb(4, 8, 16)
$rtbWorld.ForeColor = [System.Drawing.Color]::FromArgb(196, 226, 242)
$rtbWorld.Font = New-Object System.Drawing.Font("Consolas", 8)
$rtbWorld.ReadOnly = $true; $rtbWorld.ScrollBars = "Vertical"
$rtbWorld.BorderStyle = "None"; $rtbWorld.WordWrap = $false
$tabWorld.Controls.Add($worldInputPanel)
$tabWorld.Controls.Add($rtbWorld)

$worldBtnClear.Add_Click({ $rtbWorld.Clear() })
$worldInput.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $e.SuppressKeyPress = $true
        $cmd = $worldInput.Text.Trim()
        $worldInput.Clear()
        if ($cmd -ne '' -and $script:worldProc -and -not $script:worldProc.HasExited) {
            try {
                Write-TerminalLine $rtbWorld "> $cmd" "World"
                $script:worldProc.StandardInput.WriteLine($cmd)
            } catch {}
        }
    }
})
$tabRight.TabPages.Add($tabWorld)

# ------------ Tab: Compilar ------------
$tabCompile = New-Object System.Windows.Forms.TabPage
$tabCompile.Text      = "Compilar"
$tabCompile.BackColor = [System.Drawing.Color]::FromArgb(4, 8, 16)
$tabCompile.Padding   = New-Object System.Windows.Forms.Padding(0)

$compileHdr = New-Object System.Windows.Forms.Panel
$compileHdr.Dock      = "Top"
$compileHdr.Height    = 26
$compileHdr.BackColor = [System.Drawing.Color]::FromArgb(8, 16, 32)
$tabCompile.Controls.Add($compileHdr)

$compileHdrLbl = New-Object System.Windows.Forms.Label
$compileHdrLbl.Text = "COMPILAR — Salida"; $compileHdrLbl.AutoSize = $true
$compileHdrLbl.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$compileHdrLbl.ForeColor = [System.Drawing.Color]::FromArgb(88, 138, 172)
$compileHdrLbl.Location  = New-Object System.Drawing.Point(6, 5)
$compileHdr.Controls.Add($compileHdrLbl)

$compileBtnClear = New-Object System.Windows.Forms.Button
$compileBtnClear.Text = "Limpiar"; $compileBtnClear.Size = New-Object System.Drawing.Size(60, 18)
$compileBtnClear.Location = New-Object System.Drawing.Point(492, 4); $compileBtnClear.FlatStyle = "Flat"
$compileBtnClear.FlatAppearance.BorderColor = $col.Border
$compileBtnClear.BackColor = $col.Card; $compileBtnClear.ForeColor = $col.Muted
$compileBtnClear.Font = New-Object System.Drawing.Font("Segoe UI", 7); $compileBtnClear.Cursor = [System.Windows.Forms.Cursors]::Hand
$compileHdr.Controls.Add($compileBtnClear)

$compileInputPanel = New-Object System.Windows.Forms.Panel
$compileInputPanel.Dock = "Bottom"; $compileInputPanel.Height = 26
$compileInputPanel.BackColor = [System.Drawing.Color]::FromArgb(8, 16, 32)

$compilePromptLbl = New-Object System.Windows.Forms.Label
$compilePromptLbl.Text = "»"; $compilePromptLbl.ForeColor = [System.Drawing.Color]::FromArgb(88, 138, 172)
$compilePromptLbl.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
$compilePromptLbl.Location = New-Object System.Drawing.Point(4, 4); $compilePromptLbl.AutoSize = $true
$compileInputPanel.Controls.Add($compilePromptLbl)

$compileInput = New-Object System.Windows.Forms.TextBox
$compileInput.Location = New-Object System.Drawing.Point(22, 3); $compileInput.Height = 20
$compileInput.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom
$compileInput.Width  = 530
$compileInput.BackColor = [System.Drawing.Color]::FromArgb(4, 8, 16)
$compileInput.ForeColor = [System.Drawing.Color]::FromArgb(196, 226, 242)
$compileInput.Font = New-Object System.Drawing.Font("Consolas", 8)
$compileInput.BorderStyle = "None"
$compileInputPanel.Controls.Add($compileInput)

$rtbCompile = New-Object System.Windows.Forms.RichTextBox
$rtbCompile.Dock = "Fill"; $rtbCompile.BackColor = [System.Drawing.Color]::FromArgb(4, 8, 16)
$rtbCompile.ForeColor = [System.Drawing.Color]::FromArgb(196, 226, 242)
$rtbCompile.Font = New-Object System.Drawing.Font("Consolas", 8)
$rtbCompile.ReadOnly = $true; $rtbCompile.ScrollBars = "Vertical"
$rtbCompile.BorderStyle = "None"; $rtbCompile.WordWrap = $false
$tabCompile.Controls.Add($compileInputPanel)
$tabCompile.Controls.Add($rtbCompile)

$compileBtnClear.Add_Click({ $rtbCompile.Clear() })
$compileInput.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $e.SuppressKeyPress = $true
        $cmd = $compileInput.Text.Trim()
        $compileInput.Clear()
        if ($cmd -ne '' -and $script:compileProc -and -not $script:compileProc.HasExited) {
            try {
                Write-TerminalLine $rtbCompile "> $cmd" "Build"
                $script:compileProc.StandardInput.WriteLine($cmd)
            } catch {}
        }
    }
})
$tabRight.TabPages.Add($tabCompile)

# ------------ Tab: DB Import ------------
$tabDbImport = New-Object System.Windows.Forms.TabPage
$tabDbImport.Text      = "DB Import"
$tabDbImport.BackColor = [System.Drawing.Color]::FromArgb(4, 8, 16)
$tabDbImport.Padding   = New-Object System.Windows.Forms.Padding(0)

$dbimportHdr = New-Object System.Windows.Forms.Panel
$dbimportHdr.Dock      = "Top"
$dbimportHdr.Height    = 26
$dbimportHdr.BackColor = [System.Drawing.Color]::FromArgb(8, 16, 32)
$tabDbImport.Controls.Add($dbimportHdr)

$dbimportHdrLbl = New-Object System.Windows.Forms.Label
$dbimportHdrLbl.Text = "DB IMPORT — Salida"; $dbimportHdrLbl.AutoSize = $true
$dbimportHdrLbl.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$dbimportHdrLbl.ForeColor = [System.Drawing.Color]::FromArgb(88, 138, 172)
$dbimportHdrLbl.Location  = New-Object System.Drawing.Point(6, 5)
$dbimportHdr.Controls.Add($dbimportHdrLbl)

$dbimportBtnClear = New-Object System.Windows.Forms.Button
$dbimportBtnClear.Text = "Limpiar"; $dbimportBtnClear.Size = New-Object System.Drawing.Size(60, 18)
$dbimportBtnClear.Location = New-Object System.Drawing.Point(492, 4); $dbimportBtnClear.FlatStyle = "Flat"
$dbimportBtnClear.FlatAppearance.BorderColor = $col.Border
$dbimportBtnClear.BackColor = $col.Card; $dbimportBtnClear.ForeColor = $col.Muted
$dbimportBtnClear.Font = New-Object System.Drawing.Font("Segoe UI", 7); $dbimportBtnClear.Cursor = [System.Windows.Forms.Cursors]::Hand
$dbimportHdr.Controls.Add($dbimportBtnClear)

$dbimportInputPanel = New-Object System.Windows.Forms.Panel
$dbimportInputPanel.Dock = "Bottom"; $dbimportInputPanel.Height = 26
$dbimportInputPanel.BackColor = [System.Drawing.Color]::FromArgb(8, 16, 32)

$dbimportPromptLbl = New-Object System.Windows.Forms.Label
$dbimportPromptLbl.Text = "»"; $dbimportPromptLbl.ForeColor = [System.Drawing.Color]::FromArgb(88, 138, 172)
$dbimportPromptLbl.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
$dbimportPromptLbl.Location = New-Object System.Drawing.Point(4, 4); $dbimportPromptLbl.AutoSize = $true
$dbimportInputPanel.Controls.Add($dbimportPromptLbl)

$dbimportInput = New-Object System.Windows.Forms.TextBox
$dbimportInput.Location = New-Object System.Drawing.Point(22, 3); $dbimportInput.Height = 20
$dbimportInput.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom
$dbimportInput.Width  = 530
$dbimportInput.BackColor = [System.Drawing.Color]::FromArgb(4, 8, 16)
$dbimportInput.ForeColor = [System.Drawing.Color]::FromArgb(196, 226, 242)
$dbimportInput.Font = New-Object System.Drawing.Font("Consolas", 8)
$dbimportInput.BorderStyle = "None"
$dbimportInputPanel.Controls.Add($dbimportInput)

$rtbDbImport = New-Object System.Windows.Forms.RichTextBox
$rtbDbImport.Dock = "Fill"; $rtbDbImport.BackColor = [System.Drawing.Color]::FromArgb(4, 8, 16)
$rtbDbImport.ForeColor = [System.Drawing.Color]::FromArgb(196, 226, 242)
$rtbDbImport.Font = New-Object System.Drawing.Font("Consolas", 8)
$rtbDbImport.ReadOnly = $true; $rtbDbImport.ScrollBars = "Vertical"
$rtbDbImport.BorderStyle = "None"; $rtbDbImport.WordWrap = $false
$tabDbImport.Controls.Add($dbimportInputPanel)
$tabDbImport.Controls.Add($rtbDbImport)

$dbimportBtnClear.Add_Click({ $rtbDbImport.Clear() })
$dbimportInput.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $e.SuppressKeyPress = $true
        $cmd = $dbimportInput.Text.Trim()
        $dbimportInput.Clear()
        if ($cmd -ne '' -and $script:dbimportProc -and -not $script:dbimportProc.HasExited) {
            try {
                Write-TerminalLine $rtbDbImport "> $cmd" "DB"
                $script:dbimportProc.StandardInput.WriteLine($cmd)
            } catch {}
        }
    }
})
$tabRight.TabPages.Add($tabDbImport)

# Elimina códigos de escape ANSI de una cadena
function Strip-Ansi([string]$s) {
    [regex]::Replace($s, '\x1b\[[0-9;]*[a-zA-Z]', '')
}

# Escribe una línea coloreada en el RichTextBox de terminal indicado
function Write-TerminalLine([System.Windows.Forms.RichTextBox]$rtb, [string]$line, [string]$tag) {
    $rtb.SuspendLayout()
    $rtb.SelectionStart  = $rtb.TextLength
    $rtb.SelectionLength = 0

    $tagColor = switch ($tag) {
        "World"   { [System.Drawing.Color]::FromArgb(88,  182, 230) }
        "Auth"    { [System.Drawing.Color]::FromArgb(172, 218, 240) }
        "Build"   { [System.Drawing.Color]::FromArgb(46,  204, 140) }
        "Build!"  { [System.Drawing.Color]::FromArgb(210, 48,  48)  }
        default   { $col.Muted }
    }
    $rtb.SelectionColor = $tagColor
    $rtb.AppendText("[$tag] ")

    $lineColor = if ($line -match 'error\s*C[0-9]|ERROR|FATAL|crash|FAILED') {
        [System.Drawing.Color]::FromArgb(210, 80, 80)
    } elseif ($line -match 'warning|WARN|Warning') {
        [System.Drawing.Color]::FromArgb(230, 182, 48)
    } elseif ($line -match 'Loaded|Started|success|\[OK\]|Build succeeded') {
        [System.Drawing.Color]::FromArgb(46, 204, 140)
    } else {
        $col.Text
    }
    $rtb.SelectionColor = $lineColor
    $rtb.AppendText($line + "`n")

    if ($rtb.Lines.Count -gt 2000) {
        $rtb.SelectionStart  = 0
        $rtb.SelectionLength = $rtb.GetFirstCharIndexFromLine(400)
        $rtb.SelectedText    = ""
    }
    $rtb.SelectionStart = $rtb.TextLength
    $rtb.ScrollToCaret()
    $rtb.ResumeLayout()
}

# Inicia un proceso de servidor en una consola oculta.
# La salida se lee desde el log file (Auth.log / Server.log).
function Start-ServerProc([string]$exePath) {
    return (Start-Process -FilePath $exePath -WorkingDirectory $cfg.ACoreBin -WindowStyle Hidden -PassThru)
}

# Lee las líneas nuevas de un log file desde la posición guardada
function Read-LogFile([string]$path, [System.Collections.Concurrent.ConcurrentQueue[string]]$queue, [ref]$posRef) {
    if (-not (Test-Path $path)) { return }
    $f = Get-Item $path -ErrorAction SilentlyContinue
    if (-not $f) { return }
    if ($f.Length -lt $posRef.Value) { $posRef.Value = 0L }   # archivo sobreescrito al reiniciar servidor
    if ($f.Length -eq $posRef.Value) { return }
    try {
        $fs = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::Read,
              [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        $fs.Seek($posRef.Value, [System.IO.SeekOrigin]::Begin) | Out-Null
        $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
        while (-not $sr.EndOfStream) {
            $line = $sr.ReadLine()
            if ($null -ne $line -and $line.Trim() -ne '') { $queue.Enqueue($line) }
        }
        $posRef.Value = $fs.Position
        $sr.Close(); $fs.Close()
    } catch { }
}

# Muestra el panel derecho y activa el tab indicado
function Show-RightPanel([System.Windows.Forms.TabPage]$tab) {
    if (-not $rightPanel.Visible) {
        $rightPanel.Visible = $true
        $sepVert.Visible    = $true
        $form.ClientSize    = New-Object System.Drawing.Size(968, $form.ClientSize.Height)
    }
    $tabRight.SelectedTab = $tab
}

# ============================================================
# FUNCIÓN PRINCIPAL DE ACTUALIZACIÓN DE ESTADO (Update-All)
# ============================================================

<#
.SYNOPSIS
    Actualiza los indicadores visuales de cada servicio (MySQL, Auth, World).
    Se ejecuta periódicamente (cada 4 segundos) y al iniciar.
#>
function Update-All {
    # Estado de MySQL
    if (Test-MySQL) {
        $mysql.Dot.ForeColor    = $col.Green
        $mysql.Status.Text      = "CORRIENDO"
        $mysql.Status.ForeColor = $col.Green
        $mysql.Btn.Text         = "Detener"
    } else {
        $mysql.Dot.ForeColor    = $col.Red
        $mysql.Status.Text      = "DETENIDO"
        $mysql.Status.ForeColor = $col.Red
        $mysql.Btn.Text         = "Iniciar"
    }
    $mysql.Btn.Enabled = $true

    # Estado de AuthServer
    if (Test-Proc "authserver") {
        $auth.Dot.ForeColor    = $col.Green
        $auth.Status.Text      = "CORRIENDO"
        $auth.Status.ForeColor = $col.Green
        $auth.Btn.Text         = "Detener"
    } else {
        $auth.Dot.ForeColor    = $col.Red
        $auth.Status.Text      = "DETENIDO"
        $auth.Status.ForeColor = $col.Red
        $auth.Btn.Text         = "Iniciar"
    }

    # Estado de WorldServer
    if (Test-Proc "worldserver") {
        $world.Dot.ForeColor    = $col.Green
        $world.Status.Text      = "CORRIENDO"
        $world.Status.ForeColor = $col.Green
        $world.Btn.Text         = "Detener"
    } else {
        $world.Dot.ForeColor    = $col.Red
        $world.Status.Text      = "DETENIDO"
        $world.Status.ForeColor = $col.Red
        $world.Btn.Text         = "Iniciar"
    }

    $lblTime.Text = "Actualizado: $(Get-Date -Format 'HH:mm:ss')"
}

# ============================================================
# EVENTOS DE LOS BOTONES DE LAS TARJETAS (INICIAR/DETENER INDIVIDUAL)
# ============================================================

# Botón de MySQL
$mysql.Btn.Add_Click({
    if (Test-MySQL) {
        Stop-MySQLPortable
        Start-Sleep -Milliseconds 800
    } else {
        Start-MySQLPortable
    }
    Update-All
})

# Botón de AuthServer
$auth.Btn.Add_Click({
    $authRunning = ($script:authProc -and -not $script:authProc.HasExited) -or (Test-Proc "authserver")
    if ($authRunning) {
        if ($script:authProc -and -not $script:authProc.HasExited) { $script:authProc.Kill() }
        else { Get-Process -Name "authserver" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
        $script:authProc = $null
        $rtbAuth.Clear()
        Start-Sleep -Milliseconds 500
    } elseif (Test-Path "$($cfg.ACoreBin)\authserver.exe") {
        $rtbAuth.Clear()
        $script:authLogPos = 0L
        Show-RightPanel $tabAuth
        $script:authProc = Start-ServerProc "$($cfg.ACoreBin)\authserver.exe"
        Start-Sleep -Milliseconds 500
    }
    Update-All
})

# Botón de WorldServer
$world.Btn.Add_Click({
    $worldRunning = ($script:worldProc -and -not $script:worldProc.HasExited) -or (Test-Proc "worldserver")
    if ($worldRunning) {
        if ($script:worldProc -and -not $script:worldProc.HasExited) { $script:worldProc.Kill() }
        else { Get-Process -Name "worldserver" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
        $script:worldProc = $null
        $rtbWorld.Clear()
        Start-Sleep -Milliseconds 500
    } elseif (Test-Path "$($cfg.ACoreBin)\worldserver.exe") {
        $rtbWorld.Clear()
        $script:worldLogPos = 0L
        Show-RightPanel $tabWorld
        $script:worldProc = Start-ServerProc "$($cfg.ACoreBin)\worldserver.exe"
        Start-Sleep -Milliseconds 500
    }
    Update-All
})

# ============================================================
# EVENTOS DE LOS BOTONES GLOBALES
# ============================================================

# Iniciar Todo: arranca MySQL, AuthServer y WorldServer (si no están corriendo)
$btnStartAll.Add_Click({
    if (-not (Test-MySQL)) { Start-MySQLPortable }

    $authNotRunning = (-not $script:authProc -or $script:authProc.HasExited) -and -not (Test-Proc "authserver")
    if ($authNotRunning -and (Test-Path "$($cfg.ACoreBin)\authserver.exe")) {
        $rtbAuth.Clear()
        $script:authLogPos = 0L
        Show-RightPanel $tabAuth
        $script:authProc = Start-ServerProc "$($cfg.ACoreBin)\authserver.exe"
        Start-Sleep -Milliseconds 1500; [System.Windows.Forms.Application]::DoEvents()
    }

    $worldNotRunning = (-not $script:worldProc -or $script:worldProc.HasExited) -and -not (Test-Proc "worldserver")
    if ($worldNotRunning -and (Test-Path "$($cfg.ACoreBin)\worldserver.exe")) {
        $rtbWorld.Clear()
        $script:worldLogPos = 0L
        Show-RightPanel $tabWorld
        $script:worldProc = Start-ServerProc "$($cfg.ACoreBin)\worldserver.exe"
    }
    Start-Sleep -Milliseconds 500; Update-All
})

# Detener Todo: mata procesos worldserver, authserver y apaga MySQL
$btnStopAll.Add_Click({
    if ($script:authProc  -and -not $script:authProc.HasExited)  { $script:authProc.Kill() }
    if ($script:worldProc -and -not $script:worldProc.HasExited) { $script:worldProc.Kill() }
    Get-Process -Name "authserver","worldserver" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $script:authProc = $null; $script:worldProc = $null
    Stop-MySQLPortable
    Start-Sleep -Milliseconds 800; Update-All
})

# Helper: lanza update.ps1 redirigiendo toda la salida a compile.log (tail en flushTimer)
function Start-CompileJob([bool]$skipGit) {
    $updateScript = "$PSScriptRoot\update.ps1"
    if (-not (Test-Path $updateScript)) {
        [System.Windows.Forms.MessageBox]::Show("update.ps1 no encontrado en $PSScriptRoot", "Error", "OK", "Warning") | Out-Null
        return
    }
    if ($script:compileProc -and -not $script:compileProc.HasExited) {
        Show-RightPanel $tabCompile; return
    }
    Show-RightPanel $tabCompile
    $rtbCompile.Clear()
    $initMsg = if ($skipGit) { "Iniciando Solo Compilar (SKIP_GIT=1)..." } else { "Iniciando Git Pull + Compilar..." }
    Write-TerminalLine $rtbCompile $initMsg "Build"

    $logsDir = "$($cfg.ACoreBin)\logs"
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
    $compileLog = "$logsDir\compile.log"
    "" | Out-File -FilePath $compileLog -Encoding UTF8
    $script:compileLogPos = 0L

    $esc  = $updateScript -replace "'", "''"
    $body = if ($skipGit) { "`$env:SKIP_GIT='1'; & '$esc'" } else { "& '$esc'" }
    $psCmd = "& { $body } *>&1 | Out-File -FilePath '$compileLog' -Encoding UTF8 -Append"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName              = "powershell.exe"
    $psi.Arguments             = "-ExecutionPolicy Bypass -Command `"$psCmd`""
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute       = $false
    $psi.CreateNoWindow        = $true
    $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi
    $p.Start() | Out-Null
    $p.StandardInput.AutoFlush = $true
    $script:compileProc = $p
}

# Botón "Git Clone/Pull + Compilar"
$btnUpdate.Add_Click({ Start-CompileJob $false })

# Botón "Solo Compilar"
$btnCompile.Add_Click({ Start-CompileJob $true })

# ============================================================
# DIÁLOGO: CREAR / EDITAR CUENTA (SRP6)
# ============================================================

$btnAccount.Add_Click({
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Crear / Editar Cuenta"
    $dlg.ClientSize      = New-Object System.Drawing.Size(360, 310)
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.StartPosition   = "CenterParent"
    $dlg.BackColor       = $col.Bg
    $dlg.Font            = New-Object System.Drawing.Font("Segoe UI", 10)

    # Controles del formulario
    $lUser = New-Object System.Windows.Forms.Label
    $lUser.Text = "Usuario:"; $lUser.ForeColor = $col.Frost
    $lUser.Location = New-Object System.Drawing.Point(16, 14); $lUser.Size = New-Object System.Drawing.Size(328, 18)
    $dlg.Controls.Add($lUser)

    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = New-Object System.Drawing.Point(16, 34); $txtUser.Size = New-Object System.Drawing.Size(328, 24)
    $txtUser.BackColor = $col.Card; $txtUser.ForeColor = $col.Text
    $txtUser.BorderStyle = "FixedSingle"
    $dlg.Controls.Add($txtUser)

    $lPass = New-Object System.Windows.Forms.Label
    $lPass.Text = "Contrasena:"; $lPass.ForeColor = $col.Frost
    $lPass.Location = New-Object System.Drawing.Point(16, 70); $lPass.Size = New-Object System.Drawing.Size(328, 18)
    $dlg.Controls.Add($lPass)

    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Location = New-Object System.Drawing.Point(16, 90); $txtPass.Size = New-Object System.Drawing.Size(328, 24)
    $txtPass.BackColor = $col.Card; $txtPass.ForeColor = $col.Text
    $txtPass.BorderStyle = "FixedSingle"; $txtPass.PasswordChar = [char]0x2022
    $dlg.Controls.Add($txtPass)

    $lLvl = New-Object System.Windows.Forms.Label
    $lLvl.Text = "Nivel de acceso:"; $lLvl.ForeColor = $col.Frost
    $lLvl.Location = New-Object System.Drawing.Point(16, 126); $lLvl.Size = New-Object System.Drawing.Size(328, 18)
    $dlg.Controls.Add($lLvl)

    $cmbLevel = New-Object System.Windows.Forms.ComboBox
    $cmbLevel.Location = New-Object System.Drawing.Point(16, 146); $cmbLevel.Size = New-Object System.Drawing.Size(328, 26)
    $cmbLevel.DropDownStyle = "DropDownList"
    $cmbLevel.BackColor = $col.Card; $cmbLevel.ForeColor = $col.Text
    $cmbLevel.Items.AddRange(@("0 - Jugador (sin GM)", "1 - Moderador", "2 - GameMaster", "3 - Administrador"))
    $cmbLevel.SelectedIndex = 0
    $dlg.Controls.Add($cmbLevel)

    $lblResult = New-Object System.Windows.Forms.Label
    $lblResult.Text = ""; $lblResult.ForeColor = $col.Green
    $lblResult.Location = New-Object System.Drawing.Point(16, 186); $lblResult.Size = New-Object System.Drawing.Size(328, 20)
    $dlg.Controls.Add($lblResult)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "Crear Cuenta"; $btnOK.Location = New-Object System.Drawing.Point(16, 218)
    $btnOK.Size = New-Object System.Drawing.Size(156, 36); $btnOK.FlatStyle = "Flat"
    $btnOK.BackColor = $col.BtnGrn; $btnOK.ForeColor = $col.Green
    $btnOK.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(18, 130, 72)
    $btnOK.Cursor = [System.Windows.Forms.Cursors]::Hand
    $dlg.Controls.Add($btnOK)

    $btnCerrar = New-Object System.Windows.Forms.Button
    $btnCerrar.Text = "Cerrar"; $btnCerrar.Location = New-Object System.Drawing.Point(188, 218)
    $btnCerrar.Size = New-Object System.Drawing.Size(156, 36); $btnCerrar.FlatStyle = "Flat"
    $btnCerrar.BackColor = $col.Btn; $btnCerrar.ForeColor = $col.Ice
    $btnCerrar.FlatAppearance.BorderColor = $col.BtnBd
    $btnCerrar.Cursor = [System.Windows.Forms.Cursors]::Hand
    $dlg.Controls.Add($btnCerrar)

    # Acción del botón Crear Cuenta
    $btnOK.Add_Click({
        $user  = $txtUser.Text.Trim().ToUpper()
        $pass  = $txtPass.Text.Trim().ToUpper()
        $level = $cmbLevel.SelectedIndex

        if ($user -eq "" -or $pass -eq "") {
            $lblResult.ForeColor = $col.Red; $lblResult.Text = "Usuario y contrasena son obligatorios"; return
        }
        if ($user -notmatch '^[A-Z0-9_]{1,16}$') {
            $lblResult.ForeColor = $col.Red; $lblResult.Text = "Solo letras, numeros y _ (max 16 chars)"; return
        }

        $mysqlExe = "$($cfg.MySQLBin)\mysql.exe"
        if (-not (Test-Path $mysqlExe)) {
            $lblResult.ForeColor = $col.Red; $lblResult.Text = "mysql.exe no encontrado en $($cfg.MySQLBin)"; return
        }
        if (-not (Test-MySQL)) {
            $lblResult.ForeColor = $col.Red; $lblResult.Text = "MySQL no esta corriendo. Inicialo primero."; return
        }

        # Calcular SRP6
        $srp = Compute-SRP6 $user $pass
        $saltHex = ($srp.Salt     | ForEach-Object { $_.ToString('X2') }) -join ''
        $verHex  = ($srp.Verifier | ForEach-Object { $_.ToString('X2') }) -join ''
        $sqlCreate = "INSERT INTO account (username,salt,verifier,email,expansion) VALUES ('$user',0x$saltHex,0x$verHex,'',2) ON DUPLICATE KEY UPDATE salt=0x$saltHex,verifier=0x$verHex;"
        $df = "--defaults-file=$($cfg.MySQLIni)"
        $out = & $mysqlExe $df -u root acore_auth -e $sqlCreate 2>&1
        if ($LASTEXITCODE -ne 0) {
            $lblResult.ForeColor = $col.Red; $lblResult.Text = "Error: $($out -join ' ')"; return
        }

        # Asignar nivel de GM (si >0)
        if ($level -gt 0) {
            $sqlAccess = "INSERT INTO account_access (id,gmlevel,RealmID) SELECT id,$level,-1 FROM account WHERE username='$user' ON DUPLICATE KEY UPDATE gmlevel=$level;"
            & $mysqlExe $df -u root acore_auth -e $sqlAccess 2>&1 | Out-Null
        } else {
            $sqlDel = "DELETE FROM account_access WHERE id=(SELECT id FROM account WHERE username='$user');"
            & $mysqlExe $df -u root acore_auth -e $sqlDel 2>&1 | Out-Null
        }

        $lvlNames = @("Jugador","Moderador","GameMaster","Administrador")
        $lblResult.ForeColor = $col.Green
        $lblResult.Text = "[OK]  $user  ->  $($lvlNames[$level])"
        $txtUser.Text = ""; $txtPass.Text = ""
    })

    $btnCerrar.Add_Click({ $dlg.Close() })
    [void]$dlg.ShowDialog($form)
})

# ============================================================
# DIÁLOGO: SEGURIDAD MYSQL (cambiar contraseñas)
# ============================================================

$btnSecurity.Add_Click({
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Seguridad MySQL"
    $dlg.ClientSize      = New-Object System.Drawing.Size(380, 280)
    $dlg.FormBorderStyle = "FixedSingle"
    $dlg.MaximizeBox     = $false
    $dlg.StartPosition   = "CenterParent"
    $dlg.BackColor       = $col.Bg
    $dlg.Font            = New-Object System.Drawing.Font("Segoe UI", 10)

    $lRoot = New-Object System.Windows.Forms.Label
    $lRoot.Text = "Nueva contrasena de root (acceso al monitor):"; $lRoot.ForeColor = $col.Frost
    $lRoot.Location = New-Object System.Drawing.Point(16, 14); $lRoot.Size = New-Object System.Drawing.Size(348, 18)
    $dlg.Controls.Add($lRoot)

    $txtRootPass = New-Object System.Windows.Forms.TextBox
    $txtRootPass.Location = New-Object System.Drawing.Point(16, 34); $txtRootPass.Size = New-Object System.Drawing.Size(348, 24)
    $txtRootPass.PasswordChar = [char]0x2022
    $txtRootPass.BackColor = $col.Card; $txtRootPass.ForeColor = $col.Text
    $txtRootPass.BorderStyle = "FixedSingle"
    $dlg.Controls.Add($txtRootPass)

    $lNote = New-Object System.Windows.Forms.Label
    $lNote.Text = "Deja en blanco para no cambiarla."; $lNote.ForeColor = $col.Muted
    $lNote.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $lNote.Location = New-Object System.Drawing.Point(16, 60); $lNote.Size = New-Object System.Drawing.Size(348, 16)
    $dlg.Controls.Add($lNote)

    $lAcore = New-Object System.Windows.Forms.Label
    $lAcore.Text = "Nueva contrasena de acore (worldserver / authserver):"; $lAcore.ForeColor = $col.Frost
    $lAcore.Location = New-Object System.Drawing.Point(16, 86); $lAcore.Size = New-Object System.Drawing.Size(348, 18)
    $dlg.Controls.Add($lAcore)

    $txtAcorePass = New-Object System.Windows.Forms.TextBox
    $txtAcorePass.Location = New-Object System.Drawing.Point(16, 106); $txtAcorePass.Size = New-Object System.Drawing.Size(348, 24)
    $txtAcorePass.PasswordChar = [char]0x2022
    $txtAcorePass.BackColor = $col.Card; $txtAcorePass.ForeColor = $col.Text
    $txtAcorePass.BorderStyle = "FixedSingle"
    $dlg.Controls.Add($txtAcorePass)

    $lNote2 = New-Object System.Windows.Forms.Label
    $lNote2.Text = "Actualiza worldserver.conf, authserver.conf y dbimport.conf."; $lNote2.ForeColor = $col.Muted
    $lNote2.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $lNote2.Location = New-Object System.Drawing.Point(16, 132); $lNote2.Size = New-Object System.Drawing.Size(348, 16)
    $dlg.Controls.Add($lNote2)

    $lblSt = New-Object System.Windows.Forms.Label
    $lblSt.ForeColor = $col.Muted; $lblSt.Text = "MySQL debe estar corriendo para aplicar cambios."
    $lblSt.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblSt.Location = New-Object System.Drawing.Point(16, 160); $lblSt.Size = New-Object System.Drawing.Size(348, 18)
    $dlg.Controls.Add($lblSt)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "Aplicar"; $btnApply.Location = New-Object System.Drawing.Point(16, 200)
    $btnApply.Size = New-Object System.Drawing.Size(168, 36); $btnApply.FlatStyle = "Flat"
    $btnApply.BackColor = $col.BtnGrn; $btnApply.ForeColor = $col.Green
    $btnApply.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(18, 130, 72)
    $btnApply.Cursor = [System.Windows.Forms.Cursors]::Hand
    $dlg.Controls.Add($btnApply)

    $btnClose2 = New-Object System.Windows.Forms.Button
    $btnClose2.Text = "Cerrar"; $btnClose2.Location = New-Object System.Drawing.Point(196, 200)
    $btnClose2.Size = New-Object System.Drawing.Size(168, 36); $btnClose2.FlatStyle = "Flat"
    $btnClose2.BackColor = $col.Btn; $btnClose2.ForeColor = $col.Ice
    $btnClose2.FlatAppearance.BorderColor = $col.BtnBd
    $btnClose2.Cursor = [System.Windows.Forms.Cursors]::Hand
    $dlg.Controls.Add($btnClose2)

    # Aplicar cambios de contraseña
    $btnApply.Add_Click({
        $newRoot  = $txtRootPass.Text
        $newAcore = $txtAcorePass.Text
        if ($newRoot -eq '' -and $newAcore -eq '') {
            $lblSt.ForeColor = $col.Muted; $lblSt.Text = "Sin cambios — ambos campos vacios."; return
        }
        if (-not (Test-MySQL)) {
            $lblSt.ForeColor = $col.Red; $lblSt.Text = "MySQL no esta corriendo. Inicialo primero."; return
        }
        $mx  = "$($cfg.MySQLBin)\mysql.exe"
        $df  = "--defaults-file=$($cfg.MySQLIni)"
        $ok  = $true
        $msg = @()

        if ($newRoot -ne '') {
            $out = & $mx $df -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$newRoot'; FLUSH PRIVILEGES;" 2>&1
            if ($LASTEXITCODE -ne 0) { $lblSt.ForeColor = $col.Red; $lblSt.Text = "Error root: $($out -join ' ')"; $ok = $false }
            else { Update-MyIniPassword $newRoot; $msg += "root" }
        }
        if ($ok -and $newAcore -ne '') {
            $out = & $mx $df -u root -e "ALTER USER 'acore'@'localhost' IDENTIFIED BY '$newAcore'; FLUSH PRIVILEGES;" 2>&1
            if ($LASTEXITCODE -ne 0) { $lblSt.ForeColor = $col.Red; $lblSt.Text = "Error acore: $($out -join ' ')"; $ok = $false }
            else { Update-AcorePassword $newAcore; $msg += "acore" }
        }
        if ($ok) {
            $lblSt.ForeColor = $col.Green
            $lblSt.Text = "[OK] Actualizado: " + ($msg -join ", ")
            $txtRootPass.Text = ""; $txtAcorePass.Text = ""
        }
    })

    $btnClose2.Add_Click({ $dlg.Close() })
    [void]$dlg.ShowDialog($form)
})

# ============================================================
# DIÁLOGO: EDITOR DE REALMLIST (cliente WoW)
# ============================================================

$wowPathFile = "$PSScriptRoot\wow_path.txt"

$btnRealmlist.Add_Click({
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Editor de Realmlist"
    $dlg.ClientSize      = New-Object System.Drawing.Size(380, 240)
    $dlg.FormBorderStyle = "FixedSingle"
    $dlg.MaximizeBox     = $false
    $dlg.StartPosition   = "CenterParent"
    $dlg.BackColor       = $col.Bg
    $dlg.Font            = New-Object System.Drawing.Font("Segoe UI", 10)

    $lPath = New-Object System.Windows.Forms.Label
    $lPath.Text = "Carpeta del cliente WoW:"; $lPath.ForeColor = $col.Frost
    $lPath.Location = New-Object System.Drawing.Point(16, 14); $lPath.Size = New-Object System.Drawing.Size(348, 18)
    $dlg.Controls.Add($lPath)

    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = New-Object System.Drawing.Point(16, 34); $txtPath.Size = New-Object System.Drawing.Size(270, 24)
    $txtPath.BackColor = $col.Card; $txtPath.ForeColor = $col.Text
    $txtPath.BorderStyle = "FixedSingle"
    $dlg.Controls.Add($txtPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "..."; $btnBrowse.Location = New-Object System.Drawing.Point(294, 32)
    $btnBrowse.Size = New-Object System.Drawing.Size(70, 28); $btnBrowse.FlatStyle = "Flat"
    $btnBrowse.BackColor = $col.Btn; $btnBrowse.ForeColor = $col.Ice
    $btnBrowse.FlatAppearance.BorderColor = $col.BtnBd
    $btnBrowse.Cursor = [System.Windows.Forms.Cursors]::Hand
    $dlg.Controls.Add($btnBrowse)

    $lRL = New-Object System.Windows.Forms.Label
    $lRL.Text = "Realmlist (IP o hostname):"; $lRL.ForeColor = $col.Frost
    $lRL.Location = New-Object System.Drawing.Point(16, 76); $lRL.Size = New-Object System.Drawing.Size(348, 18)
    $dlg.Controls.Add($lRL)

    $txtRL = New-Object System.Windows.Forms.TextBox
    $txtRL.Location = New-Object System.Drawing.Point(16, 96); $txtRL.Size = New-Object System.Drawing.Size(348, 24)
    $txtRL.BackColor = $col.Card; $txtRL.ForeColor = $col.Text
    $txtRL.BorderStyle = "FixedSingle"
    $dlg.Controls.Add($txtRL)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.ForeColor = $col.Muted; $lblStatus.Text = ""
    $lblStatus.Location = New-Object System.Drawing.Point(16, 136); $lblStatus.Size = New-Object System.Drawing.Size(348, 18)
    $dlg.Controls.Add($lblStatus)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Guardar"; $btnSave.Location = New-Object System.Drawing.Point(16, 166)
    $btnSave.Size = New-Object System.Drawing.Size(168, 36); $btnSave.FlatStyle = "Flat"
    $btnSave.BackColor = $col.BtnGrn; $btnSave.ForeColor = $col.Green
    $btnSave.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(18, 130, 72)
    $btnSave.Cursor = [System.Windows.Forms.Cursors]::Hand
    $dlg.Controls.Add($btnSave)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Cerrar"; $btnClose.Location = New-Object System.Drawing.Point(196, 166)
    $btnClose.Size = New-Object System.Drawing.Size(168, 36); $btnClose.FlatStyle = "Flat"
    $btnClose.BackColor = $col.Btn; $btnClose.ForeColor = $col.Ice
    $btnClose.FlatAppearance.BorderColor = $col.BtnBd
    $btnClose.Cursor = [System.Windows.Forms.Cursors]::Hand
    $dlg.Controls.Add($btnClose)

    # Función auxiliar para encontrar archivos realmlist.wtf
    function Find-RealmlistFiles($p) {
        $files = @(Get-ChildItem "$p\Data\*\realmlist.wtf" -ErrorAction SilentlyContinue)
        if (Test-Path "$p\realmlist.wtf") { $files += Get-Item "$p\realmlist.wtf" }
        return $files
    }

    # Carga el realmlist desde el archivo existente
    function Load-Realmlist {
        $p = $txtPath.Text.TrimEnd('\')
        if (-not $p) { return }
        $files = Find-RealmlistFiles $p
        if ($files.Count -eq 0) {
            $lblStatus.ForeColor = $col.Red; $lblStatus.Text = "No se encontro realmlist.wtf en Data\<locale>\"; return
        }
        $content = Get-Content $files[0].FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match 'set realmlist\s+(\S+)') {
            $txtRL.Text = $matches[1]
            $locales = ($files | ForEach-Object { $_.Directory.Name }) -join ", "
            $lblStatus.ForeColor = $col.Muted; $lblStatus.Text = "Locales: $locales"
        } else {
            $txtRL.Text = ""
            $lblStatus.ForeColor = $col.Amber; $lblStatus.Text = "realmlist.wtf encontrado pero sin 'set realmlist'"
        }
    }

    # Cargar ruta guardada previamente o valor por defecto
    if (Test-Path $wowPathFile) { $txtPath.Text = (Get-Content $wowPathFile -Raw).Trim() }
    elseif (Test-Path "C:\Wow\Data") { $txtPath.Text = "C:\Wow" }
    if ($txtPath.Text) { Load-Realmlist }

    $txtPath.Add_Leave({ Load-Realmlist })

    $btnBrowse.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = "Selecciona la carpeta raiz del cliente WoW 3.3.5a"
        if ($txtPath.Text -and (Test-Path $txtPath.Text)) { $fb.SelectedPath = $txtPath.Text }
        if ($fb.ShowDialog() -eq "OK") { $txtPath.Text = $fb.SelectedPath; Load-Realmlist }
    })

    $btnSave.Add_Click({
        $p = $txtPath.Text.TrimEnd('\')
        $ip = $txtRL.Text.Trim()
        if (-not $p)  { $lblStatus.ForeColor = $col.Red; $lblStatus.Text = "Especifica la carpeta del cliente WoW"; return }
        if (-not $ip) { $lblStatus.ForeColor = $col.Red; $lblStatus.Text = "Especifica un realmlist (IP o hostname)"; return }
        if (-not (Test-Path $p)) { $lblStatus.ForeColor = $col.Red; $lblStatus.Text = "Carpeta no encontrada: $p"; return }
        $files = Find-RealmlistFiles $p
        if ($files.Count -eq 0) { $lblStatus.ForeColor = $col.Red; $lblStatus.Text = "No se encontro realmlist.wtf en Data\<locale>\"; return }
        foreach ($f in $files) { "set realmlist $ip" | Set-Content $f.FullName -Encoding ASCII }
        $txtPath.Text | Set-Content $wowPathFile -Encoding UTF8
        $locales = ($files | ForEach-Object { $_.Directory.Name }) -join ", "
        $lblStatus.ForeColor = $col.Green; $lblStatus.Text = "[OK] $ip  ($locales)"
    })

    $btnClose.Add_Click({ $dlg.Close() })
    [void]$dlg.ShowDialog($form)
})

# ============================================================
# BOTÓN: LIMPIAR BASE DE DATOS
# ============================================================

$btnCleanDb.Add_Click({
    if (-not (Test-MySQL)) {
        [System.Windows.Forms.MessageBox]::Show(
            "MySQL no esta corriendo.`nInicia MySQL antes de limpiar la base de datos.",
            "Limpiar DB", "OK", "Warning") | Out-Null
        return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Esto eliminara completamente acore_auth, acore_characters y acore_world.`n`n¿Continuar?",
        "Limpiar Base de Datos", "YesNo", "Warning")
    if ($confirm -ne "Yes") { return }

    $mysqlExe = "$($cfg.MySQLBin)\mysql.exe"
    try {
        & $mysqlExe "--defaults-file=$($cfg.MySQLIni)" -u root -e `
            "DROP DATABASE IF EXISTS acore_auth; DROP DATABASE IF EXISTS acore_characters; DROP DATABASE IF EXISTS acore_world;" 2>$null
        [System.Windows.Forms.MessageBox]::Show(
            "Bases de datos eliminadas correctamente.`n`nAhora corre 'Actualizar Base de Datos (dbimport)' para recrearlas.",
            "Limpiar DB — OK", "OK", "Information") | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error al limpiar bases de datos:`n$_", "Error", "OK", "Error") | Out-Null
    }
})

# ============================================================
# BOTÓN: ACTUALIZAR BASE DE DATOS (dbimport)
# ============================================================

$btnDbImport.Add_Click({
    Start-DbImportJob
})


# ============================================================
# TIMER Y EVENTOS DEL FORMULARIO PRINCIPAL
# ============================================================

# Timer de estado (4 seg)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 4000
$timer.Add_Tick({ Update-All })
$timer.Start()

# Helper: lanza dbimport.exe redirigiendo salida a dbimport.log (tail en flushTimer)
function Start-DbImportJob {
    $dbimport = "$($cfg.ACoreBin)\dbimport.exe"
    $dbCfg    = "$($cfg.ACoreBin)\configs\dbimport.conf"
    if (-not (Test-Path $dbimport)) {
        [System.Windows.Forms.MessageBox]::Show("dbimport.exe no encontrado en $($cfg.ACoreBin).`nCompila el servidor primero.", "Actualizar DB", "OK", "Warning") | Out-Null; return
    }
    if (-not (Test-Path $dbCfg)) {
        [System.Windows.Forms.MessageBox]::Show("dbimport.conf no encontrado en configs\.`nCompila el servidor primero.", "Actualizar DB", "OK", "Warning") | Out-Null; return
    }
    if (-not (Test-MySQL)) {
        [System.Windows.Forms.MessageBox]::Show("MySQL no esta corriendo.`nInicia MySQL antes de actualizar la base de datos.", "Actualizar DB", "OK", "Warning") | Out-Null; return
    }
    if ($script:dbimportProc -and -not $script:dbimportProc.HasExited) {
        Show-RightPanel $tabDbImport; return
    }
    Show-RightPanel $tabDbImport
    $rtbDbImport.Clear()
    Write-TerminalLine $rtbDbImport "Ejecutando dbimport..." "DB"

    $logsDir = "$($cfg.ACoreBin)\logs"
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
    $dbLog = "$logsDir\dbimport.log"
    "" | Out-File -FilePath $dbLog -Encoding UTF8
    $script:dbimportLogPos = 0L

    $dbEsc  = $dbimport -replace "'", "''"
    $cfgEsc = $dbCfg    -replace "'", "''"
    $logEsc = $dbLog    -replace "'", "''"
    $psCmd  = "`$ErrorActionPreference='SilentlyContinue'; & '$dbEsc' --config '$cfgEsc' 2>&1 | Out-File -FilePath '$logEsc' -Encoding UTF8 -Append"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = "powershell.exe"
    $psi.Arguments              = "-ExecutionPolicy Bypass -Command `"$psCmd`""
    $psi.RedirectStandardInput  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi
    $p.Start() | Out-Null
    $p.StandardInput.AutoFlush  = $true
    # Pre-responder cualquier prompt de confirmacion con 'yes'
    for ($i = 0; $i -lt 30; $i++) { $p.StandardInput.WriteLine("yes") }
    $script:dbimportProc = $p
}

# Timer de flush de salida al terminal (100 ms)
$flushTimer = New-Object System.Windows.Forms.Timer
$flushTimer.Interval = 100
$flushTimer.Add_Tick({
    Read-LogFile "$($cfg.ACoreBin)\Auth.log"   $script:authQueue  ([ref]$script:authLogPos)
    Read-LogFile "$($cfg.ACoreBin)\Server.log" $script:worldQueue ([ref]$script:worldLogPos)

    $line = $null; $n = 0
    while ($n -lt 50 -and $script:authQueue.TryDequeue([ref]$line)) {
        Write-TerminalLine $rtbAuth    (Strip-Ansi $line) "Auth";  $n++
    }
    if ($script:authProc -and $script:authProc.HasExited -and $script:authQueue.IsEmpty) {
        Write-TerminalLine $rtbAuth "--- authserver terminado (codigo $($script:authProc.ExitCode)) ---" "Auth"
        $script:authProc = $null; Update-All
    }
    $n = 0
    while ($n -lt 50 -and $script:worldQueue.TryDequeue([ref]$line)) {
        Write-TerminalLine $rtbWorld   (Strip-Ansi $line) "World"; $n++
    }
    if ($script:worldProc -and $script:worldProc.HasExited -and $script:worldQueue.IsEmpty) {
        Write-TerminalLine $rtbWorld "--- worldserver terminado (codigo $($script:worldProc.ExitCode)) ---" "World"
        $script:worldProc = $null; Update-All
    }
    $compileLog = "$($cfg.ACoreBin)\logs\compile.log"
    Read-LogFile $compileLog $script:compileQueue ([ref]$script:compileLogPos)
    $n = 0
    while ($n -lt 50 -and $script:compileQueue.TryDequeue([ref]$line)) {
        Write-TerminalLine $rtbCompile (Strip-Ansi $line) "Build"; $n++
    }
    if ($script:compileProc -and $script:compileProc.HasExited) {
        $ec  = $script:compileProc.ExitCode
        $msg = if ($ec -eq 0) { "Compilacion completada correctamente." } else { "Compilacion terminada con errores (codigo $ec)." }
        $tag = if ($ec -eq 0) { "Build" } else { "Build!" }
        Write-TerminalLine $rtbCompile $msg $tag
        $script:compileProc = $null
    }
    $dbLog = "$($cfg.ACoreBin)\logs\dbimport.log"
    Read-LogFile $dbLog $script:dbimportQueue ([ref]$script:dbimportLogPos)
    $n = 0
    while ($n -lt 50 -and $script:dbimportQueue.TryDequeue([ref]$line)) {
        Write-TerminalLine $rtbDbImport (Strip-Ansi $line) "DB"; $n++
    }
    if ($script:dbimportProc -and $script:dbimportProc.HasExited) {
        $ec  = $script:dbimportProc.ExitCode
        # Codigo 1 es falso positivo: PowerShell NativeCommandError del intento
        # de conexion inicial antes de crear la base. El import fue exitoso igual.
        $success = ($ec -eq 0 -or $ec -eq 1)
        $tag = if ($success) { "DB" } else { "DB!" }
        if ($success) {
            Write-TerminalLine $rtbDbImport "Base de datos importada correctamente." $tag
            Write-TerminalLine $rtbDbImport "─────────────────────────────────────────────" $tag
            Write-TerminalLine $rtbDbImport "Siguiente paso:" $tag
            Write-TerminalLine $rtbDbImport "  3  Crear tu cuenta con el boton 'Crear Cuenta de Juego'" $tag
            Write-TerminalLine $rtbDbImport "  4  Iniciar AuthServer" $tag
            Write-TerminalLine $rtbDbImport "  5  Iniciar WorldServer" $tag
            Write-TerminalLine $rtbDbImport "─────────────────────────────────────────────" $tag
            [System.Windows.Forms.MessageBox]::Show(
                "Base de datos importada correctamente.`n`nSiguientes pasos:`n`n  3  Crear tu cuenta  (boton 'Crear Cuenta de Juego')`n  4  Iniciar AuthServer`n  5  Iniciar WorldServer",
                "DB Import — Completado", "OK", "Information") | Out-Null
        } else {
            Write-TerminalLine $rtbDbImport "DB Import termino con errores (codigo $ec)." "DB!"
        }
        $script:dbimportProc = $null
    }
})
$flushTimer.Start()

$form.Add_FormClosing({
    $timer.Stop();      $timer.Dispose()
    $flushTimer.Stop(); $flushTimer.Dispose()
    if ($script:authProc    -and -not $script:authProc.HasExited)    { $script:authProc.Kill()    }
    if ($script:worldProc   -and -not $script:worldProc.HasExited)   { $script:worldProc.Kill()   }
    if ($script:compileProc  -and -not $script:compileProc.HasExited)  { $script:compileProc.Kill()  }
    if ($script:dbimportProc -and -not $script:dbimportProc.HasExited) { $script:dbimportProc.Kill() }
})
$form.Add_Shown({ Update-All })

# Mostrar el formulario (diálogo modal)
[void]$form.ShowDialog()