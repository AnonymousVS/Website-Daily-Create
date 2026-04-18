#!/bin/bash
# ============================================================================
# website-daily-create.sh — Bulk WordPress Site Creation Pipeline
# Version: 2.5.5
# Updated: 2026-04-18 19:45 (UTC+7)
# Location: /usr/local/sbin/website-daily-create.sh
# Usage: website-daily-create.sh /path/to/sites.csv
# ============================================================================
# CSV Format: domain,theme
# Example:    a1.com,theme-black.store
# ============================================================================
# CHANGELOG:
# v2.5.5 (2026-04-18)
#   - QUIC.cloud link ย้ายจาก Step 6.5 → Step 10 หลัง loop จบ
#   - Step 6.5 ทำแค่ init (anonymous mode — ไม่มี rate limit)
#   - Step 10: delay 30s + countdown นับถอยหลัง + auto retry 3 ครั้ง
#   - ตรวจจับ cooldown อัตโนมัติ ("3m 24s" → 209s)
#   - Process substitution ป้องกัน subshell
# v2.5.4 (2026-04-18)
#   - SUBDOMAIN_PREFIX ใช้ชื่อ domain เต็ม (เหมือน cPanel GUI)
#   - แก้ error detection: เช็ค subdomain ก่อน already exists
# v2.5.3 (2026-04-04)
#   - Production: activate theme สุดท้าย (Step 9)
#   - เปิด 6.2 ลบ default themes + ลบ debug code (_ct)
# v2.5.0 (2026-04-04)
#   - ย้าย activate theme หลัง cleanup
#   - TRUNCATE litespeed_avatar ป้องกัน Duplicate entry
# v2.4.0 (2026-04-03)
#   - แยก 3 ไฟล์: script + server-config.conf + CSV 2 columns
#   - ลบ credentials ออกจาก script ทั้งหมด
# v2.3.0 (2026-04-03)
#   - Font CSS auto-detect old domain → sed replace
#   - Rank Math delete 2 options + update_option
#   - wp eval flush_rewrite_rules ($GLOBALS["is_apache"]=true)
# v2.0.0 (2026-04-02)
#   - Copy method แทน symlink
#   - Suppress PHP Deprecated warnings (-d error_reporting flag)
#   - Fix CF Zone ID (wp eval update_option แทน litespeed-option set)
#   - $PHP_CLI ห้าม quote (มี flag ต่อท้าย ต้อง word-split)
# ============================================================================

set -o pipefail

VERSION="2.5.5"

# ========================== CONFIG ==========================================
# --- Paths ---
TEMPLATE_DIR="/usr/local/share/ai1wm-templates"  # .wpress template files
LOG_DIR="/var/log/website-daily-create"
WP_CLI="/usr/local/bin/wp"

# --- Limits ---
DISK_MIN_START_GB=30           # Pre-flight: disk ต้องมีอย่างน้อย (GB)
DISK_MIN_RUNTIME_GB=5          # ระหว่างรัน: ถ้าต่ำกว่านี้หยุดทันที
WAIT_CPANEL_MAX=30             # รอ cPanel register สูงสุด (วินาที)
TIMEOUT_WPTOOLKIT=120          # timeout WP Toolkit install (วินาที)
TIMEOUT_RESTORE=600            # timeout AI1WM restore (วินาที)

# --- Active Theme (theme ที่ .wpress template ใช้) ---
ACTIVE_THEME="blocksy-child"

# --- Server Config (credentials อ่านจากไฟล์แยก) ---
# ค้นหา server-config.conf ตามลำดับ:
#   1. อยู่ข้างๆ CSV file ที่ส่งมา
#   2. /usr/local/etc/website-daily-create/server-config.conf
#   3. ถ้าไม่เจอ → หยุดทันที
# ============================================================================

# ========================== COLORS ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
# ============================================================================

# ========================== GLOBALS =========================================
CSV_FILE=""
PHP_BIN=""      # PHP binary path เปล่าๆ (ใช้ตรวจ version)
PHP_CLI=""      # PHP_BIN + suppress flag (ห้าม quote ตอนใช้)
VISION_SET_ID=""
LOG_FILE=""
DATE_TAG=$(date '+%Y-%m-%d')
COUNT_SUCCESS=0
COUNT_SKIP=0
COUNT_FAIL=0
COUNT_TOTAL=0
START_TIME=$(date +%s)
SUMMARY_SUCCESS=""
SUMMARY_SKIP=""
SUMMARY_FAIL=""
SUMMARY_WARN=""
LINK_DOMAINS=""   # เก็บ domain ที่ต้อง QUIC.cloud link หลัง loop จบ
LINK_SUCCESS=0
LINK_FAIL=0
LINK_TOTAL=0
# ============================================================================

# ========================== FUNCTIONS =======================================

log_info()  { echo -e "${GREEN}[✅]${NC} $1"; echo "[$(date '+%H:%M:%S')] [OK] $1" >> "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[⚠️]${NC} $1"; echo "[$(date '+%H:%M:%S')] [WARN] $1" >> "$LOG_FILE"; }
log_error() { echo -e "${RED}[❌]${NC} $1"; echo "[$(date '+%H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"; }
log_step()  { echo -e "${CYAN}[→]${NC} $1"; echo "[$(date '+%H:%M:%S')] [STEP] $1" >> "$LOG_FILE"; }

# Spinner — ใช้ระหว่างรอ command ที่ใช้เวลานาน
SPINNER_PID=""
start_spinner() {
    local MSG="$1"
    local SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    (
        local i=0
        while true; do
            printf "\r  ${CYAN}%s${NC} %s" "${SPIN:i++%${#SPIN}:1}" "$MSG"
            sleep 0.2
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
        printf "\r\033[K"
    fi
}

send_telegram() {
    local MSG="$1"
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d parse_mode="HTML" \
            -d text="$MSG" > /dev/null 2>&1
    fi
}

# หา PHP CLI อัตโนมัติ (sync กับ WHM default, fallback รองลงมา 1 ตัว)
find_php_cli() {
    local CLI
    # ดึง default PHP จาก WHM MultiPHP Manager
    local DEFAULT_PHP
    DEFAULT_PHP=$(whmapi1 php_get_system_default_version 2>/dev/null | grep -o 'ea-php[0-9]*')
    if [ -n "$DEFAULT_PHP" ] && [ -f "/opt/cpanel/${DEFAULT_PHP}/root/usr/bin/php" ]; then
        CLI="/opt/cpanel/${DEFAULT_PHP}/root/usr/bin/php"
    else
        # fallback: ใช้รองลงมา 1 ตัว (ไม่ใช่ตัวใหม่สุด เพื่อหลีกเลี่ยงปัญหา compatibility)
        CLI=$(ls -d /opt/cpanel/ea-php*/root/usr/bin/php 2>/dev/null | sort -V | tail -2 | head -1)
    fi
    if [ -z "$CLI" ]; then
        return 1
    fi
    if "$CLI" -r "echo php_sapi_name();" 2>/dev/null | grep -q "cli"; then
        echo "$CLI"
        return 0
    fi
    return 1
}

# หา Vision Set ID จากชื่อ "Vision Set" อัตโนมัติ
find_vision_set_id() {
    local ID
    ID=$(wp-toolkit --sets -operation list -format json 2>/dev/null \
        | grep -o '"id":[0-9]*,"name":"Vision Set"' \
        | grep -o '"id":[0-9]*' \
        | grep -o '[0-9]*')
    echo "$ID"
}

# แปลงชื่อ default theme เป็นตัวเลข (รองรับถึงปี 2050)
theme_to_num() {
    case "$1" in
        twentytwentyone)    echo 21;;
        twentytwentytwo)    echo 22;;
        twentytwentythree)  echo 23;;
        twentytwentyfour)   echo 24;;
        twentytwentyfive)   echo 25;;
        twentytwentysix)    echo 26;;
        twentytwentyseven)  echo 27;;
        twentytwentyeight)  echo 28;;
        twentytwentynine)   echo 29;;
        twentythirty)       echo 30;;
        twentythirtyone)    echo 31;;
        twentythirtytwo)    echo 32;;
        twentythirtythree)  echo 33;;
        twentythirtyfour)   echo 34;;
        twentythirtyfive)   echo 35;;
        twentythirtysix)    echo 36;;
        twentythirtyseven)  echo 37;;
        twentythirtyeight)  echo 38;;
        twentythirtynine)   echo 39;;
        twentyforty)        echo 40;;
        twentyfortyone)     echo 41;;
        twentyfortytwo)     echo 42;;
        twentyfortythree)   echo 43;;
        twentyfortyfour)    echo 44;;
        twentyfortyfive)    echo 45;;
        twentyfortysix)     echo 46;;
        twentyfortyseven)   echo 47;;
        twentyfortyeight)   echo 48;;
        twentyfortynine)    echo 49;;
        twentyfifty)        echo 50;;
        *) echo 0;;
    esac
}

# ดู disk free เป็น GB
get_disk_free_gb() {
    df -BG /home | awk 'NR==2 {gsub(/G/,"",$4); print $4}'
}

# ========================== PRE-FLIGHT CHECK ================================

preflight_check() {
    echo ""
    echo "========================================"
    echo "  Website Daily Create v${VERSION}"
    echo "  Pre-flight Check"
    echo "========================================"
    echo ""

    local ERRORS=0

    # 1. CSV file
    log_step "1. ตรวจสอบ CSV file..."
    if [ ! -f "$CSV_FILE" ]; then
        log_error "CSV file not found: $CSV_FILE"
        return 1
    fi
    if [ ! -s "$CSV_FILE" ]; then
        log_error "CSV file is empty: $CSV_FILE"
        return 1
    fi
    local BAD_LINES
    BAD_LINES=$(grep '[^[:space:]]' "$CSV_FILE" | tail -n +2 | awk -F',' 'NF!=2 && NF!=0 {print NR+1": "$0}')
    if [ -n "$BAD_LINES" ]; then
        log_error "CSV format ผิด (ต้องมี 2 columns: domain,theme):"
        echo "$BAD_LINES"
        return 1
    fi
    local DUP_DOMAINS
    DUP_DOMAINS=$(grep '[^[:space:]]' "$CSV_FILE" | tail -n +2 | cut -d',' -f1 | sort | uniq -d)
    if [ -n "$DUP_DOMAINS" ]; then
        log_error "CSV มี domain ซ้ำ:"
        echo "$DUP_DOMAINS"
        return 1
    fi
    COUNT_TOTAL=$(grep '[^[:space:]]' "$CSV_FILE" | tail -n +2 | grep -c '[^[:space:]]')
    log_info "CSV OK — $COUNT_TOTAL domains"

    # 2. Commands
    log_step "2. ตรวจสอบ commands..."
    for CMD in cpapi2 wp-toolkit; do
        if ! command -v "$CMD" &>/dev/null; then
            log_error "$CMD not found"
            ERRORS=$((ERRORS+1))
        fi
    done
    if [ ! -f "$WP_CLI" ]; then
        log_error "WP-CLI not found: $WP_CLI"
        ERRORS=$((ERRORS+1))
    fi
    [ $ERRORS -gt 0 ] && return 1
    log_info "Commands OK"

    # 3. PHP CLI (หา binary + เพิ่ม suppress flag)
    log_step "3. ตรวจสอบ PHP CLI..."
    PHP_BIN=$(find_php_cli)
    if [ -z "$PHP_BIN" ]; then
        log_error "ไม่พบ PHP CLI ที่ใช้ได้"
        return 1
    fi
    local PHP_VER
    PHP_VER=$("$PHP_BIN" -r "echo PHP_VERSION;" 2>/dev/null)
    # เพิ่ม flag suppress Deprecated warning จาก WP Toolkit bundled WP-CLI
    PHP_CLI="$PHP_BIN -d error_reporting=E_ALL&~E_DEPRECATED"
    log_info "PHP CLI: $PHP_BIN (v$PHP_VER) + suppress deprecated"

    # 4. Vision Set
    log_step "4. ตรวจสอบ Vision Set..."
    VISION_SET_ID=$(find_vision_set_id)
    if [ -z "$VISION_SET_ID" ]; then
        log_error "ไม่เจอ Vision Set บน server นี้"
        return 1
    fi
    log_info "Vision Set ID = $VISION_SET_ID"

    # 5. Disk space
    log_step "5. ตรวจสอบ Disk space..."
    local DISK_FREE
    DISK_FREE=$(get_disk_free_gb)
    if [ "$DISK_FREE" -lt "$DISK_MIN_START_GB" ]; then
        log_error "Disk free ${DISK_FREE}GB < ${DISK_MIN_START_GB}GB"
        return 1
    fi
    log_info "Disk free: ${DISK_FREE}GB"

    # 6. cPanel user
    log_step "6. ตรวจสอบ cPanel user..."
    if [ ! -f "/var/cpanel/users/$CPANEL_USER" ]; then
        log_error "cPanel user ไม่มี: $CPANEL_USER"
        return 1
    fi
    log_info "cPanel user OK: $CPANEL_USER"

    # 7. .wpress templates
    log_step "7. ตรวจสอบ .wpress templates..."
    if [ ! -d "$TEMPLATE_DIR" ]; then
        log_error "Template directory ไม่มี: $TEMPLATE_DIR"
        return 1
    fi
    local MISSING_TEMPLATES=""
    while IFS=',' read -r DOMAIN THEME; do
        if [ ! -f "${TEMPLATE_DIR}/${THEME}.wpress" ]; then
            MISSING_TEMPLATES="$MISSING_TEMPLATES ${THEME}.wpress"
        fi
    done < <(grep '[^[:space:]]' "$CSV_FILE" | tail -n +2)
    if [ -n "$MISSING_TEMPLATES" ]; then
        log_error "Templates ไม่มี:$MISSING_TEMPLATES"
        return 1
    fi
    log_info "Templates OK"

    # 8. QUIC.cloud credentials
    log_step "8. ตรวจสอบ QUIC.cloud credentials..."
    if [ -n "$QC_CF_EMAIL" ] && [ -n "$QC_TOKEN" ]; then
        log_info "QUIC.cloud credentials OK ($QC_CF_EMAIL)"
    elif [ -n "$QC_CF_EMAIL" ] && [ -z "$QC_TOKEN" ]; then
        log_warn "QUIC.cloud token ว่าง สำหรับ $QC_CF_EMAIL (จะข้าม link)"
    else
        log_warn "QUIC.cloud email ไม่ได้ตั้ง (จะข้าม)"
    fi

    # 9. Telegram
    log_step "9. ตรวจสอบ Telegram..."
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        log_warn "Telegram bot token ไม่ได้ตั้ง"
    else
        local TG_RESULT
        TG_RESULT=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null | grep -c '"ok":true')
        if [ "$TG_RESULT" -eq 0 ]; then
            log_warn "Telegram bot ใช้ไม่ได้"
        else
            log_info "Telegram OK"
        fi
    fi

    # 10. Domains ที่มีอยู่แล้ว
    log_step "10. ตรวจสอบ domains ที่มีอยู่แล้ว..."
    local EXISTING_DOMAINS=""
    local EXISTING_COUNT=0
    while IFS=',' read -r DOMAIN THEME; do
        if grep -q "^${DOMAIN}:" /etc/userdatadomains 2>/dev/null; then
            EXISTING_DOMAINS="$EXISTING_DOMAINS  - $DOMAIN\n"
            EXISTING_COUNT=$((EXISTING_COUNT+1))
        fi
    done < <(grep '[^[:space:]]' "$CSV_FILE" | tail -n +2)
    if [ $EXISTING_COUNT -gt 0 ]; then
        log_warn "Domains ที่มีอยู่แล้ว ($EXISTING_COUNT เว็บ — ข้าม Step 1-2 ไป Step 3):"
        echo -e "$EXISTING_DOMAINS"
    fi

    # สรุป
    echo ""
    echo "========================================"
    local READY_COUNT=$((COUNT_TOTAL - EXISTING_COUNT))
    echo -e "  ${GREEN}✅ สร้างใหม่: $READY_COUNT เว็บ${NC}"
    if [ $EXISTING_COUNT -gt 0 ]; then
        echo -e "  ${YELLOW}⚠️ มีอยู่แล้ว (ข้าม Step 1-2): $EXISTING_COUNT เว็บ${NC}"
    fi
    echo "  Server: $(hostname)"
    echo "  PHP: $PHP_BIN"
    echo "  Vision Set ID: $VISION_SET_ID"
    echo "  Disk free: ${DISK_FREE}GB"
    echo "========================================"
    echo ""

    if [ $ERRORS -gt 0 ]; then
        return 1
    fi

    read -p "ดำเนินการต่อ? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "ยกเลิก"
        return 1
    fi

    return 0
}

# ========================== STEP 1: CREATE DOMAIN ===========================

step_create_domain() {
    local DOMAIN="$1"
    local CPUSER="$2"
    local SUBDOMAIN_PREFIX="$DOMAIN"

    log_step "Step 1: สร้าง Domain $DOMAIN"

    local RESULT
    RESULT=$(cpapi2 --user="$CPUSER" AddonDomain addaddondomain \
        newdomain="$DOMAIN" \
        subdomain="$SUBDOMAIN_PREFIX" \
        dir="public_html/$DOMAIN" 2>&1)

    if echo "$RESULT" | grep -q "subdomain.*already exists"; then
        log_warn "$DOMAIN — subdomain prefix ซ้ำ ($SUBDOMAIN_PREFIX)"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (subdomain prefix ซ้ำ)\n"
        return 1
    fi
    if echo "$RESULT" | grep -q "already exists"; then
        log_warn "$DOMAIN — domain already exists"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (domain already exists)\n"
        return 1
    fi
    if echo "$RESULT" | grep -qi "max.*addon\|maximum.*addon"; then
        log_error "$DOMAIN — MAX ADDON DOMAINS REACHED"
        SUMMARY_FAIL="${SUMMARY_FAIL}  - $DOMAIN (max addon domains)\n"
        return 2
    fi
    if echo "$RESULT" | grep -q "result: 1"; then
        log_info "Domain $DOMAIN สร้างสำเร็จ"
        return 0
    fi

    local ERR_MSG
    ERR_MSG=$(echo "$RESULT" | grep -i "reason:" | head -1)
    log_warn "$DOMAIN — create failed: $ERR_MSG"
    SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (create failed)\n"
    return 1
}

# ========================== STEP 2: WAIT CPANEL REGISTER ====================

step_wait_cpanel() {
    local DOMAIN="$1"
    local CPUSER="$2"
    local WAITED=0

    log_step "Step 2: รอ cPanel register..."

    while [ $WAITED -lt $WAIT_CPANEL_MAX ]; do
        if grep -q "^${DOMAIN}:" /etc/userdatadomains 2>/dev/null; then
            if [ -d "/home/${CPUSER}/public_html/${DOMAIN}" ]; then
                log_info "cPanel พร้อม (${WAITED}s)"
                return 0
            fi
        fi
        sleep 2
        WAITED=$((WAITED+2))
    done

    log_warn "$DOMAIN — cPanel register timeout ${WAIT_CPANEL_MAX}s"
    SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (cPanel register timeout)\n"
    return 1
}

# ========================== STEP 3: INSTALL WORDPRESS =======================

step_install_wp() {
    local DOMAIN="$1"
    local CPUSER="$2"
    local DOCROOT="/home/${CPUSER}/public_html/${DOMAIN}"
    local ROOT_PATH="/public_html/${DOMAIN}"

    log_step "Step 3: ติดตั้ง WordPress + Vision Set"

    # --- 3.1 ตรวจสอบ WordPress ที่มีอยู่ด้วย WP Toolkit ---
    log_step "3.1 ตรวจสอบ WordPress ใน $DOMAIN"
    local CHECK
    CHECK=$(wp-toolkit --list -domain-name "$DOMAIN" 2>&1)

    # แยก root installation vs wrong-path installations
    local ROOT_LINE
    ROOT_LINE=$(echo "$CHECK" | grep -P "^\s+\d+\s+${ROOT_PATH}\s")
    local ROOT_ID
    ROOT_ID=$(echo "$ROOT_LINE" | grep -oP '^\s+\K\d+')

    local WRONG_LINES
    WRONG_LINES=$(echo "$CHECK" | grep -P "^\s+\d+\s+${ROOT_PATH}/")
    local WRONG_COUNT
    WRONG_COUNT=$(echo "$WRONG_LINES" | grep -cP '^\s+\d+' 2>/dev/null || echo 0)

    local HAS_ROOT=false
    local HAS_WRONG=false
    [ -n "$ROOT_ID" ] && HAS_ROOT=true
    [ "$WRONG_COUNT" -gt 0 ] 2>/dev/null && HAS_WRONG=true

    # ========== กรณี B: มี WP ที่ root อย่างเดียว → skip ==========
    if [ "$HAS_ROOT" = true ] && [ "$HAS_WRONG" = false ]; then
        log_warn "$DOMAIN — พบ WordPress ติดตั้งอยู่แล้ว"
        log_warn "  ตำแหน่ง: $ROOT_PATH (root) | ID: $ROOT_ID"
        log_warn "  สถานะ: มี WordPress อยู่แล้วที่ตำแหน่งถูกต้อง — ไม่ติดตั้งซ้ำ"
        log_warn "  ผลลัพธ์: ข้ามไป step ถัดไป"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (มี WordPress อยู่แล้วที่ root)\n"
        return 1
    fi

    # ========== กรณี D: มี WP ที่ root + path อื่น → ลบ path อื่น + skip ==========
    if [ "$HAS_ROOT" = true ] && [ "$HAS_WRONG" = true ]; then
        log_warn "$DOMAIN — พบ WordPress หลายตำแหน่ง"
        log_warn "  ✅ root: $ROOT_PATH (ID: $ROOT_ID) — เก็บไว้"

        while read -r LINE; do
            local WID
            WID=$(echo "$LINE" | grep -oP '^\s+\K\d+')
            local WPATH
            WPATH=$(echo "$LINE" | grep -oP '/public_html/\S+')
            [ -z "$WID" ] && continue

            log_warn "  ❌ path ผิด: $WPATH (ID: $WID) — กำลังลบ..."
            wp-toolkit --remove -instance-id "$WID" 2>/dev/null
            if [ $? -eq 0 ]; then
                log_info "  ลบ ID $WID ($WPATH) สำเร็จ"
            else
                log_warn "  ลบ ID $WID ($WPATH) ไม่สำเร็จ"
            fi
        done <<< "$WRONG_LINES"

        log_warn "  สถานะ: ลบ path ผิดแล้ว เหลือแต่ root — ไม่ติดตั้งซ้ำ"
        log_warn "  ผลลัพธ์: ข้ามไป step ถัดไป"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (มี WP ที่ root + ลบ path ผิด ${WRONG_COUNT} ตัว)\n"
        return 1
    fi

    # ========== กรณี C: มี WP ที่ path ผิดอย่างเดียว → ลบ + ติดตั้งใหม่ ==========
    if [ "$HAS_ROOT" = false ] && [ "$HAS_WRONG" = true ]; then
        log_warn "$DOMAIN — พบ WordPress ติดตั้งผิดตำแหน่ง"
        log_warn "  ต้องติดตั้งที่ root ($ROOT_PATH) เท่านั้น"

        while read -r LINE; do
            local WID
            WID=$(echo "$LINE" | grep -oP '^\s+\K\d+')
            local WPATH
            WPATH=$(echo "$LINE" | grep -oP '/public_html/\S+')
            [ -z "$WID" ] && continue

            log_warn "  ❌ path ผิด: $WPATH (ID: $WID) — กำลังลบ..."
            wp-toolkit --remove -instance-id "$WID" 2>/dev/null
            if [ $? -eq 0 ]; then
                log_info "  ลบ ID $WID ($WPATH) สำเร็จ"
            else
                log_warn "  ลบ ID $WID ($WPATH) ไม่สำเร็จ — ข้าม domain นี้"
                SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (ลบ WP path ผิดไม่สำเร็จ)\n"
                return 1
            fi
        done <<< "$WRONG_LINES"

        log_info "$DOMAIN — ลบ path ผิดทั้งหมดสำเร็จ → ติดตั้งใหม่ที่ root"
    fi

    # ========== กรณี A: ไม่มี WP เลย → ติดตั้ง ==========
    if [ "$HAS_ROOT" = false ] && [ "$HAS_WRONG" = false ]; then
        log_info "3.1 ไม่พบ WordPress ใน $DOMAIN — พร้อมติดตั้ง"
    fi

    # --- 3.2 ติดตั้ง WordPress ที่ root เท่านั้น (-path "/") ---
    log_step "3.2 ติดตั้ง WordPress ที่ root (-path \"/\")"
    local RESULT
    local EXIT_CODE
    start_spinner "WP Toolkit install $DOMAIN..."
    RESULT=$(timeout "$TIMEOUT_WPTOOLKIT" wp-toolkit --install \
        -domain-name "$DOMAIN" \
        -path "/" \
        -set-id "$VISION_SET_ID" 2>&1)
    EXIT_CODE=$?
    stop_spinner

    if [ $EXIT_CODE -eq 124 ]; then
        log_warn "$DOMAIN — WP Toolkit timeout ${TIMEOUT_WPTOOLKIT}s"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (WP Toolkit timeout)\n"
        return 1
    fi

    if echo "$RESULT" | grep -qi "max.*database\|maximum.*database"; then
        log_error "$DOMAIN — MAX DATABASES REACHED"
        SUMMARY_FAIL="${SUMMARY_FAIL}  - $DOMAIN (max databases)\n"
        return 2
    fi

    if [ $EXIT_CODE -ne 0 ]; then
        log_warn "$DOMAIN — WP Toolkit install failed (exit $EXIT_CODE)"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (WP Toolkit failed)\n"
        return 1
    fi

    # --- 3.3 ยืนยันหลัง install ว่าลงที่ root จริง (ผ่าน WP Toolkit) ---
    log_step "3.3 ยืนยัน path ที่ติดตั้ง"
    local VERIFY
    VERIFY=$(wp-toolkit --list -domain-name "$DOMAIN" 2>/dev/null)
    local INSTALL_PATH
    INSTALL_PATH=$(echo "$VERIFY" | grep -oP '/public_html/\S+' | head -1)

    if [ "$INSTALL_PATH" != "$ROOT_PATH" ]; then
        log_warn "$DOMAIN — ติดตั้งผิด path: $INSTALL_PATH"
        log_warn "  ต้องเป็น: $ROOT_PATH"
        log_warn "  ผลลัพธ์: ข้าม domain นี้"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (ติดตั้งผิด path: $INSTALL_PATH)\n"
        return 1
    fi

    log_info "3.3 ยืนยัน path ถูกต้อง: $INSTALL_PATH"
    log_info "WordPress + Vision Set สำเร็จ (root)"
    return 0
}

# ========================== STEP 4-5: COPY + RESTORE ========================

step_restore() {
    local DOMAIN="$1"
    local CPUSER="$2"
    local THEME="$3"
    local DOCROOT="/home/${CPUSER}/public_html/${DOMAIN}"
    local WPRESS_FILE="${THEME}.wpress"
    local BACKUPS_DIR="$DOCROOT/wp-content/ai1wm-backups"

    # เช็ค disk space ก่อน restore
    local DISK_NOW
    DISK_NOW=$(get_disk_free_gb)
    if [ "$DISK_NOW" -lt "$DISK_MIN_RUNTIME_GB" ]; then
        log_error "Disk free ${DISK_NOW}GB < ${DISK_MIN_RUNTIME_GB}GB — หยุดทั้งหมด"
        SUMMARY_FAIL="${SUMMARY_FAIL}  - $DOMAIN (disk space critical: ${DISK_NOW}GB)\n"
        return 2
    fi

    # Step 4: Copy .wpress ไปที่ ai1wm-backups
    log_step "Step 4: Copy .wpress → ai1wm-backups"

    # สร้าง ai1wm-backups/ ถ้ายังไม่มี (เป็น user เพื่อ ownership ถูกต้อง)
    if [ ! -d "$BACKUPS_DIR" ]; then
        sudo -u "$CPUSER" mkdir -p "$BACKUPS_DIR"
    fi

    cp "${TEMPLATE_DIR}/${WPRESS_FILE}" "$BACKUPS_DIR/"
    if [ $? -ne 0 ]; then
        log_warn "$DOMAIN — copy .wpress ไม่สำเร็จ"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (copy wpress failed)\n"
        return 1
    fi
    chown "${CPUSER}:${CPUSER}" "$BACKUPS_DIR/${WPRESS_FILE}"
    log_info "Copy ${WPRESS_FILE} สำเร็จ"

    # Step 5: Restore
    # รอให้ WP-CLI เห็น AI1WM command หลัง WP Toolkit install
    sleep 5
    log_step "Step 5: AI1WM Restore ($WPRESS_FILE)"

    local RESULT
    local EXIT_CODE
    RESULT=$(timeout "$TIMEOUT_RESTORE" sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" \
        ai1wm restore "$WPRESS_FILE" --path="$DOCROOT" 2>&1)
    EXIT_CODE=$?

    # ลบ .wpress ทุกไฟล์ทันทีหลัง restore (ไม่ว่าชื่ออะไร ไม่ว่าสำเร็จหรือไม่)
    rm -f "$BACKUPS_DIR/"*.wpress 2>/dev/null

    if [ $EXIT_CODE -eq 124 ]; then
        log_warn "$DOMAIN — restore timeout ${TIMEOUT_RESTORE}s"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (restore timeout)\n"
        return 1
    fi

    if [ $EXIT_CODE -ne 0 ]; then
        log_warn "$DOMAIN — restore failed (exit $EXIT_CODE)"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (restore failed)\n"
        return 1
    fi

    if echo "$RESULT" | grep -qi "Restore complete"; then
        log_info "Restore สำเร็จ"
    else
        log_warn "$DOMAIN — restore result unclear"
        SUMMARY_WARN="${SUMMARY_WARN}  - $DOMAIN (restore result unclear)\n"
    fi

    return 0
}

step_cleanup() {
    local DOMAIN="$1"
    local CPUSER="$2"
    local DOCROOT="/home/${CPUSER}/public_html/${DOMAIN}"

    log_step "Step 6: Cleanup + Config"

    # 6.1 ลบ plugins (hello, akismet, all-in-one-wp-migration)
    sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" plugin deactivate \
        hello akismet all-in-one-wp-migration \
        --path="$DOCROOT" 2>/dev/null
    sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" plugin delete \
        hello akismet all-in-one-wp-migration \
        --path="$DOCROOT" 2>/dev/null
    log_info "6.1 ลบ plugins เสร็จ"
    sleep 2

    # 6.2 ลบ default themes (เก็บ active + parent + ใหม่สุด)
    local CURRENT_ACTIVE
    CURRENT_ACTIVE=$(sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" theme list \
        --path="$DOCROOT" --status=active --field=name 2>/dev/null)

    local PARENT_THEME
    PARENT_THEME=$(sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" theme list \
        --path="$DOCROOT" --status=parent --field=name 2>/dev/null)

    local LATEST_DEFAULT=""
    local LATEST_NUM=0
    local ALL_THEMES
    ALL_THEMES=$(sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" theme list \
        --path="$DOCROOT" --field=name 2>/dev/null)

    while read -r T; do
        local NUM
        NUM=$(theme_to_num "$T")
        if [ "$NUM" -gt "$LATEST_NUM" ]; then
            LATEST_NUM=$NUM
            LATEST_DEFAULT=$T
        fi
    done <<< "$ALL_THEMES"

    local THEMES_TO_DELETE=""
    while read -r T; do
        local NUM
        NUM=$(theme_to_num "$T")
        if [ "$NUM" -gt 0 ]; then
            if [ "$T" != "$CURRENT_ACTIVE" ] && [ "$T" != "$PARENT_THEME" ] && [ "$T" != "$LATEST_DEFAULT" ]; then
                THEMES_TO_DELETE="$THEMES_TO_DELETE $T"
            fi
        fi
    done <<< "$ALL_THEMES"

    if [ -n "$THEMES_TO_DELETE" ]; then
        sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" theme delete \
            $THEMES_TO_DELETE --path="$DOCROOT" 2>/dev/null
        log_info "6.2 ลบ themes:$THEMES_TO_DELETE"
    else
        log_info "6.2 ไม่มี theme ต้องลบ"
    fi
    sleep 3

    # 6.3 แก้ Font CSS URL เก่า (AI1WM ไม่แก้ URL ในไฟล์ CSS)
    log_step "6.3 แก้ Font CSS URL"
    local FONT_CSS="$DOCROOT/wp-content/uploads/blocksy/css/global.css"
    if [ -f "$FONT_CSS" ]; then
        local OLD_DOMAIN
        OLD_DOMAIN=$(grep -oP 'https://\K[^/]+' "$FONT_CSS" | head -1)
        if [ -n "$OLD_DOMAIN" ] && [ "$OLD_DOMAIN" != "$DOMAIN" ]; then
            sed -i "s|https://$OLD_DOMAIN|https://$DOMAIN|g" "$FONT_CSS"
            log_info "6.3 Font CSS URL แก้จาก $OLD_DOMAIN → $DOMAIN"
        elif [ -z "$OLD_DOMAIN" ]; then
            log_info "6.3 ไม่พบ URL ใน Font CSS (ข้าม)"
        else
            log_info "6.3 Font CSS URL ถูกต้องแล้ว ($DOMAIN)"
        fi
    else
        log_info "6.3 ไม่มี Blocksy font CSS (ข้าม)"
    fi

    # 6.4 Freemius clone resolve
    sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" config set \
        FS__RESOLVE_CLONE_AS long_term_duplicate \
        --type=constant --path="$DOCROOT" 2>/dev/null
    log_info "6.4 Freemius clone resolve เสร็จ"
    sleep 3

    # 6.5 QUIC.cloud init (link จะทำหลัง loop จบ — ป้องกัน rate limit)
    local INIT_RESULT
    INIT_RESULT=$(sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" litespeed-online init \
        --path="$DOCROOT" 2>&1)
    if echo "$INIT_RESULT" | grep -qi "success\|Congratulations"; then
        log_info "6.5 QUIC.cloud init สำเร็จ ✅"
    else
        log_warn "6.5 QUIC.cloud init ไม่สำเร็จ (จะ retry ใน Step 10)"
    fi

    # บันทึก domain สำหรับ link ทีหลัง (ไม่ว่า init สำเร็จหรือไม่ — Step 10 จะ init ซ้ำถ้าจำเป็น)
    if [ -n "$QC_CF_EMAIL" ] && [ -n "$QC_TOKEN" ]; then
        LINK_DOMAINS="${LINK_DOMAINS}${DOMAIN}\n"
    fi
    sleep 3

    # 6.6 Cloudflare API setup
    if [ -n "$CF_TOKEN" ] && [ -n "$QC_CF_EMAIL" ]; then
        log_step "6.6 Cloudflare API setup"

        sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" litespeed-option set cdn-cloudflare 1 --path="$DOCROOT" 2>/dev/null
        sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" litespeed-option set cdn-cloudflare_key "$CF_TOKEN" --path="$DOCROOT" 2>/dev/null
        sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" litespeed-option set cdn-cloudflare_email "$QC_CF_EMAIL" --path="$DOCROOT" 2>/dev/null
        sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" litespeed-option set cdn-cloudflare_name "$DOMAIN" --path="$DOCROOT" 2>/dev/null
        sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" litespeed-option set cdn-cloudflare_clear 1 --path="$DOCROOT" 2>/dev/null

        local ZONE_ID
        ZONE_ID=$(curl -s -X GET \
            "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
            -H "X-Auth-Email: $QC_CF_EMAIL" \
            -H "X-Auth-Key: $CF_TOKEN" \
            -H "Content-Type: application/json" \
            | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

        if [ -n "$ZONE_ID" ]; then
            sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" eval \
                "update_option('litespeed.conf.cdn-cloudflare_zone', '$ZONE_ID');" \
                --path="$DOCROOT" 2>/dev/null
            log_info "6.6 Cloudflare setup ครบ — Zone ID: $ZONE_ID"
        else
            log_warn "6.6 Cloudflare Zone ID ไม่เจอ"
            SUMMARY_WARN="${SUMMARY_WARN}  - $DOMAIN (CF Zone ID not found)\n"
        fi
    fi
    sleep 3

    # 6.7 Rank Math connect
    log_step "6.7 Rank Math connect"
    sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" eval '
        delete_option("rank_math_connect_data");
        delete_option("rank_math_registration_data");
        $data = [
            "username"  => "'"$RANKMATH_EMAIL"'",
            "email"     => "'"$RANKMATH_EMAIL"'",
            "api_key"   => "'"$RANKMATH_API_KEY"'",
            "plan"      => "'"$RANKMATH_PLAN"'",
            "connected" => 1,
            "site_url"  => "https://'"$DOMAIN"'"
        ];
        update_option("rank_math_connect_data", $data);
        \RankMath\Admin\Admin_Helper::get_registration_data($data);
        $v = \RankMath\Admin\Admin_Helper::get_registration_data();
        echo $v ? "connected" : "failed";
    ' --path="$DOCROOT" 2>/dev/null | grep -q "connected" \
        && log_info "6.7 Rank Math connected ($RANKMATH_EMAIL)" \
        || log_warn "6.7 Rank Math connect failed"

    # 6.8 ลบ Rank Math sitemap cache (URL เก่าจาก .wpress)
    log_step "6.8 ลบ Rank Math sitemap cache"
    local SITEMAP_COUNT
    SITEMAP_COUNT=$(find "$DOCROOT/wp-content/uploads/rank-math/" -name "*.xml" 2>/dev/null | wc -l)
    if [ "$SITEMAP_COUNT" -gt 0 ]; then
        rm -f "$DOCROOT/wp-content/uploads/rank-math/"*.xml 2>/dev/null
        log_info "6.8 ลบ sitemap cache $SITEMAP_COUNT ไฟล์ (Rank Math จะสร้างใหม่)"
    else
        log_info "6.8 ไม่มี sitemap cache (ข้าม)"
    fi

    return 0
}

# ========================== STEP 7-8: PURGE + FLUSH =========================

step_purge_flush() {
    local DOMAIN="$1"
    local CPUSER="$2"
    local DOCROOT="/home/${CPUSER}/public_html/${DOMAIN}"

    # Step 7: LiteSpeed purge (ลบ files ตรง — ไม่ง้อ DNS)
    sleep 3
    log_step "Step 7: LiteSpeed purge"
    rm -rf "$DOCROOT/wp-content/litespeed/" 2>/dev/null
    rm -rf "/home/${CPUSER}/lscache/" 2>/dev/null

    # ล้าง LiteSpeed avatar cache table (ป้องกัน Duplicate entry error จาก .wpress เก่า)
    local TABLE_PREFIX
    TABLE_PREFIX=$(sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" config get table_prefix \
        --path="$DOCROOT" 2>/dev/null)
    if [ -n "$TABLE_PREFIX" ]; then
        sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" db query \
            "TRUNCATE TABLE ${TABLE_PREFIX}litespeed_avatar;" \
            --path="$DOCROOT" 2>/dev/null
    fi
    log_info "LiteSpeed purge เสร็จ"

    # Step 8: Flush permalink
    sleep 3
    log_step "Step 8: Flush permalink"
    local FLUSH_RC
    sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" eval '
        global $wp_rewrite;
        $wp_rewrite->set_permalink_structure("/%postname%/");
        $GLOBALS["is_apache"] = true;
        flush_rewrite_rules(true);
        echo "done";
    ' --path="$DOCROOT" 2>/dev/null | grep -q "done"
    FLUSH_RC=$?
    if [ $FLUSH_RC -ne 0 ]; then
        log_warn "$DOMAIN — flush permalink failed"
        SUMMARY_WARN="${SUMMARY_WARN}  - $DOMAIN (flush failed)\n"
    else
        log_info "Flush permalink เสร็จ"
    fi

    # Step 9: Activate theme (ขั้นตอนสุดท้าย — แก้ theme ที่อาจถูก reset ระหว่าง Step 6)
    sleep 3
    log_step "Step 9: Activate $ACTIVE_THEME (ขั้นตอนสุดท้าย)"
    sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" theme activate "$ACTIVE_THEME" \
        --path="$DOCROOT" 2>/dev/null
    local FINAL_THEME
    FINAL_THEME=$(sudo -u "$CPUSER" $PHP_CLI "$WP_CLI" option get stylesheet \
        --path="$DOCROOT" 2>/dev/null)
    if [ "$FINAL_THEME" = "$ACTIVE_THEME" ]; then
        log_info "9 Theme active: $ACTIVE_THEME ✅"
    else
        log_warn "9 ❌ Theme: $FINAL_THEME (ควรเป็น $ACTIVE_THEME)"
        SUMMARY_WARN="${SUMMARY_WARN}  - $DOMAIN (final theme: $FINAL_THEME)\n"
    fi

    return 0
}

# ========================== MAIN LOOP =======================================

process_site() {
    local DOMAIN="$1"
    local THEME="$2"
    local CPUSER="$CPANEL_USER"
    local SITE_START
    SITE_START=$(date +%s)

    echo ""
    echo "════════════════════════════════════════"
    echo "  [$((COUNT_SUCCESS + COUNT_SKIP + COUNT_FAIL + 1))/$COUNT_TOTAL] $DOMAIN"
    echo "  cPanel: $CPUSER | Theme: $THEME"
    echo "════════════════════════════════════════"

    # Step 1-2: Create Domain (ข้ามถ้ามีอยู่แล้ว)
    if grep -q "^${DOMAIN}:" /etc/userdatadomains 2>/dev/null; then
        log_info "$DOMAIN — มีอยู่แล้ว ข้าม Step 1-2 → ไป Step 3"
    else
        step_create_domain "$DOMAIN" "$CPUSER"
        local RC=$?
        [ $RC -eq 2 ] && return 2
        [ $RC -ne 0 ] && { COUNT_SKIP=$((COUNT_SKIP+1)); return 0; }

        # Step 2: Wait cPanel
        step_wait_cpanel "$DOMAIN" "$CPUSER"
        [ $? -ne 0 ] && { COUNT_SKIP=$((COUNT_SKIP+1)); return 0; }
    fi

    # Step 3: Install WordPress
    step_install_wp "$DOMAIN" "$CPUSER"
    local RC=$?
    [ $RC -eq 2 ] && return 2
    [ $RC -ne 0 ] && { COUNT_SKIP=$((COUNT_SKIP+1)); return 0; }

    # Step 4-5: Copy + Restore
    step_restore "$DOMAIN" "$CPUSER" "$THEME"
    RC=$?
    [ $RC -eq 2 ] && return 2
    [ $RC -ne 0 ] && { COUNT_SKIP=$((COUNT_SKIP+1)); return 0; }

    # Step 6: Cleanup + Config
    step_cleanup "$DOMAIN" "$CPUSER"

    # Step 7-8: Purge + Flush (flush เป็นขั้นตอนสุดท้าย)
    step_purge_flush "$DOMAIN" "$CPUSER"

    # สำเร็จ
    local SITE_END
    SITE_END=$(date +%s)
    local SITE_DURATION=$((SITE_END - SITE_START))
    log_info "✅ $DOMAIN สำเร็จ (${SITE_DURATION}s)"
    SUMMARY_SUCCESS="${SUMMARY_SUCCESS}  - $DOMAIN ($THEME) — ${SITE_DURATION}s\n"
    COUNT_SUCCESS=$((COUNT_SUCCESS+1))
    return 0
}

# ========================== SUMMARY + TELEGRAM ==============================

show_summary() {
    local END_TIME
    END_TIME=$(date +%s)
    local TOTAL_DURATION=$(( (END_TIME - START_TIME) / 60 ))
    local DISK_FREE
    DISK_FREE=$(get_disk_free_gb)

    echo ""
    echo "════════════════════════════════════════"
    echo "  สรุปผล — v${VERSION} — $(date '+%d %b %Y %H:%M')"
    echo "════════════════════════════════════════"
    echo -e "  ${GREEN}✅ สำเร็จ: $COUNT_SUCCESS${NC}"
    echo -e "  ${YELLOW}⚠️ ข้าม: $COUNT_SKIP${NC}"
    echo -e "  ${RED}❌ ล้มเหลว: $COUNT_FAIL${NC}"
    if [ "$LINK_TOTAL" -gt 0 ]; then
        echo -e "  ☁️ QUIC.cloud link: ${LINK_SUCCESS}/${LINK_TOTAL} สำเร็จ"
    fi
    echo "  ⏱ เวลารวม: ${TOTAL_DURATION} นาที"
    echo "  💾 Disk free: ${DISK_FREE}GB"
    echo "  🖥 Server: $(hostname)"
    echo "════════════════════════════════════════"

    if [ -n "$SUMMARY_SUCCESS" ]; then
        echo -e "\n✅ สำเร็จ:"
        echo -e "$SUMMARY_SUCCESS"
    fi
    if [ -n "$SUMMARY_SKIP" ]; then
        echo -e "⚠️ ข้าม:"
        echo -e "$SUMMARY_SKIP"
    fi
    if [ -n "$SUMMARY_FAIL" ]; then
        echo -e "❌ ล้มเหลว:"
        echo -e "$SUMMARY_FAIL"
    fi
    if [ -n "$SUMMARY_WARN" ]; then
        echo -e "🟡 Warning:"
        echo -e "$SUMMARY_WARN"
    fi

    # Telegram
    local QC_STATUS=""
    if [ "$LINK_TOTAL" -gt 0 ]; then
        if [ "$LINK_SUCCESS" -eq "$LINK_TOTAL" ]; then
            QC_STATUS="
☁️ QUIC.cloud link: ✅ ${LINK_SUCCESS}/${LINK_TOTAL} สำเร็จทั้งหมด"
        else
            QC_STATUS="
☁️ QUIC.cloud link: ${LINK_SUCCESS}/${LINK_TOTAL} สำเร็จ (❌ ${LINK_FAIL} ไม่สำเร็จ)"
        fi
    fi

    local TG_MSG="📊 <b>Daily Web Creation — $(date '+%d %b %Y')</b>
🖥 Server: $(hostname)

✅ สำเร็จ: $COUNT_SUCCESS/$COUNT_TOTAL
⚠️ ข้าม: $COUNT_SKIP
❌ ล้มเหลว: $COUNT_FAIL${QC_STATUS}

⏱ เวลารวม: ${TOTAL_DURATION} นาที
💾 Disk free: ${DISK_FREE}GB"

    if [ -n "$SUMMARY_SKIP" ]; then
        TG_MSG="$TG_MSG

⚠️ ข้าม:
$(echo -e "$SUMMARY_SKIP")"
    fi
    if [ -n "$SUMMARY_FAIL" ]; then
        TG_MSG="$TG_MSG

❌ ล้มเหลว:
$(echo -e "$SUMMARY_FAIL")"
    fi

    send_telegram "$TG_MSG"

    echo ""
    echo "Log: $LOG_FILE"
}

# ========================== MAIN ============================================

main() {
    if [ -z "$1" ]; then
        echo "Usage: $0 /path/to/sites.csv"
        echo ""
        echo "CSV Format: domain,theme"
        echo "Example:    a1.com,theme-black.store"
        exit 1
    fi

    CSV_FILE="$1"

    if [ "$(id -u)" -ne 0 ]; then
        echo "ต้องรันด้วย root"
        exit 1
    fi

    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/${DATE_TAG}.log"
    echo "========================================" > "$LOG_FILE"
    echo "Start: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    echo "CSV: $CSV_FILE" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"

    # โหลด server-config.conf (credentials)
    local CONFIG_DIR
    CONFIG_DIR=$(dirname "$CSV_FILE")
    local SERVER_CONFIG=""

    if [ -f "${CONFIG_DIR}/server-config.conf" ]; then
        SERVER_CONFIG="${CONFIG_DIR}/server-config.conf"
    elif [ -f "/usr/local/etc/website-daily-create/server-config.conf" ]; then
        SERVER_CONFIG="/usr/local/etc/website-daily-create/server-config.conf"
    fi

    if [ -z "$SERVER_CONFIG" ]; then
        echo -e "${RED}[❌] server-config.conf ไม่เจอ${NC}"
        echo "  ค้นหาที่:"
        echo "    1. ${CONFIG_DIR}/server-config.conf"
        echo "    2. /usr/local/etc/website-daily-create/server-config.conf"
        exit 1
    fi

    source "$SERVER_CONFIG"
    echo "Config: $SERVER_CONFIG" >> "$LOG_FILE"

    # ตรวจสอบตัวแปรสำคัญจาก server-config.conf
    if [ -z "$CPANEL_USER" ]; then
        echo -e "${RED}[❌] CPANEL_USER ไม่ได้ตั้งค่าใน server-config.conf${NC}"
        exit 1
    fi

    preflight_check
    if [ $? -ne 0 ]; then
        log_error "Pre-flight check failed — ยกเลิก"
        exit 1
    fi

    # Main loop
    while IFS=',' read -r DOMAIN THEME; do
        [ -z "$DOMAIN" ] && continue

        DOMAIN=$(echo "$DOMAIN" | xargs)
        THEME=$(echo "$THEME" | xargs)

        process_site "$DOMAIN" "$THEME"
        local RC=$?

        if [ $RC -eq 2 ]; then
            log_error "🔴 หยุด loop ทั้งหมด — critical error"
            COUNT_FAIL=$((COUNT_FAIL+1))
            break
        fi

    done < <(grep '[^[:space:]]' "$CSV_FILE" | tail -n +2)

    # Step 10: QUIC.cloud link ทุกเว็บ (หลัง loop จบ — ป้องกัน rate limit)
    if [ -n "$LINK_DOMAINS" ] && [ -n "$QC_CF_EMAIL" ] && [ -n "$QC_TOKEN" ]; then
        echo ""
        echo "════════════════════════════════════════"
        echo "  Step 10: QUIC.cloud Link"
        echo "════════════════════════════════════════"

        LINK_TOTAL=$(echo -e "$LINK_DOMAINS" | grep -c '[^[:space:]]')
        log_step "Step 10: QUIC.cloud link $LINK_TOTAL เว็บ"

        local LINK_COUNT=0

        # แปลง cooldown text เป็นวินาที (เช่น "3m 24s" → 204)
        parse_cooldown() {
            local TEXT="$1"
            local MINS SECS
            MINS=$(echo "$TEXT" | grep -oP '\d+(?=m)' || echo 0)
            SECS=$(echo "$TEXT" | grep -oP '\d+(?=s)' || echo 0)
            [ -z "$MINS" ] && MINS=0
            [ -z "$SECS" ] && SECS=0
            echo $(( MINS * 60 + SECS + 5 ))
        }

        # Countdown timer (แสดงนับถอยหลัง)
        countdown() {
            local WAIT_SECS="$1"
            local MSG="$2"
            local i
            for i in $(seq "$WAIT_SECS" -1 1); do
                printf "\r  ⏳ $MSG — cooldown %ds  " "$i"
                sleep 1
            done
            printf "\r\033[K"
        }

        # link ทีละเว็บ (auto init ถ้ายังไม่ activate)
        try_link() {
            local DOMAIN="$1"
            local DOCROOT="/home/${CPANEL_USER}/public_html/${DOMAIN}"
            local MAX_RETRY=3
            local ATTEMPT=0

            while [ $ATTEMPT -lt $MAX_RETRY ]; do
                ATTEMPT=$((ATTEMPT+1))
                local RESULT
                RESULT=$(sudo -u "$CPANEL_USER" $PHP_CLI "$WP_CLI" litespeed-online link \
                    --email="$QC_CF_EMAIL" \
                    --api-key="$QC_TOKEN" \
                    --path="$DOCROOT" 2>&1)

                if echo "$RESULT" | grep -qi "success\|linked"; then
                    log_info "  [$LINK_COUNT/$LINK_TOTAL] $DOMAIN — link สำเร็จ ✅"
                    LINK_SUCCESS=$((LINK_SUCCESS+1))
                    return 0
                elif echo "$RESULT" | grep -qi "activate QC first"; then
                    # init ยังไม่สำเร็จ → init ก่อน แล้ว retry
                    log_warn "  [$LINK_COUNT/$LINK_TOTAL] $DOMAIN — ยังไม่ init → กำลัง init..."
                    sudo -u "$CPANEL_USER" $PHP_CLI "$WP_CLI" litespeed-online init \
                        --path="$DOCROOT" 2>/dev/null
                    countdown 10 "$DOMAIN — รอหลัง init"
                elif echo "$RESULT" | grep -qi "try after"; then
                    local CD_TEXT
                    CD_TEXT=$(echo "$RESULT" | grep -oP 'try after \K[^.]+')
                    local CD_SECS
                    CD_SECS=$(parse_cooldown "$CD_TEXT")
                    log_warn "  [$LINK_COUNT/$LINK_TOTAL] $DOMAIN — rate limit ($CD_TEXT)"
                    countdown "$CD_SECS" "$DOMAIN"
                elif echo "$RESULT" | grep -qi "Invalid API"; then
                    log_warn "  [$LINK_COUNT/$LINK_TOTAL] $DOMAIN — API error → รอ 60s"
                    countdown 60 "$DOMAIN — API cooldown"
                else
                    log_warn "  [$LINK_COUNT/$LINK_TOTAL] $DOMAIN — fail: $(echo "$RESULT" | tail -1)"
                    LINK_FAIL=$((LINK_FAIL+1))
                    SUMMARY_WARN="${SUMMARY_WARN}  - $DOMAIN (QUIC link failed)\n"
                    return 1
                fi
            done

            log_warn "  [$LINK_COUNT/$LINK_TOTAL] $DOMAIN — fail หลัง $MAX_RETRY retry"
            LINK_FAIL=$((LINK_FAIL+1))
            SUMMARY_WARN="${SUMMARY_WARN}  - $DOMAIN (QUIC link failed after $MAX_RETRY retries)\n"
            return 1
        }

        # ใช้ process substitution แทน pipe (ป้องกัน subshell — ตัวแปรไม่หาย)
        while read -r D; do
            [ -z "$D" ] && continue
            LINK_COUNT=$((LINK_COUNT+1))
            try_link "$D"

            # delay 30s ก่อนเว็บถัดไป (ป้องกัน rate limit)
            if [ $LINK_COUNT -lt $LINK_TOTAL ]; then
                countdown 30 "รอก่อนเว็บถัดไป"
            fi
        done < <(echo -e "$LINK_DOMAINS")

        log_info "Step 10: QUIC.cloud link เสร็จ (สำเร็จ: $LINK_SUCCESS/$LINK_TOTAL)"
    fi

    show_summary

    echo "End: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
}

# Run
main "$@"
