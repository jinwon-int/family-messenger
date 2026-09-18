// Matrix HTML is untrusted even after E2EE decryption. Sanitize to a small
// text-only subset: no remote images, styles, widgets or sender-defined classes.
import DOMPurify from 'dompurify';

const TAGS = ['p', 'div', 'br', 'strong', 'b', 'em', 'i', 'u', 's', 'del', 'code', 'pre',
  'blockquote', 'ul', 'ol', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr',
  'a', 'table', 'thead', 'tbody', 'tr', 'th', 'td'];

/** Returns a safe fragment, or null so the caller can show the plain body. */
export function richMessageFragment(html) {
  if (typeof html !== 'string' || html.length > 100_000 || !DOMPurify.isSupported) return null;
  const fragment = DOMPurify.sanitize(html, {
    ALLOWED_TAGS: TAGS,
    ALLOWED_ATTR: ['href', 'start', 'value'],
    ALLOW_DATA_ATTR: false,
    ALLOW_ARIA_ATTR: false,
    RETURN_DOM_FRAGMENT: true,
  });
  if (!fragment.textContent.trim()) return null;
  for (const node of fragment.querySelectorAll('[start], [value]')) {
    for (const attr of ['start', 'value']) {
      const tag = attr === 'start' ? 'OL' : 'LI';
      if (node.tagName !== tag || !/^-?\d{1,9}$/.test(node.getAttribute(attr) ?? '')) node.removeAttribute(attr);
    }
  }
  for (const link of fragment.querySelectorAll('a')) {
    const href = link.getAttribute('href');
    // Absolute web/mail links only; reject relative URLs and obfuscated schemes.
    if (!href || !/^(https?:\/\/|mailto:)/i.test(href) || /[\u0000-\u0020\u007f]/.test(href)) {
      link.removeAttribute('href');
      continue;
    }
    link.setAttribute('target', '_blank');
    link.setAttribute('rel', 'noopener noreferrer');
  }
  return fragment;
}
