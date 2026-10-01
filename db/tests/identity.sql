-- identity 모듈 테스트. 전체 실행: ./scripts/db.sh test
-- 각 테스트는 BEGIN..ROLLBACK 으로 격리되어 시드 데이터를 바꾸지 않는다. 하나라도 실패하면 즉시 중단.
\echo == identity

\echo T80 익명화: 신원/인증 제거, 시크릿 목록 반환, 콘텐츠와 지난 호 기록은 유지, 멱등, 같은 계정으로 재가입 가능
BEGIN;
DO $$
DECLARE u3 constant uuid := '00000000-0000-0000-0000-000000000003';
        v constant uuid := '00000000-0000-0000-0000-0000000000c1';
        v_old uuid; refs text; v_deleted_at timestamptz;
BEGIN
  INSERT INTO app_user (id, email, name) VALUES (u3, 'k3@x.com', '셋째');
  INSERT INTO auth_identity (user_id, provider, provider_uid, email, refresh_token_ref)
  VALUES (u3, 'kakao', 'k-3', 'k3@x.com', 'sec/auth/3');
  INSERT INTO social_account (user_id, platform, external_id, token_ref, consent_at, consent_scope)
  VALUES (u3, 'instagram', 'insta_3', 'sec/ig/3', now(), '{"print":true}');
  INSERT INTO family_member (group_id, user_id, role) VALUES ('00000000-0000-0000-0000-0000000000d1', u3, 'member');
  INSERT INTO issue_member (issue_id, user_id, role) VALUES (v, u3, 'contributor');
  INSERT INTO source_post (issue_id, contributor_id, platform, external_post_id, posted_at, raw)
  VALUES (v, u3, 'instagram', 'p-u3', now(), '{"user":"insta_3"}');
  INSERT INTO media (issue_id, uploader_id, storage_key, sha256, width, height, rights_ok)
  VALUES (v, u3, 'u3.jpg', 'u3sha', 4000, 3000, true);
  INSERT INTO issue (publication_id, title, period_start, period_end, close_at, status, template_id,
                     min_photos, max_photos, min_pages, max_pages, page_multiple)
  VALUES ('00000000-0000-0000-0000-0000000000b1', '지난 호', '2026-01-01', '2026-01-31', '2026-02-01 00:00+09', 'archived',
          '00000000-0000-0000-0000-0000000000a1', 15, 60, 8, 40, 4) RETURNING id INTO v_old;
  INSERT INTO issue_member (issue_id, user_id, role) VALUES (v_old, u3, 'contributor');

  SELECT string_agg(o_kind || ':' || o_ref, ',' ORDER BY o_kind) INTO refs FROM anonymize_user(u3);
  ASSERT refs = 'auth_token:sec/auth/3,social_token:sec/ig/3', 'T80 폐기할 시크릿 목록: ' || COALESCE(refs, 'NULL');

  ASSERT (SELECT email IS NULL AND name = '탈퇴한 사용자' AND deleted_at IS NOT NULL FROM app_user WHERE id = u3), 'T80 사용자 익명화';
  ASSERT (SELECT count(*) FROM auth_identity WHERE user_id = u3) = 0, 'T80 로그인 수단이 남음';
  ASSERT (SELECT token_ref IS NULL AND consent_at IS NULL AND consent_scope IS NULL AND external_id LIKE 'deleted:%'
            FROM social_account WHERE user_id = u3), 'T80 SNS 연동 정보';
  ASSERT (SELECT count(*) FROM family_member WHERE user_id = u3) = 0, 'T80 그룹 멤버십';
  ASSERT (SELECT count(*) FROM issue_member WHERE user_id = u3 AND issue_id = v) = 0, 'T80 수집 중 호의 멤버십';
  ASSERT (SELECT count(*) FROM issue_member WHERE user_id = u3 AND issue_id = v_old) = 1, 'T80 지난 호 기록은 유지';
  ASSERT (SELECT count(*) FROM media WHERE uploader_id = u3) = 1, 'T80 콘텐츠(사진)는 유지';
  ASSERT (SELECT count(*) FROM source_post WHERE contributor_id = u3) = 1, 'T80 콘텐츠(게시물)는 유지';

  SELECT deleted_at INTO v_deleted_at FROM app_user WHERE id = u3;
  ASSERT (SELECT count(*) FROM anonymize_user(u3)) = 0, 'T80 재호출이 시크릿을 또 반환';
  ASSERT (SELECT deleted_at FROM app_user WHERE id = u3) = v_deleted_at, 'T80 재호출이 deleted_at 을 덮어씀';

  -- 같은 카카오 계정으로 다시 가입 가능 (옛 연결이 완전히 해제됨)
  INSERT INTO app_user (id, name) VALUES ('00000000-0000-0000-0000-000000000004', '재가입');
  INSERT INTO auth_identity (user_id, provider, provider_uid) VALUES ('00000000-0000-0000-0000-000000000004', 'kakao', 'k-3');
END $$;
ROLLBACK;

\echo T81 익명화: 그룹 소유자는 소유권을 넘기기 전에는 거부, 없는 사용자는 예외
BEGIN;
DO $$ BEGIN
  BEGIN
    PERFORM * FROM anonymize_user('00000000-0000-0000-0000-000000000001');
    RAISE EXCEPTION 'T81 failed: 소유자가 익명화됨';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  ASSERT (SELECT email IS NULL AND name = '편집장' FROM app_user WHERE id = '00000000-0000-0000-0000-000000000001'), 'T81 거부했는데 바뀜';
  BEGIN
    PERFORM * FROM anonymize_user(gen_random_uuid());
    RAISE EXCEPTION 'T81 failed: 없는 사용자';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%not found%', 'T81 메시지: ' || SQLERRM;
  END;
END $$;
ROLLBACK;
