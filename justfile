default:
    just --list

encode-examples:
    #!/usr/bin/env bash
    set -euo pipefail
    aa archive -d Examples/Examples.phosphord -o Phosphor/Examples.phosphord.aar

# Archive the export template Swift package into the app bundle resources.
# Stages a clean copy (Package.swift + Sources only — no .build, .swiftpm,
# Package.resolved, or .DS_Store) so the shipped archive is minimal and the
# consumer resolves PhosphorKit fresh.
encode-template:
    #!/usr/bin/env bash
    set -euo pipefail
    src="Templates/PhosphorShaderPackage"
    staging="$(mktemp -d)/PhosphorShaderPackage"
    mkdir -p "$staging"
    cp "$src/Package.swift" "$staging/"
    rsync -a --exclude '.DS_Store' "$src/Sources" "$staging/"
    aa archive -d "$staging" -o Phosphor/Resources/PhosphorShaderPackage.aar
    rm -rf "$(dirname "$staging")"
    echo "Wrote Phosphor/Resources/PhosphorShaderPackage.aar"
