-- groups 모듈 테스트. 전체 실행: ./scripts/db.sh test
-- 각 테스트는 BEGIN..ROLLBACK 으로 격리되어 시드 데이터를 바꾸지 않는다. 하나라도 실패하면 즉시 중단.
\echo == groups

\echo T05 family_member PK 중복 거부
BEGIN;
DO $$ BEGIN
  BEGIN
    INSERT INTO family_member (group_id, user_id, role)
    VALUES ('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-000000000002','member');
    RAISE EXCEPTION 'T05 failed: 거부되지 않음';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END $$;
ROLLBACK;
