import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// =====================================================================
// 🔑 ค่าตั้งต้นของ Gemini อ่านจาก --dart-define ทั้งหมด (ห้าม hardcode API Key
//    ลงในซอร์สโค้ด — GitHub push protection จะบล็อกการ push ทันทีถ้าเจอ
//    และคีย์จะหลุดสู่สาธารณะถ้า repo เป็น public)
//
//    flutter run -d chrome --dart-define=GEMINI_API_KEY=<คีย์ของคุณ>
//
//    เปลี่ยนโมเดลได้ด้วย (ไม่ต้องแก้โค้ด)
//    flutter run --dart-define=GEMINI_API_KEY=<คีย์> --dart-define=GEMINI_MODEL=gemini-3.8-flash
//
//    หรือใช้ไฟล์รวมค่า (แนะนำ เพราะไม่ต้องพิมพ์ยาวทุกครั้ง)
//    flutter run --dart-define-from-file=env.json
//    โดย env.json หน้าตาเป็น
//    {"GEMINI_API_KEY": "<คีย์ของคุณ>", "GEMINI_MODEL": "gemini-2.5-flash"}
//
// ⚠️ ค่าจาก --dart-define ถูกคอมไพล์ลงในไฟล์แอป (APK/Web) ตอน build เท่านั้น
//    ไม่ได้อยู่ในซอร์สโค้ดที่ push ขึ้น git — ถ้าจะแจกแอปให้คนอื่นใช้โดยไม่ต้อง
//    ตั้งค่าเอง ให้ build ไฟล์แจกจ่าย (APK/Web) ด้วยคำสั่งข้างบนครั้งเดียวที่
//    เครื่องคุณ แล้วส่งไฟล์ที่ build เสร็จแล้วให้คนอื่น (ไม่ใช่ส่งซอร์สโค้ด)
// =====================================================================

/// API Key ของ Gemini (ว่าง = ยังไม่ได้ตั้งค่า)
const String kGeminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

/// โมเดลเริ่มต้น เปลี่ยนได้ตามต้องการผ่าน --dart-define=GEMINI_MODEL=...
const String kGeminiDefaultModel = String.fromEnvironment(
  'GEMINI_MODEL',
  defaultValue: 'gemini-2.5-flash',
);

/// 🚫 ข้อผิดพลาดที่แปลงเป็นข้อความภาษาไทยพร้อมแสดงบนหน้าจอแล้ว
class GeminiException implements Exception {
  final String message;
  final int? statusCode;

  const GeminiException(this.message, {this.statusCode});

  @override
  String toString() => 'GeminiException(${statusCode ?? '-'}): $message';
}

/// 🧩 หนึ่งบทสนทนาย่อย ใช้ส่งประวัติการคุยกลับไปให้โมเดลจำบริบท
class GeminiTurn {
  final String role; // 'user' หรือ 'model'
  final String text;

  const GeminiTurn(this.role, this.text);


  Map<String, dynamic> toJson() => <String, dynamic>{
    'role': role,
    'parts': [
      {'text': text},
    ],
  };
}

// =====================================================================
// 🤖 GeminiClient — ตัวเรียก REST API ของ Google Gemini
//    endpoint มาตรฐาน: POST /v1beta/models/{model}:generateContent
//    (Google ยังสนับสนุนเต็มรูปแบบ แม้จะมี Interactions API ตัวใหม่แล้ว)
// =====================================================================
class GeminiClient {
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  static const Duration _timeout = Duration(seconds: 45);

  final http.Client _client;

  GeminiClient({http.Client? client}) : _client = client ?? http.Client();

  /// มี API Key พร้อมใช้งานหรือยัง (ใช้โชว์การ์ดตั้งค่าในหน้าจอ AI)
  static bool get hasApiKey => kGeminiApiKey.trim().isNotEmpty;

  /// โมเดลที่สั่งปิด "โหมดคิด" ได้ เพื่อไม่ให้โทเคนคิดไปกินโควตาคำตอบ
  /// (ทดสอบกับ API จริงแล้ว: ตระกูล 2.5 flash ตอบครบถ้วนเมื่อ thinkingBudget = 0
  ///  ส่วนรุ่น 3.x ส่งค่านี้ไปแล้วจะถูกมองข้าม จึงไม่ต้องส่งให้เปล่า ๆ)
  static bool _canDisableThinking(String model) =>
      model == 'gemini-2.5-flash' || model == 'gemini-2.5-flash-lite';

  /// 📤 ส่งคำถามไปให้ Gemini แล้วคืนข้อความคำตอบ
  ///
  /// [prompt]  คำถาม/คำสั่งของผู้ใช้
  /// [context] ข้อมูลประกอบ (สถานะถังน้ำ ฯลฯ) จะถูกแปะไว้ข้างหน้าคำถาม
  /// [history] ประวัติการคุยที่ผ่านมา เพื่อให้โมเดลจำบริบทได้
  /// [model]   ระบุโมเดลเอง ถ้าไม่ใส่จะใช้ [kGeminiDefaultModel]
  Future<String> generateAdvice({
    required String prompt,
    String? context,
    List<GeminiTurn> history = const <GeminiTurn>[],
    String? model,
  }) async {
    if (!hasApiKey) {
      throw const GeminiException(
        'ยังไม่ได้ตั้งค่า GEMINI_API_KEY\n'
        'กรุณารันแอปใหม่ด้วยคำสั่ง:\n'
        'flutter run --dart-define=GEMINI_API_KEY=<คีย์ของคุณ>',
      );
    }

    // เลือกโมเดล: หน้าจอ AI ไม่ส่ง model มา จึงใช้ค่าเริ่มต้นจาก --dart-define
    // ⚠️ ห้ามใช้เครื่องหมาย ! กับ model เด็ดขาด เพราะบน Flutter Web (DDC)
    //    จะโยน Unexpected null value. ทันทีเมื่อ model เป็น null
    final String requestedModel = (model ?? '').trim();
    final String targetModel = requestedModel.isEmpty
        ? kGeminiDefaultModel
        : requestedModel;

    final StringBuffer buffer = StringBuffer();
    if (context != null && context.trim().isNotEmpty) {
      buffer.writeln('=== ข้อมูลจริงจากระบบ (ใช้ประกอบการวิเคราะห์) ===');
      buffer.writeln(context.trim());
      buffer.writeln('=== จบข้อมูลจริง ===');
      buffer.writeln();
    }
    buffer.write(prompt.trim());

    final List<GeminiTurn> turns = <GeminiTurn>[
      ...history,
      GeminiTurn('user', buffer.toString()),
    ];

    final Uri uri = Uri.parse('$_baseUrl/$targetModel:generateContent');
    final Map<String, dynamic> generationConfig = <String, dynamic>{
      'temperature': 0.7,
      // ⚠️ เผื่อโควตาไว้ให้ "โทเคนคิด" ของโมเดลรุ่นใหม่ด้วย
      //    ถ้าตั้งน้อย (เช่น 1024) คำตอบจะถูกตัดกลางประโยคโดยไม่ขึ้น error
      'maxOutputTokens': 4096,
      'topP': 0.95,
    };

    // โมเดลตระกูล 2.5 flash ปิด "โหมดคิด" ได้ → ตอบเร็ว ถูก และไม่กินโควตาจนคำตอบขาด
    // (2.5 pro ปิดไม่ได้ / รุ่น 3.x ส่งค่านี้ไปแล้วจะถูกมองข้าม)
    if (_canDisableThinking(targetModel)) {
      generationConfig['thinkingConfig'] = <String, dynamic>{'thinkingBudget': 0};
    }

    final Map<String, dynamic> body = <String, dynamic>{
      'contents': turns.map((t) => t.toJson()).toList(),
      'generationConfig': generationConfig,
    };

    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json; charset=utf-8',
              'x-goog-api-key': kGeminiApiKey.trim(),
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const GeminiException(
        'หมดเวลารอคำตอบจาก Gemini (45 วินาที) กรุณาลองใหม่อีกครั้ง',
      );
    } catch (e) {
      debugPrint('Gemini network error: $e');
      throw const GeminiException(
        'เชื่อมต่อเซิร์ฟเวอร์ Gemini ไม่สำเร็จ\n'
        'กรุณาตรวจสอบการเชื่อมต่ออินเทอร์เน็ตของอุปกรณ์',
      );
    }

    if (response.statusCode != 200) {
      throw GeminiException(
        _thaiMessageForStatus(response.statusCode, targetModel, response.body),
        statusCode: response.statusCode,
      );
    }

    return _extractText(response.body);
  }

  /// 📖 ดึงข้อความจาก JSON ที่ Gemini ตอบกลับมา
  /// โครงสร้าง: { candidates: [ { content: { parts: [ { text: "..." } ] } } ] }
  String _extractText(String rawBody) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(rawBody) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Gemini decode error: $e');
      throw const GeminiException('อ่านคำตอบจาก Gemini ไม่ได้ (รูปแบบไม่ถูกต้อง)');
    }

    // กรณี Google ปิดกั้นคำถามด้วยนโยบายความปลอดภัย
    final promptFeedback = data['promptFeedback'];
    if (promptFeedback is Map && (promptFeedback['blockReason'] ?? '') != '') {
      throw GeminiException(
        'คำถามนี้ถูกปิดกั้นด้วยนโยบายความปลอดภัยของ Gemini '
        '(${promptFeedback['blockReason']})\nกรุณาเปลี่ยนคำถามแล้วลองใหม่',
      );
    }

    final candidates = data['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final candidate = candidates.first;
      if (candidate is Map) {
        final content = candidate['content'];
        if (content is Map) {
          final parts = content['parts'];
          if (parts is List) {
            final String joined = parts
                .whereType<Map>()
                .map((p) => (p['text'] ?? '').toString())
                .join()
                .trim();
            if (joined.isNotEmpty) return joined;
          }
        }
        final finishReason = (candidate['finishReason'] ?? '').toString();
        if (finishReason == 'MAX_TOKENS') {
          return 'คำตอบยาวเกินขอบเขตที่กำหนด กรุณาถามให้สั้นลงหรือเจาะจงขึ้น';
        }
        if (finishReason == 'SAFETY' || finishReason == 'RECITATION') {
          throw GeminiException(
            'Gemini ไม่สามารถตอบคำถามนี้ได้ (เหตุผล: $finishReason)\n'
            'กรุณาเปลี่ยนคำถามแล้วลองใหม่',
          );
        }
      }
    }

    throw const GeminiException('Gemini ตอบกลับมาโดยไม่มีข้อความ กรุณาลองใหม่');
  }

  /// 🇹🇭 แปลงรหัสข้อผิดพลาด HTTP เป็นคำอธิบายภาษาไทยที่ผู้ใช้แก้ไขเองได้
  String _thaiMessageForStatus(int status, String model, String body) {
    String detail = '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        detail = (decoded['error']['message'] ?? '').toString();
      }
    } catch (_) {
      detail = '';
    }
    final String suffix = detail.isEmpty ? '' : '\n($detail)';

    switch (status) {
      case 400:
        return 'คำขอไม่ถูกต้อง อาจใช้ชื่อโมเดล "$model" ไม่ถูกต้อง\n'
            'ลองแก้ค่า GEMINI_MODEL ใน env.json แล้วรันแอปใหม่$suffix';
      case 401:
      case 403:
        return 'API Key ไม่ถูกต้อง หรือไม่มีสิทธิ์เรียกใช้งาน Gemini\n'
            'กรุณาตรวจสอบคีย์ใน Google AI Studio แล้วรันแอปใหม่$suffix';
      case 404:
        return 'ไม่พบโมเดล "$model" สำหรับ API Key นี้\n'
            'กรุณาแก้ค่า GEMINI_MODEL ใน env.json แล้วรันแอปใหม่$suffix';
      case 429:
        return 'เรียกใช้งานเกินโควตาของ API Key นี้\n'
            'กรุณารอสักครู่แล้วลองใหม่ หรือใช้คีย์อื่น$suffix';
      case 500:
      case 503:
        return 'เซิร์ฟเวอร์ของ Gemini ขัดข้องชั่วคราว กรุณาลองใหม่ในอีกสักครู่$suffix';
      default:
        if (status >= 500) {
          return 'เซิร์ฟเวอร์ของ Gemini ขัดข้องชั่วคราว (HTTP $status)$suffix';
        }
        return 'เรียก Gemini ไม่สำเร็จ (HTTP $status)$suffix';
    }
  }

  void dispose() => _client.close();
}
