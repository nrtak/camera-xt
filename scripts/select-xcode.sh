#!/bin/bash
set -euo pipefail
# Select the newest installed stable Xcode, excluding beta/RC bundles.
XCODE_PATH="$(python3 - <<'PY'
import pathlib, re
candidates = []
for path in pathlib.Path('/Applications').glob('Xcode_*.app'):
    match = re.fullmatch(r'Xcode_(\d+(?:\.\d+)*)\.app', path.name)
    if match:
        version = tuple(int(n) for n in match.group(1).split('.'))
        if version[0] >= 26:
            candidates.append((version, str(path / 'Contents/Developer')))
if not candidates:
    raise SystemExit('Xcode 26 or newer is required. Update the GitHub runner image.')
print(max(candidates)[1])
PY
)"
sudo xcode-select --switch "$XCODE_PATH"
xcodebuild -version
