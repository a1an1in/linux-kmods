#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# chardev_spi_flash 的端到端验收（宿主侧）
#
# 覆盖：
#   1. make 构建驱动 + 交叉编译用户态测试程序（静态 aarch64）
#   2. 起 QEMU；确认内核自带 spidev 已绑定 spi0.0（提供 /dev/spidev0.0）
#   3. **互斥**：spidev 占着器件时 insmod 本驱动 → 不会 probe（无节点）
#   4. unbind 内核 spidev → /dev/spidev0.0 消失
#   5. insmod 本驱动 → probe 成功、节点出现、driver 归属变成我们
#   6. /sys/class/chardev_spi_flash/spidev0.0 存在（class+device）
#   7. spidev_test 20 项全过（spidev ABI + 读 JEDEC ID = 20 ba 17）
#   8. fops.owner 保护：文件打开着时 rmmod → 失败（EBUSY）
#   9. 反复 insmod/rmmod 30 次无残留
#  10. rmmod 后节点消失；恢复内核 spidev（bind）后节点回来
#  11. 第一次 insmod 之后的内核日志无 Oops/BUG/WARNING
#
# 位置：tests/chardev/spi-flash/（与 drivers/chardev/spi-flash/ 同构）
# 用法：tests/chardev/spi-flash/verify_qemu.sh
set -u

QEMU=${QEMU:-/home/alan/workspace/qemu/build/qemu-system-aarch64}
KDIR=${KDIR:-/home/alan/workspace/linux-4.9.263}
INITRD=${INITRD:-/home/alan/workspace/busybox-1.33.1/initramfs.cpio.gz}
KMODS_ROOT=${KMODS_ROOT:-/home/alan/workspace/linux-kmods}
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}

TESTDIR_HOST="$KMODS_ROOT/tests/chardev/spi-flash"
TESTDIR_GUEST=/mnt/tests/chardev/spi-flash
KO_GUEST=/mnt/drivers/chardev/spi-flash/chardev_spi_flash.ko
DEV=/dev/spidev0.0
SPI_DEV_SYS=/sys/bus/spi/devices/spi0.0
SPIDEV_DRV=/sys/bus/spi/drivers/spidev

FIFO=$(mktemp -u /tmp/spiflash-in.XXXXXX)
LOG=$(mktemp /tmp/spiflash-log.XXXXXX)
BUILD_LOG=$(mktemp /tmp/spiflash-build.XXXXXX)
OUT="$KMODS_ROOT/.verify"
mkfifo "$FIFO"

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "  [PASS] $*"; }
bad()  { fail=$((fail + 1)); echo "  [FAIL] $*"; }
info() { echo "  [INFO] $*"; }

cleanup() {
	exec 3>&- 2>/dev/null
	[ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null
	rm -f "$FIFO"
}
trap cleanup EXIT

echo "== 1. 构建驱动 + 用户态测试程序 =="
if make -C "$KMODS_ROOT" KDIR="$KDIR" ARCH=arm64 \
	CROSS_COMPILE="$CROSS" > "$BUILD_LOG" 2>&1; then
	ko=$(ls -l "$KMODS_ROOT/drivers/chardev/spi-flash/chardev_spi_flash.ko" |
	     awk '{print $5}')
	ok "make 成功（chardev_spi_flash.ko = $ko bytes）"
else
	bad "make 失败"; cat "$BUILD_LOG"; exit 1
fi

mkdir -p "$TESTDIR_HOST/build"
if "$CROSS"gcc -static -O2 -Wall \
	-o "$TESTDIR_HOST/build/spidev_test" "$TESTDIR_HOST/spidev_test.c" \
	>> "$BUILD_LOG" 2>&1; then
	ok "交叉编译 spidev_test 成功（静态 aarch64）"
else
	bad "spidev_test 编译失败"; cat "$BUILD_LOG"; exit 1
fi

echo "== 2. 启动 QEMU =="
rm -rf "$OUT"; mkdir -p "$OUT"
"$QEMU" -M virt -cpu cortex-a57 -m 2G \
	-kernel "$KDIR/arch/arm64/boot/Image" \
	-initrd "$INITRD" \
	-nographic \
	-virtfs "local,path=$KMODS_ROOT,mount_tag=kmods,security_model=none,id=kmods" \
	-append "console=ttyAMA0 rdinit=/linuxrc" \
	< "$FIFO" > "$LOG" 2>&1 &
QPID=$!
exec 3>"$FIFO"

send() { echo "$*" >&3; sleep 1; }

wait_for() {
	local pat=$1 t=${2:-30} i=0
	while [ "$i" -lt "$t" ]; do
		grep -qE "$pat" "$LOG" && return 0
		sleep 1; i=$((i + 1))
	done
	return 1
}

wait_file() {
	local f=$1 t=${2:-30} pat=${3:-} i=0
	while [ "$i" -lt "$t" ]; do
		if [ -n "$pat" ]; then
			[ -f "$f" ] && grep -qE "$pat" "$f" && return 0
		else
			[ -s "$f" ] && return 0
		fi
		sleep 1; i=$((i + 1))
	done
	return 1
}

# 让客户机把命令输出写进 9p 共享目录，宿主轮询文件（避免 QEMU stdout 缓冲坑）
# 注意：用子 shell 包住整条命令，否则 `a; b > file` 的重定向只作用于 b
guest_out() {
	local name=$1; shift
	rm -f "$OUT/$name"
	send "( $* ) > /mnt/.verify/$name 2>&1"
	wait_file "$OUT/$name" 30
}

out_value() { tr -d '\r' < "$OUT/$1" 2>/dev/null | head -1; }

wait_for "activate this console" 60 || {
	echo "guest 没起来，日志尾部："; tail -20 "$LOG"; exit 1; }
send ""
send "mkdir -p /mnt && mount -t 9p -o trans=virtio,version=9p2000.L kmods /mnt && echo MOUNT_OK"
wait_for "MOUNT_OK" 20 && ok "9p 挂载本工程源码树到 /mnt" || bad "9p 挂载失败"
send "mkdir -p /mnt/.verify"

echo "== 3. 起点：内核自带 spidev 占着 spi0.0 =="
guest_out base_drv "basename \$(readlink -f $SPI_DEV_SYS/driver)"
drv=$(out_value base_drv)
[ "$drv" = "spidev" ] && ok "spi0.0 初始由内核 spidev 绑定" \
	|| bad "spi0.0 初始驱动 = '$drv'（期望 spidev）"
guest_out base_dev "cat /sys/class/spidev/spidev0.0/dev"
base_dev=$(out_value base_dev)		# 形如 153:0（内核 spidev 的 major:minor）
guest_out base_node "test -c $DEV && ls -l $DEV"
if [ -n "$base_dev" ] && grep -q "^c" "$OUT/base_node" 2>/dev/null; then
	ok "内核 spidev 节点存在：$(out_value base_node)（dev=$base_dev）"
else
	bad "内核 spidev 节点不存在（dev='$base_dev'）"
fi

echo "== 4. 互斥：spidev 占着器件时 insmod，本驱动不该 probe =="
send "insmod $KO_GUEST"
wait_for "chardev_spi_flash: loading out-of-tree" 30 \
	&& ok "模块 insmod 成功（注册到 SPI 总线，但没有可绑的器件）" \
	|| bad "insmod 失败（看日志）"
guest_out no_probe "ls /sys/class/chardev_spi_flash 2>&1; readlink -f $SPI_DEV_SYS/driver"
if grep -q "No such file" "$OUT/no_probe" 2>/dev/null &&
   grep -q "spidev" "$OUT/no_probe" 2>/dev/null; then
	ok "没有 probe（无 /sys/class/chardev_spi_flash）、器件仍归 spidev：1:1 绑定"
else
	bad "预期不 probe，但结果：$(tr '\n' ' ' < "$OUT/no_probe" 2>/dev/null)"
fi
send "rmmod chardev_spi_flash"

echo "== 5. unbind 内核 spidev → 再 insmod 本驱动 =="
send "echo spi0.0 > $SPIDEV_DRV/unbind; echo UNBIND_RC=\$?"
wait_for "UNBIND_RC=0" 20 && ok "unbind 内核 spidev 成功" || bad "unbind 失败"
guest_out unbound "ls -l $DEV 2>&1"
grep -q "No such file" "$OUT/unbound" 2>/dev/null \
	&& ok "unbind 后 $DEV 消失（spidev 的 class device 被摘掉）" \
	|| bad "unbind 后 $DEV 还在：$(out_value unbound)"

send "insmod $KO_GUEST"
if wait_for "ready: $DEV" 30; then
	ok "insmod 成功：$(grep -o 'ready: /dev/spidev0.0.*' "$LOG" | tail -1 | tr -d '\r')"
else
	bad "没有看到 ready: $DEV 的 probe 日志"
fi
guest_out node "ls -l $DEV"
guest_out own_dev "cat /sys/class/chardev_spi_flash/spidev0.0/dev"
own_dev=$(out_value own_dev)
if grep -q "^c" "$OUT/node" 2>/dev/null && [ -n "$own_dev" ] &&
   [ "$own_dev" != "$base_dev" ]; then
	ok "节点由本驱动重建：$(out_value node)（dev $base_dev → $own_dev）"
else
	bad "节点没换成我们的：$(out_value node)（base dev=$base_dev own='$own_dev'）"
fi
guest_out own_drv "basename \$(readlink -f $SPI_DEV_SYS/driver)"
[ "$(out_value own_drv)" = "chardev_spi_flash" ] \
	&& ok "spi0.0 现在归属 chardev_spi_flash" \
	|| bad "spi0.0 的驱动 = $(out_value own_drv)"
guest_out class "ls /sys/class/chardev_spi_flash/"
grep -q "spidev0.0" "$OUT/class" 2>/dev/null \
	&& ok "/sys/class/chardev_spi_flash/spidev0.0 存在（class+device 建好了）" \
	|| bad "/sys/class/chardev_spi_flash/ 下没有节点"

echo "== 6. 用户态验证（spidev ABI + JEDEC ID）=="
guest_out spidev_test "cp $TESTDIR_GUEST/build/spidev_test /tmp/ && /tmp/spidev_test $DEV; echo RC=\$?"
if grep -q "PASS=20 FAIL=0" "$OUT/spidev_test" 2>/dev/null; then
	ok "spidev_test 全部通过（PASS=20 FAIL=0）"
else
	bad "spidev_test 有失败项"
fi
grep -E "^  \[(PASS|FAIL)\]" "$OUT/spidev_test" 2>/dev/null | sed 's/^/    /'
grep -q "JEDEC ID == 20 ba 17 (n25q064)" "$OUT/spidev_test" 2>/dev/null \
	&& ok "JEDEC ID 读出真实数据（20 ba 17，n25q064）" \
	|| bad "没读到 JEDEC ID"

echo "== 7. fops.owner 保护：文件打开着时 rmmod 应失败 =="
# 注意：busybox 的 rmmod 在失败时也可能退出码为 0，所以这里断言"模块还在"
guest_out busy "exec 9<$DEV; rmmod chardev_spi_flash 2>&1; grep -q chardev_spi_flash /proc/modules && echo STILL_LOADED; exec 9<&-"
if grep -q "STILL_LOADED" "$OUT/busy" 2>/dev/null; then
	ok "打开着文件时卸不掉（fops.owner 加引用）：$(tr '\n' ' ' < "$OUT/busy" | tr -d '\r')"
else
	bad "rmmod 竟然卸载成功：$(tr '\n' ' ' < "$OUT/busy" 2>/dev/null)"
fi

echo "== 8. 反复 insmod/rmmod 30 次 =="
rm -f "$OUT/loop"
send "n=0; while [ \$n -lt 30 ]; do rmmod chardev_spi_flash; insmod $KO_GUEST; n=\$((n+1)); done; rmmod chardev_spi_flash; echo done > /mnt/.verify/loop"
if wait_file "$OUT/loop" 180; then
	ok "30 次 insmod/rmmod 全部成功"
else
	bad "insmod/rmmod 循环没跑完（180s 超时）"
fi
guest_out after "ls $DEV 2>&1 | head -1"
grep -q "No such file" "$OUT/after" 2>/dev/null && ok "循环结束后 $DEV 已清理" \
	|| bad "循环结束后 $DEV 仍存在"

echo "== 9. 恢复内核 spidev（bind）=="
send "echo spi0.0 > $SPIDEV_DRV/bind; echo BIND_RC=\$?"
wait_for "BIND_RC=0" 20 && ok "bind 内核 spidev 成功" || bad "bind 失败"
guest_out restored "ls -l $DEV"
guest_out restored_dev "cat /sys/class/spidev/spidev0.0/dev"
if grep -q "^c" "$OUT/restored" 2>/dev/null &&
   [ "$(out_value restored_dev)" = "$base_dev" ]; then
	ok "内核 spidev 节点恢复：$(out_value restored)（dev=$base_dev）"
else
	bad "内核 spidev 节点没回来：$(out_value restored)（dev=$(out_value restored_dev)）"
fi
guest_out restored_drv "basename \$(readlink -f $SPI_DEV_SYS/driver)"
[ "$(out_value restored_drv)" = "spidev" ] && ok "spi0.0 归还给内核 spidev" \
	|| bad "spi0.0 的驱动 = $(out_value restored_drv)"

if sed -n '/chardev_spi_flash: loading out-of-tree/,$p' "$LOG" |
	grep -qE "Oops|BUG:|Call trace|WARNING:"; then
	bad "insmod 之后日志有内核异常：$(sed -n '/chardev_spi_flash: loading out-of-tree/,$p' "$LOG" |
		grep -oE 'Oops|BUG:|Call trace|WARNING:' | sort -u | tr '\n' ' ')"
else
	ok "insmod 之后日志无 Oops / BUG / WARNING / Call trace"
fi

send "poweroff -f"
wait "$QPID" 2>/dev/null
exec 3>&-

echo
echo "== 汇总：PASS=$pass FAIL=$fail =="
if [ "$fail" -ne 0 ]; then
	echo "完整串口日志：$LOG"
	exit 1
fi
rm -rf "$OUT" "$LOG" "$BUILD_LOG"
