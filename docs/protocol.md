# Inspector protocol (v1)

All clients talk to the app through **one** Dart VM service extension:

```
ext.flutter_db_inspector.request      params: { isolateId, request: "<JSON string>" }
```

## Envelope

```json
{ "version": 1, "requestId": "abc123", "method": "database.list", "params": {} }
```

```json
{ "version": 1, "requestId": "abc123", "success": true,  "result": { "databases": [] } }
{ "version": 1, "requestId": "abc123", "success": false, "error": { "code": "TABLE_NOT_FOUND", "message": "Table \"users\" does not exist", "details": { "table": "users" } } }
```

The runtime never returns raw exceptions.

## Versioning

- `version` is an integer **major** version. Requests for an unsupported major version return `UNSUPPORTED_PROTOCOL_VERSION` with `details.supportedVersions`.
- Additive changes, such as new methods or new optional fields, don't change the version. Clients discover what's available from `inspector.status → methods`.
- Clients must ignore unknown fields and tolerate unknown enum values, capability names and error codes.

## Methods

| Method | Params | Result |
|---|---|---|
| `inspector.status` | — | `protocolVersion`, `supportedVersions`, `packageVersion`, `mode`, `methods`, `limits` |
| `database.list` | — | `databases: [{id, name, type, dataModel, capabilities, readOnly}]` |
| `database.info` | `databaseId` | `database`, `metadata: {engine, engineVersion, path, sizeBytes, extra}` |
| `database.stats` | `databaseId` | `sizeBytes`, `entityCount`, `indexCount`, `triggerCount`, `totalRows`, `entities` |
| `schema.list` | `databaseId` | `entities: [{name, kind, rowCount, readOnly}]`, `indexes`, `triggers` |
| `schema.table` | `databaseId, table` | `schema: {name, kind, columns, rowKey, foreignKeys, indexes, triggers, sql}`, `sensitiveColumns` |
| `rows.query` | `databaseId, table, page, pageSize, filters, sort, search` | `columns`, `rows: [{key, values}]`, `page`, `pageSize`, `total` |
| `rows.count` | `databaseId, table, filters, search` | `count` |
| `row.insert` | `databaseId, table, values` | `affectedRows`, `insertedKey` |
| `row.update` | `databaseId, table, key, values` | `affectedRows` |
| `row.delete` | `databaseId, table, key` | `affectedRows` |
| `table.clear` | `databaseId, table` | `affectedRows` |
| `query.execute` | `databaseId, sql, arguments, allowWrite, maxRows` | `kind`, `columns`, `rows`, `rowCount`, `truncated`, `affectedRows`, `lastInsertId`, `elapsedMs` |
| `value.read` | `databaseId, table, key, column, offset, length` | `base64`, `offset`, `length`, `totalBytes`, `isText`, `done` |

Reserved for later versions: `transaction.*`, `database.export/import` (runtime-side), `query.history` (history is kept in the client).

### Data models, entity kinds and row keys

- `dataModel`: `relational` | `document` | `keyValue`
- `kind`: `table` | `view` | `collection` | `box` | `store`
- `rowKey` describes how rows are addressed in `key`:
  - `rowid`: `{"rowid": 42}`
  - `primaryKey`: `{"tenant": "a", "id": 7}`
  - `key`: `{"key": "theme"}` or `{"id": 3}`
  - `none`: rows are read-only, for example SQL views

Clients treat `key` as opaque and send it back unchanged.

### Capabilities

`read, filter, sort, search, insert, update, delete, clear, sql, schema, indexes, transactions, export, import, liveChanges`. The router rejects any operation the adapter doesn't advertise, and clients hide those operations.

### Filters and sorting

```json
{ "column": "name", "operator": "contains", "value": "man" }
{ "column": "created_at", "direction": "desc" }
```

Operators: `equals, notEquals, contains, startsWith, endsWith, greaterThan, lessThan, greaterOrEqual, lessOrEqual, isNull, isNotNull`.

## Values

Lossless JSON values are sent as they are. Everything else is tagged with `$type`:

| Wire | Meaning |
|---|---|
| `null`, `true`, `42`, `1.5`, `"text"` | as is |
| `{"$type":"bigint","value":"9007199254740993"}` | integers outside the JavaScript-safe range |
| `{"$type":"real","value":"NaN"}` | non-finite doubles |
| `{"$type":"text","preview":"…","size":50000,"truncated":true}` | long text; read the full value with `value.read` |
| `{"$type":"blob","size":2097152,"preview":"<base64>","truncated":true}` | binary data (short preview only) |
| `{"$type":"dateTime","value":"2024-05-01T10:30:00.000Z"}` | dates |
| `{"$type":"json","value":{…}}` | maps and lists from document or key-value stores |
| `{"$type":"masked"}` | sensitive value; never sent |
| `{"$type":"unknown","display":"…"}` | values with no JSON form |

To write a blob, send `{"$type":"blob","base64":"…"}`. Masked or truncated values can't be written back.

## Writes and confirmation

- Mutations return `WRITE_NOT_ALLOWED` with `requiresConfirmation: false` in read-only mode or for read-only databases.
- `query.execute` classifies statements. Anything not provably read-only returns `WRITE_NOT_ALLOWED` with `details.requiresConfirmation: true`. The client must ask the user, then resend with `allowWrite: true`.
- Only one statement is allowed per request.

## Limits (defaults)

| Limit | Default |
|---|---|
| Page size | 50 (max 100) |
| SQL result rows | 100 (`truncated: true` beyond) |
| Response size | 5 MB (re-encoded with compact previews, then `RESULT_TOO_LARGE`) |
| Timeout | 5 s → `QUERY_TIMEOUT` |
| Text preview | 10 KB |
| `value.read` chunk | 1 MB |

## Error codes

`INVALID_REQUEST, UNSUPPORTED_PROTOCOL_VERSION, INSPECTOR_DISABLED, DATABASE_NOT_FOUND, TABLE_NOT_FOUND, COLUMN_NOT_FOUND, ROW_NOT_FOUND, QUERY_FAILED, PERMISSION_DENIED, WRITE_NOT_ALLOWED, UNSUPPORTED_OPERATION, ADAPTER_NOT_SUPPORTED, TRANSACTION_FAILED, QUERY_TIMEOUT, RESULT_TOO_LARGE, DATABASE_BUSY, INTERNAL_ERROR`

## Events

On the VM service `Extension` stream:

| `extensionKind` | Data | Meaning |
|---|---|---|
| `flutter_db_inspector.databasesChanged` | `{databases: [ids]}` | Re-run `database.list` |

Hot restart shows up as VM `Isolate` events (`IsolateExit`, then `ServiceExtensionAdded` for the new isolate).
