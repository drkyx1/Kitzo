<#
  modulos\diagnostico.ps1 — Etapa (b): discos/SMART, memória, inicialização e eventos.
  Todas as ações aqui são SOMENTE LEITURA.
#>

# ---------------------------------------------------------------------
# Discos físicos: saúde, temperatura e contadores de confiabilidade (SMART)
# ---------------------------------------------------------------------
function Obter-DiscosFisicos {
    $lista = New-Object System.Collections.ArrayList

    $fisicos = @(Tentar -Padrao @() { Get-PhysicalDisk -ErrorAction Stop | Sort-Object { [int]$_.DeviceId } })
    foreach ($d in $fisicos) {
        # Contadores de confiabilidade = dados SMART traduzidos pelo Windows (exige admin;
        # discos USB e alguns controladores RAID não informam)
        $rel = Tentar { $d | Get-StorageReliabilityCounter -ErrorAction Stop }
        [void]$lista.Add([ordered]@{
            numero         = $d.DeviceId
            nome           = ([string]$d.FriendlyName).Trim()
            tipo           = [string]$d.MediaType        # SSD, HDD, SCM, Unspecified
            barramento     = [string]$d.BusType          # NVMe, SATA, USB, RAID...
            tamanhoGB      = [math]::Round($d.Size / 1GB, 1)
            saude          = [string]$d.HealthStatus     # Healthy, Warning, Unhealthy
            status         = (@($d.OperationalStatus) | ForEach-Object { [string]$_ }) -join ', '
            serie          = ([string]$d.SerialNumber).Trim()
            temperatura    = if ($rel -and $rel.Temperature) { [int]$rel.Temperature } else { $null }
            temperaturaMax = if ($rel -and $rel.TemperatureMax) { [int]$rel.TemperatureMax } else { $null }
            desgaste       = if ($rel -and $null -ne $rel.Wear) { [int]$rel.Wear } else { $null }
            horasLigado    = if ($rel -and $rel.PowerOnHours) { [int]$rel.PowerOnHours } else { $null }
            errosLeitura   = if ($rel) { $rel.ReadErrorsUncorrected } else { $null }
            errosEscrita   = if ($rel) { $rel.WriteErrorsUncorrected } else { $null }
            smartDisponivel = [bool]$rel
        })
    }

    # Alternativa para PCs sem o módulo Storage (raro): WMI clássico
    if ($lista.Count -eq 0) {
        foreach ($d in @(Tentar -Padrao @() { Get-CimInstance Win32_DiskDrive })) {
            [void]$lista.Add([ordered]@{
                numero = $d.Index; nome = $d.Model; tipo = [string]$d.MediaType; barramento = $d.InterfaceType
                tamanhoGB = [math]::Round($d.Size / 1GB, 1)
                saude = if ($d.Status -eq 'OK') { 'Healthy' } else { [string]$d.Status }
                status = $d.Status; serie = ([string]$d.SerialNumber).Trim()
                temperatura = $null; temperaturaMax = $null; desgaste = $null; horasLigado = $null
                errosLeitura = $null; errosEscrita = $null; smartDisponivel = $false
            })
        }
    }

    # Previsão de falha SMART "clássica" (discos ATA/SATA)
    $predicao = @(Tentar -Padrao @() {
        Get-CimInstance -Namespace 'root/wmi' -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop
    })
    [ordered]@{
        discos = @($lista)
        smart  = [ordered]@{
            disponivel     = ($predicao.Count -gt 0)
            falhaPrevista  = (@($predicao | Where-Object { $_.PredictFailure }).Count -gt 0)
            discosComFalha = @($predicao | Where-Object { $_.PredictFailure } | ForEach-Object { [string]$_.InstanceName })
        }
    }
}

# ---------------------------------------------------------------------
# Memória: módulos instalados, arquivo de paginação e maiores consumidores
# ---------------------------------------------------------------------
function Obter-DiagMemoria {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem

    $modulos = @(Tentar -Padrao @() {
        Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop | ForEach-Object {
            $vel = if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed }
            [ordered]@{
                slot          = $_.DeviceLocator
                capacidadeGB  = [math]::Round($_.Capacity / 1GB, 1)
                velocidadeMHz = $vel
                fabricante    = ([string]$_.Manufacturer).Trim()
                peca          = ([string]$_.PartNumber).Trim()
            }
        }
    })
    $slots = Tentar { [int](Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object -Property MemoryDevices -Sum).Sum }

    $paginacao = @(Tentar -Padrao @() {
        Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop | ForEach-Object {
            [ordered]@{ caminho = $_.Name; tamanhoMB = $_.AllocatedBaseSize; usoMB = $_.CurrentUsage; picoMB = $_.PeakUsage }
        }
    })

    # Agrupa por nome (ex.: 30 processos do Chrome viram uma linha só)
    $processos = @(Get-Process | Group-Object ProcessName | ForEach-Object {
        $soma = ($_.Group | Measure-Object -Property WorkingSet64 -Sum).Sum
        [pscustomobject]@{ nome = $_.Name; quantidade = $_.Count; bytes = $soma }
    } | Sort-Object bytes -Descending | Select-Object -First 15 | ForEach-Object {
        [ordered]@{ nome = $_.nome; quantidade = $_.quantidade; memoriaMB = [math]::Round($_.bytes / 1MB) }
    })

    $totalKB = [double]$os.TotalVisibleMemorySize
    $livreKB = [double]$os.FreePhysicalMemory
    $virtTotal = [double]$os.TotalVirtualMemorySize
    $virtLivre = [double]$os.FreeVirtualMemory
    [ordered]@{
        totalGB          = [math]::Round($totalKB / 1MB, 1)
        usadoGB          = [math]::Round(($totalKB - $livreKB) / 1MB, 1)
        usoPercentual    = if ($totalKB) { [math]::Round(($totalKB - $livreKB) / $totalKB * 100) } else { $null }
        compromissoGB    = [math]::Round(($virtTotal - $virtLivre) / 1MB, 1)   # memória "comprometida"
        limiteGB         = [math]::Round($virtTotal / 1MB, 1)
        slotsTotal       = $slots
        modulos          = $modulos
        paginacao        = $paginacao
        processos        = $processos
    }
}

# ---------------------------------------------------------------------
# Programas que iniciam com o Windows (Registro "Run" e pastas Inicializar)
# ---------------------------------------------------------------------
function Obter-ProgramasInicializacao {
    # O Gerenciador de Tarefas guarda quem foi DESATIVADO em "StartupApproved":
    # 1º byte par = ativado, ímpar = desativado.
    $aprovados = @{}
    $ignorar = 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider'
    foreach ($base in 'HKCU:', 'HKLM:') {
        foreach ($sub in 'Run', 'Run32', 'StartupFolder') {
            $props = Tentar { Get-ItemProperty -LiteralPath "$base\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$sub" }
            if (-not $props) { continue }
            foreach ($p in $props.PSObject.Properties) {
                if ($ignorar -contains $p.Name -or $p.Value -isnot [byte[]] -or $p.Value.Length -eq 0) { continue }
                $aprovados[$p.Name] = (($p.Value[0] % 2) -eq 0)
            }
        }
    }

    @(Get-CimInstance -ClassName Win32_StartupCommand | ForEach-Object {
        $ativo = $true
        foreach ($chave in @($_.Name, "$($_.Name).lnk", [IO.Path]::GetFileName([string]$_.Command))) {
            if ($chave -and $aprovados.ContainsKey($chave)) { $ativo = $aprovados[$chave]; break }
        }
        $local = [string]$_.Location
        $origem = if ($local -match '^HKLM') { 'Registro (todos os usuários)' }
                  elseif ($local -match '^HKU|^HKCU') { 'Registro (usuário)' }
                  elseif ($local -match 'Common') { 'Pasta Inicializar (todos)' }
                  else { 'Pasta Inicializar (usuário)' }
        [ordered]@{
            nome    = $_.Name
            comando = $_.Command
            origem  = $origem
            usuario = $_.User
            ativo   = $ativo
        }
    } | Sort-Object { -not $_.ativo }, { $_.nome })
}

# ---------------------------------------------------------------------
# Eventos de erro e críticos (Sistema e Aplicativo) das últimas N horas
# ---------------------------------------------------------------------
function Primeira-Linha {
    param([string]$Texto, [int]$Max = 300)
    if (-not $Texto) { return '(sem descrição)' }
    $l = ($Texto -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $l) { return '(sem descrição)' }
    $l = $l.Trim()
    if ($l.Length -gt $Max) { $l = $l.Substring(0, $Max) + '…' }
    $l
}

function Obter-EventosErro {
    param([int]$Horas = 72)
    $inicio = (Get-Date).AddHours(-$Horas)
    # Get-WinEvent dá erro quando não há eventos; nesse caso a lista fica vazia
    $eventos = @(Tentar -Padrao @() {
        Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = $inicio } -MaxEvents 400 -ErrorAction Stop
    })

    # Desligamentos inesperados (queda de energia, travamento) e telas azuis
    $inesperados = @($eventos | Where-Object {
        ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41) -or
        ($_.Id -eq 1001 -and $_.ProviderName -match 'BugCheck|WER-SystemErrorReporting')
    }).Count

    $frequentes = @($eventos | Group-Object { '{0}|{1}' -f $_.ProviderName, $_.Id } |
        Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
            $e = $_.Group[0]   # o mais recente (a lista vem do mais novo para o mais antigo)
            [ordered]@{
                fonte      = $e.ProviderName
                id         = $e.Id
                quantidade = $_.Count
                ultima     = Formatar-Data $e.TimeCreated
                mensagem   = Primeira-Linha $e.Message 200
            }
        })

    $lista = @($eventos | Select-Object -First 150 | ForEach-Object {
        [ordered]@{
            data     = Formatar-Data $_.TimeCreated
            log      = if ($_.LogName -eq 'System') { 'Sistema' } else { 'Aplicativo' }
            fonte    = $_.ProviderName
            id       = $_.Id
            nivel    = if ($_.Level -eq 1) { 'Crítico' } else { 'Erro' }
            mensagem = Primeira-Linha $_.Message
        }
    })

    [ordered]@{
        horas                     = $Horas
        total                     = $eventos.Count
        limiteAtingido            = ($eventos.Count -ge 400)
        criticos                  = @($eventos | Where-Object { $_.Level -eq 1 }).Count
        desligamentosInesperados  = $inesperados
        frequentes                = $frequentes
        eventos                   = $lista
    }
}

# ---------------------------------------------------------------------
# Ações da API (somente leitura)
# ---------------------------------------------------------------------
Registrar-Acao -Nome 'diagnostico.discos' -Descricao 'Saúde e SMART dos discos físicos' -Bloco {
    param($P)
    Obter-DiscosFisicos
}

Registrar-Acao -Nome 'diagnostico.memoria' -Descricao 'Memória e processos que mais consomem' -Bloco {
    param($P)
    Obter-DiagMemoria
}

Registrar-Acao -Nome 'diagnostico.inicializacao' -Descricao 'Programas que iniciam com o Windows' -Bloco {
    param($P)
    [ordered]@{ programas = @(Obter-ProgramasInicializacao) }
}

Registrar-Acao -Nome 'diagnostico.eventos' -Descricao 'Eventos de erro recentes' -Bloco {
    param($P)
    $horas = Ler-Parametro $P 'horas' -Permitidos '24', '72', '168', '720' -ValorPadrao '72'
    Obter-EventosErro -Horas ([int]$horas)
}
