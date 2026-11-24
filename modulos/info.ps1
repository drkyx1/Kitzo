<#
  modulos\info.ps1 — Informações gerais do PC e nota de saúde (tela Início)

  Convenção de módulo:
    - Este arquivo é carregado ("dot-source") pelo servidor.ps1.
    - Defina funções auxiliares e registre as ações com Registrar-Acao.
    - Ações devolvem UM objeto ([ordered]@{...}), que vira JSON para o painel.
    - Use Tentar { ... } para coletas que podem falhar sem derrubar a tela inteira.
#>

# ---------------------------------------------------------------------
# Coletas individuais
# ---------------------------------------------------------------------

function Obter-InfoCpu {
    $cpus = @(Get-CimInstance -ClassName Win32_Processor)

    # LoadPercentage é a média do último segundo; em alguns PCs vem vazio,
    # então usamos o contador de desempenho via WMI (independe do idioma do Windows).
    $cargas = @($cpus | Where-Object { $null -ne $_.LoadPercentage } | ForEach-Object { [double]$_.LoadPercentage })
    if ($cargas.Count -gt 0) {
        $uso = [math]::Round(($cargas | Measure-Object -Average).Average)
    }
    else {
        $uso = Tentar { [int](Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime }
    }

    $nucleos = 0; $threads = 0
    foreach ($c in $cpus) { $nucleos += [int]$c.NumberOfCores; $threads += [int]$c.NumberOfLogicalProcessors }

    [ordered]@{
        nome          = ([string]$cpus[0].Name).Trim()
        nucleos       = $nucleos
        threads       = $threads
        clockMHz      = [int]$cpus[0].MaxClockSpeed
        usoPercentual = $uso
    }
}

function Obter-InfoMemoria {
    param($Os)
    # Win32_OperatingSystem informa em KB; KB / 1MB = GB
    $totalKB = [double]$Os.TotalVisibleMemorySize
    $livreKB = [double]$Os.FreePhysicalMemory
    $usadoKB = $totalKB - $livreKB
    [ordered]@{
        totalGB       = [math]::Round($totalKB / 1MB, 1)
        usadoGB       = [math]::Round($usadoKB / 1MB, 1)
        livreGB       = [math]::Round($livreKB / 1MB, 1)
        usoPercentual = if ($totalKB -gt 0) { [math]::Round($usadoKB / $totalKB * 100) } else { $null }
    }
}

function Obter-InfoDiscos {
    # DriveType=3 => discos locais fixos (o pendrive, removível, fica de fora)
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' |
        Where-Object { $_.Size -gt 0 } |
        ForEach-Object {
            [ordered]@{
                letra           = $_.DeviceID
                rotulo          = $_.VolumeName
                sistemaArquivos = $_.FileSystem
                totalGB         = [math]::Round($_.Size / 1GB, 1)
                livreGB         = [math]::Round($_.FreeSpace / 1GB, 1)
                livrePercentual = [math]::Round($_.FreeSpace / $_.Size * 100, 1)
                sistema         = ($_.DeviceID -eq $env:SystemDrive)
            }
        }
}

function Obter-InfoWindows {
    param($Os)
    $cv = Tentar { Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }
    $versao = $null; $ubr = $null
    if ($cv) {
        $versao = $cv.DisplayVersion                 # ex.: 23H2 (Win10 20H2+ / Win11)
        if (-not $versao) { $versao = $cv.ReleaseId } # versões antigas do Win10
        $ubr = $cv.UBR                               # número de revisão do build
    }
    $build = [string]$Os.BuildNumber
    if ($null -ne $ubr) { $build = "$build.$ubr" }
    $boot = $Os.LastBootUpTime

    [ordered]@{
        # Caption traz "Windows 11" corretamente (o registro diz "Windows 10" no 11)
        nome             = ([string]$Os.Caption -replace '^Microsoft\s+', '').Trim()
        versao           = $versao
        build            = $build
        arquitetura      = $Os.OSArchitecture
        instaladoEm      = Formatar-Data $Os.InstallDate
        ultimoBoot       = Formatar-Data $boot
        tempoLigadoHoras = if ($boot) { [math]::Round(((Get-Date) - $boot).TotalHours, 1) } else { $null }
    }
}

function Obter-StatusDefender {
    $r = [ordered]@{
        disponivel            = $false
        protecaoTempoReal     = $null
        antivirusAtivo        = $null
        modo                  = $null
        idadeAssinaturaDias   = $null
        versaoAssinatura      = $null
        ultimaVarreduraRapida = $null
        outrosAntivirus       = @()
        mensagem              = ''
    }

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $r.disponivel            = $true
        $r.protecaoTempoReal     = [bool]$mp.RealTimeProtectionEnabled
        $r.antivirusAtivo        = [bool]$mp.AntivirusEnabled
        $r.modo                  = $mp.AMRunningMode   # "Normal", "Passive mode"... (Win10 1703+)
        $r.idadeAssinaturaDias   = [int]$mp.AntivirusSignatureAge
        $r.versaoAssinatura      = $mp.AntivirusSignatureVersion
        $r.ultimaVarreduraRapida = Formatar-Data $mp.QuickScanEndTime
    }
    catch {
        $r.mensagem = 'Windows Defender indisponível (pode ter sido desativado por outro antivírus).'
    }

    # Central de Segurança: lista antivírus de terceiros (só existe em Windows "cliente")
    $r.outrosAntivirus = @(Tentar -Padrao @() {
        Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop |
            ForEach-Object {
                # productState: o 2º byte indica o estado do mecanismo (0x10 = ligado)
                $estado = [int]$_.productState
                [ordered]@{
                    nome        = $_.displayName
                    ativo       = ((($estado -shr 8) -band 0xFF) -band 0x10) -ne 0
                    atualizado  = ($estado -band 0xFF) -eq 0
                }
            }
    })
    $r
}

function Obter-ReinicioPendente {
    $motivos = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $motivos += 'Instalação de componentes do Windows'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $motivos += 'Windows Update'
    }
    $pfro = Tentar { (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations).PendingFileRenameOperations }
    if ($pfro) { $motivos += 'Arquivos aguardando substituição' }

    $nomeAtivo = Tentar { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName }
    $nomeNovo  = Tentar { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName }
    if ($nomeAtivo -and $nomeNovo -and $nomeAtivo -ne $nomeNovo) { $motivos += 'Troca do nome do computador' }

    [ordered]@{ pendente = ($motivos.Count -gt 0); motivos = $motivos }
}

# ---------------------------------------------------------------------
# Nota de saúde (0 a 100): começa em 100 e cada problema desconta pontos.
# Os descontos voltam para o painel, para o técnico saber o PORQUÊ da nota.
# ---------------------------------------------------------------------
function Calcular-NotaSaude {
    param($R)
    $alertas = New-Object System.Collections.ArrayList
    $add = { param($pontos, $nivel, $texto) [void]$alertas.Add([ordered]@{ pontos = $pontos; nivel = $nivel; texto = $texto }) }

    # Disco
    foreach ($d in $R.discos) {
        if ($d.sistema) {
            if ($d.livrePercentual -lt 10) { & $add 25 'critico' ('Pouco espaço livre no disco do sistema {0} ({1}% livre)' -f $d.letra, $d.livrePercentual) }
            elseif ($d.livrePercentual -lt 20) { & $add 10 'atencao' ('Espaço livre baixo no disco do sistema {0} ({1}% livre)' -f $d.letra, $d.livrePercentual) }
        }
        elseif ($d.livrePercentual -lt 10) { & $add 5 'atencao' ('Disco {0} quase cheio ({1}% livre)' -f $d.letra, $d.livrePercentual) }
    }

    foreach ($f in $R.saudeDiscos) {
        if ($f.saude -eq 'Unhealthy') { & $add 30 'critico' ('O disco "{0}" está reportando FALHA. Faça backup imediatamente.' -f $f.nome) }
        elseif ($f.saude -eq 'Warning') { & $add 15 'atencao' ('O disco "{0}" está reportando alerta de saúde' -f $f.nome) }
    }

    # Memória e CPU (momentâneos: pesam pouco)
    $mem = $R.memoria
    if ($mem -and $null -ne $mem.usoPercentual) {
        if ($mem.usoPercentual -ge 90) { & $add 15 'critico' ('Memória RAM quase esgotada ({0}% em uso)' -f $mem.usoPercentual) }
        elseif ($mem.usoPercentual -ge 80) { & $add 7 'atencao' ('Uso de memória RAM alto ({0}% em uso)' -f $mem.usoPercentual) }
    }
    if ($R.cpu -and $R.cpu.usoPercentual -ge 90) { & $add 5 'atencao' ('Processador muito ocupado agora ({0}%)' -f $R.cpu.usoPercentual) }

    # Antivírus
    $def = $R.defender
    $outroAtivo = @($def.outrosAntivirus | Where-Object { $_.ativo -and $_.nome -notmatch 'Defender' }).Count -gt 0
    $defenderAtivo = $def.disponivel -and $def.protecaoTempoReal
    if (-not $defenderAtivo -and -not $outroAtivo) {
        & $add 25 'critico' 'Nenhuma proteção antivírus em tempo real ativa'
    }
    elseif ($defenderAtivo -and $def.idadeAssinaturaDias -gt 7) {
        & $add 10 'atencao' ('Definições de vírus do Defender desatualizadas ({0} dias)' -f $def.idadeAssinaturaDias)
    }

    # Reinício
    if ($R.reinicio.pendente) { & $add 10 'atencao' ('Reinício pendente: {0}' -f ($R.reinicio.motivos -join ', ')) }
    $horas = $R.windows.tempoLigadoHoras
    if ($horas -gt 24 * 7) {
        & $add 5 'info' ('Ligado há {0} dias sem reiniciar (com a Inicialização Rápida, "Desligar" não zera esse tempo)' -f [math]::Floor($horas / 24))
    }

    # Manutenção feita por esta ferramenta
    $m = $R.manutencao
    if (-not $m) {
        & $add 5 'info' 'Nenhuma manutenção registrada por esta ferramenta neste PC'
    }
    else {
        $dataM = Ler-DataIso $m.data
        if ($dataM -and ((Get-Date) - $dataM).TotalDays -gt 30) {
            & $add 5 'info' ('Última manutenção há {0} dias' -f [math]::Floor(((Get-Date) - $dataM).TotalDays))
        }
    }

    $desconto = 0
    foreach ($a in $alertas) { $desconto += $a.pontos }
    $valor = [math]::Max(0, 100 - $desconto)
    $classe = if ($valor -ge 85) { 'Ótimo' } elseif ($valor -ge 70) { 'Bom' } elseif ($valor -ge 50) { 'Atenção' } else { 'Crítico' }

    [ordered]@{
        valor         = $valor
        classificacao = $classe
        alertas       = @($alertas)
    }
}

function Obter-ResumoSaude {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs = Tentar { Get-CimInstance -ClassName Win32_ComputerSystem }

    $resumo = [ordered]@{
        coletadoEm = Formatar-Data (Get-Date)
        computador = $env:COMPUTERNAME
        usuario    = "$env:USERDOMAIN\$env:USERNAME"
        fabricante = if ($cs) { ([string]$cs.Manufacturer).Trim() } else { $null }
        modelo     = if ($cs) { ([string]$cs.Model).Trim() } else { $null }
        cpu        = Tentar { Obter-InfoCpu }
        memoria    = Obter-InfoMemoria $os
        discos     = @(Tentar -Padrao @() { Obter-InfoDiscos })
        # Saúde informada pelo próprio disco (SMART resumido pelo Windows)
        saudeDiscos = @(Tentar -Padrao @() {
            Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
                [ordered]@{ nome = $_.FriendlyName; saude = [string]$_.HealthStatus }
            }
        })
        windows    = Obter-InfoWindows $os
        defender   = Obter-StatusDefender
        reinicio   = Obter-ReinicioPendente
        manutencao = Obter-UltimaManutencao
        # Identificação e histórico desta máquina (logs\maquinas\<id>.json)
        maquina    = Resumo-Maquina
    }
    $resumo['nota'] = Calcular-NotaSaude $resumo
    $resumo
}

# ---------------------------------------------------------------------
# Ações expostas na API (somente leitura)
# ---------------------------------------------------------------------
Registrar-Acao -Nome 'info.resumo' -Descricao 'Resumo de saúde para a tela Início' -Bloco {
    param($P)
    Obter-ResumoSaude
}
