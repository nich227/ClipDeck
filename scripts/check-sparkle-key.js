// Checks that SPARKLE_ED_PRIVATE_KEY is the private half of the key the app trusts. An installed
// copy refuses an update signed with any other key, so the release stops here before the build
// starts.
//
// The key arrives as a raw Ed25519 seed encoded in base64, the same form sign-release.js reads.
// Only public keys are printed.
const crypto = require('crypto');
const fs = require('fs');

const plist = process.argv[2] || 'ClipDeck/Info.plist';
if (!process.env.SPARKLE_ED_PRIVATE_KEY) {
  console.error('usage: SPARKLE_ED_PRIVATE_KEY=<b64 seed> node check-sparkle-key.js [Info.plist]');
  process.exit(1);
}

const seed = Buffer.from(process.env.SPARKLE_ED_PRIVATE_KEY.trim(), 'base64');
if (seed.length !== 32) {
  console.error('the key must be the base64 of a 32 byte ed25519 seed');
  process.exit(1);
}

const trusted = fs.readFileSync(plist, 'utf8').match(/<key>SUPublicEDKey<\/key>\s*<string>([^<]+)<\/string>/);
if (!trusted) {
  console.error(`${plist} has no SUPublicEDKey`);
  process.exit(1);
}

// PKCS#8 wrapper for a raw Ed25519 seed
const pkcs8 = Buffer.concat([
  Buffer.from('302e020100300506032b657004220420', 'hex'),
  seed,
]);
const key = crypto.createPrivateKey({key: pkcs8, format: 'der', type: 'pkcs8'});
// The last 32 bytes of the SPKI encoding are the raw public key.
const derived = crypto.createPublicKey(key).export({format: 'der', type: 'spki'}).subarray(-32).toString('base64');

if (derived !== trusted[1].trim()) {
  console.error(`SPARKLE_ED_PRIVATE_KEY belongs to the public key ${derived}, but the app trusts ${trusted[1].trim()}`);
  process.exit(1);
}
console.log(`the Sparkle key matches SUPublicEDKey (${derived})`);
