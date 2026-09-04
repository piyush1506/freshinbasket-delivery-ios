import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import '../models/order.dart';
import '../providers/delivery_provider.dart';
import '../theme/app_theme.dart';

/// A shared map widget that reads all state from [DeliveryProvider].
///
/// The map renders immediately — it does NOT wait for GPS.
/// While GPS is acquiring, the map shows a default center (India) with a
/// subtle banner. Once [DeliveryProvider.locationReady] becomes true the
/// camera moves to the real driver position automatically.
class DeliveryMapWidget extends StatefulWidget {
  const DeliveryMapWidget({
    super.key,
    this.height,
    this.showLoadingOverlay = true,
    this.onOrderTap,
    this.mapController,
  });

  final double? height;

  /// Legacy flag — no longer blocks rendering. Kept for API compatibility.
  final bool showLoadingOverlay;
  final void Function(DeliveryOrder order)? onOrderTap;

  /// Supply an external [MapController] when the caller needs to move the
  /// camera programmatically (e.g. re-centre button in MapView).
  /// IMPORTANT: the caller is responsible for disposing an external controller.
  final MapController? mapController;

  @override
  State<DeliveryMapWidget> createState() => _DeliveryMapWidgetState();
}

class _DeliveryMapWidgetState extends State<DeliveryMapWidget> {
  MapController? _ownController;
  MapController get _controller => widget.mapController ?? _ownController!;

  // Track whether we have already moved the camera to the real GPS fix.
  bool _centeredOnGps = false;

  // Track the last active order so we re-center when a new order arrives.
  int? _lastActiveOrderId;

  // A reasonable default center (center of India) shown only as absolute fallback.
  static const LatLng _defaultCenter = LatLng(20.5937, 78.9629);

  @override
  void initState() {
    super.initState();
    if (widget.mapController == null) {
      _ownController = MapController();
    }
  }

  @override
  void dispose() {
    _ownController?.dispose();
    _ownController = null;
    super.dispose();
  }

  // ── Auto-center camera when GPS or active order changes ─────────────────

  void _maybeCenterCamera(DeliveryProvider delivery) {
    final locationReady = delivery.locationReady;
    final driverLoc = delivery.driverLocation;
    final activeOrder = delivery.activeOrder;
    final newOrderId = activeOrder?.orderId;

    // Case 1: New active order arrived → re-fit camera to show driver + destination
    if (newOrderId != null && newOrderId != _lastActiveOrderId) {
      _lastActiveOrderId = newOrderId;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          final points = <LatLng>[];
          if (locationReady && driverLoc != null) {
            points.add(driverLoc);
          }
          if (activeOrder?.deliveryLatitude != null && activeOrder?.deliveryLongitude != null) {
            points.add(LatLng(activeOrder!.deliveryLatitude!, activeOrder.deliveryLongitude!));
          }

          if (points.length > 1) {
            final bounds = LatLngBounds.fromPoints(points);
            final latDiff = (bounds.northEast.latitude - bounds.southWest.latitude).abs();
            final lngDiff = (bounds.northEast.longitude - bounds.southWest.longitude).abs();
            if (latDiff > 0.0001 || lngDiff > 0.0001) {
              _controller.fitCamera(
                CameraFit.bounds(
                  bounds: bounds,
                  padding: const EdgeInsets.all(60),
                  maxZoom: 17.0,
                ),
              );
            } else {
              _controller.move(points.first, 16.0);
            }
          } else if (points.isNotEmpty) {
            _controller.move(points.first, 15.0);
          }
        } catch (_) {}
      });
      return;
    }

    // Case 2: No order changed, but GPS just became ready for the first time → center on driver
    if (locationReady && driverLoc != null && !_centeredOnGps) {
      _centeredOnGps = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          _controller.move(driverLoc, 15.0);
        } catch (_) {}
      });
    }

    // Track order cleared
    if (newOrderId == null) {
      _lastActiveOrderId = null;
    }
  }

  // ── Marker builders ──────────────────────────────────────────────────────

  Marker _buildDriverMarker(LatLng loc, double heading) {
    final double turns = heading / 360.0;

    return Marker(
      point: loc,
      width: 54,
      height: 54,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 1. Asphalt drop shadow
          Positioned(
            bottom: 4,
            child: Container(
              width: 28,
              height: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 6,
                    spreadRadius: 1.5,
                  ),
                ],
              ),
            ),
          ),

          // 2. Pure Vector Top-Down Rapido Scooter (100% transparent, no white background or border)
          AnimatedRotation(
            turns: turns,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            child: const CustomPaint(
              size: Size(44, 44),
              painter: RapidoTopDownBikePainter(),
            ),
          ),
        ],
      ),
    );
  }

  Marker _buildActiveDestMarker(DeliveryOrder order) {
    return Marker(
      point: LatLng(order.deliveryLatitude!, order.deliveryLongitude!),
      width: 56,
      height: 60,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.green.shade700,
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
              ],
            ),
            child: Text(
              order.customerName.split(' ').first,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(Icons.location_on, color: Colors.green.shade700, size: 34),
        ],
      ),
    );
  }

  List<Marker> _buildPendingOrderMarkers(
    List<DeliveryOrder> orders,
    LatLng? activeDest,
  ) {
    final markers = <Marker>[];
    final Map<String, int> coordinateCounts = {};

    if (activeDest != null) {
      final key =
          '${activeDest.latitude.toStringAsFixed(6)}_${activeDest.longitude.toStringAsFixed(6)}';
      coordinateCounts[key] = 1;
    }

    for (final o in orders) {
      if (o.deliveryLatitude == null || o.deliveryLongitude == null) continue;

      final lat = o.deliveryLatitude!;
      final lng = o.deliveryLongitude!;
      final key = '${lat.toStringAsFixed(6)}_${lng.toStringAsFixed(6)}';

      final count = coordinateCounts[key] ?? 0;
      coordinateCounts[key] = count + 1;

      double offsetLat = lat;
      double offsetLng = lng;
      if (count > 0) {
        final angle = (count * 2 * math.pi) / 8;
        final radius = 0.00012 * ((count - 1) ~/ 8 + 1);
        offsetLat += radius * math.sin(angle);
        offsetLng += radius * math.cos(angle);
      }

      markers.add(
        Marker(
          point: LatLng(offsetLat, offsetLng),
          width: 44,
          height: 44,
          child: GestureDetector(
            onTap:
                widget.onOrderTap != null ? () => widget.onOrderTap!(o) : null,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.orange.shade600,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black26,
                      blurRadius: 4,
                      offset: Offset(0, 2)),
                ],
              ),
              child: Center(
                child: Text(
                  o.customerName.isNotEmpty
                      ? o.customerName[0].toUpperCase()
                      : 'O',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return markers;
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final delivery = context.watch<DeliveryProvider>();

    final locationReady = delivery.locationReady;
    final routePoints = delivery.routePoints;
    final activeOrder = delivery.activeOrder;

    final driverLoc = delivery.driverLocation;
    final bool hasRealGps = locationReady &&
        driverLoc != null &&
        !(driverLoc.latitude.abs() < 1.0 && driverLoc.longitude.abs() < 1.0);

    // Auto-center / auto-fit camera on GPS fix or active order change
    _maybeCenterCamera(delivery);

    // Pending orders to show as orange markers.
    final pendingOrders = delivery.assignedOrders.where((o) {
      if (activeOrder != null && o.orderId == activeOrder.orderId) return false;
      return o.status == 'CONFIRMED' ||
          o.status == 'PENDING' ||
          o.status == 'OUT_FOR_DELIVERY';
    }).toList();

    final LatLng? activeDest =
        (activeOrder?.deliveryLatitude != null &&
                activeOrder?.deliveryLongitude != null)
            ? LatLng(
                activeOrder!.deliveryLatitude!, activeOrder.deliveryLongitude!)
            : null;

    // Only add driver marker when we have a verified real GPS fix
    final markers = <Marker>[
      if (hasRealGps) _buildDriverMarker(driverLoc, delivery.driverHeading),
      if (activeDest != null && activeOrder != null) _buildActiveDestMarker(activeOrder),
      ..._buildPendingOrderMarkers(pendingOrders, activeDest),
    ];

    // Camera options — after real GPS fix use bounds to show all points,
    // before GPS fires center on customer locations instead of center of India.
    final MapOptions mapOptions;
    if (hasRealGps) {
      final List<LatLng> allPoints = [driverLoc];
      if (activeDest != null) allPoints.add(activeDest);
      for (final o in pendingOrders) {
        if (o.deliveryLatitude != null && o.deliveryLongitude != null) {
          allPoints.add(LatLng(o.deliveryLatitude!, o.deliveryLongitude!));
        }
      }
      if (routePoints.isNotEmpty) allPoints.addAll(routePoints);

      mapOptions = allPoints.length > 1
          ? MapOptions(
              initialCameraFit: CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(allPoints),
                padding: const EdgeInsets.all(60),
                maxZoom: 17.0,
              ),
            )
          : MapOptions(
              initialCenter: driverLoc,
              initialZoom: 15.0,
            );
    } else {
      // GPS not ready yet — center on customer locations instead of India.
      final List<LatLng> orderPoints = [];
      if (activeDest != null) orderPoints.add(activeDest);
      for (final o in pendingOrders) {
        if (o.deliveryLatitude != null && o.deliveryLongitude != null) {
          orderPoints.add(LatLng(o.deliveryLatitude!, o.deliveryLongitude!));
        }
      }

      if (orderPoints.isNotEmpty) {
        mapOptions = orderPoints.length > 1
            ? MapOptions(
                initialCameraFit: CameraFit.bounds(
                  bounds: LatLngBounds.fromPoints(orderPoints),
                  padding: const EdgeInsets.all(60),
                  maxZoom: 17.0,
                ),
              )
            : MapOptions(
                initialCenter: orderPoints.first,
                initialZoom: 15.0,
              );
      } else {
        mapOptions = const MapOptions(
          initialCenter: _defaultCenter,
          initialZoom: 5.0,
        );
      }
    }

    final Widget map = Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: mapOptions,
          children: [
            TileLayer(
              urlTemplate: 'https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}',
              userAgentPackageName: 'com.freshinbasket.delivery',
            ),
            if (routePoints.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: routePoints,
                    color: AppTheme.primaryColor,
                    strokeWidth: 5.5,
                    borderColor: Colors.white,
                    borderStrokeWidth: 1.5,
                  ),
                ],
              ),
            if (markers.isNotEmpty) MarkerLayer(markers: markers),
          ],
        ),

        // Full screen overlay while GPS is acquiring or disabled,
        // providing a direct button to enable location settings.
        if (!hasRealGps)
          Positioned.fill(
            child: Container(
              color: Colors.white.withAlpha(235),
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (delivery.isLocationServiceDisabled || delivery.isPermissionDenied)
                    const Icon(
                      Icons.location_off_rounded,
                      size: 56,
                      color: Colors.redAccent,
                    )
                  else
                    const CircularProgressIndicator(
                      color: AppTheme.primaryColor,
                      strokeWidth: 3,
                    ),
                  const SizedBox(height: 16),
                  Text(
                    delivery.isLocationServiceDisabled
                        ? 'Location (GPS) Disabled'
                        : (delivery.isPermissionDenied
                            ? 'Location Permission Required'
                            : 'Acquiring GPS location...'),
                    style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    delivery.isLocationServiceDisabled
                        ? 'Please enable location services on your device to continue delivery tracking.'
                        : (delivery.isPermissionDenied
                            ? 'Location permission is required for live delivery tracking.'
                            : 'Please ensure your GPS is turned on.'),
                    style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      elevation: 2,
                    ),
                    icon: const Icon(Icons.location_on, size: 20),
                    label: Text(
                      delivery.isPermissionDenied
                          ? 'GRANT PERMISSION'
                          : 'TURN ON LOCATION / GPS',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        letterSpacing: 0.5,
                      ),
                    ),
                    onPressed: () => delivery.enableLocationServices(),
                  ),
                ],
              ),
            ),
          ),
      ],
    );

    return widget.height != null ? SizedBox(height: widget.height, child: map) : map;
  }
}

class RapidoTopDownBikePainter extends CustomPainter {
  const RapidoTopDownBikePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Colors
    final yellowPaint = Paint()
      ..color = const Color(0xFFFFC107) // Rapido yellow
      ..style = PaintingStyle.fill;

    final yellowDarkPaint = Paint()
      ..color = const Color(0xFFFFA000)
      ..style = PaintingStyle.fill;

    final blackPaint = Paint()
      ..color = const Color(0xFF212121)
      ..style = PaintingStyle.fill;

    final greenPaint = Paint()
      ..color = const Color(0xFF2E7D32) // FreshInBasket green jacket
      ..style = PaintingStyle.fill;

    final whitePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final strokePaint = Paint()
      ..color = const Color(0xFF1A1A1A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    // 1. Rear Tire (bottom)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy + 18), width: 6, height: 10),
        const Radius.circular(3),
      ),
      blackPaint,
    );

    // 2. Front Tire (top)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy - 18), width: 6, height: 10),
        const Radius.circular(3),
      ),
      blackPaint,
    );

    // 3. Scooter Main Body (Yellow)
    final bodyPath = Path()
      ..moveTo(cx - 7, cy - 12)
      ..cubicTo(cx - 10, cy - 6, cx - 10, cy + 6, cx - 8, cy + 14)
      ..lineTo(cx + 8, cy + 14)
      ..cubicTo(cx + 10, cy + 6, cx + 10, cy - 6, cx + 7, cy - 12)
      ..close();
    canvas.drawPath(bodyPath, yellowPaint);
    canvas.drawPath(bodyPath, strokePaint);

    // 4. Scooter Front Cowl & Headlight (Yellow & White)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy - 14), width: 14, height: 8),
        const Radius.circular(4),
      ),
      yellowDarkPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy - 14), width: 14, height: 8),
        const Radius.circular(4),
      ),
      strokePaint,
    );
    // Headlight
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy - 16), width: 6, height: 3),
        const Radius.circular(1.5),
      ),
      whitePaint,
    );

    // 5. Handlebars & Grips
    final barPaint = Paint()
      ..color = const Color(0xFF1A1A1A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;
    canvas.drawLine(Offset(cx - 13, cy - 12), Offset(cx + 13, cy - 12), barPaint);
    canvas.drawCircle(Offset(cx - 13, cy - 12), 2.0, blackPaint);
    canvas.drawCircle(Offset(cx + 13, cy - 12), 2.0, blackPaint);

    // 6. Rider Arms (Green Jacket)
    final armPaint = Paint()
      ..color = const Color(0xFF2E7D32)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx - 6, cy - 3), Offset(cx - 11, cy - 10), armPaint);
    canvas.drawLine(Offset(cx + 6, cy - 3), Offset(cx + 11, cy - 10), armPaint);

    // 7. Rider Torso (Green)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy - 1), width: 13, height: 11),
        const Radius.circular(5),
      ),
      greenPaint,
    );

    // 8. Rider Helmet (Yellow with visor)
    canvas.drawCircle(Offset(cx, cy - 4), 7.0, yellowPaint);
    canvas.drawCircle(Offset(cx, cy - 4), 7.0, strokePaint..strokeWidth = 1.0);
    // Visor
    final visorPath = Path()
      ..addArc(Rect.fromCircle(center: Offset(cx, cy - 4), radius: 5.2), -2.4, 1.7);
    canvas.drawPath(visorPath, blackPaint..style = PaintingStyle.stroke..strokeWidth = 2.5);

    // 9. Delivery Box on Rear (Yellow box with green FreshInBasket accent)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy + 11), width: 18, height: 13),
        const Radius.circular(2.5),
      ),
      yellowPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy + 11), width: 18, height: 13),
        const Radius.circular(2.5),
      ),
      strokePaint..style = PaintingStyle.stroke..strokeWidth = 1.0,
    );
    // FreshInBasket green box badge
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy + 11), width: 13, height: 5),
        const Radius.circular(1.0),
      ),
      greenPaint..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
