# Website-Daily-Create

Bulk WordPress site creation pipeline สำหรับ cPanel/WHM + LiteSpeed + AI1WM

## โครงสร้างไฟล์

```
website-daily-create.sh   ← Script หลัก (ไม่มี credentials)
server-config.conf        ← Server/Account config (กำหนดค่าก่อนรัน)
domains-config.csv        ← รายชื่อ domain (เปลี่ยนทุกวัน)
```

## Quick Start

```bash
curl -s https://raw.githubusercontent.com/AnonymousVS/Website-Daily-Create/main/server-config.conf -o /tmp/server-config.conf && \
curl -s -H "Authorization: token ghp_2A18Rc7JLgqpFaRcqzS97uvzRdUป" \
https://raw.githubusercontent.com/AnonymousVS/config/main/cf-token-Website-Daily-Create.conf -o /tmp/cf-token-Website-Daily-Create.conf && \
curl -s https://raw.githubusercontent.com/AnonymousVS/Website-Daily-Create/main/domains-config.csv -o /tmp/domains-config.csv && \
bash <(curl -s https://raw.githubusercontent.com/AnonymousVS/Website-Daily-Create/main/website-daily-create.sh) /tmp/domains-config.csv
```

ต้องรันด้วย **root** บน server ที่มี cPanel/WHM + LiteSpeed

## ไฟล์ Config

### server-config.conf

เก็บ credentials ทั้งหมดแยกจาก script — **กำหนดค่าให้ถูกต้องก่อนรัน** ทุกครั้ง

```bash
# cPanel User — เว็บจะถูกสร้างใต้ cPanel user นี้
CPANEL_USER="y2026m04ns504"

# QUIC.cloud + Cloudflare — email ใช้ร่วมกัน กำหนดว่าจะใช้บัญชีไหน
QC_CF_EMAIL="your-email@gmail.com"
QC_TOKEN="your-quic-cloud-token"
CF_TOKEN="your-cloudflare-global-api-key"

# Rank Math SEO
RANKMATH_EMAIL="your-rankmath-email@gmail.com"
RANKMATH_API_KEY="your-rankmath-api-key"
RANKMATH_PLAN="pro"

# Telegram Notification
TELEGRAM_BOT_TOKEN="your-bot-token"
TELEGRAM_CHAT_ID="your-chat-id"
```

**เปลี่ยนแปลงตามที่ต้องการ:**
- `CPANEL_USER` — กำหนดว่าจะสร้างเว็บที่ cPanel user ไหน
- `QC_CF_EMAIL` / `QC_TOKEN` — กำหนดว่า QUIC.cloud ใช้บัญชีไหน
- `CF_TOKEN` — กำหนดว่า Cloudflare ใช้ Global API Key ของบัญชีไหน
- ค่าอื่นๆ — กำหนดให้ถูกต้องก่อนรัน

Script ค้นหา `server-config.conf` ตามลำดับ:
1. อยู่ข้างๆ CSV file ที่ส่งมา
2. `/usr/local/etc/website-daily-create/server-config.conf`
3. ถ้าไม่เจอ → หยุดทันที

### domains-config.csv

2 columns: `domain,theme`

```csv
domain,theme
example1.com,theme-black.store
example2.com,theme-blue.store
example3.com,theme-green.store
```

- `domain` — ชื่อ domain ที่จะสร้าง
- `theme` — ชื่อ .wpress template (ตรงกับไฟล์ใน `/usr/local/share/ai1wm-templates/`)

## .wpress Templates

Template files เก็บที่ `/usr/local/share/ai1wm-templates/` บน server:

```
/usr/local/share/ai1wm-templates/
├── theme-black.store.wpress
├── theme-blue.store.wpress
├── theme-red.store.wpress
├── theme-green.store.wpress
└── theme-purple.store.wpress
```

### วิธีตั้งค่า (ครั้งแรกครั้งเดียวต่อ server)

ใช้โปรแกรม **Termius** หรือ **FileZilla** เชื่อมต่อ SFTP เข้า server ด้วย **root**:

1. เปิด SFTP → ไปที่ path `/usr/local/share/`
2. สร้างโฟลเดอร์ `ai1wm-templates`
3. เข้าไปในโฟลเดอร์ `ai1wm-templates`
4. Copy ไฟล์ `.wpress` ต้นแบบแต่ละสีไปวางในนั้น

```
ผลลัพธ์:
/usr/local/share/ai1wm-templates/
├── theme-black.store.wpress
├── theme-blue.store.wpress
├── theme-red.store.wpress
├── theme-green.store.wpress
└── theme-purple.store.wpress
```

ชื่อไฟล์ต้องตรงกับ column `theme` ใน CSV + `.wpress`

**ถ้ามีอัพเดท Theme เวอร์ชันใหม่** — SFTP เข้าไปวางไฟล์ .wpress ใหม่ทับของเดิมในโฟลเดอร์เดียวกัน

> **หมายเหตุ:** ต้อง login SFTP ด้วย root เท่านั้น เพราะ `/usr/local/share/` เป็น system path ที่ cPanel user ไม่มีสิทธิ์เขียน

### โปรแกรม SFTP แนะนำ

- **Termius** (แนะนำ) — รองรับ SFTP มี File Manager ในตัว ใช้ง่าย ลงบน PC/Mac
- **FileZilla** — ฟรี รองรับ SFTP เช่นกัน

## Pipeline Flow

```
Pre-flight:  CSV, commands, PHP CLI, Vision Set, disk, cPanel user, templates, QUIC, Telegram

Step 1:      สร้าง domain (cpapi2 AddonDomain) — ข้ามถ้ามีอยู่แล้ว
Step 2:      รอ cPanel register — ข้ามถ้ามีอยู่แล้ว
Step 3:      WP Toolkit เช็ค + ติดตั้ง WordPress (root, Vision Set)
Step 4:      Copy .wpress → ai1wm-backups
Step 5:      AI1WM restore
Step 6.1:    ลบ plugins (hello, akismet, ai1wm)
Step 6.2:    ลบ default themes เก่า (เก็บ active + parent + ใหม่สุด)
Step 6.3:    แก้ Font CSS URL (auto-detect domain เก่า → sed replace)
Step 6.4:    Freemius clone resolve
Step 6.5:    QUIC.cloud init + link
Step 6.6:    Cloudflare API setup + Zone ID
Step 6.7:    Rank Math connect
Step 6.8:    ลบ Rank Math sitemap cache
Step 7:      LiteSpeed purge + TRUNCATE avatar cache
Step 8:      Flush permalink (wp eval + $GLOBALS["is_apache"]=true)
Step 9:      Activate theme (ขั้นตอนสุดท้าย)
```

## Requirements

- AlmaLinux 9 + cPanel/WHM
- LiteSpeed Enterprise + LiteSpeed Cache plugin
- WP Toolkit (cPanel)
- WP-CLI (`/usr/local/bin/wp`)
- AI1WM v6.77 plugin (อยู่ใน .wpress template)
- .wpress template files ใน `/usr/local/share/ai1wm-templates/`

## Domain ที่มีอยู่แล้ว

ถ้า domain มีอยู่แล้วใน cPanel:
- ข้าม Step 1-2 (สร้าง domain)
- ไปต่อ Step 3 (WP Toolkit) ทันที
- ทำ restore + config ใหม่ทั้งหมด

ใช้สำหรับรันซ้ำเพื่อแก้ปัญหาหรืออัพเดท config ได้

## DNS ยังไม่ Point

**ไม่แนะนำให้รัน** ถ้า DNS ยังไม่ point — อาจติดปัญหาเรื่องการ config ค่าต่างๆ:
- QUIC.cloud link จะ fail (verify domain ไม่ผ่าน)
- Cloudflare Zone ID หาไม่เจอ (domain ยังไม่อยู่ใน Cloudflare)
- เว็บเปิดไม่ได้ (403 / default page)

แต่สามารถ **ทดสอบ ทดลอง และประเมินผลลัพธ์** ได้เลย — script จะ log warning แล้วทำต่อไม่หยุด

## ขั้นตอนที่ต้องทำ Manual หลัง Script สร้างเว็บเสร็จ

Script ทำ config อัตโนมัติได้ถึง Step 9 — ขั้นตอนต่อไปนี้ต้องทำเองผ่าน Browser:

### 1. เปลี่ยน Logo (Header + Footer)
- เข้า wp-admin → Appearance → Customize → Header / Footer
- อัพโหลดรูป Logo ใหม่ทั้ง Header และ Footer

### 2. ตั้งค่า Cloudflare (นอกเหนือ API)
- ค่าบางตัวที่ยังเป็น Beta ต้องตั้งค่าเองใน Cloudflare Dashboard
- เช่น Speed, Caching Rules, Page Rules ที่ API ยังไม่รองรับ

### 3. Google Search Console
- Add Property → เพิ่ม domain ใน GSC
- เพิ่ม Sitemap (`/sitemap_index.xml`)
- เพิ่มสิทธิ์ Looker Studio (ถ้าต้องการดู report)

### 4. ลบ User เก่า + สร้าง User ใหม่
- เข้า wp-admin → Users → ลบ user เดิมที่มากับ WP Toolkit
- Add New User → ตั้งชื่อคนไทย + role Administrator
- นำ Password ไปบันทึกใน Google Sheets

### 5. เปลี่ยน Title ที่ Front Page
- เข้า wp-admin → Pages → Front Page → แก้ Title

### 6. ตั้ง Site Title
- เข้า wp-admin → Settings → General → Site Title

## Log

Log เก็บที่ `/var/log/website-daily-create/` แยกตามวันที่:

```
/var/log/website-daily-create/
├── 2026-04-01.log
├── 2026-04-02.log
└── 2026-04-04.log
```

สรุปผลส่ง Telegram อัตโนมัติหลังรันเสร็จ

## Error Handling

| ระดับ | สถานการณ์ | ผล |
|-------|----------|-----|
| หยุด loop | disk < 5GB, max addon, max DB | หยุดทันทีป้องกัน server เต็ม |
| ข้ามเว็บ | WP Toolkit fail, restore fail | ข้ามเว็บนี้ ทำเว็บถัดไป |
| warning | flush fail, CF Zone ไม่เจอ, Rank Math fail | แจ้งเตือน ทำต่อ |

## Version History

| Version | เปลี่ยนอะไร |
|---------|------------|
| 2.5.3 | Production: activate theme สุดท้าย, เปิด 6.2 ลบ themes, ลบ debug code |
| 2.5.2 | Debug: theme check ทุก step, Step 9 monitor 30 วิ |
| 2.5.0 | ย้าย activate theme หลัง cleanup, TRUNCATE litespeed_avatar |
| 2.4.0 | แยก 3 ไฟล์: script + server-config.conf + CSV 2 columns |
| 2.3.0 | Font CSS auto-detect, Rank Math fix, wp eval flush |
| 2.0.0 | Copy method, suppress deprecated, fix CF Zone ID |
