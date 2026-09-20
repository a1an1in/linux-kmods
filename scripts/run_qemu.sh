#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# 启动 QEMU（arm64 virt + busybox initramfs）做 tmp105 驱动的上机验证。
#
# 前置结论（已核实，见设计文档 §7、§11.1）：
#   自研 QEMU（/home/alan/workspace/qemu）的 virt 机器在 create_i2c() 里
#   已经内置了 tmp105@0x48，并且**自动生成的 FDT** 里带了
#       /i2c@9060000/tmp105@48 { compatible = "ti,tmp105"; reg = <0x48>; }
#   所以本脚本默认**不传 -dtb** —— 让 QEMU 自己生成 FDT，tmp105 节点才是全的。
#   若必须传 -dtb：virt_custom.dtb 里**没有** tmp105 节点，probe 不会触发；
#   需要把下面这段加进 virt_custom.dts 再 dtc 重新生成：
#
#       i2c@9060000 {
#               /* ...原有属性不变... */
#               eeprom@50 { compatible = "atmel,24c02"; reg = <0x50>; };
#               tmp105@48 { compatible = "ti,tmp105"; reg = <0x48>; };
#       };
#
# 进入客户机后：
#   modprobe/insmod tmp105_hwmon.ko（9p 挂到 /mnt 后取 /mnt/drivers/...）
#   ./tests/read_hwmon.sh
#
# 动态改温度（验证"不是读死值"）两种方式：
#   A) 带 QMP socket 启动，在**另开一个宿主终端**里用现成脚本：
#        QMP_SOCK=/tmp/tmp105.sock ./scripts/run_qemu.sh
#        python3 scripts/qmp_set_temp.py /tmp/tmp105.sock          # 只打印 QOM 路径
#        python3 scripts/qmp_set_temp.py /tmp/tmp105.sock -6000    # 设为 -6.0 °C
#        python3 scripts/qmp_set_temp.py /tmp/tmp105.sock get      # 读回属性值
#   B) 在 QEMU 里按 Ctrl-A c 切到 monitor（路径可从 A 的脚本输出拿到）：
#        (qemu) qom-get /machine/unattached/device[10] temperature
#        (qemu) qom-set /machine/unattached/device[10] temperature -6000
#      再按 Ctrl-A c 切回串口，重新 cat temp1_input。
#
# 完整手动步骤（含阈值/报警/反复加载/反向用例）见 doc/手动测试指南.md。
set -e

QEMU=${QEMU:-/home/alan/workspace/qemu/build/qemu-system-aarch64}
KDIR=${KDIR:-/home/alan/workspace/linux-4.9.263}
INITRD=${INITRD:-/home/alan/workspace/busybox-1.33.1/initramfs.cpio.gz}
KMODS_ROOT=${KMODS_ROOT:-/home/alan/workspace/linux-kmods}
DTB=${DTB:-}          # 留空 → 用 QEMU 自生成 FDT（含 tmp105 节点）
FLASH=${FLASH:-}      # 需要 pflash 时：/home/alan/workspace/qemu_virt_machine/flash.img
QMP_SOCK=${QMP_SOCK:-}  # 非空则额外开 QMP（例 QMP_SOCK=/tmp/tmp105.sock）

[ -x "$QEMU" ] || { echo "找不到 QEMU：$QEMU" >&2; exit 1; }
[ -f "$KDIR/arch/arm64/boot/Image" ] || { echo "找不到内核 Image" >&2; exit 1; }

args=(
	-M virt
	-cpu cortex-a57
	-m 2G
	-kernel "$KDIR/arch/arm64/boot/Image"
	-initrd "$INITRD"
	-nographic
	# 9p：把本工程源码树挂进客户机（改一次编一次，最方便）
	-virtfs "local,path=$KMODS_ROOT,mount_tag=kmods,security_model=none,id=kmods"
)

[ -n "$DTB" ] && args+=(-dtb "$DTB")
[ -n "$FLASH" ] && args+=(-drive "file=$FLASH,if=pflash,index=1,format=raw")
# QMP：QEMU Machine Protocol（JSON over unix socket），用来在"宿主另一个终端"里
# 发 qom-set/qom-get 改/读器件属性（这里就是 tmp105 的 temperature）。
#   server = 以服务端监听；nowait = 不等客户端就连上
# 不设 QMP_SOCK 也能改温度，只是要按 Ctrl-A c 切到 monitor 手工敲 HMP 命令。
if [ -n "$QMP_SOCK" ]; then
	rm -f "$QMP_SOCK"		# 清掉上次可能残留的 socket 文件
	args+=(-qmp "unix:$QMP_SOCK,server,nowait")
fi

args+=(-append "console=ttyAMA0 rdinit=/linuxrc")

echo "启动：$QEMU ${args[*]}"
[ -n "$QMP_SOCK" ] && echo "QMP：$QMP_SOCK（宿主侧：scripts/qmp_set_temp.py 改/读温度）"
echo "提示：串口里 Ctrl-A c 可切到 QEMU monitor（再按一次切回）"
exec "$QEMU" "${args[@]}" "$@"
