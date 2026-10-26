#!/bin/zsh
# Scripts/install-launch-agent.sh 的 --check 校验回归。
#
# 只调用 --check。不执行任何真实安装动作：不碰你的 ~/Applications、不碰 LaunchAgent、
# 不启动或终止任何进程、不改任何配置。全程在任务私有的临时目录里跑，并把 HOME 指向
# 该临时目录，所以被校验的"安装目标"也落在临时目录内。
#
# 用的是合成的最小 .app：只包含校验会读到的 Contents/Info.plist 与一个带可执行位的
# 占位 Contents/MacOS/AIQuotaBar。该占位文件从不被执行。
#
# 每个用例都会比对执行前后的临时目录快照：普通文件比**内容 SHA256**、目录比权限、
# 符号链接只比 readlink 目标 —— 绝不跟随链接去读它指向的树。这样才能证明 --check
# 既没有改动任何文件内容，也没有删掉或重写任何链接。
#
# 这不是真实安装的集成测试。它只覆盖 --check 的校验与拒绝边界，不验证 ditto、
# launchctl bootstrap/kickstart 或 plist 写入是否正确 —— 那些动作本测试刻意不触发。
set -uo pipefail

ROOT=${0:A:h:h}
SCRIPT=$ROOT/Scripts/install-launch-agent.sh

if [[ ! -x $SCRIPT ]]; then
  print -r -- "找不到可执行的 $SCRIPT" >&2
  exit 70
fi

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/AIQuotaBar-install-check.XXXXXX") || exit 70
trap 'rm -rf "$TMPROOT"' EXIT

FAKE_HOME=$TMPROOT/home
mkdir -p "$FAKE_HOME"

typeset -i pass=0 fail=0 skip=0
LAST_OUT=''

# 造一个最小的合成 AIQuotaBar.app。
#   make_app <app路径> [bundle id] [是否放可执行文件 1/0] [是否给可执行位 1/0]
make_app() {
  local app=$1 id=${2:-com.local.aiquotabar} with_exe=${3:-1} exec_bit=${4:-1}
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$id</string>
</dict>
</plist>
PLIST
  if (( with_exe )); then
    printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/AIQuotaBar"
    (( exec_bit )) && chmod +x "$app/Contents/MacOS/AIQuotaBar"
  fi
}

# 为需要独立「安装目标状态」的用例新建一个干净的临时 HOME。
fresh_home() {
  local h=$TMPROOT/home-$1
  mkdir -p "$h/Applications"
  print -r -- "$h"
}

# 对临时目录整棵树做快照，用来断言 --check 零副作用。
#   普通文件 → 内容 SHA256（不只是大小/权限，这样内容被改写也能发现）
#   目录     → 权限
#   符号链接 → 只记 readlink 目标，**绝不跟随链接**读取它指向的树
# find 默认用 lstat、不跟随链接；这里也只对链接调 readlink。
# 前提：夹具路径里没有换行符（本测试自己造的路径都满足）。
snapshot() {
  find "$TMPROOT" \( -type d -o -type f -o -type l \) 2>/dev/null | sort | while IFS= read -r p; do
    if [[ -L $p ]]; then
      print -r -- "L|$p|$(readlink "$p")"
    elif [[ -d $p ]]; then
      print -r -- "D|$p|$(stat -f '%Sp' "$p" 2>/dev/null)"
    else
      print -r -- "F|$p|$(stat -f '%Sp' "$p" 2>/dev/null)|$(shasum -a 256 "$p" 2>/dev/null | awk '{print $1}')"
    fi
  done
}

# run_check <用例名> <期望退出码> <HOME> <BUILD_DIR 或 -> [传给脚本的参数...]
run_check() {
  local name=$1 want=$2 home=$3 bdir=$4
  shift 4
  local before after code ok=1

  before=$(snapshot)
  if [[ $bdir == - ]]; then
    LAST_OUT=$(env -u BUILD_DIR HOME="$home" "$SCRIPT" --check "$@" 2>&1)
  else
    LAST_OUT=$(env HOME="$home" BUILD_DIR="$bdir" "$SCRIPT" --check "$@" 2>&1)
  fi
  code=$?
  after=$(snapshot)

  if (( code != want )); then
    print -r -- "  FAIL  $name：期望退出码 $want，实际 $code"
    print -r -- "        输出: ${LAST_OUT//$'\n'/ / }"
    ok=0
  fi
  if [[ $before != $after ]]; then
    print -r -- "  FAIL  $name：--check 改动了临时目录（应当零副作用）"
    ok=0
  fi
  if (( ok )); then
    print -r -- "  PASS  $name（退出码 $code，临时目录未变）"
    (( pass += 1 ))
  else
    (( fail += 1 ))
  fi
}

# 断言上一次 run_check 的输出含某段文本（用于验证默认路径推导）。
assert_match() {
  local name=$1 needle=$2
  if [[ $LAST_OUT == *"$needle"* ]]; then
    print -r -- "  PASS  $name"
    (( pass += 1 ))
  else
    print -r -- "  FAIL  $name：输出里找不到 '$needle'"
    (( fail += 1 ))
  fi
}

note_skip() {
  print -r -- "  SKIP  $1"
  (( skip += 1 ))
}

print -r -- "install-launch-agent.sh --check 回归（临时根: $TMPROOT）"
print -r -- ""

# ── 有效源 ────────────────────────────────────────────────────────────────────
make_app "$TMPROOT/build/AIQuotaBar.app"
run_check "普通有效源" 0 "$FAKE_HOME" - "$TMPROOT/build/AIQuotaBar.app"

mkdir -p "$TMPROOT/with space"
make_app "$TMPROOT/with space/AIQuotaBar.app"
run_check "路径含空格的有效源" 0 "$FAKE_HOME" - "$TMPROOT/with space/AIQuotaBar.app"

# ── 默认路径推导（与 Makefile 的 BUILD_DIR 对齐）────────────────────────────────
run_check "不传参数时按 BUILD_DIR 推导出有效源" 0 "$FAKE_HOME" "$TMPROOT/build"

run_check "不传参数且 BUILD_DIR 指向不存在的目录" 66 "$FAKE_HOME" "$TMPROOT/missing"
assert_match "错误信息里是 BUILD_DIR 推导出的路径" "missing/AIQuotaBar.app"

run_check "显式参数优先于 BUILD_DIR" 0 "$FAKE_HOME" "$TMPROOT/missing" "$TMPROOT/build/AIQuotaBar.app"

if [[ -e /tmp/AIQuotaBar-build/AIQuotaBar.app ]]; then
  note_skip "BUILD_DIR 未设时回落到 /tmp/AIQuotaBar-build（本机该路径已存在，跳过以保持判定确定）"
else
  run_check "BUILD_DIR 未设时回落到 /tmp/AIQuotaBar-build" 66 "$FAKE_HOME" -
  assert_match "错误信息里是硬编码的默认路径" "AIQuotaBar-build/AIQuotaBar.app"
fi

# ── 源与目标冲突（旧脚本会先 rm 目标再 ditto，源等于目标即丢源）──────────────────
make_app "$FAKE_HOME/Applications/AIQuotaBar.app"
run_check "源与安装目标同一路径" 69 "$FAKE_HOME" - "$FAKE_HOME/Applications/AIQuotaBar.app"

ln -s "$FAKE_HOME/Applications/AIQuotaBar.app" "$TMPROOT/alias.app"
run_check "经符号链接别名指向安装目标" 69 "$FAKE_HOME" - "$TMPROOT/alias.app"

run_check "路径里带 .. 绕回安装目标" 69 "$FAKE_HOME" - \
  "$FAKE_HOME/Applications/../Applications/AIQuotaBar.app"

make_app "$FAKE_HOME/Applications/AIQuotaBar.app/inner/AIQuotaBar.app"
run_check "源位于安装目标内部" 69 "$FAKE_HOME" - \
  "$FAKE_HOME/Applications/AIQuotaBar.app/inner/AIQuotaBar.app"

# 把 HOME 放进一个有效 bundle 内部，使安装目标落在源内部。
NESTED_HOME=$TMPROOT/outer.app/home
make_app "$TMPROOT/outer.app"
mkdir -p "$NESTED_HOME"
run_check "安装目标位于源内部" 69 "$NESTED_HOME" - "$TMPROOT/outer.app"

# ── 源不可用 ──────────────────────────────────────────────────────────────────
run_check "源不存在" 66 "$FAKE_HOME" - "$TMPROOT/nope/AIQuotaBar.app"

printf 'not a bundle\n' > "$TMPROOT/plain-file"
run_check "源是文件不是目录" 66 "$FAKE_HOME" - "$TMPROOT/plain-file"

run_check "显式传入空字符串" 66 "$FAKE_HOME" - ""
run_check "源是根目录" 66 "$FAKE_HOME" - "/"

# ── 源不是有效的 AIQuotaBar.app ────────────────────────────────────────────────
mkdir -p "$TMPROOT/no-plist.app/Contents/MacOS"
run_check "缺 Contents/Info.plist" 65 "$FAKE_HOME" - "$TMPROOT/no-plist.app"

make_app "$TMPROOT/wrong-id.app" "com.example.other"
run_check "CFBundleIdentifier 不符" 65 "$FAKE_HOME" - "$TMPROOT/wrong-id.app"

make_app "$TMPROOT/no-exe.app" "com.local.aiquotabar" 0
run_check "缺 Contents/MacOS/AIQuotaBar" 65 "$FAKE_HOME" - "$TMPROOT/no-exe.app"

make_app "$TMPROOT/no-exec-bit.app" "com.local.aiquotabar" 1 0
run_check "可执行文件缺可执行位" 65 "$FAKE_HOME" - "$TMPROOT/no-exec-bit.app"

# ── 用法错误 ──────────────────────────────────────────────────────────────────
run_check "未知选项" 64 "$FAKE_HOME" - "--bogus"
run_check "参数过多" 64 "$FAKE_HOME" - "$TMPROOT/build/AIQuotaBar.app" "$TMPROOT/outer.app"

# ── 安装目标本身不可用（R2 / P1）────────────────────────────────────────────────
# 安装会 rm -rf 安装目标。如果目标是符号链接而校验跟着链接走，删掉的就是链接指向的
# 任意目录。下面每个用例都用同一个合法源，只改变「安装目标」的状态。
SRC_OK=$TMPROOT/build/AIQuotaBar.app

mkdir -p "$TMPROOT/unrelated-data"
printf 'must-not-delete\n' > "$TMPROOT/unrelated-data/sentinel.txt"
H=$(fresh_home sym-unrelated)
ln -s "$TMPROOT/unrelated-data" "$H/Applications/AIQuotaBar.app"
run_check "目标是符号链接 → 无关目录（含 sentinel）" 73 "$H" - "$SRC_OK"

make_app "$TMPROOT/another-valid.app"
H=$(fresh_home sym-validapp)
ln -s "$TMPROOT/another-valid.app" "$H/Applications/AIQuotaBar.app"
run_check "目标是符号链接 → 另一个合法 app" 73 "$H" - "$SRC_OK"

H=$(fresh_home sym-root)
ln -s / "$H/Applications/AIQuotaBar.app"
run_check "目标是符号链接 → 根目录" 73 "$H" - "$SRC_OK"

H=$(fresh_home sym-dangling)
ln -s "$TMPROOT/does-not-exist" "$H/Applications/AIQuotaBar.app"
run_check "目标是悬空符号链接" 73 "$H" - "$SRC_OK"

H=$(fresh_home plain-dir)
mkdir -p "$H/Applications/AIQuotaBar.app"
printf 'must-not-delete\n' > "$H/Applications/AIQuotaBar.app/sentinel.txt"
run_check "目标已存在但是普通无关目录（含 sentinel）" 73 "$H" - "$SRC_OK"

H=$(fresh_home dest-file)
printf 'x\n' > "$H/Applications/AIQuotaBar.app"
run_check "目标已存在但是普通文件" 73 "$H" - "$SRC_OK"

# ── 合法的两种目标状态仍应通过 ──────────────────────────────────────────────────
H=$(fresh_home dest-absent)
run_check "目标不存在（首次安装）" 0 "$H" - "$SRC_OK"

H=$(fresh_home dest-upgrade)
make_app "$H/Applications/AIQuotaBar.app"
run_check "目标是已存在的合法 app（正常升级）" 0 "$H" - "$SRC_OK"

# ── 磁盘实际叶子名与固定安装叶子大小写不同（R3 / P1）──────────────────────────────
# 安装目标的叶子刻意保持字面量 `AIQuotaBar.app`，但磁盘上可能叫 `aiquotabar.app`。
# 在 Mac 默认的大小写不敏感卷上那是同一个文件，必须认出来，否则 rm -rf 会删掉源。
# 先探测本卷：大小写敏感卷上这些用例不成立，明确 SKIP，不伪造通过。
mkdir -p "$TMPROOT/CaseProbe"
if [[ -d $TMPROOT/caseprobe ]]; then
  typeset -i CASE_INSENSITIVE=1
else
  typeset -i CASE_INSENSITIVE=0
fi
rmdir "$TMPROOT/CaseProbe"

if (( CASE_INSENSITIVE )); then
  H=$(fresh_home case-actual-lower)
  make_app "$H/Applications/aiquotabar.app"
  run_check "磁盘叶子是小写、源传该实际路径" 69 "$H" - "$H/Applications/aiquotabar.app"

  H=$(fresh_home case-input-upper)
  make_app "$H/Applications/aiquotabar.app"
  run_check "磁盘叶子小写、源用固定叶子的大写拼写（同一文件）" 69 "$H" - "$H/Applications/AIQuotaBar.app"

  H=$(fresh_home case-nested)
  make_app "$H/Applications/aiquotabar.app"
  make_app "$H/Applications/aiquotabar.app/inner/AIQuotaBar.app"
  run_check "源位于小写磁盘叶子目标内部" 69 "$H" - "$H/Applications/aiquotabar.app/inner/AIQuotaBar.app"

  H=$(fresh_home case-lower-upgrade)
  make_app "$H/Applications/aiquotabar.app"
  run_check "磁盘叶子小写、源是无关的另一个合法 app（仍应放行）" 0 "$H" - "$SRC_OK"
else
  note_skip "磁盘叶子是小写、源传该实际路径（本卷大小写敏感）"
  note_skip "磁盘叶子小写、源用固定叶子的大写拼写（本卷大小写敏感）"
  note_skip "源位于小写磁盘叶子目标内部（本卷大小写敏感）"
  note_skip "磁盘叶子小写、源是无关的另一个合法 app（本卷大小写敏感）"
fi

# ── 终局总检：sentinel 与链接一个都没动 ────────────────────────────────────────
for s in "$TMPROOT/unrelated-data/sentinel.txt" \
         "$TMPROOT/home-plain-dir/Applications/AIQuotaBar.app/sentinel.txt"; do
  if [[ -f $s && $(cat "$s") == 'must-not-delete' ]]; then
    print -r -- "  PASS  sentinel 完好且内容未变：${s:h:t}/${s:t}"
    (( pass += 1 ))
  else
    print -r -- "  FAIL  sentinel 丢失或被改：$s"
    (( fail += 1 ))
  fi
done

for pair in "sym-unrelated:$TMPROOT/unrelated-data" "sym-root:/" "sym-dangling:$TMPROOT/does-not-exist"; do
  link=$TMPROOT/home-${pair%%:*}/Applications/AIQuotaBar.app
  want=${pair#*:}
  if [[ -L $link && $(readlink "$link") == "$want" ]]; then
    print -r -- "  PASS  链接仍是链接且目标未变：${pair%%:*}"
    (( pass += 1 ))
  else
    print -r -- "  FAIL  链接被删除或改写：$link"
    (( fail += 1 ))
  fi
done

print -r -- ""
print -r -- "结果: $pass 通过 · $fail 失败 · $skip 跳过"
print -r -- "（全程只跑 --check；未安装、未触碰用户应用 / LaunchAgent / 配置。）"

(( fail == 0 )) || exit 1
