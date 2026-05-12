// reolens.io — minimal client-side polish.
//
// Three tiny behaviors:
//   1. Copy-to-clipboard buttons (look for [data-copy="<id>"]).
//   2. Smooth-scroll for in-page nav anchors (skipped if the user has
//      requested reduced motion — respect their setting).
//   3. Rewrite [data-latest-dmg] anchors to point at the *versioned*
//      DMG of the latest GitHub release, so the file the user
//      downloads is named `Reolens-X.Y.Z.dmg` instead of the bare
//      `Reolens.dmg` permalink. Falls back to the static permalink
//      when the GitHub API is unreachable, so the link is never
//      broken.

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

  // ── versioned download link ──────────────────────────────────────
  // The release workflow uploads two DMG names per release:
  //   - `Reolens-X.Y.Z.dmg` (versioned — what we want users to download)
  //   - `Reolens.dmg` (version-less alias — what the static HTML links to)
  // The static link works always but downloads as a featureless
  // "Reolens.dmg" with no version in the filename. Hitting the
  // unauthenticated GitHub API on page load is cheap (60 req/h per IP,
  // no token needed) and lets us rewrite the link to the versioned
  // asset before the user clicks. If the API is unreachable or
  // rate-limited, the fallback href stays as the unversioned permalink
  // so the button is never dead.
  const latestApi = 'https://api.github.com/repos/jestatsio/reolens/releases/latest';
  const dmgPattern = /^Reolens-\d+\.\d+\.\d+\.dmg$/;
  fetch(latestApi, { headers: { Accept: 'application/vnd.github+json' } })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((release) => {
      const asset = (release.assets || []).find((a) => dmgPattern.test(a.name));
      if (!asset) return;
      const url = asset.browser_download_url;
      const tag = release.tag_name || '';
      document.querySelectorAll('[data-latest-dmg]').forEach((a) => {
        a.href = url;
        if (a.dataset.versionLabel) {
          const label = a.querySelector('[data-version-label]');
          if (label) label.textContent = tag;
        }
      });
    })
    .catch(() => {
      // Silent fallback to the static href — the user still gets a
      // working download, just without the version in the filename.
    });
})();
