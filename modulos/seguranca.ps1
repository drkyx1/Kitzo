<#
  modulos\seguranca.ps1 — Etapa (d): Defender, firewall, UAC, Secure Boot, BitLocker,
  atualizações pendentes do Windows e varredura rápida.
  Reaproveita Obter-StatusDefender do info.ps1.
#>

function Obter-CaminhoMpCmdRun {
    $c = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    if (-not (Test-Path -LiteralPath $c)) { throw 'O Windows Defender não está instalado ou foi removido neste PC.' }
    $c
}

function Obter-StatusSeguranca {
    $def = Obter-StatusDefender
    $mp = Tentar { Get-MpComputerStatus -ErrorAction Stop }
    if ($mp) {
        $def['protecaoAdulteracao']     = $mp.IsTamperProtected
        $def['ultimaVarreduraCompleta'] = Formatar-Data $mp.FullScanEndTime
        $def['definicoesAtualizadasEm'] = Formatar-Data $mp.AntivirusSignatureLastUpdated
        $def['versaoMotor']             = $mp.AMEngineVersion
    }

    # Ameaças detectadas nos últimos 30 dias
    $nomes = @{}
    Tentar { Get-MpThreat -ErrorAction Stop | ForEach-Object { $nomes[[string]$_.ThreatID] = $_.ThreatName } } | Out-Null
    $limite = (Get-Date).AddDays(-30)
    $ameacas = @(Tentar -Padrao @() {
        Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.InitialDetectionTime -gt $limite } |
            Sort-Object InitialDetectionTime -Descending | Select-Object -First 20 | ForEach-Object {
                $nome = $nomes[[string]$_.ThreatID]
                [ordered]@{
                    nome      = if ($nome) { $nome } else { "Ameaça $($_.ThreatID)" }
                    data      = Formatar-Data $_.InitialDetectionTime
                    arquivos  = @($_.Resources | Select-Object -First 3 | ForEach-Object { [string]$_ })
                    resolvida = [bool]$_.ActionSuccess
                }
            }
    })

    $firewall = @(Tentar -Padrao @() {
        Get-NetFirewallProfile -ErrorAction Stop | ForEach-Object {
            [ordered]@{ perfil = [string]$_.Name; ativo = ([string]$_.Enabled -eq 'True') }
        }
    })

    $politica = Tentar { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' }
    $uac = if ($politica) { [ordered]@{ ativo = ($politica.EnableLUA -eq 1); nivelAdmin = $politica.ConsentPromptBehaviorAdmin } } else { $null }

    # $true / $false / $null (BIOS legado ou sem suporte)
    $secureBoot = Tentar { Confirm-SecureBootUEFI -ErrorAction Stop }

    $bitlocker = @(Tentar -Padrao @() {
        Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop |
            Where-Object { $_.DriveLetter } | ForEach-Object {
                [ordered]@{
                    unidade  = $_.DriveLetter
                    protegido = switch ([int]$_.ProtectionStatus) { 1 { $true } 0 { $false } default { $null } }
                }
            }
    })

    $ultimaAtualizacao = Tentar {
        $h = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($h) { [ordered]@{ kb = $h.HotFixID; data = Formatar-Data $h.InstalledOn; descricao = $h.Description } }
    }

    [ordered]@{
        defender          = $def
        ameacas           = $ameacas
        firewall          = $firewall
        uac               = $uac
        secureBoot        = $secureBoot
        bitlocker         = $bitlocker
        ultimaAtualizacao = $ultimaAtualizacao
    }
}

# ---------------------------------------------------------------------
# Ações
# ---------------------------------------------------------------------
Registrar-Acao -Nome 'seguranca.status' -Descricao 'Resumo de segurança do PC' -Bloco {
    param($P)
    Obter-StatusSeguranca
}

Registrar-Acao -Nome 'seguranca.atualizacoes' -Descricao 'Procura atualizações pendentes do Windows' -Bloco {
    param($P)
    $t = Iniciar-TarefaScript -Nome 'seguranca.atualizacoes' -Titulo 'Procurando atualizações do Windows' `
        -Arquivo 'windows_update.ps1' -SemProgresso
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'seguranca.varredura_rapida' -AlteraSistema -Descricao 'Varredura rápida do Defender' -Bloco {
    param($P)
    # MpCmdRun: 0 = nada encontrado, 2 = ameaças encontradas (e tratadas pelo Defender)
    $t = Iniciar-Tarefa -Nome 'seguranca.varredura_rapida' -Titulo 'Varredura rápida do Windows Defender' `
        -Executavel (Obter-CaminhoMpCmdRun) -Argumentos '-Scan', '-ScanType', '1' -SemProgresso `
        -CodigosSucesso 0, 2 -Exclusiva `
        -AoConcluir {
            param($Tarefa, $Texto)
            $c = $Tarefa.processo.ExitCode
            [ordered]@{ ameacasEncontradas = ($c -eq 2); interpretacao = if ($c -eq 2) { 'Ameaças encontradas! Veja a lista em "Ameaças recentes".' } elseif ($c -eq 0) { 'Nenhuma ameaça encontrada.' } else { "Código de saída $c." } }
        }
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'seguranca.atualizar_definicoes' -AlteraSistema -Descricao 'Atualiza as definições do Defender' -Bloco {
    param($P)
    $t = Iniciar-Tarefa -Nome 'seguranca.atualizar_definicoes' -Titulo 'Atualizando definições de vírus' `
        -Executavel (Obter-CaminhoMpCmdRun) -Argumentos '-SignatureUpdate' -SemProgresso
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'seguranca.ativar_firewall' -AlteraSistema -Descricao 'Liga o firewall em todos os perfis' -Bloco {
    param($P)
    Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True
    [ordered]@{ mensagem = 'Firewall ativado nos perfis Domínio, Privado e Público.' }
}
