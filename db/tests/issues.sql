-- issues 모듈 테스트. 전체 실행: ./scripts/db.sh test
-- 각 테스트는 BEGIN..ROLLBACK 으로 격리되어 시드 데이터를 바꾸지 않는다. 하나라도 실패하면 즉시 중단.
\echo == issues

\echo T01 issue: min_photos > max_photos 거부
BEGIN;
DO $$ BEGIN
  BEGIN
    INSERT INTO issue (group_id, title, period_start, period_end, close_at, template_id,
                       min_photos, max_photos, min_pages, max_pages, page_multiple)
    VALUES ('00000000-0000-0000-0000-0000000000d1','x','2026-10-01','2026-10-31', now(),
            '00000000-0000-0000-0000-0000000000a1', 10, 5, 8, 40, 4);
    RAISE EXCEPTION 'T01 failed: 거부되지 않음';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;
ROLLBACK;

\echo T02 issue: 잘못된 status 거부
BEGIN;
DO $$ BEGIN
  BEGIN
    INSERT INTO issue (group_id, title, period_start, period_end, close_at, template_id,
                       status, min_photos, max_photos, min_pages, max_pages, page_multiple)
    VALUES ('00000000-0000-0000-0000-0000000000d1','x','2026-10-01','2026-10-31', now(),
            '00000000-0000-0000-0000-0000000000a1', 'bogus', 1, 5, 8, 40, 4);
    RAISE EXCEPTION 'T02 failed: 거부되지 않음';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;
ROLLBACK;

\echo T03 issue: 같은 그룹/같은 기간 시작일 중복 거부
BEGIN;
DO $$ BEGIN
  BEGIN
    INSERT INTO issue (group_id, title, period_start, period_end, close_at, template_id,
                       min_photos, max_photos, min_pages, max_pages, page_multiple)
    VALUES ('00000000-0000-0000-0000-0000000000d1','dup','2026-09-01','2026-09-30', now(),
            '00000000-0000-0000-0000-0000000000a1', 1, 5, 8, 40, 4);
    RAISE EXCEPTION 'T03 failed: 거부되지 않음';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END $$;
ROLLBACK;

\echo T04 호를 지우면 그 호의 선별 결과/이력은 함께 지워지지만 가족의 글과 사진은 남는다
BEGIN;
DO $$ BEGIN
  PERFORM change_issue_status('00000000-0000-0000-0000-0000000000c1', 'closing');
  PERFORM * FROM select_media('00000000-0000-0000-0000-0000000000c1');
  ASSERT (SELECT count(*) FROM issue_media WHERE issue_id = '00000000-0000-0000-0000-0000000000c1') = 100, 'T04 precondition: 후보 100장';
  DELETE FROM issue WHERE id = '00000000-0000-0000-0000-0000000000c1';
  ASSERT (SELECT count(*) FROM issue_media) = 0,            'T04 issue_media 남음';
  ASSERT (SELECT count(*) FROM issue_status_history) = 0,   'T04 history 남음';
  ASSERT (SELECT count(*) FROM media) = 100 AND (SELECT count(*) FROM post) = 50, 'T04 가족의 글/사진이 사라짐';
END $$;
ROLLBACK;

\echo T04b 조판 결과(배치)까지 있는 호도 삭제된다 (배치와 텍스트는 지워지고 글/사진은 남는다)
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1'; v_run uuid; v_pg uuid; v_tb uuid;
BEGIN
  PERFORM change_issue_status(v, 'closing');
  PERFORM * FROM select_media(v);
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (v, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'done') RETURNING id INTO v_run;
  INSERT INTO page (run_id, page_no) VALUES (v_run, 1) RETURNING id INTO v_pg;
  INSERT INTO text_block (issue_id, group_id, kind, body) VALUES (v, '00000000-0000-0000-0000-0000000000d1', 'caption', '캡션') RETURNING id INTO v_tb;
  INSERT INTO placement (page_id, ref_type, media_id, x, y, w, h)
  SELECT v_pg, 'media', media_id, 0, 0, 10, 10 FROM issue_media WHERE issue_id = v AND selection_status = 'selected' LIMIT 3;
  INSERT INTO placement (page_id, ref_type, text_block_id, x, y, w, h) VALUES (v_pg, 'text_block', v_tb, 0, 20, 10, 5);
  ASSERT (SELECT count(*) FROM placement) = 4, 'T04b precondition';

  DELETE FROM issue WHERE id = v;
  ASSERT (SELECT count(*) FROM placement) = 0 AND (SELECT count(*) FROM text_block) = 0
     AND (SELECT count(*) FROM layout_run) = 0, 'T04b 하위 데이터가 남음';
  ASSERT (SELECT count(*) FROM media) = 100, 'T04b 사진이 사라짐';
END $$;
ROLLBACK;

\echo T04c 배치에 쓰인 사진만 따로 삭제하는 것은 막힌다
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1'; v_run uuid; v_pg uuid;
BEGIN
  PERFORM change_issue_status(v, 'closing');
  PERFORM * FROM select_media(v);
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (v, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'done') RETURNING id INTO v_run;
  INSERT INTO page (run_id, page_no) VALUES (v_run, 1) RETURNING id INTO v_pg;
  INSERT INTO placement (page_id, ref_type, media_id, x, y, w, h)
  SELECT v_pg, 'media', media_id, 0, 0, 10, 10 FROM issue_media WHERE issue_id = v AND selection_status = 'selected' LIMIT 1;
  BEGIN
    DELETE FROM media WHERE id IN (SELECT media_id FROM placement);
    RAISE EXCEPTION 'T04c failed: 배치된 사진이 삭제됨';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
END $$;
ROLLBACK;

\echo T20 전이: 허용/불허/이력/closed_at
BEGIN;
DO $$
DECLARE v_issue constant uuid := '00000000-0000-0000-0000-0000000000c1';
BEGIN
  BEGIN
    PERFORM change_issue_status(v_issue, 'review');
    RAISE EXCEPTION 'T20 failed: collecting->review 가 허용됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  PERFORM change_issue_status(v_issue, 'closing', '00000000-0000-0000-0000-000000000001', '마감');
  ASSERT (SELECT closed_at IS NOT NULL FROM issue WHERE id = v_issue), 'T20 closed_at 없음';
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (v_issue, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'done');
  PERFORM change_issue_status(v_issue, 'review');
  ASSERT (SELECT count(*) FROM issue_status_history WHERE issue_id = v_issue) = 2, 'T20 이력 개수';
  ASSERT (SELECT to_status FROM issue_status_history WHERE issue_id = v_issue ORDER BY id DESC LIMIT 1) = 'review', 'T20 마지막 이력';
END $$;
ROLLBACK;

\echo T21 전이: 존재하지 않는 호
BEGIN;
DO $$ BEGIN
  BEGIN
    PERFORM change_issue_status(gen_random_uuid(), 'closing');
    RAISE EXCEPTION 'T21 failed: 예외 없음';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
END $$;
ROLLBACK;

\echo T30 진행상태: 수집 단계 (그 달에 글을 올린 활동 중 구성원 수, 나간 구성원 제외, 마감 초과)
BEGIN;
DO $$
DECLARE v_issue constant uuid := '00000000-0000-0000-0000-0000000000c1'; p record;
        g  constant uuid := '00000000-0000-0000-0000-0000000000d1';
        u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        u3 constant uuid := '00000000-0000-0000-0000-000000000003';
BEGIN
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.current_step = 'collecting' AND p.total_members = 2 AND p.submitted_members = 2 AND p.progress_pct = 20,
         format('T30 초기값 이상: total=%s submitted=%s pct=%s', p.total_members, p.submitted_members, p.progress_pct);

  -- 한 명(u1)의 글이 모두 삭제되면 제출한 사람은 1명
  UPDATE post SET deleted_at = now() WHERE group_id = g AND author_id = u1;
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.submitted_members = 1 AND p.progress_pct = 10, format('T30 글 삭제 후 pct=%s', p.progress_pct);

  -- 새 구성원이 합류하면 전체가 늘고 제출 비율이 낮아진다
  INSERT INTO app_user (id, name) VALUES (u3, '새 가족');
  INSERT INTO family_member (group_id, user_id) VALUES (g, u3);
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.total_members = 3 AND p.submitted_members = 1 AND p.progress_pct = 7, format('T30 합류 후 total=%s pct=%s', p.total_members, p.progress_pct);

  -- 나간 구성원은 집계에서 빠진다
  UPDATE family_member SET left_at = now() WHERE group_id = g AND user_id = u3;
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.total_members = 2 AND p.progress_pct = 10, 'T30 나간 구성원이 집계에 포함됨';

  UPDATE issue SET close_at = now() - interval '1 day' WHERE id = v_issue;
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.is_overdue, 'T30 is_overdue 아님';
END $$;
ROLLBACK;

\echo T31 진행상태: 마감 처리 세부 단계 (selecting -> composing -> compose_failed)
BEGIN;
DO $$
DECLARE v_issue constant uuid := '00000000-0000-0000-0000-0000000000c1'; p record; v_run uuid;
BEGIN
  PERFORM change_issue_status(v_issue, 'closing');
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.current_step = 'selecting' AND p.progress_pct = 30, 'T31 selecting 아님: ' || p.current_step;

  PERFORM * FROM select_media(v_issue);
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.current_step = 'composing' AND p.selected_media > 0, 'T31 composing 아님: ' || p.current_step;

  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (v_issue, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'failed') RETURNING id INTO v_run;
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.current_step = 'compose_failed' AND p.latest_run_status = 'failed', 'T31 compose_failed 아님';
END $$;
ROLLBACK;

\echo T32 진행상태: 검토 단계 페이지 승인 집계 (페이지별 최신 승인만 반영)
BEGIN;
DO $$
DECLARE v_issue constant uuid := '00000000-0000-0000-0000-0000000000c1'; p record;
        v_run uuid; v_p1 uuid; v_p2 uuid;
        u constant uuid := '00000000-0000-0000-0000-000000000001';
BEGIN
  PERFORM change_issue_status(v_issue, 'closing');
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (v_issue, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'done') RETURNING id INTO v_run;
  INSERT INTO page (run_id, page_no) VALUES (v_run, 1) RETURNING id INTO v_p1;
  INSERT INTO page (run_id, page_no) VALUES (v_run, 2) RETURNING id INTO v_p2;
  PERFORM change_issue_status(v_issue, 'review');

  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.current_step = 'reviewing' AND p.total_pages = 2 AND p.approved_pages = 0 AND p.progress_pct = 50, 'T32 초기';

  INSERT INTO approval (issue_id, page_id, user_id, status, created_at) VALUES
    (v_issue, v_p1, u, 'approved',          '2026-10-01 10:00+09'),
    (v_issue, v_p2, u, 'changes_requested', '2026-10-01 10:05+09');
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.approved_pages = 1 AND p.changes_requested_pages = 1 AND p.progress_pct = 65, format('T32 중간 pct=%s', p.progress_pct);

  INSERT INTO approval (issue_id, page_id, user_id, status, created_at)
  VALUES (v_issue, v_p2, u, 'approved', '2026-10-01 11:00+09');
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.approved_pages = 2 AND p.changes_requested_pages = 0 AND p.progress_pct = 80, format('T32 최종 pct=%s', p.progress_pct);
END $$;
ROLLBACK;

\echo T33 진행상태: 인쇄 ~ 배송 단계
BEGIN;
DO $$
DECLARE v_issue constant uuid := '00000000-0000-0000-0000-0000000000c1'; p record;
        v_run uuid; v_job uuid; v_order uuid;
BEGIN
  PERFORM change_issue_status(v_issue, 'closing');
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (v_issue, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'done') RETURNING id INTO v_run;
  INSERT INTO page (run_id, page_no) VALUES (v_run, 1);
  PERFORM change_issue_status(v_issue, 'review');
  INSERT INTO approval (issue_id, page_id, user_id, status)
  SELECT v_issue, id, '00000000-0000-0000-0000-000000000001', 'approved' FROM page WHERE run_id = v_run;
  PERFORM change_issue_status(v_issue, 'approved');
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.current_step = 'approved' AND p.progress_pct = 85, 'T33 approved';

  PERFORM change_issue_status(v_issue, 'printing');
  INSERT INTO print_job (issue_id, run_id, override_seq, status)
  VALUES (v_issue, v_run, 0, 'preflight_failed') RETURNING id INTO v_job;
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.current_step = 'preflight_failed', 'T33 preflight_failed 아님';

  UPDATE print_job SET status = 'ready' WHERE id = v_job;
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.current_step = 'printing' AND p.progress_pct = 90, 'T33 printing';

  PERFORM change_issue_status(v_issue, 'printed');
  INSERT INTO print_order (print_job_id, ordered_by, delivery_address_id, recipient_name, postal_code, address_line1, quantity, status)
  VALUES (v_job, '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000e1',
          '김가상', '00000', '서울특별시 가상구 가상로 1', 3, 'shipped') RETURNING id INTO v_order;
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.current_step = 'shipping' AND p.progress_pct = 95, 'T33 shipping';

  UPDATE print_order SET status = 'delivered' WHERE id = v_order;
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.current_step = 'delivered' AND p.progress_pct = 100, 'T33 delivered';

  UPDATE print_order SET status = 'cancelled' WHERE id = v_order;
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.current_step = 'order_cancelled' AND p.progress_pct = 90, 'T33 order_cancelled';
END $$;
ROLLBACK;

\echo T34 진행상태: 미발행(skipped)
BEGIN;
DO $$
DECLARE v_issue constant uuid := '00000000-0000-0000-0000-0000000000c1'; p record;
BEGIN
  PERFORM change_issue_status(v_issue, 'skipped', NULL, '수집량 미달');
  SELECT * INTO p FROM v_issue_progress WHERE issue_id = v_issue;
  ASSERT p.current_step = 'skipped' AND p.progress_pct = 100, 'T34 skipped';
END $$;
ROLLBACK;

\echo T40 호 생성: 이번 달 호/마감시각/템플릿 복사, 재실행 멱등
BEGIN;
DO $$
DECLARE r record; v_issue uuid; i record;
BEGIN
  SELECT * INTO r FROM open_monthly_issues('2026-10-02 12:00+09');
  ASSERT r.o_created, 'T40 생성 안 됨';
  v_issue := r.o_issue_id;
  SELECT * INTO i FROM issue WHERE id = v_issue;
  ASSERT i.period_start = '2026-10-01' AND i.period_end = '2026-10-31', 'T40 기간';
  ASSERT i.close_at = '2026-11-01 00:00+09', 'T40 마감시각 ' || i.close_at;
  ASSERT i.title = '2026년 10월호' AND i.status = 'collecting', 'T40 제목/상태';
  ASSERT i.min_photos = 15 AND i.max_photos = 60, 'T40 템플릿 값 복사';

  SELECT * INTO r FROM open_monthly_issues('2026-10-02 12:00+09');
  ASSERT NOT r.o_created AND r.o_issue_id = v_issue, 'T40 재실행이 중복 생성';
  ASSERT (SELECT count(*) FROM issue WHERE period_start = '2026-10-01') = 1, 'T40 중복 호';
END $$;
ROLLBACK;

\echo T41 호 생성: 그룹 타임존 기준 월 경계 + close_day
BEGIN;
DO $$
DECLARE r record; i record;
BEGIN
  -- UTC 9/30 16:00 = KST 10/1 01:00 -> 10월호
  SELECT * INTO r FROM open_monthly_issues('2026-09-30 16:00+00');
  ASSERT (SELECT period_start FROM issue WHERE id = r.o_issue_id) = '2026-10-01', 'T41 타임존 경계';

  DELETE FROM issue WHERE id = r.o_issue_id;
  UPDATE family_group SET close_day = 5;
  SELECT * INTO r FROM open_monthly_issues('2026-10-02 12:00+09');
  ASSERT (SELECT close_at FROM issue WHERE id = r.o_issue_id) = '2026-11-05 00:00+09', 'T41 close_day=5';
END $$;
ROLLBACK;

\echo T42 마감: 시각 전에는 아무것도 안 함
BEGIN;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM close_due_issues('2026-09-30 23:00+09')) = 0, 'T42 마감 전에 처리됨';
  ASSERT (SELECT status FROM issue WHERE id = '00000000-0000-0000-0000-0000000000c1') = 'collecting', 'T42 상태 변경됨';
END $$;
ROLLBACK;

\echo T43 마감: 시각 후 closing + 사진 선별
BEGIN;
DO $$
DECLARE r record; v_issue constant uuid := '00000000-0000-0000-0000-0000000000c1';
BEGIN
  SELECT * INTO r FROM close_due_issues('2026-10-01 00:00:01+09');
  ASSERT r.o_action = 'closing' AND r.o_issue_id = v_issue, 'T43 action=' || r.o_action;
  ASSERT (SELECT status FROM issue WHERE id = v_issue) = 'closing', 'T43 status';
  ASSERT (SELECT closed_at IS NOT NULL FROM issue WHERE id = v_issue), 'T43 closed_at';
  ASSERT (SELECT count(*) FROM issue_media WHERE issue_id = v_issue AND selection_status = 'selected') >= 15, 'T43 선별 안 됨';
END $$;
ROLLBACK;

\echo T44 마감: 수집량 미달 -> 기본은 skipped, auto_skip_below_min=false 면 closing
BEGIN;
DO $$
DECLARE r record; v_issue constant uuid := '00000000-0000-0000-0000-0000000000c1';
BEGIN
  UPDATE issue SET min_photos = 500, max_photos = 600 WHERE id = v_issue;
  SELECT * INTO r FROM close_due_issues('2026-10-01 00:00:01+09');
  ASSERT r.o_action = 'skipped', 'T44 skipped 아님: ' || r.o_action;
  ASSERT (SELECT status FROM issue WHERE id = v_issue) = 'skipped', 'T44 status';
  ASSERT (SELECT note FROM issue_status_history WHERE issue_id = v_issue ORDER BY id DESC LIMIT 1) LIKE '자동 미발행%', 'T44 사유 기록';
END $$;
ROLLBACK;

BEGIN;
DO $$
DECLARE r record; v_issue constant uuid := '00000000-0000-0000-0000-0000000000c1';
BEGIN
  UPDATE issue SET min_photos = 500, max_photos = 600 WHERE id = v_issue;
  UPDATE family_group SET auto_skip_below_min = false;
  SELECT * INTO r FROM close_due_issues('2026-10-01 00:00:01+09');
  ASSERT r.o_action = 'closing', 'T44b closing 아님: ' || r.o_action;
END $$;
ROLLBACK;

\echo T45 마감: 한 호가 실패해도 다른 호는 계속 처리 (실패 호는 롤백)
BEGIN;
DO $$
DECLARE v_bad uuid; n_ok int; n_err int; k int;
BEGIN
  INSERT INTO issue (group_id, title, period_start, period_end, close_at, template_id,
                     min_photos, max_photos, min_pages, max_pages, page_multiple)
  VALUES ('00000000-0000-0000-0000-0000000000d1','bad','2026-08-01','2026-08-31','2026-09-01 00:00+09',
          '00000000-0000-0000-0000-0000000000a1', 1, 5, 8, 40, 4) RETURNING id INTO v_bad;
  -- 문제의 호만 이력 기록 시 실패하도록 함정 설치 (트랜잭션 안에서만 존재)
  EXECUTE format($f$
    CREATE FUNCTION trg_fail() RETURNS trigger LANGUAGE plpgsql AS
    $b$ BEGIN IF NEW.issue_id = %L THEN RAISE EXCEPTION 'boom'; END IF; RETURN NEW; END $b$;
    CREATE TRIGGER t_fail BEFORE INSERT ON issue_status_history FOR EACH ROW EXECUTE FUNCTION trg_fail();
  $f$, v_bad);

  SELECT count(*) FILTER (WHERE o_action = 'closing'), count(*) FILTER (WHERE o_action = 'error')
    INTO n_ok, n_err FROM close_due_issues('2026-10-01 00:00:01+09');
  ASSERT n_ok = 1 AND n_err = 1, format('T45 ok=%s err=%s', n_ok, n_err);
  ASSERT (SELECT status FROM issue WHERE id = v_bad) = 'collecting', 'T45 실패한 호가 롤백되지 않음';
  ASSERT (SELECT status FROM issue WHERE id = '00000000-0000-0000-0000-0000000000c1') = 'closing', 'T45 정상 호 미처리';
  ASSERT (SELECT close_attempts FROM issue WHERE id = v_bad) = 1, 'T45 실패 횟수 기록';
  ASSERT (SELECT close_error FROM issue WHERE id = v_bad) LIKE '%boom%', 'T45 실패 사유 기록';

  -- 5회까지 재시도, 이후에는 자동 재시도 제외 + close_failed 로 표시
  FOR k IN 2..5 LOOP
    PERFORM * FROM close_due_issues('2026-10-01 00:00:01+09');
  END LOOP;
  ASSERT (SELECT close_attempts FROM issue WHERE id = v_bad) = 5, 'T45 5회 시도';
  ASSERT (SELECT count(*) FROM close_due_issues('2026-10-01 00:00:01+09')) = 0, 'T45 5회 실패 호가 계속 재시도됨';
  ASSERT (SELECT current_step FROM v_issue_progress WHERE issue_id = v_bad) = 'close_failed', 'T45 close_failed 아님';
END $$;
ROLLBACK;

\echo T46 배치 진입점: 마감 + 새 호 생성, 같은 시각 재실행은 아무 일도 안 함
BEGIN;
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM run_monthly_batch('2026-10-01 00:00:01+09');
  ASSERT n = 2, 'T46 첫 실행 행 수=' || n;
  ASSERT EXISTS (SELECT 1 FROM run_monthly_batch('2026-10-01 00:00:02+09')) = false, 'T46 재실행이 일을 함';
  ASSERT (SELECT status FROM issue WHERE period_start = '2026-09-01') = 'closing', 'T46 9월호 closing';
  ASSERT (SELECT status FROM issue WHERE period_start = '2026-10-01') = 'collecting', 'T46 10월호 collecting';
END $$;
ROLLBACK;

\echo T50 재오픈(S1): close_at 필수(미래), 이전 조판 무효화, 바로 다시 닫히지 않음, 재마감 시 재조판 큐 진입
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1'; v_run uuid;
BEGIN
  PERFORM * FROM close_due_issues('2026-10-01 00:00:01+09');
  ASSERT (SELECT status FROM issue WHERE id = v) = 'closing', 'T50 precondition';
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (v, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'done') RETURNING id INTO v_run;

  BEGIN
    PERFORM change_issue_status(v, 'collecting');
    RAISE EXCEPTION 'T50 failed: close_at 없이 재오픈됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM change_issue_status(v, 'collecting', NULL, NULL, now() - interval '1 hour');
    RAISE EXCEPTION 'T50 failed: 과거 close_at 으로 재오픈됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  PERFORM change_issue_status(v, 'collecting', NULL, '재오픈', now() + interval '1 day');
  ASSERT (SELECT status FROM issue WHERE id = v) = 'collecting', 'T50 재오픈 상태';
  ASSERT (SELECT closed_at IS NULL FROM issue WHERE id = v), 'T50 closed_at 초기화';
  ASSERT (SELECT close_at > now() FROM issue WHERE id = v), 'T50 close_at 연장';
  ASSERT (SELECT status FROM layout_run WHERE id = v_run) = 'superseded', 'T50 조판 무효화';
  ASSERT (SELECT count(*) FROM close_due_issues(now())) = 0, 'T50 재오픈 직후 배치가 다시 닫음';

  PERFORM * FROM close_due_issues(now() + interval '2 days');
  ASSERT (SELECT status FROM issue WHERE id = v) = 'closing', 'T50 재마감';
  ASSERT (SELECT count(*) FROM v_compose_queue WHERE issue_id = v) = 1, 'T50 재마감 호가 조판 큐에 없음';
END $$;
ROLLBACK;

\echo T53 상태 직접 변경 차단(S3)
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1';
BEGIN
  BEGIN
    UPDATE issue SET status = 'printed' WHERE id = v;
    RAISE EXCEPTION 'T53 failed: status 직접 변경됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  ASSERT (SELECT status FROM issue WHERE id = v) = 'collecting', 'T53 상태가 바뀜';
  UPDATE issue SET title = '새 제목' WHERE id = v;
  ASSERT (SELECT title FROM issue WHERE id = v) = '새 제목', 'T53 다른 컬럼은 수정 가능해야 함';
  PERFORM change_issue_status(v, 'closing');
  BEGIN
    UPDATE issue SET status = 'review' WHERE id = v;
    RAISE EXCEPTION 'T53 failed: 함수 호출 뒤에도 직접 변경됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;
ROLLBACK;

\echo T55 전이 사전조건(S5): review/approved/printed 는 실체가 있어야 함
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1';
        u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        v_run uuid; v_p1 uuid; v_p2 uuid; v_job uuid; s bigint;
BEGIN
  PERFORM change_issue_status(v, 'closing');
  BEGIN
    PERFORM change_issue_status(v, 'review');
    RAISE EXCEPTION 'T55 failed: 조판 없이 review';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status, created_at)
  VALUES (v, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'failed', '2026-10-01 09:00+09');
  BEGIN
    PERFORM change_issue_status(v, 'review');
    RAISE EXCEPTION 'T55 failed: 실패한 조판만 있는데 review';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- 시각은 형식상 명시한 것이다. "최신"은 seq(삽입 순서)로 정해지므로 시각과 무관하다 (T63 참고)
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status, created_at)
  VALUES (v, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 2, 'h', 'done', '2026-10-01 09:30+09') RETURNING id INTO v_run;
  INSERT INTO page (run_id, page_no) VALUES (v_run, 1) RETURNING id INTO v_p1;
  INSERT INTO page (run_id, page_no) VALUES (v_run, 2) RETURNING id INTO v_p2;
  PERFORM change_issue_status(v, 'review');

  BEGIN
    PERFORM change_issue_status(v, 'approved');
    RAISE EXCEPTION 'T55 failed: 승인 0건인데 approved';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO approval (issue_id, page_id, user_id, status, created_at) VALUES
    (v, v_p1, u1, 'approved',          '2026-10-01 10:00+09'),
    (v, v_p2, u1, 'changes_requested', '2026-10-01 10:05+09');
  BEGIN
    PERFORM change_issue_status(v, 'approved');
    RAISE EXCEPTION 'T55 failed: 수정 요청이 남았는데 approved';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO approval (issue_id, page_id, user_id, status, created_at)
  VALUES (v, v_p2, u1, 'approved', '2026-10-01 11:00+09');
  PERFORM change_issue_status(v, 'approved');
  PERFORM change_issue_status(v, 'printing');

  BEGIN
    PERFORM change_issue_status(v, 'printed');
    RAISE EXCEPTION 'T55 failed: 인쇄 작업 없이 printed';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO print_job (issue_id, run_id, override_seq, status)
  VALUES (v, v_run, 0, 'rendering') RETURNING id INTO v_job;
  BEGIN
    PERFORM change_issue_status(v, 'printed');
    RAISE EXCEPTION 'T55 failed: 렌더링 중인 작업으로 printed';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE print_job SET status = 'ready' WHERE id = v_job;
  PERFORM change_issue_status(v, 'printed');
  ASSERT (SELECT status FROM issue WHERE id = v) = 'printed', 'T55 printed';
END $$;
ROLLBACK;

\echo T55b 전이 사전조건: 인쇄 작업이 최신 수정 번호보다 오래된 것이면 printed 불가
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1';
        u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        u2 constant uuid := '00000000-0000-0000-0000-000000000002';
        v_run uuid; v_p1 uuid; v_job uuid; s bigint;
BEGIN
  PERFORM change_issue_status(v, 'closing');
  INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash, status)
  VALUES (v, '00000000-0000-0000-0000-0000000000a1', '0.1.0', 1, 'h', 'done') RETURNING id INTO v_run;
  INSERT INTO page (run_id, page_no) VALUES (v_run, 1) RETURNING id INTO v_p1;
  PERFORM change_issue_status(v, 'review');
  INSERT INTO override (issue_id, run_id, target_type, target_id, op, author_id)
  VALUES (v, v_run, 'page', v_p1, '{"op":"move"}', u2);
  SELECT max(seq) INTO s FROM override WHERE run_id = v_run;
  INSERT INTO approval (issue_id, page_id, user_id, status) VALUES (v, v_p1, u1, 'approved');
  ASSERT (SELECT override_seq FROM approval WHERE page_id = v_p1) = s, 'T55b 승인이 최신 수정 번호를 기록';
  PERFORM change_issue_status(v, 'approved');
  PERFORM change_issue_status(v, 'printing');

  INSERT INTO print_job (issue_id, run_id, override_seq, status)
  VALUES (v, v_run, s - 1, 'ready') RETURNING id INTO v_job;
  BEGIN
    PERFORM change_issue_status(v, 'printed');
    RAISE EXCEPTION 'T55b failed: 오래된 버전의 인쇄 작업으로 printed';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE print_job SET override_seq = s WHERE id = v_job;
  PERFORM change_issue_status(v, 'printed');
END $$;
ROLLBACK;

\echo T56 미발행 호: 강제 발행 / 재오픈(close_at 필요)
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1';
BEGIN
  PERFORM change_issue_status(v, 'skipped', NULL, '미달');
  PERFORM change_issue_status(v, 'closing', NULL, '관리자 강제 발행');
  ASSERT (SELECT status FROM issue WHERE id = v) = 'closing', 'T56 강제 발행';
END $$;
ROLLBACK;
BEGIN;
DO $$
DECLARE v constant uuid := '00000000-0000-0000-0000-0000000000c1';
BEGIN
  PERFORM change_issue_status(v, 'skipped');
  BEGIN
    PERFORM change_issue_status(v, 'collecting');
    RAISE EXCEPTION 'T56 failed: close_at 없이 재오픈';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  PERFORM change_issue_status(v, 'collecting', NULL, NULL, now() + interval '3 days');
  ASSERT (SELECT status FROM issue WHERE id = v) = 'collecting', 'T56 재오픈';
END $$;
ROLLBACK;

\echo T58 활동 중인 구성원이 0명이어도 진행률은 NULL 이 아님(S6)
BEGIN;
DO $$ BEGIN
  UPDATE family_member SET left_at = now();
  ASSERT (SELECT progress_pct FROM v_issue_progress WHERE issue_id = '00000000-0000-0000-0000-0000000000c1') = 0, 'T58 pct';
END $$;
ROLLBACK;

\echo T59 배치 한 번에 처리하는 건수 제한: 마감이 남았으면 호 생성은 미루고, 다 끝나면 생성
BEGIN;
DO $$
DECLARE a int; b int; c int; d int; e int; f int;
BEGIN
  INSERT INTO issue (group_id, title, period_start, period_end, close_at, template_id,
                     min_photos, max_photos, min_pages, max_pages, page_multiple)
  SELECT '00000000-0000-0000-0000-0000000000d1', 'old' || m, make_date(2026, m, 1),
         (make_date(2026, m, 1) + interval '1 month - 1 day')::date,
         (make_date(2026, m, 1) + interval '1 month')::timestamptz,
         '00000000-0000-0000-0000-0000000000a1', 15, 60, 8, 40, 4
    FROM generate_series(5, 7) m;      -- 마감이 지난 호 3개 + 시드 호 1개 = 4건

  SELECT count(*) FILTER (WHERE o_step = 'close'), count(*) FILTER (WHERE o_step = 'open')
    INTO a, b FROM run_monthly_batch('2026-10-01 00:00:01+09', 2);
  ASSERT a = 2 AND b = 0, format('T59 1회차 close=%s open=%s', a, b);

  SELECT count(*) FILTER (WHERE o_step = 'close'), count(*) FILTER (WHERE o_step = 'open')
    INTO c, d FROM run_monthly_batch('2026-10-01 00:00:01+09', 2);
  ASSERT c = 2 AND d = 0, format('T59 2회차 close=%s open=%s', c, d);

  SELECT count(*) FILTER (WHERE o_step = 'close'), count(*) FILTER (WHERE o_step = 'open')
    INTO e, f FROM run_monthly_batch('2026-10-01 00:00:01+09', 2);
  ASSERT e = 0 AND f = 1, format('T59 3회차 close=%s open=%s', e, f);

  ASSERT (SELECT count(*) FROM issue WHERE status = 'collecting' AND period_start < '2026-10-01') = 0, 'T59 마감 안 된 호가 남음';
END $$;
ROLLBACK;
