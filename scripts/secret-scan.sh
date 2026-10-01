#!/usr/bin/env bash
# 비밀(키/토큰/비밀번호)이 커밋되는 사고를 막는다. gitleaks v8.30.1 (Docker 이미지, 버전 고정).
#   ./scripts/secret-scan.sh --staged    스테이징된 변경만 (pre-commit 이 사용, 기본값)
#   ./scripts/secret-scan.sh --history   git 전체 이력 (CI 가 사용)
#   ./scripts/secret-scan.sh --tree      작업 폴더의 모든 파일 (첫 커밋 전 점검 등)
#
# Docker 가 꺼져 있을 때
#   - 로컬 pre-commit(--staged): 경고만 하고 통과한다 (CI 가 같은 검사를 다시 하므로 막지는 않는다)
#   - 그 외(CI, --history, --tree): 실패한다 (검사를 못 했는데 통과시키지 않는다)
#
# 오탐이면: 출력의 Fingerprint 값을 저장소 루트의 .gitleaksignore 에 한 줄로 추가한다.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="ghcr.io/gitleaks/gitleaks:v8.30.1"
MODE="${1:---staged}"

if ! docker info >/dev/null 2>&1; then
  if [ "$MODE" = "--staged" ] && [ -z "${CI:-}" ]; then
    echo "[경고] Docker 가 꺼져 있어 비밀 스캔을 건너뜁니다. CI 가 다시 검사하지만, 가능하면 Docker 를 켜고 다시 커밋하세요."
    exit 0
  fi
  echo "[오류] Docker 를 사용할 수 없어 비밀 스캔을 할 수 없습니다"
  exit 2
fi

# --redact: 출력에 비밀 값을 그대로 찍지 않는다 (로그/CI 기록에 비밀이 남는 2차 유출 방지)
# safe.directory: 컨테이너(root)가 호스트 소유 저장소를 읽을 때 git 이 거부하는 것을 피한다
scan() {
  MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/repo" -w /repo \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/repo \
    "$IMAGE" "$@" --no-banner --redact
}

rc=0
case "$MODE" in
  --staged)  scan git --staged /repo || rc=$? ;;
  --history)
    if git rev-parse --verify -q HEAD >/dev/null; then
      scan git /repo || rc=$?
    else
      echo "(커밋 이력이 없어 작업 폴더를 검사합니다)"
      scan dir /repo || rc=$?
    fi ;;
  --tree)    scan dir /repo || rc=$? ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac

if [ "$rc" -eq 1 ]; then
  cat <<'EOF'

[비밀 의심 항목 발견] 위 파일/줄을 확인하세요.
  진짜 비밀이면: 1) 지금 바로 그 비밀을 폐기하고 재발급하세요 (이미 노출된 것으로 간주)
                 2) 파일에서 제거하고, 값은 .env(무시됨) 또는 시크릿 저장소로 옮기세요
                 3) 이미 커밋/푸시했다면 이력에서 지우는 것만으로는 부족합니다. 반드시 재발급하세요
  오탐이면:     출력의 Fingerprint 를 .gitleaksignore 에 추가하세요
EOF
fi
exit "$rc"
