import fs from 'fs';
import path from 'path';

const BUNDLE_DIR = path.resolve('node_modules/@zama-fhe/relayer-sdk/bundle');
const TARGET_DIR = process.cwd();
const FILES = ['tfhe_bg.wasm', 'kms_lib_bg.wasm', 'relayer-sdk-js.js', 'workerHelpers.js'];

function copyFile(filename) {
  const source = path.join(BUNDLE_DIR, filename);
  const target = path.join(TARGET_DIR, filename);

  if (!fs.existsSync(source)) {
    console.warn(`⚠️  Missing ${filename} in ${BUNDLE_DIR}`);
    return;
  }

  fs.copyFileSync(source, target);
  console.log(`✅ Copied ${filename} -> ${target}`);
}

function main() {
  if (!fs.existsSync(BUNDLE_DIR)) {
    console.warn('⚠️  relayer SDK bundle not found. Run `npm install` first.');
    return;
  }

  FILES.forEach(copyFile);
}

main();
