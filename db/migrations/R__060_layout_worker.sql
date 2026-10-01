-- [layout 모듈] 조판 워커 임대 계약 / 조판 회차 부여 / 조판 큐
-- Flyway 반복 마이그레이션: 내용이 바뀌면 다음 migrate 때 자동 재적용된다. 파일명 번호 순서로 적용된다.
-- 소유 테이블/의존 방향은 docs/architecture.md 와 db/tests/architecture.sql 참고.

-- 조판 워커 계약: 임대(lease) 기반 작업 큐
--
-- 워커 흐름
--   1. claim_compose_job(worker)   : 마감된 호 1건을 가져가 layout_run(status=running)을 만든다. 없으면 0행.
--   2. (조판 계산 중) heartbeat_compose_job(run, worker)  : 주기적으로 호출. false 면 내 작업이 무효가 된 것 -> 즉시 중단
--   3. 한 트랜잭션 안에서 page/placement 를 저장한 뒤 complete_compose_job(...)
--        - 아직 내 작업이 유효할 때만 done 으로 바꾸고, 호를 closing -> review 로 넘긴다.
--        - 무효(superseded/reaped/탈취)면 예외 -> 저장하던 page/placement 까지 전부 롤백된다.
--   4. 실패하면 fail_compose_job(run, worker, 사유). 3번 실패한 호는 큐에서 빠지고 compose_failed 로 표시된다.
--
-- 워커가 죽으면: running 인데 heartbeat 가 timeout(기본 5분) 넘게 멈춘 실행을 claim 때 자동으로 failed 처리하고
--               다른 워커가 이어받는다 (이전 워커가 뒤늦게 살아나도 complete 가 거부된다).

-- =========================================================
-- 1. 오래된 running 정리
-- =========================================================
CREATE OR REPLACE FUNCTION reap_stale_compose_jobs(
    p_now timestamptz DEFAULT now(), p_timeout interval DEFAULT interval '5 minutes')
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    n int;
BEGIN
    UPDATE layout_run
       SET status = 'failed', finished_at = p_now,
           log = COALESCE(log || E'\n', '') || format('worker %s lost: no heartbeat since %s', locked_by, heartbeat_at)
     WHERE status = 'running' AND heartbeat_at < p_now - p_timeout;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

-- =========================================================
-- 2. 작업 가져가기
--    조건은 v_compose_queue 와 같다 (잠금 때문에 뷰를 쓰지 못해 복제했으므로, 바꿀 때는 둘을 같이 바꿀 것)
--    FOR UPDATE SKIP LOCKED 라서 여러 워커가 동시에 불러도 같은 호를 받지 않는다.
-- =========================================================
CREATE OR REPLACE FUNCTION claim_compose_job(
    p_worker text, p_algorithm_version text,
    p_timeout interval DEFAULT interval '5 minutes', p_now timestamptz DEFAULT now())
RETURNS TABLE (o_run_id uuid, o_issue_id uuid, o_seed bigint, o_attempt int)
LANGUAGE plpgsql AS $$
DECLARE
    v_issue   uuid;
    v_tpl     uuid;
    v_attempt int;
    v_seed    bigint;
    v_run     uuid;
BEGIN
    PERFORM reap_stale_compose_jobs(p_now, p_timeout);

    SELECT i.id, i.template_id INTO v_issue, v_tpl
      FROM issue i
     WHERE i.status = 'closing'
       AND NOT EXISTS (SELECT 1 FROM layout_run lr
                        WHERE lr.issue_id = i.id AND lr.status IN ('queued','running','done'))
       AND (SELECT count(*) FROM layout_run lr
             WHERE lr.issue_id = i.id AND lr.status = 'failed') < 3
     ORDER BY i.closed_at, i.id
     LIMIT 1
       FOR UPDATE OF i SKIP LOCKED;

    IF v_issue IS NULL THEN
        RETURN;
    END IF;

    SELECT count(*) + 1 INTO v_attempt FROM layout_run WHERE issue_id = v_issue AND status = 'failed';
    v_seed := floor(random() * 2147483647)::bigint;

    INSERT INTO layout_run (issue_id, template_id, algorithm_version, seed, input_snapshot_hash,
                            status, locked_by, locked_at, heartbeat_at, started_at, attempts)
    VALUES (v_issue, v_tpl, p_algorithm_version, v_seed, '',   -- 입력 해시는 complete 때 확정
            'running', p_worker, p_now, p_now, p_now, v_attempt)
    RETURNING id INTO v_run;

    RETURN QUERY SELECT v_run, v_issue, v_seed, v_attempt;
END $$;

-- =========================================================
-- 3. 하트비트: false 면 이 작업은 더 이상 내 것이 아니다 (superseded / reaped / 다른 워커가 인수)
-- =========================================================
CREATE OR REPLACE FUNCTION heartbeat_compose_job(
    p_run uuid, p_worker text, p_now timestamptz DEFAULT now())
RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE layout_run SET heartbeat_at = p_now
     WHERE id = p_run AND status = 'running' AND locked_by = p_worker;
    RETURN FOUND;
END $$;

-- =========================================================
-- 4. 완료: 조건부 갱신 + 호를 review 로 전환 (같은 트랜잭션)
--    무효가 된 작업이면 예외 -> 호출한 트랜잭션 전체 롤백
-- =========================================================
CREATE OR REPLACE FUNCTION complete_compose_job(
    p_run uuid, p_worker text, p_input_hash text, p_score real DEFAULT NULL,
    p_report jsonb DEFAULT NULL, p_input_ref text DEFAULT NULL, p_now timestamptz DEFAULT now())
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_issue uuid;
BEGIN
    UPDATE layout_run
       SET status = 'done', finished_at = p_now, heartbeat_at = p_now,
           input_snapshot_hash = p_input_hash, score = p_score, report = p_report, input_ref = p_input_ref
     WHERE id = p_run AND status = 'running' AND locked_by = p_worker
    RETURNING issue_id INTO v_issue;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'compose job % is no longer running for worker % (superseded, reaped or taken over)',
            p_run, p_worker;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM page WHERE run_id = p_run) THEN
        RAISE EXCEPTION 'compose job % produced no pages', p_run;
    END IF;

    PERFORM change_issue_status(v_issue, 'review', NULL, format('자동 조판 완료 (run #%s)',
            (SELECT run_no FROM layout_run WHERE id = p_run)));
END $$;

-- =========================================================
-- 5. 실패 보고 (내 작업이 아직 유효할 때만 기록, 아니면 조용히 false)
-- =========================================================
CREATE OR REPLACE FUNCTION fail_compose_job(
    p_run uuid, p_worker text, p_error text, p_now timestamptz DEFAULT now())
RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE layout_run
       SET status = 'failed', finished_at = p_now, log = left(p_error, 2000)
     WHERE id = p_run AND status = 'running' AND locked_by = p_worker;
    RETURN FOUND;
END $$;

-- =========================================================
-- 6. 운영자 조치: 3번 실패해 멈춘 호를 다시 시도하게 함 (실패 기록은 superseded 로 보존)
-- =========================================================
CREATE OR REPLACE FUNCTION reset_compose_failures(p_issue uuid) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    n int;
BEGIN
    UPDATE layout_run SET status = 'superseded' WHERE issue_id = p_issue AND status = 'failed';
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

-- =========================================================
-- 5. 조판 회차(run_no) 자동 부여: 호별 1, 2, 3 ...
--    같은 호에 대한 동시 삽입은 어드바이저리 락으로 직렬화 (호 행 잠금은 업로드/마감과 엉키므로 쓰지 않음)
-- =========================================================
CREATE OR REPLACE FUNCTION layout_run_assign_no() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.run_no IS NULL THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('layout_run:' || NEW.issue_id::text, 0));
        SELECT COALESCE(max(run_no), 0) + 1 INTO NEW.run_no FROM layout_run WHERE issue_id = NEW.issue_id;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_layout_run_no ON layout_run;
CREATE TRIGGER trg_layout_run_no BEFORE INSERT ON layout_run
    FOR EACH ROW EXECUTE FUNCTION layout_run_assign_no();

-- =========================================================
-- 4. 조판 워커용 큐: 마감됐는데 아직 조판이 시작/완료되지 않은 호
--    superseded(재오픈/재조판으로 무효가 된 실행)는 무시하므로 다시 마감된 호는 새로 조판된다.
--    실패 3회 이상이면 자동 재시도를 멈춘다 (사람이 확인해야 함 -> current_step=compose_failed)
--    워커는 SELECT ... FOR UPDATE SKIP LOCKED 로 한 건씩 가져가 layout_run 을 만든다.
--    저장 직전에 자기 layout_run 이 superseded 가 아닌지 확인할 것.
-- =========================================================
CREATE OR REPLACE VIEW v_compose_queue AS
SELECT i.id AS issue_id, i.closed_at
  FROM issue i
 WHERE i.status = 'closing'
   AND NOT EXISTS (SELECT 1 FROM layout_run lr
                    WHERE lr.issue_id = i.id AND lr.status IN ('queued','running','done'))
   AND (SELECT count(*) FROM layout_run lr
         WHERE lr.issue_id = i.id AND lr.status = 'failed') < 3;

-- =========================================================
-- 정합성 가드: 배치(placement)에는 이 호에서 선별된(issue_media) 사진과 이 호의 텍스트만 올 수 있다
--   다른 호(다른 가족 그룹일 수도 있다)의 사진, 또는 이 호에서 선별되지 않은 사진이 조판/인쇄에 섞이는 것을 막는다.
--   placement 는 호를 직접 갖지 않고 page -> layout_run 을 거치므로 외래키로 표현할 수 없다. (layout -> feed 방향의 읽기)
-- =========================================================
CREATE OR REPLACE FUNCTION guard_placement_same_issue() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_issue uuid;
BEGIN
    SELECT lr.issue_id INTO v_issue
      FROM page pg JOIN layout_run lr ON lr.id = pg.run_id
     WHERE pg.id = NEW.page_id;

    IF NEW.media_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM issue_media im
             WHERE im.issue_id = v_issue AND im.media_id = NEW.media_id AND im.selection_status = 'selected') THEN
        RAISE EXCEPTION 'placement: media % was not selected for the issue of page %', NEW.media_id, NEW.page_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.text_block_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM text_block WHERE id = NEW.text_block_id AND issue_id = v_issue) THEN
        RAISE EXCEPTION 'placement: text_block % does not belong to the issue of page %', NEW.text_block_id, NEW.page_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_placement_same_issue ON placement;
CREATE TRIGGER trg_placement_same_issue BEFORE INSERT OR UPDATE OF page_id, media_id, text_block_id ON placement
    FOR EACH ROW EXECUTE FUNCTION guard_placement_same_issue();
