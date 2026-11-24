<#
  modulos\tarefas\limpeza.ps1 — Executa a limpeza em um PowerShell separado.
  Chamado pelo servidor (Iniciar-TarefaScript). Recebe -Pasta da tarefa, lê
  parametros.json (categorias já calculadas pelo servidor) e grava resultado.json.
  Linhas "##PROGRESSO n" alimentam a barra de progresso do painel.
#>
param([Parameter(Mandatory)][string]$Pasta)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'limpeza_comum.ps1')

$par = Get-Content -LiteralPath (Join-Path $Pasta 'parametros.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$categorias = @($par.categorias)
$excluir = @($par.excluir | ForEach-Object { [string]$_ })
$resultado = New-Object System.Collections.ArrayList
$totalBytes = [long]0
$i = 0

foreach ($cat in $categorias) {
    Write-Output ("##PROGRESSO {0}" -f [int]($i / $categorias.Count * 100))
    $i++
    Write-Output ''
    Write-Output "=== $($cat.nome) ==="

    # O cache do Windows Update só pode ser apagado com os serviços parados
    $servicos = @()
    if ($cat.id -eq 'cache_wu') {
        $servicos = @(Get-Service -Name 'wuauserv', 'bits' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
        if ($servicos) {
            Write-Output 'Parando os serviços do Windows Update...'
            $servicos | Stop-Service -Force -ErrorAction SilentlyContinue
        }
    }

    $removidos = 0; $bytes = [long]0; $falhas = 0
    foreach ($p in @($cat.pastas)) {
        Write-Output "Limpando $p"
        $lista = Listar-ItensLimpeza -Pasta ([string]$p) -IdadeHoras ([int]$cat.idadeHoras) -Excluir $excluir
        $r = Remover-ItensLimpeza -Lista $lista
        $removidos += $r.Removidos; $bytes += $r.Bytes; $falhas += $r.Falhas
    }

    if ($servicos) {
        Write-Output 'Religando os serviços do Windows Update...'
        $servicos | ForEach-Object { Start-Service -Name $_.Name -ErrorAction SilentlyContinue }
    }

    Write-Output ("{0} arquivo(s) removido(s), {1} liberado(s). {2} em uso ou protegido(s) foram mantidos." -f $removidos, (Formatar-Tamanho $bytes), $falhas)
    $totalBytes += $bytes
    [void]$resultado.Add([ordered]@{ id = $cat.id; nome = $cat.nome; removidos = $removidos; bytes = $bytes; falhas = $falhas })
}

Write-Output ''
Write-Output ("Total liberado: {0}" -f (Formatar-Tamanho $totalBytes))
Write-Output '##PROGRESSO 100'

ConvertTo-Json -InputObject ([ordered]@{ categorias = @($resultado); totalBytes = $totalBytes }) -Depth 5 |
    Set-Content -LiteralPath (Join-Path $Pasta 'resultado.json') -Encoding UTF8
