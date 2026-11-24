<#
  modulos\personalizacao.ps1 — Personalização do Windows (tema, barra de tarefas,
  Explorador de Arquivos, ícones da área de trabalho, menu de contexto).

  Só altera chaves do usuário atual (HKCU), todas numa lista fixa (allowlist).
  Nenhum caminho ou valor vem da tela sem ser validado contra essa lista.
#>

$Script:RegTema     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$Script:RegAvancado = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$Script:RegBusca    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
$Script:RegDwm      = 'HKCU:\Software\Microsoft\Windows\DWM'
$Script:RegIcones   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
$Script:RegMenuCl   = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'

$Script:OpSimNao  = @(@{ valor = 1; rotulo = 'Ligado' }, @{ valor = 0; rotulo = 'Desligado' })
$Script:OpNaoSim  = @(@{ valor = 0; rotulo = 'Ligado' }, @{ valor = 1; rotulo = 'Desligado' })

# grupo, id, rótulo, descrição, chave, nome do valor, padrão (se não existir), opções, precisa reiniciar o Explorer
function Novo-Ajuste($Grupo, $Id, $Rotulo, $Desc, $Chave, $Nome, $Padrao, $Opcoes, [bool]$Explorer = $false) {
    [pscustomobject]@{ Grupo = $Grupo; Id = $Id; Rotulo = $Rotulo; Desc = $Desc; Chave = $Chave; Nome = $Nome
                       Padrao = $Padrao; Opcoes = $Opcoes; Explorer = $Explorer; Especial = $null }
}

$Script:Ajustes = @(
    (Novo-Ajuste 'Aparência' 'tema_apps'    'Modo escuro nos aplicativos' 'Aplicativos do Windows (Configurações, Loja, etc.) usam o tema escuro.' $Script:RegTema 'AppsUseLightTheme' 1 $Script:OpNaoSim)
    (Novo-Ajuste 'Aparência' 'tema_sistema' 'Modo escuro no sistema'      'Barra de tarefas, Menu Iniciar e central de ações usam o tema escuro.' $Script:RegTema 'SystemUsesLightTheme' 1 $Script:OpNaoSim)
    (Novo-Ajuste 'Aparência' 'transparencia' 'Efeitos de transparência'   'Deixa a barra de tarefas e o Menu Iniciar translúcidos.' $Script:RegTema 'EnableTransparency' 1 $Script:OpSimNao)
    (Novo-Ajuste 'Aparência' 'cor_titulo'   'Cor de destaque nas barras de título' 'Pinta barras de título e bordas das janelas com a cor de destaque.' $Script:RegDwm 'ColorPrevalence' 0 $Script:OpSimNao)

    (Novo-Ajuste 'Barra de tarefas' 'barra_alinhamento' 'Alinhamento dos ícones (Windows 11)' 'Centralizado ou à esquerda, como no Windows 10.' $Script:RegAvancado 'TaskbarAl' 1 @(@{ valor = 1; rotulo = 'Centro' }, @{ valor = 0; rotulo = 'Esquerda' }) $true)
    (Novo-Ajuste 'Barra de tarefas' 'barra_busca' 'Caixa de pesquisa' 'Como a pesquisa aparece na barra de tarefas.' $Script:RegBusca 'SearchboxTaskbarMode' 1 @(@{ valor = 0; rotulo = 'Oculta' }, @{ valor = 1; rotulo = 'Só ícone' }, @{ valor = 2; rotulo = 'Caixa completa' }, @{ valor = 3; rotulo = 'Ícone e texto' }) $true)
    (Novo-Ajuste 'Barra de tarefas' 'barra_visao_tarefas' 'Botão Visão de Tarefas' 'Mostra o botão das áreas de trabalho virtuais.' $Script:RegAvancado 'ShowTaskViewButton' 1 $Script:OpSimNao $true)
    (Novo-Ajuste 'Barra de tarefas' 'barra_widgets' 'Botão Widgets (Windows 11)' 'Painel de notícias e clima. Em algumas versões o Windows bloqueia esta mudança.' $Script:RegAvancado 'TaskbarDa' 1 $Script:OpSimNao $true)
    (Novo-Ajuste 'Barra de tarefas' 'barra_chat' 'Botão Chat/Teams (Windows 11)' 'Atalho do Microsoft Teams na barra de tarefas.' $Script:RegAvancado 'TaskbarMn' 1 $Script:OpSimNao $true)

    (Novo-Ajuste 'Explorador de Arquivos' 'exp_extensoes' 'Mostrar extensões de arquivo' 'Exibe .pdf, .exe, .docx… Ajuda a identificar arquivos suspeitos.' $Script:RegAvancado 'HideFileExt' 1 $Script:OpNaoSim $true)
    (Novo-Ajuste 'Explorador de Arquivos' 'exp_ocultos' 'Mostrar arquivos e pastas ocultos' 'Exibe itens marcados como ocultos.' $Script:RegAvancado 'Hidden' 2 @(@{ valor = 1; rotulo = 'Ligado' }, @{ valor = 2; rotulo = 'Desligado' }) $true)
    (Novo-Ajuste 'Explorador de Arquivos' 'exp_protegidos' 'Mostrar arquivos protegidos do sistema' 'Exibe também os arquivos críticos do Windows. Use com cuidado.' $Script:RegAvancado 'ShowSuperHidden' 0 $Script:OpSimNao $true)
    (Novo-Ajuste 'Explorador de Arquivos' 'exp_abrir_em' 'Abrir o Explorador em' 'Pasta exibida ao abrir o Explorador de Arquivos.' $Script:RegAvancado 'LaunchTo' 1 @(@{ valor = 1; rotulo = 'Este Computador' }, @{ valor = 2; rotulo = 'Acesso rápido / Início' }, @{ valor = 3; rotulo = 'Downloads' }) $true)
    (Novo-Ajuste 'Explorador de Arquivos' 'exp_compacto' 'Espaçamento compacto' 'Reduz o espaço entre os itens do Explorador (mais itens por tela).' $Script:RegAvancado 'UseCompactMode' 0 $Script:OpSimNao $true)
    (Novo-Ajuste 'Explorador de Arquivos' 'exp_barra_status' 'Barra de status' 'Mostra a contagem de itens no rodapé do Explorador.' $Script:RegAvancado 'ShowStatusBar' 1 $Script:OpSimNao $true)

    (Novo-Ajuste 'Área de trabalho' 'icone_pc' 'Ícone "Este Computador"' 'Atalho na área de trabalho.' $Script:RegIcones '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' 1 $Script:OpNaoSim $true)
    (Novo-Ajuste 'Área de trabalho' 'icone_usuario' 'Ícone da pasta do usuário' 'Atalho para a pasta pessoal.' $Script:RegIcones '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' 1 $Script:OpNaoSim $true)
    (Novo-Ajuste 'Área de trabalho' 'icone_rede' 'Ícone "Rede"' 'Atalho para a rede local.' $Script:RegIcones '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}' 1 $Script:OpNaoSim $true)
    (Novo-Ajuste 'Área de trabalho' 'icone_lixeira' 'Ícone da Lixeira' 'Atalho da Lixeira na área de trabalho.' $Script:RegIcones '{645FF040-5081-101B-9F08-00AA002F954E}' 0 $Script:OpNaoSim $true)
)

# Menu de contexto clássico (Windows 11): existe a chave => menu antigo completo
$menuClassico = Novo-Ajuste 'Explorador de Arquivos' 'exp_menu_classico' 'Menu de clique direito clássico (Windows 11)' 'Mostra o menu completo do Windows 10 sem precisar de "Mostrar mais opções".' $Script:RegMenuCl '' 0 $Script:OpSimNao $true
$menuClassico.Especial = 'menu_classico'
$Script:Ajustes += $menuClassico

function Obter-ValorAjuste {
    param($A)
    if ($A.Especial -eq 'menu_classico') {
        return $(if (Test-Path -LiteralPath $Script:RegMenuCl) { 1 } else { 0 })
    }
    $v = Tentar { (Get-ItemProperty -LiteralPath $A.Chave -Name $A.Nome -ErrorAction Stop).($A.Nome) }
    if ($null -eq $v) { return [int]$A.Padrao }
    [int]$v
}

function Aplicar-Ajuste {
    param($A, [int]$Valor)
    if ($A.Especial -eq 'menu_classico') {
        if ($Valor -eq 1) {
            New-Item -Path $Script:RegMenuCl -Force | Out-Null
            Set-ItemProperty -LiteralPath $Script:RegMenuCl -Name '(default)' -Value '' -ErrorAction SilentlyContinue
        } else {
            Remove-Item -LiteralPath 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Recurse -Force -ErrorAction SilentlyContinue
        }
        return
    }
    if (-not (Test-Path -LiteralPath $A.Chave)) { New-Item -Path $A.Chave -Force | Out-Null }
    New-ItemProperty -LiteralPath $A.Chave -Name $A.Nome -Value $Valor -PropertyType DWord -Force -ErrorAction Stop | Out-Null
}

Registrar-Acao -Nome 'personalizacao.estado' -Descricao 'Lê os ajustes de personalização do Windows' -Bloco {
    param($P)
    $build = [Environment]::OSVersion.Version.Build
    $lista = foreach ($a in $Script:Ajustes) {
        [ordered]@{
            id = $a.Id; grupo = $a.Grupo; rotulo = $a.Rotulo; descricao = $a.Desc
            valor = Obter-ValorAjuste $a
            opcoes = @($a.Opcoes | ForEach-Object { [ordered]@{ valor = [int]$_.valor; rotulo = [string]$_.rotulo } })
            explorer = [bool]$a.Explorer
        }
    }
    [ordered]@{ windows11 = ($build -ge 22000); build = $build; ajustes = @($lista) }
}

Registrar-Acao -Nome 'personalizacao.aplicar' -AlteraSistema -Descricao 'Altera um ajuste de personalização do Windows' -Bloco {
    param($P)
    $id = [string]$P.id
    $a = $Script:Ajustes | Where-Object { $_.Id -ceq $id } | Select-Object -First 1
    if (-not $a) { throw [ArgumentException]'Ajuste desconhecido.' }
    $v = 0
    if (-not [int]::TryParse([string]$P.valor, [ref]$v)) { throw [ArgumentException]'Valor inválido.' }
    if (-not ($a.Opcoes | Where-Object { [int]$_.valor -eq $v })) { throw [ArgumentException]'Valor fora das opções permitidas.' }

    $antes = Obter-ValorAjuste $a
    Aplicar-Ajuste $a $v
    $depois = Obter-ValorAjuste $a
    if ($depois -ne $v) { throw "O Windows não aceitou a mudança de '$($a.Rotulo)' (pode estar bloqueada nesta versão ou por política)." }
    $rot = ($a.Opcoes | Where-Object { [int]$_.valor -eq $v } | Select-Object -First 1).rotulo
    [ordered]@{ mensagem = "$($a.Rotulo): $rot (antes: $antes)."; valor = $depois; explorer = [bool]$a.Explorer }
}

Registrar-Acao -Nome 'personalizacao.reiniciar_explorer' -AlteraSistema -Descricao 'Reinicia o Explorador de Arquivos para aplicar ajustes visuais' -Bloco {
    param($P)
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    [ordered]@{ mensagem = 'Explorador de Arquivos reiniciado (a barra de tarefas piscou por alguns segundos).' }
}
