#!/usr/bin/env bash
# shellcheck disable=SC2015  # ok/fail 도우미는 항상 성공하므로 `A && ok || fail` 패턴이 안전하다
# 두 세션이 동시에 움직일 때의 보장을 재현한다. (단일 세션 테스트로는 증명할 수 없는 부분)
#   [A] 마감 처리 중(커밋 전)에 글을 올리면: 글 등록은 마감이 끝날 때까지 기다린 뒤 거부되고, 글이 저장되지 않는다
#   [C] 사용 1회짜리 초대 링크를 두 사람이 동시에 수락하면: 한 명만 합류하고 다른 한 명은 기다렸다가 거부된다
#   [B] 워커 둘이 동시에 작업을 가져가면: 호가 1개면 한쪽은 막히지 않고 '없음', 2개면 서로 다른 호를 받는다
# 시간 기준은 넉넉하게 잡았다 (세션 하나가 잠금을 3초 쥐고 있고, 다른 세션은 1.5초 뒤에 시작).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
export COMPOSE_FILE=docker-compose.dbtest.yml  # 앱 개발용 docker-compose.yml 과 분리된 DB 검증 전용 환경
export MSYS_NO_PATHCONV=1
trap 'docker compose --profile tools down >/dev/null 2>&1' EXIT

PSQL=(docker compose exec -T db psql -U postgres -d pub -At -q)
ms() { date +%s%3N; }
bad=0
ok()   { echo "    OK   $1"; }
fail() { echo "    FAIL $1"; bad=1; }

fresh() {
  bash scripts/db.sh up >/dev/null 2>&1 && bash scripts/db.sh reset >/dev/null 2>&1 \
    && bash scripts/db.sh migrate >/dev/null 2>&1 && bash scripts/db.sh seed >/dev/null 2>&1 || { echo "준비 실패"; exit 2; }
}

USER2=00000000-0000-0000-0000-000000000002
GROUP=00000000-0000-0000-0000-0000000000d1

echo "[A] 마감 처리 중 글 올리기"
fresh
"${PSQL[@]}" -c "BEGIN; SELECT count(*) FROM close_due_issues('2026-10-01 00:00:01+09'); SELECT pg_sleep(3); COMMIT;" >/dev/null 2>&1 &
apid=$!
sleep 1.5
s=$(ms)
out=$("${PSQL[@]}" -c "INSERT INTO post (group_id, author_id, body, posted_at) VALUES ('$GROUP','$USER2','race-post','2026-09-15 12:00+09')" 2>&1)
e=$(ms)
wait "$apid"
elapsed=$((e - s))
grep -q "not collecting" <<<"$out" && ok "글 올리기가 거부됨 (closing 으로 바뀐 것을 확인)" || fail "글 올리기가 거부되지 않음: $out"
[ "$elapsed" -ge 1000 ] && ok "마감이 끝날 때까지 기다렸다 (${elapsed}ms)" || fail "기다리지 않고 바로 응답함 (${elapsed}ms) -> 직렬화가 안 됨"
n=$("${PSQL[@]}" -c "SELECT count(*) FROM post WHERE body='race-post'")
[ "$n" = "0" ] && ok "글이 저장되지 않음 (선별에서 조용히 누락되는 일 없음)" || fail "글이 저장됨 ($n)"

echo "[B1] 마감된 호 1개를 워커 둘이 동시에"
"${PSQL[@]}" -c "SELECT count(*) FROM close_due_issues('2026-10-01 00:00:01+09')" >/dev/null 2>&1
"${PSQL[@]}" -c "BEGIN; SELECT o_issue_id FROM claim_compose_job('A','0.1'); SELECT pg_sleep(3); COMMIT;" >"${TMPDIR:-/tmp}/claim_a.out" 2>&1 &
apid=$!
sleep 1.5
s=$(ms)
rows=$("${PSQL[@]}" -c "SELECT count(*) FROM claim_compose_job('B','0.1')" 2>&1)
e=$(ms)
wait "$apid"
elapsed=$((e - s))
[ "$rows" = "0" ] && ok "B 는 받을 작업이 없다고 응답 (같은 호를 중복으로 받지 않음)" || fail "B 가 작업을 받음: $rows"
[ "$elapsed" -lt 1500 ] && ok "B 는 막히지 않고 즉시 응답 (${elapsed}ms)" || fail "B 가 A 를 기다림 (${elapsed}ms) -> SKIP LOCKED 가 동작하지 않음"

echo "[B2] 마감된 호 2개를 워커 둘이 동시에"
fresh
"${PSQL[@]}" -c "SELECT count(*) FROM close_due_issues('2026-10-01 00:00:01+09')" >/dev/null 2>&1
"${PSQL[@]}" -c "INSERT INTO issue (group_id, title, period_start, period_end, close_at, template_id, min_photos, max_photos, min_pages, max_pages, page_multiple)
                 SELECT '$GROUP', 'x'||m, make_date(2026,m,1), make_date(2026,m,28), now(), '00000000-0000-0000-0000-0000000000a1', 15,60,8,40,4 FROM generate_series(5,5) m" >/dev/null 2>&1
"${PSQL[@]}" -c "SELECT change_issue_status(id,'closing') FROM issue WHERE title='x5'" >/dev/null 2>&1
"${PSQL[@]}" -c "BEGIN; SELECT 'A:'||o_issue_id FROM claim_compose_job('A','0.1'); SELECT pg_sleep(3); COMMIT;" >"${TMPDIR:-/tmp}/claim_a.out" 2>&1 &
apid=$!
sleep 1.5
s=$(ms)
b=$("${PSQL[@]}" -c "SELECT 'B:'||o_issue_id FROM claim_compose_job('B','0.1')" 2>&1)
e=$(ms)
wait "$apid"
elapsed=$((e - s))
a=$(grep -o "A:[0-9a-f-]*" "${TMPDIR:-/tmp}/claim_a.out" | head -1)
rm -f "${TMPDIR:-/tmp}/claim_a.out"
if [ -n "$a" ] && [ -n "$b" ] && [ "${a#A:}" != "${b#B:}" ]; then ok "서로 다른 호를 받음 ($a / $b)"; else fail "같은 호를 받았거나 못 받음 (A='$a' B='$b')"; fi
[ "$elapsed" -lt 1500 ] && ok "B 는 막히지 않음 (${elapsed}ms)" || fail "B 가 A 를 기다림 (${elapsed}ms)"
r=$("${PSQL[@]}" -c "SELECT count(*) FROM layout_run WHERE status='running'")
[ "$r" = "2" ] && ok "running 실행이 정확히 2개 (호마다 1개)" || fail "running 실행 수=$r"

echo "[C] 사용 1회짜리 초대 링크를 두 사람이 동시에"
fresh
U1=00000000-0000-0000-0000-000000000001
U3=00000000-0000-0000-0000-000000000003
U4=00000000-0000-0000-0000-000000000004
HASH=$(printf 'a%.0s' $(seq 1 64))
"${PSQL[@]}" -c "INSERT INTO app_user (id, name) VALUES ('$U3','셋째'), ('$U4','넷째');
                 INSERT INTO family_invite (group_id, created_by, token_hash, expires_at, max_uses) VALUES ('$GROUP','$U1','$HASH', now() + interval '1 day', 1)" >/dev/null 2>&1
"${PSQL[@]}" -c "BEGIN; SELECT accept_family_invite('$HASH','$U3'); SELECT pg_sleep(3); COMMIT;" >/dev/null 2>&1 &
apid=$!
sleep 1.5
s=$(ms)
out=$("${PSQL[@]}" -c "SELECT accept_family_invite('$HASH','$U4')" 2>&1)
e=$(ms)
wait "$apid"
elapsed=$((e - s))
grep -q "exhausted" <<<"$out" && ok "두 번째 사람은 거부됨 (사용 횟수 초과)" || fail "두 번째 사람이 합류함: $out"
[ "$elapsed" -ge 1000 ] && ok "첫 번째 수락이 끝날 때까지 기다렸다 (${elapsed}ms)" || fail "기다리지 않음 (${elapsed}ms) -> 초대 행 잠금이 안 됨"
m=$("${PSQL[@]}" -c "SELECT count(*) FROM family_member WHERE group_id='$GROUP' AND user_id IN ('$U3','$U4')")
[ "$m" = "1" ] && ok "새 구성원은 정확히 1명" || fail "새 구성원 수=$m"

echo "----"
[ "$bad" -eq 0 ] && echo "동시성 보장 확인됨" || echo "기대와 다른 결과가 있다"
exit "$bad"
