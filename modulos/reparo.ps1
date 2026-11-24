<#
  modulos\reparo.ps1 — Etapa (c): SFC, DISM e CHKDSK.
  Os comandos rodam como tarefas em segundo plano (veja Iniciar-Tarefa no servidor.ps1)
  e o painel mostra a saída em tempo real por polling.
#>

# Unidades locais fixas que o CHKDSK consegue verificar
function Obter-UnidadesVerificaveis {
    @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' |
        Where-Object { $_.FileSystem -in 'NTFS', 'FAT32', 'exFAT', 'FAT' } |
        ForEach-Object {
            [ordered]@{
                letra           = $_.DeviceID
                rotulo          = $_.VolumeName
                sistemaArquivos = $_.FileSystem
                sistema         = ($_.DeviceID -eq $env:SystemDrive)
            }
        })
}

function Validar-Unidade {
    param($P)
    $letra = (Ler-Parametro $P 'unidade' -Padrao '^[A-Za-z]:$' -Obrigatorio).ToUpperInvariant()
    $unidade = Obter-UnidadesVerificaveis | Where-Object { $_.letra -eq $letra } | Select-Object -First 1
    if (-not $unidade) { Erro-Entrada "A unidade $letra não é um disco local que o CHKDSK possa verificar." }
    $unidade
}

# Significado dos códigos de saída do CHKDSK
$Script:CodigosChkdsk = @{
    0 = 'Nenhum erro encontrado.'
    1 = 'Erros encontrados e corrigidos.'
    2 = 'Limpeza do disco realizada (ou erros encontrados sem a opção de correção).'
    3 = 'Não foi possível verificar, ou há erros que exigem correção offline. Use "Agendar correção no reinício".'
}

# ---------------------------------------------------------------------
# Ações
# ---------------------------------------------------------------------
Registrar-Acao -Nome 'reparo.unidades' -Descricao 'Unidades disponíveis para o CHKDSK' -Bloco {
    param($P)
    [ordered]@{ unidades = Obter-UnidadesVerificaveis }
}

Registrar-Acao -Nome 'reparo.sfc' -AlteraSistema -Descricao 'SFC /scannow' -Bloco {
    param($P)
    $t = Iniciar-Tarefa -Nome 'reparo.sfc' -Titulo 'Verificador de arquivos do sistema (SFC /scannow)' `
        -Executavel (Caminho-Sistema 'sfc.exe') -Argumentos '/scannow' `
        -Exclusiva -Manutencao 'Reparo: SFC /scannow'
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'reparo.dism_verificar' -Descricao 'DISM /CheckHealth (rápido, só leitura)' -Bloco {
    param($P)
    $t = Iniciar-Tarefa -Nome 'reparo.dism_verificar' -Titulo 'DISM /CheckHealth' `
        -Executavel (Caminho-Sistema 'dism.exe') -Argumentos '/Online', '/Cleanup-Image', '/CheckHealth' `
        -Exclusiva
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'reparo.dism_reparar' -AlteraSistema -Descricao 'DISM /RestoreHealth' -Bloco {
    param($P)
    # 3010 = concluído, mas pede reinício
    $t = Iniciar-Tarefa -Nome 'reparo.dism_reparar' -Titulo 'DISM /RestoreHealth' `
        -Executavel (Caminho-Sistema 'dism.exe') -Argumentos '/Online', '/Cleanup-Image', '/RestoreHealth' `
        -Exclusiva -CodigosSucesso 0, 3010 -Manutencao 'Reparo: DISM /RestoreHealth'
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'reparo.chkdsk' -AlteraSistema -Descricao 'CHKDSK online' -Bloco {
    param($P)
    $u = Validar-Unidade $P
    # NTFS: /scan verifica com o disco em uso. FAT/exFAT: verificação somente leitura.
    $argumentos = if ($u.sistemaArquivos -eq 'NTFS') { @($u.letra, '/scan') } else { @($u.letra) }
    $t = Iniciar-Tarefa -Nome 'reparo.chkdsk' -Titulo ("CHKDSK {0}" -f ($argumentos -join ' ')) `
        -Executavel (Caminho-Sistema 'chkdsk.exe') -Argumentos $argumentos `
        -Exclusiva -CodigosSucesso 0, 1, 2 -Manutencao ("Reparo: CHKDSK {0}" -f $u.letra) `
        -AoConcluir {
            param($Tarefa, $Texto)
            $codigo = $Tarefa.processo.ExitCode
            $txt = $Script:CodigosChkdsk[[int]$codigo]
            if (-not $txt) { $txt = "Código de saída $codigo." }
            [ordered]@{ interpretacao = $txt }
        }
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'reparo.chkdsk_agendar' -AlteraSistema -Descricao 'Agenda CHKDSK completo no próximo reinício' -Bloco {
    param($P)
    $u = Validar-Unidade $P
    # "fsutil dirty set" marca o volume como "sujo": o Windows roda o CHKDSK completo
    # (equivalente a /f) no próximo boot. Não depende do idioma, ao contrário de "chkdsk /f" + S/N.
    $ErrorActionPreference = 'Continue'   # no PS 5.1, stderr de programa externo + 'Stop' vira exceção
    $saida = & (Caminho-Sistema 'fsutil.exe') dirty set $u.letra 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Não foi possível agendar: $($saida.Trim())" }
    Escrever-Log "CHKDSK agendado para o próximo reinício em $($u.letra)" -Nivel ACAO
    Registrar-Manutencao "Reparo: CHKDSK agendado em $($u.letra)"
    [ordered]@{ mensagem = "Verificação completa de $($u.letra) agendada. Reinicie o PC; a verificação roda antes do Windows carregar e pode demorar." }
}
