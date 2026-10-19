import 'package:flutter/material.dart';
import 'package:keynest/ui/widgets/keynest_search_highlight.dart';

enum CardFinish { matte, metal, plastic }

enum GradientDirection { diagonal, horizontal, vertical }

enum CardOrientation { landscape, portrait }

enum NamePosition { left, center, right }

class KeyNestPaymentCardView extends StatelessWidget {
  const KeyNestPaymentCardView({
    super.key,
    this.cardholderName = 'CARDHOLDER NAME',
    this.cardNumber = '•••• •••• •••• ••••',
    this.expiry = 'MM/YY',
    this.cardNetwork = 'Auto',
    this.cardColor = const Color(0xFF1E293B),
    this.secondaryColor = const Color(0xFF0F172A),
    this.finish = CardFinish.matte,
    this.gradientDirection = GradientDirection.diagonal,
    this.orientation = CardOrientation.landscape,
    this.namePosition = NamePosition.left,
    this.nameColor = Colors.white,
    this.isMasked = true,
    this.onToggleMask,
    this.searchQuery,
  });

  /// Safely parses hex color strings (supports #, 0x, 6-digit RRGGBB, and 8-digit AARRGGBB),
  /// preventing 100% transparent or failed color rendering.
  static Color parseCardColor(
    String? rawColorHex, [
    Color defaultColor = const Color(0xFF1E293B),
  ]) {
    if (rawColorHex == null) {
      return defaultColor;
    }
    var clean = rawColorHex.trim();
    while (clean.startsWith('#')) {
      clean = clean.substring(1).trim();
    }
    if (clean.toLowerCase().startsWith('0x')) {
      clean = clean.substring(2).trim();
    }
    if (clean.isEmpty) {
      return defaultColor;
    }
    if (clean.length == 6) {
      clean = 'FF$clean';
    }
    final val = int.tryParse(clean, radix: 16);
    if (val == null) {
      return defaultColor;
    }
    return Color(val);
  }

  final String cardholderName;
  final String cardNumber;
  final String expiry;
  final String cardNetwork;
  final Color cardColor;
  final Color secondaryColor;
  final CardFinish finish;
  final GradientDirection gradientDirection;
  final CardOrientation orientation;
  final NamePosition namePosition;
  final Color nameColor;
  final bool isMasked;
  final VoidCallback? onToggleMask;
  final String? searchQuery;

  String get _displayCardNumber {
    if (cardNumber.isEmpty) {
      return '•••• •••• •••• ••••';
    }
    final clean = cardNumber.replaceAll(RegExp(r'\D'), '');
    if (isMasked) {
      if (cardNumber.contains('•') || cardNumber.contains('*')) {
        return cardNumber;
      }
      if (clean.length >= 4) {
        return '•••• •••• •••• ${clean.substring(clean.length - 4)}';
      }
      return '•••• •••• •••• ••••';
    } else {
      if (clean.length <= 4) {
        return clean;
      }
      return clean
          .replaceAllMapped(RegExp(r'.{4}'), (m) => '${m.group(0)} ')
          .trim();
    }
  }

  String _detectedNetwork() {
    if (cardNetwork != 'Auto') {
      return cardNetwork;
    }
    final clean = cardNumber.replaceAll(RegExp(r'\s+'), '');
    if (clean.startsWith('4')) {
      return 'Visa';
    }
    if (clean.startsWith(RegExp(r'5[1-5]')) ||
        clean.startsWith(RegExp(r'2[2-7]'))) {
      return 'Mastercard';
    }
    if (clean.startsWith('34') || clean.startsWith('37')) {
      return 'American Express';
    }
    if (clean.startsWith('6011') || clean.startsWith('65')) {
      return 'Discover';
    }
    if (clean.startsWith(RegExp(r'35[2-8]'))) {
      return 'JCB';
    }
    if (clean.startsWith(RegExp(r'30[0-5]')) ||
        clean.startsWith('36') ||
        clean.startsWith('38')) {
      return 'Diners Club';
    }
    if (clean.startsWith(RegExp(r'(508|60|65)'))) {
      return 'RuPay';
    }
    return 'Card';
  }

  LinearGradient _buildGradient() {
    Alignment begin;
    Alignment end;
    switch (gradientDirection) {
      case GradientDirection.horizontal:
        begin = Alignment.centerLeft;
        end = Alignment.centerRight;
        break;
      case GradientDirection.vertical:
        begin = Alignment.topCenter;
        end = Alignment.bottomCenter;
        break;
      case GradientDirection.diagonal:
        begin = Alignment.topLeft;
        end = Alignment.bottomRight;
        break;
    }

    if (finish == CardFinish.metal) {
      return LinearGradient(
        begin: begin,
        end: end,
        colors: [
          cardColor,
          cardColor.withValues(alpha: 0.8),
          Colors.white.withValues(alpha: 0.25),
          cardColor,
          secondaryColor,
        ],
        stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
      );
    }

    return LinearGradient(
      begin: begin,
      end: end,
      colors: [cardColor, secondaryColor],
    );
  }

  Widget _buildNetworkBadge() {
    final net = _detectedNetwork();
    switch (net) {
      case 'Visa':
        return const Text(
          'VISA',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
            letterSpacing: 1.5,
          ),
        );
      case 'Mastercard':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: const BoxDecoration(
                color: Color(0xFFEB001B),
                shape: BoxShape.circle,
              ),
            ),
            Transform.translate(
              offset: const Offset(-6, 0),
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: const Color(0xFFF79E1B).withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        );
      case 'American Express':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFF006FCF),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            'AMEX',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
        );
      default:
        return const Icon(
          Icons.credit_card_rounded,
          color: Colors.white70,
          size: 26,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = orientation == CardOrientation.landscape;
    final width = isLandscape ? 340.0 : 240.0;
    final height = isLandscape ? 210.0 : 340.0;

    final nameAlign = namePosition == NamePosition.left
        ? CrossAxisAlignment.start
        : namePosition == NamePosition.right
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.center;

    return Center(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          gradient: _buildGradient(),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: cardColor.withValues(alpha: 0.4),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Stack(
            children: [
              if (finish == CardFinish.plastic) ...[
                Positioned(
                  top: -60,
                  right: -60,
                  child: Container(
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Top Row: Chip + Contactless + optional visibility toggle button
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Chip
                        Container(
                          width: 44,
                          height: 32,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEAB308),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: const Color(0xFFCA8A04),
                              width: 1,
                            ),
                          ),
                          child: CustomPaint(
                            painter: _ChipLinesPainter(),
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (onToggleMask != null) ...[
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: onToggleMask,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.25,
                                      ),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.2,
                                        ),
                                        width: 0.8,
                                      ),
                                    ),
                                    child: Icon(
                                      isMasked
                                          ? Icons.visibility_off_rounded
                                          : Icons.visibility_rounded,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            const Icon(
                              Icons.contactless_rounded,
                              color: Colors.white70,
                              size: 26,
                            ),
                          ],
                        ),
                      ],
                    ),

                    // Middle: Card Number
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: KeyNestSearchHighlight.text(
                          text: _displayCardNumber,
                          query: searchQuery,
                          isDark: false,
                          highlightColor: Colors.amberAccent,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            letterSpacing: 1.8,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'JetBrainsMono',
                          ),
                        ),
                      ),
                    ),

                    // Bottom Row: Name, Expiry, Network Logo
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: nameAlign,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              KeyNestSearchHighlight.text(
                                text: cardholderName.isEmpty
                                    ? 'CARDHOLDER NAME'
                                    : cardholderName.toUpperCase(),
                                query: searchQuery,
                                isDark: false,
                                highlightColor: Colors.amberAccent,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: nameColor,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                expiry.isEmpty ? 'MM/YY' : expiry,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  letterSpacing: 1.0,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        _buildNetworkBadge(),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChipLinesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFB45309).withValues(alpha: 0.6)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(0, size.height * 0.5),
      Offset(size.width, size.height * 0.5),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.33, 0),
      Offset(size.width * 0.33, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.66, 0),
      Offset(size.width * 0.66, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
