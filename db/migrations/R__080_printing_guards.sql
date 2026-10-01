-- [printing 모듈] 주문 정합성 가드
-- Flyway 반복 마이그레이션: 내용이 바뀌면 다음 migrate 때 자동 재적용된다. 파일명 번호 순서로 적용된다.
-- 소유 테이블/의존 방향은 docs/architecture.md 와 db/tests/architecture.sql 참고.


-- 주문(print_order)
--   - 배송지는 그 인쇄 작업의 호와 같은 가족 그룹의 것이어야 한다 (다른 가족의 조부모님 주소로 보내지 않게)
--   - 주문한 사람은 그 그룹에서 활동 중인 구성원이어야 한다
--   (누가 주문할 수 있는지, 예: 방장만 -- 의 정책은 TODO.md 에서 정한다)
CREATE OR REPLACE FUNCTION guard_order_consistency() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_group uuid;
BEGIN
    SELECT i.group_id INTO v_group
      FROM print_job j JOIN issue i ON i.id = j.issue_id
     WHERE j.id = NEW.print_job_id;

    IF NOT is_active_member(v_group, NEW.ordered_by) THEN
        RAISE EXCEPTION 'print_order: user % is not an active member of group %', NEW.ordered_by, v_group
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.delivery_address_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM delivery_address a WHERE a.id = NEW.delivery_address_id AND a.group_id = v_group) THEN
        RAISE EXCEPTION 'print_order: address % does not belong to group %', NEW.delivery_address_id, v_group
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_order_consistency ON print_order;
CREATE TRIGGER trg_order_consistency BEFORE INSERT ON print_order
    FOR EACH ROW EXECUTE FUNCTION guard_order_consistency();
