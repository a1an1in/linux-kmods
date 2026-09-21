#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# 在 QEMU 客户机里跑：只用 /dev/spidevB.C（标准 spidev 接口）做自检
#
# 用法：
#   ./read_spidev.sh                                   # 模块已加载（且已 unbind 内核 spidev）
#   ./read_spidev.sh /mnt/drivers/chardev/spi-flash/chardev_spi_flash.ko
#   SPIDEV_TEST=/mnt/tests/chardev/spi-flash/build/spidev_test ./read_spidev.sh
#
# 教学点：
#   - 本驱动对外就是**标准 spidev ABI**（/dev/spidevB.C + SPI_IOC_*），
#     所以任何按 spidev 写的用户态程序（libobject 的 Spi HAL、
#     test_spi.c、spidev_test.c）不用改就能跑；
#   - SPI 总线是"一个器件同一时刻只能绑一个驱动"，所以本驱动与
#     内核自带 spidev **互斥**：先用 unbind 让 spidev 松手（本脚本会
#     检测这一点并给出命令）。

DEV=${DEV:-/dev/spidev0.0}
KO=${KO:-/mnt/drivers/chardev/spi-flash/chardev_spi_flash.ko}
SPIDEV_TEST=${SPIDEV_TEST:-/mnt/tests/chardev/spi-flash/build/spidev_test}
SPI_DEV_SYS=${SPI_DEV_SYS:-/sys/bus/spi/devices/spi0.0}

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "  [PASS] $*"; }
bad()  { fail=$((fail + 1)); echo "  [FAIL] $*"; }
info() { echo "  [INFO] $*"; }

if [ -n "$1" ]; then
	echo "== insmod $1 =="
	insmod "$1" || { echo "insmod 失败"; exit 1; }
	sleep 1
fi

echo "== A. SPI 器件与驱动的绑定情况 =="
if [ -e "$SPI_DEV_SYS" ]; then
	drv=$(basename "$(readlink -f "$SPI_DEV_SYS/driver" 2>/dev/null)" 2>/dev/null)
	info "$SPI_DEV_SYS 的驱动 = ${drv:-（无）}"
	case "$drv" in
	chardev_spi_flash)
		ok "本驱动已绑定该 SPI 器件"
		;;
	spidev)
		bad "内核 spidev 还占着器件（先 unbind）："
		info "  echo spi0.0 > /sys/bus/spi/drivers/spidev/unbind"
		info "  然后 insmod $KO"
		;;
	*)
		info "驱动是 '${drv:-无}'，不是本驱动"
		;;
	esac
else
	bad "$SPI_DEV_SYS 不存在（QEMU 没建 PL022 控制器？）"
fi

echo "== B. 设备节点 =="
if [ -c "$DEV" ]; then
	ok "$DEV 存在：$(ls -l "$DEV" | awk '{print $1, $5, $6}')"
else
	bad "$DEV 不存在（insmod 了吗？看 dmesg）"
	exit 1
fi

echo "== C. sysfs 里的 class/device =="
if [ -e "/sys/class/chardev_spi_flash/$(basename "$DEV")" ]; then
	ok "/sys/class/chardev_spi_flash/$(basename "$DEV") 存在（class+device 建好了）"
else
	bad "/sys/class/chardev_spi_flash/ 下没有节点"
fi

echo "== D. probe 日志 =="
if dmesg | grep -q "chardev_spi_flash.*ready: $DEV"; then
	ok "dmesg: $(dmesg | grep -o "ready: $DEV.*" | tail -1)"
else
	bad "dmesg 里没有 ready 日志"
fi

echo "== E. 用户态验证（spidev ABI + 读 JEDEC ID）=="
if [ -f "$SPIDEV_TEST" ]; then
	# 9p 挂载不一定允许直接执行，先拷到 /tmp（tmpfs 一定可执行）
	cp "$SPIDEV_TEST" /tmp/spidev_test 2>/dev/null
	out=$(/tmp/spidev_test "$DEV" 2>&1)
	echo "$out" | sed 's/^/    /'
	if echo "$out" | grep -q "PASS=20 FAIL=0"; then
		ok "spidev_test 全部通过（20 项）"
	else
		bad "spidev_test 有失败项"
	fi
else
	info "没找到 $SPIDEV_TEST，跳过"
fi

echo
echo "== 汇总：PASS=$pass FAIL=$fail =="
[ "$fail" -eq 0 ] || exit 1

echo
echo "提示："
echo "  - 读 JEDEC ID 要重试：QEMU virt + PL022 上，对控制器连续发消息"
echo "    会奇偶交替（奇数条读到 20 ba 17，偶数条读回全 0），"
echo "    内核自带 spidev 表现完全相同；见设计文档 §6。"
echo "  - 换回内核 spidev：rmmod chardev_spi_flash &&"
echo "      echo spi0.0 > /sys/bus/spi/drivers/spidev/bind"
