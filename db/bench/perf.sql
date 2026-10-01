-- 성능 측정 (로컬 전용). 실행: ./scripts/db.sh bench
-- 그룹 5,001 / 호 60,001 / 구성원 행 20,004 / 게시물 100,050 / 사진 200,100 규모의 데이터를 넣고 핵심 조회를 측정한다.
-- 큰 데이터를 넣고 지우지 않으므로 반드시 db.sh bench 로 실행할 것 (실행 전에 DB 를 비우고 시드를 넣는다).
-- 수치는 PC 와 Docker 설정에 따라 다르다. 비교용으로 쓸 때는 같은 PC 에서 전/후를 비교한다.
\set ON_ERROR_STOP on
\pset pager off
\echo ===== [쿼리 성능 실험] 그룹 5,000 / 호 60,000 / 구성원 20,000 / 게시물 100,000 / 사진 200,000 =====
\timing off
SELECT setseed(0.1);
INSERT INTO app_user (id, name) SELECT gen_random_uuid(), 'bu' || g FROM generate_series(1, 20000) g;
CREATE TEMP TABLE bu AS SELECT id, substr(name, 3)::int AS rn FROM app_user WHERE name LIKE 'bu%';
CREATE INDEX ON bu (rn);
-- 그룹과 방장 구성원은 같은 트랜잭션에서 넣는다 (서로를 참조하는 외래키는 커밋 시점에 검사된다)
BEGIN;
INSERT INTO family_group (id, name, owner_id)
SELECT gen_random_uuid(), 'g' || n, bu.id FROM generate_series(1, 5000) n JOIN bu ON bu.rn = (n - 1) * 4 + 1;
CREATE TEMP TABLE bg AS SELECT id, substr(name, 2)::int AS n, owner_id FROM family_group WHERE name ~ '^g[0-9]+$';
INSERT INTO family_member (group_id, user_id)
SELECT bg.id, bu.id FROM bg JOIN bu ON bu.rn BETWEEN (bg.n - 1) * 4 + 1 AND bg.n * 4;
COMMIT;
INSERT INTO issue (group_id, title, period_start, period_end, close_at, status, template_id,
                   min_photos, max_photos, min_pages, max_pages, page_multiple)
SELECT g.id, 'bulk', (DATE '2025-11-01' + (m || ' month')::interval)::date,
       (DATE '2025-11-01' + ((m + 1) || ' month')::interval - interval '1 day')::date,
       (DATE '2025-11-01' + ((m + 1) || ' month')::interval)::timestamptz,
       CASE WHEN m = 11 THEN 'collecting' ELSE 'archived' END,
       '00000000-0000-0000-0000-0000000000a1', 15, 60, 8, 40, 4
  FROM bg g, generate_series(0, 11) m;
-- 최신 호(collecting, 2026-10) 중 2,000개 그룹에 게시물 50개, 게시물마다 사진 2장 (사진 200,000장)
INSERT INTO post (group_id, author_id, body, posted_at)
SELECT i.group_id, g.owner_id, 'p' || s, TIMESTAMPTZ '2026-10-01 00:00+09' + (s % 28) * interval '1 day'
  FROM (SELECT id, group_id FROM issue WHERE title = 'bulk' AND status = 'collecting' ORDER BY id LIMIT 2000) i
  JOIN bg g ON g.id = i.group_id, generate_series(1, 50) s;
INSERT INTO media (post_id, group_id, storage_key, sha256, width, height, quality_score, phash, rights_ok)
SELECT p.id, p.group_id, 'b' || k, md5(random()::text), 4000, 3000,
       0.1 + random() * 0.9, (random() * 4611686018427387904)::bigint, true
  FROM post p, generate_series(1, 2) k WHERE p.body ~ '^p[0-9]+$';
-- 그중 200개 호는 마감 시각이 지난 상태
UPDATE issue SET close_at = now() - interval '1 hour'
 WHERE id IN (SELECT i.id FROM issue i
               WHERE i.title = 'bulk' AND i.status = 'collecting'
                 AND i.group_id IN (SELECT group_id FROM post WHERE body ~ '^p[0-9]+$')
               LIMIT 200);
ANALYZE;

SELECT count(*) AS issues FROM issue;
SELECT count(*) AS media FROM media;
SELECT id AS pid, group_id AS pgid FROM issue WHERE title = 'bulk' AND status = 'collecting' AND group_id IN (SELECT group_id FROM post WHERE body ~ '^p[0-9]+$') LIMIT 1 \gset

\echo --- P1 호 1건 진행 조회 (v_issue_progress WHERE issue_id)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT * FROM v_issue_progress WHERE issue_id = :'pid';

\echo --- P2 그룹의 호 목록 조회 (v_issue_progress WHERE group_id)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT * FROM v_issue_progress WHERE group_id = :'pgid';

\echo --- P3 마감 대상 찾기 (status=collecting AND close_at<=now)
EXPLAIN (ANALYZE, COSTS OFF) SELECT i.id FROM issue i WHERE i.status = 'collecting' AND i.close_at <= now();

\echo --- P4 인덱스 없는 FK 조회 (approval.page_id, print_job.issue_id, print_order.print_job_id)
SELECT conrelid::regclass AS table_name, a.attname AS fk_column,
       NOT EXISTS (SELECT 1 FROM pg_index ix WHERE ix.indrelid = c.conrelid AND ix.indkey[0] = a.attnum) AS no_leading_index
  FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
 WHERE c.contype = 'f' AND array_length(c.conkey, 1) = 1
   AND NOT EXISTS (SELECT 1 FROM pg_index ix WHERE ix.indrelid = c.conrelid AND ix.indkey[0] = a.attnum)
 ORDER BY 1, 2;

\timing on
\echo --- P5 호 생성(open_monthly_issues) 그룹 5,001개 전체 훑기 (롤백)
BEGIN;
SELECT count(*) FILTER (WHERE o_created) AS created, count(*) AS groups FROM open_monthly_issues('2026-11-02 12:00+09');
ROLLBACK;

\echo --- P6 마감(close_due_issues): 마감 대상 200건 x 사진 100장 (롤백)
BEGIN;
SELECT o_action, count(*) FROM close_due_issues(now()) GROUP BY 1;
ROLLBACK;

\echo --- P7 select_media: 사진 3,000장(게시물 1,000개)짜리 호 1건 (hamming64 = bit_count 방식)
BEGIN;
INSERT INTO issue (id, group_id, title, period_start, period_end, close_at, template_id,
                   min_photos, max_photos, min_pages, max_pages, page_multiple)
VALUES ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d1', 'big',
        '2026-07-01', '2026-07-31', now(), '00000000-0000-0000-0000-0000000000a1', 15, 60, 8, 40, 4);
INSERT INTO post (group_id, author_id, body, posted_at)
SELECT '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-000000000002', 'big' || s,
       TIMESTAMPTZ '2026-07-01 00:00+09' + (s % 28) * interval '1 day'
  FROM generate_series(1, 1000) s;
INSERT INTO media (post_id, group_id, storage_key, sha256, width, height, quality_score, phash, rights_ok)
SELECT p.id, p.group_id, 'x' || p.body || k, md5(p.body || k), 4000, 3000,
       0.1 + random() * 0.9, (random() * 4611686018427387904)::bigint, true
  FROM post p, generate_series(1, 3) k WHERE p.body ~ '^big[0-9]+$';
SELECT * FROM select_media('00000000-0000-0000-0000-0000000000f1');

ROLLBACK;
