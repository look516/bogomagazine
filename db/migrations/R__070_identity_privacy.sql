-- [identity 모듈] 회원 탈퇴 익명화
-- Flyway 반복 마이그레이션: 내용이 바뀌면 다음 migrate 때 자동 재적용된다. 파일명 번호 순서로 적용된다.
-- 소유 테이블/의존 방향은 docs/architecture.md 와 db/tests/architecture.sql 참고.

-- 회원 탈퇴: 사용자 행을 지우지 않고 익명화한다.
-- (사용자를 참조하는 외래키가 많아 삭제하면 가족 호의 기록이 깨지거나 삭제 자체가 막힌다.)
--
-- 이 함수가 하는 일 (보수적 기본값 — 신원/인증 정보만 제거)
--   * app_user       : 이메일/이름 제거, deleted_at 기록 (id 는 유지)
--   * auth_identity  : 전부 삭제 -> 같은 카카오/애플 계정으로 더 이상 로그인되지 않음
--   * social_account : 토큰 참조/동의 정보 제거, 외부 계정 ID 익명화 (행은 게시물 참조 때문에 유지)
--   * family_member / 수집 중(collecting)인 호의 issue_member / page_lock : 제거
--   * 호출자에게 돌려줌 : 외부 시크릿 저장소에서 폐기해야 할 토큰 참조 목록 (DB 밖이라 DB 가 지울 수 없다)
-- 이 함수가 하지 않는 일 (정책 결정이 필요 — 별도 논의)
--   * 사용자가 올린 사진(media), 게시물(source_post, raw 포함), 캡션/코멘트 본문 삭제
--   * 이미 인쇄/발행된 호의 내용 변경
--   * 그룹 소유자 처리: 그룹/출판물 소유자는 먼저 소유권을 넘겨야 한다 (아니면 예외)
-- 여러 번 호출해도 안전(멱등).

CREATE OR REPLACE FUNCTION anonymize_user(p_user uuid)
RETURNS TABLE (o_kind text, o_ref text)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM app_user WHERE id = p_user FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'user % not found', p_user;
    END IF;

    IF EXISTS (SELECT 1 FROM family_group WHERE owner_id = p_user)
       OR EXISTS (SELECT 1 FROM publication WHERE owner_id = p_user) THEN
        RAISE EXCEPTION 'user % owns a family group or publication: transfer ownership first', p_user
            USING ERRCODE = 'check_violation';
    END IF;

    -- 삭제 전에 폐기 대상 시크릿 참조를 수집해 돌려준다
    RETURN QUERY
    SELECT 'auth_token'::text, refresh_token_ref FROM auth_identity
     WHERE user_id = p_user AND refresh_token_ref IS NOT NULL
    UNION ALL
    SELECT 'social_token'::text, token_ref FROM social_account
     WHERE user_id = p_user AND token_ref IS NOT NULL;

    DELETE FROM auth_identity WHERE user_id = p_user;

    UPDATE social_account
       SET token_ref = NULL, consent_at = NULL, consent_scope = NULL,
           external_id = 'deleted:' || id::text
     WHERE user_id = p_user;

    DELETE FROM family_member WHERE user_id = p_user;
    DELETE FROM issue_member
     WHERE user_id = p_user AND issue_id IN (SELECT id FROM issue WHERE status = 'collecting');
    DELETE FROM page_lock WHERE user_id = p_user;

    UPDATE app_user
       SET email = NULL, name = '탈퇴한 사용자', deleted_at = COALESCE(deleted_at, now())
     WHERE id = p_user;
END $$;
