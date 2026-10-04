import assert from 'node:assert/strict';

export function frame(payload, opcode = 1, final = true, declaredSize) {
  payload = Buffer.from(payload);
  declaredSize ??= payload.length;
  let header;
  if (declaredSize < 126) header = Buffer.from([0, declaredSize]);
  else if (declaredSize <= 65535) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(declaredSize, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(declaredSize), 2);
  }
  header[0] = (final ? 128 : 0) | opcode;
  return Buffer.concat([header, payload]);
}

export function decoder(socket, onFrame) {
  let pending = Buffer.alloc(0);
  socket.on('data', chunk => {
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 2) {
      const first = pending[0];
      const masked = (pending[1] & 128) !== 0;
      let length = pending[1] & 127;
      let offset = 2;
      if (length === 126) {
        if (pending.length < 4) return;
        length = pending.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (pending.length < 10) return;
        length = Number(pending.readBigUInt64BE(2));
        offset = 10;
      }
      assert.ok(masked, 'Client frames must be masked');
      assert.ok(length <= 32 * 1024 * 1024, 'Unexpected client frame size');
      if (pending.length < offset + 4 + length) return;
      const mask = pending.subarray(offset, offset + 4);
      offset += 4;
      const payload = Buffer.from(pending.subarray(offset, offset + length));
      for (let i = 0; i < payload.length; ++i) payload[i] ^= mask[i % 4];
      pending = pending.subarray(offset + length);
      onFrame({opcode: first & 15, final: (first & 128) !== 0, payload});
    }
  });
}
