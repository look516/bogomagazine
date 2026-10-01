-- [intake 모듈] 사진 선별(select_media)
-- Flyway 반복 마이그레이션: 내용이 바뀌면 다음 migrate 때 자동 재적용된다. 파일명 번호 순서로 적용된다.
-- 소유 테이블/의존 방향은 docs/architecture.md 와 db/tests/architecture.sql 참고.

-- 사진 선별: media.selection_status 를 selected / excluded_auto 로 채운다.
-- 규칙 (순서대로)
--   1. excluded_manual 은 건드리지 않는다. 권리 미확인(rights_ok=false)은 제외.
--   2. 저화질(quality_score < 0.3)은 제외. 단 pinned 는 예외.
--   3. 유사 사진(phash 해밍거리 <= 8)은 점수 높은 한 장만 남긴다. pinned 우선.
--   4. 하루 상한(day_cap)을 넘는 사진은 점수 낮은 순으로 제외 (시간 편중 완화). pinned 는 예외.
--   5. 전체 max_photos 를 넘으면 점수 낮은 순으로 제외. pinned 는 항상 포함.
--   6. min_photos 에 못 미치면 3~5단계에서 탈락한 사진 중 점수 높은 순으로 채움.
--      그래도 모자라면 short_by > 0 으로 보고 (조판 쪽에서 큰 사진/여백 레이아웃으로 대응).
-- 점수 = 0.6 * quality + 0.4 * 반응(좋아요) 백분위

-- bit_count 는 PostgreSQL 14+ (문자열 변환 방식보다 약 4.5배 빠름: 3,000장 기준 2.3s -> 0.5s)
CREATE OR REPLACE FUNCTION hamming64(a bigint, b bigint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT bit_count((a # b)::bit(64))::int $$;

CREATE OR REPLACE FUNCTION select_media(p_issue uuid)
RETURNS TABLE (selected int, excluded_auto int, short_by int)
LANGUAGE plpgsql AS $$
DECLARE
    v_min  int;
    v_max  int;
    v_days int;
    v_cap  int;
    v_have int;
BEGIN
    SELECT min_photos, max_photos, (period_end - period_start + 1)
      INTO v_min, v_max, v_days
      FROM issue WHERE id = p_issue;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'issue % not found', p_issue;
    END IF;
    v_cap := ceil(v_max::numeric / v_days * 2);

    -- 같은 트랜잭션에서 반복 호출해도 충돌하지 않게 정리
    DROP TABLE IF EXISTS t_scored, t_elig, t_dedup, t_capped;

    UPDATE media SET selection_status = 'candidate', selection_score = NULL
     WHERE issue_id = p_issue AND selection_status <> 'excluded_manual';

    CREATE TEMP TABLE t_scored ON COMMIT DROP AS
    SELECT m.id, m.pinned, m.phash, m.quality_score, m.rights_ok,
           COALESCE(sp.posted_at, m.taken_at, m.created_at)::date AS day,
           0.6 * COALESCE(m.quality_score, 0)
             + 0.4 * percent_rank() OVER (ORDER BY COALESCE((sp.engagement->>'likes')::int, 0)) AS score
      FROM media m
      LEFT JOIN source_post sp ON sp.id = m.source_post_id
     WHERE m.issue_id = p_issue AND m.selection_status <> 'excluded_manual';

    UPDATE media m SET selection_score = round(s.score::numeric, 4)::real
      FROM t_scored s WHERE s.id = m.id;

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
    UPDATE media m SET selection_status = 'selected'
      FROM (SELECT id, pinned, row_number() OVER (ORDER BY pinned DESC, score DESC) AS g
              FROM t_capped) f
     WHERE m.id = f.id AND (f.pinned OR f.g <= v_max);

    -- 6단계: 최소 수량 채우기 (중복·저화질·권리 미확인은 채우지 않음)
    SELECT count(*) INTO v_have FROM media
     WHERE issue_id = p_issue AND selection_status = 'selected';
    IF v_have < v_min THEN
        UPDATE media m SET selection_status = 'selected'
          FROM (SELECT d.id FROM t_dedup d
                 WHERE NOT EXISTS (SELECT 1 FROM media x
                                    WHERE x.id = d.id AND x.selection_status = 'selected')
                 ORDER BY d.score DESC
                 LIMIT v_min - v_have) f
         WHERE m.id = f.id;
    END IF;

    UPDATE media SET selection_status = 'excluded_auto'
     WHERE issue_id = p_issue AND selection_status = 'candidate';

    RETURN QUERY
    SELECT count(*) FILTER (WHERE m.selection_status = 'selected')::int,
           count(*) FILTER (WHERE m.selection_status = 'excluded_auto')::int,
           greatest(0, v_min - count(*) FILTER (WHERE m.selection_status = 'selected'))::int
      FROM media m WHERE m.issue_id = p_issue;
END $$;
