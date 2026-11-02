import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../l10n/app_localizations.dart';

/// 社区合集详情列表共用的信息头部。
class CommunityCollectionHeader extends StatefulWidget {
  final String? description;
  final String? authorNickname;
  final DateTime? updatedAt;
  final int fileCount;
  final bool showAuthor;

  const CommunityCollectionHeader({
    super.key,
    required this.description,
    required this.authorNickname,
    this.updatedAt,
    required this.fileCount,
    this.showAuthor = true,
  });

  @override
  State<CommunityCollectionHeader> createState() =>
      _CommunityCollectionHeaderState();
}

class _CommunityCollectionHeaderState extends State<CommunityCollectionHeader> {
  bool _expanded = false;
  late final TapGestureRecognizer _descriptionToggleRecognizer;

  @override
  void initState() {
    super.initState();
    _descriptionToggleRecognizer = TapGestureRecognizer()
      ..onTap = _toggleDescription;
  }

  @override
  void dispose() {
    _descriptionToggleRecognizer.dispose();
    super.dispose();
  }

  void _toggleDescription() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final description = widget.description?.trim();
    final authorNickname = widget.authorNickname?.trim();
    final author = authorNickname == null || authorNickname.isEmpty
        ? l10n.communityCollectionUnknownAuthor
        : authorNickname;
    final updatedAt = widget.updatedAt;
    final updateDate = updatedAt == null
        ? null
        : DateFormat('yyyy-MM-dd HH:mm').format(updatedAt);
    final authorItem = _MetadataItem(
      key: const ValueKey('community-collection-author-metadata'),
      icon: Icons.person_outline_rounded,
      label: author,
      semanticLabel: l10n.communityCollectionAuthor(author),
    );
    final updateItem = updateDate == null
        ? null
        : _MetadataItem(
            key: const ValueKey('community-collection-updated-metadata'),
            icon: Icons.update_rounded,
            label: updateDate,
            semanticLabel: updateDate,
          );
    final countItem = _MetadataItem(
      key: const ValueKey('community-collection-count-metadata'),
      icon: Icons.library_music_outlined,
      label: l10n.audioCount(widget.fileCount),
      semanticLabel: l10n.audioCount(widget.fileCount),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (description != null && description.isNotEmpty)
            LayoutBuilder(
              builder: (context, constraints) {
                final style = theme.textTheme.bodyMedium;
                final descriptionStyle =
                    style ?? DefaultTextStyle.of(context).style;
                final toggleStyle = descriptionStyle.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                );
                final painter = TextPainter(
                  text: TextSpan(text: description, style: descriptionStyle),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                  maxLines: 3,
                  ellipsis: '…',
                )..layout(maxWidth: constraints.maxWidth);
                final hasOverflow = painter.didExceedMaxLines;
                painter.dispose();
                final collapsedPrefix = hasOverflow
                    ? _collapsedPrefix(
                        description: description,
                        actionLabel: l10n.communityCollectionShowMore,
                        maxWidth: constraints.maxWidth,
                        textStyle: descriptionStyle,
                        actionStyle: toggleStyle,
                        textDirection: Directionality.of(context),
                        textScaler: MediaQuery.textScalerOf(context),
                      )
                    : description;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeInOut,
                      alignment: Alignment.topLeft,
                      child: Semantics(
                        expanded: _expanded,
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: _expanded ? description : collapsedPrefix,
                                style: descriptionStyle,
                              ),
                              if (hasOverflow) ...[
                                TextSpan(
                                  text: _expanded ? ' ' : '… ',
                                  style: descriptionStyle,
                                ),
                                TextSpan(
                                  text: _expanded
                                      ? l10n.communityCollectionShowLess
                                      : l10n.communityCollectionShowMore,
                                  style: toggleStyle,
                                  recognizer: _descriptionToggleRecognizer,
                                ),
                              ],
                            ],
                          ),
                          key: const ValueKey(
                            'community-collection-description',
                          ),
                          maxLines: _expanded ? null : 3,
                          overflow: TextOverflow.clip,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          if (description != null && description.isNotEmpty)
            const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: Wrap(
              key: const ValueKey('community-collection-metadata-row'),
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.showAuthor) authorItem,
                if (updateItem != null) updateItem,
                countItem,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 测量三行内可容纳的最长前缀，为行内展开链接预留位置。
String _collapsedPrefix({
  required String description,
  required String actionLabel,
  required double maxWidth,
  required TextStyle textStyle,
  required TextStyle actionStyle,
  required TextDirection textDirection,
  required TextScaler textScaler,
}) {
  final characters = description.runes.toList(growable: false);
  var lower = 0;
  var upper = characters.length;

  while (lower < upper) {
    final candidateLength = (lower + upper + 1) ~/ 2;
    final prefix = String.fromCharCodes(
      characters.take(candidateLength),
    ).trimRight();
    final painter = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(text: prefix, style: textStyle),
          TextSpan(text: '… ', style: textStyle),
          TextSpan(text: actionLabel, style: actionStyle),
        ],
      ),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 3,
    )..layout(maxWidth: maxWidth);
    final fits = !painter.didExceedMaxLines;
    painter.dispose();

    if (fits) {
      lower = candidateLength;
    } else {
      upper = candidateLength - 1;
    }
  }

  return String.fromCharCodes(characters.take(lower)).trimRight();
}

class _MetadataItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String semanticLabel;

  const _MetadataItem({
    super.key,
    required this.icon,
    required this.label,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metadataColor =
        Color.lerp(
          theme.colorScheme.onSurfaceVariant,
          theme.colorScheme.surfaceContainerLow,
          0.20,
        ) ??
        theme.colorScheme.onSurfaceVariant;
    return LayoutBuilder(
      builder: (context, constraints) {
        final labelMaxWidth = constraints.maxWidth.isFinite
            ? (constraints.maxWidth - 21).clamp(0.0, 240.0).toDouble()
            : 240.0;
        return Semantics(
          label: semanticLabel,
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(icon, size: 16, color: metadataColor),
                ),
              ),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: labelMaxWidth),
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: metadataColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
