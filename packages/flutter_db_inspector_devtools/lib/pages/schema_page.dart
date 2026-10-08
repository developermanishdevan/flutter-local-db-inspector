import 'package:flutter/material.dart';

import '../services/host.dart';
import '../services/inspector_controller.dart';
import '../widgets/common.dart';
import '../widgets/schema_view.dart';

/// The Schema tab: the selected entity's schema, or the database overview
/// when no entity is selected.
class SchemaPage extends StatelessWidget {
  const SchemaPage({super.key, required this.controller, required this.host});

  final InspectorController controller;
  final InspectorHost host;

  @override
  Widget build(BuildContext context) {
    final db = controller.selectedDatabase;
    if (db == null) return const EmptyMessage('Select a database');
    final model = db.descriptor.dataModel;
    final table = controller.table;
    if (table == null) {
      final overview = db.overview;
      if (overview == null) {
        return db.error != null
            ? Center(child: ErrorText(db.error!))
            : const Center(child: CircularProgressIndicator());
      }
      return SchemaOverviewView(
        overview: overview,
        dataModel: model,
        onOpenEntity: (name) =>
            controller.selectEntity(db.id, name, tab: InspectorTab.schema),
      );
    }
    return ListenableBuilder(
      listenable: table,
      builder: (context, _) {
        final schema = table.schema;
        if (schema == null) {
          return table.error != null
              ? Center(child: ErrorText(table.error!))
              : const Center(child: CircularProgressIndicator());
        }
        return SchemaView(
          result: schema,
          dataModel: model,
          onCopy: (text) => host.copyToClipboard(text, what: 'definition'),
          onOpenTable: (name) {
            if (db.entity(name) != null) {
              controller.selectEntity(db.id, name, tab: InspectorTab.schema);
            }
          },
        );
      },
    );
  }
}
