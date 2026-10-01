-- placement 가 참조하는 media / text_block 외래키를 "커밋 시점에 검사"(DEFERRABLE INITIALLY DEFERRED)로 바꾼다.
--
-- 문제: 호를 삭제하면 media(issue 에서 CASCADE)와 placement(layout_run -> page -> placement 로 CASCADE)가
--       같은 문장에서 함께 지워져야 한다. 그런데 즉시 검사(NO ACTION)이면 media 가 먼저 지워지는 순간
--       placement 가 아직 남아 있어서 "violates foreign key constraint placement_media_id_fkey" 로 호 삭제가 실패한다.
--       (조판 결과가 있는 호는 삭제할 수 없었다. 기존 T04 는 배치가 없는 호만 시험해서 못 잡았다)
-- 해결: 커밋 시점에 검사하면 둘 다 지워진 뒤라 통과한다. 배치된 사진만 따로 지우는 것은 여전히 막힌다
--       (이 경우 오류가 문장이 아니라 커밋 시점에 난다는 점만 다르다).
-- 인쇄 작업(print_job)이 있는 호는 여전히 삭제할 수 없다. 이것은 의도한 보호이며 삭제 정책은 TODO.md 참고.

ALTER TABLE placement
    DROP CONSTRAINT placement_media_id_fkey,
    ADD CONSTRAINT placement_media_id_fkey
        FOREIGN KEY (media_id) REFERENCES media(id) DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE placement
    DROP CONSTRAINT placement_text_block_id_fkey,
    ADD CONSTRAINT placement_text_block_id_fkey
        FOREIGN KEY (text_block_id) REFERENCES text_block(id) DEFERRABLE INITIALLY DEFERRED;
