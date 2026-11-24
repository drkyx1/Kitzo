@echo off
:: ===================================================================
::  Iniciar.bat - Launcher do Kitzo
::  1) Pede permissao de Administrador (UAC)
::  2) Sobe o servidor.ps1 OCULTO, em segundo plano (ExecutionPolicy Bypass,
::     nada e instalado). O servidor abre o navegador sozinho e se encerra
::     automaticamente quando o painel e fechado.
::  3) Se a ferramenta ja estiver aberta, apenas reabre o painel.
::
::  "Iniciar.bat console" (ou Iniciar-Console.bat) mostra a janela do
::  servidor, util para diagnosticar problemas.
::  Obs.: texto sem acentos de proposito (o cmd.exe usa outra codificacao)
:: ===================================================================
setlocal EnableExtensions
cd /d "%~dp0"

:: Caminho fixo do Windows PowerShell 5.1 (funciona mesmo com PATH quebrado)
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
    echo Windows PowerShell nao encontrado neste computador.
    pause
    exit /b 1
)
if not exist "%~dp0servidor.ps1" (
    echo Arquivo servidor.ps1 nao encontrado. Copie a pasta da ferramenta inteira.
    pause
    exit /b 1
)

:: Argumentos do servidor. O caminho vai por variavel de ambiente para nao
:: quebrar com espacos ou apostrofos no nome da pasta do pendrive.
:: (ifs de uma linha so: um ")" no caminho quebraria um bloco entre parenteses)
set "KITZO_JANELA=Hidden"
set "KITZO_ARGS=-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0servidor.ps1""
if /i "%~1"=="console" set "KITZO_JANELA=Normal"
if /i "%~1"=="console" set "KITZO_ARGS=-NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0servidor.ps1""

echo Iniciando o Kitzo... confirme o aviso de administrador do Windows.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath $env:PS -Verb RunAs -WindowStyle $env:KITZO_JANELA -ArgumentList $env:KITZO_ARGS -ErrorAction Stop } catch { exit 1 }"
if errorlevel 1 (
    echo.
    echo Permissao de administrador negada. A ferramenta precisa dela para
    echo diagnosticar e reparar o Windows.
    pause
    exit /b 1
)
endlocal
exit /b 0
