#!/usr/bin/env bash
set -euo pipefail

KSU_TYPE="${1:-}"
KSU_META="${2:-}"

append_github_env() {
  local line="$1"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "$line" >> "$GITHUB_ENV"
  else
    echo "$line"
  fi
}

append_github_output() {
  local line="$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$line" >> "$GITHUB_OUTPUT"
  else
    echo "$line"
  fi
}

emit_ksuver() {
  local version="$1"
  append_github_env "KSUVER=$version"
  append_github_output "ksuver=$version"
}

die() {
  echo "ERROR: $*" >&2
  exit 10
}

require_safe_field() {
  local name="$1"
  local value="$2"
  [[ "$value" != *$'\n'* ]] || die "$name contains a newline"
  [[ "$value" != *$'\r'* ]] || die "$name contains a carriage return"
  [[ "$value" != *'"'* ]] || die "$name contains a double quote"
  [[ "$value" != *"'"* ]] || die "$name contains a single quote"
  [[ "$value" != *'`'* ]] || die "$name contains a backtick"
  [[ "$value" != *'$'* ]] || die "$name contains a dollar sign"
  [[ "$value" != *'\'* ]] || die "$name contains a backslash"
}

download_setup() {
  local repo="$1"
  local branch="$2"
  local fallback_branch="$3"
  local out_file="$4"
  local ref

  for ref in "$branch" "$fallback_branch"; do
    [[ -n "$ref" ]] || continue
    echo "Trying setup.sh from $repo@$ref"
    if curl -fsSL "https://raw.githubusercontent.com/${repo}/refs/heads/${ref}/kernel/setup.sh" -o "$out_file"; then
      return 0
    fi
  done

  echo "ERROR: unable to download setup.sh from $repo ($branch or $fallback_branch)" >&2
  exit 11
}

checkout_manual_hash() {
  local branch="$1"
  local manual_hash="$2"

  [[ -n "$manual_hash" ]] || return 0
  echo "Checking out requested KSU commit: $manual_hash"
  git fetch origin "$branch" --depth=100 || git fetch origin --depth=100
  git checkout "$manual_hash"
}

latest_tag() {
  local repo="$1"
  local tag

  tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  if [[ -z "$tag" ]]; then
    tag="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
      | grep '"tag_name":' \
      | sed -E 's/.*"v?([^"]+)".*/\1/' \
      | head -n1 || true)"
  fi
  if [[ -z "$tag" ]]; then
    tag="$(curl -fsSL "https://api.github.com/repos/${repo}/tags" 2>/dev/null \
      | grep -o '"name": *"[^"]*"' \
      | head -n1 \
      | sed -E 's/"name": *"v?([^"]+)"/\1/' || true)"
  fi

  tag="${tag#v}"
  [[ -n "$tag" ]] || tag="0.0.0"
  echo "$tag"
}

set_defconfig_full_name_format() {
  local format="$1"
  local defconfig="common/arch/arm64/configs/gki_defconfig"

  [[ -f "$defconfig" ]] || return 0
  sed -i '/^CONFIG_KSU_FULL_NAME_FORMAT=/d' "$defconfig"
  printf 'CONFIG_KSU_FULL_NAME_FORMAT="%s"\n' "$format" >> "$defconfig"
}

write_version_full() {
  local ksu_dir="$1"
  local version_full="$2"
  local version_tag="$3"
  local file
  local escaped_full
  local escaped_tag

  escaped_full="$(printf '%s' "$version_full" | sed 's/[&|\/]/\\&/g')"
  escaped_tag="$(printf '%s' "$version_tag" | sed 's/[&|\/]/\\&/g')"

  for file in "$ksu_dir/kernel/Makefile" "$ksu_dir/kernel/Kbuild"; do
    [[ -f "$file" ]] || continue

    if grep -q '^KSU_VERSION_FULL := ' "$file"; then
      sed -i "s|^KSU_VERSION_FULL := .*|KSU_VERSION_FULL := $escaped_full|" "$file"
    elif [[ "$file" == "$ksu_dir/kernel/Makefile" ]] && grep -q '^REPO_OWNER :=' "$file"; then
      awk -v full="$version_full" '
        /^REPO_OWNER :=/ && !done {
          print
          print ""
          print "KSU_VERSION_FULL := " full
          done=1
          next
        }
        { print }
      ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    fi

    if grep -q '^KSU_VERSION_API := ' "$file"; then
      sed -i "s|^KSU_VERSION_API := .*|KSU_VERSION_API := $escaped_tag|" "$file"
    fi
    if grep -q '^KSU_VERSION_TAG_FALLBACK := ' "$file"; then
      sed -i "s|^KSU_VERSION_TAG_FALLBACK := .*|KSU_VERSION_TAG_FALLBACK := v$escaped_tag|" "$file"
    fi
  done
}

configure_version_metadata() {
  local repo="$1"
  local branch="$2"
  local custom_tag="$3"
  local manual_hash="$4"
  local version_tag="$5"
  local ksu_dir="$6"
  local use_hash="$7"
  local version_full
  local full_name_format

  if [[ -z "$use_hash" && -n "$manual_hash" ]]; then
    use_hash="${manual_hash:0:8}"
  fi
  [[ -n "$use_hash" ]] || use_hash="unknown"

  if [[ -n "$custom_tag" ]]; then
    version_full="v${version_tag}-${custom_tag}@${branch}[${use_hash}]"
    full_name_format="%TAG_NAME%-${custom_tag}@${branch}[%COMMIT_SHA%]"
  else
    version_full="v${version_tag}-${use_hash}@${branch}"
    full_name_format="%TAG_NAME%-%COMMIT_SHA%@${branch}"
  fi

  echo "KSU version tag: $version_tag"
  echo "KSU version full: $version_full"
  write_version_full "$ksu_dir" "$version_full" "$version_tag"
  set_defconfig_full_name_format "$full_name_format"
}

parse_ksu_meta() {
  local slash_count

  [[ -n "$KSU_META" ]] || die "ksu_meta is required"
  slash_count="$(grep -o '/' <<< "$KSU_META" | wc -l | tr -d ' ')"
  if [[ "$slash_count" -lt 2 ]]; then
    die "ksu_meta must use: branch/custom_tag/commit_hash"
  fi

  IFS='/' read -r BRANCH_NAME CUSTOM_TAG MANUAL_HASH EXTRA_FIELD <<< "$KSU_META"
  [[ -n "${BRANCH_NAME:-}" ]] || die "KSU branch name is required"
  [[ -z "${EXTRA_FIELD:-}" ]] || die "ksu_meta contains too many '/' separators"

  require_safe_field "KSU branch name" "$BRANCH_NAME"
  require_safe_field "custom version identifier" "${CUSTOM_TAG:-}"
  require_safe_field "rollback commit hash" "${MANUAL_HASH:-}"
  [[ "$BRANCH_NAME" != *' '* ]] || die "KSU branch name must not contain spaces"
  [[ "$CUSTOM_TAG" != *'/'* ]] || die "custom version identifier must not contain '/'"
  if [[ -n "${MANUAL_HASH:-}" && ! "$MANUAL_HASH" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    die "rollback commit hash must be a 7-40 character hex commit hash"
  fi
}

[[ -n "$KSU_TYPE" ]] || die "ksu_type is required"

if [[ "$KSU_TYPE" == "none" ]]; then
  echo "KSU disabled, skipping setup"
  emit_ksuver "0"
  exit 0
fi

[[ -d common ]] || die "install_ksu.sh must run from kernel_workspace"
parse_ksu_meta

echo "KSU type: $KSU_TYPE"
echo "KSU branch: $BRANCH_NAME"
[[ -n "${CUSTOM_TAG:-}" ]] && echo "Custom KSU version identifier: $CUSTOM_TAG" || echo "Custom KSU version identifier: unchanged"
[[ -n "${MANUAL_HASH:-}" ]] && echo "Rollback KSU commit hash: $MANUAL_HASH" || echo "Rollback KSU commit hash: unchanged"

case "$KSU_TYPE" in
  resukisu|sukisu)
    KSU_REPO="ReSukiSU/ReSukiSU"
    SETUP_FILE="/tmp/resukisu_setup.sh"
    download_setup "$KSU_REPO" "$BRANCH_NAME" "main" "$SETUP_FILE"
    bash "$SETUP_FILE" "$BRANCH_NAME"
    cd KernelSU
    checkout_manual_hash "$BRANCH_NAME" "${MANUAL_HASH:-}"
    KSU_COMMIT_SHORT="$(git rev-parse --short=8 HEAD 2>/dev/null || true)"
    KSU_VERSION="$(expr "$(git rev-list --count HEAD 2>/dev/null || echo 0)" + 30700)"
    emit_ksuver "$KSU_VERSION"
    VERSION_TAG="$(latest_tag "$KSU_REPO")"
    cd ..
    configure_version_metadata "$KSU_REPO" "$BRANCH_NAME" "${CUSTOM_TAG:-}" "${MANUAL_HASH:-}" "$VERSION_TAG" "KernelSU" "$KSU_COMMIT_SHORT"
    ;;
  ksunext)
    KSU_REPO="pershoot/KernelSU-Next"
    SETUP_FILE="/tmp/ksunext_setup.sh"
    download_setup "$KSU_REPO" "$BRANCH_NAME" "dev-susfs" "$SETUP_FILE"
    bash "$SETUP_FILE" "$BRANCH_NAME"
    cd KernelSU-Next
    checkout_manual_hash "$BRANCH_NAME" "${MANUAL_HASH:-}"
    KSU_COMMIT_SHORT="$(git rev-parse --short=8 HEAD 2>/dev/null || true)"
    KSU_VERSION="$(expr "$(git rev-list --count HEAD 2>/dev/null || echo 0)" + 30000)"
    emit_ksuver "$KSU_VERSION"
    sed -i "s/KSU_VERSION_FALLBACK := 1/KSU_VERSION_FALLBACK := $KSU_VERSION/g" kernel/Kbuild
    VERSION_TAG="$(latest_tag "$KSU_REPO")"
    cd ..
    configure_version_metadata "$KSU_REPO" "$BRANCH_NAME" "${CUSTOM_TAG:-}" "${MANUAL_HASH:-}" "$VERSION_TAG" "KernelSU-Next" "$KSU_COMMIT_SHORT"
    cd common/drivers/kernelsu
    wget "https://github.com/${GITHUB_REPOSITORY}/raw/refs/heads/${GITHUB_REF_NAME}/other_patch/apk_sign.patch"
    patch -p2 -N -F 3 < apk_sign.patch || true
    ;;
  ksu)
    KSU_REPO="tiann/KernelSU"
    SETUP_FILE="/tmp/ksu_setup.sh"
    download_setup "$KSU_REPO" "$BRANCH_NAME" "main" "$SETUP_FILE"
    bash "$SETUP_FILE" "$BRANCH_NAME"
    cd KernelSU
    checkout_manual_hash "$BRANCH_NAME" "${MANUAL_HASH:-}"
    KSU_COMMIT_SHORT="$(git rev-parse --short=8 HEAD 2>/dev/null || true)"
    KSU_VERSION="$(expr "$(git rev-list --count HEAD 2>/dev/null || echo 0)" + 30000)"
    emit_ksuver "$KSU_VERSION"
    sed -i "s/DKSU_VERSION=16/DKSU_VERSION=${KSU_VERSION}/" kernel/Kbuild
    VERSION_TAG="$(latest_tag "$KSU_REPO")"
    cd ..
    configure_version_metadata "$KSU_REPO" "$BRANCH_NAME" "${CUSTOM_TAG:-}" "${MANUAL_HASH:-}" "$VERSION_TAG" "KernelSU" "$KSU_COMMIT_SHORT"
    ;;
  *)
    die "unsupported ksu_type: $KSU_TYPE"
    ;;
esac
