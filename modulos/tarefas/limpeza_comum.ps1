<#
  modulos\tarefas\limpeza_comum.ps1 — Funções usadas tanto na ANÁLISE (servidor)
  quanto na EXECUÇÃO da limpeza (processo separado), para que o tamanho estimado
  e o que é apagado sigam exatamente as mesmas regras.

  Regras de segurança:
    - nunca segue junções / links simbólicos (ReparsePoint), para não "escapar" da pasta;
    - nunca remove a pasta raiz da categoria, só o conteúdo;
    - ignora desktop.ini e caminhos da lista de exclusão (ex.: a própria ferramenta);
    - respeita a idade mínima dos arquivos (temporários com menos de 24 h ficam).
#>

function Listar-ItensLimpeza {
    param(
        [Parameter(Mandatory)][string]$Pasta,
        [int]$IdadeHoras = 0,
        [string[]]$Excluir = @()
    )
    $arquivos = New-Object System.Collections.Generic.List[IO.FileInfo]
    $pastas = New-Object System.Collections.Generic.List[IO.DirectoryInfo]
    $limite = (Get-Date).AddHours(-$IdadeHoras)
    $resultado = [pscustomobject]@{ Arquivos = $arquivos; Pastas = $pastas; Bytes = [long]0; Limite = $limite }

    $raiz = New-Object IO.DirectoryInfo($Pasta)
    if (-not $raiz.Exists) { return $resultado }

    $pilha = New-Object System.Collections.Generic.Stack[IO.DirectoryInfo]
    $pilha.Push($raiz)
    $bytes = [long]0
    while ($pilha.Count -gt 0) {
        $dir = $pilha.Pop()
        try { $itens = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($item in $itens) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($Excluir.Count) {
                $pular = $false
                foreach ($e in $Excluir) {
                    if ($item.FullName.StartsWith($e, [StringComparison]::OrdinalIgnoreCase)) { $pular = $true; break }
                }
                if ($pular) { continue }
            }
            if ($item -is [IO.DirectoryInfo]) {
                $pilha.Push($item)
                $pastas.Add($item)
            }
            elseif ($item.Name -ne 'desktop.ini' -and $item.LastWriteTime -lt $limite -and $item.CreationTime -lt $limite) {
                $arquivos.Add($item)
                $bytes += $item.Length
            }
        }
    }
    $resultado.Bytes = $bytes
    $resultado
}

# Apaga os arquivos listados; arquivos em uso são ignorados (contados em "falhas").
function Remover-ItensLimpeza {
    param([Parameter(Mandatory)]$Lista)
    $removidos = 0; $bytes = [long]0; $falhas = 0
    foreach ($f in $Lista.Arquivos) {
        try {
            if ($f.Attributes -band [IO.FileAttributes]::ReadOnly) { $f.Attributes = [IO.FileAttributes]::Normal }
            $tam = $f.Length
            $f.Delete()
            $removidos++; $bytes += $tam
        }
        catch { $falhas++ }
    }
    # Remove subpastas que ficaram vazias (das mais profundas para as mais rasas),
    # desde que também fossem mais antigas que o limite de idade. Usa a data lida
    # na listagem (sem Refresh), pois apagar o conteúdo atualiza a data da pasta.
    foreach ($d in ($Lista.Pastas | Sort-Object { $_.FullName.Length } -Descending)) {
        try {
            if ([IO.Directory]::Exists($d.FullName) -and $d.LastWriteTime -lt $Lista.Limite -and
                -not $d.EnumerateFileSystemInfos().GetEnumerator().MoveNext()) {
                $d.Delete()
            }
        }
        catch { }
    }
    [pscustomobject]@{ Removidos = $removidos; Bytes = $bytes; Falhas = $falhas }
}

function Formatar-Tamanho {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}
