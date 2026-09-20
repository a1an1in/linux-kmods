#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# 在 QEMU 客户机里跑：定位 name=tmp105 的 hwmon 设备，做完 L2 + L4 自检。
# 用法：
#   ./read_hwmon.sh                 # 模块已加载，只做检查
#   ./read_hwmon.sh /mnt/drivers/i2c/hwmon_tmp105/hwmon_tmp105.ko   # 先 insmod
#
# 注意：
#  - L1 的原始寄存器对照（i2cget）必须在 insmod **之前**做：驱动一旦绑定
#    0x48，i2c-dev 再访问同一从机会返回 "Device or resource busy"（EBUSY）。
#  - L3 的"动态改温度"和负温度用例需要宿主机的 QMP/qom-set，见
#    scripts/run_qemu.sh 与同目录的 verify_qemu.sh；本脚本只覆盖客户机侧
#    能独立完成的检查。

HWMON_ROOT=/sys/class/hwmon
I2C_BUS=${I2C_BUS:-0}
I2C_ADDR=${I2C_ADDR:-48}          # 十进制，避免 busybox 解析 0x 前缀的门槛
TMP105_REG_TEMP=0x00

pass=0
fail=0

ok()   { pass=$((pass + 1)); echo "  [PASS] $*"; }
bad()  { fail=$((fail + 1)); echo "  [FAIL] $*"; }
info() { echo "  [INFO] $*"; }

# 1) 可选：加载模块
KO="$1"
if [ -n "$KO" ]; then
	echo "== insmod $KO =="
	insmod "$KO" || { echo "insmod 失败"; exit 1; }
	sleep 1
fi

# 2) 找到我们的 hwmon 设备（按 name 找，不依赖 hwmonN 序号）
DEV=""
for d in $HWMON_ROOT/hwmon*; do
	[ -f "$d/name" ] || continue
	if [ "$(cat "$d/name" 2>/dev/null)" = "tmp105" ]; then
		DEV="$d"
		break
	fi
done

echo "== L2: probe / sysfs =="
if [ -z "$DEV" ]; then
	bad "没有找到 name=tmp105 的 hwmon 设备（insmod 了吗？看 dmesg）"
	exit 1
fi
ok "hwmon 设备：$DEV"

for f in temp1_input temp1_max temp1_min temp1_max_alarm; do
	if [ -f "$DEV/$f" ]; then
		ok "$f 存在：$(cat "$DEV/$f")"
	else
		bad "$f 缺失"
	fi
done

# 3) 量程检查
t=$(cat "$DEV/temp1_input" 2>/dev/null)
case "$t" in
''|*[!0-9-]*) bad "temp1_input 不是整数：'$t'" ;;
*)
	if [ "$t" -ge -55000 ] && [ "$t" -le 125000 ]; then
		ok "temp1_input=$t m°C 在量程内"
	else
		bad "temp1_input=$t m°C 超出 -55000..125000"
	fi
	;;
esac

# 4) 与 i2cget 原始寄存器交叉验证（L1 链路 + 换算公式）
if command -v i2cget >/dev/null 2>&1; then
	raw=$(i2cget -y "$I2C_BUS" "$I2C_ADDR" "$TMP105_REG_TEMP" w 2>&1)
	case "$raw" in
	*"busy"*)
		# 驱动已绑定该从机时，普通访问会 EBUSY；-f（I2C_SLAVE_FORCE）可绕过
		raw=$(i2cget -f -y "$I2C_BUS" "$I2C_ADDR" "$TMP105_REG_TEMP" w 2>&1)
		;;
	esac
	case "$raw" in
	0x*)
		# i2cget w 返回 SMBus 低字节在前的字 → 交换回 TMP105 的大端 8.8
		lo=$((raw & 0xff))
		hi=$(((raw >> 8) & 0xff))
		be=$(((lo << 8) | hi))
		[ "$be" -ge 32768 ] && be=$((be - 65536))   # 补码 → 有符号
		expect=$((be * 1000 / 256))
		info "i2cget raw=$raw → 有符号 $be → $expect m°C"
		if [ "$expect" = "$t" ]; then
			ok "hwmon 读数与 i2cget 换算一致"
		else
			info "hwmon=$t 与 i2cget=$expect 不同（两次读之间温度被改过？）"
		fi
		;;
	*"busy"*)
		info "i2cget 被占用且 -f 也不行：$raw"
		;;
	*)
		info "i2cget 失败：$raw（器件没挂上？）"
		;;
	esac
else
	info "客户机没有 i2cget，跳过原始寄存器交叉验证"
fi

echo "== L4: 阈值与报警 =="
ORIG_MAX=$(cat "$DEV/temp1_max" 2>/dev/null)
ORIG_MIN=$(cat "$DEV/temp1_min" 2>/dev/null)

# 4.1 写 50 °C，应能原样读回（验证 0.5 °C 量化与字节序）
if echo 50000 > "$DEV/temp1_max" 2>/dev/null; then
	rb=$(cat "$DEV/temp1_max")
	if [ "$rb" = "50000" ]; then
		ok "写 temp1_max=50000 读回 $rb（量化正确）"
	else
		bad "写 temp1_max=50000 读回 $rb"
	fi
else
	bad "写 temp1_max 失败（权限？只读文件系统？）"
fi

# 4.2 报警翻转：上限压到当前温度以下 → alarm=1；抬到当前温度以上 → alarm=0
t=$(cat "$DEV/temp1_input")
low=$((t - 5000))
high=$((t + 5000))
echo "$low" > "$DEV/temp1_max" 2>/dev/null
a1=$(cat "$DEV/temp1_max_alarm" 2>/dev/null)
echo "$high" > "$DEV/temp1_max" 2>/dev/null
a0=$(cat "$DEV/temp1_max_alarm" 2>/dev/null)
if [ "$a1" = "1" ] && [ "$a0" = "0" ]; then
	ok "temp1_max_alarm 随阈值翻转（低于温度=1，高于温度=0）"
else
	bad "temp1_max_alarm 翻转异常（低阈值=$a1，高阈值=$a0，当前温度=$t）"
fi

# 4.3 恢复原阈值
[ -n "$ORIG_MAX" ] && echo "$ORIG_MAX" > "$DEV/temp1_max" 2>/dev/null
[ -n "$ORIG_MIN" ] && echo "$ORIG_MIN" > "$DEV/temp1_min" 2>/dev/null

echo
echo "== 汇总：PASS=$pass FAIL=$fail =="
[ "$fail" -eq 0 ] || exit 1

echo
echo "提示（宿主机侧，见同目录 verify_qemu.sh 或 QEMU monitor 的 Ctrl-A c）："
echo "  qom-set <tmp105 路径> temperature -6250   # 负温度：temp1_input 应为 -6250"
echo "  qom-set <tmp105 路径> temperature 30000   # 动态改温度：temp1_input 应跟随"
