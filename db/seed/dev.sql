-- 개발/테스트 전용 샘플 데이터. 운영 DB 에는 절대 적용하지 않는다 (Flyway 마이그레이션이 아님).
-- 가족 그룹 1개(방장 + 구성원 1명), 조부모님 배송지 2곳, 9월호 1개, 게시물 50개와 사진 100장.
-- 의도적으로 넣은 상황: 특정 날짜 편중, 유사(중복) 사진, 저화질, 권리 문제, 꼭 넣기(pinned). 전화번호/주소는 모두 가짜다.
SELECT setseed(0.42);

BEGIN;

INSERT INTO app_user (id, email, name) VALUES
    ('00000000-0000-0000-0000-000000000001', NULL, '엄마'),
    ('00000000-0000-0000-0000-000000000002', NULL, '아빠');

INSERT INTO template (id, name, version, spec, min_photos, max_photos, min_pages, max_pages, page_multiple)
VALUES ('00000000-0000-0000-0000-0000000000a1', '기본 잡지', 1,
        '{"trim_mm":[210,297],"columns":3,"margin_mm":15}', 15, 60, 8, 40, 4);

-- 그룹과 방장 구성원은 한 트랜잭션에서 함께 넣는다 (서로를 참조하는 외래키는 커밋 시점에 검사된다)
INSERT INTO family_group (id, name, owner_id)
VALUES ('00000000-0000-0000-0000-0000000000d1', '김씨네', '00000000-0000-0000-0000-000000000001');
INSERT INTO family_member (group_id, user_id, nickname) VALUES
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-000000000001', '엄마'),
    ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-000000000002', '아빠');

INSERT INTO delivery_address (id, group_id, label, recipient_name, recipient_phone, postal_code,
                              address_line1, address_line2, created_by) VALUES
    ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000d1',
     '친할머니·친할아버지 댁', '김가상', '010-0000-0000', '00000', '서울특별시 가상구 가상로 1', '101동 101호',
     '00000000-0000-0000-0000-000000000001'),
    ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000d1',
     '외할머니·외할아버지 댁', '이가상', '010-0000-0001', '00001', '부산광역시 가상구 가상로 2', NULL,
     '00000000-0000-0000-0000-000000000001');

INSERT INTO issue (id, group_id, title, period_start, period_end, close_at, template_id,
                   min_photos, max_photos, min_pages, max_pages, page_multiple)
VALUES ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000d1',
        '2026년 9월호', DATE '2026-09-01', DATE '2026-09-30', TIMESTAMPTZ '2026-10-01 00:00+09',
        '00000000-0000-0000-0000-0000000000a1', 15, 60, 8, 40, 4);

COMMIT;

DO $$
DECLARE
    v_group constant uuid := '00000000-0000-0000-0000-0000000000d1';
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
            INSERT INTO post (group_id, author_id, body, posted_at)
            VALUES (v_group,
                    CASE WHEN i % 3 = 0 THEN '00000000-0000-0000-0000-000000000001'::uuid
                         ELSE '00000000-0000-0000-0000-000000000002'::uuid END,
                    '샘플 글 ' || i,
                    DATE '2026-09-01' + v_day + (random() * 86000)::int * interval '1 second')
            RETURNING id INTO v_post;
        END IF;

        INSERT INTO media (post_id, group_id, storage_key, sha256, width, height, taken_at,
                           quality_score, phash, rights_ok, pinned)
        VALUES (v_post, v_group, 'media/' || i || '.jpg', md5(i::text), 4000, 3000,
                DATE '2026-09-01' + v_day,
                round((0.1 + random() * 0.9)::numeric, 3),
                v_hash,
                i NOT IN (7, 33, 58),      -- 3장은 권리 문제로 제외 대상
                i IN (5, 77));             -- 2장은 사용자가 "꼭 넣기"
    END LOOP;
END $$;
