-- DB 카탈로그에서 ERD 생성에 필요한 정보를 JSON 한 덩어리로 뽑는다. (scripts/gen_erd.py 의 입력)
-- 실행: ./scripts/db.sh erd   (직접 실행할 일은 없다)
SELECT json_build_object(
  'tables', (
    SELECT json_agg(x ORDER BY x.name) FROM (
      SELECT c.relname AS name,
             obj_description(c.oid, 'pg_class') AS comment,
             (SELECT json_agg(json_build_object('name', a.attname,
                                                'type', format_type(a.atttypid, a.atttypmod),
                                                'notnull', a.attnotnull) ORDER BY a.attnum)
                FROM pg_attribute a
               WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS cols,
             (SELECT json_agg(a.attname ORDER BY k.ord)
                FROM pg_constraint p
                CROSS JOIN LATERAL unnest(p.conkey) WITH ORDINALITY AS k(attnum, ord)
                JOIN pg_attribute a ON a.attrelid = p.conrelid AND a.attnum = k.attnum
               WHERE p.conrelid = c.oid AND p.contype = 'p') AS pk,
             (SELECT COALESCE(json_agg(u.cols), '[]'::json) FROM (
                SELECT (SELECT json_agg(a.attname ORDER BY k.ord)
                          FROM unnest(p.conkey) WITH ORDINALITY AS k(attnum, ord)
                          JOIN pg_attribute a ON a.attrelid = p.conrelid AND a.attnum = k.attnum) AS cols
                  FROM pg_constraint p
                 WHERE p.conrelid = c.oid AND p.contype = 'u') u) AS uniques
        FROM pg_class c
       WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
         AND c.relname <> 'flyway_schema_history') x),
  'fks', (
    SELECT json_agg(f ORDER BY f.child, f.cols::text) FROM (
      SELECT p.conrelid::regclass::text AS child,
             p.confrelid::regclass::text AS parent,
             (SELECT json_agg(a.attname ORDER BY k.ord)
                FROM unnest(p.conkey) WITH ORDINALITY AS k(attnum, ord)
                JOIN pg_attribute a ON a.attrelid = p.conrelid AND a.attnum = k.attnum) AS cols,
             (SELECT bool_and(a.attnotnull)
                FROM unnest(p.conkey) AS k(attnum)
                JOIN pg_attribute a ON a.attrelid = p.conrelid AND a.attnum = k.attnum) AS required,
             p.confdeltype::text AS on_delete
        FROM pg_constraint p
        JOIN pg_class c ON c.oid = p.conrelid
       WHERE p.contype = 'f' AND c.relnamespace = 'public'::regnamespace) f)
);
