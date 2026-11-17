#!/usr/bin/env node
// Build an independent Abyss browser extension without changing BaoCode's
// source manifest, icons, signing files, or ordinary packaging output.
//
//   node tool/build_abyss_extension.mjs --out <NEW directory>
//
// The output directory must not already exist. It contains an unpacked/
// extension and Abyss-browser-<version>.zip. Only the public key in
// browser_extension/abyss.json is read; this command never reads a private
// key and has no first-upload mode.

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = join(root, 'browser_extension');
const sizes = [16, 32, 48, 128];

/** Chrome's unpacked-extension id: the first 128 bits of the public key's
 * SHA-256, with each hexadecimal nibble represented by a letter a-p. */
export function extensionId(publicKey) {
  const key = Buffer.from(publicKey, 'base64');
  if (key.length === 0 || key.toString('base64') !== publicKey) {
    throw new Error('abyss.json: publicKey is not canonical base64');
  }
  return [...createHash('sha256').update(key).digest().subarray(0, 16)]
    .map((byte) => String.fromCharCode(97 + (byte >> 4)) + String.fromCharCode(97 + (byte & 15)))
    .join('');
}

function powerShell(script, source, destination) {
  // Node's Windows quoting adds outer quotes to -Command arguments. Windows
  // PowerShell can then treat supplied paths as commands instead of $args.
  // Encode the script and pass paths as opaque environment values instead.
  const encoded = Buffer.from(script, 'utf16le').toString('base64');
  command('powershell.exe', [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-EncodedCommand', encoded,
  ], {
    env: {
      ...process.env,
      ABYSS_EXTENSION_UNPACKED: source,
      ABYSS_EXTENSION_ZIP: destination,
    },
  });
}

function command(command, args, options = {}) {
  // Never use a shell: output paths are passed as data, not command text.
  const result = spawnSync(command, args, {
    cwd: root,
    windowsHide: true,
    ...options,
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} exited with status ${result.status ?? 'unknown'}`);
  }
}

function makeIcons(out) {
  // Pillow is already used by the repository's asset tools. Do not execute
  // Python from the generated directory or add an npm image dependency.
  const script = [
    'import sys',
    'from pathlib import Path',
    'from PIL import Image',
    'source, out = Path(sys.argv[1]), Path(sys.argv[2])',
    'image = Image.open(source).convert("RGBA")',
    'for size in (16, 32, 48):',
    '    image.resize((size, size), Image.Resampling.LANCZOS).save(out / f"icon-{size}.png", optimize=True)',
    'framed = Image.new("RGBA", (128, 128), (0, 0, 0, 0))',
    'icon = image.resize((96, 96), Image.Resampling.LANCZOS)',
    'framed.alpha_composite(icon, (16, 16))',
    'framed.save(out / "icon-128.png", optimize=True)',
  ].join('\n');
  command('py', [
    '-3',
    '-I',
    '-c',
    script,
    join(root, 'assets', 'branding', 'app_icon.png'),
    join(out, 'icons'),
  ]);
}

function makeZip(unpacked, zip) {
  // Archive unpacked's contents, not its parent folder. The temporary archive
  // makes the final rename atomic and leaves no partial file under the final
  // name if compression fails.
  const temporary = `${zip}.tmp.zip`;
  const script = [
    '$ErrorActionPreference = "Stop"',
    'Add-Type -AssemblyName System.IO.Compression',
    'Add-Type -AssemblyName System.IO.Compression.FileSystem',
    '$archive = [IO.Compression.ZipFile]::Open($env:ABYSS_EXTENSION_ZIP, [IO.Compression.ZipArchiveMode]::Create)',
    'try { Get-ChildItem -LiteralPath $env:ABYSS_EXTENSION_UNPACKED -File -Recurse | Sort-Object FullName | ForEach-Object { $name = $_.FullName.Substring($env:ABYSS_EXTENSION_UNPACKED.Length + 1).Replace([char]92, [char]47); $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal); $entry.LastWriteTime = [DateTimeOffset]::new(2020, 1, 1, 0, 0, 0, [TimeSpan]::Zero); $input = [IO.File]::OpenRead($_.FullName); $output = $entry.Open(); try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() } } } finally { $archive.Dispose() }',
  ].join('; ');
  try {
    powerShell(script, resolve(unpacked), resolve(temporary));
    renameSync(temporary, zip);
  } finally {
    rmSync(temporary, { force: true });
  }
}

export function main(args) {
  if (args.length !== 2 || args[0] !== '--out' || !args[1]) {
    throw new Error('Usage: node tool/build_abyss_extension.mjs --out <NEW directory>');
  }
  const out = resolve(args[1]);
  if (existsSync(out) || lstatSync(out, { throwIfNoEntry: false }) !== undefined) {
    throw new Error(`Refusing to use an existing output path: ${out}`);
  }
  const config = JSON.parse(readFileSync(join(source, 'abyss.json'), 'utf8'));
  const manifest = JSON.parse(readFileSync(join(source, 'manifest.json'), 'utf8'));
  if (config.name !== 'Abyss' || config.group !== 'Abyss') {
    throw new Error('abyss.json: expected the Abyss product and tab group');
  }
  if (config.host !== 'dev.abyss.browser' || config.version !== '0.1.0') {
    throw new Error('abyss.json: unexpected host or version');
  }
  if (extensionId(config.publicKey) !== config.extensionId) {
    throw new Error('abyss.json: publicKey does not derive extensionId');
  }

  mkdirSync(out, { recursive: false });
  const unpacked = join(out, 'unpacked');
  mkdirSync(join(unpacked, 'icons'), { recursive: true });
  cpSync(join(source, '_locales'), join(unpacked, '_locales'), { recursive: true });
  for (const file of ['background.js', 'identity.js']) {
    cpSync(join(source, file), join(unpacked, file));
  }
  makeIcons(unpacked);
  cpSync(join(root, 'LICENSE'), join(unpacked, 'LICENSE'));
  writeFileSync(join(unpacked, 'NOTICE.txt'), 'Abyss browser extension: independent modified edition of BaoCode.\nGPL-3.0; retain LICENSE and copyright notices.\nCorresponding source: https://github.com/AlbertSkyer/Abyss/tree/edition/abyss/browser_extension\nUpstream: https://github.com/baocode-dev/baocode\nNo private signing key is included.\n');

  // Explicit changes, not a hand-maintained second manifest. The inherited
  // permission and host-permission lists must remain exactly those of the
  // shared source.
  // A constrained, single-assignment parser for the literal identity file,
  // rather than executing a source script as part of packaging.
  const identitySource = readFileSync(join(source, 'identity.js'), 'utf8');
  const fields = {};
  for (const match of identitySource.matchAll(/^  (name|host|group|help): '([^']+)',$/gm)) {
    fields[match[1]] = match[2];
  }
  if (!/globalThis\.ABYSS_BROWSER_IDENTITY = Object\.freeze\(\{/.test(identitySource) ||
      Object.keys(fields).length !== 4) {
    throw new Error('identity.js: expected a literal Abyss identity');
  }
  if (fields.name !== config.name || fields.host !== config.host || fields.group !== config.group ||
      fields.help !== 'https://github.com/AlbertSkyer/Abyss/blob/edition/abyss/docs/abyss-browser-extension.md') {
    throw new Error('identity.js does not match abyss.json and its GitHub help page');
  }
  for (const locale of ['en', 'zh_CN']) {
    const path = join(unpacked, '_locales', locale, 'messages.json');
    const messages = JSON.parse(readFileSync(path, 'utf8'));
    messages.name.message = config.name;
    if (locale === 'en') {
      messages.description.message = "Lets Abyss's agents use the tabs you share with them: open, read, click and type, as you watch.";
    } else {
      messages.description.message = '让 Abyss 的 agent 使用你共享给它的标签页：打开、阅读、点击和输入，全程在你眼前。';
    }
    writeFileSync(path, `${JSON.stringify(messages, null, 2)}\n`);
  }
  Object.assign(manifest, {
    version: config.version,
    key: config.publicKey,
  });
  manifest.background.service_worker = 'identity.js';
  manifest.action.default_title = config.name;
  for (const paths of [manifest.icons, manifest.action.default_icon]) {
    for (const [size, path] of Object.entries(paths)) {
      const expected = `icons/icon-${size}.png`;
      if (path !== expected || !sizes.includes(Number(size))) {
        throw new Error(`manifest.json: unexpected icon ${path}`);
      }
      if (!existsSync(join(unpacked, path))) throw new Error(`Missing ${path}`);
    }
  }
  if (!manifest.background.service_worker || !existsSync(join(unpacked, manifest.background.service_worker))) {
    throw new Error('manifest.json: missing background service worker');
  }
  writeFileSync(join(unpacked, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  const zip = join(out, `Abyss-browser-${config.version}.zip`);
  makeZip(unpacked, zip);
  console.log(unpacked);
  console.log(zip);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error?.message ?? error);
    process.exitCode = 1;
  }
}
