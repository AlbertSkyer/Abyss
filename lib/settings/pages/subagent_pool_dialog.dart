import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_input.dart';
import '../../l10n/l10n.dart';
import '../../models/model_provider.dart';
import '../../models/model_providers.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import 'model_dialogs.dart';

/// Asks which of the models configured in [providers] to add to the
/// subagent pool: those already in it are not offered. Completes with the
/// [modelRef]s checked, in the order listed, or null when dismissed.
Future<List<String>?> showSubagentPoolDialog(
  BuildContext context, {
  required ModelProviders providers,
}) => showGeneralDialog<List<String>>(
  context: context,
  barrierDismissible: true,
  barrierLabel: context.l10n.commonDismiss,
  barrierColor: const Color(0x80000000),
  transitionDuration: Duration.zero,
  pageBuilder: (context, _, _) => SubagentPoolDialog(providers: providers),
);

class SubagentPoolDialog extends StatefulWidget {
  const SubagentPoolDialog({super.key, required this.providers});

  final ModelProviders providers;

  @override
  State<SubagentPoolDialog> createState() => _SubagentPoolDialogState();
}

class _SubagentPoolDialogState extends State<SubagentPoolDialog> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _checked = {};

  /// The models that may be added: those turned on, of the upstreams
  /// turned on, that are not in the pool yet nor gone upstream.
  late final List<(ModelProvider, ProviderModel)> _candidates = [
    for (final provider in widget.providers.enabled)
      for (final model in provider.enabledModels)
        if (!model.missing &&
            !widget.providers.hasSubagentModel(modelRef(provider.id, model.id)))
          (provider, model),
  ];

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<(ModelProvider, ProviderModel)> get _shown {
    final query = _search.text.trim().toLowerCase();
    return [
      for (final (provider, model) in _candidates)
        if (query.isEmpty ||
            model.id.toLowerCase().contains(query) ||
            model.displayName.toLowerCase().contains(query) ||
            provider.name.toLowerCase().contains(query))
          (provider, model),
    ];
  }

  void _apply() {
    Navigator.pop(context, [
      for (final (provider, model) in _candidates)
        if (_checked.contains(modelRef(provider.id, model.id)))
          modelRef(provider.id, model.id),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final shown = _shown;
    final Widget body;
    if (_candidates.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(l10n.modelsSubagentPoolNoModels, style: _muted(context)),
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.modelsSubagentPoolDialogDescription,
            style: _muted(context),
          ),
          const SizedBox(height: 8),
          IdeInputBox(
            controller: _search,
            autofocus: true,
            placeholder: l10n.modelsSearch,
            semanticsLabel: l10n.modelsSearch,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.modelsFetchSelected(_checked.length, _candidates.length),
                  style: _muted(context),
                ),
              ),
              ModelDialogLinkButton(
                label: l10n.modelsFetchSelectAll,
                onPressed: () => setState(
                  () => _checked.addAll([
                    for (final (provider, model) in shown)
                      modelRef(provider.id, model.id),
                  ]),
                ),
              ),
              const SizedBox(width: 10),
              ModelDialogLinkButton(
                label: l10n.modelsFetchSelectNone,
                onPressed: () => setState(
                  () => _checked.removeAll([
                    for (final (provider, model) in shown)
                      modelRef(provider.id, model.id),
                  ]),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Flexible(
            child: shown.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(l10n.modelsNoMatch, style: _muted(context)),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: shown.length,
                    itemExtent: 30,
                    itemBuilder: (context, index) {
                      final (provider, model) = shown[index];
                      final ref = modelRef(provider.id, model.id);
                      final checked = _checked.contains(ref);
                      void toggle(bool value) => setState(
                        () => value ? _checked.add(ref) : _checked.remove(ref),
                      );
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => toggle(!checked),
                          child: Row(
                            children: [
                              ModelCheckbox(
                                checked: checked,
                                semanticLabel:
                                    '${provider.name} · '
                                    '${provider.labelOf(model)}',
                                onChanged: toggle,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: provider.labelOf(model),
                                        style: _text(context),
                                      ),
                                      TextSpan(
                                        text: '  ${provider.name}',
                                        style: _muted(context),
                                      ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
    }
    return ModelDialogFrame(
      title: l10n.modelsSubagentPoolDialogTitle,
      maxWidth: 700,
      onSubmit: _candidates.isEmpty ? null : _apply,
      actions: [
        IdeButton(
          label: l10n.modelsSubagentPoolAdd,
          onPressed: _checked.isEmpty ? null : _apply,
        ),
        IdeButton(
          label: l10n.commonCancel,
          secondary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
      child: body,
    );
  }
}

TextStyle _text(BuildContext context) => TextStyle(
  fontSize: 13,
  height: 18 / 13,
  color: themeColors['editorWidget.foreground'],
);

TextStyle _muted(BuildContext context) => TextStyle(
  fontSize: 12,
  height: 16 / 12,
  color: themeColors['descriptionForeground'],
);
