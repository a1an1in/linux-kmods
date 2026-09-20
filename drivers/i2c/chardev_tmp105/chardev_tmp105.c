// SPDX-License-Identifier: GPL-2.0
/*
 * chardev_tmp105.c - TMP105 的字符设备驱动
 * （学习用：把字符驱动的标准结构完整走一遍）
 *
 * 标准结构清单（代码里用 ①…⑩ 标注对应位置）：
 *   ① 模块参数：总线号 / 从机地址
 *   ② 设备号：alloc_chrdev_region() / unregister_chrdev_region()
 *   ③ struct cdev：cdev_init()/cdev_add()/cdev_del()
 *   ④ class_create() + device_create() → /dev/tmp105
 *   ⑤ file_operations：open/read/write/llseek/ioctl
 *   ⑥ file->private_data 传递私有数据
 *   ⑦ copy_to_user()/copy_from_user() 搬数据
 *   ⑧ 私有 ioctl：_IOR/_IOW 命令号 + get/put_user()
 *   ⑨ mutex：锁只保护"访问器件"这一段
 *   ⑩ init/exit 的注册顺序与错误回滚
 *
 * 与 hwmon_tmp105 的关系（同一颗芯片，两种暴露方式）：
 *   - hwmon_tmp105：i2c client 驱动 → hwmon，暴露 temp1_*
 *   - 本模块：字符设备驱动 → /dev/tmp105
 *   本模块刻意**不注册 i2c client**：只用 i2c_get_adapter() 拿
 *   适配器引用 + i2c_transfer 直接发消息，所以不去"占"0x48，
 *   可与 hwmon_tmp105 同时加载（正好对照两种接口）。
 *
 * 命名/位置见 doc/开发规范.md：drivers/<总线>/<子系统>_<器件>/
 * 注意：/dev/tmp105 与 hwmon 的 name=tmp105 是两套独立 ABI。
 */

#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/i2c.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/types.h>
#include <linux/uaccess.h>

#include "chardev_tmp105.h"

#define DRIVER_NAME		"chardev_tmp105"
#define DEVICE_NAME		"tmp105"	/* → /dev/tmp105 */

/* 器件寄存器指针与换算常数（与 hwmon_tmp105 保持一致） */
#define TMP105_REG_TEMP		0x00
#define TMP105_REG_T_LOW	0x02
#define TMP105_REG_T_HIGH	0x03

#define TMP105_TEMP_SCALE_DIV	256		/* 8.8 定点 */
#define TMP105_LIMIT_STEP_MC	500		/* 阈值 0.5 °C 量化 */
#define TMP105_LIMIT_SHIFT	7
#define TMP105_TEMP_MIN_MC	(-55000)	/* 量程下限 */
#define TMP105_TEMP_MAX_MC	125000		/* 量程上限 */

/* ------------------------------------------------------------------ */
/* ① 模块参数：环境相关的量（总线/地址）做成参数 */
/* ------------------------------------------------------------------ */

static int bus;
module_param(bus, int, 0444);
MODULE_PARM_DESC(bus, "I2C adapter number (default 0)");

static int addr = 0x48;
module_param(addr, int, 0444);
MODULE_PARM_DESC(addr, "I2C slave address (default 0x48)");

/* ------------------------------------------------------------------ */
/* 私有数据：每个"设备实例"一份（先做单实例） */
/* ------------------------------------------------------------------ */

struct tmp105_char {
	struct device		*dev;		/* device_create() 建的 */
	struct class		*class;		/* class_create() 建的 */
	struct cdev		cdev;		/* ③ 字符设备对象 */
	dev_t			devt;		/* ② 主/次设备号 */
	struct i2c_adapter	*adapter;	/* 总线控制器 */
	u16			addr;		/* 从机地址 */
	struct mutex		lock;		/* ⑨ 保护寄存器访问 */
};

/* 单实例指针：open() 时挂到 file->private_data（⑥） */
static struct tmp105_char *tmp105;

/* ------------------------------------------------------------------ */
/* I2C 访问：用 i2c_transfer 手写消息                                 */
/* （对比：hwmon 驱动用的是 SMBus API） */
/* ------------------------------------------------------------------ */

/*
 * 读 16 位寄存器：TMP105 高字节在前。
 * 先发"寄存器指针"再读 2 字节，由 i2c_transfer 串成一次事务
 * （STOP 只在最后），这是最通用的总线访问方式。
 */
static int tmp105_read_word(struct tmp105_char *d, u8 reg, s16 *raw)
{
	u8 buf[2];
	struct i2c_msg msgs[2] = {
		{
			.addr = d->addr,
			.flags = 0,
			.len = 1,
			.buf = &reg,
		},
		{
			.addr = d->addr,
			.flags = I2C_M_RD,
			.len = 2,
			.buf = buf,
		},
	};
	int ret;

	mutex_lock(&d->lock);				/* ⑨ */
	ret = i2c_transfer(d->adapter, msgs, ARRAY_SIZE(msgs));
	mutex_unlock(&d->lock);
	if (ret < 0)
		return ret;				/* 传播 -EREMOTEIO */
	if (ret != ARRAY_SIZE(msgs))
		return -EIO;

	*raw = (s16)((buf[0] << 8) | buf[1]);

	return 0;
}

static int tmp105_write_word(struct tmp105_char *d, u8 reg, s16 raw)
{
	u8 buf[3] = { reg, (u8)(raw >> 8), (u8)raw };
	struct i2c_msg msg = {
		.addr = d->addr,
		.flags = 0,
		.len = ARRAY_SIZE(buf),
		.buf = buf,
	};
	int ret;

	mutex_lock(&d->lock);				/* ⑨ */
	ret = i2c_transfer(d->adapter, &msg, 1);
	mutex_unlock(&d->lock);
	if (ret < 0)
		return ret;
	if (ret != 1)
		return -EIO;

	return 0;
}

/* 8.8 定点 → m°C（与 hwmon 驱动同一公式） */
static int tmp105_reg_to_mc(s16 raw)
{
	return (s32)raw * 1000 / TMP105_TEMP_SCALE_DIV;
}

/*
 * 注意"返回值二义性"这个坑：温度本身可以是负数
 * （-6250 = -6.25 °C），若把温度直接当返回值，就没法区分
 * "合法的负温度"和"错误码 -EINVAL"。
 * 所以统一用 ret + 出参（*mc）：ret < 0 才是错误。
 */
static int tmp105_read_temp_mc(struct tmp105_char *d, int *mc)
{
	s16 raw;
	int ret;

	ret = tmp105_read_word(d, TMP105_REG_TEMP, &raw);
	if (ret < 0)
		return ret;

	*mc = tmp105_reg_to_mc(raw);

	return 0;
}

static int tmp105_read_limit_mc(struct tmp105_char *d, u8 reg, int *mc)
{
	s16 raw;
	int ret;

	ret = tmp105_read_word(d, reg, &raw);
	if (ret < 0)
		return ret;

	*mc = tmp105_reg_to_mc(raw);

	return 0;
}

static int tmp105_set_limit_mc(struct tmp105_char *d, u8 reg, long mc)
{
	long raw;

	mc = clamp_val(mc, TMP105_TEMP_MIN_MC, TMP105_TEMP_MAX_MC);
	raw = DIV_ROUND_CLOSEST(mc, TMP105_LIMIT_STEP_MC) << TMP105_LIMIT_SHIFT;

	return tmp105_write_word(d, reg, (s16)raw);
}

/* 报警：软件比较 temp >= T_HIGH（不用 ALERT 引脚） */
static int tmp105_get_alarm(struct tmp105_char *d, int *alarm)
{
	int temp, tmax, ret;

	ret = tmp105_read_temp_mc(d, &temp);
	if (ret < 0)
		return ret;

	ret = tmp105_read_limit_mc(d, TMP105_REG_T_HIGH, &tmax);
	if (ret < 0)
		return ret;

	*alarm = temp >= tmax ? 1 : 0;

	return 0;
}

/* ------------------------------------------------------------------ */
/* ⑤ file_operations：字符设备的"行为" */
/* ------------------------------------------------------------------ */

static int tmp105_open(struct inode *inode, struct file *filp)
{
	/*
	 * ⑥ 把私有数据挂到 file 上（->private_data），
	 *    后面 read/write/ioctl 都从这里取；
	 *    多实例时必须这样（别靠全局变量猜设备）。
	 */
	filp->private_data = tmp105;

	return 0;
}

static int tmp105_release(struct inode *inode, struct file *filp)
{
	/* 本驱动没有每文件资源要回收；写上只为结构完整 */
	return 0;
}

/*
 * read：返回当前温度的十进制文本，如 "25000\n"（单位 m°C）
 * 用文本是为了 `cat /dev/tmp105` 就能看，便于手动验证。
 *
 * 教学点：
 *   - 必须尊重 *ppos 与 count：用户态可能分多次读、也可能从
 *     中间读；
 *   - 搬数据用 copy_to_user()（检查用户指针，失败 -EFAULT）；
 *   - 读完了要返回 0（EOF）；
 *   - 简单场景可用 simple_read_from_buffer() 少写几行。
 */
static ssize_t tmp105_read(struct file *filp, char __user *buf, size_t count,
			   loff_t *ppos)
{
	struct tmp105_char *d = filp->private_data;
	char kbuf[32];
	int len, mc, ret;

	ret = tmp105_read_temp_mc(d, &mc);		/* 内部已加锁 */
	if (ret < 0)
		return ret;

	len = scnprintf(kbuf, sizeof(kbuf), "%d\n", mc);

	if (*ppos >= len)
		return 0;				/* 读完 → EOF */
	if (count > len - *ppos)
		count = len - *ppos;		/* 不要溢出 */

	if (copy_to_user(buf, kbuf + *ppos, count))	/* ⑦ */
		return -EFAULT;

	*ppos += count;

	return count;
}

/*
 * write：写一个整数（m°C）作为上限阈值 T_HIGH：
 *     echo 50000 > /dev/tmp105     # 上限设 50.0 °C
 * 返回值必须是"实际消费的字节数"（用户态靠它判断）。
 */
static ssize_t tmp105_write(struct file *filp, const char __user *buf,
			    size_t count, loff_t *ppos)
{
	struct tmp105_char *d = filp->private_data;
	char kbuf[32];
	long mc;
	int ret;

	if (count == 0 || count >= sizeof(kbuf))
		return -EINVAL;

	if (copy_from_user(kbuf, buf, count))		/* ⑦ */
		return -EFAULT;

	kbuf[count] = '\0';				/* 自己收尾 */
	ret = kstrtol(kbuf, 0, &mc);
	if (ret)
		return ret;			/* 语法错 */

	ret = tmp105_set_limit_mc(d, TMP105_REG_T_HIGH, mc);
	if (ret < 0)
		return ret;

	return count;
}

/*
 * ⑧ unlocked_ioctl：内核不再拿大锁，自己保证并发安全。
 * 约定：先校验 magic/命令号，再按数据方向取/放值。
 * 这里都是标量（__s32），get_user()/put_user() 就够；
 * 若是结构体，要换成 copy_from_user()/copy_to_user()
 * （并注意 _IOC_SIZE / _IOC_DIR）。
 */
static long tmp105_ioctl(struct file *filp, unsigned int cmd,
			 unsigned long arg)
{
	struct tmp105_char *d = filp->private_data;
	void __user *uarg = (void __user *)arg;
	s32 val;
	int iv, ret;

	if (_IOC_TYPE(cmd) != TMP105_IOC_MAGIC)
		return -ENOTTY;
	if (_IOC_NR(cmd) > TMP105_IOC_MAXNR)
		return -ENOTTY;

	switch (cmd) {
	case TMP105_IOC_GET_TEMP:
		ret = tmp105_read_temp_mc(d, &iv);
		if (ret < 0)
			return ret;
		val = iv;
		return put_user(val, (s32 __user *)uarg) ? -EFAULT : 0;

	case TMP105_IOC_GET_TMAX:
		ret = tmp105_read_limit_mc(d, TMP105_REG_T_HIGH, &iv);
		if (ret < 0)
			return ret;
		val = iv;
		return put_user(val, (s32 __user *)uarg) ? -EFAULT : 0;

	case TMP105_IOC_GET_TMIN:
		ret = tmp105_read_limit_mc(d, TMP105_REG_T_LOW, &iv);
		if (ret < 0)
			return ret;
		val = iv;
		return put_user(val, (s32 __user *)uarg) ? -EFAULT : 0;

	case TMP105_IOC_SET_TMAX:
		if (get_user(val, (s32 __user *)uarg))
			return -EFAULT;
		return tmp105_set_limit_mc(d, TMP105_REG_T_HIGH, val);

	case TMP105_IOC_SET_TMIN:
		if (get_user(val, (s32 __user *)uarg))
			return -EFAULT;
		return tmp105_set_limit_mc(d, TMP105_REG_T_LOW, val);

	case TMP105_IOC_GET_ALARM:
		ret = tmp105_get_alarm(d, &iv);
		if (ret < 0)
			return ret;
		val = iv;
		return put_user(val, (s32 __user *)uarg) ? -EFAULT : 0;

	default:
		return -ENOTTY;				/* 未知命令 */
	}
}

/*
 * fops.owner = THIS_MODULE 的作用：open 时内核给模块加引用，
 * release 时减引用 —— 所以文件还开着时 rmmod 会返回
 * -EBUSY，而不会把正在执行的代码卸掉。
 */
static const struct file_operations tmp105_fops = {
	.owner		= THIS_MODULE,
	.open		= tmp105_open,
	.release	= tmp105_release,
	.read		= tmp105_read,
	.write		= tmp105_write,
	.unlocked_ioctl	= tmp105_ioctl,
	.llseek		= default_llseek,	/* 让 *ppos 语义完整 */
};

/* ------------------------------------------------------------------ */
/* ⑩ init/exit：注册顺序与失败回滚 */
/* ------------------------------------------------------------------ */

static int __init tmp105_init(void)
{
	struct tmp105_char *d;
	int ret, mc;

	d = kzalloc(sizeof(*d), GFP_KERNEL);
	if (!d)
		return -ENOMEM;

	mutex_init(&d->lock);
	d->addr = (u16)addr;

	/* ① 拿适配器引用：用完必须 i2c_put_adapter() */
	d->adapter = i2c_get_adapter(bus);
	if (!d->adapter) {
		pr_err(DRIVER_NAME ": no i2c adapter %d\n", bus);
		ret = -ENODEV;
		goto err_free;
	}

	/* ② 申请设备号：动态 major（baseminor=0，count=1） */
	ret = alloc_chrdev_region(&d->devt, 0, 1, DEVICE_NAME);
	if (ret < 0) {
		pr_err(DRIVER_NAME ": alloc_chrdev_region: %d\n", ret);
		goto err_put_adapter;
	}

	/* ③ cdev：把 file_operations 绑到设备号上 */
	cdev_init(&d->cdev, &tmp105_fops);
	d->cdev.owner = THIS_MODULE;
	ret = cdev_add(&d->cdev, d->devt, 1);
	if (ret < 0) {
		pr_err(DRIVER_NAME ": cdev_add: %d\n", ret);
		goto err_unregister;
	}

	/* ④ class + device：用户态才会出现 /dev/tmp105 */
	d->class = class_create(THIS_MODULE, DEVICE_NAME);
	if (IS_ERR(d->class)) {
		ret = PTR_ERR(d->class);
		pr_err(DRIVER_NAME ": class_create: %d\n", ret);
		goto err_del_cdev;
	}

	d->dev = device_create(d->class, NULL, d->devt, d, DEVICE_NAME);
	if (IS_ERR(d->dev)) {
		ret = PTR_ERR(d->dev);
		pr_err(DRIVER_NAME ": device_create: %d\n", ret);
		goto err_destroy_class;
	}

	tmp105 = d;

	/* 读一次温度：失败不致命 */
	if (tmp105_read_temp_mc(d, &mc) == 0)
		dev_info(d->dev, "ready: /dev/%s (i2c-%d addr 0x%02x) T=%dmC\n",
			 DEVICE_NAME, bus, d->addr, mc);
	else
		dev_info(d->dev, "ready: /dev/%s (i2c-%d addr 0x%02x)\n",
			 DEVICE_NAME, bus, d->addr);

	return 0;

	/* 错误回滚：顺序与申请相反 */
err_destroy_class:
	class_destroy(d->class);
err_del_cdev:
	cdev_del(&d->cdev);
err_unregister:
	unregister_chrdev_region(d->devt, 1);
err_put_adapter:
	i2c_put_adapter(d->adapter);
err_free:
	kfree(d);

	return ret;
}

static void __exit tmp105_exit(void)
{
	struct tmp105_char *d = tmp105;

	if (!d)
		return;
	tmp105 = NULL;

	device_destroy(d->class, d->devt);	/* 先摘 /dev 节点 */
	class_destroy(d->class);
	cdev_del(&d->cdev);
	unregister_chrdev_region(d->devt, 1);
	i2c_put_adapter(d->adapter);
	kfree(d);
}

module_init(tmp105_init);
module_exit(tmp105_exit);

MODULE_AUTHOR("linux-kmods");
MODULE_DESCRIPTION("TMP105 char device driver (char-driver skeleton)");
MODULE_LICENSE("GPL");
