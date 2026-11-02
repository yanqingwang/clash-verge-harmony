#!/usr/bin/env bash
# Build the Verge React frontend and stage it into the HAP rawfile.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FE="${VERGE_FRONTEND:-$ROOT/../clash-verge-rev}"
DEST="$ROOT/app/entry/src/main/resources/rawfile/ui"

cd "$FE"
[ -d node_modules ] || pnpm install
pnpm web:build

# post-process: relative asset paths + shim injection + strip crossorigin
python3 - <<'EOF'
html = open('dist/index.html').read()
html = html.replace('src="/assets/', 'src="./assets/').replace('href="/assets/', 'href="./assets/')
html = html.replace(' crossorigin', '')
if '<script src="./ohos-shim.js"></script>' not in html:
    html = html.replace('<script type="module"', '<script src="./ohos-shim.js"></script>\n    <script type="module"', 1)
open('dist/index.html', 'w').write(html)
EOF

rm -rf "$DEST"
mkdir -p "$DEST"
cp -r dist/* "$DEST/"
cp "$ROOT/scripts/ohos-shim.js" "$DEST/ohos-shim.js"
echo "frontend staged to $DEST ($(du -sh "$DEST" | cut -f1))"
