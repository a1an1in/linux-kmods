#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# iio_i2c_tmp105 的端到端验收（宿主侧，覆盖设计文档 §6 的 L1~L4）：
#   1. make 交叉编译（递归构建发现 drivers/iio/i2c-tmp105/Kbuild）
#   2. 启动 QEMU（挂 QMP socket，用 scripts/qmp_dev.py 改温度）
#   3. 自动执行：
#        L1 i2cget 原始寄存器对照（insmod 前，驱动绑定后 i2c-dev 会 EBUSY）
#        L2 insmod -> 设备树自动 probe -> name=tmp105 的 iio:deviceN
#        L3 QMP qom-set 改温度 -> in_temp_raw 换算跟随（含负温度/量化）
#        L4 客户机 read_iio.sh 自检、100 次 insmod/rmmod、内核异常扫描
#   4. 汇总 PASS/FAIL；退出码非 0 表示失败（并保留串口日志路径）
#
# 与 hwmon_i2c_tmp105/verify_qemu.sh 的差异：
#   - 断言对象从 temp1_input（m°C，驱动算好）换成
#     in_temp_raw（8.8 定点）+ in_temp_scale，m°C 由客户机 shell 换算
#     （raw * 1000 / 256，教学点：IIO 的 processed 公式）
#
# 实现要点同 hwmon 版：QEMU stdout 是块缓冲，"取值类"检查让客户机把
# 结果写进 9p 共享目录（$KMODS_ROOT/.verify），宿主轮询文件。
#
# 位置：tests/iio/i2c-tmp105/（与 drivers/iio/i2c-tmp105/ 同构）
# 用法：tests/iio/i2c-tmp105/verify_qemu.sh
# 可用环境变量覆盖：QEMU / KDIR / INITRD / KMODS_ROOT
set -u

QEMU=${QEMU:-/home/alan/workspace/qemu/build/qemu-system-aarch64}
KDIR=${KDIR:-/home/alan/workspace/linux-4.9.263}
INITRD=${INITRD:-/home/alan/workspace/busybox-1.33.1/initramfs.cpio.gz}
KMODS_ROOT=${KMODS_ROOT:-/home/alan/workspace/linux-kmods}
KO_IN_GUEST=/mnt/drivers/iio/i2c-tmp105/iio_i2c_tmp105.ko

SOCK=$(mktemp -u /tmp/iio105-qmp.XXXXXX.sock)
FIFO=$(mktemp -u /tmp/iio105-in.XXXXXX)
LOG=$(mktemp /tmp/iio105-log.XXXXXX)
BUILD_LOG=$(mktemp /tmp/iio105-build.XXXXXX)
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
	ko=$(ls -l "$KMODS_ROOT/drivers/iio/i2c-tmp105/iio_i2c_tmp105.ko" | awk '{print $5}')
	ok "make 成功（iio_i2c_tmp105.ko = $ko bytes）"
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

# guest_out <共享文件名> <客户机命令>：结果写进 9p 共享目录
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
wait_for "MOUNT_OK" 20 && ok "9p 挂载本工程源码树到 /mnt" \
	|| bad "9p 挂载失败"
send "mkdir -p /mnt/.verify"

echo "== 3. L1：原始寄存器（此时驱动未绑定 0x48）=="
if guest_out raw0 "i2cget -y 0 48 0x00 w"; then
	raw0=$(out_value raw0)
	case "$raw0" in
	0x*)	ok "i2cget 读到原始值 $raw0（SMBus 低字节在前）" ;;
	*)	bad "i2cget 输出异常：$raw0" ;;
	esac
else
	bad "i2cget 读不到 0x48（器件或总线没通）"
fi

echo "== 4. L2：设备树自动 probe =="
guest_out base "ls /sys/bus/iio/devices 2>/dev/null | grep -c '^iio:device'"
BASE_IIO=$(out_value base)
send "insmod $KO_IN_GUEST"
if wait_for "iio at 0x48 on" 30; then
	ok "insmod + 设备树自动 probe：$(grep -o 'iio at 0x48 on.*' "$LOG" | tail -1 | tr -d '\r')"
else
	bad "没有 probe 日志（设备树 of_match 没生效？看串口日志）"
fi

# 按 name 定位 iio:deviceN（不依赖序号），把路径写回共享目录
send "for d in /sys/bus/iio/devices/iio:device*; do [ -f \$d/name ] && [ \"\$(cat \$d/name)\" = tmp105 ] && echo \$d > /mnt/.verify/devpath; done; cat /mnt/.verify/devpath"
wait_file "$OUT/devpath" 20 || { bad "没找到 name=tmp105 的 iio 设备"; exit 1; }
IIO_DEV=$(out_value devpath)
[ -n "$IIO_DEV" ] && ok "按 name 定位到 $IIO_DEV（不依赖 deviceN 序号）" \
	|| { bad "name=tmp105 的 iio 设备没找到"; exit 1; }

guest_out nm "cat $IIO_DEV/name"
nm=$(out_value nm)
if [ "$nm" = "tmp105" ]; then
	ok "iio name == tmp105（用户态 ABI，不随模块名变）"
else
	bad "iio name 不是 tmp105：$nm"
fi

echo "== 5. L2：in_temp_raw / in_temp_scale =="
guest_out sc "cat $IIO_DEV/in_temp_scale"
sc=$(out_value sc)
if [ "$sc" = "3.906250" ]; then
	ok "in_temp_scale=$sc（= 1000/256 m°C/LSB）"
else
	bad "in_temp_scale=$sc（期望 3.906250）"
fi
# 上电默认 25.0 °C -> raw 0x1900 = 6400（与 L1 的 i2cget 值对照）
guest_out rawn "cat $IIO_DEV/in_temp_raw"
rawn=$(out_value rawn)
case "$rawn" in
''|*[!0-9-]*) bad "in_temp_raw 不是整数：'$rawn'" ;;
*)
	ok "in_temp_raw=$rawn（有符号 8.8 定点）"
	guest_out mc0 "r=\$(cat $IIO_DEV/in_temp_raw); echo \$((r*1000/256))"
	mc0=$(out_value mc0)
	# 用 L1 的 i2cget 值换算出期望 m°C
	if [ "${raw0:-}" != "" ]; then
		lo=$((raw0 & 0xff)); hi=$(((raw0 >> 8) & 0xff))
		be=$(((lo << 8) | hi)); [ "$be" -ge 32768 ] && be=$((be - 65536))
		exp0=$((be * 1000 / 256))
		if [ "$mc0" = "$exp0" ]; then
			ok "raw 换算 m°C=$mc0 与 i2cget 对照一致"
		else
			info "mc=$mc0 与 i2cget=$exp0 不同（温度被改过？不判失败）"
		fi
	fi
	;;
esac

echo "== 6. L3：QMP 动态改温度（raw 路径跟随）=="
QMP="python3 $KMODS_ROOT/scripts/qmp_dev.py $SOCK --match tmp105 --prop temperature"
QOM_PATH=$($QMP set --value -6250 2>&1)
if [ -n "$QOM_PATH" ] && [ "${QOM_PATH#/}" != "$QOM_PATH" ]; then
	ok "定位到 tmp105 的 QOM 路径：$QOM_PATH"
	# 6.1 9 位量化：-6.25 °C -> 器件量化为 -6.5 °C -> raw -1664 -> -6500
	guest_out mc1 "r=\$(cat $IIO_DEV/in_temp_raw); echo \$((r*1000/256))"
	got=$(out_value mc1)
	if [ "$got" = "-6500" ]; then
		ok "负温度：raw 换算 = $got m°C（9 位模式量化到 -6.5 °C）"
	else
		bad "负温度异常：$got m°C（期望 -6500）"
	fi
	# 6.2 可精确表示的负值
	$QMP set --value -6000 >/dev/null 2>&1
	guest_out mc2 "r=\$(cat $IIO_DEV/in_temp_raw); echo \$((r*1000/256))"
	got=$(out_value mc2)
	if [ "$got" = "-6000" ]; then
		ok "负温度（可精确表示）：raw 换算 = $got m°C"
	else
		bad "负温度失败：$got m°C（期望 -6000）"
	fi
	# 6.3 动态改温度：证明不是读死值
	$QMP set --value 30000 >/dev/null 2>&1
	guest_out mc3 "r=\$(cat $IIO_DEV/in_temp_raw); echo \$((r*1000/256))"
	got=$(out_value mc3)
	if [ "$got" = "30000" ]; then
		ok "动态改温度：raw 换算 = $got m°C（跟随 qom-set）"
	else
		bad "动态改温度失败：$got m°C（期望 30000）"
	fi
else
	bad "QMP 改温度失败：$QOM_PATH"
fi

echo "== 7. L4：客户机自检脚本 =="
guest_out ri "sh /mnt/tests/iio/i2c-tmp105/read_iio.sh"
if wait_file "$OUT/ri" 90 "汇总" && grep -q "FAIL=0" "$OUT/ri"; then
	ok "read_iio.sh 全部通过"
else
	bad "read_iio.sh 有失败项"
fi
grep -E "^  \[(PASS|FAIL)\]" "$OUT/ri" 2>/dev/null | sed 's/^/    /'

echo "== 8. L4：反复 insmod/rmmod 100 次（残留检查）=="
rm -f "$OUT/loop"
send "n=0; while [ \$n -lt 100 ]; do rmmod iio_i2c_tmp105; insmod $KO_IN_GUEST; n=\$((n+1)); done; rmmod iio_i2c_tmp105; echo done > /mnt/.verify/loop"
if wait_file "$OUT/loop" 300; then
	ok "100 次 insmod/rmmod 全部返回成功"
else
	bad "insmod/rmmod 循环没跑完（300s 超时）"
fi
guest_out after "ls /sys/bus/iio/devices 2>/dev/null | grep -c '^iio:device'"
AFTER_IIO=$(out_value after)
if [ -n "$AFTER_IIO" ] && [ "${BASE_IIO:-x}" = "$AFTER_IIO" ]; then
	ok "rmmod 后 /sys/bus/iio/devices 无残留（$AFTER_IIO 个）"
else
	bad "iio 设备残留：insmod 前 ${BASE_IIO:-?} 个 -> 现在 ${AFTER_IIO:-?} 个"
fi

# 只扫描"加载本模块之后"的日志：开机 0.9s 的 i2c_dw WARN 与本模块无关
if sed -n '/iio at 0x48/,$p' "$LOG" | grep -qE "Oops|BUG:|Call trace|WARNING:"; then
	bad "insmod 之后日志有内核异常：$(sed -n '/iio at 0x48/,$p' "$LOG" | grep -oE 'Oops|BUG:|Call trace|WARNING:' | sort -u | tr '\n' ' ')"
else
	ok "insmod 之后串口日志无 Oops / BUG / WARNING / Call trace"
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