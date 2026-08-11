#!/usr/bin/env bash
#
# 构建未签名 IPA(可用 AltStore / Sideloadly / TrollStore 侧载)。
#
# 用法:
#   scripts/build-ipa.sh all       # doctor → generate → archive → package → verify
#   scripts/build-ipa.sh doctor    # 检查构建环境
#   scripts/build-ipa.sh generate  # xcodegen 生成 .xcodeproj
#   scripts/build-ipa.sh archive   # xcodebuild 归档(不签名)
#   scripts/build-ipa.sh package   # 把 .app 打包成 .ipa 并生成 sha256
#   scripts/build-ipa.sh verify    # 校验 IPA 结构
#
# 可用环境变量覆盖:
#   SCHEME            默认 TranslateBrowser
#   CONFIGURATION     默认 Release
#   BUILD_DIR         默认 build
#   MARKETING_VERSION 默认取最近 git tag(去掉前缀 v),否则 1.0.0
#   BUILD_NUMBER      默认 1(CI 中传 run number)
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="${SCHEME:-TranslateBrowser}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="${BUILD_DIR:-build}"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"

default_version() {
  local tag
  tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  if [[ -n "$tag" ]]; then
    echo "${tag#v}"
  else
    echo "1.0.0"
  fi
}

MARKETING_VERSION="${MARKETING_VERSION:-$(default_version)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
IPA_NAME="$SCHEME-$MARKETING_VERSION-$BUILD_NUMBER.ipa"

log() { printf '\n==> %s\n' "$*"; }

cmd_doctor() {
  log "检查构建环境"
  local ok=1
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "错误:未找到 xcodebuild,需要 macOS + Xcode" >&2
    ok=0
  else
    xcodebuild -version
  fi
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "错误:未找到 xcodegen,请运行 brew install xcodegen" >&2
    ok=0
  else
    echo "xcodegen $(xcodegen --version)"
  fi
  [[ "$ok" == 1 ]] || exit 1
  echo "环境正常;版本 $MARKETING_VERSION,构建号 $BUILD_NUMBER"
}

cmd_generate() {
  log "生成 Xcode 工程"
  xcodegen generate
}

cmd_archive() {
  log "归档 $SCHEME($CONFIGURATION,未签名)"
  xcodebuild archive \
    -project "$SCHEME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
}

cmd_package() {
  log "打包 IPA"
  local app_path="$ARCHIVE_PATH/Products/Applications/$SCHEME.app"
  if [[ ! -d "$app_path" ]]; then
    echo "错误:未找到 $app_path,请先执行 archive" >&2
    exit 1
  fi
  local staging="$BUILD_DIR/ipa-staging"
  rm -rf "$staging"
  mkdir -p "$staging/Payload"
  cp -R "$app_path" "$staging/Payload/"
  (cd "$staging" && zip -qry "../$IPA_NAME" Payload)
  rm -rf "$staging"
  (cd "$BUILD_DIR" && shasum -a 256 "$IPA_NAME" > "$IPA_NAME.sha256")
  log "产物:$BUILD_DIR/$IPA_NAME"
  cat "$BUILD_DIR/$IPA_NAME.sha256"
}

cmd_verify() {
  log "校验 IPA 结构"
  local ipa="$BUILD_DIR/$IPA_NAME"
  if [[ ! -f "$ipa" ]]; then
    echo "错误:未找到 $ipa" >&2
    exit 1
  fi
  unzip -l "$ipa" | grep -q "Payload/$SCHEME.app/$SCHEME" \
    || { echo "错误:IPA 中缺少主二进制" >&2; exit 1; }
  unzip -l "$ipa" | grep -q "Payload/$SCHEME.app/Info.plist" \
    || { echo "错误:IPA 中缺少 Info.plist" >&2; exit 1; }
  (cd "$BUILD_DIR" && shasum -a 256 -c "$IPA_NAME.sha256")
  echo "IPA 校验通过"
}

cmd_all() {
  cmd_doctor
  cmd_generate
  cmd_archive
  cmd_package
  cmd_verify
}

case "${1:-all}" in
  doctor)   cmd_doctor ;;
  generate) cmd_generate ;;
  archive)  cmd_archive ;;
  package)  cmd_package ;;
  verify)   cmd_verify ;;
  all)      cmd_all ;;
  *)
    echo "用法:$0 {doctor|generate|archive|package|verify|all}" >&2
    exit 1
    ;;
esac
