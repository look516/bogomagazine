#!/usr/bin/env bash
# "테스트가 정말 문제를 잡는가"를 확인하는 변이 검사(mutation check).
# 보호 장치를 일부러 하나씩 빼거나 망가뜨린 DB 에서 해당 테스트를 돌려, 테스트가 **실패해야** 한다.
# 통과해 버리면 그 테스트는 아무것도 지키지 못하고 있다는 뜻이다.
#
#   ./scripts/verify-guards.sh          전체 (항목마다 DB 를 새로 만들어 약 2분)
#   ./scripts/verify-guards.sh 3        3번 항목만
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PSQL=(docker compose exec -T -e PGOPTIONS="-c client_min_messages=warning" db psql -U postgres -d pub -v ON_ERROR_STOP=1 -q)
bad=0; n=0; only="${1:-}"

fresh() {
  bash scripts/db.sh up >/dev/null 2>&1
  bash scripts/db.sh reset >/dev/null 2>&1
  bash scripts/db.sh migrate >/dev/null 2>&1
  bash scripts/db.sh seed >/dev/null 2>&1
}

# check <이름> <변이 SQL> <테스트 파일> <실패 출력에 있어야 할 문자열>
check() {
  local name="$1" mutation="$2" file="$3" expect="$4" out
  n=$((n + 1))
  if [ -n "$only" ] && [ "$only" != "$n" ]; then return; fi
  fresh
  "${PSQL[@]}" -c "$mutation" >/dev/null
  if out=$("${PSQL[@]}" < "$file" 2>&1); then
    echo "FAIL  #$n [$name]  장치를 뺐는데 $file 이 통과했다 -> 이 테스트는 문제를 못 잡는다"
    bad=1
  elif grep -qF -- "$expect" <<<"$out"; then
    echo "OK    #$n [$name]  '$expect' 에서 잡힘"
  else
    echo "FAIL  #$n [$name]  실패는 했지만 기대한 이유가 아니다: $(grep -m1 ERROR <<<"$out")"
    bad=1
  fi
}

check "업로드 가드 제거"          "DROP TRIGGER trg_media_collecting ON media"                                db/tests/media.sql        "T51 failed"
check "상태 직접변경 차단 제거"    "DROP TRIGGER trg_issue_status_guard ON issue"                             db/tests/issues.sql       "T53 failed"
check "승인 후 수정 가드 제거"     "DROP TRIGGER trg_override_guard ON override"                              db/tests/review.sql       "T54"
check "승인 버전 기록 제거"        "DROP TRIGGER trg_approval_version ON approval"                            db/tests/review.sql       "T54"
check "조판 회차 부여 제거"        "DROP TRIGGER trg_layout_run_no ON layout_run"                             db/tests/layout.sql       "run_no"
check "허용 전이 한 줄 삭제"       "DELETE FROM issue_status_transition WHERE from_status='collecting' AND to_status='closing'" db/tests/issues.sql "invalid transition"
check "금지된 모듈 간 외래키"      "ALTER TABLE template ADD COLUMN bad uuid REFERENCES issue(id)"            db/tests/architecture.sql "허용되지 않은 모듈 간 외래키"
check "코멘트 없는 새 테이블"      "CREATE TABLE zz_new (id int)"                                             db/tests/architecture.sql "소유 모듈 코멘트가 없거나"
check "사용자 조회 인덱스 제거"    "DROP INDEX ix_family_member_user"                                         db/tests/health.sql       "T64"
check "배치 외래키를 다시 즉시 검사로"  "ALTER TABLE placement DROP CONSTRAINT placement_media_id_fkey, ADD CONSTRAINT placement_media_id_fkey FOREIGN KEY (media_id) REFERENCES media(id)" db/tests/issues.sql "foreign key constraint"
check "죽은 워커 정리 무력화"      "CREATE OR REPLACE FUNCTION reap_stale_compose_jobs(p_now timestamptz DEFAULT now(), p_timeout interval DEFAULT interval '5 minutes') RETURNS int LANGUAGE sql AS 'SELECT 0'" db/tests/layout.sql "T71"

echo "----"
if [ "$bad" -eq 0 ]; then echo "모든 변이를 테스트가 잡았다"; else echo "놓친 변이가 있다 (위 FAIL 항목)"; fi
exit "$bad"
