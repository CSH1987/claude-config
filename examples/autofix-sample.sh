#!/usr/bin/env bash
# Claude 자동수정 테스트용 샘플 (병합 금지).
# 의도적 결함: set -euo pipefail 없음 · ls 파싱 · 따옴표 누락 · 인자검증 없음.

backup() {
  src="$1"
  dest="$2"
  for f in "$src"/*; do
    cp "$f" "$dest/"
  done
  echo "backup done: $src -> $dest"
}

backup "$1" "$2"
