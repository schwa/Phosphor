default:
    just --list

encode-examples:
    #!/usr/bin/env bash
    set -euo pipefail
    aa archive -d Examples/Examples.phosphord -o Phosphor/Examples.phosphord.aar
