-- [intake 모듈] 업로드 가드(수집 중인 호에만 업로드)
-- Flyway 반복 마이그레이션: 내용이 바뀌면 다음 migrate 때 자동 재적용된다. 파일명 번호 순서로 적용된다.
-- 소유 테이블/의존 방향은 docs/architecture.md 와 db/tests/architecture.sql 참고.

-- 데이터 무결성 가드 (트리거): 수집 중인 호에만 업로드, 업로더/등록자는 그 호의 참여자

-- =========================================================
-- 1. 업로드 가드: 수집 중(collecting)인 호에만 사진/게시물을 넣을 수 있다.
--    FOR SHARE 로 호 행을 잠가 마감 배치(FOR UPDATE)와 직렬화한다.
--      - 배치가 먼저 잠그면: 업로드는 배치가 끝날 때까지 기다린 뒤 closing 을 보고 거부됨
--      - 업로드가 먼저면: 배치는 그 호를 건너뛰고(SKIP LOCKED) 다음 호출에서 처리
--    => 선별이 끝난 뒤에 들어온 사진이 조용히 누락되는 일이 없다.
--    마감 시각(close_at) 자체는 DB 가 강제하지 않는다. 배치가 호를 닫기 전까지는 받는다.
--    마감 시각을 엄격히 적용하려면 앱이 close_at 을 먼저 확인할 것.
-- =========================================================
CREATE OR REPLACE FUNCTION guard_issue_collecting() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_status text;
BEGIN
    SELECT status INTO v_status FROM issue WHERE id = NEW.issue_id FOR SHARE;
    IF v_status IS DISTINCT FROM 'collecting' THEN
        RAISE EXCEPTION 'issue % is not collecting (status=%): upload not allowed', NEW.issue_id, v_status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_media_collecting ON media;
CREATE TRIGGER trg_media_collecting BEFORE INSERT ON media
    FOR EACH ROW EXECUTE FUNCTION guard_issue_collecting();

DROP TRIGGER IF EXISTS trg_source_post_collecting ON source_post;
CREATE TRIGGER trg_source_post_collecting BEFORE INSERT ON source_post
    FOR EACH ROW EXECUTE FUNCTION guard_issue_collecting();

-- =========================================================
-- 2. 업로더 정합성 가드: 사진을 올리거나 게시물을 등록하는 사람은 그 호의 참여자(viewer 제외)여야 한다
--    issue_member 는 issues 모듈 소유지만, intake -> issues 방향의 읽기다.
-- =========================================================
CREATE OR REPLACE FUNCTION guard_media_uploader() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM issue_member
                    WHERE issue_id = NEW.issue_id AND user_id = NEW.uploader_id AND role <> 'viewer') THEN
        RAISE EXCEPTION 'media: user % is not a contributor of issue %', NEW.uploader_id, NEW.issue_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_media_uploader ON media;
CREATE TRIGGER trg_media_uploader BEFORE INSERT OR UPDATE OF issue_id, uploader_id ON media
    FOR EACH ROW EXECUTE FUNCTION guard_media_uploader();

CREATE OR REPLACE FUNCTION guard_source_post_contributor() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM issue_member
                    WHERE issue_id = NEW.issue_id AND user_id = NEW.contributor_id AND role <> 'viewer') THEN
        RAISE EXCEPTION 'source_post: user % is not a contributor of issue %', NEW.contributor_id, NEW.issue_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_source_post_contributor ON source_post;
CREATE TRIGGER trg_source_post_contributor BEFORE INSERT OR UPDATE OF issue_id, contributor_id ON source_post
    FOR EACH ROW EXECUTE FUNCTION guard_source_post_contributor();
