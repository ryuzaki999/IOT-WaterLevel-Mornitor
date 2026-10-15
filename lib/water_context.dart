import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';

// =====================================================================
// 📦 Firebase schema ที่ไฟล์นี้ใช้ (ตรงกับหน้าน้ำ/ประวัติ)
// water_system/setting:   { tank_depth, tank_capacity }
// water_system/monitor:   { water_level_liters, flow_rate_min }
// water_system/history/{yyyy-MM-dd}: {
//     used_liters: <number>,
//     hourly: { 'HH': { used_liters: <number> } }
// }
// =====================================================================

/// 📅 ต้องมี "วันเต็มวัน" อย่างน้อยเท่านี้ จึงจะเชื่อถือค่าเฉลี่ยการใช้น้ำได้
///    • "วันเต็มวัน" = วันก่อนวันนี้ที่มีคีย์ใน water_system/history
///      (วันนี้ยังสะสมไม่จบวัน ถ้านำมาหารด้วย ค่าเฉลี่ยจะต่ำกว่าจริงมาก
///       เช่น ใช้น้ำไปแค่ 1.9 ลิตรตอนเช้า → เฉลี่ยกลายเป็น 1.9 ลิตร/วัน)
///    • ยังไม่ครบเกณฑ์ → estimatedDaysRemaining = null
///      (การ์ดจะโชว์ "--" พร้อมข้อความ "ข้อมูลยังไม่พอ" แทนการเดาตัวเลข)
const int kMinFullDaysForAverage = 3;

class HourlyUsage {
  final String hour; // 'HH'
  final double liters;

  const HourlyUsage(this.hour, this.liters);
}

// =====================================================================
// 📸 WaterSnapshot — ภาพรวมสถานะระบบ ณ ขณะหนึ่ง ใช้เป็นบริบทให้ Gemini
// =====================================================================
class WaterSnapshot {
  final double capacity; // ลิตร
  final double tankDepth; // ซม.
  final double currentLiters;
  final double flowRate; // ลิตร/นาที
  final double usedToday; // ลิตร
  final List<HourlyUsage> hourlyToday;
  /// ค่าเฉลี่ยการใช้น้ำต่อวัน — คิดจาก "วันเต็มวัน" เท่านั้น (ไม่นับวันนี้)
  final double averageDailyLiters;
  /// จำนวน "วันเต็มวัน" ที่มีข้อมูลในประวัติ (ไม่นับวันนี้)
  final int recordedDays;
  final String? peakDayLabel;
  final double peakDayLiters;
  final bool hasData;

  const WaterSnapshot({
    required this.capacity,
    required this.tankDepth,
    required this.currentLiters,
    required this.flowRate,
    required this.usedToday,
    required this.hourlyToday,
    required this.averageDailyLiters,
    required this.recordedDays,
    required this.peakDayLabel,
    required this.peakDayLiters,
    required this.hasData,
  });

  /// เปอร์เซ็นต์น้ำคงเหลือ (0 - 100)
  double get percent {
    if (capacity <= 0) return 0;
    return ((currentLiters / capacity) * 100).clamp(0.0, 100.0);
  }

  /// 🟢🟡🔴 สถานะระดับน้ำ (เกณฑ์เดียวกับ watertank.dart)
  String get statusLabel {
    if (percent <= 25.0) return 'วิกฤต (น้ำน้อยมาก)';
    if (percent <= 50.0) return 'ควรระวัง';
    return 'ปกติ';
  }

  bool get isFlowing => flowRate > 0.01;

  /// ✅ มีข้อมูล "วันเต็มวัน" พอที่จะเชื่อถือค่าเฉลี่ยหรือยัง
  ///    ต้องมีค่าเฉลี่ย > 0 และครบ [kMinFullDaysForAverage] วัน
  bool get hasReliableAverage =>
      averageDailyLiters > 0 && recordedDays >= kMinFullDaysForAverage;

  /// 📅 จำนวนวันเต็มวันที่ยังขาดก่อนจะใช้ค่าเฉลี่ยได้ (0 = ครบแล้ว)
  int get fullDaysShort =>
      (kMinFullDaysForAverage - recordedDays).clamp(0, kMinFullDaysForAverage);

  /// 🔮 ประมาณจำนวนวันที่น้ำที่เหลือจะใช้ได้อีก ถ้าใช้อัตราเดิม
  ///    • ยังไม่ครบ [kMinFullDaysForAverage] วัน → null (ไม่เดาจากการใช้วันนี้
  ///      เพราะวันนี้ยังไม่จบวัน ตัวเลขจะต่ำกว่าจริงมาก)
  double? get estimatedDaysRemaining {
    if (!hasReliableAverage) return null;
    return currentLiters / averageDailyLiters;
  }

  /// จำนวนชั่วโมงที่มีการบันทึกการใช้น้ำวันนี้ (ใช้คิดค่าเฉลี่ยต่อชั่วโมง)
  int get activeHoursToday => hourlyToday.length;

  static const WaterSnapshot empty = WaterSnapshot(
    capacity: 0,
    tankDepth: 0,
    currentLiters: 0,
    flowRate: 0,
    usedToday: 0,
    hourlyToday: <HourlyUsage>[],
    averageDailyLiters: 0,
    recordedDays: 0,
    peakDayLabel: null,
    peakDayLiters: 0,
    hasData: false,
  );

  // ------------------------------------------------------------------
  // 📝 แปลงข้อมูลทั้งหมดเป็นข้อความภาษาไทย สำหรับแนบไปกับคำถามให้ Gemini
  // ------------------------------------------------------------------
  String toPromptText() {
    if (!hasData) {
      return 'ยังไม่ได้รับข้อมูลจากเซ็นเซอร์ (ไม่พบข้อมูลใน Firebase)';
    }

    final now = DateTime.now();
    final String timeLabel =
        '${now.day}/${now.month}/${now.year} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')} น.';

    final b = StringBuffer();
    b.writeln('เวลาเก็บข้อมูล: $timeLabel');
    b.writeln(
      'ความจุถัง: ${capacity.toStringAsFixed(0)} ลิตร'
      '${tankDepth > 0 ? ' (ความสูง ${tankDepth.toStringAsFixed(0)} ซม.)' : ''}',
    );
    b.writeln(
      'น้ำคงเหลือ: ${currentLiters.toStringAsFixed(1)} ลิตร '
      '(${percent.toStringAsFixed(1)}% ของถัง) สถานะ: $statusLabel',
    );
    b.writeln(
      'อัตราการไหลปัจจุบัน: ${flowRate.toStringAsFixed(2)} ลิตร/นาที '
      '(${isFlowing ? 'กำลังมีการไหล' : 'น้ำหยุดนิ่ง'})',
    );
    b.writeln(
      'ใช้น้ำไปแล้ววันนี้: ${usedToday.toStringAsFixed(1)} ลิตร '
      '(วันนี้ยังไม่จบวัน จึงไม่ถูกนำมาคิดค่าเฉลี่ย)',
    );

    if (hasReliableAverage) {
      b.writeln(
        'ค่าเฉลี่ยการใช้น้ำต่อวัน (จากวันเต็มวัน $recordedDays วัน '
        'ไม่นับวันนี้): ${averageDailyLiters.toStringAsFixed(1)} ลิตร/วัน',
      );
    } else if (recordedDays > 0) {
      b.writeln(
        'ค่าเฉลี่ยการใช้น้ำต่อวัน: ยังสรุปไม่ได้ '
        '(มีวันเต็มวัน $recordedDays วัน ต้องมีอย่างน้อย '
        '$kMinFullDaysForAverage วัน)',
      );
    }
    if (peakDayLiters > 0 && peakDayLabel != null) {
      b.writeln(
        'วันที่ใช้น้ำมากที่สุด: $peakDayLabel '
        '(${peakDayLiters.toStringAsFixed(1)} ลิตร)',
      );
    }

    final days = estimatedDaysRemaining;
    if (days != null) {
      b.writeln(
        'ประมาณการ: ถ้าใช้อัตราเดิม น้ำที่เหลือจะใช้ได้อีกประมาณ '
        '${days.toStringAsFixed(1)} วัน',
      );
    } else {
      b.writeln(
        'ประมาณการ: ยังประเมินจำนวนวันคงเหลือไม่ได้ '
        '(ข้อมูลวันเต็มวันไม่พอ)',
      );
    }

    if (hourlyToday.isNotEmpty) {
      b.writeln();
      b.writeln('การใช้น้ำรายชั่วโมงวันนี้ (เฉพาะชั่วโมงที่มีการใช้น้ำ):');
      for (final h in hourlyToday) {
        b.writeln('  ${h.hour}:00 = ${h.liters.toStringAsFixed(1)} ลิตร');
      }
    }

    return b.toString();
  }
}

// =====================================================================
// 👂 WaterContextWatcher — ดักฟัง Firebase แล้วส่ง WaterSnapshot ออกมา
//    ฟังที่ปมราก 'water_system' ครั้งเดียว ได้ข้อมูลครบทุกส่วน
//    (monitor + setting + history) เหมือนที่ watertank.dart ทำ
// =====================================================================
class WaterContextWatcher {
  final DatabaseReference _rootRef = FirebaseDatabase.instance.ref(
    'water_system',
  );
  final void Function(WaterSnapshot snapshot) onSnapshot;

  StreamSubscription<DatabaseEvent>? _subscription;

  WaterContextWatcher({required this.onSnapshot});

  void start() {
    _subscription = _rootRef.onValue.listen(
      (event) {
        onSnapshot(parseSnapshot(event.snapshot.value));
      },
      onError: (error) {
        debugPrint('Firebase water context stream error: $error');
        onSnapshot(WaterSnapshot.empty);
      },
    );
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  // ------------------------------------------------------------------
  // 🧮 แปลงข้อมูลดิบจาก Firebase เป็น WaterSnapshot
  // ------------------------------------------------------------------
  static WaterSnapshot parseSnapshot(dynamic rootValue) {
    if (rootValue == null) return WaterSnapshot.empty;

    try {
      final root = Map<dynamic, dynamic>.from(rootValue as Map);

      final setting = root['setting'] != null
          ? Map<dynamic, dynamic>.from(root['setting'] as Map)
          : <dynamic, dynamic>{};
      final monitor = root['monitor'] != null
          ? Map<dynamic, dynamic>.from(root['monitor'] as Map)
          : <dynamic, dynamic>{};

      final double capacity = _toDouble(setting['tank_capacity'], 0);
      final double tankDepth = _toDouble(setting['tank_depth'], 0);
      final double currentLiters = _toDouble(monitor['water_level_liters'], 0);
      final double flowRate = _toDouble(monitor['flow_rate_min'], 0);

      // ---------- ประวัติการใช้น้ำ ----------
      final history = root['history'] != null
          ? Map<dynamic, dynamic>.from(root['history'] as Map)
          : <dynamic, dynamic>{};

      double usedToday = 0;
      final List<HourlyUsage> hourly = <HourlyUsage>[];

      final String todayKey = _todayKey();
      final todayEntry = history[todayKey];
      if (todayEntry is Map) {
        final dayMap = Map<dynamic, dynamic>.from(todayEntry);
        usedToday = _toDouble(dayMap['used_liters'], 0);

        final rawHourly = dayMap['hourly'];
        if (rawHourly is Map) {
          final hm = Map<dynamic, dynamic>.from(rawHourly);
          for (final key in hm.keys) {
            final value = hm[key];
            if (value is Map) {
              final liters = _toDouble(value['used_liters'], 0);
              if (liters > 0) {
                hourly.add(HourlyUsage(key.toString().padLeft(2, '0'), liters));
              }
            }
          }
          hourly.sort((a, b) => a.hour.compareTo(b.hour));
        }
      }

      // ---------- สถิติย้อนหลัง ----------
      // • "วันที่ใช้น้ำมากที่สุด" นับทุกวันรวมวันนี้ (เป็นสถิติย้อนหลัง)
      // • "ค่าเฉลี่ย/วัน" ใช้เฉพาะ "วันเต็มวัน" = วันก่อนวันนี้ (ตัดวันนี้ออก)
      //   เพราะวันนี้ยังสะสมไม่จบวัน จะทำให้ค่าเฉลี่ยต่ำกว่าความจริงมาก
      double totalFullDays = 0;
      int recordedDays = 0;
      String? peakDayLabel;
      double peakDayLiters = 0;

      for (final key in history.keys) {
        final dayKey = key.toString();
        if (!_isDateKey(dayKey)) continue;
        final entry = history[key];
        if (entry is! Map) continue;
        final liters = _toDouble(entry['used_liters'], 0);

        if (liters > peakDayLiters) {
          peakDayLiters = liters;
          peakDayLabel = _formatDayLabel(dayKey);
        }

        // วันนี้ (และวันในอนาคต ถ้ามีข้อมูลหลุดมา) ยังไม่จบวัน → ไม่คิดค่าเฉลี่ย
        if (dayKey.compareTo(todayKey) >= 0) continue;
        totalFullDays += liters;
        recordedDays++;
      }

      final double averageDaily =
          recordedDays > 0 ? totalFullDays / recordedDays : 0;

      return WaterSnapshot(
        capacity: capacity,
        tankDepth: tankDepth,
        currentLiters: currentLiters,
        flowRate: flowRate,
        usedToday: usedToday,
        hourlyToday: hourly,
        averageDailyLiters: averageDaily,
        recordedDays: recordedDays,
        peakDayLabel: peakDayLabel,
        peakDayLiters: peakDayLiters,
        // ถือว่า "มีข้อมูล" ก็ต่อเมื่อมีค่าความจุถัง หรือมีข้อมูลจากเซ็นเซอร์แล้ว
        // (กันกรณี Firebase ว่างเปล่า แล้วเปอร์เซ็นต์กลายเป็น 0 → แจ้งเตือนวิกฤตผิดๆ)
        hasData: capacity > 0 || monitor.isNotEmpty,
      );
    } catch (e) {
      debugPrint('Error parsing water context: $e');
      return WaterSnapshot.empty;
    }
  }

  // ------------------------- ตัวช่วยย่อย -------------------------
  static double _toDouble(dynamic value, double fallback) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? fallback;
    return fallback;
  }

  static bool _isDateKey(String key) {
    if (key.length != 10) return false;
    return DateTime.tryParse(key) != null;
  }

  static String _todayKey() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  static String _formatDayLabel(String dayKey) {
    final d = DateTime.tryParse(dayKey);
    if (d == null) return dayKey;
    return '${d.day}/${d.month}/${d.year}';
  }
}
