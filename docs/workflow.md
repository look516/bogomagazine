# 작업 흐름

목표는 **사람이 기억해야 할 규칙을 줄이고, 어기면 기계가 막게 하는 것**이다.

## 처음 한 번

```bash
./scripts/setup.sh        # git 훅 활성화 + 실행 권한
./scripts/db.sh test      # Docker 가 켜져 있어야 함. 처음엔 이미지를 내려받느라 오래 걸린다
```

## 매일

```bash
git switch -c feat/issues-close-grace      # 짧게 사는 브랜치
# ... 작업 ...
./scripts/db.sh test                        # push 전에 로컬에서 CI 와 같은 검사
git commit                                  # pre-commit 훅: 마이그레이션 규칙 + 공백 오류 + 비밀 스캔(gitleaks)
git push -u origin HEAD                     # PR 을 만들면 CI 가 같은 검사를 다시 한다
```

| 명령 | 설명 |
|---|---|
| `./scripts/db.sh test` | 빈 DB → 마이그레이션 → 체크섬 검증 → 시드 → 전체 테스트 (CI 와 동일) |
| `./scripts/db.sh psql` | 로컬 DB 접속 |
| `./scripts/db.sh reset` | 로컬 DB 비우기 (로컬 전용) |

## 무엇을 바꿀 때 어떤 파일을 고치나

| 하고 싶은 일 | 방법 |
|---|---|
| 함수/뷰/트리거 수정 | 해당 모듈의 `R__###_모듈_*.sql` 을 직접 수정. 테스트 추가/수정 |
| 테이블/컬럼/인덱스 추가·변경 | **새 `V###__설명.sql`** (다음 번호). 기존 V 파일은 건드리지 않는다 |
| 새 테이블 | 위 + 같은 마이그레이션에 `COMMENT ON TABLE 테이블 IS 'module:<모듈> \| 설명'` 추가, 그리고 `./scripts/db.sh erd` 로 `docs/erd.md` 갱신 |
| 컬럼/외래키를 바꿨다 | `./scripts/db.sh erd` 로 `docs/erd.md` 를 다시 생성해 함께 커밋 (안 하면 CI 실패) |
| 모듈 간 외래키 추가 | 위 + `allowed_dep` 와 `docs/architecture.md` 갱신 (정말 맞는 의존 방향인지 먼저 고민) |
| 규칙 추가 | 해당 모듈의 `db/tests/<모듈>.sql` 에 테스트 추가 |

## 브랜치와 커밋

- **trunk-based**: `main` 은 항상 배포 가능. 브랜치는 며칠 안에 합친다. 이름은 `feat/…`, `fix/…`, `docs/…`.
- **커밋 메시지**: `종류(모듈): 요약` — 종류는 `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, 모듈은 `identity | groups | templates | issues | intake | layout | review | printing`.
  예: `fix(issues): 재오픈 시 close_at 을 필수로`
- 한 PR은 한 가지 목적. 마이그레이션이 있으면 PR 설명에 이유를 쓴다.

## 원격 저장소에서 설정할 것 (코드로는 못 함)

GitHub 저장소를 만든 뒤 **Settings → Branches → main 보호 규칙**에서:

- [ ] Require a pull request before merging
- [ ] Require status checks to pass: `ci / db`
- [ ] Require branches to be up to date before merging
- [ ] (선택) Require review from Code Owners — `CODEOWNERS` 파일을 만들려면 GitHub 계정명이 필요하다

이 설정이 없으면 훅과 CI는 "권고"일 뿐이다 (훅은 `--no-verify` 로 우회 가능).
