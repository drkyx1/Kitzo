'use strict';
/* =====================================================================
   pulso.js — Web Worker que avisa o servidor "o painel ainda está aberto".

   Roda num Worker porque o navegador congela/atrasa os timers de abas em
   segundo plano, mas não os de Workers. Se o servidor parar de receber
   estes pulsos (navegador fechado), ele se encerra sozinho.
   Mensagens para a página: { status } (200 = ok, 401 = token velho, 0 = servidor fora)
   ===================================================================== */
const INTERVALO_MS = 8000;
let token = null;

async function pulsar() {
  if (!token) return;
  let status = 0;
  try {
    const r = await fetch('/api/acao/sistema.pulso', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Token': token },
      body: '{}',
      cache: 'no-store',
    });
    status = r.status;
  } catch {
    status = 0;
  }
  self.postMessage({ status });
}

self.onmessage = (e) => {
  token = e.data && e.data.token;
  pulsar();
};

setInterval(pulsar, INTERVALO_MS);
