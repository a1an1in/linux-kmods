// SPDX-License-Identifier: GPL-2.0
/*
 * chardev_spi_flash.c - SPI NOR Flash 的字符设备驱动
 * （学习用：把字符驱动标准结构，从 I2C 搬到 SPI）
 *
 * 标准结构清单（代码里用 ①…⑩ 标注对应位置）：
 *   ① 设备发现：of_device_id 表 → SPI 总线自动 probe
 *      （对照 i2c 版：那边是模块参数 bus/addr）
 *   ② 设备号：alloc_chrdev_region() / unregister_chrdev_region()
 *   ③ struct cdev：cdev_init()/cdev_add()/cdev_del()
 *   ④ class_create() + device_create() → /dev/spidevB.C
 *   ⑤ file_operations：open/release/read/write/ioctl
 *   ⑥ file->private_data 传递私有数据
 *   ⑦ copy_to_user()/copy_from_user() 搬数据
 *   ⑧ ioctl：**标准 spidev ABI**（SPI_IOC_*），不发明私有命令
 *   ⑨ mutex：保护"改配置 + 传输"这一段
 *   ⑩ probe/remove 的注册顺序与错误回滚
 *
 * 与内核自带 spidev（drivers/spi/spidev.c）的关系：
 *   - 两者对外是同一套用户态 ABI（/dev/spidevB.C + SPI_IOC_*），
 *     所以 libobject 的 Spi HAL 一行不改就能跑在本驱动上；
 *   - SPI 总线 1:1 绑定（一个器件只能绑一个驱动），
 *     本驱动与内核 spidev **互斥**：先 unbind 内核 spidev，再
 *     insmod 本模块，见 doc/chardev/spi-flash/设计文档.md §4。
 *     （对照 chardev_i2c_tmp105：那边刻意不注册 i2c client，
 *     可与 hwmon 驱动共存；SPI 没有"适配器级"的裸传输 API
 *     —— spi_sync() 必须在 spi_device 上发 spi_message，
 *     所以这里只能绑器件，不能"只借控制器"。）
 *
 * 命名见 doc/开发规范.md：drivers/<子系统>/<总线>-<器件>/
 * 本驱动属 chardev/spi、器件是 SPI NOR Flash，故模块名为
 * chardev_spi_flash，叶目录 spi-flash。
 *
 * 器件背景（QEMU virt / 真机同构）：
 *   PL022 控制器（spi0）的 CS0 上挂 n25q064 NOR Flash；
 *   JEDEC ID 用 0x9F 命令读 3 字节（20 ba 17）。
 *   设备树 ABI 是 compatible = "rohm,dh2228fv"（内核 spidev 的
 *   通用节点写法），本驱动沿用它，所以不用改设备树。
 */

#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/spi/spi.h>
#include <linux/spi/spidev.h>
#include <linux/types.h>
#include <linux/uaccess.h>

/*
 * 4.9 的头文件没有 SPI_MODE_MASK（spidev.c 自己定义），
 * 所以照抄一份：只保留"配置类"位，避免误改 SPI_READY 等
 * 控制器内部标志位。
 */
#define SPI_MODE_MASK	(SPI_CPHA | SPI_CPOL | SPI_CS_HIGH | SPI_LSB_FIRST | \
			 SPI_3WIRE | SPI_LOOP | SPI_NO_CS | SPI_READY | \
			 SPI_TX_DUAL | SPI_TX_QUAD | SPI_RX_DUAL | SPI_RX_QUAD)

#define DRIVER_NAME		"chardev_spi_flash"
#define CLASS_NAME		"chardev_spi_flash"

/* 单次传输长度上限（防止用户态申请超大内核缓冲） */
#define CHARDEV_SPI_FLASH_BUF_MAX	4096
/* 一条 SPI_IOC_MESSAGE 里的段数上限 */
#define CHARDEV_SPI_FLASH_SEG_MAX	16

/* ------------------------------------------------------------------ */
/* 私有数据：每个"设备实例"一份（先做单实例） */
/* ------------------------------------------------------------------ */

struct chardev_spi_flash {
	struct spi_device	*spi;		/* ① 匹配到的器件 */
	struct class		*class;		/* class_create() 建的 */
	struct device		*dev;		/* device_create() 建的 */
	struct cdev		cdev;		/* ③ 字符设备对象 */
	dev_t			devt;		/* ② 主/次设备号 */
	struct mutex		lock;		/* ⑨ 保护配置与传输 */
	u32			speed_hz;	/* 传输默认速率 */
};

/* 单实例指针：open() 时挂到 file->private_data（⑥） */
static struct chardev_spi_flash *flash;

/* ------------------------------------------------------------------ */
/* SPI 访问：统一走 spi_message（与 spidev 的语义一致） */
/* ------------------------------------------------------------------ */

/*
 * 把一条 spi_message 发出去（内部加锁）。
 * 这里刻意把 SPI 调用收在一个函数里（规范 §4）：
 * 别让 spi_sync() 散落在各个回调里。
 */
static int chardev_spi_flash_sync(struct chardev_spi_flash *d,
				  struct spi_message *msg)
{
	int ret;

	mutex_lock(&d->lock);				/* ⑨ */
	ret = spi_sync(d->spi, msg);
	mutex_unlock(&d->lock);

	return ret;
}

/* ------------------------------------------------------------------ */
/* ⑤ file_operations：字符设备的"行为"（实现标准 spidev ABI） */
/* ------------------------------------------------------------------ */

static int chardev_spi_flash_open(struct inode *inode, struct file *filp)
{
	/*
	 * ⑥ 把私有数据挂到 file 上（->private_data），
	 *    后面 read/write/ioctl 都从这里取；
	 *    多实例时必须这样（别靠全局变量猜设备）。
	 */
	filp->private_data = flash;

	return 0;
}

static int chardev_spi_flash_release(struct inode *inode, struct file *filp)
{
	/* 本驱动没有每文件资源要回收；写上只为结构完整 */
	return 0;
}

/*
 * read：半双工接收 count 字节（CS 在本次操作内保持有效）。
 * 这是标准 spidev 语义：裸 SPI 收发，由用户态决定协议。
 * 读 Flash 要"先命令后数据"，用 SPI_IOC_MESSAGE 组消息，
 * 或让用户态先 write() 再 read()（本驱动的 read/write 各是一次
 * 独立操作，两次之间 CS 会释放，只适合 CS 不连续的器件）
 */
/*
 * 坑：4.9 内核已经导出了 int spi_flash_read(struct spi_device *,
 * struct spi_flash_read_message *)（include/linux/spi/spi.h），
 * 所以本文件不能再用这个名字，否则报 conflicting types。
 * 命名规约：模块内符号统一用 chardev_spi_flash_ 前缀。
 */
static ssize_t chardev_spi_flash_read(struct file *filp, char __user *buf,
				      size_t count, loff_t *ppos)
{
	struct chardev_spi_flash *d = filp->private_data;
	struct spi_transfer xfer;
	struct spi_message msg;
	u8 *kbuf;
	int ret;

	if (count == 0 || count > CHARDEV_SPI_FLASH_BUF_MAX)
		return -EMSGSIZE;

	kbuf = kmalloc(count, GFP_KERNEL);
	if (!kbuf)
		return -ENOMEM;

	memset(&xfer, 0, sizeof(xfer));
	xfer.rx_buf = kbuf;
	xfer.len = count;
	xfer.speed_hz = d->speed_hz;

	spi_message_init(&msg);
	spi_message_add_tail(&xfer, &msg);

	ret = chardev_spi_flash_sync(d, &msg);
	if (ret == 0)
		ret = msg.actual_length;

	/* ⑦ 搬到用户态：检查返回值 */
	if (ret > 0 && copy_to_user(buf, kbuf, ret))
		ret = -EFAULT;

	kfree(kbuf);

	return ret;
}

/* write：半双工发送 count 字节（语义见 read 的注释） */
static ssize_t chardev_spi_flash_write(struct file *filp,
				       const char __user *buf,
				       size_t count, loff_t *ppos)
{
	struct chardev_spi_flash *d = filp->private_data;
	struct spi_transfer xfer;
	struct spi_message msg;
	u8 *kbuf;
	int ret;

	if (count == 0 || count > CHARDEV_SPI_FLASH_BUF_MAX)
		return -EMSGSIZE;

	kbuf = kmalloc(count, GFP_KERNEL);
	if (!kbuf)
		return -ENOMEM;

	/* ⑦ 从用户态搬进来：检查返回值 */
	if (copy_from_user(kbuf, buf, count)) {
		kfree(kbuf);
		return -EFAULT;
	}

	memset(&xfer, 0, sizeof(xfer));
	xfer.tx_buf = kbuf;
	xfer.len = count;
	xfer.speed_hz = d->speed_hz;

	spi_message_init(&msg);
	spi_message_add_tail(&xfer, &msg);

	ret = chardev_spi_flash_sync(d, &msg);
	if (ret == 0)
		ret = msg.actual_length;

	kfree(kbuf);

	return ret;
}

/*
 * ⑧ SPI_IOC_MESSAGE(N)：一次提交 N 段传输。
 * 与 spidev 一样：先把 spi_ioc_transfer 数组整体拷进来，
 * 再为每段准备内核缓冲（tx 从用户态拷入、rx 用 kzalloc），
 * 组一条 spi_message（N 段共用一次 CS 有效窗口），最后把
 * rx 缓冲拷回用户态。
 */
static int chardev_spi_flash_message(struct chardev_spi_flash *d,
				     struct spi_ioc_transfer __user *u_ioc,
				     unsigned int n)
{
	struct spi_ioc_transfer *ioc;
	struct spi_transfer *xfer;
	struct spi_message msg;
	u8 **txb;
	u8 **rxb;
	unsigned int i;
	unsigned int total = 0;
	int ret;

	if (n == 0 || n > CHARDEV_SPI_FLASH_SEG_MAX)
		return -EINVAL;

	ioc = memdup_user(u_ioc, n * sizeof(*ioc));
	if (IS_ERR(ioc))
		return PTR_ERR(ioc);

	xfer = kcalloc(n, sizeof(*xfer), GFP_KERNEL);
	txb = kcalloc(n, sizeof(*txb), GFP_KERNEL);
	rxb = kcalloc(n, sizeof(*rxb), GFP_KERNEL);
	if (!xfer || !txb || !rxb) {
		ret = -ENOMEM;
		goto out_free;
	}

	spi_message_init(&msg);
	for (i = 0; i < n; i++) {
		if (ioc[i].len == 0 || ioc[i].len > CHARDEV_SPI_FLASH_BUF_MAX) {
			ret = -EMSGSIZE;
			goto out_free;
		}

		if (ioc[i].tx_buf) {
			txb[i] = memdup_user((u8 __user *)
					     (uintptr_t)ioc[i].tx_buf,
					     ioc[i].len);
			if (IS_ERR(txb[i])) {
				ret = PTR_ERR(txb[i]);
				txb[i] = NULL;
				goto out_free;
			}
			xfer[i].tx_buf = txb[i];
		}
		if (ioc[i].rx_buf) {
			rxb[i] = kzalloc(ioc[i].len, GFP_KERNEL);
			if (!rxb[i]) {
				ret = -ENOMEM;
				goto out_free;
			}
			xfer[i].rx_buf = rxb[i];
		}

		xfer[i].len = ioc[i].len;
		/* 0 表示"用设备当前默认值"（与 spidev 一致） */
		xfer[i].speed_hz = ioc[i].speed_hz ? ioc[i].speed_hz
						  : d->speed_hz;
		xfer[i].bits_per_word = ioc[i].bits_per_word;
		xfer[i].delay_usecs = ioc[i].delay_usecs;
		xfer[i].cs_change = ioc[i].cs_change ? 1 : 0;

		total += ioc[i].len;
		spi_message_add_tail(&xfer[i], &msg);
	}

	ret = chardev_spi_flash_sync(d, &msg);
	if (ret == 0)
		ret = msg.actual_length;
	if (ret < 0)
		goto out_free;

	for (i = 0; i < n; i++)
		if (ioc[i].rx_buf) {
			if (copy_to_user((u8 __user *)(uintptr_t)ioc[i].rx_buf,
					 rxb[i], ioc[i].len)) {
				ret = -EFAULT;
				goto out_free;
			}
		}

	ret = total;				/* 成功返回总字节数 */

out_free:
	for (i = 0; i < n; i++) {
		kfree(txb[i]);
		kfree(rxb[i]);
	}
	kfree(xfer);
	kfree(txb);
	kfree(rxb);
	kfree(ioc);

	return ret;
}

/*
 * spidev 兼容的 ioctl：命令号、方向、参数类型都来自
 * <linux/spi/spidev.h>（UAPI），所以是"标准 ABI"而非私有命令。
 * 约定：先校验 magic 与访问方向，再按命令处理。
 */
static long chardev_spi_flash_ioctl(struct file *filp, unsigned int cmd,
				    unsigned long arg)
{
	struct chardev_spi_flash *d = filp->private_data;
	struct spi_device *spi = d->spi;
	void __user *uarg = (void __user *)arg;
	u32 tmp;
	int err;

	if (_IOC_TYPE(cmd) != SPI_IOC_MAGIC)
		return -ENOTTY;

	/*
	 * 方向与 access_ok 视角相反：_IOC_DIR 是用户态视角，
	 * access_ok 是内核视角，所以 _IOC_READ 对应 VERIFY_WRITE。
	 */
	err = 0;
	if (_IOC_DIR(cmd) & _IOC_READ)
		err = !access_ok(VERIFY_WRITE, uarg, _IOC_SIZE(cmd));
	if (err == 0 && (_IOC_DIR(cmd) & _IOC_WRITE))
		err = !access_ok(VERIFY_READ, uarg, _IOC_SIZE(cmd));
	if (err)
		return -EFAULT;

	switch (cmd) {
	case SPI_IOC_RD_MODE:
		return put_user((u8)(spi->mode & SPI_MODE_MASK),
				(u8 __user *)uarg) ? -EFAULT : 0;
	case SPI_IOC_RD_MODE32:
		return put_user((u32)(spi->mode & SPI_MODE_MASK),
				(u32 __user *)uarg) ? -EFAULT : 0;
	case SPI_IOC_RD_LSB_FIRST:
		return put_user((u8)((spi->mode & SPI_LSB_FIRST) ? 1 : 0),
				(u8 __user *)uarg) ? -EFAULT : 0;
	case SPI_IOC_RD_BITS_PER_WORD:
		return put_user(spi->bits_per_word,
				(u8 __user *)uarg) ? -EFAULT : 0;
	case SPI_IOC_RD_MAX_SPEED_HZ:
		return put_user(d->speed_hz,
				(u32 __user *)uarg) ? -EFAULT : 0;

	case SPI_IOC_WR_MODE:
	case SPI_IOC_WR_MODE32:
		if (cmd == SPI_IOC_WR_MODE) {
			u8 mode8;

			if (get_user(mode8, (u8 __user *)uarg))
				return -EFAULT;
			tmp = mode8;
		} else {
			if (get_user(tmp, (u32 __user *)uarg))
				return -EFAULT;
		}
		if (tmp & ~SPI_MODE_MASK)
			return -EINVAL;

		tmp |= spi->mode & ~SPI_MODE_MASK;
		mutex_lock(&d->lock);
		spi->mode = (u16)tmp;
		err = spi_setup(spi);	/* 让控制器认下时序 */
		mutex_unlock(&d->lock);
		if (err < 0) {
			dev_err(&spi->dev, "spi_setup(mode) failed: %d\n",
				err);
			return err;
		}
		return 0;

	case SPI_IOC_WR_LSB_FIRST: {
		u8 lsb;

		if (get_user(lsb, (u8 __user *)uarg))
			return -EFAULT;
		mutex_lock(&d->lock);
		if (lsb)
			spi->mode |= SPI_LSB_FIRST;
		else
			spi->mode &= ~SPI_LSB_FIRST;
		err = spi_setup(spi);
		mutex_unlock(&d->lock);
		if (err < 0) {
			dev_err(&spi->dev, "spi_setup(lsb) failed: %d\n",
				err);
			return err;
		}
		return 0;
	}

	case SPI_IOC_WR_BITS_PER_WORD: {
		u8 bits;

		if (get_user(bits, (u8 __user *)uarg))
			return -EFAULT;
		mutex_lock(&d->lock);
		spi->bits_per_word = bits;
		err = spi_setup(spi);
		mutex_unlock(&d->lock);
		if (err < 0) {
			dev_err(&spi->dev, "spi_setup(bits) failed: %d\n",
				err);
			return err;
		}
		return 0;
	}

	case SPI_IOC_WR_MAX_SPEED_HZ: {
		u32 save;

		if (get_user(tmp, (u32 __user *)uarg))
			return -EFAULT;
		if (tmp == 0)
			return -EINVAL;

		save = spi->max_speed_hz;
		mutex_lock(&d->lock);
		spi->max_speed_hz = tmp;
		err = spi_setup(spi);
		/*
		 * 传输速率记在 d->speed_hz（对照 spidev），
		 * spi->max_speed_hz 还原成设备树上限，
		 * 否则成了"用户设一次就永久生效"。
		 */
		if (err >= 0)
			d->speed_hz = tmp;
		spi->max_speed_hz = save;
		mutex_unlock(&d->lock);
		if (err < 0) {
			dev_err(&spi->dev, "spi_setup(speed) failed: %d\n",
				err);
			return err;
		}
		return 0;
	}

	default:
		/* 分段传输：段数编码在命令号里 */
		if (_IOC_NR(cmd) != _IOC_NR(SPI_IOC_MESSAGE(0)))
			return -ENOTTY;
		if (_IOC_DIR(cmd) != _IOC_WRITE)
			return -ENOTTY;
		if (_IOC_SIZE(cmd) % sizeof(struct spi_ioc_transfer))
			return -EINVAL;
		return chardev_spi_flash_message(d,
					 (struct spi_ioc_transfer __user *)uarg,
					 _IOC_SIZE(cmd) /
					 sizeof(struct spi_ioc_transfer));
	}
}

/*
 * fops.owner = THIS_MODULE 的作用：open 时内核给模块加引用，
 * release 时减引用 —— 所以文件还开着时 rmmod 会返回
 * -EBUSY，而不会把正在执行的代码卸掉。
 *
 * llseek = no_llseek：本设备是"传输端点"，没有文件偏移语义，
 * 与 spidev 保持一致。
 */
static const struct file_operations chardev_spi_flash_fops = {
	.owner		= THIS_MODULE,
	.open		= chardev_spi_flash_open,
	.release	= chardev_spi_flash_release,
	.read		= chardev_spi_flash_read,
	.write		= chardev_spi_flash_write,
	.unlocked_ioctl	= chardev_spi_flash_ioctl,
	.llseek		= no_llseek,
};

/* ------------------------------------------------------------------ */
/* ① 设备发现：of_device_id 表 + spi_driver（probe/remove） */
/* ------------------------------------------------------------------ */

/*
 * compatible 与内核 spidev 用的同一个通用节点写法一致，
 * 所以设备树不用改：谁先绑定，器件就归谁（1:1）。
 */
static const struct of_device_id chardev_spi_flash_of_match[] = {
	{ .compatible = "rohm,dh2228fv" },
	{ }
};
MODULE_DEVICE_TABLE(of, chardev_spi_flash_of_match);

/* ------------------------------------------------------------------ */
/* ⑩ probe/remove：注册顺序与失败回滚 */
/* ------------------------------------------------------------------ */

static int chardev_spi_flash_probe(struct spi_device *spi)
{
	struct chardev_spi_flash *d;
	int ret;

	if (flash) {
		dev_err(&spi->dev, "only one instance is supported\n");
		return -EBUSY;
	}

	d = kzalloc(sizeof(*d), GFP_KERNEL);
	if (!d)
		return -ENOMEM;

	mutex_init(&d->lock);
	d->spi = spi;
	/*
	 * 默认速率 = 设备树给的上限（12 MHz），
	 * 之后用户态可用 SPI_IOC_WR_MAX_SPEED_HZ 改。
	 */
	d->speed_hz = spi->max_speed_hz ? spi->max_speed_hz : 1000000;

	/* ② 申请设备号：动态 major（baseminor=0，count=1） */
	ret = alloc_chrdev_region(&d->devt, 0, 1, DRIVER_NAME);
	if (ret < 0) {
		dev_err(&spi->dev, "alloc_chrdev_region: %d\n", ret);
		goto err_free;
	}

	/* ③ cdev：把 file_operations 绑到设备号上 */
	cdev_init(&d->cdev, &chardev_spi_flash_fops);
	d->cdev.owner = THIS_MODULE;
	ret = cdev_add(&d->cdev, d->devt, 1);
	if (ret < 0) {
		dev_err(&spi->dev, "cdev_add: %d\n", ret);
		goto err_unregister;
	}

	/*
	 * ④ class + device：用户态才会出现 /dev/spidevB.C。
	 * 节点名与 spidev 一致（ABI 不变），
	 * 所以 libobject 的 Spi HAL 不用改。
	 */
	d->class = class_create(THIS_MODULE, CLASS_NAME);
	if (IS_ERR(d->class)) {
		ret = PTR_ERR(d->class);
		dev_err(&spi->dev, "class_create: %d\n", ret);
		goto err_del_cdev;
	}

	d->dev = device_create(d->class, &spi->dev, d->devt, d, "spidev%d.%d",
			       spi->master->bus_num, spi->chip_select);
	if (IS_ERR(d->dev)) {
		ret = PTR_ERR(d->dev);
		dev_err(&spi->dev, "device_create: %d\n", ret);
		goto err_destroy_class;
	}

	flash = d;

	/*
	 * probe 不读器件（规范 §5）。
	 * 数据通路交给用户态（spidev_test）。
	 */
	dev_info(d->dev, "ready: /dev/spidev%d.%d (bus %d cs %d, %u Hz)\n",
		 spi->master->bus_num, spi->chip_select,
		 spi->master->bus_num, spi->chip_select, d->speed_hz);

	return 0;

	/* 错误回滚：顺序与申请相反 */
err_destroy_class:
	class_destroy(d->class);
err_del_cdev:
	cdev_del(&d->cdev);
err_unregister:
	unregister_chrdev_region(d->devt, 1);
err_free:
	kfree(d);

	return ret;
}

static int chardev_spi_flash_remove(struct spi_device *spi)
{
	struct chardev_spi_flash *d = flash;

	if (!d)
		return 0;
	flash = NULL;

	device_destroy(d->class, d->devt);	/* 先摘 /dev 节点 */
	class_destroy(d->class);
	cdev_del(&d->cdev);
	unregister_chrdev_region(d->devt, 1);
	kfree(d);

	return 0;
}

static struct spi_driver chardev_spi_flash_driver = {
	.driver = {
		.name		= DRIVER_NAME,
		.of_match_table	= chardev_spi_flash_of_match,
	},
	.probe	= chardev_spi_flash_probe,
	.remove	= chardev_spi_flash_remove,
};

static int __init chardev_spi_flash_init(void)
{
	int ret;

	/*
	 * 注册 spi_driver：内核用 of_device_id 与总线上
	 * 还没有驱动的器件匹配，命中就调用 probe()。
	 * 若 spidev 已绑该器件，本驱动不被 probe
	 * （需要先 unbind，见设计文档 §4）。
	 */
	ret = spi_register_driver(&chardev_spi_flash_driver);
	if (ret < 0) {
		pr_err(DRIVER_NAME ": spi_register_driver: %d\n", ret);
		return ret;
	}

	return 0;
}

static void __exit chardev_spi_flash_exit(void)
{
	spi_unregister_driver(&chardev_spi_flash_driver);
}

module_init(chardev_spi_flash_init);
module_exit(chardev_spi_flash_exit);

MODULE_AUTHOR("linux-kmods");
MODULE_DESCRIPTION("SPI NOR flash char device driver (spidev-compatible ABI)");
MODULE_LICENSE("GPL");
