-- [feed 모듈] 게시 가드 (마감된 기간에는 글/사진을 넣을 수 없고, 작성자는 활동 중인 구성원이어야 한다)
-- Flyway 반복 마이그레이션: 내용이 바뀌면 다음 migrate 때 자동 재적용된다. 파일명 번호 순서로 적용된다.
-- 소유 테이블/의존 방향은 docs/architecture.md 와 db/tests/architecture.sql 참고.


-- 이미 마감된(수집 중이 아닌) 호의 기간에 속하는 글/사진은 넣을 수 없다.
-- 호 행을 FOR SHARE 로 잠가 마감 배치(FOR UPDATE)와 직렬화한다.
--   - 배치가 먼저 잠그면: 게시는 배치가 끝날 때까지 기다린 뒤 closing 을 보고 거부됨
--   - 게시가 먼저면: 배치는 그 호를 건너뛰고(SKIP LOCKED) 다음 호출에서 처리
--   => 선별이 끝난 뒤에 들어온 글/사진이 조용히 누락되는 일이 없다.
-- 기간에 해당하는 호가 아직 만들어지지 않았으면(이번 달 배치가 돌기 전) 허용한다.
-- 마감 시각(close_at) 자체는 DB 가 강제하지 않는다. 배치가 호를 닫기 전까지는 받는다.
CREATE OR REPLACE FUNCTION assert_period_open(p_group uuid, p_ts timestamptz) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_status text;
BEGIN
    SELECT i.status INTO v_status
      FROM issue i JOIN family_group g ON g.id = i.group_id
     WHERE i.group_id = p_group
       AND (p_ts AT TIME ZONE g.timezone)::date BETWEEN i.period_start AND i.period_end
       FOR SHARE OF i;
    IF FOUND AND v_status <> 'collecting' THEN
        RAISE EXCEPTION 'the issue for this period is not collecting (status=%): posting not allowed', v_status
            USING ERRCODE = 'check_violation';
    END IF;
END $$;

-- 글: 작성자는 그 그룹에서 활동 중인 구성원이어야 하고, 마감된 기간에는 올릴 수 없다
CREATE OR REPLACE FUNCTION guard_post_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM assert_period_open(NEW.group_id, NEW.posted_at);
    IF NOT is_active_member(NEW.group_id, NEW.author_id) THEN
        RAISE EXCEPTION 'post: user % is not an active member of group %', NEW.author_id, NEW.group_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_post_insert ON post;
CREATE TRIGGER trg_post_insert BEFORE INSERT ON post
    FOR EACH ROW EXECUTE FUNCTION guard_post_insert();

-- 글의 날짜를 마감된 기간으로 옮길 수 없다 (날짜를 거슬러 올라가 마감된 호에 끼워 넣는 것을 막는다)
CREATE OR REPLACE FUNCTION guard_post_period_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM assert_period_open(NEW.group_id, NEW.posted_at);
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_post_period_update ON post;
CREATE TRIGGER trg_post_period_update BEFORE UPDATE OF posted_at, group_id ON post
    FOR EACH ROW EXECUTE FUNCTION guard_post_period_update();

-- 사진: 글이 속한 기간이 마감되었으면 붙일 수 없다
CREATE OR REPLACE FUNCTION guard_media_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_group uuid;
    v_ts    timestamptz;
BEGIN
    SELECT group_id, posted_at INTO v_group, v_ts FROM post WHERE id = NEW.post_id;
    IF FOUND THEN
        PERFORM assert_period_open(v_group, v_ts);
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_media_insert ON media;
CREATE TRIGGER trg_media_insert BEFORE INSERT ON media
    FOR EACH ROW EXECUTE FUNCTION guard_media_insert();
