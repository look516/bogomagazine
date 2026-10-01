#!/usr/bin/env bash
# "테스트가 정말 문제를 잡는가"를 확인하는 변이 검사(mutation check).
# 보호 장치를 일부러 하나씩 빼거나 망가뜨린 DB 에서 해당 테스트를 돌려, 테스트가 **실패해야** 한다.
# 통과해 버리면 그 테스트는 아무것도 지키지 못하고 있다는 뜻이다.
#
#   ./scripts/verify-guards.sh          전체 (항목마다 DB 를 새로 만들어 약 2분)
#   ./scripts/verify-guards.sh 3        3번 항목만
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
export COMPOSE_FILE=docker-compose.dbtest.yml  # 앱 개발용 docker-compose.yml 과 분리된 DB 검증 전용 환경

PSQL=(docker compose exec -T -e PGOPTIONS="-c client_min_messages=warning" db psql -U postgres -d pub -v ON_ERROR_STOP=1 -q)
bad=0; n=0; only="${1:-}"

fresh() {
  bash scripts/db.sh up >/dev/null 2>&1
  bash scripts/db.sh reset >/dev/null 2>&1
  bash scripts/db.sh migrate >/dev/null 2>&1
  bash scripts/db.sh seed >/dev/null 2>&1
}

# check <이름> <변이> <테스트 파일> <실패 출력에 있어야 할 문자열>
#   변이는 SQL 이거나, "FN|<함수 시그니처>|<바꿀 문장>|<바뀔 문장>" (함수 본문의 한 문장만 약화한다)
check() {
  local name="$1" mutation="$2" file="$3" expect="$4" out def sig from to
  n=$((n + 1))
  if [ -n "$only" ] && [ "$only" != "$n" ]; then return; fi
  fresh
  if [[ "$mutation" == FN\|* ]]; then
    IFS='|' read -r _ sig from to <<<"$mutation"
    def=$("${PSQL[@]}" -At -c "SELECT pg_get_functiondef('$sig'::regprocedure)")
    if [[ "$def" != *"$from"* ]]; then echo "FAIL  #$n [$name]  함수 본문에 '$from' 이 없다 (변이 정의가 낡음)"; bad=1; return; fi
    mutation="${def/"$from"/$to}"
  fi
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

POST_ONLY_PERIOD="CREATE OR REPLACE FUNCTION guard_post_insert() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN PERFORM assert_period_open(NEW.group_id, NEW.posted_at); RETURN NEW; END'"

# --- 수명주기 / 조판 / 구조 ---
check "상태 직접변경 차단 제거"    "DROP TRIGGER trg_issue_status_guard ON issue"                             db/tests/issues.sql       "T53 failed"
check "허용 전이 한 줄 삭제"       "DELETE FROM issue_status_transition WHERE from_status='collecting' AND to_status='closing'" db/tests/issues.sql "invalid transition"
check "승인 후 수정 가드 제거"     "DROP TRIGGER trg_override_guard ON override"                              db/tests/review.sql       "T54"
check "승인 버전 기록 제거"        "DROP TRIGGER trg_approval_version ON approval"                            db/tests/review.sql       "T54"
check "조판 회차 부여 제거"        "DROP TRIGGER trg_layout_run_no ON layout_run"                             db/tests/layout.sql       "run_no"
check "죽은 워커 정리 무력화"      "CREATE OR REPLACE FUNCTION reap_stale_compose_jobs(p_now timestamptz DEFAULT now(), p_timeout interval DEFAULT interval '5 minutes') RETURNS int LANGUAGE sql AS 'SELECT 0'" db/tests/layout.sql "T71"
check "금지된 모듈 간 외래키"      "ALTER TABLE template ADD COLUMN bad uuid REFERENCES issue(id)"            db/tests/architecture.sql "허용되지 않은 모듈 간 외래키"
check "코멘트 없는 새 테이블"      "CREATE TABLE zz_new (id int)"                                             db/tests/architecture.sql "소유 모듈 코멘트가 없거나"
check "사용자 조회 인덱스 제거"    "DROP INDEX ix_family_member_user"                                         db/tests/health.sql       "T64"
check "배치 텍스트 외래키를 즉시 검사로" "ALTER TABLE placement DROP CONSTRAINT placement_text_block_id_fkey, ADD CONSTRAINT placement_text_block_id_fkey FOREIGN KEY (text_block_id) REFERENCES text_block(id)" db/tests/issues.sql "foreign key constraint"

# --- 피드 (게시 가드) ---
check "사진 게시 가드 제거"        "DROP TRIGGER trg_media_insert ON media"                                   db/tests/feed.sql         "T51 failed"
check "글 게시 가드 제거"          "DROP TRIGGER trg_post_insert ON post"                                     db/tests/feed.sql         "T51 failed"
check "글 날짜 이동 가드 제거"     "DROP TRIGGER trg_post_period_update ON post"                              db/tests/feed.sql         "T52 failed"
check "글 작성자(구성원) 확인 제거" "$POST_ONLY_PERIOD"                                                       db/tests/feed.sql         "T53 failed"

# --- 그룹 / 초대 / 방장 권한 ---
check "방장 구성원 외래키 제거"    "ALTER TABLE family_group DROP CONSTRAINT family_group_owner_member_fkey"  db/tests/groups.sql       "T20 failed"
check "초대 생성자(방장) 확인 제거" "DROP TRIGGER trg_invite_creator ON family_invite"                        db/tests/groups.sql       "T21 failed"
check "취소된 초대 거부 제거"      "FN|accept_family_invite(text,uuid,timestamptz)|IF v.revoked_at IS NOT NULL THEN|IF false THEN" db/tests/groups.sql "T23 failed"
check "만료된 초대 거부 제거"      "FN|accept_family_invite(text,uuid,timestamptz)|IF v.expires_at <= p_now THEN|IF false THEN"    db/tests/groups.sql "T23 failed"
check "내보내기 권한 확인 제거"    "CREATE OR REPLACE FUNCTION remove_family_member(p_group uuid, p_actor uuid, p_target uuid) RETURNS void LANGUAGE sql AS 'UPDATE family_member SET left_at = now() WHERE group_id = p_group AND user_id = p_target AND left_at IS NULL'" db/tests/groups.sql "T24 failed"
check "방장 넘기기 권한 확인 제거"  "CREATE OR REPLACE FUNCTION transfer_family_owner(p_group uuid, p_actor uuid, p_new_owner uuid) RETURNS void LANGUAGE sql AS 'UPDATE family_group SET owner_id = p_new_owner WHERE id = p_group'" db/tests/groups.sql "T25 failed"
check "배송지 등록자 확인 제거"    "DROP TRIGGER trg_address_creator ON delivery_address"                     db/tests/groups.sql       "T26 failed"
check "방장 익명화 거부 제거"      "FN|anonymize_user(uuid)|IF EXISTS (SELECT 1 FROM family_group WHERE owner_id = p_user) THEN|IF false THEN" db/tests/identity.sql "T81 failed"
check "로그인 수단 제한 제거"      "ALTER TABLE auth_identity DROP CONSTRAINT auth_identity_provider_check"   db/tests/identity.sql     "T82 failed"

# --- 참조 정합성(db/tests/integrity.sql): 복합 외래키와 트리거를 하나씩 약화/제거 ---
check "사진-글 복합 FK 제거"          "ALTER TABLE media DROP CONSTRAINT media_post_id_group_id_fkey, ADD FOREIGN KEY (post_id) REFERENCES post(id) ON DELETE CASCADE" db/tests/integrity.sql "T100 failed"
check "텍스트-글 복합 FK 제거"        "ALTER TABLE text_block DROP CONSTRAINT text_block_post_id_group_id_fkey, ADD FOREIGN KEY (post_id) REFERENCES post(id) ON DELETE SET NULL" db/tests/integrity.sql "T101 failed"
check "텍스트-호 복합 FK 제거"        "ALTER TABLE text_block DROP CONSTRAINT text_block_issue_id_group_id_fkey, ADD FOREIGN KEY (issue_id) REFERENCES issue(id) ON DELETE CASCADE" db/tests/integrity.sql "T101 failed"
check "호별 선별-사진 복합 FK 제거"   "ALTER TABLE issue_media DROP CONSTRAINT issue_media_media_id_group_id_fkey, ADD FOREIGN KEY (media_id) REFERENCES media(id) ON DELETE CASCADE" db/tests/integrity.sql "T102 failed"
check "호별 선별-호 복합 FK 제거"     "ALTER TABLE issue_media DROP CONSTRAINT issue_media_issue_id_group_id_fkey, ADD FOREIGN KEY (issue_id) REFERENCES issue(id) ON DELETE CASCADE" db/tests/integrity.sql "T102 failed"
check "글 작성자 확인 제거 (정합성)"   "$POST_ONLY_PERIOD"                                                      db/tests/integrity.sql    "T103 failed"
check "승인-페이지 복합 FK 제거"      "ALTER TABLE approval DROP CONSTRAINT approval_page_id_run_id_fkey"        db/tests/integrity.sql    "T104 failed"
check "승인 작성자 확인 제거"         "DROP TRIGGER trg_approval_author ON approval"                             db/tests/integrity.sql    "T104 failed"
check "수정로그-조판 복합 FK 제거"    "ALTER TABLE override DROP CONSTRAINT override_run_id_issue_id_fkey"       db/tests/integrity.sql    "T105 failed"
check "수정 작성자 확인 제거"         "DROP TRIGGER trg_override_author ON override"                             db/tests/integrity.sql    "T105 failed"
check "인쇄작업-조판 복합 FK 제거"    "ALTER TABLE print_job DROP CONSTRAINT print_job_run_id_issue_id_fkey"     db/tests/integrity.sql    "T106 failed"
check "배치 교차 참조 가드 제거"      "DROP TRIGGER trg_placement_same_issue ON placement"                       db/tests/integrity.sql    "T107 failed"
check "미리보기-페이지 FK 제거"       "ALTER TABLE preview DROP CONSTRAINT preview_run_id_page_no_fkey"          db/tests/integrity.sql    "T108 failed"
check "주문 배송지/주문자 가드 제거"  "DROP TRIGGER trg_order_consistency ON print_order"                        db/tests/integrity.sql    "T109 failed"
check "텍스트-글 FK 를 CASCADE 로"    "ALTER TABLE text_block DROP CONSTRAINT text_block_post_id_group_id_fkey, ADD FOREIGN KEY (post_id, group_id) REFERENCES post(id, group_id) ON DELETE CASCADE" db/tests/integrity.sql "T114"
check "배치된 사진 보호 FK 제거"      "ALTER TABLE placement DROP CONSTRAINT placement_media_id_fkey"            db/tests/integrity.sql    "T115 failed"

echo "----"
if [ "$bad" -eq 0 ]; then echo "모든 변이를 테스트가 잡았다"; else echo "놓친 변이가 있다 (위 FAIL 항목)"; fi
exit "$bad"
