#!/usr/bin/env bash

set -euo pipefail  

mkdir -p ./backup

GAME_MODS="$HOME/.steam/steam/steamapps/common/Stardew Valley/Mods"
mkdir -p "$GAME_MODS"

for zipfile in *.zip; do
    [ -e "$zipfile" ] || continue

    folder="${zipfile%.zip}"

    echo "处理: $zipfile → $folder"

    if ! ouch decompress "$zipfile"; then
        echo "× 解压失败: $zipfile"
        continue
    fi

    mv "$zipfile" ./backup/

    # 检查文件夹是否存在
    if [ ! -d "$folder" ]; then
        echo "⚠ 解压后没有出现文件夹 $folder，可能 zip 结构不对"
        # 可选择：rm -rf "$folder" 2>/dev/null
        continue
    fi

    # 创建软链接（-n 防止已存在时出错）
    ln -sfn "$(pwd)/$folder" "$GAME_MODS/$folder"

    echo "√ 已链接: $folder"
done
