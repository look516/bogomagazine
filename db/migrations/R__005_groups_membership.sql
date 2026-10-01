-- [groups 모듈] 구성원 확인, 그룹 만들기, 초대 수락, 멤버 관리(방장 전용), 배송지 가드
-- Flyway 반복 마이그레이션: 내용이 바뀌면 다음 migrate 때 자동 재적용된다. 파일명 번호 순서로 적용된다.
-- 소유 테이블/의존 방향은 docs/architecture.md 와 db/tests/architecture.sql 참고.


-- 권한 규칙: 방장만 멤버를 관리한다 (초대 링크 만들기, 다른 사람 내보내기, 방장 넘기기). 구성원은 누구나 스스로 나갈 수 있다.
-- 아래 함수들은 "행위자(p_actor)"를 인자로 받아 규칙을 검사한다. 앱은 로그인한 사용자를 그대로 넘겨야 한다.
-- 앱이 테이블을 직접 UPDATE/DELETE 하면 이 검사를 우회할 수 있으므로, 운영에서는 DB 권한 분리(TODO.md)로 막는다.

-- 활동 중인 구성원인가 (나간 구성원은 false)
CREATE OR REPLACE FUNCTION is_active_member(p_group uuid, p_user uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM family_member
                    WHERE group_id = p_group AND user_id = p_user AND left_at IS NULL)
$$;

-- 그룹 만들기: 그룹과 방장 구성원을 한 트랜잭션에서 함께 넣는다
-- (그룹과 방장 구성원이 서로를 참조하는 외래키는 커밋 시점에 검사되므로 반드시 같은 트랜잭션이어야 한다)
CREATE OR REPLACE FUNCTION create_family_group(p_name text, p_owner uuid, p_nickname text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO family_group (name, owner_id) VALUES (p_name, p_owner) RETURNING id INTO v_id;
    INSERT INTO family_member (group_id, user_id, nickname) VALUES (v_id, p_owner, p_nickname);
    RETURN v_id;
END $$;

-- 초대 링크는 방장(활동 중)만 만들 수 있다
CREATE OR REPLACE FUNCTION guard_invite_creator() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM family_group g
                    WHERE g.id = NEW.group_id AND g.owner_id = NEW.created_by
                      AND is_active_member(g.id, g.owner_id)) THEN
        RAISE EXCEPTION 'family_invite: only the owner of group % can create invites', NEW.group_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_invite_creator ON family_invite;
CREATE TRIGGER trg_invite_creator BEFORE INSERT ON family_invite
    FOR EACH ROW EXECUTE FUNCTION guard_invite_creator();

-- 배송지는 그 그룹의 활동 중인 구성원이 등록한다
CREATE OR REPLACE FUNCTION guard_address_creator() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT is_active_member(NEW.group_id, NEW.created_by) THEN
        RAISE EXCEPTION 'delivery_address: user % is not an active member of group %', NEW.created_by, NEW.group_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_address_creator ON delivery_address;
CREATE TRIGGER trg_address_creator BEFORE INSERT ON delivery_address
    FOR EACH ROW EXECUTE FUNCTION guard_address_creator();

-- 초대 수락: 로그인(카카오/애플)을 마친 사용자가 링크로 들어와 그룹에 합류한다.
--   p_token_hash 는 링크 토큰의 sha256 hex (토큰 원문은 DB 에 없다). 합류하는 사람은 항상 일반 구성원이다.
--   - 이미 활동 중인 구성원이면 사용 횟수를 쓰지 않고 그룹 id 만 돌려준다 (링크를 두 번 눌러도 안전)
--   - 나갔던 구성원이면 다시 활동 중으로 돌아온다 (방장이 내보낸 사람이 옛 링크로 돌아올 수 있으므로 방장은 링크를 취소해야 한다)
--   - 같은 링크를 동시에 여러 명이 눌러도 사용 횟수 제한이 지켜지도록 초대 행을 잠근다
CREATE OR REPLACE FUNCTION accept_family_invite(p_token_hash text, p_user uuid, p_now timestamptz DEFAULT now())
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v family_invite%ROWTYPE;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM app_user WHERE id = p_user AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'accept_family_invite: user % not found or deleted', p_user;
    END IF;

    SELECT * INTO v FROM family_invite WHERE token_hash = p_token_hash FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'invite not found'; END IF;
    IF v.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'invite revoked'; END IF;
    IF v.expires_at <= p_now THEN RAISE EXCEPTION 'invite expired'; END IF;

    IF is_active_member(v.group_id, p_user) THEN
        RETURN v.group_id;
    END IF;
    IF v.max_uses IS NOT NULL AND v.use_count >= v.max_uses THEN
        RAISE EXCEPTION 'invite exhausted';
    END IF;

    INSERT INTO family_member (group_id, user_id, joined_at) VALUES (v.group_id, p_user, p_now)
    ON CONFLICT (group_id, user_id) DO UPDATE SET left_at = NULL, joined_at = EXCLUDED.joined_at;
    UPDATE family_invite SET use_count = use_count + 1 WHERE id = v.id;
    RETURN v.group_id;
END $$;

-- 나가기 / 내보내기: 행을 지우지 않고 left_at 을 채운다 (그 사람이 쓴 글의 작성자 정보 유지)
--   - 자기 자신은 누구나 나갈 수 있고, 다른 사람은 방장만 내보낼 수 있다
--   - 방장은 나가거나 내보낼 수 없다 (먼저 방장을 넘겨야 한다)
CREATE OR REPLACE FUNCTION remove_family_member(p_group uuid, p_actor uuid, p_target uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_owner uuid;
BEGIN
    SELECT owner_id INTO v_owner FROM family_group WHERE id = p_group FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'family group % not found', p_group; END IF;

    IF NOT is_active_member(p_group, p_actor) THEN
        RAISE EXCEPTION 'user % is not an active member of group %', p_actor, p_group
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_actor <> p_target AND p_actor <> v_owner THEN
        RAISE EXCEPTION 'only the owner can remove other members' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_target = v_owner THEN
        RAISE EXCEPTION 'the owner cannot leave or be removed: transfer ownership first' USING ERRCODE = 'check_violation';
    END IF;

    UPDATE family_member SET left_at = now()
     WHERE group_id = p_group AND user_id = p_target AND left_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'member % not found or already left', p_target; END IF;
END $$;

-- 방장 넘기기: 현재 방장만 할 수 있고, 새 방장은 활동 중인 구성원이어야 한다
CREATE OR REPLACE FUNCTION transfer_family_owner(p_group uuid, p_actor uuid, p_new_owner uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_owner uuid;
BEGIN
    SELECT owner_id INTO v_owner FROM family_group WHERE id = p_group FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'family group % not found', p_group; END IF;
    IF p_actor <> v_owner THEN
        RAISE EXCEPTION 'only the owner can transfer ownership' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT is_active_member(p_group, p_new_owner) THEN
        RAISE EXCEPTION 'new owner must be an active member of the group' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE family_group SET owner_id = p_new_owner WHERE id = p_group;
END $$;
