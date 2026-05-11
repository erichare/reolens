// reolens.io — minimal client-side polish.
//
// Two tiny behaviors:
//   1. Copy-to-clipboard buttons (look for [data-copy="<id>"]).
//   2. Smooth-scroll for in-page nav anchors (skipped if the user has
//      requested reduced motion — respect their setting).

(() => {
  // ── copy buttons ────────────────────────────────────────────────
  document.querySelectorAll('[data-copy]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const target = document.getElementById(btn.dataset.copy);
      if (!target) return;
      const text = target.textContent.trim();
      try {
        await navigator.clipboard.writeText(text);
        const original = btn.textContent;
        btn.textContent = 'Copied';
        btn.classList.add('copied');
        setTimeout(() => {
          btn.textContent = original;
          btn.classList.remove('copied');
        }, 1500);
      } catch {
        // Older browsers — fall back to selecting the text so the
        // user can ⌘C themselves.
        const range = document.createRange();
        range.selectNodeContents(target);
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      }
    });
  });

  // ── smooth scroll ────────────────────────────────────────────────
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (!reduceMotion) {
    document.querySelectorAll('a[href^="#"]').forEach((a) => {
      a.addEventListener('click', (e) => {
        const id = a.getAttribute('href').slice(1);
        if (!id) return;
        const target = document.getElementById(id);
        if (!target) return;
        e.preventDefault();
        target.scrollIntoView({ behavior: 'smooth', block: 'start' });
        history.replaceState(null, '', `#${id}`);
      });
    });
  }
})();
