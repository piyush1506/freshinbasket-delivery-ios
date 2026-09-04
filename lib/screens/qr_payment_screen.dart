import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/order.dart';
import '../providers/delivery_provider.dart';
import '../theme/app_theme.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import 'dart:math' as math;

class QrPaymentScreen extends StatefulWidget {
  final DeliveryOrder order;

  const QrPaymentScreen({super.key, required this.order});

  @override
  State<QrPaymentScreen> createState() => _QrPaymentScreenState();
}

class _QrPaymentScreenState extends State<QrPaymentScreen>
    with TickerProviderStateMixin {
  bool _paymentSuccess = false;
  bool _processing = true;
  String? _qrId;
  String? _qrImageUrl;
  String? _qrData; // Raw UPI string for local QR generation
  String? _transactionId;
  Timer? _pollingTimer;
  StreamSubscription? _fcmSubscription;

  // Animation controllers
  late AnimationController _successAnimController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<double> _checkAnimation;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    
    // Success animation controller
    _successAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _successAnimController,
        curve: const Interval(0.0, 0.5, curve: Curves.elasticOut),
      ),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _successAnimController,
        curve: const Interval(0.3, 0.7, curve: Curves.easeIn),
      ),
    );

    _checkAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _successAnimController,
        curve: const Interval(0.4, 0.8, curve: Curves.easeOut),
      ),
    );

    // Pulse animation for waiting indicator
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    // Listen for FCM payment success notifications (from webhook)
    _fcmSubscription = NotificationService.instance.onPaymentSuccess.listen((data) {
      final orderId = data['order_id'] ?? '';
      if (orderId == widget.order.orderId.toString() && !_paymentSuccess) {
        _transactionId = data['transaction_id'];
        _handlePaymentSuccess();
      }
    });

    _generateQrCode();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _fcmSubscription?.cancel();
    _successAnimController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _generateQrCode() async {
    try {
      final response = await ApiService.post('/payment/qr/generate/', {
        'order_id': widget.order.orderId,
        'order_number': widget.order.orderNumber,
        'amount': widget.order.totalAmount,
      });

      if (!mounted) return;

      if (response['qr_id'] != null) {
        final qrString = response['qr_string'] ?? '';
        setState(() {
          _qrId = response['qr_id'];
          _qrImageUrl = response['image_url'];
          // Use qr_string for local rendering if it's actual data (not a URL to an image)
          _qrData = (qrString.isNotEmpty && !qrString.startsWith('http'))
              ? qrString
              : null;
          _processing = false;
        });
        debugPrint('QR data: $_qrData');
        debugPrint('QR image URL: $_qrImageUrl');
        _startPolling();
      } else {
        _handleError('Invalid response from server');
      }
    } catch (e) {
      _handleError('Could not generate QR code: $e');
    }
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (_qrId == null || !mounted || _paymentSuccess) return;

      try {
        final response = await ApiService.get('/payment/qr/status/$_qrId/');
        if (response['is_paid'] == true && !_paymentSuccess) {
          timer.cancel();
          _handlePaymentSuccess();
        }
      } catch (e) {
        debugPrint('Polling error: $e');
      }
    });
  }

  void _handleError(String message) {
    if (mounted) {
      setState(() {
        _processing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _handlePaymentSuccess() async {
    _pollingTimer?.cancel();

    setState(() {
      _processing = true; // Show loading while updating status
    });

    try {
      final delivery = Provider.of<DeliveryProvider>(context, listen: false);
      await delivery.updateOrderStatus(widget.order.orderId, 'DELIVERED');
    } catch (e) {
      debugPrint('Status update error: $e');
    }

    if (mounted) {
      setState(() {
        _processing = false;
        _paymentSuccess = true;
      });
      _successAnimController.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_paymentSuccess) {
      return _buildSuccessScreen();
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5FA),
      appBar: AppBar(
        title: const Text(
          'Collect Payment',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        foregroundColor: AppTheme.textPrimaryColor,
        elevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
      ),
      body: _processing && _qrImageUrl == null && _qrData == null
          ? _buildProcessingScreen()
          : _buildQrScreen(),
    );
  }

  Widget _buildQrScreen() {
    final order = widget.order;
    return Column(
      children: [
        // ── Compact Order Info Strip ──
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: const Color(0xFF5C2D91).withValues(alpha: 0.06),
          child: Row(
            children: [
              Text(
                'Order #${order.orderNumber}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF5C2D91),
                ),
              ),
              const Spacer(),
              Text(
                '₹${order.totalAmount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF5C2D91),
                ),
              ),
            ],
          ),
        ),

        // ── QR Code — fills remaining space ──
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const Text(
                  'Ask Customer to Scan',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'GPay · PhonePe · Paytm · Any UPI App',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                const SizedBox(height: 12),

                // QR fills all available space
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (_qrData != null) {
                        // For local QR, use a square based on the smaller dimension
                        final qrSize = constraints.maxWidth < constraints.maxHeight
                            ? constraints.maxWidth
                            : constraints.maxHeight;
                        return Center(
                          child: SizedBox(
                            width: qrSize,
                            height: qrSize,
                            child: QrImageView(
                              data: _qrData!,
                              version: QrVersions.auto,
                              size: qrSize,
                              backgroundColor: Colors.white,
                              eyeStyle: const QrEyeStyle(
                                eyeShape: QrEyeShape.square,
                                color: Color(0xFF1A1A2E),
                              ),
                              dataModuleStyle: const QrDataModuleStyle(
                                dataModuleShape: QrDataModuleShape.square,
                                color: Color(0xFF1A1A2E),
                              ),
                              errorStateBuilder: (ctx, err) {
                                return Center(
                                  child: Text('Error: $err'),
                                );
                              },
                            ),
                          ),
                        );
                      } else if (_qrImageUrl != null) {
                        // For Razorpay image, use full available space to maximize size
                        return Center(
                          child: Image.network(
                            _qrImageUrl!,
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                            fit: BoxFit.cover,
                            loadingBuilder: (context, child, loadingProgress) {
                              if (loadingProgress == null) return child;
                              return const Center(
                                child: CircularProgressIndicator(
                                  color: Color(0xFF5C2D91),
                                  strokeWidth: 2.5,
                                ),
                              );
                            },
                            errorBuilder: (context, error, stackTrace) {
                              return const Center(
                                child: Icon(Icons.broken_image, size: 50, color: Colors.grey),
                              );
                            },
                          ),
                        );
                      } else {
                        return const Center(child: Text('Error loading QR Code'));
                      }
                    },
                  ),
                ),

                const SizedBox(height: 12),

                // Waiting indicator
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.06 + (_pulseController.value * 0.06)),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.orange[700],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Waiting for payment...',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.orange[800],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ],
    );
  }



  Widget _buildProcessingScreen() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF5C2D91).withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: const CircularProgressIndicator(
              color: Color(0xFF5C2D91),
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Generating UPI QR Code...',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Creating a secure payment link',
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessScreen() {
    final order = widget.order;
    return Scaffold(
      backgroundColor: const Color(0xFFF0FFF4),
      body: Stack(
        children: [
          // Confetti background
          Positioned.fill(
            child: CustomPaint(
              painter: _ConfettiPainter(animation: _successAnimController),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // ── Green check circle ──
                    ScaleTransition(
                      scale: _scaleAnimation,
                      child: Container(
                        width: 110,
                        height: 110,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF00C853), Color(0xFF00E676)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF00C853).withValues(alpha: 0.4),
                              blurRadius: 30,
                              spreadRadius: 5,
                            ),
                          ],
                        ),
                        child: FadeTransition(
                          opacity: _checkAnimation,
                          child: const Icon(
                            Icons.check_rounded,
                            color: Colors.white,
                            size: 70,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),

                    // ── Payment Successful Text ──
                    FadeTransition(
                      opacity: _fadeAnimation,
                      child: Column(
                        children: [
                          const Text(
                            'Payment Received!',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1B5E20),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '₹${order.totalAmount.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF00C853),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // ── Transaction Details Card ──
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.06),
                                  blurRadius: 16,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                _buildDetailRow('Order', '#${order.orderNumber}'),
                                const Divider(height: 20),
                                _buildDetailRow('Customer', order.customerName),
                                const Divider(height: 20),
                                _buildDetailRow('Amount', '₹${order.totalAmount.toStringAsFixed(2)}'),
                                if (_transactionId != null) ...[
                                  const Divider(height: 20),
                                  _buildDetailRow('Transaction ID', _transactionId!),
                                ],
                                const Divider(height: 20),
                                _buildDetailRow('Status', 'Paid & Delivered',
                                    valueColor: Colors.green[700]),
                              ],
                            ),
                          ),

                          const SizedBox(height: 32),

                          // ── Complete Delivery Button ──
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.check_circle_outline, size: 22),
                              label: const Text(
                                'Done',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00C853),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                elevation: 2,
                              ),
                              onPressed: () {
                                Navigator.of(context).pop(true);
                              },
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
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey[600],
          ),
        ),
        Flexible(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: valueColor ?? const Color(0xFF1A1A2E),
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  final Animation<double> animation;
  final List<_Particle> particles = [];

  _ConfettiPainter({required this.animation}) : super(repaint: animation) {
    final random = math.Random();
    for (int i = 0; i < 60; i++) {
      particles.add(_Particle(
        x: random.nextDouble() * 400,
        y: random.nextDouble() * 900,
        color: [
          const Color(0xFF00C853),
          const Color(0xFF2196F3),
          const Color(0xFFFF9800),
          const Color(0xFFE91E63),
          const Color(0xFF9C27B0),
          const Color(0xFFFFEB3B),
        ][random.nextInt(6)],
        speed: random.nextDouble() * 3 + 1,
        angle: random.nextDouble() * math.pi * 2,
        size: random.nextDouble() * 8 + 3,
      ));
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (animation.value == 0) return;

    for (var particle in particles) {
      final paint = Paint()
        ..color = particle.color.withValues(alpha: 1 - animation.value)
        ..style = PaintingStyle.fill;

      final currentY = particle.y + (particle.speed * 120 * animation.value);
      final currentX = particle.x + (math.sin(particle.angle) * 60 * animation.value);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(currentX, currentY), width: particle.size, height: particle.size * 0.6),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _Particle {
  final double x, y, speed, angle, size;
  final Color color;
  _Particle({
    required this.x,
    required this.y,
    required this.speed,
    required this.angle,
    required this.size,
    required this.color,
  });
}
