-- [issues 모듈] 월 마감 배치(호 생성/마감 처리/진입점)
-- Flyway 반복 마이그레이션: 내용이 바뀌면 다음 migrate 때 자동 재적용된다. 파일명 번호 순서로 적용된다.
-- 소유 테이블/의존 방향은 docs/architecture.md 와 db/tests/architecture.sql 참고.

-- 월 마감 배치
-- 스케줄러(앱 크론 또는 pg_cron)가 주기적으로(예: 30분마다) 호출한다. 여러 번 불려도 안전(멱등).
--
-- 한 번 호출 = 한 트랜잭션 = 마감 대상 최대 p_limit(기본 200)건.
-- 월초에 모든 그룹이 한꺼번에 마감되어도 트랜잭션이 길어지지 않도록, 호출자가 아래처럼 반복한다:
--     loop:
--         rows = SELECT * FROM run_monthly_batch();     -- 매번 별도 트랜잭션
--         break if rows 중 o_action IN ('closing','skipped') 가 0건
--     (error 만 남았다면 더 돌려도 소용없다. 실패 호는 5회까지만 자동 재시도된다.)
-- 마감 대상이 p_limit 미만으로 남았을 때에만 "이번 달 호 생성"까지 수행한다.
--
-- pg_cron 예 (한 번에 200건씩, 30분마다):
--     SELECT cron.schedule('monthly-batch', '*/30 * * * *', $$SELECT * FROM run_monthly_batch()$$);
--
-- 하는 일
--   1. close_due_issues : 마감 시각이 지난 collecting 호를 closing(또는 skipped)으로 넘김
--   2. open_monthly_issues : 그룹별로 "이번 달" 호가 없으면 생성 (그룹 타임존 기준)
-- 조판은 여기서 하지 않는다. 조판 워커가 v_compose_queue 를 보고 처리한 뒤
-- change_issue_status(issue, 'review') 로 넘긴다.
--
-- 동시 실행: 마감은 FOR UPDATE SKIP LOCKED 라서 여러 러너가 동시에 돌아도 같은 호를 두 번 처리하지 않고,
--           호 생성은 UNIQUE(group_id, period_start) + ON CONFLICT 로 안전하다.

-- =========================================================
-- 1. 이번 달 호 생성
--    기간: 그룹 타임존 기준 이번 달 1일 ~ 말일
--    마감: 다음 달 close_day 일 00:00 (그룹 타임존)
-- =========================================================
CREATE OR REPLACE FUNCTION open_monthly_issues(p_now timestamptz DEFAULT now())
RETURNS TABLE (o_group_id uuid, o_issue_id uuid, o_created boolean)
LANGUAGE plpgsql AS $$
DECLARE
    g       record;
    v_tpl   record;
    v_start date;
    v_end   date;
    v_close timestamptz;
    v_issue uuid;
BEGIN
    FOR g IN SELECT * FROM family_group ORDER BY created_at, id LOOP
        v_start := date_trunc('month', p_now AT TIME ZONE g.timezone)::date;
        v_end   := (v_start + interval '1 month - 1 day')::date;
        v_close := ((v_start + interval '1 month')::date + (g.close_day - 1))::timestamp
                   AT TIME ZONE g.timezone;

        -- 템플릿: 직전 호가 쓴 템플릿의 최신 버전, 없으면 가장 최근 템플릿
        SELECT t.* INTO v_tpl FROM template t
         WHERE t.name = (SELECT t2.name FROM issue i JOIN template t2 ON t2.id = i.template_id
                          WHERE i.group_id = g.id ORDER BY i.period_start DESC LIMIT 1)
         ORDER BY t.version DESC LIMIT 1;
        IF v_tpl.id IS NULL THEN
            SELECT t.* INTO v_tpl FROM template t ORDER BY t.created_at DESC, t.version DESC LIMIT 1;
        END IF;
        CONTINUE WHEN v_tpl.id IS NULL;

        INSERT INTO issue (group_id, title, period_start, period_end, close_at, template_id,
                           min_photos, max_photos, min_pages, max_pages, page_multiple)
        VALUES (g.id,
                format('%s년 %s월호', extract(year FROM v_start)::int, extract(month FROM v_start)::int),
                v_start, v_end, v_close, v_tpl.id,
                v_tpl.min_photos, v_tpl.max_photos, v_tpl.min_pages, v_tpl.max_pages, v_tpl.page_multiple)
        ON CONFLICT (group_id, period_start) DO NOTHING
        RETURNING id INTO v_issue;

        o_group_id := g.id;
        o_created  := v_issue IS NOT NULL;
        IF v_issue IS NULL THEN
            SELECT i.id INTO v_issue FROM issue i
             WHERE i.group_id = g.id AND i.period_start = v_start;
        END IF;
        o_issue_id := v_issue;

        RETURN NEXT;
    END LOOP;
END $$;

-- =========================================================
-- 2. 마감 시각이 지난 호 처리 (최대 p_limit 건)
--    - select_media 가 이 그룹의 기간 안 게시물 사진으로 호별 후보(issue_media)를 만들고 선별한다
--    - select_media 실행 후 선별 사진이 min_photos 미만이면
--        auto_skip_below_min=true  -> skipped (미발행)
--        false                     -> closing 으로 진행
--    - 호 하나가 실패해도 다른 호는 계속 처리한다. 실패는 action='error' 로 보고하고
--      issue.close_attempts / close_error 에 기록한다. 5회 실패하면 자동 재시도에서 제외
--      (v_issue_progress.current_step = 'close_failed' 로 사람이 확인).
-- =========================================================
DROP FUNCTION IF EXISTS close_due_issues(timestamptz);

CREATE OR REPLACE FUNCTION close_due_issues(p_now timestamptz DEFAULT now(), p_limit int DEFAULT 200)
RETURNS TABLE (o_issue_id uuid, o_action text, o_detail text)
LANGUAGE plpgsql AS $$
DECLARE
    c record;
    r record;
BEGIN
    FOR c IN
        SELECT i.id, i.min_photos, g.auto_skip_below_min
          FROM issue i
          JOIN family_group g ON g.id = i.group_id
         WHERE i.status = 'collecting' AND i.close_at <= p_now AND i.close_attempts < 5
         ORDER BY i.close_at, i.id
         LIMIT p_limit
           FOR UPDATE OF i SKIP LOCKED
    LOOP
        BEGIN
            SELECT * INTO r FROM select_media(c.id);

            o_issue_id := c.id;
            IF r.short_by > 0 AND c.auto_skip_below_min THEN
                PERFORM change_issue_status(c.id, 'skipped', NULL,
                    format('자동 미발행: 선별 %s장 < 최소 %s장', r.selected, c.min_photos));
                o_action := 'skipped';
            ELSE
                PERFORM change_issue_status(c.id, 'closing', NULL, '자동 마감');
                o_action := 'closing';
            END IF;
            o_detail := format('selected=%s min=%s short_by=%s', r.selected, c.min_photos, r.short_by);
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            -- 위 블록의 변경은 롤백된 상태. 실패 기록만 남긴다 (행 잠금은 바깥 루프가 보유 중).
            UPDATE issue SET close_attempts = close_attempts + 1, close_error = left(SQLERRM, 500)
             WHERE id = c.id;
            o_issue_id := c.id;
            o_action := 'error';
            o_detail := SQLERRM;
            RETURN NEXT;
        END;
    END LOOP;
END $$;

-- =========================================================
-- 3. 배치 진입점
--    출력: 실제로 일어난 일만 (마감 처리, 새로 생성된 호)
--    마감 대상이 p_limit 건을 채웠으면 아직 남았을 수 있으므로 호 생성은 다음 호출로 미룬다.
-- =========================================================
DROP FUNCTION IF EXISTS run_monthly_batch(timestamptz);

CREATE OR REPLACE FUNCTION run_monthly_batch(p_now timestamptz DEFAULT now(), p_limit int DEFAULT 200)
RETURNS TABLE (o_step text, o_issue_id uuid, o_action text, o_detail text)
LANGUAGE plpgsql AS $$
DECLARE
    r record;
    n int := 0;
BEGIN
    FOR r IN SELECT * FROM close_due_issues(p_now, p_limit) LOOP
        n := n + 1;
        o_step := 'close'; o_issue_id := r.o_issue_id; o_action := r.o_action; o_detail := r.o_detail;
        RETURN NEXT;
    END LOOP;

    IF n < p_limit THEN
        FOR r IN SELECT * FROM open_monthly_issues(p_now) o WHERE o.o_created LOOP
            o_step := 'open'; o_issue_id := r.o_issue_id; o_action := 'created'; o_detail := NULL;
            RETURN NEXT;
        END LOOP;
    END IF;
END $$;
