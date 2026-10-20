(() => {
  const normalize = s => (s || '').replace(/\s+/g, ' ').trim();
  const visible = n => !!n?.isConnected && n.getClientRects().length > 0 && getComputedStyle(n).visibility !== 'hidden' && getComputedStyle(n).display !== 'none';
  const accessible = n => {
    const refs = n.getAttribute('aria-labelledby');
    if (refs) return normalize(refs.split(/\s+/).map(id => document.getElementById(id)?.textContent || '').join(' '));
    const label = n.getAttribute('aria-label'); if (label) return normalize(label);
    if (n.labels?.length) return normalize([...n.labels].map(l => l.textContent).join(' '));
    return normalize(n.getAttribute('alt') || (n.tagName === 'INPUT' && ['button','submit'].includes(n.type) ? n.value : n.innerText || n.textContent));
  };
  const role = n => n.getAttribute('role') || ({BUTTON:'button',A:n.hasAttribute('href')?'link':'',H1:'heading',H2:'heading',H3:'heading',H4:'heading',TABLE:'table',SELECT:n.multiple?'listbox':'combobox',OPTION:'option',TEXTAREA:'textbox',DIALOG:'dialog',PROGRESS:'progressbar',SECTION:n.hasAttribute('aria-label')?'region':'',FIELDSET:'group',INPUT:({checkbox:'checkbox',radio:'radio',search:'searchbox',button:'button',submit:'button'})[n.type] || 'textbox'})[n.tagName] || '';
  window.__cdp = {
    handles: [], visible, accessible,
    css: (root, selector) => [...root.querySelectorAll(selector)],
    one: ns => { if(ns.length!==1 || !ns[0]) throw Error('locator must resolve exactly once'); return ns[0]; },
    role: (root, o) => [...root.querySelectorAll('*')].filter(n => role(n)===o.role && visible(n) && !n.closest('[aria-hidden="true"]') && (o.name===null || (o.regex ? new RegExp(o.name).test(accessible(n)) : o.exact ? accessible(n)===o.name : accessible(n).includes(o.name)))),
    label: (root, name) => [...root.querySelectorAll('input,select,textarea,button')].filter(n=>accessible(n)===name),
    text: (root, name, regex) => {
      const matches = [...root.querySelectorAll('*')].filter(n=>visible(n) && (regex ? new RegExp(name).test(normalize(n.textContent)) : normalize(n.textContent)===name));
      return matches.filter(n=>!matches.some(child=>child!==n && n.contains(child)));
    },
    point: n => {
      if(!visible(n) || n.disabled || n.getAttribute('aria-disabled')==='true' || n.closest('[inert]')) return null;
      n.scrollIntoView({block:'center',inline:'center'});
      const r=n.getBoundingClientRect(); const x=Math.max(0,Math.min(innerWidth,r.right)+Math.max(0,r.left))/2, y=(Math.min(innerHeight,r.bottom)+Math.max(0,r.top))/2;
      const hit=document.elementFromPoint(x,y);
      return hit && (n===hit||n.contains(hit)) ? {x,y} : null;
    }
  };
  return true;
})()
