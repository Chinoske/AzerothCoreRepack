Dim sh  : Set sh  = CreateObject("WScript.Shell")
Dim fso : Set fso = CreateObject("Scripting.FileSystemObject")

Dim root : root = fso.GetParentFolderName(WScript.ScriptFullName)

' Regenerar Monitor.lnk con la ruta actual
Dim lnk : Set lnk = sh.CreateShortcut(root & "\Monitor.lnk")
lnk.TargetPath       = WScript.ScriptFullName
lnk.WorkingDirectory = root
lnk.IconLocation     = root & "\tools\monitor.ico, 0"
lnk.Description      = "AzerothCore Monitor"
lnk.Save

' Actualizar icono de la carpeta raiz
Dim iniPath : iniPath = root & "\desktop.ini"
Dim ico     : ico     = root & "\tools\monitor.ico"
Dim f       : Set f   = fso.CreateTextFile(iniPath, True, False)
f.WriteLine "[.ShellClassInfo]"
f.WriteLine "IconResource=" & ico & ",0"
f.Close
sh.Run "cmd /c attrib +h +s """ & iniPath & """", 0, True
sh.Run "cmd /c attrib +r +s """ & root & """", 0, True

sh.Run "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\tools\azerothcore-monitor.ps1""", 0, False
