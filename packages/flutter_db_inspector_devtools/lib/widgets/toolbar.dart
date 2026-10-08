import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

/// A dense toolbar row (DevTools style).
class InspectorToolbar extends StatelessWidget {
  const InspectorToolbar({super.key, required this.children, this.label});

  final List<Widget> children;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: label,
      child: Container(
        height: defaultToolbarHeight + densePadding,
        padding: const EdgeInsets.symmetric(horizontal: densePadding),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: FocusTraversalGroup(
          child: Row(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(width: densePadding),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A thin vertical separator between toolbar groups.
class ToolbarSeparator extends StatelessWidget {
  const ToolbarSeparator({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: defaultButtonHeight - densePadding,
        child: VerticalDivider(
            width: 1, color: Theme.of(context).colorScheme.outlineVariant),
      );
}

/// Search box that reports changes after the user stopped typing.
class DebouncedSearchField extends StatefulWidget {
  const DebouncedSearchField({
    super.key,
    required this.onChanged,
    this.initialValue = '',
    this.focusNode,
    this.hintText = 'Search',
    this.delay = const Duration(milliseconds: 300),
    this.width = defaultSearchFieldWidth,
  });

  final void Function(String text) onChanged;
  final String initialValue;
  final FocusNode? focusNode;
  final String hintText;
  final Duration delay;
  final double width;

  @override
  State<DebouncedSearchField> createState() => _DebouncedSearchFieldState();
}

class _DebouncedSearchFieldState extends State<DebouncedSearchField> {
  late final _controller = TextEditingController(text: widget.initialValue);
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _timer?.cancel();
    _timer = Timer(widget.delay, () => widget.onChanged(text));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: widget.width,
      height: defaultTextFieldHeight,
      child: TextField(
        controller: _controller,
        focusNode: widget.focusNode,
        style: theme.regularTextStyle,
        onChanged: _changed,
        onSubmitted: (text) {
          _timer?.cancel();
          widget.onChanged(text);
        },
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.hintText,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: densePadding),
          prefixIcon: const Icon(Icons.search, size: defaultIconSize),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 24, minHeight: 24),
          suffixIconConstraints:
              const BoxConstraints(minWidth: 24, minHeight: 24),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  iconSize: defaultIconSize,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _controller.clear();
                    _changed('');
                  },
                ),
        ),
      ),
    );
  }
}

/// Page size selector and first/previous/next/last navigation.
class Pager extends StatelessWidget {
  const Pager({
    super.key,
    required this.pageIndex,
    required this.pageSize,
    required this.pageSizes,
    required this.hasNext,
    required this.onPage,
    required this.onPageSize,
    this.pageCount,
  });

  final int pageIndex;
  final int? pageCount;
  final int pageSize;
  final List<int> pageSizes;
  final bool hasNext;
  final void Function(int index) onPage;
  final void Function(int size) onPageSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pages = pageCount;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Page size',
          child: DropdownButton<int>(
            value: pageSize,
            isDense: true,
            underline: const SizedBox(),
            style: theme.regularTextStyle,
            items: [
              for (final n in pageSizes)
                DropdownMenuItem(value: n, child: Text('$n / page')),
            ],
            onChanged: (n) {
              if (n != null) onPageSize(n);
            },
          ),
        ),
        const SizedBox(width: densePadding),
        DevToolsButton.iconOnly(
          icon: Icons.first_page,
          tooltip: 'First page',
          outlined: false,
          onPressed: pageIndex > 0 ? () => onPage(0) : null,
        ),
        DevToolsButton.iconOnly(
          icon: Icons.chevron_left,
          tooltip: 'Previous page',
          outlined: false,
          onPressed: pageIndex > 0 ? () => onPage(pageIndex - 1) : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: densePadding),
          child: Semantics(
            label: 'Page ${pageIndex + 1}${pages == null ? '' : ' of $pages'}',
            excludeSemantics: true,
            child: Text(
              '${WireValues.formatCount(pageIndex + 1)}'
              '${pages == null ? '' : ' / ${WireValues.formatCount(pages)}'}',
              style: theme.regularTextStyle,
            ),
          ),
        ),
        DevToolsButton.iconOnly(
          icon: Icons.chevron_right,
          tooltip: 'Next page',
          outlined: false,
          onPressed: hasNext ? () => onPage(pageIndex + 1) : null,
        ),
        DevToolsButton.iconOnly(
          icon: Icons.last_page,
          tooltip: 'Last page',
          outlined: false,
          onPressed: pages != null && pageIndex < pages - 1
              ? () => onPage(pages - 1)
              : null,
        ),
      ],
    );
  }
}

/// The status line under a grid.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        height: statusLineHeight + densePadding,
        padding: const EdgeInsets.symmetric(horizontal: denseSpacing),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          border:
              Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: DefaultTextStyle(
          style: theme.subtleTextStyle,
          child: Row(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(width: denseSpacing),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
