#!/usr/bin/env bash
# Encrypted snapshot of Home Assistant's /config (PVC home-assistant-config).
# The tar is streamed from the pod straight into age, so the archive never
# exists unencrypted on disk. Encrypted to the age recipient in .sops.yaml;
# decrypt with the matching age key (see docs/restore-ha.md).
#
# Not included: recorder DB (history is expendable), logs, tts, backups,
# deps, __pycache__.
#
# Usage (from repo root): scripts/backup-ha.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

HOST="k8s@10.0.0.88"
OUT_DIR="backups/ha"
OUT="$OUT_DIR/ha-config-$(date +%F).tar.gz.age"
MAX_BYTES=$((30 * 1024 * 1024))  # git history grows with every snapshot
KEEP=3

# Public age recipient (not a secret).
RECIPIENT="$(grep -o 'age1[a-z0-9]*' .sops.yaml | head -1)"
[[ -n "$RECIPIENT" ]] || { echo "no age1 recipient in .sops.yaml" >&2; exit 1; }
command -v age >/dev/null || { echo "age not installed: brew install age" >&2; exit 1; }

mkdir -p "$OUT_DIR"
# Remove partial output on any failure.
trap 'rc=$?; [[ $rc -ne 0 ]] && rm -f "$OUT"; exit $rc' EXIT

# Overwrites today's snapshot only. Patterns quoted so the remote shell can't glob them.
ssh "$HOST" "kubectl -n home-assistant exec deploy/home-assistant -- tar czf - -C /config \
  --exclude=home-assistant_v2.db --exclude=home-assistant_v2.db-shm --exclude=home-assistant_v2.db-wal \
  '--exclude=*.log' '--exclude=*.log.*' \
  --exclude=./tts --exclude=./backups --exclude=./deps --exclude=./__pycache__ ." \
  | age -r "$RECIPIENT" -o "$OUT"

# Must be an age file, never plaintext.
if ! head -1 "$OUT" | grep -q '^age-encryption.org'; then
  echo "ERROR: $OUT has no age header" >&2
  exit 1
fi

SIZE=$(wc -c < "$OUT" | tr -d ' ')
echo "$OUT: $SIZE bytes ($((SIZE / 1024)) KiB)"
if (( SIZE > MAX_BYTES )); then
  echo "ERROR: larger than 30 MB, not keeping it" >&2
  exit 1
fi

# Keep the newest $KEEP snapshots (names sort by date).
ls -1 "$OUT_DIR"/ha-config-*.tar.gz.age | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do
  echo "removing old snapshot $old"
  rm -f "$old"
done
