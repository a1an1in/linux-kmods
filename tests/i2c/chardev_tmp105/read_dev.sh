#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# 在 QEMU 客户机里跑：只用 /dev/tmp105（字符设备接口）做自检
#
# 用法：
#   ./read_dev.sh                          # 模块已加载
#   ./read_dev.sh /mnt/drivers/i2c/chardev_tmp105/chardev_tmp105.ko
#   IOCTL_TEST=/mnt/tests/i2c/chardev_tmp105/build/ioctl_test ./read_dev.sh
#
# 教学点：
#   - 字符设备在 /dev 下的节点由 devtmpfs/udev 按"class+device"自动创建；
#     若系统没有 devtmpfs，就要自己 mknod（本脚本会演示怎么取主设备号）；
#   - read()/write() 之外的接口（阈值读写、报警）走 ioctl，需要配套的
#     用户态程序（ioctl_test）。

DEV=${DEV:-/dev/tmp105}
IOCTL_TEST=${IOCTL_TEST:-/mnt/tests/i2c/chardev_tmp105/build/ioctl_test}

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "  [PASS] $*"; }
bad()  { fail=$((fail + 1)); echo "  [FAIL] $*"; }
info() { echo "  [INFO] $*"; }

# 1) 可选：加载模块
if [ -n "$1" ]; then
	echo "== insmod $1 =="
	insmod "$1" || { echo "insmod 失败"; exit 1; }
	sleep 1
fi

echo "== A. 设备节点 =="
if [ ! -c "$DEV" ]; then
	# 没有 devtmpfs 时演示：从 /proc/devices 取主设备号，自己 mknod
	major=$(awk '$2 == "tmp105" { print $1 }' /proc/devices 2>/dev/null)
	if [ -n "$major" ]; then
		info "$DEV 不存在，但 /proc/devices 里有 tmp105（major=$major）"
		info "手动创建：mknod $DEV c $major 0"
		[ -e /dev ] && mknod "$DEV" c "$major" 0 2>/dev/null
	fi
fi

if [ -c "$DEV" ]; then
	ok "$DEV 存在：$(ls -l "$DEV" | awk '{print $1, $5, $6}')"
else
	bad "$DEV 不存在（insmod 了吗？看 dmesg）"
	exit 1
fi

# 2) read()：驱动返回十进制文本温度（m°C）
echo "== B. read()：读当前温度 =="
t=$(cat "$DEV" 2>/dev/null)
case "$t" in
''|*[!0-9-]*)
	bad "cat $DEV 不是整数：'$t'"
	;;
*)
	if [ "$t" -ge -55000 ] && [ "$t" -le 125000 ]; then
		ok "温度 = ${t} m°C（量程内）"
	else
		bad "温度 = ${t} m°C 超出量程"
	fi
	;;
esac

# 3) write()：写文本阈值（等价于 ioctl SET_TMAX）
echo "== C. write()：写上限阈值 =="
if echo 50000 > "$DEV" 2>/dev/null; then
	ok "write(\"50000\") 成功（阈值 50.0 °C）"
else
	bad "write 失败（权限？只读文件系统？）"
fi

# 4) 错误路径：非数字内容 → EINVAL
if echo abc > "$DEV" 2>/dev/null; then
	bad "写非数字竟然成功了（应该返回 EINVAL）"
else
	ok "写非数字被拒绝（EINVAL，符合预期）"
fi

# 5) ioctl：阈值/报警/错误码（需要 ioctl_test）
echo "== D. ioctl（用户态测试程序）=="
if [ -f "$IOCTL_TEST" ]; then
	# 9p 挂载不一定允许直接执行，先拷到 /tmp（tmpfs 一定可执行）
	cp "$IOCTL_TEST" /tmp/ioctl_test 2>/dev/null || cp "$IOCTL_TEST" /tmp/ioctl_test
	out=$(/tmp/ioctl_test "$DEV" 2>&1)
	echo "$out" | sed 's/^/    /'
	if echo "$out" | grep -q "PASS=11 FAIL=0"; then
		ok "ioctl_test 全部通过（11 项）"
	else
		bad "ioctl_test 有失败项"
	fi
else
	info "没找到 $IOCTL_TEST，跳过 ioctl 测试"
fi

# 6) 恢复出厂默认阈值
echo 80000 > "$DEV" 2>/dev/null

echo
echo "== 汇总：PASS=$pass FAIL=$fail =="
[ "$fail" -eq 0 ] || exit 1

echo
echo "提示："
echo "  - 与 hwmon 驱动共存：insmod hwmon_tmp105.ko 后，"
echo "    /sys/class/hwmon/hwmonN/temp1_input 与 /dev/tmp105 应读到同一温度"
echo "  - 改环境温度（宿主侧）："
echo "    python3 scripts/qmp_dev.py <sock> set --match tmp105 --value -6000"
