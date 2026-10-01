#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2329  # SC2015: 위와 같은 이유 / SC2329: cleanup 은 trap 으로 호출된다
# 재현: Flyway 기본 락 방식에서는 CREATE INDEX CONCURRENTLY 마이그레이션이 영원히 멈춘다.
#   [1] FLYWAY_POSTGRESQL_TRANSACTIONAL_LOCK=true  (기본값) -> 30초 안에 끝나지 않아 timeout(124) 이어야 함
#   [2] FLYWAY_POSTGRESQL_TRANSACTIONAL_LOCK=false (우리 설정) -> 정상 적용(0) 이고 인덱스가 유효해야 함
# 임시 마이그레이션(V999)은 끝나면 항상 지운다. 멈춘 컨테이너/세션도 정리한다.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
export COMPOSE_FILE=docker-compose.dbtest.yml  # 앱 개발용 docker-compose.yml 과 분리된 DB 검증 전용 환경
export MSYS_NO_PATHCONV=1

PROBE=db/migrations/V999__repro_concurrent_index.sql
PSQL=(docker compose exec -T db psql -U postgres -d pub -At)

cleanup() {
  docker ps -q --filter "name=flyway-run" | xargs -r docker rm -f >/dev/null 2>&1
  rm -f "$PROBE"
  docker compose --profile tools down >/dev/null 2>&1
}
trap cleanup EXIT

prepare() {   # 빈 DB 에 정식 마이그레이션만 적용한 뒤, 문제의 마이그레이션 파일을 놓는다
  rm -f "$PROBE"
  bash scripts/db.sh up >/dev/null 2>&1 && bash scripts/db.sh reset >/dev/null 2>&1 && bash scripts/db.sh migrate >/dev/null 2>&1 || { echo "준비 실패"; exit 2; }
  echo "CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_repro_issue_title ON issue (title);" > "$PROBE"
}

run() {       # run <제한 초> <락 설정값>
  timeout "$1" docker compose --profile tools run --rm -e FLYWAY_POSTGRESQL_TRANSACTIONAL_LOCK="$2" flyway migrate >/dev/null 2>&1
}

rc_bad=0

echo "[1] 락 방식=true (Flyway 기본값): 30초 제한"
prepare
run 30 true; rc=$?
if [ "$rc" -eq 124 ]; then
  echo "    재현됨: 30초 안에 끝나지 않고 멈춤 (timeout)"
  echo "    멈춘 이유 -> DB 세션:"
  "${PSQL[@]}" -F ' | ' -c "SELECT state, wait_event_type||'/'||coalesce(wait_event,''), left(query,55) FROM pg_stat_activity WHERE datname='pub' AND pid <> pg_backend_pid() AND (state='idle in transaction' OR wait_event='virtualxid')" | sed 's/^/      /'
else
  echo "    재현 실패: 종료 코드 $rc (124 를 기대). Flyway/PostgreSQL 버전이 바뀌어 동작이 달라졌을 수 있다"; rc_bad=1
fi
docker ps -q --filter "name=flyway-run" | xargs -r docker rm -f >/dev/null 2>&1

echo "[2] 락 방식=false (우리 설정): 60초 제한"
prepare
run 60 false; rc=$?
valid=$("${PSQL[@]}" -c "SELECT x.indisvalid FROM pg_class c JOIN pg_index x ON x.indexrelid=c.oid WHERE c.relname='ix_repro_issue_title'")
if [ "$rc" -eq 0 ] && [ "$valid" = "t" ]; then
  echo "    정상: 적용 완료, 인덱스 유효"
else
  echo "    실패: 종료 코드 $rc, 인덱스 유효=${valid:-없음}"; rc_bad=1
fi

echo "----"
[ "$rc_bad" -eq 0 ] && echo "재현 성공: 기본 설정은 멈추고, 우리 설정은 통과한다" || echo "기대와 다른 결과가 있다"
exit "$rc_bad"
