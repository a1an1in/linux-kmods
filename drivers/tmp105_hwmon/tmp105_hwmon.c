// SPDX-License-Identifier: GPL-2.0
/*
 * tmp105_hwmon.c - TI TMP105 / LM75 兼容 I2C 温度传感器驱动（hwmon）
 *
 * 器件（QEMU hw/sensor/tmp105.c 同款，设计文档 §3）：
 *   指针寄存器 + 数据，标准 I2C 读写，从机地址 0x48：
 *     0x00 TEMPERATURE  16 bit  8.8 定点、12 位有效（有符号）
 *     0x01 CONFIG        8 bit  第一版只读不写
 *     0x02 T_LOW        16 bit  下限阈值（9 位，0.5 °C 步进）
 *     0x03 T_HIGH       16 bit  上限阈值（同上）
 *
 * 对外接口（hwmon，单位 m°C，设计文档 §5.5、§6）：
 *   .../name            -> "tmp105"
 *   .../temp1_input     -> 温度（m°C）
 *   .../temp1_max       -> T_HIGH（读写）
 *   .../temp1_min       -> T_LOW （读写）
 *   .../temp1_max_alarm -> 软件比较 temp >= T_HIGH
 *
 * 换算（对温度与阈值统一成立，设计文档 §3.2）：
 *   mC = (int32_t)(int16_t)raw * 1000 / 256
 *
 * 说明：4.9 内核没有 HWMON_CHANNEL_INFO() 宏，需手写结构体，
 *       参照树内 drivers/hwmon/tmp102.c（4.9 版）。
 */

#include <linux/err.h>
#include <linux/hwmon.h>
#include <linux/i2c.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/slab.h>

#define DRIVER_NAME		"tmp105_hwmon"

/* 寄存器指针（设计文档 §3.1） */
#define TMP105_REG_TEMP		0x00
#define TMP105_REG_CONF		0x01
#define TMP105_REG_T_LOW	0x02
#define TMP105_REG_T_HIGH	0x03

/* 8.8 定点：1 LSB = 1/256 °C */
#define TMP105_TEMP_SCALE_DIV	256
/* 阈值只有 9 位有效 → 0.5 °C 量化步进 */
#define TMP105_LIMIT_STEP_MC	500
#define TMP105_LIMIT_SHIFT	7

/* 器件量程（-55 ~ 125 °C），仅用于写阈值时钳位 */
#define TMP105_TEMP_MIN_MC	(-55000)
#define TMP105_TEMP_MAX_MC	125000

struct tmp105_data {
	struct i2c_client	*client;
	struct device		*hwmon_dev;
	struct mutex		lock;	/* 串行化寄存器访问 */
	int			resolution;	/* 扩展点：9~11 位时用 */
};

/* ------------------------------------------------------------------ */
/* 寄存器访问：唯一进临界区的地方（设计文档 §5.4） */
/* ------------------------------------------------------------------ */

/*
 * 没有 SMBus WORD 事务时的退化路径。
 *
 * 注意：不要用两次 read_byte_data(reg)/(reg + 1) 拼字节：
 * TMP105 不会在两次独立事务之间自动递增指针，
 * reg + 1 读到的是另一个寄存器。
 * 正确做法是一次 i2c_transfer 做"写指针 + 读 2 字节"的
 * 组合事务（线路时序同 SMBus read_word），高字节在前。
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
 * 读 16 位寄存器：TMP105 高字节在前，用 swapped 版本
 * （等价于 mainline lm75.c 的做法）。
 * 返回负值即 I2C 错误（如 -EREMOTEIO），直接向上传播。
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

static int tmp105_write_word(struct tmp105_data *data, u8 reg, s16 raw)
{
	struct i2c_client *client = data->client;
	int ret;

	mutex_lock(&data->lock);
	if (i2c_check_functionality(client->adapter,
				    I2C_FUNC_SMBUS_WORD_DATA)) {
		ret = i2c_smbus_write_word_swapped(client, reg, (u16)raw);
	} else {
		u8 buf[3] = { reg, (u8)(raw >> 8), (u8)raw };

		ret = i2c_master_send(client, buf, sizeof(buf));
		if (ret >= 0 && ret != sizeof(buf))
			ret = -EIO;
	}
	mutex_unlock(&data->lock);

	return ret;
}

/* 寄存器 → m°C（温度与阈值通用） */
static int tmp105_reg_to_mc(struct tmp105_data *data, u8 reg, long *mc)
{
	s16 raw;
	int ret;

	ret = tmp105_read_word(data, reg, &raw);
	if (ret < 0)
		return ret;

	/* 有符号 8.8 定点，与 QEMU qom-get 的换算一致 */
	*mc = (s32)raw * 1000 / TMP105_TEMP_SCALE_DIV;

	return 0;
}

/* m°C → 阈值：钳位到量程后按 0.5 °C 量化（§5.4） */
static int tmp105_write_limit(struct tmp105_data *data, u8 reg, long mc)
{
	long raw;

	mc = clamp_val(mc, TMP105_TEMP_MIN_MC, TMP105_TEMP_MAX_MC);
	raw = DIV_ROUND_CLOSEST(mc, TMP105_LIMIT_STEP_MC) << TMP105_LIMIT_SHIFT;

	return tmp105_write_word(data, reg, (s16)raw);
}

/* ------------------------------------------------------------------ */
/* hwmon 接口（with_info 风格，§5.5） */
/* ------------------------------------------------------------------ */

static umode_t tmp105_is_visible(const void *drvdata,
				 enum hwmon_sensor_types type,
				 u32 attr, int channel)
{
	if (type != hwmon_temp || channel != 0)
		return 0;

	switch (attr) {
	case hwmon_temp_input:
	case hwmon_temp_max_alarm:
		return 0444;
	case hwmon_temp_max:
	case hwmon_temp_min:
		return 0644;
	default:
		return 0;
	}
}

static int tmp105_read(struct device *dev, enum hwmon_sensor_types type,
		       u32 attr, int channel, long *val)
{
	struct tmp105_data *data = dev_get_drvdata(dev);
	long temp, limit;
	int ret;

	if (type != hwmon_temp)
		return -EINVAL;

	switch (attr) {
	case hwmon_temp_input:
		return tmp105_reg_to_mc(data, TMP105_REG_TEMP, val);
	case hwmon_temp_max:
		return tmp105_reg_to_mc(data, TMP105_REG_T_HIGH, val);
	case hwmon_temp_min:
		return tmp105_reg_to_mc(data, TMP105_REG_T_LOW, val);
	case hwmon_temp_max_alarm:
		/* 软件比较，不依赖 ALERT 引脚（§3.4） */
		ret = tmp105_reg_to_mc(data, TMP105_REG_TEMP, &temp);
		if (ret < 0)
			return ret;
		ret = tmp105_reg_to_mc(data, TMP105_REG_T_HIGH, &limit);
		if (ret < 0)
			return ret;
		*val = temp >= limit ? 1 : 0;
		return 0;
	default:
		return -EINVAL;
	}
}

static int tmp105_write(struct device *dev, enum hwmon_sensor_types type,
			u32 attr, int channel, long val)
{
	struct tmp105_data *data = dev_get_drvdata(dev);

	if (type != hwmon_temp)
		return -EINVAL;

	switch (attr) {
	case hwmon_temp_max:
		return tmp105_write_limit(data, TMP105_REG_T_HIGH, val);
	case hwmon_temp_min:
		return tmp105_write_limit(data, TMP105_REG_T_LOW, val);
	default:
		return -EINVAL;
	}
}

/*
 * 只暴露一路温度通道（temp1_*）；多通道器件
 * （如 emc1413）再往 tmp105_temp_config[] 里加一项，
 * 并在 read/write 里按 channel 分支。
 */
static const u32 tmp105_temp_config[] = {
	HWMON_T_INPUT | HWMON_T_MAX | HWMON_T_MIN | HWMON_T_MAX_ALARM,
	0,
};

static const struct hwmon_channel_info tmp105_temp = {
	.type = hwmon_temp,
	.config = tmp105_temp_config,
};

static const struct hwmon_channel_info *tmp105_info[] = {
	&tmp105_temp,
	NULL,
};

static const struct hwmon_ops tmp105_hwmon_ops = {
	.is_visible = tmp105_is_visible,
	.read = tmp105_read,
	.write = tmp105_write,
};

static const struct hwmon_chip_info tmp105_chip_info = {
	.ops = &tmp105_hwmon_ops,
	.info = tmp105_info,
};

/* ------------------------------------------------------------------ */
/* probe：全部 devm_*，remove 无需做事（§5.3） */
/* ------------------------------------------------------------------ */

static int tmp105_probe(struct i2c_client *client,
			const struct i2c_device_id *id)
{
	struct tmp105_data *data;
	s32 conf;

	data = devm_kzalloc(&client->dev, sizeof(*data), GFP_KERNEL);
	if (!data)
		return -ENOMEM;

	data->client = client;
	data->resolution = 12;		/* 器件默认 12 位（占位） */
	mutex_init(&data->lock);
	i2c_set_clientdata(client, data);

	/*
	 * 只读 CONFIG 打日志（第一版不写 CONFIG，见 §3.3）。
	 * 读失败不当成 probe 失败：有些适配器没有
	 * SMBus byte 事务；真正的链路错误会在读温度时
	 * 暴露为 -EREMOTEIO。
	 */
	conf = i2c_smbus_read_byte_data(client, TMP105_REG_CONF);
	if (conf >= 0)
		dev_dbg(&client->dev, "CONFIG=0x%02x (shutdown=%d, tm=%d)\n",
			conf, conf & 0x01, !!(conf & 0x02));

	data->hwmon_dev =
		devm_hwmon_device_register_with_info(&client->dev, "tmp105",
						     data, &tmp105_chip_info,
						     NULL);
	if (IS_ERR(data->hwmon_dev))
		return PTR_ERR(data->hwmon_dev);

	dev_info(&client->dev, "tmp105 at 0x%02x on %s\n",
		 client->addr, client->adapter->name);

	return 0;
}

/* ------------------------------------------------------------------ */
/* 设备匹配：两套表（§5.6） */
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
MODULE_DESCRIPTION("TI TMP105 / LM75 I2C temperature sensor (hwmon)");
MODULE_LICENSE("GPL");
