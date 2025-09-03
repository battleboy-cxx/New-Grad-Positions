#!/usr/bin/env bash
set -euo pipefail

BRANCH=""
PREFER=""
NO_STASH="false"

usage() {
cat <<'H'
Usage: ./sync-fork.sh [options]
  -b, --branch <name>     指定同步的分支（默认=当前分支）
      --prefer-local      冲突时本地优先（merge -X ours）
      --prefer-upstream   冲突时上游优先（merge -X theirs）
      --no-stash          不自动 stash 未提交改动
  -h, --help
H
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--branch) BRANCH="${2:-}"; shift 2;;
    --prefer-local) PREFER="ours"; shift;;
    --prefer-upstream) PREFER="theirs"; shift;;
    --no-stash) NO_STASH="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not a git repo"; exit 1; }
git remote get-url upstream >/dev/null 2>&1 || { echo "No 'upstream' remote. Add it first."; exit 1; }
git remote get-url origin >/dev/null 2>&1 || { echo "No 'origin' remote."; exit 1; }

if [[ -z "${BRANCH}" ]]; then
  BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
  [[ -z "$BRANCH" ]] && { echo "Detached HEAD, use -b to specify branch."; exit 1; }
fi

# 备份点
BACKUP="pre-sync-$(date +%Y%m%d-%H%M%S)-$BRANCH"
git tag -f "$BACKUP" >/dev/null 2>&1 || true

# 处理工作区未提交改动
STASHED="false"
if [[ "$NO_STASH" != "true" ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "[sync] Auto-stash local changes..."
    git stash push -u -m "sync-fork auto-stash $(date +%F-%T)"
    STASHED="true"
  fi
fi

echo "[sync] Fetch upstream..."
git fetch upstream --prune

# 确保本地有该分支
if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "[sync] Create local branch $BRANCH from upstream/$BRANCH"
  git checkout -b "$BRANCH" "upstream/$BRANCH"
else
  git checkout "$BRANCH"
fi

# 合并上游 -> 当前分支
MERGE_EXTRA=()
if [[ -n "$PREFER" ]]; then
  MERGE_EXTRA=(-X "$PREFER")
  echo "[sync] Merge with preference: $PREFER"
fi

set +e
git merge --no-edit "${MERGE_EXTRA[@]}" "upstream/$BRANCH"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  echo
  echo "[sync] ❗Merge has conflicts. Resolve them, then:"
  echo "       git add -A && git commit --no-edit"
  echo "       (If you want to undo: git merge --abort && git reset --hard $BACKUP)"
  exit $RC
fi

echo "[sync] Push to your fork (origin/$BRANCH)..."
git push origin "$BRANCH"

if [[ "$STASHED" == "true" ]]; then
  echo "[sync] Restore stashed changes..."
  git stash pop || { echo "[sync] Stash pop had conflicts. Resolve manually."; }
fi

echo "[sync] ✅ Done. Backup tag: $BACKUP"
