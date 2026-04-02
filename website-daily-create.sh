#!/bin/bash
# ============================================================================
# website-daily-create.sh — Bulk WordPress Site Creation Pipeline
# Version: 1.0.0
# Location: /usr/local/sbin/website-daily-create.sh
# Usage: website-daily-create.sh /path/to/sites.csv
# ============================================================================
# CSV Format: domain,cpanel_user,theme,qc_cf_email,qc_token,cf_token
# Example:    a1.com,y2026m04ns504,theme-black.store,user@gmail.com,quic_token,cf_global_api_key
# ============================================================================

set -o pipefail

# ========================== CONFIG ==========================================
# --- Paths ---
TEMPLATE_DIR="/usr/local/share/ai1wm-templates"  # .wpress template files
LOG_DIR="/var/log/website-daily-create"
WP_CLI="/usr/local/bin/wp"

# --- Telegram Notification ---
TELEGRAM_BOT_TOKEN="8601090793:AAHNfwBd5Vf80Hq59NqQ5ZIwPmbYcqRdir4"
TELEGRAM_CHAT_ID="-5223351518"

# --- Limits ---
DISK_MIN_START_GB=30           # Pre-flight: disk ต้องมีอย่างน้อย (GB)
DISK_MIN_RUNTIME_GB=5          # ระหว่างรัน: ถ้าต่ำกว่านี้หยุดทันที
WAIT_CPANEL_MAX=30             # รอ cPanel register สูงสุด (วินาที)
TIMEOUT_WPTOOLKIT=120          # timeout WP Toolkit install (วินาที)
TIMEOUT_RESTORE=600            # timeout AI1WM restore (วินาที)

# --- Rank Math SEO (ใช้ค่าเดียวกันทุกเว็บ ไม่ต้องใส่ใน CSV) ---
# เปลี่ยน email/api_key ที่นี่ ถ้าย้าย Rank Math account
# หา API Key ได้ที่: rankmath.com/account/ → API Key
RANKMATH_EMAIL="ufavisionseoteam@gmail.com"       # Rank Math account email
RANKMATH_API_KEY="03cefb18bb49a91d3c619d2906b43db8"  # Rank Math API Key
RANKMATH_PLAN="pro"                                # free / pro / business / agency
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
PHP_CLI=""
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
# ============================================================================

# ========================== FUNCTIONS =======================================

log_info()  { echo -e "${GREEN}[✅]${NC} $1"; echo "[$(date '+%H:%M:%S')] [OK] $1" >> "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[⚠️]${NC} $1"; echo "[$(date '+%H:%M:%S')] [WARN] $1" >> "$LOG_FILE"; }
log_error() { echo -e "${RED}[❌]${NC} $1"; echo "[$(date '+%H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"; }
log_step()  { echo -e "${CYAN}[→]${NC} $1"; echo "[$(date '+%H:%M:%S')] [STEP] $1" >> "$LOG_FILE"; }

# Spinner — ใช้ระหว่างรอ command ที่ใช้เวลานาน
# Usage: start_spinner "Installing..." → รัน command → stop_spinner
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

# หา PHP CLI อัตโนมัติ (ตัวใหม่สุดบน server)
find_php_cli() {
    local CLI
    CLI=$(ls -d /opt/cpanel/ea-php*/root/usr/bin/php 2>/dev/null | sort -V | tail -1)
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

# แปลงชื่อ theme เป็นตัวเลข
theme_to_num() {
    case "$1" in
        twentytwentyone)   echo 21;;
        twentytwentytwo)   echo 22;;
        twentytwentythree) echo 23;;
        twentytwentyfour)  echo 24;;
        twentytwentyfive)  echo 25;;
        twentytwentysix)   echo 26;;
        twentytwentyseven) echo 27;;
        twentytwentyeight) echo 28;;
        twentytwentynine)  echo 29;;
        twentythirty)      echo 30;;
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
    echo "  Pre-flight Check"
    echo "========================================"
    echo ""

    local ERRORS=0
    local WARNINGS=0

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
    # ตรวจ format (5 columns)
    local BAD_LINES
    BAD_LINES=$(grep '[^[:space:]]' "$CSV_FILE" | tail -n +2 | awk -F',' 'NF!=6 && NF!=0 {print NR+1": "$0}')
    if [ -n "$BAD_LINES" ]; then
        log_error "CSV format ผิด (ต้องมี 6 columns: domain,cpanel_user,theme,qc_cf_email,qc_token,cf_token):"
        echo "$BAD_LINES"
        return 1
    fi
    # ตรวจ domain ซ้ำ
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

    # 3. PHP CLI
    log_step "3. ตรวจสอบ PHP CLI..."
    PHP_CLI=$(find_php_cli)
    if [ -z "$PHP_CLI" ]; then
        log_error "ไม่พบ PHP CLI ที่ใช้ได้"
        return 1
    fi
    local PHP_VER
    PHP_VER=$("$PHP_CLI" -r "echo PHP_VERSION;" 2>/dev/null)
    log_info "PHP CLI: $PHP_CLI (v$PHP_VER)"

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

    # 6. cPanel users
    log_step "6. ตรวจสอบ cPanel users..."
    local MISSING_USERS=""
    while IFS=',' read -r DOMAIN CPUSER THEME QC_CF_EMAIL QC_TOKEN CF_TOKEN; do
        if [ ! -d "/var/cpanel/users" ] || [ ! -f "/var/cpanel/users/$CPUSER" ]; then
            MISSING_USERS="$MISSING_USERS $CPUSER"
        fi
    done < <(grep '[^[:space:]]' "$CSV_FILE" | tail -n +2)
    if [ -n "$MISSING_USERS" ]; then
        log_error "cPanel users ไม่มี:$MISSING_USERS"
        return 1
    fi
    log_info "cPanel users OK"

    # 7. .wpress templates
    log_step "7. ตรวจสอบ .wpress templates..."
    if [ ! -d "$TEMPLATE_DIR" ]; then
        log_error "Template directory ไม่มี: $TEMPLATE_DIR"
        return 1
    fi
    local MISSING_TEMPLATES=""
    while IFS=',' read -r DOMAIN CPUSER THEME QC_CF_EMAIL QC_TOKEN CF_TOKEN; do
        if [ ! -f "${TEMPLATE_DIR}/${THEME}.wpress" ]; then
            MISSING_TEMPLATES="$MISSING_TEMPLATES ${THEME}.wpress"
        fi
    done < <(grep '[^[:space:]]' "$CSV_FILE" | tail -n +2)
    if [ -n "$MISSING_TEMPLATES" ]; then
        log_error "Templates ไม่มี:$MISSING_TEMPLATES"
        return 1
    fi
    log_info "Templates OK"

    # 8. QUIC.cloud credentials ใน CSV
    log_step "8. ตรวจสอบ QUIC.cloud credentials..."
    local MISSING_QUIC=""
    while IFS=',' read -r DOMAIN CPUSER THEME QC_CF_EMAIL QC_TOKEN CF_TOKEN; do
        if [ -n "$QC_CF_EMAIL" ] && [ -z "$QC_TOKEN" ]; then
            MISSING_QUIC="$MISSING_QUIC  - $DOMAIN ($QC_CF_EMAIL ไม่มี token)\n"
        fi
    done < <(grep '[^[:space:]]' "$CSV_FILE" | tail -n +2)
    if [ -n "$MISSING_QUIC" ]; then
        log_warn "QUIC.cloud token ไม่ครบ (จะข้าม link):"
        echo -e "$MISSING_QUIC"
    else
        log_info "QUIC.cloud credentials OK"
    fi

    # 9. Telegram
    log_step "9. ตรวจสอบ Telegram..."
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        log_warn "Telegram bot token ไม่ได้ตั้ง (จะไม่ส่ง notification)"
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
    while IFS=',' read -r DOMAIN CPUSER THEME QC_CF_EMAIL QC_TOKEN CF_TOKEN; do
        if grep -q "^${DOMAIN}:" /etc/userdatadomains 2>/dev/null; then
            EXISTING_DOMAINS="$EXISTING_DOMAINS  - $DOMAIN\n"
            EXISTING_COUNT=$((EXISTING_COUNT+1))
        fi
    done < <(grep '[^[:space:]]' "$CSV_FILE" | tail -n +2)
    if [ $EXISTING_COUNT -gt 0 ]; then
        log_warn "Domains ที่มีอยู่แล้ว ($EXISTING_COUNT เว็บ — จะข้าม):"
        echo -e "$EXISTING_DOMAINS"
    fi

    # สรุป
    echo ""
    echo "========================================"
    local READY_COUNT=$((COUNT_TOTAL - EXISTING_COUNT))
    echo -e "  ${GREEN}✅ พร้อมสร้าง: $READY_COUNT เว็บ${NC}"
    if [ $EXISTING_COUNT -gt 0 ]; then
        echo -e "  ${YELLOW}⚠️ ข้าม (มีอยู่แล้ว): $EXISTING_COUNT เว็บ${NC}"
    fi
    echo "  Server: $(hostname)"
    echo "  PHP: $PHP_CLI"
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
    local SUBDOMAIN_PREFIX
    SUBDOMAIN_PREFIX=$(echo "$DOMAIN" | cut -d. -f1)

    log_step "Step 1: สร้าง Domain $DOMAIN"

    local RESULT
    RESULT=$(cpapi2 --user="$CPUSER" AddonDomain addaddondomain \
        newdomain="$DOMAIN" \
        subdomain="$SUBDOMAIN_PREFIX" \
        dir="public_html/$DOMAIN" 2>&1)

    # เช็ค error
    if echo "$RESULT" | grep -q "already exists"; then
        log_warn "$DOMAIN — domain already exists"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (domain already exists)\n"
        return 1
    fi
    if echo "$RESULT" | grep -q "subdomain.*already exists"; then
        log_warn "$DOMAIN — subdomain already exists (ต้องตรวจสอบ)"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (subdomain already exists)\n"
        return 1
    fi
    if echo "$RESULT" | grep -qi "max.*addon\|maximum.*addon"; then
        log_error "$DOMAIN — MAX ADDON DOMAINS REACHED"
        SUMMARY_FAIL="${SUMMARY_FAIL}  - $DOMAIN (max addon domains)\n"
        return 2  # 2 = หยุด loop ทั้งหมด
    fi
    if echo "$RESULT" | grep -q "result: 1"; then
        log_info "Domain $DOMAIN สร้างสำเร็จ"
        return 0
    fi

    # error อื่นๆ
    local ERR_MSG
    ERR_MSG=$(echo "$RESULT" | grep -i "reason:" | head -1)
    log_warn "$DOMAIN — create failed: $ERR_MSG"
    SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (create failed: $ERR_MSG)\n"
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

    log_warn "$DOMAIN — cPanel register timeout ${WAIT_CPANEL_MAX}s (ต้องตรวจสอบ)"
    SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (cPanel register timeout)\n"
    return 1
}

# ========================== STEP 3: INSTALL WORDPRESS =======================

step_install_wp() {
    local DOMAIN="$1"
    local CPUSER="$2"
    local DOCROOT="/home/${CPUSER}/public_html/${DOMAIN}"

    log_step "Step 3: ติดตั้ง WordPress + Vision Set"

    local RESULT
    start_spinner "WP Toolkit install $DOMAIN..."
    RESULT=$(timeout "$TIMEOUT_WPTOOLKIT" wp-toolkit --install \
        -domain-name "$DOMAIN" \
        -set-id "$VISION_SET_ID" 2>&1)
    local EXIT_CODE=$?
    stop_spinner

    if [ $EXIT_CODE -eq 124 ]; then
        log_warn "$DOMAIN — WP Toolkit timeout ${TIMEOUT_WPTOOLKIT}s"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (WP Toolkit timeout)\n"
        return 1
    fi

    if echo "$RESULT" | grep -qi "max.*database\|maximum.*database"; then
        log_error "$DOMAIN — MAX DATABASES REACHED"
        SUMMARY_FAIL="${SUMMARY_FAIL}  - $DOMAIN (max databases)\n"
        return 2  # 2 = หยุด loop ทั้งหมด
    fi

    if [ $EXIT_CODE -ne 0 ]; then
        log_warn "$DOMAIN — WP Toolkit install failed (exit $EXIT_CODE)"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (WP Toolkit failed)\n"
        return 1
    fi

    # เช็ค document root
    local DOCROOT_CHECK
    DOCROOT_CHECK=$(wp-toolkit --info -domain-name "$DOMAIN" -format json 2>/dev/null \
        | grep -o '"path":"[^"]*"' | head -1)
    if ! echo "$DOCROOT_CHECK" | grep -q "public_html/${DOMAIN}"; then
        log_warn "$DOMAIN — document root ไม่ตรง: $DOCROOT_CHECK (ต้องตรวจสอบ)"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (docroot mismatch)\n"
        return 1
    fi

    log_info "WordPress + Vision Set สำเร็จ"
    return 0
}

# ========================== STEP 4-5: SYMLINK + RESTORE =====================

step_restore() {
    local DOMAIN="$1"
    local CPUSER="$2"
    local THEME="$3"
    local DOCROOT="/home/${CPUSER}/public_html/${DOMAIN}"
    local WPRESS_FILE="${THEME}.wpress"

    # เช็ค disk space ก่อน restore
    local DISK_NOW
    DISK_NOW=$(get_disk_free_gb)
    if [ "$DISK_NOW" -lt "$DISK_MIN_RUNTIME_GB" ]; then
        log_error "Disk free ${DISK_NOW}GB < ${DISK_MIN_RUNTIME_GB}GB — หยุดทั้งหมด"
        SUMMARY_FAIL="${SUMMARY_FAIL}  - $DOMAIN (disk space critical: ${DISK_NOW}GB)\n"
        return 2
    fi

    # Step 4: Symlink
    log_step "Step 4: Symlink .wpress"
    mkdir -p "$DOCROOT/wp-content/ai1wm-backups"
    chown "${CPUSER}:${CPUSER}" "$DOCROOT/wp-content/ai1wm-backups"
    ln -sf "${TEMPLATE_DIR}/${WPRESS_FILE}" "$DOCROOT/wp-content/ai1wm-backups/"

    if [ ! -L "$DOCROOT/wp-content/ai1wm-backups/${WPRESS_FILE}" ]; then
        log_warn "$DOMAIN — symlink สร้างไม่ได้"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (symlink failed)\n"
        return 1
    fi

    # Step 5: Restore
    log_step "Step 5: AI1WM Restore ($WPRESS_FILE)"
    local RESULT
    start_spinner "Restoring $DOMAIN..."
    RESULT=$(timeout "$TIMEOUT_RESTORE" sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" \
        ai1wm restore "$WPRESS_FILE" --path="$DOCROOT" 2>&1)
    local EXIT_CODE=$?
    stop_spinner

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
        return 0
    fi

    log_warn "$DOMAIN — restore result unclear"
    SUMMARY_WARN="${SUMMARY_WARN}  - $DOMAIN (restore result unclear)\n"
    return 0
}

# ========================== STEP 6: CLEANUP =================================

step_cleanup() {
    local DOMAIN="$1"
    local CPUSER="$2"
    local QC_CF_EMAIL="$3"
    local QC_TOKEN="$4"
    local CF_TOKEN="$5"
    local DOCROOT="/home/${CPUSER}/public_html/${DOMAIN}"

    log_step "Step 6: Cleanup"

    # 6.1 ลบ symlink + ai1wm-backups
    rm -f "$DOCROOT/wp-content/ai1wm-backups/"*.wpress 2>/dev/null
    rm -rf "$DOCROOT/wp-content/ai1wm-backups/" 2>/dev/null

    # 6.2 ลบ plugins (hello, akismet, all-in-one-wp-migration)
    sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" plugin deactivate \
        hello akismet all-in-one-wp-migration \
        --path="$DOCROOT" 2>/dev/null
    sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" plugin delete \
        hello akismet all-in-one-wp-migration \
        --path="$DOCROOT" 2>/dev/null
    log_info "6.2 ลบ plugins เสร็จ"

    # 6.3 ลบ default themes (เก็บ active + parent + ใหม่สุด)
    local ACTIVE_THEME
    ACTIVE_THEME=$(sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" theme list \
        --path="$DOCROOT" --status=active --field=name 2>/dev/null)

    local PARENT_THEME
    PARENT_THEME=$(sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" theme list \
        --path="$DOCROOT" --status=parent --field=name 2>/dev/null)

    # หา default theme ใหม่สุด
    local LATEST_DEFAULT=""
    local LATEST_NUM=0
    local ALL_THEMES
    ALL_THEMES=$(sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" theme list \
        --path="$DOCROOT" --field=name 2>/dev/null)

    while read -r T; do
        local NUM
        NUM=$(theme_to_num "$T")
        if [ "$NUM" -gt "$LATEST_NUM" ]; then
            LATEST_NUM=$NUM
            LATEST_DEFAULT=$T
        fi
    done <<< "$ALL_THEMES"

    # ลบ default themes ที่ไม่ใช่ active + parent + ใหม่สุด
    local THEMES_TO_DELETE=""
    while read -r T; do
        local NUM
        NUM=$(theme_to_num "$T")
        if [ "$NUM" -gt 0 ]; then
            if [ "$T" != "$ACTIVE_THEME" ] && [ "$T" != "$PARENT_THEME" ] && [ "$T" != "$LATEST_DEFAULT" ]; then
                THEMES_TO_DELETE="$THEMES_TO_DELETE $T"
            fi
        fi
    done <<< "$ALL_THEMES"

    if [ -n "$THEMES_TO_DELETE" ]; then
        sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" theme delete \
            $THEMES_TO_DELETE --path="$DOCROOT" 2>/dev/null
        log_info "6.3 ลบ themes:$THEMES_TO_DELETE"
    else
        log_info "6.3 ไม่มี theme ต้องลบ"
    fi

    # 6.4 Freemius clone resolve
    sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" config set \
        FS__RESOLVE_CLONE_AS long_term_duplicate \
        --type=constant --path="$DOCROOT" 2>/dev/null
    log_info "6.4 Freemius clone resolve เสร็จ"

    # 6.5 QUIC.cloud init + link
    sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" litespeed-online init \
        --path="$DOCROOT" 2>/dev/null
    log_info "6.5 QUIC.cloud init เสร็จ"

    if [ -n "$QC_CF_EMAIL" ] && [ -n "$QC_TOKEN" ]; then
        sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" litespeed-online link \
            --email="$QC_CF_EMAIL" \
            --api-key="$QC_TOKEN" \
            --path="$DOCROOT" 2>/dev/null
        log_info "6.5 QUIC.cloud link เสร็จ ($QC_CF_EMAIL)"
    elif [ -n "$QC_CF_EMAIL" ]; then
        log_warn "6.5 QUIC token ว่าง สำหรับ $QC_CF_EMAIL"
        SUMMARY_WARN="${SUMMARY_WARN}  - $DOMAIN (QUIC token empty for $QC_CF_EMAIL)\n"
    fi

    # 6.6 Cloudflare API setup
    if [ -n "$CF_TOKEN" ] && [ -n "$QC_CF_EMAIL" ]; then
        log_step "6.6 Cloudflare API setup"

        # ใส่ค่าทั้งหมด (ทับของเก่าทันที)
        sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" litespeed-option set cdn-cloudflare 1 --path="$DOCROOT" 2>/dev/null
        sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" litespeed-option set cdn-cloudflare_key "$CF_TOKEN" --path="$DOCROOT" 2>/dev/null
        sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" litespeed-option set cdn-cloudflare_email "$QC_CF_EMAIL" --path="$DOCROOT" 2>/dev/null
        sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" litespeed-option set cdn-cloudflare_name "$DOMAIN" --path="$DOCROOT" 2>/dev/null
        sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" litespeed-option set cdn-cloudflare_clear 1 --path="$DOCROOT" 2>/dev/null

        # Fetch Zone ID จาก Cloudflare API → ใส่เข้า LiteSpeed
        local ZONE_ID
        ZONE_ID=$(curl -s -X GET \
            "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
            -H "X-Auth-Email: $QC_CF_EMAIL" \
            -H "X-Auth-Key: $CF_TOKEN" \
            -H "Content-Type: application/json" \
            | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

        if [ -n "$ZONE_ID" ]; then
            sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" litespeed-option set cdn-cloudflare_zone "$ZONE_ID" --path="$DOCROOT" 2>/dev/null
            log_info "6.6 Cloudflare setup ครบ — Zone ID: $ZONE_ID"
        else
            log_warn "6.6 Cloudflare setup แต่ Zone ID ไม่เจอ (domain อาจยังไม่อยู่ใน CF)"
            SUMMARY_WARN="${SUMMARY_WARN}  - $DOMAIN (CF Zone ID not found)\n"
        fi
    fi

    # 6.7 Rank Math connect
    # หลัง restore → connection data เก่า decrypt ไม่ได้ (wp-config keys เปลี่ยน)
    # ลบเก่า + เขียนใหม่ด้วย RANKMATH_EMAIL/API_KEY จาก config section ด้านบน
    log_step "6.7 Rank Math connect"
    sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" eval '
        delete_option("rank_math_connect_data");
        $data = [
            "username"  => "'"$RANKMATH_EMAIL"'",
            "email"     => "'"$RANKMATH_EMAIL"'",
            "api_key"   => "'"$RANKMATH_API_KEY"'",
            "plan"      => "'"$RANKMATH_PLAN"'",
            "connected" => 1,
            "site_url"  => "https://'"$DOMAIN"'"
        ];
        \RankMath\Admin\Admin_Helper::get_registration_data($data);
        $v = \RankMath\Admin\Admin_Helper::get_registration_data();
        echo $v ? "connected" : "failed";
    ' --path="$DOCROOT" 2>/dev/null | grep -q "connected" \
        && log_info "6.7 Rank Math connected ($RANKMATH_EMAIL)" \
        || log_warn "6.7 Rank Math connect failed"

    return 0
}

# ========================== STEP 7-8: FLUSH + PURGE =========================

step_flush_purge() {
    local DOMAIN="$1"
    local CPUSER="$2"
    local DOCROOT="/home/${CPUSER}/public_html/${DOMAIN}"

    # Step 7: Flush permalink
    log_step "Step 7: Flush permalink"
    sudo -u "$CPUSER" "$PHP_CLI" "$WP_CLI" rewrite flush --hard \
        --path="$DOCROOT" 2>/dev/null
    if [ $? -ne 0 ]; then
        log_warn "$DOMAIN — flush permalink failed"
        SUMMARY_WARN="${SUMMARY_WARN}  - $DOMAIN (flush permalink failed)\n"
    else
        log_info "Flush permalink เสร็จ"
    fi

    # Step 8: LiteSpeed purge (ลบ files ตรง — ไม่ง้อ DNS)
    log_step "Step 8: LiteSpeed purge"
    rm -rf "$DOCROOT/wp-content/litespeed/" 2>/dev/null
    rm -rf "/home/${CPUSER}/lscache/" 2>/dev/null
    log_info "LiteSpeed purge เสร็จ"

    return 0
}

# ========================== MAIN LOOP =======================================

process_site() {
    local DOMAIN="$1"
    local CPUSER="$2"
    local THEME="$3"
    local QC_CF_EMAIL="$4"
    local QC_TOKEN="$5"
    local CF_TOKEN="$6"
    local SITE_START
    SITE_START=$(date +%s)

    echo ""
    echo "════════════════════════════════════════"
    echo "  [$((COUNT_SUCCESS + COUNT_SKIP + COUNT_FAIL + 1))/$COUNT_TOTAL] $DOMAIN"
    echo "  cPanel: $CPUSER | Theme: $THEME"
    echo "════════════════════════════════════════"

    # ข้าม domain ที่มีอยู่แล้ว
    if grep -q "^${DOMAIN}:" /etc/userdatadomains 2>/dev/null; then
        log_warn "$DOMAIN — มีอยู่แล้ว ข้าม"
        SUMMARY_SKIP="${SUMMARY_SKIP}  - $DOMAIN (already exists)\n"
        COUNT_SKIP=$((COUNT_SKIP+1))
        return 0
    fi

    # Step 1: Create Domain
    step_create_domain "$DOMAIN" "$CPUSER"
    local RC=$?
    [ $RC -eq 2 ] && return 2  # หยุด loop
    [ $RC -ne 0 ] && { COUNT_SKIP=$((COUNT_SKIP+1)); return 0; }

    # Step 2: Wait cPanel
    step_wait_cpanel "$DOMAIN" "$CPUSER"
    [ $? -ne 0 ] && { COUNT_SKIP=$((COUNT_SKIP+1)); return 0; }

    # Step 3: Install WordPress
    step_install_wp "$DOMAIN" "$CPUSER"
    RC=$?
    [ $RC -eq 2 ] && return 2  # หยุด loop
    [ $RC -ne 0 ] && { COUNT_SKIP=$((COUNT_SKIP+1)); return 0; }

    # Step 4-5: Symlink + Restore
    step_restore "$DOMAIN" "$CPUSER" "$THEME"
    RC=$?
    [ $RC -eq 2 ] && return 2  # หยุด loop
    [ $RC -ne 0 ] && { COUNT_SKIP=$((COUNT_SKIP+1)); return 0; }

    # Step 6: Cleanup
    step_cleanup "$DOMAIN" "$CPUSER" "$QC_CF_EMAIL" "$QC_TOKEN" "$CF_TOKEN"

    # Step 7-8: Flush + Purge
    step_flush_purge "$DOMAIN" "$CPUSER"

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
    echo "  สรุปผล — $(date '+%d %b %Y %H:%M')"
    echo "════════════════════════════════════════"
    echo -e "  ${GREEN}✅ สำเร็จ: $COUNT_SUCCESS${NC}"
    echo -e "  ${YELLOW}⚠️ ข้าม: $COUNT_SKIP${NC}"
    echo -e "  ${RED}❌ ล้มเหลว: $COUNT_FAIL${NC}"
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
    local TG_MSG="📊 <b>Daily Web Creation — $(date '+%d %b %Y')</b>
🖥 Server: $(hostname)

✅ สำเร็จ: $COUNT_SUCCESS/$COUNT_TOTAL
⚠️ ข้าม: $COUNT_SKIP
❌ ล้มเหลว: $COUNT_FAIL

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
    # ตรวจ argument
    if [ -z "$1" ]; then
        echo "Usage: $0 /path/to/sites.csv"
        echo ""
        echo "CSV Format: domain,cpanel_user,theme,qc_cf_email,qc_token,cf_token"
        echo "Example:    a1.com,y2026m04ns504,theme-black.store,user@gmail.com,quic_token,cf_global_api_key"
        exit 1
    fi

    CSV_FILE="$1"

    # ตรวจ root
    if [ "$(id -u)" -ne 0 ]; then
        echo "ต้องรันด้วย root"
        exit 1
    fi

    # สร้าง log directory + file (เขียนทับ log วันเดียวกัน)
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/${DATE_TAG}.log"
    echo "========================================" > "$LOG_FILE"
    echo "Start: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    echo "CSV: $CSV_FILE" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"

    # Pre-flight check
    preflight_check
    if [ $? -ne 0 ]; then
        log_error "Pre-flight check failed — ยกเลิก"
        exit 1
    fi

    # Main loop
    while IFS=',' read -r DOMAIN CPUSER THEME QC_CF_EMAIL QC_TOKEN CF_TOKEN; do
        # ข้ามบรรทัดว่าง
        [ -z "$DOMAIN" ] && continue

        # trim whitespace
        DOMAIN=$(echo "$DOMAIN" | xargs)
        CPUSER=$(echo "$CPUSER" | xargs)
        THEME=$(echo "$THEME" | xargs)
        QC_CF_EMAIL=$(echo "$QC_CF_EMAIL" | xargs)
        QC_TOKEN=$(echo "$QC_TOKEN" | xargs)
        CF_TOKEN=$(echo "$CF_TOKEN" | xargs)

        process_site "$DOMAIN" "$CPUSER" "$THEME" "$QC_CF_EMAIL" "$QC_TOKEN" "$CF_TOKEN"
        local RC=$?

        if [ $RC -eq 2 ]; then
            log_error "🔴 หยุด loop ทั้งหมด — critical error"
            COUNT_FAIL=$((COUNT_FAIL+1))
            break
        fi

    done < <(grep '[^[:space:]]' "$CSV_FILE" | tail -n +2)

    # สรุป
    show_summary

    echo "End: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
}

# Run
main "$@"
