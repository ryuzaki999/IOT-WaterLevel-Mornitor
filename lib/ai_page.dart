import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'ai_policy.dart';
import 'ai_reply.dart';
import 'gemini_client.dart';
import 'notification.dart'; // notificationColorFor / notificationIconFor ใช้โชว์สี/ไอคอนตามระดับ
import 'water_context.dart';
import 'water_tips.dart';

// =====================================================================
// 🤖 หน้าจอ AI — แดชบอร์ดวิเคราะห์การใช้น้ำ (ขับเคลื่อนด้วย Google Gemini)
//
//    ทำงานอย่างไร
//    1. WaterContextWatcher ดักฟัง Firebase แล้วสรุปเป็น WaterSnapshot
//    2. พอได้ข้อมูลครั้งแรก ระบบจะสั่งให้ AI วิเคราะห์ให้ "อัตโนมัติ"
//       (ไม่ต้องพิมพ์คำถามเอง — หน้านี้เป็นแดชบอร์ดสรุปผล)
//    3. แสดงผลเป็นการ์ด "AI วิเคราะห์การใช้น้ำ" (ประโยคสรุปบรรทัดเดียวที่คำนวณ
//       จากข้อมูลเซ็นเซอร์เอง) / การ์ดสถิติ / การ์ดคาดการณ์จาก AI 5 วัน /
//       การ์ด "สรุปการใช้น้ำ" (ประโยคสรุปตามเกณฑ์น้ำ)
//    4. บทวิเคราะห์แสดงอยู่บนหน้า AI เท่านั้น (การแจ้งเตือนอัตโนมัติแยกไปที่
//       notification_service.dart ซึ่งเฝ้าดูเกณฑ์ระดับน้ำ/อัตราไหลเอง)
//
//    ⛽ เรื่องโควตา Gemini (สำคัญ)
//    หน้านี้ถูกวางใน IndexedStack ของ watertank.dart จึง mount ค้างไว้
//    ตลอดอายุแอป และบน Web ทุกแท็บที่เปิดค้าง/ทุกรอบ hot restart คือ
//    อินสแตนซ์ใหม่ แอปจึง "ไม่ยิงมั่ว": ทุกครั้งจะถาม ai_policy.dart ก่อน
//      • ครบ kAiAutoIntervalMinutes (60 นาที) จากครั้งล่าสุดที่ส่งคำขอ
//      • ข้อมูลเปลี่ยนจริง (เปอร์เซ็นต์/อัตราไหล)
//      • ไม่ได้ยิงค้างอยู่ + มี API Key + มีข้อมูลจากเซ็นเซอร์
//    สถานะล่าสุดเก็บที่ water_system/ai_state (schema อยู่ใน ai_policy.dart)
//    ทุกแท็บ/ทุกอุปกรณ์จึงใช้สถานะร่วมกัน → เปิดซ้ำ/รีสตาร์ทก็ไม่ยิงซ้ำ
//    และหยุดตัวจับเวลาไว้เมื่อผู้ใช้ไม่ได้อยู่แท็บนี้ (widget.isActive)
// =====================================================================
class AiPage extends StatefulWidget {
  /// true = ผู้ใช้กำลังเปิดแท็บนี้อยู่ (ส่งมาจาก watertank.dart)
  /// ใช้หยุดตัวจับเวลาเมื่อผู้ใช้ย้ายไปแท็บอื่น → ประหยัดโควตา Gemini
  final bool isActive;

  const AiPage({super.key, this.isActive = true});

  @override
  State<AiPage> createState() => _AiPageState();
}

/// 🧠 บทบาทที่กำหนดให้ AI ตอบแบบผู้เชี่ยวชาญระบบน้ำ และตอบเป็นภาษาไทย
const String _systemPrompt =
    'คุณคือผู้ช่วยวิเคราะห์ระบบถังเก็บน้ำและพฤติกรรมการใช้น้ำของบ้านพักอาศัยในประเทศไทย '
    'ตอบเป็นภาษาไทยเสมอ กระชับ ตรงประเด็น ใช้ตัวเลขจากข้อมูลจริงที่ให้มา '
    'ให้อ่านพฤติกรรมการใช้น้ำจากข้อมูลรายชั่วโมงและค่าเฉลี่ยรายวัน '
    'ส่วนการคาดการณ์ ให้ประเมินแนวโน้มจากค่าเฉลี่ย + การใช้วันนี้ + รายชั่วโมง '
    'ถ้าข้อมูลไม่พอให้บอกตรงๆ ว่าขาดข้อมูลอะไร อย่าเดาตัวเลขขึ้นเอง';

/// 🎯 คำสั่งวิเคราะห์พฤติกรรมการใช้น้ำปัจจุบัน (ใช้ทั้งตอนเปิดหน้าครั้งแรกและกดวิเคราะห์ใหม่)
///    ขอ 3 ส่วน: [สรุป] บทวิเคราะห์ / [คาดการณ์] แนวโน้ม 5 วัน / [คำแนะนำ] ข้อประหยัดน้ำ
const String _analysisRequest =
    'ช่วยวิเคราะห์พฤติกรรมการใช้น้ำของบ้านนี้จากข้อมูลที่ให้ '
    'แล้วตอบตามรูปแบบนี้เท่านั้น (เรียงบล็อกตามนี้ ห้ามสลับหรือเพิ่มหัวข้ออื่น)\n'
    '$kSummaryHeader\n'
    '(2-3 ประโยค: น้ำเหลือพอใช้ได้อีกกี่วัน ควรเติมเมื่อไหร่ '
    'พร้อมสะท้อนพฤติกรรม เช่น ช่วงเวลาที่ใช้น้ำมากสุด '
    'และการใช้วันนี้เทียบกับค่าเฉลี่ยรายวัน โดยใส่ตัวเลขจริงจากข้อมูล)\n'
    '$kForecastHeader\n'
    'วัน|1|<เปอร์เซ็นต์ 0-100>|<critical|warning|info>|<เหตุผลสั้นไม่เกิน 12 คำ>\n'
    'วัน|2|<เปอร์เซ็นต์>|<ระดับ>|<เหตุผล>\n'
    'วัน|3|<เปอร์เซ็นต์>|<ระดับ>|<เหตุผล>\n'
    'วัน|4|<เปอร์เซ็นต์>|<ระดับ>|<เหตุผล>\n'
    'วัน|5|<เปอร์เซ็นต์>|<ระดับ>|<เหตุผล>\n'
    'หมด|<วัน 1-5 หรือ ->|<HH:MM> (เวลาที่คาดว่าน้ำจะหมด ถ้าไม่หมดใน 5 วันให้ หมด|-|-)\n'
    '(กติกาคาดการณ์: เปอร์เซ็นต์เป็นจำนวนเต็ม 0-100 ต้องไม่เพิ่มขึ้นในแต่ละวัน '
    'วัน 1 ต้องต่างจากเปอร์เซ็นต์ปัจจุบันไม่เกิน 15; ระดับ critical ถ้าเปอร์เซ็นต์ ≤ 25 '
    'warning ถ้า ≤ 50 info ถ้ามากกว่านั้น และยกระดับได้แต่ห้ามลดระดับ; '
    'อ้างอิงวันจริงจากตารางวันที่ที่ให้มา ห้ามคิดตัวเลขขึ้นเอง)\n'
    '$kTipsHeader\n'
    '- คำแนะนำข้อที่ 1\n'
    '- คำแนะนำข้อที่ 2\n'
    '- คำแนะนำข้อที่ 3\n'
    '(แต่ละข้อไม่เกิน 12 คำ เน้นสิ่งที่เจ้าของบ้านทำได้จริงเพื่อประหยัดน้ำ '
    'ให้อิงพฤติกรรมที่พบจากรายชั่วโมง และต้องอ้างอิงตัวเลขหรือเกณฑ์ '
    'จากข้อมูลที่ให้มา ห้ามคิดค่าขึ้นเอง ถ้าไม่มีข้อมูลรายชั่วโมง '
    'ให้บอกตรงๆ ว่าข้อมูลไม่พอ)';

/// 📏 ความสูงของพื้นที่แท่งกราฟคาดการณ์ (พิกเซล) — แท่งที่ 100% จะสูงเต็มพื้นที่นี้
const double _forecastChartHeight = 118;

class _AiPageState extends State<AiPage> {
  final GeminiClient _gemini = GeminiClient();

  /// 📚 ตำแหน่งเก็บสถานะการเรียก Gemini ครั้งล่าสุด (แชร์กันทุกแท็บ/ทุกอุปกรณ์)
  final DatabaseReference _aiStateRef = FirebaseDatabase.instance.ref(
    'water_system/ai_state',
  );

  /// สถานะล่าสุดที่อ่านจาก Firebase (ใช้ตัดสินใจว่าจะเรียก Gemini ไหม)
  AiState _aiState = AiState.empty;

  /// งานโหลดสถานะจาก Firebase (รอให้เสร็จก่อนตัดสินใจยิง)
  Future<void>? _stateLoading;

  /// เวลาที่ "ส่งคำขอ" ครั้งล่าสุดในเซสชันนี้ (ใช้นาฬิกาเครื่อง)
  /// เก็บไว้เพื่อไม่ต้องพึ่งเวลาของเซิร์ฟเวอร์เวลานาฬิกาเครื่องไม่ตรงกัน
  DateTime? _lastAttemptLocal;

  WaterContextWatcher? _watcher;
  WaterSnapshot _snapshot = WaterSnapshot.empty;

  /// หมายเหตุ: คำตอบทั้งหมดของ AI ([สรุป] / [คาดการณ์] / [คำแนะนำ]) ยังถูกบันทึกไว้ที่
  /// water_system/ai_state (`last_narrative` / `last_forecast` / `last_tips`)
  /// เพื่อกันยิงซ้ำและให้ทุกแท็บเห็นตรงกัน แต่การ์ด "สรุปการใช้น้ำ" แสดงเฉพาะประโยค
  /// ที่คำนวณจากเกณฑ์ระดับน้ำ (water_tips.dart) จึงไม่เก็บ [คำแนะนำ] ไว้ในหน่วยความจำ

  /// ผลคาดการณ์ 5 วันจาก AI (null = ยังไม่มี หรือตอบไม่ถูกต้อง → ใช้สูตรระบบ)
  AiForecast? _forecast;

  String? _error;

  bool _isAnalyzing = false;
  bool _autoRequested = false;

  /// ⏰ ตัวจับเวลาตรวจว่า "ควรวิเคราะห์หรือยัง" ทุก kAiTickMinutes
  ///    (ไม่ใช่ยิงทุก 5 นาที — ai_policy.dart เป็นตัวตัดสินว่าจะยิงจริงไหม)
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _watcher = WaterContextWatcher(onSnapshot: _handleSnapshot)..start();
    _stateLoading = _loadAiState();

    // ⏰ ผู้ใช้เปิดแท็บนี้อยู่จึงเริ่มตัวจับเวลา (สลับแท็บไปที่อื่นจะหยุดให้)
    if (widget.isActive) _startTickTimer();
  }

  @override
  void didUpdateWidget(covariant AiPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive == widget.isActive) return;

    if (widget.isActive) {
      // กลับเข้าหน้า AI → เริ่มจับเวลาใหม่ + เช็คเงื่อนไขทันที (ครบเวลาก็ยิงเลย)
      _startTickTimer();
      unawaited(_maybeRunAnalysis(auto: true));
    } else {
      _stopTickTimer();
    }
  }

  @override
  void dispose() {
    _stopTickTimer();
    _watcher?.stop();
    _gemini.dispose();
    super.dispose();
  }

  // ⏰ ตัวจับเวลา (แค่ "ตื่นมาเช็คเงื่อนไข" — ไม่ได้แปลว่ายิงทุกครั้ง)
  void _startTickTimer() {
    _tickTimer ??= Timer.periodic(
      const Duration(minutes: kAiTickMinutes),
      (_) => _maybeRunAnalysis(auto: true),
    );
  }

  void _stopTickTimer() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  // ------------------------------------------------------------------
  // 💾 อ่าน/เขียนสถานะการเรียก Gemini ล่าสุด (water_system/ai_state)
  //    ทำให้เปิดแอปใหม่/รีสตาร์ท/เปิดหลายแท็บ ก็ไม่ยิงซ้ำซ้อน
  // ------------------------------------------------------------------
  Future<void> _loadAiState() async {
    try {
      final event = await _aiStateRef.once();
      final dynamic raw = event.snapshot.value;
      final AiState loaded = AiState.fromMap(
        raw is Map ? Map<dynamic, dynamic>.from(raw) : null,
      );
      if (!mounted) return;

      setState(() {
        _aiState = loaded;

        // นำผลคาดการณ์ 5 วันล่าสุดที่เคยบันทึกไว้กลับมาใช้หลังรีสตาร์ท/เปิดแอปซ้ำ
        // (ส่วน [สรุป] และ [คำแนะนำ] ของ AI ไม่ได้แสดงบนการ์ดแล้ว จึงไม่ต้องเก็บไว้)
        if ((loaded.lastForecast ?? '').trim().isNotEmpty) {
          _forecast = _forecastFromState(loaded);
        }
      });
    } catch (e) {
      debugPrint('อ่านสถานะ AI จาก Firebase ไม่สำเร็จ: $e');
    }
  }

  /// บันทึกว่า "ส่งคำขอแล้ว" — เรียกก่อนยิงจริงเสมอ
  /// ถ้า timeout หรือโควต้าหมด ก็ยังกันการยิงซ้ำรัว ๆ ได้
  Future<void> _markAttemptSent() async {
    try {
      await _aiStateRef.update(<String, Object?>{
        'last_attempt_at': ServerValue.timestamp,
      });
    } catch (e) {
      debugPrint('บันทึกเวลาส่งคำขอลง Firebase ไม่สำเร็จ: $e');
    }
  }

  /// บันทึกผลวิเคราะห์ที่ได้ + เงื่อนไข ณ ตอนที่ยิง (ไว้เทียบว่าข้อมูลเปลี่ยนไหม)
  Future<void> _saveAnalysisResult({
    required String narrative,
    required List<String> tips,
    required String? forecastRaw,
    required double percent,
    required double flowRate,
  }) async {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;

    // อัปเดตสำเนาในเครื่องก่อน เพื่อให้การตัดสินใจครั้งถัดไปแม่นทันที
    if (mounted) {
      setState(() {
        _aiState = _aiState.copyWith(
          lastAttemptAt: nowMs,
          lastSuccessAt: nowMs,
          lastPercent: percent,
          lastFlow: flowRate,
          lastNarrative: narrative,
          lastTips: tips,
          lastForecast: forecastRaw,
        );
      });
    }

    try {
      await _aiStateRef.update(<String, Object?>{
        'last_success_at': ServerValue.timestamp,
        'last_percent': percent,
        'last_flow': flowRate,
        'last_narrative': narrative,
        'last_tips': tips.join('\n'),
        'last_forecast': forecastRaw,
      });
    } catch (e) {
      // เขียนไม่ได้ก็ไม่เป็นไร (เช่น rule ปิดอยู่) — แอปยังทำงานต่อได้ปกติ
      debugPrint('บันทึกผลวิเคราะห์ลง Firebase ไม่สำเร็จ: $e');
    }
  }

  // ------------------------------------------------------------------
  // 👂 รับข้อมูลเรียลไทม์ + สั่งวิเคราะห์อัตโนมัติครั้งแรก
  // ------------------------------------------------------------------
  void _handleSnapshot(WaterSnapshot snapshot) {
    if (!mounted) return;
    final bool firstData = !_snapshot.hasData && snapshot.hasData;
    setState(() => _snapshot = snapshot);

    // พอได้ข้อมูลจริงครั้งแรก → ให้ AI วิเคราะห์ให้เลยโดยไม่ต้องกดอะไร
    if (firstData) unawaited(_autoAnalyze());
  }

  /// เรียกเมื่อได้ข้อมูลจริงครั้งแรก (ยังต้องผ่านเงื่อนไขของ ai_policy.dart อีกชั้น)
  Future<void> _autoAnalyze() async {
    if (_autoRequested) return;
    if (!_snapshot.hasData || !GeminiClient.hasApiKey) return;
    _autoRequested = true;

    // รอสถานะล่าสุดจาก Firebase ก่อน → เปิดแอปซ้ำ/รีสตาร์ทจะได้ไม่ยิงซ้ำ
    await _stateLoading;
    if (!mounted) return;
    await _maybeRunAnalysis(auto: true);
  }

  // ------------------------------------------------------------------
  // 🚦 เช็คเงื่อนไขก่อนยิง (ตรรกะทั้งหมดอยู่ใน ai_policy.dart) แล้วจึงยิงจริง
  // ------------------------------------------------------------------
  Future<void> _maybeRunAnalysis({required bool auto}) async {
    await _stateLoading;
    if (!mounted) return;

    final DateTime now = DateTime.now();
    final AiSkipReason reason = auto
        ? aiAutoDecision(
            state: _aiState,
            now: now,
            lastAttemptLocal: _lastAttemptLocal,
            hasApiKey: GeminiClient.hasApiKey,
            hasData: _snapshot.hasData,
            isAnalyzing: _isAnalyzing,
            percent: _snapshot.percent,
            flowRate: _snapshot.flowRate,
          )
        : aiManualDecision(
            state: _aiState,
            now: now,
            lastAttemptLocal: _lastAttemptLocal,
            hasApiKey: GeminiClient.hasApiKey,
            hasData: _snapshot.hasData,
            isAnalyzing: _isAnalyzing,
          );

    if (reason != AiSkipReason.none) {
      debugPrint('⏭️ ข้ามการเรียก Gemini (${reason.name})');

      if (!auto) {
        _showSkipSnack(
          aiSkipMessageThai(
            reason,
            state: _aiState,
            now: now,
            lastAttemptLocal: _lastAttemptLocal,
          ),
        );
      }

      return;
    }

    await _performRequest();
  }

  void _showSkipSnack(String message) {
    if (!mounted || message.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  // ------------------------------------------------------------------
  // 🧠 ขอ "บทสรุป + คำแนะนำ" จาก Gemini (ยิงจริง)
  // ------------------------------------------------------------------
  Future<void> _performRequest() async {
    if (_isAnalyzing) return;

    setState(() {
      _isAnalyzing = true;
      _error = null;
    });

    // 🧾 บันทึกว่า "ส่งคำขอแล้ว" ก่อนยิงจริง (ไม่รอผล)
    _lastAttemptLocal = DateTime.now();
    unawaited(_markAttemptSent());

    // จำค่า ณ ตอนที่ยิง ไว้บันทึกเป็นเกณฑ์เทียบ "ข้อมูลเปลี่ยนไหม" ครั้งถัดไป
    final double percentAtCall = _snapshot.percent;
    final double flowAtCall = _snapshot.flowRate;

    try {
      final String reply = await _gemini.generateAdvice(
        prompt: '$_systemPrompt\n\n$_analysisRequest',
        context:
            '${_snapshot.toPromptText()}\n\n${forecastDateContext(DateTime.now())}',
      );
      if (!mounted) return;

      final String narrative = narrativeOf(reply);
      final List<String> tips = tipsOf(reply);
      final AiForecast? forecast = forecastFromReply(
        reply,
        currentPercent: percentAtCall,
      );
      final String? forecastRaw = forecastBlockOf(reply);

      setState(() {
        _forecast = forecast;
        _isAnalyzing = false;
      });

      await _saveAnalysisResult(
        narrative: narrative,
        tips: tips,
        forecastRaw: forecastRaw,
        percent: percentAtCall,
        flowRate: flowAtCall,
      );
    } on GeminiException catch (e) {
      _failWith(e.message);
    } catch (e) {
      debugPrint('Unexpected AI error: $e');
      _failWith(
        'เกิดข้อผิดพลาดที่ไม่คาดคิด กรุณาลองใหม่อีกครั้ง\nรายละเอียด: $e',
      );
    }
  }

  void _failWith(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _isAnalyzing = false;
    });
  }

  // ------------------------------------------------------------------
  // 🧩 แยกคำตอบดิบของ AI (ย้ายไปไว้ที่ ai_reply.dart แล้ว — ดู narrativeOf/
  //    tipsOf/forecastFromReply) และแปลงผลคาดการณ์ที่บันทึกไว้กลับมาใช้
  // ------------------------------------------------------------------
  AiForecast? _forecastFromState(AiState state) {
    final String? raw = state.lastForecast;
    if (raw == null || raw.trim().isEmpty) return null;
    return forecastFromBlock(
      raw,
      currentPercent: state.lastPercent ?? _snapshot.percent,
    );
  }

  // ------------------------------------------------------------------
  // 🧮 ประโยคสรุปบรรทัดเดียวของการ์ด "AI วิเคราะห์การใช้น้ำ"
  //    คำนวณเองจากข้อมูลเซ็นเซอร์ (ไม่ต้องรอ AI จึงได้ข้อความคงที่ทุกครั้ง)
  //    • ค่าเฉลี่ยการใช้น้ำคิดจาก "วันเต็มวัน" เท่านั้น (ไม่นับวันนี้)
  //      และต้องครบ kMinFullDaysForAverage วัน (อยู่ใน water_context.dart)
  //    ตัวอย่าง: น้ำที่เหลือ 1485 ลิตร (74.3%) เพียงพอใช้ได้อีกประมาณ 25 วัน
  //              หากใช้น้ำในอัตราเดิม
  // ------------------------------------------------------------------
  String get _summaryLine {
    final WaterSnapshot s = _snapshot;
    final String liters = _fmtNum(s.currentLiters);
    final String percent = _fmtNum(s.percent);

    // ยังไม่มีค่าเฉลี่ยการใช้น้ำย้อนหลัง (หรือวันเต็มวันยังไม่ครบเกณฑ์)
    // → ประเมินจำนวนวันไม่ได้ จึงบอกไปตรง ๆ ว่าข้อมูลยังไม่พอ (ไม่เดาตัวเลข)
    if (s.estimatedDaysRemaining == null) {
      return 'น้ำที่เหลือ $liters ลิตร ($percent%) '
          'สถานะปัจจุบัน: ${s.statusLabel} • ยังประเมินจำนวนวันไม่ได้ '
          '(ข้อมูล ${s.recordedDays}/$kMinFullDaysForAverage วัน)';
    }

    final String days = _fmtNum(s.estimatedDaysRemaining!);
    return 'น้ำที่เหลือ $liters ลิตร ($percent%) '
        'เพียงพอใช้ได้อีกประมาณ $days วัน หากใช้น้ำในอัตราเดิม';
  }

  /// 🧾 จัดรูปแบบตัวเลข: ลงตัว → ไม่มีทศนิยม, ไม่ลงตัว → ทศนิยม 1 ตำแหน่ง
  String _fmtNum(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }

  /// 🕒 เวลาประมาณ (HH:MM) หลังผ่านไป [days] วันนับจากตอนนี้
  String _clockAfter(double days) {
    final DateTime t =
        DateTime.now().add(Duration(minutes: (days * 24 * 60).round()));
    final String hh = t.hour.toString().padLeft(2, '0');
    final String mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  // ------------------------------------------------------------------
  // 💡 คำแนะนำประหยัดน้ำ — ประโยคสรุปท้ายการ์ด "สรุปการใช้น้ำ"
  //      ใช้เกณฑ์ใน water_tips.dart เท่านั้น
  //      (70–100% → "ใช้น้ำได้ตามปกติ" / 0–69% → "กรุณาใช้น้ำแบบประหยัด")
  // ------------------------------------------------------------------
  WaterTipsResult get _tipsResult => buildWaterTips(_tipsInput());

  /// 📥 รวบรวมค่าจาก WaterSnapshot ส่งเข้า water_tips.dart
  WaterTipInput _tipsInput() {
    final WaterSnapshot s = _snapshot;
    return WaterTipInput(
      hasData: s.hasData,
      percent: s.percent,
      currentLiters: s.currentLiters,
      flowRate: s.flowRate,
      estimatedDaysRemaining: s.estimatedDaysRemaining,
    );
  }

  // ==================================================================
  // 🎨 ส่วนแสดงผล (แดชบอร์ด)
  // ==================================================================
  @override
  Widget build(BuildContext context) {
    final bool hasLevel = _snapshot.hasData && _snapshot.capacity > 0;

    return RefreshIndicator(
      // ดึงลงเพื่อสั่งวิเคราะห์ใหม่ (ผู้ใช้สั่งเอง) — ai_policy ยังกันกดรัว ๆ 60 วินาที
      onRefresh: () => _maybeRunAnalysis(auto: false),
      color: const Color(0xFF2F80ED),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (!GeminiClient.hasApiKey) ...<Widget>[
                  _buildSetupCard(),
                  const SizedBox(height: 12),
                ],
                _buildHeaderCard(),
                const SizedBox(height: 12),
                _buildStatRow(),
                if (hasLevel) ...<Widget>[
                  const SizedBox(height: 12),
                  _buildForecastCard(),
                ],
                const SizedBox(height: 12),
                _buildTipsCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // 🤖 การ์ด AI: อวตาร + ชื่อ + เวลาอัปเดต + บทวิเคราะห์ (ตัวเลขไฮไลต์สีส้ม)
  // ------------------------------------------------------------------
  Widget _buildHeaderCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFFEDE9FE),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.smart_toy_outlined,
                  color: Color(0xFF7C5CFF),
                  size: 26,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const SizedBox(height: 3),
                    const Text(
                      'AI วิเคราะห์การใช้น้ำ',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1F2937),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _buildNarrative(),
        ],
      ),
    );
  }

  /// 📄 เนื้อหาการ์ด "AI วิเคราะห์การใช้น้ำ" — แสดง "บรรทัดเดียว" เท่านั้น
  ///    (สถานะรอข้อมูล / กำลังโหลด / ผิดพลาด จะแสดงข้อความสั้น ๆ แทน)
  Widget _buildNarrative() {
    final String? err = _error;
    if (err != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF4F4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFFEB5757).withValues(alpha: 0.25),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 18, color: Color(0xFFEB5757)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                err,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFFB23A3A),
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // ⏳ ยังไม่มีข้อมูลจากเซ็นเซอร์ → ยังไม่ต้องแสดงประโยคสรุป
    if (!_snapshot.hasData) {
      return Row(
        children: <Widget>[
          if (_isAnalyzing) ...<Widget>[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              _isAnalyzing
                  ? 'กำลังวิเคราะห์ข้อมูลจากเซ็นเซอร์...'
                  : 'กำลังรอข้อมูลจากเซ็นเซอร์ในถังน้ำ... '
                        'พอระบบได้รับข้อมูลแล้ว จะวิเคราะห์ให้อัตโนมัติครับ',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 📄 ประโยคสรุปบรรทัดเดียว (ตัวเลขไฮไลต์สีส้ม)
        _highlightedText(_summaryLine),
        if (_isAnalyzing) ...<Widget>[
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                'กำลังอัปเดตข้อมูลล่าสุด...',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 🎨 ไฮไลต์ "ตัวเลข" ในบทวิเคราะห์ให้เป็นสีส้ม ตัวหนา อ่านง่ายขึ้น
  Widget _highlightedText(String text) {
    final RegExp numberPattern = RegExp(r'\d+(?:[.,]\d+)?');
    final List<TextSpan> spans = <TextSpan>[];
    int cursor = 0;

    for (final Match match in numberPattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: match.group(0),
          style: const TextStyle(
            color: Color(0xFFF2994A),
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(
      TextSpan(
        style: const TextStyle(
          fontSize: 13.5,
          height: 1.6,
          color: Color(0xFF37474F),
          fontWeight: FontWeight.w500,
        ),
        children: spans,
      ),
    );
  }

  // ------------------------------------------------------------------
  // 📊 การ์ดสถิติ 2 ใบ: น้ำที่ใช้ได้อีกกี่วัน + ค่าเฉลี่ยต่อวัน
  //    ค่าเฉลี่ยคิดจาก "วันเต็มวัน" เท่านั้น → ถ้ายังไม่ครบเกณฑ์จะโชว์ "--"
  //    พร้อมบรรทัดบอกที่มา "ข้อมูลยังไม่พอ N/3 วัน" เพื่อไม่ให้ผู้ใช้เข้าใจผิด
  // ------------------------------------------------------------------
  Widget _buildStatRow() {
    final WaterSnapshot s = _snapshot;
    final double? days = s.estimatedDaysRemaining;
    final String avg =
        s.hasReliableAverage ? _fmtNum(s.averageDailyLiters) : '--';

    final String note = s.hasReliableAverage
        ? 'จากวันเต็มวัน ${s.recordedDays} วัน'
        : 'ข้อมูลยังไม่พอ ${s.recordedDays}/$kMinFullDaysForAverage วัน';

    return Row(
      children: <Widget>[
        Expanded(
          child: _statCard(
            label: 'น้ำที่ใช้ได้อีก',
            value: days == null ? '--' : _fmtNum(days),
            unit: 'วัน',
            color: const Color(0xFFF2994A),
            icon: Icons.event_available_rounded,
            iconBg: const Color(0xFFFFF3E2),
            subtitle: days == null ? note : null,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _statCard(
            label: 'ค่าเฉลี่ย/วัน',
            value: avg,
            unit: 'ลิตร',
            color: const Color(0xFF2F80ED),
            icon: Icons.bar_chart_rounded,
            iconBg: const Color(0xFFE7F1FE),
            subtitle: note,
          ),
        ),
      ],
    );
  }

  Widget _statCard({
    required String label,
    required String value,
    required String unit,
    required Color color,
    required IconData icon,
    required Color iconBg,
    String? subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.grey.withValues(alpha: 0.08),
            spreadRadius: 1,
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 17, color: color),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: color,
                    height: 1.05,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  unit,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ),
            ],
          ),
          // 📅 บรรทัดเล็กบอกที่มาของตัวเลข (เช่น "จากวันเต็มวัน 5 วัน")
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                color: Color(0xFF6B7A8D),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // 📈 การ์ด "คาดการณ์จาก AI" — แนวโน้มระดับน้ำ 5 วัน
  //    • เปอร์เซ็นต์/ระดับความเสี่ยง "ยึดค่าเฉลี่ยการใช้น้ำ" (สูตรระบบ) เสมอ
  //      เพื่อให้สอดคล้องกับจำนวนวันคงเหลือและการ์ดค่าเฉลี่ย
  //    • AI ให้เฉพาะ "เหตุผลสั้น ๆ" ของแต่ละวัน (ใช้เป็นข้อความแนวโน้ม)
  // ------------------------------------------------------------------
  Widget _buildForecastCard() {
    final List<String> labels = forecastDateLabels(DateTime.now());
    final List<ForecastDay> days = _forecastDays();
    final Widget? insight = _forecastInsight(days);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: const Color(0xFFE7F1FE),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  Icons.auto_graph_rounded,
                  size: 17,
                  color: Color(0xFF2F80ED),
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'คาดการณ์จาก AI',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1F2937),
                  ),
                ),
              ),
            ],
          ),
          // แบนเนอร์เวลาที่คาดว่าน้ำจะหมด (ยึดค่าเฉลี่ยการใช้น้ำ)
          if (_snapshot.hasData && _snapshot.capacity > 0)
            _buildEtaBanner(labels),
          // ข้อความแนวโน้มสั้น ๆ จาก AI (ถ้ามีเหตุผลแนบมา)
          if (insight != null) ...<Widget>[
            const SizedBox(height: 10),
            insight,
          ],
          const SizedBox(height: 14),
          _forecastChart(days, labels),
          if (_isAnalyzing) ...<Widget>[
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                const Text(
                  'กำลังประเมินแนวโน้ม 5 วัน...',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7A8D)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
  /// 📅 สร้างรายการ 5 วันที่จะแสดง — "ยึดค่าเฉลี่ยการใช้น้ำ" ล้วน ๆ
  ///    เปอร์เซ็นต์คำนวณจาก averageDailyLiters (สูตรระบบ ผ่าน averageDrivenForecast)
  ///    ไม่ใช้ตัวเลขที่ AI เดาเอง (AI เหลือบทบาทแค่ให้เหตุผลสั้น ๆ เป็น "แนวโน้ม")
  List<ForecastDay> _forecastDays() {
    final AiForecast? ai = _forecast;
    final Map<int, String> notes = <int, String>{
      if (ai != null)
        for (final ForecastDay d in ai.days)
          if (d.note.isNotEmpty) d.day: d.note,
    };
    return averageDrivenForecast(
      currentPercent: _snapshot.percent,
      // ยังไม่ครบเกณฑ์วันเต็มวัน → ส่ง 0 เพื่อให้กราฟ "นิ่ง" ที่เปอร์เซ็นต์ปัจจุบัน
      // (ไม่เดาวันหมดจากตัวเลขที่ยังเชื่อถือไม่ได้)
      averageDailyLiters:
          _snapshot.hasReliableAverage ? _snapshot.averageDailyLiters : 0,
      capacity: _snapshot.capacity,
      notes: notes,
    );
  }

  /// ⏳ แบนเนอร์สรุปเวลาที่คาดว่าน้ำจะหมด — "ยึดค่าเฉลี่ย" (estimatedDaysRemaining)
  ///    วันหมด = จำนวนวันที่น้ำที่เหลือหารด้วยค่าเฉลี่ยต่อวัน (ปัดขึ้น)
  ///    ค่านี้เป็นค่าเดียวกับที่ใช้คิดจำนวนวันคงเหลือ จึงสอดคล้องกันเสมอ
  ///    ข้อมูลวันเต็มวันไม่ครบเกณฑ์ → บอกตรง ๆ ว่ายังประเมินไม่ได้ (ไม่เดา)
  Widget _buildEtaBanner(List<String> labels) {
    final WaterSnapshot s = _snapshot;
    final double? days = s.estimatedDaysRemaining;
    final String text;
    final String level;
    if (days == null) {
      text = 'ยังประเมินเวลาน้ำหมดไม่ได้ — ต้องมีข้อมูลอย่างน้อย '
          '$kMinFullDaysForAverage วันเต็มวัน (ตอนนี้ ${s.recordedDays} วัน)';
      level = 'info';
    } else if (days <= kForecastDays) {
      final int index = days.floor().clamp(0, labels.length - 1);
      final String label = labels[index];
      final String clock = _clockAfter(days);
      text = 'คาดว่าน้ำจะหมดประมาณ $label เวลาราว $clock น.';
      level = 'critical';
    } else {
      text = 'คาดว่าใช้ได้เกิน 5 วัน';
      level = 'info';
    }

    final Color color = notificationColorFor(level);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: <Widget>[
          Icon(notificationIconFor(level), size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: color,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
  /// 📊 กราฟแท่งแนวตั้ง 5 วัน (สไตล์แดชบอร์ดเดิม) — แท่งสูงตาม % สีตามระดับเสี่ยง
  Widget _forecastChart(List<ForecastDay> days, List<String> labels) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: _forecastChartHeight,
          child: Stack(
            children: <Widget>[
              // เส้นกริดแนวนอน (0 / 25 / 50 / 75 / 100% ของความสูง)
              Positioned.fill(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List<Widget>.generate(
                    5,
                    (_) => Container(
                      height: 1,
                      color: const Color(0xFFEEF2F6),
                    ),
                  ),
                ),
              ),
              // แท่งของแต่ละวัน (ชิดล่าง)
              Positioned.fill(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final ForecastDay day in days)
                      Expanded(child: _forecastBar(day)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 7),
        // ค่า % และป้ายวัน ใต้แท่งแต่ละแท่ง
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < days.length; i++)
              Expanded(
                child: Column(
                  children: <Widget>[
                    Text(
                      '${days[i].percent.toStringAsFixed(0)}%',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: notificationColorFor(days[i].level),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      i < labels.length ? labels[i] : 'วัน ${days[i].day}',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9.5,
                        height: 1.25,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF5B6B7C),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// 📊 หนึ่งแท่งแนวตั้ง (สูงตามเปอร์เซ็นต์ สีตามระดับความเสี่ยง)
  Widget _forecastBar(ForecastDay day) {
    final Color color = notificationColorFor(day.level);
    final double ratio = (day.percent / 100.0).clamp(0.0, 1.0);
    final double barHeight = (ratio * _forecastChartHeight)
        .clamp(6.0, _forecastChartHeight);

    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: 22,
        height: barHeight,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[color, color.withValues(alpha: 0.5)],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
        ),
      ),
    );
  }

  /// ✨ ข้อความแนวโน้มจาก AI (ของวันที่น่าเป็นห่วงที่สุด) — ว่างก็ไม่แสดง
  Widget? _forecastInsight(List<ForecastDay> days) {
    ForecastDay? pick;
    for (final ForecastDay d in days) {
      if (d.note.isEmpty) continue;
      if (pick == null || d.percent < pick.percent) pick = d;
    }
    if (pick == null) return null;
    final ForecastDay day = pick;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.auto_awesome, size: 14, color: Color(0xFF7C5CFF)),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            'แนวโน้ม: ${day.note}',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              fontWeight: FontWeight.w500,
              color: notificationColorFor(day.level),
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------
  // 📋 การ์ด "สรุปการใช้น้ำ" — แสดงตลอด (เว้นแต่ยังไม่มีข้อมูลจากเซ็นเซอร์)
  //      ประโยคสรุปบรรทัดเดียวจากเกณฑ์ระดับน้ำ (water_tips.dart)
  // ------------------------------------------------------------------
  Widget _buildTipsCard() {
    final WaterTipsResult result = _tipsResult;

    // 🚫 ยังไม่มีข้อมูลจากเซ็นเซอร์ → ไม่แสดงการ์ด
    //    (สถานะอื่นแสดงตลอด — ข้อความเปลี่ยนตามระดับน้ำ)
    if (!result.shouldShow) return const SizedBox.shrink();

    final WaterTip primary = result.tips.first; // เกณฑ์ระดับน้ำ (water_tips.dart)
    final String levelKey = primary.level.typeKey;
    final Color accent = notificationColorFor(levelKey);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // หัวการ์ด: ไอคอนตามระดับ + ชื่อการ์ด + ป้ายระดับ
          Row(
            children: <Widget>[
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  notificationIconFor(levelKey),
                  size: 17,
                  color: accent,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'สรุปการใช้น้ำ',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1F2937),
                  ),
                ),
              ),
              _levelChip(levelKey, accent),
            ],
          ),
          const SizedBox(height: 12),
          // ประโยคเดียว — สถานะน้ำ (%, ลิตร, วันที่ใช้ได้) + คำแนะนำตามเกณฑ์ระดับน้ำ
          _statusCallout(primary.text, levelKey, accent),
        ],
      ),
    );
  }

  /// 🏷️ ป้ายระดับความเสี่ยง (สีตามระดับ)
  Widget _levelChip(String levelKey, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        notificationLabelFor(levelKey),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.bold,
          color: accent,
        ),
      ),
    );
  }

  /// 📣 กล่องคำแนะนำรวม (พื้นสีอ่อน + ตัวอักษรเข้ม) — สถานะน้ำ + คำแนะนำตามเกณฑ์ระดับน้ำ
  Widget _statusCallout(String text, String levelKey, Color accent) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(notificationIconFor(levelKey), size: 18, color: accent),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF37474F),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // 🔑 การ์ดเตือนเมื่อยังไม่ได้ใส่ API Key
  // ------------------------------------------------------------------
  Widget _buildSetupCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.key_off, color: Colors.red.shade600, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'ยังไม่ได้ตั้งค่า Gemini API Key',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.red.shade700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'หน้าจอ AI ต้องใช้คีย์ฟรีจาก Google AI Studio\n'
            'รันแอปใหม่ด้วยคำสั่งนี้ แล้วระบบจะพร้อมใช้งานทันที:',
            style: TextStyle(
              fontSize: 12.5,
              color: Colors.grey.shade700,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const SelectableText(
              'flutter run --dart-define=GEMINI_API_KEY=<คีย์ของคุณ>',
              style: TextStyle(
                fontSize: 11.5,
                color: Colors.greenAccent,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // 🧰 ตัวช่วยสร้างการ์ดสีขาวมุมโค้ง ตามโทเคนดีไซน์ของทั้งแอป
  // ------------------------------------------------------------------
  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.grey.withValues(alpha: 0.08),
            spreadRadius: 1,
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: child,
    );
  }
}
