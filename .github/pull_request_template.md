## 무엇을, 왜
<!-- 변경 내용과 이유. 관련 TODO.md 항목이나 이슈가 있으면 링크 -->

## 영향받는 모듈
<!-- identity / groups / templates / issues / intake / layout / review / printing -->

## 체크리스트
- [ ] `./scripts/db.sh test` 통과
- [ ] 이미 합쳐진 `V###` 마이그레이션을 수정하지 않았다 (변경은 새 V 파일 또는 `R__` 파일)
- [ ] 새 테이블: `COMMENT ON TABLE ... IS 'module:<모듈> | 설명'` 추가
- [ ] 스키마를 바꿨다면 `./scripts/db.sh erd` 로 `docs/erd.md` 를 다시 생성해 함께 커밋
- [ ] 새 모듈 간 외래키: `allowed_dep` 와 `docs/architecture.md` 갱신 (의존 방향이 정말 맞는지 확인)
- [ ] 상태/규칙을 바꿨다면 해당 모듈의 테스트를 추가하거나 고쳤다
- [ ] 개인정보/권한/삭제 정책에 영향이 있으면 `TODO.md` 의 결정 대기 항목과 충돌하지 않는지 확인
