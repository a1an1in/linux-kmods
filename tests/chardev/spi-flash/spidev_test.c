// SPDX-License-Identifier: GPL-2.0
/*
 * spidev_test.c - chardev_spi_flash 的用户态验证程序
 *
 * 与 libobject 的 tests/board/test_spi.c 是**同一条验证路径**：
 *   1. open("/dev/spidevB.C")；
 *   2. 配置 mode / max_speed_hz / bits_per_word / lsb_first
 *      （即 Spi HAL 的 configure()）；
 *   3. write_then_read(0x9F, 1, id, 3)：一次 SPI_IOC_MESSAGE(2)
 *      提交"发命令 + 读数据"两段
 *      （即 Spi HAL 的 write_then_read()）；
 *   4. 打印/断言 3 字节 JEDEC ID。
 *
 * 差别只有两点：
 *   - test_spi.c 走 libobject 的 Spi 对象（要动态链接 libobject），
 *     本程序直接用 ioctl，便于 -static 编译后丢进 busybox
 *     的 initramfs 里跑（规范 §1.3）；
 *   - 本程序对"读 ID"做**重试**，原因见下。
 *
 * 为什么要重试（QEMU/PL022 平台现象，不是驱动问题）：
 *   在 QEMU virt + PL022 + n25q064 上，对 SPI 控制器连续发消息时
 *   出现全局奇偶交替：第 1、3、5… 条消息读到真实数据，
 *   第 2、4、6… 条读回全 0。与消息间隔、cs_change、
 *   消息形状、fd 是否重开都无关；内核自带 spidev 表现
 *   完全相同（见设计文档 §6 的对照实验）。
 *   所以本程序最多试 4 次，命中真实 ID 即通过，并顺带
 *   校验失败样本必须正好是全 0（那现象的指纹）。
 *
 * 用法：spidev_test [/dev/spidev0.0]
 * 输出：每项 [PASS]/[FAIL]，末行 PASS=n FAIL=m（供脚本断言）。
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/spi/spidev.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define DEF_DEV		"/dev/spidev0.0"
#define TEST_SPEED_HZ	500000		/* 与 Spi HAL 的默认配置一致 */
#define RETRY_MAX	4

/* QEMU virt 上 CS0 挂的是 n25q064（见 qemu hw/block/m25p80.c） */
static const uint8_t want_id[3] = { 0x20, 0xba, 0x17 };

static int pass;
static int fail;

/* 统计：重试里成功/失败各多少次，失败样本是否全 0 */
static int id_ok_cnt;
static int id_zero_cnt;
static int id_bad_cnt;

static void check(int ok, const char *name, const char *detail)
{
	if (ok) {
		pass++;
		printf("  [PASS] %s\n", name);
		return;
	}

	fail++;
	if (detail)
		printf("  [FAIL] %s (%s)\n", name, detail);
	else
		printf("  [FAIL] %s\n", name);
}

static int is_want_id(const uint8_t *id)
{
	return memcmp(id, want_id, 3) == 0;
}

static int is_zero_id(const uint8_t *id)
{
	return id[0] == 0 && id[1] == 0 && id[2] == 0;
}

/*
 * write_then_read：一次 SPI_IOC_MESSAGE(2) 完成"0x9F + 读 3 字节"。
 * 返回 ioctl 的返回值（成功 = 1 + 3 = 4），数据落在 id。
 */
static int read_jedec_id(int fd, uint8_t *id)
{
	uint8_t cmd = 0x9f;
	struct spi_ioc_transfer tr[2];

	memset(tr, 0, sizeof(tr));
	memset(id, 0, 3);

	tr[0].tx_buf = (uint64_t)(uintptr_t)&cmd;
	tr[0].len = 1;
	tr[1].rx_buf = (uint64_t)(uintptr_t)id;
	tr[1].len = 3;

	return ioctl(fd, SPI_IOC_MESSAGE(2), tr);
}

/* 单段全双工：同一段里既发命令又收数据 */
static int read_jedec_id_fullduplex(int fd, uint8_t *id)
{
	uint8_t tx[4] = { 0x9f, 0x00, 0x00, 0x00 };
	uint8_t rx[4] = { 0 };
	struct spi_ioc_transfer tr;

	memset(&tr, 0, sizeof(tr));
	tr.tx_buf = (uint64_t)(uintptr_t)tx;
	tr.rx_buf = (uint64_t)(uintptr_t)rx;
	tr.len = 4;

	if (ioctl(fd, SPI_IOC_MESSAGE(1), &tr) < 0)
		return -1;

	memcpy(id, rx + 1, 3);

	return 0;
}

/*
 * 带重试读 ID：返回最后的 ioctl 值，id 是最后一次数据。
 * 每次尝试都进统计（成功/全 0/异常）。
 */
static int read_id_retry(int fd, uint8_t *id, int fullduplex)
{
	int i, rc = -1;

	for (i = 0; i < RETRY_MAX; i++) {
		rc = fullduplex ? read_jedec_id_fullduplex(fd, id)
				: read_jedec_id(fd, id);
		if (rc >= 0 && is_want_id(id))
			id_ok_cnt++;
		else if (is_zero_id(id))
			id_zero_cnt++;
		else
			id_bad_cnt++;
		if (rc >= 0 && is_want_id(id))
			break;
	}

	return rc;
}

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : DEF_DEV;
	uint8_t mode = SPI_MODE_0;
	uint8_t bits = 8;
	uint8_t lsb = 0;
	uint32_t speed = TEST_SPEED_HZ;
	uint8_t rd_mode = 0xff, rd_bits = 0xff, rd_lsb = 0xff;
	uint32_t rd_speed = 0;
	uint8_t id[3];
	uint8_t tx[4] = { 0x9f, 0x00, 0x00, 0x00 };
	uint8_t rx[4];
	struct spi_ioc_transfer tr;
	uint32_t bad_mode32;
	char buf[96];
	int fd, ret;

	memset(id, 0, sizeof(id));

	printf("== chardev_spi_flash 用户态验证（dev=%s）==\n", dev);

	/* 1. open（对应 Spi HAL 的 open(bus, cs)） */
	fd = open(dev, O_RDWR);
	if (fd < 0) {
		printf("  [FAIL] open %s: %s\n", dev, strerror(errno));
		printf("PASS=0 FAIL=1\n");
		return 1;
	}
	check(1, "open 设备节点", NULL);

	/* 2. 配置（对应 Spi HAL 的 configure()） */
	check(ioctl(fd, SPI_IOC_WR_MODE, &mode) == 0,
	      "SPI_IOC_WR_MODE(0)", strerror(errno));
	check(ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed) == 0,
	      "SPI_IOC_WR_MAX_SPEED_HZ(500000)", strerror(errno));
	check(ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits) == 0,
	      "SPI_IOC_WR_BITS_PER_WORD(8)", strerror(errno));
	check(ioctl(fd, SPI_IOC_WR_LSB_FIRST, &lsb) == 0,
	      "SPI_IOC_WR_LSB_FIRST(0)", strerror(errno));

	/* 3. 回读配置（spidev ABI 必须自洽） */
	ret = ioctl(fd, SPI_IOC_RD_MODE, &rd_mode);
	check(ret == 0 && (rd_mode & 0x03) == 0, "SPI_IOC_RD_MODE 回读一致",
	      "mode");
	ret = ioctl(fd, SPI_IOC_RD_MAX_SPEED_HZ, &rd_speed);
	check(ret == 0 && rd_speed == TEST_SPEED_HZ,
	      "SPI_IOC_RD_MAX_SPEED_HZ 回读一致", "speed");
	ret = ioctl(fd, SPI_IOC_RD_BITS_PER_WORD, &rd_bits);
	check(ret == 0 && rd_bits == 8, "SPI_IOC_RD_BITS_PER_WORD 回读一致",
	      "bits");
	ret = ioctl(fd, SPI_IOC_RD_LSB_FIRST, &rd_lsb);
	check(ret == 0 && rd_lsb == 0,
	      "SPI_IOC_RD_LSB_FIRST 回读一致", "lsb");

	/* 4. write_then_read 形状：一次消息两段，返回 1+3 */
	ret = read_jedec_id(fd, id);
	snprintf(buf, sizeof(buf), "rc=%d errno=%s", ret, strerror(errno));
	check(ret == 4, "SPI_IOC_MESSAGE(2) 返回 1+3 字节", buf);

	/* 5. JEDEC ID：两段消息（= test_spi.c 形状） */
	memset(id, 0, sizeof(id));
	read_id_retry(fd, id, 0);
	snprintf(buf, sizeof(buf), "id=%02x %02x %02x", id[0], id[1], id[2]);
	check(is_want_id(id), "JEDEC ID == 20 ba 17 (n25q064)", buf);

	/* 6. 单段全双工也能读到同一个 ID */
	memset(id, 0, sizeof(id));
	read_id_retry(fd, id, 1);
	snprintf(buf, sizeof(buf), "id=%02x %02x %02x", id[0], id[1], id[2]);
	check(is_want_id(id), "单段全双工(tx+rx)读 ID 一致", buf);

	/*
	 * 7. 重试统计：必须有成功样本；失败样本必须全 0
	 *    （QEMU/PL022 奇偶指纹；平台已修则无失败样本，
	 *     本项照旧通过）。
	 */
	snprintf(buf, sizeof(buf), "ok=%d zero=%d other=%d",
		 id_ok_cnt, id_zero_cnt, id_bad_cnt);
	check(id_ok_cnt > 0 && id_bad_cnt == 0,
	      "重试样本：有成功且失败样本全 0", buf);

	/* 8. read()/write()：裸半双工语义，返回消费的字节数 */
	ret = write(fd, tx, 4);
	snprintf(buf, sizeof(buf), "rc=%d errno=%s", ret, strerror(errno));
	check(ret == 4, "write() 半双工发送 4 字节", buf);
	ret = read(fd, rx, 4);
	snprintf(buf, sizeof(buf), "rc=%d errno=%s", ret, strerror(errno));
	check(ret == 4, "read() 半双工接收 4 字节", buf);

	/* 9. 错误路径 */
	errno = 0;
	ret = ioctl(fd, _IO(0x78, 1), 0);
	snprintf(buf, sizeof(buf), "errno=%d(%s)", errno, strerror(errno));
	check(ret < 0 && errno == ENOTTY,
	      "未知 magic 的命令 → ENOTTY", buf);

	errno = 0;
	memset(&tr, 0, sizeof(tr));
	tr.tx_buf = (uint64_t)(uintptr_t)tx;
	tr.len = 8192;				/* > 驱动上限 4096 */
	ret = ioctl(fd, SPI_IOC_MESSAGE(1), &tr);
	snprintf(buf, sizeof(buf), "errno=%d(%s)", errno, strerror(errno));
	check(ret < 0 && errno == EMSGSIZE,
	      "单段超长(8192) → EMSGSIZE", buf);

	errno = 0;
	ret = ioctl(fd, _IOW(SPI_IOC_MAGIC, 0, __u8), tr.len);
	snprintf(buf, sizeof(buf), "errno=%d(%s)", errno, strerror(errno));
	check(ret < 0 && errno == EINVAL,
	      "命令号 0 但长度不合法 → EINVAL", buf);

	errno = 0;
	bad_mode32 = 0xffffffffu;	/* 含 MASK 之外的位 */
	ret = ioctl(fd, SPI_IOC_WR_MODE32, &bad_mode32);
	snprintf(buf, sizeof(buf), "errno=%d(%s)", errno, strerror(errno));
	check(ret < 0 && errno == EINVAL,
	      "WR_MODE32 非法位 → EINVAL", buf);

	/* 10. 收尾：配置仍可读回（失败用例没破坏状态） */
	rd_speed = 0;
	ret = ioctl(fd, SPI_IOC_RD_MAX_SPEED_HZ, &rd_speed);
	check(ret == 0 && rd_speed == TEST_SPEED_HZ,
	      "失败用例后配置未被破坏", NULL);

	close(fd);

	printf("PASS=%d FAIL=%d\n", pass, fail);

	return fail == 0 ? 0 : 1;
}
