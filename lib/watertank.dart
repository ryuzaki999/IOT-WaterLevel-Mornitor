import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'history.dart'; // นำเข้าหน้า HistoryPage เพื่อใช้ใน BottomNavigationBar
import 'notification.dart'; // นำเข้าหน้า NotificationPage เพื่อใช้ใน BottomNavigationBar
import 'ai_page.dart'; // นำเข้าหน้า AiPage (ผู้ช่วย AI วิเคราะห์การใช้น้ำ)
import 'notification_service.dart'; // ระบบเขียนการแจ้งเตือนอัตโนมัติ + เฝ้าดูสถานะถังน้ำ

class WaterTankPage extends StatefulWidget {
  const WaterTankPage({super.key});

  @override
  State<WaterTankPage> createState() => _WaterTankPageState();
}

class _WaterTankPageState extends State<WaterTankPage>
    with TickerProviderStateMixin {
  // อ้างอิงพิกัด Firebase ไปที่ปมหลัก 'water_system'
  final DatabaseReference _monitorRef = FirebaseDatabase.instance.ref(
    'water_system',
  );
  StreamSubscription<DatabaseEvent>? _streamSubscription;

  // 🔔 ตัวเฝ้าดูสถานะถังน้ำ แล้วเขียนการแจ้งเตือนอัตโนมัติลง Firebase
  late final TankAlertWatcher _alertWatcher;

  // ตัวแปรสำหรับเก็บข้อมูลเรียลไทม์ที่ดึงมาจาก Firebase
  double _currentLiters = 0;
  double _flowRate = 0.0;
  double _maxCapacity = 400.0;
  bool _isLoading = true;

  // 🔢 จำนวนการแจ้งเตือนที่ยังไม่อ่าน (แสดงป้ายตัวเลขบนไอคอนระฆังมุมขวาบน)
  int _unreadCount = 0;
  StreamSubscription<DatabaseEvent>? _notiSubscription;

  // ตำแหน่งหน้าปัจจุบันที่เลือกใน BottomNavigationBar
  int _selectedIndex = 0;

  // 🌊 ตัวควบคุมแอนิเมชันคลื่นน้ำ (วนลูปตลอดเวลาให้น้ำดูไหลลื่น)
  late final AnimationController _waveController;
  // 🎯 ตัวแปรสำหรับ Tween ระดับน้ำ ให้เปลี่ยนค่าอย่างนุ่มนวลเวลาข้อมูลอัปเดต
  double _displayedPercent = 0.0;

  // ⬆️ ตัวควบคุมแอนิเมชันตอนเข้าหน้า (เลื่อนขึ้นจากด้านล่างพร้อมค่อยๆ ปรากฏ)
  late final AnimationController _entranceController;
  late final Animation<double> _entranceFade;
  late final Animation<Offset> _entranceSlide;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _entranceFade = CurvedAnimation(
      parent: _entranceController,
      curve: Curves.easeOut,
    );
    _entranceSlide =
        Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _entranceController,
            curve: Curves.easeOutCubic,
          ),
        );
    _entranceController.forward();

    // 🚀 เริ่มต้นการดักฟังข้อมูลเรียลไทม์จาก Firebase แบบปลอดภัย
    _initFirebaseStream();

    // 🔔 เริ่มเฝ้าดูสถานะถัง แล้วเขียนการแจ้งเตือนอัตโนมัติเมื่อถึงเกณฑ์
    //    (ต่ำกว่า 20% = วิกฤต, ต่ำกว่า 50% = ควรระวัง, ไหลผิดปกติ ฯลฯ)
    _alertWatcher = TankAlertWatcher(onAlert: _handleTankAlert);
    _alertWatcher.start();

    // 🔢 ดักฟังจำนวนการแจ้งเตือนที่ยังไม่อ่าน เพื่อโชว์ป้ายบนไอคอนระฆัง
    _initUnreadBadge();
  }

  // -----------------------------------------------------------------
  // 🔢 นับจำนวนการแจ้งเตือนที่ยังไม่อ่าน (is_read == false) แบบเรียลไทม์
  // -----------------------------------------------------------------
  void _initUnreadBadge() {
    final notiRef = FirebaseDatabase.instance.ref('water_system/notifications');
    _notiSubscription = notiRef.onValue.listen((event) {
      if (!mounted) return;
      final value = event.snapshot.value;
      int unread = 0;
      if (value is Map) {
        final data = Map<dynamic, dynamic>.from(value);
        for (final entry in data.values) {
          if (entry is Map && entry['is_read'] == false) unread++;
        }
      }
      if (unread != _unreadCount) {
        setState(() => _unreadCount = unread);
      }
    });
  }

  void _initFirebaseStream() {
    _streamSubscription = _monitorRef.onValue.listen(
      (event) {
        if (!mounted) return;

        final rootValue = event.snapshot.value;
        if (rootValue != null) {
          try {
            final rootData = Map<dynamic, dynamic>.from(rootValue as Map);

            // ดึงข้อมูลลูกปม 'monitor'
            final monitorData = rootData['monitor'] != null
                ? Map<dynamic, dynamic>.from(rootData['monitor'] as Map)
                : {};

            // ดึงข้อมูลลูกปม 'setting'
            final settingData = rootData['setting'] != null
                ? Map<dynamic, dynamic>.from(rootData['setting'] as Map)
                : {};

            setState(() {
              _currentLiters = (monitorData['water_level_liters'] ?? 0).toDouble();
              _flowRate = (monitorData['flow_rate_min'] ?? 0.0).toDouble();
              _maxCapacity = (settingData['tank_capacity'] ?? 400.0).toDouble();
              _isLoading = false;
            });
          } catch (e) {
            debugPrint('Error parsing Firebase data in WaterTankPage: $e');
          }
        } else {
          setState(() {
            _isLoading = false;
          });
        }
      },
      onError: (error) {
        debugPrint('Firebase Stream Error: $error');
      },
    );
  }

  // -----------------------------------------------------------------
  // 🔔 เด้ง SnackBar ทันทีเมื่อมีการแจ้งเตือนใหม่ถูกเขียนลง Firebase
  // -----------------------------------------------------------------
  void _handleTankAlert(TankAlert alert) {
    if (!mounted) return;
    // ถ้าผู้ใช้เปิดหน้าจอการแจ้งเตือนอยู่แล้ว ก็ไม่ต้องเด้งซ้ำ
    if (_selectedIndex == 3) return;

    // 🎨 ใช้สี/ไอคอนชุดเดียวกับหน้าแจ้งเตือน (notification.dart) กันข้อความไม่ตรงกัน
    final Color color = notificationColorFor(alert.type);
    final IconData icon = notificationIconFor(alert.type);

    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: color,
        duration: const Duration(seconds: 5),
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    alert.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    alert.message,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'ดูทั้งหมด',
          textColor: Colors.white,
          onPressed: () {
            if (mounted) setState(() => _selectedIndex = 3);
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    // 🚀 ปิดและทำลายตัวเชื่อมต่อสตรีมทันทีเมื่อปิดหน้านี้ เพื่อคืนพื้นที่แรม ป้องกันแอปค้าง
    _streamSubscription?.cancel();
    _notiSubscription?.cancel();
    _alertWatcher.stop();
    _waveController.dispose();
    _entranceController.dispose();
    super.dispose();
  }

  // 🔴🟡🟢 ฟังก์ชันเลือกสีน้ำตามระดับเปอร์เซ็นต์
  Color _getWaterColor(double percent) {
    if (percent <= 25.0) {
      return Colors.red.shade400; // ระดับวิกฤต (น้ำต่ำมาก)
    } else if (percent <= 50.0) {
      return Colors.orange.shade400; // ระดับเตือนภัย (น้ำเริ่มน้อย)
    } else {
      return Colors.blue.shade300; // ระดับปกติ
    }
  }

  // 🟢🟡🔴 สีจุดสถานะบอกระดับน้ำ (เขียว = ปกติ, เหลือง = ควรระวัง, แดง = วิกฤต)
  Color _getStatusDotColor(double percent) {
    if (percent <= 25.0) {
      return Colors.red;
    } else if (percent <= 50.0) {
      return Colors.amber.shade600;
    } else {
      return Colors.green;
    }
  }

  // 📝 ข้อความอธิบายสถานะคู่กับจุดสี
  String _getStatusText(double percent) {
    if (percent <= 25.0) {
      return 'ระดับน้ำวิกฤต';
    } else if (percent <= 50.0) {
      return 'ควรระวังการใช้น้ำ';
    } else {
      return 'ปกติ';
    }
  }

  // 🌈 สีไล่ระดับของน้ำ ให้ตัวถังดูมีมิติมากกว่าสีทึบเดิม
  List<Color> _getWaterGradient(double percent) {
    if (percent <= 25.0) {
      return [Colors.red.shade200, Colors.red.shade400];
    } else if (percent <= 50.0) {
      return [Colors.orange.shade200, Colors.orange.shade400];
    } else {
      return [Colors.blue.shade200, Colors.blue.shade400];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEAF3FB),
      appBar: AppBar(
        title: Text(_getAppBarTitle(_selectedIndex)),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1F2937),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.bold,
          color: Color(0xFF1F2937),
        ),
        leadingWidth: 60,
        leading: _selectedIndex == 0
            ? const Padding(
                padding: EdgeInsets.only(left: 16),
                child: Icon(
                  Icons.water_drop_rounded,
                  color: Color(0xFF2F80ED),
                  size: 24,
                ),
              )
            : Padding(
                padding: const EdgeInsets.only(left: 12),
                child: _AppBarCircleButton(
                  icon: Icons.arrow_back_ios_new_rounded,
                  tooltip: 'กลับหน้าแรก',
                  onTap: () => setState(() => _selectedIndex = 0),
                ),
              ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _AppBarCircleButton(
              icon: Icons.notifications_none_rounded,
              tooltip: 'การแจ้งเตือน',
              badgeCount: _unreadCount,
              onTap: () => setState(() => _selectedIndex = 3),
            ),
          ),
        ],
      ),

      body: IndexedStack(
        index: _selectedIndex,
        children: [
          _buildMainWaterTankView(), // ดัชนี 0: หน้าถังน้ำเรียลไทม์
          const HistoryPage(), // ดัชนี 1: หน้าจอประวัติการใช้น้ำ
          AiPage(isActive: _selectedIndex == 2), // ดัชนี 2: หน้าจอผู้ช่วย AI (หยุดวิเคราะห์อัตโนมัติเมื่อไม่ได้เปิดแท็บนี้)
          const NotificationPage(), // ดัชนี 3: หน้าจอการแจ้งเตือน
        ],
      ),

      // 📱 แถบเมนูด้านล่าง (Bottom Navigation Bar)
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 14,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: (int index) {
            setState(() {
              _selectedIndex = index;
            });
          },
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.white,
          elevation: 0,
          selectedItemColor: const Color(0xFF2F80ED),
          unselectedItemColor: Colors.grey.shade500,
          selectedFontSize: 11.5,
          unselectedFontSize: 11,
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.water_drop_outlined),
              activeIcon: Icon(Icons.water_drop),
              label: 'ระดับน้ำ',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.insert_chart_outlined_rounded),
              activeIcon: Icon(Icons.insert_chart_rounded),
              label: 'ประวัติ',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.smart_toy_outlined),
              activeIcon: Icon(Icons.smart_toy),
              label: 'AI',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.notifications_none_rounded),
              activeIcon: Icon(Icons.notifications_rounded),
              label: 'การแจ้งเตือน',
            ),
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------------------------
  // 🟢 ฟังก์ชันหน้าตาหลักส่วนแสดงผลแทงค์น้ำ
  // -----------------------------------------------------------------
  Widget _buildMainWaterTankView() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 13),
            Text('กำลังเชื่อมต่อฐานข้อมูลแทงค์น้ำ...'),
          ],
        ),
      );
    }

    // คำนวณเปอร์เซ็นต์น้ำในถัง
    double waterPercent = (_currentLiters / _maxCapacity) * 100;
    if (waterPercent > 100) waterPercent = 100;
    if (waterPercent < 0) waterPercent = 0;

    bool isFlowing = _flowRate > 0;

    // เรียกดึงสีตามระดับน้ำปัจจุบัน
    Color currentWaterColor = _getWaterColor(waterPercent);
    List<Color> waterGradient = _getWaterGradient(waterPercent);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          // ⬆️ แอนิเมชันเลื่อนขึ้นจากด้านล่างพร้อมค่อยๆ ปรากฏตอนเข้าหน้านี้
          child: SlideTransition(
            position: _entranceSlide,
            child: FadeTransition(
              opacity: _entranceFade,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 10),

                  // 🏷️ ป้ายแสดงความจุทั้งหมด (อยู่ด้านบนสุดของแทงค์น้ำ)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.grey.shade400, width: 1),
                    ),
                    child: Text(
                      'ความจุถังทั้งหมด: ${_maxCapacity.toInt()} ลิตร',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 🛢️ ภาพกราฟิกตัวถังน้ำและเอฟเฟกต์คลื่นน้ำเคลื่อนไหวแบบ smooth
                  Container(
                    width: 500.0, // กำหนดความกว้างของ Container
                    height: 320.0, // กำหนดความสูงของ Container
                    alignment:
                        Alignment.center, // จัดให้ Stack อยู่ตรงกลางกล่อง
                    padding: const EdgeInsets.all(
                      20.0,
                    ), // ขยาย Padding ให้กว้างขึ้น
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16.0),
                      border: Border.all(color: Colors.grey.shade200),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.withOpacity(0.08),
                          spreadRadius: 1,
                          blurRadius: 6,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Stack(
                          alignment: Alignment.bottomCenter,
                          children: [
                            // ตัวถังพื้นหลัง (ขอบถัง)
                            Container(
                              width: 160,
                              height: 240,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                border: Border.all(
                                  color: const Color.fromARGB(255, 53, 55, 56),
                                  width: 4,
                                ),
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(20),
                                  bottom: Radius.circular(10),
                                ),
                              ),
                            ),
                            // 🌊 คลื่นน้ำเคลื่อนไหวภายในถัง ครอบด้วย ClipRRect ให้โค้งตามขอบถัง
                            ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(18),
                                bottom: Radius.circular(8),
                              ),
                              child: SizedBox(
                                width: 152,
                                height: 232,
                                child: TweenAnimationBuilder<double>(
                                  // 🎯 ค่อยๆ ไล่ระดับน้ำจากค่าเดิมไปค่าใหม่อย่างนุ่มนวลเมื่อข้อมูลเปลี่ยน
                                  tween: Tween<double>(
                                    begin: _displayedPercent,
                                    end: waterPercent,
                                  ),
                                  duration: const Duration(milliseconds: 800),
                                  curve: Curves.easeInOutCubic,
                                  onEnd: () {
                                    _displayedPercent = waterPercent;
                                  },
                                  builder: (context, animatedPercent, child) {
                                    return AnimatedBuilder(
                                      animation: _waveController,
                                      builder: (context, _) {
                                        return CustomPaint(
                                          painter: _WavePainter(
                                            progress: animatedPercent / 100,
                                            phase: _waveController.value,
                                            colors: waterGradient,
                                          ),
                                          size: const Size(152, 232),
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                            ),
                            // ตัวเลขเปอร์เซ็นต์กลางถัง
                            Padding(
                              padding: const EdgeInsets.only(bottom: 100),
                              child: Text(
                                '${waterPercent.toStringAsFixed(1)}%',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  color: waterPercent > 55
                                      ? Colors.white
                                      : const Color.fromARGB(255, 0, 0, 0),
                                  shadows: const [
                                    Shadow(
                                      color: Colors.black26,
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 6),
                        // 📏 สเกลตัวเลขบอกปริมาณน้ำด้านข้างถัง (100 -> 0)
                        SizedBox(
                          height: 240,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [100, 75, 50, 25, 0].map((mark) {
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 6,
                                    height: 1.5,
                                    color: Colors.grey.shade400,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '$mark',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 15),

                  // 📊 1. การ์ดแสดงระดับน้ำเป็นเปอร์เซ็นต์และหลอดวัดระดับ
                  Container(
                    padding: const EdgeInsets.all(20.0),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18.0),
                      border: Border.all(
                        color: const Color.fromARGB(255, 30, 30, 30),
                        width: 1.6,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.12),
                          spreadRadius: 0,
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.shade50,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(
                                    Icons.water_damage,
                                    color: Colors.blue,
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'ระดับน้ำในแทงค์',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: Color.fromARGB(255, 95, 95, 95),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${waterPercent.toStringAsFixed(0)}%',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: currentWaterColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            // 🟢🟡🔴 จุดสถานะบอกระดับน้ำ มุมขวาบนของการ์ด
                            Tooltip(
                              message: _getStatusText(waterPercent),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: _getStatusDotColor(waterPercent),
                                      boxShadow: [
                                        BoxShadow(
                                          color: _getStatusDotColor(
                                            waterPercent,
                                          ).withOpacity(0.5),
                                          blurRadius: 6,
                                          spreadRadius: 1,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _getStatusText(waterPercent),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: _getStatusDotColor(waterPercent),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: TweenAnimationBuilder<double>(
                            tween: Tween<double>(
                              begin: 0,
                              end: (waterPercent / 100).clamp(0.0, 1.0),
                            ),
                            duration: const Duration(milliseconds: 800),
                            curve: Curves.easeInOutCubic,
                            builder: (context, value, _) {
                              return LinearProgressIndicator(
                                value: value,
                                minHeight: 10,
                                backgroundColor: const Color.fromARGB(
                                  255,
                                  222,
                                  236,
                                  243,
                                ),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  currentWaterColor,
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  // 💧 2. การ์ดแสดงปริมาณน้ำในแทงค์ (นำข้อความความจุทั้งหมดออกเรียบร้อยแล้ว)
                  Container(
                    padding: const EdgeInsets.all(20.0),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18.0),
                      border: Border.all(
                        color: const Color.fromARGB(255, 30, 30, 30),
                        width: 1.6,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.12),
                          spreadRadius: 0,
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.shade50,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(
                                    Icons.opacity,
                                    color: Colors.blue,
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'ปริมาณน้ำปัจจุบัน',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: Color.fromARGB(255, 95, 95, 95),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${_currentLiters.toStringAsFixed(1)} / ${_maxCapacity.toInt()} ลิตร',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: currentWaterColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        // หลอดวัดระดับน้ำ
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: (waterPercent / 100).clamp(0.0, 1.0),
                            minHeight: 10,
                            backgroundColor: const Color.fromARGB(
                              255,
                              222,
                              236,
                              243,
                            ),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              currentWaterColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  // ⚡ 3. การ์ดแสดงสถานะการไหลและอัตราการไหล
                  Container(
                    padding: const EdgeInsets.all(20.0),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18.0),
                      border: Border.all(
                        color: const Color.fromARGB(255, 30, 30, 30),
                        width: 1.6,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.12),
                          spreadRadius: 0,
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: isFlowing
                                    ? Colors.green.shade50
                                    : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                isFlowing ? Icons.waves : Icons.pause_circle,
                                color: isFlowing ? Colors.green : Colors.grey,
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'สถานะการไหล',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  isFlowing
                                      ? 'กำลังไหล (Flowing)'
                                      : 'น้ำหยุดนิ่ง (Idle)',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: isFlowing
                                        ? Colors.green
                                        : Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        Text(
                          '${_flowRate.toStringAsFixed(1)} L/min',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.blueAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ฟังก์ชันสลับชื่อพาดหัวบนแถบ AppBar
  String _getAppBarTitle(int index) {
    switch (index) {
      case 0:
        return 'ปริมาณน้ำในแทงค์ (Real-time)';
      case 1:
        return 'ประวัติการใช้น้ำ';
      case 2:
        return 'ผู้ช่วย AI วิเคราะห์การใช้น้ำ';
      case 3:
        return 'การแจ้งเตือน';
      default:
        return 'Water Tank IoT';
    }
  }
}

// 🧊 ปุ่มไอคอนทรงกลมมนบนแถบ AppBar (ให้เข้ากับดีไซน์การ์ดมุมโค้งของทั้งแอป)
class _AppBarCircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final int badgeCount;

  const _AppBarCircleButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Tooltip(
            message: tooltip,
            child: Material(
              color: const Color(0xFFF2F7FD),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(icon, size: 18, color: const Color(0xFF2F80ED)),
                ),
              ),
            ),
          ),
          if (badgeCount > 0)
            Positioned(
              top: -4,
              right: -4,
              child: _UnreadBadge(count: badgeCount),
            ),
        ],
      ),
    );
  }
}

// 🔴 ป้ายตัวเลขสีแดงแสดงจำนวนการแจ้งเตือนที่ยังไม่อ่าน
class _UnreadBadge extends StatelessWidget {
  final int count;

  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final String label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFFEB5757),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          height: 1,
        ),
      ),
    );
  }
}

// 🌊 CustomPainter วาดคลื่นน้ำเคลื่อนไหวภายในถัง พร้อมไล่สีให้ดูมีมิติและ smooth
class _WavePainter extends CustomPainter {
  final double progress; // 0.0 - 1.0 ระดับน้ำปัจจุบัน
  final double phase; // 0.0 - 1.0 วนลูปไปเรื่อยๆ ทำให้คลื่นเคลื่อนที่
  final List<Color> colors;

  _WavePainter({
    required this.progress,
    required this.phase,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double waterHeight = size.height * progress;
    final double baseY = size.height - waterHeight;

    final Paint fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [colors[0].withOpacity(0.85), colors[1].withOpacity(0.95)],
      ).createShader(Rect.fromLTWH(0, baseY, size.width, waterHeight + 20));

    // คลื่นชั้นหลัง (เคลื่อนช้ากว่า สีอ่อนกว่า ให้ดูมีความลึก)
    final Path backWavePath = Path();
    backWavePath.moveTo(0, baseY);
    const double backWaveHeight = 5.0;
    const double backWaveLength = 90.0;
    for (double x = 0; x <= size.width; x++) {
      final double y =
          baseY -
          2 +
          backWaveHeight *
              sin((x / backWaveLength * 2 * pi) + (phase * 2 * pi * -0.8));
      backWavePath.lineTo(x, y);
    }
    backWavePath.lineTo(size.width, size.height);
    backWavePath.lineTo(0, size.height);
    backWavePath.close();

    final Paint backWavePaint = Paint()..color = colors[0].withOpacity(0.35);
    canvas.drawPath(backWavePath, backWavePaint);

    // คลื่นชั้นหน้า (เคลื่อนเร็วกว่า สีเข้มกว่า)
    final Path path = Path();
    path.moveTo(0, baseY);

    const double waveHeight = 6.0;
    const double waveLength = 60.0;

    for (double x = 0; x <= size.width; x++) {
      final double y =
          baseY +
          waveHeight * sin((x / waveLength * 2 * pi) + (phase * 2 * pi));
      path.lineTo(x, y);
    }

    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();

    canvas.drawPath(path, fillPaint);

    // เส้นผิวน้ำแบบจางๆ ให้ดูมีแสงสะท้อน เพิ่มความ smooth ให้ภาพรวม
    final Paint surfacePaint = Paint()
      ..color = Colors.white.withOpacity(0.35)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final Path surfacePath = Path();
    surfacePath.moveTo(0, baseY);
    for (double x = 0; x <= size.width; x++) {
      final double y =
          baseY +
          waveHeight * sin((x / waveLength * 2 * pi) + (phase * 2 * pi));
      surfacePath.lineTo(x, y);
    }
    canvas.drawPath(surfacePath, surfacePaint);

    // ฟองอากาศเล็กๆ ลอยขึ้นเมื่อน้ำกำลังไหล เพิ่มลูกเล่นให้มีชีวิตชีวา
    if (progress > 0.02) {
      final Paint bubblePaint = Paint()..color = Colors.white.withOpacity(0.45);
      for (int i = 0; i < 5; i++) {
        final double seed = i * 37.0;
        final double bx = (seed + phase * size.width * 1.3) % size.width;
        final double cycle = (phase + i * 0.2) % 1.0;
        final double by = size.height - (cycle * waterHeight);
        if (by > baseY) {
          canvas.drawCircle(Offset(bx, by), 2.0 + (i % 3), bubblePaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.phase != phase ||
        oldDelegate.colors != colors;
  }
}
