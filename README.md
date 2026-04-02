# Website-Daily-Create

Bulk WordPress Site Creation Pipeline — สร้างเว็บ WordPress จาก .wpress template พร้อมตั้งค่า QUIC.cloud, Cloudflare, Rank Math อัตโนมัติ

## คำสั่งรัน
```bash
curl -s https://raw.githubusercontent.com/AnonymousVS/Website-Daily-Create/main/domains-config.csv -o /tmp/domains-config.csv && bash <(curl -s https://raw.githubusercontent.com/AnonymousVS/Website-Daily-Create/main/website-daily-create.sh) /tmp/domains-config.csv
```

```bash
# ติดตั้ง (ครั้งเดียว)
curl -s https://raw.githubusercontent.com/AnonymousVS/Website-Daily-Create/main/website-daily-create.sh \
  -o /usr/local/sbin/website-daily-create.sh && chmod +x /usr/local/sbin/website-daily-create.sh

# อัพเดท script
curl -s https://raw.githubusercontent.com/AnonymousVS/Website-Daily-Create/main/website-daily-create.sh \
  -o /usr/local/sbin/website-daily-create.sh

# รัน — ดึง CSV จาก GitHub
curl -s https://raw.githubusercontent.com/AnonymousVS/Website-Daily-Create/main/domains-config.csv \
  -o /tmp/today.csv && website-daily-create.sh /tmp/today.csv

# รัน — ใช้ CSV ใน server
website-daily-create.sh /path/to/domains-config.csv
```

## CSV Format (6 columns)

```csv
domain,cpanel_user,theme,qc_cf_email,qc_token,cf_token
a1.com,y2026m04ns504,theme-black.store,user@gmail.com,quic_api_token,cf_global_api_key
```

| Column | คำอธิบาย |
|--------|----------|
| `domain` | ชื่อ domain ที่จะสร้าง |
| `cpanel_user` | cPanel username ที่จะเพิ่ม addon domain |
| `theme` | ชื่อ .wpress template (ไม่ต้องใส่ .wpress) |
| `qc_cf_email` | Email ใช้ร่วมกันทั้ง QUIC.cloud + Cloudflare |
| `qc_token` | QUIC.cloud API Token |
| `cf_token` | Cloudflare Global API Key |

## Pipeline — ทำอะไรบ้าง

```
Step 1:   สร้าง Addon Domain (cpapi2)
Step 2:   รอ cPanel register domain + สร้าง directory
Step 3:   ติดตั้ง WordPress ผ่าน WP Toolkit + Vision Set
Step 4:   Symlink .wpress template เข้า ai1wm-backups/
Step 5:   AI1WM Restore ผ่าน WP-CLI (PHP CLI ตรง)
Step 6.1: ลบ symlink + ai1wm-backups/
Step 6.2: ลบ plugins (hello, akismet, all-in-one-wp-migration)
Step 6.3: ลบ default themes เก่า (เก็บ active + parent + ใหม่สุด)
Step 6.4: Freemius clone resolve (Blocksy Companion)
Step 6.5: QUIC.cloud init + link
Step 6.6: Cloudflare API setup + fetch Zone ID
Step 6.7: Rank Math SEO connect
Step 7:   Flush permalink (wp rewrite flush --hard)
Step 8:   LiteSpeed cache purge
```

## Config ใน Script

แก้ไขค่าต่างๆ ที่ส่วนบนของ `website-daily-create.sh`:

```bash
# --- Telegram Notification ---
TELEGRAM_BOT_TOKEN="xxx"
TELEGRAM_CHAT_ID="xxx"

# --- Rank Math SEO (ใช้ค่าเดียวกันทุกเว็บ) ---
RANKMATH_EMAIL="email@gmail.com"       # Rank Math account email
RANKMATH_API_KEY="xxx"                 # Rank Math API Key
RANKMATH_PLAN="pro"                    # free / pro / business / agency
```

## .wpress Templates

วางไฟล์ .wpress ที่ `/usr/local/share/ai1wm-templates/`:

```
/usr/local/share/ai1wm-templates/
├── theme-black.store.wpress
├── theme-blue.store.wpress
├── theme-green.store.wpress
├── theme-purple.store.wpress
└── theme-red.store.wpress
```

## Pre-flight Check (12 ข้อ)

Script ตรวจสอบทุกอย่างก่อนเริ่ม:

1. CSV file มีอยู่ + format ถูกต้อง + ไม่มี domain ซ้ำ
2. Commands พร้อม (cpapi2, wp-toolkit, wp-cli)
3. PHP CLI auto-detect (`/opt/cpanel/ea-php*/root/usr/bin/php`)
4. Vision Set auto-detect (หาจากชื่อ "Vision Set")
5. Disk space > 30 GB
6. cPanel users มีอยู่จริง
7. .wpress templates มีครบ
8. QUIC.cloud credentials ใน CSV ครบ
9. Telegram bot ใช้งานได้
10. Domains ที่มีอยู่แล้ว → แจ้งเตือน
11. แสดงสรุป → รอกด y ก่อนเริ่ม

## Error Handling

| ระดับ | สิ่งที่เกิด | การจัดการ |
|-------|------------|----------|
| 🔴 หยุด loop | Disk < 5GB, Max addon domains, Max databases | หยุดทันที แจ้ง Telegram |
| ⚠️ ข้ามเว็บ | Domain exists, WP Toolkit fail, Restore fail | ข้ามไปเว็บถัดไป |
| 🟡 Warning | Flush fail, Purge fail, CF Zone not found | แจ้ง Telegram ตอนสรุป |

## ระยะเวลา

~107 วินาที/เว็บ × 36 เว็บ = ~64 นาที/วัน → 1,080 เว็บ/เดือน

## Requirements

- AlmaLinux 9 + cPanel/WHM
- LiteSpeed Enterprise + LiteSpeed Cache plugin
- WP Toolkit (Vision Set ต้องตั้งไว้แล้ว)
- AI1WM v6.77 patched (ติดตั้งใน .wpress template)
- Rank Math SEO plugin (ติดตั้งใน .wpress template)
- Blocksy theme + Companion (ติดตั้งใน .wpress template)

## Log Files

```
/var/log/website-daily-create/
└── 2026-04-03.log
```
