#!/usr/bin/env bash
# Full session backup: /config volume + installed packages list
# Uploads to GitHub Release "kali-desktop-backup"
set -euo pipefail

BACKUP_TAG="${BACKUP_TAG:-kali-desktop-backup}"
BACKUP_FILE="${BACKUP_FILE:-kali-backup.tar.zst}"
REPO="${GITHUB_REPOSITORY}"
WORK=/tmp/backup-work

echo "🔧 Starting backup process..."

# 1) Install zstd on runner
if ! command -v zstd >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq zstd
fi

# 2) Prepare workspace
rm -rf "${WORK}"
mkdir -p "${WORK}"
cd "${WORK}"

# 3) Gracefully flush Firefox so cookies/session get written
echo "📤 Flushing Firefox to disk..."
docker exec selkies-desktop bash -c '
  # Send SIGHUP to firefox to flush profile (soft signal)
  pkill -HUP -f firefox 2>/dev/null || true
  sync
  sleep 3
' || true

# 4) Extract package list from container
echo "📋 Capturing package list..."
docker exec selkies-desktop bash -c '
  dpkg --get-selections | awk "\$2==\"install\"{print \$1}" > /config/pkglist.txt
  # Also grab firefox extensions if any
  cp -r ~/.mozilla /config/mozilla-backup 2>/dev/null || true
' || echo "⚠️  Package list capture had warnings"

# 5) Create tarball of /config volume (host-side, fastest)
echo "📦 Creating compressed archive..."
sudo tar --zstd \
  --exclude='*/Cache/*' \
  --exclude='*/cache2/*' \
  --exclude='*/thumbnails/*' \
  --exclude='*/.cache/*' \
  --exclude='*/Trash/*' \
  --exclude='*.log' \
  --exclude='*.log.*' \
  -cf "${BACKUP_FILE}" \
  -C /var/lib/docker/volumes/selkies-config/_data \
  . || {
    echo "::error::tar failed"
    exit 1
  }

sudo chown "$(id -u):$(id -g)" "${BACKUP_FILE}"

SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
echo "✅ Archive created: ${SIZE}"

# 6) Extract pkglist to separate file for easier inspection
sudo cp /var/lib/docker/volumes/selkies-config/_data/pkglist.txt ./pkglist.txt 2>/dev/null || \
  echo "# no pkglist" > pkglist.txt
sudo chown "$(id -u):$(id -g)" ./pkglist.txt

# 7) Delete previous release (single-slot backup) then re-upload
echo "☁️  Uploading to GitHub Release '${BACKUP_TAG}'..."
if gh release view "${BACKUP_TAG}" --repo "${REPO}" >/dev/null 2>&1; then
  gh release delete "${BACKUP_TAG}" --repo "${REPO}" --yes --cleanup-tag || true
  sleep 2
fi

gh release create "${BACKUP_TAG}" \
  --repo "${REPO}" \
  --title "Kali Desktop Auto-Backup" \
  --notes "Auto-generated backup at $(date -u '+%Y-%m-%d %H:%M UTC') · Size: ${SIZE}" \
  "${BACKUP_FILE}" \
  "pkglist.txt"

echo "✅ Backup uploaded successfully"
echo "🔗 https://github.com/${REPO}/releases/tag/${BACKUP_TAG}"

# Summary
{
  echo "## 💾 Backup Complete"
  echo ""
  echo "- Size: ${SIZE}"
  echo "- Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "- Release: [${BACKUP_TAG}](https://github.com/${REPO}/releases/tag/${BACKUP_TAG})"
} >> "${GITHUB_STEP_SUMMARY}"
