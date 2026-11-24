#Requires -Version 5.1
<#
.SYNOPSIS
    Servidor local do Kitzo (painel de diagnóstico e manutenção do Windows).

.DESCRIPTION
    - Roda em SEGUNDO PLANO (janela oculta) e escuta SOMENTE em http://localhost:8080/.
    - Encerra sozinho quando o painel deixa de responder (navegador/aba fechados),
      mas NUNCA no meio de uma tarefa (SFC, DISM, limpeza...): espera ela terminar.
    - A cada execução gera um token aleatório, exigido no cabeçalho X-Token da API.
    - Só executa ações registradas pelos módulos (lista fixa / "allowlist").
      Nenhum texto vindo do navegador é executado como comando.
    - Ações que alteram o sistema exigem "confirmado": true no corpo da requisição.
    - Tudo é registrado em logs\, inclusive um HISTÓRICO POR MÁQUINA
      (logs\maquinas\<id>.json) e uma planilha geral (logs\historico_geral.csv).

    Este arquivo é o "núcleo". As funcionalidades ficam em modulos\*.ps1, que são
    carregados automaticamente e registram suas ações com Registrar-Acao.
#>

$ErrorActionPreference = 'Stop'

# =====================================================================
# 1. Caminhos, limites e estado global (sempre relativos ao script => portátil)
# =====================================================================
$Script:Versao       = '1.1.0'
$Script:Porta        = 8080
$Script:Raiz         = $PSScriptRoot
$Script:PastaWeb     = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'web'))
$Script:PastaModulos = Join-Path $PSScriptRoot 'modulos'
$Script:PastaLogs    = Join-Path $PSScriptRoot 'logs'

# Encerramento automático (segundos)
$Script:LimitePrimeiroContato = 300   # tempo para o navegador abrir o painel pela 1ª vez
$Script:LimiteSemContato      = 90    # sem nenhum sinal do painel => navegador fechado
$Script:LimiteAposFechar      = 20    # após a aba avisar que fechou (dá tempo de um F5)

# Estado compartilhado com os módulos (hashtable => alterações valem em qualquer escopo)
$Script:Estado = @{
    Rodando            = $true
    Inicio             = Get-Date
    UltimoContato      = $null    # última requisição autenticada do painel
    FechamentoPedido   = $null    # a aba avisou que foi fechada
    UltimaVerificacao  = Get-Date # detecta suspensão do PC (sleep)
    AvisouEspera       = $false
    MotivoEncerramento = 'desconhecido'
}

# Garante a pasta de logs. Se o pendrive estiver protegido contra gravação,
# usa a pasta temporária do usuário.
function Preparar-PastaLogs {
    try {
        if (-not (Test-Path -LiteralPath $Script:PastaLogs)) {
            New-Item -ItemType Directory -Path $Script:PastaLogs -Force | Out-Null
        }
        $teste = Join-Path $Script:PastaLogs '.teste_gravacao'
        [IO.File]::WriteAllText($teste, 'ok')
        Remove-Item -LiteralPath $teste -Force
        $Script:LogsNoPendrive = $true
    }
    catch {
        $Script:PastaLogs = Join-Path $env:TEMP 'Kitzo_logs'
        New-Item -ItemType Directory -Path $Script:PastaLogs -Force | Out-Null
        $Script:LogsNoPendrive = $false
    }
}
Preparar-PastaLogs

# Pasta com a saída de cada tarefa em segundo plano (apaga as de mais de 15 dias)
$Script:PastaTarefas = Join-Path $Script:PastaLogs 'tarefas'
$Script:PastaMaquinas = Join-Path $Script:PastaLogs 'maquinas'
try {
    New-Item -ItemType Directory -Path $Script:PastaTarefas -Force | Out-Null
    New-Item -ItemType Directory -Path $Script:PastaMaquinas -Force | Out-Null
    Get-ChildItem -LiteralPath $Script:PastaTarefas -Directory |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-15) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} catch { }

# =====================================================================
# 2. Utilitários compartilhados (podem ser usados por todos os módulos)
# =====================================================================

# Registra uma linha no log do dia, separado por computador
# (o mesmo pendrive passa por vários PCs).
function Escrever-Log {
    param(
        [Parameter(Mandatory)][string]$Mensagem,
        [ValidateSet('INFO', 'AVISO', 'ERRO', 'ACAO')][string]$Nivel = 'INFO'
    )
    $agora = Get-Date
    $linha = '{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] {2}' -f $agora, $Nivel, $Mensagem
    $arquivo = Join-Path $Script:PastaLogs ('acoes_{0}_{1:yyyy-MM-dd}.log' -f $env:COMPUTERNAME, $agora)
    try { [IO.File]::AppendAllText($arquivo, $linha + "`r`n", [Text.Encoding]::UTF8) } catch { }

    # Só aparece quando aberto pelo Iniciar-Console.bat (modo de diagnóstico)
    $cor = switch ($Nivel) { 'ERRO' { 'Red' } 'AVISO' { 'Yellow' } 'ACAO' { 'Cyan' } default { 'Gray' } }
    try { Write-Host $linha -ForegroundColor $cor } catch { }
}

# Janela de aviso (o servidor roda oculto, então erros graves aparecem assim)
function Mostrar-Aviso {
    param([Parameter(Mandatory)][string]$Texto, [ValidateSet('erro', 'info')][string]$Tipo = 'erro')
    try {
        $icone = if ($Tipo -eq 'erro') { 0x10 } else { 0x40 }
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.Popup($Texto, 0, 'Kitzo', $icone + 0x1000)   # 0x1000 = sempre na frente
    } catch { }
}

# Executa um bloco e devolve um valor padrão em caso de erro.
# Útil para coletas que podem falhar em alguns PCs (WMI corrompido, recurso ausente etc.).
function Tentar {
    param([scriptblock]$Bloco, $Padrao = $null)
    try { & $Bloco } catch { $Padrao }
}

# Converte DateTime para texto ISO local (o ConvertTo-Json do PS 5.1 gera "\/Date(...)\/").
function Formatar-Data {
    param($Data)
    if ($Data -is [datetime] -and $Data.Year -gt 1601) { return $Data.ToString('yyyy-MM-ddTHH:mm:ss') }
    return $null
}

function Ler-DataIso {
    param($Texto)
    if ($Texto -is [datetime]) { return $Texto }
    if (-not $Texto) { return $null }
    Tentar { [datetime]::ParseExact([string]$Texto, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
}

# ConvertFrom-Json do PS 5.1 não tem -AsHashtable: converte recursivamente
function Converter-ParaHashtable {
    param($Objeto)
    if ($null -eq $Objeto) { return $null }
    if ($Objeto -is [Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Objeto.PSObject.Properties) { $h[$p.Name] = Converter-ParaHashtable $p.Value }
        return $h
    }
    if ($Objeto -is [array]) {
        $lista = New-Object System.Collections.ArrayList
        foreach ($item in $Objeto) { [void]$lista.Add((Converter-ParaHashtable $item)) }
        return , $lista
    }
    return $Objeto
}

# Lê um JSON (tenta também a cópia .tmp, caso o pendrive tenha sido removido no meio de uma gravação)
function Ler-Json {
    param([Parameter(Mandatory)][string]$Caminho)
    foreach ($c in @($Caminho, "$Caminho.tmp")) {
        if (-not [IO.File]::Exists($c)) { continue }
        try {
            $obj = [IO.File]::ReadAllText($c, [Text.Encoding]::UTF8) | ConvertFrom-Json
            return (Converter-ParaHashtable $obj)
        } catch { }
    }
    return $null
}

# Grava primeiro em .tmp e só depois substitui o arquivo definitivo
function Salvar-Json {
    param([Parameter(Mandatory)][string]$Caminho, [Parameter(Mandatory)]$Objeto)
    $tmp = "$Caminho.tmp"
    $json = ConvertTo-Json -InputObject $Objeto -Depth 10
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($true)))
    [IO.File]::Copy($tmp, $Caminho, $true)
    [IO.File]::Delete($tmp)
}

# =====================================================================
# 2b. Histórico por máquina
#     Cada PC é identificado pelo UUID da placa-mãe + número de série da BIOS
#     (não pelo nome, que pode mudar). Fica em logs\maquinas\<id>.json e
#     cada evento também vai para logs\historico_geral.csv (abre no Excel).
# =====================================================================
$Script:Maquina = $null
$Script:ArquivoMaquina = $null
$Script:Config = [ordered]@{ tecnico = '' }
$Script:ArquivoConfig = Join-Path $Script:PastaLogs 'config.json'

# Situações que o técnico pode marcar para a máquina (lista fixa)
$Script:Situacoes = @('em_revisao', 'revisada', 'locada', 'disponivel', 'defeito')

function Carregar-Config {
    $c = Ler-Json $Script:ArquivoConfig
    if ($c) { foreach ($k in @($c.Keys)) { $Script:Config[$k] = $c[$k] } }
}

function Salvar-Config {
    try { Salvar-Json $Script:ArquivoConfig $Script:Config } catch { Escrever-Log "Não foi possível salvar config.json: $($_.Exception.Message)" -Nivel ERRO }
}

function Obter-IdentidadeMaquina {
    $produto = Tentar { Get-CimInstance -ClassName Win32_ComputerSystemProduct }
    $bios = Tentar { Get-CimInstance -ClassName Win32_BIOS }
    $cs = Tentar { Get-CimInstance -ClassName Win32_ComputerSystem }

    # Valores "de fábrica" que muitos fabricantes deixam no lugar do número real
    $invalido = '^(|0+|none|n/?a|default string|to be filled.*|system serial number|not specified|not applicable|o\.?e\.?m\.?.*|chassis serial number|123456789|serial)$'
    $serial = if ($bios) { ([string]$bios.SerialNumber).Trim() } else { '' }
    if ($serial -match $invalido) { $serial = '' }
    $uuid = if ($produto) { ([string]$produto.UUID).Trim().ToUpperInvariant() } else { '' }
    if ($uuid -match '^(|0{8}-0{4}-0{4}-0{4}-0{12}|F{8}-F{4}-F{4}-F{4}-F{12}|03000200-0400-0500-0006-000700080009)$') { $uuid = '' }

    $partes = @()
    if ($uuid) { $partes += "uuid:$uuid" }
    if ($serial) { $partes += "serial:$serial" }
    if (-not $partes) { $partes += "nome:$($env:COMPUTERNAME)" }
    $chave = ($partes -join '|').ToUpperInvariant()

    $sha = [Security.Cryptography.SHA1]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($chave)) } finally { $sha.Dispose() }
    $id = -join ($bytes[0..5] | ForEach-Object { $_.ToString('x2') })

    [ordered]@{
        id         = $id
        baseId     = if ($uuid -and $serial) { 'UUID + número de série' } elseif ($uuid) { 'UUID' } elseif ($serial) { 'Número de série' } else { 'Nome do computador' }
        computador = $env:COMPUTERNAME
        fabricante = if ($cs) { ([string]$cs.Manufacturer).Trim() } else { '' }
        modelo     = if ($cs) { ([string]$cs.Model).Trim() } else { '' }
        serial     = $serial
        uuid       = $uuid
    }
}

# Abre (ou cria) o registro desta máquina e conta uma nova sessão
function Iniciar-SessaoMaquina {
    $ident = Obter-IdentidadeMaquina
    $arq = Join-Path $Script:PastaMaquinas "$($ident.id).json"
    $m = Ler-Json $arq
    $agora = Formatar-Data (Get-Date)

    if (-not $m) {
        $m = [ordered]@{
            versao = 1; id = $ident.id; baseId = $ident.baseId
            computador = $ident.computador; nomesAnteriores = @()
            fabricante = $ident.fabricante; modelo = $ident.modelo; serial = $ident.serial; uuid = $ident.uuid
            primeiraVisita = $agora; ultimaVisita = $null; visitaAnterior = $null; sessoes = 0
            situacao = $null; ultimaManutencao = $null
            comandos = [ordered]@{}; historico = @()
        }
        # Migração da versão 1.0 (historico_manutencao.json, indexado pelo nome do PC)
        $antigo = Ler-Json (Join-Path $Script:PastaLogs 'historico_manutencao.json')
        if ($antigo -and $antigo.Contains($env:COMPUTERNAME)) {
            $v = $antigo[$env:COMPUTERNAME]
            $m.ultimaManutencao = [ordered]@{ data = [string]$v.data; descricao = [string]$v.descricao }
        }
    }

    # O PC foi renomeado desde a última visita?
    if ($m.computador -and $m.computador -ne $env:COMPUTERNAME) {
        $m.nomesAnteriores = @(@($m.nomesAnteriores) + $m.computador | Where-Object { $_ } | Select-Object -Unique)
    }
    $m.computador = $ident.computador
    $m.fabricante = $ident.fabricante
    $m.modelo = $ident.modelo
    $m.serial = $ident.serial
    $m.uuid = $ident.uuid
    $m.visitaAnterior = $m.ultimaVisita
    $m.ultimaVisita = $agora
    $m.sessoes = [int]$m.sessoes + 1
    if (-not $m.comandos) { $m.comandos = [ordered]@{} }
    $hist = New-Object System.Collections.ArrayList
    foreach ($e in @($m.historico)) { if ($e) { [void]$hist.Add($e) } }
    $m.historico = $hist

    $Script:Maquina = $m
    $Script:ArquivoMaquina = $arq
    $detalhe = if ($m.visitaAnterior) { "Sessão nº $($m.sessoes); visita anterior em $($m.visitaAnterior)" } else { 'Primeira vez neste PC' }
    Registrar-Historico -Acao 'sessao.inicio' -Titulo 'Ferramenta aberta neste PC' -Resultado 'info' -Detalhes $detalhe
}

function Salvar-RegistroMaquina {
    if (-not $Script:Maquina) { return }
    try { Salvar-Json $Script:ArquivoMaquina $Script:Maquina }
    catch { Escrever-Log "Não foi possível salvar o histórico da máquina: $($_.Exception.Message)" -Nivel ERRO }
}

# Linha na planilha geral (todas as máquinas, abre no Excel)
function Anexar-CsvGeral {
    param($Entrada)
    $arq = Join-Path $Script:PastaLogs 'historico_geral.csv'
    $m = $Script:Maquina
    $campos = @($Entrada.data, $m.computador, $m.id, $m.serial, $Entrada.usuario, $Entrada.tecnico,
        $Entrada.acao, $Entrada.titulo, $Entrada.resultado, $Entrada.codigo, $Entrada.detalhes)
    $linha = ($campos | ForEach-Object {
            $v = ([string]$_) -replace '[\r\n]+', ' '
            if ($v -match '^[=+\-@]') { $v = "'" + $v }   # evita que o Excel interprete como fórmula
            '"' + $v.Replace('"', '""') + '"'
        }) -join ';'
    try {
        if (-not [IO.File]::Exists($arq)) {
            [IO.File]::WriteAllText($arq, "data;computador;id_maquina;serial;usuario;tecnico;acao;titulo;resultado;codigo;detalhes`r`n", (New-Object Text.UTF8Encoding($true)))
        }
        [IO.File]::AppendAllText($arq, $linha + "`r`n", (New-Object Text.UTF8Encoding($false)))
    }
    catch { Escrever-Log 'historico_geral.csv está aberto em outro programa (Excel?): linha não gravada.' -Nivel AVISO }
}

<#
  Registrar-Historico: grava um evento no histórico DESTA máquina.
    -Acao       nome da ação (ex.: 'reparo.sfc'); também indexa "última execução"
    -Resultado  iniciada | concluida | falhou | cancelada | ok | erro | info
                ('info' não altera a "última execução" do comando)
#>
function Registrar-Historico {
    param(
        [Parameter(Mandatory)][string]$Acao,
        [string]$Titulo = '',
        [ValidateSet('iniciada', 'concluida', 'falhou', 'cancelada', 'ok', 'erro', 'info')][string]$Resultado = 'ok',
        [string]$Detalhes = '',
        $Codigo = $null
    )
    if (-not $Script:Maquina) { return }
    $entrada = [ordered]@{
        data      = Formatar-Data (Get-Date)
        acao      = $Acao
        titulo    = $Titulo
        resultado = $Resultado
        codigo    = $Codigo
        usuario   = "$env:USERDOMAIN\$env:USERNAME"
        tecnico   = [string]$Script:Config.tecnico
        detalhes  = $Detalhes
    }
    $m = $Script:Maquina
    [void]$m.historico.Add($entrada)
    while ($m.historico.Count -gt 1000) { $m.historico.RemoveAt(0) }
    # 'info' e ações internas (tarefa.cancelar...) não contam como "comando executado"
    if ($Resultado -ne 'info' -and $Acao -notlike 'tarefa.*') {
        $m.comandos[$Acao] = [ordered]@{
            data = $entrada.data; titulo = $Titulo; resultado = $Resultado; codigo = $Codigo; tecnico = $entrada.tecnico
        }
    }
    Salvar-RegistroMaquina
    Anexar-CsvGeral $entrada
}

function Obter-UltimaManutencao {
    if ($Script:Maquina) { return $Script:Maquina.ultimaManutencao }
    return $null
}

# Chamado ao concluir uma manutenção (limpeza, reparo, atualização de programas)
function Registrar-Manutencao {
    param([Parameter(Mandatory)][string]$Descricao)
    if (-not $Script:Maquina) { return }
    $Script:Maquina.ultimaManutencao = [ordered]@{ data = Formatar-Data (Get-Date); descricao = $Descricao }
    Salvar-RegistroMaquina
}

# Resumo curto para a tela Início
function Resumo-Maquina {
    $m = $Script:Maquina
    if (-not $m) { return $null }
    [ordered]@{
        id              = $m.id
        baseId          = $m.baseId
        serial          = $m.serial
        sessoes         = $m.sessoes
        primeiraVisita  = $m.primeiraVisita
        visitaAnterior  = $m.visitaAnterior
        nomesAnteriores = @($m.nomesAnteriores)
        situacao        = $m.situacao
        comandosExecutados = @($m.comandos.Keys | Where-Object { $_ -notlike 'historico.*' }).Count
        tecnico         = [string]$Script:Config.tecnico
    }
}

# =====================================================================
# 3. Registro de ações (a "lista fixa" de tudo que a API pode executar)
# =====================================================================
$Script:Acoes = @{}

<#
  Registrar-Acao: usado pelos módulos para expor uma ação na API.
    -Nome           'modulo.acao' (somente minúsculas, números e _)
    -Bloco          scriptblock que recebe um parâmetro ($P = objeto "params" do JSON)
                    e devolve UM objeto (hashtable/[ordered]/pscustomobject).
    -AlteraSistema  exige confirmação explícita (confirmado: true), é logado como ACAO
                    e entra no histórico da máquina.
    -Silenciosa     não grava no log quando dá certo (consultas repetidas, ex.: polling)
  Cada ação é responsável por VALIDAR os campos de $P que usar.
#>
function Registrar-Acao {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z]+\.[a-z0-9_]+$')][string]$Nome,
        [Parameter(Mandatory)][scriptblock]$Bloco,
        [string]$Descricao = '',
        [switch]$AlteraSistema,
        [switch]$Silenciosa
    )
    $Script:Acoes[$Nome] = [pscustomobject]@{
        Nome          = $Nome
        Bloco         = $Bloco
        Descricao     = $Descricao
        AlteraSistema = [bool]$AlteraSistema
        Silenciosa    = [bool]$Silenciosa
    }
}

# =====================================================================
# 3b. Utilitários de validação e caminhos do sistema
# =====================================================================

# Caminho de um executável do Windows (System32), corrigindo o redirecionamento
# de 32 bits caso o PowerShell tenha sido aberto em modo x86.
function Caminho-Sistema {
    param([Parameter(Mandatory)][string]$Arquivo)
    $pasta = if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        Join-Path $env:SystemRoot 'Sysnative'
    } else { Join-Path $env:SystemRoot 'System32' }
    Join-Path $pasta $Arquivo
}

# Erro de validação de entrada (vira HTTP 400 em vez de 500)
function Erro-Entrada {
    param([string]$Mensagem)
    throw (New-Object ArgumentException($Mensagem))
}

<#
  Ler-Parametro: lê e VALIDA um campo simples vindo do navegador.
    -Padrao      expressão regular que o valor inteiro precisa satisfazer
    -Permitidos  lista fixa de valores aceitos
    -MaxTamanho  tamanho máximo do texto (padrão 200)
  Objetos e listas são recusados (use Ler-ListaParametro).
#>
function Ler-Parametro {
    param(
        $P,
        [Parameter(Mandatory)][string]$Nome,
        [string]$Padrao,
        [string[]]$Permitidos,
        $ValorPadrao = $null,
        [int]$MaxTamanho = 200,
        [switch]$Obrigatorio
    )
    $prop = if ($P) { $P.PSObject.Properties[$Nome] } else { $null }
    $valor = if ($prop) { $prop.Value } else { $null }
    if ($null -eq $valor -or "$valor" -eq '') {
        if ($Obrigatorio) { Erro-Entrada "Parâmetro obrigatório ausente: $Nome" }
        return $ValorPadrao
    }
    if ($valor -is [array] -or $valor -is [Management.Automation.PSCustomObject]) { Erro-Entrada "Formato inválido para o parâmetro $Nome." }
    $texto = ([string]$valor).Trim()
    if ($texto.Length -gt $MaxTamanho) { Erro-Entrada "Valor muito longo para o parâmetro $Nome (máximo $MaxTamanho caracteres)." }
    if ($Permitidos -and ($Permitidos -notcontains $texto)) { Erro-Entrada "Valor não permitido para o parâmetro $Nome." }
    if ($Padrao -and ($texto -notmatch $Padrao)) { Erro-Entrada "Valor inválido para o parâmetro $Nome." }
    return $texto
}

# Lê uma lista de textos, aceitando somente valores da lista fixa.
function Ler-ListaParametro {
    param($P, [Parameter(Mandatory)][string]$Nome, [Parameter(Mandatory)][string[]]$Permitidos)
    $prop = if ($P) { $P.PSObject.Properties[$Nome] } else { $null }
    if (-not $prop -or $null -eq $prop.Value) { Erro-Entrada "Parâmetro obrigatório ausente: $Nome" }
    $itens = @($prop.Value)
    if ($itens.Count -eq 0 -or $itens.Count -gt 50) { Erro-Entrada "Lista inválida: $Nome" }
    foreach ($i in $itens) {
        if ($i -isnot [string] -or $Permitidos -notcontains $i) { Erro-Entrada "Valor não permitido em $Nome." }
    }
    , [string[]]$itens
}

# Abre um arquivo/pasta/URL com o programa padrão do usuário.
# Via explorer.exe, o programa abre como o usuário comum (não elevado).
function Abrir-NoExplorer {
    param([Parameter(Mandatory)][string]$Caminho, [switch]$Selecionar)
    $arg = if ($Selecionar) { "/select,`"$Caminho`"" } else { "`"$Caminho`"" }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList $arg
}

# =====================================================================
# 3c. Tarefas em segundo plano (SFC, DISM, CHKDSK, winget, ping, scripts...)
#     O servidor atende uma requisição por vez. Por isso, tudo que demora roda
#     como PROCESSO SEPARADO, com a saída gravada em logs\tarefas\<id>\.
#     O painel consulta o andamento a cada segundo (polling) via tarefa.estado.
# =====================================================================
$Script:Tarefas = @{}
$Script:ContadorTarefas = 0

# Codificação "OEM" do console (ping, dism, chkdsk escrevem nela; ex.: 850 no Brasil)
$Script:CodificacaoOem = Tentar -Padrao ([Text.Encoding]::Default) {
    $cp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage').OEMCP
    [Text.Encoding]::GetEncoding([int]$cp)
}

# Descobre se a saída de um programa está em UTF-16 (sfc.exe), UTF-8 (winget, scripts)
# ou na página de código OEM (ferramentas clássicas). $null = ainda só há ASCII.
function Detectar-Codificacao {
    param([byte[]]$Buf, [int]$Qtd)
    if ($Qtd -le 0) { return $null }
    $amostra = [math]::Min($Qtd, 4000)
    $zeros = 0
    for ($i = 1; $i -lt $amostra; $i += 2) { if ($Buf[$i] -eq 0) { $zeros++ } }
    if ($zeros -gt ($amostra / 8)) { return 'utf16' }

    $latin = [Text.Encoding]::GetEncoding(28591).GetString($Buf, 0, $Qtd)
    if ($latin -notmatch '[\x80-\xff]') { return $null }

    $estrito = New-Object Text.UTF8Encoding($false, $true)   # lança erro se não for UTF-8 válido
    $ini = 0
    while ($ini -lt 3 -and $ini -lt $Qtd -and $Buf[$ini] -ge 0x80 -and $Buf[$ini] -le 0xBF) { $ini++ }
    for ($corte = 0; $corte -le 3; $corte++) {
        $n = $Qtd - $ini - $corte
        if ($n -le 0) { break }
        try { [void]$estrito.GetString($Buf, $ini, $n); return 'utf8' } catch { }
    }
    return 'oem'
}

# Lê (até $Maximo bytes do fim de) um arquivo que ainda pode estar sendo escrito.
function Ler-ArquivoSaida {
    param([string]$Caminho, [string]$Codificacao, [int]$Maximo = 262144)
    $r = [pscustomobject]@{ Texto = ''; Codificacao = $Codificacao }
    if (-not $Caminho -or -not [IO.File]::Exists($Caminho)) { return $r }
    $fs = $null
    try {
        $fs = New-Object IO.FileStream($Caminho, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $tam = $fs.Length
        if ($tam -eq 0) { return $r }
        $inicio = [long][math]::Max([long]0, $tam - $Maximo)
        if ($inicio % 2) { $inicio++ }   # mantém o alinhamento do UTF-16
        $fs.Position = $inicio
        $qtd = [int]($tam - $inicio)
        $buf = New-Object byte[] $qtd
        $lidos = 0
        while ($lidos -lt $qtd) {
            $n = $fs.Read($buf, $lidos, $qtd - $lidos)
            if ($n -le 0) { break }
            $lidos += $n
        }
    }
    catch { return $r }
    finally { if ($fs) { $fs.Dispose() } }

    if (-not $r.Codificacao) { $r.Codificacao = Detectar-Codificacao $buf $lidos }
    switch ($r.Codificacao) {
        'utf16' { $texto = [Text.Encoding]::Unicode.GetString($buf, 0, $lidos - ($lidos % 2)) }
        'oem'   { $texto = $Script:CodificacaoOem.GetString($buf, 0, $lidos) }
        default { $texto = [Text.Encoding]::UTF8.GetString($buf, 0, $lidos) }
    }
    $texto = $texto.Replace([string][char]0xFEFF, '').Replace([string][char]0, '')
    if ($inicio -gt 0) {
        $p = $texto.IndexOf("`n")
        if ($p -ge 0) { $texto = $texto.Substring($p + 1) }
    }
    $r.Texto = $texto
    $r
}

# Converte a saída bruta em linhas "como no terminal": trata o `r das barras de
# progresso (a última atualização vence), remove códigos de cor e o "spinner" do winget.
function Converter-Linhas {
    param([string]$Texto, [int]$Maximo = 400)
    $linhas = New-Object System.Collections.Generic.List[string]
    $vazias = 0
    foreach ($bruta in ($Texto -split "`n")) {
        $l = $bruta -replace "`r$", ''
        if ($l.Contains("`r")) {
            $partes = @($l -split "`r" | Where-Object { $_.Trim() -ne '' })
            $l = if ($partes.Count) { $partes[-1] } else { '' }
        }
        $l = $l -replace '\x1b\[[0-9;?]*[A-Za-z]', '' -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
        if ($l -match '^\s*[-\\|/]\s*$' -or $l -match '^##PROGRESSO') { continue }
        $l = $l.TrimEnd()
        if ($l -eq '') { $vazias++; if ($vazias -gt 1) { continue } } else { $vazias = 0 }
        $linhas.Add($l)
    }
    if ($linhas.Count -gt $Maximo) { return , $linhas.GetRange($linhas.Count - $Maximo, $Maximo).ToArray() }
    , $linhas.ToArray()
}

# Percentual de progresso: "##PROGRESSO n" (scripts) ou o último "nn%" da saída.
function Extrair-Progresso {
    param([string]$Texto)
    $m = [regex]::Matches($Texto, '##PROGRESSO\s+(\d{1,3})')
    if ($m.Count) { return [int]$m[$m.Count - 1].Groups[1].Value }
    $fim = if ($Texto.Length -gt 3000) { $Texto.Substring($Texto.Length - 3000) } else { $Texto }
    $m = [regex]::Matches($fim, '(\d{1,3})(?:[.,]\d+)?\s?%')
    if ($m.Count) {
        $v = [int]$m[$m.Count - 1].Groups[1].Value
        if ($v -le 100) { return $v }
    }
    $null
}

function Obter-TarefasAtivas {
    @($Script:Tarefas.Values | Where-Object { $_.estado -in 'executando', 'cancelando' })
}

<#
  Iniciar-Tarefa: executa um programa FIXO (definido no módulo, nunca vindo do navegador).
    -Nome           'modulo.acao' (agrupa a tarefa na tela e no histórico da máquina)
    -Argumentos     lista de argumentos; "{PASTA}" é trocado pela pasta da tarefa
    -Parametros     hashtable gravada em parametros.json (para scripts em modulos\tarefas)
    -Exclusiva      impede duas tarefas pesadas ao mesmo tempo (ex.: SFC + DISM)
    -SemProgresso   não tenta ler "nn%" da saída
    -SemHistorico   não grava no histórico da máquina (listagens e consultas)
    -AoConcluir     scriptblock param($Tarefa, $Texto) que interpreta a saída
    -Manutencao     texto gravado como "última manutenção" se terminar com sucesso
    -CodigosSucesso códigos de saída considerados sucesso
#>
function Iniciar-Tarefa {
    param(
        [Parameter(Mandatory)][string]$Nome,
        [Parameter(Mandatory)][string]$Titulo,
        [Parameter(Mandatory)][string]$Executavel,
        [string[]]$Argumentos = @(),
        [hashtable]$Parametros,
        [switch]$Exclusiva,
        [switch]$SemProgresso,
        [switch]$SemHistorico,
        [scriptblock]$AoConcluir,
        [string]$Manutencao,
        [int[]]$CodigosSucesso = @(0)
    )
    Atualizar-Tarefas
    foreach ($t in @(Obter-TarefasAtivas)) {
        if ($Exclusiva -and $t.exclusiva) { throw "Aguarde: '$($t.titulo)' ainda está em execução." }
        if ($t.nome -eq $Nome) { throw "'$($t.titulo)' já está em execução." }
    }
    if (-not [IO.File]::Exists($Executavel) -and -not (Get-Command $Executavel -ErrorAction SilentlyContinue)) {
        throw "Programa não encontrado neste PC: $Executavel"
    }

    $Script:ContadorTarefas++
    $id = '{0:yyyyMMddHHmmss}{1:000}' -f (Get-Date), ($Script:ContadorTarefas % 1000)
    $pasta = Join-Path $Script:PastaTarefas ('{0}_{1}' -f $id, $Nome)
    New-Item -ItemType Directory -Path $pasta -Force | Out-Null
    $saida = Join-Path $pasta 'saida.txt'
    $erro = Join-Path $pasta 'erro.txt'
    $entrada = Join-Path $pasta 'entrada.txt'
    [IO.File]::WriteAllText($entrada, '')   # entrada vazia: nenhum programa fica esperando teclado
    if ($Parametros) {
        ConvertTo-Json -InputObject $Parametros -Depth 8 | Set-Content -LiteralPath (Join-Path $pasta 'parametros.json') -Encoding UTF8
    }

    # Monta a linha de argumentos com aspas onde necessário
    $lista = @(foreach ($a in $Argumentos) {
        $a = $a.Replace('{PASTA}', $pasta)
        if ($a -eq '' -or $a -match '[\s"]') { '"' + $a.Replace('"', '\"') + '"' } else { $a }
    })
    $splat = @{
        FilePath               = $Executavel
        NoNewWindow            = $true
        PassThru               = $true
        RedirectStandardOutput = $saida
        RedirectStandardError  = $erro
        RedirectStandardInput  = $entrada
        WorkingDirectory       = $pasta
    }
    if ($lista.Count) { $splat.ArgumentList = ($lista -join ' ') }
    $proc = Start-Process @splat
    $null = $proc.Handle   # mantém o handle aberto para ler o ExitCode depois

    $tarefa = [pscustomobject]@{
        id             = $id
        nome           = $Nome
        titulo         = $Titulo
        inicio         = Get-Date
        fim            = $null
        estado         = 'executando'
        codigo         = $null
        processo       = $proc
        pasta          = $pasta
        saida          = $saida
        erro           = $erro
        codificacao    = $null
        exclusiva      = [bool]$Exclusiva
        semProgresso   = [bool]$SemProgresso
        semHistorico   = [bool]$SemHistorico
        aoConcluir     = $AoConcluir
        manutencao     = $Manutencao
        codigosSucesso = $CodigosSucesso
        resultado      = $null
        mensagem       = $null
    }
    $Script:Tarefas[$id] = $tarefa
    Escrever-Log ("Tarefa iniciada: {0} [{1}] -> {2} {3}" -f $Titulo, $id, $Executavel, ($lista -join ' ')) -Nivel ACAO
    if (-not $SemHistorico) { Registrar-Historico -Acao $Nome -Titulo $Titulo -Resultado 'iniciada' -Detalhes "Tarefa $id" }
    $tarefa
}

# Atalho para rodar um script de modulos\tarefas\ num PowerShell separado.
# O script recebe -Pasta, lê parametros.json e grava resultado.json.
function Iniciar-TarefaScript {
    param(
        [Parameter(Mandatory)][string]$Nome,
        [Parameter(Mandatory)][string]$Titulo,
        [Parameter(Mandatory)][string]$Arquivo,
        [hashtable]$Parametros = @{},
        [switch]$Exclusiva,
        [switch]$SemProgresso,
        [switch]$SemHistorico,
        [string]$Manutencao,
        [scriptblock]$AoConcluir
    )
    $caminho = Join-Path (Join-Path $Script:PastaModulos 'tarefas') $Arquivo
    if (-not (Test-Path -LiteralPath $caminho)) { throw "Script de tarefa não encontrado: $Arquivo" }
    Iniciar-Tarefa -Nome $Nome -Titulo $Titulo `
        -Executavel (Caminho-Sistema 'WindowsPowerShell\v1.0\powershell.exe') `
        -Argumentos @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $caminho, '-Pasta', '{PASTA}') `
        -Parametros $Parametros -Exclusiva:$Exclusiva -SemProgresso:$SemProgresso -SemHistorico:$SemHistorico `
        -Manutencao $Manutencao -AoConcluir $AoConcluir
}

function Ler-TextoTarefa {
    param($T, [int]$Maximo = 262144)
    $s = Ler-ArquivoSaida -Caminho $T.saida -Codificacao $T.codificacao -Maximo $Maximo
    if ($s.Codificacao) { $T.codificacao = $s.Codificacao }
    $e = Ler-ArquivoSaida -Caminho $T.erro -Codificacao $null -Maximo 65536
    $texto = $s.Texto
    if ($e.Texto.Trim()) { $texto += "`n" + $e.Texto }
    $texto
}

function Finalizar-Tarefa {
    param($T)
    $T.fim = Get-Date
    $T.codigo = Tentar { $T.processo.ExitCode }

    $arqResultado = Join-Path $T.pasta 'resultado.json'
    if (Test-Path -LiteralPath $arqResultado) {
        $T.resultado = Tentar { Get-Content -LiteralPath $arqResultado -Raw -Encoding UTF8 | ConvertFrom-Json }
    }
    if ($T.aoConcluir -and $T.estado -ne 'cancelando') {
        try { $T.resultado = & $T.aoConcluir $T (Ler-TextoTarefa $T) }
        catch { $T.mensagem = "Não foi possível interpretar o resultado: $($_.Exception.Message)" }
    }

    if ($T.estado -eq 'cancelando') { $T.estado = 'cancelada' }
    elseif ($T.codigosSucesso -contains $T.codigo) { $T.estado = 'concluida' }
    else { $T.estado = 'falhou' }

    if ($T.estado -eq 'concluida' -and $T.manutencao) {
        try { Registrar-Manutencao $T.manutencao } catch { }
    }
    $duracao = [int]($T.fim - $T.inicio).TotalSeconds
    $nivel = if ($T.estado -eq 'concluida') { 'ACAO' } else { 'AVISO' }
    Escrever-Log ("Tarefa {0}: {1} [{2}] código de saída {3}, {4} s" -f $T.estado, $T.titulo, $T.id, $T.codigo, $duracao) -Nivel $nivel
    if (-not $T.semHistorico) {
        $det = "Tarefa $($T.id); duração $([math]::Ceiling($duracao / 60)) min"
        if ($T.resultado -and $T.resultado.interpretacao) { $det += "; $($T.resultado.interpretacao)" }
        Registrar-Historico -Acao $T.nome -Titulo $T.titulo -Resultado $T.estado -Codigo $T.codigo -Detalhes $det
    }
}

# Chamado no laço principal (a cada 500 ms) e antes de consultar o estado.
function Atualizar-Tarefas {
    foreach ($t in @(Obter-TarefasAtivas)) {
        $saiu = Tentar -Padrao $true { $t.processo.HasExited }
        if ($saiu) { Finalizar-Tarefa $t }
    }
}

# Objeto enviado ao painel. -ComSaida inclui as linhas do console e o progresso.
function Resumo-Tarefa {
    param($T, [switch]$ComSaida)
    $ref = if ($T.fim) { $T.fim } else { Get-Date }
    $r = [ordered]@{
        id         = $T.id
        nome       = $T.nome
        titulo     = $T.titulo
        estado     = $T.estado
        codigo     = $T.codigo
        inicio     = Formatar-Data $T.inicio
        fim        = Formatar-Data $T.fim
        duracaoSeg = [int]($ref - $T.inicio).TotalSeconds
        progresso  = $null
        mensagem   = $T.mensagem
        resultado  = $T.resultado
    }
    if ($ComSaida) {
        $texto = Ler-TextoTarefa $T
        $r['linhas'] = Converter-Linhas $texto
        if ($T.estado -eq 'concluida') { $r.progresso = 100 }
        elseif (-not $T.semProgresso) { $r.progresso = Extrair-Progresso $texto }
    }
    $r
}

# =====================================================================
# 4. HTTP: respostas, arquivos estáticos, API e sinais do painel
# =====================================================================
$Script:TiposMime = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.ico'  = 'image/x-icon'
}

function Enviar-Bytes {
    param($Ctx, [int]$Status, [string]$Tipo, [byte[]]$Bytes)
    $res = $Ctx.Response
    $res.StatusCode = $Status
    $res.ContentType = $Tipo
    # Cabeçalhos de segurança: sem cache, sem iframe, sem vazar a URL (com token) por Referer
    $res.AddHeader('Cache-Control', 'no-store')
    $res.AddHeader('X-Content-Type-Options', 'nosniff')
    $res.AddHeader('X-Frame-Options', 'DENY')
    $res.AddHeader('Referrer-Policy', 'no-referrer')
    $res.AddHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; worker-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
    $res.ContentLength64 = $Bytes.Length
    $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $res.OutputStream.Close()
}

function Enviar-Json {
    param($Ctx, [int]$Status, $Objeto)
    $json = ConvertTo-Json -InputObject $Objeto -Depth 10 -Compress
    Enviar-Bytes -Ctx $Ctx -Status $Status -Tipo 'application/json; charset=utf-8' -Bytes ([Text.Encoding]::UTF8.GetBytes($json))
}

function Enviar-Erro {
    param($Ctx, [int]$Status, [string]$Mensagem)
    Enviar-Json -Ctx $Ctx -Status $Status -Objeto ([ordered]@{ ok = $false; erro = $Mensagem })
}

function Enviar-Estatico {
    param($Ctx, [string]$Caminho)
    $rel = [Uri]::UnescapeDataString($Caminho).TrimStart('/')
    if ($rel -eq '') { $rel = 'index.html' }

    $ext = [IO.Path]::GetExtension($rel).ToLowerInvariant()
    if (-not $Script:TiposMime.ContainsKey($ext)) { Enviar-Erro $Ctx 404 'Arquivo não encontrado.'; return }

    # Impede "path traversal": o caminho final PRECISA estar dentro de web\
    try { $completo = [IO.Path]::GetFullPath([IO.Path]::Combine($Script:PastaWeb, $rel.Replace('/', '\'))) }
    catch { Enviar-Erro $Ctx 400 'Caminho inválido.'; return }
    if (-not $completo.StartsWith($Script:PastaWeb + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Enviar-Erro $Ctx 403 'Acesso negado.'; return
    }
    if (-not [IO.File]::Exists($completo)) { Enviar-Erro $Ctx 404 'Arquivo não encontrado.'; return }

    Enviar-Bytes -Ctx $Ctx -Status 200 -Tipo $Script:TiposMime[$ext] -Bytes ([IO.File]::ReadAllBytes($completo))
}

# Lê o corpo da requisição como texto, com limite de tamanho (vale também
# quando o navegador não informa o Content-Length).
function Ler-CorpoTexto {
    param($Req, [int]$Limite = 65536)
    if (-not $Req.HasEntityBody) { return '' }
    if ($Req.ContentLength64 -gt $Limite) { Erro-Entrada 'Requisição muito grande.' }
    $leitor = New-Object IO.StreamReader($Req.InputStream, [Text.Encoding]::UTF8)
    try {
        $buf = New-Object char[] ($Limite + 1)
        $total = 0
        while ($total -le $Limite) {
            $n = $leitor.Read($buf, $total, $buf.Length - $total)
            if ($n -le 0) { break }
            $total += $n
        }
    }
    finally { $leitor.Dispose() }
    if ($total -gt $Limite) { Erro-Entrada 'Requisição muito grande.' }
    [string]::new($buf, 0, $total)
}

# Lê o corpo JSON da requisição e devolve um objeto.
function Ler-CorpoJson {
    param($Req)
    $vazio = New-Object psobject
    $texto = Ler-CorpoTexto $Req
    if ([string]::IsNullOrWhiteSpace($texto)) { return $vazio }
    try { $obj = $texto | ConvertFrom-Json } catch { Erro-Entrada 'JSON inválido.' }
    if ($obj -isnot [Management.Automation.PSCustomObject]) { Erro-Entrada 'O corpo deve ser um objeto JSON.' }
    return $obj
}

function Origem-Permitida {
    param($Req)
    $origem = $Req.Headers['Origin']
    if ($origem -and $origem -ne "http://localhost:$($Script:Porta)") {
        Escrever-Log "Requisição recusada: origem não permitida ($origem)" -Nivel AVISO
        return $false
    }
    return $true
}

# Marca que o painel está vivo (adia o encerramento automático)
function Registrar-Contato {
    $Script:Estado.UltimoContato = Get-Date
    $Script:Estado.FechamentoPedido = $null
}

# Indica se um objeto devolvido por uma ação é o resumo de uma tarefa
function Eh-ResumoTarefa {
    param($Dados)
    ($Dados -is [Collections.IDictionary]) -and $Dados.Contains('id') -and $Dados.Contains('estado') -and $Dados.Contains('duracaoSeg')
}

function Processar-Api {
    param($Ctx)
    $req = $Ctx.Request

    if ($req.HttpMethod -ne 'POST') { Enviar-Erro $Ctx 405 'Use POST.'; return }

    # Bloqueia chamadas vindas de outros sites abertos no navegador (CSRF)
    if (-not (Origem-Permitida $req)) { Enviar-Erro $Ctx 403 'Origem não permitida.'; return }

    # Token desta execução (comparação sensível a maiúsculas)
    if ($req.Headers['X-Token'] -cne $Script:Token) {
        Escrever-Log "Requisição recusada: token inválido em $($req.Url.AbsolutePath)" -Nivel AVISO
        Enviar-Erro $Ctx 401 'Token inválido ou ausente. Abra o painel pelo Iniciar.bat.'; return
    }
    Registrar-Contato

    if ($req.Url.AbsolutePath -match '^/api/acao/([a-z]+\.[a-z0-9_]+)$') { $nome = $Matches[1] }
    else { Enviar-Erro $Ctx 404 'Rota desconhecida.'; return }

    # Allowlist: só o que foi registrado pelos módulos
    $acao = $Script:Acoes[$nome]
    if (-not $acao) {
        Escrever-Log "Ação desconhecida solicitada: $nome" -Nivel AVISO
        Enviar-Erro $Ctx 404 "Ação desconhecida: $nome"; return
    }

    try { $corpo = Ler-CorpoJson $req } catch { Enviar-Erro $Ctx 400 $_.Exception.Message; return }

    if ($acao.AlteraSistema -and -not ($corpo.confirmado -is [bool] -and $corpo.confirmado)) {
        Enviar-Erro $Ctx 400 'Esta ação altera o sistema e precisa ser confirmada na tela.'; return
    }

    $params = $corpo.params
    if ($null -eq $params) { $params = New-Object psobject }
    elseif ($params -isnot [Management.Automation.PSCustomObject]) { Enviar-Erro $Ctx 400 'O campo "params" deve ser um objeto.'; return }

    $nivelLog = if ($acao.AlteraSistema) { 'ACAO' } else { 'INFO' }
    $cron = [Diagnostics.Stopwatch]::StartNew()
    try {
        $dados = & $acao.Bloco $params
        $cron.Stop()
        if (-not $acao.Silenciosa) {
            Escrever-Log ("{0} concluída em {1} ms" -f $nome, $cron.ElapsedMilliseconds) -Nivel $nivelLog
        }
        # Ações síncronas que alteram o sistema entram no histórico da máquina
        # (as que iniciam tarefas são registradas pela própria tarefa)
        if ($acao.AlteraSistema -and -not (Eh-ResumoTarefa $dados)) {
            $det = if ($dados -is [Collections.IDictionary] -and $dados.Contains('mensagem')) { [string]$dados.mensagem } else { '' }
            Registrar-Historico -Acao $nome -Titulo $acao.Descricao -Resultado 'ok' -Detalhes $det
        }
        Enviar-Json -Ctx $Ctx -Status 200 -Objeto ([ordered]@{ ok = $true; dados = $dados })
    }
    catch {
        $cron.Stop()
        $ehEntrada = $_.Exception -is [ArgumentException]
        Escrever-Log ("{0} falhou: {1}" -f $nome, $_.Exception.Message) -Nivel $(if ($ehEntrada) { 'AVISO' } else { 'ERRO' })
        if ($acao.AlteraSistema -and -not $ehEntrada) {
            Registrar-Historico -Acao $nome -Titulo $acao.Descricao -Resultado 'erro' -Detalhes $_.Exception.Message
        }
        Enviar-Erro $Ctx $(if ($ehEntrada) { 400 } else { 500 }) $_.Exception.Message
    }
    finally {
        Registrar-Contato   # ações longas (ex.: relatório) não contam como "navegador sumiu"
    }
}

# Sinais sem o cabeçalho X-Token:
#  /api/sinal/fechando : a aba avisa que está fechando (sendBeacon; o token vai no corpo)
#  /api/sinal/abrir    : o Iniciar.bat foi aberto de novo => reabre o painel no navegador.
#                        Exige um cabeçalho que páginas web não conseguem enviar e não
#                        devolve o token (quem abre o navegador é o próprio servidor).
function Processar-Sinal {
    param($Ctx)
    $req = $Ctx.Request
    if ($req.HttpMethod -ne 'POST') { Enviar-Erro $Ctx 405 'Use POST.'; return }
    $caminho = $req.Url.AbsolutePath

    if ($caminho -eq '/api/sinal/fechando') {
        if (-not (Origem-Permitida $req)) { Enviar-Erro $Ctx 403 'Origem não permitida.'; return }
        $token = (Ler-CorpoTexto $req 200).Trim()
        if ($token -cne $Script:Token) { Enviar-Erro $Ctx 401 'Token inválido.'; return }
        $Script:Estado.FechamentoPedido = Get-Date
        Escrever-Log 'O painel avisou que a aba foi fechada (aguardando para confirmar).'
        Enviar-Json $Ctx 200 ([ordered]@{ ok = $true })
    }
    elseif ($caminho -eq '/api/sinal/abrir') {
        if ($req.Headers['Origin'] -or $req.Headers['X-Kitzo-Lancador'] -ne '1') { Enviar-Erro $Ctx 403 'Não permitido.'; return }
        Registrar-Contato
        Escrever-Log 'Iniciar.bat executado novamente: reabrindo o painel no navegador.'
        Abrir-Painel
        Enviar-Json $Ctx 200 ([ordered]@{ ok = $true })
    }
    else { Enviar-Erro $Ctx 404 'Rota desconhecida.' }
}

function Processar-Requisicao {
    param($Ctx)
    $req = $Ctx.Request

    # Defesa extra: só conexões do próprio PC e com Host "localhost"
    # (evita acesso pela rede e ataques de "DNS rebinding").
    if (-not $req.IsLocal -or $req.Url.Host -ne 'localhost') {
        Escrever-Log "Conexão recusada de $($req.RemoteEndPoint) (Host: $($req.Url.Host))" -Nivel AVISO
        Enviar-Erro $Ctx 403 'Acesso permitido somente a partir deste computador.'; return
    }

    $caminho = $req.Url.AbsolutePath
    if ($caminho.StartsWith('/api/sinal/')) { Processar-Sinal $Ctx; return }
    if ($caminho.StartsWith('/api/')) { Processar-Api $Ctx; return }
    if ($req.HttpMethod -ne 'GET') { Enviar-Erro $Ctx 405 'Método não permitido.'; return }
    Enviar-Estatico $Ctx $caminho
}

function Abrir-Painel {
    $url = "http://localhost:$($Script:Porta)/?t=$($Script:Token)"
    try { Abrir-NoExplorer $url }
    catch { try { Start-Process $url } catch { Escrever-Log "Não foi possível abrir o navegador: $($_.Exception.Message)" -Nivel ERRO } }
}

# =====================================================================
# 5. Encerramento automático
#    O painel envia um "pulso" a cada ~8 s (Web Worker, que o navegador não
#    congela em abas de fundo) e avisa quando a aba é fechada.
# =====================================================================
function Verificar-Inatividade {
    $E = $Script:Estado
    $agora = Get-Date

    # PC acordando da suspensão: o painel ainda não teve chance de dar sinal
    if (($agora - $E.UltimaVerificacao).TotalSeconds -gt 30 -and $E.UltimoContato) { $E.UltimoContato = $agora }
    $E.UltimaVerificacao = $agora

    $motivo = $null
    if ($null -eq $E.UltimoContato) {
        if (($agora - $E.Inicio).TotalSeconds -ge $Script:LimitePrimeiroContato) { $motivo = 'o painel não foi aberto no navegador' }
    }
    elseif ($E.FechamentoPedido -and ($agora - $E.FechamentoPedido).TotalSeconds -ge $Script:LimiteAposFechar) {
        $motivo = 'a aba do painel foi fechada'
    }
    elseif (($agora - $E.UltimoContato).TotalSeconds -ge $Script:LimiteSemContato) {
        $motivo = 'o navegador parou de responder (provavelmente foi fechado)'
    }
    if (-not $motivo) { $E.AvisouEspera = $false; return }

    # Nunca encerra no meio de um reparo/limpeza: espera terminar e registrar no histórico
    $ativas = @(Obter-TarefasAtivas)
    if ($ativas.Count) {
        if (-not $E.AvisouEspera) {
            Escrever-Log ("Encerramento adiado: {0}, mas '{1}' ainda está em execução." -f $motivo, $ativas[0].titulo) -Nivel AVISO
            $E.AvisouEspera = $true
        }
        return
    }
    Escrever-Log "Encerrando automaticamente: $motivo." -Nivel AVISO
    $E.MotivoEncerramento = "automático: $motivo"
    $E.Rodando = $false
}

# =====================================================================
# 6. Ações do próprio núcleo
# =====================================================================
$Script:EhAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Registrar-Acao -Nome 'sistema.ping' -Descricao 'Informações básicas da sessão' -Bloco {
    param($P)
    [ordered]@{
        versao          = $Script:Versao
        computador      = $env:COMPUTERNAME
        usuario         = "$env:USERDOMAIN\$env:USERNAME"
        administrador   = $Script:EhAdmin
        pastaFerramenta = $Script:Raiz
        logsNoPendrive  = $Script:LogsNoPendrive
        pastaLogs       = $Script:PastaLogs
        tecnico         = [string]$Script:Config.tecnico
        maquina         = Resumo-Maquina
        acoes           = @($Script:Acoes.Keys | Sort-Object)
    }
}

# "Estou vivo" do painel (a cada ~8 s). Não grava log.
Registrar-Acao -Nome 'sistema.pulso' -Silenciosa -Descricao 'Mantém o servidor ativo' -Bloco {
    param($P)
    [ordered]@{ ok = $true; tarefasAtivas = @(Obter-TarefasAtivas).Count }
}

Registrar-Acao -Nome 'sistema.encerrar' -Descricao 'Encerra o servidor local' -Bloco {
    param($P)
    $Script:Estado.MotivoEncerramento = 'botão "Encerrar servidor" no painel'
    $Script:Estado.Rodando = $false
    [ordered]@{ mensagem = 'Servidor encerrado. Você já pode fechar esta aba.' }
}

# --- Tarefas em segundo plano: consultar, listar e cancelar ---
Registrar-Acao -Nome 'tarefa.estado' -Silenciosa -Descricao 'Andamento e saída de uma tarefa' -Bloco {
    param($P)
    $id = Ler-Parametro $P 'id' -Padrao '^\d{17}$' -Obrigatorio
    Atualizar-Tarefas
    $t = $Script:Tarefas[$id]
    if (-not $t) { throw 'Tarefa não encontrada (o servidor pode ter sido reiniciado).' }
    Resumo-Tarefa $t -ComSaida
}

Registrar-Acao -Nome 'tarefa.listar' -Silenciosa -Descricao 'Tarefas desta sessão (opcionalmente de um módulo)' -Bloco {
    param($P)
    $modulo = Ler-Parametro $P 'modulo' -Padrao '^[a-z]+$'
    Atualizar-Tarefas
    $lista = @($Script:Tarefas.Values | Where-Object { -not $modulo -or $_.nome -like "$modulo.*" } |
        Sort-Object inicio -Descending | ForEach-Object { Resumo-Tarefa $_ })
    [ordered]@{ tarefas = $lista; ativas = @(Obter-TarefasAtivas).Count }
}

Registrar-Acao -Nome 'tarefa.cancelar' -AlteraSistema -Descricao 'Interromper tarefa' -Bloco {
    param($P)
    $id = Ler-Parametro $P 'id' -Padrao '^\d{17}$' -Obrigatorio
    $t = $Script:Tarefas[$id]
    if (-not $t) { throw 'Tarefa não encontrada.' }
    if ($t.estado -ne 'executando') { throw 'A tarefa não está em execução.' }
    $t.estado = 'cancelando'
    # Encerra o processo e todos os filhos (taskkill /T)
    $ErrorActionPreference = 'Continue'   # no PS 5.1, stderr de programa externo + 'Stop' vira exceção
    & (Caminho-Sistema 'taskkill.exe') /PID $t.processo.Id /T /F 2>&1 | Out-Null
    Escrever-Log "Tarefa cancelada pelo técnico: $($t.titulo) [$id]" -Nivel ACAO
    [ordered]@{ mensagem = "Cancelamento solicitado: $($t.titulo)" }
}

# =====================================================================
# 7. Inicia o servidor
# =====================================================================
# Token aleatório de 256 bits, novo a cada execução
$bytesToken = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytesToken) } finally { $rng.Dispose() }
$Script:Token = -join ($bytesToken | ForEach-Object { $_.ToString('x2') })

# A porta é reservada ANTES de carregar os módulos: se já houver um Kitzo
# aberta, só pedimos para ela reabrir o painel e saímos.
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$($Script:Porta)/")
try {
    $listener.Start()
}
catch {
    $detalhe = $_.Exception.Message
    $reaberto = $false
    try {
        $r = [Net.HttpWebRequest]::Create("http://localhost:$($Script:Porta)/api/sinal/abrir")
        $r.Method = 'POST'; $r.Proxy = $null; $r.Timeout = 5000; $r.ContentLength = 0
        $r.Headers.Add('X-Kitzo-Lancador', '1')
        $resp = $r.GetResponse()
        $reaberto = ([int]$resp.StatusCode -eq 200)
        $resp.Close()
    } catch { }
    if ($reaberto) {
        Escrever-Log 'Outra instância já estava aberta: o painel foi reaberto nela.'
        exit 0
    }
    Escrever-Log "Falha ao iniciar o servidor: $detalhe" -Nivel ERRO
    Mostrar-Aviso ("Não foi possível usar a porta $($Script:Porta).`n`nOutro programa está usando essa porta. Feche-o e abra o Iniciar.bat de novo.`n`nDetalhe: $detalhe")
    exit 1
}

try { $Host.UI.RawUI.WindowTitle = 'Kitzo - servidor' } catch { }

# Carrega os módulos (cada .ps1 de modulos\ registra suas ações)
foreach ($arquivoModulo in (Get-ChildItem -LiteralPath $Script:PastaModulos -Filter '*.ps1' | Sort-Object Name)) {
    try {
        . $arquivoModulo.FullName
        Escrever-Log "Módulo carregado: $($arquivoModulo.Name)"
    }
    catch {
        Escrever-Log "Falha ao carregar o módulo $($arquivoModulo.Name): $($_.Exception.Message)" -Nivel ERRO
    }
}

# Registro da máquina (histórico) e configurações do pendrive
Carregar-Config
try { Iniciar-SessaoMaquina }
catch { Escrever-Log "Não foi possível abrir o histórico da máquina: $($_.Exception.Message)" -Nivel ERRO }

Escrever-Log ("Servidor iniciado (v{0}, admin={1}, pasta={2}, máquina={3})" -f $Script:Versao, $Script:EhAdmin, $Script:Raiz, $(if ($Script:Maquina) { $Script:Maquina.id } else { '?' }))
if (-not $Script:LogsNoPendrive) { Escrever-Log "O pendrive está protegido contra gravação: logs em $($Script:PastaLogs)" -Nivel AVISO }
Write-Host ''
Write-Host "  Kitzo v$($Script:Versao) rodando. Painel: http://localhost:$($Script:Porta)/?t=$($Script:Token)" -ForegroundColor Cyan
Write-Host '  O servidor fecha sozinho quando o navegador for fechado.' -ForegroundColor Gray
Write-Host ''

Abrir-Painel

try {
    while ($Script:Estado.Rodando -and $listener.IsListening) {
        $esperaContexto = $listener.GetContextAsync()
        # Espera em fatias de 500 ms: entre uma requisição e outra, atualiza as
        # tarefas e verifica se o painel ainda está aberto.
        while (-not $esperaContexto.Wait(500)) {
            try { Atualizar-Tarefas; Verificar-Inatividade } catch { Escrever-Log "Erro na verificação periódica: $($_.Exception.Message)" -Nivel ERRO }
            if (-not $Script:Estado.Rodando) { break }
        }
        if (-not $Script:Estado.Rodando) { break }
        $ctx = $esperaContexto.Result
        try {
            Processar-Requisicao $ctx
        }
        catch {
            Escrever-Log "Erro ao processar $($ctx.Request.Url.AbsolutePath): $($_.Exception.Message)" -Nivel ERRO
            try { Enviar-Erro $ctx 500 'Erro interno no servidor.' } catch { }
        }
    }
}
finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    $emExecucao = @(Obter-TarefasAtivas)
    foreach ($t in $emExecucao) {
        Escrever-Log "A tarefa '$($t.titulo)' continua rodando sem acompanhamento (PID $($t.processo.Id))." -Nivel AVISO
        Registrar-Historico -Acao $t.nome -Titulo $t.titulo -Resultado 'info' -Detalhes 'Servidor encerrado com a tarefa em andamento: resultado não registrado.'
    }
    $min = [math]::Ceiling(((Get-Date) - $Script:Estado.Inicio).TotalMinutes)
    Registrar-Historico -Acao 'sessao.fim' -Titulo 'Ferramenta encerrada' -Resultado 'info' -Detalhes ("Motivo: {0}; duração: {1} min" -f $Script:Estado.MotivoEncerramento, $min)
    Escrever-Log "Servidor encerrado ($($Script:Estado.MotivoEncerramento))."
}
