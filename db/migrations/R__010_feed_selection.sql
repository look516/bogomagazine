-- [feed 모듈] 호별 사진 선별(select_media)
-- Flyway 반복 마이그레이션: 내용이 바뀌면 다음 migrate 때 자동 재적용된다. 파일명 번호 순서로 적용된다.
-- 소유 테이블/의존 방향은 docs/architecture.md 와 db/tests/architecture.sql 참고.


-- 사진 선별: 이 호의 기간 안 게시물 사진으로 후보(issue_media)를 만들고, issue_media.selection_status 를
--           selected / excluded_auto 로 채운다. 여러 번 불러도 같은 결과다.
-- 후보: 이 호의 그룹이 올린 글(삭제되지 않은) 중 posted_at(그룹 타임존 날짜)이 호의 기간에 속하는 글의 사진
-- 규칙 (순서대로)
--   1. 사용자가 뺀 사진(media.excluded)과 삭제된 글의 사진은 excluded_manual. 권리 문제(rights_ok=false)는 제외.
--   2. 저화질(quality_score < 0.3)은 제외. 단 사용자가 "꼭 넣기"(media.pinned)한 사진은 예외.
--   3. 유사 사진(phash 해밍거리 <= 8)은 점수 높은 한 장만 남긴다. pinned 우선.
--   4. 하루 상한(day_cap)을 넘는 사진은 점수 낮은 순으로 제외 (특정 날짜 편중 완화). pinned 는 예외.
--   5. 전체 max_photos 를 넘으면 점수 낮은 순으로 제외. pinned 는 항상 포함.
--   6. min_photos 에 못 미치면 3~5단계에서 탈락한 사진 중 점수 높은 순으로 채움.
--      그래도 모자라면 short_by > 0 으로 보고 (조판 쪽에서 큰 사진/여백 레이아웃으로 대응).
-- 점수 = quality_score (댓글/좋아요가 없는 피드라 반응 점수는 쓰지 않는다)

-- bit_count 는 PostgreSQL 14+ (문자열 변환 방식보다 약 4.5배 빠름: 3,000장 기준 2.3s -> 0.5s)
CREATE OR REPLACE FUNCTION hamming64(a bigint, b bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT bit_count((a # b)::bit(64))::int $$;

CREATE OR REPLACE FUNCTION select_media(p_issue uuid)
RETURNS TABLE (selected int, excluded_auto int, short_by int)
LANGUAGE plpgsql AS $$
DECLARE
    v_min   int;
    v_max   int;
    v_days  int;
    v_cap   int;
    v_have  int;
    v_group uuid;
    v_tz    text;
    v_start date;
    v_end   date;
BEGIN
    SELECT i.min_photos, i.max_photos, (i.period_end - i.period_start + 1),
           i.group_id, g.timezone, i.period_start, i.period_end
      INTO v_min, v_max, v_days, v_group, v_tz, v_start, v_end
      FROM issue i JOIN family_group g ON g.id = i.group_id
     WHERE i.id = p_issue;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'issue % not found', p_issue;
    END IF;
    v_cap := ceil(v_max::numeric / v_days * 2);

    -- 같은 트랜잭션에서 반복 호출해도 충돌하지 않게 정리
    DROP TABLE IF EXISTS t_scored, t_elig, t_dedup, t_capped;

    -- 후보 만들기 (이미 있는 행은 그대로 둔다)
    INSERT INTO issue_media (issue_id, media_id, group_id)
    SELECT p_issue, m.id, v_group
      FROM media m JOIN post p ON p.id = m.post_id
     WHERE p.group_id = v_group
       AND (p.posted_at AT TIME ZONE v_tz)::date BETWEEN v_start AND v_end
    ON CONFLICT (issue_id, media_id) DO NOTHING;

    -- 이전 선별 결과 초기화 (사용자가 뺀 사진/삭제된 글의 사진은 excluded_manual)
    UPDATE issue_media im
       SET selection_status = CASE WHEN m.excluded OR p.deleted_at IS NOT NULL THEN 'excluded_manual' ELSE 'candidate' END,
           selection_score = NULL
      FROM media m JOIN post p ON p.id = m.post_id
     WHERE m.id = im.media_id AND im.issue_id = p_issue;

    CREATE TEMP TABLE t_scored ON COMMIT DROP AS
    SELECT m.id, m.pinned, m.phash, m.quality_score, m.rights_ok,
           (p.posted_at AT TIME ZONE v_tz)::date AS day,
           COALESCE(m.quality_score, 0)::numeric AS score
      FROM issue_media im
      JOIN media m ON m.id = im.media_id
      JOIN post p ON p.id = m.post_id
     WHERE im.issue_id = p_issue AND im.selection_status <> 'excluded_manual';

    UPDATE issue_media im SET selection_score = round(s.score, 4)::real
      FROM t_scored s WHERE s.id = im.media_id AND im.issue_id = p_issue;

    -- 1~2단계: 자격
    CREATE TEMP TABLE t_elig ON COMMIT DROP AS
    SELECT * FROM t_scored WHERE rights_ok AND (pinned OR quality_score >= 0.3);

    -- 3단계: 중복 제거
    CREATE TEMP TABLE t_dedup ON COMMIT DROP AS
    SELECT e.* FROM t_elig e
     WHERE e.pinned OR NOT EXISTS (
            SELECT 1 FROM t_elig o
             WHERE o.id <> e.id
               AND hamming64(o.phash, e.phash) <= 8
               AND (o.pinned, o.score, o.id) > (e.pinned, e.score, e.id));

    -- 4단계: 하루 상한
    CREATE TEMP TABLE t_capped ON COMMIT DROP AS
    SELECT * FROM (
        SELECT d.*, row_number() OVER (PARTITION BY day ORDER BY pinned DESC, score DESC) AS rn
          FROM t_dedup d) x
     WHERE pinned OR rn <= v_cap;

    -- 5단계: 전체 상한
    UPDATE issue_media im SET selection_status = 'selected'
      FROM (SELECT id, pinned, row_number() OVER (ORDER BY pinned DESC, score DESC) AS g
              FROM t_capped) f
     WHERE im.issue_id = p_issue AND im.media_id = f.id AND (f.pinned OR f.g <= v_max);

    -- 6단계: 최소 수량 채우기 (중복·저화질·권리 문제는 채우지 않음)
    SELECT count(*) INTO v_have FROM issue_media
     WHERE issue_id = p_issue AND selection_status = 'selected';
    IF v_have < v_min THEN
        UPDATE issue_media im SET selection_status = 'selected'
          FROM (SELECT d.id FROM t_dedup d
                 WHERE NOT EXISTS (SELECT 1 FROM issue_media x
                                    WHERE x.issue_id = p_issue AND x.media_id = d.id
                                      AND x.selection_status = 'selected')
                 ORDER BY d.score DESC
                 LIMIT v_min - v_have) f
         WHERE im.issue_id = p_issue AND im.media_id = f.id;
    END IF;

    UPDATE issue_media SET selection_status = 'excluded_auto'
     WHERE issue_id = p_issue AND selection_status = 'candidate';

    RETURN QUERY
    SELECT count(*) FILTER (WHERE im.selection_status = 'selected')::int,
           count(*) FILTER (WHERE im.selection_status = 'excluded_auto')::int,
           greatest(0, v_min - count(*) FILTER (WHERE im.selection_status = 'selected'))::int
      FROM issue_media im WHERE im.issue_id = p_issue;
END $$;
