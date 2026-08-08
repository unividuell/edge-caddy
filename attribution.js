/*
 * Geo data in this report comes from DB-IP's free IP-to-Country Lite database,
 * which is licensed CC-BY 4.0 and requires a visible attribution link on pages
 * that display its results. See docs/superpowers/specs/2026-08-08-goaccess-geo-design.md.
 *
 * GoAccess references this file as <script src='attribution.js'>, resolved by the
 * browser against the report URL — so it must sit next to index.html in report/.
 */
(function () {
  function addAttribution() {
    if (document.getElementById('dbip-attribution')) {
      return;
    }
    var p = document.createElement('p');
    p.id = 'dbip-attribution';
    p.style.textAlign = 'center';
    p.style.padding = '1em 0';
    p.style.fontSize = '0.85em';
    p.style.opacity = '0.7';

    var a = document.createElement('a');
    a.href = 'https://db-ip.com';
    a.rel = 'noopener';
    a.textContent = 'IP Geolocation by DB-IP';

    p.appendChild(a);
    document.body.appendChild(p);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', addAttribution);
  } else {
    addAttribution();
  }
})();
