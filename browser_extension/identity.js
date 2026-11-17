// Abyss's entry point. The shared background implementation defaults to
// BaoCode, so its source and the ordinary BaoCode package stay unchanged.
globalThis.ABYSS_BROWSER_IDENTITY = Object.freeze({
  name: 'Abyss',
  host: 'dev.abyss.browser',
  group: 'Abyss',
  help: 'https://github.com/AlbertSkyer/Abyss/blob/edition/abyss/docs/abyss-browser-extension.md',
});

importScripts('background.js');
