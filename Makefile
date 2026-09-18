# SPDX-License-Identifier: GPL-2.0
#
# linux-kmods 顶层 Makefile —— 遍历 drivers/* 调 kbuild 做外部模块构建
#
#   make                                       # 默认内核树 + arm64 交叉编译
#   make KDIR=/lib/modules/$(uname -r)/build ARCH=x86_64 CROSS_COMPILE=   # 编本机
#   make clean
#
# 每个模块目录（drivers/<name>/）里必须有 Kbuild，本文件自动发现它们，
# 逐个用 M=<模块目录> 做外部模块构建（产物为 tmp105_hwmon.ko）。

KDIR		?= /home/alan/workspace/linux-4.9.263
ARCH		?= arm64
CROSS_COMPILE	?= aarch64-linux-gnu-

PWD		:= $(shell pwd)
KBUILD_FLAGS	:= -C $(KDIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE)

# 自动发现模块目录：drivers/*/Kbuild
MODULE_DIRS	:= $(patsubst %/,%,$(dir $(wildcard drivers/*/Kbuild)))

.PHONY: all modules clean help

all: modules

modules:
	@if [ -z "$(MODULE_DIRS)" ]; then \
		echo "找不到任何模块目录（drivers/*/Kbuild）"; exit 1; \
	fi
	@for d in $(MODULE_DIRS); do \
		echo "=== 构建 $$d ==="; \
		$(MAKE) $(KBUILD_FLAGS) M=$(PWD)/$$d modules || exit 1; \
	done

clean:
	@for d in $(MODULE_DIRS); do \
		$(MAKE) $(KBUILD_FLAGS) M=$(PWD)/$$d clean; \
	done

help:
	@echo "make [KDIR=<内核树>] [ARCH=<arch>] [CROSS_COMPILE=<前缀>]"
	@echo "发现到的模块目录: $(MODULE_DIRS)"
