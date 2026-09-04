import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../providers/delivery_provider.dart';
import '../models/order.dart';
import '../theme/app_theme.dart';
import '../widgets/delivery_map_widget.dart';
import 'main_shell.dart';

class MapView extends StatefulWidget {
  const MapView({super.key});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  // The MapController lives here so the re-centre button can move the camera.
  // The controller is passed down to DeliveryMapWidget, which renders the map.
  final MapController _mapController = MapController();

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  void _recenter() {
    final delivery = context.read<DeliveryProvider>();
    // Ask the provider to get a fresh GPS fix; the widget will rebuild.
    delivery.recenterLocation().then((_) {
      if (!mounted) return;
      try {
        if (delivery.driverLocation != null) {
          _mapController.move(delivery.driverLocation!, 15.0);
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final delivery = context.watch<DeliveryProvider>();
    final activeOrder = delivery.activeOrder;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppTheme.primaryColor),
          onPressed: () => MainShell.selectTab(context, 0),
        ),
        title: const Text(
          'Active Delivery Map',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _recenter,
        backgroundColor: AppTheme.primaryColor,
        child: const Icon(Icons.my_location, color: Colors.white),
      ),
      body: Stack(
        children: [
          // ── Shared map widget — no GPS/route logic here ────────────────
          DeliveryMapWidget(
            mapController: _mapController,
            showLoadingOverlay: true,
            onOrderTap: (order) => _showOrderDetails(order, delivery),
          ),

          // ── Active order info card at bottom ───────────────────────────
          if (activeOrder != null)
            Positioned(
              bottom: 20,
              left: 16,
              right: 16,
              child: Card(
                elevation: 8,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'ACTIVE DELIVERY',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey.shade500,
                              letterSpacing: 1.2,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppTheme.successBgColor,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Order #${activeOrder.orderNumber}',
                              style: const TextStyle(
                                color: AppTheme.primaryColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Customer name
                      Text(
                        activeOrder.customerName,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),

                      // Delivery address
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.location_on_outlined,
                              size: 16, color: Colors.grey),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              activeOrder.deliveryAddress.isNotEmpty
                                  ? activeOrder.deliveryAddress
                                  : 'Address not available',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey.shade600),
                            ),
                          ),
                        ],
                      ),

                      // Distance indicator (uses provider's driverLocation)
                      if (delivery.locationReady &&
                          activeOrder.deliveryLatitude != null &&
                          activeOrder.deliveryLongitude != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              const Icon(Icons.directions_bike,
                                  size: 14,
                                  color: AppTheme.primaryColor),
                              const SizedBox(width: 4),
                              Text(
                                _distanceText(delivery, activeOrder),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.primaryColor,
                                  fontWeight: FontWeight.w600,
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

  String _distanceText(DeliveryProvider delivery, dynamic order) {
    if (order.deliveryLatitude == null || order.deliveryLongitude == null || delivery.driverLocation == null) {
      return '';
    }
    final m = Geolocator.distanceBetween(
      delivery.driverLocation!.latitude,
      delivery.driverLocation!.longitude,
      order.deliveryLatitude as double,
      order.deliveryLongitude as double,
    );
    return m < 1000
        ? '${m.toStringAsFixed(0)} m away'
        : '${(m / 1000).toStringAsFixed(1)} km away';
  }

  void _showOrderDetails(DeliveryOrder order, DeliveryProvider delivery) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Order #${order.orderNumber}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primaryColor,
                    ),
                  ),
                  Text(
                    _distanceText(delivery, order),
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const Divider(height: 32),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline, color: AppTheme.primaryColor),
                title: Text(order.customerName, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(order.customerPhone),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.location_on_outlined, color: AppTheme.primaryColor),
                title: const Text('Address', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(order.deliveryAddress),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.payment_outlined, color: AppTheme.primaryColor),
                title: const Text('Payment', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${order.paymentMethod} - ₹${order.totalAmount.toStringAsFixed(2)}'),
              ),
              const Divider(height: 32),
              const Text(
                'ITEMS',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: order.items.length,
                itemBuilder: (context, index) {
                  final item = order.items[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${item.productName} (${item.quantity % 1 == 0 ? item.quantity.toInt() : item.quantity}x ${item.unitName})'),
                        Text('₹${item.totalPrice.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    delivery.updateOrderStatus(order.orderId, 'OUT_FOR_DELIVERY');
                  },
                  child: const Text('START DELIVERY', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }
}
