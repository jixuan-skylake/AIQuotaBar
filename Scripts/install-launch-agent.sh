#!/bin/zsh
# 把构建好的 AIQuotaBar.app 安装到 ~/Applications 并写入 LaunchAgent（登录自启）。
#
# 用法：
#   ./Scripts/install-launch-agent.sh [app路径]           校验并安装
#   ./Scripts/install-launch-agent.sh --check [app路径]   只校验，不做任何改动
#   ./Scripts/install-launch-agent.sh --help
#
# 不传 app 路径时取 ${BUILD_DIR:-/tmp/AIQuotaBar-build}/AIQuotaBar.app，与 Makefile 的
# BUILD_DIR 默认值一致；显式参数优先于 BUILD_DIR。
#
# 退出码：
#   0   校验通过（--check）或安装完成
#   64  用法错误：未知选项，或给了多于一个 app 路径
#   65  源不是有效的 AIQuotaBar.app：缺 Contents/Info.plist、CFBundleIdentifier 不符，
#       或缺少带可执行位的 Contents/MacOS/AIQuotaBar
#   66  源路径不可用：为空、是根目录、不存在，或不是目录
#   69  源与安装目标冲突：同一路径，或任一位于另一个内部
#   73  安装目标不可用：它本身是符号链接，或已存在但不是合法的 AIQuotaBar bundle
#
# 为什么必须有 69 这组检查：安装会在 ditto 之前 rm -rf 安装目标。如果源就是目标
# （或位于目标内部），不检查就会把源一起删掉。源路径会被完整物理规范化，所以用别名
# 或 .. 指向目标也绕不过去；比较时还会把安装目标的叶子换成磁盘上的真实拼写，因此
# 大小写不敏感卷上 `aiquotabar.app` 与 `AIQuotaBar.app` 这种同一文件也认得出来。
#
# 为什么必须有 73 这组检查，以及源与目标的解析方式为何刻意不对称：
#   源只被读取，所以整条路径（含叶子）都做物理规范化，便于识别别名。
#   安装目标会被 rm -rf 然后写入，所以**只规范化父目录，叶子保持字面量**。
#   如果跟随叶子的符号链接，rm -rf 删掉的就是链接指向的任意目录 —— 可能是与本项目
#   完全无关的用户数据；而只删除链接本身，也会悄悄丢掉用户刻意建立的链接。两种都不做：
#   直接拒绝，让用户自己决定怎么处理那个链接。同理，已存在的目标必须确实是一个合法的
#   AIQuotaBar bundle 才允许被替换 —— 不能因为目录名字像 app 就删掉它。
set -euo pipefail

readonly BUNDLE_ID='com.local.aiquotabar'
readonly LABEL="$BUNDLE_ID"
readonly APP_DEST="$HOME/Applications/AIQuotaBar.app"
readonly PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

readonly EX_USAGE=64
readonly EX_DATAERR=65
readonly EX_NOINPUT=66
readonly EX_CONFLICT=69
readonly EX_CANTCREAT=73

usage() {
  print -r -- "用法: ${0:t} [--check] [app路径]"
  print -r -- "  不传 app 路径时取 \${BUILD_DIR:-/tmp/AIQuotaBar-build}/AIQuotaBar.app"
  print -r -- "  --check  只做校验并退出，不安装、不启动或终止进程、不创建目录、不写文件"
}

# die <退出码> <消息...>
die() {
  local code=$1
  shift
  print -r -- "install-launch-agent: $*" >&2
  exit "$code"
}

# 把路径解析成物理绝对路径：展开相对路径与 ~，并解析其中的符号链接。
# zsh 的 :A 在叶子不存在时也会把已存在的祖先解析到底，因此首次安装（目标尚未创建）
# 同样能得到可比较的规范形式。它只做字符串与 lstat 解析，不创建任何东西。
physical_path() {
  print -r -- "${1:A}"
}

# 判断一个目录是否是合法的 AIQuotaBar.app bundle。
#
# 输入：$1 = 已经存在的目录路径。
# 输出：合法时无输出并返回 0；否则把原因写到标准输出并返回 1。
# 边界：只做存在性与可执行位检查，**绝不执行** bundle 里的可执行文件。
bundle_problem() {
  local dir=$1
  local plist="$dir/Contents/Info.plist"
  local exe="$dir/Contents/MacOS/AIQuotaBar"

  if [[ ! -f $plist ]]; then
    print -r -- "缺少 Contents/Info.plist"
    return 1
  fi

  local found_id
  if ! found_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null); then
    print -r -- "Info.plist 读不出 CFBundleIdentifier"
    return 1
  fi
  if [[ $found_id != "$BUNDLE_ID" ]]; then
    print -r -- "CFBundleIdentifier 是 $found_id，期望 $BUNDLE_ID"
    return 1
  fi

  if [[ ! -f $exe || ! -x $exe ]]; then
    print -r -- "缺少带可执行位的 Contents/MacOS/AIQuotaBar"
    return 1
  fi

  return 0
}

# 校验源 .app 与安装目标，并比对两者是否冲突。
#
# 输入：$1 = 源路径，允许相对路径、含空格、含符号链接、含 `..`。
# 输出：成功时通过全局 SOURCE_PHYS / DEST_LEAF 返回两个路径；DEST_LEAF 就是后续
#       rm -rf 与 ditto 的唯一锚点。
# 失败：按文件头的退出码表终止。
# 边界：全程只读 —— 不创建目录、不写文件、不启动或终止任何进程，不执行源或目标里的
#       任何可执行文件，也**不跟随安装目标叶子的符号链接**去读写它指向的内容。
validate_source() {
  local raw=$1
  local problem

  # ── 源：整条路径（含叶子）做物理规范化，因为源只会被读取 ──────────────────────
  [[ -n $raw ]] || die "$EX_NOINPUT" "源路径为空。"

  SOURCE_PHYS=$(physical_path "$raw")

  [[ $SOURCE_PHYS != / ]] || die "$EX_NOINPUT" "拒绝把根目录当作源。"
  [[ -e $SOURCE_PHYS ]] || die "$EX_NOINPUT" "源不存在：$SOURCE_PHYS"
  [[ -d $SOURCE_PHYS ]] || die "$EX_NOINPUT" "源不是目录（.app 必须是 bundle 目录）：$SOURCE_PHYS"

  if ! problem=$(bundle_problem "$SOURCE_PHYS"); then
    die "$EX_DATAERR" "源不是有效的 AIQuotaBar.app（$problem）：$SOURCE_PHYS"
  fi

  # ── 安装目标：只规范化父目录，叶子保持字面量 ────────────────────────────────
  # 父目录是链接（例如 ~/Applications 指向别处）是常见且安全的布局，解析它没问题。
  # 叶子绝不解析：它是 rm -rf 的对象，跟随链接就会删到链接指向的地方去。
  DEST_LEAF="$(physical_path "${APP_DEST:h}")/${APP_DEST:t}"

  if [[ -L $DEST_LEAF ]]; then
    die "$EX_CANTCREAT" \
      "安装目标本身是符号链接，拒绝（不会跟随它删除指向的内容）：$DEST_LEAF -> $(readlink "$DEST_LEAF")"
  fi
  if [[ -e $DEST_LEAF ]]; then
    [[ -d $DEST_LEAF ]] \
      || die "$EX_CANTCREAT" "安装目标已存在且不是目录，拒绝：$DEST_LEAF"
    if ! problem=$(bundle_problem "$DEST_LEAF"); then
      die "$EX_CANTCREAT" \
        "安装目标已存在但不是合法的 AIQuotaBar.app（$problem），拒绝删除：$DEST_LEAF"
    fi
  fi

  # ── 两者的关系 ────────────────────────────────────────────────────────────
  # 冲突比较另算一份目标路径，而且它是**函数局部变量**：不会流到 rm -rf / ditto /
  # plist 那三处去 —— 删除与写入永远只锚定上面的 DEST_LEAF。
  #
  # 为什么要对叶子再规范化一次：DEST_LEAF 的叶子刻意保持字面量 `AIQuotaBar.app`，
  # 而磁盘上实际的名字可能是别的大小写（例如 `aiquotabar.app`）。在 Mac 默认的大小写
  # 不敏感卷上那是**同一个文件**，纯字符串比较会错判成「不同」，于是真实安装的
  # rm -rf 会把源删掉。这里把叶子换成内核给出的真实拼写再比。
  #
  # 此刻解析叶子是安全的：上面已经拒绝了叶子是符号链接的情况，所以这次规范化只会校正
  # 大小写，不可能把路径重定向到别处。
  #
  # 存在性边界：叶子不存在时问不到真实名字，只能退回字面量 —— 那种情况下两者本来就不是
  # 同一个文件，用字面量比较是正确的。大小写敏感卷上真实名字就等于字面量，因此不会误拒；
  # 刻意不把路径统一小写化，否则大小写敏感卷上会把两个不同的 bundle 错判成冲突。
  local dest_compare=$DEST_LEAF
  if [[ -e $DEST_LEAF ]]; then
    dest_compare=$(physical_path "$DEST_LEAF")
  fi

  if [[ $SOURCE_PHYS == "$dest_compare" ]]; then
    die "$EX_CONFLICT" "源与安装目标是同一路径，拒绝（否则会删掉源）：$SOURCE_PHYS"
  fi
  # 兜底：两者都存在时直接比设备号 + inode，不依赖任何路径拼写规则。
  if [[ -e $SOURCE_PHYS && -e $dest_compare && $SOURCE_PHYS -ef $dest_compare ]]; then
    die "$EX_CONFLICT" \
      "源与安装目标是同一个文件（设备号 + inode 相同），拒绝：$SOURCE_PHYS 等同于 $DEST_LEAF"
  fi
  if [[ $SOURCE_PHYS == "$dest_compare"/* ]]; then
    die "$EX_CONFLICT" "源位于安装目标内部，拒绝：$SOURCE_PHYS 在 $dest_compare 之内"
  fi
  if [[ $dest_compare == "$SOURCE_PHYS"/* ]]; then
    die "$EX_CONFLICT" "安装目标位于源内部，拒绝：$dest_compare 在 $SOURCE_PHYS 之内"
  fi
}

# 选项可以出现在任意位置；以 - 开头的参数一律按选项处理，不会被当成路径。
# 需要传以 - 开头的路径时写成 ./-name。
typeset -i check_only=0
typeset -i have_source=0
source_arg=''

while (( $# )); do
  case $1 in
    --check)
      check_only=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      die "$EX_USAGE" "未知选项：$1"
      ;;
    *)
      if (( have_source )); then
        usage >&2
        die "$EX_USAGE" "参数过多，只接受一个 app 路径。"
      fi
      source_arg=$1
      have_source=1
      ;;
  esac
  shift
done

# 只有完全没给路径时才套用默认值。显式传入的空字符串会原样保留，
# 由校验按「源路径为空」拒绝，而不是悄悄换成默认路径。
if (( have_source )); then
  app_source=$source_arg
else
  app_source=${BUILD_DIR:-/tmp/AIQuotaBar-build}/AIQuotaBar.app
fi

validate_source "$app_source"

if (( check_only )); then
  if [[ -e $DEST_LEAF ]]; then
    dest_state='已存在的合法 bundle，安装会替换它'
  else
    dest_state='尚不存在，安装会新建'
  fi
  print -r -- "校验通过。"
  print -r -- "source: $SOURCE_PHYS"
  print -r -- "dest:   $DEST_LEAF（$dest_state）"
  print -r -- "plist:  $PLIST"
  print -r -- "（--check：未安装，未启动或终止任何进程，未创建目录，未写任何文件。）"
  exit 0
fi

# 校验通过之后才开始有副作用。
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"

/bin/launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
/usr/bin/pkill -x AIQuotaBar >/dev/null 2>&1 || true
sleep 0.5

# 锚定校验过的安装叶子。DEST_LEAF 的叶子部分从未被符号链接解析过，所以这里删掉的
# 一定是安装位置本身，不会是某个链接指向的目录。
rm -rf "$DEST_LEAF"
/usr/bin/ditto "$SOURCE_PHYS" "$DEST_LEAF"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DEST_LEAF/Contents/MacOS/AIQuotaBar</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
EOF

/bin/launchctl bootstrap "gui/$(id -u)" "$PLIST"
/bin/launchctl kickstart -k "gui/$(id -u)/$LABEL"
print -r -- "Installed $DEST_LEAF and enabled launch-at-login via $PLIST."
