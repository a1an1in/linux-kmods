/* SPDX-License-Identifier: GPL-2.0 */
/*
 * chardev_tmp105.h - /dev/tmp105 的用户态 ABI
 * （驱动与用户态测试程序共用这一个头文件）
 *
 * 这是驱动与用户态的"契约"：
 *   - 命令号、单位、数据布局一旦发布就不能改
 *     （改了就是破坏 ABI：老程序会 -ENOTTY 或读错数据）；
 *   - 定义只写一份，两边都 include 它，避免漂移。
 *
 * 用户态只需要两个 UAPI 头（glibc/交叉工具链都自带）：
 *   <linux/ioctl.h>、<linux/types.h>
 */
#ifndef _CHARDEV_TMP105_H
#define _CHARDEV_TMP105_H

#include <linux/ioctl.h>
#include <linux/types.h>

/* 温度单位统一为 m°C（毫摄氏度） */
/* 例：25000 = 25.000 °C；-6250 = -6.250 °C */
/* 同一类设备的命令共用 magic；MAXNR 给用户态校验用 */
#define TMP105_IOC_MAGIC	0x74		/* 't' */
#define TMP105_IOC_MAXNR	5

/* 读当前温度 */
#define TMP105_IOC_GET_TEMP	_IOR(TMP105_IOC_MAGIC, 0, __s32)
/* 读上限阈值 T_HIGH */
#define TMP105_IOC_GET_TMAX	_IOR(TMP105_IOC_MAGIC, 1, __s32)
/* 写上限阈值 T_HIGH */
#define TMP105_IOC_SET_TMAX	_IOW(TMP105_IOC_MAGIC, 2, __s32)
/* 读下限阈值 T_LOW */
#define TMP105_IOC_GET_TMIN	_IOR(TMP105_IOC_MAGIC, 3, __s32)
/* 写下限阈值 T_LOW */
#define TMP105_IOC_SET_TMIN	_IOW(TMP105_IOC_MAGIC, 4, __s32)
/* 0/1：temp >= T_HIGH ? */
#define TMP105_IOC_GET_ALARM	_IOR(TMP105_IOC_MAGIC, 5, __s32)

#endif /* _CHARDEV_TMP105_H */
