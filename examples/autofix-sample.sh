#!/usr/bin/env bash
set -euo pipefail
# Claude 자동수정 테스트용 샘플 (병합 금지).
# 의도적 결함: set -euo pipefail 없음 · ls 파싱 · 따옴표 누락 · 인자검증 없음.

backup() {
  local src="$1"
  local dest="$2"
  for f in "$src"/*; do
    cp "$f" "$dest/"
  done
  echo "backup done: $src -> $dest"
}

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <src> <dest>" >&2
  exit 1
fi

backup "$1" "$2"
