<#
  modulos\historico.ps1 — Histórico por máquina.

  Responde perguntas como: "este PC já passou por aqui?", "já rodei o SFC nele?",
  "está locado/revisado?". Os dados ficam no pendrive:
    logs\maquinas\<id>.json      registro completo de cada máquina
    logs\historico_geral.csv     uma linha por evento, de todas as máquinas (Excel)
  As funções de gravação ficam no servidor.ps1 (Registrar-Historico etc.).
#>

# Lista resumida de todas as máquinas registradas neste pendrive
function Obter-MaquinasRegistradas {
    @(Get-ChildItem -LiteralPath $Script:PastaMaquinas -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $m = if ($Script:Maquina -and $_.BaseName -eq $Script:Maquina.id) { $Script:Maquina } else { Ler-Json $_.FullName }
        if (-not $m) { return }
        [ordered]@{
            id               = $m.id
            computador       = $m.computador
            fabricante       = $m.fabricante
            modelo           = $m.modelo
            serial           = $m.serial
            sessoes          = $m.sessoes
            primeiraVisita   = $m.primeiraVisita
            ultimaVisita     = $m.ultimaVisita
            situacao         = $m.situacao
            ultimaManutencao = $m.ultimaManutencao
            atual            = ($Script:Maquina -and $m.id -eq $Script:Maquina.id)
        }
    } | Sort-Object { $_.ultimaVisita } -Descending)
}

# Mapa "ação -> última execução" (o painel mostra ao lado de cada botão)
function Obter-MapaComandos {
    $mapa = [ordered]@{}
    if ($Script:Maquina) { foreach ($k in @($Script:Maquina.comandos.Keys)) { $mapa[$k] = $Script:Maquina.comandos[$k] } }
    $mapa
}

# ---------------------------------------------------------------------
# Ações
# ---------------------------------------------------------------------
Registrar-Acao -Nome 'historico.maquina' -Silenciosa -Descricao 'Histórico desta máquina' -Bloco {
    param($P)
    $resumo = Ler-Parametro $P 'resumo' -Permitidos 'true', 'false' -ValorPadrao 'false'
    $m = $Script:Maquina
    if (-not $m) { throw 'O histórico desta máquina não pôde ser aberto (veja o log).' }

    $r = [ordered]@{
        maquina      = [ordered]@{
            id = $m.id; baseId = $m.baseId; computador = $m.computador; nomesAnteriores = @($m.nomesAnteriores)
            fabricante = $m.fabricante; modelo = $m.modelo; serial = $m.serial; uuid = $m.uuid
            primeiraVisita = $m.primeiraVisita; ultimaVisita = $m.ultimaVisita; visitaAnterior = $m.visitaAnterior
            sessoes = $m.sessoes; situacao = $m.situacao; ultimaManutencao = $m.ultimaManutencao
        }
        tecnico      = [string]$Script:Config.tecnico
        comandosMapa = Obter-MapaComandos
    }
    if ($resumo -ne 'true') {
        # Mais recente primeiro, até 300 eventos
        $eventos = @($m.historico)
        [array]::Reverse($eventos)
        $r['historico'] = @($eventos | Select-Object -First 300)
        $r['arquivo'] = $Script:ArquivoMaquina
    }
    $r
}

Registrar-Acao -Nome 'historico.maquinas' -Descricao 'Máquinas registradas no pendrive' -Bloco {
    param($P)
    [ordered]@{ maquinas = Obter-MaquinasRegistradas; pasta = $Script:PastaMaquinas }
}

# Situação da máquina: em revisão, revisada, locada, disponível, com defeito (+ observação)
Registrar-Acao -Nome 'historico.situacao' -Descricao 'Define a situação da máquina' -Bloco {
    param($P)
    $situacao = Ler-Parametro $P 'situacao' -Permitidos (@('') + $Script:Situacoes) -ValorPadrao ''
    $obs = Ler-Parametro $P 'observacao' -MaxTamanho 500 -ValorPadrao ''
    if ($obs -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { Erro-Entrada 'A observação contém caracteres inválidos.' }
    $m = $Script:Maquina
    if (-not $m) { throw 'O histórico desta máquina não está disponível.' }

    $m.situacao = if ($situacao -or $obs) {
        [ordered]@{ valor = $situacao; observacao = $obs; tecnico = [string]$Script:Config.tecnico; data = Formatar-Data (Get-Date) }
    } else { $null }
    $txt = if ($situacao) { $situacao } else { '(sem situação)' }
    Registrar-Historico -Acao 'historico.situacao' -Titulo 'Situação da máquina alterada' -Resultado 'info' -Detalhes ("{0}{1}" -f $txt, $(if ($obs) { " - $obs" } else { '' }))
    [ordered]@{ mensagem = 'Situação salva no histórico da máquina.'; situacao = $m.situacao }
}

# Nome do técnico (fica no pendrive e vai junto em cada evento do histórico)
Registrar-Acao -Nome 'historico.tecnico' -Descricao 'Define o técnico responsável' -Bloco {
    param($P)
    $nome = Ler-Parametro $P 'nome' -Padrao '^[\p{L}\p{N} .\-_]{1,60}$' -MaxTamanho 60 -ValorPadrao ''
    $Script:Config.tecnico = $nome
    Salvar-Config
    Escrever-Log "Técnico responsável definido: $(if ($nome) { $nome } else { '(nenhum)' })"
    [ordered]@{ mensagem = 'Técnico salvo.'; tecnico = $nome }
}

Registrar-Acao -Nome 'historico.abrir_planilha' -Descricao 'Abre o historico_geral.csv' -Bloco {
    param($P)
    $arq = Join-Path $Script:PastaLogs 'historico_geral.csv'
    if (-not (Test-Path -LiteralPath $arq)) { throw 'A planilha ainda não foi criada.' }
    Abrir-NoExplorer $arq
    [ordered]@{ mensagem = 'Abrindo historico_geral.csv' }
}
