#!/bin/zsh
# Scripts/build-release.sh 的打包边界回归。
#
# 覆盖：版本一致性、bundle 与 DMG 白名单、脚本安全边界、参数处理、输出路径与输出叶子
# 的拒绝规则（含符号链接越界写入）、Git 来源校验、以及签名身份的参数契约。
#
# 这套测试实际会做这些事，全部发生在它自己用 mktemp 建的临时目录里：
#   - `build-release.sh --check`（只读校验）与 `make -n`（干跑，不执行任何命令）；
#   - `build-release.sh --commit-probe`，它**会真的写文件** —— 走的就是正式落地所用的
#     那个 commit_artifact，目标都是临时目录内的路径；
#   - 在合成仓库里跑一次**完整脚本并让它故意失败**（那棵树没有真实源码与图标，make 会
#     在编译之前就失败），用来回归「失败时输出目录不留半成品、staging 被保留」。
# 它**不做**完整编译、不打包 DMG、不挂载磁盘镜像、不签名、不安装、不读取任何真实账户
# 数据或凭据，也不碰仓库之外的任何路径。真实的构建 / 打包 / 挂载校验由维护者在本机跑
# 完整脚本完成（见 RELEASING.md）。
#
# Git 探针一律在任务私有的**独立合成仓库**里做，不碰当前仓库的配置、索引或工作树。
set -uo pipefail

ROOT=${0:A:h:h}
cd "$ROOT" || { print -r -- "进不到仓库根目录" >&2; exit 70 }
SCRIPT=Scripts/build-release.sh
SCRIPT_ABS=$ROOT/$SCRIPT

[[ -x $SCRIPT ]] || { print -r -- "找不到可执行的 $SCRIPT" >&2; exit 70 }

typeset -i pass=0 fail=0 skip=0

ok()  { print -r -- "  PASS  $1"; (( pass += 1 )) }
bad() { print -r -- "  FAIL  $1"; (( fail += 1 )) }

assert_eq() {
  if [[ $2 == $3 ]]; then ok "$1（$3）"; else bad "$1：期望「$2」，实际「$3」"; fi
}
assert_contains() {
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1：$2 里找不到「$3」"; fi
}
assert_absent() {
  if grep -qF -- "$3" "$2"; then bad "$1：$2 里不该出现「$3」"; else ok "$1"; fi
}
# 只在非注释行里找。注释里专门说明「为什么不调用某个命令」不算调用。
assert_absent_code() {
  if grep -v '^[[:space:]]*#' "$2" | grep -qF -- "$3"; then
    bad "$1：$2 的代码里不该出现「$3」"
  else
    ok "$1"
  fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/AIQuotaBar-release-check.XXXXXX") || exit 70
cleanup() {
  # 合成仓库里可能留下 chmod 000 的 index，先恢复权限再删，避免删不掉。
  chmod -R u+rwX "$TMP" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
  WORKTREE=dirty
  typeset -a DIRTY=(--allow-dirty)
else
  WORKTREE=clean
  typeset -a DIRTY=()
fi

# run_check <用例名> <期望退出码> [参数...]        在当前仓库根运行
run_check() {
  local name=$1 want=$2
  shift 2
  local out code
  out=$("$SCRIPT" "$@" 2>&1); code=$?
  if (( code == want )); then ok "$name（退出码 $code）"
  else bad "$name：期望退出码 $want，实际 $code — ${out//$'\n'/ / }"; fi
}

# run_check_in <目录> <用例名> <期望退出码> [参数...]   在指定目录运行
run_check_in() {
  local dir=$1 name=$2 want=$3
  shift 3
  local out code
  out=$( cd "$dir" && "$SCRIPT_ABS" "$@" 2>&1 ); code=$?
  if (( code == want )); then ok "$name（退出码 $code）"
  else bad "$name：期望退出码 $want，实际 $code — ${out//$'\n'/ / }"; fi
}

# 造一棵最小的、能通过「仓库根文件」与版本一致性检查的合成源码树。
mk_src() {
  local d=$1
  mkdir -p "$d/Sources/AIQuotaBar"
  cp Info.plist LICENSE README.md Makefile "$d/"
  printf 'let appVersion = "%s"\n' "$PLIST_VERSION" > "$d/Sources/AIQuotaBar/main.swift"
}

print -r -- "build-release.sh 打包边界回归（工作树: $WORKTREE）"
print -r -- ""

# ── 版本一致性 ────────────────────────────────────────────────────────────────
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null)
PLIST_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist 2>/dev/null)
PLIST_MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist 2>/dev/null)
SWIFT_VERSION=$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' Sources/AIQuotaBar/main.swift | head -1)

assert_eq "Info.plist 与 main.swift 的版本一致" "$PLIST_VERSION" "$SWIFT_VERSION"
if [[ $PLIST_BUILD == <-> && $PLIST_BUILD -gt 0 ]]; then
  ok "CFBundleVersion 是正整数（$PLIST_BUILD）"
else
  bad "CFBundleVersion 不是正整数：$PLIST_BUILD"
fi

SCRIPT_MIN_OS=$(sed -n "s/^readonly TARGET_MIN_MACOS='\(.*\)'$/\1/p" "$SCRIPT")
SCRIPT_ARCH=$(sed -n "s/^readonly TARGET_ARCH='\(.*\)'$/\1/p" "$SCRIPT")
SCRIPT_DMG=$(sed -n "s/^readonly DMG_BASENAME='\(.*\)'$/\1/p" "$SCRIPT")
assert_eq "LSMinimumSystemVersion 与脚本的构建目标一致" "$PLIST_MIN_OS" "$SCRIPT_MIN_OS"
assert_eq "脚本只针对 arm64" "arm64" "$SCRIPT_ARCH"
assert_eq "固定资产名" "AIQuotaBar-macOS-arm64.dmg" "$SCRIPT_DMG"

CHANGELOG_TOP=$(sed -n 's/^## \[\{0,1\}\([0-9][0-9.]*\)\]\{0,1\}.*$/\1/p' CHANGELOG.md | head -1)
assert_eq "CHANGELOG 最新条目等于当前版本" "$PLIST_VERSION" "$CHANGELOG_TOP"

assert_contains "README 有 latest 直链" README.md \
  "https://github.com/jixuan-skylake/AIQuotaBar/releases/latest/download/$SCRIPT_DMG"
assert_contains "README 写了当前版本" README.md "$PLIST_VERSION"
assert_contains "README 指向更新记录" README.md "CHANGELOG.md"
assert_contains "RELEASING 使用同一资产名" RELEASING.md "$SCRIPT_DMG"
assert_contains "README 声明未公证" README.md "未经 Apple 公证"
assert_contains "README 声明没有自动更新" README.md "没有自动更新"
assert_contains "README 声明只支持 Apple Silicon" README.md "Apple Silicon"

# ── 首次打开文案不得做保证（P4）────────────────────────────────────────────────
# README 与 DMG 内 INSTALL.txt 的生成文案都必须写成「可能阻止」，并指向系统设置与
# Apple 官方说明；不得承诺只拦一次、也不得承诺某个具体操作一定有效。
assert_contains "README 用「可能会阻止」而非保证" README.md "可能会阻止"
assert_contains "README 指向系统设置 → 隐私与安全性" README.md "系统设置 → 隐私与安全性"
assert_contains "README 引用 Apple 官方说明" README.md "https://support.apple.com/en-us/102445"
assert_contains "README 明确不保证只拦一次" README.md "不保证"
assert_absent "README 不再把被拦写成确定的「预期行为」" README.md "这是预期行为"
assert_contains "README 明说不建议关 Gatekeeper" README.md "不需要、也不建议"
assert_absent "README 不给 Gatekeeper 绕过命令" README.md "spctl --master-disable"
assert_absent "README 不给删 quarantine 的命令" README.md "xattr -d com.apple.quarantine"
assert_absent_code "脚本不教删 quarantine" "$SCRIPT" "com.apple.quarantine"
assert_absent_code "脚本不碰 SIP" "$SCRIPT" "csrutil"
assert_contains "INSTALL 生成文案用「可能会阻止」" "$SCRIPT" "macOS 可能会阻止打开"
assert_contains "INSTALL 生成文案引用 Apple 官方说明" "$SCRIPT" "https://support.apple.com/en-us/102445"
assert_absent "INSTALL 生成文案不承诺右键一定可以" "$SCRIPT" "右键点 AIQuotaBar"

# RELEASING 必须如实描述失败与覆盖行为。
assert_contains "RELEASING 说明只有全部通过才搬进输出目录" RELEASING.md "只有全部通过才会搬进输出目录"
assert_contains "RELEASING 说明失败时保留临时目录" RELEASING.md "失败时临时目录会被保留"
assert_contains "RELEASING 说明产物永不覆盖" RELEASING.md "产物永不覆盖"
assert_contains "RELEASING 说明来源必须是 Git 顶层" RELEASING.md "真实的 Git 仓库顶层"
assert_contains "RELEASING 说明落地是原子独占创建" RELEASING.md "O_CREAT|O_EXCL"
assert_contains "RELEASING 点明 mv -n 也挡不住目录链接" RELEASING.md "mv -n"
assert_contains "RELEASING 明确跨卷输出是支持的" RELEASING.md "跨卷输出是支持的"
assert_contains "RELEASING 如实说明三个文件不是整体事务" RELEASING.md "不是一个整体事务"
assert_contains "README 说明落地是原子独占创建" README.md "O_CREAT|O_EXCL"

# ── bundle / DMG 白名单声明 ────────────────────────────────────────────────────
EXPECTED_BUNDLE='Contents/Info.plist
Contents/MacOS/AIQuotaBar
Contents/Resources/AIQuotaBar.icns
Contents/Resources/LICENSE
Contents/Resources/README.md
Contents/Resources/Scripts/generate-app-icon.swift
Contents/Resources/Scripts/install-launch-agent.sh
Contents/_CodeSignature/CodeResources'
# locale 会改变下划线与字母的排序；两侧都按字节排序，保留所有条目及重复项。
# LC_ALL 仅作用于 sort，不改变其余测试或中文输出的 locale。
EXPECTED_BUNDLE=$(print -r -- "$EXPECTED_BUNDLE" | LC_ALL=C sort)
ACTUAL_BUNDLE=$(awk "/^readonly -a BUNDLE_WHITELIST=\(/,/^\)/" "$SCRIPT" \
  | sed -n "s/^  '\(.*\)'$/\1/p" | LC_ALL=C sort)
if [[ $EXPECTED_BUNDLE == $ACTUAL_BUNDLE ]]; then
  ok "bundle 白名单声明与期望完全一致（$(print -r -- "$ACTUAL_BUNDLE" | wc -l | tr -d ' ') 条）"
else
  bad "bundle 白名单声明与期望不一致"
  diff <(print -r -- "$EXPECTED_BUNDLE") <(print -r -- "$ACTUAL_BUNDLE") >&2 || true
fi

ACTUAL_ROOT=$(sed -n "s/^readonly -a DMG_ROOT_WHITELIST=(\(.*\))$/\1/p" "$SCRIPT")
assert_eq "DMG 根目录白名单" "'AIQuotaBar.app' 'Applications' 'INSTALL.txt'" "$ACTUAL_ROOT"

for forbidden in '.git' '.DS_Store' '.log' '.p12' 'config.json' 'claude-usage-cache' 'OPEN-SOURCE' 'dist/'; do
  if print -r -- "$ACTUAL_BUNDLE" | grep -qF -- "$forbidden"; then
    bad "白名单里出现了不该发布的东西：$forbidden"
  else
    ok "白名单不含 $forbidden"
  fi
done

# ── 脚本安全边界（静态）────────────────────────────────────────────────────────
assert_absent_code "不调用 make clean" "$SCRIPT" "make clean"
assert_absent_code "不写 ~/Applications" "$SCRIPT" '$HOME/Applications'
assert_absent_code "不碰 LaunchAgent" "$SCRIPT" "launchctl"
assert_absent_code "不启动 GUI" "$SCRIPT" "open -a"
assert_absent_code "不读 Keychain" "$SCRIPT" "find-generic-password"
assert_absent_code "不做公证" "$SCRIPT" "notarytool"
assert_absent_code "不关 Gatekeeper" "$SCRIPT" "spctl"
assert_absent_code "hdiutil create 不用 -ov 静默覆盖" "$SCRIPT" "create -ov"
# 注意匹配的是参数解析分支 `--force)`，不是 codesign 自己的 --force 开关。
assert_absent_code "参数解析里不再有 --force 分支" "$SCRIPT" "--force)"
assert_contains "用 mktemp 做独立 staging" "$SCRIPT" "mktemp -d"
assert_contains "只读挂载" "$SCRIPT" "-readonly"
assert_contains "做 hdiutil verify" "$SCRIPT" "hdiutil verify"
assert_contains "核实 load commands 的 minos" "$SCRIPT" "vtool -show-build"
assert_contains "核实架构" "$SCRIPT" "lipo -archs"
assert_contains "核实签名形态是 ad-hoc" "$SCRIPT" "Signature=adhoc"

# ── 参数处理 ──────────────────────────────────────────────────────────────────
run_check "--help 正常退出" 0 --help
run_check "未知参数" 64 --bogus
run_check "--force 已移除，按未知参数拒绝" 64 --check --force
run_check "--output 缺值" 64 --check --output
run_check "正常 --check 通过" 0 --check "${DIRTY[@]}" --output "$TMP/fresh"

# --check 不得创建输出目录，也不得写任何产物。
if [[ -e $TMP/fresh ]]; then bad "--check 创建了输出目录"; else ok "--check 没有创建输出目录"; fi

# ── 输出路径边界（P1）─────────────────────────────────────────────────────────
run_check "输出路径为空" 66 --check "${DIRTY[@]}" --output ''
run_check "输出路径是根目录" 66 --check "${DIRTY[@]}" --output /
printf 'x\n' > "$TMP/plain-file"
run_check "输出路径已存在但是文件" 66 --check "${DIRTY[@]}" --output "$TMP/plain-file"
run_check "输出目录的父路径不是目录" 66 --check "${DIRTY[@]}" --output "$TMP/plain-file/sub"
ln -s "$TMP/nowhere" "$TMP/dangling-dir"
run_check "输出目录是悬空符号链接" 66 --check "${DIRTY[@]}" --output "$TMP/dangling-dir"

# ── 输出叶子拒绝规则（P1 的核心）──────────────────────────────────────────────
# 三个叶子分别是 DMG / SHA256SUMS / build-info。符号链接（含悬空）必须拒绝，否则
# 后续写入会落到链接指向的外部路径上 —— 这正是本轮整改的那个越界写入。
OUT="$TMP/out"; mkdir -p "$OUT"
EXT="$TMP/external"; mkdir -p "$EXT"
printf 'SENTINEL-MUST-NOT-CHANGE\n' > "$EXT/sentinel.txt"
SENTINEL_BEFORE=$(shasum -a 256 "$EXT/sentinel.txt" | awk '{print $1}')
INFO_BASENAME="${SCRIPT_DMG:r}.build-info.txt"

for leaf in "$SCRIPT_DMG" SHA256SUMS "$INFO_BASENAME"; do
  # 1) 指向外部真实文件的链接
  ln -s "$EXT/sentinel.txt" "$OUT/$leaf"
  run_check "叶子 $leaf 是指向外部文件的符号链接" 69 --check "${DIRTY[@]}" --output "$OUT"
  rm -f "$OUT/$leaf"
  # 2) 悬空链接（-e 判不出来，必须靠 -L）
  ln -s "$EXT/does-not-exist.txt" "$OUT/$leaf"
  run_check "叶子 $leaf 是悬空符号链接" 69 --check "${DIRTY[@]}" --output "$OUT"
  rm -f "$OUT/$leaf"
  # 3) 目录
  mkdir -p "$OUT/$leaf"
  run_check "叶子 $leaf 是目录" 69 --check "${DIRTY[@]}" --output "$OUT"
  rmdir "$OUT/$leaf"
  # 4) 普通文件已存在
  printf 'old\n' > "$OUT/$leaf"
  run_check "叶子 $leaf 已存在" 69 --check "${DIRTY[@]}" --output "$OUT"
  rm -f "$OUT/$leaf"
done

# 5) 特殊文件（FIFO）
mkfifo "$OUT/$SCRIPT_DMG"
run_check "叶子是 FIFO 特殊文件" 69 --check "${DIRTY[@]}" --output "$OUT"
rm -f "$OUT/$SCRIPT_DMG"

assert_eq "sentinel 内容未被改动" "$SENTINEL_BEFORE" "$(shasum -a 256 "$EXT/sentinel.txt" | awk '{print $1}')"
ln -s "$EXT/sentinel.txt" "$OUT/keep-link"
run_check "输出目录里无关的符号链接不影响通过（不过度拒绝）" 0 --check "${DIRTY[@]}" --output "$OUT"
if [[ -L $OUT/keep-link && $(readlink "$OUT/keep-link") == "$EXT/sentinel.txt" ]]; then
  ok "无关符号链接未被删除或改写"
else
  bad "无关符号链接被动过了"
fi
if [[ -z $(find "$OUT" -type f 2>/dev/null) ]]; then
  ok "--check 全程只读：输出目录里没有生成任何普通文件"
else
  bad "--check 在输出目录里写了文件：$(find "$OUT" -type f | tr '\n' ' ')"
fi

# ── 最终提交的竞争窗口（R2）────────────────────────────────────────────────────
# 前面两轮叶子检查缩小了窗口，但「查完」到「真正写」之间仍有窗口。实测普通 `mv` 与
# `mv -n` 对「指向目录的符号链接」都返回 0 并把产物写进了链接指向的目录 —— `mv -n`
# 只挡得住「目标是已存在的文件」。所以落地改用 O_CREAT|O_EXCL 独占创建。
#
# `--commit-probe` 走的就是正式落地所用的那同一个 commit_artifact 函数，因此下面这些
# 用例是**确定性**的：直接把各种占用形态摆在叶子上，不需要去赌微秒级的竞争窗口。
PROBE_DIR="$TMP/commit"; mkdir -p "$PROBE_DIR/out" "$PROBE_DIR/ext/realdir"
PROBE_SRC="$PROBE_DIR/src.bin"
printf 'ARTIFACT-PAYLOAD\n' > "$PROBE_SRC"
printf 'SENTINEL-MUST-NOT-CHANGE\n' > "$PROBE_DIR/ext/sentinel.txt"
PROBE_SENTINEL_BEFORE=$(shasum -a 256 "$PROBE_DIR/ext/sentinel.txt" | awk '{print $1}')

probe_reject() {  # probe_reject <用例名> <目标路径>
  local name=$1 dst=$2 out code
  out=$("$SCRIPT" --commit-probe "$PROBE_SRC" "$dst" 2>&1); code=$?
  if (( code == 69 )); then ok "$name（退出码 69）"
  else bad "$name：期望退出码 69，实际 $code — ${out//$'\n'/ / }"; fi
}

for leaf in "$SCRIPT_DMG" SHA256SUMS "$INFO_BASENAME"; do
  D="$PROBE_DIR/out/$leaf"
  short=${leaf:0:28}

  # 1) 目标是已存在的普通文件 —— 不得覆盖
  printf 'PRE-EXISTING\n' > "$D"
  probe_reject "提交：$short 位置是普通文件" "$D"
  assert_eq "  └ 原文件未被覆盖" 'PRE-EXISTING' "$(cat "$D")"
  rm -f "$D"

  # 2) 目标是目录 —— 不得被当成容器把文件塞进去（mv / mv -n 都挡不住这一种）
  mkdir -p "$D"
  probe_reject "提交：$short 位置是目录" "$D"
  if [[ -z $(ls -A "$D") ]]; then ok "  └ 目录内未被塞入文件"; else bad "  └ 目录被当成容器了：$(ls -A "$D")"; fi
  rmdir "$D"

  # 3) 目标是指向目录的符号链接 —— 不得沿链接写进目标目录，链接本身也不得被替换
  ln -s "$PROBE_DIR/ext/realdir" "$D"
  probe_reject "提交：$short 位置是目录符号链接" "$D"
  if [[ -z $(ls -A "$PROBE_DIR/ext/realdir") ]]; then ok "  └ 链接目标目录内未被写入"; else bad "  └ 写进了链接目标目录"; fi
  if [[ -L $D ]]; then ok "  └ 链接本身未被替换"; else bad "  └ 链接被替换成了普通文件"; fi
  rm -f "$D"

  # 4) 目标是指向外部文件的符号链接
  ln -s "$PROBE_DIR/ext/sentinel.txt" "$D"
  probe_reject "提交：$short 位置是文件符号链接" "$D"
  rm -f "$D"

  # 5) 目标是悬空符号链接（-e 判不出来，只有 O_EXCL 才挡得住）
  ln -s "$PROBE_DIR/ext/nowhere" "$D"
  probe_reject "提交：$short 位置是悬空符号链接" "$D"
  rm -f "$D"
done

assert_eq "提交探针全程未改动 sentinel" "$PROBE_SENTINEL_BEFORE" \
  "$(shasum -a 256 "$PROBE_DIR/ext/sentinel.txt" | awk '{print $1}')"

# 正常路径必须仍然成功，且内容逐字节一致。
FRESH="$PROBE_DIR/out/fresh.bin"
out=$("$SCRIPT" --commit-probe "$PROBE_SRC" "$FRESH" 2>&1); code=$?
if (( code == 0 )); then ok "提交：目标空闲时成功（退出码 0）"
else bad "提交：目标空闲时应成功，实际 $code — ${out//$'\n'/ / }"; fi
assert_eq "落地内容与源逐字节一致" \
  "$(shasum -a 256 "$PROBE_SRC" | awk '{print $1}')" \
  "$(shasum -a 256 "$FRESH" | awk '{print $1}')"
# 同一个路径再提交一次必须被拒绝（证明它确实是独占创建而不是幂等覆盖）。
probe_reject "提交：同一路径重复提交被拒绝" "$FRESH"

# 接线：三个正式叶子必须都走 commit_artifact，且落地阶段不得再出现普通 mv。
PUBLISH_BODY=$(awk '/^publish_artifacts\(\) \{/,/^\}/' "$SCRIPT")
# 只数「行首就是调用」的那几行，避免把注释里提到的函数名也算进来。
commit_calls=$(print -r -- "$PUBLISH_BODY" | grep -cE '^[[:space:]]*commit_artifact ')
assert_eq "publish_artifacts 对三个叶子都调用 commit_artifact" "3" "$commit_calls"
if print -r -- "$PUBLISH_BODY" | grep -qE '^\s*(mv|cp|ln) '; then
  bad "publish_artifacts 里还在用 mv/cp/ln 落地"
else
  ok "publish_artifacts 里没有 mv/cp/ln 落地"
fi
assert_contains "提交用 O_CREAT|O_EXCL 独占创建" "$SCRIPT" "sysopen -w -o creat,excl"
assert_contains "加载了 zsh/system 模块" "$SCRIPT" "zmodload zsh/system"
assert_contains "落地后按 SHA256 回验" "$SCRIPT" "落地后 SHA256 与 staging 不一致"
assert_contains "失败时回滚本次已落地产物" "$SCRIPT" "回滚本次已落地的"

# ── 摘要失败路径（R3）─────────────────────────────────────────────────────────
# commit_artifact 以前用 `shasum … | awk …` 取摘要。在 set -e + pipefail 下，目标侧
# shasum 非 0 退出会让那条赋值语句直接终止脚本：跳过写好的显式失败处理、以 shasum 的
# 退出码退出，而此时文件已经被独占创建、却还没登记进 COMMITTED，于是留在输出目录里。
#
# 这里用一个**本测试自己写的 shasum 替身**确定性地复现那条路径：替身只对指定路径返回
# 74，其它一律转发给真正的 shasum。替身和所有目标都在全新的 mktemp 目录内，不读任何
# 凭据、不使用任何旧探针目录；走的是公开入口里真实的那个函数，也没有为测试放宽任何
# 安全检查。
SHADIR=$(mktemp -d "$TMP/sha-stub.XXXXXX") || exit 70
mkdir -p "$SHADIR/bin" "$SHADIR/out"
printf 'DIGEST-PATH-PAYLOAD\n' > "$SHADIR/src.bin"
cat > "$SHADIR/bin/shasum" <<'STUB'
#!/bin/sh
# 测试替身：对 $SHASUM_FAIL_FOR 指定的那个路径返回 74，其它一律转发给真正的 shasum。
if [ -n "${SHASUM_FAIL_FOR:-}" ]; then
  for a in "$@"; do
    [ "$a" = "$SHASUM_FAIL_FOR" ] && exit 74
  done
fi
exec /usr/bin/shasum "$@"
STUB
chmod +x "$SHADIR/bin/shasum"

# 先确认替身在不触发失败条件时是透明的，否则后面的断言可能是假阳性。
if [[ $(PATH="$SHADIR/bin:$PATH" shasum -a 256 -- "$SHADIR/src.bin" 2>&1) \
      == $(/usr/bin/shasum -a 256 -- "$SHADIR/src.bin") ]]; then
  ok "shasum 替身未触发时与真实 shasum 一致（断言非假阳性）"
else
  bad "shasum 替身不透明，后续断言不可信"
fi

# 1) 目标侧摘要**执行失败** → 必须 70，且不得把已独占创建的文件留在输出目录
DST_FAIL="$SHADIR/out/dest-digest-fails.bin"
out=$(PATH="$SHADIR/bin:$PATH" SHASUM_FAIL_FOR="$DST_FAIL" \
      "$SCRIPT" --commit-probe "$SHADIR/src.bin" "$DST_FAIL" 2>&1); code=$?
assert_eq "目标摘要执行失败时退出码 70" "70" "$code"
if [[ -e $DST_FAIL ]]; then
  bad "  └ 目标摘要失败后仍留下文件（$(stat -f '%z' "$DST_FAIL" 2>/dev/null) 字节）"
else
  ok "  └ 已删除本轮创建的未完成文件"
fi
if print -r -- "$out" | grep -qF '读不出目标文件摘要'; then
  ok "  └ 有明确的失败原因"
else
  bad "  └ 没有明确的失败原因：${out//$'\n'/ / }"
fi

# 2) 源侧摘要执行失败 → 必须 70，且根本不该创建目标
SRC_FAIL_DST="$SHADIR/out/src-digest-fails.bin"
out=$(PATH="$SHADIR/bin:$PATH" SHASUM_FAIL_FOR="$SHADIR/src.bin" \
      "$SCRIPT" --commit-probe "$SHADIR/src.bin" "$SRC_FAIL_DST" 2>&1); code=$?
assert_eq "源摘要执行失败时退出码 70" "70" "$code"
if [[ -e $SRC_FAIL_DST ]]; then
  bad "  └ 源摘要失败却创建了目标文件"
else
  ok "  └ 没有创建任何目标文件"
fi

# 3) 摘要失败绝不能牵连既存文件：目标被占用时应在独占创建那一步就以 69 拒绝
PRE="$SHADIR/out/pre-existing.bin"
printf 'PRE-EXISTING-KEEP\n' > "$PRE"
PRE_BEFORE=$(/usr/bin/shasum -a 256 -- "$PRE" | awk '{print $1}')
out=$(PATH="$SHADIR/bin:$PATH" SHASUM_FAIL_FOR="$PRE" \
      "$SCRIPT" --commit-probe "$SHADIR/src.bin" "$PRE" 2>&1); code=$?
assert_eq "目标已存在时仍先以 69 拒绝（替身不改变这一点）" "69" "$code"
assert_eq "  └ 既存文件未被删除或改动" "$PRE_BEFORE" \
  "$(/usr/bin/shasum -a 256 -- "$PRE" | awk '{print $1}')"

# 4) 替身在位但不触发失败时，正常路径仍必须成功
NORMAL="$SHADIR/out/normal.bin"
out=$(PATH="$SHADIR/bin:$PATH" "$SCRIPT" --commit-probe "$SHADIR/src.bin" "$NORMAL" 2>&1); code=$?
assert_eq "替身在位但未触发时正常路径仍成功" "0" "$code"
assert_eq "  └ 落地内容逐字节一致" \
  "$(/usr/bin/shasum -a 256 -- "$SHADIR/src.bin" | awk '{print $1}')" \
  "$(/usr/bin/shasum -a 256 -- "$NORMAL" | awk '{print $1}')"

# 5) 结构断言：取摘要不再经管道（管道才是 set -e + pipefail 下跳过失败处理的根因）
assert_contains "改用可捕获退出码的 file_sha256" "$SCRIPT" "file_sha256()"
assert_contains "摘要取字段不经管道" "$SCRIPT" '${out%% *}'
assert_contains "记录本轮未完成的叶子以便清理" "$SCRIPT" "PENDING_LEAF"
assert_contains "文档说明原子的是独占创建而非内容复制" "$SCRIPT" "不是文件内容的复制过程"
assert_contains "文档说明 SIGKILL / 断电不保证清理" "$SCRIPT" "trap 不运行，不保证清理"

# ── Git 来源校验（P2）─────────────────────────────────────────────────────────
# 全部在独立合成仓库里做。查不到来源绝不能降级成 clean。
G="$TMP/git"; mkdir -p "$G"

mk_src "$G/norepo"
run_check_in "$G/norepo" "来源不是 Git 仓库" 66 --check --output "$TMP/g1"

mk_src "$G/nohead"
( cd "$G/nohead" && git init -q . )
run_check_in "$G/nohead" "Git 仓库但没有有效 HEAD" 66 --check --output "$TMP/g2"

mk_src "$G/clean"
( cd "$G/clean" && git init -q . && git add -A \
  && git -c user.name=t -c user.email=t@example.invalid commit -qm init )
run_check_in "$G/clean" "干净的合成仓库通过" 0 --check --output "$TMP/g3"

printf 'extra\n' > "$G/clean/untracked.txt"
run_check_in "$G/clean" "脏树默认被拒绝" 66 --check --output "$TMP/g4"
run_check_in "$G/clean" "脏树加 --allow-dirty 通过" 0 --check --allow-dirty --output "$TMP/g5"
rm -f "$G/clean/untracked.txt"

mk_src "$G/clean/subdir"
run_check_in "$G/clean/subdir" "从仓库子目录运行被拒绝（不借父仓库 HEAD）" 66 \
  --check --allow-dirty --output "$TMP/g6"
rm -rf "$G/clean/subdir"

# git status 查询失败：把索引设为不可读，status 会以非 0 退出。
chmod 000 "$G/clean/.git/index"
run_check_in "$G/clean" "git status 查询失败被拒绝（不当成 clean）" 66 --check --output "$TMP/g7"
chmod 644 "$G/clean/.git/index"

# ── 失败路径：输出目录不留半成品，staging 作为证据保留（P4）─────────────────────
# 在合成仓库里跑**完整**流程（不是 --check）：前置校验会通过，随后 make 会因为缺少
# 真实源码与图标而很快失败。这条用例一次验证三件事：失败退出码是 70、输出目录里
# 什么都没留下、staging 被保留且路径被打印出来（所以错误信息引用的日志路径仍然有效）。
# 它顺带守住 cleanup 本身能跑完 —— zsh 里 `local status=` 会让 cleanup 中途报错退出。
FAILOUT="$TMP/failout"
fail_out=$( cd "$G/clean" && "$SCRIPT_ABS" --output "$FAILOUT" 2>&1 ); fail_rc=$?
if (( fail_rc == 70 )); then
  ok "失败路径退出码 70"
else
  bad "失败路径退出码应为 70，实际 $fail_rc — ${fail_out//$'\n'/ / }"
fi
if [[ -d $FAILOUT && -n $(find "$FAILOUT" -mindepth 1 2>/dev/null) ]]; then
  bad "失败后输出目录里留下了东西：$(find "$FAILOUT" -mindepth 1 | tr '\n' ' ')"
else
  ok "失败后输出目录里没有任何产物（不留半成品）"
fi
KEPT=$(print -r -- "$fail_out" | sed -n 's/^build-release: 失败证据保留在 \(.*\)（未自动删除.*$/\1/p' | head -1)
if [[ -n $KEPT && -d $KEPT ]]; then
  ok "失败时 staging 被保留且路径已打印"
  rm -rf "$KEPT"
else
  bad "失败时没有保留 staging 证据或没打印路径"
fi
assert_absent_code "cleanup 不使用 zsh 只读特殊变量 status" "$SCRIPT" "local status="

# ── 签名身份契约（P3）─────────────────────────────────────────────────────────
# 用 make -n 干跑，不会真的编译或签名。先证明「不显式赋值就会泄漏环境身份」（也就是
# 本轮修掉的那个 bug），再证明脚本实际使用的那组参数能把它压成 ad-hoc。
DRY="$TMP/dry"
leak=$(env CODESIGN_IDENTITY=REVIEW_SENTINEL make -n test \
  BUILD_DIR="$DRY" SWIFTFLAGS="-target arm64-apple-macos$PLIST_MIN_OS" 2>&1 \
  | grep -F 'codesign --force' || true)
if print -r -- "$leak" | grep -qF 'REVIEW_SENTINEL'; then
  ok "对照：不显式赋值时环境里的 CODESIGN_IDENTITY 确实会被继承（说明这条断言非空转）"
else
  bad "对照用例失效：没能复现环境继承，后面的断言可能是空转"
fi

pinned=$(env CODESIGN_IDENTITY=REVIEW_SENTINEL make -n test \
  BUILD_DIR="$DRY" SWIFTFLAGS="-target arm64-apple-macos$PLIST_MIN_OS" CODESIGN_IDENTITY=- 2>&1 \
  | grep -F 'codesign --force' || true)
if print -r -- "$pinned" | grep -qF 'REVIEW_SENTINEL'; then
  bad "命令行显式赋值没能压住环境里的 CODESIGN_IDENTITY"
else
  ok "命令行显式赋值压住了环境里的 CODESIGN_IDENTITY"
fi
if print -r -- "$pinned" | grep -qF -- '--sign "-"'; then
  ok "干跑出来的签名命令确实是 ad-hoc（--sign \"-\"）"
else
  bad "干跑出来的签名命令不是 ad-hoc：$pinned"
fi

# 脚本必须真的把这个赋值传给 make（否则上面的契约用不上）。
if grep -v '^[[:space:]]*#' "$SCRIPT" | grep -qF 'CODESIGN_IDENTITY="$ADHOC_IDENTITY"'; then
  ok "脚本把 CODESIGN_IDENTITY 显式传给了 make"
else
  bad "脚本没有把 CODESIGN_IDENTITY 显式传给 make"
fi

# 普通 make 用户仍然可以自选签名身份。
user_choice=$(make -n app BUILD_DIR="$DRY" CODESIGN_IDENTITY='REVIEW_USER_CERT' 2>&1 \
  | grep -F 'codesign --force' || true)
if print -r -- "$user_choice" | grep -qF 'REVIEW_USER_CERT'; then
  ok "普通 make 用户仍可自选签名身份（Makefile 能力保留）"
else
  bad "Makefile 丢掉了用户自选签名身份的能力"
fi

print -r -- ""
print -r -- "结果: $pass 通过 · $fail 失败 · $skip 跳过"
print -r -- "（全程在测试自己的临时目录内：含 --check、make -n 干跑、commit-probe 实际写文件、"
print -r -- "  以及一次故意失败的合成仓库构建；未完整编译、未打包、未挂载、未签名、未安装。）"

(( fail == 0 )) || exit 1
