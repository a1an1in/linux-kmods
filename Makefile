# SPDX-License-Identifier: GPL-2.0
#
# linux-kmods 顶层 Makefile —— 递归发现 drivers/**/Kbuild 做外部模块构建
#
#   make                                       # 默认内核树 + arm64 交叉编译
#   make KDIR=/lib/modules/$(uname -r)/build ARCH=x86_64 CROSS_COMPILE=   # 编本机
#   make clean
#   make list                                  # 列出会被构建的模块目录
#
# 目录/命名规则见 doc/开发规范.md：
#   drivers/<总线>/<子系统>_<器件>/{Kbuild,<子系统>_<器件>.c}
# 新增驱动只要按规则建目录（含 Kbuild），**本文件无需修改**（递归发现，任意嵌套深度）。

KDIR		?= /home/alan/workspace/linux-4.9.263
ARCH		?= arm64
CROSS_COMPILE	?= aarch64-linux-gnu-

PWD		:= $(shell pwd)
KBUILD_FLAGS	:= -C $(KDIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE)

# 递归发现所有模块目录：任何包含 Kbuild 的目录都当作一个模块单元
MODULE_DIRS	:= $(shell find drivers -name Kbuild -printf '%h\n' 2>/dev/null | sort)

.PHONY: all modules clean list help

all: modules

modules:
	@if [ -z "$(MODULE_DIRS)" ]; then \
		echo "找不到任何模块目录（drivers/**/Kbuild）"; exit 1; \
	fi
	@for d in $(MODULE_DIRS); do \
		echo "=== 构建 $$d ==="; \
		$(MAKE) $(KBUILD_FLAGS) M=$(PWD)/$$d modules || exit 1; \
	done

clean:
	@for d in $(MODULE_DIRS); do \
		$(MAKE) $(KBUILD_FLAGS) M=$(PWD)/$$d clean; \
	done

list:
	@echo "$(MODULE_DIRS)" | tr ' ' '\n'

help:
	@echo "make [KDIR=<内核树>] [ARCH=<arch>] [CROSS_COMPILE=<前缀>]"
	@echo "发现到的模块目录:"; $(MAKE) -s list
