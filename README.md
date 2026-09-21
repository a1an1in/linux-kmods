# linux-kmods

Linux **内核模块（kmod）** 开发工程 —— 与用户态库 [libobject](../libobject) 分离：
libobject 只做用户态（UIO/VFIO/I2C/SPI/MTD 等），内核态的驱动/模块放这里。

> 为什么单独一个工程（不要混进 libobject）：构建体系不同（kbuild vs CMake）、
> 内核 ABI 随版本变（必须跟着内核重编）、许可边界不同（GPL）、交付路径不同（rootfs/模块目录）。
>
> 目录与命名规则见 [开发规范](doc/开发规范.md)：**目录按子系统分、叶目录按
> `<总线>-<器件>` 起、主文件名与模块名按 `<子系统>_<总线>_<器件>` 起** ——
> 新增驱动只碰 4 处（`drivers/` + `doc/` + `tests/` + 本 README 的清单/进度）。

## 驱动清单

| 子系统 | 目录（总线-器件） | 模块 | 器件 / 对外接口 | 文档 | 测试 |
|---|---|---|---|---|---|
| hwmon | `i2c-tmp105` | `hwmon_i2c_tmp105.ko` | TI TMP105（LM75 兼容），地址 0x48；`/sys/class/hwmon/hwmonN/temp1_{input,max,min,max_alarm}`（m°C） | [设计](doc/hwmon/i2c-tmp105/设计文档.md) · [手动](doc/hwmon/i2c-tmp105/手动测试指南.md) | `tests/hwmon/i2c-tmp105/`（13 项） |
| chardev | `i2c-tmp105` | `chardev_i2c_tmp105.ko` | 同一颗 TMP105（**不占 0x48**，可与上面共存）；`/dev/tmp105`：`read/write` + 6 个 ioctl（m°C） | [设计](doc/chardev/i2c-tmp105/设计文档.md) · [手动](doc/chardev/i2c-tmp105/手动测试指南.md) | `tests/chardev/i2c-tmp105/`（18 项） |
| iio | `i2c-tmp105` | `iio_i2c_tmp105.ko` | 同一颗 TMP105（与 hwmon **互斥加载**，同占 0x48）；`/sys/bus/iio/devices/iio:deviceN/{name,in_temp_raw,in_temp_scale}`（raw+scale） | [设计](doc/iio/i2c-tmp105/设计文档.md) · [手动](doc/iio/i2c-tmp105/手动测试指南.md) | `tests/iio/i2c-tmp105/`（17 项） |
| chardev | `spi-flash` | `chardev_spi_flash.ko` | SPI NOR Flash（QEMU 上是 n25q064，PL022 spi0 CS0）；对外 = **标准 spidev ABI**：`/dev/spidev0.0` + `SPI_IOC_*`（与内核 spidev **互斥**，需先 unbind，可与 libobject 的 Spi HAL/test_spi.c 直接对接） | [设计](doc/chardev/spi-flash/设计文档.md) · [手动](doc/chardev/spi-flash/手动测试指南.md) | `tests/chardev/spi-flash/`（22 项） |

## 当前进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | 工程骨架（Makefile/Kbuild/scripts/doc） | ✅ 完成（2026-09-18） |
| M1 | QEMU 挂 tmp105 + 设备树节点 | ✅ 无需改动：自研 QEMU **已内置** tmp105@0x48 并自动生成 FDT 节点（设计文档 §12.1） |
| M2 | 用内核自带 lm75 驱动做对照通路 | ⏳ 可选未做（`CONFIG_SENSORS_LM75` 仍未开；本驱动已能独立验收） |
| M3 | 自研驱动读出 `temp1_input` | ✅ 完成并实测：probe 日志 `tmp105 at 0x48`、`temp1_input=25000`、动态改温度跟随（§12.3） |
| M4 | 阈值与 `temp1_max_alarm` | ✅ 完成并实测：写 `50000` 读回 `50000`；alarm 随阈值正确翻转（§12.3） |
| M5 | 文档 + 测试脚本 | ✅ 完成：[开发规范](doc/开发规范.md)、`tests/hwmon/i2c-tmp105/{read_hwmon.sh,verify_qemu.sh}`（13 项断言） |

### chardev_i2c_tmp105（学习：字符驱动标准结构）

| 内容 | 状态 |
|---|---|
| 标准骨架：模块参数 / `alloc_chrdev_region` / `cdev` / `class+device` / `file_operations` / ioctl / 错误回滚 | ✅ 完成（代码里用 ①~⑩ 标注，见[设计文档 §2](doc/chardev/i2c-tmp105/设计文档.md)） |
| `/dev/tmp105`：`read`（文本温度）/`write`（写阈值）/6 个 ioctl（阈值、报警、错误码） | ✅ 完成并实测：`cat /dev/tmp105` → `25000`；ioctl_test 11/11 |
| 与 `hwmon_i2c_tmp105` 共存（同芯片两种接口） | ✅ 实测：两个模块同时加载，两边都读到同一温度 |
| 端到端验收 | ✅ `tests/chardev/i2c-tmp105/verify_qemu.sh`（**PASS=18 FAIL=0**） |
| 踩坑记录（返回值二义性 / 9p 执行 / 重定向作用域） | ✅ 已写入[设计文档 §5](doc/chardev/i2c-tmp105/设计文档.md) |

### iio_i2c_tmp105（学习：IIO 子系统，与 hwmon 同芯片对照）

| 内容 | 状态 |
|---|---|
| IIO 标准骨架：`devm_iio_device_alloc` / `iio_priv` / `iio_chan_spec`（info_mask）/ `read_raw` / `devm_iio_device_register` | ✅ 完成（对照 hwmon_i2c_tmp105，见[设计文档 §2](doc/iio/i2c-tmp105/设计文档.md)） |
| `in_temp_raw`（8.8 定点有符号）+ `in_temp_scale`（3.906250 m°C/LSB），用户态换算 m°C | ✅ 完成并实测：`raw=7680 → 30000 m°C`，与 i2cget 对照一致 |
| L3 动态温度（raw 路径）：`-6250→-6500`（9 位量化）、`-6000`、`30000` | ✅ 实测跟随 |
| 端到端验收 | ✅ `tests/iio/i2c-tmp105/verify_qemu.sh`（PASS=17 FAIL=0） |
| 与 hwmon 的差异沉淀（数值模型：驱动算好 vs raw+scale） | ✅ 已写入[设计文档 §2](doc/iio/i2c-tmp105/设计文档.md) |

### chardev_spi_flash（学习：字符驱动结构搬到 SPI + 标准 spidev ABI）

| 内容 | 状态 |
|---|---|
| 标准骨架：`of_device_id` 匹配 / `alloc_chrdev_region` / `cdev` / `class+device` / `file_operations` / ioctl / 错误回滚（代码里 ①~⑩ 标注） | ✅ 完成（[设计文档 §2](doc/chardev/spi-flash/设计文档.md)，含与 `chardev_i2c_tmp105` 的逐项对照） |
| 对外 ABI：**标准 spidev**（`SPI_IOC_RD/WR_MODE/MODE32/MAX_SPEED_HZ/BITS_PER_WORD/LSB_FIRST` + `SPI_IOC_MESSAGE(N)` + `read/write`），不发明私有命令 | ✅ 完成并实测：`spidev_test` **PASS=20 FAIL=0**（含 `JEDEC ID == 20 ba 17`） |
| 与内核自带 spidev 的关系 | ✅ 实测：**同 ABI、1:1 互斥**；未 unbind 时 `insmod` 不 probe（无节点），unbind→insmod 后节点 dev 由 `153:0` 变 `240:0`，`rmmod`+`bind` 可归还 |
| 平台现象（QEMU/PL022 消息"奇偶交替"读回全 0） | ✅ 已定位并对照证实**内核 spidev 完全相同**（[设计文档 §6](doc/chardev/spi-flash/设计文档.md) 对照实验表）→ 用户态测试用重试，驱动侧不做规避 |
| 端到端验收 | ✅ `tests/chardev/spi-flash/verify_qemu.sh`（**PASS=22 FAIL=0**） |
| 踩坑记录（`spi_flash_read` 重名 / `SPI_MODE_MASK` 未导出 / busybox `rmmod` 失败仍返回 0 / `ls -l` 解析 dev 号） | ✅ 已写入[设计文档 §7](doc/chardev/spi-flash/设计文档.md) |

## 规格（一眼记住）

- **器件**：TI TMP105（LM75 兼容），I2C，地址 **0x48**，挂在 virt 的 `i2c@9060000`（`snps,designware-i2c`）
- **驱动**：`drivers/hwmon/i2c-tmp105/`，模块名 `hwmon_i2c_tmp105.ko`；hwmon 对外 `name` 仍是 **`tmp105`**（ABI，不随模块名变）
- **QEMU 模型**：`hw/sensor/tmp105.c`（8.8 定点；`temperature` 属性单位 **m°C**，可用 QMP `qom-set` 动态改）
  - 实测 QOM 路径：`/machine/unattached/device[10]`（用通用的 `scripts/qmp_dev.py --match tmp105` 自动定位，别写死）
  - 上电默认 `CONFIG=0` → **R1:R0=00 → 9 位有效（0.5 °C 步进）**：`qom-set -6250` 读回 `-6500`（§12.1）
- **换算**：`m°C = (int16_t)raw * 1000 / 256`（raw = 寄存器 0x00 两字节，大端）
- **内核树**：`/home/alan/workspace/linux-4.9.263`（arm64，已配置并编译，可直接做外部模块构建）
- **注意**：4.9 的 `hwmon.h` 没有 `HWMON_CHANNEL_INFO()` 宏，必须手写 `hwmon_channel_info`（§12.1）

## 目录结构

```
linux-kmods/
├── README.md                          # 本文件：驱动清单 / 进度 / 结构 / 构建验证
├── Makefile                           # 递归发现 drivers/**/Kbuild（新增驱动不用改它）
├── .gitignore
├── drivers/                             # ← 一级按子系统分（与内核树 drivers/ 顶层同层次）
│   ├── hwmon/
│   │   └── i2c-tmp105/                  # ← 叶目录 = <总线>-<器件>
│   │       ├── Kbuild                   #    obj-m := hwmon_i2c_tmp105.o
│   │       └── hwmon_i2c_tmp105.c           #    i2c client + hwmon 子系统（模块 hwmon_i2c_tmp105.ko）
│   ├── iio/
│   │   └── i2c-tmp105/                  #    同一颗芯片的另一种外壳（与 hwmon 互斥加载）
│   │       ├── Kbuild                   #    obj-m := iio_i2c_tmp105.o
│   │       └── iio_i2c_tmp105.c             #    i2c client + iio 子系统（raw+scale）
│   └── chardev/
│       ├── i2c-tmp105/                  #    字符设备：/dev/tmp105（不占 0x48，可与上面共存）
│       │   ├── Kbuild                   #    obj-m := chardev_i2c_tmp105.o
│       │   ├── chardev_i2c_tmp105.h         #    用户态 ABI（ioctl 号，驱动/用户态共用）
│       │   └── chardev_i2c_tmp105.c         #    cdev 字符设备
│       └── spi-flash/                   #    SPI 字符设备：/dev/spidevB.C（= 标准 spidev ABI）
│           ├── Kbuild                   #    obj-m := chardev_spi_flash.o
│           └── chardev_spi_flash.c          #    spi_driver + cdev（与内核 spidev 互斥）
├── scripts/                             # 通用工具（与具体驱动无关）
│   ├── build.sh                         #   递归构建 / clean / checkpatch / sparse
│   ├── run_qemu.sh                      #   起 QEMU（含 QMP_SOCK 开关）+ 9p 挂载
│   └── qmp_dev.py                       #   通用 QMP 工具：--match <设备> 定位，get/set 任意属性
├── tests/                               # ← 与 drivers/ 同构（子系统/<总线>-<器件>）
│   ├── hwmon/i2c-tmp105/
│   │   ├── read_hwmon.sh                #   客户机内自检（找 name=tmp105 → 校验 temp1_*）
│   │   └── verify_qemu.sh               #   宿主端到端：编译 + 起 QEMU + 13 项断言
│   ├── chardev/i2c-tmp105/
│   │   ├── ioctl_test.c                 #   用户态测试程序（与驱动共用 ioctl 头）
│   │   ├── read_dev.sh                  #   客户机内自检（只用 /dev/tmp105 接口）
│   │   └── verify_qemu.sh               #   宿主端到端：编译 + 起 QEMU + 18 项断言
│   ├── iio/i2c-tmp105/
│   │   ├── read_iio.sh                  #   客户机内自检（只用 in_temp_* 接口）
│   │   └── verify_qemu.sh               #   宿主端到端：编译 + 起 QEMU + 17 项断言
│   └── chardev/spi-flash/
│       ├── spidev_test.c                #   用户态测试程序（= test_spi.c 的静态可跑版：读 JEDEC ID）
│       ├── read_spidev.sh               #   客户机内自检（只用 /dev/spidevB.C 接口）
│       └── verify_qemu.sh               #   宿主端到端：互斥/unbind/insmod + 22 项断言
└── doc/
    ├── 开发规范.md                      # 全局：目录/命名/风格/许可/日志/提交/验收
    ├── hwmon/i2c-tmp105/
    │   ├── 设计文档.md                  # 器件规约 / 架构 / 4 层测试 / §12 实测结论
    │   └── 手动测试指南.md              # 手动验证（只用驱动接口）
    ├── chardev/i2c-tmp105/
    │   ├── 设计文档.md                  # 字符驱动标准结构（①~⑩）/ ABI / 踩坑
    │   └── 手动测试指南.md              # 手动验证（纯命令）
    ├── chardev/spi-flash/
    │   ├── 设计文档.md                  # SPI 版标准结构 / spidev ABI / 1:1 互斥 / §6 平台现象对照实验 / 踩坑
    │   └── 手动测试指南.md              # 手动验证（纯命令：unbind→insmod→spidev_test→归还）
    └── iio/i2c-tmp105/
        ├── 设计文档.md                  # IIO 模型速讲 / 与 hwmon 对照 / ABI / 实测结论
        └── 手动测试指南.md              # 手动验证（纯命令，raw 换算）
```

## 构建与验证

```sh
make                                   # 递归构建 drivers/**（默认内核树 + aarch64 交叉编译）
make list                              # 只列出会被构建的模块目录
make clean
./scripts/build.sh checkpatch          # 内核树 checkpatch 自检（当前 0 errors / 0 warnings）

tests/hwmon/i2c-tmp105/verify_qemu.sh      # 一键端到端：编译 + 起 QEMU + 13 项断言
tests/chardev/i2c-tmp105/verify_qemu.sh    # 一键端到端（含交叉编译 ioctl_test）+ 18 项断言
tests/chardev/spi-flash/verify_qemu.sh     # 一键端到端（互斥/unbind/insmod，含交叉编译 spidev_test）+ 22 项断言
tests/iio/i2c-tmp105/verify_qemu.sh        # 一键端到端：编译 + 起 QEMU + 17 项断言（raw+scale）
QMP_SOCK=/tmp/tmp105.sock ./scripts/run_qemu.sh   # 手动调试（客户机里 insmod/测试见手动指南）
make KDIR=/lib/modules/$(uname -r)/build ARCH=x86_64 CROSS_COMPILE=   # 编本机内核模块
```

## 新增一个驱动（4 步）

1. `drivers/<子系统>/<总线>-<器件>/{Kbuild,<子系统>_<总线>_<器件>.c}`（模块名 = 主文件名 = `<子系统>_<总线>_<器件>`）
2. `doc/<子系统>/<总线>-<器件>/{设计文档.md,手动测试指南.md}`
3. `tests/<子系统>/<总线>-<器件>/`（客户机自检 + 宿主端到端脚本）
4. 本 README 的「驱动清单」「当前进度」各加一行

## 文档

- [开发规范](doc/开发规范.md) —— 目录/命名规则（含反例）、新增驱动 4 步、编码风格（checkpatch 0/0）、许可、日志、错误处理、提交与验收
- [hwmon_i2c_tmp105 设计文档](doc/hwmon/i2c-tmp105/设计文档.md) —— 器件规约 / 架构选择 / 驱动设计 / 设备侧配置 / 4 层测试 / 里程碑 / **§12 实测结论**
- [hwmon_i2c_tmp105 手动测试指南](doc/hwmon/i2c-tmp105/手动测试指南.md) —— **纯手动命令版，且只用驱动的 hwmon 接口**：接口读写与边界（0.5 °C 量化、量程钳位）、报警翻转、`qom-set` 造温度、反向用例、`Ctrl-A c` 排查、现象速查表
- [chardev_i2c_tmp105 设计文档](doc/chardev/i2c-tmp105/设计文档.md) —— **字符驱动标准结构教学**：①~⑩ 要素清单、生命周期、`/dev/tmp105` ABI、与 hwmon 的对照、踩坑与扩展点
- [chardev_i2c_tmp105 手动测试指南](doc/chardev/i2c-tmp105/手动测试指南.md) —— 纯命令：编译驱动与 `ioctl_test`、起 QEMU、节点/读写/ioctl 逐步验证、与 hwmon 共存、现象速查表
- [chardev_spi_flash 设计文档](doc/chardev/spi-flash/设计文档.md) —— **SPI 版字符驱动教学**：①~⑩ 与 i2c 版逐项对照、**标准 spidev ABI**、与内核 spidev 的 **1:1 互斥**（unbind/bind）、`SPI_IOC_MESSAGE(N)` 数据流、**§6 QEMU/PL022"奇偶交替"现象的对照实验**、踩坑
- [chardev_spi_flash 手动测试指南](doc/chardev/spi-flash/手动测试指南.md) —— 纯命令：编译、起 QEMU、看起点（spidev 占位）、互斥演示、unbind→insmod 切换（dev 153:0→240:0）、跑 `spidev_test` 读 JEDEC ID、归还 spidev、现象速查表
- [iio_i2c_tmp105 设计文档](doc/iio/i2c-tmp105/设计文档.md) —— **IIO 模型速讲**：raw+scale 数值模型、与 hwmon 逐项对照、`iio:deviceN` ABI、错误码、扩展点（事件/PROCESSED/分辨率）
- [iio_i2c_tmp105 手动测试指南](doc/iio/i2c-tmp105/手动测试指南.md) —— 纯命令：定位 `iio:deviceN`、raw/scale 手算 m°C、`qom-set` 造温度、反向用例、现象速查表
