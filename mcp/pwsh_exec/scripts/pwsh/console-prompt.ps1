function Set-ConsolePrompt {
    $prefix = 'PS'
    $pathLeaf = Split-Path -Leaf $PWD
    $suffix = if ($NestedPromptLevel -ge 1) { '>> ' } else { '> ' }
    return "$prefix $pathLeaf$suffix"
}

function prompt {
    Set-ConsolePrompt
}