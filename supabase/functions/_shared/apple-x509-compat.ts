import crypto, { X509Certificate as NativeCertificate, type KeyObject } from 'node:crypto';
import { Buffer } from 'node:buffer';
// Apple's server library already uses this certificate parser. Keep its version pinned.
import { X509, ASN1HEX } from 'npm:jsrsasign@11.1.5';
import roots from './apple-root-certificates.json' with { type: 'json' };

/** Equivalent certificate-signature check for older Supabase Edge runtimes.
 * Chain trust, Apple certificate purposes, dates, OCSP and JWS checks remain in
 * Apple's SignedDataVerifier. This never treats an unsupported check as success.
 */
export function verifyCertificateSignature(certificate: NativeCertificate, key: KeyObject): boolean {
  if (key.type !== 'public') throw new TypeError('Certificate verification requires a public key');
  try {
    const parsed = new X509();
    parsed.readCertHex(certificate.raw.toString('hex'));
    const algorithm = parsed.getSignatureAlgorithmField();
    if (algorithm !== parsed.getSignatureAlgorithmName()) return false;
    const algorithms: Record<string, { digest: string; keyType: string }> = {
      SHA1withRSA: { digest: 'sha1', keyType: 'rsa' },
      SHA256withRSA: { digest: 'sha256', keyType: 'rsa' },
      SHA384withRSA: { digest: 'sha384', keyType: 'rsa' },
      SHA512withRSA: { digest: 'sha512', keyType: 'rsa' },
      SHA256withECDSA: { digest: 'sha256', keyType: 'ec' },
      SHA384withECDSA: { digest: 'sha384', keyType: 'ec' },
      SHA512withECDSA: { digest: 'sha512', keyType: 'ec' },
    };
    const selected = algorithms[algorithm];
    if (!selected || key.asymmetricKeyType !== selected.keyType) return false;
    // Keep the parser for DER extraction, but use native cryptography to avoid
    // pure-JS EC verification overhead in the CPU-limited Edge runtime.
    const tbs = ASN1HEX.getTLVbyList(parsed.hex, 0, [0], '30');
    if (!tbs) return false;
    return crypto.verify(selected.digest, Buffer.from(tbs, 'hex'), key,
      Buffer.from(parsed.getSignatureValueHex(), 'hex'));
  } catch {
    // Node returns false when a candidate issuer has an incompatible key. The
    // parser can throw instead; reject that candidate so Apple can try the next
    // trusted root. An error must never count as a verified signature.
    return false;
  }
}

function missing(error: unknown, method: string): boolean {
  const e = error as { code?: unknown; message?: unknown };
  return e?.code === 'ERR_NOT_IMPLEMENTED' &&
    e.message === `Not implemented: crypto.X509Certificate.prototype.${method}`;
}

// Older Edge runtimes also lack raw, toString and infoAccess. Retain the exact
// certificate bytes passed to the native parser, which still validates the input
// and provides issuer, subject, dates, CA status and its native public key.
export class CompatibleCertificate extends NativeCertificate {
  private readonly der: Buffer;
  constructor(input: ConstructorParameters<typeof NativeCertificate>[0]) {
    super(input);
    const bytes = typeof input === 'string' ? Buffer.from(input) :
      Buffer.from(input.buffer, input.byteOffset, input.byteLength);
    if (bytes.toString('utf8').includes('-----BEGIN CERTIFICATE-----')) {
      const parsed = new X509();
      parsed.readCertPEM(bytes.toString('utf8'));
      this.der = Buffer.from(parsed.hex, 'hex');
    } else this.der = Buffer.from(bytes);
    Object.defineProperties(this, {
      raw: { get: () => Buffer.from(this.der) },
      infoAccess: { get: () => this.readInfoAccess() },
    });
  }
  override toString(): string {
    return `-----BEGIN CERTIFICATE-----\n${this.der.toString('base64').match(/.{1,64}/g)!.join('\n')}\n-----END CERTIFICATE-----\n`;
  }
  private readInfoAccess(): string | undefined {
    const parsed = new X509();
    parsed.readCertHex(this.der.toString('hex'));
    const aia = parsed.getExtAIAInfo();
    if (!aia) return undefined;
    const lines = [
      ...(aia.ocsp ?? []).map((url: string) => `OCSP - URI:${url}`),
      ...(aia.caissuer ?? []).map((url: string) => `CA Issuers - URI:${url}`),
    ];
    return lines.length ? lines.join('\n') : undefined;
  }
  override verify(key: KeyObject): boolean {
    try { return super.verify(key); }
    catch (error) {
      if (!missing(error, 'verify')) throw error;
      return verifyCertificateSignature(this, key);
    }
  }
}

// Apple's CommonJS library reads this module's X509Certificate constructor.
// Keep modern runtimes native; adapt only the explicitly unsupported runtime.
try { void new NativeCertificate(Buffer.from(roots[0].der_base64, 'base64')).raw; }
catch (error) {
  if (!missing(error, 'raw')) throw error;
  crypto.X509Certificate = CompatibleCertificate;
}

// Deno's older Node layer names Apple's NIST curves p256/p384. Node's JWT
// verifier expects OpenSSL names. Normalize the metadata, preserving its strict
// algorithm/curve validation (never use allowInvalidAsymmetricKeyTypes).
const aliases: Record<string, string> = { p256: 'prime256v1', p384: 'secp384r1' };
const sampleKey = new crypto.X509Certificate(Buffer.from(roots[1].der_base64, 'base64')).publicKey;
if (aliases[sampleKey.asymmetricKeyDetails?.namedCurve ?? '']) {
  let prototype = Object.getPrototypeOf(sampleKey);
  while (prototype) {
    const descriptor = Object.getOwnPropertyDescriptor(prototype, 'asymmetricKeyDetails');
    if (descriptor?.get) {
      const original = descriptor.get;
      Object.defineProperty(prototype, 'asymmetricKeyDetails', { ...descriptor, get() {
        const details = original.call(this);
        const namedCurve = aliases[details?.namedCurve];
        return namedCurve ? { ...details, namedCurve } : details;
      } });
      break;
    }
    prototype = Object.getPrototypeOf(prototype);
  }
}
