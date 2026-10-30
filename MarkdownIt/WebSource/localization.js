/* Translations are generated from the app's String Catalog. */
(() => {
  const catalogs = /* localization-data */ {};
  const preferred = window.MarkdownItLanguages || [];
  const language = preferred.find(value => Object.hasOwn(catalogs, value)) || 'en';
  const strings = catalogs[language] || {};
  const seconds = new Intl.NumberFormat(language, { style: 'unit', unit: 'second', unitDisplay: 'long' });
  function t(key, values = {}) {
    const text = Object.hasOwn(strings, key) ? strings[key] : key;
    return text.replace(/\{([a-zA-Z]\w*)\}/g, (token, name) => Object.hasOwn(values, name) ? String(values[name]) : token);
  }
  function apply(root) {
    const nodes = [root, ...root.querySelectorAll('[data-l10n], [data-l10n-aria-label]')];
    nodes.forEach(node => {
      if (node.dataset?.l10n) node.textContent = t(node.dataset.l10n);
      if (node.dataset?.l10nAriaLabel) node.setAttribute('aria-label', t(node.dataset.l10nAriaLabel));
    });
  }
  window.MarkdownItLocalization = Object.freeze({ t, apply, language, formatSeconds: value => seconds.format(value) });
  document.documentElement.lang = language;
  apply(document);
})();
