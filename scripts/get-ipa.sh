#!/bin/zsh
# Builds a fresh unsigned Lumina.ipa in the cloud (free) and downloads it to ~/Lumina/Lumina-IPA/
set -e
cd "$(dirname "$0")/.."
OUT="$HOME/Lumina/Lumina-IPA"
mkdir -p "$OUT"
gh workflow run ios-ipa.yml
sleep 8
RUN=$(gh run list --workflow ios-ipa.yml --limit 1 --json databaseId -q '.[0].databaseId')
echo "Cloud build $RUN running (about 1 minute)..."
gh run watch "$RUN" --exit-status --interval 10 >/dev/null
rm -f "$OUT/Lumina.ipa"
gh run download "$RUN" -n Lumina-ipa -D "$OUT"
echo "Done: $OUT/Lumina.ipa"
