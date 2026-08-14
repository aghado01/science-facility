# Profile 2: Para-Agent Worker Helper Commands (helpers.nu)

# Emit structured JSON turn result directly to stdout
def "para-emit" [data] {
  $data | to json -r | print $in
}

# Compact/Raw JSON formatting helper
def "to-j" [] {
  $in | to json -r
}

# Safe file touch/ensure
def "para-touch" [filepath: string] {
  if not ($filepath | path exists) {
    "" | save -f $filepath
  }
}
