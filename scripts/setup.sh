#!/usr/bin/env bash
# 클론 후 한 번만 실행: git 훅 활성화 + 스크립트 실행 권한.
set -euo pipefail
cd "$(dirname "$0")/.."

git config core.hooksPath .githooks
chmod +x scripts/*.sh .githooks/* 2>/dev/null || true

echo "git 훅 활성화 완료 (core.hooksPath=.githooks)"
echo "다음: ./scripts/db.sh test  # Docker 가 켜져 있어야 합니다"
