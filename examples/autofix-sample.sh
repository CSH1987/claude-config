#!/usr/bin/env bash
# Claude 자동수정 테스트용 샘플 (병합 금지).
# 의도적 결함: set -euo pipefail 없음 · ls 파싱 · 따옴표 누락 · 인자검증 없음.

backup() {
  src=$1
  dest=$2
  files=$(ls $src)
  for f in $files; do
    cp $src/$f $dest/$f
  done
  echo "backup done: $files"
}

backup $1 $2