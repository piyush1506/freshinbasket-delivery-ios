import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';

import '../widgets/dynamic_slide_action.dart';
import '../providers/auth_provider.dart';
import '../providers/delivery_provider.dart';
import '../models/order.dart';
import '../theme/app_theme.dart';
import '../widgets/delivery_map_widget.dart';
import 'main_shell.dart';
import 'qr_payment_screen.dart';

class DashboardView extends StatefulWidget {
  const DashboardView({super.key});

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  @override
  void initState() {
    super.initState();
    // Data fetch and GPS are started by MainShell.initState — no-op here.
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _makePhoneCall(String phoneNumber) async {
    final Uri launchUri = Uri(
      scheme: 'tel',
      path: phoneNumber,
    );
    if (await canLaunchUrl(launchUri)) {
      await launchUrl(launchUri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not launch phone call')),
        );
      }
    }
  }

  void _showOrderItemsDialog(DeliveryOrder order) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Order ${order.orderNumber} Items'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: order.items.length,
            itemBuilder: (context, index) {
              final item = order.items[index];
              return ListTile(
                title: Text(item.productName),
                trailing: Text('${item.quantity % 1 == 0 ? item.quantity.toInt() : item.quantity} ${item.unitName}'),
                subtitle: Text('₹${item.unitPrice} / unit'),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleMarkDelivered(BuildContext context, DeliveryOrder activeOrder, DeliveryProvider delivery) async {
    final bool isCod = activeOrder.paymentMethod == 'COD';
    
    final bool? confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(isCod ? 'Confirm Cash Payment' : 'Confirm Delivery'),
        content: Text(isCod
            ? 'Did you receive ₹${activeOrder.totalAmount.toStringAsFixed(2)} in cash from ${activeOrder.customerName}?'
            : 'Are you sure you want to mark order #${activeOrder.orderNumber} as delivered?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isCod ? Colors.amber.shade800 : AppTheme.primaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(isCod ? 'Yes, Received' : 'Yes, Delivered'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (!context.mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final deliveryProvider = Provider.of<DeliveryProvider>(context, listen: false);
      final completed = await delivery.updateOrderStatus(activeOrder.orderId, 'DELIVERED');
      if (completed && mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Order delivered successfully!'),
            backgroundColor: AppTheme.primaryColor,
          ),
        );
        // Re-centre map on current position after delivery is marked
        deliveryProvider.recenterLocation();
      }
    }
  }

  String _getDistanceText(DeliveryOrder order) {
    if (order.deliveryLatitude == null || order.deliveryLongitude == null) {
      return '';
    }
    final delivery =
        Provider.of<DeliveryProvider>(context, listen: false);
    if (!delivery.locationReady || delivery.driverLocation == null) {
      return '';
    }
    final driverLoc = delivery.driverLocation!;
    final m = Geolocator.distanceBetween(
      driverLoc.latitude,
      driverLoc.longitude,
      order.deliveryLatitude!,
      order.deliveryLongitude!,
    );
    return m < 1000
        ? '${m.toStringAsFixed(0)} m away'
        : '${(m / 1000).toStringAsFixed(1)} km away';
  }

  void _showUnassignedOrderDetails(DeliveryOrder order, DeliveryProvider delivery) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: SingleChildScrollView(
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
                    _getDistanceText(order),
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
            ],
          ),
        ));
      },
    );
  }



  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final delivery = Provider.of<DeliveryProvider>(context);

    final String driverName = auth.user?.username ?? 'Delivery Agent';
    final activeOrder = delivery.activeOrder;
    final remainingOrders = delivery.assignedOrders.where((o) => o.status == 'CONFIRMED' || o.status == 'PENDING').toList();
    final totalStops = delivery.assignedOrders.length;
    final completedStops = delivery.assignedOrders.where((o) => o.status == 'DELIVERED').length;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'FreshInBasket',
          style: TextStyle(
            color: AppTheme.primaryColor,
            fontWeight: FontWeight.bold,
            fontFamily: Theme.of(context).textTheme.titleLarge?.fontFamily,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: GestureDetector(
              onTap: () => MainShell.selectTab(context, 4),
              child: CircleAvatar(
                radius: 18,
                backgroundColor: AppTheme.successBgColor,
                backgroundImage: auth.user?.avatar != null
                    ? NetworkImage(auth.user!.avatar!)
                    : null,
                child: auth.user?.avatar == null
                    ? const Icon(Icons.person, size: 18, color: AppTheme.primaryColor)
                    : null,
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await delivery.fetchDashboard();
          await delivery.fetchAssignedOrders();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Welcome & On Duty Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Hello, $driverName',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () async {
                      final newStatus = !(auth.user?.isActive ?? true);
                      try {
                        await auth.toggleActiveStatus(newStatus);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(newStatus ? 'You are now Online / On Duty' : 'You are now Offline / Off Duty'),
                              backgroundColor: AppTheme.primaryColor,
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Failed to update status: $e'),
                              backgroundColor: AppTheme.errorColor,
                            ),
                          );
                        }
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: (auth.user?.isActive ?? true) ? AppTheme.successBgColor : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 4,
                            backgroundColor: (auth.user?.isActive ?? true) ? AppTheme.primaryColor : Colors.grey.shade600,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            (auth.user?.isActive ?? true) ? 'ON DUTY' : 'OFF DUTY',
                            style: TextStyle(
                              color: (auth.user?.isActive ?? true) ? AppTheme.primaryColor : Colors.grey.shade700,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'Active Route: Morning Delivery Slot',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey.shade600,
                      fontSize: 13,
                    ),
              ),
              const SizedBox(height: 14),

              // Current Order Section
              Text(
                'CURRENT ORDER',
                style: TextStyle(
                  color: Colors.grey.shade500,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 8),

              if (activeOrder != null || remainingOrders.isNotEmpty) ...[
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: DeliveryMapWidget(
                    height: 260,
                    showLoadingOverlay: false,
                    onOrderTap: (order) =>
                        _showUnassignedOrderDetails(order, delivery),
                  ),
                ),
                const SizedBox(height: 10),
              ],

              if (activeOrder != null) ...[
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Order Stop Info
                      Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppTheme.successBgColor,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'STOP #${completedStops + 1} OF $totalStops',
                                    style: const TextStyle(
                                      color: AppTheme.primaryColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  style: IconButton.styleFrom(
                                    backgroundColor: Colors.grey.shade100,
                                    padding: const EdgeInsets.all(10),
                                  ),
                                  icon: const Icon(Icons.phone_outlined, color: AppTheme.primaryColor),
                                  onPressed: () => _makePhoneCall(activeOrder.customerPhone),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              activeOrder.customerName,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              activeOrder.deliveryAddress,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            if (activeOrder.notes.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Note: ${activeOrder.notes}',
                                style: const TextStyle(
                                  color: Colors.redAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppTheme.primaryColor,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                      elevation: 0,
                                    ),
                                    icon: const Icon(Icons.navigation_outlined, size: 18),
                                    label: const Text('NAVIGATE'),
                                    onPressed: () async {
                                      // If order is PENDING or CONFIRMED, transition to OUT_FOR_DELIVERY
                                      if (activeOrder.status == 'CONFIRMED' || activeOrder.status == 'PENDING') {
                                        delivery.updateOrderStatus(activeOrder.orderId, 'OUT_FOR_DELIVERY');
                                      }
                                      
                                      final lat = activeOrder.deliveryLatitude;
                                      final lng = activeOrder.deliveryLongitude;
                                      if (lat != null && lng != null) {
                                        final url = 'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&dir_action=navigate';
                                        try {
                                          final launched = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                                          if (launched) return;
                                        } catch (e) {
                                          // Ignore and fall through to in-app map fallback
                                        }
                                      }
                                      
                                      // Fallback to in-app map if url_launcher fails or no coords
                                      if (context.mounted) {
                                        MainShell.selectTab(context, 3);
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppTheme.primaryColor,
                                      side: const BorderSide(color: AppTheme.primaryColor, width: 1.5),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                    ),
                                    onPressed: () {
                                      _showOrderItemsDialog(activeOrder);
                                    },
                                    child: const Text('VIEW ITEMS'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            const Divider(),
                            const SizedBox(height: 8),
                            // Order Details Block
                            Row(
                              children: [
                                const Icon(Icons.person_outline, size: 20, color: Colors.grey),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Customer: ${activeOrder.customerName}',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                const Icon(Icons.payment, size: 20, color: Colors.grey),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: RichText(
                                    text: TextSpan(
                                      style: TextStyle(
                                        color: Colors.grey.shade800,
                                        fontSize: 14,
                                        height: 1.4,
                                      ),
                                      children: [
                                        const TextSpan(text: 'Payment Mode: '),
                                        TextSpan(
                                          text: activeOrder.paymentMethod == 'COD' ? 'Cash on Delivery (COD)' : 'Prepaid / Online',
                                          style: const TextStyle(fontWeight: FontWeight.bold),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (activeOrder.paymentMethod == 'COD')
                              Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(top: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: Colors.amber.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.amber.shade200),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.monetization_on_outlined, color: Colors.amber.shade800, size: 20),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: RichText(
                                        text: TextSpan(
                                          style: TextStyle(
                                            color: Colors.amber.shade900,
                                            fontSize: 14,
                                          ),
                                          children: [
                                            const TextSpan(text: 'Receive payment: '),
                                            TextSpan(
                                              text: '₹${activeOrder.totalAmount.toStringAsFixed(2)}',
                                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                            ),
                                            const TextSpan(text: ' from user.'),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (activeOrder.paymentMethod == 'COD' && activeOrder.status == 'OUT_FOR_DELIVERY')
                              Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(top: 10),
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.primaryColor,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    elevation: 0,
                                  ),
                                  icon: const Icon(Icons.qr_code_2, size: 20),
                                  label: const Text(
                                    'COLLECT VIA UPI',
                                    style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5),
                                  ),
                                  onPressed: () async {
                                    final result = await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => QrPaymentScreen(order: activeOrder),
                                      ),
                                    );
                                    if (!context.mounted) return;
                                    if (result == true) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Payment collected & order delivered successfully!'),
                                          backgroundColor: AppTheme.primaryColor,
                                        ),
                                      );
                                    }
                                  },
                                ),
                              ),
                            if (activeOrder.paymentMethod != 'COD')
                              Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(top: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: AppTheme.successBgColor,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppTheme.primaryColor.withAlpha(51)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.check_circle_outline, color: AppTheme.primaryColor, size: 20),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Payment Received: ₹${activeOrder.totalAmount.toStringAsFixed(2)} (Paid Online)',
                                        style: const TextStyle(
                                          color: AppTheme.primaryColor,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 16),
                            if (activeOrder.status == 'OUT_FOR_DELIVERY')
                              Padding(
                                padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
                                child: DynamicSlideAction(
                                  text: "Mark Delivered",
                                  onSubmit: () async {
                                    _handleMarkDelivered(context, activeOrder, delivery);
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ] else if (remainingOrders.isNotEmpty) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.map_outlined, size: 40, color: Colors.grey.shade400),
                          const SizedBox(height: 8),
                          Text(
                            'No active delivery (${remainingOrders.length} pending).',
                            style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Select an order from the map or list below.',
                            style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ] else ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.check_circle_outline, size: 40, color: Colors.grey.shade400),
                          const SizedBox(height: 8),
                          Text(
                            'No assigned orders.',
                            style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 12),

              // Stat Row
              Row(
                children: [
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'COMPLETED',
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '$completedStops / $totalStops',
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.primaryColor),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Stops finished',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'PROGRESS',
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: totalStops > 0 ? (completedStops / totalStops) : 0.0,
                              backgroundColor: Colors.grey.shade200,
                              valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              totalStops > 0 ? '${((completedStops / totalStops) * 100).toInt()}% completed' : '0% completed',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // Remaining stops
              if (remainingOrders.isNotEmpty) ...[
                Text(
                  'REMAINING ORDERS',
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 12),
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: remainingOrders.length,
                  itemBuilder: (context, index) {
                    final order = remainingOrders[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.grey.shade100,
                          foregroundColor: AppTheme.primaryColor,
                          child: Text('${index + 1}'),
                        ),
                        title: Text(
                          order.customerName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              order.deliveryAddress,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _getDistanceText(order),
                              style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.w600, fontSize: 12),
                            ),
                          ],
                        ),
                        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                        onTap: () {
                          _showUnassignedOrderDetails(order, delivery);
                        },
                      ),
                    );
                  },
                ),
              ],

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

extension CountExtension<T> on Iterable<T> {
  int count() => length;
}
