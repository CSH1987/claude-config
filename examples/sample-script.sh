#!/usr/bin/env bash
# Claude 자동리뷰 품질 테스트용 샘플 스크립트 (병합하지 말 것).
# 의도적으로 리뷰거리(따옴표 누락 · ls 파싱 · 에러처리 없음)를 넣었습니다.

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