#!/usr/bin/env bash
# 마이그레이션 파일 규칙 검사. 사람이 실수하기 쉬운 부분을 기계가 막는다.
#   ./scripts/check-migrations.sh --staged       커밋 직전(pre-commit)  : 스테이징된 변경을 main 과 비교
#   ./scripts/check-migrations.sh origin/main    PR/CI                 : 기준 브랜치와 비교
# 보호 대상은 "기준 브랜치(기본 origin/main)에 이미 합쳐진" V 파일이다. 아직 main 에 없는 V 파일(이 브랜치에서 새로 만든 것)은
# 어떤 DB 에도 적용되지 않았으므로 자유롭게 고칠 수 있다. 기준 브랜치가 없으면(첫 커밋 등) HEAD 를 기준으로 삼는다.
# 기준 브랜치 이름이 다르면 MIGRATION_BASE_REF=origin/master 처럼 지정한다.
# 검사 항목
#   1. 파일 이름 규칙:  V###__설명.sql / R__###_설명.sql  (소문자·숫자·_ 만)
#   2. 버전 번호 중복 금지
#   3. 이미 존재하던 V 파일의 수정/삭제/이름변경 금지 (적용된 DB 의 체크섬이 깨짐) -> 새 V 파일을 추가할 것
#   4. 새 V 파일의 번호는 기준의 최대 번호보다 커야 함 (순서가 뒤바뀌면 기존 DB 에서 적용이 거부됨)
# R__ 파일은 자유롭게 수정할 수 있다 (바뀌면 다음 migrate 때 자동 재적용).
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-origin/main}"
DIR="db/migrations"
fail=0

# --- 1. 이름 규칙 ---
shopt -s nullglob
for f in "$DIR"/*.sql; do
  b=$(basename "$f")
  if ! [[ "$b" =~ ^V[0-9]{3}__[a-z0-9_]+\.sql$ || "$b" =~ ^R__[0-9]{3}_[a-z0-9_]+\.sql$ ]]; then
    echo "[이름 규칙] $b : V###__설명.sql 또는 R__###_설명.sql (소문자/숫자/_ 만) 이어야 합니다"
    fail=1
  fi
done

# --- 2. 버전 번호 중복 ---
dups=$(for f in "$DIR"/V[0-9]*__*.sql; do basename "$f" | sed -E 's/^V([0-9]+)__.*/\1/'; done | sort | uniq -d)
if [ -n "$dups" ]; then
  echo "[버전 중복] 같은 번호의 V 파일이 둘 이상입니다: $(echo "$dups" | tr '\n' ' ')"
  fail=1
fi

# --- 3, 4. 기준(base)과 비교 ---
if [ "$MODE" = "--staged" ]; then
  BASE="HEAD"
  BASE_REF="${MIGRATION_BASE_REF:-origin/main}"
  if git rev-parse --verify -q "$BASE_REF" >/dev/null && git rev-parse --verify -q HEAD >/dev/null; then
    BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null || echo HEAD)
  fi
  DIFF=(git diff --cached --name-status --diff-filter=MDRT "$BASE" -- "$DIR")
  ADDED=(git diff --cached --name-only --diff-filter=A "$BASE" -- "$DIR")
else
  BASE="$MODE"
  DIFF=(git diff --name-status --diff-filter=MDRT "$BASE"...HEAD -- "$DIR")
  ADDED=(git diff --name-only --diff-filter=A "$BASE"...HEAD -- "$DIR")
fi

if ! git rev-parse --verify -q "$BASE" >/dev/null; then
  if [ "$MODE" = "--staged" ]; then
    echo "(첫 커밋이라 기준 비교는 건너뜁니다)"
    exit $fail
  fi
  echo "[오류] 기준 '$BASE' 를 찾을 수 없습니다 (CI 에서는 fetch-depth: 0 필요)"
  exit 2
fi

changed=$("${DIFF[@]}" | grep -E "(^|[[:space:]])$DIR/V" || true)
if [ -n "$changed" ]; then
  echo "[V 파일 수정 금지] 이미 존재하던 버전 마이그레이션을 바꿨습니다:"
  # shellcheck disable=SC2001  # 줄마다 들여쓰기를 붙이는 용도라 ${var//} 로는 대체할 수 없음
  echo "$changed" | sed 's/^/    /'
  echo "    -> 되돌리고, 변경은 새 V 파일(다음 번호)로 추가하세요. 함수/뷰/트리거라면 R__ 파일을 고치세요."
  fail=1
fi

base_max=$(git ls-tree --name-only "$BASE" "$DIR/" 2>/dev/null | sed -E 's#.*/##' | grep -E '^V[0-9]+__' \
           | sed -E 's/^V([0-9]+)__.*/\1/' | sort -n | tail -1 || true)
# 공백이 든 파일명에도 안전하도록 줄 단위로 읽는다 (이름 규칙 위반은 위에서 이미 보고됨)
while IFS= read -r f; do
  [ -z "$f" ] && continue
  n=$(basename "$f" | sed -nE 's/^V([0-9]+)__.*/\1/p')
  [ -z "$n" ] && continue
  if [ -n "$base_max" ] && [ $((10#$n)) -le $((10#$base_max)) ]; then
    echo "[버전 순서] $(basename "$f") : 번호가 기준의 최대 번호($base_max)보다 커야 합니다"
    fail=1
  fi
done < <("${ADDED[@]}" | grep -E "$DIR/V[0-9]+__" || true)

if [ $fail -eq 0 ]; then echo "마이그레이션 규칙 OK"; fi
exit $fail
