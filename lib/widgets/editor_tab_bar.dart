import 'package:flutter/material.dart';

import '../models/editor_tab.dart';
import 'editor_tab_item.dart';

class EditorTabBar extends StatelessWidget {
  final List<EditorTab> tabs;
  final int activeTabIndex;
  final ValueChanged<int> onTabTap;
  final ValueChanged<int> onTabClose;
  final VoidCallback onNewTab;

  const EditorTabBar({
    super.key,
    required this.tabs,
    required this.activeTabIndex,
    required this.onTabTap,
    required this.onTabClose,
    required this.onNewTab,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      height: 36,
      color: colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          // Scrollable tab list
          Expanded(
            child: ScrollConfiguration(
              // Hide the scrollbar — horizontal tab scrolling should feel natural.
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (int i = 0; i < tabs.length; i++)
                      EditorTabItem(
                        tab: tabs[i],
                        isActive: i == activeTabIndex,
                        onTap: () => onTabTap(i),
                        onClose: () => onTabClose(i),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // Divider before the + button
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: colorScheme.outlineVariant,
          ),

          // New tab button — ExcludeFocus prevents focus theft on click.
          ExcludeFocus(
            child: SizedBox(
              width: 36,
              height: 36,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 18,
                icon: Icon(Icons.add, color: colorScheme.onSurfaceVariant),
                tooltip: 'New tab (Ctrl+N)',
                onPressed: onNewTab,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
