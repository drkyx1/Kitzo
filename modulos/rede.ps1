<#
  modulos\rede.ps1 — Etapa (d): adaptadores, IP, DNS, gateway, ping, teste de internet,
  renovar IP e limpar cache DNS.
#>

function Obter-InfoRede {
    $adaptadores = @(Get-NetAdapter -ErrorAction Stop | Sort-Object { $_.Status -ne 'Up' }, Name)
    foreach ($a in $adaptadores) {
        $idx = $a.ifIndex
        $ipv4 = @(Tentar -Padrao @() {
            Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength }
        })
        $ipv6 = @(Tentar -Padrao @() {
            Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv6 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike 'fe80*' } | ForEach-Object { $_.IPAddress }
        })
        $gateway = @(Tentar -Padrao @() {
            Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | ForEach-Object { $_.NextHop }
        })
        $dns = @(Tentar -Padrao @() {
            (Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses
        })
        $dhcp = Tentar { [string](Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction Stop).Dhcp }

        [ordered]@{
            nome       = $a.Name
            descricao  = $a.InterfaceDescription
            status     = [string]$a.Status        # Up, Disconnected, Disabled...
            mac        = $a.MacAddress
            velocidade = $a.LinkSpeed
            virtual    = [bool]$a.Virtual
            ipv4       = $ipv4
            ipv6       = $ipv6
            gateway    = $gateway
            dns        = $dns
            dhcp       = ($dhcp -eq 'Enabled')
        }
    }
}

# Ping rápido via .NET (não depende do idioma da saída do ping.exe)
function Testar-Ping {
    param([string]$Endereco, [int]$TempoLimite = 2000)
    try {
        $r = (New-Object Net.NetworkInformation.Ping).Send($Endereco, $TempoLimite)
        [ordered]@{ ok = ($r.Status -eq 'Success'); ms = if ($r.Status -eq 'Success') { [int]$r.RoundtripTime } else { $null }; status = [string]$r.Status }
    }
    catch { [ordered]@{ ok = $false; ms = $null; status = $_.Exception.InnerException.Message } }
}

function Testar-Internet {
    $ProgressPreference = 'SilentlyContinue'
    $etapas = New-Object System.Collections.ArrayList
    $add = { param($nome, $ok, $detalhe) [void]$etapas.Add([ordered]@{ etapa = $nome; ok = [bool]$ok; detalhe = $detalhe }) }

    # 1) Rota padrão / gateway
    $rota = Tentar {
        Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    }
    if ($rota) {
        $p = Testar-Ping $rota.NextHop
        $detalhe = if ($p.ok) { "Roteador $($rota.NextHop) respondeu em $($p.ms) ms" } else { "Roteador $($rota.NextHop) não respondeu (alguns roteadores bloqueiam ping)" }
        & $add 'Roteador (gateway)' $p.ok $detalhe
    }
    else { & $add 'Roteador (gateway)' $false 'Nenhum gateway configurado: o PC não está conectado a uma rede' }

    # 2) Internet por IP (sem depender de DNS)
    $p1 = Testar-Ping '1.1.1.1'
    $p2 = if ($p1.ok) { $null } else { Testar-Ping '8.8.8.8' }
    $okIp = $p1.ok -or ($p2 -and $p2.ok)
    $ms = if ($p1.ok) { $p1.ms } elseif ($p2) { $p2.ms } else { $null }
    & $add 'Internet (por IP)' $okIp $(if ($okIp) { "Servidores públicos respondem ($ms ms)" } else { 'Sem resposta de 1.1.1.1 nem 8.8.8.8' })

    # 3) Resolução de nomes (DNS)
    $nomeTeste = 'www.msftconnecttest.com'
    $ip = Tentar { (Resolve-DnsName -Name $nomeTeste -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress }
    & $add 'DNS' ([bool]$ip) $(if ($ip) { "$nomeTeste resolvido para $ip" } else { "Não foi possível resolver $nomeTeste" })

    # 4) Acesso HTTP real (detecta também "portal cativo" de hotel/aeroporto)
    $okHttp = $false; $detHttp = ''
    try {
        $resp = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 6
        $okHttp = ($resp.Content -eq 'Microsoft Connect Test')
        $detHttp = if ($okHttp) { 'Página de teste da Microsoft carregada' } else { 'Resposta inesperada: a rede pode exigir login (portal cativo)' }
    }
    catch { $detHttp = "Falha no acesso web: $($_.Exception.Message)" }
    & $add 'Acesso à web (HTTP)' $okHttp $detHttp

    $diag = if ($okHttp) { 'Internet funcionando.' }
            elseif ($okIp -and -not $ip) { 'Há conexão, mas o DNS não responde. Tente "Limpar cache DNS" ou trocar o DNS.' }
            elseif ($okIp) { 'Há conexão, mas o acesso web falhou (proxy, firewall ou portal cativo).' }
            elseif ($rota) { 'A rede local funciona, mas não há saída para a internet (verifique modem/provedor).' }
            else { 'O PC não está conectado a nenhuma rede.' }

    [ordered]@{ conectado = $okHttp; diagnostico = $diag; etapas = @($etapas) }
}

# Destino de ping: IPv4/IPv6 ou nome de host. Começa com letra/número
# (impede que algo como "-t" seja interpretado como opção do ping).
$Script:PadraoDestino = '^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9\-\.:]*[A-Za-z0-9])?$'

# ---------------------------------------------------------------------
# Ações
# ---------------------------------------------------------------------
Registrar-Acao -Nome 'rede.info' -Descricao 'Adaptadores, IP, DNS e gateway' -Bloco {
    param($P)
    [ordered]@{ computador = $env:COMPUTERNAME; adaptadores = @(Obter-InfoRede) }
}

Registrar-Acao -Nome 'rede.ping' -Descricao 'Ping (4 pacotes)' -Bloco {
    param($P)
    $destino = Ler-Parametro $P 'destino' -Padrao $Script:PadraoDestino -Obrigatorio
    $t = Iniciar-Tarefa -Nome 'rede.ping' -Titulo "Ping $destino" -Executavel (Caminho-Sistema 'PING.EXE') `
        -Argumentos '-n', '4', $destino -SemProgresso -SemHistorico -CodigosSucesso 0, 1
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'rede.teste_internet' -Descricao 'Teste de conexão em etapas' -Bloco {
    param($P)
    Testar-Internet
}

Registrar-Acao -Nome 'rede.renovar_ip' -AlteraSistema -Descricao 'ipconfig /release e /renew' -Bloco {
    param($P)
    $t = Iniciar-Tarefa -Nome 'rede.renovar_ip' -Titulo 'Renovando IP (ipconfig /release + /renew)' `
        -Executavel (Caminho-Sistema 'cmd.exe') -Argumentos '/d', '/c', 'ipconfig /release & ipconfig /renew' `
        -SemProgresso -CodigosSucesso 0, 1
    Resumo-Tarefa $t
}

Registrar-Acao -Nome 'rede.limpar_dns' -AlteraSistema -Descricao 'Limpa o cache DNS' -Bloco {
    param($P)
    Clear-DnsClientCache
    [ordered]@{ mensagem = 'Cache DNS limpo.' }
}
