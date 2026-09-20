# linux-kmods

Linux **内核模块（kmod）** 开发工程 —— 与用户态库 [libobject](../libobject) 分离：
libobject 只做用户态（UIO/VFIO/I2C/SPI/MTD 等），内核态的驱动/模块放这里。

> 为什么单独一个工程（不要混进 libobject）：构建体系不同（kbuild vs CMake）、
> 内核 ABI 随版本变（必须跟着内核重编）、许可边界不同（GPL）、交付路径不同（rootfs/模块目录）。
> 详见 [温度传感器驱动设计文档](doc/温度传感器驱动设计文档.md) §10。

## 当前进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | 工程骨架（Makefile/Kbuild/scripts/doc） | ✅ 完成（2026-09-18） |
| M1 | QEMU 挂 tmp105 + 设备树加节点（`i2cdetect` 看到 0x48） | ✅ 无需改动：自研 QEMU **已内置** tmp105@0x48 并自动生成 FDT 节点；实测 `i2cget -y 0 48 0x00 w` → `0x0019`（设计文档 §12.1） |
| M2 | 用内核自带 lm75 驱动做对照通路 | ⏳ 可选未做（`CONFIG_SENSORS_LM75` 仍未开，需要重编内核模块；本驱动已可独立验收） |
| M3 | 自研 `tmp105_hwmon.ko` 读出 `temp1_input` | ✅ 完成并实测：probe 日志 `tmp105 at 0x48`，`temp1_input=25000`、动态改温度跟随（§12.3） |
| M4 | 阈值与 `temp1_max_alarm` | ✅ 完成并实测：写 `50000` 读回 `50000`；alarm 随阈值正确翻转（§12.3） |
| M5 | 文档收尾（`开发规范.md`）+ 测试脚本 | ✅ 完成：[开发规范](doc/开发规范.md)、`tests/read_hwmon.sh`、一键 `scripts/verify_qemu.sh`（13 项断言） |

## 规格（一眼记住）

- **器件**：TI TMP105（LM75 兼容），I2C，地址 **0x48**，挂在 virt 的 `i2c@9060000`（`snps,designware-i2c`）
- **QEMU 模型**：`hw/sensor/tmp105.c`（8.8 定点；`temperature` 属性单位 **m°C**，可用 QMP `qom-set` 动态改）
  - 实测 QOM 路径：`/machine/unattached/device[10]`（用 `scripts/qmp_set_temp.py` 自动定位，别写死）
  - 上电默认 `CONFIG=0` → **R1:R0=00 → 9 位有效（0.5 °C 步进）**：`qom-set -6250` 读回 `-6500`（§12.1）
- **驱动形态**：I2C 客户端驱动 + **hwmon**，暴露 `/sys/class/hwmon/hwmonN/temp1_{input,max,min,max_alarm}`
- **换算**：`m°C = (int16_t)raw * 1000 / 256`（raw = 寄存器 0x00 两字节，大端）
- **内核树**：`/home/alan/workspace/linux-4.9.263`（arm64，已配置并编译，可直接做外部模块构建）
- **注意**：4.9 的 `hwmon.h` 没有 `HWMON_CHANNEL_INFO()` 宏，必须手写 `hwmon_channel_info`（§12.1）

## 目录规划

```
linux-kmods/
├── README.md
├── Makefile                  # 顶层：自动发现 drivers/*/Kbuild 并逐个调 kbuild
├── .gitignore
├── drivers/
│   └── tmp105_hwmon/         # 第 1 个模块：{Kbuild,tmp105_hwmon.c}
├── scripts/
│   ├── build.sh              # 交叉编译封装（modules/clean/checkpatch/sparse）
│   ├── run_qemu.sh           # 起 QEMU（不传 -dtb，让 QEMU 自生成含 tmp105 的 FDT）
│   ├── verify_qemu.sh        # 一键端到端验收（L1~L4，13 项断言）
│   └── qmp_set_temp.py       # QMP 客户端：定位 tmp105 的 QOM 路径 + 改/读 temperature
├── tests/
│   └── read_hwmon.sh         # 设备上读 hwmon 的自测（L2/L4）
└── doc/
    ├── 温度传感器驱动设计文档.md   # 器件规约 / 架构 / 测试 / §12 实测结论
    ├── 开发规范.md                 # 编码风格 / 许可 / 已知坑
    └── 手动测试指南.md             # QEMU 里一步步手动验证（含 QMP 改温度）
```

## 构建与验证

```sh
./scripts/build.sh                                   # 等价于 make：默认内核树 + aarch64 交叉编译
./scripts/build.sh checkpatch                        # 内核树 checkpatch 自检（当前 0 errors/0 warnings）
./scripts/build.sh clean

./scripts/verify_qemu.sh                             # 一键端到端：编译 + 起 QEMU + L1~L4 断言
./scripts/run_qemu.sh                                # 手动调试：进去后 insmod /mnt/drivers/... 并跑 tests/

make KDIR=/lib/modules/$(uname -r)/build ARCH=x86_64 CROSS_COMPILE=   # 编本机内核模块
```

## 文档

- [温度传感器驱动设计文档（tmp105）](doc/温度传感器驱动设计文档.md) —— 器件规约 / 架构选择 / 驱动设计 / 设备侧配置 / 4 层测试 / 里程碑 / **§12 实测结论**
- [开发规范](doc/开发规范.md) —— 编码风格（checkpatch 0/0）、许可、日志、错误处理、提交与验收流程
- [手动测试指南](doc/手动测试指南.md) —— **纯手动命令版，且只用驱动的 hwmon 接口**：原命令行编译/起 QEMU、`temp1_*` 读写与边界（0.5 °C 量化、量程钳位）、报警翻转、`qom-set` 造温度条件、反向用例、`Ctrl-A c` 排查、现象速查表
