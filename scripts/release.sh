#!/usr/bin/env bash
# One-command release: test → universal build → sign → notarize → verify → GitHub release.
#
#   ./scripts/release.sh               # release the version in Sources/macOCRCLI/main.swift
#   ./scripts/release.sh --bump minor  # bump patch|minor|major, commit, then release
#   ./scripts/release.sh --preflight   # only check identity, notary profile, git state
#   ./scripts/release.sh --no-publish  # sign + notarize, but skip tag push and GitHub release
#
# Environment overrides: APPLE_TEAM_ID (default 4HBBQ4R4RN), APPLE_SIGNING_IDENTITY,
# APPLE_NOTARY_PROFILE (default macOCR), RELEASE_BRANCH (default main).
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/Sources/macOCRCLI/main.swift"
TEAM_ID="${APPLE_TEAM_ID:-4HBBQ4R4RN}"
NOTARY_PROFILE="${APPLE_NOTARY_PROFILE:-macOCR}"
RELEASE_BRANCH="${RELEASE_BRANCH:-main}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$ROOT_DIR/.logs/release/$RUN_ID"
DIST_DIR="$ROOT_DIR/dist"
PREFLIGHT_ONLY=false
PUBLISH=true
BUMP=""

log() { printf '\n\033[1m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\n\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preflight) PREFLIGHT_ONLY=true; shift ;;
      --no-publish) PUBLISH=false; shift ;;
      --bump)
        [[ "${2:-}" =~ ^(patch|minor|major)$ ]] || fail "--bump requires patch, minor or major."
        BUMP="$2"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) fail "Unknown argument: $1 (see --help)" ;;
    esac
  done
}

current_version() { sed -n 's/^let VERSION = "\([0-9][0-9.]*\)"/\1/p' "$VERSION_FILE"; }

bump_version() {
  local v major minor patch
  v="$(current_version)"
  IFS=. read -r major minor patch <<<"$v"
  case "$BUMP" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  local next="$major.$minor.$patch"
  log "Bumping version $v → $next"
  sed -i '' "s/^let VERSION = \"$v\"/let VERSION = \"$next\"/" "$VERSION_FILE"
  git -C "$ROOT_DIR" commit -q -m "chore(release): $next" -- "$VERSION_FILE"
}

select_identity() {
  if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    printf '%s' "$APPLE_SIGNING_IDENTITY"
    return
  fi
  local ids
  ids="$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\"/\1/p")"
  [[ -n "$ids" ]] || fail "No 'Developer ID Application' identity for team $TEAM_ID in the keychain."
  [[ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" == 1 ]] || fail "Several identities for $TEAM_ID; set APPLE_SIGNING_IDENTITY."
  printf '%s' "$ids"
}

check_notary_profile() {
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --team-id "$TEAM_ID" --output-format json >/dev/null 2>&1; then
    return
  fi
  [[ -t 0 ]] || fail "Notary profile '$NOTARY_PROFILE' is not usable. Run: xcrun notarytool store-credentials $NOTARY_PROFILE --team-id $TEAM_ID"
  log "Notary profile '$NOTARY_PROFILE' not found — storing credentials (Apple ID + app-specific password)"
  xcrun notarytool store-credentials "$NOTARY_PROFILE" --team-id "$TEAM_ID"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --team-id "$TEAM_ID" --output-format json >/dev/null \
    || fail "Notary profile '$NOTARY_PROFILE' still not usable."
}

check_git() {
  cd "$ROOT_DIR"
  [[ -z "$(git status --porcelain)" ]] || fail "Working tree is not clean. Commit or stash first."
  local branch
  branch="$(git branch --show-current)"
  [[ "$branch" == "$RELEASE_BRANCH" ]] || fail "Releases are cut from '$RELEASE_BRANCH' (current: '$branch'). Set RELEASE_BRANCH to override."
  git fetch -q origin "$RELEASE_BRANCH" --tags
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$RELEASE_BRANCH")" ]] \
    || fail "'$RELEASE_BRANCH' is not in sync with origin/$RELEASE_BRANCH. Push or pull first."
}

main() {
  parse_args "$@"
  [[ "$(uname -s)" == "Darwin" ]] || fail "This script must run on macOS."
  for c in swift xcrun security codesign ditto shasum git; do require_cmd "$c"; done
  [[ "$PUBLISH" == false ]] || require_cmd gh

  check_git
  [[ -z "$BUMP" || "$PREFLIGHT_ONLY" == true ]] || bump_version
  local version identity
  version="$(current_version)"
  [[ -n "$version" ]] || fail "Could not read VERSION from $VERSION_FILE."
  if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    fail "Tag $version already exists. Use --bump patch|minor|major."
  fi
  identity="$(select_identity)"
  log "Release $version · $identity · notary profile '$NOTARY_PROFILE'"
  check_notary_profile

  if [[ "$PREFLIGHT_ONLY" == true ]]; then
    log "Preflight OK. Nothing was built, submitted or published."
    return
  fi

  mkdir -p "$LOG_DIR" "$DIST_DIR"
  log "Logs: $LOG_DIR"

  log "Running tests"
  swift test 2>&1 | tee "$LOG_DIR/test.log" >/dev/null || fail "Tests failed (see $LOG_DIR/test.log)."

  log "Building universal release binary (arm64 + x86_64)"
  swift build -c release --arch arm64 --arch x86_64 2>&1 | tee "$LOG_DIR/build.log" >/dev/null || fail "Build failed."
  local built
  built="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/macOCR"
  local stage="$DIST_DIR/$version"
  rm -rf "$stage" && mkdir -p "$stage"
  cp "$built" "$stage/macOCR"
  lipo -info "$stage/macOCR" | tee "$LOG_DIR/lipo.log"
  [[ "$("$stage/macOCR" --version)" == "macOCR version $version" ]] || fail "Built binary does not report version $version."

  log "Signing (hardened runtime, secure timestamp)"
  codesign --force --timestamp --options runtime --sign "$identity" "$stage/macOCR"
  codesign --verify --strict --verbose=2 "$stage/macOCR" 2>&1 | tee "$LOG_DIR/codesign-verify.log"

  local zip="$stage/macOCR.zip"
  ditto -c -k --keepParent "$stage/macOCR" "$zip"

  log "Submitting to Apple notarization (this usually takes a few minutes)"
  xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --team-id "$TEAM_ID" --wait --output-format json \
    | tee "$LOG_DIR/notary-submit.json"
  local sub_id status
  sub_id="$(plutil -extract id raw -o - "$LOG_DIR/notary-submit.json" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - "$LOG_DIR/notary-submit.json" 2>/dev/null || true)"
  [[ -n "$sub_id" ]] || fail "No notarization submission id (see $LOG_DIR/notary-submit.json)."
  xcrun notarytool log "$sub_id" "$LOG_DIR/notary-log.json" --keychain-profile "$NOTARY_PROFILE" --team-id "$TEAM_ID" >/dev/null
  [[ "$status" == "Accepted" ]] || fail "Notarization $status (see $LOG_DIR/notary-log.json)."

  # A bare command-line binary cannot carry a stapled ticket; Gatekeeper checks it online on first run.
  log "Gatekeeper assessment"
  spctl --assess --type open --context context:primary-signature -vv "$stage/macOCR" 2>&1 | tee "$LOG_DIR/spctl.log" || true

  (cd "$stage" && shasum -a 256 macOCR.zip >macOCR.zip.sha256 && shasum -a 256 -c macOCR.zip.sha256)

  if [[ "$PUBLISH" == false ]]; then
    log "Done (not published). Artifacts: $zip"
    return
  fi

  log "Tagging $version and publishing the GitHub release"
  [[ -z "$BUMP" ]] || git push -q origin "$RELEASE_BRANCH"
  git tag -a "$version" -m "macOCR $version"
  git push -q origin "$version"
  gh release create "$version" "$zip" "$stage/macOCR.zip.sha256" \
    --title "v$version" --generate-notes --verify-tag | tee "$LOG_DIR/gh-release.log"

  log "Released macOCR $version · notarization $sub_id · $(cut -d' ' -f1 "$stage/macOCR.zip.sha256")"
}

main "$@"
