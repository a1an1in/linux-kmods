#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# 交叉编译封装（设计文档 §8.1）
#
#   ./scripts/build.sh                 # 编译所有模块
#   ./scripts/build.sh clean           # 清理产物
#   ./scripts/build.sh checkpatch      # 对所有 .c 跑内核树里的 checkpatch
#   ./scripts/build.sh sparse          # 带 C=2 编译（需要系统装了 sparse）
#
# 可用环境变量覆盖：
#   KDIR=/path/to/linux-tree  ARCH=arm64  CROSS_COMPILE=aarch64-linux-gnu-
set -e

KDIR=${KDIR:-/home/alan/workspace/linux-4.9.263}
ARCH=${ARCH:-arm64}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KBUILD_FLAGS=(-C "$KDIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE")
MODE=${1:-modules}

case "$MODE" in
modules)
	make -C "$ROOT" KDIR="$KDIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE"
	;;
clean)
	make -C "$ROOT" clean KDIR="$KDIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE"
	;;
sparse)
	make -C "$ROOT" KDIR="$KDIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
		"KBUILD_FLAGS=${KBUILD_FLAGS[*]} C=2" 2>/dev/null ||
		for d in "$ROOT"/drivers/*/; do
			make "${KBUILD_FLAGS[@]}" M="$d" C=2 modules
		done
	;;
checkpatch)
	if [ ! -x "$KDIR/scripts/checkpatch.pl" ]; then
		echo "找不到 $KDIR/scripts/checkpatch.pl" >&2
		exit 1
	fi
	# 排除 kbuild 生成的文件（*.mod.c 等），只检查我们手写的源码
	files=$(find "$ROOT/drivers" \( -name '*.c' -o -name '*.h' \) \
		! -name '*.mod.c' ! -path '*/.tmp_versions/*' | sort)
	[ -n "$files" ] || { echo "没有可检查的源文件"; exit 1; }
	# shellcheck disable=SC2086
	"$KDIR/scripts/checkpatch.pl" --no-tree --strict -f $files
	;;
*)
	sed -n '2,13p' "$0"
	exit 1
	;;
esac
