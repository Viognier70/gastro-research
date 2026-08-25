// ORDER 167 — minimal service worker för Chrome/Chromium PWA-installability.
//
// KRAV: Chrome/Edge/Android Chromium kräver att sidan har en registrerad SW
// med minst en `fetch`-event-lyssnare för att `beforeinstallprompt` ska fyra.
// Den här SW:n gör INGEN caching — pass-through-fetch räcker för install-
// kriteriet. Om vi senare vill ha äkta offline-support kommer det som egen
// ORDER (då krävs versionerade caches, invalideringsstrategi, precache-
// manifest — allt hör ihop och ska tänkas i sammanhang).
//
// HISTORIK: föregångaren var ett självdestruerings-stubb som — vid activate —
// nollade alla caches och avregistrerade sig själv. Behövdes när en gammal
// buggig SW skulle städas bort. Den skörden är gjord; nu vill vi ha en levande
// SW som möjliggör installation, inte en som fortsätter dammsuga.

self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()))

// Pass-through fetch. Låter browserns default hantera requesten — samma
// nätverksbeteende som utan SW. Nödvändigt eftersom Chrome-install-kriteriet
// specifikt kräver att fetch-lyssnare finns, även om den inte gör något.
self.addEventListener('fetch', () => {})
