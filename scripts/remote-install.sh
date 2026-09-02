#!/bin/sh
# Yoink remote installer — public-but-unlisted repo curl install.
#
# Usage (recipient runs this, not you):
#   curl -fsSL https://raw.githubusercontent.com/OwaisQuadri/yoink/main/scripts/remote-install.sh | sh
#
# The repo is public (not searchable, no Chrome Web Store listing) so no
# GitHub account or token is needed on either end.

set -eu

REPO="OwaisQuadri/yoink"
BRANCH="${YOINK_BRANCH:-main}"
DEST="${YOINK_DEST:-$HOME/Yoink}"

if [ "$(uname)" != "Darwin" ]; then
  echo "Yoink currently supports macOS only." >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || { echo "git is required. Install Xcode Command Line Tools first: xcode-select --install" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "Node.js is required. Install it (e.g. 'brew install node') then re-run." >&2; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "npm is required (ships with Node.js)." >&2; exit 1; }

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found."
  if command -v brew >/dev/null 2>&1; then
    echo "Installing ffmpeg with Homebrew..."
    brew install ffmpeg
  else
    echo "Install Homebrew (https://brew.sh) then 'brew install ffmpeg', or install ffmpeg manually." >&2
    exit 1
  fi
fi

echo "Cloning $REPO ($BRANCH) into $DEST ..."
if [ -d "$DEST/.git" ]; then
  git -C "$DEST" fetch "https://github.com/${REPO}.git" "$BRANCH"
  git -C "$DEST" checkout "$BRANCH"
  git -C "$DEST" reset --hard FETCH_HEAD
else
  git clone --branch "$BRANCH" --single-branch \
    "https://github.com/${REPO}.git" "$DEST"
fi

cd "$DEST"
echo "Installing dependencies..."
npm install
npx playwright install chromium
echo "Building..."
npm run build
echo "Installing local helper..."
npm run helper:install

echo "Installing the yoink command..."
npm run cli:install

cat <<EOF

Yoink installed.

Next steps:
  1. Open chrome://extensions in Google Chrome.
  2. Turn on Developer mode.
  3. Click "Load unpacked" and choose:
       $DEST/dist
  4. Pin Yoink from the Extensions menu.

To update later: yoink update
To remove Yoink: yoink uninstall
(If the \`yoink\` command isn't found, open a new terminal, or see the
install output above for where it was placed.)
EOF
