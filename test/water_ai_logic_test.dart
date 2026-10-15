import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/ai_policy.dart';
import 'package:flutter_application_1/notification_service.dart';
import 'package:flutter_application_1/water_context.dart';

// =====================================================================
// 🧪 เทสต์ตรรกะล้วนของส่วน AI + การแจ้งเตือน
//    (ไม่ต้องต่อ Firebase จึงรันได้ทันที)
//
//    flutter test test/water_ai_logic_test.dart
// =====================================================================
void main() {
  final now = DateTime.now();

  /// สร้างคีย์วันที่แบบ yyyy-MM-dd (ใช้จำลองประวัติย้อนหลังในเทสต์)
  String dateKeyOf(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  final todayKey = dateKeyOf(now);

  // 📅 "วันเต็มวัน" = วันก่อนวันนี้ (ตอนนี้ค่าเฉลี่ย/วัน ใช้เฉพาะวันเหล่านี้)
  final String fullDay1 = dateKeyOf(DateTime(now.year, now.month, now.day - 1));
  final String fullDay2 = dateKeyOf(DateTime(now.year, now.month, now.day - 2));
  final String fullDay3 = dateKeyOf(DateTime(now.year, now.month, now.day - 3));

  group('WaterContextWatcher.parseSnapshot', () {
    test('อ่านค่า setting / monitor / history ได้ถูกต้อง', () {
      final snapshot = WaterContextWatcher.parseSnapshot(<String, dynamic>{
        'setting': <String, dynamic>{'tank_depth': 93, 'tank_capacity': 400},
        'monitor': <String, dynamic>{
          'water_level_liters': 220,
          'flow_rate_min': 1.5,
        },
        'history': <String, dynamic>{
          todayKey: <String, dynamic>{
            'used_liters': 40,
            'hourly': <String, dynamic>{
              '07': <String, dynamic>{'used_liters': 28.0},
              '06': <String, dynamic>{'used_liters': 12.0},
            },
          },
          fullDay1: <String, dynamic>{'used_liters': 60},
        },
      });

      expect(snapshot.hasData, isTrue);
      expect(snapshot.capacity, 400);
      expect(snapshot.tankDepth, 93);
      expect(snapshot.currentLiters, 220);
      expect(snapshot.flowRate, 1.5);
      expect(snapshot.percent, closeTo(55.0, 0.001));
      expect(snapshot.statusLabel, 'ปกติ');
      expect(snapshot.isFlowing, isTrue);

      expect(snapshot.usedToday, 40);
      expect(snapshot.hourlyToday.length, 2);
      expect(snapshot.hourlyToday.first.hour, '06'); // เรียงตามชั่วโมง
      expect(snapshot.activeHoursToday, 2);

      // 📅 ค่าเฉลี่ย/วัน นับเฉพาะ "วันเต็มวัน" → วันนี้ (40 ลิตร) ต้องไม่ถูกนำมาหาร
      expect(snapshot.recordedDays, 1);
      expect(snapshot.averageDailyLiters, closeTo(60.0, 0.001));
      expect(snapshot.peakDayLiters, 60);
      // ข้อมูลยังไม่ครบ kMinFullDaysForAverage วัน → ยังประเมินจำนวนวันไม่ได้
      expect(snapshot.hasReliableAverage, isFalse);
      expect(snapshot.fullDaysShort, kMinFullDaysForAverage - 1);
      expect(snapshot.estimatedDaysRemaining, isNull);
    });

    test('ค่าเฉลี่ย/วัน ใช้เฉพาะวันเต็มวัน และประเมินได้เมื่อครบ 3 วัน', () {
      final snapshot = WaterContextWatcher.parseSnapshot(<String, dynamic>{
        'setting': <String, dynamic>{'tank_capacity': 400},
        'monitor': <String, dynamic>{
          'water_level_liters': 220,
          'flow_rate_min': 0,
        },
        'history': <String, dynamic>{
          todayKey: <String, dynamic>{'used_liters': 999}, // วันนี้ → ต้องถูกตัดออก
          fullDay1: <String, dynamic>{'used_liters': 60},
          fullDay2: <String, dynamic>{'used_liters': 30},
          fullDay3: <String, dynamic>{'used_liters': 90},
        },
      });

      expect(snapshot.usedToday, 999); // วันนี้ยังแสดงตามจริง แต่ไม่เข้าค่าเฉลี่ย
      expect(snapshot.recordedDays, 3);
      expect(snapshot.averageDailyLiters, closeTo(60.0, 0.001)); // (60+30+90)/3
      expect(snapshot.hasReliableAverage, isTrue);
      expect(snapshot.fullDaysShort, 0);
      expect(snapshot.estimatedDaysRemaining, closeTo(220 / 60, 0.001));
    });

    test('คีย์ที่ไม่ใช่วันที่ และวันในอนาคต ไม่ถูกนับเป็นวันเต็มวัน', () {
      final String tomorrow =
          dateKeyOf(DateTime(now.year, now.month, now.day + 1));

      final snapshot = WaterContextWatcher.parseSnapshot(<String, dynamic>{
        'setting': <String, dynamic>{'tank_capacity': 400},
        'monitor': <String, dynamic>{
          'water_level_liters': 220,
          'flow_rate_min': 0,
        },
        'history': <String, dynamic>{
          'hotel': <String, dynamic>{'used_liters': 500}, // ไม่ใช่วันที่ → ข้าม
          tomorrow: <String, dynamic>{'used_liters': 80}, // อนาคต → ข้าม
          fullDay1: <String, dynamic>{'used_liters': 60}, // วันเต็มวันจริงวันเดียว
        },
      });

      expect(snapshot.recordedDays, 1);
      expect(snapshot.averageDailyLiters, closeTo(60.0, 0.001));
      expect(snapshot.peakDayLiters, 80); // สถิติย้อนหลังยังนับทุกวัน
      expect(snapshot.hasReliableAverage, isFalse);
      expect(snapshot.estimatedDaysRemaining, isNull);
    });

    test('ข้อมูลว่างหรือรูปแบบผิด คืน empty โดยไม่ throw', () {
      expect(WaterContextWatcher.parseSnapshot(null).hasData, isFalse);
      // Firebase ว่างเปล่า → ยังไม่ถือว่ามีข้อมูล (กันแจ้งเตือนวิกฤตผิดๆ)
      expect(WaterContextWatcher.parseSnapshot(<String, dynamic>{}).hasData,
          isFalse);
      expect(
        WaterContextWatcher.parseSnapshot(<String, dynamic>{
          'monitor': 'broken',
        }).hasData,
        isFalse,
      );
    });

    test('toPromptText() มีข้อมูลที่ AI ต้องใช้ครบ', () {
      final snapshot = WaterContextWatcher.parseSnapshot(<String, dynamic>{
        'setting': <String, dynamic>{'tank_capacity': 400},
        'monitor': <String, dynamic>{
          'water_level_liters': 80,
          'flow_rate_min': 0.0,
        },
        'history': <String, dynamic>{
          todayKey: <String, dynamic>{'used_liters': 30},
        },
      });

      final text = snapshot.toPromptText();
      expect(text, contains('400 ลิตร'));
      expect(text, contains('80.0 ลิตร'));
      expect(text, contains('20.0%'));
      expect(text, contains('วิกฤต')); // 20% = ขอบเขตวิกฤตพอดี
      expect(text, contains('น้ำหยุดนิ่ง'));
    });

    test('toPromptText() บอกว่าค่าเฉลี่ยยังสรุปไม่ได้ เมื่อวันเต็มวันไม่พอ', () {
      final snapshot = WaterContextWatcher.parseSnapshot(<String, dynamic>{
        'setting': <String, dynamic>{'tank_capacity': 400},
        'monitor': <String, dynamic>{
          'water_level_liters': 300,
          'flow_rate_min': 0,
        },
        'history': <String, dynamic>{
          todayKey: <String, dynamic>{'used_liters': 1.9},
          fullDay1: <String, dynamic>{'used_liters': 2.5}, // มีแค่ 1 วันเต็มวัน
        },
      });

      final text = snapshot.toPromptText();
      expect(text, contains('วันนี้ยังไม่จบวัน')); // บอกว่าวันนี้ไม่ถูกคิดค่าเฉลี่ย
      expect(text, contains('ยังสรุปไม่ได้'));
      expect(text, contains('มีวันเต็มวัน 1 วัน'));
      expect(text, contains('อย่างน้อย $kMinFullDaysForAverage วัน'));
      expect(text, contains('ยังประเมินจำนวนวันคงเหลือไม่ได้'));
      expect(text, isNot(contains('ลิตร/วัน'))); // ไม่โชว์ค่าเฉลี่ยที่เชื่อถือไม่ได้

      // ไม่มีวันเต็มวันเลย → ไม่พูดถึงบรรทัดค่าเฉลี่ย
      final none = WaterContextWatcher.parseSnapshot(<String, dynamic>{
        'monitor': <String, dynamic>{'water_level_liters': 300},
        'history': <String, dynamic>{
          todayKey: <String, dynamic>{'used_liters': 1.9},
        },
      });
      expect(none.recordedDays, 0);
      expect(none.toPromptText(), isNot(contains('ค่าเฉลี่ยการใช้น้ำต่อวัน')));
    });

    test('toPromptText() แสดงค่าเฉลี่ยจากวันเต็มวัน เมื่อข้อมูลครบเกณฑ์', () {
      final snapshot = WaterContextWatcher.parseSnapshot(<String, dynamic>{
        'setting': <String, dynamic>{'tank_capacity': 400},
        'monitor': <String, dynamic>{
          'water_level_liters': 300,
          'flow_rate_min': 0,
        },
        'history': <String, dynamic>{
          todayKey: <String, dynamic>{'used_liters': 1.9},
          fullDay1: <String, dynamic>{'used_liters': 60},
          fullDay2: <String, dynamic>{'used_liters': 30},
          fullDay3: <String, dynamic>{'used_liters': 90},
        },
      });

      final text = snapshot.toPromptText();
      expect(text, contains('จากวันเต็มวัน 3 วัน'));
      expect(text, contains('60.0 ลิตร/วัน'));
      expect(text, contains('ประมาณการ'));
      expect(text, contains('5.0 วัน')); // 300 ÷ 60
    });

    test('WaterSnapshot.empty ให้ข้อความบอกว่ายังไม่มีข้อมูล', () {
      expect(WaterSnapshot.empty.toPromptText(), contains('ยังไม่ได้รับข้อมูล'));
      expect(WaterSnapshot.empty.percent, 0);
      expect(WaterSnapshot.empty.estimatedDaysRemaining, isNull);
    });
  });

  group('TankAlertWatcher เกณฑ์แจ้งเตือน', () {
    test('levelZoneOf แบ่งระดับตามจุด 25% / 50% / 75%', () {
      expect(TankAlertWatcher.levelZoneOf(0), 0);
      expect(TankAlertWatcher.levelZoneOf(25.0), 0);
      expect(TankAlertWatcher.levelZoneOf(25.1), 1);
      expect(TankAlertWatcher.levelZoneOf(50.0), 1);
      expect(TankAlertWatcher.levelZoneOf(50.1), 2);
      expect(TankAlertWatcher.levelZoneOf(75.0), 2);
      expect(TankAlertWatcher.levelZoneOf(75.1), 3);
      expect(TankAlertWatcher.levelZoneOf(100.0), 3);
    });

    test('flowStateOf แบ่งสถานะการไหลเป็น หยุด/ไหล', () {
      expect(TankAlertWatcher.flowStateOf(0), 'none');
      expect(TankAlertWatcher.flowStateOf(0.01), 'none');
      expect(TankAlertWatcher.flowStateOf(0.02), 'flowing');
      expect(TankAlertWatcher.flowStateOf(10.0), 'flowing');
      expect(TankAlertWatcher.flowStateOf(30.0), 'flowing');
    });

    test('flowAlertFor แจ้งเฉพาะ หยุดไหล / กลับมาไหล', () {
      const s = WaterSnapshot(
        capacity: 400,
        tankDepth: 93,
        currentLiters: 200,
        flowRate: 2.5,
        usedToday: 0,
        hourlyToday: <HourlyUsage>[],
        averageDailyLiters: 0,
        recordedDays: 0,
        peakDayLabel: null,
        peakDayLiters: 0,
        hasData: true,
      );

      final stopped = TankAlertWatcher.flowAlertFor('none', 'flowing', s);
      expect(stopped!.title, 'น้ำหยุดไหล');

      final resumed = TankAlertWatcher.flowAlertFor('flowing', 'none', s);
      expect(resumed!.title, 'น้ำกลับมาไหล');
      expect(resumed.message, contains('2.5 ลิตร/นาที'));

      // ไหลอยู่แล้วแล้วเปลี่ยนความเร็ว → ไม่ต้องแจ้ง
      expect(TankAlertWatcher.flowAlertFor('flowing', 'flowing', s), isNull);
    });

    test('levelAlertFor สร้างข้อความและ type ตามช่วงระดับน้ำ', () {
      const low = WaterSnapshot(
        capacity: 400,
        tankDepth: 93,
        currentLiters: 40,
        flowRate: 0,
        usedToday: 10,
        hourlyToday: <HourlyUsage>[],
        averageDailyLiters: 0,
        recordedDays: 0,
        peakDayLabel: null,
        peakDayLiters: 0,
        hasData: true,
      );

      final critical = TankAlertWatcher.levelAlertFor(0, low);
      expect(critical.type, 'critical');
      expect(critical.title, 'ระดับน้ำต่ำมาก (วิกฤต)');
      expect(critical.message, contains('40 ลิตร'));

      final warning = TankAlertWatcher.levelAlertFor(1, low);
      expect(warning.type, 'warning');
      expect(warning.title, 'ระดับน้ำต่ำ (ควรระวัง)');

      final mid = TankAlertWatcher.levelAlertFor(2, low);
      expect(mid.type, 'info');
      expect(mid.title, 'ระดับน้ำ');

      final normal = TankAlertWatcher.levelAlertFor(3, low);
      expect(normal.type, 'info');
      expect(normal.title, 'ระดับน้ำปกติ');
    });

    test('ระดับน้ำลดจากเต็มถัง: แจ้งเฉพาะเมื่อข้ามช่วง 75% / 50% / 25%', () {
      WaterSnapshot at(double percent) => WaterSnapshot(
        capacity: 400,
        tankDepth: 93,
        currentLiters: 400 * percent / 100,
        flowRate: 0,
        usedToday: 0,
        hourlyToday: <HourlyUsage>[],
        averageDailyLiters: 0,
        recordedDays: 0,
        peakDayLabel: null,
        peakDayLiters: 0,
        hasData: true,
      );

      // จำลองการเดินของระดับน้ำจากเต็มถัง (เหมือน _handleSnapshot ตัดสินใจจริง)
      final Map<double, TankAlert> emitted = <double, TankAlert>{};
      int lastZone = TankAlertWatcher.levelZoneOf(100.0);
      for (final double pct in <double>[97, 80, 74.9, 60, 49.9, 40, 24.9, 10]) {
        final int zone = TankAlertWatcher.levelZoneOf(pct);
        if (zone == lastZone) continue;
        emitted[pct] = TankAlertWatcher.levelAlertFor(zone, at(pct));
        lastZone = zone;
      }

      // >75% อยู่ในโซน "ระดับน้ำปกติ" เดียว → 97% และ 80% ไม่แจ้งแยกกัน
      expect(emitted.containsKey(97), isFalse);
      expect(emitted.containsKey(80), isFalse);
      // ข้ามลงมาต่ำกว่า 75% → ระดับน้ำ
      expect(emitted[74.9]!.title, 'ระดับน้ำ');
      expect(emitted[74.9]!.type, 'info');
      // 60% ยังโซนเดียวกัน → ไม่แจ้ง
      expect(emitted.containsKey(60), isFalse);
      // ข้ามลงมาต่ำกว่า 50% → ระดับน้ำต่ำ (ควรระวัง)
      expect(emitted[49.9]!.title, 'ระดับน้ำต่ำ (ควรระวัง)');
      expect(emitted[49.9]!.type, 'warning');
      // 40% ยังโซนเดียวกัน → ไม่แจ้ง
      expect(emitted.containsKey(40), isFalse);
      // ข้ามลงมาต่ำกว่า 25% → ระดับน้ำต่ำมาก (วิกฤต)
      expect(emitted[24.9]!.title, 'ระดับน้ำต่ำมาก (วิกฤต)');
      expect(emitted[24.9]!.type, 'critical');
      expect(emitted.containsKey(10), isFalse);
    });

    test('เกณฑ์ค่าคงที่ตรงกับที่ระบุ', () {
      expect(kCriticalPercent, 25.0);
      expect(kWarningPercent, 50.0);
      expect(kNormalPercent, 75.0);
      expect(kHighFlowLpm, 30.0);
      expect(kAlertCooldown.inMinutes, 15);
    });
  });

  // ==================================================================
  // ⛽ เทสต์ตรรกะ "ประหยัดโควตา Gemini" (lib/ai_policy.dart)
  //    เดิมแอปยิงทุกครั้งที่เปิดหน้า + ทุก 1 ชั่วโมง ต่ออินสแตนซ์ (รวมทุกแท็บ
  //    และทุกรอบ hot restart) ทำให้เกินโควต้าฟรีของ Gemini API
  //    หลังแก้: ยิงเฉพาะเมื่อครบเวลา + ข้อมูลเปลี่ยนจริง
  // ==================================================================
  group('AiPolicy ตัดสินใจเรียก Gemini', () {
    final DateTime now = DateTime(2026, 10, 1, 12, 0);
    final int nowMs = now.millisecondsSinceEpoch;
    int minutesAgo(int minutes) =>
        now.subtract(Duration(minutes: minutes)).millisecondsSinceEpoch;

    /// เรียก aiAutoDecision ด้วยค่ามาตรฐาน (ระบุเฉพาะค่าที่เทสต์สนใจ)
    AiSkipReason autoAt({
      required AiState state,
      double percent = 60.0,
      double flowRate = 0.0,
      bool hasApiKey = true,
      bool hasData = true,
      bool isAnalyzing = false,
      DateTime? lastAttemptLocal,
    }) {
      return aiAutoDecision(
        state: state,
        now: now,
        lastAttemptLocal: lastAttemptLocal,
        hasApiKey: hasApiKey,
        hasData: hasData,
        isAnalyzing: isAnalyzing,
        percent: percent,
        flowRate: flowRate,
      );
    }

    test('ยังไม่เคยวิเคราะห์ → ยิงอัตโนมัติได้ทันที', () {
      expect(autoAt(state: AiState.empty), AiSkipReason.none);
      expect(aiElapsedSeconds(state: AiState.empty, now: now), isNull);
    });

    test('เพิ่งวิเคราะห์ไป 30 นาที → ข้าม (tooSoon) แม้ข้อมูลจะเปลี่ยนมาก', () {
      final AiState state = AiState(
        lastAttemptAt: minutesAgo(30),
        lastSuccessAt: minutesAgo(30),
        lastPercent: 30.0,
        lastFlow: 0.0,
      );
      expect(autoAt(state: state, percent: 60.0), AiSkipReason.tooSoon);
    });

    test('ครบ 61 นาทีแต่ข้อมูลไม่เปลี่ยน → ข้าม (noChange)', () {
      final AiState state = AiState(
        lastAttemptAt: minutesAgo(61),
        lastSuccessAt: minutesAgo(61),
        lastPercent: 60.0,
        lastFlow: 0.0,
      );
      // เปอร์เซ็นต์ขยับไม่ถึง 1 → ไม่ยิงเปล่า
      expect(autoAt(state: state, percent: 60.4), AiSkipReason.noChange);
    });

    test('ครบ 61 นาทีและเปอร์เซ็นต์เปลี่ยน ≥ 1 → ยิง', () {
      final AiState state = AiState(
        lastAttemptAt: minutesAgo(61),
        lastSuccessAt: minutesAgo(61),
        lastPercent: 60.0,
        lastFlow: 0.0,
      );
      expect(autoAt(state: state, percent: 61.5), AiSkipReason.none);
      expect(autoAt(state: state, percent: 58.5), AiSkipReason.none);
    });

    test('น้ำเริ่มไหล (สถานะเปลี่ยน) → ยิง', () {
      final AiState state = AiState(
        lastAttemptAt: minutesAgo(61),
        lastSuccessAt: minutesAgo(61),
        lastPercent: 60.0,
        lastFlow: 0.0,
      );
      expect(
        autoAt(state: state, percent: 60.0, flowRate: 0.02),
        AiSkipReason.none,
      );
    });

    test('ไม่มีคีย์ / ไม่มีข้อมูล / กำลังวิเคราะห์ → noKey / noData / busy', () {
      expect(autoAt(state: AiState.empty, hasApiKey: false), AiSkipReason.noKey);
      expect(autoAt(state: AiState.empty, hasData: false), AiSkipReason.noData);
      expect(autoAt(state: AiState.empty, isAnalyzing: true), AiSkipReason.busy);
    });

    test('นาฬิกาเครื่องช้ากว่าเซิร์ฟเวอร์ (เวลาเซิร์ฟเวอร์ล้ำหน้า) → ไม่ยิง', () {
      // กันการยิงรัว ๆ เมื่อเวลาเครื่องกับ Firebase ไม่ตรงกัน
      final AiState state = AiState(
        lastAttemptAt: nowMs + const Duration(hours: 3).inMilliseconds,
        lastSuccessAt: nowMs + const Duration(hours: 3).inMilliseconds,
        lastPercent: 10.0,
      );
      expect(autoAt(state: state, percent: 90.0), AiSkipReason.tooSoon);
    });

    test('ในเซสชันเดียวกันใช้เวลาเครื่อง (lastAttemptLocal) แทนเวลาเซิร์ฟเวอร์', () {
      // เวลาบนเซิร์ฟเวอร์เก่ามาก (ถ้าดูเฉพาะค่านั้นจะยิงได้)
      final AiState state = AiState(
        lastAttemptAt: minutesAgo(120),
        lastSuccessAt: minutesAgo(120),
        lastPercent: 10.0,
      );

      // แต่เพิ่งยิงไปจริง ๆ 10 นาทีในเซสชันนี้ → ต้องรอ
      expect(
        autoAt(
          state: state,
          percent: 90.0,
          lastAttemptLocal: now.subtract(const Duration(minutes: 10)),
        ),
        AiSkipReason.tooSoon,
      );

      // ผ่านไป 75 นาที + ข้อมูลเปลี่ยน → ยิงได้
      expect(
        autoAt(
          state: state,
          percent: 90.0,
          lastAttemptLocal: now.subtract(const Duration(minutes: 75)),
        ),
        AiSkipReason.none,
      );
    });

    test('กดเอง (manual): กันกดรัว 60 วินาที แต่ไม่ต้องรอข้อมูลเปลี่ยน', () {
      AiSkipReason manualAt(DateTime? local) => aiManualDecision(
            state: AiState.empty,
            now: now,
            lastAttemptLocal: local,
            hasApiKey: true,
            hasData: true,
            isAnalyzing: false,
          );

      expect(
        manualAt(now.subtract(const Duration(seconds: 30))),
        AiSkipReason.cooldown,
      );
      expect(
        manualAt(now.subtract(const Duration(seconds: 90))),
        AiSkipReason.none,
      );
      expect(manualAt(null), AiSkipReason.none);
    });

    test('ข้อความไทยอธิบายเหตุผลที่ยังไม่เรียก Gemini', () {
      final AiState state = AiState(
        lastAttemptAt: minutesAgo(20),
        lastSuccessAt: minutesAgo(20),
      );

      expect(
        aiSkipMessageThai(AiSkipReason.tooSoon, state: state, now: now),
        contains('20 นาที'),
      );
      expect(
        aiSkipMessageThai(AiSkipReason.cooldown, state: state, now: now),
        contains('กรุณารออีก'),
      );
      expect(
        aiSkipMessageThai(AiSkipReason.noChange, state: state, now: now),
        contains('ยังไม่เปลี่ยน'),
      );
      expect(aiSkipMessageThai(AiSkipReason.none, state: state, now: now), '');
    });

    test('AiState fromMap/toMap ไป-กลับได้ค่าเดิม (และทนค่าผิดรูปแบบ)', () {
      const AiState state = AiState(
        lastAttemptAt: 111,
        lastSuccessAt: 222,
        lastPercent: 61.5,
        lastFlow: 1.25,
        lastNarrative: 'น้ำเหลือ 61.5% ใช้ได้อีก 2 วัน',
        lastTips: <String>['ปิดก๊อกตอนแปรงฟัน', 'ตรวจท่อรั่ว'],
        lastForecast: 'วัน|1|60|info|ปกติ\nหมด|-|-',
      );

      final AiState back = AiState.fromMap(state.toMap());
      expect(back.lastAttemptAt, 111);
      expect(back.lastSuccessAt, 222);
      expect(back.lastPercent, 61.5);
      expect(back.lastFlow, 1.25);
      expect(back.lastNarrative, 'น้ำเหลือ 61.5% ใช้ได้อีก 2 วัน');
      expect(back.lastTips, <String>['ปิดก๊อกตอนแปรงฟัน', 'ตรวจท่อรั่ว']);
      expect(back.lastForecast, 'วัน|1|60|info|ปกติ\nหมด|-|-');

      // ค่าที่ว่าง/ผิดรูปแบบ ต้องไม่ throw และอ่านค่าเลขเป็นข้อความได้
      expect(AiState.fromMap(null).lastAttemptAt, isNull);
      expect(
        AiState.fromMap(<String, dynamic>{'last_percent': 'x'}).lastPercent,
        isNull,
      );
      expect(
        AiState.fromMap(<String, dynamic>{'last_percent': '55.5'}).lastPercent,
        55.5,
      );
      expect(
        AiState.fromMap(<String, dynamic>{'last_narrative': '   '}).lastNarrative,
        isNull,
      );
      expect(
        AiState.fromMap(<String, dynamic>{'last_forecast': '   '}).lastForecast,
        isNull,
      );
      expect(
        AiState.fromMap(<String, dynamic>{'last_tips': 'ก\n\n ข '}).lastTips,
        <String>['ก', 'ข'],
      );
    });

    test('คัดลอกสถานะด้วย copyWith แล้วเงื่อนไขใช้ค่าล่าสุดทันที', () {
      final AiState state = AiState.empty.copyWith(
        lastAttemptAt: nowMs,
        lastSuccessAt: nowMs,
        lastPercent: 42.0,
      );

      // เพิ่งยิงไป → ต้องรอ
      expect(
        autoAt(state: state, percent: 90.0, lastAttemptLocal: now),
        AiSkipReason.tooSoon,
      );
      // เปอร์เซ็นต์เท่าเดิมหลังครบเวลา → ไม่ยิง
      expect(
        autoAt(
          state: state.copyWith(lastAttemptAt: minutesAgo(90)),
          percent: 42.3,
          lastAttemptLocal: now.subtract(const Duration(minutes: 90)),
        ),
        AiSkipReason.noChange,
      );
    });
  });
}
