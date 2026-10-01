#!/usr/bin/env bash
# shellcheck disable=SC2015  # ok/fail 도우미는 항상 성공하므로 `A && ok || fail` 패턴이 안전하다
# 두 세션이 동시에 움직일 때의 보장을 재현한다. (단일 세션 테스트로는 증명할 수 없는 부분)
#   [A] 마감 처리 중(커밋 전)에 업로드하면: 업로드는 마감이 끝날 때까지 기다린 뒤 거부되고, 사진이 저장되지 않는다
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

ISSUE=00000000-0000-0000-0000-0000000000c1
USER2=00000000-0000-0000-0000-000000000002

echo "[A] 마감 처리 중 업로드"
fresh
"${PSQL[@]}" -c "BEGIN; SELECT count(*) FROM close_due_issues('2026-10-01 00:00:01+09'); SELECT pg_sleep(3); COMMIT;" >/dev/null 2>&1 &
apid=$!
sleep 1.5
s=$(ms)
out=$("${PSQL[@]}" -c "INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, rights_ok) VALUES ('$ISSUE','$USER2','race.jpg','race',4000,3000,true)" 2>&1)
e=$(ms)
wait "$apid"
elapsed=$((e - s))
grep -q "not collecting" <<<"$out" && ok "업로드가 거부됨 (closing 으로 바뀐 것을 확인)" || fail "업로드가 거부되지 않음: $out"
[ "$elapsed" -ge 1000 ] && ok "마감이 끝날 때까지 기다렸다 (${elapsed}ms)" || fail "기다리지 않고 바로 응답함 (${elapsed}ms) -> 직렬화가 안 됨"
n=$("${PSQL[@]}" -c "SELECT count(*) FROM media WHERE storage_key='race.jpg'")
[ "$n" = "0" ] && ok "사진이 저장되지 않음 (선별에서 조용히 누락되는 일 없음)" || fail "사진이 저장됨 ($n)"

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
"${PSQL[@]}" -c "INSERT INTO issue (publication_id, title, period_start, period_end, close_at, template_id, min_photos, max_photos, min_pages, max_pages, page_multiple)
                 SELECT '00000000-0000-0000-0000-0000000000b1', 'x'||m, make_date(2026,m,1), make_date(2026,m,28), now(), '00000000-0000-0000-0000-0000000000a1', 15,60,8,40,4 FROM generate_series(5,5) m" >/dev/null 2>&1
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

echo "----"
[ "$bad" -eq 0 ] && echo "동시성 보장 확인됨" || echo "기대와 다른 결과가 있다"
exit "$bad"
