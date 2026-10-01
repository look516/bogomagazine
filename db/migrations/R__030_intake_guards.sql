-- [intake 모듈] 업로드 가드(수집 중인 호에만 업로드) + 업로드 라우팅
-- Flyway 반복 마이그레이션: 내용이 바뀌면 다음 migrate 때 자동 재적용된다. 파일명 번호 순서로 적용된다.
-- 소유 테이블/의존 방향은 docs/architecture.md 와 db/tests/architecture.sql 참고.

-- 데이터 무결성 가드 (트리거) + 업로드 라우팅

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
-- 2. 업로드 라우팅: 그룹의 사진이 어느 호로 들어가야 하는가
--    마감 유예(close_day > 1) 동안은 호 두 개가 동시에 collecting 일 수 있다.
--      1순위: 촬영/게시 시각(그룹 타임존)이 기간에 속하는 collecting 호
--      2순위: 가장 이른 collecting 호 (전달이 닫혔으면 이번 달로 넘어감)
--    수집 중인 호가 없으면 NULL -> 앱은 사용자에게 "마감되었습니다"를 보여주고,
--    관리자가 필요하면 change_issue_status(호, 'collecting', ..., 새 close_at)로 재오픈한다.
-- =========================================================
CREATE OR REPLACE FUNCTION upload_target_issue(p_group uuid, p_ts timestamptz DEFAULT now())
RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT i.id
      FROM issue i
      JOIN publication p ON p.id = i.publication_id
      JOIN family_group g ON g.id = p.group_id
     WHERE g.id = p_group AND i.status = 'collecting'
     ORDER BY ((p_ts AT TIME ZONE g.timezone)::date BETWEEN i.period_start AND i.period_end) DESC,
              i.period_start
     LIMIT 1
$$;
