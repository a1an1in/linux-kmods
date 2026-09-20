#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# chardev_i2c_tmp105 的端到端验收（宿主侧）
#
# 覆盖：
#   1. make 构建驱动 + 交叉编译用户态测试程序（静态 aarch64）
#   2. 起 QEMU（挂 QMP socket，用于改环境温度）
#   3. insmod 后 /dev/tmp105 自动出现（class+device → devtmpfs）
#   4. read()：cat /dev/tmp105 得到十进制温度（m°C）
#   5. write()：echo 阈值成功；写非数字被拒（EINVAL）
#   6. ioctl：ioctl_test 11 项（阈值/报警/ENOTTY/EFAULT/EINVAL）
#   7. 动态：QMP 改温度 → cat /dev/tmp105 跟随
#   8. 共存：与 hwmon_i2c_tmp105 同时加载，两个接口读到同一温度
#   9. rmmod 后 /dev/tmp105 消失；100 次 insmod/rmmod 无残留
#  10. insmod 之后的内核日志无 Oops/BUG/WARNING
#
# 位置：tests/chardev/i2c-tmp105/（与 drivers/chardev/i2c-tmp105/ 同构）
# 用法：tests/chardev/i2c-tmp105/verify_qemu.sh
set -u

QEMU=${QEMU:-/home/alan/workspace/qemu/build/qemu-system-aarch64}
KDIR=${KDIR:-/home/alan/workspace/linux-4.9.263}
INITRD=${INITRD:-/home/alan/workspace/busybox-1.33.1/initramfs.cpio.gz}
KMODS_ROOT=${KMODS_ROOT:-/home/alan/workspace/linux-kmods}
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}

TESTDIR_HOST="$KMODS_ROOT/tests/chardev/i2c-tmp105"
TESTDIR_GUEST=/mnt/tests/chardev/i2c-tmp105
KO_CHAR_GUEST=/mnt/drivers/chardev/i2c-tmp105/chardev_i2c_tmp105.ko
KO_HWMON_GUEST=/mnt/drivers/hwmon/i2c-tmp105/hwmon_i2c_tmp105.ko
DEV=/dev/tmp105

SOCK=$(mktemp -u /tmp/tmp105c-qmp.XXXXXX.sock)
FIFO=$(mktemp -u /tmp/tmp105c-in.XXXXXX)
LOG=$(mktemp /tmp/tmp105c-log.XXXXXX)
BUILD_LOG=$(mktemp /tmp/tmp105c-build.XXXXXX)
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
	rm -f "$FIFO" "$SOCK"
}
trap cleanup EXIT

echo "== 1. 构建驱动 + 用户态测试程序 =="
if make -C "$KMODS_ROOT" KDIR="$KDIR" ARCH=arm64 \
	CROSS_COMPILE="$CROSS" > "$BUILD_LOG" 2>&1; then
	ko=$(ls -l "$KMODS_ROOT/drivers/chardev/i2c-tmp105/chardev_i2c_tmp105.ko" |
	     awk '{print $5}')
	ok "make 成功（chardev_i2c_tmp105.ko = $ko bytes）"
else
	bad "make 失败"; cat "$BUILD_LOG"; exit 1
fi

mkdir -p "$TESTDIR_HOST/build"
if "$CROSS"gcc -static -O2 -Wall \
	-I "$KMODS_ROOT/drivers/chardev/i2c-tmp105" \
	-o "$TESTDIR_HOST/build/ioctl_test" "$TESTDIR_HOST/ioctl_test.c" \
	>> "$BUILD_LOG" 2>&1; then
	ok "交叉编译 ioctl_test 成功（静态 aarch64）"
else
	bad "ioctl_test 编译失败"; cat "$BUILD_LOG"; exit 1
fi

echo "== 2. 启动 QEMU（QMP socket：$SOCK）=="
rm -rf "$OUT"; mkdir -p "$OUT"
"$QEMU" -M virt -cpu cortex-a57 -m 2G \
	-kernel "$KDIR/arch/arm64/boot/Image" \
	-initrd "$INITRD" \
	-nographic \
	-qmp "unix:$SOCK,server,nowait" \
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

echo "== 3. 加载驱动：/dev/tmp105 是否自动出现 =="
send "insmod $KO_CHAR_GUEST"
if wait_for "ready: /dev/tmp105" 30; then
	ok "insmod 成功：$(grep -o 'ready: /dev/tmp105.*' "$LOG" | tail -1 | tr -d '\r')"
else
	bad "没有看到 /dev/tmp105 的 probe 日志"
fi

guest_out devnode "ls -l $DEV"
if [ -c "$OUT/devnode" ] || grep -q "^c" "$OUT/devnode" 2>/dev/null; then
	ok "设备节点存在：$(out_value devnode)"
else
	bad "设备节点不存在：$(out_value devnode)"
fi
guest_out class "ls /sys/class/tmp105/"
grep -q "tmp105" "$OUT/class" 2>/dev/null && ok "/sys/class/tmp105/tmp105 存在（class+device 建好了）" \
	|| bad "/sys/class/tmp105/ 下没有节点"

echo "== 4. read()/write()（字符设备基本接口）=="
guest_out cat1 "cat $DEV"
got=$(out_value cat1)
[ "$got" = "25000" ] && ok "cat $DEV = $got（25.0 °C，单位 m°C）" \
	|| bad "cat $DEV = $got（期望 25000）"

guest_out wr_ok "echo 50000 > $DEV && echo WRITE_OK"
grep -q "WRITE_OK" "$OUT/wr_ok" 2>/dev/null && ok "write(\"50000\") 成功（上限阈值 50 °C）" \
	|| bad "write 失败：$(out_value wr_ok)"

guest_out wr_bad "echo abc > $DEV; echo RC=\$?"
if grep -q "RC=1" "$OUT/wr_bad" 2>/dev/null && \
   grep -q "Invalid argument" "$OUT/wr_bad" 2>/dev/null; then
	ok "写非数字被拒（Invalid argument，rc=1）"
else
	bad "写非数字没有报 EINVAL：$(cat "$OUT/wr_bad" 2>/dev/null | tr '\n' ' ')"
fi

echo "== 5. ioctl（用户态测试程序，11 项）=="
guest_out iotest "cp $TESTDIR_GUEST/build/ioctl_test /tmp/ && /tmp/ioctl_test $DEV; echo RC=\$?"
if grep -q "PASS=11 FAIL=0" "$OUT/iotest" 2>/dev/null; then
	ok "ioctl_test 全部通过（阈值/报警/ENOTTY/EFAULT/EINVAL）"
else
	bad "ioctl_test 有失败项"
fi
grep -E "^  \[(PASS|FAIL)\]" "$OUT/iotest" 2>/dev/null | sed 's/^/    /'

echo "== 6. 动态：QMP 改环境温度 → /dev/tmp105 跟随 =="
QMP="python3 $KMODS_ROOT/scripts/qmp_dev.py $SOCK"
QOM_PATH=$(cd "$KMODS_ROOT" && $QMP set --match tmp105 --prop temperature --value -6000 2>&1)
if [ -n "$QOM_PATH" ] && [ "${QOM_PATH#/}" != "$QOM_PATH" ]; then
	guest_out neg "cat $DEV"
	got=$(out_value neg)
	[ "$got" = "-6000" ] && ok "QMP 设 -6000 → cat $DEV = $got" \
		|| bad "动态改温失败：cat $DEV = $got（期望 -6000）"
	(cd "$KMODS_ROOT" && $QMP set --match tmp105 --prop temperature --value 25000 >/dev/null 2>&1)
else
	bad "QMP 改温度失败：$QOM_PATH"
fi

echo "== 7. 与 hwmon_i2c_tmp105 共存（同一颗芯片，两个接口）=="
send "insmod $KO_HWMON_GUEST"
wait_for "hwmon_i2c_tmp105 0-0048" 30 && ok "hwmon_i2c_tmp105 也加载成功" \
	|| bad "hwmon_i2c_tmp105 加载失败（两个模块抢设备？）"
guest_out both "echo HW=\$(cat /sys/class/hwmon/hwmon0/temp1_input) CH=\$(cat $DEV)"
hw=$(sed -n 's/.*HW=\([-0-9]*\).*/\1/p' "$OUT/both" 2>/dev/null)
ch=$(sed -n 's/.*CH=\([-0-9]*\).*/\1/p' "$OUT/both" 2>/dev/null)
if [ -n "$hw" ] && [ "$hw" = "$ch" ]; then
	ok "两个接口读到同一温度：hwmon=$hw  /dev/tmp105=$ch"
else
	bad "两个接口不一致：hwmon=$hw  /dev/tmp105=$ch"
fi

echo "== 8. 卸载与残留 =="
send "rmmod chardev_i2c_tmp105"
guest_out rm1 "ls $DEV 2>&1; echo RC=\$?"
grep -q "No such file" "$OUT/rm1" 2>/dev/null && ok "rmmod 后 $DEV 消失" \
	|| bad "rmmod 后 $DEV 还在：$(out_value rm1)"
guest_out hwkeep "cat /sys/class/hwmon/hwmon0/temp1_input"
[ -n "$(out_value hwkeep)" ] && ok "hwmon_i2c_tmp105 不受影响，仍可读：$(out_value hwkeep)" \
	|| bad "hwmon 接口也没了"

echo "== 9. 反复 insmod/rmmod 100 次 =="
rm -f "$OUT/loop"
send "n=0; while [ \$n -lt 100 ]; do rmmod chardev_i2c_tmp105; insmod $KO_CHAR_GUEST; n=\$((n+1)); done; rmmod chardev_i2c_tmp105; echo done > /mnt/.verify/loop"
if wait_file "$OUT/loop" 300; then
	ok "100 次 insmod/rmmod 全部成功"
else
	bad "insmod/rmmod 循环没跑完（300s 超时）"
fi
guest_out after "ls $DEV 2>&1 | head -1"
grep -q "No such file" "$OUT/after" 2>/dev/null && ok "循环结束后 $DEV 已清理" \
	|| bad "循环结束后 $DEV 仍存在"

if sed -n '/ready: \/dev\/tmp105/,$p' "$LOG" | grep -qE "Oops|BUG:|Call trace|WARNING:"; then
	bad "insmod 之后日志有内核异常：$(sed -n '/ready: \/dev\/tmp105/,$p' "$LOG" | grep -oE 'Oops|BUG:|Call trace|WARNING:' | sort -u | tr '\n' ' ')"
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
