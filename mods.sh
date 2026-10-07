#!/usr/bin/env bash
# =====================================================================
# Stardew Valley Mods 同步脚本
#
# 以本仓库为准，把游戏 Mods 目录同步成"完全一致"的状态：
#   1. 自动解压下载到本目录的 zip / 7z / rar（SMAPI 安装包自动安装）
#   2. 把带有 manifest.json 的 mod 目录软链接进游戏 Mods
#   3. 删除游戏 Mods 里"多余 / 失效"的链接
#      —— 在本目录删掉某个 mod、重命名它、或放进新版本后，
#         对应的旧软链接会在下次运行时被自动清理
#   4. 自动识别同 UniqueID 的多个版本，只同步较新的那个
#
# 安全原则（很重要）：
#   * 只会删除「指向本仓库的软链接」，绝不会删除符号链接以外的任何东西
#     （SMAPI 自带的 ConsoleCommands / SaveBackup、你自己手动装的 mod
#       都不会被碰）
#   * 指向仓库以外的链接只警告、不删除
#
# 用法：
#   ./mods.sh                 # 默认：解压 + 链接 + 清理（sync）
#   ./mods.sh sync            # 同上
#   ./mods.sh link            # 只链接，不删除任何东西
#   ./mods.sh prune           # 只清理多余/失效链接，不新增
#   ./mods.sh status          # 只预览差异，不做任何修改
#   ./mods.sh clean           # 删除已被新版本取代的旧解压目录（先加 -n 预览！）
#   ./mods.sh unlink <Mod名>  # 手动解除游戏 Mods 中某一个链接
#   ./mods.sh help            # 帮助
#
# 选项：
#   -n, --dry-run     演练模式（也可以用 DRY_RUN=1 ./mods.sh）
#       --keep-all    不按 UniqueID 去重，允许同一 mod 的多个版本共存
#   -h, --help        帮助
#
# 环境变量：
#   GAME_DIR=/path   手动指定游戏根目录
#   GAME_MODS=/path  手动指定 Mods 目录
#   SCAN_DEPTH=4     扫描 manifest.json 的最大深度
#   KEEP_ALL=1       等价于 --keep-all
#
# 小技巧：
#   想临时停用某个 mod 但不想删掉它，在它的目录里放一个空文件 .disabled
#   （或 .nolink），脚本就不会链接它，并会清掉已有的链接。
# =====================================================================
set -euo pipefail

cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
SRC="$(pwd)"
GAME_DIR="${GAME_DIR:-$HOME/.steam/steam/steamapps/common/Stardew Valley}"
GAME_MODS="${GAME_MODS:-$GAME_DIR/Mods}"
SCAN_DEPTH="${SCAN_DEPTH:-4}"
DRY_RUN="${DRY_RUN:-0}"
KEEP_ALL="${KEEP_ALL:-0}"
DISABLE_MARKERS=(".disabled" ".nolink")

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
    C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_OK=; C_WARN=; C_ERR=; C_DIM=; C_RST=
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s√%s %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { printf '%s⚠%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
err()  { printf '%s×%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; }
dry()  { printf '%s[演练]%s %s\n' "$C_DIM" "$C_RST" "$*"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

LINKED=0; PRUNED=0; CLEANED=0; PROBLEMS=0; SKIPPED_SAME=0

########################################
# 工具函数
########################################
usage() {
    awk 'NR>1 && /^set -euo/ {exit} NR>1 && /^#/ {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
}

# 规范化路径（允许目标不存在）
abspath() {
    if [[ "$1" = /* ]]; then realpath -m -- "$1"; else realpath -m -- "$PWD/$1"; fi
}

# 判断 path 是否位于本仓库内
is_under_src() {
    case "$1" in
        "$SRC" | "$SRC"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# 取软链接的真实目标（即使目标不存在也能得到规范化路径）
link_target() {
    local raw
    raw="$(readlink -- "$1")"
    if [[ "$raw" = /* ]]; then
        abspath "$raw"
    else
        abspath "$(dirname -- "$1")/$raw"
    fi
}

# 读取 manifest.json 字段：先用 jq，失败再用正则兜底
# （很多 mod 的 manifest 是带注释 / BOM / CRLF 的 JSON5，jq 会解析失败）
manifest_field() {
    local file="$1" key="$2" val=""
    if command -v jq >/dev/null 2>&1; then
        val="$(jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null || true)"
    fi
    if [ -z "$val" ]; then
        val="$(tr -d '\r' < "$file" \
            | grep -m1 -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
            | sed -e 's/^[^:]*:[[:space:]]*"//' -e 's/"$//' || true)"
    fi
    printf '%s' "$val"
}

# $1=目录A $2=版本A $3=目录B $4=版本B → A 是否比 B 新
is_newer() {
    local dir_a="$1" ver_a="$2" dir_b="$3" ver_b="$4"
    if [ "$ver_a" != "$ver_b" ]; then
        [ "$(printf '%s\n%s\n' "$ver_a" "$ver_b" | LC_ALL=C sort -V | tail -n1)" = "$ver_a" ]
    else
        [ "$dir_a/manifest.json" -nt "$dir_b/manifest.json" ]
    fi
}

########################################
# 扫描：得到 DESIRED / SUPERSEDED / DISABLED
########################################
DESIRED=(); SUPERSEDED=(); DISABLED=()

scan_mods() {
    DESIRED=(); SUPERSEDED=(); DISABLED=()
    local -A uid_dir=() uid_ver=()
    local manifest dir uid ver prev prevver marker disabled

    while IFS= read -r manifest; do
        dir="$(dirname -- "$manifest")"
        # 排除备份 / git 目录
        case "$dir" in
            "$SRC"/backup/* | "$SRC"/.backup/* | "$SRC"/.git/*) continue ;;
        esac
        # 排除 SMAPI 安装器之类的目录
        case "${dir,,}" in
            *installer*) continue ;;
        esac
        # 手动禁用标记
        disabled=0
        for marker in "${DISABLE_MARKERS[@]}"; do
            [ -e "$dir/$marker" ] && disabled=1
        done
        if [ "$disabled" = 1 ]; then
            DISABLED+=("$dir")
            continue
        fi

        uid="$(manifest_field "$manifest" UniqueID)"
        ver="$(manifest_field "$manifest" Version)"
        [ -z "$uid" ] && uid="__path__:$dir"
        [ -z "$ver" ] && ver="0"
        # --keep-all：每个目录都用独立 key，等于不做去重
        [ "$KEEP_ALL" = 1 ] && uid="__path__:$dir"

        prev="${uid_dir[$uid]:-}"
        if [ -z "$prev" ]; then
            uid_dir[$uid]="$dir"; uid_ver[$uid]="$ver"; continue
        fi
        prevver="${uid_ver[$uid]}"
        if is_newer "$dir" "$ver" "$prev" "$prevver"; then
            SUPERSEDED+=("$prev")
            uid_dir[$uid]="$dir"; uid_ver[$uid]="$ver"
        else
            SUPERSEDED+=("$dir")
        fi
    done < <(find "$SRC" -mindepth 2 -maxdepth "$SCAN_DEPTH" -name manifest.json -print \
                | LC_ALL=C sort)

    local key
    for key in "${!uid_dir[@]}"; do DESIRED+=("${uid_dir[$key]}"); done
    if [ "${#DESIRED[@]}" -gt 0 ]; then
        mapfile -t DESIRED < <(printf '%s\n' "${DESIRED[@]}" | LC_ALL=C sort)
    fi
    if [ "${#SUPERSEDED[@]}" -gt 0 ]; then
        mapfile -t SUPERSEDED < <(printf '%s\n' "${SUPERSEDED[@]}" | LC_ALL=C sort -u)
    fi
}

########################################
# 链接
########################################
link_mod() {
    local src="$1" name dst
    name="$(basename -- "$src")"
    dst="$GAME_MODS/$name"

    if [ -L "$dst" ]; then
        if [ "$(link_target "$dst")" = "$(abspath "$src")" ]; then
            SKIPPED_SAME=$((SKIPPED_SAME + 1))
            return 0
        fi
        warn "同名链接指向别处，跳过: $dst → $(readlink -- "$dst")"
        PROBLEMS=$((PROBLEMS + 1))
        return 0
    fi
    if [ -e "$dst" ]; then
        warn "已存在同名真实目录/文件，跳过（请人工处理）: $dst"
        PROBLEMS=$((PROBLEMS + 1))
        return 0
    fi

    if [ "$DRY_RUN" = 1 ]; then
        dry "链接: $name"
    else
        ln -s -- "$src" "$dst"
        ok "链接: $name"
    fi
    LINKED=$((LINKED + 1))
}

link_all() {
    local d
    for d in "${DESIRED[@]}"; do link_mod "$d"; done
}

########################################
# 清理多余 / 失效链接
########################################
remove_link() {
    local link="$1" reason="$2"
    if [ "$DRY_RUN" = 1 ]; then
        dry "删除链接: $(basename -- "$link")  （$reason）"
    else
        rm -- "$link"
        ok "删除链接: $(basename -- "$link")  （$reason）"
    fi
    PRUNED=$((PRUNED + 1))
}

prune_links() {
    shopt -s nullglob
    local -A wanted=()
    local d entry tgt
    for d in "${DESIRED[@]}"; do wanted["$(abspath "$d")"]=1; done

    for entry in "$GAME_MODS"/*; do
        [ -L "$entry" ] || continue
        tgt="$(link_target "$entry")"
        if ! is_under_src "$tgt"; then
            if [ ! -e "$entry" ]; then
                warn "失效链接（不在本仓库管辖范围，未处理）: $entry → $(readlink -- "$entry")"
                PROBLEMS=$((PROBLEMS + 1))
            fi
            continue
        fi
        [ -n "${wanted[$tgt]:-}" ] && continue
        if [ -e "$tgt" ]; then
            remove_link "$entry" "源目录已不在同步列表（已删除 / 已禁用 / 被新版本取代）"
        else
            remove_link "$entry" "源目录已不存在（失效链接）"
        fi
    done
}

########################################
# 删除被新版本取代的旧解压目录
########################################
clean_superseded() {
    local d keep skip
    if [ "${#SUPERSEDED[@]}" -eq 0 ]; then
        ok "没有需要清理的旧版本目录"
        return 0
    fi
    for d in "${SUPERSEDED[@]}"; do
        [ -d "$d" ] || continue
        skip=0
        for keep in "${DESIRED[@]}"; do
            case "$keep" in "$d"/*) skip=1 ;; esac
        done
        if [ "$skip" = 1 ]; then
            warn "保留（其中含有已同步的子 mod）: ${d#"$SRC"/}"
            continue
        fi
        if [ "$DRY_RUN" = 1 ]; then
            dry "删除旧版本目录: ${d#"$SRC"/}"
        else
            rm -rf -- "$d"
            ok "删除旧版本目录: ${d#"$SRC"/}"
        fi
        CLEANED=$((CLEANED + 1))
    done
}

########################################
# 手动解除单个链接
########################################
do_unlink() {
    local name="${1:-}" dst
    if [ -z "$name" ]; then
        err "用法: ./mods.sh unlink <Mod名>"
        exit 2
    fi
    dst="$GAME_MODS/$name"
    if [ ! -L "$dst" ]; then
        err "不是一个软链接或不存在: $dst"
        PROBLEMS=$((PROBLEMS + 1))
        return 0
    fi
    if ! is_under_src "$(link_target "$dst")"; then
        err "该链接不指向本仓库，拒绝删除: $dst → $(readlink -- "$dst")"
        PROBLEMS=$((PROBLEMS + 1))
        return 0
    fi
    remove_link "$dst" "手动解除"
    info "提示：默认 sync 下次会把它重新链上；想长期停用请在该 mod 目录里放一个 .disabled 文件。"
}

########################################
# 解压压缩包
########################################
extract_archive() {
    local archive="$1" abs
    abs="$(abspath "$archive")"
    case "${archive,,}" in
        *.zip) command -v unzip >/dev/null 2>&1 && unzip -q -o "$abs" && return 0 ;;
    esac
    if command -v ouch >/dev/null 2>&1 && ouch decompress -y "$abs"; then
        return 0
    fi
    case "${archive,,}" in
        *.7z)
            for t in 7z 7za 7zz; do
                command -v "$t" >/dev/null 2>&1 && "$t" x -y "$abs" && return 0
            done
            ;;
        *.rar)
            command -v unrar >/dev/null 2>&1 && unrar x -o+ -y "$abs" && return 0
            command -v unar  >/dev/null 2>&1 && unar -f "$abs" && return 0
            ;;
    esac
    return 1
}

install_smapi() {
    local archive="$1" tmp installer idir rc=0
    info "检测到 SMAPI 安装包: $archive"
    if [ "$DRY_RUN" = 1 ]; then
        dry "解压并安装 SMAPI 到 $GAME_DIR"
        return 0
    fi
    tmp="$(mktemp -d)"
    if ! (cd "$tmp" && extract_archive "$archive"); then
        err "解压失败，无法安装 SMAPI: $archive"
        rm -rf -- "$tmp"; PROBLEMS=$((PROBLEMS + 1)); return 0
    fi
    installer="$(find "$tmp" -type f -name 'install on Linux.sh' -print -quit)"
    if [ -z "$installer" ]; then
        err "未找到 'install on Linux.sh'，跳过: $archive"
        rm -rf -- "$tmp"; PROBLEMS=$((PROBLEMS + 1)); return 0
    fi
    idir="$(dirname -- "$installer")"
    if command -v steam-run >/dev/null 2>&1; then
        info "使用 steam-run 运行安装脚本..."
        (cd "$idir" && steam-run ./install\ on\ Linux.sh --game-path "$GAME_DIR") || rc=$?
    else
        info "未找到 steam-run，直接运行（NixOS 上可能失败）..."
        (cd "$idir" && ./install\ on\ Linux.sh --game-path "$GAME_DIR") || rc=$?
    fi
    rm -rf -- "$tmp"
    if [ "$rc" -eq 0 ]; then
        mkdir -p ./backup
        mv -- "$archive" ./backup/
        ok "SMAPI 安装完成，安装包已移入 backup/"
    else
        err "SMAPI 安装脚本返回 $rc，安装包保留在原处"
        PROBLEMS=$((PROBLEMS + 1))
    fi
}

process_archives() {
    shopt -s nullglob
    local archive
    for archive in *.zip *.7z *.rar; do
        [ -e "$archive" ] || continue
        if [[ "${archive,,}" == *smapi* ]]; then
            install_smapi "$archive"
            continue
        fi
        info "解压: $archive"
        if [ "$DRY_RUN" = 1 ]; then
            dry "解压 $archive 并移入 backup/"
            continue
        fi
        if extract_archive "$archive"; then
            mkdir -p ./backup
            mv -- "$archive" ./backup/
            ok "已解压并归档: $archive"
        else
            err "解压失败，压缩包保留在原处: $archive"
            PROBLEMS=$((PROBLEMS + 1))
        fi
    done
}

########################################
# 报告
########################################
report_scan() {
    local d
    if [ "${#DISABLED[@]}" -gt 0 ]; then
        echo "已禁用（存在 ${DISABLE_MARKERS[*]} 标记，不同步）:"
        for d in "${DISABLED[@]}"; do echo "  - ${d#"$SRC"/}"; done
        echo
    fi
    if [ "${#SUPERSEDED[@]}" -gt 0 ]; then
        echo "检测到同 UniqueID 的多个版本（只同步较新的，旧目录可 ./mods.sh clean 清理）:"
        for d in "${SUPERSEDED[@]}"; do
            printf '  - %s  (%s @ %s)\n' "${d#"$SRC"/}" \
                "$(manifest_field "$d/manifest.json" UniqueID)" \
                "$(manifest_field "$d/manifest.json" Version)"
        done
        echo
    fi
}

summary() {
    echo
    hr
    printf '仓库内 mod 数：%d\n' "${#DESIRED[@]}"
    [ "$LINKED" -gt 0 ]      && printf '新建链接：    %d\n' "$LINKED"
    [ "$SKIPPED_SAME" -gt 0 ] && printf '已是最新：    %d\n' "$SKIPPED_SAME"
    [ "$PRUNED" -gt 0 ]      && printf '删除链接：    %d\n' "$PRUNED"
    [ "$CLEANED" -gt 0 ]     && printf '清理旧目录：  %d\n' "$CLEANED"
    if [ -f "$GAME_DIR/StardewModdingAPI" ] || [ -f "$GAME_DIR/StardewModdingAPI.exe" ]; then
        echo "SMAPI：       已安装在游戏目录 √"
    else
        warn "未检测到 StardewModdingAPI，请确认 SMAPI 是否安装成功"
    fi
    hr
    if [ "$PROBLEMS" -gt 0 ]; then
        warn "有 $PROBLEMS 项需要人工确认（见上方 ⚠ / × ）"
        return 1
    fi
}

########################################
# 参数解析
########################################
ACTION=""
TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        --keep-all)   KEEP_ALL=1 ;;
        -h|--help)    ACTION="help" ;;
        sync|link|prune|status|clean|help) ACTION="$1" ;;
        unlink)       ACTION="unlink"; shift; TARGET="${1:-}" ;;
        *) err "未知参数: $1"; echo; usage; exit 2 ;;
    esac
    shift
done
ACTION="${ACTION:-sync}"

if [ "$ACTION" = "help" ]; then usage; exit 0; fi

mkdir -p "$GAME_MODS"
echo "仓库:      $SRC"
echo "游戏 Mods: $GAME_MODS"
[ "$DRY_RUN" = 1 ] && echo "${C_DIM}（演练模式，不会修改任何文件）${C_RST}"
echo

case "$ACTION" in
    sync) process_archives ;;
esac

scan_mods

case "$ACTION" in
    sync)   report_scan; link_all; echo; prune_links ;;
    link)   report_scan; link_all ;;
    prune)  prune_links ;;
    status) DRY_RUN=1; report_scan; link_all; echo; prune_links ;;
    clean)  clean_superseded ;;
    unlink) do_unlink "$TARGET" ;;
esac

summary || exit 1
