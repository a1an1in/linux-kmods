// SPDX-License-Identifier: GPL-2.0
/*
 * ioctl_test.c - /dev/tmp105 的**用户态**测试程序（配合 chardev_i2c_tmp105 驱动）
 *
 * 学习点：用户态怎么用字符设备
 *   - open()/read()/write()/close() 基本调用
 *   - ioctl()：命令号由 _IOR/_IOW 生成，**驱动与用户态共用同一个头文件**
 *   - 错误路径：errno（ENOTTY=命令不认识、EINVAL=参数不对、EFAULT=指针不对）
 *
 * 交叉编译（busybox rootfs 没动态库，必须 -static）：
 *   aarch64-linux-gnu-gcc -static -O2 -Wall \
 *       -I ../../../drivers/chardev/i2c-tmp105 \
 *       -o build/ioctl_test ioctl_test.c
 *
 * 用法：ioctl_test [/dev/tmp105]
 */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>

#include "chardev_i2c_tmp105.h"

static const char *dev = "/dev/tmp105";
static int pass, fail;

static void ok(const char *fmt, ...)
{
	va_list ap;

	pass++;
	printf("  [PASS] ");
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
}

static void bad(const char *fmt, ...)
{
	va_list ap;

	fail++;
	printf("  [FAIL] ");
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
}

/* 读温度（ioctl），成功返回 0，结果写回 *val */
static int get_temp(int fd, int *val)
{
	return ioctl(fd, TMP105_IOC_GET_TEMP, val);
}

int main(int argc, char **argv)
{
	char buf[64];
	ssize_t n;
	int fd, val;

	if (argc > 1)
		dev = argv[1];

	fd = open(dev, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open(%s) 失败：%s\n", dev, strerror(errno));
		return 1;
	}
	printf("打开 %s 成功（fd=%d）\n", dev, fd);

	/* --- read()：驱动返回十进制文本，如 "25000\n" --- */
	memset(buf, 0, sizeof(buf));
	n = read(fd, buf, sizeof(buf) - 1);
	if (n > 0) {
		buf[n] = '\0';
		ok("read() 返回 %zd 字节：「%s」", n, buf);
	} else {
		bad("read() 失败：%s", strerror(errno));
	}

	/* --- ioctl GET_TEMP --- */
	val = 0;
	if (get_temp(fd, &val) == 0)
		ok("TMP105_IOC_GET_TEMP = %d mC", val);
	else
		bad("TMP105_IOC_GET_TEMP 失败：%s", strerror(errno));

	/* --- ioctl SET/GET_TMAX：阈值会被 0.5 °C 量化 --- */
	val = 20000;
	if (ioctl(fd, TMP105_IOC_SET_TMAX, &val) == 0)
		ok("TMP105_IOC_SET_TMAX(%d) 成功", val);
	else
		bad("SET_TMAX 失败：%s", strerror(errno));

	val = 0;
	if (ioctl(fd, TMP105_IOC_GET_TMAX, &val) == 0) {
		if (val == 20000)
			ok("GET_TMAX 读回 %d（与写入一致）", val);
		else
			bad("GET_TMAX 读回 %d（期望 20000）", val);
	} else {
		bad("GET_TMAX 失败：%s", strerror(errno));
	}

	/* --- 报警：阈值 20 °C，当前 25 °C → 应为 1 --- */
	val = -1;
	if (ioctl(fd, TMP105_IOC_GET_ALARM, &val) == 0) {
		if (val == 1)
			ok("GET_ALARM = 1（阈值低于当前温度）");
		else
			bad("GET_ALARM = %d（期望 1）", val);
	} else {
		bad("GET_ALARM 失败：%s", strerror(errno));
	}

	/* --- 抬到 90 °C → 报警应回到 0 --- */
	val = 90000;
	if (ioctl(fd, TMP105_IOC_SET_TMAX, &val) == 0 && get_temp(fd, &val) == 0) {
		int alarm = -1;

		if (ioctl(fd, TMP105_IOC_GET_ALARM, &alarm) == 0) {
			if (alarm == 0)
				ok("GET_ALARM = 0（阈值高于当前温度）");
			else
				bad("GET_ALARM = %d（期望 0）", alarm);
		}
	}

	/* --- write()：写文本阈值（等价于 SET_TMAX） --- */
	n = write(fd, "30000", 5);
	if (n == 5) {
		ok("write(\"30000\") 返回 %zd（= 消费的字节数）", n);
	} else {
		bad("write 失败：%s", strerror(errno));
	}

	/* --- 错误路径 1：未知命令 → ENOTTY --- */
	errno = 0;
	val = 0;
	if (ioctl(fd, _IOR(TMP105_IOC_MAGIC, 9, int), &val) < 0 && errno == ENOTTY)
		ok("未知命令返回 ENOTTY");
	else
		bad("未知命令没按预期返回 ENOTTY（errno=%d）", errno);

	/* --- 错误路径 2：magic 不对 → ENOTTY --- */
	errno = 0;
	if (ioctl(fd, _IOR(0x99, 0, int), &val) < 0 && errno == ENOTTY)
		ok("magic 不对返回 ENOTTY");
	else
		bad("magic 校验失败（errno=%d）", errno);

	/* --- 错误路径 3：用户指针非法（NULL）→ EFAULT --- */
	errno = 0;
	if (ioctl(fd, TMP105_IOC_GET_TEMP, NULL) < 0 && errno == EFAULT)
		ok("NULL 指针返回 EFAULT");
	else
		bad("NULL 指针没按预期返回 EFAULT（errno=%d）", errno);

	/* --- 错误路径 4：write 非数字 → EINVAL --- */
	errno = 0;
	if (write(fd, "abc", 3) < 0 && errno == EINVAL)
		ok("write(\"abc\") 返回 EINVAL");
	else
		bad("write(\"abc\") 没按预期返回 EINVAL（errno=%d）", errno);

	/* --- 恢复默认阈值 --- */
	val = 80000;
	ioctl(fd, TMP105_IOC_SET_TMAX, &val);

	close(fd);
	printf("== ioctl_test: PASS=%d FAIL=%d ==\n", pass, fail);

	return fail ? 1 : 0;
}
