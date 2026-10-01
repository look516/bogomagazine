#!/usr/bin/env bash
# 커밋 전 빠른 검사 (수 초). 무거운 검사(DB 테스트)는 CI 와 ./scripts/db.sh test 가 담당한다.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[1/3] 마이그레이션 규칙"
bash scripts/check-migrations.sh --staged

echo "[2/3] 공백 오류 / 충돌 표시 검사"
git diff --cached --check

echo "[3/3] 비밀 스캔 (스테이징된 변경)"
bash scripts/secret-scan.sh --staged
echo "OK"
