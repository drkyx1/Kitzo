<#
  modulos\programas.ps1 — Etapa (d): listar, instalar e atualizar programas via winget.
  Sem winget, a lista de instalados vem do Registro (e instalar/atualizar ficam indisponíveis).

  Todas as chamadas ao winget rodam como tarefas em segundo plano, pois podem demorar.
  IDs de pacote e termos de busca são validados por expressão regular e passados
  como ARGUMENTOS (nunca concatenados em linha de comando de shell).
#>

$Script:Winget = $null   # cache: @{ caminho; versao; interativoOk }

function Obter-Winget {
    if ($Script:Winget) { return $Script:Winget }

    $caminho = $null
    $cmd = Get-Command 'winget.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $caminho = $cmd.Source }
    if (-not $caminho) {
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $alias) { $caminho = $alias }
    }
    if (-not $caminho) {
        # Quando o técnico elevou com OUTRA conta, o alias do usuário não existe: procura no pacote
        $pacote = Tentar {
            Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe' -Directory -ErrorAction Stop |
                Sort-Object Name -Descending | Select-Object -First 1
        }
        if ($pacote) {
            $exe = Join-Path $pacote.FullName 'winget.exe'
            if (Test-Path -LiteralPath $exe) { $caminho = $exe }
        }
    }
    if (-not $caminho) { return $null }

    $ErrorActionPreference = 'Continue'
    $textoVersao = (& $caminho --version 2>$null | Out-String).Trim()
    $versao = $null
    if ($textoVersao -match 'v?(\d+)\.(\d+)') { $versao = [version]("{0}.{1}" -f $Matches[1], $Matches[2]) }

    $Script:Winget = [pscustomobject]@{
        caminho = $caminho
        versao  = $textoVersao
        # --disable-interactivity existe a partir do winget 1.4
        semInteracao = ($versao -and $versao -ge [version]'1.4')
    }
    $Script:Winget
}

function Exigir-Winget {
    $w = Obter-Winget
    if (-not $w) { throw 'O winget não está disponível neste PC. Instale o "Instalador de Aplicativo" pela Microsoft Store.' }
    $w
}

# Argumentos comuns a todos os comandos do winget
function Argumentos-Winget {
    param($W, [string[]]$Extras)
    $a = @($Extras) + '--accept-source-agreements'
    if ($W.semInteracao) { $a += '--disable-interactivity' }
    $a
}

<#
  Converte as tabelas de texto do winget (list/upgrade/search) em objetos.
  O cabeçalho é traduzido conforme o idioma, por isso as colunas são localizadas
  pela POSIÇÃO: cada coluna começa onde uma palavra do cabeçalho começa.
#>
function Converter-TabelaWinget {
    param([string]$Texto, [ValidateSet('list', 'upgrade', 'search')][string]$Tipo)
    $linhas = Converter-Linhas $Texto 100000
    $iSep = -1
    for ($i = 0; $i -lt $linhas.Count; $i++) { if ($linhas[$i] -match '^-{10,}\s*$') { $iSep = $i; break } }
    if ($iSep -lt 1) { return @() }

    $cab = $linhas[$iSep - 1]
    $inicios = @()
    for ($c = 0; $c -lt $cab.Length; $c++) {
        if ($cab[$c] -ne ' ' -and ($c -eq 0 -or $cab[$c - 1] -eq ' ')) { $inicios += $c }
    }
    if ($inicios.Count -lt 3) { return @() }

    # Nomes das colunas conforme a quantidade encontrada
    $nomes = switch ($inicios.Count) {
        3 { 'nome', 'id', 'versao' }
        4 { 'nome', 'id', 'versao', 'origem' }
        default {
            if ($Tipo -eq 'search') { 'nome', 'id', 'versao', 'correspondencia', 'origem' }
            else { 'nome', 'id', 'versao', 'disponivel', 'origem' }
        }
    }

    $res = New-Object System.Collections.ArrayList
    for ($i = $iSep + 1; $i -lt $linhas.Count; $i++) {
        $l = $linhas[$i]
        # Fim da tabela: linha em branco ou rodapé ("3 atualizações disponíveis.")
        if ($l.Trim() -eq '' -or $l.Length -le $inicios[1]) { break }
        $obj = [ordered]@{ nome = ''; id = ''; versao = ''; disponivel = ''; origem = '' }
        for ($k = 0; $k -lt $inicios.Count -and $k -lt $nomes.Count; $k++) {
            $ini = $inicios[$k]
            if ($ini -ge $l.Length) { continue }
            $fim = if ($k + 1 -lt $inicios.Count) { [math]::Min($inicios[$k + 1], $l.Length) } else { $l.Length }
            $obj[$nomes[$k]] = $l.Substring($ini, $fim - $ini).Trim()
        }
        [void]$res.Add($obj)
    }
    @($res)
}

# Lista de instalados pelo Registro (usada quando não há winget, e no relatório)
function Obter-ProgramasRegistro {
    $chaves = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    @(Get-ItemProperty -Path $chaves -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
        Sort-Object DisplayName -Unique |
        ForEach-Object {
            [ordered]@{
                nome       = ([string]$_.DisplayName).Trim()
                id         = ''
                versao     = [string]$_.DisplayVersion
                disponivel = ''
                origem     = 'Registro'
                fabricante = [string]$_.Publisher
            }
        })
}

# Validações de entrada
$Script:PadraoIdWinget = '^[A-Za-z0-9][A-Za-z0-9.\-_+]{1,127}$'
$Script:PadraoBuscaWinget = '^[\p{L}\p{N}][\p{L}\p{N} .+\-_]{1,49}$'

# ---------------------------------------------------------------------
# Ações
# ---------------------------------------------------------------------
Registrar-Acao -Nome 'programas.winget_status' -Descricao 'Verifica se o winget existe' -Bloco {
    param($P)
    $w = Obter-Winget
    [ordered]@{
        disponivel = [bool]$w
        versao     = if ($w) { $w.versao } else { $null }
        caminho    = if ($w) { $w.caminho } else { $null }
    }
}

Registrar-Acao -Nome 'programas.listar' -Descricao 'Programas instalados' -Bloco {
    param($P)
    $w = Obter-Winget
    if (-not $w) {
        return [ordered]@{ semWinget = $true; programas = @(Obter-ProgramasRegistro) }
    }
    $t = Iniciar-Tarefa -Nome 'programas.listar' -Titulo 'Listando programas instalados (winget list)' `
        -Executavel $w.caminho -Argumentos (Argumentos-Winget $w @('list')) -SemProgresso -SemHistorico `
        -AoConcluir { param($Tarefa, $Texto) [ordered]@{ programas = @(Converter-TabelaWinget $Texto 'list') } }
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'programas.atualizaveis' -Descricao 'Programas com atualização disponível' -Bloco {
    param($P)
    $w = Exigir-Winget
    $t = Iniciar-Tarefa -Nome 'programas.atualizaveis' -Titulo 'Procurando atualizações (winget upgrade)' `
        -Executavel $w.caminho -Argumentos (Argumentos-Winget $w @('upgrade')) -SemProgresso -SemHistorico `
        -AoConcluir { param($Tarefa, $Texto) [ordered]@{ programas = @(Converter-TabelaWinget $Texto 'upgrade') } }
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'programas.buscar' -Descricao 'Busca programas no repositório do winget' -Bloco {
    param($P)
    $w = Exigir-Winget
    $termo = Ler-Parametro $P 'termo' -Padrao $Script:PadraoBuscaWinget -Obrigatorio
    $t = Iniciar-Tarefa -Nome 'programas.buscar' -Titulo "Buscando ""$termo""" `
        -Executavel $w.caminho -Argumentos (Argumentos-Winget $w @('search', '--query', $termo, '--source', 'winget')) -SemProgresso -SemHistorico `
        -AoConcluir { param($Tarefa, $Texto) [ordered]@{ programas = @(Converter-TabelaWinget $Texto 'search') } }
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'programas.instalar' -AlteraSistema -Descricao 'Instala um programa pelo ID do winget' -Bloco {
    param($P)
    $w = Exigir-Winget
    $id = Ler-Parametro $P 'id' -Padrao $Script:PadraoIdWinget -Obrigatorio
    $t = Iniciar-Tarefa -Nome 'programas.instalar' -Titulo "Instalando $id" -Exclusiva `
        -Executavel $w.caminho `
        -Argumentos (Argumentos-Winget $w @('install', '--id', $id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements'))
    Resumo-Tarefa $t
}

# 0x8A15002B (-1978335189) = "nenhuma atualização aplicável": não é erro
Registrar-Acao -Nome 'programas.atualizar' -AlteraSistema -Descricao 'Atualiza um programa pelo ID' -Bloco {
    param($P)
    $w = Exigir-Winget
    $id = Ler-Parametro $P 'id' -Padrao $Script:PadraoIdWinget -Obrigatorio
    $t = Iniciar-Tarefa -Nome 'programas.atualizar' -Titulo "Atualizando $id" -Exclusiva `
        -Executavel $w.caminho -CodigosSucesso @(0, -1978335189) `
        -Argumentos (Argumentos-Winget $w @('upgrade', '--id', $id, '--exact', '--silent', '--accept-package-agreements'))
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'programas.atualizar_todos' -AlteraSistema -Descricao 'Atualiza todos os programas' -Bloco {
    param($P)
    $w = Exigir-Winget
    $t = Iniciar-Tarefa -Nome 'programas.atualizar_todos' -Titulo 'Atualizando todos os programas' -Exclusiva `
        -Executavel $w.caminho -CodigosSucesso @(0, -1978335189) -Manutencao 'Programas atualizados (winget)' `
        -Argumentos (Argumentos-Winget $w @('upgrade', '--all', '--silent', '--accept-package-agreements'))
    Resumo-Tarefa $t
}
