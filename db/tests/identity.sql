-- identity 모듈 테스트 (로그인 수단, 탈퇴 익명화). 전체 실행: ./scripts/db.sh test
-- 각 테스트는 BEGIN..ROLLBACK 으로 격리되어 시드 데이터를 바꾸지 않는다. 하나라도 실패하면 즉시 중단.
\echo == identity

\echo T80 익명화: 신원/인증 제거, 시크릿 목록 반환, 구성원 행/글/사진은 유지, 멱등, 탈퇴 후 글 작성 불가, 같은 계정으로 재가입 가능
BEGIN;
DO $$
DECLARE u3 constant uuid := '00000000-0000-0000-0000-000000000003';
        g  constant uuid := '00000000-0000-0000-0000-0000000000d1';
        v_post uuid; refs text; v_deleted_at timestamptz;
BEGIN
  INSERT INTO app_user (id, email, name) VALUES (u3, 'k3@x.com', '셋째');
  INSERT INTO auth_identity (user_id, provider, provider_uid, email, refresh_token_ref)
  VALUES (u3, 'kakao', 'k-3', 'k3@x.com', 'sec/auth/3');
  INSERT INTO family_member (group_id, user_id, nickname) VALUES (g, u3, '막내');
  INSERT INTO post (group_id, author_id, body, posted_at) VALUES (g, u3, '막내의 글', '2026-09-20 12:00+09') RETURNING id INTO v_post;
  INSERT INTO media (post_id, group_id, storage_key, sha256, width, height) VALUES (v_post, g, 'u3.jpg', 'u3sha', 4000, 3000);

  SELECT string_agg(o_kind || ':' || o_ref, ',' ORDER BY o_kind) INTO refs FROM anonymize_user(u3);
  ASSERT refs = 'auth_token:sec/auth/3', 'T80 폐기할 시크릿 목록: ' || COALESCE(refs, 'NULL');

  ASSERT (SELECT email IS NULL AND name = '탈퇴한 사용자' AND deleted_at IS NOT NULL FROM app_user WHERE id = u3), 'T80 사용자 익명화';
  ASSERT (SELECT count(*) FROM auth_identity WHERE user_id = u3) = 0, 'T80 로그인 수단이 남음';
  ASSERT (SELECT left_at IS NOT NULL FROM family_member WHERE group_id = g AND user_id = u3), 'T80 구성원 행은 남고 left_at 이 채워짐';
  ASSERT (SELECT count(*) FROM post WHERE author_id = u3) = 1 AND (SELECT count(*) FROM media WHERE post_id = v_post) = 1,
         'T80 글/사진은 유지';

  SELECT deleted_at INTO v_deleted_at FROM app_user WHERE id = u3;
  ASSERT (SELECT count(*) FROM anonymize_user(u3)) = 0, 'T80 재호출이 시크릿을 또 반환';
  ASSERT (SELECT deleted_at FROM app_user WHERE id = u3) = v_deleted_at, 'T80 재호출이 deleted_at 을 덮어씀';

  BEGIN
    INSERT INTO post (group_id, author_id, body, posted_at) VALUES (g, u3, '탈퇴 후 글', '2026-09-21 12:00+09');
    RAISE EXCEPTION 'T80 failed: 탈퇴한 사용자가 글을 올림';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- 같은 카카오 계정으로 다시 가입 가능 (옛 연결이 완전히 해제됨)
  INSERT INTO app_user (id, name) VALUES ('00000000-0000-0000-0000-000000000004', '재가입');
  INSERT INTO auth_identity (user_id, provider, provider_uid) VALUES ('00000000-0000-0000-0000-000000000004', 'kakao', 'k-3');
END $$;
ROLLBACK;

\echo T81 익명화: 방장은 방장을 넘기기 전에는 거부, 넘긴 뒤에는 가능, 없는 사용자는 예외
BEGIN;
DO $$
DECLARE u1 constant uuid := '00000000-0000-0000-0000-000000000001';
        u2 constant uuid := '00000000-0000-0000-0000-000000000002';
        g  constant uuid := '00000000-0000-0000-0000-0000000000d1';
BEGIN
  BEGIN
    PERFORM * FROM anonymize_user(u1);
    RAISE EXCEPTION 'T81 failed: 방장이 익명화됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  ASSERT (SELECT email IS NULL AND name = '엄마' FROM app_user WHERE id = u1), 'T81 거부했는데 바뀜';

  PERFORM transfer_family_owner(g, u1, u2);
  PERFORM * FROM anonymize_user(u1);
  ASSERT (SELECT name = '탈퇴한 사용자' FROM app_user WHERE id = u1), 'T81 방장을 넘긴 뒤에는 익명화되어야 함';

  BEGIN
    PERFORM * FROM anonymize_user(gen_random_uuid());
    RAISE EXCEPTION 'T81 failed: 없는 사용자';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%not found%', 'T81 메시지: ' || SQLERRM;
  END;
END $$;
ROLLBACK;

\echo T82 로그인 수단은 카카오와 애플뿐이다
BEGIN;
DO $$
DECLARE p text;
BEGIN
  INSERT INTO auth_identity (user_id, provider, provider_uid) VALUES ('00000000-0000-0000-0000-000000000001', 'kakao', 'kk-1');
  INSERT INTO auth_identity (user_id, provider, provider_uid, is_private_relay) VALUES ('00000000-0000-0000-0000-000000000001', 'apple', 'ap-1', true);
  FOREACH p IN ARRAY ARRAY['google', 'password', 'naver'] LOOP
    BEGIN
      INSERT INTO auth_identity (user_id, provider, provider_uid) VALUES ('00000000-0000-0000-0000-000000000001', p, 'x-' || p);
      RAISE EXCEPTION 'T82 failed: % 로그인 수단이 허용됨', p;
    EXCEPTION WHEN check_violation THEN NULL;
    END;
  END LOOP;
END $$;
ROLLBACK;
