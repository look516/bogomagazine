-- layout 모듈 테스트. 전체 실행: ./scripts/db.sh test
-- 각 테스트는 BEGIN..ROLLBACK 으로 격리되어 시드 데이터를 바꾸지 않는다. 하나라도 실패하면 즉시 중단.
\echo == layout

\echo T47 조판 큐: closing 이면 노출, 조판 진행/완료 또는 실패 3회면 제외
BEGIN;
DO $$
DECLARE v_issue constant uuid := '00000000-0000-0000-0000-0000000000c1'; v_run uuid; k int;
BEGIN
  ASSERT (SELECT count(*) FROM v_compose_queue) = 0, 'T47 collecting 인데 큐에 있음';
  PERFORM change_issue_status(v_issue, 'closing');
  ASSERT (SELECT count(*) FROM v_compose_queue WHERE issue_id = v_issue) = 1, 'T47 closing 인데 큐에 없음';

  FOR k IN 1..2 LOOP
    INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
    VALUES (v_issue, '00000000-0000-0000-0000-0000000000a1', '0.1.0', k, 'h', 'failed');
  END LOOP;
  ASSERT (SELECT count(*) FROM v_compose_queue WHERE issue_id = v_issue) = 1, 'T47 실패 2회는 재시도 대상';
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (v_issue, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 3, 'h', 'failed');
  ASSERT (SELECT count(*) FROM v_compose_queue WHERE issue_id = v_issue) = 0, 'T47 실패 3회인데 큐에 있음';

  DELETE FROM layout_run WHERE issue_id = v_issue;
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (v_issue, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'running');
  ASSERT (SELECT count(*) FROM v_compose_queue WHERE issue_id = v_issue) = 0, 'T47 진행 중인데 큐에 있음';
END $$;
ROLLBACK;

\echo T63 "최신" 판정은 시각이 아니라 삽입 순서(seq): 시각이 모두 같아도 안정적, 조판 회차는 호별로 독립
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1';
        u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        v_r1 uuid; v_r2 uuid; v_p uuid; v_oct uuid; p record;
BEGIN
  PERFORM change_issue_status(v, 'closing');
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status, created_at)
  VALUES (v, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'failed', '2026-10-01 09:00+09') RETURNING id INTO v_r1;
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status, created_at)
  VALUES (v, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 2, 'h', 'done', '2026-10-01 09:00+09') RETURNING id INTO v_r2;
  ASSERT (SELECT run_no FROM layout_run WHERE id = v_r1) = 1 AND (SELECT run_no FROM layout_run WHERE id = v_r2) = 2, 'T63 run_no';
  ASSERT (SELECT latest_run_id FROM v_issue_progress WHERE issue_id = v) = v_r2, 'T63 최신 실행이 삽입 순서와 다름';

  SELECT o_issue_id INTO v_oct FROM open_monthly_issues('2026-10-02 12:00+09');
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash)
  VALUES (v_oct, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h');
  ASSERT (SELECT run_no FROM layout_run WHERE issue_id = v_oct) = 1, 'T63 다른 호의 run_no 는 1부터';

  INSERT INTO page (run_id, page_no) VALUES (v_r2, 1) RETURNING id INTO v_p;
  PERFORM change_issue_status(v, 'review');
  -- 승인 3건이 모두 같은 시각이어도 마지막에 넣은 것이 최신
  INSERT INTO approval (issue_id, page_id, user_id, status, created_at)
  VALUES (v, v_p, u1, 'changes_requested', '2026-10-01 10:00+09');
  INSERT INTO approval (issue_id, page_id, user_id, status, created_at)
  VALUES (v, v_p, u1, 'approved', '2026-10-01 10:00+09');
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v;
  ASSERT p.approved_pages = 1 AND p.changes_requested_pages = 0, 'T63 승인이 최신이어야 함';
  INSERT INTO approval (issue_id, page_id, user_id, status, created_at)
  VALUES (v, v_p, u1, 'changes_requested', '2026-10-01 10:00+09');
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v;
  ASSERT p.approved_pages = 0 AND p.changes_requested_pages = 1, 'T63 수정 요청이 최신이어야 함';
END $$;
ROLLBACK;

\echo T70 워커: claim -> heartbeat -> 페이지 없이 complete 거부 -> 정상 complete 시 review 전환
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1'; r record;
BEGIN
  PERFORM * FROM close_due_issues('2026-10-01 00:00:01+09');
  ASSERT (SELECT count(*) FROM v_compose_queue WHERE issue_id = v) = 1, 'T70 큐에 없음';

  SELECT * INTO r FROM claim_compose_job('w1', '0.1.0');
  ASSERT r.o_issue_id = v AND r.o_attempt = 1, 'T70 claim 결과';
  ASSERT (SELECT status FROM layout_run WHERE id = r.o_run_id) = 'running'
     AND (SELECT locked_by FROM layout_run WHERE id = r.o_run_id) = 'w1'
     AND (SELECT run_no FROM layout_run WHERE id = r.o_run_id) = 1, 'T70 run 상태';
  ASSERT (SELECT count(*) FROM claim_compose_job('w2', '0.1.0')) = 0, 'T70 진행 중인 호를 또 받음';
  ASSERT (SELECT count(*) FROM v_compose_queue) = 0, 'T70 진행 중인데 큐에 있음';
  ASSERT heartbeat_compose_job(r.o_run_id, 'w1'), 'T70 heartbeat';
  ASSERT NOT heartbeat_compose_job(r.o_run_id, 'w2'), 'T70 남의 heartbeat 가 통과';

  BEGIN
    PERFORM complete_compose_job(r.o_run_id, 'w1', 'hash');
    RAISE EXCEPTION 'T70 failed: 페이지 없이 complete 됨';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%no pages%', 'T70 메시지: ' || SQLERRM;
  END;
  ASSERT (SELECT status FROM layout_run WHERE id = r.o_run_id) = 'running', 'T70 거부 뒤 롤백 안 됨';

  INSERT INTO page (run_id, page_no) VALUES (r.o_run_id, 1);
  BEGIN
    PERFORM complete_compose_job(r.o_run_id, 'w2', 'hash');
    RAISE EXCEPTION 'T70 failed: 남의 작업을 complete 함';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%no longer running%', 'T70 메시지: ' || SQLERRM;
  END;

  PERFORM complete_compose_job(r.o_run_id, 'w1', 'hash123', 0.8::real, '{"warnings":[]}', 's3://x/input.json');
  ASSERT (SELECT status FROM issue WHERE id = v) = 'review', 'T70 review 전환';
  ASSERT (SELECT status FROM layout_run WHERE id = r.o_run_id) = 'done'
     AND (SELECT input_snapshot_hash FROM layout_run WHERE id = r.o_run_id) = 'hash123'
     AND (SELECT input_ref FROM layout_run WHERE id = r.o_run_id) = 's3://x/input.json', 'T70 결과 저장';
  ASSERT (SELECT note FROM issue_status_history WHERE issue_id = v ORDER BY id DESC LIMIT 1) LIKE '자동 조판 완료%', 'T70 이력';
END $$;
ROLLBACK;

\echo T71 워커가 죽으면: heartbeat 끊긴 작업은 failed 처리되고 다른 워커가 인수, 옛 워커의 늦은 complete 는 거부
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1'; r1 record; r2 record;
BEGIN
  PERFORM * FROM close_due_issues('2026-10-01 00:00:01+09');
  SELECT * INTO r1 FROM claim_compose_job('w1', '0.1.0');
  UPDATE layout_run SET heartbeat_at = now() - interval '10 minutes' WHERE id = r1.o_run_id;

  SELECT * INTO r2 FROM claim_compose_job('w2', '0.1.0');
  ASSERT r2.o_issue_id = v AND r2.o_attempt = 2, format('T71 인수: attempt=%s', r2.o_attempt);
  ASSERT (SELECT status FROM layout_run WHERE id = r1.o_run_id) = 'failed', 'T71 죽은 작업이 failed 가 아님';
  ASSERT (SELECT run_no FROM layout_run WHERE id = r2.o_run_id) = 2, 'T71 run_no';
  ASSERT NOT heartbeat_compose_job(r1.o_run_id, 'w1'), 'T71 죽었던 워커의 heartbeat 가 통과';
  ASSERT NOT fail_compose_job(r1.o_run_id, 'w1', 'late'), 'T71 죽었던 워커의 fail 이 통과';
  INSERT INTO page (run_id, page_no) VALUES (r1.o_run_id, 1);
  BEGIN
    PERFORM complete_compose_job(r1.o_run_id, 'w1', 'h');
    RAISE EXCEPTION 'T71 failed: 죽었던 워커가 complete 함';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%no longer running%', 'T71 메시지: ' || SQLERRM;
  END;
  ASSERT (SELECT status FROM issue WHERE id = v) = 'closing', 'T71 호 상태가 바뀜';
END $$;
ROLLBACK;

\echo T72 재오픈되면 진행 중이던 워커 작업이 무효가 되고, 다시 마감하면 새 회차로 조판
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1'; r1 record; r2 record;
BEGIN
  PERFORM * FROM close_due_issues('2026-10-01 00:00:01+09');
  SELECT * INTO r1 FROM claim_compose_job('w1', '0.1.0');
  PERFORM change_issue_status(v, 'collecting', NULL, '재오픈', now() + interval '1 day');
  ASSERT NOT heartbeat_compose_job(r1.o_run_id, 'w1'), 'T72 무효가 된 작업의 heartbeat 가 통과';
  INSERT INTO page (run_id, page_no) VALUES (r1.o_run_id, 1);
  BEGIN
    PERFORM complete_compose_job(r1.o_run_id, 'w1', 'h');
    RAISE EXCEPTION 'T72 failed: 재오픈된 호의 작업이 complete 됨';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%no longer running%', 'T72 메시지: ' || SQLERRM;
  END;

  PERFORM * FROM close_due_issues(now() + interval '2 days');
  SELECT * INTO r2 FROM claim_compose_job('w1', '0.1.0');
  ASSERT r2.o_issue_id = v AND r2.o_attempt = 1, 'T72 새 마감 주기는 시도 1부터';
  ASSERT (SELECT run_no FROM layout_run WHERE id = r2.o_run_id) = 2, 'T72 run_no 는 이어서 증가';
END $$;
ROLLBACK;

\echo T73 3번 실패하면 큐에서 빠지고 compose_failed, 운영자가 reset 하면 다시 시도
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1'; r record; k int;
BEGIN
  PERFORM * FROM close_due_issues('2026-10-01 00:00:01+09');
  FOR k IN 1..3 LOOP
    SELECT * INTO r FROM claim_compose_job('w1', '0.1.0');
    ASSERT r.o_attempt = k, format('T73 시도 %s 번째 attempt=%s', k, r.o_attempt);
    ASSERT fail_compose_job(r.o_run_id, 'w1', 'boom'), 'T73 fail 보고';
  END LOOP;
  ASSERT (SELECT count(*) FROM claim_compose_job('w1', '0.1.0')) = 0, 'T73 3번 실패 뒤에도 계속 받음';
  ASSERT (SELECT current_step FROM v_issue_progress WHERE issue_id = v) = 'compose_failed', 'T73 compose_failed 아님';
  ASSERT reset_compose_failures(v) = 3, 'T73 reset 건수';
  SELECT * INTO r FROM claim_compose_job('w1', '0.1.0');
  ASSERT r.o_issue_id = v AND r.o_attempt = 1, 'T73 reset 후 다시 시도 1';
END $$;
ROLLBACK;

\echo T74 두 호가 마감되면 워커 둘이 서로 다른 호를 받는다
BEGIN;
DO $$
DECLARE v_oct uuid; a record; b record;
BEGIN
  SELECT o_issue_id INTO v_oct FROM open_monthly_issues('2026-10-02 12:00+09');
  PERFORM change_issue_status(v_oct, 'closing');
  PERFORM * FROM close_due_issues('2026-10-01 00:00:01+09');   -- 9월호도 closing
  SELECT * INTO a FROM claim_compose_job('w1', '0.1.0');
  SELECT * INTO b FROM claim_compose_job('w2', '0.1.0');
  ASSERT a.o_issue_id IS NOT NULL AND b.o_issue_id IS NOT NULL AND a.o_issue_id <> b.o_issue_id, 'T74 같은 호를 받음';
  ASSERT (SELECT count(*) FROM claim_compose_job('w3', '0.1.0')) = 0, 'T74 남은 호가 없는데 받음';
END $$;
ROLLBACK;
