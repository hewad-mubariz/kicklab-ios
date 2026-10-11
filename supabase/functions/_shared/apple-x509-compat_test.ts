import { Buffer } from 'node:buffer';
import crypto, { generateKeyPairSync } from 'node:crypto';
import { CompatibleCertificate, verifyCertificateSignature } from './apple-x509-compat.ts';
import roots from './apple-root-certificates.json' with { type: 'json' };
import { SignJWT, importPKCS8 } from 'npm:jose@6.2.12';
import jwt from 'npm:jsonwebtoken@9.0.3';
import { SignedDataVerifier, Environment } from 'npm:@apple/app-store-server-library@3.1.0';
import fixtures from '../../tests/fixtures/apple-certificate-chains.json' with { type: 'json' };
import { ASN1HEX } from 'npm:jsrsasign@11.1.5';

const equal = (actual: boolean, expected: boolean) => {
  if (actual !== expected) throw new Error(`Expected ${expected}, got ${actual}`);
};
const certificates = roots.map(root => new CompatibleCertificate(Buffer.from(root.der_base64, 'base64')));

Deno.test('RSA and EC Apple roots verify with their own keys in native and compatible runtimes', () => {
  for (const cert of certificates) {
    equal(verifyCertificateSignature(cert, cert.publicKey), true);
    equal(cert.verify(cert.publicKey), true);
    equal(new crypto.X509Certificate(cert.raw).verify(cert.publicKey), true);
    equal(new crypto.X509Certificate(cert.toString()).verify(cert.publicKey), true);
  }
});
Deno.test('unrelated issuer keys cannot verify an Apple certificate', () => {
  for (let i = 0; i < certificates.length; i++) {
    const cert = certificates[i], other = certificates[1 - i];
    equal(verifyCertificateSignature(cert, other.publicKey), false);
    equal(cert.verify(other.publicKey), false);
  }
});
Deno.test('an unrelated key using the correct algorithm is rejected', () => {
  const keys = [generateKeyPairSync('rsa', { modulusLength: 2048 }).publicKey,
    generateKeyPairSync('ec', { namedCurve: 'secp384r1' }).publicKey];
  for (let i = 0; i < certificates.length; i++) {
    equal(verifyCertificateSignature(certificates[i], keys[i]), false);
    equal(certificates[i].verify(keys[i]), false);
  }
});
Deno.test('a changed certificate signature is rejected', () => {
  for (const cert of certificates) {
    const changed = Buffer.from(cert.raw);
    changed[changed.length - 1] ^= 1;
    const tampered = new CompatibleCertificate(changed);
    equal(verifyCertificateSignature(tampered, cert.publicKey), false);
    equal(tampered.verify(cert.publicKey), false);
  }
});

Deno.test('mismatched inner and outer signature algorithms are rejected', () => {
  const cert = certificates[1];
  const hex = cert.raw.toString('hex');
  const position = ASN1HEX.getIdxbyList(hex, 0, [1], '30');
  const algorithm = ASN1HEX.getTLV(hex, position);
  // Apple Root CA G3 uses ECDSA with SHA-384; change only the outer OID to SHA-256.
  if (!algorithm.endsWith('2a8648ce3d040303')) throw new Error('Unexpected fixture algorithm');
  const changed = hex.slice(0, position) + algorithm.slice(0, -2) + '02' + hex.slice(position + algorithm.length);
  equal(verifyCertificateSignature(new CompatibleCertificate(Buffer.from(changed, 'hex')), cert.publicKey), false);
});

Deno.test('Node JWT verification accepts valid EC signatures and still rejects mismatched keys and algorithms', async () => {
  for (const [algorithm, namedCurve] of [['ES256', 'prime256v1'], ['ES384', 'secp384r1']]) {
    const pair = generateKeyPairSync('ec', { namedCurve });
    const publicKey = pair.publicKey.export({ type: 'spki', format: 'pem' });
    const privateKey = await importPKCS8(pair.privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(), algorithm);
    const token = await new SignJWT({ test: true }).setProtectedHeader({ alg: algorithm }).sign(privateKey);
    equal((jwt.verify(token, publicKey) as { test: boolean }).test, true);
    const other = generateKeyPairSync('ec', { namedCurve });
    let rejected = false;
    try { jwt.verify(token, other.publicKey.export({ type: 'spki', format: 'pem' })); } catch { rejected = true; }
    equal(rejected, true);
    const parts = token.split('.');
    parts[0] = Buffer.from(JSON.stringify({ alg: algorithm === 'ES256' ? 'ES384' : 'ES256' })).toString('base64url');
    rejected = false;
    try { jwt.verify(parts.join('.'), publicKey); } catch { rejected = true; }
    equal(rejected, true);
  }
});

const chain = fixtures.certificates;
class ChainVerifier extends SignedDataVerifier {
  check(leaf: string, intermediate: string, date = new Date('2026-10-11')) {
    // Apple's Node typings use `crypto`; Deno exposes the same module as `node:crypto`.
    type Certificate = typeof this.rootCertificates[number];
    return this.verifyCertificateChain(this.rootCertificates,
      new crypto.X509Certificate(Buffer.from(leaf, 'base64')) as unknown as Certificate,
      new crypto.X509Certificate(Buffer.from(intermediate, 'base64')) as unknown as Certificate, date);
  }
}
const verifier = (root = chain.ROOT_CA) => new ChainVerifier([Buffer.from(root, 'base64')],
  false, Environment.SANDBOX, 'com.example'); // Offline fixture tests only; production uses online checks.

Deno.test('Apple library validates its full fixture certificate chain on the compatible runtime', async () => {
  await verifier().check(chain.LEAF_CERT, chain.INTERMEDIATE_CA);
  await verifier(chain.REAL_APPLE_ROOT).check(chain.REAL_APPLE_SIGNING_CERTIFICATE, chain.REAL_APPLE_INTERMEDIATE);
  const leaf = new CompatibleCertificate(Buffer.from(chain.REAL_APPLE_SIGNING_CERTIFICATE, 'base64'));
  equal(leaf.infoAccess?.includes('OCSP - URI:http://ocsp.apple.com/ocsp03-wwdrg602') ?? false, true);
});

Deno.test('Apple verifier tries the matching root after a different-algorithm root', async () => {
  const bothRoots = new ChainVerifier(roots.map(root => Buffer.from(root.der_base64, 'base64')),
    false, Environment.SANDBOX, 'com.example');
  await bothRoots.check(chain.REAL_APPLE_SIGNING_CERTIFICATE, chain.REAL_APPLE_INTERMEDIATE);
});

Deno.test('Apple trust roots, signing purposes and certificate expiry remain enforced', async () => {
  const cases = [
    () => verifier(chain.REAL_APPLE_ROOT).check(chain.LEAF_CERT, chain.INTERMEDIATE_CA),
    () => verifier().check(chain.LEAF_CERT_INVALID_OID, chain.INTERMEDIATE_CA),
    () => verifier().check(chain.LEAF_CERT_FOR_INTERMEDIATE_CA_INVALID_OID, chain.INTERMEDIATE_CA_INVALID_OID),
    () => verifier().check(chain.LEAF_CERT, chain.INTERMEDIATE_CA, new Date('2040-01-01')),
  ];
  for (const run of cases) {
    let rejected = false;
    try { await run(); } catch { rejected = true; }
    equal(rejected, true);
  }
});
