#!/bin/zsh
# 从当前工作树构建公开发布用的 AIQuotaBar DMG（Apple Silicon / arm64）。
#
# 用法：
#   ./Scripts/build-release.sh [--check] [--output <目录>] [--allow-dirty]
#   ./Scripts/build-release.sh --help
#
#   --check        只做前置校验就退出：不构建、不打包、不挂载、不写任何产物
#   --output <目录> 产物输出目录，默认 dist（已被 .gitignore 忽略）
#   --allow-dirty  允许在有未提交改动的工作树上构建（产物信息里会标记 dirty）
#
# 刻意**没有** --force：公开产物永不覆盖。三个输出叶子（DMG、SHA256SUMS、build-info）
# 任何一个已经存在就直接拒绝，请换一个空的 --output 目录，或自己先移走旧产物。
#
# 退出码：
#   0   成功，或 --check 通过
#   64  用法错误
#   66  前置条件不满足（不在仓库顶层、缺工具、宿主不是 arm64、来源不是有效 Git 提交、
#       版本不一致、输出目录不可用、工作树脏且未加 --allow-dirty）
#   69  输出叶子已被占用（已存在，或是符号链接 / 目录 / 特殊文件）
#   70  构建、打包或校验失败
#
# 这个脚本做什么、不做什么 —— 边界是刻意的：
#   做：在独立的 mktemp 目录里构建 + 跑 make test（签名身份固定 ad-hoc）+ 钉死架构与
#       最低系统 + 按白名单裁剪 app bundle + ad-hoc 重签并核实签名形态 + 在 staging 里
#       生成 DMG + hdiutil verify + 只读挂载后逐文件比对 + 从挂载点跑 --version /
#       --self-test，**全部通过之后**才把产物落地到输出目录。落地用 O_CREAT|O_EXCL
#       独占创建 + SHA256 回验：永不覆盖、不沿符号链接写出去、目标是目录也不当容器。
#       原子的是**独占创建那一步**，不是文件内容的复制过程；三个叶子也不构成一个事务。
#       正常失败会删掉本轮自己创建的半成品；被 SIGKILL 或断电时 trap 不运行，不保证清理。
#   不做：不安装、不复制到用户的应用目录、不写 LaunchAgent、不启动 GUI、不读取或刷新
#       浏览器、不改任何用户配置、不读取或导出任何证书与 Keychain 身份、不做 Apple
#       公证、不碰 Gatekeeper / SIP、不删 quarantine 属性、不调用 make clean、不上传。
#   清理：成功时只删除本次自己 mktemp 出来的那一个目录；失败时**保留**它作为错误证据，
#       并把路径打出来。自己挂的挂载点无论成败都会卸载。
set -euo pipefail

# ── 常量 ──────────────────────────────────────────────────────────────────────
# 在任何函数之外取脚本名：zsh 在函数内会把 $0 设成函数名，函数里直接用 ${0:t} 会取错。
readonly SCRIPT_NAME=${0:t}

# 首个公开包明确只发布 Apple Silicon。Intel / Universal 既未构建也未测试。
readonly TARGET_ARCH='arm64'
readonly TARGET_MIN_MACOS='13.0'
readonly SWIFT_TARGET="arm64-apple-macos${TARGET_MIN_MACOS}"
# 正式资产名固定不变：README 的直链与 Release 资产都依赖它。
readonly DMG_BASENAME='AIQuotaBar-macOS-arm64.dmg'
readonly SUMS_BASENAME='SHA256SUMS'
readonly INFO_BASENAME="${DMG_BASENAME:r}.build-info.txt"
readonly VOLNAME='AIQuotaBar'
# 公开包一律 ad-hoc 签名。显式传给 make，不让调用者环境里的 CODESIGN_IDENTITY 被
# Makefile 的 ?= 继承进来 —— 否则第一次 make 签名就可能去访问个人证书。
readonly ADHOC_IDENTITY='-'

readonly EX_USAGE=64
readonly EX_PRECONDITION=66
readonly EX_EXISTS=69
readonly EX_FAILED=70

# 产物落地依赖 zsh/system 的 sysopen 做 O_CREAT|O_EXCL 独占创建 —— 那是「永不覆盖、
# 不沿符号链接写出去、目标是目录也不当容器」这三条保证的核心。加载不了就别继续。
# 这里还没定义 die()，所以直接内联报错退出。
if ! zmodload zsh/system 2>/dev/null; then
  print -r -- "build-release: 加载 zsh/system 失败，无法做原子独占创建，已中止。" >&2
  exit $EX_PRECONDITION
fi

# 本次已经成功落地的产物路径。任何后续失败都会在 cleanup 里把它们回滚掉，
# 这样失败时不会在输出目录里留下「只写了一半的那一组」。
typeset -ga COMMITTED=()

# 本轮已经独占创建、但还没完成写入与核验的那一个目标路径。
# sysopen 成功的那一刻就记上，核验通过并登记进 COMMITTED 之后清空。
# 任何中途失败（包括我没预料到的 set -e 退出）都能靠它把自己创建的半成品删掉；
# 它一定是本轮 O_CREAT|O_EXCL 创建出来的路径，所以绝不会误删既存文件或链接。
typeset -g PENDING_LEAF=''

# app bundle 允许出现的全部路径。多一个少一个都算打包失败 —— 这是防止日志、缓存、
# 任务书、证书、.git 之类的东西混进公开包的最后一道闸。
readonly -a BUNDLE_WHITELIST=(
  'Contents/Info.plist'
  'Contents/MacOS/AIQuotaBar'
  'Contents/Resources/AIQuotaBar.icns'
  'Contents/Resources/LICENSE'
  'Contents/Resources/README.md'
  'Contents/Resources/Scripts/generate-app-icon.swift'
  'Contents/Resources/Scripts/install-launch-agent.sh'
  'Contents/_CodeSignature/CodeResources'
)
# DMG 根目录允许出现的条目：app、指向 /Applications 的普通快捷方式、一份安装说明。
readonly -a DMG_ROOT_WHITELIST=('AIQuotaBar.app' 'Applications' 'INSTALL.txt')
# HFS+ 卷自带的元数据条目。允许存在，但会被显式列出，不静默忽略。
readonly -a VOLUME_METADATA=('.fseventsd' '.Trashes' '.DS_Store' '.background' '.VolumeIcon.icns')

usage() {
  print -r -- "用法: $SCRIPT_NAME [--check] [--output <目录>] [--allow-dirty]"
  print -r -- "  --check        只做前置校验就退出，不构建、不打包、不写产物"
  print -r -- "  --output <目录> 产物输出目录，默认 dist"
  print -r -- "  --allow-dirty  允许在有未提交改动的工作树上构建"
  print -r -- "  （没有 --force：产物永不覆盖，请换一个空的输出目录）"
}

die() {
  local code=$1
  shift
  print -r -- "build-release: $*" >&2
  exit "$code"
}

say() { print -r -- "==> $*"; }

# ── 参数 ──────────────────────────────────────────────────────────────────────
typeset -i check_only=0 allow_dirty=0 commit_probe=0
output_dir='dist'
probe_src=''
probe_dst=''

while (( $# )); do
  case $1 in
    --check)       check_only=1 ;;
    --allow-dirty) allow_dirty=1 ;;
    # 自检用的提交探针：对单个路径执行与正式产物落地**完全相同**的提交语义
    # （commit_artifact）后退出。它存在的唯一理由是让「最终那一步到底会不会覆盖、
    # 会不会沿链接、会不会把目录当容器」可以被确定性回归，而不必去赌一个微秒级的
    # 竞争窗口。它只按 O_CREAT|O_EXCL 创建你指定的那一个文件：不构建、不打包、
    # 不读 Git、不碰输出目录策略，也不会放宽任何安全语义。
    --commit-probe)
      shift
      (( $# >= 2 )) || { usage >&2; die "$EX_USAGE" "--commit-probe 需要 <源文件> <目标路径>"; }
      commit_probe=1
      probe_src=$1
      probe_dst=$2
      shift
      ;;
    --output)
      shift
      (( $# )) || { usage >&2; die "$EX_USAGE" "--output 后面缺目录。"; }
      output_dir=$1
      ;;
    --help|-h)     usage; exit 0 ;;
    *)             usage >&2; die "$EX_USAGE" "未知参数：$1" ;;
  esac
  shift
done

# ── 输出叶子校验 ───────────────────────────────────────────────────────────────
# 一个产物叶子只有「完全不存在」才可用。
#
# 先用 -L（lstat）判符号链接，再用 -e 判存在：顺序很重要。-e 会跟随链接，所以一个
# **悬空**链接在 -e 下是「不存在」，但之后用 `>` 重定向写它，会按链接目标去创建/截断
# 外部文件 —— 那就是越界写入。指向外部文件的非悬空链接同理。所以链接一律拒绝，
# 也刻意不提供任何 --force 来绕过它。
#
# 这个函数会被调用两次：前置校验时一次，产物真正落地前再一次 —— 因为长构建期间叶子
# 可能被换掉，只在开头查一次不够。
validate_output_leaf() {
  local p=$1 label=$2
  if [[ -L $p ]]; then
    die "$EX_EXISTS" "$label 的位置是符号链接，拒绝（写入会落到链接指向的地方）：$p -> $(readlink "$p")"
  fi
  if [[ -d $p ]]; then
    die "$EX_EXISTS" "$label 的位置是目录，拒绝：$p"
  fi
  if [[ -e $p ]]; then
    die "$EX_EXISTS" "$label 已存在，拒绝覆盖：$p（请换一个空的 --output 目录，或自己先移走旧产物）"
  fi
}

# 输出目录本身：拒绝空路径与根路径；已存在就必须是目录；不存在就要求父路径是目录，
# 否则 mkdir 必然失败。父目录是符号链接是允许的（那是用户有意的布局），危险只在叶子。
validate_output_target() {
  [[ -n $output_dir ]] || die "$EX_PRECONDITION" "--output 不能是空路径。"

  local out_abs=${output_dir:a}
  [[ $out_abs != / ]] || die "$EX_PRECONDITION" "拒绝把根目录当输出目录。"

  if [[ -L $output_dir && ! -e $output_dir ]]; then
    die "$EX_PRECONDITION" "输出目录是悬空符号链接，拒绝：$output_dir -> $(readlink "$output_dir")"
  fi
  if [[ -e $output_dir ]]; then
    [[ -d $output_dir ]] \
      || die "$EX_PRECONDITION" "输出路径已存在但不是目录：$output_dir"
  else
    local parent=${out_abs:h}
    [[ -d $parent ]] \
      || die "$EX_PRECONDITION" "输出目录的父路径不是目录，无法创建：$parent"
  fi

  DMG_PATH="$output_dir/$DMG_BASENAME"
  SUMS_PATH="$output_dir/$SUMS_BASENAME"
  INFO_PATH="$output_dir/$INFO_BASENAME"
  validate_output_leaf "$DMG_PATH"  'DMG'
  validate_output_leaf "$SUMS_PATH" 'SHA256SUMS'
  validate_output_leaf "$INFO_PATH" 'build-info'
}

# ── 来源校验 ──────────────────────────────────────────────────────────────────
# 公开包必须能说清楚「它是从哪个提交来的」。所以这里的每一次 Git 查询失败都当硬错误：
# 查不到绝不能降级成 unknown 或 clean —— 那等于拿来源不明的树去发布。
# --allow-dirty 只放宽「工作树有改动」，不放宽「没有有效来源」。
validate_git_source() {
  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "$EX_PRECONDITION" "当前目录不在任何 Git 仓库里，拒绝构建公开包。"

  # 必须正好站在仓库顶层：从子目录运行会借到同一个仓库的 HEAD，从别的仓库里套娃运行
  # 会借到那个仓库的 HEAD，两种都会让 build-info 里的来源对不上实际打包的文件。
  local here=${PWD:A}
  [[ ${toplevel:A} == "$here" ]] \
    || die "$EX_PRECONDITION" "必须在仓库顶层运行（当前 $here，仓库顶层 ${toplevel:A}）。"

  GIT_COMMIT=$(git rev-parse --verify HEAD 2>/dev/null) \
    || die "$EX_PRECONDITION" "仓库没有有效的 HEAD 提交，拒绝构建公开包。"

  local status_out
  if ! status_out=$(git status --porcelain 2>/dev/null); then
    die "$EX_PRECONDITION" "git status 查询失败，无法确认工作树状态，拒绝构建公开包。"
  fi

  if [[ -n $status_out ]]; then
    WORKTREE_STATE='dirty'
    (( allow_dirty )) \
      || die "$EX_PRECONDITION" "工作树有未提交改动。公开包应从干净提交构建；本地试跑请加 --allow-dirty。"
  else
    WORKTREE_STATE='clean'
  fi
}

# ── 阶段一：前置校验（只读，--check 到这里就结束）────────────────────────────────
# 这一段刻意不产生任何副作用：不创建目录、不写文件、不碰已有产物，所以 --check 可以
# 安全地在 CI 里反复跑。
validate_environment() {
  local f
  for f in Makefile Info.plist LICENSE README.md Sources/AIQuotaBar/main.swift; do
    [[ -f $f ]] || die "$EX_PRECONDITION" "请在仓库根目录运行；找不到 $f"
  done

  local t
  for t in swiftc codesign hdiutil plutil shasum lipo vtool ditto make git; do
    command -v "$t" >/dev/null 2>&1 || die "$EX_PRECONDITION" "缺少必需工具：$t"
  done

  # 只在 Apple Silicon 上构建。交叉编译出的 arm64 包无法在本机跑 --self-test，
  # 那就等于拿未经执行验证的二进制去发布，宁可直接拒绝。
  local host_arch
  host_arch=$(uname -m)
  [[ $host_arch == "$TARGET_ARCH" ]] \
    || die "$EX_PRECONDITION" "本脚本只在 $TARGET_ARCH 宿主上构建（当前是 $host_arch）。"

  validate_git_source

  # 版本一致性：Info.plist 与 Swift 里的 appVersion 必须相同，否则包和界面会对不上。
  PLIST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null) \
    || die "$EX_PRECONDITION" "读不到 Info.plist 的 CFBundleShortVersionString"
  PLIST_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist 2>/dev/null) \
    || die "$EX_PRECONDITION" "读不到 Info.plist 的 CFBundleVersion"
  PLIST_MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist 2>/dev/null) \
    || die "$EX_PRECONDITION" "读不到 Info.plist 的 LSMinimumSystemVersion"

  local swift_version
  swift_version=$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' Sources/AIQuotaBar/main.swift | head -1)
  [[ -n $swift_version ]] || die "$EX_PRECONDITION" "在 main.swift 里找不到 appVersion"
  [[ $swift_version == "$PLIST_VERSION" ]] \
    || die "$EX_PRECONDITION" "版本不一致：Info.plist=$PLIST_VERSION，main.swift=$swift_version"
  [[ $PLIST_MIN_OS == "$TARGET_MIN_MACOS" ]] \
    || die "$EX_PRECONDITION" "LSMinimumSystemVersion=$PLIST_MIN_OS，与构建目标 $TARGET_MIN_MACOS 不一致"

  validate_output_target

  say "前置校验通过"
  print -r -- "    repo commit : $GIT_COMMIT"
  print -r -- "    worktree    : $WORKTREE_STATE"
  print -r -- "    version     : $PLIST_VERSION (build $PLIST_BUILD)"
  print -r -- "    target      : $SWIFT_TARGET"
  print -r -- "    host arch   : $host_arch"
  print -r -- "    codesign    : ad-hoc（固定，不受环境 CODESIGN_IDENTITY 影响）"
  print -r -- "    output dir  : $output_dir"
  print -r -- "    dmg         : $DMG_BASENAME"
}

# ── 清理：只碰自己创建的东西 ────────────────────────────────────────────────────
TMP_PREFIX="${TMPDIR:-/tmp}/AIQuotaBar-release."
cleanup() {
  # 参数名刻意不叫 status：zsh 里 `status` 是只读特殊变量（等价于 $?），
  # `local status=...` 会直接报错让整个 cleanup 中途退出，挂载点和 staging 都清不掉。
  local rc=$1
  if [[ -n ${MNT:-} ]] && mount | grep -qF " on $MNT "; then
    /usr/bin/hdiutil detach "$MNT" -quiet 2>/dev/null \
      || /usr/bin/hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
  fi
  # 本轮已独占创建、但还没核验完就被中断的那个叶子（例如 set -e 在意料外的地方退出）。
  # 它一定是本轮自己创建的，删它不会碰到既存文件或链接。
  if [[ -n ${PENDING_LEAF:-} ]]; then
    print -r -- "build-release: 移除本轮未完成的产物 $PENDING_LEAF" >&2
    rm -f -- "$PENDING_LEAF"
    PENDING_LEAF=''
  fi

  # 失败回滚：只删本次 commit_artifact 自己创建成功的那几个叶子（路径都记在 COMMITTED
  # 里），不碰任何别的东西。目的是失败时不留下「三个产物只写了一两个」的半套。
  if (( rc != 0 )) && (( ${#COMMITTED} )); then
    print -r -- "build-release: 回滚本次已落地的 ${#COMMITTED} 个产物" >&2
    local f
    for f in "${COMMITTED[@]}"; do
      rm -f -- "$f"
    done
  fi

  # 前缀判断保证我们只会删掉本次 mktemp 出来的那个目录。
  if [[ -n ${STAGE:-} && -d ${STAGE:-} && ${STAGE:-} == ${TMP_PREFIX}* ]]; then
    if (( rc == 0 )); then
      rm -rf "$STAGE"
    else
      # 失败时保留现场：构建日志、manifest diff 都在里面。错误信息引用的路径因此仍然有效。
      print -r -- "build-release: 失败证据保留在 $STAGE（未自动删除；确认后请自行移除）" >&2
    fi
  fi
}

# ── 阶段二：构建并测试 ─────────────────────────────────────────────────────────
# 只构建一次。make test = 构建 app + plutil 校验 + codesign 校验 + --version + --self-test，
# 所以「先构建再测试再打包」用这一次调用就够了，不重复全量构建。
#
# CODESIGN_IDENTITY 用命令行赋值显式钉成 ad-hoc。Makefile 里是 `?=`，所以如果不传，
# 调用者环境里的 CODESIGN_IDENTITY 会被 make 继承，第一次签名就可能去访问个人证书；
# 命令行赋值的优先级高于环境变量，能彻底压掉这条路径。普通用户直接跑 make 时仍然可以
# 自己选签名身份 —— 那是 Makefile 的事，这里只约束公开打包入口。
# 注意：不调用 make clean —— 那个目标会 rm -rf 掉 BUILD_DIR 和整个 dist/。
build_and_test() {
  say "构建并测试（$SWIFT_TARGET，ad-hoc 签名）"
  local before after
  before=$(git status --porcelain)

  make test \
      BUILD_DIR="$STAGE/build" \
      SWIFTFLAGS="-target $SWIFT_TARGET" \
      CODESIGN_IDENTITY="$ADHOC_IDENTITY" \
      >"$STAGE/make-test.log" 2>&1 \
    || { tail -30 "$STAGE/make-test.log" >&2; die "$EX_FAILED" "make test 失败，完整日志见 $STAGE/make-test.log"; }

  grep -E '^结果: ' "$STAGE/make-test.log" | tail -1 | sed 's/^/    self-test /' || true

  # 构建过程不应该改动工作树（例如意外触发图标重建）。改了就说明产物来源不再等于
  # 上面记录的那个提交，必须停下。
  after=$(git status --porcelain)
  [[ $before == $after ]] \
    || die "$EX_FAILED" "构建过程修改了工作树，产物来源无法与记录的提交对应，已中止。"
}

# ── 阶段三：核实二进制的架构与最低系统 ──────────────────────────────────────────
# Info.plist 里的 LSMinimumSystemVersion 只是声明；真正起作用的是 Mach-O 的
# LC_BUILD_VERSION。这里直接从 load commands 读，避免「声明了 13.0 其实没编进去」。
verify_binary() {
  local exe="$STAGE/build/AIQuotaBar.app/Contents/MacOS/AIQuotaBar"
  [[ -f $exe ]] || die "$EX_FAILED" "构建产物里找不到可执行文件"

  BIN_ARCHS=$(lipo -archs "$exe")
  [[ $BIN_ARCHS == "$TARGET_ARCH" ]] \
    || die "$EX_FAILED" "二进制架构是「$BIN_ARCHS」，期望恰好是「$TARGET_ARCH」"

  local build_version
  build_version=$(vtool -show-build "$exe" 2>/dev/null) \
    || die "$EX_FAILED" "vtool 读不出 load commands"
  BIN_PLATFORM=$(print -r -- "$build_version" | sed -n 's/^ *platform \(.*\)$/\1/p' | head -1)
  BIN_MINOS=$(print -r -- "$build_version" | sed -n 's/^ *minos \(.*\)$/\1/p' | head -1)
  [[ $BIN_PLATFORM == 'MACOS' ]] || die "$EX_FAILED" "平台是 $BIN_PLATFORM，期望 MACOS"
  [[ $BIN_MINOS == "$TARGET_MIN_MACOS" ]] \
    || die "$EX_FAILED" "load commands 里的 minos 是 $BIN_MINOS，期望 $TARGET_MIN_MACOS"

  say "二进制核实：arch=$BIN_ARCHS platform=$BIN_PLATFORM minos=$BIN_MINOS"
}

# 核实签名形态确实是 ad-hoc：没有签名机构、没有团队标识。即使环境里塞了个人身份，
# 公开产物也不该带上任何真实签名者信息。
verify_adhoc_signature() {
  local target=$1 info
  info=$(codesign --display --verbose=2 "$target" 2>&1) \
    || die "$EX_FAILED" "codesign --display 失败：$target"
  print -r -- "$info" | grep -q '^Signature=adhoc$' \
    || die "$EX_FAILED" "签名不是 ad-hoc：$(print -r -- "$info" | grep -E '^Signature=' || print -r -- '无 Signature 行')"
  if print -r -- "$info" | grep -q '^Authority='; then
    die "$EX_FAILED" "产物带了签名机构（Authority），公开包必须是 ad-hoc 无身份签名。"
  fi
  local team
  team=$(print -r -- "$info" | sed -n 's/^TeamIdentifier=\(.*\)$/\1/p' | head -1)
  [[ -z $team || $team == 'not set' ]] \
    || die "$EX_FAILED" "产物带了 TeamIdentifier=$team，公开包必须没有团队标识。"
  SIGNATURE_FORM="Signature=adhoc TeamIdentifier=${team:-not set}"
}

# 列出一棵树的「相对路径 + 类型 + 内容指纹」。普通文件取 SHA256，符号链接只取
# readlink 目标（不跟随链接读外部内容），目录只记类型。
tree_manifest() {
  local root=$1 p rel
  find "$root" -mindepth 1 | sort | while IFS= read -r p; do
    rel=${p#$root/}
    if [[ -L $p ]]; then
      print -r -- "L|$rel|$(readlink "$p")"
    elif [[ -d $p ]]; then
      print -r -- "D|$rel"
    else
      print -r -- "F|$rel|$(shasum -a 256 "$p" | awk '{print $1}')"
    fi
  done
}

# ── 阶段四：按白名单组装 DMG 载荷 ───────────────────────────────────────────────
# 构建出来的 bundle 会被整份复制过来，然后：补上 MIT LICENSE、移除只对维护者有意义的
# 发布脚本、ad-hoc 重新签名（改过 bundle 内容就必须重签）、核实签名形态、再逐条核对白名单。
stage_payload() {
  say "组装 DMG 载荷"
  PAYLOAD="$STAGE/payload"
  mkdir -p "$PAYLOAD"
  ditto "$STAGE/build/AIQuotaBar.app" "$PAYLOAD/AIQuotaBar.app"

  # 公开包里应当带上许可全文。
  ditto LICENSE "$PAYLOAD/AIQuotaBar.app/Contents/Resources/LICENSE"
  # Makefile 会把整个 Scripts/ 拷进 bundle；发布脚本本身对终端用户没用，去掉。
  rm -f "$PAYLOAD/AIQuotaBar.app/Contents/Resources/Scripts/$SCRIPT_NAME"

  # 改过内容，签名必须重做，否则 codesign --verify 会失败。只用 ad-hoc，不碰任何证书。
  codesign --force --deep --sign "$ADHOC_IDENTITY" "$PAYLOAD/AIQuotaBar.app" >/dev/null 2>&1 \
    || die "$EX_FAILED" "ad-hoc 重新签名失败"
  codesign --verify --deep --strict "$PAYLOAD/AIQuotaBar.app" \
    || die "$EX_FAILED" "打包前 codesign 严格校验失败"
  verify_adhoc_signature "$PAYLOAD/AIQuotaBar.app"
  say "签名形态：$SIGNATURE_FORM"

  # 白名单：bundle 内的文件集合必须与声明完全一致。
  local -a actual expected
  actual=("${(@f)$(find "$PAYLOAD/AIQuotaBar.app" \( -type f -o -type l \) -print | sed "s|^$PAYLOAD/AIQuotaBar.app/||" | sort)}")
  expected=("${(@f)$(print -rl -- "${BUNDLE_WHITELIST[@]}" | sort)}")
  if [[ "${actual[*]}" != "${expected[*]}" ]]; then
    print -r -- "bundle 内容与白名单不一致：" >&2
    diff <(print -rl -- "${expected[@]}") <(print -rl -- "${actual[@]}") >&2 || true
    die "$EX_FAILED" "白名单校验失败"
  fi
  say "bundle 白名单校验通过（${#actual} 个文件）"

  # 普通的拖拽安装布局：一个指向 /Applications 的符号链接 + 一份中文安装说明。
  ln -s /Applications "$PAYLOAD/Applications"
  write_install_note "$PAYLOAD/INSTALL.txt"

  # DMG 根目录同样核白名单。
  local -a root_actual root_expected
  root_actual=("${(@f)$(find "$PAYLOAD" -mindepth 1 -maxdepth 1 | sed "s|^$PAYLOAD/||" | sort)}")
  root_expected=("${(@f)$(print -rl -- "${DMG_ROOT_WHITELIST[@]}" | sort)}")
  [[ "${root_actual[*]}" == "${root_expected[*]}" ]] \
    || die "$EX_FAILED" "DMG 根目录条目与白名单不一致：${root_actual[*]}"
}

# DMG 里的安装说明。刻意用 ASCII 文件名，避开 HFS+ 的 Unicode 规范化差异；正文中文。
# 首次打开的说法刻意不做任何承诺：不说「只会拦一次」，也不说「右键打开一定可以」——
# 实际提示与可用选项取决于 macOS 版本与设备管理策略。
write_install_note() {
  cat > "$1" <<NOTE
AIQuotaBar $PLIST_VERSION (build $PLIST_BUILD) — Apple Silicon / arm64

安装
  把 AIQuotaBar 拖到右边的 Applications（应用程序）文件夹。

首次打开
  这个包是本地 ad-hoc 签名、未经 Apple 公证，所以 macOS 可能会阻止打开。
  请先自己确认来源与校验值（见下面「校验下载」），确认没问题之后，打开
  「系统设置 → 隐私与安全性」，找到针对 AIQuotaBar 的提示，按那里给出的选项处理。
  具体提示文案与可用选项取决于你的 macOS 版本与设备管理策略；在某些策略或系统版本
  下，未经公证的 app 可能根本无法打开。Apple 的官方说明：
    https://support.apple.com/en-us/102445
  不要为此关闭 Gatekeeper 或系统完整性保护。

校验下载
  Release 里附带 SHA256SUMS。把它和 DMG 放在同一个目录，然后运行：
    shasum -a 256 -c SHA256SUMS

使用前提
  - macOS $TARGET_MIN_MACOS 或更高版本；本包只适用于 Apple Silicon（arm64），未提供也未测试 Intel 版本。
  - 只支持 Google Chrome。需要在已登录的个人资料里打开并保持这两个额度页：
      https://chatgpt.com/settings/usage?tab=overview
      https://claude.ai/new#settings/usage
  - 在 Chrome 菜单开启「查看 → 开发者 → 允许 Apple 事件中的 JavaScript」。
  - 首次读取时在系统弹窗里允许 AIQuotaBar 控制 Google Chrome；也可以到
    「系统设置 → 隐私与安全性 → 自动化」里手动打开。

更新
  这个包没有自动更新。要升级请到项目的 Releases 页面重新下载。

许可与声明
  MIT 许可，全文见 AIQuotaBar.app 内的 Contents/Resources/LICENSE。
  第三方非官方工具，与 OpenAI、Anthropic、Google 没有任何隶属、赞助或背书关系。
  项目主页：https://github.com/jixuan-skylake/AIQuotaBar
NOTE
}

# ── 阶段五：在 staging 里生成 DMG ───────────────────────────────────────────────
# 刻意先写进 staging 而不是输出目录：这样校验没过时，输出目录里不会留下任何未经完整
# 验证的「半包」。
make_dmg() {
  say "生成 DMG（先落在 staging）"
  STAGE_DMG="$STAGE/$DMG_BASENAME"
  hdiutil create -volname "$VOLNAME" -srcfolder "$PAYLOAD" \
    -fs HFS+ -format UDZO "$STAGE_DMG" >"$STAGE/hdiutil-create.log" 2>&1 \
    || { tail -20 "$STAGE/hdiutil-create.log" >&2; die "$EX_FAILED" "hdiutil create 失败"; }
}

# ── 阶段六：校验 DMG ───────────────────────────────────────────────────────────
# hdiutil verify 看镜像自身完整性；随后只读挂载，把挂载点的文件集合、内容 SHA 与
# 符号链接目标跟载荷逐条比对，再从挂载点跑 --version / --self-test。
# 只跑命令行自检，绝不启动 GUI；输出只取自检的汇总行，不含任何真实用量。
verify_dmg() {
  say "校验 DMG"
  hdiutil verify "$STAGE_DMG" >"$STAGE/hdiutil-verify.log" 2>&1 \
    || { tail -20 "$STAGE/hdiutil-verify.log" >&2; die "$EX_FAILED" "hdiutil verify 失败"; }

  MNT="$STAGE/mnt"
  mkdir -p "$MNT"
  hdiutil attach "$STAGE_DMG" -readonly -nobrowse -mountpoint "$MNT" \
    >"$STAGE/hdiutil-attach.log" 2>&1 \
    || { tail -20 "$STAGE/hdiutil-attach.log" >&2; die "$EX_FAILED" "只读挂载失败"; }

  # 卷级元数据允许存在，但要显式列出来，不静默忽略。
  local -a extra
  extra=()
  local rel
  while IFS= read -r rel; do
    [[ -z $rel ]] && continue
    if (( ${DMG_ROOT_WHITELIST[(Ie)$rel]} == 0 )); then
      if (( ${VOLUME_METADATA[(Ie)$rel]} )); then
        extra+=("$rel")
      else
        die "$EX_FAILED" "挂载后发现白名单外的条目：$rel"
      fi
    fi
  done < <(find "$MNT" -mindepth 1 -maxdepth 1 | sed "s|^$MNT/||" | sort)
  if (( ${#extra} )); then
    print -r -- "    卷元数据（HFS+ 自带，非打包内容）：${extra[*]}"
  fi

  # 逐文件比对：集合、普通文件内容 SHA、符号链接目标。
  tree_manifest "$PAYLOAD" > "$STAGE/manifest-payload.txt"
  tree_manifest "$MNT" | grep -vE "^[DFL]\|(${(j:|:)VOLUME_METADATA})(\||/|$)" > "$STAGE/manifest-mount.txt"
  if ! diff -u "$STAGE/manifest-payload.txt" "$STAGE/manifest-mount.txt" >"$STAGE/manifest-diff.txt"; then
    cat "$STAGE/manifest-diff.txt" >&2
    die "$EX_FAILED" "挂载内容与载荷不一致"
  fi
  say "挂载内容与载荷逐文件一致（$(grep -c '^F|' "$STAGE/manifest-payload.txt") 个文件、$(grep -c '^L|' "$STAGE/manifest-payload.txt") 个符号链接）"

  codesign --verify --deep --strict "$MNT/AIQuotaBar.app" \
    || die "$EX_FAILED" "挂载后 codesign 严格校验失败"
  verify_adhoc_signature "$MNT/AIQuotaBar.app"

  local mounted_exe="$MNT/AIQuotaBar.app/Contents/MacOS/AIQuotaBar"
  MOUNT_VERSION=$("$mounted_exe" --version 2>&1) \
    || die "$EX_FAILED" "挂载点上 --version 失败"
  [[ $MOUNT_VERSION == "AIQuotaBar $PLIST_VERSION" ]] \
    || die "$EX_FAILED" "挂载点上的版本是「$MOUNT_VERSION」，期望「AIQuotaBar $PLIST_VERSION」"

  if "$mounted_exe" --self-test >"$STAGE/mount-selftest.log" 2>&1; then
    MOUNT_SELFTEST=$(grep -E '^结果: ' "$STAGE/mount-selftest.log" | tail -1)
  else
    tail -20 "$STAGE/mount-selftest.log" >&2
    die "$EX_FAILED" "挂载点上 --self-test 失败"
  fi
  say "挂载点自检：$MOUNT_SELFTEST"

  hdiutil detach "$MNT" -quiet 2>/dev/null || hdiutil detach "$MNT" -force -quiet
  MNT=''
}

# ── 阶段七：产物落地（全部校验通过之后才写进输出目录）────────────────────────────
# SHA256SUMS 与 build-info 都先在 staging 里生成，然后在落地前**再核一次**三个叶子，
# 最后由 commit_artifact 用 O_CREAT|O_EXCL 独占创建并复制进去 —— 不是 mv，也不对输出
# 叶子做 `>` 重定向，所以不存在跟随符号链接写到外部路径的可能；叶子在长构建期间被换成
# 文件 / 目录 / 链接，也会在独占创建那一步直接失败。
#
# 「原子」的确切范围：**独占创建那一步是原子的**（路径要么由我们新建、要么直接失败），
# 文件内容的复制过程本身**不是**原子的，所以读者可能看到一个正在写入的中间状态。
# 进程被 SIGKILL 或断电时，trap 不会运行，已创建但没写完的文件**不会**被自动清理 ——
# 这种情况下请把输出目录当成不可信，自行清掉后重新打包。
# 把一个文件以「原子独占创建」的语义提交到最终路径。
#
# 为什么不用 mv / mv -n / cp / ln：它们都是**工具语义**，目标是目录（或指向目录的
# 符号链接）时会把目标当容器，把文件塞进去 —— 实测 `mv` 与 `mv -n` 对「目录符号链接」
# 都返回 0 并把产物写进了链接指向的目录。`mv -n` 只挡得住「目标是已存在的文件」。
#
# 这里改用 open(2) 本身的语义：sysopen -o creat,excl 就是 O_CREAT|O_EXCL。
#   - 目标已存在（普通文件 / 目录 / 符号链接，含悬空）→ 直接失败，绝不覆盖。
#   - O_EXCL|O_CREAT 在路径是符号链接时按 POSIX 必须失败，所以不会沿链接写到别处。
#   - 它不是工具，所以目标是目录时不会被当容器，而是直接失败。
#   - 创建本身是原子的，不存在「先判断再创建」的窗口。
# 内容随后通过这个 fd 写入（是复制，不是 rename），所以**跨卷输出同样支持**。
# 写完按 SHA256 回验；写入失败或校验不符就删掉自己刚创建的那个文件再报错，
# 绝不把没写完 / 没核验过的文件当成功产物。
# 取一个文件的 SHA256，成功时打印摘要，失败返回 1。
#
# 刻意**不用** `shasum … | awk …` 这种管道：在 set -e + pipefail 下，管道里任何一端
# 失败都会让那条赋值语句直接终止整个脚本，从而跳过下面写好的显式失败处理 —— 这正是
# 「目标侧摘要失败时把已创建的文件留在输出目录里」那个缺陷的成因。
# 这里只执行 shasum，用 if 捕获退出码，再在 shell 里切出第一个字段。
file_sha256() {
  local out
  if ! out=$(shasum -a 256 -- "$1" 2>/dev/null); then
    return 1
  fi
  [[ -n $out ]] || return 1
  print -r -- "${out%% *}"
}

# 丢弃本轮自己刚独占创建、但没能完整写入或核验的那个目标文件，然后以 70 退出。
# 只删 PENDING_LEAF：它一定来自本轮的 O_CREAT|O_EXCL 创建，不会是既存文件或链接。
# 若外部在创建之后把该路径换成了符号链接，`rm -f` 删掉的也只是那个链接本身，
# 不会跟随它去删别处的内容。
discard_pending() {
  local reason=$1 leaf=$PENDING_LEAF
  PENDING_LEAF=''
  if [[ -n $leaf ]]; then
    rm -f -- "$leaf"
  fi
  die "$EX_FAILED" "$reason，已移除本轮创建的未完成文件：$leaf"
}

commit_artifact() {
  local src=$1 dst=$2 label=$3
  local want got

  # 源摘要先取：这一步失败时还没有创建任何东西，所以不需要清理，只需如实报错。
  if ! want=$(file_sha256 "$src"); then
    die "$EX_FAILED" "$label 读不出源文件摘要，未创建任何目标文件：$src"
  fi

  if ! sysopen -w -o creat,excl -u 3 -- "$dst" 2>/dev/null; then
    die "$EX_EXISTS" "$label 的最终位置已被占用（已存在的文件 / 目录 / 符号链接），拒绝覆盖：$dst"
  fi
  # 从这一刻起这个路径是本轮自己创建的，后面任何失败都必须把它删掉。
  PENDING_LEAF=$dst

  if ! cat -- "$src" >&3; then
    exec 3>&-
    discard_pending "$label 写入失败"
  fi
  exec 3>&-

  # 目标摘要**执行失败**与**摘要不匹配**是两种不同的失败，都要显式处理：
  # 前者说明根本没核验成，后者说明核验没通过 —— 两种都不能把文件留在输出目录里。
  if ! got=$(file_sha256 "$dst"); then
    discard_pending "$label 落地后读不出目标文件摘要（无法核验）"
  fi
  if [[ $got != $want ]]; then
    discard_pending "$label 落地后 SHA256 与 staging 不一致"
  fi

  PENDING_LEAF=''
  COMMITTED+=("$dst")
}

publish_artifacts() {
  say "写出产物与证据"
  ( cd "$STAGE" && shasum -a 256 "$DMG_BASENAME" > "$SUMS_BASENAME" )
  DMG_SHA256=$(awk '{print $1}' "$STAGE/$SUMS_BASENAME")
  DMG_BYTES=$(stat -f '%z' "$STAGE_DMG")
  write_build_info "$STAGE/$INFO_BASENAME"

  mkdir -p "$output_dir"

  # 这一轮 validate_output_leaf 只是为了「尽早给出清楚的错误信息」。真正的保证来自
  # 下面 commit_artifact 的 O_CREAT|O_EXCL —— 即使在这两步之间有人往叶子上放了文件、
  # 目录或目录链接，提交也会失败而不是覆盖或写进链接目标。
  validate_output_leaf "$DMG_PATH"  'DMG'
  validate_output_leaf "$SUMS_PATH" 'SHA256SUMS'
  validate_output_leaf "$INFO_PATH" 'build-info'

  # 事务性：每个叶子单独是原子的，但三个文件**不是一个整体事务**。所以任何一个失败时，
  # cleanup 会把本次已经落地的那些回滚掉，输出目录里不会留下不完整的一组。
  commit_artifact "$STAGE_DMG"              "$DMG_PATH"  'DMG'
  commit_artifact "$STAGE/$SUMS_BASENAME"   "$SUMS_PATH" 'SHA256SUMS'
  commit_artifact "$STAGE/$INFO_BASENAME"   "$INFO_PATH" 'build-info'
}

# 给维护者 / 复审者的来源证据。不进 DMG，也不随 Release 上传。
write_build_info() {
  {
    print -r -- "AIQuotaBar 公开发布包构建信息"
    print -r -- "generated-at        : $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
    print -r -- "source-commit       : $GIT_COMMIT"
    print -r -- "worktree-state      : $WORKTREE_STATE"
    print -r -- "app-version         : $PLIST_VERSION"
    print -r -- "app-build           : $PLIST_BUILD"
    print -r -- "swift-target        : $SWIFT_TARGET"
    print -r -- "binary-archs        : $BIN_ARCHS"
    print -r -- "binary-platform     : $BIN_PLATFORM"
    print -r -- "binary-minos        : $BIN_MINOS"
    print -r -- "lsminimumsystem     : $PLIST_MIN_OS"
    print -r -- "codesign-identity   : ad-hoc ($ADHOC_IDENTITY)，未公证，无 Developer ID"
    print -r -- "signature-form      : $SIGNATURE_FORM"
    print -r -- "mounted-version     : $MOUNT_VERSION"
    print -r -- "mounted-self-test   : $MOUNT_SELFTEST"
    print -r -- "dmg                 : $DMG_BASENAME"
    print -r -- "dmg-sha256          : $DMG_SHA256"
    print -r -- "dmg-bytes           : $DMG_BYTES"
    print -r -- ""
    print -r -- "app bundle 完整文件清单（相对 AIQuotaBar.app/，SHA256）:"
    ( cd "$PAYLOAD/AIQuotaBar.app" && find . -type f | sort | while IFS= read -r f; do
        print -r -- "  $(shasum -a 256 "$f" | awk '{print $1}')  ${f#./}"
      done )
  } > "$1"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
# 提交探针走在最前面：它不依赖仓库、Git 来源或输出目录策略，只验证提交语义本身。
if (( commit_probe )); then
  [[ -f $probe_src ]] || die "$EX_PRECONDITION" "--commit-probe 的源文件不存在：$probe_src"
  commit_artifact "$probe_src" "$probe_dst" '探针'
  say "探针提交成功：$probe_dst"
  exit 0
fi

validate_environment

if (( check_only )); then
  say "--check 结束：未构建、未打包、未挂载、未写任何产物。"
  exit 0
fi

trap 'cleanup $?' EXIT
STAGE=$(mktemp -d "${TMP_PREFIX}XXXXXX") || die "$EX_FAILED" "mktemp 失败"
say "staging: $STAGE"

build_and_test
verify_binary
stage_payload
make_dmg
verify_dmg
publish_artifacts

say "完成"
print -r -- "    $DMG_PATH"
print -r -- "    $SUMS_PATH"
print -r -- "    $INFO_PATH"
print -r -- "未执行：安装、启动 GUI、浏览器读取、公证、上传。"
