const paths = {
  grid: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  jar: '<path d="M7 3h10v4H7zM6 7h12l1 3v10a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V10zM5 13h14M9 16h6"/>',
  spark: '<path d="m12 3 2.4 6.6L21 12l-6.6 2.4L12 21l-2.4-6.6L3 12l6.6-2.4zM20 2v4M18 4h4"/>',
  sliders: '<path d="M5 3v6m0 4v8M12 3v11m0 4v3M19 3v3m0 4v11M2 9h6m1 5h6m1-8h6"/><circle cx="5" cy="11" r="2"/><circle cx="12" cy="16" r="2"/><circle cx="19" cy="8" r="2"/>',
  book: '<path d="M4 3h13a2 2 0 0 1 2 2v16H6a3 3 0 0 1-3-3V6a3 3 0 0 1 3-3M3 17h16M8 7h7M8 10h5"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M7 3v4m10-4v4M3 11h18"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6m0-10v1"/>',
  edit: '<path d="m15 4 5 5M4 20l5-1L21 7a2 2 0 0 0-5-5L4 14z"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  device: '<rect x="5" y="2" width="14" height="20" rx="2"/><path d="M9 6h6m-6 4h6m-3 7v1"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  heart: '<path d="M20 5a5 5 0 0 0-8 1 5 5 0 0 0-8-1c-4 5 3 10 8 14 5-4 12-9 8-14z"/>',
};
const icon = name => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${paths[name] || paths.jar}</svg>`;
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt = value => Number(value).toLocaleString('ko-KR', {maximumFractionDigits:2});
const labels = {dashboard:'대시보드',ingredients:'재료 관리',ai:'AI 레시피',custom:'CUSTOM 계량',recipes:'내 레시피',history:'제조 이력',progress:'제조 상태'};
const navIcons = {dashboard:'grid',ingredients:'jar',ai:'spark',custom:'sliders',recipes:'book',history:'clock'};
const statusLabels = {
  starting:'시작 확인 중', running:'계량 중', stopping:'중단 요청 중',
  unconfirmed:'정지 확인 불가', completed:'완료', stopped:'중단', error:'오류'
};
const main = document.querySelector('#main');
const modal = document.querySelector('#modal');
let state = {slots:[], recipes:[], jobs:[]};
let page = location.hash.slice(1) || 'dashboard';
let draft = null;
let draftId = null;
let activeJobId = null;
let search = '';
let favoritesOnly = false;
let aiPending = false;
let aiActionBusy = false;
let aiMessages = [];
let aiHistory = [];
let aiRecipe = null;
let aiSavedId = null;
let aiInput = '';
let toastTimer;
let refreshing = false;
let requestKey = null;
let submitting = false;
let approvalRecipe = null;
let approvalMode = 'demo';
let controlKey = '';

const usesArduino = () => state.device?.mode === 'uart';
const activeJob = job => ['starting', 'running', 'stopping', 'unconfirmed'].includes(job.status);
const jobMode = job => job.demo === false ? '실계량' : '모의 계량';
const scaleAction = () => usesArduino() ? '실제 계량하기' : '데모 계량하기';

function deviceStatus() {
  if (!usesArduino()) return '데모 모드 · 장치 미연결';
  if (!state.device.connected) return 'Arduino 미연결';
  if (state.device.error) return state.device.error;
  return state.device.ready ? 'Arduino 계량 준비 완료' : 'Arduino 연결됨 · 준비 또는 계량 중';
}

function slotStatus(slot) {
  if (!slot.name) return '비어 있음';
  if (slot.operator_available === 0) return '사용 중지';
  if (usesArduino() && slot.has_level_sensor === false) return '잔량 미측정';
  if (usesArduino() && slot.check_at_center) return '중앙에서 확인';
  if (usesArduino() && slot.material_present == null) return '센서 확인 불가';
  return slot.available ? '사용 가능' : '보충 필요';
}

function slotRemaining(slot) {
  if (!usesArduino() || !slot.name || !Number.isInteger(slot.remaining_pct)) return '';
  const label = slot.check_at_center ? '마지막 잔량' : '잔량';
  return `${label} 약 ${slot.remaining_pct}%`;
}

async function api(path, method='GET', body) {
  let response;
  const headers = body ? {'Content-Type':'application/json'} : {};
  if (usesArduino() && controlKey && (/^\/jobs(?:\/[^/]+\/stop)?$/.test(path) || path.startsWith('/slots/'))) {
    headers['X-UART-Control-Token'] = controlKey;
  }
  try { response = await fetch(`/api${path}`, {method, headers, redirect:'error', body:body ? JSON.stringify(body) : undefined}); }
  catch { throw new Error('서버에 연결할 수 없습니다. 서버 실행 상태를 확인해 주세요.'); }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `요청을 처리하지 못했습니다. (${response.status})`);
  return data;
}
async function refresh() {
  state = await api('/state');
  document.querySelector('#device-status').textContent = deviceStatus();
  document.querySelector('#device-mode').textContent = usesArduino() ? '실계량 모드' : '데모 모드';
  document.querySelector('#device-controls').hidden = !usesArduino();
}
function toast(message) {
  const el = document.querySelector('#toast');
  el.textContent = message; el.classList.add('visible');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => el.classList.remove('visible'), 4000);
}
function date(timestamp) { return new Date(timestamp * 1000).toLocaleString('ko-KR', {month:'long',day:'numeric',hour:'2-digit',minute:'2-digit'}); }
function heading(title, sub, eyebrow='MY KITCHEN') {
  return `<div class="page-head"><div><p class="eyebrow">${eyebrow}</p><h1>${title}</h1><p class="subtitle">${sub}</p></div><div class="date-label">${icon('calendar')}${new Date().toLocaleDateString('ko-KR', {year:'numeric',month:'long',day:'numeric',weekday:'long'})}</div></div>`;
}
const banner = (message=deviceStatus()) => `<div class="demo-banner">${icon('info')}<span>${esc(message)}</span></div>`;
function navigate(target) { if (page === target) render(); else location.hash = target; }
function navigation() {
  document.querySelector('#navigation').innerHTML = Object.keys(navIcons).map(key => `<a href="#${key}" class="${page === key ? 'active' : ''}" ${page === key ? 'aria-current="page"' : ''}>${icon(navIcons[key])}<span>${labels[key]}</span>${key === 'recipes' ? `<span class="nav-number">${state.recipes.length}</span>` : ''}</a>`).join('');
  document.querySelector('#breadcrumb').textContent = labels[page] || labels.dashboard;
}
function machine() {
  return `<svg viewBox="0 0 340 280" class="machine" role="img" aria-label="분말통 네 개와 액체통 두 개를 갖춘 스마트 양념 계량 장치 일러스트">
  <defs><linearGradient id="body" x1="0" x2="1"><stop stop-color="#ecebdf"/><stop offset="1" stop-color="#dbdccd"/></linearGradient><linearGradient id="glass"><stop stop-color="#ffffff" stop-opacity=".85"/><stop offset="1" stop-color="#f6f4e9" stop-opacity=".4"/></linearGradient><filter id="shadow"><feGaussianBlur stdDeviation="6"/></filter></defs>
  <ellipse cx="173" cy="252" rx="121" ry="12" fill="#79836b" opacity=".15" filter="url(#shadow)"/>
  <path d="M59 137 171 107 291 139 178 173Z" fill="#cbcdbb"/><path d="m59 137 119 36v66L59 202Z" fill="#d1d4c1"/><path d="m178 173 113-34v67l-113 33Z" fill="#c2c8b3"/>
  <path d="m68 157 64 19v37l-64-18Z" fill="#f1f0e6"/><path d="m83 172 30 8v17l-30-8Z" fill="#52664c"/><path d="m89 178 18 5" stroke="#b5c79c" stroke-width="2"/><circle cx="123" cy="195" r="3" fill="#8d9a78"/>
  <path d="m187 185 95-28v40l-95 29Z" fill="#8a967c"/><path d="m197 189 75-23v23l-75 23Z" fill="#6f7f61"/>
  <ellipse cx="235" cy="196" rx="24" ry="8" fill="#b0b59f"/><path d="M212 179h46l-5 19q-18 12-36 0Z" fill="#f4efe0"/><ellipse cx="235" cy="179" rx="23" ry="7" fill="#e0d7c0"/><ellipse cx="235" cy="179" rx="18" ry="4" fill="#b48a59"/>
  <path d="M231 137v27" stroke="#dce0d1" stroke-width="5"/><path d="m229 162 6 6 6-6" stroke="#7e8e6e" stroke-width="2" fill="none"/>
  ${[[88,74,'#ede3c9','P1'],[138,61,'#88806b','P2'],[187,72,'#c9b58f','P3'],[235,88,'#b96c42','P4']].map(([x,y,c,l])=>`<g transform="translate(${x} ${y})"><path d="m-18 0 35-10 17 7-35 10Z" fill="#ddd8c4"/><path d="m-18 0 17 7v56l-17-7Z" fill="#ddd8c4" opacity=".9"/><path d="m-1 7 35-10v56l-35 10Z" fill="url(#glass)" stroke="#c9cbb9"/><path d="m2 32 29-8v26l-29 8Z" fill="${c}" opacity=".9"/><path d="m-20-4 36-10 20 8v7L0 11l-20-8Z" fill="#718267"/><path d="m-20-4 20 8L36-6" fill="none" stroke="#a1ad8e"/><text x="11" y="22" font-size="7" fill="#637257" transform="rotate(-15 11 22)">${l}</text></g>`).join('')}
  <g transform="translate(62 107)"><path d="m0 7 17-5 12 5v49l-17 5L0 55Z" fill="#d3c8a8"/><path d="m3 32 12 4 11-3v20l-14 4-9-4Z" fill="#83572f"/><path d="m7 0 11-3 6 4v10l-11 3-6-4Z" fill="#596c50"/><path d="m12 13 10-3v16l-10 3Z" fill="#f4eee0" opacity=".5"/></g>
  <path d="m300 106-17-6-12 5v49l17 5 12-6Z" fill="#d3c8a8"/><path d="m297 130-12 4-11-3v20l14 4 9-4Z" fill="#c7a65d"/><path d="m293 99-11-3-6 4v10l11 3 6-4Z" fill="#596c50"/>
  <path d="m73 208 3 7 13 4v-6m176 3-2 6 13-4 2-7" fill="#68765d"/>
  <path d="M300 49h14m-7-7v14M38 82h10m-5-5v10" stroke="#a0ac8d" stroke-width="1.5"/><circle cx="280" cy="72" r="3" fill="none" stroke="#acb69a"/>
  </svg>`;
}
const slotOrder = ['P1','P2','P3','P4','L1','L2'];
function jarHTML(slot) {
  const colorIndex = slotOrder.indexOf(slot.id);
  return `<span class="jar ${slot.kind === 'liquid' ? 'liquid' : ''}" aria-hidden="true"><span class="jar-fill ingredient-${colorIndex}"></span></span>`;
}
function slotsHTML(manage=false) {
  const ordered = [...state.slots].sort((a,b) => slotOrder.indexOf(a.id)-slotOrder.indexOf(b.id));
  const cards = ordered.map(slot => {
    const off = !slot.available || !slot.name ? 'off' : '';
    const remaining = slotRemaining(slot);
    return `<article class="slot-card ${off}" data-slot="${esc(slot.id)}">
      <div class="slot-top"><span class="slot-id">${slot.id}</span><span class="slot-status ${off}">${slotStatus(slot)}</span></div>
      ${jarHTML(slot)}<h3>${esc(slot.name || '미등록')}</h3>
      <p class="slot-kind">${slot.kind === 'liquid' ? 'LIQUID · 액체' : 'POWDER · 분말'}</p>
      ${remaining ? `<p class="slot-inventory">${remaining}</p>` : ''}
      ${usesArduino() ? '' : '<div class="slot-bottom"><span></span></div>'}
      ${manage ? `<button class="edit-slot" data-action="edit-slot" data-id="${slot.id}">${icon('edit')}재료 수정</button>` : ''}
    </article>`;
  }).join('');
  return `<div class="slot-grid ${manage ? 'manage' : ''}">${cards}</div>`;
}
function empty(title, description, target='custom', cta='첫 배합 만들기', full=false) {
  return `<div class="empty ${full ? 'full-empty' : ''}"><div class="empty-icon">${icon('book')}</div><p>${title}</p><small>${description}</small><button class="btn ghost" data-action="navigate" data-target="${target}">${cta}${icon('arrow')}</button></div>`;
}
function dashboard() {
  const completed = state.jobs.filter(j=>j.status === 'completed');
  const active = state.jobs.find(activeJob);
  return `${heading('오늘도, 맛있는 한 끼를 준비해요.','취향에 맞는 배합부터 정확한 한 꼬집까지. 나의 주방을 한눈에 확인하세요.','A LITTLE PINCH, A BETTER MEAL')}
  <section class="hero"><div class="hero-content"><span class="hero-tag">${icon('spark')} SMART SEASONING STUDIO</span><h2>맛있는 비율을 찾고,<br><em>계량은 한꼬집에게.</em></h2><p>어떤 요리를 만들고 싶으세요?<br>가지고 있는 양념으로 나만의 배합을 시작해 보세요.</p><button class="btn primary" data-action="navigate" data-target="ai">${icon('spark')}AI와 배합 만들기${icon('arrow')}</button></div><div class="hero-art">${machine()}<span class="art-caption">YOUR LITTLE KITCHEN COMPANION</span></div></section>
  <section class="stats" aria-label="주방 요약"><div class="stat"><div><div class="stat-label">등록된 재료</div><div class="stat-value">${state.slots.filter(s=>s.name).length}<small>/ 6 슬롯</small></div></div><div class="stat-icon">${icon('jar')}</div></div><div class="stat"><div><div class="stat-label">저장한 레시피</div><div class="stat-value">${state.recipes.length}<small>개</small></div></div><div class="stat-icon">${icon('book')}</div></div><div class="stat"><div><div class="stat-label">완료한 계량</div><div class="stat-value">${completed.length}<small>회</small></div></div><div class="stat-icon">${icon('check')}</div></div></section>
  ${active ? `<div class="demo-banner">${icon('device')}<span>${jobMode(active)} · ${statusLabels[active.status]}</span><button class="text-link" data-action="navigate" data-target="progress">진행 상태 보기 →</button></div>` : ''}
  <section><div class="section-title"><h2>나의 재료 <span class="meta">분말 4 · 액체 2</span></h2><a class="text-link" href="#ingredients">재료 관리${icon('arrow')}</a></div>${slotsHTML()}<p class="section-note">${icon('info')}${usesArduino() ? '재료 센서는 유무를 감지합니다.' : '재료 상태는 데모 설정값입니다.'}</p></section>
  <div class="bottom-grid"><section class="card"><div class="section-title"><h2>어떤 배합을 만들어 볼까요?</h2></div><div class="mode-options"><button class="mode-card" data-action="navigate" data-target="ai">${icon('spark')}<span class="arrow">↗</span><h3>AI 레시피</h3><p>음식과 취향을 이야기하고<br>어울리는 배합을 찾아보세요.</p></button><button class="mode-card" data-action="new-custom">${icon('sliders')}<span class="arrow">↗</span><h3>CUSTOM 계량</h3><p>나만의 비율이 있다면<br>원하는 중량을 직접 설정하세요.</p></button></div></section><section class="card"><div class="section-title"><h2>최근 제조 이력</h2><a class="text-link" href="#history">전체 보기${icon('arrow')}</a></div>${state.jobs.length ? state.jobs.slice(0,3).map(j=>`<div class="history-mini"><div><strong>${esc(j.name)}</strong><small>${date(j.started)} · ${jobMode(j)}</small></div><span class="status-tag ${j.status}">${statusLabels[j.status]}</span></div>`).join('') : empty('아직 제조한 배합이 없어요.','첫 번째 배합을 만들고 나만의 맛을 기록해 보세요.')}</section></div>`;
}
function ingredients() {
  return `${heading('나의 재료를 관리해요.','양념통에 담긴 재료를 등록하면 배합과 계량에 반영할 수 있어요.','INGREDIENT STATION')}${banner(usesArduino() ? deviceStatus() : '데모에서 슬롯의 재료와 유무 상태를 직접 설정할 수 있어요.')}${slotsHTML(true)}<div class="connection-panel">${icon('device')}<div><h3>양념을 바꿨다면, 슬롯 정보도 바꿔 주세요.</h3><p>기존에 저장한 레시피는 현재 재료와 다시 확인한 뒤 제조할 수 있어요. 제조 중에는 슬롯 변경이 제한됩니다.</p></div></div>`;
}
function freshDraft() {
  draftId = null;
  draft = {name:'나만의 양념',servings:2,mode:'CUSTOM',favorite:false,items:[]};
}
function custom() {
  if (!draft) freshDraft();
  return `${heading('나만의 비율, 그대로 계량해요.','재료별 중량을 직접 정하고 마음에 드는 배합을 저장해 보세요.','CUSTOM BLEND')}${banner()}
  <div class="builder-layout"><section class="card"><h2>${draftId ? '저장한 배합 수정' : '배합 설정'}</h2><p class="builder-intro">사용할 재료의 목표 중량을 입력하세요. 사용하지 않을 재료는 0g으로 두세요.</p><form id="custom-form"><div class="form-row"><label class="field">레시피 이름<input id="recipe-name" name="name" maxlength="80" required value="${esc(draft.name)}"></label><label class="field">기준 인분<input id="recipe-servings" name="servings" type="number" min="1" max="20" step="1" required value="${draft.servings}"></label></div><div class="weights">${state.slots.map(s => {
    const item = draft.items.find(i=>i.slot === s.id);
    const stale = item && (item.name !== s.name || item.revision !== s.revision || item.kind !== s.kind);
    return `<label class="weight-row" data-slot="${esc(s.id)}">${jarHTML(s)}<span class="weight-slot">${s.id}</span><span class="weight-name"><strong>${esc(s.name || '미등록')}</strong><small>${stale ? `이전 재료: ${esc(item.name)} · 변경된 중량 확인 필요` : s.kind === 'liquid' ? '액체' : '분말'}${s.available ? '' : ' · ' + slotStatus(s)}</small></span><span class="gram-input"><input name="${s.id}" type="number" min="0" max="100" step="0.1" aria-label="${esc(s.name || s.id)} 목표 중량" value="${item?.grams || 0}" ${!s.name ? 'disabled' : ''}><span>g</span></span></label>`;
  }).join('')}</div><p class="hint">배합 입력 범위: 재료별 0.1~100g · 총 300g 이하.${usesArduino() ? ' 제조 시 장치의 허용 범위를 추가로 확인합니다.' : ''}<br>인분을 바꿔도 입력한 중량은 자동으로 변하지 않습니다.</p><div class="form-foot"><button class="btn primary" type="submit">배합 확인하기${icon('arrow')}</button></div></form></section><aside class="card summary" id="blend-summary">${summary(draft)}</aside></div>`;
}
function summary(recipe, notice='', recipeId=draftId) {
  const items = recipe?.items || [];
  return `<div class="summary-head">${icon('jar')}<h2>배합 미리보기</h2></div>${notice ? `<p class="ai-notice" role="status">${esc(notice)}</p>` : ''}${items.length ? `<h3>${esc(recipe.name)}</h3><p class="hint">${recipe.servings}인분 · ${recipe.mode === 'AI' ? 'AI 배합' : recipe.mode === 'DEMO' ? '고정 배합 데모' : 'CUSTOM'}</p>${items.map(i=>`<div class="summary-line" data-slot="${esc(i.slot)}"><span class="summary-ingredient">${jarHTML({id:i.slot,kind:i.kind})}<span>${esc(i.name)} <small>${esc(i.slot)}</small></span></span><strong>${fmt(i.grams)} g</strong></div>`).join('')}<div class="summary-total"><span>총 목표 중량</span><strong>${fmt(items.reduce((a,i)=>a+i.grams,0))} <small>g</small></strong></div><div class="summary-actions"><button class="btn primary" data-action="confirm">${scaleAction()}${icon('arrow')}</button><button class="btn secondary" data-action="save-recipe">${icon('book')}${recipeId ? '레시피 변경 저장' : '내 레시피에 저장'}</button></div><p class="hint">${usesArduino() ? '컵을 놓고 장치 주변을 확인한 뒤 계량을 승인하세요.' : '최종 승인 후 모의 계량을 시작합니다.'}</p>` : !notice ? `<div class="summary-empty">${icon('sliders')}<p>재료를 선택하면<br>배합을 여기에서 확인할 수 있어요.</p></div>` : ''}`;
}
function aiSummary() {
  if (aiPending) return `<div class="summary-head">${icon('jar')}<h2>배합 미리보기</h2></div><div class="ai-loading" role="status"><span class="ai-spinner" aria-hidden="true"></span><strong>AI가 답변을 준비하고 있어요…</strong><p>잠시만 기다려 주세요.</p></div>`;
  return summary(aiRecipe, aiRecipe ? '마지막으로 제안된 배합입니다.' : '대화에서 양념 배합을 요청하면 여기에 표시됩니다.', aiSavedId);
}
function aiMessagesHTML() {
  const welcome = `<div class="chat-bubble assistant"><strong>한꼬집</strong><p>안녕하세요! 오늘 먹을 음식이나 양념 배합을 함께 정해요. 무엇이 궁금하세요?</p></div>`;
  return welcome + aiMessages.map(m => `<div class="chat-bubble ${m.role === 'user' ? 'user' : 'assistant'}"><strong>${m.role === 'user' ? '나' : '한꼬집'}</strong><p>${esc(m.content)}</p>${m.foods?.length ? `<div class="chat-choices">${m.foods.map(food=>`<button class="chat-choice" data-action="ai-choice" data-message="${esc(food)}" ${aiPending ? 'disabled' : ''}>${esc(food)}</button>`).join('')}</div>` : ''}${m.recipe ? m.recipe === aiRecipe ? `<button class="text-link" data-action="ai-preview">배합 미리보기${icon('arrow')}</button>` : '<small>이전 배합 제안</small>' : ''}</div>`).join('') + (aiPending ? `<div class="chat-bubble assistant chat-waiting" role="status"><span class="ai-spinner" aria-hidden="true"></span>AI가 답변을 준비하고 있어요…</div>` : '');
}
function syncAiView() {
  if (page !== 'ai') return;
  const list = document.querySelector('#ai-messages');
  if (!list) return;
  list.innerHTML = aiMessagesHTML();
  list.scrollTop = list.scrollHeight;
  const form = document.querySelector('#ai-chat-form');
  form.querySelector('input').value = aiInput;
  const blocked = aiPending || aiActionBusy;
  form.querySelectorAll('input, button').forEach(control => { control.disabled = blocked; });
  form.querySelector('[type="submit"]').textContent = aiPending ? '답변 중…' : '보내기';
  document.querySelectorAll('[data-action="ai-choice"], [data-action="ai-reset"]').forEach(control => { control.disabled = blocked; });
  document.querySelector('#ai-request-status').textContent = aiPending ? 'AI가 답변을 준비하고 있어요.' : '';
  const preview = document.querySelector('#blend-summary');
  preview.setAttribute('aria-busy', String(aiPending));
  preview.innerHTML = aiSummary();
  if (aiActionBusy) preview.querySelectorAll('button').forEach(control => { control.disabled = true; });
}
async function sendAiMessage(value) {
  const message = value.trim();
  if (aiPending || aiActionBusy || !message) return;
  if (message.length > 500) { toast('메시지는 500자 이내로 입력해 주세요.'); return; }
  aiInput = '';
  aiMessages.push({role:'user', content:message});
  aiPending = true;
  syncAiView();
  try {
    const result = await api('/ai/chat', 'POST', {message, history:aiHistory, current_recipe:aiRecipe});
    const options = result.foods.map((food, index) => `${index + 1}. ${food}`).join(' / ');
    const replyContext = options ? `${Array.from(result.message).slice(0,1200).join('')}\n추천 음식: ${options}` : result.message;
    aiHistory.push({role:'user',content:message}, {role:'assistant',content:Array.from(replyContext).slice(0,1500).join('')});
    aiHistory = aiHistory.slice(-12);
    while (aiHistory.length > 2 && aiHistory.reduce((sum, entry) => sum + Array.from(entry.content).length, 0) > 6000) aiHistory.splice(0, 2);
    if (result.recipe) { aiRecipe = result.recipe; aiSavedId = null; }
    aiMessages.push({role:'assistant',content:result.message,foods:result.foods,recipe:result.recipe});
  } catch (error) {
    aiInput = message;
    aiMessages.push({role:'assistant',content:`답변을 불러오지 못했어요: ${error.message}\n입력한 메시지를 확인하고 다시 보내 주세요.`});
  } finally {
    aiPending = false;
    syncAiView();
  }
}
function ai() {
  return `${heading('오늘은 어떤 요리를 만들까요?','음식 추천부터 양념 배합까지 대화로 함께 정해요.','AI KITCHEN ASSISTANT')}${banner(state.ai?.configured ? deviceStatus() : 'AI 설정 필요 · 서버에 API 키와 모델을 설정해 주세요.')}
  <div class="builder-layout"><section class="card ai-chat"><div class="chat-heading"><div><h2>한꼬집 AI 도우미</h2><p class="hint">대화는 새로고침하거나 브라우저를 닫으면 초기화됩니다.</p></div><button class="btn secondary" data-action="ai-reset" ${aiPending ? 'disabled' : ''}>새 대화</button></div><div id="ai-messages" class="chat-messages" aria-live="polite">${aiMessagesHTML()}</div><div class="chat-quick"><button class="chat-choice" data-action="ai-choice" data-message="오늘 뭐 먹을까?">오늘 뭐 먹지?</button><button class="chat-choice" data-action="ai-choice" data-message="양념 배합을 만들고 싶어.">양념 배합 만들기</button></div><form id="ai-chat-form" class="chat-form"><label class="sr-only" for="ai-message">메시지</label><input id="ai-message" name="message" maxlength="500" required placeholder="음식이나 양념에 대해 물어보세요" value="${esc(aiInput)}"><button class="btn primary" type="submit">보내기</button><span class="sr-only" id="ai-request-status" role="status"></span></form></section><aside class="card summary" id="blend-summary" aria-busy="${aiPending}">${aiSummary()}</aside></div>`;
}
function recipeCards() {
  const recipes = state.recipes.filter(r=>(!favoritesOnly || r.favorite) && r.name.toLowerCase().includes(search.toLowerCase()));
  return recipes.length ? `<div class="recipe-grid">${recipes.map(r=>`<article class="card recipe-card"><div class="recipe-top"><span class="recipe-type">${r.mode === 'AI' ? 'AI BLEND' : r.mode === 'DEMO' ? 'DEMO BLEND' : 'CUSTOM BLEND'}</span><button class="favorite ${r.favorite ? 'on' : ''}" data-action="favorite" data-id="${r.id}" aria-label="${esc(r.name)} 즐겨찾기 ${r.favorite ? '해제' : '등록'}" aria-pressed="${r.favorite}">${r.favorite ? '★' : '☆'}</button></div><h3>${esc(r.name)}</h3><p class="recipe-description">${r.servings}인분 · ${r.items.length}가지 재료 · ${fmt(r.items.reduce((a,i)=>a+i.grams,0))}g</p><p class="recipe-ingredients">${r.items.map(i=>`${esc(i.name)} ${fmt(i.grams)}g`).join(' · ')}</p><div class="recipe-buttons"><button class="btn primary" data-action="load-recipe" data-id="${r.id}">불러오기${icon('arrow')}</button><button class="btn secondary" data-action="load-recipe" data-id="${r.id}">수정</button><button class="btn ghost" data-action="delete-recipe" data-id="${r.id}">삭제</button></div></article>`).join('')}</div>` : empty(search || favoritesOnly ? '조건에 맞는 레시피가 없어요.' : '나만의 맛을 차곡차곡 모아 보세요.','AI 데모 배합이나 직접 만든 배합을 저장할 수 있어요.','custom','새 배합 만들기',true);
}
function recipes() {
  return `${heading('다시 찾고 싶은, 나만의 맛.','저장한 배합을 수정하고 자주 사용하는 레시피를 즐겨찾기 해보세요.','MY RECIPE COLLECTION')}<div class="toolbar"><input id="recipe-search" type="search" placeholder="레시피 이름 검색" aria-label="레시피 검색" value="${esc(search)}"><button class="btn secondary ${favoritesOnly ? 'active' : ''}" data-action="filter-favorites" aria-pressed="${favoritesOnly}">${favoritesOnly ? '★ 즐겨찾기만 보는 중' : '☆ 즐겨찾기만 보기'}</button><button class="btn primary" data-action="new-custom">${icon('plus')}새 레시피</button></div><div id="recipe-cards">${recipeCards()}</div>`;
}
function history() {
  const cards = state.jobs.map(j=>`<details class="card history-card" data-job-id="${esc(j.id)}">
    <summary><div><h3>${esc(j.name)}</h3><p class="date">${date(j.started)} · ${j.servings}인분 · ${j.items.length}가지 재료</p></div><span class="status-tag ${esc(j.status)}">${statusLabels[j.status]} · ${jobMode(j)}</span></summary>
    ${resultsTable(j)}
    ${j.error ? `<p class="hint">${esc(jobNote(j))}</p>` : ''}
    ${activeJob(j)
      ? `<div class="progress-actions"><button class="btn primary" data-action="view-job" data-id="${esc(j.id)}">진행 상태 보기 →</button></div>`
      : `<p class="hint">이력을 레시피로 저장하면 목표 중량이 복사됩니다.</p><div class="progress-actions"><button class="btn secondary" data-action="save-history" data-id="${esc(j.id)}">내 레시피에 저장</button><button class="btn danger" data-action="delete-history" data-id="${esc(j.id)}">이력 삭제</button></div>`}
  </details>`).join('');
  return `${heading('우리 주방의 맛있는 기록.','배합별 목표 중량과 계량 결과를 확인해 보세요.','BLENDING JOURNAL')}
    ${cards ? `<div class="history-list">${cards}</div>` : empty('아직 제조 기록이 없어요.','배합을 확인하고 계량을 시작해 보세요.','custom','첫 계량 시작하기',true)}`;
}
function resultsTable(job) {
  const rows = job.items.map(i => {
    const measured = Number.isFinite(i.actual);
    return `<tr><td>${esc(i.name)} <small>${esc(i.slot)}</small></td><td>${fmt(i.grams)}g</td>
      <td>${measured ? fmt(i.actual) + 'g' : '미측정'}</td><td>${measured ? fmt(i.actual - i.grams) + 'g' : '—'}</td></tr>`;
  }).join('');
  return `<table><thead><tr><th scope="col">재료 / 슬롯</th><th scope="col">목표</th><th scope="col">${job.demo === false ? '실측값' : '모의 계량값'}</th><th scope="col">차이</th></tr></thead><tbody>${rows}</tbody></table>`;
}
function jobNote(job) {
  if (job.stop_confirmed === false) return `${job.error || ''} Arduino의 정지 결과를 확인할 수 없습니다.`.trim();
  if (job.error) return job.error;
  if (job.phase === 'taring') return '빈 컵을 기준으로 영점을 맞추는 중입니다.';
  if (job.phase === 'settling') return '배출을 멈추고 무게가 안정되기를 기다리는 중입니다.';
  if (job.status === 'running') {
    const current = job.items.find(i => job.current_slot ? i.slot === job.current_slot : !i.done);
    const powderPhases = {
      homing: '분말통 이동부의 원점을 찾는 중입니다.',
      positioning: '분말통을 배출구 중앙으로 이동하는 중입니다.',
      checking: '분말통의 ToF 잔량을 확인하는 중입니다.',
      engaging: '서보가 결합부를 밀어 결합하는 중입니다.',
      disengaging: '배출을 멈추고 결합부를 물리는 중입니다.',
    };
    if (powderPhases[job.phase]) return current ? `${current.name} · ${powderPhases[job.phase]}` : powderPhases[job.phase];
    const live = Number.isFinite(job.live_g) ? ` · 현재 측정 ${fmt(job.live_g)}g` : '';
    return current ? `${current.name} · 목표 ${fmt(current.grams)}g${live}` : '계량 중입니다.';
  }
  if (job.status === 'completed') return '계량 결과를 제조 이력에 저장했습니다.';
  if (job.status === 'stopped') return '계량을 중단했습니다.';
  return statusLabels[job.status];
}
function progress() {
  const job = state.jobs.find(j=>j.id === activeJobId) || state.jobs.find(activeJob) || state.jobs[0];
  if (!job) return `${heading('계량 상태','진행 중인 배합과 결과를 확인하세요.','BLENDING STATION')}${empty('진행 중인 계량이 없어요.','직접 배합을 설정하고 계량을 시작해 보세요.','custom','배합 만들기',true)}`;
  activeJobId = job.id;
  return `${heading('계량 진행 상태','재료와 목표 중량을 확인해 보세요.','BLENDING STATION')}${banner()}
    <section class="card progress-card"><div class="status-circle">${icon(job.status === 'completed' ? 'check' : 'jar')}</div>
    <span class="status-tag ${esc(job.status)}">${statusLabels[job.status]} · ${jobMode(job)}</span>
    <h2 class="progress-title">${esc(job.name)}</h2><p class="subtitle">${esc(jobNote(job))}</p>
    <div class="progress-track"><span class="progress-value"></span></div>
    <div class="progress-overview"><span>${job.items.filter(i=>i.done).length} / ${job.items.length} 재료</span><strong>${job.progress}%</strong></div>
    ${resultsTable(job)}<div class="progress-actions">${activeJob(job)
      ? `<button class="btn danger" data-action="stop-job" data-id="${esc(job.id)}" ${job.status === 'stopping' ? 'disabled' : ''}>계량 중단하기</button>`
      : '<a class="btn secondary" href="#history">제조 이력 확인</a><button class="btn primary" data-action="new-custom">새 배합 만들기</button>'}</div></section>`;
}
function render() {
  if (!labels[page]) page = 'dashboard';
  // 자동 갱신 시에도 사용자가 펼쳐 둔 제조 결과를 유지합니다.
  const openJobs = new Set(Array.from(main.querySelectorAll('.history-card[open]'), card => card.dataset.jobId));
  navigation();
  main.innerHTML = ({dashboard,ingredients,custom,ai,recipes,history,progress}[page])();
  if (page === 'ai') syncAiView();
  if (page === 'history') {
    main.querySelectorAll('.history-card').forEach(card => {
      card.open = openJobs.has(card.dataset.jobId);
    });
  }
  if (page === 'progress') {
    const job = state.jobs.find(j=>j.id === activeJobId);
    if (job) document.querySelector('.progress-value')?.style.setProperty('width', `${job.progress}%`);
  }
}
function showModal(title, content, actions) {
  document.querySelector('#modal-content').innerHTML = `<div class="modal-top"><h2>${title}</h2><button class="modal-close" data-action="close-modal" aria-label="닫기">×</button></div>${content}<p class="error-text" id="modal-error" role="alert"></p>${actions || ''}`;
  modal.showModal();
}
function draftFromForm() {
  const form = document.querySelector('#custom-form');
  if (!form) return draft;
  if (!form.reportValidity()) throw new Error('입력한 이름, 인분과 중량을 확인해 주세요.');
  const data = new FormData(form);
  const items = state.slots.filter(s=>s.name && Number(data.get(s.id)) > 0).map(s=>({slot:s.id,name:s.name,kind:s.kind,revision:s.revision,grams:Number(data.get(s.id))}));
  draft = {...draft,name:data.get('name').trim(),servings:Number(data.get('servings')),items};
  return draft;
}
function verifyRecipe(recipe) {
  if (!recipe?.items.length) throw new Error('한 가지 이상의 재료 중량을 입력해 주세요.');
  if (!recipe.name || !Number.isInteger(recipe.servings) || recipe.servings<1 || recipe.servings>20) throw new Error('레시피 이름과 인분(1~20)을 확인해 주세요.');
  if (recipe.items.some(i=>!Number.isFinite(i.grams)||i.grams<.1||i.grams>100) || recipe.items.reduce((a,i)=>a+i.grams,0)>300) throw new Error('재료별 0.1~100g, 총 300g 이하로 입력해 주세요.');
  for (const item of recipe.items) {
    const slot = state.slots.find(s=>s.id === item.slot);
    if (!slot || slot.name !== item.name || slot.revision !== item.revision || slot.kind !== item.kind) throw new Error('재료가 변경되었습니다. CUSTOM 화면에서 현재 재료로 배합을 확인해 주세요.');
  }
}
function verifyDraft() {
  if (page === 'custom') draftFromForm();
  verifyRecipe(draft);
}
async function action(button) {
  const id = button.dataset.id;
  const kind = button.dataset.action;
  if (kind === 'navigate') return navigate(button.dataset.target);
  if (kind === 'view-job') { activeJobId = id; return navigate('progress'); }
  if (kind === 'control-settings') {
    showModal('장치 제어 키', `<form id="control-form" class="form-stack">
      <p class="modal-description">실제 계량을 시작하거나 중단하려면 서버에서 설정한 제어 키를 입력하세요.</p>
      <label class="field">제어 키<input type="password" name="controlKey" maxlength="128" autocomplete="off"></label>
      <button type="submit" class="btn primary">적용</button></form>`);
    return;
  }
  if (kind === 'new-custom') { freshDraft(); return navigate('custom'); }
  if (kind === 'close-modal') { modal.close(); return; }
  if (kind === 'retry') { await refresh(); return render(); }
  if (kind === 'ai-choice') return sendAiMessage(button.dataset.message);
  if (kind === 'ai-preview') { document.querySelector('#blend-summary')?.scrollIntoView({behavior:'smooth',block:'start'}); return; }
  if (kind === 'ai-reset') {
    if (aiPending || aiActionBusy) return;
    aiMessages=[]; aiHistory=[]; aiRecipe=null; aiSavedId=null; aiInput='';
    syncAiView(); return;
  }
  if (kind === 'edit-slot') {
    const slot = state.slots.find(s=>s.id === id);
    const allowed = slot.operator_available ?? slot.available;
    showModal(`${id} 재료 수정`, `<p class="modal-description">${slot.kind === 'liquid' ? '액체' : '분말'} 슬롯입니다. 재료를 바꾸면 저장된 배합의 재확인이 필요해요.</p>
      <form id="slot-form" class="form-stack" data-id="${esc(id)}">
        <label class="field">재료 이름<input name="name" maxlength="30" value="${esc(slot.name)}" placeholder="비워 두면 미등록 슬롯이 됩니다"></label>
        <label class="field">${usesArduino() ? '슬롯 사용 설정' : '재료 상태'}<select name="available">
          <option value="true" ${allowed ? 'selected' : ''}>${usesArduino() ? '사용 허용' : '사용 가능'}</option>
          <option value="false" ${!allowed ? 'selected' : ''}>${usesArduino() ? '사용 중지' : '보충 필요'}</option>
        </select></label><button type="submit" class="btn primary">변경 저장</button>
      </form>`);
    return;
  }
  if (kind === 'save-recipe') {
    if (page === 'ai') {
      if (aiPending || !aiRecipe) return;
      const selected = aiRecipe;
      const body = structuredClone(selected);
      verifyRecipe(body);
      const recipe = await api(`/recipes${aiSavedId ? '/'+aiSavedId : ''}`, aiSavedId ? 'PUT' : 'POST', body);
      if (aiRecipe === selected) { Object.assign(aiRecipe, recipe); aiSavedId=recipe.id; }
      await refresh();
      if (page === 'ai') syncAiView();
      navigation(); toast('내 레시피에 저장했어요.'); return;
    }
    verifyDraft();
    const recipe = await api(`/recipes${draftId ? '/'+draftId : ''}`, draftId ? 'PUT' : 'POST', draft);
    draftId = recipe.id; draft = recipe; await refresh();
    if (page === 'custom') document.querySelector('#blend-summary').innerHTML = summary(draft);
    navigation(); toast('내 레시피에 저장했어요.'); return;
  }
  if (kind === 'load-recipe') {
    draft = structuredClone(state.recipes.find(r=>r.id === id)); draftId = id; return navigate('custom');
  }
  if (kind === 'favorite') {
    const recipe = state.recipes.find(r=>r.id === id);
    const favorite = !recipe.favorite;
    const updated = await api(`/recipes/${id}/favorite`, 'PATCH', {favorite});
    if (draftId === id && draft) draft.favorite = updated.favorite;
    if (aiSavedId === id && aiRecipe) aiRecipe.favorite = updated.favorite;
    await refresh(); render();
    toast(favorite ? '즐겨찾기에 등록했어요.' : '즐겨찾기를 해제했어요.'); return;
  }
  if (kind === 'filter-favorites') { favoritesOnly = !favoritesOnly; render(); return; }
  if (kind === 'delete-recipe') {
    const recipe = state.recipes.find(r=>r.id === id);
    showModal('레시피를 삭제할까요?', `<p class="modal-description">‘${esc(recipe.name)}’ 배합이 삭제됩니다. 기존 제조 이력은 유지됩니다.</p>`, `<div class="modal-actions"><button class="btn secondary" data-action="close-modal">취소</button><button class="btn danger" data-action="delete-confirmed" data-id="${id}">삭제하기</button></div>`); return;
  }
  if (kind === 'delete-confirmed') {
    await api(`/recipes/${id}`,'DELETE'); if (draftId === id) {draftId=null;draft=null;} if (aiSavedId === id) aiSavedId=null; modal.close(); await refresh(); render(); toast('레시피를 삭제했어요.'); return;
  }
  if (kind === 'save-history') {
    await api(`/jobs/${id}/recipe`, 'POST', {});
    await refresh(); render(); toast('목표 중량을 내 레시피에 저장했어요.'); return;
  }
  if (kind === 'delete-history') {
    showModal('제조 이력을 삭제할까요?', '<p class="modal-description">이력 목록에서 삭제되며 복구할 수 없습니다. 저장한 레시피는 유지됩니다.</p>', `<div class="modal-actions"><button class="btn secondary" data-action="close-modal">취소</button><button class="btn danger" data-action="delete-history-confirmed" data-id="${id}">삭제하기</button></div>`); return;
  }
  if (kind === 'delete-history-confirmed') {
    await api(`/jobs/${id}`, 'DELETE');
    modal.close(); await refresh(); render(); toast('제조 이력을 삭제했어요.'); return;
  }
  if (kind === 'confirm') {
    const sourcePage = page;
    if (sourcePage === 'ai' && (aiPending || !aiRecipe)) return;
    if (sourcePage !== 'ai') verifyDraft();
    let selected = sourcePage === 'ai' ? structuredClone(aiRecipe) : null;
    if (selected) verifyRecipe(selected);
    await refresh();
    if (page !== sourcePage) return;
    if (sourcePage === 'ai') verifyRecipe(selected);
    else { verifyDraft(); selected = structuredClone(draft); }
    if (usesArduino() && !state.device.ready) throw new Error(deviceStatus());
    if (usesArduino() && !controlKey) throw new Error('화면 상단의 제어 키를 먼저 입력해 주세요.');
    const unavailable = selected.items.find(i=>!state.slots.find(s=>s.id === i.slot)?.available);
    if (unavailable) throw new Error(`${unavailable.name}: 슬롯 설정과 재료 상태를 확인해 주세요.`);
    approvalRecipe = selected;
    approvalMode = usesArduino() ? 'uart' : 'demo';
    requestKey = Array.from(crypto.getRandomValues(new Uint8Array(24)), b => b.toString(16).padStart(2, '0')).join('');
    const real = approvalMode === 'uart';
    const confirmation = real
      ? '빈 컵과 목표 중량을 확인했으며, 실제 장치 작동을 승인합니다.'
      : '목표 중량을 확인했으며 모의 계량을 승인합니다.';
    showModal(real ? '실계량 최종 승인' : '데모 계량 최종 승인',
      `<p class="modal-description">${esc(selected.name)} · ${selected.servings}인분</p>
      ${selected.items.map(i=>`<div class="summary-line"><span>${esc(i.name)} · ${esc(i.slot)}</span><strong>${fmt(i.grams)}g</strong></div>`).join('')}
      <label class="check-row"><input id="approve" type="checkbox"><span>${confirmation}</span></label>`,
      '<div class="modal-actions"><button class="btn secondary" data-action="close-modal">취소</button><button class="btn primary" data-action="start-job" disabled>승인하고 시작</button></div>');
    return;
  }
  if (kind === 'start-job') {
    if (!document.querySelector('#approve')?.checked || submitting) return;
    if (!approvalRecipe) throw new Error('승인할 배합을 다시 확인해 주세요.');
    submitting = true;
    try {
      const job = await api('/jobs','POST',{approved:true,request_key:requestKey,recipe:approvalRecipe,device_mode:approvalMode});
      activeJobId = job.id; modal.close(); await refresh(); navigate('progress');
      toast(job.demo === false ? '제조 요청을 접수했어요.' : '데모 계량을 시작했어요.');
    } finally { submitting = false; }
    return;
  }
  if (kind === 'stop-job') {
    const job = await api(`/jobs/${id}/stop`,'POST',{});
    await refresh();
    render();
    toast(job.status === 'stopped' ? '계량을 중단했어요.' : statusLabels[job.status]);
  }
}
document.addEventListener('click', async event => {
  const button = event.target.closest('button[data-action]');
  if (!button || button.disabled) return;
  const aiAction = page === 'ai' && ['save-recipe', 'confirm'].includes(button.dataset.action);
  if (aiAction && (aiPending || aiActionBusy)) return;
  if (aiAction) { aiActionBusy = true; syncAiView(); }
  button.disabled = true;
  try { await action(button); }
  catch (error) { if (!aiAction && modal.open) document.querySelector('#modal-error').textContent=error.message; else toast(error.message); }
  finally {
    if (aiAction) { aiActionBusy = false; syncAiView(); }
    else if (button.isConnected) button.disabled=false;
  }
});
document.addEventListener('change', event => {
  if (event.target.id === 'approve') document.querySelector('[data-action="start-job"]').disabled = !event.target.checked;
});
document.addEventListener('input', event => {
  if (event.target.id === 'ai-message') aiInput = event.target.value;
  if (event.target.id === 'recipe-search') { search=event.target.value; document.querySelector('#recipe-cards').innerHTML=recipeCards(); }
  if (event.target.closest('#custom-form')) {
    // Never erase a stale recipe's identity before the user explicitly reviews it.
    const form = document.querySelector('#custom-form');
    if (form.checkValidity()) { draftFromForm(); document.querySelector('#blend-summary').innerHTML=summary(draft); }
  }
});
document.addEventListener('submit', async event => {
  if (!['custom-form','ai-chat-form','slot-form','control-form'].includes(event.target.id)) return;
  event.preventDefault();
  const form = event.target;
  if (form.id === 'control-form') {
    controlKey = form.elements.controlKey.value.trim();
    form.reset();
    modal.close();
    toast(controlKey ? '제어 키를 적용했어요.' : '제어 키를 지웠어요.');
    return;
  }
  if (form.id === 'ai-chat-form') { await sendAiMessage(form.elements.message.value); return; }
  const submit = form.querySelector('[type="submit"]');
  if (submit.disabled) return;
  submit.disabled = true;
  try {
    if (form.id === 'custom-form') { verifyDraft(); document.querySelector('#blend-summary').innerHTML=summary(draft); toast('배합을 확인했어요. 저장하거나 계량을 시작하세요.'); }
    if (form.id === 'slot-form') {
      const data = new FormData(form); await api(`/slots/${form.dataset.id}`,'PUT',{name:data.get('name'),available:data.get('available') === 'true'});
      await refresh(); modal.close(); render(); toast('재료 정보를 저장했어요.');
    }
  } catch (error) {
    if (modal.open) document.querySelector('#modal-error').textContent=error.message;
    else toast(error.message);
  } finally { if (submit.isConnected) submit.disabled=false; }
});
modal.addEventListener('click', event => { if (event.target === modal) {const r=modal.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom) modal.close();} });
window.addEventListener('hashchange', async () => {
  page=location.hash.slice(1)||'dashboard';
  try {await refresh();render(); window.scrollTo({top:0});main.focus({preventScroll:true});} catch(e){toast(e.message);}
});
async function init() {
  try { await refresh(); render(); }
  catch (error) { main.innerHTML=`<section class="card error-panel"><h1>주방에 연결하지 못했어요.</h1><p>${esc(error.message)}</p><button class="btn primary" data-action="retry">다시 연결하기</button></section>`; }
}
await init();
setInterval(async () => {
  if (refreshing || document.hidden || modal.open) return;
  refreshing=true;
  try {
    const previous=state.jobs.find(j=>j.id === activeJobId)?.status;
    const wasRunning=state.jobs.some(activeJob);
    const previousSlots=JSON.stringify(state.slots);
    await refresh();
    if (page === 'progress') {
      render();
      if (previous === 'running' && state.jobs.find(j=>j.id===activeJobId)?.status==='completed') toast('계량을 완료했어요.');
    } else if ((['history', 'dashboard'].includes(page) && (wasRunning || state.jobs.some(activeJob)))
               || (['dashboard', 'ingredients'].includes(page) && JSON.stringify(state.slots) !== previousSlots)) {
      render();
    }
  } catch (error) { if (page === 'progress') toast(error.message); }
  finally {refreshing=false;}
}, 1000);
