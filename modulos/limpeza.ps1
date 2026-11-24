<#
  modulos\limpeza.ps1 — Etapa (c): limpeza de temporários, lixeira e cache do Windows Update.

  Fluxo:
    1) limpeza.analisar  -> calcula quanto cada categoria vai liberar (nada é apagado)
    2) o técnico escolhe as categorias e confirma na tela
    3) limpeza.executar  -> roda modulos\tarefas\limpeza.ps1 em segundo plano

  O navegador envia SOMENTE os ids das categorias. As pastas são sempre
  calculadas aqui, a partir da lista fixa abaixo.
#>

. (Join-Path $PSScriptRoot 'tarefas\limpeza_comum.ps1')

function Obter-CategoriasLimpeza {
    # Pasta Temp de cada perfil de usuário do PC (não só de quem abriu a ferramenta)
    $perfis = @(Tentar -Padrao @() {
        Get-CimInstance -ClassName Win32_UserProfile -Filter 'Special=False' -ErrorAction Stop | ForEach-Object { $_.LocalPath }
    })
    if (-not $perfis) { $perfis = @($env:USERPROFILE) }
    $tempsUsuarios = @($perfis | ForEach-Object { Join-Path $_ 'AppData\Local\Temp' } | Where-Object { Test-Path -LiteralPath $_ })

    # Lixeira: X:\$Recycle.Bin\<SID do usuário> em cada disco local
    $lixeiras = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $raiz = Join-Path ($_.DeviceID + '\') '$Recycle.Bin'
        Tentar -Padrao @() { Get-ChildItem -LiteralPath $raiz -Directory -Force -ErrorAction Stop | ForEach-Object { $_.FullName } }
    })

    $wer = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    @(
        [ordered]@{ id = 'temp_usuarios'; nome = 'Temporários dos usuários'
            descricao = 'Pasta Temp de cada perfil do PC. Só arquivos com mais de 24 horas.'
            pastas = $tempsUsuarios; idadeHoras = 24 }
        [ordered]@{ id = 'temp_windows'; nome = 'Temporários do Windows'
            descricao = 'Pasta Windows\Temp. Só arquivos com mais de 24 horas.'
            pastas = @(Join-Path $env:SystemRoot 'Temp'); idadeHoras = 24 }
        [ordered]@{ id = 'lixeira'; nome = 'Lixeira'
            descricao = 'Itens na Lixeira de todos os usuários e discos. Não poderão ser recuperados.'
            pastas = $lixeiras; idadeHoras = 0 }
        [ordered]@{ id = 'cache_wu'; nome = 'Cache do Windows Update'
            descricao = 'Instaladores de atualizações já baixados. O serviço é parado e religado automaticamente.'
            pastas = @(Join-Path $env:SystemRoot 'SoftwareDistribution\Download'); idadeHoras = 0 }
        [ordered]@{ id = 'relatorios_erro'; nome = 'Relatórios de erro do Windows'
            descricao = 'Relatórios de falhas de programas já enviados ou na fila.'
            pastas = @($wer); idadeHoras = 0 }
    )
}

# Nunca apagar a própria ferramenta (caso ela tenha sido extraída dentro de um Temp)
function Obter-ExclusoesLimpeza {
    @(($Script:Raiz.TrimEnd('\') + '\'), ($Script:PastaLogs.TrimEnd('\') + '\'))
}

$Script:IdsLimpeza = 'temp_usuarios', 'temp_windows', 'lixeira', 'cache_wu', 'relatorios_erro'

Registrar-Acao -Nome 'limpeza.analisar' -Descricao 'Calcula o espaço que cada categoria libera' -Bloco {
    param($P)
    $excluir = Obter-ExclusoesLimpeza
    $total = [long]0
    $categorias = foreach ($c in Obter-CategoriasLimpeza) {
        $arquivos = 0; $bytes = [long]0
        foreach ($pasta in $c.pastas) {
            $l = Listar-ItensLimpeza -Pasta $pasta -IdadeHoras $c.idadeHoras -Excluir $excluir
            $arquivos += $l.Arquivos.Count
            $bytes += $l.Bytes
        }
        $total += $bytes
        [ordered]@{
            id = $c.id; nome = $c.nome; descricao = $c.descricao
            pastas = @($c.pastas); arquivos = $arquivos; bytes = $bytes
        }
    }
    [ordered]@{ categorias = @($categorias); totalBytes = $total }
}

Registrar-Acao -Nome 'limpeza.executar' -AlteraSistema -Descricao 'Apaga as categorias escolhidas' -Bloco {
    param($P)
    $ids = Ler-ListaParametro $P 'categorias' -Permitidos $Script:IdsLimpeza
    $escolhidas = @(Obter-CategoriasLimpeza | Where-Object { $ids -contains $_.id })
    $nomes = ($escolhidas | ForEach-Object { $_.nome }) -join ', '
    $t = Iniciar-TarefaScript -Nome 'limpeza.executar' -Titulo "Limpeza: $nomes" -Arquivo 'limpeza.ps1' `
        -Parametros @{ categorias = $escolhidas; excluir = Obter-ExclusoesLimpeza } `
        -Exclusiva -Manutencao "Limpeza: $nomes"
    Resumo-Tarefa $t
}
