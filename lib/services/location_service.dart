import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'api_service.dart';

/// Singleton service that manages the single GPS stream for the entire app,
/// broadcasting real-time position updates to [DeliveryProvider] and uploading
/// throttled location updates to the backend.
///
/// How background tracking works:
///   1. [NotificationService.initialize()] creates 'location_tracking_channel'.
///   2. [startTracking()] opens a [Geolocator.getPositionStream] with
///      [AndroidSettings.foregroundNotificationConfig] that references that
///      channel. geolocator starts a foreground service, posts a persistent
///      notification, and holds a GPS wake-lock.
///   3. The OS cannot kill a foreground service (unless the user force-stops
///      the app), so the stream — and therefore the server updates — continue
///      even with the screen off and phone in the rider's pocket.
class LocationService {
  static final LocationService instance = LocationService._internal();
  LocationService._internal();

  StreamSubscription<Position>? _positionSubscription;
  bool _isTracking = false;
  bool _activeDeliveryMode = false;

  final StreamController<Position> _positionController =
      StreamController<Position>.broadcast();

  /// Real-time stream of GPS positions for UI / Map / Heading.
  Stream<Position> get onPositionChanged => _positionController.stream;

  Position? _lastPosition;
  Position? get lastPosition => _lastPosition;  

  DateTime? _lastServerUploadTime;
  Position? _lastServerUploadPosition;

  bool get isTracking => _isTracking;
  bool get activeDeliveryMode => _activeDeliveryMode;

  bool _isLocationServiceDisabled = false;
  bool get isLocationServiceDisabled => _isLocationServiceDisabled;

  bool _isPermissionDenied = false;
  bool get isPermissionDenied => _isPermissionDenied;

  bool _isPermissionDeniedForever = false;
  bool get isPermissionDeniedForever => _isPermissionDeniedForever;

  /// Open device Location / GPS Settings directly.
  Future<void> openLocationSettings() async {
    await Geolocator.openLocationSettings();
  }

  /// Open App Settings directly (for permanently denied permissions).
  Future<void> openAppSettings() async {
    await Geolocator.openAppSettings();
  }

  /// Prompt user to enable Location / GPS or grant permissions.
  Future<bool> promptAndEnableLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _isLocationServiceDisabled = true;
      await Geolocator.openLocationSettings();
      final recheck = await Geolocator.isLocationServiceEnabled();
      _isLocationServiceDisabled = !recheck;
      if (!recheck) return false;
    } else {
      _isLocationServiceDisabled = false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      _isPermissionDenied = true;
      return false;
    }
    if (permission == LocationPermission.deniedForever) {
      _isPermissionDenied = true;
      _isPermissionDeniedForever = true;
      await Geolocator.openAppSettings();
      return false;
    }

    _isPermissionDenied = false;
    _isPermissionDeniedForever = false;
    await startTracking(activeDelivery: _activeDeliveryMode);
    return true;
  }

  /// Start or update the single GPS stream.
  Future<bool> startTracking({bool activeDelivery = false, bool promptIfDisabled = false}) async {
    _activeDeliveryMode = activeDelivery;

    // ── Permission checks ────────────────────────────────────────────────────
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('[LocationService] GPS is disabled on device.');
      _isLocationServiceDisabled = true;
      if (promptIfDisabled) {
        await Geolocator.openLocationSettings();
      }
      return false;
    }
    _isLocationServiceDisabled = false;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('[LocationService] Location permission denied by user.');
        _isPermissionDenied = true;
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint('[LocationService] Location permission permanently denied.');
      _isPermissionDenied = true;
      _isPermissionDeniedForever = true;
      if (promptIfDisabled) {
        await Geolocator.openAppSettings();
      }
      return false;
    }

    _isPermissionDenied = false;
    _isPermissionDeniedForever = false;

    // Quick fix from last known position if available
    try {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null && lastKnown.latitude.abs() > 1.0) {
        _lastPosition = lastKnown;
        _positionController.add(lastKnown);
        _maybeSendPositionToServer(lastKnown);
      }
    } catch (_) {}

    _isTracking = true;
    _startOrRestartStream();
    return true;
  }

  /// Switch tracking mode (e.g. when an order becomes active or completes)
  void updateMode({required bool activeDelivery}) {
    if (_activeDeliveryMode == activeDelivery && _positionSubscription != null) {
      return;
    }
    _activeDeliveryMode = activeDelivery;
    if (_isTracking) {
      _startOrRestartStream();
    }
  }

  void _startOrRestartStream() {
    _positionSubscription?.cancel();
    _positionSubscription = null;

    final LocationSettings streamSettings;
    if (Platform.isAndroid) {
      if (_activeDeliveryMode) {
        // High-power foreground service with persistent notification during delivery
        streamSettings = AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0, // fire on every GPS tick for live heading
          intervalDuration: const Duration(seconds: 1),
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationChannelName: 'Location Tracking',
            notificationTitle: 'FreshInBasket — On Delivery',
            notificationText: 'Tracking your location for active delivery.',
            enableWakeLock: true,
            setOngoing: true,
            color: Color(0xFF2E7D32),
          ),
        );
      } else {
        // Lightweight foreground stream when idle
        streamSettings = AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 2),
        );
      }
    } else if (Platform.isIOS) {
      // iOS: enable background location streaming during delivery
      streamSettings = AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    } else {
      // Other platforms
      streamSettings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      );
    }

    debugPrint('[LocationService] Starting GPS stream (activeDelivery=$_activeDeliveryMode)');

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: streamSettings,
    ).listen(
      (Position position) {
        if (position.latitude.abs() < 1.0 && position.longitude.abs() < 1.0) {
          return; // Ignore invalid default coordinates
        }
        _lastPosition = position;
        _positionController.add(position);
        _maybeSendPositionToServer(position);
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[LocationService] Stream error: $error');
      },
      cancelOnError: false,
    );
  }

  void stopTracking() {
    debugPrint('[LocationService] Stopping location tracking.');
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _isTracking = false;
    _activeDeliveryMode = false;
  }

  // ── Throttled Server Upload ──────────────────────────────────────────────

  void _maybeSendPositionToServer(Position position) {
    final now = DateTime.now();
    bool shouldUpload = false;

    if (_lastServerUploadTime == null || _lastServerUploadPosition == null) {
      shouldUpload = true;
    } else {
      final elapsed = now.difference(_lastServerUploadTime!).inSeconds;
      if (elapsed >= 10) {
        shouldUpload = true;
      } else {
        final dist = Geolocator.distanceBetween(
          _lastServerUploadPosition!.latitude,
          _lastServerUploadPosition!.longitude,
          position.latitude,
          position.longitude,
        );
        if (dist >= 15) {
          shouldUpload = true;
        }
      }
    }

    if (shouldUpload) {
      _lastServerUploadTime = now;
      _lastServerUploadPosition = position;
      _sendPositionToServer(position);
    }
  }

  Future<void> _sendPositionToServer(Position position) async {
    try {
      await ApiService.post('/delivery/location/', {
        'latitude': position.latitude,
        'longitude': position.longitude,
      });
      debugPrint('[LocationService] Server updated: ${position.latitude}, ${position.longitude}');
    } catch (e) {
      debugPrint('[LocationService] Server update failed: $e');
    }
  }
}
