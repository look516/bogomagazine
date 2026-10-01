-- 모듈 경계 검증 (모듈러 모놀리스를 문서가 아니라 CI 로 지킨다). 전체 실행: ./scripts/db.sh test
-- 소유권의 단일 기준은 각 테이블의 코멘트 'module:<모듈> | 설명' 이다 (db/migrations 에서 COMMENT ON TABLE 로 지정).
-- 새 테이블을 만들면 같은 마이그레이션에서 COMMENT 를 달아야 하고,
-- 모듈 간 외래키를 새로 만들면 아래 allowed_dep 에 의존 방향을 추가하고 docs/architecture.md 를 고쳐야 한다.
\echo == architecture

-- 테이블 -> 소유 모듈 (코멘트에서 읽는다)
CREATE TEMP TABLE module_of AS
SELECT c.relname::text AS tbl,
       substring(obj_description(c.oid, 'pg_class') FROM '^module:([a-z]+)') AS module
  FROM pg_class c
 WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
   AND c.relname <> 'flyway_schema_history';

-- 허용하는 모듈 간 외래키 방향 (from 이 to 의 테이블을 참조해도 된다)
CREATE TEMP TABLE allowed_dep (from_module text, to_module text, PRIMARY KEY (from_module, to_module));
INSERT INTO allowed_dep VALUES
    ('groups',   'identity'),
    ('issues',   'identity'), ('issues',   'groups'),  ('issues',   'templates'),
    ('intake',   'identity'), ('intake',   'issues'),
    ('layout',   'issues'),   ('layout',   'templates'), ('layout', 'intake'),
    ('review',   'identity'), ('review',   'issues'),  ('review',   'layout'),
    ('printing', 'identity'), ('printing', 'issues'),  ('printing', 'layout');

\echo T90 모든 테이블에는 'module:<알려진 모듈> | 설명' 코멘트가 있다
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(tbl || ' (' || COALESCE(module, '코멘트 없음/형식 오류') || ')', ', ' ORDER BY tbl) INTO bad
    FROM module_of
   WHERE module IS NULL
      OR module NOT IN ('identity', 'groups', 'templates', 'issues', 'intake', 'layout', 'review', 'printing');
  ASSERT bad IS NULL,
         '소유 모듈 코멘트가 없거나 알 수 없는 모듈: ' || COALESCE(bad, '') ||
         E'\n-> COMMENT ON TABLE <테이블> IS ''module:<모듈> | 설명''; 을 마이그레이션에 추가하세요';
END $$;

\echo T91 모듈 간 외래키는 허용된 방향으로만 존재한다
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(format('%s.%s (%s) -> %s (%s)', c.conrelid::regclass, a.attname, mc.module,
                           c.confrelid::regclass, mp.module), E'\n') INTO bad
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
    JOIN module_of mc ON mc.tbl = c.conrelid::regclass::text
    JOIN module_of mp ON mp.tbl = c.confrelid::regclass::text
   WHERE c.contype = 'f' AND mc.module <> mp.module
     AND NOT EXISTS (SELECT 1 FROM allowed_dep d WHERE d.from_module = mc.module AND d.to_module = mp.module);
  ASSERT bad IS NULL, E'허용되지 않은 모듈 간 외래키:\n' || COALESCE(bad, '') ||
         E'\n-> 의도한 의존이면 allowed_dep 에 추가하고 docs/architecture.md 를 갱신하세요';
END $$;

\echo T92 허용한 의존 방향에 순환이 없다
DO $$
DECLARE cyc int;
BEGIN
  WITH RECURSIVE r(start_m, cur, depth) AS (
      SELECT from_module, to_module, 1 FROM allowed_dep
      UNION ALL
      SELECT r.start_m, d.to_module, r.depth + 1 FROM r JOIN allowed_dep d ON d.from_module = r.cur WHERE r.depth < 20)
  SELECT count(*) INTO cyc FROM r WHERE cur = start_m;
  ASSERT cyc = 0, 'allowed_dep 에 순환 의존이 있음';
END $$;
