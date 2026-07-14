# mtk-pgpt-tool

MediaTek 设备 Primary GPT 分区表读写 + SP Flash Tool scatter 文件生成工具。

纯 shell 脚本，在已 root 的安卓设备上直接运行，无需额外依赖。

## 功能

| 命令 | 说明 |
|------|------|
| `read` | 从块设备提取完整的 Primary GPT（包含 MBR + GPT 头 + 分区表项 + 填充区） |
| `write` | 将修改后的 pgpt 文件写回块设备（写前校验 MBR 签名和 GPT 头） |
| `scatter` | 从 pgpt 生成 SP Flash Tool 可用的 `MTxxxx_Android_scatter.txt` |

## 兼容性

- 存储类型：UFS（4096B 扇区）/ eMMC（512B 扇区）自动识别
- 块设备：自动检测（UFS: `/dev/block/sdc`，eMMC: `/dev/block/mmcblk0`），可手动指定
- 平台名：scatter 模式自动从 `/proc/device-tree/compatible` 检测，也可手动指定
- Shell：兼容 Android mksh、busybox ash，不依赖 bash 特性

## 用法

```
sh dump_pgpt.sh read    [输出文件] [块设备]
sh dump_pgpt.sh write   <输入文件> [块设备]
sh dump_pgpt.sh scatter [MT平台名] [pgpt文件]
```

所有输出文件默认保存到脚本所在目录。

### 参数说明

| 参数 | 说明 |
|------|------|
| 输出文件 | 可选，默认 `脚本目录/pgpt.bin` |
| 输入文件 | write 模式必填，要写入设备的 pgpt 文件 |
| 块设备 | 可选，不指定则自动检测 |
| MT平台名 | 可选，如 `MT6893`、`MT6991`，不指定则自动检测 |
| pgpt文件 | scatter 模式可选，不指定则直接从块设备读取 |

## 示例

### 提取分区表

```sh
# 提取到脚本目录 (默认 pgpt.bin)
sh dump_pgpt.sh read

# 提取到指定路径
sh dump_pgpt.sh read /sdcard/pgpt.bin

# 指定块设备
sh dump_pgpt.sh read pgpt.bin /dev/block/sda
```

### 写回分区表

```sh
# 写入修改后的 pgpt
sh dump_pgpt.sh write pgpt_patched.bin

# 指定目标块设备
sh dump_pgpt.sh write pgpt_patched.bin /dev/block/sdc
```

写入前会校验 MBR 签名（55AA）和 GPT 头魔数（EFI PART），并要求手动确认。

### 生成 scatter 文件

```sh
# 直接从设备生成 (自动检测平台名和存储类型)
sh dump_pgpt.sh scatter

# 指定平台名
sh dump_pgpt.sh scatter MT6893

# 从已有的 pgpt 文件生成
sh dump_pgpt.sh scatter MT6991 pgpt.bin
```

生成的 scatter 文件可直接导入 SP Flash Tool 使用。

## 技术细节

### pgpt 大小计算

pgpt 大小 = 第一个 GPT 分区的起始字节偏移，而非固定的 GPT 结构大小。这确保读取和生成的 pgpt 覆盖完整区域（包含 GPT 表项后的对齐填充），与 SP Flash Tool 等工具的行为一致。

### scatter 文件内容

- **preloader**：合成条目（不在 GPT 中），region 根据存储类型设为 `EMMC_BOOT1_BOOT2` 或 `UFS_LU0`
- **pgpt**：合成条目，大小为第一个分区起始地址
- **其他分区**：从 GPT 分区表项解析，包含分区名、偏移、大小
- **operation_type** 自动映射：
  - `INVISIBLE`：pgpt、sgpt、para、misc、otp
  - `PROTECTED`：protect1/2、nvram、nvcfg、nvdata、persist、sec1、seccfg、efuse
  - `UPDATE`：其他所有分区

### 存储类型检测

优先根据块设备路径判断（`mmcblk` → eMMC，`sd[a-z]` → UFS），块设备不可用时根据 GPT 头位置推断扇区大小。

## 注意事项

- 需要 **root 权限**才能读写块设备
- 写入操作会直接修改磁盘分区表，**操作前请务必备份原始 pgpt**
- scatter 中的 preloader 大小为默认值（512KB），实际大小因机型而异
- 建议通过 `adb push` 将脚本传到设备后执行

## License

MIT
