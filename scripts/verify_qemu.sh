#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# 端到端验收（宿主侧，覆盖设计文档 §9 的 L1~L4）：
#   1. make 交叉编译
#   2. 启动 QEMU（额外挂 -qmp unix socket，用 qmp_set_temp.py 改温度）
#   3. 自动执行：
#        L1 i2cget 原始寄存器对照（insmod 前，驱动绑定后 i2c-dev 会 EBUSY）
#        L2 insmod → 设备树自动 probe → name=tmp105
#        L3 QMP qom-set 改温度 → temp1_input 跟随；负温度/符号扩展
#        L4 阈值量化、max_alarm 翻转、反复 insmod/rmmod 100 次、内核异常扫描
#   4. 汇总 PASS/FAIL；退出码非 0 表示失败（并保留串口日志路径）
#
# 实现要点：QEMU 的 stdout 是块缓冲的，串口日志读到的时间不可控。
# 所以"取值类"检查一律让**客户机把结果写进 9p 共享目录**（$KMODS_ROOT/.verify），
# 宿主轮询文件；串口日志只用于看内核 printk（probe 日志）与异常扫描。
#
# 用法：./scripts/verify_qemu.sh
# 可用环境变量覆盖：QEMU / KDIR / INITRD / KMODS_ROOT
set -u

QEMU=${QEMU:-/home/alan/workspace/qemu/build/qemu-system-aarch64}
KDIR=${KDIR:-/home/alan/workspace/linux-4.9.263}
INITRD=${INITRD:-/home/alan/workspace/busybox-1.33.1/initramfs.cpio.gz}
KMODS_ROOT=${KMODS_ROOT:-/home/alan/workspace/linux-kmods}
KO_IN_GUEST=/mnt/drivers/tmp105_hwmon/tmp105_hwmon.ko
HWMON=/sys/class/hwmon/hwmon0

SOCK=$(mktemp -u /tmp/tmp105-qmp.XXXXXX.sock)
FIFO=$(mktemp -u /tmp/tmp105-in.XXXXXX)
LOG=$(mktemp /tmp/tmp105-log.XXXXXX)
BUILD_LOG=$(mktemp /tmp/tmp105-build.XXXXXX)
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

echo "== 1. 交叉编译 =="
if make -C "$KMODS_ROOT" KDIR="$KDIR" ARCH=arm64 \
	CROSS_COMPILE=aarch64-linux-gnu- > "$BUILD_LOG" 2>&1; then
	ko=$(ls -l "$KMODS_ROOT/drivers/tmp105_hwmon/tmp105_hwmon.ko" | awk '{print $5}')
	ok "make 成功（tmp105_hwmon.ko = $ko bytes）"
else
	bad "make 失败"; cat "$BUILD_LOG"; exit 1
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

# wait_for <串口日志正则> [超时秒]
wait_for() {
	local pat=$1 t=${2:-30} i=0
	while [ "$i" -lt "$t" ]; do
		grep -qE "$pat" "$LOG" && return 0
		sleep 1; i=$((i + 1))
	done
	return 1
}

# wait_file <共享文件> [超时秒] [内部正则]
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

# guest_out <共享文件名> <客户机命令>：让客户机把命令输出写进 9p 共享目录
guest_out() {
	local name=$1; shift
	rm -f "$OUT/$name"
	send "$* > /mnt/.verify/$name 2>&1"
	wait_file "$OUT/$name" 30
}

# 读共享文件的第一行（去掉 CR）
out_value() { tr -d '\r' < "$OUT/$1" 2>/dev/null | head -1; }

wait_for "activate this console" 60 || {
	echo "guest 没起来，日志尾部："; tail -20 "$LOG"; exit 1; }
send ""
send "mkdir -p /mnt && mount -t 9p -o trans=virtio,version=9p2000.L kmods /mnt && echo MOUNT_OK"
wait_for "MOUNT_OK" 20 && ok "9p 挂载本工程源码树到 /mnt（也能回写 .verify/）" \
	|| bad "9p 挂载失败"
send "mkdir -p /mnt/.verify"

echo "== 3. L1：原始寄存器（此时驱动未绑定 0x48）=="
if guest_out raw "i2cget -y 0 48 0x00 w"; then
	raw=$(out_value raw)
	case "$raw" in
	0x*)	ok "i2cget 读到原始值 $raw（SMBus 低字节在前；0x0019 → 25.0 °C）" ;;
	*)	bad "i2cget 输出异常：$raw" ;;
	esac
else
	bad "i2cget 读不到 0x48（器件或总线没通）"
fi

echo "== 4. L2：设备树自动 probe =="
guest_out base "ls /sys/class/hwmon 2>/dev/null | grep -c '^hwmon'"
BASE_HWMON=$(out_value base)
send "insmod $KO_IN_GUEST"
if wait_for "tmp105 at 0x48 on" 30; then
	ok "insmod + 设备树自动 probe：$(grep -o 'tmp105 at 0x48 on.*' "$LOG" | tail -1 | tr -d '\r')"
else
	bad "没有 probe 日志（设备树 of_match 没生效？看串口日志）"
fi
if guest_out name "cat $HWMON/name" && [ "$(out_value name)" = "tmp105" ]; then
	ok "hwmon name == tmp105（按 name 定位，不依赖 hwmonN 序号）"
else
	bad "hwmon name 不是 tmp105：$(out_value name)"
fi

echo "== 5. L3：QMP 动态改温度（含负温度）=="
QMP="python3 $KMODS_ROOT/scripts/qmp_set_temp.py $SOCK"

# 5.1 负温度（符号扩展）。注意 QEMU/器件的默认 CONFIG=0 → R1:R0=00 →
#     温度寄存器 9 位有效（0.5 °C 步进）：-6.25 °C 在寄存器里量化为 -6.5 °C
#     （= -6500 m°C），而 qom-get 读的是未量化的属性值（-6250）。
QOM_PATH=$($QMP -6250 2>&1)
if [ -n "$QOM_PATH" ] && [ "${QOM_PATH#/}" != "$QOM_PATH" ]; then
	ok "定位到 tmp105 的 QOM 路径：$QOM_PATH，已 qom-set temperature=-6250"
	qom=$($QMP get)
	guest_out neg "cat $HWMON/temp1_input"
	got=$(out_value neg)
	if [ "$got" = "-6500" ]; then
		ok "负温度：temp1_input=$got（qom-get=$qom，按 9 位模式量化到 -6.5 °C）"
	elif [ "$got" = "$qom" ]; then
		ok "负温度：temp1_input=$got == qom-get=$qom"
	else
		bad "负温度异常：temp1_input=$got（qom-get=$qom，期望 -6500）"
	fi

	# 5.2 可精确表示的负值：0.5 °C 步进下的 -6.0 °C，必须与 qom-get 完全一致
	$QMP -6000 >/dev/null 2>&1
	qom=$($QMP get)
	guest_out neg2 "cat $HWMON/temp1_input"
	got=$(out_value neg2)
	if [ "$got" = "-6000" ] && [ "$qom" = "-6000" ]; then
		ok "负温度（可精确表示）：temp1_input=$got == qom-get=$qom"
	else
		bad "负温度失败：temp1_input=$got，qom-get=$qom（期望都是 -6000）"
	fi

	# 5.3 动态改温度：证明不是读死值
	$QMP 30000 >/dev/null 2>&1
	guest_out dyn "cat $HWMON/temp1_input"
	got=$(out_value dyn)
	if [ "$got" = "30000" ]; then
		ok "动态改温度：temp1_input=$got（跟随 qom-set 30000，不是读死值）"
	else
		bad "动态改温度失败：temp1_input=$got（期望 30000）"
	fi
else
	bad "QMP 改温度失败：$QOM_PATH"
fi

echo "== 6. L4：客户机自检脚本（阈值/量化/报警）=="
guest_out rh "sh /mnt/tests/read_hwmon.sh"
if wait_file "$OUT/rh" 90 "汇总" && grep -q "FAIL=0" "$OUT/rh"; then
	ok "read_hwmon.sh 全部通过"
else
	bad "read_hwmon.sh 有失败项"
fi
grep -E "^  \[(PASS|FAIL)\]" "$OUT/rh" 2>/dev/null | sed 's/^/    /'
[ -f "$OUT/rh" ] || info "read_hwmon.sh 没产出结果（见串口日志）"

echo "== 7. L4：反复 insmod/rmmod 100 次（残留检查，§9.4）=="
rm -f "$OUT/loop"
send "n=0; while [ \$n -lt 100 ]; do rmmod tmp105_hwmon; insmod $KO_IN_GUEST; n=\$((n+1)); done; rmmod tmp105_hwmon; echo done > /mnt/.verify/loop"
if wait_file "$OUT/loop" 300; then
	ok "100 次 insmod/rmmod 全部返回成功"
else
	bad "insmod/rmmod 循环没跑完（300s 超时）"
fi
guest_out after "ls /sys/class/hwmon 2>/dev/null | grep -c '^hwmon'"
AFTER_HWMON=$(out_value after)
if [ -n "$AFTER_HWMON" ] && [ "${BASE_HWMON:-x}" = "$AFTER_HWMON" ]; then
	ok "rmmod 后 /sys/class/hwmon 无残留（$AFTER_HWMON 个，与 insmod 前一致）"
else
	bad "/sys/class/hwmon 残留：insmod 前 ${BASE_HWMON:-?} 个 → 现在 ${AFTER_HWMON:-?} 个"
fi

# 只扫描"加载本模块之后"的日志：开机 0.9s 时 DesignWare I2C 驱动自带的
# WARN_ON_ONCE（i2c_dw_clk_rate）与本模块无关，见设计文档 §12 实测结论。
if sed -n '/tmp105 at 0x48/,$p' "$LOG" | grep -qE "Oops|BUG:|Call trace|WARNING:"; then
	bad "insmod 之后日志有内核异常：$(sed -n '/tmp105 at 0x48/,$p' "$LOG" | grep -oE 'Oops|BUG:|Call trace|WARNING:' | sort -u | tr '\n' ' ')"
else
	ok "insmod 之后串口日志无 Oops / BUG / WARNING / Call trace"
fi
grep -q "i2c_dw_clk_rate" "$LOG" && \
	info "开机自带（0.9s，早于本模块）：i2c_dw_clk_rate WARN_ON，与本驱动无关"

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
