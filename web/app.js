'use strict';
/* =====================================================================
   app.js — Lógica do painel do Kitzo (JavaScript puro)

   - Lê o token da URL (?t=...) uma única vez, guarda na sessionStorage
     e remove da barra de endereço.
   - Toda chamada à API é POST /api/acao/<nome> com o cabeçalho X-Token.
   - Cada página do menu é uma função "render" registrada em Paginas.
   - Ações que alteram o sistema passam por confirmar() antes da chamada.
   ===================================================================== */

// ---------------------------------------------------------------------
// Utilitários
// ---------------------------------------------------------------------
const $ = (seletor, raiz = document) => raiz.querySelector(seletor);

/** Escapa texto vindo do servidor antes de inserir em HTML (evita XSS). */
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => (
  { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
));

/** Número no formato brasileiro (vírgula decimal). */
const fmt = (n, casas = 1) => (n === null || n === undefined || Number.isNaN(Number(n)))
  ? '—'
  : Number(n).toLocaleString('pt-BR', { maximumFractionDigits: casas });

function fmtData(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? esc(iso) : d.toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' });
}

function fmtDuracao(horas) {
  if (horas === null || horas === undefined) return '—';
  const totalMin = Math.round(horas * 60);
  const d = Math.floor(totalMin / 1440);
  const h = Math.floor((totalMin % 1440) / 60);
  const m = totalMin % 60;
  if (d > 0) return `${d} d ${h} h`;
  if (h > 0) return `${h} h ${m} min`;
  return `${m} min`;
}

/** Nível visual a partir de um percentual de uso. */
const nivelPorUso = (p, atencao = 80, critico = 90) => (p >= critico ? 'critico' : p >= atencao ? 'atencao' : 'ok');

const selo = (texto, nivel) => `<span class="selo selo-${nivel}">${esc(texto)}</span>`;

// ---------------------------------------------------------------------
// Ícones (SVG em linha, sem dependências externas)
// ---------------------------------------------------------------------
const Icones = {
  bigorna: '<path d="M3 8h13a5 5 0 0 0 5-5"/><path d="M3 8c0 3 2 4 5 4h6v3"/><path d="M8 21h10"/><path d="M10 15h6l2 6H8z"/>',
  casa: '<path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/><path d="M10 20v-6h4v6"/>',
  pulso: '<path d="M3 12h4l3-8 4 16 3-8h4"/>',
  chave: '<path d="M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.5 2.5-2.4-.6-.6-2.4z"/>',
  lixeira: '<path d="M4 7h16"/><path d="M9 7V4h6v3"/><path d="M6 7l1 13h10l1-13"/><path d="M10 11v6M14 11v6"/>',
  grade: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  globo: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3a14 14 0 0 1 0 18a14 14 0 0 1 0-18"/>',
  escudo: '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/>',
  documento: '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4"/><path d="M9 13h6M9 17h6"/>',
  cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
  memoria: '<rect x="3" y="7" width="18" height="10" rx="1.5"/><path d="M7 17v3M12 17v3M17 17v3M7 10v4M12 10v4M17 10v4"/>',
  disco: '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
  janela: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M7 6.5h.01M10 6.5h.01"/>',
  reiniciar: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
  calendario: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
  energia: '<path d="M12 3v9"/><path d="M6.3 6.3a8 8 0 1 0 11.4 0"/>',
  menu: '<path d="M4 6h16M4 12h16M4 18h16"/>',
  relogio: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
};
const icone = (nome) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${Icones[nome] || ''}</svg>`;

/** Preenche elementos estáticos do HTML que têm data-icone="nome". */
function montarIcones(raiz = document) {
  raiz.querySelectorAll('[data-icone]').forEach((el) => {
    el.insertAdjacentHTML('afterbegin', icone(el.dataset.icone));
    el.removeAttribute('data-icone');
  });
}

// ---------------------------------------------------------------------
// Progresso global, avisos (toasts) e confirmação
// ---------------------------------------------------------------------
const Progresso = {
  ativos: 0,
  iniciar() { this.ativos += 1; document.body.classList.add('ocupado'); },
  finalizar() {
    this.ativos = Math.max(0, this.ativos - 1);
    if (this.ativos === 0) document.body.classList.remove('ocupado');
  },
};

/** tipo: 'info' | 'sucesso' | 'erro' | 'atencao' */
function avisar(texto, tipo = 'info', ms = 4500) {
  const div = document.createElement('div');
  div.className = `aviso aviso-${tipo}`;
  div.textContent = texto;
  $('#avisos').append(div);
  setTimeout(() => {
    div.classList.add('saindo');
    setTimeout(() => div.remove(), 300);
  }, ms);
}

/** Abre a janela de confirmação. Resolve true se o técnico confirmar. */
function confirmar({ titulo = 'Confirmar ação', texto = '', botao = 'Confirmar', perigo = true } = {}) {
  const dlg = $('#dialogo');
  $('#dialogoTitulo').textContent = titulo;
  $('#dialogoTexto').textContent = texto;
  const ok = $('#dialogoOk');
  ok.textContent = botao;
  ok.className = `botao ${perigo ? 'botao-perigo' : 'botao-primario'}`;
  dlg.returnValue = '';
  dlg.showModal();
  return new Promise((resolver) => {
    dlg.addEventListener('close', () => resolver(dlg.returnValue === 'ok'), { once: true });
  });
}

// ---------------------------------------------------------------------
// Comunicação com o servidor
// ---------------------------------------------------------------------
const Estado = { token: null, sessao: null, pulso: null, encerrado: false };

/** Pega o token da URL (primeira abertura) ou da sessão (recarregamentos). */
function obterToken() {
  const url = new URL(window.location.href);
  const t = url.searchParams.get('t');
  if (t && /^[0-9a-f]{64}$/.test(t)) {
    sessionStorage.setItem('token', t);
    url.searchParams.delete('t');
    history.replaceState(null, '', url.pathname + url.hash);
  }
  return sessionStorage.getItem('token');
}

/**
 * Executa uma ação permitida no servidor.
 * @param {string} acao       nome registrado, ex.: 'info.resumo'
 * @param {object} params     parâmetros (validados no servidor)
 * @param {object} opcoes     { confirmado: true } para ações que alteram o sistema;
 *                            { silencioso: true } não mostra a barra de progresso (polling)
 */
async function api(acao, params = {}, { confirmado = false, silencioso = false } = {}) {
  if (!silencioso) Progresso.iniciar();
  try {
    let resposta;
    try {
      resposta = await fetch(`/api/acao/${encodeURIComponent(acao)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Token': Estado.token || '' },
        body: JSON.stringify({ params, confirmado }),
      });
    } catch {
      throw Object.assign(new Error('O servidor não responde. A janela do Iniciar.bat ainda está aberta?'), { status: 0 });
    }
    let json = null;
    try { json = await resposta.json(); } catch { /* resposta sem JSON */ }
    if (!resposta.ok || !json || !json.ok) {
      const msg = (json && json.erro) || `Erro HTTP ${resposta.status}`;
      throw Object.assign(new Error(msg), { status: resposta.status });
    }
    if (confirmado) atualizarHistorico(); // ações confirmadas entram no histórico da máquina
    return json.dados;
  } finally {
    if (!silencioso) Progresso.finalizar();
  }
}

// ---------------------------------------------------------------------
// Navegação entre páginas
// ---------------------------------------------------------------------
const Paginas = {
  inicio: { titulo: 'Início', render: paginaInicio },
  diagnostico: { titulo: 'Diagnóstico', render: paginaDiagnostico },
  reparo: { titulo: 'Reparo', render: paginaReparo },
  limpeza: { titulo: 'Limpeza', render: paginaLimpeza },
  programas: { titulo: 'Programas', render: paginaProgramas },
  rede: { titulo: 'Rede', render: paginaRede },
  seguranca: { titulo: 'Segurança', render: paginaSeguranca },
  relatorio: { titulo: 'Relatório', render: paginaRelatorio },
  historico: { titulo: 'Histórico', render: paginaHistorico },
};

let geracaoRender = 0; // evita que uma página antiga sobrescreva a atual

function botaoTopo(texto, nomeIcone, aoClicar) {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = 'botao botao-fantasma';
  b.innerHTML = `${icone(nomeIcone)} ${esc(texto)}`;
  b.addEventListener('click', aoClicar);
  $('#topoAcoes').append(b);
  return b;
}

function caixaErro(erro) {
  return `<div class="erro-caixa"><h2>Não foi possível carregar</h2><p>${esc(erro.message)}</p></div>`;
}

async function navegar() {
  const id = window.location.hash.slice(1) || 'inicio';
  const pagina = Paginas[id] || Paginas.inicio;
  const idReal = Paginas[id] ? id : 'inicio';

  document.querySelectorAll('.menu a').forEach((a) => a.classList.toggle('ativo', a.dataset.pagina === idReal));
  $('#tituloPagina').textContent = pagina.titulo;
  document.title = `${pagina.titulo} · Kitzo`;
  $('#topoAcoes').innerHTML = '';
  $('#lateral').classList.remove('aberto');

  const el = $('#conteudo');
  const minhaGeracao = ++geracaoRender;
  const ativa = () => minhaGeracao === geracaoRender;

  try {
    const promessa = pagina.render(el, ativa); // a parte síncrona já montou o HTML
    preencherUltimas(el);
    await promessa;
  } catch (e) {
    if (ativa()) el.innerHTML = caixaErro(e);
  }
}

// ---------------------------------------------------------------------
// Página: Início
// ---------------------------------------------------------------------
function esqueletoInicio() {
  return `<p class="carregando-texto">Coletando informações do computador…</p>
    <div class="esqueleto esqueleto-nota"></div>
    <div class="grade-cards">${'<div class="esqueleto esqueleto-card"></div>'.repeat(6)}</div>`;
}

function card({ titulo, nomeIcone, valor, sub = '', barra = null, nivel = 'ok', extra = '' }) {
  const largura = barra === null || barra === undefined ? null : Math.min(100, Math.max(0, Number(barra)));
  return `<article class="card card-${nivel}">
    <header class="card-topo"><span class="card-icone">${icone(nomeIcone)}</span><h3>${esc(titulo)}</h3></header>
    <div class="card-valor">${valor}</div>
    ${sub ? `<div class="card-sub">${sub}</div>` : ''}
    ${largura !== null ? `<div class="barra"><div class="barra-preench nivel-${nivel}" data-largura="${largura}"></div></div>` : ''}
    ${extra}
  </article>`;
}

function blocoNota(nota) {
  const C = 2 * Math.PI * 52; // circunferência do anel
  const v = Number(nota.valor) || 0;
  const nivel = v >= 85 ? 'ok' : v >= 70 ? 'bom' : v >= 50 ? 'atencao' : 'critico';
  const alertas = nota.alertas || [];
  const itens = alertas.length
    ? alertas.map((a) => `<li class="${esc(a.nivel)}"><span>${esc(a.texto)}</span><span class="pontos">−${esc(a.pontos)} pts</span></li>`).join('')
    : '<li class="tudo-ok">Nenhum problema encontrado nesta verificação.</li>';
  return `
    <div class="nota nota-${nivel}">
      <svg class="nota-anel" viewBox="0 0 120 120" aria-hidden="true">
        <circle class="nota-trilho" cx="60" cy="60" r="52"/>
        <circle class="nota-progresso" cx="60" cy="60" r="52" transform="rotate(-90 60 60)"
          stroke-dasharray="${C.toFixed(1)}" stroke-dashoffset="${C.toFixed(1)}"
          data-alvo="${(C * (1 - v / 100)).toFixed(1)}"/>
      </svg>
      <div class="nota-centro"><strong>${v}</strong><span>de 100</span></div>
    </div>
    <div class="saude-texto">
      <h2>Saúde do PC: ${esc(nota.classificacao)}</h2>
      <p>${alertas.length ? 'Itens que reduziram a nota:' : 'Tudo certo por aqui.'}</p>
      <ul class="alertas">${itens}</ul>
    </div>`;
}

function cardCpu(c) {
  if (!c) return card({ titulo: 'Processador', nomeIcone: 'cpu', valor: '—', sub: 'Não foi possível ler o processador.', nivel: 'atencao' });
  const nivel = c.usoPercentual === null ? 'ok' : nivelPorUso(c.usoPercentual);
  return card({
    titulo: 'Processador', nomeIcone: 'cpu', nivel, barra: c.usoPercentual,
    valor: `${fmt(c.usoPercentual, 0)}% <small>em uso</small>`,
    sub: `${esc(c.nome)}<br>${esc(c.nucleos)} núcleos · ${esc(c.threads)} threads`,
  });
}

function cardMemoria(m) {
  return card({
    titulo: 'Memória RAM', nomeIcone: 'memoria', nivel: nivelPorUso(m.usoPercentual), barra: m.usoPercentual,
    valor: `${fmt(m.usoPercentual, 0)}% <small>em uso</small>`,
    sub: `${fmt(m.usadoGB)} GB de ${fmt(m.totalGB)} GB · ${fmt(m.livreGB)} GB livres`,
  });
}

function cardDisco(discos) {
  if (!discos || !discos.length) return card({ titulo: 'Disco', nomeIcone: 'disco', valor: '—', sub: 'Nenhum disco local encontrado.', nivel: 'atencao' });
  const sis = discos.find((d) => d.sistema) || discos[0];
  const nivel = sis.livrePercentual < 10 ? 'critico' : sis.livrePercentual < 20 ? 'atencao' : 'ok';
  const outros = discos.filter((d) => d !== sis);
  const extra = outros.length
    ? `<ul class="lista-mini">${outros.map((d) => `<li>${esc(d.letra)} ${esc(d.rotulo)} — ${fmt(d.livreGB)} GB livres de ${fmt(d.totalGB)} GB</li>`).join('')}</ul>`
    : '';
  return card({
    titulo: 'Disco do sistema', nomeIcone: 'disco', nivel, barra: 100 - sis.livrePercentual, extra,
    valor: `${fmt(sis.livreGB)} GB <small>livres</small>`,
    sub: `${esc(sis.letra)} ${esc(sis.rotulo)} · ${fmt(sis.totalGB)} GB no total (${fmt(sis.livrePercentual)}% livre)`,
  });
}

function cardWindows(w) {
  return card({
    titulo: 'Windows', nomeIcone: 'janela',
    valor: `<span class="card-valor-menor">${esc(w.nome)}</span>`,
    sub: `Versão ${esc(w.versao || '—')} · Build ${esc(w.build)} · ${esc(w.arquitetura)}<br>
          Ligado há ${fmtDuracao(w.tempoLigadoHoras)} (desde ${fmtData(w.ultimoBoot)})`,
  });
}

function cardDefender(def) {
  const outros = (def.outrosAntivirus || []).filter((a) => !/defender/i.test(a.nome || ''));
  let nivel; let valor;
  if (def.disponivel && def.protecaoTempoReal) { nivel = 'ok'; valor = selo('Protegido', 'ok'); }
  else if (outros.some((a) => a.ativo)) { nivel = 'ok'; valor = selo('Outro antivírus ativo', 'ok'); }
  else if (def.disponivel) { nivel = 'critico'; valor = selo('Proteção em tempo real desligada', 'critico'); }
  else { nivel = 'atencao'; valor = selo('Indisponível', 'atencao'); }

  if (nivel === 'ok' && def.disponivel && def.protecaoTempoReal && def.idadeAssinaturaDias > 7) {
    nivel = 'atencao'; valor = selo('Definições desatualizadas', 'atencao');
  }

  const sub = def.disponivel
    ? `Definições: ${esc(def.idadeAssinaturaDias)} dia(s) · Última varredura rápida: ${fmtData(def.ultimaVarreduraRapida)}`
    : esc(def.mensagem);
  const extra = outros.length
    ? `<ul class="lista-mini">${outros.map((a) => `<li>${esc(a.nome)} — ${a.ativo ? 'ativo' : 'inativo'}</li>`).join('')}</ul>`
    : '';
  return card({ titulo: 'Windows Defender', nomeIcone: 'escudo', nivel, valor, sub, extra });
}

function cardReinicio(r) {
  if (!r.pendente) return card({ titulo: 'Reinício pendente', nomeIcone: 'reiniciar', nivel: 'ok', valor: selo('Não', 'ok'), sub: 'Nenhuma instalação aguardando reinício.' });
  return card({
    titulo: 'Reinício pendente', nomeIcone: 'reiniciar', nivel: 'atencao', valor: selo('Sim', 'atencao'),
    sub: 'Reinicie o PC antes de rodar reparos.',
    extra: `<ul class="lista-mini">${r.motivos.map((m) => `<li>• ${esc(m)}</li>`).join('')}</ul>`,
  });
}

function cardManutencao(m) {
  if (!m) {
    return card({
      titulo: 'Última manutenção', nomeIcone: 'calendario', nivel: 'atencao',
      valor: '<small>Nenhuma registrada</small>',
      sub: 'A data é gravada no pendrive quando você roda limpeza ou reparo por esta ferramenta.',
    });
  }
  return card({ titulo: 'Última manutenção', nomeIcone: 'calendario', valor: fmtData(m.data), sub: esc(m.descricao) });
}

function cardHistorico(m) {
  if (!m) {
    return card({ titulo: 'Histórico deste PC', nomeIcone: 'relogio', nivel: 'atencao', valor: '—', sub: 'Histórico indisponível (veja o log).' });
  }
  const primeira = !m.visitaAnterior;
  const s = m.situacao && m.situacao.valor ? Situacoes[m.situacao.valor] : null;
  const obs = m.situacao && m.situacao.observacao ? ` <span class="suave">${esc(m.situacao.observacao)}</span>` : '';
  return card({
    titulo: 'Histórico deste PC', nomeIcone: 'relogio', nivel: primeira ? 'atencao' : 'ok',
    valor: primeira ? '<small>Primeira visita</small>' : `${esc(m.sessoes)} <small>sessões</small>`,
    sub: primeira
      ? 'Este PC nunca foi atendido com este pendrive.'
      : `Visita anterior: ${fmtData(m.visitaAnterior)} · ${esc(m.comandosExecutados)} comando(s) já executado(s)`,
    extra: `${s || obs ? `<div>${s ? selo(s[0], s[1]) : ''}${obs}</div>` : ''}<a href="#historico" class="link-pequeno">Ver histórico completo →</a>`,
  });
}

/** Dispara as animações (anel da nota e barras) depois que o HTML entrou na tela. */
function animarIndicadores(raiz) {
  requestAnimationFrame(() => requestAnimationFrame(() => {
    raiz.querySelectorAll('[data-largura]').forEach((b) => { b.style.width = `${b.dataset.largura}%`; });
    raiz.querySelectorAll('[data-alvo]').forEach((c) => { c.style.strokeDashoffset = c.dataset.alvo; });
  }));
}

async function paginaInicio(el, ativa) {
  const btn = botaoTopo('Atualizar', 'reiniciar', () => navegar());
  btn.disabled = true;
  el.innerHTML = esqueletoInicio();
  try {
    const d = await api('info.resumo');
    if (!ativa()) return;
    el.innerHTML = `
      <section class="painel-saude">${blocoNota(d.nota)}</section>
      <section class="grade-cards">
        ${cardCpu(d.cpu)}
        ${cardMemoria(d.memoria)}
        ${cardDisco(d.discos)}
        ${cardWindows(d.windows)}
        ${cardDefender(d.defender)}
        ${cardReinicio(d.reinicio)}
        ${cardManutencao(d.manutencao)}
        ${cardHistorico(d.maquina)}
      </section>
      <p class="rodape-coleta">Coletado em ${fmtData(d.coletadoEm)} · ${esc(d.computador)}
        ${d.fabricante ? `· ${esc(d.fabricante)} ${esc(d.modelo)}` : ''}</p>`;
    animarIndicadores(el);
  } finally {
    btn.disabled = false;
  }
}

// ---------------------------------------------------------------------
// Componentes reutilizáveis (blocos, tabelas, tarefas em segundo plano)
// ---------------------------------------------------------------------
const fmtBytes = (b) => {
  const n = Number(b) || 0;
  if (n >= 1024 ** 3) return `${fmt(n / 1024 ** 3, 2)} GB`;
  if (n >= 1024 ** 2) return `${fmt(n / 1024 ** 2, 1)} MB`;
  if (n >= 1024) return `${fmt(n / 1024, 0)} KB`;
  return `${n} bytes`;
};

function fmtCronometro(seg) {
  const s = Math.max(0, Number(seg) || 0);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${r}` : `${m}:${r}`;
}

const carregandoMini = (texto = 'Carregando…') => `<div class="carregando-mini"><span class="girando"></span>${esc(texto)}</div>`;

/** Seção com título, ações à direita e corpo. */
function bloco(titulo, corpo, { id = '', acoes = '' } = {}) {
  return `<section class="bloco"${id ? ` id="${id}"` : ''}>
    <div class="bloco-topo"><h2>${esc(titulo)}</h2><div class="bloco-acoes">${acoes}</div></div>
    <div class="bloco-corpo">${corpo}</div>
  </section>`;
}

/** Tabela simples. colunas: [{ titulo, campo } | { titulo, html: (linha) => '...' }] */
function tabela(colunas, linhas, { vazio = 'Nada encontrado.' } = {}) {
  if (!linhas || !linhas.length) return `<p class="vazio-mini">${esc(vazio)}</p>`;
  const cab = colunas.map((c) => `<th class="${c.classe || ''}">${esc(c.titulo)}</th>`).join('');
  const corpo = linhas.map((l) => `<tr>${colunas.map((c) => `<td class="${c.classe || ''}">${c.html ? c.html(l) : esc(l[c.campo])}</td>`).join('')}</tr>`).join('');
  return `<div class="tabela-rolagem"><table class="tabela"><thead><tr>${cab}</tr></thead><tbody>${corpo}</tbody></table></div>`;
}

/** Lista "rótulo: valor" (valores já em HTML seguro). */
const listaDados = (pares) => `<dl class="dados">${pares.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v}</dd>`).join('')}</dl>`;

const faixa = (texto, nivel = 'info') => `<div class="alerta-faixa alerta-${nivel}">${texto}</div>`;

/** Carrega uma ação de leitura dentro de um elemento, com indicador e tratamento de erro. */
async function carregarEm(alvo, acao, render, ativa, params = {}, depois = null) {
  if (!alvo) return null;
  alvo.innerHTML = carregandoMini();
  try {
    const d = await api(acao, params);
    if (!ativa()) return null;
    alvo.innerHTML = render(d);
    animarIndicadores(alvo);
    if (depois) depois(alvo, d);
    return d;
  } catch (e) {
    if (ativa()) alvo.innerHTML = caixaErro(e);
    return null;
  }
}

const EstadosTarefa = {
  executando: ['Em execução', 'info'],
  cancelando: ['Cancelando…', 'atencao'],
  concluida: ['Concluída', 'ok'],
  falhou: ['Terminou com erro', 'critico'],
  cancelada: ['Cancelada', 'atencao'],
};

/**
 * Mostra uma tarefa em segundo plano dentro de "area" e acompanha o andamento
 * (consulta tarefa.estado a cada segundo enquanto a página estiver aberta).
 * opcoes: { aoConcluir(resumo, elResultado), consoleFechado, restaurada, avisoCancelar }
 */
function mostrarTarefa(area, resumo, opcoes = {}) {
  area.innerHTML = `
    <div class="tarefa">
      <div class="tarefa-topo">
        <strong class="tarefa-titulo"></strong>
        <span class="tarefa-estado"></span>
        <span class="tarefa-tempo suave"></span>
        <button type="button" class="botao botao-fantasma botao-pequeno tarefa-cancelar" hidden>Cancelar</button>
      </div>
      <div class="barra tarefa-barra"><div class="barra-preench"></div></div>
      ${opcoes.consoleFechado
        ? '<details class="tarefa-detalhes"><summary>Saída do comando</summary><pre class="console"></pre></details>'
        : '<pre class="console"></pre>'}
      <div class="tarefa-resultado"></div>
    </div>`;
  const q = (s) => area.querySelector(s);
  const el = {
    titulo: q('.tarefa-titulo'), estado: q('.tarefa-estado'), tempo: q('.tarefa-tempo'),
    cancelar: q('.tarefa-cancelar'), barra: q('.tarefa-barra'), preench: q('.barra-preench'),
    saida: q('.console'), resultado: q('.tarefa-resultado'),
  };
  el.titulo.textContent = resumo.titulo;

  el.cancelar.addEventListener('click', async () => {
    const ok = await confirmar({
      titulo: 'Interromper a tarefa?',
      texto: opcoes.avisoCancelar || 'O comando será encerrado. Interromper reparos ou instalações no meio pode deixar o trabalho incompleto.',
      botao: 'Interromper',
    });
    if (!ok) return;
    try { await api('tarefa.cancelar', { id: resumo.id }, { confirmado: true }); } catch (e) { avisar(e.message, 'erro'); }
  });

  const emAndamento = (r) => r.estado === 'executando' || r.estado === 'cancelando';

  const desenhar = (r) => {
    const [txt, nivel] = EstadosTarefa[r.estado] || [r.estado, 'info'];
    el.estado.innerHTML = selo(txt, nivel);
    el.tempo.textContent = fmtCronometro(r.duracaoSeg);
    el.cancelar.hidden = r.estado !== 'executando';
    if (emAndamento(r)) {
      const indeterminada = r.progresso === null || r.progresso === undefined;
      el.barra.classList.toggle('indeterminada', indeterminada);
      if (!indeterminada) el.preench.style.width = `${r.progresso}%`;
    } else {
      el.barra.classList.remove('indeterminada');
      el.preench.style.width = '100%';
      el.preench.className = `barra-preench nivel-${nivel === 'info' ? 'ok' : nivel}`;
    }
    if (r.linhas) {
      const s = el.saida;
      const noFim = s.scrollHeight - s.scrollTop - s.clientHeight < 40;
      s.textContent = r.linhas.length ? r.linhas.join('\n') : 'Aguardando a saída do comando…';
      if (noFim) s.scrollTop = s.scrollHeight;
    }
  };
  desenhar(resumo);

  const ciclo = async () => {
    if (!area.isConnected) return; // o técnico saiu da página: para de consultar
    let r;
    try {
      r = await api('tarefa.estado', { id: resumo.id }, { silencioso: true });
    } catch (e) {
      if (area.isConnected) el.resultado.innerHTML = caixaErro(e);
      return;
    }
    if (!area.isConnected) return;
    desenhar(r);
    if (emAndamento(r)) { setTimeout(ciclo, 1000); return; }

    if (r.mensagem) el.resultado.insertAdjacentHTML('beforeend', faixa(esc(r.mensagem), 'atencao'));
    if (opcoes.aoConcluir) {
      try { opcoes.aoConcluir(r, el.resultado); } catch (e) { el.resultado.insertAdjacentHTML('beforeend', caixaErro(e)); }
    }
    if (!opcoes.restaurada || emAndamento(resumo)) {
      atualizarHistorico();
      const [txt, nivel] = EstadosTarefa[r.estado];
      avisar(`${r.titulo}: ${txt}`, nivel === 'ok' ? 'sucesso' : nivel === 'critico' ? 'erro' : 'atencao', 7000);
    }
  };
  ciclo();
}

// ---------------------------------------------------------------------
// Histórico da máquina: "este comando já foi executado neste PC?"
// (os dados ficam no pendrive: logs\maquinas\<id>.json)
// ---------------------------------------------------------------------
const Historico = { comandos: {}, maquina: null, tecnico: '' };

const TxtResultado = {
  iniciada: ['Iniciada (sem resultado registrado)', 'atencao'],
  concluida: ['Concluída', 'ok'],
  falhou: ['Terminou com erro', 'critico'],
  cancelada: ['Cancelada', 'atencao'],
  ok: ['OK', 'ok'],
  erro: ['Erro', 'critico'],
  info: ['Registro', 'info'],
};

const Situacoes = {
  em_revisao: ['Em revisão', 'atencao'],
  revisada: ['Revisada', 'ok'],
  locada: ['Locada', 'info'],
  disponivel: ['Disponível', 'ok'],
  defeito: ['Com defeito', 'critico'],
};

const seloResultado = (r) => { const [t, n] = TxtResultado[r] || [r || '—', 'info']; return selo(t, n); };

/** Recarrega o mapa "comando -> última execução" e atualiza os avisos da tela. */
async function atualizarHistorico() {
  try {
    const d = await api('historico.maquina', { resumo: 'true' }, { silencioso: true });
    Historico.comandos = d.comandosMapa || {};
    Historico.maquina = d.maquina;
    Historico.tecnico = d.tecnico || '';
  } catch { /* sem histórico: os botões continuam funcionando */ }
  preencherUltimas(document);
  atualizarRodapeLateral();
}

/** Execução mais recente entre os nomes de ação informados. */
function ultimaExecucao(...nomes) {
  return nomes.map((n) => Historico.comandos[n]).filter(Boolean)
    .sort((a, b) => String(b.data).localeCompare(String(a.data)))[0] || null;
}

/** Marcador "Última vez neste PC: ..." para colocar perto de um botão. */
const marcadorUltima = (nomes, rotulo = '') => `<p class="ultima-exec" data-ultima="${esc(nomes)}" data-rotulo="${esc(rotulo)}"></p>`;

function preencherUltimas(raiz) {
  raiz.querySelectorAll('[data-ultima]').forEach((el) => {
    const u = ultimaExecucao(...el.dataset.ultima.split(' '));
    const rotulo = el.dataset.rotulo ? `<strong>${esc(el.dataset.rotulo)}:</strong> ` : '';
    if (!u) {
      el.className = 'ultima-exec nunca';
      el.innerHTML = `${icone('relogio')} ${rotulo}nunca executado neste PC por esta ferramenta.`;
      return;
    }
    el.className = 'ultima-exec';
    el.innerHTML = `${icone('relogio')} ${rotulo}última vez neste PC em <strong>${fmtData(u.data)}</strong> ${seloResultado(u.resultado)}${u.tecnico ? ` <span class="suave">por ${esc(u.tecnico)}</span>` : ''}`;
  });
}

/** Acrescenta à confirmação um aviso quando o comando já foi executado neste PC. */
function avisoJaExecutado(texto, ...nomes) {
  const u = ultimaExecucao(...nomes);
  if (!u) return texto;
  const [txt] = TxtResultado[u.resultado] || [u.resultado];
  return `${texto}\n\n⚠ Este comando já foi executado neste PC em ${fmtData(u.data)} (${txt}${u.tecnico ? `, por ${u.tecnico}` : ''}).`;
}

/** Inicia uma ação que devolve uma tarefa (com confirmação opcional) e mostra o painel dela. */
async function iniciarTarefa(area, acao, params = {}, { confirmacao = null, ...opcoes } = {}) {
  try {
    let r;
    if (confirmacao) {
      const conf = { ...confirmacao, texto: avisoJaExecutado(confirmacao.texto || '', acao) };
      if (!await confirmar(conf)) return null;
      r = await api(acao, params, { confirmado: true });
    } else {
      r = await api(acao, params);
    }
    mostrarTarefa(area, r, opcoes);
    if (!confirmacao) atualizarHistorico();
    area.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    return r;
  } catch (e) {
    avisar(e.message, 'erro', 8000);
    return null;
  }
}

/** Ao reabrir uma página, mostra a tarefa mais recente de cada área (em andamento ou não). */
async function restaurarTarefas(raiz, modulo, opcoesPorNome = {}) {
  let lista = [];
  try { lista = (await api('tarefa.listar', { modulo }, { silencioso: true })).tarefas || []; } catch { return; }
  raiz.querySelectorAll('[data-tarefas]').forEach((area) => {
    const nomes = area.dataset.tarefas.split(' ');
    const t = lista.find((x) => nomes.includes(x.nome)); // a lista vem da mais nova para a mais antiga
    if (t) mostrarTarefa(area, t, { ...(opcoesPorNome[t.nome] || {}), restaurada: true });
  });
}

// ---------------------------------------------------------------------
// Página: Diagnóstico (etapa b)
// ---------------------------------------------------------------------
const TradSaude = { Healthy: ['Saudável', 'ok'], Warning: ['Alerta', 'atencao'], Unhealthy: ['Falha', 'critico'] };
const TradTipo = (t) => ({ Unspecified: 'Não informado', '': 'Não informado' }[t ?? ''] ?? t);

function renderDiscos(d) {
  let html = '';
  if (d.smart && d.smart.falhaPrevista) {
    html += faixa('<strong>O SMART prevê FALHA em pelo menos um disco.</strong> Faça backup dos dados imediatamente e planeje a troca.', 'critico');
  }
  if (!d.discos.length) return `${html}<p class="vazio-mini">Nenhum disco físico encontrado.</p>`;
  html += `<div class="grade-cards">${d.discos.map((x) => {
    const [sTxt, sNivel] = TradSaude[x.saude] || [x.saude || 'Desconhecida', 'atencao'];
    const t = x.temperatura;
    const nivelTemp = t >= 60 ? 'critico' : t >= 50 ? 'atencao' : 'ok';
    const erros = (x.errosLeitura || 0) + (x.errosEscrita || 0);
    const pares = [
      ['Tipo', `${esc(TradTipo(x.tipo))} · ${esc(x.barramento)}`],
      ['Tamanho', `${fmt(x.tamanhoGB)} GB`],
      ['Temperatura', t ? `<span class="texto-${nivelTemp}">${t} °C</span>${x.temperaturaMax ? ` <span class="suave">(máx. ${x.temperaturaMax} °C)</span>` : ''}` : '—'],
      ['Desgaste (vida usada)', x.desgaste !== null && x.desgaste !== undefined ? `<span class="texto-${nivelPorUso(x.desgaste, 70, 90)}">${x.desgaste}%</span>` : '—'],
      ['Horas ligado', x.horasLigado ? `${fmt(x.horasLigado, 0)} h` : '—'],
      ['Erros não corrigidos', x.smartDisponivel ? `<span class="texto-${erros ? 'critico' : 'ok'}">${erros}</span>` : '—'],
    ];
    return card({
      titulo: `Disco ${x.numero}`, nomeIcone: 'disco', nivel: sNivel,
      valor: `<span class="card-valor-menor">${esc(x.nome)}</span>`,
      sub: selo(sTxt, sNivel),
      extra: listaDados(pares) + (x.smartDisponivel ? '' : '<p class="suave pequeno">Este disco não informa dados SMART detalhados (comum em USB e RAID).</p>'),
    });
  }).join('')}</div>`;
  return html;
}

function renderMemoria(d) {
  const max = Math.max(1, ...d.processos.map((p) => p.memoriaMB));
  const ocupados = d.modulos.length;
  return `
    <div class="chips">
      <span class="chip">Em uso: <strong>${fmt(d.usadoGB)} de ${fmt(d.totalGB)} GB (${fmt(d.usoPercentual, 0)}%)</strong></span>
      <span class="chip">Memória comprometida: <strong>${fmt(d.compromissoGB)} de ${fmt(d.limiteGB)} GB</strong></span>
      <span class="chip">Slots: <strong>${ocupados} ocupado(s)${d.slotsTotal ? ` de ${d.slotsTotal}` : ''}</strong></span>
      ${d.paginacao.map((p) => `<span class="chip">Paginação ${esc(p.caminho)}: <strong>${fmt(p.usoMB, 0)} de ${fmt(p.tamanhoMB, 0)} MB</strong></span>`).join('')}
    </div>
    <div class="duas-colunas">
      <div>
        <h3>Pentes de memória</h3>
        ${tabela([
          { titulo: 'Slot', campo: 'slot' },
          { titulo: 'Capacidade', html: (m) => `${fmt(m.capacidadeGB)} GB` },
          { titulo: 'Velocidade', html: (m) => (m.velocidadeMHz ? `${m.velocidadeMHz} MHz` : '—') },
          { titulo: 'Fabricante', campo: 'fabricante' },
          { titulo: 'Peça', campo: 'peca', classe: 'mono' },
        ], d.modulos, { vazio: 'Não foi possível ler os pentes de memória.' })}
      </div>
      <div>
        <h3>Programas que mais usam memória</h3>
        ${tabela([
          { titulo: 'Processo', html: (p) => `${esc(p.nome)}${p.quantidade > 1 ? ` <span class="suave">×${p.quantidade}</span>` : ''}` },
          { titulo: 'Memória', classe: 'col-barra', html: (p) => `<div class="mini-barra"><span data-largura="${(p.memoriaMB / max) * 100}"></span></div>${fmt(p.memoriaMB, 0)} MB` },
        ], d.processos)}
      </div>
    </div>`;
}

function renderInicializacao(d) {
  return `<p class="suave">Para desativar um item, use o Gerenciador de Tarefas &gt; Inicializar (Ctrl+Shift+Esc).</p>
    ${tabela([
      { titulo: 'Programa', html: (p) => `<strong>${esc(p.nome)}</strong><div class="mono pequeno suave quebra">${esc(p.comando)}</div>` },
      { titulo: 'Origem', campo: 'origem' },
      { titulo: 'Usuário', campo: 'usuario' },
      { titulo: 'Situação', html: (p) => (p.ativo ? selo('Ativo', 'ok') : selo('Desativado', 'atencao')) },
    ], d.programas, { vazio: 'Nenhum programa configurado para iniciar com o Windows.' })}`;
}

function renderEventos(d) {
  const nivelDesl = d.desligamentosInesperados ? 'critico' : 'ok';
  return `
    <div class="chips">
      <span class="chip">Erros: <strong>${d.total}${d.limiteAtingido ? '+' : ''}</strong></span>
      <span class="chip">Críticos: <strong class="texto-${d.criticos ? 'critico' : 'ok'}">${d.criticos}</strong></span>
      <span class="chip" title="Kernel-Power 41 (desligou sem desligar corretamente) e telas azuis (BugCheck 1001)">
        Desligamentos inesperados / telas azuis: <strong class="texto-${nivelDesl}">${d.desligamentosInesperados}</strong></span>
    </div>
    ${d.total ? `
      <h3>Mais frequentes</h3>
      ${tabela([
        { titulo: 'Qtd.', campo: 'quantidade', classe: 'num' },
        { titulo: 'Fonte', html: (e) => `${esc(e.fonte)} <span class="suave">(ID ${esc(e.id)})</span>` },
        { titulo: 'Última vez', html: (e) => fmtData(e.ultima) },
        { titulo: 'Mensagem', campo: 'mensagem' },
      ], d.frequentes)}
      <details class="detalhes"><summary>Ver os eventos mais recentes (${d.eventos.length})</summary>
      ${tabela([
        { titulo: 'Data', html: (e) => fmtData(e.data) },
        { titulo: 'Nível', html: (e) => selo(e.nivel, e.nivel === 'Crítico' ? 'critico' : 'atencao') },
        { titulo: 'Log', campo: 'log' },
        { titulo: 'Fonte', html: (e) => `${esc(e.fonte)} <span class="suave">(${esc(e.id)})</span>` },
        { titulo: 'Mensagem', campo: 'mensagem' },
      ], d.eventos)}
      </details>` : '<p class="vazio-mini">Nenhum erro registrado no período. Ótimo sinal!</p>'}`;
}

async function paginaDiagnostico(el, ativa) {
  botaoTopo('Atualizar', 'reiniciar', () => navegar());
  el.innerHTML = `
    ${bloco('Discos e SMART', '', { id: 'dgDiscos' })}
    ${bloco('Memória', '', { id: 'dgMemoria' })}
    ${bloco('Programas que iniciam com o Windows', '', { id: 'dgInicio' })}
    ${bloco('Erros recentes (Visualizador de Eventos)', '', {
      id: 'dgEventos',
      acoes: `<select class="campo" id="dgHoras" aria-label="Período">
        <option value="24">Últimas 24 horas</option><option value="72" selected>Últimos 3 dias</option>
        <option value="168">Últimos 7 dias</option><option value="720">Últimos 30 dias</option></select>`,
    })}`;
  const corpo = (id) => $(`#${id} .bloco-corpo`, el);
  const carregarEventos = () => carregarEm(corpo('dgEventos'), 'diagnostico.eventos', renderEventos, ativa, { horas: $('#dgHoras').value });
  $('#dgHoras').addEventListener('change', carregarEventos);
  ['dgMemoria', 'dgInicio', 'dgEventos'].forEach((id) => { corpo(id).innerHTML = carregandoMini('Na fila…'); });

  await carregarEm(corpo('dgDiscos'), 'diagnostico.discos', renderDiscos, ativa);
  if (!ativa()) return;
  await carregarEm(corpo('dgMemoria'), 'diagnostico.memoria', renderMemoria, ativa);
  if (!ativa()) return;
  await carregarEm(corpo('dgInicio'), 'diagnostico.inicializacao', renderInicializacao, ativa);
  if (!ativa()) return;
  await carregarEventos();
}

// ---------------------------------------------------------------------
// Página: Reparo (etapa c)
// ---------------------------------------------------------------------
function resultadoInterpretado(r, alvo) {
  if (r.resultado && r.resultado.interpretacao) {
    alvo.insertAdjacentHTML('beforeend', faixa(esc(r.resultado.interpretacao), r.estado === 'concluida' ? 'ok' : 'atencao'));
  }
}

async function paginaReparo(el, ativa) {
  el.innerHTML = `
    ${faixa('Ordem recomendada quando o Windows está instável: <strong>DISM (Reparar) → SFC → reiniciar</strong>. Feche os programas e não desligue o PC durante os reparos.', 'info')}
    ${bloco('SFC — Verificador de arquivos do sistema', `
      <p class="suave">Verifica os arquivos protegidos do Windows e substitui os corrompidos. Leva de 5 a 30 minutos.</p>
      <div class="linha-botoes"><button type="button" class="botao" id="rpSfc">Executar SFC /scannow</button></div>
      ${marcadorUltima('reparo.sfc')}
      <div class="tarefa-area" data-tarefas="reparo.sfc"></div>`)}
    ${bloco('DISM — Reparo da imagem do Windows', `
      <p class="suave">"Verificar" é rápido e não altera nada. "Reparar" baixa arquivos íntegros do Windows Update (precisa de internet) e leva de 10 a 40 minutos.</p>
      <div class="linha-botoes">
        <button type="button" class="botao botao-fantasma" id="rpDismVer">Verificar (CheckHealth)</button>
        <button type="button" class="botao" id="rpDismRep">Reparar (RestoreHealth)</button>
      </div>
      ${marcadorUltima('reparo.dism_verificar', 'Verificar')}
      ${marcadorUltima('reparo.dism_reparar', 'Reparar')}
      <div class="tarefa-area" data-tarefas="reparo.dism_verificar reparo.dism_reparar"></div>`)}
    ${bloco('CHKDSK — Verificação do disco', `
      <p class="suave">"Verificar agora" analisa o disco sem reiniciar (NTFS: <code>/scan</code>). Se forem encontrados erros, agende a correção completa no próximo reinício.</p>
      <div class="linha-botoes">
        <select class="campo" id="rpUnidade" aria-label="Unidade"><option>Carregando…</option></select>
        <button type="button" class="botao" id="rpChk">Verificar agora</button>
        <button type="button" class="botao botao-fantasma" id="rpChkAg">Agendar correção no reinício</button>
      </div>
      ${marcadorUltima('reparo.chkdsk', 'Verificação')}
      ${marcadorUltima('reparo.chkdsk_agendar', 'Correção agendada')}
      <div class="tarefa-area" data-tarefas="reparo.chkdsk"></div>`)}`;

  const area = (nome) => el.querySelector(`[data-tarefas~="${nome}"]`);
  const posReparo = (r, alvo) => {
    resultadoInterpretado(r, alvo);
    if (r.estado === 'concluida' && r.nome !== 'reparo.dism_verificar') {
      alvo.insertAdjacentHTML('beforeend', faixa('Leia o resumo no fim da saída acima. Reinicie o PC para concluir as correções.', 'ok'));
    }
  };

  $('#rpSfc').addEventListener('click', () => iniciarTarefa(area('reparo.sfc'), 'reparo.sfc', {}, {
    confirmacao: { titulo: 'Executar SFC /scannow?', texto: 'O SFC vai verificar e reparar os arquivos do sistema. Pode levar até 30 minutos.\nNão desligue o computador durante o processo.', botao: 'Executar', perigo: false },
    aoConcluir: posReparo,
  }));
  $('#rpDismVer').addEventListener('click', () => iniciarTarefa(area('reparo.dism_verificar'), 'reparo.dism_verificar', {}, { aoConcluir: posReparo }));
  $('#rpDismRep').addEventListener('click', () => iniciarTarefa(area('reparo.dism_reparar'), 'reparo.dism_reparar', {}, {
    confirmacao: { titulo: 'Reparar a imagem do Windows?', texto: 'O DISM vai baixar arquivos do Windows Update e reparar a imagem do sistema. Precisa de internet e pode levar até 40 minutos.\nO progresso pode ficar parado em 20% ou 40% por vários minutos: isso é normal.', botao: 'Reparar', perigo: false },
    aoConcluir: posReparo,
  }));

  const unidade = () => $('#rpUnidade').value;
  $('#rpChk').addEventListener('click', () => iniciarTarefa(area('reparo.chkdsk'), 'reparo.chkdsk', { unidade: unidade() }, {
    confirmacao: { titulo: `Verificar a unidade ${unidade()}?`, texto: 'A verificação roda com o Windows em uso e pode deixar o disco lento por alguns minutos.', botao: 'Verificar', perigo: false },
    aoConcluir: resultadoInterpretado,
  }));
  $('#rpChkAg').addEventListener('click', async () => {
    const u = unidade();
    if (!await confirmar({ titulo: `Agendar CHKDSK completo em ${u}?`, texto: avisoJaExecutado('No próximo reinício, o Windows vai verificar e corrigir o disco antes de carregar. Em discos grandes isso pode levar mais de uma hora. Não desligue o PC durante a verificação.', 'reparo.chkdsk_agendar'), botao: 'Agendar' })) return;
    try {
      const r = await api('reparo.chkdsk_agendar', { unidade: u }, { confirmado: true });
      avisar(r.mensagem, 'sucesso', 9000);
    } catch (e) { avisar(e.message, 'erro', 8000); }
  });

  try {
    const d = await api('reparo.unidades');
    if (!ativa()) return;
    $('#rpUnidade').innerHTML = d.unidades.map((u) => `<option value="${esc(u.letra)}"${u.sistema ? ' selected' : ''}>${esc(u.letra)} ${esc(u.rotulo)} (${esc(u.sistemaArquivos)})</option>`).join('');
  } catch (e) { avisar(e.message, 'erro'); }

  await restaurarTarefas(el, 'reparo', {
    'reparo.sfc': { aoConcluir: posReparo },
    'reparo.dism_verificar': { aoConcluir: posReparo },
    'reparo.dism_reparar': { aoConcluir: posReparo },
    'reparo.chkdsk': { aoConcluir: resultadoInterpretado },
  });
}

// ---------------------------------------------------------------------
// Página: Limpeza (etapa c)
// ---------------------------------------------------------------------
function resultadoLimpeza(r, alvo) {
  const res = r.resultado;
  if (!res || !res.categorias) return;
  alvo.insertAdjacentHTML('beforeend', `
    ${faixa(`Espaço liberado: <strong>${fmtBytes(res.totalBytes)}</strong>`, 'ok')}
    ${tabela([
      { titulo: 'Categoria', campo: 'nome' },
      { titulo: 'Removidos', html: (c) => fmt(c.removidos, 0), classe: 'num' },
      { titulo: 'Liberado', html: (c) => fmtBytes(c.bytes), classe: 'num' },
      { titulo: 'Mantidos (em uso)', html: (c) => fmt(c.falhas, 0), classe: 'num' },
    ], res.categorias)}`);
}

async function paginaLimpeza(el, ativa) {
  el.innerHTML = `
    ${bloco('O que pode ser limpo', '', { id: 'lpAnalise' })}
    ${marcadorUltima('limpeza.executar', 'Limpeza')}
    <div class="tarefa-area" data-tarefas="limpeza.executar"></div>`;
  const corpo = $('#lpAnalise .bloco-corpo', el);
  const area = $('[data-tarefas]', el);

  async function analisar() {
    corpo.innerHTML = carregandoMini('Calculando o espaço de cada categoria… (nada é apagado nesta etapa)');
    let d;
    try { d = await api('limpeza.analisar'); } catch (e) { if (ativa()) corpo.innerHTML = caixaErro(e); return; }
    if (!ativa()) return;

    corpo.innerHTML = `
      <div class="lista-limpeza">${d.categorias.map((c) => `
        <label class="item-limpeza">
          <input type="checkbox" value="${esc(c.id)}" data-bytes="${c.bytes}" data-arquivos="${c.arquivos}" data-nome="${esc(c.nome)}" ${c.bytes > 0 ? 'checked' : 'disabled'}>
          <span class="item-limpeza-texto"><strong>${esc(c.nome)}</strong><span class="suave">${esc(c.descricao)}</span></span>
          <span class="item-limpeza-tamanho"><strong>${fmtBytes(c.bytes)}</strong><span class="suave">${fmt(c.arquivos, 0)} arquivo(s)</span></span>
        </label>`).join('')}
      </div>
      <div class="rodape-limpeza">
        <span>Será liberado: <strong id="lpTotal">—</strong></span>
        <button type="button" class="botao botao-perigo" id="lpLimpar">${icone('lixeira')} Limpar selecionados</button>
      </div>`;

    const marcados = () => [...corpo.querySelectorAll('input[type=checkbox]:checked')];
    const atualizarTotal = () => {
      const total = marcados().reduce((s, cb) => s + Number(cb.dataset.bytes), 0);
      $('#lpTotal').textContent = fmtBytes(total);
      $('#lpLimpar').disabled = marcados().length === 0;
    };
    corpo.querySelectorAll('input[type=checkbox]').forEach((cb) => cb.addEventListener('change', atualizarTotal));
    atualizarTotal();

    $('#lpLimpar').addEventListener('click', async () => {
      const sel = marcados();
      const total = sel.reduce((s, cb) => s + Number(cb.dataset.bytes), 0);
      const arquivos = sel.reduce((s, cb) => s + Number(cb.dataset.arquivos), 0);
      await iniciarTarefa(area, 'limpeza.executar', { categorias: sel.map((cb) => cb.value) }, {
        confirmacao: {
          titulo: 'Confirmar limpeza',
          texto: `Serão apagados aproximadamente ${fmtBytes(total)} (${fmt(arquivos, 0)} arquivos) de:\n• ${sel.map((cb) => cb.dataset.nome).join('\n• ')}\n\nArquivos em uso serão mantidos. Esta ação não pode ser desfeita.`,
          botao: 'Apagar agora',
        },
        aoConcluir: (r, alvo) => { resultadoLimpeza(r, alvo); if (ativa()) analisar(); },
      });
    });
  }

  botaoTopo('Analisar novamente', 'reiniciar', () => analisar());
  await restaurarTarefas(el, 'limpeza', { 'limpeza.executar': { aoConcluir: resultadoLimpeza } });
  if (!ativa()) return;
  await analisar();
}

// ---------------------------------------------------------------------
// Página: Programas (etapa d)
// ---------------------------------------------------------------------
async function paginaProgramas(el, ativa) {
  el.innerHTML = `<div class="pagina">
    <div id="pgStatus">${carregandoMini('Procurando o winget…')}</div>
    ${bloco('Atualizações disponíveis', `
      <div class="linha-botoes">
        <button type="button" class="botao" id="pgProcurar" data-winget>Procurar atualizações</button>
        <button type="button" class="botao botao-fantasma" id="pgTodos" data-winget>Atualizar todos</button>
      </div>
      <div class="tarefa-area" data-tarefas="programas.atualizaveis"></div>`)}
    ${bloco('Instalar programa', `
      <form class="linha-botoes" id="pgBusca">
        <input class="campo campo-largo" id="pgTermo" maxlength="50" placeholder="Ex.: 7zip, Chrome, VLC, AnyDesk, Adobe Reader" data-winget>
        <button type="submit" class="botao" data-winget>Buscar</button>
      </form>
      <div class="tarefa-area" data-tarefas="programas.buscar"></div>`)}
    ${bloco('Instalações e atualizações em andamento', `
      ${marcadorUltima('programas.atualizar_todos', 'Atualizar todos')}
      <div class="tarefa-area" data-tarefas="programas.instalar programas.atualizar programas.atualizar_todos">
        <p class="vazio-mini">Nenhuma instalação iniciada nesta sessão.</p></div>`)}
    ${bloco('Programas instalados', `
      <div class="linha-botoes">
        <button type="button" class="botao botao-fantasma" id="pgListar">Carregar lista</button>
        <input class="campo" id="pgFiltro" placeholder="Filtrar por nome ou ID…" hidden>
      </div>
      <div class="tarefa-area" data-tarefas="programas.listar"></div>
      <div id="pgLista"></div>`)}</div>`;
  const raiz = el.firstElementChild;

  const area = (nome) => el.querySelector(`[data-tarefas~="${nome}"]`);
  const areaOperacoes = area('programas.instalar');
  const idUtil = (id) => id && !id.endsWith('…'); // o winget corta IDs longos com "…"

  const btnId = (rotulo, attr, p) => (idUtil(p.id)
    ? `<button type="button" class="botao botao-pequeno" ${attr}="${esc(p.id)}" data-nome="${esc(p.nome)}">${rotulo}</button>`
    : '<span class="suave pequeno" title="O winget cortou o ID deste pacote">ID incompleto</span>');

  const operar = (acao, id, nome, titulo, texto, botao) => iniciarTarefa(areaOperacoes, acao, { id }, {
    confirmacao: { titulo, texto, botao, perigo: false },
  });

  // Delegação de cliques (os botões são criados dinamicamente)
  raiz.addEventListener('click', (e) => {
    const inst = e.target.closest('[data-instalar]');
    const att = e.target.closest('[data-atualizar]');
    if (inst) {
      operar('programas.instalar', inst.dataset.instalar, inst.dataset.nome, `Instalar ${inst.dataset.nome}?`,
        `O pacote "${inst.dataset.instalar}" será baixado e instalado em modo silencioso via winget.`, 'Instalar');
    } else if (att) {
      operar('programas.atualizar', att.dataset.atualizar, att.dataset.nome, `Atualizar ${att.dataset.nome}?`,
        'O programa será atualizado em modo silencioso. Feche-o antes, se estiver aberto.', 'Atualizar');
    }
  });

  const renderAtualizaveis = (r, alvo) => {
    const lista = (r.resultado && r.resultado.programas) || [];
    alvo.insertAdjacentHTML('beforeend', lista.length
      ? tabela([
        { titulo: 'Programa', campo: 'nome' },
        { titulo: 'ID', campo: 'id', classe: 'mono pequeno' },
        { titulo: 'Versão atual', campo: 'versao' },
        { titulo: 'Disponível', html: (p) => `<strong class="texto-ok">${esc(p.disponivel)}</strong>` },
        { titulo: '', html: (p) => btnId('Atualizar', 'data-atualizar', p) },
      ], lista)
      : (r.estado === 'concluida' ? faixa('Todos os programas gerenciados pelo winget estão atualizados.', 'ok') : ''));
  };

  const renderBusca = (r, alvo) => {
    const lista = (r.resultado && r.resultado.programas) || [];
    alvo.insertAdjacentHTML('beforeend', tabela([
      { titulo: 'Programa', campo: 'nome' },
      { titulo: 'ID', campo: 'id', classe: 'mono pequeno' },
      { titulo: 'Versão', campo: 'versao' },
      { titulo: '', html: (p) => btnId('Instalar', 'data-instalar', p) },
    ], lista, { vazio: 'Nenhum programa encontrado com esse nome.' }));
  };

  let instalados = [];
  const desenharInstalados = () => {
    const f = $('#pgFiltro').value.trim().toLowerCase();
    const lista = f ? instalados.filter((p) => `${p.nome} ${p.id}`.toLowerCase().includes(f)) : instalados;
    $('#pgLista').innerHTML = `<p class="suave pequeno">${lista.length} de ${instalados.length} programa(s)</p>
      ${tabela([
        { titulo: 'Programa', campo: 'nome' },
        { titulo: 'ID', campo: 'id', classe: 'mono pequeno' },
        { titulo: 'Versão', campo: 'versao' },
        { titulo: 'Atualização', html: (p) => (p.disponivel ? `<strong class="texto-ok">${esc(p.disponivel)}</strong>` : '') },
        { titulo: 'Origem', campo: 'origem' },
      ], lista)}`;
  };
  const mostrarInstalados = (lista) => {
    instalados = lista || [];
    $('#pgFiltro').hidden = false;
    desenharInstalados();
  };
  $('#pgFiltro').addEventListener('input', desenharInstalados);

  $('#pgListar').addEventListener('click', async () => {
    try {
      const r = await api('programas.listar');
      if (r.id) mostrarTarefa(area('programas.listar'), r, { consoleFechado: true, aoConcluir: (t) => mostrarInstalados(t.resultado && t.resultado.programas) });
      else mostrarInstalados(r.programas);
    } catch (e) { avisar(e.message, 'erro'); }
  });
  $('#pgProcurar').addEventListener('click', () => iniciarTarefa(area('programas.atualizaveis'), 'programas.atualizaveis', {}, { consoleFechado: true, aoConcluir: renderAtualizaveis }));
  $('#pgTodos').addEventListener('click', () => iniciarTarefa(areaOperacoes, 'programas.atualizar_todos', {}, {
    confirmacao: { titulo: 'Atualizar todos os programas?', texto: 'Todos os programas com atualização disponível no winget serão atualizados em modo silencioso.\nFeche os programas abertos antes. Pode levar bastante tempo.', botao: 'Atualizar todos', perigo: false },
  }));
  $('#pgBusca').addEventListener('submit', (e) => {
    e.preventDefault();
    const termo = $('#pgTermo').value.trim();
    if (termo.length < 2) { avisar('Digite ao menos 2 caracteres.', 'atencao'); return; }
    iniciarTarefa(area('programas.buscar'), 'programas.buscar', { termo }, { consoleFechado: true, aoConcluir: renderBusca });
  });

  // Situação do winget
  try {
    const st = await api('programas.winget_status');
    if (!ativa()) return;
    if (st.disponivel) {
      $('#pgStatus').innerHTML = faixa(`winget encontrado (${esc(st.versao || 'versão desconhecida')}). As instalações usam o repositório oficial do winget.`, 'ok');
    } else {
      $('#pgStatus').innerHTML = faixa(`<strong>O winget não está disponível neste PC.</strong> Instalar e atualizar ficam desativados;
        a lista de instalados vem do Registro do Windows. Para habilitar, instale/atualize o
        <em>Instalador de Aplicativo</em> pela Microsoft Store e abra a ferramenta de novo.`, 'atencao');
      el.querySelectorAll('[data-winget]').forEach((b) => { b.disabled = true; });
    }
  } catch (e) { $('#pgStatus').innerHTML = caixaErro(e); }

  await restaurarTarefas(el, 'programas', {
    'programas.atualizaveis': { consoleFechado: true, aoConcluir: renderAtualizaveis },
    'programas.buscar': { consoleFechado: true, aoConcluir: renderBusca },
    'programas.listar': { consoleFechado: true, aoConcluir: (t) => mostrarInstalados(t.resultado && t.resultado.programas) },
  });
}

// ---------------------------------------------------------------------
// Página: Rede (etapa d)
// ---------------------------------------------------------------------
const TradStatusRede = { Up: ['Conectado', 'ok'], Disconnected: ['Desconectado', 'atencao'], Disabled: ['Desativado', 'atencao'] };

function cardAdaptador(a) {
  const [txt, nivel] = TradStatusRede[a.status] || [a.status, 'atencao'];
  const junta = (l) => (l && l.length ? l.map(esc).join('<br>') : '—');
  return card({
    titulo: a.nome, nomeIcone: 'globo', nivel: nivel === 'ok' ? 'ok' : 'atencao',
    valor: `<span class="card-valor-menor">${junta(a.ipv4)}</span>`,
    sub: `${selo(txt, nivel)} <span class="suave">${esc(a.descricao)}</span>`,
    extra: listaDados([
      ['Gateway', junta(a.gateway)],
      ['DNS', junta(a.dns)],
      ['IPv6', junta(a.ipv6)],
      ['DHCP', a.dhcp ? 'Sim (automático)' : 'Não (IP fixo)'],
      ['MAC', esc(a.mac || '—')],
      ['Velocidade', esc(a.velocidade || '—')],
    ]),
  });
}

function renderRede(d) {
  const ativos = d.adaptadores.filter((a) => a.status === 'Up');
  const outros = d.adaptadores.filter((a) => a.status !== 'Up');
  return `${ativos.length ? `<div class="grade-cards">${ativos.map(cardAdaptador).join('')}</div>` : faixa('Nenhum adaptador conectado.', 'atencao')}
    ${outros.length ? `<details class="detalhes"><summary>Outros adaptadores (${outros.length})</summary>
      <div class="grade-cards">${outros.map(cardAdaptador).join('')}</div></details>` : ''}`;
}

function renderTesteInternet(d) {
  return `${faixa(`<strong>${esc(d.diagnostico)}</strong>`, d.conectado ? 'ok' : 'critico')}
    <ul class="passos">${d.etapas.map((e) => `
      <li class="${e.ok ? 'ok' : 'falha'}"><span class="passo-icone">${e.ok ? '✓' : '✗'}</span>
        <strong>${esc(e.etapa)}</strong><span class="suave">${esc(e.detalhe)}</span></li>`).join('')}
    </ul>`;
}

async function paginaRede(el, ativa) {
  botaoTopo('Atualizar', 'reiniciar', () => navegar());
  el.innerHTML = `
    ${bloco('Ferramentas de rede', `
      <div class="linha-botoes">
        <button type="button" class="botao" id="rdTeste">Testar internet</button>
        <button type="button" class="botao botao-fantasma" id="rdRenovar">Renovar IP</button>
        <button type="button" class="botao botao-fantasma" id="rdDns">Limpar cache DNS</button>
      </div>
      <form class="linha-botoes" id="rdPing">
        <input class="campo" id="rdDestino" value="8.8.8.8" maxlength="253" aria-label="Endereço para ping" placeholder="IP ou endereço (ex.: google.com)">
        <button type="submit" class="botao botao-fantasma">Ping</button>
      </form>
      <div id="rdTesteRes"></div>
      ${marcadorUltima('rede.renovar_ip', 'Renovar IP')}
      ${marcadorUltima('rede.limpar_dns', 'Limpar DNS')}
      <div class="tarefa-area" data-tarefas="rede.ping rede.renovar_ip"></div>`)}
    ${bloco('Adaptadores de rede', '', { id: 'rdAdapt' })}`;
  const areaTarefas = $('[data-tarefas]', el);

  $('#rdTeste').addEventListener('click', async () => {
    const alvo = $('#rdTesteRes');
    alvo.innerHTML = carregandoMini('Testando roteador, internet, DNS e acesso web…');
    try { alvo.innerHTML = renderTesteInternet(await api('rede.teste_internet')); } catch (e) { alvo.innerHTML = caixaErro(e); }
  });
  $('#rdPing').addEventListener('submit', (e) => {
    e.preventDefault();
    const destino = $('#rdDestino').value.trim();
    if (!/^[A-Za-z0-9](?:[A-Za-z0-9.:-]*[A-Za-z0-9])?$/.test(destino)) { avisar('Endereço inválido.', 'atencao'); return; }
    iniciarTarefa(areaTarefas, 'rede.ping', { destino });
  });
  $('#rdRenovar').addEventListener('click', () => iniciarTarefa(areaTarefas, 'rede.renovar_ip', {}, {
    confirmacao: { titulo: 'Renovar o endereço IP?', texto: 'A conexão de rede cairá por alguns segundos (acessos remotos como AnyDesk/TeamViewer serão desconectados).', botao: 'Renovar IP' },
    aoConcluir: () => carregarEm($('#rdAdapt .bloco-corpo', el), 'rede.info', renderRede, ativa),
  }));
  $('#rdDns').addEventListener('click', async () => {
    if (!await confirmar({ titulo: 'Limpar o cache DNS?', texto: 'Os endereços de sites guardados pelo Windows serão descartados. É seguro e não derruba a conexão.', botao: 'Limpar', perigo: false })) return;
    try { avisar((await api('rede.limpar_dns', {}, { confirmado: true })).mensagem, 'sucesso'); } catch (e) { avisar(e.message, 'erro'); }
  });

  await restaurarTarefas(el, 'rede');
  if (!ativa()) return;
  await carregarEm($('#rdAdapt .bloco-corpo', el), 'rede.info', renderRede, ativa);
}

// ---------------------------------------------------------------------
// Página: Segurança (etapa d)
// ---------------------------------------------------------------------
const TradPerfil = { Domain: 'Domínio', Private: 'Privado', Public: 'Público' };

function renderSeguranca(d) {
  const def = d.defender;
  const fwDesligado = d.firewall.some((f) => !f.ativo);
  const sb = d.secureBoot === true ? ['Ativo', 'ok'] : d.secureBoot === false ? ['Desativado', 'atencao'] : ['Não suportado (BIOS legado)', 'atencao'];
  const cards = [
    cardDefender(def).replace('</article>', `${listaDados([
      ['Proteção contra adulteração', def.protecaoAdulteracao === true ? 'Ativa' : def.protecaoAdulteracao === false ? 'Desativada' : '—'],
      ['Definições atualizadas em', fmtData(def.definicoesAtualizadasEm)],
      ['Última varredura completa', fmtData(def.ultimaVarreduraCompleta)],
      ['Versão do mecanismo', esc(def.versaoMotor || '—')],
    ])}</article>`),
    card({
      titulo: 'Firewall', nomeIcone: 'escudo', nivel: fwDesligado ? 'critico' : 'ok',
      valor: fwDesligado ? selo('Desligado em algum perfil', 'critico') : selo('Ativo', 'ok'),
      extra: listaDados(d.firewall.map((f) => [TradPerfil[f.perfil] || f.perfil, f.ativo ? selo('Ativo', 'ok') : selo('Desligado', 'critico')]))
        + (fwDesligado ? '<button type="button" class="botao botao-pequeno" id="sgFirewall">Ativar em todos os perfis</button>' : ''),
    }),
    card({
      titulo: 'Controle de Conta (UAC)', nomeIcone: 'escudo', nivel: d.uac && d.uac.ativo ? 'ok' : 'critico',
      valor: d.uac ? (d.uac.ativo ? selo('Ativo', 'ok') : selo('Desativado', 'critico')) : '—',
      sub: d.uac && d.uac.nivelAdmin === 0 ? 'Atenção: administradores não recebem aviso (nível mínimo).' : '',
    }),
    card({ titulo: 'Secure Boot', nomeIcone: 'chave', nivel: sb[1], valor: selo(sb[0], sb[1]) }),
    card({
      titulo: 'BitLocker', nomeIcone: 'disco', nivel: 'ok',
      valor: d.bitlocker.length ? '' : '<small>Indisponível nesta edição</small>',
      extra: d.bitlocker.length ? listaDados(d.bitlocker.map((b) => [b.unidade, b.protegido === true ? selo('Criptografado', 'ok') : b.protegido === false ? selo('Sem criptografia', 'atencao') : '—'])) : '',
    }),
    card({
      titulo: 'Última atualização instalada', nomeIcone: 'calendario',
      nivel: d.ultimaAtualizacao ? 'ok' : 'atencao',
      valor: d.ultimaAtualizacao ? fmtData(d.ultimaAtualizacao.data) : '—',
      sub: d.ultimaAtualizacao ? `${esc(d.ultimaAtualizacao.kb)} · ${esc(d.ultimaAtualizacao.descricao)}` : '',
    }),
  ];
  return `<div class="grade-cards">${cards.join('')}</div>
    <h3>Ameaças detectadas nos últimos 30 dias</h3>
    ${tabela([
      { titulo: 'Ameaça', html: (a) => `<strong>${esc(a.nome)}</strong>${a.arquivos.length ? `<div class="mono pequeno suave quebra">${a.arquivos.map(esc).join('<br>')}</div>` : ''}` },
      { titulo: 'Detectada em', html: (a) => fmtData(a.data) },
      { titulo: 'Situação', html: (a) => (a.resolvida ? selo('Resolvida', 'ok') : selo('Pendente', 'critico')) },
    ], d.ameacas, { vazio: 'Nenhuma ameaça detectada nos últimos 30 dias.' })}`;
}

function renderAtualizacoesWindows(r, alvo) {
  const res = r.resultado;
  if (!res) return;
  if (res.erro) { alvo.insertAdjacentHTML('beforeend', faixa(esc(res.erro), 'critico')); return; }
  const lista = res.atualizacoes || [];
  alvo.insertAdjacentHTML('beforeend', `
    ${faixa(lista.length
      ? `<strong>${lista.length} atualização(ões) pendente(s).</strong> Instale por Configurações &gt; Windows Update.`
      : '<strong>O Windows está atualizado.</strong>', lista.length ? 'atencao' : 'ok')}
    ${res.ultimaInstalacao ? `<p class="suave pequeno">Última instalação registrada: ${fmtData(res.ultimaInstalacao)}</p>` : ''}
    ${tabela([
      { titulo: 'Atualização', campo: 'titulo' },
      { titulo: 'KB', campo: 'kb', classe: 'mono' },
      { titulo: 'Tamanho', html: (u) => (u.tamanhoMB ? `${fmt(u.tamanhoMB)} MB` : '—'), classe: 'num' },
      { titulo: 'Baixada', html: (u) => (u.baixada ? 'Sim' : 'Não') },
      { titulo: 'Gravidade', campo: 'severidade' },
    ], lista, { vazio: '' })}`);
}

async function paginaSeguranca(el, ativa) {
  botaoTopo('Atualizar', 'reiniciar', () => navegar());
  el.innerHTML = `
    ${bloco('Ações', `
      <div class="linha-botoes">
        <button type="button" class="botao" id="sgVarredura">Varredura rápida</button>
        <button type="button" class="botao botao-fantasma" id="sgDefinicoes">Atualizar definições de vírus</button>
        <button type="button" class="botao botao-fantasma" id="sgUpdates">Procurar atualizações do Windows</button>
      </div>
      ${marcadorUltima('seguranca.varredura_rapida', 'Varredura rápida')}
      ${marcadorUltima('seguranca.atualizar_definicoes', 'Definições')}
      ${marcadorUltima('seguranca.atualizacoes', 'Busca de atualizações')}
      <div class="tarefa-area" data-tarefas="seguranca.varredura_rapida seguranca.atualizar_definicoes"></div>
      <div class="tarefa-area" data-tarefas="seguranca.atualizacoes"></div>`)}
    ${bloco('Situação de segurança', '', { id: 'sgStatus' })}`;
  const area = (nome) => el.querySelector(`[data-tarefas~="${nome}"]`);
  const carregarStatus = () => carregarEm($('#sgStatus .bloco-corpo', el), 'seguranca.status', renderSeguranca, ativa, {}, (alvo) => {
    const b = $('#sgFirewall', alvo);
    if (b) {
      b.addEventListener('click', async () => {
        if (!await confirmar({ titulo: 'Ativar o firewall?', texto: 'O Firewall do Windows será ligado nos perfis Domínio, Privado e Público.', botao: 'Ativar', perigo: false })) return;
        try { avisar((await api('seguranca.ativar_firewall', {}, { confirmado: true })).mensagem, 'sucesso'); carregarStatus(); } catch (e) { avisar(e.message, 'erro'); }
      });
    }
  });
  const aoConcluirDefender = (r, alvo) => { resultadoInterpretado(r, alvo); if (ativa()) carregarStatus(); };

  $('#sgVarredura').addEventListener('click', () => iniciarTarefa(area('seguranca.varredura_rapida'), 'seguranca.varredura_rapida', {}, {
    confirmacao: { titulo: 'Iniciar varredura rápida?', texto: 'O Windows Defender vai verificar os locais mais comuns de infecção (5 a 15 minutos). Ameaças encontradas são tratadas automaticamente.', botao: 'Iniciar', perigo: false },
    aoConcluir: aoConcluirDefender,
  }));
  $('#sgDefinicoes').addEventListener('click', () => iniciarTarefa(area('seguranca.atualizar_definicoes'), 'seguranca.atualizar_definicoes', {}, {
    confirmacao: { titulo: 'Atualizar as definições de vírus?', texto: 'Baixa as definições mais recentes do Windows Defender (precisa de internet).', botao: 'Atualizar', perigo: false },
    aoConcluir: aoConcluirDefender,
  }));
  $('#sgUpdates').addEventListener('click', () => iniciarTarefa(area('seguranca.atualizacoes'), 'seguranca.atualizacoes', {}, {
    consoleFechado: true, aoConcluir: renderAtualizacoesWindows,
  }));

  await restaurarTarefas(el, 'seguranca', {
    'seguranca.varredura_rapida': { aoConcluir: resultadoInterpretado },
    'seguranca.atualizacoes': { consoleFechado: true, aoConcluir: renderAtualizacoesWindows },
  });
  if (!ativa()) return;
  await carregarStatus();
}

// ---------------------------------------------------------------------
// Página: Relatório (etapa e)
// ---------------------------------------------------------------------
async function paginaRelatorio(el, ativa) {
  el.innerHTML = `<div class="pagina">
    ${bloco('Gerar relatório', `
      <p>Reúne a nota de saúde, hardware, discos (SMART), segurança, rede, erros recentes, programas
         instalados e as ações feitas nesta sessão. São gerados dois arquivos na pasta <code>logs</code> do pendrive:
         <strong>HTML</strong> (para o cliente, pode ser impresso em PDF) e <strong>TXT</strong> (para colar em chamados).</p>
      <div class="linha-botoes">
        <button type="button" class="botao" id="rlGerar">${icone('documento')} Gerar relatório agora</button>
        <button type="button" class="botao botao-fantasma" id="rlPasta">Abrir pasta de logs</button>
      </div>
      <div id="rlStatus"></div>`)}
    ${bloco('Relatórios salvos no pendrive', '', { id: 'rlLista' })}</div>`;

  const abrir = async (arquivo) => {
    try { avisar((await api('relatorio.abrir', { arquivo })).mensagem, 'info'); } catch (e) { avisar(e.message, 'erro'); }
  };
  el.firstElementChild.addEventListener('click', (e) => {
    const b = e.target.closest('[data-abrir]');
    if (b) abrir(b.dataset.abrir);
  });

  const carregarLista = () => carregarEm($('#rlLista .bloco-corpo', el), 'relatorio.listar', (d) => tabela([
    { titulo: 'Arquivo', campo: 'arquivo', classe: 'mono pequeno' },
    { titulo: 'Computador', campo: 'computador' },
    { titulo: 'Data', html: (r) => fmtData(r.data) },
    { titulo: 'Tamanho', html: (r) => `${fmt(r.tamanhoKB, 0)} KB`, classe: 'num' },
    { titulo: '', html: (r) => `<button type="button" class="botao botao-pequeno botao-fantasma" data-abrir="${esc(r.arquivo)}">Abrir</button>` },
  ], d.relatorios, { vazio: 'Nenhum relatório gerado ainda.' }), ativa);

  $('#rlPasta').addEventListener('click', async () => {
    try { await api('relatorio.abrir_pasta'); } catch (e) { avisar(e.message, 'erro'); }
  });
  $('#rlGerar').addEventListener('click', async () => {
    const btn = $('#rlGerar');
    btn.disabled = true;
    $('#rlStatus').innerHTML = carregandoMini('Coletando dados de todas as áreas… pode levar até 1 minuto.');
    try {
      const r = await api('relatorio.gerar');
      if (!ativa()) return;
      $('#rlStatus').innerHTML = faixa(`Relatório gerado: <code>${esc(r.html)}</code> e <code>${esc(r.txt)}</code>
        <span class="linha-botoes"><button type="button" class="botao botao-pequeno" data-abrir="${esc(r.html)}">Abrir HTML</button>
        <button type="button" class="botao botao-pequeno botao-fantasma" data-abrir="${esc(r.txt)}">Abrir TXT</button></span>`, 'ok');
      avisar('Relatório gerado na pasta logs.', 'sucesso');
      carregarLista();
    } catch (e) {
      if (ativa()) $('#rlStatus').innerHTML = caixaErro(e);
    } finally {
      btn.disabled = false;
    }
  });

  await carregarLista();
}

// ---------------------------------------------------------------------
// Página: Histórico (máquina atual + todas as máquinas do pendrive)
// ---------------------------------------------------------------------
async function paginaHistorico(el, ativa) {
  botaoTopo('Atualizar', 'reiniciar', () => navegar());
  el.innerHTML = `<div class="pagina">
    ${bloco('Esta máquina', '', { id: 'hsMaquina' })}
    ${bloco('Comandos já executados neste PC', '', { id: 'hsComandos' })}
    ${bloco('Linha do tempo deste PC', '', { id: 'hsLinha' })}
    ${bloco('Todas as máquinas atendidas com este pendrive', '', {
      id: 'hsTodas',
      acoes: '<button type="button" class="botao botao-fantasma botao-pequeno" id="hsPlanilha">Abrir planilha (CSV)</button>',
    })}
  </div>`;
  const corpo = (id) => $(`#${id} .bloco-corpo`, el);
  $('#hsPlanilha', el).addEventListener('click', async () => {
    try { await api('historico.abrir_planilha'); } catch (e) { avisar(e.message, 'erro'); }
  });

  corpo('hsMaquina').innerHTML = carregandoMini();
  let d;
  try { d = await api('historico.maquina'); } catch (e) { if (ativa()) corpo('hsMaquina').innerHTML = caixaErro(e); return; }
  if (!ativa()) return;
  Historico.comandos = d.comandosMapa || {};
  Historico.maquina = d.maquina;
  Historico.tecnico = d.tecnico || '';
  atualizarRodapeLateral();

  const m = d.maquina;
  const sit = m.situacao || {};
  const antes = (m.nomesAnteriores || []).length ? ` <span class="suave">(antes: ${m.nomesAnteriores.map(esc).join(', ')})</span>` : '';
  corpo('hsMaquina').innerHTML = `
    <div class="duas-colunas">
      <div>${listaDados([
        ['Computador', esc(m.computador) + antes],
        ['Equipamento', `${esc(m.fabricante)} ${esc(m.modelo)}`],
        ['Número de série', esc(m.serial || '—')],
        ['Identificação', `<span class="mono">${esc(m.id)}</span> <span class="suave">(por ${esc(m.baseId)})</span>`],
        ['Primeira visita', fmtData(m.primeiraVisita)],
        ['Visita anterior', m.visitaAnterior ? fmtData(m.visitaAnterior) : 'Nenhuma: é a primeira vez'],
        ['Sessões', esc(m.sessoes)],
        ['Última manutenção', m.ultimaManutencao ? `${fmtData(m.ultimaManutencao.data)} — ${esc(m.ultimaManutencao.descricao)}` : 'Nenhuma registrada'],
      ])}</div>
      <form class="form-situacao" id="hsForm">
        <label>Situação da máquina
          <select class="campo" id="hsSituacao">
            <option value="">— sem situação —</option>
            ${Object.entries(Situacoes).map(([k, [txt]]) => `<option value="${k}"${sit.valor === k ? ' selected' : ''}>${esc(txt)}</option>`).join('')}
          </select>
        </label>
        <label>Observação
          <textarea class="campo" id="hsObs" maxlength="500" rows="3"
            placeholder="Ex.: locada para a Empresa X até 30/12; SSD trocado; aguardando peça…">${esc(sit.observacao || '')}</textarea>
        </label>
        <label>Técnico responsável
          <input class="campo" id="hsTecnico" maxlength="60" value="${esc(d.tecnico)}" placeholder="Seu nome (fica salvo no pendrive)">
        </label>
        ${sit.data ? `<p class="suave pequeno">Situação definida em ${fmtData(sit.data)}${sit.tecnico ? ` por ${esc(sit.tecnico)}` : ''}.</p>` : ''}
        <div class="linha-botoes"><button type="submit" class="botao">Salvar</button></div>
      </form>
    </div>`;

  $('#hsForm', el).addEventListener('submit', async (e) => {
    e.preventDefault();
    const tec = $('#hsTecnico', el).value.trim();
    if (tec && !/^[\p{L}\p{N} .\-_]{1,60}$/u.test(tec)) { avisar('Nome do técnico: use só letras, números, espaço, ponto, hífen e _.', 'atencao'); return; }
    try {
      if (tec !== Historico.tecnico) {
        await api('historico.tecnico', { nome: tec });
        Historico.tecnico = tec;
        atualizarRodapeLateral();
      }
      const r = await api('historico.situacao', { situacao: $('#hsSituacao', el).value, observacao: $('#hsObs', el).value.trim() });
      avisar(r.mensagem, 'sucesso');
      navegar();
    } catch (err) { avisar(err.message, 'erro', 8000); }
  });

  const cmds = Object.entries(d.comandosMapa || {})
    .filter(([acao]) => !acao.startsWith('historico.'))
    .map(([acao, c]) => ({ acao, ...c }))
    .sort((a, b) => String(b.data).localeCompare(String(a.data)));
  corpo('hsComandos').innerHTML = tabela([
    { titulo: 'Comando', html: (c) => `${esc(c.titulo)}<div class="mono pequeno suave">${esc(c.acao)}</div>` },
    { titulo: 'Última execução', html: (c) => fmtData(c.data) },
    { titulo: 'Resultado', html: (c) => seloResultado(c.resultado) },
    { titulo: 'Técnico', html: (c) => esc(c.tecnico || '—') },
  ], cmds, { vazio: 'Nenhum comando executado neste PC por esta ferramenta ainda.' });

  corpo('hsLinha').innerHTML = `<p class="suave pequeno">Últimos ${(d.historico || []).length} eventos. Arquivo: <code>${esc(d.arquivo)}</code></p>
    ${tabela([
      { titulo: 'Data', html: (h) => fmtData(h.data) },
      { titulo: 'Evento', html: (h) => `${esc(h.titulo || h.acao)}${h.detalhes ? `<div class="pequeno suave quebra">${esc(h.detalhes)}</div>` : ''}` },
      { titulo: 'Resultado', html: (h) => seloResultado(h.resultado) },
      { titulo: 'Por', html: (h) => `${esc(h.tecnico || '')}<div class="pequeno suave">${esc(h.usuario)}</div>` },
    ], d.historico || [])}`;

  await carregarEm(corpo('hsTodas'), 'historico.maquinas', (r) => tabela([
    { titulo: 'Computador', html: (x) => `<strong>${esc(x.computador)}</strong>${x.atual ? ' <span class="selo selo-ok">este PC</span>' : ''}` },
    { titulo: 'Equipamento', html: (x) => `${esc(x.fabricante)} ${esc(x.modelo)}<div class="mono pequeno suave">${esc(x.serial || '')}</div>` },
    { titulo: 'Visitas', campo: 'sessoes', classe: 'num' },
    { titulo: 'Primeira / última visita', html: (x) => `${fmtData(x.primeiraVisita)}<br>${fmtData(x.ultimaVisita)}` },
    { titulo: 'Situação', html: (x) => { const s = x.situacao && Situacoes[x.situacao.valor]; return s ? selo(s[0], s[1]) : '<span class="suave">—</span>'; } },
    { titulo: 'Última manutenção', html: (x) => (x.ultimaManutencao ? `${fmtData(x.ultimaManutencao.data)}<div class="pequeno suave">${esc(x.ultimaManutencao.descricao)}</div>` : '—') },
  ], r.maquinas, { vazio: 'Nenhuma máquina registrada.' }), ativa);
}

// ---------------------------------------------------------------------
// Telas especiais
// ---------------------------------------------------------------------
function telaSemToken(expirado = false) {
  document.body.innerHTML = `
    <div class="tela-cheia"><div class="vazio">
      <h2>${expirado ? 'Sessão expirada' : 'Acesso não autorizado'}</h2>
      <p>${expirado
        ? 'O servidor foi reiniciado e gerou um novo código de acesso.'
        : 'Este painel precisa do código de acesso gerado pelo servidor.'}</p>
      <p>Execute o <code>Iniciar.bat</code> novamente: se a ferramenta já estiver aberta,
         o painel é reaberto com um acesso válido.</p>
    </div></div>`;
}

function telaDesconectado() {
  document.body.innerHTML = `
    <div class="tela-cheia"><div class="vazio">
      <h2>Servidor desconectado</h2>
      <p>O Kitzo foi encerrado neste PC (pelo botão "Encerrar" ou porque o painel ficou fechado por muito tempo).</p>
      <p>Para continuar, execute o <code>Iniciar.bat</code> novamente.</p>
    </div></div>`;
}

function telaEncerrado() {
  document.body.innerHTML = `
    <div class="tela-cheia"><div class="vazio">
      <h2>Servidor encerrado</h2>
      <p>Você já pode fechar esta aba e remover o pendrive com segurança.</p>
    </div></div>`;
}

// ---------------------------------------------------------------------
// Inicialização
// ---------------------------------------------------------------------

/** Rodapé do menu lateral: PC, usuário, técnico e situação de admin. */
function atualizarRodapeLateral() {
  const s = Estado.sessao;
  if (!s) return;
  const m = Historico.maquina || s.maquina;
  const sit = m && m.situacao && m.situacao.valor ? Situacoes[m.situacao.valor] : null;
  $('#infoPc').innerHTML = `<strong>${esc(s.computador)}</strong>
    <span class="suave">${esc(s.usuario)}</span>
    ${Historico.tecnico ? `<span class="suave">Técnico: ${esc(Historico.tecnico)}</span>` : '<a href="#historico" class="link-pequeno">Definir técnico</a>'}
    ${sit ? `<span>${selo(sit[0], sit[1])}</span>` : ''}
    ${s.administrador ? '' : '<span class="tag-aviso">Sem privilégios de administrador</span>'}`;
}

/**
 * Mantém o servidor vivo enquanto o painel estiver aberto. Se o navegador
 * fechar, os pulsos param e o servidor se encerra sozinho (depois de terminar
 * as tarefas em andamento).
 */
function iniciarPulso() {
  let falhas = 0;
  let w;
  try { w = new Worker('pulso.js'); } catch { return; }
  w.onmessage = (e) => {
    const status = e.data ? e.data.status : 0;
    if (status === 200) { falhas = 0; return; }
    if (status === 401) { w.terminate(); sessionStorage.removeItem('token'); telaSemToken(true); return; }
    if (status === 0) {
      falhas += 1;
      if (falhas >= 2) { w.terminate(); telaDesconectado(); }
    }
  };
  w.postMessage({ token: Estado.token });
  Estado.pulso = w;
}

async function encerrarServidor() {
  let ativas = 0;
  try { ativas = (await api('tarefa.listar', {}, { silencioso: true })).ativas || 0; } catch { /* segue */ }
  const ok = await confirmar({
    titulo: 'Encerrar o servidor?',
    texto: `${ativas ? `Há ${ativas} tarefa(s) em andamento. Elas continuarão rodando, mas o resultado NÃO será registrado no histórico.\n\n` : ''}`
      + 'O painel deixará de funcionar até você abrir o Iniciar.bat novamente.\n'
      + 'Dica: basta fechar o navegador, o servidor se encerra sozinho (e espera as tarefas terminarem).',
    botao: 'Encerrar',
  });
  if (!ok) return;
  Estado.encerrado = true;
  if (Estado.pulso) Estado.pulso.terminate();
  try { await api('sistema.encerrar'); } catch { /* já pode ter caído */ }
  sessionStorage.removeItem('token');
  telaEncerrado();
}

async function iniciar() {
  montarIcones();

  $('#btnMenu').addEventListener('click', () => $('#lateral').classList.toggle('aberto'));
  $('#veu').addEventListener('click', () => $('#lateral').classList.remove('aberto'));
  $('#btnEncerrar').addEventListener('click', encerrarServidor);

  Estado.token = obterToken();
  if (!Estado.token) { telaSemToken(); return; }

  try {
    Estado.sessao = await api('sistema.ping');
  } catch (e) {
    if (e.status === 401) { sessionStorage.removeItem('token'); telaSemToken(true); return; }
    avisar(e.message, 'erro', 8000);
  }

  // Avisa o servidor quando a aba fecha (ele espera alguns segundos: um F5 não derruba nada)
  window.addEventListener('pagehide', () => {
    if (!Estado.token || Estado.encerrado) return;
    try { navigator.sendBeacon('/api/sinal/fechando', new Blob([Estado.token], { type: 'text/plain' })); } catch { /* ignora */ }
  });
  iniciarPulso();

  await atualizarHistorico();
  if (Estado.sessao) {
    Historico.tecnico = Historico.tecnico || Estado.sessao.tecnico || '';
    atualizarRodapeLateral();
    if (!Estado.sessao.logsNoPendrive) {
      avisar(`O pendrive está protegido contra gravação. Logs e histórico desta sessão estão em ${Estado.sessao.pastaLogs}`, 'atencao', 15000);
    }
  }

  window.addEventListener('hashchange', navegar);
  navegar();
}

document.addEventListener('DOMContentLoaded', iniciar);
