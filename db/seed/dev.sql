-- 개발/테스트 전용 샘플 데이터. 운영 DB 에는 절대 적용하지 않는다 (Flyway 마이그레이션이 아님).
-- 샘플 데이터: 2주짜리 호 1개, 게시물 90개, 사진 100장
-- 의도적으로 넣은 상황: 특정 날짜 편중, 유사(중복) 사진, 저화질, 권리 미확인, 핀 지정
SELECT setseed(0.42);

INSERT INTO app_user (id, email, name) VALUES
    ('00000000-0000-0000-0000-000000000001', NULL, '편집장'),
    ('00000000-0000-0000-0000-000000000002', NULL, '참여자');

INSERT INTO template (id, name, version, spec, min_photos, max_photos, min_pages, max_pages, page_multiple)
VALUES ('00000000-0000-0000-0000-0000000000a1', '기본 잡지', 1,
        '{"trim_mm":[210,297],"columns":3,"margin_mm":15}', 15, 60, 8, 40, 4);

INSERT INTO family_group (id, name, owner_id)
VALUES ('00000000-0000-0000-0000-0000000000d1', '김씨네', '00000000-0000-0000-0000-000000000001');

INSERT INTO family_member (group_id, user_id, role) VALUES
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-000000000001', 'admin'),
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-000000000002', 'member');

INSERT INTO publication (id, group_id, name, owner_id)
VALUES ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000d1',
        '김씨네 월간지', '00000000-0000-0000-0000-000000000001');

INSERT INTO issue (id, publication_id, title, period_start, period_end, close_at, template_id,
                   min_photos, max_photos, min_pages, max_pages, page_multiple)
VALUES ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1',
        '2026년 9월호', DATE '2026-09-01', DATE '2026-09-30', TIMESTAMPTZ '2026-10-01 00:00+09',
        '00000000-0000-0000-0000-0000000000a1', 15, 60, 8, 40, 4);

INSERT INTO issue_member (issue_id, user_id, role) VALUES
    ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-000000000001', 'owner'),
    ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-000000000002', 'contributor');

DO $$
DECLARE
    v_issue constant uuid := '00000000-0000-0000-0000-0000000000c1';
    v_user  constant uuid := '00000000-0000-0000-0000-000000000002';
    v_post  uuid;
    v_day   int;
    v_hash  bigint;
    v_prev  bigint := 0;
    i       int;
BEGIN
    FOR i IN 1..100 LOOP
        -- 앞쪽 날짜에 몰리게 (random()^2)
        v_day := floor(power(random(), 2) * 14)::int;

        -- 10번째마다 직전 사진과 거의 같은 phash (연속 촬영/중복)
        IF i % 10 = 0 THEN
            v_hash := v_prev # (1::bigint << floor(random() * 6)::int);
        ELSE
            v_hash := (random() * 4611686018427387904)::bigint;
        END IF;
        v_prev := v_hash;

        -- 사진 2장짜리 게시물도 섞기 (홀수 i 는 새 게시물, 짝수 i 는 앞 게시물에 이어붙임)
        IF i % 2 = 1 OR v_post IS NULL THEN
            INSERT INTO source_post (issue_id, contributor_id, platform, external_post_id,
                                     posted_at, caption, engagement)
            VALUES (v_issue, v_user, 'instagram', 'p' || i,
                    DATE '2026-09-01' + v_day + (random() * 86000)::int * interval '1 second',
                    '샘플 캡션 ' || i,
                    jsonb_build_object('likes', (power(random(), 3) * 500)::int))
            RETURNING id INTO v_post;
        END IF;

        INSERT INTO media (issue_id, source_post_id, uploader_id, storage_key, sha256,
                           width, height, taken_at, quality_score, phash, rights_ok, pinned)
        VALUES (v_issue, v_post, v_user, 'media/' || i || '.jpg', md5(i::text),
                4000, 3000, DATE '2026-09-01' + v_day,
                round((0.1 + random() * 0.9)::numeric, 3),
                v_hash,
                i NOT IN (7, 33, 58),      -- 3장은 권리 미확인
                i IN (5, 77));             -- 2장은 사용자가 "꼭 넣기"
    END LOOP;
END $$;
