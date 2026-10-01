-- [review 모듈] 승인 버전 기록 / 수정(override) 가드
-- Flyway 반복 마이그레이션: 내용이 바뀌면 다음 migrate 때 자동 재적용된다. 파일명 번호 순서로 적용된다.
-- 소유 테이블/의존 방향은 docs/architecture.md 와 db/tests/architecture.sql 참고.

-- =========================================================
-- 3. 승인 기록에 버전(조판 실행, 수정 번호)을 자동 기록
--    - run_id        : 페이지가 속한 조판 실행 (page_id 가 없으면 호의 최신 유효 실행)
--    - override_seq  : 승인 시점까지의 최신 수정 번호
--    조판 이후 이 페이지에 더 큰 seq 의 수정이 생기면 v_issue_progress 가 승인을 stale 로 센다.
-- =========================================================
CREATE OR REPLACE FUNCTION approval_fill_version() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_run_issue uuid;
    v_run_status text;
BEGIN
    IF NEW.run_id IS NULL THEN
        IF NEW.page_id IS NOT NULL THEN
            SELECT run_id INTO NEW.run_id FROM page WHERE id = NEW.page_id;
        ELSE
            SELECT id INTO NEW.run_id FROM layout_run
             WHERE issue_id = NEW.issue_id AND status <> 'superseded'
             ORDER BY seq DESC LIMIT 1;
        END IF;
    END IF;

    IF NEW.run_id IS NOT NULL THEN
        SELECT issue_id, status INTO v_run_issue, v_run_status FROM layout_run WHERE id = NEW.run_id;
        IF v_run_issue IS DISTINCT FROM NEW.issue_id THEN
            RAISE EXCEPTION 'approval: run % does not belong to issue %', NEW.run_id, NEW.issue_id
                USING ERRCODE = 'check_violation';
        END IF;
        IF v_run_status = 'superseded' THEN
            RAISE EXCEPTION 'approval: run % is superseded (재조판/재오픈으로 무효)', NEW.run_id
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    IF NEW.override_seq IS NULL THEN
        SELECT COALESCE(max(seq), 0) INTO NEW.override_seq FROM override WHERE run_id = NEW.run_id;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_approval_version ON approval;
CREATE TRIGGER trg_approval_version BEFORE INSERT ON approval
    FOR EACH ROW EXECUTE FUNCTION approval_fill_version();

-- =========================================================
-- 4. 수정(override) 가드
--    - review    : 허용
--    - approved  : 허용하되 호를 자동으로 review 로 되돌림 (수정된 페이지의 승인은 stale)
--    - 그 외     : 거부 (인쇄 진행 중/완료 후에는 수정 불가)
--    - superseded 조판 실행에 대한 수정은 거부
-- =========================================================
CREATE OR REPLACE FUNCTION override_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_status text;
    v_run_status text;
BEGIN
    SELECT status INTO v_status FROM issue WHERE id = NEW.issue_id FOR UPDATE;
    SELECT status INTO v_run_status FROM layout_run WHERE id = NEW.run_id;

    IF v_run_status = 'superseded' THEN
        RAISE EXCEPTION 'override: run % is superseded', NEW.run_id USING ERRCODE = 'check_violation';
    END IF;

    IF v_status = 'approved' THEN
        PERFORM change_issue_status(NEW.issue_id, 'review', NEW.author_id,
                                    '승인 후 수정이 발생하여 검토 단계로 복귀');
    ELSIF v_status IS DISTINCT FROM 'review' THEN
        RAISE EXCEPTION 'override not allowed while issue status is %', v_status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_override_guard ON override;
CREATE TRIGGER trg_override_guard BEFORE INSERT ON override
    FOR EACH ROW EXECUTE FUNCTION override_guard();

-- =========================================================
-- 5. 정합성 가드: 승인/수정의 작성자는 그 호의 그룹에서 활동 중인 구성원이어야 한다
--    (누가 승인할 수 있는지의 정책은 TODO.md 의 "다중 승인 정책"에서 정한다. 여기서는 그룹 밖 사람만 막는다)
--    TG_ARGV[0] = 작성자 컬럼 이름 (approval: user_id, override: author_id)
-- =========================================================
CREATE OR REPLACE FUNCTION guard_review_author() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_group uuid;
    v_user  uuid := (to_jsonb(NEW) ->> TG_ARGV[0])::uuid;
BEGIN
    SELECT group_id INTO v_group FROM issue WHERE id = NEW.issue_id;
    IF NOT is_active_member(v_group, v_user) THEN
        RAISE EXCEPTION '%: user % is not an active member of the group of issue %', TG_TABLE_NAME, v_user, NEW.issue_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_approval_author ON approval;
CREATE TRIGGER trg_approval_author BEFORE INSERT ON approval
    FOR EACH ROW EXECUTE FUNCTION guard_review_author('user_id');

DROP TRIGGER IF EXISTS trg_override_author ON override;
CREATE TRIGGER trg_override_author BEFORE INSERT ON override
    FOR EACH ROW EXECUTE FUNCTION guard_review_author('author_id');
