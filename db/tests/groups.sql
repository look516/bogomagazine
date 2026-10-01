-- groups 모듈 테스트 (그룹 만들기, 초대, 방장 권한, 배송지). 전체 실행: ./scripts/db.sh test
-- 각 테스트는 BEGIN..ROLLBACK 으로 격리되어 시드 데이터를 바꾸지 않는다. 하나라도 실패하면 즉시 중단.
\echo == groups

\echo T05 family_member PK 중복 거부
BEGIN;
DO $$ BEGIN
  BEGIN
    INSERT INTO family_member (group_id, user_id)
    VALUES ('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-000000000002');
    RAISE EXCEPTION 'T05 failed: 거부되지 않음';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END $$;
ROLLBACK;

\echo T20 그룹 만들기: 방장이 구성원으로 함께 들어가고, 구성원 없이 그룹만 넣으면 커밋 시점에 거부
BEGIN;
DO $$
DECLARE u3 constant uuid := '00000000-0000-0000-0000-000000000003'; g uuid;
BEGIN
  INSERT INTO app_user (id, name) VALUES (u3, '셋째');
  g := create_family_group('이씨네', u3, '막내');
  ASSERT (SELECT owner_id = u3 FROM family_group WHERE id = g), 'T20 방장';
  ASSERT is_active_member(g, u3), 'T20 방장이 구성원이 아님';
END $$;
ROLLBACK;

BEGIN;
INSERT INTO app_user (id, name) VALUES ('00000000-0000-0000-0000-000000000003', '셋째');
INSERT INTO family_group (name, owner_id) VALUES ('유령방', '00000000-0000-0000-0000-000000000003');
DO $$ BEGIN
  BEGIN
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'T20 failed: 방장이 구성원이 아닌 그룹이 허용됨';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
END $$;
ROLLBACK;

\echo T21 초대: 방장만 만들 수 있다 (일반 구성원/외부인 거부)
BEGIN;
DO $$
DECLARE g constant uuid := '00000000-0000-0000-0000-0000000000d1';
        u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        u2 constant uuid := '00000000-0000-0000-0000-000000000002';
BEGIN
  INSERT INTO family_invite (group_id, created_by, token_hash, expires_at)
  VALUES (g, u1, repeat('a', 64), now() + interval '7 days');
  BEGIN
    INSERT INTO family_invite (group_id, created_by, token_hash, expires_at)
    VALUES (g, u2, repeat('b', 64), now() + interval '7 days');
    RAISE EXCEPTION 'T21 failed: 일반 구성원이 초대를 만듦';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO family_invite (group_id, created_by, token_hash, expires_at)
    VALUES (g, u1, 'short', now() + interval '7 days');
    RAISE EXCEPTION 'T21 failed: 짧은 해시 허용';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;
ROLLBACK;

\echo T22 초대 수락: 합류, 멱등(사용 횟수 안 쓰임), 일반 구성원으로 합류
BEGIN;
DO $$
DECLARE g constant uuid := '00000000-0000-0000-0000-0000000000d1';
        u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        u3 constant uuid := '00000000-0000-0000-0000-000000000003';
        r uuid;
BEGIN
  INSERT INTO app_user (id, name) VALUES (u3, '셋째');
  INSERT INTO family_invite (group_id, created_by, token_hash, expires_at, max_uses)
  VALUES (g, u1, repeat('a', 64), now() + interval '7 days', 5);

  r := accept_family_invite(repeat('a', 64), u3);
  ASSERT r = g, 'T22 그룹 id 반환';
  ASSERT is_active_member(g, u3), 'T22 합류 안 됨';
  ASSERT (SELECT owner_id <> u3 FROM family_group WHERE id = g), 'T22 합류자가 방장이 됨';
  ASSERT (SELECT use_count FROM family_invite WHERE token_hash = repeat('a', 64)) = 1, 'T22 사용 횟수';

  r := accept_family_invite(repeat('a', 64), u3);
  ASSERT (SELECT use_count FROM family_invite WHERE token_hash = repeat('a', 64)) = 1, 'T22 두 번 눌러도 횟수는 그대로';
END $$;
ROLLBACK;

\echo T23 초대 수락 거부: 없는 링크, 만료, 취소, 횟수 소진, 탈퇴한 사용자
BEGIN;
DO $$
DECLARE g constant uuid := '00000000-0000-0000-0000-0000000000d1';
        u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        u3 constant uuid := '00000000-0000-0000-0000-000000000003';
        u4 constant uuid := '00000000-0000-0000-0000-000000000004';
        u5 constant uuid := '00000000-0000-0000-0000-000000000005';
BEGIN
  INSERT INTO app_user (id, name) VALUES (u3, '셋째'), (u4, '넷째');
  INSERT INTO app_user (id, name, deleted_at) VALUES (u5, '탈퇴', now());
  INSERT INTO family_invite (group_id, created_by, token_hash, expires_at, max_uses)
  VALUES (g, u1, repeat('a', 64), now() + interval '7 days', 1);
  INSERT INTO family_invite (group_id, created_by, token_hash, expires_at, revoked_at)
  VALUES (g, u1, repeat('b', 64), now() + interval '7 days', now());
  INSERT INTO family_invite (group_id, created_by, token_hash, expires_at)
  VALUES (g, u1, repeat('c', 64), now() + interval '1 day');

  BEGIN PERFORM accept_family_invite(repeat('z', 64), u3); RAISE EXCEPTION 'T23 failed: 없는 링크';
  EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM LIKE '%not found%', 'T23 메시지: ' || SQLERRM; END;

  BEGIN PERFORM accept_family_invite(repeat('b', 64), u3); RAISE EXCEPTION 'T23 failed: 취소된 링크';
  EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM LIKE '%revoked%', 'T23 메시지: ' || SQLERRM; END;

  BEGIN PERFORM accept_family_invite(repeat('c', 64), u3, now() + interval '2 days'); RAISE EXCEPTION 'T23 failed: 만료된 링크';
  EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM LIKE '%expired%', 'T23 메시지: ' || SQLERRM; END;

  BEGIN PERFORM accept_family_invite(repeat('a', 64), u5); RAISE EXCEPTION 'T23 failed: 탈퇴한 사용자';
  EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM LIKE '%not found or deleted%', 'T23 메시지: ' || SQLERRM; END;

  PERFORM accept_family_invite(repeat('a', 64), u3);       -- 1회 소진
  BEGIN PERFORM accept_family_invite(repeat('a', 64), u4); RAISE EXCEPTION 'T23 failed: 횟수 초과';
  EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM LIKE '%exhausted%', 'T23 메시지: ' || SQLERRM; END;
  ASSERT NOT is_active_member(g, u4), 'T23 거부됐는데 합류됨';
END $$;
ROLLBACK;

\echo T24 나가기/내보내기: 본인은 누구나, 타인은 방장만, 방장은 불가, 행은 남고 left_at 만 채워짐, 재합류 가능
BEGIN;
DO $$
DECLARE g constant uuid := '00000000-0000-0000-0000-0000000000d1';
        u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        u2 constant uuid := '00000000-0000-0000-0000-000000000002';
        u3 constant uuid := '00000000-0000-0000-0000-000000000003';
BEGIN
  INSERT INTO app_user (id, name) VALUES (u3, '셋째');
  INSERT INTO family_member (group_id, user_id) VALUES (g, u3);

  BEGIN PERFORM remove_family_member(g, u2, u3); RAISE EXCEPTION 'T24 failed: 일반 구성원이 남을 내보냄';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  BEGIN PERFORM remove_family_member(g, u1, u1); RAISE EXCEPTION 'T24 failed: 방장이 나감';
  EXCEPTION WHEN check_violation THEN NULL; END;

  BEGIN PERFORM remove_family_member(g, gen_random_uuid(), u3); RAISE EXCEPTION 'T24 failed: 외부인이 내보냄';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  PERFORM remove_family_member(g, u1, u3);                 -- 방장이 내보냄
  ASSERT NOT is_active_member(g, u3), 'T24 내보내기 안 됨';
  ASSERT (SELECT count(*) FROM family_member WHERE group_id = g AND user_id = u3) = 1, 'T24 행은 남아야 함';

  BEGIN PERFORM remove_family_member(g, u1, u3); RAISE EXCEPTION 'T24 failed: 이미 나간 사람';
  EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM LIKE '%already left%', 'T24 메시지: ' || SQLERRM; END;

  PERFORM remove_family_member(g, u2, u2);                 -- 본인이 나감
  ASSERT NOT is_active_member(g, u2), 'T24 스스로 나가기';

  -- 옛 링크로 재합류
  INSERT INTO family_invite (group_id, created_by, token_hash, expires_at)
  VALUES (g, u1, repeat('a', 64), now() + interval '7 days');
  PERFORM accept_family_invite(repeat('a', 64), u3);
  ASSERT is_active_member(g, u3) AND (SELECT left_at IS NULL FROM family_member WHERE group_id = g AND user_id = u3), 'T24 재합류';
END $$;
ROLLBACK;

\echo T25 방장 넘기기: 방장만, 활동 중인 구성원에게만, 넘긴 뒤에는 옛 방장이 나갈 수 있고 초대는 새 방장만
BEGIN;
DO $$
DECLARE g constant uuid := '00000000-0000-0000-0000-0000000000d1';
        u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        u2 constant uuid := '00000000-0000-0000-0000-000000000002';
        u3 constant uuid := '00000000-0000-0000-0000-000000000003';
BEGIN
  INSERT INTO app_user (id, name) VALUES (u3, '셋째');

  BEGIN PERFORM transfer_family_owner(g, u2, u2); RAISE EXCEPTION 'T25 failed: 방장이 아닌데 넘김';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  BEGIN PERFORM transfer_family_owner(g, u1, u3); RAISE EXCEPTION 'T25 failed: 구성원이 아닌 사람에게 넘김';
  EXCEPTION WHEN check_violation THEN NULL; END;

  PERFORM transfer_family_owner(g, u1, u2);
  ASSERT (SELECT owner_id = u2 FROM family_group WHERE id = g), 'T25 방장이 안 바뀜';

  BEGIN
    INSERT INTO family_invite (group_id, created_by, token_hash, expires_at)
    VALUES (g, u1, repeat('a', 64), now() + interval '7 days');
    RAISE EXCEPTION 'T25 failed: 옛 방장이 초대를 만듦';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  PERFORM remove_family_member(g, u1, u1);                 -- 이제 나갈 수 있음
  ASSERT NOT is_active_member(g, u1), 'T25 옛 방장이 나가지 못함';

  BEGIN PERFORM transfer_family_owner(g, u2, u1); RAISE EXCEPTION 'T25 failed: 나간 사람에게 넘김';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
ROLLBACK;

\echo T26 배송지: 활동 중인 구성원만 등록, 나간 사람/외부인 거부, 주소 지워도 주문 기록은 그대로(T55 참고)
BEGIN;
DO $$
DECLARE g constant uuid := '00000000-0000-0000-0000-0000000000d1';
        u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        u2 constant uuid := '00000000-0000-0000-0000-000000000002';
BEGIN
  INSERT INTO delivery_address (group_id, label, recipient_name, postal_code, address_line1, created_by)
  VALUES (g, '고모 댁', '김가상', '00002', '대전광역시 가상구 1', u2);

  BEGIN
    INSERT INTO delivery_address (group_id, label, recipient_name, postal_code, address_line1, created_by)
    VALUES (g, '외부', '누구', '00003', '어딘가', gen_random_uuid());
    RAISE EXCEPTION 'T26 failed: 외부인이 배송지를 등록함';
  EXCEPTION WHEN check_violation THEN NULL; END;

  PERFORM remove_family_member(g, u1, u2);
  BEGIN
    INSERT INTO delivery_address (group_id, label, recipient_name, postal_code, address_line1, created_by)
    VALUES (g, '나간 사람', '누구', '00003', '어딘가', u2);
    RAISE EXCEPTION 'T26 failed: 나간 구성원이 배송지를 등록함';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
ROLLBACK;

\echo T27 그룹 삭제: 호가 없는 그룹은 구성원/초대/배송지가 함께 지워지고, 호가 있으면 거부
BEGIN;
DO $$
DECLARE u3 constant uuid := '00000000-0000-0000-0000-000000000003'; g uuid;
BEGIN
  INSERT INTO app_user (id, name) VALUES (u3, '셋째');
  g := create_family_group('임시', u3);
  INSERT INTO family_invite (group_id, created_by, token_hash, expires_at) VALUES (g, u3, repeat('a', 64), now() + interval '1 day');
  INSERT INTO delivery_address (group_id, label, recipient_name, postal_code, address_line1, created_by)
  VALUES (g, '댁', '이름', '00004', '주소', u3);
  DELETE FROM family_group WHERE id = g;
  ASSERT (SELECT count(*) FROM family_member WHERE group_id = g) = 0
     AND (SELECT count(*) FROM family_invite WHERE group_id = g) = 0
     AND (SELECT count(*) FROM delivery_address WHERE group_id = g) = 0, 'T27 하위 행이 남음';
  SET CONSTRAINTS ALL IMMEDIATE;
  BEGIN
    DELETE FROM family_group WHERE id = '00000000-0000-0000-0000-0000000000d1';
    RAISE EXCEPTION 'T27 failed: 호가 있는 그룹이 삭제됨';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;
END $$;
ROLLBACK;
