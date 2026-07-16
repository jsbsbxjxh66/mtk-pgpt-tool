#!/system/bin/sh
# ============================================================
# Primary GPT 读写 + scatter 生成工具 (兼容 UFS / eMMC)
# 在安卓设备上以 root 权限运行
# 所有文件默认输出到脚本所在目录
# ============================================================
#
# 用法:
#   sh dump_pgpt.sh read      [输出文件] [块设备]
#   sh dump_pgpt.sh write     <输入文件> [块设备]
#   sh dump_pgpt.sh read-sgpt [输出文件] [块设备]
#   sh dump_pgpt.sh write-sgpt <输入文件> [块设备]
#   sh dump_pgpt.sh scatter   [MT平台名] [pgpt文件]
#
# 参数说明:
#   输出文件   可选, read 默认 pgpt.bin, read-sgpt 默认 sgpt.bin
#   输入文件   写入模式必填, 要写入设备的分区表文件
#   块设备     可选, 自动检测 (UFS: /dev/block/sdc, eMMC: /dev/block/mmcblk0)
#   MT平台名   可选, 如 MT6893, 自动从 /proc/device-tree 检测
#   pgpt文件   可选, 不指定则直接从块设备读取
#
# 示例:
#   sh dump_pgpt.sh read                          # 从设备提取 pgpt 到脚本目录
#   sh dump_pgpt.sh read /sdcard/pgpt.bin         # 提取到指定路径
#   sh dump_pgpt.sh write pgpt_patched.bin        # 将修改后的 pgpt 写回设备
#   sh dump_pgpt.sh read-sgpt                     # 从设备提取 sgpt 到脚本目录
#   sh dump_pgpt.sh read-sgpt /sdcard/sgpt.bin    # 提取到指定路径
#   sh dump_pgpt.sh write-sgpt sgpt_patched.bin   # 将修改后的 sgpt 写回设备
#   sh dump_pgpt.sh scatter                       # 直接从设备生成 scatter
#   sh dump_pgpt.sh scatter MT6991                # 指定平台名生成 scatter
#   sh dump_pgpt.sh scatter MT6991 pgpt.bin       # 从已有文件生成 scatter
#   sh dump_pgpt.sh pgpt.bin                      # 兼容旧用法, 等同 read pgpt.bin
# ============================================================

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

ACTION="$1"
case "$ACTION" in
    read|write|read-sgpt|write-sgpt|scatter) shift ;;
    *) ACTION="read" ;;
esac

detect_dev() {
    if [ -b /dev/block/sdc ]; then echo "/dev/block/sdc"
    elif [ -b /dev/block/mmcblk0 ]; then echo "/dev/block/mmcblk0"
    else return 1; fi
}

get_sector_size() {
    local bname ss_path
    bname=$(basename "$1")
    ss_path="/sys/block/$bname/queue/logical_block_size"
    if [ -f "$ss_path" ]; then cat "$ss_path"; else echo 512; fi
}

detect_gpt_sector() {
    local magic
    magic=$(dd if="$1" bs=1 skip=512 count=8 2>/dev/null)
    if [ "$magic" = "EFI PART" ]; then echo 512; return; fi
    magic=$(dd if="$1" bs=1 skip=4096 count=8 2>/dev/null)
    if [ "$magic" = "EFI PART" ]; then echo 4096; return; fi
    return 1
}

read_le32() {
    dd if="$1" bs=1 skip="$2" count=4 2>/dev/null | od -v -t x1 | awk '
    {for(i=1;i<=NF;i++){if(length($i)==2&&$i~/^[0-9a-fA-F][0-9a-fA-F]$/)G=G $i}}
    END{
        b0=substr(G,1,2);b1=substr(G,3,2);b2=substr(G,5,2);b3=substr(G,7,2)
        n=0;h=b3 b2 b1 b0
        for(i=1;i<=8;i++){c=substr(h,i,1);v=index("0123456789abcdef",tolower(c))-1;if(v<0)v=0;n=n*16+v}
        print n
    }'
}

read_le64() {
    dd if="$1" bs=1 skip="$2" count=8 2>/dev/null | od -v -t x1 | awk '
    {for(i=1;i<=NF;i++){if(length($i)==2&&$i~/^[0-9a-fA-F][0-9a-fA-F]$/)G=G $i}}
    END{
        b0=substr(G,1,2);b1=substr(G,3,2);b2=substr(G,5,2);b3=substr(G,7,2)
        b4=substr(G,9,2);b5=substr(G,11,2);b6=substr(G,13,2);b7=substr(G,15,2)
        lo=b3 b2 b1 b0; hi=b7 b6 b5 b4; n_lo=0; n_hi=0
        for(i=1;i<=8;i++){c=substr(lo,i,1);v=index("0123456789abcdef",tolower(c))-1;if(v<0)v=0;n_lo=n_lo*16+v}
        for(i=1;i<=8;i++){c=substr(hi,i,1);v=index("0123456789abcdef",tolower(c))-1;if(v<0)v=0;n_hi=n_hi*16+v}
        printf "%.0f\n", n_hi * 4294967296 + n_lo
    }'
}

read_first_part_lba() {
    read_le32 "$1" $(( 2 * $2 + 32 ))
}

# ===========================
#  READ
# ===========================
if [ "$ACTION" = "read" ]; then
    FILE="${1:-${SCRIPT_DIR}/pgpt.bin}"
    if [ -n "$2" ]; then DEV="$2"
    else DEV=$(detect_dev) || { echo "错误: 未找到块设备"; exit 1; }; fi
    [ ! -b "$DEV" ] && { echo "错误: $DEV 不存在"; exit 1; }

    SECTOR_SIZE=$(get_sector_size "$DEV")
    # 先探测: 读 GPT 头 + 分区表项
    PROBE_LBAS=$(( 2 + 16384 / SECTOR_SIZE ))
    dd if="$DEV" of="$FILE" bs="$SECTOR_SIZE" count="$PROBE_LBAS" 2>/dev/null || { echo "错误: 读取失败"; exit 1; }

    SRC_SECTOR=$(detect_gpt_sector "$FILE") || { echo "错误: 未找到 GPT 头"; exit 1; }
    FIRST_LBA=$(read_first_part_lba "$FILE" "$SRC_SECTOR")
    PGPT_BYTES=$(( FIRST_LBA * SRC_SECTOR ))

    # 如果解析失败则回退到 GPT 结构大小
    if [ "$PGPT_BYTES" -le 0 ] 2>/dev/null; then
        PGPT_BYTES=$(( PROBE_LBAS * SECTOR_SIZE ))
    fi

    # 如果 pgpt 比探测读的大, 重新读取完整大小
    PROBE_BYTES=$(( PROBE_LBAS * SECTOR_SIZE ))
    if [ "$PGPT_BYTES" -gt "$PROBE_BYTES" ]; then
        dd if="$DEV" of="$FILE" bs=512 count=$((PGPT_BYTES / 512)) 2>/dev/null || { echo "错误: 读取失败"; exit 1; }
    fi

    echo "已保存 $(wc -c < "$FILE")B 到 $FILE  (第一分区起始: $(printf '0x%X' $PGPT_BYTES))"

# ===========================
#  WRITE
# ===========================
elif [ "$ACTION" = "write" ]; then
    FILE="${1:-${SCRIPT_DIR}/pgpt.bin}"
    if [ -n "$2" ]; then DEV="$2"
    else DEV=$(detect_dev) || { echo "错误: 未找到块设备"; exit 1; }; fi
    [ ! -f "$FILE" ] && { echo "错误: $FILE 不存在"; exit 1; }
    [ ! -b "$DEV" ] && { echo "错误: $DEV 不存在"; exit 1; }

    FILE_SIZE=$(wc -c < "$FILE")

    MBR_SIG=$(dd if="$FILE" bs=1 skip=510 count=2 2>/dev/null | od -A n -t x1 | tr -d ' \t\r\n')
    [ "$MBR_SIG" != "55aa" ] && { echo "错误: MBR 签名无效 ($MBR_SIG)"; exit 1; }

    SRC_SECTOR=$(detect_gpt_sector "$FILE") || { echo "错误: 未找到 GPT 头"; exit 1; }
    FIRST_LBA=$(read_first_part_lba "$FILE" "$SRC_SECTOR")
    PGPT_BYTES=$(( FIRST_LBA * SRC_SECTOR ))

    # 写入大小: 取文件大小和 pgpt 实际大小的较小值
    WRITE_BYTES=$FILE_SIZE
    if [ "$PGPT_BYTES" -gt 0 ] 2>/dev/null && [ "$PGPT_BYTES" -lt "$FILE_SIZE" ]; then
        WRITE_BYTES=$PGPT_BYTES
    fi

    echo "写入 $DEV  文件: ${FILE_SIZE}B  pgpt: $(printf '0x%X' $PGPT_BYTES)  写入: ${WRITE_BYTES}B"
    printf "确认? (y/N) "
    read CONFIRM
    case "$CONFIRM" in
        y|Y)
            dd if="$FILE" of="$DEV" bs=512 count=$(( (WRITE_BYTES + 511) / 512 )) 2>/dev/null || { echo "错误: 写入失败"; exit 1; }
            echo "已写入 ${WRITE_BYTES}B"; sync ;;
        *) echo "已取消"; exit 0 ;;
    esac

# ===========================
#  READ-SGPT
# ===========================
elif [ "$ACTION" = "read-sgpt" ]; then
    FILE="${1:-${SCRIPT_DIR}/sgpt.bin}"
    if [ -n "$2" ]; then DEV="$2"
    else DEV=$(detect_dev) || { echo "错误: 未找到块设备"; exit 1; }; fi
    [ ! -b "$DEV" ] && { echo "错误: $DEV 不存在"; exit 1; }

    SECTOR_SIZE=$(get_sector_size "$DEV")
    PROBE_LBAS=$(( 2 + 16384 / SECTOR_SIZE ))
    PGPT_TMP="${SCRIPT_DIR}/_pgpt_probe.bin"
    dd if="$DEV" of="$PGPT_TMP" bs="$SECTOR_SIZE" count="$PROBE_LBAS" 2>/dev/null || { rm -f "$PGPT_TMP"; echo "错误: 读取 PGPT 失败"; exit 1; }

    SRC_SECTOR=$(detect_gpt_sector "$PGPT_TMP") || { rm -f "$PGPT_TMP"; echo "错误: 未找到 GPT 头"; exit 1; }
    HDR_OFF=$SRC_SECTOR
    ALT_LBA=$(read_le64 "$PGPT_TMP" $(( HDR_OFF + 32 )))
    NUM_ENTRIES=$(read_le32 "$PGPT_TMP" $(( HDR_OFF + 80 )))
    ENTRY_SIZE=$(read_le32 "$PGPT_TMP" $(( HDR_OFF + 84 )))
    rm -f "$PGPT_TMP"

    if [ -z "$ALT_LBA" ] || [ "$ALT_LBA" = "0" ]; then
        echo "错误: 无法从 PGPT 获取备份 GPT 位置 (alt_lba)"; exit 1
    fi

    ENTRIES_BYTES=$(( NUM_ENTRIES * ENTRY_SIZE ))
    ENTRIES_LBAS=$(( (ENTRIES_BYTES + SRC_SECTOR - 1) / SRC_SECTOR ))
    SGPT_START_LBA=$(( ALT_LBA - ENTRIES_LBAS ))
    SGPT_LBAS=$(( ENTRIES_LBAS + 1 ))

    echo "备份 GPT 头 LBA: $ALT_LBA  分区条目: ${NUM_ENTRIES} × ${ENTRY_SIZE}B"
    echo "SGPT 区域: LBA ${SGPT_START_LBA} - ${ALT_LBA} (${SGPT_LBAS} 扇区, $(( SGPT_LBAS * SRC_SECTOR ))B)"

    dd if="$DEV" of="$FILE" bs="$SRC_SECTOR" skip="$SGPT_START_LBA" count="$SGPT_LBAS" 2>/dev/null || { echo "错误: 读取 SGPT 失败"; exit 1; }

    SGPT_HDR_OFF=$(( (SGPT_LBAS - 1) * SRC_SECTOR ))
    SGPT_SIG=$(dd if="$FILE" bs=1 skip="$SGPT_HDR_OFF" count=8 2>/dev/null)
    if [ "$SGPT_SIG" != "EFI PART" ]; then
        echo "警告: SGPT 文件末尾无 GPT 头签名，数据可能不完整"
    fi

    echo "已保存 $(wc -c < "$FILE")B 到 $FILE"

# ===========================
#  WRITE-SGPT
# ===========================
elif [ "$ACTION" = "write-sgpt" ]; then
    FILE="${1:-${SCRIPT_DIR}/sgpt.bin}"
    if [ -n "$2" ]; then DEV="$2"
    else DEV=$(detect_dev) || { echo "错误: 未找到块设备"; exit 1; }; fi
    [ ! -f "$FILE" ] && { echo "错误: $FILE 不存在"; exit 1; }
    [ ! -b "$DEV" ] && { echo "错误: $DEV 不存在"; exit 1; }

    SECTOR_SIZE=$(get_sector_size "$DEV")
    PROBE_LBAS=$(( 2 + 16384 / SECTOR_SIZE ))
    PGPT_TMP="${SCRIPT_DIR}/_pgpt_probe.bin"
    dd if="$DEV" of="$PGPT_TMP" bs="$SECTOR_SIZE" count="$PROBE_LBAS" 2>/dev/null || { rm -f "$PGPT_TMP"; echo "错误: 读取 PGPT 失败"; exit 1; }

    SRC_SECTOR=$(detect_gpt_sector "$PGPT_TMP") || { rm -f "$PGPT_TMP"; echo "错误: 未找到 GPT 头"; exit 1; }
    HDR_OFF=$SRC_SECTOR
    ALT_LBA=$(read_le64 "$PGPT_TMP" $(( HDR_OFF + 32 )))
    NUM_ENTRIES=$(read_le32 "$PGPT_TMP" $(( HDR_OFF + 80 )))
    ENTRY_SIZE=$(read_le32 "$PGPT_TMP" $(( HDR_OFF + 84 )))
    rm -f "$PGPT_TMP"

    if [ -z "$ALT_LBA" ] || [ "$ALT_LBA" = "0" ]; then
        echo "错误: 无法从 PGPT 获取备份 GPT 位置 (alt_lba)"; exit 1
    fi

    ENTRIES_BYTES=$(( NUM_ENTRIES * ENTRY_SIZE ))
    ENTRIES_LBAS=$(( (ENTRIES_BYTES + SRC_SECTOR - 1) / SRC_SECTOR ))
    SGPT_START_LBA=$(( ALT_LBA - ENTRIES_LBAS ))
    SGPT_LBAS=$(( ENTRIES_LBAS + 1 ))
    EXPECTED_SIZE=$(( SGPT_LBAS * SRC_SECTOR ))

    FILE_SIZE=$(wc -c < "$FILE")

    SGPT_HDR_OFF=$(( FILE_SIZE - SRC_SECTOR ))
    if [ "$SGPT_HDR_OFF" -lt 0 ]; then
        echo "错误: SGPT 文件太小"; exit 1
    fi
    SGPT_SIG=$(dd if="$FILE" bs=1 skip="$SGPT_HDR_OFF" count=8 2>/dev/null)
    [ "$SGPT_SIG" != "EFI PART" ] && { echo "错误: SGPT 文件末尾无 GPT 头签名 (EFI PART)"; exit 1; }

    if [ "$FILE_SIZE" -ne "$EXPECTED_SIZE" ]; then
        echo "警告: 文件大小 (${FILE_SIZE}B) 与预期 (${EXPECTED_SIZE}B) 不一致"
        SGPT_LBAS=$(( FILE_SIZE / SRC_SECTOR ))
        SGPT_START_LBA=$(( ALT_LBA - SGPT_LBAS + 1 ))
    fi

    echo "写入 $DEV  文件: ${FILE_SIZE}B  SGPT 区域: LBA ${SGPT_START_LBA}-${ALT_LBA} (${SGPT_LBAS} 扇区)"
    printf "确认? (y/N) "
    read CONFIRM
    case "$CONFIRM" in
        y|Y)
            dd if="$FILE" of="$DEV" bs="$SRC_SECTOR" seek="$SGPT_START_LBA" count="$SGPT_LBAS" 2>/dev/null || { echo "错误: 写入失败"; exit 1; }
            echo "已写入 ${FILE_SIZE}B"; sync ;;
        *) echo "已取消"; exit 0 ;;
    esac

# ===========================
#  SCATTER
# ===========================
elif [ "$ACTION" = "scatter" ]; then
    PLATFORM=""
    PGPT_FILE=""
    CLEANUP_TMP=0

    for arg in "$@"; do
        if echo "$arg" | grep -qiE '^mt[0-9]+$'; then
            PLATFORM=$(echo "$arg" | tr 'a-z' 'A-Z')
        elif [ -f "$arg" ]; then
            PGPT_FILE="$arg"
        fi
    done

    if [ -z "$PLATFORM" ] && [ -f /proc/device-tree/compatible ]; then
        PLATFORM=$(tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null | grep -ioE 'mt[0-9]+' | head -1 | tr 'a-z' 'A-Z')
    fi
    [ -z "$PLATFORM" ] && PLATFORM="MTK"

    if [ -z "$PGPT_FILE" ]; then
        DEV=$(detect_dev) || { echo "错误: 未找到块设备，请指定 pgpt 文件"; exit 1; }
        SECTOR_SIZE=$(get_sector_size "$DEV")
        TOTAL_LBAS=$(( 2 + 16384 / SECTOR_SIZE ))
        PGPT_FILE="${SCRIPT_DIR}/_pgpt_tmp.bin"
        echo "从 $DEV 读取 GPT..."
        dd if="$DEV" of="$PGPT_FILE" bs="$SECTOR_SIZE" count="$TOTAL_LBAS" 2>/dev/null || { echo "错误: 读取失败"; exit 1; }
        CLEANUP_TMP=1
    fi

    SRC_SECTOR=$(detect_gpt_sector "$PGPT_FILE") || { echo "错误: 未找到 GPT 头"; exit 1; }

    # 存储类型检测: 优先看块设备路径, 扇区大小做备选
    STOR_TYPE=""
    if [ -n "$DEV" ]; then
        case "$DEV" in
            *mmcblk*) STOR_TYPE="EMMC" ;;
            *sd[a-z]) STOR_TYPE="UFS" ;;
        esac
    fi
    if [ -z "$STOR_TYPE" ]; then
        if [ "$SRC_SECTOR" = "4096" ]; then STOR_TYPE="UFS"
        else STOR_TYPE="EMMC"; fi
    fi

    if [ "$STOR_TYPE" = "UFS" ]; then
        STORAGE="HW_STORAGE_UFS"; REGION="UFS_LU2"; BOOT_CH="UFS_0"
    else
        STORAGE="HW_STORAGE_EMMC"; REGION="EMMC_USER"; BOOT_CH="MSDC_0"
    fi

    SCATTER="${SCRIPT_DIR}/${PLATFORM}_Android_scatter.txt"
    echo "平台: $PLATFORM  存储: $STOR_TYPE  扇区: ${SRC_SECTOR}B  输出: $SCATTER"

    od -v -t x1 < "$PGPT_FILE" | awk \
        -v src_sector="$SRC_SECTOR" \
        -v platform="$PLATFORM" \
        -v storage="$STORAGE" \
        -v region="$REGION" \
        -v boot_ch="$BOOT_CH" \
        -v stor_type="$STOR_TYPE" \
    '
    function hex2dec(s,   n,i,c,v) {
        n=0
        for(i=1;i<=length(s);i++){
            c=tolower(substr(s,i,1))
            v=index("0123456789abcdef",c)-1
            if(v<0) v=0
            n=n*16+v
        }
        return n
    }
    function le32(pos,   b0,b1,b2,b3) {
        b0=substr(G,pos,2); b1=substr(G,pos+2,2)
        b2=substr(G,pos+4,2); b3=substr(G,pos+6,2)
        return hex2dec(b3 b2 b1 b0)
    }
    function le64(pos,   lo,hi) {
        lo=le32(pos); hi=le32(pos+8)
        return hi*4294967296+lo
    }
    function uname16(pos,   s,j,lo,hi) {
        s=""
        for(j=0;j<36;j++){
            lo=substr(G,pos+j*4,2)
            hi=substr(G,pos+j*4+2,2)
            if(lo=="00"&&hi=="00") break
            s=s sprintf("%c",hex2dec(lo))
        }
        return s
    }
    function to_hex(val,   r,d,digits) {
        if(val==0) return "0x0"
        r=""; digits="0123456789ABCDEF"
        while(val>0.5){
            d=int(val%16)
            r=substr(digits,d+1,1) r
            val=int(val/16)
        }
        return "0x" r
    }
    function optype(name) {
        if(name~/^(pgpt|sgpt|para|misc|otp)$/) return "INVISIBLE"
        if(name~/^(protect[12_]|nvram|nvcfg|nvdata|persist|sec1|seccfg|efuse)/) return "PROTECTED"
        return "UPDATE"
    }
    function upgradable(op) {
        if(op=="UPDATE") return "true"
        return "false"
    }
    function emit(idx,name,fname,dl,typ,addr,size,rgn,op) {
        print ""
        print "  - partition_index: SYS" idx
        print "    partition_name: " name
        print "    file_name: " fname
        print "    is_download: " dl
        print "    type: " typ
        print "    linear_start_addr: " to_hex(addr)
        print "    physical_start_addr: " to_hex(addr)
        print "    partition_size: " to_hex(size)
        print "    region: " rgn
        print "    storage: " storage
        print "    boundary_check: true"
        print "    is_reserved: false"
        print "    operation_type: " op
        print "    is_upgradable: " upgradable(op)
        print "    empty_boot_needed: false"
        print "    reserve: 0x0"
    }

    {for(i=1;i<=NF;i++){if(length($i)==2&&$i~/^[0-9a-fA-F][0-9a-fA-F]$/)G=G $i}}

    END {
        h=src_sector*2+1
        alt_lba=le64(h+64)
        first_lba=le64(h+80)
        last_lba=le64(h+96)
        num_ent=le32(h+160)
        ent_size=le32(h+168)
        e_base=src_sector*4+1

        print "############################################################################################################"
        print "#"
        print "#  General Setting"
        print "#"
        print "############################################################################################################"
        print "- general: MTK_PLATFORM_CFG"
        print "  info:"
        print "  - config_version: V2.1.0"
        print "    platform: " platform
        print "    project: " platform "_generic"
        print "############################################################################################################"
        print "#"
        print "#  " stor_type " Layout Setting"
        print "#"
        print "############################################################################################################"
        print "- storage_type: " stor_type
        print "  description:"
        print "  - general: MTK_STORAGE_CFG"
        print "    info:"
        print "    - storage: " stor_type
        print "      boot_channel: " boot_ch
        print "      block_size: 0x200000"

        # preloader (不在 GPT 中, 合成条目)
        if(stor_type=="EMMC")
            boot_rgn="EMMC_BOOT1_BOOT2"
        else
            boot_rgn="UFS_LU0"
        emit(0,"preloader","preloader_" platform ".bin","true","SV5_BL_BIN",0,524288,boot_rgn,"BOOTLOADERS")

        # pgpt 大小 = 第一个分区的起始地址
        first_part_lba=le64(e_base+64)
        pgpt_bytes=first_part_lba*src_sector
        emit(1,"pgpt","pgpt.bin","false","NORMAL_ROM",0,pgpt_bytes,region,"INVISIBLE")

        idx=2
        for(i=0;i<num_ent;i++){
            ep=e_base+i*ent_size*2
            empty=1
            for(j=0;j<32;j++){
                if(substr(G,ep+j,1)!="0"){empty=0;break}
            }
            if(empty) break

            name=uname16(ep+112)
            s_lba=le64(ep+64)
            e_lba=le64(ep+80)
            boff=s_lba*src_sector
            psz=(e_lba-s_lba+1)*src_sector
            op=optype(name)
            dl="true"; if(op=="INVISIBLE"||op=="PROTECTED") dl="false"
            emit(idx,name,name ".img",dl,"NORMAL_ROM",boff,psz,region,op)
            idx++
        }

        printf "%d",idx-2 > "/dev/stderr"
    }
    ' > "$SCATTER" 2>${SCRIPT_DIR}/_scatter_count

    COUNT=$(cat ${SCRIPT_DIR}/_scatter_count 2>/dev/null)
    rm -f ${SCRIPT_DIR}/_scatter_count
    [ "$CLEANUP_TMP" = "1" ] && rm -f "$PGPT_FILE"
    echo "已生成 $SCATTER ($COUNT 个分区 + pgpt)"
fi
