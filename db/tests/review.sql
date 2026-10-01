-- review 모듈 테스트. 전체 실행: ./scripts/db.sh test
-- 각 테스트는 BEGIN..ROLLBACK 으로 격리되어 시드 데이터를 바꾸지 않는다. 하나라도 실패하면 즉시 중단.
\echo == review

\echo T54 승인 버전(S4): 수정이 생기면 승인 무효, 재승인 시 유효, 승인 후 수정은 검토로 복귀, 인쇄 중 수정 거부
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1';
        u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        u2 constant uuid := '00000000-0000-0000-0000-000000000002';
        v_run uuid; v_p1 uuid; v_p2 uuid; p record;
BEGIN
  PERFORM change_issue_status(v, 'closing');
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (v, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'done') RETURNING id INTO v_run;
  INSERT INTO page (run_id, page_no) VALUES (v_run, 1) RETURNING id INTO v_p1;
  INSERT INTO page (run_id, page_no) VALUES (v_run, 2) RETURNING id INTO v_p2;
  PERFORM change_issue_status(v, 'review');

  INSERT INTO approval (issue_id, page_id, user_id, status, created_at) VALUES
    (v, v_p1, u1, 'approved', '2026-10-01 10:00+09'),
    (v, v_p2, u1, 'approved', '2026-10-01 10:00+09');
  ASSERT (SELECT run_id FROM approval WHERE page_id = v_p1) = v_run, 'T54 run_id 자동 기록';
  ASSERT (SELECT override_seq FROM approval WHERE page_id = v_p1) = 0, 'T54 override_seq 자동 기록';
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v;
  ASSERT p.approved_pages = 2 AND p.stale_approval_pages = 0, 'T54 초기 승인';

  INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id)
  VALUES (v, v_run, 'page', v_p1, '{"op":"move"}', u2);
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v;
  ASSERT p.approved_pages = 1 AND p.stale_approval_pages = 1,
         format('T54 수정 후 approved=%s stale=%s', p.approved_pages, p.stale_approval_pages);
  BEGIN
    PERFORM change_issue_status(v, 'approved');
    RAISE EXCEPTION 'T54 failed: 낡은 승인으로 approved 가 됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  INSERT INTO approval (issue_id, page_id, user_id, status, created_at)
  VALUES (v, v_p1, u1, 'approved', '2026-10-01 11:00+09');
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v;
  ASSERT p.approved_pages = 2 AND p.stale_approval_pages = 0, 'T54 재승인';
  PERFORM change_issue_status(v, 'approved');

  -- 승인 후 수정 -> 자동으로 review 복귀
  INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id)
  VALUES (v, v_run, 'page', v_p2, '{"op":"resize"}', u2);
  ASSERT (SELECT status FROM issue WHERE id = v) = 'review', 'T54 승인 후 수정이 review 로 되돌리지 않음';
  ASSERT (SELECT note FROM issue_status_history WHERE issue_id = v ORDER BY id DESC LIMIT 1) LIKE '승인 후 수정%', 'T54 사유 기록';
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v;
  ASSERT p.approved_pages = 1 AND p.stale_approval_pages = 1, 'T54 p2 승인 무효';

  -- 인쇄 중에는 수정 불가
  INSERT INTO approval (issue_id, page_id, user_id, status, created_at)
  VALUES (v, v_p2, u1, 'approved', '2026-10-01 12:00+09');
  PERFORM change_issue_status(v, 'approved');
  PERFORM change_issue_status(v, 'printing');
  BEGIN
    INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id)
    VALUES (v, v_run, 'page', v_p1, '{"op":"move"}', u2);
    RAISE EXCEPTION 'T54 failed: printing 중 수정이 허용됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;
ROLLBACK;

\echo T62 무효가 된(superseded) 조판에는 승인/수정 불가
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1';
        u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        v_run uuid; v_p1 uuid;
BEGIN
  PERFORM change_issue_status(v, 'closing');
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (v, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'done') RETURNING id INTO v_run;
  INSERT INTO page (run_id, page_no) VALUES (v_run, 1) RETURNING id INTO v_p1;
  PERFORM change_issue_status(v, 'review');
  PERFORM change_issue_status(v, 'closing');      -- 재조판: 이전 실행은 superseded
  ASSERT (SELECT status FROM layout_run WHERE id = v_run) = 'superseded', 'T62 precondition';
  BEGIN
    INSERT INTO approval (issue_id, page_id, user_id, status) VALUES (v, v_p1, u1, 'approved');
    RAISE EXCEPTION 'T62 failed: 무효 조판에 승인됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id)
    VALUES (v, v_run, 'page', v_p1, '{"op":"move"}', u1);
    RAISE EXCEPTION 'T62 failed: 무효 조판에 수정됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;
ROLLBACK;
