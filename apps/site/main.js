// Maple Factory — marketing site

const root = document.documentElement;
root.classList.add('js');
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

// Theme: follows the system until you pick one, then remembers it.
const toggle = document.querySelector('.theme-toggle');
const systemDark = matchMedia('(prefers-color-scheme: dark)');
const isDark = () => (root.dataset.theme ? root.dataset.theme === 'dark' : systemDark.matches);
toggle.addEventListener('click', () => {
  const next = isDark() ? 'light' : 'dark';
  root.dataset.theme = next;
  try { localStorage.setItem('mf-theme', next); } catch (e) {}
  syncThemeColor();
});
function syncThemeColor() {
  const color = getComputedStyle(root).getPropertyValue('--bg').trim();
  document.querySelectorAll('meta[name="theme-color"]').forEach((m) => m.setAttribute('content', color));
}
if (root.dataset.theme) syncThemeColor();

// Nav border once you've scrolled.
const nav = document.querySelector('.nav');
const onScroll = () => nav.classList.toggle('scrolled', scrollY > 8);
addEventListener('scroll', onScroll, { passive: true });
onScroll();

// Reveal on scroll, staggered within each group.
const io = new IntersectionObserver((entries) => {
  for (const e of entries) {
    if (!e.isIntersecting) continue;
    e.target.classList.add('in');
    io.unobserve(e.target);
  }
}, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
document.querySelectorAll('.reveal').forEach((el) => {
  const siblings = [...el.parentElement.children].filter((c) => c.classList.contains('reveal'));
  el.style.setProperty('--d', `${Math.min(siblings.indexOf(el), 5) * 0.07}s`);
  io.observe(el);
});

// Hero task card: one task, plan to merge, on a loop.
const STAGES = [
  { key: 'planning', label: 'Planning', lines: [
    ['planner', 'Reading the repo…'],
    ['planner', 'Wrote a plan: 4 steps, 1 mockup'],
  ] },
  { key: 'awaiting', label: 'Awaiting you', lines: [
    ['factory', 'Plan ready for review', ''],
    ['AF', 'Approved. Stream it, please.'],
  ] },
  { key: 'building', label: 'Building', lines: [
    ['builder', 'Session 3 on studio-mac'],
    ['builder', '12 files changed · 214 tests', 'ok'],
  ] },
  { key: 'reviewing', label: 'Reviewing', lines: [
    ['reviewer', '2 notes, both resolved'],
    ['ci', 'checks 14 / 14 passed', 'ok'],
  ] },
  { key: 'merged', label: 'Merged', lines: [
    ['github', 'Squash-merged #388 into main', 'ok'],
  ] },
];

const card = document.getElementById('task-card');
if (card) {
  const status = card.querySelector('.status');
  const steps = [...card.querySelectorAll('.stages li')];
  const log = card.querySelector('.task-log');
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));

  const addLine = ([who, what, kind]) => {
    const p = document.createElement('p');
    p.className = 'log-line' + (kind === '' ? ' ask' : '');
    p.innerHTML = `<span class="who"></span><span class="what"></span>`;
    p.querySelector('.who').textContent = who;
    const w = p.querySelector('.what');
    if (kind === 'ok') {
      const ok = document.createElement('span');
      ok.className = 'ok';
      ok.textContent = '✓ ';
      w.append(ok);
    }
    w.append(what);
    log.append(p);
    while (log.children.length > 5) log.firstElementChild.remove();
  };

  const show = (i) => {
    const s = STAGES[i];
    status.dataset.status = s.key;
    status.querySelector('b').textContent = s.label;
    steps.forEach((li, j) => {
      li.classList.toggle('done', j < i || (i === STAGES.length - 1 && j === i));
      li.classList.toggle('now', j === i && i !== STAGES.length - 1);
    });
  };

  if (reduced) {
    show(STAGES.length - 1);
    log.innerHTML = '';
    STAGES.forEach((s) => addLine(s.lines[s.lines.length - 1]));
  } else {
    (async function loop() {
      for (;;) {
        log.innerHTML = '';
        for (let i = 0; i < STAGES.length; i++) {
          show(i);
          for (const line of STAGES[i].lines) {
            addLine(line);
            await wait(1300);
          }
          await wait(500);
        }
        await wait(3200);
      }
    })();
  }
}

// Waitlist form. Posts to /api/waitlist (a Pages Function, not written yet).
const form = document.querySelector('.access-form');
const note = document.querySelector('.form-note');
form?.addEventListener('submit', async (e) => {
  e.preventDefault();
  const button = form.querySelector('button');
  button.disabled = true;
  try {
    const res = await fetch(form.action, { method: 'POST', body: new FormData(form) });
    if (!res.ok) throw new Error(res.statusText);
    form.hidden = true;
    note.classList.remove('err');
    note.textContent = 'You’re on the list. We’ll write when the sap’s running.';
  } catch {
    note.classList.add('err');
    note.textContent = 'That didn’t go through. Please try again in a moment.';
    button.disabled = false;
  }
  note.hidden = false;
});

document.getElementById('year').textContent = new Date().getFullYear();
