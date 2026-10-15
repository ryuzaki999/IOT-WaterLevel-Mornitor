# IoT Water Level Monitor (Water Tank IoT)

แอปพลิเคชันตรวจสอบระดับน้ำและการไหลของน้ำผ่านอุปกรณ์ IoT
ประกอบด้วย **แอป Flutter** (มือถือ/Web) + **บอร์ด ESP32** + **Firebase Realtime Database**

## โครงสร้างโปรเจค

```
lib/
├── main.dart                 # หน้าตั้งค่าขนาดถังน้ำ (เลือกขนาด/กำหนดเอง)
├── watertank.dart            # หน้าแสดงระดับน้ำแบบ realtime + แท็บหลัก
├── history.dart              # หน้าประวัติการใช้น้ำ (รายวัน/เดือน/ปี)
├── notification.dart         # หน้าการแจ้งเตือน (อ่านข้อมูลมาแสดง)
├── notification_service.dart # เขียนการแจ้งเตือนลง Firebase + ตัวเฝ้าดูเกณฑ์น้ำ
├── ai_page.dart              # หน้าผู้ช่วย AI วิเคราะห์การใช้น้ำ
├── gemini_client.dart        # ตัวเรียก Gemini REST API (generateContent)
├── water_context.dart        # รวมข้อมูลจาก Firebase เป็นบริบทให้ AI
└── firebase_options.dart     # ค่า config Firebase (Web/Android)

HC-SR04device.txt           # โค้ด Arduino/ESP32 (วัดระดับน้ำด้วย ultrasonic + OLED)
android/                    # โปรเจค Android
web/                        # โปรเจค Web
```

## ข้อมูล Firebase (Realtime Database)

- Project: `water-tank-iot-8c113`
- Database URL: `https://water-tank-iot-8c113-default-rtdb.asia-southeast1.firebasedatabase.app`
- Schema หลักอยู่ใต้ `/water_system`:
  - `monitor/water_level_liters`, `monitor/flow_rate_min` ← ESP32 เขียน
  - `setting/tank_depth`, `setting/tank_capacity` ← แอปเขียน / ESP32 อ่าน
  - `history/{yyyy-MM-dd}/used_liters` ← ข้อมูลน้ำที่ใช้รายวัน
  - `notifications/{id}` ← การแจ้งเตือน (ดูโครงสร้างด้านล่าง)
  - `notification_state/{level|flow}` ← สถานะล่าสุดที่เคยแจ้งเตือน (กันแจ้งซ้ำ)

### โครงสร้างการแจ้งเตือน 1 รายการ

```json
{
  "title": "น้ำในถังอยู่ในระดับวิกฤต",
  "message": "เหลือน้ำ 45 ลิตร (11% ของถัง) กรุณาเติมน้ำเข้าถังโดยเร็วที่สุด",
  "type": "critical",
  "timestamp": 1767000000000,
  "is_read": false
}
```

`type` มี 3 ค่า: `critical` (แดง) / `warning` (ส้ม) / `info` (ฟ้า)
`timestamp` เป็น milliseconds — แอปเขียนด้วย `ServerValue.timestamp` (เวลาจากเซิร์ฟเวอร์)
ฝั่ง ESP32 เขียนด้วย `millis()` ของตัวเองได้เช่นกัน

---

## วิธีรันแอป Flutter

### สิ่งที่ต้องติดตั้ง (เตรียมไว้แล้วในเครื่องนี้)

| เครื่องมือ | ตำแหน่ง |
|---|---|
| Flutter SDK 3.47.2 | `C:\flutter` |
| Android SDK (cmdline-tools 12.0) | `C:\Android` |
| JDK 21 | `C:\Program Files\Eclipse Adoptium\jdk-21.0.10.7-hotspot` |
| AVD (emulator) | ชื่อ `flutter_emulator` (Pixel 7, Android API 36) |

> หมายเหตุ: ถ้ายังไม่เพิ่ม `C:\flutter\bin` ใน PATH ให้เรียก flutter ด้วย path เต็ม:
> `C:\flutter\bin\flutter.bat`

### 1) รันบน Chrome (Web) — เร็วสุด

```bat
cd C:\MyProject\IOT-WaterLevel-Mornitor
C:\flutter\bin\flutter.bat run -d chrome
```

หรือ build เป็น static แล้ว serve เอง:

```bat
cd C:\MyProject\IOT-WaterLevel-Mornitor
C:\flutter\bin\flutter.bat build web
python -m http.server 8080 --directory build\web
:: แล้วเปิด http://localhost:8080 ใน browser
```

### 2) รันบน Android Emulator

```bat
:: 1. เปิด emulator (ถ้ายังไม่เปิด)
C:\Android\emulator\emulator.exe -avd flutter_emulator

:: 2. รอให้ boot เสร็จ (เช็คด้วย)
C:\Android\platform-tools\adb.exe devices

:: 3. รันแอป
cd C:\MyProject\IOT-WaterLevel-Mornitor
C:\flutter\bin\flutter.bat run -d emulator-5554
```

> ถ้าเครื่องตั้ง PATH ไว้แล้ว ใช้ `flutter run` สั้น ๆ ได้เลย

### ตัวแปร environment ที่ใช้ (สำหรับการ build Android)

```bat
set JAVA_HOME=C:\Program Files\Eclipse Adoptium\jdk-21.0.10.7-hotspot
set ANDROID_HOME=C:\Android
set ANDROID_SDK_ROOT=C:\Android
```

---

## 🤖 ผู้ช่วย AI วิเคราะห์การใช้น้ำ (Google Gemini)

แท็บ **AI** (เมนูล่างอันที่ 4) เป็นผู้ช่วยที่อ่านข้อมูลจริงจาก Firebase
แล้วส่งให้ Gemini วิเคราะห์เป็นภาษาไทย

### ตั้งค่า API Key (จำเป็น)

สมัครคีย์ฟรีได้ที่ https://aistudio.google.com/apikey แล้วรันแอปแบบนี้

> ⚠️ **ห้าม hardcode คีย์ลงในซอร์สโค้ดเด็ดขาด** — `lib/gemini_client.dart` อ่านค่า
> จาก `--dart-define` เท่านั้น ถ้าเขียนคีย์ลงไปตรงๆ แล้ว push ขึ้น GitHub
> (โดยเฉพาะ repo แบบ public) GitHub push protection จะบล็อกการ push ทันที
> และถ้าหลุดไปได้ คีย์จะถูกใช้งานโดยคนอื่นได้ทันที
>
> ถ้าอยากแจกแอปให้คนอื่นใช้โดยไม่ต้องตั้งค่าเอง ให้ build ไฟล์แจกจ่าย (APK/Web)
> ด้วยคำสั่ง `--dart-define` ข้างล่างนี้ครั้งเดียวที่เครื่องคุณ แล้วส่ง**ไฟล์ที่
> build เสร็จแล้ว** ให้คนอื่น (ไม่ใช่ส่งซอร์สโค้ด) — คีย์จะถูกคอมไพล์ติดไปกับ
> ไฟล์แอปเท่านั้น ไม่ติดไปกับโค้ดที่ push ขึ้น git

```bat
cd C:\MyProject\IOT-WaterLevel-Mornitor
C:\flutter\bin\flutter.bat run -d chrome --dart-define=GEMINI_API_KEY=คีย์ของคุณ
```

หรือสร้างไฟล์ `env.json` ไว้ที่ root โปรเจค (ถูก `.gitignore` ไว้แล้ว)

```json
{
  "GEMINI_API_KEY": "<คีย์ของคุณจาก AI Studio>",
  "GEMINI_MODEL": "gemini-2.5-flash"
}
```

แล้วรัน

```bat
C:\flutter\bin\flutter.bat run -d chrome --dart-define-from-file=env.json
```

### โมเดลที่ใช้

แอปล็อกเป็นโมเดลเดียวคือ `gemini-2.5-flash` — ดีที่สุดในกลุ่มฟรี และแอปปิดโหมดคิดให้อัตโนมัติ
จึงไม่เปลืองโทเคนตอนวิเคราะห์อัตโนมัติ ผู้ใช้ไม่ต้องเลือกโมเดลเองแล้ว
ถ้าต้องการเปลี่ยน กำหนดได้ตอนรันแอปด้วย `--dart-define=GEMINI_MODEL=...` เท่านั้น

> 💡 โควต้าฟรีของ Gemini นับเป็น **"จำนวนคำขอต่อวัน"** ไม่ใช่จำนวนโทเคน
> ตัวที่ทำให้โควต้าหมดจึงเป็น "จำนวนครั้งที่เรียก" (ดูหัวข้อ ⛽ ด้านล่าง)
> ถ้ายังไม่พอ ให้ใช้ `gemini-2.5-flash-lite` ซึ่งเพดานคำขอต่อวันสูงกว่า
> (`{"GEMINI_MODEL": "gemini-2.5-flash-lite"}` ใน `env.json`)

> 📌 โมเดลรุ่นใหม่นับ **"โทเคนที่ใช้คิด"** รวมอยู่ในเพดาน `maxOutputTokens` ด้วย
> ถ้าตั้งเพดานต่ำ (เช่น 1024) คำตอบจะถูกตัดกลางประโยคโดยไม่ขึ้น error
> แอปจึงตั้งไว้ที่ 4096 และสั่ง `thinkingBudget: 0` ให้ตระกูล 2.5 flash

> ⚠️ API Key ถูกฝังในตัวแอปตอน compile (ผ่าน `--dart-define`) จึงเหมาะกับโครงงาน
> ถ้าจะขึ้นระบบจริงควรเรียก Gemini ผ่าน backend ของตัวเอง เพื่อไม่ให้คีย์หลุด

### หน้านี้ทำอะไรได้

แท็บ AI เป็น **แดชบอร์ดวิเคราะห์** (ไม่มีช่องพิมพ์คำถามแล้ว) พอเปิดหน้าครั้งแรก
และมีข้อมูลจากเซ็นเซอร์ ระบบจะสั่งให้ Gemini วิเคราะห์ให้อัตโนมัติ
แล้ววิเคราะห์ซ้ำให้เองเมื่อ **ข้อมูลเปลี่ยน** และ **อย่างน้อยทุก 1 ชั่วโมง**

- **การ์ด "AI วิเคราะห์การใช้น้ำ"** ด้านบน: แสดง **ประโยคสรุปบรรทัดเดียว** ที่คำนวณจากข้อมูลเซ็นเซอร์เอง (ไฮไลต์ตัวเลขเป็นสีส้ม)
  ตัวอย่าง: `น้ำที่เหลือ 1485 ลิตร (74.3%) เพียงพอใช้ได้อีกประมาณ 25 วัน หากใช้น้ำในอัตราเดิม`
  (คำนวณจาก `capacity` / `water_level_liters` / `estimatedDaysRemaining` — ได้ผลคงที่ ไม่ต้องรอ AI)
  ถ้าข้อมูลวันเต็มวันยังไม่ครบเกณฑ์ (ดูหัวข้อ **ค่าเฉลี่ยการใช้น้ำต่อวัน**) จะขึ้นว่า
  `… สถานะปัจจุบัน: ปกติ • ยังประเมินจำนวนวันไม่ได้ (ข้อมูล 1/3 วัน)` แทนการเดาตัวเลข
- **การ์ดสถิติ 2 ใบ**: น้ำที่ใช้ได้อีกกี่วัน และค่าเฉลี่ยลิตร/วัน — มีบรรทัดเล็กกำกับที่มาของตัวเลข
  (`จากวันเต็มวัน N วัน` หรือ `ข้อมูลยังไม่พอ N/3 วัน` เมื่อยังประเมินไม่ได้)
- **การ์ด "คาดการณ์จาก AI"** กราฟแท่งแนวตั้ง 5 วัน (วันที่จริง + เปอร์เซ็นต์ + สีตามระดับความเสี่ยง + แบนเนอร์เวลาที่คาดว่าน้ำจะหมด + ข้อความแนวโน้มจาก AI)
  ตัวเลขทุกตัว **"ยึดค่าเฉลี่ยการใช้น้ำ"** ล้วน ๆ — เปอร์เซ็นต์และระดับความเสี่ยงคำนวณจากสูตรระบบ (ลดเชิงเส้น `averageDailyLiters ÷ capacity × 100 ต่อวัน`) และวันหมดคำนวณจาก `estimatedDaysRemaining`
  จึงสอดคล้องกับจำนวนวันคงเหลือและการ์ดค่าเฉลี่ยเสมอ ส่วน AI ให้เฉพาะ **ข้อความเหตุผลสั้น ๆ** ของแต่ละวัน (ใช้เป็นข้อความแนวโน้ม) — ตรรกะอยู่ที่ `averageDrivenForecast` ใน `lib/ai_reply.dart`
- **การ์ด "สรุปการใช้น้ำ"** แสดงตลอด (เว้นแต่ยังไม่มีข้อมูลจากเซ็นเซอร์) — เป็นกล่องประโยคสรุป **บรรทัดเดียว** รูปแบบ
  `น้ำในถังเหลือ <เปอร์เซ็นต์>% (<ลิตร> ลิตร) ใช้ได้อีก ~<วัน> วัน — <คำแนะนำ>`
  (ถ้ายังไม่มีค่าเฉลี่ยที่เชื่อถือได้ ส่วน `ใช้ได้อีก ~<วัน> วัน` จะถูกตัดออก เหลือแค่ประโยคสถานะ + คำแนะนำ)
  โดย `<คำแนะนำ>` เหลือแค่ **2 แบบตามเกณฑ์ 70%**: **70–100% → "ใช้น้ำได้ตามปกติ"** และ **0–69% → "กรุณาใช้น้ำแบบประหยัด"**
  (สี/ไอคอนของการ์ดยังแยกระดับน้ำให้เห็นชัด ≤ 25% แดง / < 70% ส้ม / ≥ 70% เขียว — ตรรกะอยู่ที่ `lib/water_tips.dart`)
  ส่วน **คำแนะนำ `[คำแนะนำ]` ของ AI** ยังถูกบันทึกที่ `water_system/ai_state` (`last_tips`) แต่ไม่นำมาแสดงต่อท้ายประโยคนี้แล้ว
- ดึงลง (pull to refresh) เพื่อสั่งวิเคราะห์ใหม่เองได้ (กันกดรัว ๆ 60 วินาที)

### 📅 ค่าเฉลี่ยการใช้น้ำต่อวัน (`averageDailyLiters`)

ตัวเลขนี้เป็น **ฐานของทุกการประเมิน** (จำนวนวันคงเหลือ / กราฟ 5 วัน / แบนเนอร์เวลาน้ำหมด) จึงนิยามไว้ชัดเจน:

| เรื่อง | กติกา |
| --- | --- |
| แหล่งข้อมูล | `water_system/history/{yyyy-MM-dd}/used_liters` (เฉพาะคีย์ที่เป็นวันที่) |
| นับวันไหน | **"วันเต็มวัน" = วันก่อนวันนี้เท่านั้น** — วันนี้ยังสะสมไม่จบวัน และวันในอนาคต (ถ้ามีข้อมูลหลุดมา) ถูกตัดออก |
| สูตร | `averageDailyLiters = Σ used_liters ของวันเต็มวัน ÷ จำนวนวันเต็มวัน` |
| เกณฑ์เชื่อถือ | ต้องมีวันเต็มวัน ≥ **`kMinFullDaysForAverage` = 3 วัน** (`lib/water_context.dart`) |
| ยังไม่ครบเกณฑ์ | `hasReliableAverage` = false → `estimatedDaysRemaining` = **null** → การ์ดขึ้น `--` / "ข้อมูลยังไม่พอ N/3 วัน" และกราฟนิ่งที่เปอร์เซ็นต์ปัจจุบัน (ไม่เดาตัวเลข) |
| วันที่ใช้น้ำน้อยผิดปกติ | ยังนับเป็น 1 วันเต็มวัน (ถ้าต้องการกรองวันทดสอบออก ให้เพิ่มเงื่อนไข `used_liters < ε` ที่ลูปใน `parseSnapshot`) |

> ❓ ทำไมเดิมเห็น "1.9 ลิตร/วัน" — เพราะประวัติมีแค่ **วันนี้** วันเดียว และวันนี้ใช้น้ำไปแค่ 1.9 ลิตรตอนเช้า → `1.9 ÷ 1 = 1.9`
> ทำให้ระบบประเมินว่า "น้ำเหลือใช้ได้อีก 781 วัน" (misleading) ตอนนี้ค่าที่มาจากวันเดียว/ไม่ครบ 3 วันจะ **ไม่ถูกใช้ประเมินเลย**

### ⛽ ทำไมคำขอ Gemini ถึงไม่พุ่งจนโควต้าหมด (429)

`watertank.dart` วางทุกหน้าไว้ใน `IndexedStack` หน้า AI จึงถูก mount ค้างไว้
ตลอดอายุแอป ไม่ถูก dispose ตอนสลับแท็บ และบน Flutter Web ทุกแท็บที่เปิดค้าง
หรือทุกรอบ hot restart จะสร้างอินสแตนซ์ใหม่ ถ้าให้แต่ละอินสแตนซ์ยิงเอง
จำนวนคำขอจะพุ่งเกินโควต้าฟรีของ Gemini API ในไม่ช้า

แอปจึงถามเงื่อนไขก่อนยิงทุกครั้ง — ตรรกะรวมอยู่ที่ **`lib/ai_policy.dart`**
(ฟังก์ชันล้วน ไม่พึ่ง Flutter/Firebase จึงเทสต์ได้)

| ตัวกัน | ค่า | ค่าคงที่ |
|---|---|---|
| ยิงอัตโนมัติห่างกันอย่างน้อย | 60 นาที | `kAiAutoIntervalMinutes` |
| ต้องมีอะไรเปลี่ยนก่อนจึงจะยิง | เปอร์เซ็นต์ ≥ 1% / อัตราไหล ≥ 0.05 ลิตร/นาที | `kAiPercentEpsilon`, `kAiFlowEpsilonLpm` |
| กันดึงลงเพื่อรีเฟรชรัว ๆ | 60 วินาที | `kAiManualCooldownSeconds` |
| รอบที่แอปตื่นมาเช็คเงื่อนไข | 5 นาที (ไม่ใช่รอบยิง) | `kAiTickMinutes` |
| หยุดตัวจับเวลาเมื่อผู้ใช้ไม่ได้อยู่แท็บ AI | `AiPage(isActive: ...)` | — |

- สถานะการยิงล่าสุดเก็บที่ **`water_system/ai_state`**
  (`last_attempt_at`, `last_success_at`, `last_percent`, `last_flow`,
  `last_narrative`, `last_tips`)
  ทุกแท็บ/ทุกอุปกรณ์จึงใช้สถานะร่วมกัน → เปิดซ้ำหรือรีสตาร์ทก็ไม่ยิงซ้ำ
- เวลาที่บันทึกใช้ `ServerValue.timestamp` ของ Firebase เหมือนระบบแจ้งเตือน
  และในเซสชันเดียวกันจะใช้เวลาของเครื่องเทียบด้วย (`lastAttemptLocal`)
  เพื่อกันกรณีนาฬิกาเครื่องกับเซิร์ฟเวอร์ไม่ตรงกัน
- ถ้ายังไม่ถึงเงื่อนไข แอปจะ **ไม่เรียกเน็ตเลย** (ประหยัดโควตา) และเด้ง SnackBar
  บอกเหตุผลสั้น ๆ เช่น "ข้อมูลน้ำยังไม่เปลี่ยนจากครั้งล่าสุด"
  โดยการ์ดต่าง ๆ ยังแสดงผลวิเคราะห์ล่าสุดที่โหลดจาก `water_system/ai_state`
  (`last_tips`, `last_forecast`) ได้ตามปกติ
- อยากลดจำนวนคำขอต่อวันลงอีก: ตั้ง `GEMINI_MODEL=gemini-2.5-flash-lite`
  ใน `env.json` (โควต้าฟรีต่อวันสูงกว่า `gemini-2.5-flash`)

### ไฟล์ที่เกี่ยวข้อง

| ไฟล์ | หน้าที่ |
|---|---|
| `lib/ai_page.dart` | แดชบอร์ด AI: ประโยคสรุปบรรทัดเดียว + การ์ดสถิติ + การ์ดคาดการณ์จาก AI + การ์ด "สรุปการใช้น้ำ" (เกณฑ์ระดับน้ำรวมเป็นประโยคเดียว) + อ่าน/เขียนสถานะ `water_system/ai_state` |
| `lib/ai_reply.dart` | แยกคำตอบดิบของ AI ออกเป็น [สรุป] / [คาดการณ์] / [คำแนะนำ] + ตรวจความถูกต้อง + สูตร fallback + ป้ายวันที่ (ฟังก์ชันล้วน → เทสต์ได้) |
| `lib/ai_policy.dart` | เงื่อนไขว่าจะเรียก Gemini ไหม (ครบเวลา + ข้อมูลเปลี่ยน + cooldown) + ข้อความอธิบายเหตุผล + สกีมาของ `water_system/ai_state` |
| `lib/gemini_client.dart` | เรียก `POST /v1beta/models/{model}:generateContent` ผ่าน `http` |
| `lib/water_context.dart` | อ่าน Firebase แล้วสรุปเป็นข้อความบริบทให้ AI |
| `lib/water_tips.dart` | ระบบผู้เชี่ยวชาญตามเกณฑ์: สร้างประโยคสรุป 2 แบบตามเกณฑ์ 70% (ต่ำกว่า 70% = ประหยัด / ตั้งแต่ 70% = ปกติ) ใช้เป็นประโยคท้ายการ์ด "สรุปการใช้น้ำ", ฟังก์ชันล้วน เทสต์ได้ |

---

## 🔔 การแจ้งเตือนอัตโนมัติ (write → listen → notify)

`lib/notification_service.dart` เฝ้าดูค่าในถังทุกครั้งที่ Firebase เปลี่ยน
แล้วเขียนการแจ้งเตือนลง `water_system/notifications` เองเมื่อเข้าเกณฑ์
(แจ้งตามระดับน้ำแบบเรียลไทม์ + สถานะการไหล หยุด/กลับมาไหล เท่านั้น)

| เกณฑ์ | ระดับ | ข้อความ |
|---|---|---|
| น้ำ ≤ 25% | `critical` | ระดับน้ำต่ำมาก (วิกฤต) |
| น้ำ 25–50% | `warning` | ระดับน้ำต่ำ (ควรระวัง) |
| น้ำ 50–75% | `info` | ระดับน้ำ |
| น้ำ > 75% | `info` | ระดับน้ำปกติ |
| ไหลกลับเป็น 0 ลิตร/นาที | `info` | น้ำหยุดไหล |
| ไหลกลับมาไหล (> 0.01 ลิตร/นาที) | `info` | น้ำกลับมาไหล |

- ระบบจะแจ้งเฉพาะเมื่อระดับน้ำ **ข้ามช่วง** (25% / 50% / 75%) หรือสถานะการไหล
  เปลี่ยนระหว่าง "ไม่ไหล ⇄ ไหล" เท่านั้น — ไม่แจ้งทุกครั้งที่ตัวเลขขยับเล็กน้อย
- ค่าเกณฑ์แก้ได้ตอนบนของ `lib/notification_service.dart`
  (`kCriticalPercent`, `kWarningPercent`, `kNormalPercent`, `kHighFlowLpm`)
- มี cooldown 15 นาที (`kAlertCooldown`) กันแจ้งซ้ำถี่เกินไป
- สถานะล่าสุดบันทึกไว้ที่ `water_system/notification_state` เปิดแอปใหม่แล้วไม่แจ้งซ้ำ
- เมื่อมีการแจ้งเตือนใหม่ หน้าจอที่เปิดอยู่จะเด้ง `SnackBar` พร้อมปุ่ม "ดูทั้งหมด"
- หน้าจอการแจ้งเตือน (`notification.dart`) รับข้อมูลผ่าน `onValue` จึงขึ้นเองแบบเรียลไทม์
  โดยไม่ต้อง refresh
- หน้าจอการแจ้งเตือนมี **แบนเนอร์สรุปจำนวนที่ยังไม่อ่าน**, **chip กรอง**
  (ทั้งหมด / วิกฤต / ควรระวัง / ปกติ), ปุ่ม **"อ่านทั้งหมด"** และแตะการ์ดเพื่อปิดสถานะยังไม่อ่าน
- สี/ไอคอน/ป้ายชื่อของแต่ละระดับใช้ชุดเดียวกันทั้งแอป ผ่านตัวช่วย
  `notificationColorFor`, `notificationIconFor`, `notificationLabelFor` ใน `lib/notification.dart`

การไหลของข้อมูลทั้งระบบ:

```
ESP32 → monitor/water_level_liters
          ↓ (onValue)
   TankAlertWatcher ตรวจเกณฑ์ → เขียน water_system/notifications
          ↓ (onValue)                        ↓ (callback)
   NotificationPage ขึ้นการ์ดใหม่        SnackBar เด้งเตือนทันที
```

---

## หมายเหตุ / ข้อควรรู้

- **Firebase Web appId** ใน `lib/firebase_options.dart` ยังเป็นค่า placeholder —
  ถ้าต้องการค่า appId จริง ให้รัน `flutterfire configure` (หลัง `firebase login`)
  หรือลงทะเบียน Web app ใน Firebase Console
- **สิทธิ์ Realtime Database**: ถ้าแอปอ่าน/เขียนข้อมูลไม่ได้ (permission denied)
  ให้เปิด rule ใน Firebase Console เช่น `".read": true, ".write": true` (เฉพาะช่วงพัฒนา)
- **เทสต์**: รัน `flutter test` เพื่อตรวจตรรกะเกณฑ์แจ้งเตือน/บริบท AI และ
  เงื่อนไขการเรียก Gemini (ประหยัดโควตา) ใน `test/water_ai_logic_test.dart`
  (ตรรกะการเรียก Gemini อยู่ใน `lib/ai_policy.dart` ซึ่งเป็นฟังก์ชันล้วน เทสต์ได้ไม่ต้องมี Firebase)
- **สิทธิ์ INTERNET (Android)**: ประกาศไว้ครบทั้ง `debug` / `profile` และ
  `main` (release) แล้ว เพื่อให้เรียก Gemini API และ Firebase ได้ทุกโหมดการ build
- **CORS บน Web**: เรียก Gemini จาก `flutter run -d chrome` ได้ตามปกติ
  ถ้าเจอปัญหา CORS ให้ลอง `flutter run -d windows` หรือรันบน Android emulator แทน
- **API Key ห้าม commit**: เก็บใน `env.json` (อยู่ใน `.gitignore`) หรือส่งผ่าน
  `--dart-define` เท่านั้น โปรเจคนี้ไม่เขียนคีย์ลง Firebase และไม่ hardcode ในโค้ด
- **นาฬิกาไม่ตรงกัน**: การแจ้งเตือนที่แอปเขียนใช้ `ServerValue.timestamp` ของ Firebase
  จึงไม่เพี้ยนแม้เวลาของมือถือคลาดเคลื่อน และสถานะการเรียก Gemini
  (`water_system/ai_state`) ก็ใช้เวลาเดียวกัน
  โดยในเซสชันเดียวกันจะเทียบกับเวลาของเครื่องด้วย (`lastAttemptLocal`)
  ถ้านาฬิกาเครื่องช้ากว่าเซิร์ฟเวอร์มาก ระบบจะตีความว่า "ยังไม่ครบเวลา"
  แล้วไม่เรียก Gemini (ปลอดภัยต่อโควตา) — ควรตั้งเวลาเครื่องเป็นอัตโนมัติ
- **สถานะที่แอปเขียนเพิ่ม**: `water_system/notifications` (การแจ้งเตือน),
  `water_system/notification_state` (กันแจ้งซ้ำ) และ
  `water_system/ai_state` (เงื่อนไขการเรียก Gemini) — ลบได้ตลอด
  แอปจะสร้างใหม่เอง

## ฝั่ง ESP32 (Arduino)

- เปิด `Code IOT device.txt` ใน Arduino IDE
- ต้องติดตั้งไลบรารี: `Adafruit GFX`, `Adafruit SSD1306`, `Firebase ESP32`
- แก้ค่า `WIFI_SSID`, `WIFI_PASSWORD`, `FIREBASE_HOST`, `FIREBASE_AUTH` ให้ตรงกับของจริง
- เลือกบอร์ด ESP32 แล้ว Upload

