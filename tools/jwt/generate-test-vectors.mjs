import crypto from 'node:crypto';
const rsa = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const ec = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
const rsaJwk = { ...rsa.publicKey.export({ format: 'jwk' }), kid: 'rsa-1', alg: 'RS256', use: 'sig' };
const ecJwk = { ...ec.publicKey.export({ format: 'jwk' }), kid: 'ec-1', alg: 'ES256' };
const jwks = JSON.stringify({ keys: [rsaJwk, ecJwk, { kty: 'oct', k: 'AAAA', kid: 'hmac' }] });
const b64 = (b) => Buffer.from(b).toString('base64url');
const NOW = 1900000000;
function sign(header, claims, key = 'rsa') {
  const input = `${b64(JSON.stringify(header))}.${b64(JSON.stringify(claims))}`;
  let sig;
  if (header.alg === 'RS256') sig = crypto.sign('sha256', Buffer.from(input), rsa.privateKey);
  else if (header.alg === 'ES256') sig = crypto.sign('sha256', Buffer.from(input), { key: ec.privateKey, dsaEncoding: 'ieee-p1363' });
  else sig = Buffer.alloc(0);
  return `${input}.${b64(sig)}`;
}
const base = { sub: 'player-42', iss: 'Example', aud: ['app', 'other'], exp: NOW + 600, iat: NOW - 10, extra: { platform: 'web' } };
const v = {
  rsValid: sign({ alg: 'RS256', kid: 'rsa-1', typ: 'JWT' }, base),
  esValid: sign({ alg: 'ES256', kid: 'ec-1' }, base),
  noKid: sign({ alg: 'RS256' }, base),
  expired: sign({ alg: 'RS256', kid: 'rsa-1' }, { ...base, exp: NOW }),
  future: sign({ alg: 'RS256', kid: 'rsa-1' }, { ...base, nbf: NOW + 60 }),
  wrongIss: sign({ alg: 'RS256', kid: 'rsa-1' }, { ...base, iss: 'EVIL' }),
  noSub: sign({ alg: 'ES256', kid: 'ec-1' }, { ...base, sub: undefined }),
  unknownKid: sign({ alg: 'RS256', kid: 'rsa-2' }, base),
  none: sign({ alg: 'none', kid: 'rsa-1' }, base),
  algSwap: sign({ alg: 'RS256', kid: 'ec-1' }, base),
};
const [h, p, s] = v.rsValid.split('.');
v.tampered = `${h}.${b64(JSON.stringify({ ...base, sub: 'admin' }))}.${s}`;
const es = v.esValid.split('.');
const sig = Buffer.from(es[2], 'base64url'); sig[5] ^= 1;
v.esTampered = `${es[0]}.${es[1]}.${b64(sig)}`;
console.log(JSON.stringify({ NOW, jwks, ...v }, null, 1));
