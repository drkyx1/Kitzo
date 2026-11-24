'use strict';
/* tema.js — aplica as preferências visuais ANTES do painel desenhar (evita "piscar").
   As preferências ficam só neste navegador (localStorage). */
const PrefsPadrao = { tema: 'escuro', destaque: '#4aa8ff', densidade: 'confortavel', fonte: 14, raio: 12, recolhida: false, animacoes: true, fundo: 'liso' };
const PrefsChave = 'kitzo.prefs';

function lerPrefs() {
  try { return { ...PrefsPadrao, ...JSON.parse(localStorage.getItem(PrefsChave) || '{}') }; } catch { return { ...PrefsPadrao }; }
}
function aplicarPrefs(p = lerPrefs()) {
  const r = document.documentElement;
  const claro = p.tema === 'claro' || (p.tema === 'auto' && matchMedia('(prefers-color-scheme: light)').matches);
  r.dataset.tema = claro ? 'claro' : 'escuro';
  r.dataset.densidade = p.densidade;
  r.dataset.fundo = p.fundo;
  r.classList.toggle('sem-animacao', !p.animacoes);
  r.classList.toggle('lateral-recolhida', !!p.recolhida);
  if (/^#[0-9a-f]{6}$/i.test(p.destaque)) r.style.setProperty('--destaque', p.destaque);
  r.style.setProperty('--raio', `${Math.min(24, Math.max(0, Number(p.raio) || 0))}px`);
  r.style.fontSize = `${Math.min(18, Math.max(12, Number(p.fonte) || 14))}px`;
}
function salvarPrefs(parcial) {
  const p = { ...lerPrefs(), ...parcial };
  try { localStorage.setItem(PrefsChave, JSON.stringify(p)); } catch { /* sem armazenamento */ }
  aplicarPrefs(p);
  return p;
}
aplicarPrefs();
matchMedia('(prefers-color-scheme: light)').addEventListener('change', () => aplicarPrefs());
