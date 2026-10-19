import 'package:flutter/material.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';

class KeyNestSegmentedTab {
  const KeyNestSegmentedTab({
    required this.label,
    required this.icon,
    this.badge = false,
  });

  final String label;
  final Widget icon;
  final bool badge;
}

/// Segmented tab pill selector and animated sliding indicator pager.
class KeyNestSegmentedTabs extends StatefulWidget {
  const KeyNestSegmentedTabs({
    super.key,
    required this.options,
    required this.selectedIndex,
    required this.onSelect,
    this.compact = false,
    this.accentColor,
    this.padding = EdgeInsets.zero,
  });

  final List<KeyNestSegmentedTab> options;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool compact;
  final Color? accentColor;
  final EdgeInsetsGeometry padding;

  @override
  State<KeyNestSegmentedTabs> createState() => _KeyNestSegmentedTabsState();
}

class _KeyNestSegmentedTabsState extends State<KeyNestSegmentedTabs> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final segmentHeight = widget.compact ? 34.0 : KeyNestTokens.pillHeightLarge;
    final iconSize = widget.compact ? 16.0 : 18.0;

    final baseFill = isDark
        ? KeyNestTokens.darkSurfaceVariant.withValues(alpha: 0.35)
        : KeyNestTokens.lightSurfaceVariant.withValues(alpha: 0.5);

    final selectedFill = widget.accentColor != null
        ? widget.accentColor!.withValues(alpha: 0.25)
        : (isDark
              ? KeyNestTokens.darkPrimaryContainer
              : KeyNestTokens.lightPrimaryContainer);

    final selectedEdge =
        widget.accentColor ??
        (isDark ? KeyNestTokens.darkPrimary : KeyNestTokens.lightPrimary);

    final contentColor = isDark
        ? KeyNestTokens.darkOnSurface
        : KeyNestTokens.lightOnSurface;
    final selectedContentColor = widget.accentColor != null
        ? contentColor
        : (isDark
              ? KeyNestTokens.darkOnPrimaryContainer
              : KeyNestTokens.lightOnPrimaryContainer);

    return Padding(
      padding: widget.padding,
      child: Container(
        height: segmentHeight + 8.0,
        padding: const EdgeInsets.all(4.0),
        decoration: ShapeDecoration(
          color: baseFill,
          shape: const StadiumBorder(
            side: BorderSide(
              color: Colors.black12,
              width: 0.5,
            ),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tabWidth = constraints.maxWidth / widget.options.length;

            return Stack(
              children: [
                // Sliding indicator pill
                AnimatedPositioned(
                  duration: KeyNestTokens.durationNormal,
                  curve: KeyNestTokens.fastOutSlowIn,
                  left: widget.selectedIndex * tabWidth,
                  top: 0,
                  bottom: 0,
                  width: tabWidth,
                  child: Container(
                    decoration: ShapeDecoration(
                      color: selectedFill,
                      shape: StadiumBorder(
                        side: BorderSide(color: selectedEdge, width: 1.0),
                      ),
                    ),
                  ),
                ),
                // Tab labels & icons
                Row(
                  children: [
                    for (int i = 0; i < widget.options.length; i++)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => widget.onSelect(i),
                          child: Container(
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4.0,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconTheme(
                                  data: IconThemeData(
                                    size: iconSize,
                                    color: i == widget.selectedIndex
                                        ? selectedContentColor
                                        : contentColor.withValues(alpha: 0.6),
                                  ),
                                  child: widget.options[i].icon,
                                ),
                                const SizedBox(width: 6.0),
                                Flexible(
                                  child: Text(
                                    widget.options[i].label,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: i == widget.selectedIndex
                                              ? selectedContentColor
                                              : contentColor.withValues(
                                                  alpha: 0.7,
                                                ),
                                          fontWeight: i == widget.selectedIndex
                                              ? FontWeight.bold
                                              : FontWeight.w500,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (widget.options[i].badge) ...[
                                  const SizedBox(width: 4.0),
                                  Container(
                                    width: 6.0,
                                    height: 6.0,
                                    decoration: BoxDecoration(
                                      color: selectedEdge,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
