import 'dart:async';
import 'dart:io' show Platform;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'api_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint("Handling a background message: ${message.messageId}");
}

class NotificationService {
  static final NotificationService instance = NotificationService._internal();
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _localNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // ── Deduplication guard ──────────────────────────────────────────────────
  // Tracks FCM message IDs already processed to prevent onMessage +
  // onMessageOpenedApp both firing for the same push.
  final Set<String> _processedMessageIds = {};

  // Stream for payment success events from webhook FCM push
  final StreamController<Map<String, String>> _paymentSuccessController =
      StreamController<Map<String, String>>.broadcast();
  Stream<Map<String, String>> get onPaymentSuccess =>
      _paymentSuccessController.stream;

  Future<void> initialize() async {
    if (_initialized) return;

    try {
      // 1. Initialize Local Notifications Plugin for Android/iOS
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const initSettings =
          InitializationSettings(android: androidSettings, iOS: iosSettings);

      await _localNotificationsPlugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse details) {
          debugPrint("Notification tapped: ${details.payload}");
        },
      );

      // Create High Importance Android Notification Channel (for payments)
      const androidChannel = AndroidNotificationChannel(
        'high_importance_channel',
        'High Importance Notifications',
        description: 'This channel is used for payment notifications.',
        importance: Importance.max,
      );

      await _localNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidChannel);

      // Create Location Tracking Notification Channel (for geolocator foreground service).
      const locationChannel = AndroidNotificationChannel(
        'location_tracking_channel',
        'Location Tracking',
        description:
            'Shows while FreshInBasket is tracking your delivery location.',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      );

      await _localNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(locationChannel);

      // 2. Request FCM permissions
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      // Request local notification permissions on iOS
      if (Platform.isIOS) {
        await _localNotificationsPlugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            );
      }

      // Set foreground presentation options
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      // 3. Fetch and upload FCM Token
      if (Platform.isIOS) {
        String? apnsToken = await messaging.getAPNSToken();
        int retryCount = 0;
        while (apnsToken == null && retryCount < 6) {
          debugPrint("[FCM] Waiting for APNs token... retry $retryCount");
          await Future.delayed(const Duration(milliseconds: 1000));
          apnsToken = await messaging.getAPNSToken();
          retryCount++;
        }
        if (apnsToken != null) {
          debugPrint("[FCM] APNs token received: $apnsToken");
        } else {
          debugPrint("[FCM] Warning: APNs token not received yet.");
        }
      }

      String? token = await messaging.getToken();
      if (token != null) {
        debugPrint("[FCM] Token retrieved: $token");
        await _uploadFcmToken(token);
      }

      // Listen for token refreshes
      messaging.onTokenRefresh.listen((newToken) async {
        await _uploadFcmToken(newToken);
      });

      // 4. Register background handler
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      // 5. Handle foreground messages
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint(
            "Received foreground message: ${message.notification?.title}");
        _handleMessage(message);
      });

      // 6. Handle app opened from notification
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint("App opened from notification: ${message.messageId}");
        _handleMessage(message);
      });

      _initialized = true;
    } catch (e) {
      debugPrint("FCM initialization failed: $e");
    }
  }

  void _handleMessage(RemoteMessage message) {
    final data = message.data;

    // ── Deduplicate: same FCM message can arrive via both onMessage AND
    //    onMessageOpenedApp when the user taps a notification banner.
    final msgId = message.messageId;
    if (msgId != null && msgId.isNotEmpty) {
      if (_processedMessageIds.contains(msgId)) {
        debugPrint('[FCM] Duplicate message ignored: $msgId');
        return;
      }
      _processedMessageIds.add(msgId);
      // Keep the set small — only remember the last 20 message IDs
      if (_processedMessageIds.length > 20) {
        _processedMessageIds.remove(_processedMessageIds.first);
      }
    }

    // ── Handle payment success from Razorpay webhook ──
    if (data['type'] == 'PAYMENT_SUCCESS') {
      debugPrint(
          "[FCM] Payment success received for order ${data['order_id']}");
      _paymentSuccessController.add({
        'order_id': data['order_id']?.toString() ?? '',
        'order_number': data['order_number']?.toString() ?? '',
        'amount': data['amount']?.toString() ?? '',
        'transaction_id': data['transaction_id']?.toString() ?? '',
      });
      // Show a local notification banner for payment confirmation
      _showLocalNotification(
        title: message.notification?.title ?? '✅ Payment Received!',
        body: message.notification?.body ?? 'Payment confirmed',
      );
    }

    // All other notification types (NEW_ORDER, etc.) are silently ignored.
    // The rider manages orders through the dashboard and orders list.
  }

  Future<void> _showLocalNotification({
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'high_importance_channel',
      'High Importance Notifications',
      channelDescription: 'Used for payment alerts',
      importance: Importance.max,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details =
        NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _localNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }

  Future<void> _uploadFcmToken(String token) async {
    final platform = Platform.isIOS ? 'ios' : 'android';
    // 1. Register device token
    try {
      await ApiService.post('/notifications/register-device/', {
        'token': token,
        'platform': platform,
      });
      debugPrint("[FCM] Device token registered to backend ($platform).");
    } catch (e) {
      debugPrint("[FCM] Device token registration error: $e");
    }

    // 2. Register FCM user token
    try {
      await ApiService.post('/notifications/register-token/', {
        'token': token,
      });
      debugPrint("[FCM] FCM user token successfully registered to backend.");
    } catch (e) {
      debugPrint("[FCM] User token registration error: $e");
    }
  }
}
