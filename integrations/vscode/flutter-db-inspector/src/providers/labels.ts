import type { DataModel, EntityKind } from '../protocol/types';

const ENGINE_LABELS: Record<string, string> = {
  sqlite: 'SQLite',
  sqflite: 'sqflite',
  drift: 'Drift',
  floor: 'Floor',
  isar: 'Isar',
  hive: 'Hive',
  objectbox: 'ObjectBox',
  realm: 'Realm',
  sembast: 'Sembast',
  shared_preferences: 'SharedPreferences',
  secure_storage: 'Secure Storage',
  get_storage: 'GetStorage',
};

export function engineLabel(type: string): string {
  return ENGINE_LABELS[type] ?? type;
}

export function dataModelLabel(model: DataModel): string {
  switch (model) {
    case 'relational':
      return 'relational';
    case 'document':
      return 'object / document';
    case 'keyValue':
      return 'key-value';
    default:
      return model;
  }
}

export function entityGroupLabel(kind: EntityKind): string {
  switch (kind) {
    case 'table':
      return 'Tables';
    case 'view':
      return 'Views';
    case 'collection':
      return 'Collections';
    case 'box':
      return 'Boxes';
    case 'store':
      return 'Stores';
    default:
      return `${kind[0]?.toUpperCase() ?? ''}${kind.slice(1)}s`;
  }
}

/** Singular word for one record in an entity of this kind. */
export function recordNoun(kind: EntityKind, plural = false): string {
  const noun = kind === 'collection' ? 'object' : kind === 'box' || kind === 'store' ? 'entry' : 'row';
  if (!plural) return noun;
  return noun === 'entry' ? 'entries' : `${noun}s`;
}

export function entityIcon(kind: EntityKind): string {
  switch (kind) {
    case 'view':
      return 'eye';
    case 'collection':
      return 'symbol-class';
    case 'box':
      return 'package';
    case 'store':
      return 'symbol-key';
    default:
      return 'table';
  }
}
