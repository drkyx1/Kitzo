<#
  modulos\tarefas\windows_update.ps1 — Procura atualizações pendentes pela API COM
  do Windows Update (a mesma usada pelo Configurações > Windows Update).
  Só PROCURA, não instala nada. Pode levar vários minutos.
#>
param([Parameter(Mandatory)][string]$Pasta)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

# Códigos de erro mais comuns do Windows Update
$erros = @{
    '0x8024402C' = 'Sem conexão com o servidor de atualizações (verifique internet/proxy).'
    '0x80072EE2' = 'Tempo esgotado ao contatar o Windows Update.'
    '0x80072EFD' = 'Não foi possível conectar ao Windows Update.'
    '0x8024401C' = 'Tempo esgotado ao contatar o servidor (WSUS ou Windows Update).'
    '0x80240438' = 'Sem acesso ao serviço do Windows Update.'
    '0x80070422' = 'O serviço Windows Update está desativado.'
}

$resultado = [ordered]@{ ok = $false; atualizacoes = @(); ultimaInstalacao = $null; erro = $null }
try {
    Write-Output 'Conectando ao serviço do Windows Update...'
    $sessao = New-Object -ComObject Microsoft.Update.Session
    $sessao.ClientApplicationID = 'Kitzo'
    $busca = $sessao.CreateUpdateSearcher()

    try {
        $n = $busca.GetTotalHistoryCount()
        if ($n -gt 0) {
            $h = $busca.QueryHistory(0, 1)
            if ($h.Count -gt 0) { $resultado.ultimaInstalacao = $h.Item(0).Date.ToLocalTime().ToString('yyyy-MM-ddTHH:mm:ss') }
        }
    } catch { }

    Write-Output 'Procurando atualizações pendentes (pode levar alguns minutos)...'
    $r = $busca.Search('IsInstalled=0 and IsHidden=0')

    $lista = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $r.Updates.Count; $i++) {
        $u = $r.Updates.Item($i)
        $kbs = @(); foreach ($k in $u.KBArticleIDs) { $kbs += "KB$k" }
        $categoria = ''
        try { if ($u.Categories.Count -gt 0) { $categoria = $u.Categories.Item(0).Name } } catch { }
        [void]$lista.Add([ordered]@{
            titulo     = $u.Title
            kb         = ($kbs -join ', ')
            tamanhoMB  = [math]::Round([double]$u.MaxDownloadSize / 1MB, 1)
            baixada    = [bool]$u.IsDownloaded
            severidade = [string]$u.MsrcSeverity
            categoria  = $categoria
        })
        Write-Output (" - {0}" -f $u.Title)
    }
    $resultado.atualizacoes = @($lista)
    $resultado.ok = $true
    Write-Output ''
    Write-Output ("{0} atualização(ões) pendente(s)." -f $lista.Count)
}
catch {
    $hex = '0x{0:X8}' -f $_.Exception.HResult
    $msg = $erros[$hex]
    if (-not $msg) { $msg = $_.Exception.Message }
    $resultado.erro = "$msg ($hex)"
    Write-Output "ERRO: $($resultado.erro)"
}

ConvertTo-Json -InputObject $resultado -Depth 5 | Set-Content -LiteralPath (Join-Path $Pasta 'resultado.json') -Encoding UTF8
if (-not $resultado.ok) { exit 1 }
