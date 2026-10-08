import assert from 'node:assert/strict';
import { test } from 'node:test';

import { toWebSocketUri } from '../../src/connection/wsTransport';

test('normalizes VM service URIs from every source', () => {
  assert.equal(toWebSocketUri('http://127.0.0.1:50300/abc=/'), 'ws://127.0.0.1:50300/abc=/ws');
  assert.equal(toWebSocketUri('http://127.0.0.1:50300/abc='), 'ws://127.0.0.1:50300/abc=/ws');
  assert.equal(toWebSocketUri('ws://127.0.0.1:50300/abc=/ws'), 'ws://127.0.0.1:50300/abc=/ws');
  assert.equal(
    toWebSocketUri('The Dart VM service is listening on http://127.0.0.1:61234/x_Y-z=/'),
    'ws://127.0.0.1:61234/x_Y-z=/ws',
  );
  assert.equal(
    toWebSocketUri('http://127.0.0.1:9100/devtools/?uri=ws%3A%2F%2F127.0.0.1%3A61234%2Ftok%3D%2Fws'),
    'ws://127.0.0.1:61234/tok=/ws',
  );
  assert.throws(() => toWebSocketUri('not a uri'));
});
