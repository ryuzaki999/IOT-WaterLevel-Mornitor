// =====================================================================
// 🔐 ai_policy.dart — ตรรกะตัดสินใจว่า "จะเรียก Gemini หรือไม่"
//
//    ทำไมต้องมีไฟล์นี้
//    หน้า AI ถูกวางไว้ใน IndexedStack ของ watertank.dart จึงถูก mount
//    ค้างไว้ตลอดอายุแอป (สลับแท็บก็ไม่ถูก dispose) และบน Flutter Web
//    ทุกแท็บที่เปิดค้าง/ทุกรอบ hot restart จะสร้างอินสแตนซ์ใหม่
//    เดิมแอปจึงยิง Gemini "ทันทีที่เปิดแอป" + "ทุก 1 ชั่วโมง" ต่ออินสแตนซ์
//    ทำให้จำนวนคำขอพุ่งเกินโควต้าฟรีของ Gemini API (429 RESOURCE_EXHAUSTED)
//
//    ไฟล์นี้รวมเงื่อนไขทั้งหมดไว้เป็นฟังก์ชันล้วน (ไม่พึ่ง Flutter/Firebase)
//    จึงเทสต์ได้ใน test/water_ai_logic_test.dart
//    ส่วนการอ่าน/เขียน Firebase และการเรียก Gemini อยู่ใน ai_page.dart
//
// Firebase schema ที่ไฟล์นี้ผูกด้วย (เขียนโดย ai_page.dart)
// water_system/ai_state: {
//   last_attempt_at:  <ms>     ครั้งล่าสุดที่ "ส่งคำขอ" (ServerValue.timestamp)
//   last_success_at:  <ms>     ครั้งล่าสุดที่ "ได้คำตอบ"
//   last_percent:     <number> เปอร์เซ็นต์น้ำตอนยิงล่าสุด
//   last_flow:        <number> ลิตร/นาที ตอนยิงล่าสุด
//   last_narrative:   <string> บทวิเคราะห์ล่าสุด (แสดงต่อได้หลังรีสตาร์ท)
//   last_tips:        <string> คำแนะนำล่าสุด คั่นแต่ละข้อด้วย \n
//   last_forecast:    <string> เนื้อความบล็อก [คาดการณ์] ล่าสุด (5 บรรทัด + หมด)
// }
// =====================================================================

/// ⏳ ยิงอัตโนมัติห่างกันอย่างน้อยกี่นาที (เดิมยิงทุก 1 ชั่วโมงแบบตายตัว)
const int kAiAutoIntervalMinutes = 60;

/// 🚦 กันกด "ดึงลงเพื่อรีเฟรช" รัว ๆ (นับจากครั้งล่าสุดที่ส่งคำขอ)
const int kAiManualCooldownSeconds = 60;

/// 📊 เปอร์เซ็นต์น้ำต่างจากครั้งล่าสุดตั้งแต่ค่านี้ = ถือว่า "ข้อมูลเปลี่ยน"
const double kAiPercentEpsilon = 1.0;

/// 💧 อัตราไหลต่างจากครั้งล่าสุดตั้งแต่ค่านี้ (ลิตร/นาที) = "ข้อมูลเปลี่ยน"
const double kAiFlowEpsilonLpm = 0.05;

/// 🚰 อัตราไหลที่ถือว่า "มีน้ำไหลอยู่จริง" (ตรงกับ WaterSnapshot.isFlowing)
const double kAiFlowActiveLpm = 0.01;

/// ⏰ รอบตรวจเงื่อนไข (ไม่ใช่รอบยิง — ตรวจไม่ผ่านก็ไม่มีการเรียกเน็ตเลย)
const int kAiTickMinutes = 5;

// =====================================================================
// 📚 AiState — สถานะการเรียก Gemini ครั้งล่าสุด (เก็บที่ water_system/ai_state)
//    เก็บบน Firebase จึงแชร์กันทุกแท็บ/ทุกอุปกรณ์ → เปิดซ้ำก็ไม่ยิงซ้ำ
// =====================================================================
class AiState {
  final int? lastAttemptAt; // ms ที่ "ส่งคำขอ" ล่าสุด
  final int? lastSuccessAt; // ms ที่ "ได้คำตอบ" ล่าสุด
  final double? lastPercent; // เปอร์เซ็นต์น้ำตอนยิงล่าสุด
  final double? lastFlow; // ลิตร/นาที ตอนยิงล่าสุด
  final String? lastNarrative; // บทวิเคราะห์ล่าสุด
  final List<String> lastTips; // คำแนะนำล่าสุด
  final String? lastForecast; // เนื้อความบล็อก [คาดการณ์] ล่าสุด

  const AiState({
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.lastPercent,
    this.lastFlow,
    this.lastNarrative,
    this.lastTips = const <String>[],
    this.lastForecast,
  });

  /// สถานะว่าง (ยังไม่เคยวิเคราะห์) — เงื่อนไขทุกข้อจะถือว่า "ยิงได้"
  static const AiState empty = AiState();

  /// แปลงข้อมูลจาก Firebase (ทนค่าผิดประเภท/ค่าที่หายไป)
  factory AiState.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return empty;
    final data = Map<dynamic, dynamic>.from(map);

    final String narrative = (data['last_narrative'] ?? '').toString().trim();
    final String tipsRaw = (data['last_tips'] ?? '').toString();
    final String forecastRaw = (data['last_forecast'] ?? '').toString().trim();

    return AiState(
      lastAttemptAt: _toIntOrNull(data['last_attempt_at']),
      lastSuccessAt: _toIntOrNull(data['last_success_at']),
      lastPercent: _toDoubleOrNull(data['last_percent']),
      lastFlow: _toDoubleOrNull(data['last_flow']),
      lastNarrative: narrative.isEmpty ? null : narrative,
      lastTips: tipsRaw
          .split('\n')
          .map((String line) => line.trim())
          .where((String line) => line.isNotEmpty)
          .toList(),
      lastForecast: forecastRaw.isEmpty ? null : forecastRaw,
    );
  }

  /// ⚠️ ใช้ตรวจสอบ/เทสต์เท่านั้น — อย่าเอาไป `update()` ตรง ๆ
  /// เพราะค่า `null` จะไป "ลบฟิลด์" ทิ้งบน Firebase
  Map<String, Object?> toMap() => <String, Object?>{
        'last_attempt_at': lastAttemptAt,
        'last_success_at': lastSuccessAt,
        'last_percent': lastPercent,
        'last_flow': lastFlow,
        'last_narrative': lastNarrative,
        'last_tips': lastTips.join('\n'),
        'last_forecast': lastForecast,
      };

  /// คัดลอกค่าพร้อมแก้บางฟิลด์ (จำลองสถานะใหม่ในเซสชัน ไม่ต้องรอเซิร์ฟเวอร์)
  AiState copyWith({
    int? lastAttemptAt,
    int? lastSuccessAt,
    double? lastPercent,
    double? lastFlow,
    String? lastNarrative,
    List<String>? lastTips,
    String? lastForecast,
  }) {
    return AiState(
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      lastPercent: lastPercent ?? this.lastPercent,
      lastFlow: lastFlow ?? this.lastFlow,
      lastNarrative: lastNarrative ?? this.lastNarrative,
      lastTips: lastTips ?? this.lastTips,
      lastForecast: lastForecast ?? this.lastForecast,
    );
  }

  static int? _toIntOrNull(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? _toDoubleOrNull(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}

/// 🚫 เหตุผลที่ "ไม่เรียก" Gemini (none = เรียกได้)
enum AiSkipReason {
  /// เรียกได้เลย
  none,

  /// กำลังวิเคราะห์อยู่แล้ว
  busy,

  /// ยังไม่ได้ตั้งค่า API Key
  noKey,

  /// ยังไม่ได้รับข้อมูลจากเซ็นเซอร์
  noData,

  /// ยังไม่ครบรอบเวลาขั้นต่ำ
  tooSoon,

  /// ข้อมูลไม่เปลี่ยนจากครั้งล่าสุด
  noChange,

  /// อยู่ในช่วง cooldown ของการกดเอง
  cooldown,
}

// =====================================================================
// ⏱️ เวลาที่ผ่านไปนับจากครั้งล่าสุดที่ส่งคำขอ (วินาที)
//    - null = ไม่เคยมีบันทึก (ถือว่า "ยิงได้")
//    - ค่าติดลบ = timestamp ล้ำหน้าเวลาปัจจุบัน (นาฬิกาเครื่องช้ากว่าเซิร์ฟเวอร์)
//      ซึ่งเงื่อนไข "ครบเวลาไหม" จะตีความเป็น "ยังไม่ครบ" → ไม่ยิง (ปลอดภัยต่อโควต้า)
//    - ถ้ามี lastAttemptLocal (เซสชันเดียวกัน) จะใช้เวลาของเครื่องนั้น
//      เพราะนาฬิกาเครื่องเองเดินสอดคล้องกัน ความเพี้ยนจึงหักล้างกันไปเอง
// =====================================================================
int? aiElapsedSeconds({
  required AiState state,
  required DateTime now,
  DateTime? lastAttemptLocal,
}) {
  final DateTime? local = lastAttemptLocal;
  if (local != null) {
    final int diff = now.difference(local).inSeconds;
    return diff < 0 ? 0 : diff;
  }

  final int? serverMs = state.lastAttemptAt;
  if (serverMs == null || serverMs <= 0) return null;
  return (now.millisecondsSinceEpoch - serverMs) ~/ 1000;
}

// =====================================================================
// 🔍 ข้อมูลเปลี่ยนจากครั้งล่าสุดที่ส่งคำขอไปจริงหรือไม่
//    (ตรวจเฉพาะตอนครบรอบเวลาแล้ว — จึงยัง "อัปเดตอย่างน้อยทุก 1 ชม."
//     เมื่อมีการใช้น้ำ แต่ไม่ยิงเปล่า ๆ ตอนไม่มีอะไรเปลี่ยนเลย)
// =====================================================================
bool aiHasMaterialChange({
  required AiState state,
  required double percent,
  required double flowRate,
}) {
  // ยังไม่เคยวิเคราะห์สำเร็จเลย → ต้องวิเคราะห์
  if (state.lastSuccessAt == null) return true;

  final double? prevPercent = state.lastPercent;
  if (prevPercent == null) return true;
  if ((percent - prevPercent).abs() >= kAiPercentEpsilon) return true;

  final double prevFlow = state.lastFlow ?? 0;
  if ((flowRate - prevFlow).abs() >= kAiFlowEpsilonLpm) return true;

  // น้ำเริ่มไหล/หยุดไหล เปลี่ยนสถานะ (แม้ตัวเลขต่างกันไม่มาก)
  final bool wasFlowing = prevFlow > kAiFlowActiveLpm;
  final bool isFlowingNow = flowRate > kAiFlowActiveLpm;
  if (wasFlowing != isFlowingNow) return true;

  return false;
}

// =====================================================================
// 🤖 ตัดสินใจสำหรับ "การวิเคราะห์อัตโนมัติ" (ตอนเปิดหน้า / ตัวจับเวลา)
//    ต้องผ่าน: ครบเวลาขั้นต่ำ + ข้อมูลเปลี่ยนจริง + พร้อมยิง
// =====================================================================
AiSkipReason aiAutoDecision({
  required AiState state,
  required DateTime now,
  DateTime? lastAttemptLocal,
  required bool hasApiKey,
  required bool hasData,
  required bool isAnalyzing,
  required double percent,
  required double flowRate,
}) {
  if (isAnalyzing) return AiSkipReason.busy;
  if (!hasApiKey) return AiSkipReason.noKey;
  if (!hasData) return AiSkipReason.noData;

  final int? since = aiElapsedSeconds(
    state: state,
    now: now,
    lastAttemptLocal: lastAttemptLocal,
  );
  if (since != null && since < kAiAutoIntervalMinutes * 60) {
    return AiSkipReason.tooSoon;
  }

  final bool changed = aiHasMaterialChange(
    state: state,
    percent: percent,
    flowRate: flowRate,
  );
  if (!changed) return AiSkipReason.noChange;

  return AiSkipReason.none;
}

// =====================================================================
// 👆 ตัดสินใจสำหรับ "การกดเอง" (ดึงลงเพื่อรีเฟรช)
//    ผู้ใช้สั่งเองจึงไม่ต้องรอข้อมูลเปลี่ยน — แต่ยังกันการกดรัว ๆ
// =====================================================================
AiSkipReason aiManualDecision({
  required AiState state,
  required DateTime now,
  DateTime? lastAttemptLocal,
  required bool hasApiKey,
  required bool hasData,
  required bool isAnalyzing,
}) {
  if (isAnalyzing) return AiSkipReason.busy;
  if (!hasApiKey) return AiSkipReason.noKey;
  if (!hasData) return AiSkipReason.noData;

  final int? since = aiElapsedSeconds(
    state: state,
    now: now,
    lastAttemptLocal: lastAttemptLocal,
  );
  if (since != null && since < kAiManualCooldownSeconds) {
    return AiSkipReason.cooldown;
  }

  return AiSkipReason.none;
}

// =====================================================================
// 🗣️ ข้อความไทยอธิบายเหตุผลที่ยังไม่เรียก Gemini (โชว์ใน SnackBar/ใต้การ์ด AI)
// =====================================================================
String aiSkipMessageThai(
  AiSkipReason reason, {
  required AiState state,
  required DateTime now,
  DateTime? lastAttemptLocal,
}) {
  final int raw =
      aiElapsedSeconds(
        state: state,
        now: now,
        lastAttemptLocal: lastAttemptLocal,
      ) ??
      0;
  final int since = raw < 0 ? 0 : raw;

  switch (reason) {
    case AiSkipReason.none:
      return '';
    case AiSkipReason.busy:
      return 'กำลังวิเคราะห์อยู่ กรุณารอสักครู่';
    case AiSkipReason.noKey:
      return 'ยังไม่ได้ตั้งค่า API Key ของ Gemini';
    case AiSkipReason.noData:
      return 'ยังไม่ได้รับข้อมูลจากเซ็นเซอร์ในถังน้ำ';
    case AiSkipReason.cooldown:
      final int wait = kAiManualCooldownSeconds - since;
      return 'เพิ่งส่งคำขอไปเมื่อ $since วินาทีที่แล้ว กรุณารออีก $wait วินาที';
    case AiSkipReason.tooSoon:
      final int minutes = since ~/ 60;
      return 'เพิ่งวิเคราะห์ไปเมื่อ $minutes นาทีที่แล้ว '
          'จะวิเคราะห์อัตโนมัติอีกครั้งเมื่อข้อมูลเปลี่ยน '
          'หรือครบ $kAiAutoIntervalMinutes นาที';
    case AiSkipReason.noChange:
      return 'ข้อมูลน้ำยังไม่เปลี่ยนจากครั้งล่าสุด '
          'จึงยังไม่วิเคราะห์ใหม่ (ประหยัดโควตา Gemini)';
  }
}
