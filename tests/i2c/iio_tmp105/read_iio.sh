#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# 在 QEMU 客户机里跑：定位 name=tmp105 的 IIO 设备，做自检。
# 用法：
#   ./read_iio.sh                # 模块已加载，只做检查
#   ./read_iio.sh /mnt/drivers/i2c/iio_tmp105/iio_tmp105.ko   # 先 insmod
#
# 与 read_hwmon.sh 的差异（教学点）：
#   - hwmon 给的是"驱动算好的 m°C"（temp1_input）；
#     IIO 给的是 raw + scale，m°C 要自己算：raw * 1000 / 256
#     （scale=3.906250，正好等于 1000/256，所以 shell 整数运算即可）
#   - IIO 设备没有 /dev 节点，也不需要；一切在
#     /sys/bus/iio/devices/iio:deviceN/ 下
#
# 注意：i2cget 的原始寄存器对照必须在 insmod **之前**做（驱动绑定
# 0x48 后 i2c-dev 会 EBUSY），与 read_hwmon.sh 同一坑（开发规范 §8.1）。

IIO_ROOT=/sys/bus/iio/devices
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

# 2) 按 name 找设备（不依赖 iio:deviceN 序号，同 hwmon 按 name 找的纪律）
DEV=""
for d in $IIO_ROOT/iio:device*; do
	[ -f "$d/name" ] || continue
	if [ "$(cat "$d/name" 2>/dev/null)" = "tmp105" ]; then
		DEV="$d"
		break
	fi
done

echo "== L2: probe / sysfs =="
if [ -z "$DEV" ]; then
	bad "没有找到 name=tmp105 的 iio 设备（insmod 了吗？看 dmesg）"
	exit 1
fi
ok "iio 设备：$DEV"

for f in in_temp_raw in_temp_scale; do
	if [ -f "$DEV/$f" ]; then
		ok "$f 存在：$(cat "$DEV/$f")"
	else
		bad "$f 缺失"
	fi
done

# 3) scale 必须是 3.906250（= 1000/256 m°C/LSB）
s=$(cat "$DEV/in_temp_scale" 2>/dev/null)
if [ "$s" = "3.906250" ]; then
	ok "in_temp_scale=$s（= 1000/256 m°C/LSB）"
else
	bad "in_temp_scale=$s（期望 3.906250）"
fi

# 4) raw 是有符号整数；换算成 m°C 检查量程
raw=$(cat "$DEV/in_temp_raw" 2>/dev/null)
case "$raw" in
''|*[!0-9-]*) bad "in_temp_raw 不是整数：'$raw'" ;;
*)
	mc=$((raw * 1000 / 256))
	if [ "$mc" -ge -55000 ] && [ "$mc" -le 125000 ]; then
		ok "raw=$raw -> ${mc} m°C 在量程内"
	else
		bad "raw=$raw -> ${mc} m°C 超出 -55000..125000"
	fi
	;;
esac

# 5) 与 i2cget 原始寄存器交叉验证（L1 链路 + 换算公式）
if command -v i2cget >/dev/null 2>&1; then
	g=$(i2cget -y "$I2C_BUS" "$I2C_ADDR" "$TMP105_REG_TEMP" w 2>&1)
	case "$g" in
	*"busy"*)
		# 驱动已绑定该从机时，普通访问会 EBUSY；-f 可绕过（调试用）
		g=$(i2cget -f -y "$I2C_BUS" "$I2C_ADDR" "$TMP105_REG_TEMP" w 2>&1)
		;;
	esac
	case "$g" in
	0x*)
		# i2cget w 是 SMBus 低字节在前，换回 TMP105 的大端 8.8
		lo=$((g & 0xff))
		hi=$(((g >> 8) & 0xff))
		be=$(((lo << 8) | hi))
		[ "$be" -ge 32768 ] && be=$((be - 65536))   # 补码 -> 有符号
		expect=$((be * 1000 / 256))
		info "i2cget raw=$g -> 有符号 $be -> $expect m°C"
		if [ "$expect" = "$mc" ]; then
			ok "in_temp_raw 换算与 i2cget 一致"
		else
			info "raw=$mc 与 i2cget=$expect 不同（两次读之间温度被改过？）"
		fi
		;;
	*"busy"*)
		info "i2cget 被占用且 -f 也不行：$g"
		;;
	*)
		info "i2cget 失败：$g（器件没挂上？）"
		;;
	esac
else
	info "客户机没有 i2cget，跳过原始寄存器交叉验证"
fi

# 6) 反向用例：v1 无 write_raw，所有文件 0444，写入必须被拒
if echo 1 > "$DEV/in_temp_raw" 2>/dev/null; then
	bad "in_temp_raw 写入居然成功（应为只读）"
else
	ok "in_temp_raw 只读保护生效（v1 无 write_raw，0444）"
fi

echo
echo "== 汇总：PASS=$pass FAIL=$fail =="
[ "$fail" -eq 0 ] || exit 1

echo
echo "提示（宿主机侧，见 scripts/verify_qemu.sh 或 QEMU monitor 的 Ctrl-A c）："
echo "  qom-set <tmp105 路径> temperature -6000   # 负温度：raw 应为 -1536"
echo "  qom-set <tmp105 路径> temperature 30000   # 动态改温度：raw 应为 7680"