const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const nacl = require('tweetnacl');

test('transfer keys are recipient-wrapped and file chunks authenticate with secretbox', () => {
  const sender = nacl.box.keyPair();
  const first = nacl.box.keyPair();
  const second = nacl.box.keyPair();
  const outsider = nacl.box.keyPair();
  const transferKey = crypto.randomBytes(32);
  const envelopeFor = publicKey => {
    const nonce = crypto.randomBytes(nacl.box.nonceLength);
    return { nonce, ciphertext: nacl.box(transferKey, nonce, publicKey, sender.secretKey) };
  };
  const firstEnvelope = envelopeFor(first.publicKey);
  const secondEnvelope = envelopeFor(second.publicKey);
  assert.deepEqual(Array.from(nacl.box.open(firstEnvelope.ciphertext, firstEnvelope.nonce, sender.publicKey, first.secretKey)), Array.from(transferKey));
  assert.deepEqual(Array.from(nacl.box.open(secondEnvelope.ciphertext, secondEnvelope.nonce, sender.publicKey, second.secretKey)), Array.from(transferKey));
  assert.equal(nacl.box.open(firstEnvelope.ciphertext, firstEnvelope.nonce, sender.publicKey, outsider.secretKey), null);

  const plaintext = Buffer.from('file data is encrypted on the sending device');
  const nonce = crypto.randomBytes(nacl.secretbox.nonceLength);
  const ciphertext = nacl.secretbox(plaintext, nonce, transferKey);
  assert.deepEqual(Array.from(nacl.secretbox.open(ciphertext, nonce, transferKey)), Array.from(plaintext));
  const tampered = new Uint8Array(ciphertext); tampered[tampered.length - 1] ^= 1;
  assert.equal(nacl.secretbox.open(tampered, nonce, transferKey), null);
});
