<#
  modulos\relatorio.ps1 — Etapa (e): gera um relatório HTML e TXT em logs\ com
  o nome do computador e a data. Reúne o que os outros módulos coletam.
#>

function Esc-Html { param($Texto) [Net.WebUtility]::HtmlEncode([string]$Texto) }

function Fmt-Data {
    param($Iso)
    if (-not $Iso) { return '—' }
    $d = Tentar { [datetime]::ParseExact([string]$Iso, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
    if ($d) { $d.ToString('dd/MM/yyyy HH:mm') } else { [string]$Iso }
}

function Fmt-Num { param($N, [int]$Casas = 1) if ($null -eq $N) { '—' } else { ([double]$N).ToString("N$Casas", [Globalization.CultureInfo]'pt-BR') } }

# Coleta tudo (cada parte isolada: se uma falhar, o resto do relatório sai)
function Coletar-DadosRelatorio {
    [ordered]@{
        geradoEm      = Get-Date
        resumo        = Obter-ResumoSaude
        discos        = Tentar { Obter-DiscosFisicos }
        memoria       = Tentar { Obter-DiagMemoria }
        inicializacao = @(Tentar -Padrao @() { Obter-ProgramasInicializacao })
        eventos       = Tentar { Obter-EventosErro -Horas 72 }
        rede          = @(Tentar -Padrao @() { Obter-InfoRede })
        seguranca     = Tentar { Obter-StatusSeguranca }
        programas     = @(Tentar -Padrao @() { Obter-ProgramasRegistro })
        tarefas       = @($Script:Tarefas.Values | Sort-Object inicio | ForEach-Object { Resumo-Tarefa $_ })
        maquina       = $Script:Maquina
    }
}

$Script:NomesEstado = @{ executando = 'Em execução'; cancelando = 'Cancelando'; concluida = 'Concluída'; falhou = 'Falhou'; cancelada = 'Cancelada' }
$Script:NomesSaude = @{ Healthy = 'Saudável'; Warning = 'Alerta'; Unhealthy = 'FALHA' }
$Script:NomesSituacao = @{ em_revisao = 'Em revisão'; revisada = 'Revisada'; locada = 'Locada'; disponivel = 'Disponível'; defeito = 'Com defeito' }
$Script:NomesResultado = @{ iniciada = 'Iniciada (sem resultado)'; concluida = 'Concluída'; falhou = 'Terminou com erro'; cancelada = 'Cancelada'; ok = 'OK'; erro = 'Erro' }

# Textos do histórico da máquina usados no HTML e no TXT
function Textos-HistoricoMaquina {
    param($Mq)
    $sit = '—'
    if ($Mq.situacao -and ($Mq.situacao.valor -or $Mq.situacao.observacao)) {
        $nome = $Script:NomesSituacao[[string]$Mq.situacao.valor]
        if (-not $nome) { $nome = 'Observação' }
        $sit = $nome
        if ($Mq.situacao.observacao) { $sit += ' — ' + $Mq.situacao.observacao }
    }
    $info = [ordered]@{
        'Identificação'   = "$($Mq.id) (por $($Mq.baseId))"
        'Número de série' = $(if ($Mq.serial) { $Mq.serial } else { '—' })
        'Primeira visita' = Fmt-Data $Mq.primeiraVisita
        'Visita anterior' = Fmt-Data $Mq.visitaAnterior
        'Sessões'         = [string]$Mq.sessoes
        'Situação'        = $sit
        'Técnico'         = $(if ($Script:Config.tecnico) { [string]$Script:Config.tecnico } else { '—' })
        'Nomes anteriores' = $(if (@($Mq.nomesAnteriores).Count) { @($Mq.nomesAnteriores) -join ', ' } else { '—' })
    }
    $comandos = @($Mq.comandos.Keys | Where-Object { $_ -notlike 'historico.*' } | ForEach-Object {
        $c = $Mq.comandos[$_]
        $res = $Script:NomesResultado[[string]$c.resultado]; if (-not $res) { $res = $c.resultado }
        [pscustomobject]@{ data = [string]$c.data; titulo = $c.titulo; resultado = $res; tecnico = $c.tecnico }
    } | Sort-Object data -Descending)
    [pscustomobject]@{ Info = $info; Comandos = $comandos }
}

# ---------------------------------------------------------------------
# HTML (autocontido: abre em qualquer navegador, sem internet)
# ---------------------------------------------------------------------
function Gerar-HtmlRelatorio {
    param($D)
    $r = $D.resumo
    $sb = New-Object Text.StringBuilder
    $w = { param($s) [void]$sb.AppendLine($s) }
    $tabela = {
        param([string[]]$Cab, $Linhas)
        & $w '<table><thead><tr>'
        foreach ($c in $Cab) { & $w "<th>$(Esc-Html $c)</th>" }
        & $w '</tr></thead><tbody>'
        foreach ($l in $Linhas) { & $w ('<tr>' + (($l | ForEach-Object { "<td>$(Esc-Html $_)</td>" }) -join '') + '</tr>') }
        if (-not @($Linhas).Count) { & $w "<tr><td colspan=""$($Cab.Count)"" class=""vazio"">Nada a mostrar</td></tr>" }
        & $w '</tbody></table>'
    }

    $corNota = if ($r.nota.valor -ge 85) { '#1f9d63' } elseif ($r.nota.valor -ge 70) { '#5d9e2f' } elseif ($r.nota.valor -ge 50) { '#c98a12' } else { '#c43c3c' }

    & $w @"
<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8">
<title>Relatório - $(Esc-Html $r.computador) - $($D.geradoEm.ToString('dd/MM/yyyy HH:mm'))</title>
<style>
body{font:14px/1.5 "Segoe UI",Arial,sans-serif;color:#1d2430;margin:0;background:#f4f6f9}
main{max-width:1000px;margin:0 auto;padding:32px 24px}
header{display:flex;gap:24px;align-items:center;background:#fff;border-radius:12px;padding:24px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.nota{width:110px;height:110px;border-radius:50%;display:grid;place-items:center;color:#fff;font-size:36px;font-weight:700;background:$corNota;flex:none}
h1{margin:0 0 4px;font-size:22px} h2{font-size:17px;margin:28px 0 10px;border-bottom:2px solid #dfe4ec;padding-bottom:4px}
.sub{color:#5b6576} section{background:#fff;border-radius:12px;padding:4px 20px 16px;margin-top:16px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
table{width:100%;border-collapse:collapse;font-size:13px} th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #eef1f5;vertical-align:top}
th{background:#f7f9fc;font-weight:600} .vazio{color:#8a93a3;text-align:center}
ul.alertas{margin:8px 0 0;padding-left:18px} .critico{color:#c43c3c} .atencao{color:#b07400}
.grade{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:4px 24px}
.grade div span{color:#5b6576;display:block;font-size:12px}
footer{color:#8a93a3;font-size:12px;text-align:center;margin-top:24px}
@media print{body{background:#fff} section,header{box-shadow:none;border:1px solid #dfe4ec}}
</style></head><body><main>
<header><div class="nota">$($r.nota.valor)</div><div>
<h1>Relatório de manutenção — $(Esc-Html $r.computador)</h1>
<div class="sub">Gerado em $($D.geradoEm.ToString('dd/MM/yyyy HH:mm')) · Saúde: <strong>$(Esc-Html $r.nota.classificacao)</strong> · $(Esc-Html $r.fabricante) $(Esc-Html $r.modelo)</div>
<ul class="alertas">
"@
    foreach ($a in $r.nota.alertas) { & $w "<li class=""$(Esc-Html $a.nivel)"">$(Esc-Html $a.texto) (−$($a.pontos))</li>" }
    if (-not @($r.nota.alertas).Count) { & $w '<li>Nenhum problema encontrado.</li>' }
    & $w '</ul></div></header>'

    # Sistema
    $win = $r.windows
    & $w '<section><h2>Sistema</h2><div class="grade">'
    $itens = [ordered]@{
        'Windows'           = "$($win.nome) $($win.versao) (build $($win.build), $($win.arquitetura))"
        'Instalado em'      = Fmt-Data $win.instaladoEm
        'Último boot'       = Fmt-Data $win.ultimoBoot
        'Processador'       = "$($r.cpu.nome) ($($r.cpu.nucleos) núcleos / $($r.cpu.threads) threads)"
        'Memória RAM'       = "$(Fmt-Num $r.memoria.totalGB) GB ($($r.memoria.usoPercentual)% em uso)"
        'Usuário'           = $r.usuario
        'Última manutenção' = if ($r.manutencao) { "$(Fmt-Data $r.manutencao.data) — $($r.manutencao.descricao)" } else { 'Nenhuma registrada' }
        'Reinício pendente' = if ($r.reinicio.pendente) { 'Sim: ' + ($r.reinicio.motivos -join ', ') } else { 'Não' }
    }
    foreach ($k in $itens.Keys) { & $w "<div><span>$(Esc-Html $k)</span>$(Esc-Html $itens[$k])</div>" }
    & $w '</div>'
    & $w '<h2>Unidades</h2>'
    & $tabela @('Unidade', 'Rótulo', 'Sistema de arquivos', 'Total (GB)', 'Livre (GB)', 'Livre (%)') @(
        $r.discos | ForEach-Object { , @($_.letra, $_.rotulo, $_.sistemaArquivos, (Fmt-Num $_.totalGB), (Fmt-Num $_.livreGB), (Fmt-Num $_.livrePercentual)) })

    if ($D.discos) {
        & $w '<h2>Discos físicos (SMART)</h2>'
        & $tabela @('Disco', 'Tipo', 'Tamanho (GB)', 'Saúde', 'Temperatura', 'Desgaste', 'Horas ligado') @(
            $D.discos.discos | ForEach-Object {
                $s = $Script:NomesSaude[$_.saude]; if (-not $s) { $s = $_.saude }
                , @($_.nome, "$($_.tipo) / $($_.barramento)", (Fmt-Num $_.tamanhoGB), $s,
                    $(if ($_.temperatura) { "$($_.temperatura) °C" } else { '—' }),
                    $(if ($null -ne $_.desgaste) { "$($_.desgaste)%" } else { '—' }),
                    $(if ($_.horasLigado) { $_.horasLigado } else { '—' }))
            })
        if ($D.discos.smart.falhaPrevista) { & $w '<p class="critico"><strong>ATENÇÃO: o SMART prevê falha em pelo menos um disco. Faça backup.</strong></p>' }
    }
    & $w '</section>'

    # Histórico desta máquina
    if ($D.maquina) {
        $hm = Textos-HistoricoMaquina $D.maquina
        & $w '<section><h2>Histórico desta máquina</h2><div class="grade">'
        foreach ($k in $hm.Info.Keys) { & $w "<div><span>$(Esc-Html $k)</span>$(Esc-Html $hm.Info[$k])</div>" }
        & $w '</div><h2>Comandos já executados neste PC</h2>'
        & $tabela @('Comando', 'Última execução', 'Resultado', 'Técnico') @($hm.Comandos | ForEach-Object { , @($_.titulo, (Fmt-Data $_.data), $_.resultado, $_.tecnico) })
        & $w '</section>'
    }

    # Segurança
    $seg = $D.seguranca
    if ($seg) {
        $df = $seg.defender
        & $w '<section><h2>Segurança</h2><div class="grade">'
        $itens = [ordered]@{
            'Defender – tempo real' = if ($df.disponivel) { if ($df.protecaoTempoReal) { 'Ativa' } else { 'DESATIVADA' } } else { 'Indisponível' }
            'Definições de vírus'   = if ($df.disponivel) { "$($df.idadeAssinaturaDias) dia(s)" } else { '—' }
            'Última varredura rápida' = Fmt-Data $df.ultimaVarreduraRapida
            'Firewall'              = (($seg.firewall | ForEach-Object { "$($_.perfil): $(if ($_.ativo) { 'ativo' } else { 'DESATIVADO' })" }) -join ' · ')
            'UAC'                   = if ($seg.uac) { if ($seg.uac.ativo) { 'Ativo' } else { 'DESATIVADO' } } else { '—' }
            'Secure Boot'           = if ($seg.secureBoot -eq $true) { 'Ativo' } elseif ($seg.secureBoot -eq $false) { 'Desativado' } else { 'Não suportado' }
            'Última atualização'    = if ($seg.ultimaAtualizacao) { "$($seg.ultimaAtualizacao.kb) em $(Fmt-Data $seg.ultimaAtualizacao.data)" } else { '—' }
            'Outros antivírus'      = (($df.outrosAntivirus | Where-Object { $_.nome -notmatch 'Defender' } | ForEach-Object { $_.nome }) -join ', ')
        }
        foreach ($k in $itens.Keys) { & $w "<div><span>$(Esc-Html $k)</span>$(Esc-Html $itens[$k])</div>" }
        & $w '</div><h2>Ameaças nos últimos 30 dias</h2>'
        & $tabela @('Ameaça', 'Data', 'Resolvida') @($seg.ameacas | ForEach-Object { , @($_.nome, (Fmt-Data $_.data), $(if ($_.resolvida) { 'Sim' } else { 'Não' })) })
        & $w '</section>'
    }

    # Rede
    & $w '<section><h2>Rede</h2>'
    & $tabela @('Adaptador', 'Status', 'IPv4', 'Gateway', 'DNS', 'MAC') @(
        $D.rede | Where-Object { $_.status -eq 'Up' -or $_.ipv4 } | ForEach-Object {
            , @("$($_.nome) ($($_.descricao))", $_.status, ($_.ipv4 -join ', '), ($_.gateway -join ', '), ($_.dns -join ', '), $_.mac) })
    & $w '</section>'

    # Diagnóstico
    & $w '<section><h2>Programas que iniciam com o Windows</h2>'
    & $tabela @('Programa', 'Origem', 'Situação') @($D.inicializacao | ForEach-Object { , @($_.nome, $_.origem, $(if ($_.ativo) { 'Ativo' } else { 'Desativado' })) })
    if ($D.eventos) {
        & $w ("<h2>Erros mais frequentes (últimas 72 h) — {0} erro(s), {1} crítico(s), {2} desligamento(s) inesperado(s)</h2>" -f $D.eventos.total, $D.eventos.criticos, $D.eventos.desligamentosInesperados)
        & $tabela @('Fonte', 'ID', 'Qtd.', 'Última', 'Mensagem') @($D.eventos.frequentes | ForEach-Object { , @($_.fonte, $_.id, $_.quantidade, (Fmt-Data $_.ultima), $_.mensagem) })
    }
    & $w '</section>'

    # Tarefas executadas nesta sessão
    & $w '<section><h2>Ações executadas nesta sessão</h2>'
    & $tabela @('Ação', 'Início', 'Duração', 'Resultado') @($D.tarefas | ForEach-Object {
        $e = $Script:NomesEstado[$_.estado]; if (-not $e) { $e = $_.estado }
        , @($_.titulo, (Fmt-Data $_.inicio), ('{0} min' -f [math]::Ceiling($_.duracaoSeg / 60)), "$e (código $($_.codigo))") })
    & $w '</section>'

    # Programas instalados
    & $w ("<section><h2>Programas instalados ({0})</h2>" -f @($D.programas).Count)
    & $tabela @('Programa', 'Versão', 'Fabricante') @($D.programas | ForEach-Object { , @($_.nome, $_.versao, $_.fabricante) })
    & $w '</section>'

    & $w "<footer>Gerado pelo Kitzo v$($Script:Versao)</footer></main></body></html>"
    $sb.ToString()
}

# ---------------------------------------------------------------------
# TXT (para colar em chamado / e-mail)
# ---------------------------------------------------------------------
function Gerar-TxtRelatorio {
    param($D)
    $r = $D.resumo
    $sb = New-Object Text.StringBuilder
    $w = { param($s) [void]$sb.AppendLine($s) }
    $linha = '=' * 70

    & $w $linha
    & $w " RELATÓRIO DE MANUTENÇÃO — $($r.computador)"
    & $w " Gerado em $($D.geradoEm.ToString('dd/MM/yyyy HH:mm'))"
    & $w $linha
    & $w ("Nota de saúde : {0}/100 ({1})" -f $r.nota.valor, $r.nota.classificacao)
    foreach ($a in $r.nota.alertas) { & $w ("  - {0} (-{1})" -f $a.texto, $a.pontos) }
    & $w ''
    & $w '[SISTEMA]'
    & $w ("Windows       : {0} {1} (build {2}, {3})" -f $r.windows.nome, $r.windows.versao, $r.windows.build, $r.windows.arquitetura)
    & $w ("Equipamento   : {0} {1}" -f $r.fabricante, $r.modelo)
    & $w ("Processador   : {0}" -f $r.cpu.nome)
    & $w ("Memória       : {0} GB ({1}% em uso)" -f (Fmt-Num $r.memoria.totalGB), $r.memoria.usoPercentual)
    & $w ("Último boot   : {0}" -f (Fmt-Data $r.windows.ultimoBoot))
    & $w ("Reinício pend.: {0}" -f $(if ($r.reinicio.pendente) { 'Sim - ' + ($r.reinicio.motivos -join ', ') } else { 'Não' }))
    & $w ("Últ. manutenção: {0}" -f $(if ($r.manutencao) { "$(Fmt-Data $r.manutencao.data) - $($r.manutencao.descricao)" } else { 'nenhuma registrada' }))
    if ($D.maquina) {
        $hm = Textos-HistoricoMaquina $D.maquina
        & $w ''
        & $w '[HISTÓRICO DESTA MÁQUINA]'
        foreach ($k in $hm.Info.Keys) { & $w ("{0,-16}: {1}" -f $k, $hm.Info[$k]) }
        foreach ($c in $hm.Comandos) { & $w ("  {0} - {1}: {2}" -f (Fmt-Data $c.data), $c.titulo, $c.resultado) }
    }
    & $w ''
    & $w '[UNIDADES]'
    foreach ($d in $r.discos) { & $w ("{0,-4} {1,10} GB livres de {2,10} GB ({3}% livre)" -f $d.letra, (Fmt-Num $d.livreGB), (Fmt-Num $d.totalGB), (Fmt-Num $d.livrePercentual)) }
    if ($D.discos) {
        & $w ''
        & $w '[DISCOS FÍSICOS]'
        foreach ($d in $D.discos.discos) {
            $s = $Script:NomesSaude[$d.saude]; if (-not $s) { $s = $d.saude }
            & $w ("{0} ({1}/{2}, {3} GB) - Saúde: {4}{5}" -f $d.nome, $d.tipo, $d.barramento, (Fmt-Num $d.tamanhoGB), $s, $(if ($d.temperatura) { ", $($d.temperatura) °C" } else { '' }))
        }
    }
    if ($D.seguranca) {
        $df = $D.seguranca.defender
        & $w ''
        & $w '[SEGURANÇA]'
        & $w ("Defender      : {0}" -f $(if ($df.disponivel) { if ($df.protecaoTempoReal) { "ativo (definições com $($df.idadeAssinaturaDias) dia(s))" } else { 'TEMPO REAL DESATIVADO' } } else { 'indisponível' }))
        & $w ("Firewall      : {0}" -f (($D.seguranca.firewall | ForEach-Object { "$($_.perfil)=$(if ($_.ativo) { 'on' } else { 'OFF' })" }) -join ', '))
        & $w ("Ameaças 30d   : {0}" -f @($D.seguranca.ameacas).Count)
    }
    & $w ''
    & $w '[REDE]'
    foreach ($a in ($D.rede | Where-Object { $_.status -eq 'Up' })) {
        & $w ("{0}: IP {1} | Gateway {2} | DNS {3}" -f $a.nome, ($a.ipv4 -join ', '), ($a.gateway -join ', '), ($a.dns -join ', '))
    }
    if ($D.eventos) {
        & $w ''
        & $w ("[EVENTOS 72h] {0} erro(s), {1} crítico(s), {2} desligamento(s) inesperado(s)" -f $D.eventos.total, $D.eventos.criticos, $D.eventos.desligamentosInesperados)
        foreach ($e in $D.eventos.frequentes) { & $w ("  {0,4}x  {1} ({2}): {3}" -f $e.quantidade, $e.fonte, $e.id, $e.mensagem) }
    }
    & $w ''
    & $w '[AÇÕES NESTA SESSÃO]'
    if (-not @($D.tarefas).Count) { & $w '  nenhuma' }
    foreach ($t in $D.tarefas) {
        $e = $Script:NomesEstado[$t.estado]; if (-not $e) { $e = $t.estado }
        & $w ("  {0} - {1}: {2} (código {3})" -f (Fmt-Data $t.inicio), $t.titulo, $e, $t.codigo)
    }
    & $w ''
    & $w ("[PROGRAMAS INSTALADOS: {0}]" -f @($D.programas).Count)
    foreach ($p in $D.programas) { & $w ("  {0} {1}" -f $p.nome, $p.versao) }
    $sb.ToString()
}

# Nomes de arquivo aceitos para abrir (evita abrir caminhos arbitrários)
$Script:PadraoArquivoRelatorio = '^relatorio_[A-Za-z0-9_\-]+\.(html|txt)$'

# ---------------------------------------------------------------------
# Ações
# ---------------------------------------------------------------------
Registrar-Acao -Nome 'relatorio.gerar' -Descricao 'Gera relatório HTML e TXT em logs\' -Bloco {
    param($P)
    $dados = Coletar-DadosRelatorio
    $pc = $env:COMPUTERNAME -replace '[^A-Za-z0-9_\-]', '_'
    $base = 'relatorio_{0}_{1:yyyy-MM-dd_HHmm}' -f $pc, $dados.geradoEm
    $html = Join-Path $Script:PastaLogs "$base.html"
    $txt = Join-Path $Script:PastaLogs "$base.txt"
    $utf8Bom = New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($html, (Gerar-HtmlRelatorio $dados), $utf8Bom)
    [IO.File]::WriteAllText($txt, (Gerar-TxtRelatorio $dados), $utf8Bom)
    Escrever-Log "Relatório gerado: $base (.html e .txt)" -Nivel ACAO
    Registrar-Historico -Acao 'relatorio.gerar' -Titulo 'Relatório gerado' -Resultado 'ok' -Detalhes "$base.html / $base.txt"
    [ordered]@{ html = "$base.html"; txt = "$base.txt"; pasta = $Script:PastaLogs }
}

Registrar-Acao -Nome 'relatorio.listar' -Descricao 'Relatórios salvos no pendrive' -Bloco {
    param($P)
    $lista = @(Get-ChildItem -LiteralPath $Script:PastaLogs -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $Script:PadraoArquivoRelatorio } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 100 | ForEach-Object {
            $pc = if ($_.BaseName -match '^relatorio_(.+)_\d{4}-\d{2}-\d{2}_\d{4}$') { $Matches[1] } else { '' }
            [ordered]@{ arquivo = $_.Name; computador = $pc; data = Formatar-Data $_.LastWriteTime; tamanhoKB = [math]::Ceiling($_.Length / 1KB) }
        })
    [ordered]@{ pasta = $Script:PastaLogs; relatorios = $lista }
}

Registrar-Acao -Nome 'relatorio.abrir' -Descricao 'Abre um relatório com o programa padrão' -Bloco {
    param($P)
    $nome = Ler-Parametro $P 'arquivo' -Padrao $Script:PadraoArquivoRelatorio -Obrigatorio
    $caminho = Join-Path $Script:PastaLogs $nome
    if (-not (Test-Path -LiteralPath $caminho -PathType Leaf)) { throw 'Relatório não encontrado.' }
    Abrir-NoExplorer $caminho
    [ordered]@{ mensagem = "Abrindo $nome" }
}

Registrar-Acao -Nome 'relatorio.abrir_pasta' -Descricao 'Abre a pasta logs no Explorer' -Bloco {
    param($P)
    Abrir-NoExplorer $Script:PastaLogs
    [ordered]@{ mensagem = 'Pasta de logs aberta.' }
}
