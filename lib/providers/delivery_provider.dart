import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import '../models/order.dart';
import '../models/delivery_group.dart';
import '../models/delivery_stats.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';

class DeliveryProvider extends ChangeNotifier {
  // ── Per-operation error state ────────────────────────────────────────────
  String? _dashboardError;
  String? _ordersError;
  String? _groupsError;
  String? _statsError;
  String? _statusError;

  // ── Delivery stats ───────────────────────────────────────────────────────
  double _todayEarnings = 0.0;
  int _todayDeliveriesCount = 0;
  int _weekDeliveriesCount = 0;
  int _totalDeliveriesCount = 0;
  double _avgRating = 0.0;

  // ── Orders ───────────────────────────────────────────────────────────────
  DeliveryOrder? _activeOrder;
  List<DeliveryOrder> _assignedOrders = [];

  // ── Groups / stats ───────────────────────────────────────────────────────
  List<DeliveryGroup> _activeGroups = [];
  List<DeliveryGroup> _pastGroups = [];
  DeliveryStats? _stats;
  bool _groupsLoading = false;
  bool _statsLoading = false;

  // ── Loading flags ────────────────────────────────────────────────────────
  bool _dashboardLoading = false;
  bool _ordersLoading = false;
  bool _statusUpdating = false;

  // =========================================================================
  // GPS + Route state (shared between DashboardView and MapView)
  // =========================================================================

  // No India-center fallback — we keep null until real GPS fires.
  // driverLocation getter returns a safe default only for calculations
  // that need a non-null value; the map won't render until locationReady=true.
  LatLng? _driverLocation;
  double _driverHeading = 0.0;
  bool _locationReady = false;
  List<LatLng> _routePoints = [];

  // Route-fetch throttle: only re-fetch after moving this many metres
  static const double _routeRefetchDistanceMeters = 5.0;

  // Debounce timer so we never fire more than one OSRM request per window
  static const Duration _routeDebounceWindow = Duration(seconds: 1);
  Timer? _routeDebounceTimer;
  bool _routeFetchInProgress = false;
  bool _routeFetchQueued = false;

  // Periodic route refresh timer — forces a route update even if the rider
  // hasn't moved (e.g. stuck in traffic, the road network may change)
  Timer? _periodicRouteTimer;
  static const Duration _periodicRouteInterval = Duration(seconds: 30);

  int? _lastActiveOrderId;
  LatLng? _lastRouteFetchLocation;
  StreamSubscription<Position>? _positionStreamSubscription;

  // Debounce map redraws: location ticks batch into one rebuild per frame
  bool _locationRebuildPending = false;

  // ── Public GPS / route getters ───────────────────────────────────────────

  /// Returns the real GPS location, or a safe fallback for distance maths.
  /// Always check [locationReady] before centering the map here.
  /// Returns the real GPS location, or null if GPS hasn't fired yet.
  /// Always check [locationReady] before using this for map centering or routes.
  LatLng? get driverLocation => _driverLocation;
  double get driverHeading => _driverHeading;
  bool get locationReady => _locationReady;
  List<LatLng> get routePoints => List.unmodifiable(_routePoints);

  bool get isLocationServiceDisabled => LocationService.instance.isLocationServiceDisabled;
  bool get isPermissionDenied => LocationService.instance.isPermissionDenied;

  // =========================================================================
  // Existing getters
  // =========================================================================

  List<DeliveryGroup> get activeGroups => _activeGroups;
  List<DeliveryGroup> get pastGroups => _pastGroups;
  DeliveryStats? get stats => _stats;

  bool get loading =>
      _dashboardLoading ||
      _ordersLoading ||
      _statusUpdating ||
      _groupsLoading ||
      _statsLoading;

  String? get error =>
      _dashboardError ??
      _ordersError ??
      _statusError ??
      _groupsError ??
      _statsError;

  String? get dashboardError => _dashboardError;
  String? get ordersError => _ordersError;
  String? get groupsError => _groupsError;
  String? get statsError => _statsError;
  String? get statusError => _statusError;

  double get todayEarnings => _todayEarnings;
  int get todayDeliveriesCount => _todayDeliveriesCount;
  int get weekDeliveriesCount => _weekDeliveriesCount;
  int get totalDeliveriesCount => _totalDeliveriesCount;
  double get avgRating => _avgRating;

  DeliveryOrder? get activeOrder => _activeOrder;
  List<DeliveryOrder> get assignedOrders => _assignedOrders;

  // =========================================================================
  // GPS — start once, shared by all consumers
  // =========================================================================

  /// Called once from DashboardView.initState.
  /// Called once from DashboardView.initState.
  /// Subscribes to the unified [LocationService] stream and starts tracking.
  Future<void> startLocationTracking() async {
    // If we already have a stream subscription, just update mode
    if (_positionStreamSubscription != null) {
      LocationService.instance.updateMode(activeDelivery: _activeOrder != null);
      return;
    }

    // Subscribe to unified LocationService broadcast stream
    _positionStreamSubscription = LocationService.instance.onPositionChanged.listen(
      (Position position) {
        final newLoc = LatLng(position.latitude, position.longitude);

        if (_driverLocation != null) {
          final dist = Geolocator.distanceBetween(
            _driverLocation!.latitude,
            _driverLocation!.longitude,
            newLoc.latitude,
            newLoc.longitude,
          );
          // Manually calculate heading to ensure it always points in direction of movement
          if (dist > 2.0) {
            double lat1 = _driverLocation!.latitude * math.pi / 180;
            double lng1 = _driverLocation!.longitude * math.pi / 180;
            double lat2 = newLoc.latitude * math.pi / 180;
            double lng2 = newLoc.longitude * math.pi / 180;

            double dLng = lng2 - lng1;
            double y = math.sin(dLng) * math.cos(lat2);
            double x = math.cos(lat1) * math.sin(lat2) -
                math.sin(lat1) * math.cos(lat2) * math.cos(dLng);

            double bearing = math.atan2(y, x) * 180 / math.pi;
            _driverHeading = (bearing + 360) % 360;
          }
        } else if (position.heading >= 0) {
          _driverHeading = position.heading;
        }

        _driverLocation = newLoc;
        _locationReady = true;

        // Batch redraws: schedule one rebuild instead of one per GPS tick
        if (!_locationRebuildPending) {
          _locationRebuildPending = true;
          Future.microtask(() {
            _locationRebuildPending = false;
            notifyListeners();
          });
        }

        // Route refresh — only if we have an active order
        if (_activeOrder != null) {
          _maybeRefetchRoute(newLoc);
        }
      },
      onError: (Object e) {
        debugPrint('[DeliveryProvider] LocationService stream error: $e');
      },
      cancelOnError: false,
    );

    // If LocationService already has a cached fix, display it immediately
    final cached = LocationService.instance.lastPosition;
    if (cached != null && cached.latitude.abs() > 1.0) {
      _driverLocation = LatLng(cached.latitude, cached.longitude);
      if (cached.heading >= 0) {
        _driverHeading = cached.heading;
      }
      _locationReady = true;
      notifyListeners();
      _scheduleRouteDebounce();
    }

    // Start single tracking stream through LocationService
    await LocationService.instance.startTracking(activeDelivery: _activeOrder != null);
  }

  void _syncLocationStream() {
    LocationService.instance.updateMode(activeDelivery: _activeOrder != null);
  }

  /// Explicitly prompt user to turn on Location / GPS settings and re-attempt tracking.
  Future<void> enableLocationServices() async {
    final enabled = await LocationService.instance.promptAndEnableLocation();
    if (enabled) {
      await recenterLocation();
    }
    notifyListeners();
  }

  /// Force a fresh GPS fix and re-centre (e.g. re-centre button in MapView).
  bool _isRecentering = false;

  Future<void> recenterLocation() async {
    if (_isRecentering) return;
    _isRecentering = true;
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        await enableLocationServices();
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      _driverLocation = LatLng(position.latitude, position.longitude);
      if (position.heading >= 0) {
        _driverHeading = position.heading;
      }
      _locationReady = true;
      _lastRouteFetchLocation = null; // force route refresh from new position
      _scheduleRouteDebounce();
      notifyListeners();
    } catch (e) {
      debugPrint('[DeliveryProvider] recenterLocation error: $e');
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) {
        _driverLocation = LatLng(lastKnown.latitude, lastKnown.longitude);
        if (lastKnown.heading >= 0) {
          _driverHeading = lastKnown.heading;
        }
        _locationReady = true;
        _lastRouteFetchLocation = null;
        _scheduleRouteDebounce();
        notifyListeners();
      }
    } finally {
      _isRecentering = false;
    }
  }

  @override
  void dispose() {
    _routeDebounceTimer?.cancel();
    _periodicRouteTimer?.cancel();
    _positionStreamSubscription?.cancel();
    super.dispose();
  }

  // =========================================================================
  // Route fetching — debounced + error-resilient
  // =========================================================================

  void _onActiveOrderChanged() {
    final newId = _activeOrder?.orderId;
    if (newId != _lastActiveOrderId) {
      _lastActiveOrderId = newId;
      _lastRouteFetchLocation = null; // force fresh fetch for new order
      if (_activeOrder != null && _locationReady) {
        _scheduleRouteDebounce();
        _startPeriodicRouteRefresh();
      } else {
        _routePoints.clear();
        _routeFetchInProgress = false;
        _routeDebounceTimer?.cancel();
        _stopPeriodicRouteRefresh();
      }
    }
    // Always sync the stream when order status changes
    _syncLocationStream();
  }

  /// Start a periodic timer that forces route refresh every 30 seconds,
  /// ensuring the polyline stays accurate even when the rider is stationary.
  void _startPeriodicRouteRefresh() {
    _periodicRouteTimer?.cancel();
    _periodicRouteTimer = Timer.periodic(_periodicRouteInterval, (_) {
      if (_activeOrder != null && _locationReady && _driverLocation != null) {
        debugPrint('[DeliveryProvider] Periodic route refresh triggered.');
        _lastRouteFetchLocation = null; // force fresh fetch from current position
        _scheduleRouteDebounce();
      }
    });
  }

  void _stopPeriodicRouteRefresh() {
    _periodicRouteTimer?.cancel();
    _periodicRouteTimer = null;
  }

  void _maybeRefetchRoute(LatLng newLocation) {
    if (_lastRouteFetchLocation == null) {
      _scheduleRouteDebounce();
      return;
    }
    final moved = Geolocator.distanceBetween(
      _lastRouteFetchLocation!.latitude,
      _lastRouteFetchLocation!.longitude,
      newLocation.latitude,
      newLocation.longitude,
    );
    if (moved >= _routeRefetchDistanceMeters) {
      _scheduleRouteDebounce();
    }
  }

  /// Debounce: cancel any pending timer and restart it. The actual OSRM call
  /// fires only after [_routeDebounceWindow] of inactivity, preventing request
  /// floods when the rider is moving quickly.
  void _scheduleRouteDebounce() {
    _routeDebounceTimer?.cancel();
    if (_lastRouteFetchLocation == null) {
      if (_routeFetchInProgress) {
        _routeFetchQueued = true;
      } else {
        _fetchRoute();
      }
    } else {
      _routeDebounceTimer = Timer(_routeDebounceWindow, () {
        if (_routeFetchInProgress) {
          _routeFetchQueued = true;
        } else {
          _fetchRoute();
        }
      });
    }
  }

  Future<void> _fetchRoute() async {
    final order = _activeOrder;
    final loc = _driverLocation;
    if (order == null ||
        order.deliveryLatitude == null ||
        order.deliveryLongitude == null ||
        !_locationReady ||
        loc == null) {
      return;
    }

    final endLat = order.deliveryLatitude!;
    final endLng = order.deliveryLongitude!;

    // Sanity check: reject obviously wrong coordinates (near 0,0 or default India center)
    if (loc.latitude.abs() < 1.0 && loc.longitude.abs() < 1.0) {
      debugPrint('[DeliveryProvider] Skipping route fetch — driver location looks like default (0,0).');
      return;
    }
    if (endLat.abs() < 1.0 && endLng.abs() < 1.0) {
      debugPrint('[DeliveryProvider] Skipping route fetch — destination coordinates look like default (0,0).');
      return;
    }
    if (loc.latitude.isNaN || loc.longitude.isNaN || endLat.isNaN || endLng.isNaN) {
      return;
    }

    _routeFetchInProgress = true;
    final fetchFromLocation = loc;

    try {
      final startLng = fetchFromLocation.longitude;
      final startLat = fetchFromLocation.latitude;

      final url =
          'https://router.project-osrm.org/route/v1/driving/'
          '$startLng,$startLat;$endLng,$endLat'
          '?overview=full&geometries=geojson';

      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final dynamic decoded = json.decode(response.body);
        if (decoded is Map<String, dynamic>) {
          final routes = decoded['routes'];
          if (routes is List && routes.isNotEmpty && routes[0] is Map) {
            final geometry = routes[0]['geometry'];
            if (geometry is Map && geometry['coordinates'] is List) {
              final rawCoords = geometry['coordinates'] as List;
              final validPoints = <LatLng>[];
              for (final c in rawCoords) {
                if (c is List && c.length >= 2) {
                  final lng = (c[0] as num?)?.toDouble();
                  final lat = (c[1] as num?)?.toDouble();
                  if (lat != null &&
                      lng != null &&
                      !lat.isNaN &&
                      !lng.isNaN &&
                      lat.abs() <= 90 &&
                      lng.abs() <= 180) {
                    validPoints.add(LatLng(lat, lng));
                  }
                }
              }

              if (validPoints.length >= 2) {
                _routePoints = validPoints;
                _lastRouteFetchLocation = fetchFromLocation;
                debugPrint('[DeliveryProvider] Route loaded: ${_routePoints.length} points.');
                notifyListeners();
                return;
              }
            }
          }
        }
      }

      // If OSRM returned non-200 or invalid geometry, create a direct 2-point fallback line
      debugPrint('[DeliveryProvider] OSRM route unavailable (status: ${response.statusCode}), using direct fallback line.');
      _routePoints = [fetchFromLocation, LatLng(endLat, endLng)];
      _lastRouteFetchLocation = fetchFromLocation;
      notifyListeners();
    } catch (e) {
      debugPrint('[DeliveryProvider] Route fetch error: $e. Falling back to direct line.');
      // Safe fallback: direct line between driver and destination
      _routePoints = [fetchFromLocation, LatLng(endLat, endLng)];
      notifyListeners();
    } finally {
      _routeFetchInProgress = false;
      if (_routeFetchQueued) {
        _routeFetchQueued = false;
        _scheduleRouteDebounce();
      }
    }
  }

  // =========================================================================
  // Data fetching
  // =========================================================================

  Future<void> fetchDashboard() async {
    _dashboardLoading = true;
    _dashboardError = null;
    notifyListeners();

    try {
      final data = await ApiService.get('/delivery/dashboard/');
      _todayEarnings =
          double.tryParse(data['today_earnings']?.toString() ?? '0.0') ?? 0.0;
      _todayDeliveriesCount = data['today_deliveries'] ?? 0;
      _weekDeliveriesCount = data['week_deliveries'] ?? 0;
      _totalDeliveriesCount = data['total_deliveries'] ?? 0;
      _avgRating =
          double.tryParse(data['avg_rating']?.toString() ?? '0.0') ?? 0.0;

      DeliveryOrder? backendActive;
      if (data['active_delivery'] != null) {
        backendActive = DeliveryOrder.fromJson(data['active_delivery']);
      }

      if (backendActive != null &&
          backendActive.status == 'OUT_FOR_DELIVERY') {
        _activeOrder = backendActive;
      } else {
        final outForDeliveryOrder = _assignedOrders.firstWhere(
          (o) => o.status == 'OUT_FOR_DELIVERY',
          orElse: () =>
              backendActive ??
              DeliveryOrder(
                assignmentId: 0,
                orderId: 0,
                orderNumber: '',
                customerName: '',
                customerPhone: '',
                deliveryAddress: '',
                status: 'PENDING',
                subtotal: 0,
                deliveryCharge: 0,
                totalAmount: 0,
                isPaid: false,
                paymentMethod: 'COD',
                notes: '',
                items: [],
              ),
        );
        _activeOrder = outForDeliveryOrder.status == 'OUT_FOR_DELIVERY'
            ? outForDeliveryOrder
            : null;
      }

      // Sync with assigned orders list to get correct unit names
      if (_activeOrder != null) {
        final matched = _assignedOrders.firstWhere(
          (o) => o.orderId == _activeOrder!.orderId,
          orElse: () => _activeOrder!,
        );
        if (matched.orderId == _activeOrder!.orderId &&
            matched.items.isNotEmpty) {
          _activeOrder = matched;
        }
      }

      _dashboardLoading = false;
      _onActiveOrderChanged(); // may trigger a (debounced) route refresh
      notifyListeners();
    } catch (e) {
      _dashboardError = e.toString().replaceFirst('Exception: ', '');
      _dashboardLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchAssignedOrders({String? statusFilter}) async {
    _ordersLoading = true;
    _ordersError = null;
    notifyListeners();

    try {
      String path = '/delivery/orders/';
      if (statusFilter != null && statusFilter.isNotEmpty) {
        path += '?status=$statusFilter';
      }
      final List<dynamic> data = await ApiService.get(path);
      _assignedOrders = data.map((o) => DeliveryOrder.fromJson(o)).toList();

      _ordersLoading = false;
      notifyListeners();
    } catch (e) {
      _ordersError = e.toString().replaceFirst('Exception: ', '');
      _ordersLoading = false;
      notifyListeners();
    }
  }

  Future<bool> updateOrderStatus(int orderId, String newStatus) async {
    _statusUpdating = true;
    _statusError = null;
    notifyListeners();

    try {
      await ApiService.patch('/delivery/orders/$orderId/status/', {
        'status': newStatus,
      });
      await fetchAssignedOrders();
      await fetchDashboard();
      await fetchGroups();
      await fetchStats();
      _statusUpdating = false;
      notifyListeners();
      return true;
    } catch (e) {
      _statusError = e.toString().replaceFirst('Exception: ', '');
      _statusUpdating = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> fetchGroups() async {
    _groupsLoading = true;
    _groupsError = null;
    notifyListeners();

    try {
      final data = await ApiService.get('/delivery/groups/');

      var activeList = data['active_groups'] as List? ?? [];
      _activeGroups = activeList.map((g) => DeliveryGroup.fromJson(g)).toList();

      var pastList = data['past_groups'] as List? ?? [];
      _pastGroups = pastList.map((g) => DeliveryGroup.fromJson(g)).toList();

      _groupsLoading = false;
      notifyListeners();
    } catch (e) {
      _groupsError = e.toString().replaceFirst('Exception: ', '');
      _groupsLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchStats() async {
    _statsLoading = true;
    _statsError = null;
    notifyListeners();

    try {
      final data = await ApiService.get('/delivery/stats/');
      _stats = DeliveryStats.fromJson(data);

      _statsLoading = false;
      notifyListeners();
    } catch (e) {
      _statsError = e.toString().replaceFirst('Exception: ', '');
      _statsLoading = false;
      notifyListeners();
    }
  }

  Future<bool> markUndelivered(int orderId, String reason) async {
    _statusUpdating = true;
    _statusError = null;
    notifyListeners();

    try {
      await ApiService.patch('/delivery/orders/$orderId/status/', {
        'status': 'UNDELIVERED',
        'reason': reason,
      });
      await fetchAssignedOrders();
      await fetchDashboard();
      await fetchGroups();
      await fetchStats();
      _statusUpdating = false;
      notifyListeners();
      return true;
    } catch (e) {
      _statusError = e.toString().replaceFirst('Exception: ', '');
      _statusUpdating = false;
      notifyListeners();
      return false;
    }
  }
}
