// SPDX-License-Identifier: GPL-2.0
/*
 * iio_tmp105.c - TI TMP105 / LM75 兼容 I2C 温度传感器驱动（IIO）
 *
 * 命名遵循 doc/开发规范.md：drivers/<总线>/<子系统>_<器件>/
 * （<总线>=i2c、<子系统>=iio、<器件>=tmp105）。
 *
 * 与 hwmon_tmp105 是同一颗芯片的两种外壳（对照学习），
 * 见 doc/i2c/iio_tmp105/设计文档.md §2：
 *   hwmon：驱动算好语义量，sysfs 直接给 m°C（temp1_input）
 *   iio：  驱动只给 raw + scale，用户态按 mC = raw * scale 换算
 *
 * 器件（QEMU hw/sensor/tmp105.c 同款，寄存器表同 hwmon_tmp105）：
 *   0x00 TEMPERATURE  16 bit  8.8 定点、12 位有效
 *          （有符号，高字节在前，负温度按补码）
 *   0x01 CONFIG        8 bit  第一版只读不写
 *   0x02 T_LOW / 0x03 T_HIGH 阈值：IIO v1 不做——
 *          事件要 ALERT 中断（virt 未接线，§7 扩展点）
 *
 * 对外接口（IIO）：name 是用户态 ABI，不随模块名变：
 *   .../name         -> "tmp105"
 *   .../in_temp_raw   -> 8.8 定点原始值（有符号，25.0 °C = 6400）
 *   .../in_temp_scale -> 3.906250（m°C/LSB）
 * 换算：mC = in_temp_raw * in_temp_scale（IIO 标准 processed 公式）
 * 注意：IIO 同样没有 /dev 节点，接口在 /sys/bus/iio/devices/。
 *
 * 参考树内同版本驱动：drivers/iio/temperature/tmp006.c（4.9）
 */

#include <linux/err.h>
#include <linux/i2c.h>
#include <linux/iio/iio.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>

/*
 * 模块名决定 .ko 名与 /sys/bus/i2c/drivers/iio_tmp105；
 * iio 设备名是另一个东西：indio_dev->name = "tmp105" 才是
 * 用户态在 /sys/bus/iio/devices/iio:deviceN/name 里看到的（ABI）。
 */
#define DRIVER_NAME		"iio_tmp105"
#define IIO_DEVICE_NAME		"tmp105"

/* 寄存器指针（与 hwmon_tmp105 一致，设计文档 §3） */
#define TMP105_REG_TEMP		0x00
#define TMP105_REG_CONF		0x01

/* 8.8 定点：1 LSB = 1/256 °C = 3.90625 m°C */
#define TMP105_TEMP_SCALE_DIV	256

struct tmp105_data {
	struct i2c_client	*client;
	struct mutex		lock;	/* 串行化寄存器访问 */
};

/* ------------------------------------------------------------------ */
/* 寄存器访问：同 hwmon_tmp105.c 的两条路径 */
/* ------------------------------------------------------------------ */

/*
 * 没有 SMBus WORD 事务时的退化路径：一次 i2c_transfer 做
 * "写指针 + 读 2 字节"组合事务（时序同 SMBus read_word）。
 * 注意不要用两次独立字节读拼：器件指针不会自动递增。
 */
static int tmp105_read_word_xfer(struct i2c_client *client, u8 reg, s16 *raw)
{
	u8 buf[2];
	struct i2c_msg msgs[2] = {
		{
			.addr = client->addr,
			.flags = 0,
			.len = 1,
			.buf = &reg,
		},
		{
			.addr = client->addr,
			.flags = I2C_M_RD,
			.len = 2,
			.buf = buf,
		},
	};
	int ret;

	ret = i2c_transfer(client->adapter, msgs, ARRAY_SIZE(msgs));
	if (ret < 0)
		return ret;
	if (ret != ARRAY_SIZE(msgs))
		return -EIO;

	*raw = (s16)((buf[0] << 8) | buf[1]);

	return 0;
}

/*
 * 读 16 位寄存器：高字节在前，用 swapped 版本
 * （同 hwmon_tmp105.c）。按开发规范 §1.5：跨模块共享符号要
 * EXPORT_SYMBOL*，教学模块自包含即可，暂不抽 drivers/common/。
 */
static int tmp105_read_word(struct tmp105_data *data, u8 reg, s16 *raw)
{
	struct i2c_client *client = data->client;
	int ret;

	mutex_lock(&data->lock);
	if (i2c_check_functionality(client->adapter,
				    I2C_FUNC_SMBUS_WORD_DATA)) {
		s32 val = i2c_smbus_read_word_swapped(client, reg);

		if (val < 0) {
			ret = val;
		} else {
			*raw = (s16)val;
			ret = 0;
		}
	} else {
		ret = tmp105_read_word_xfer(client, reg, raw);
	}
	mutex_unlock(&data->lock);

	return ret;
}

/* ------------------------------------------------------------------ */
/* IIO 接口：channels + iio_info.read_raw                              */
/* ------------------------------------------------------------------ */

static int tmp105_read_raw(struct iio_dev *indio_dev,
			   struct iio_chan_spec const *chan,
			   int *val, int *val2, long mask)
{
	struct tmp105_data *data = iio_priv(indio_dev);
	s16 raw;
	int ret;

	if (chan->type != IIO_TEMP)
		return -EINVAL;

	switch (mask) {
	case IIO_CHAN_INFO_RAW:
		/*
		 * 原始值：有符号 8.8 定点原样给用户态
		 * （25.0 °C -> 6400；-6.5 °C -> -1664）。
		 * 负值不是错误：错误用返回值表达。
		 */
		ret = tmp105_read_word(data, TMP105_REG_TEMP, &raw);
		if (ret < 0)
			return ret;
		*val = raw;
		return IIO_VAL_INT;
	case IIO_CHAN_INFO_SCALE:
		/*
		 * 1 LSB = 1000/256 m°C = 3.90625，IIO 用
		 * 整数 + 6 位小数两段表示（VAL_INT_PLUS_MICRO），
		 * 用户态看到的是 "3.906250"。
		 */
		*val = 1000 / TMP105_TEMP_SCALE_DIV;
		*val2 = 1000000 * (1000 % TMP105_TEMP_SCALE_DIV) /
			TMP105_TEMP_SCALE_DIV;
		return IIO_VAL_INT_PLUS_MICRO;
	default:
		return -EINVAL;
	}
}

/*
 * 单通道温度。不设 .indexed：文件名就没有 0 后缀
 * （in_temp_raw 而不是 in_temp0_raw），与树内 tmp006.c 一致。
 * info_mask 声明通道暴露哪些信息，IIO 据此生成 sysfs 文件
 * （对照 hwmon 的 HWMON_T_* 位掩码，两者是同一思想）。
 */
static const struct iio_chan_spec tmp105_channels[] = {
	{
		.type = IIO_TEMP,
		.info_mask_separate = BIT(IIO_CHAN_INFO_RAW) |
				      BIT(IIO_CHAN_INFO_SCALE),
	},
};

static const struct iio_info tmp105_info = {
	.read_raw		= tmp105_read_raw,
	.driver_module		= THIS_MODULE,
};

/* ------------------------------------------------------------------ */
/* probe：全部 devm_*，remove 无需做事 */
/* ------------------------------------------------------------------ */

static int tmp105_probe(struct i2c_client *client,
			const struct i2c_device_id *id)
{
	struct iio_dev *indio_dev;
	struct tmp105_data *data;
	s32 conf;
	int ret;

	/*
	 * iio_dev 与私有数据一次分配（devm 自动释放），
	 * iio_priv() 取 iio_dev 之后的私有区
	 * （对照 hwmon 的 devm_kzalloc + 自己管结构体）。
	 */
	indio_dev = devm_iio_device_alloc(&client->dev, sizeof(*data));
	if (!indio_dev)
		return -ENOMEM;

	data = iio_priv(indio_dev);
	data->client = client;
	mutex_init(&data->lock);
	i2c_set_clientdata(client, indio_dev);

	/*
	 * 只读 CONFIG 打日志，失败不当 probe 失败（同 hwmon）：
	 * 设备树写了节点但器件没挂上时，真正的读错误会在
	 * 读 raw 时暴露为 -EREMOTEIO。
	 */
	conf = i2c_smbus_read_byte_data(client, TMP105_REG_CONF);
	if (conf >= 0)
		dev_dbg(&client->dev, "CONFIG=0x%02x (shutdown=%d, tm=%d)\n",
			conf, conf & 0x01, !!(conf & 0x02));

	indio_dev->name = IIO_DEVICE_NAME;
	indio_dev->modes = INDIO_DIRECT_MODE;
	indio_dev->channels = tmp105_channels;
	indio_dev->num_channels = ARRAY_SIZE(tmp105_channels);
	indio_dev->info = &tmp105_info;

	/*
	 * devm 注册：卸载时自动 iio_device_unregister
	 * （同 hwmon_tmp105 的 devm 注册，remove 留空）。
	 */
	ret = devm_iio_device_register(&client->dev, indio_dev);
	if (ret < 0)
		return ret;

	/* 日志带地址/总线名，是 verify_qemu.sh 的日志锚点 */
	dev_info(&client->dev, "tmp105 iio at 0x%02x on %s\n",
		 client->addr, client->adapter->name);

	return 0;
}

/* ------------------------------------------------------------------ */
/* 设备匹配：两套表（同 hwmon_tmp105 §5.6） */
/* ------------------------------------------------------------------ */

static const struct i2c_device_id tmp105_id[] = {
	{ "tmp105", 0 },
	{ }
};
MODULE_DEVICE_TABLE(i2c, tmp105_id);

static const struct of_device_id tmp105_of_match[] = {
	/* QEMU virt 生成的正是 ti,tmp105 */
	{ .compatible = "ti,tmp105" },
	{ .compatible = "national,lm75" },	/* LM75 兼容器件 */
	{ }
};
MODULE_DEVICE_TABLE(of, tmp105_of_match);

static struct i2c_driver tmp105_driver = {
	.driver = {
		.name		= DRIVER_NAME,
		.of_match_table	= tmp105_of_match,
	},
	.probe		= tmp105_probe,
	.id_table	= tmp105_id,
};
module_i2c_driver(tmp105_driver);

MODULE_AUTHOR("linux-kmods");
MODULE_DESCRIPTION("TI TMP105 / LM75 I2C temperature sensor (IIO)");
MODULE_LICENSE("GPL");
