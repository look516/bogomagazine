#!/usr/bin/env bash
# DB 개발/테스트 명령 모음. 로컬과 CI 가 같은 경로를 쓰도록 하나로 통일한다.
#   ./scripts/db.sh up        DB 컨테이너 기동 (healthy 까지 대기)
#   ./scripts/db.sh migrate   Flyway 마이그레이션 적용
#   ./scripts/db.sh validate  적용된 마이그레이션과 파일의 체크섬 일치 확인
#   ./scripts/db.sh seed      개발용 샘플 데이터 적재
#   ./scripts/db.sh reset     로컬 DB 를 비움 (public 스키마 삭제 후 재생성) — 로컬 전용
#   ./scripts/db.sh test      reset -> migrate -> seed -> db/tests/*.sql 전부 실행 (CI 가 쓰는 명령)
#   ./scripts/db.sh erd       현재 스키마로 docs/erd.md 를 다시 생성 (migrate 이후에 실행)
#   ./scripts/db.sh erd --check   docs/erd.md 가 스키마와 같은지만 검사 (다르면 실패, test 에 포함됨)
#   ./scripts/db.sh bench     성능 측정 (DB 를 비우고 큰 데이터를 넣음. 로컬 전용, 수 분 소요)
#   ./scripts/db.sh psql      로컬 DB 에 psql 접속
#   ./scripts/db.sh down      컨테이너 종료 (데이터 유지) / down -v 는 데이터까지 삭제
set -euo pipefail
cd "$(dirname "$0")/.."

# NOTICE 로그 소음 제거. 테스트 실패(ASSERT/EXCEPTION)는 그대로 비정상 종료로 드러난다.
PSQL=(docker compose exec -T -e PGOPTIONS="-c client_min_messages=warning" db psql -U postgres -d pub -v ON_ERROR_STOP=1 -q)

PSQL_RAW=(docker compose exec -T -e PGOPTIONS="-c client_min_messages=warning" db psql -U postgres -d pub -v ON_ERROR_STOP=1)

# python3 / python / py 중 실제로 실행되는 것을 찾는다 (Windows 의 Microsoft Store 가짜 python 은 걸러진다)
find_python() {
  local p
  for p in python3 python py /c/Python314/python.exe; do
    if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys' >/dev/null 2>&1; then echo "$p"; return 0; fi
  done
  return 1
}

cmd_up()       { docker compose up -d --wait db; }
cmd_migrate()  { docker compose --profile tools run --rm flyway migrate; }
cmd_validate() { docker compose --profile tools run --rm flyway validate; }
cmd_seed()     { "${PSQL[@]}" < db/seed/dev.sql; }
cmd_reset()    { "${PSQL[@]}" -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'; }
cmd_erd() {
  local py tmp
  py=$(find_python) || { echo "[오류] ERD 생성에는 python3 가 필요합니다"; return 2; }
  tmp=$(mktemp)
  "${PSQL_RAW[@]}" -At -f - < scripts/erd-query.sql | PYTHONUTF8=1 "$py" scripts/gen_erd.py > "$tmp"
  if [ "${1:-}" = "--check" ]; then
    if ! diff -u docs/erd.md "$tmp" > "$tmp.diff"; then
      echo "[ERD 불일치] docs/erd.md 가 현재 스키마와 다릅니다. './scripts/db.sh erd' 로 다시 생성해 함께 커밋하세요."
      head -30 "$tmp.diff"
      rm -f "$tmp" "$tmp.diff"
      return 1
    fi
    rm -f "$tmp" "$tmp.diff"
    echo "ERD 최신 상태 (docs/erd.md)"
  else
    mv "$tmp" docs/erd.md
    echo "docs/erd.md 생성 완료"
  fi
}
cmd_bench() {
  cmd_up
  cmd_reset
  cmd_migrate
  cmd_seed
  "${PSQL_RAW[@]}" -f - < db/bench/perf.sql
}
cmd_psql()     { docker compose exec db psql -U postgres -d pub; }
cmd_down()     { docker compose down "$@"; }

cmd_test() {
  cmd_up
  cmd_reset
  cmd_migrate
  cmd_validate
  cmd_erd --check
  cmd_seed
  local n=0
  for f in db/tests/*.sql; do
    echo "== $f"
    "${PSQL[@]}" < "$f"
    n=$((n + 1))
  done
  echo "ALL DB TESTS PASSED ($n files)"
}

case "${1:-}" in
  up|migrate|validate|seed|reset|erd|bench|psql|down|test) c="$1"; shift; "cmd_$c" "$@" ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
