#!/usr/bin/env bash
# 把本目录下的 SMAPI mod / Content Patcher 包软链接到游戏 Mods 目录。
#
#
# 用法：
#   ./mods.sh            # 正式执行：链接全部 mod
#   DRY_RUN=1 ./mods.sh  # 演练：只打印将要做什么，不实际改动
#   GAME_MODS=/xx ./mods.sh   # 手动指定游戏 Mods 路径

set -euo pipefail
cd "$(dirname "$0")"

SRC="$(pwd)"
GAME_MODS="${GAME_MODS:-$HOME/.steam/steam/steamapps/common/Stardew Valley/Mods}"
mkdir -p "$GAME_MODS"

link_mod() {
    local src="$1" name dst
    name="$(basename "$src")"
    dst="$GAME_MODS/$name"

    if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
        echo "= 已链接过，跳过: $name"
        return 0
    fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        echo "⚠ 跳过: $dst 已存在且不是指向本目录的链接（请人工处理）" >&2
        return 1
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "[演练] 将链接: $src"
    else
        ln -s "$src" "$dst"
        echo "√ 已链接: $name"
    fi
}

shopt -s nullglob
for zipfile in *.zip; do
    echo "处理压缩包: $zipfile"
    if command -v ouch >/dev/null 2>&1; then
        ok=0; ouch decompress "$zipfile" && ok=1
    elif command -v unzip >/dev/null 2>&1; then
        ok=0; unzip -q -o "$zipfile" && ok=1
    else
        echo "× 没有 ouch / unzip，无法解压 $zipfile" >&2
        ok=0
    fi
    if [ "$ok" = 1 ]; then
        mkdir -p ./backup
        mv "$zipfile" ./backup/
    else
        echo "× 解压失败，zip 保留在原地: $zipfile" >&2
    fi
done

count=0
while IFS= read -r manifest; do
    mod_dir="$(dirname "$manifest")"
    if link_mod "$mod_dir"; then
        count=$((count + 1))
    fi
done < <(find "$SRC" -mindepth 2 -maxdepth 3 -name manifest.json \
            -not -path "$SRC/backup/*" \
            -not -path "$SRC/.backup/*" \
            -not -path "$SRC/.git/*" \
        | sort)

echo "----"
echo "完成：共处理 $count 个 mod → $GAME_MODS"
[ "${DRY_RUN:-0}" = "1" ] && echo "（演练模式：未实际改动。去掉 DRY_RUN=1 再执行一次即生效）"
