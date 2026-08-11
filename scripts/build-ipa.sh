#!/usr/bin/env bash
#
# build-ipa.sh — TranslateBrowser iOS IPA 构建底层
#
# 本地与 CI 共用同一套构建逻辑。用法:
#   scripts/build-ipa.sh all                # 完整流水线:doctor → generate → archive → package → verify
#   scripts/build-ipa.sh <stage>            # 单独执行某个阶段:doctor / generate / archive / package / verify / clean
#
# 可通过环境变量覆盖的配置(均有默认值):
#   SCHEME            Xcode scheme            (默认 TranslateBrowser)
#   CONFIGURATION     构建配置                 (默认 Release)
#   SDK               目标 SDK                 (默认 iphoneos)
#   BUILD_DIR         构建产物根目录            (默认 build)
#   MARKETING_VERSION 应用版本号                (默认取最近 git tag,无则 1.0.0)
#   BUILD_NUMBER      构建号                   (默认 GITHUB_RUN_NUMBER,无则 git 提交数)
#   CODE_SIGNING      YES 启用签名             (默认 NO,产出未签名 IPA 供侧载)

set -euo pipefail

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="${SCHEME:-TranslateBrowser}"
CONFIGURATION="${CONFIGURATION:-Release}"
SDK="${SDK:-iphoneos}"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
CODE_SIGNING="${CODE_SIGNING:-NO}"

ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
PAYLOAD_DIR="$BUILD_DIR/Payload"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData"

resolve_marketing_version() {
  if [[ -n "${MARKETING_VERSION:-}" ]]; then
    echo "$MARKETING_VERSION"
  elif tag="$(git describe --tags --abbrev=0 2>/dev/null)"; then
    echo "${tag#v}"
  else
    echo "1.0.0"
  fi
}

resolve_build_number() {
  if [[ -n "${BUILD_NUMBER:-}" ]]; then
    echo "$BUILD_NUMBER"
  elif [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
    echo "$GITHUB_RUN_NUMBER"
  else
    git rev-list --count HEAD 2>/dev/null || echo "1"
  fi
}

MARKETING_VERSION="$(resolve_marketing_version)"
BUILD_NUMBER="$(resolve_build_number)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
IPA_NAME="$SCHEME-$MARKETING_VERSION-$BUILD_NUMBER"
IPA_PATH="$BUILD_DIR/$IPA_NAME.ipa"

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m[build-ipa]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[build-ipa] 错误:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 阶段:doctor — 环境自检
# ---------------------------------------------------------------------------
stage_doctor() {
  log "环境自检"
  [[ "$(uname -s)" == "Darwin" ]] || die "IPA 构建需要 macOS(当前:$(uname -s))"
  command -v xcodebuild >/dev/null || die "缺少 xcodebuild,请安装 Xcode"
  command -v xcodegen  >/dev/null || die "缺少 xcodegen,请执行:brew install xcodegen"
  command -v plutil    >/dev/null || die "缺少 plutil"
  log "Xcode:    $(xcodebuild -version | tr '\n' ' ')"
  log "XcodeGen: $(xcodegen --version)"
  log "版本:     $MARKETING_VERSION ($BUILD_NUMBER) @ $GIT_SHA"
}

# ---------------------------------------------------------------------------
# 阶段:generate — 由 project.yml 生成 Xcode 工程
# ---------------------------------------------------------------------------
stage_generate() {
  log "生成 Xcode 工程"
  [[ -f project.yml ]] || die "找不到 project.yml"
  xcodegen generate --spec project.yml
  [[ -d "$SCHEME.xcodeproj" ]] || die "工程生成失败:$SCHEME.xcodeproj 不存在"
}

# ---------------------------------------------------------------------------
# 阶段:archive — 归档
# ---------------------------------------------------------------------------
stage_archive() {
  log "归档 ($CONFIGURATION / $SDK / 签名=$CODE_SIGNING)"
  local signing_flags=()
  if [[ "$CODE_SIGNING" != "YES" ]]; then
    signing_flags=(
      CODE_SIGNING_ALLOWED=NO
      CODE_SIGNING_REQUIRED=NO
      CODE_SIGN_IDENTITY=""
    )
  fi
  xcodebuild \
    -project "$SCHEME.xcodeproj" \
    -scheme "$SCHEME" \
    -sdk "$SDK" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -skipPackagePluginValidation \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ${signing_flags[@]+"${signing_flags[@]}"} \
    archive
  [[ -d "$ARCHIVE_PATH/Products/Applications/$SCHEME.app" ]] \
    || die "归档产物缺失:$ARCHIVE_PATH/Products/Applications/$SCHEME.app"
}

# ---------------------------------------------------------------------------
# 阶段:package — 打包 IPA 并生成校验和
# ---------------------------------------------------------------------------
stage_package() {
  log "打包 IPA"
  rm -rf "$PAYLOAD_DIR" "$IPA_PATH"
  mkdir -p "$PAYLOAD_DIR"
  cp -R "$ARCHIVE_PATH/Products/Applications/$SCHEME.app" "$PAYLOAD_DIR/"
  (cd "$BUILD_DIR" && zip -qryX "$IPA_PATH" Payload)
  shasum -a 256 "$IPA_PATH" | awk '{print $1}' > "$IPA_PATH.sha256"
  log "产物: $IPA_PATH ($(du -h "$IPA_PATH" | cut -f1 | tr -d ' '))"
  log "SHA256: $(cat "$IPA_PATH.sha256")"
}

# ---------------------------------------------------------------------------
# 阶段:verify — 校验 IPA 结构与元数据
# ---------------------------------------------------------------------------
stage_verify() {
  log "校验 IPA"
  [[ -f "$IPA_PATH" ]] || die "IPA 不存在:$IPA_PATH"

  unzip -tq "$IPA_PATH" >/dev/null || die "IPA zip 完整性校验失败"

  local extract_dir="$BUILD_DIR/verify"
  rm -rf "$extract_dir"
  unzip -q "$IPA_PATH" -d "$extract_dir"

  local app_dir="$extract_dir/Payload/$SCHEME.app"
  [[ -d "$app_dir" ]] || die "IPA 内缺少 Payload/$SCHEME.app"
  [[ -f "$app_dir/Info.plist" ]] || die "缺少 Info.plist"
  plutil -lint "$app_dir/Info.plist" >/dev/null || die "Info.plist 格式非法"
  [[ -f "$app_dir/$SCHEME" ]] || die "缺少可执行文件 $SCHEME"

  local bundle_id version build
  bundle_id="$(plutil -extract CFBundleIdentifier raw "$app_dir/Info.plist")"
  version="$(plutil -extract CFBundleShortVersionString raw "$app_dir/Info.plist")"
  build="$(plutil -extract CFBundleVersion raw "$app_dir/Info.plist")"

  [[ "$version" == "$MARKETING_VERSION" ]] || die "版本号不匹配:期望 $MARKETING_VERSION,实际 $version"
  [[ "$build" == "$BUILD_NUMBER" ]] || die "构建号不匹配:期望 $BUILD_NUMBER,实际 $build"

  log "校验通过:$bundle_id v$version ($build)"

  # CI 中输出产物信息,供后续步骤引用
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "ipa-path=$IPA_PATH"
      echo "ipa-name=$IPA_NAME"
      echo "version=$MARKETING_VERSION"
      echo "build-number=$BUILD_NUMBER"
      echo "sha256=$(cat "$IPA_PATH.sha256")"
    } >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## IPA 构建完成"
      echo ""
      echo "| 项 | 值 |"
      echo "|----|----|"
      echo "| Bundle ID | \`$bundle_id\` |"
      echo "| 版本 | $version ($build) |"
      echo "| 提交 | \`$GIT_SHA\` |"
      echo "| 大小 | $(du -h "$IPA_PATH" | cut -f1 | tr -d ' ') |"
      echo "| SHA256 | \`$(cat "$IPA_PATH.sha256")\` |"
      echo ""
      echo "在 Artifacts 中下载 \`$IPA_NAME\`,可用 AltStore / Sideloadly / TrollStore 侧载。"
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  rm -rf "$extract_dir"
}

# ---------------------------------------------------------------------------
# 阶段:clean
# ---------------------------------------------------------------------------
stage_clean() {
  log "清理构建产物"
  rm -rf "$BUILD_DIR" "$SCHEME.xcodeproj"
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    doctor)   stage_doctor ;;
    generate) stage_generate ;;
    archive)  stage_archive ;;
    package)  stage_package ;;
    verify)   stage_verify ;;
    clean)    stage_clean ;;
    all)
      stage_doctor
      stage_generate
      stage_archive
      stage_package
      stage_verify
      ;;
    *) usage ;;
  esac
}

main "$@"
