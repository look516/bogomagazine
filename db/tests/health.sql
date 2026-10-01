-- health 모듈 테스트. 전체 실행: ./scripts/db.sh test
-- 각 테스트는 BEGIN..ROLLBACK 으로 격리되어 시드 데이터를 바꾸지 않는다. 하나라도 실패하면 즉시 중단.
\echo == health

\echo T61 부모 삭제/조회 경로가 되는 외래키에는 모두 선행 인덱스가 있음
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(c.conrelid::regclass::text || '.' || a.attname, ', ') INTO missing
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
   WHERE c.contype = 'f' AND array_length(c.conkey, 1) = 1
     AND c.confrelid::regclass::text IN ('issue','page','layout_run','print_job','source_post',
                                         'publication','family_group','media','social_account')
     AND NOT EXISTS (SELECT 1 FROM pg_index ix WHERE ix.indrelid = c.conrelid AND ix.indkey[0] = a.attnum);
  ASSERT missing IS NULL, 'T61 인덱스 없는 FK: ' || COALESCE(missing, '');
END $$;

\echo T64 사용자 기준 조회/탈퇴 처리용 인덱스 존재 + 실제로 사용 가능
BEGIN;
DO $$
DECLARE missing text; plan text := ''; line text;
BEGIN
  SELECT string_agg(v.t || '.' || v.c, ', ') INTO missing
    FROM (VALUES ('family_member','user_id'), ('issue_member','user_id'), ('media','uploader_id'),
                 ('source_post','contributor_id'), ('social_account','user_id')) v(t, c)
   WHERE NOT EXISTS (SELECT 1 FROM pg_index ix JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = ix.indkey[0]
                      WHERE ix.indrelid = v.t::regclass AND a.attname = v.c);
  ASSERT missing IS NULL, 'T64 인덱스 없음: ' || COALESCE(missing, '');

  PERFORM set_config('enable_seqscan', 'off', true);
  FOR line IN EXECUTE 'EXPLAIN SELECT group_id FROM family_member WHERE user_id = ''00000000-0000-0000-0000-000000000001''' LOOP
    plan := plan || line || E'\n';
  END LOOP;
  ASSERT plan LIKE '%ix_family_member_user%', 'T64 "내 그룹" 조회가 인덱스를 못 씀: ' || plan;
END $$;
ROLLBACK;
