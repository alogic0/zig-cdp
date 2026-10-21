({
  query(q) {
    if (q.selector !== null) return [...document.querySelectorAll(q.selector)];
    const norm = s => (s || '').replace(/\s+/g, ' ').trim();
    const nodes = [...document.querySelectorAll('*')].filter(n => norm(n.textContent) === norm(q.text));
    return nodes.filter(n => !nodes.some(child => child !== n && n.contains(child)));
  },
  info() {
    const style = getComputedStyle(this);
    return {
      visible: this.isConnected && this.getClientRects().length > 0 && style.display !== 'none' && style.visibility !== 'hidden' && style.visibility !== 'collapse',
      disabled: this.matches(':disabled') || !!this.closest('[aria-disabled="true"],[inert]'),
      readonly: !!this.readOnly
    };
  },
  point() {
    if (this.matches(':disabled') || this.closest('[aria-disabled="true"],[inert]')) return {reason:'disabled'};
    this.scrollIntoView({block:'center', inline:'center'});
    const r = this.getBoundingClientRect(), style = getComputedStyle(this);
    if (!this.isConnected || !r.width || !r.height || style.visibility !== 'visible' || style.display === 'none') return {reason:'hidden'};
    const left=Math.max(0,r.left), right=Math.min(innerWidth,r.right);
    const top=Math.max(0,r.top), bottom=Math.min(innerHeight,r.bottom);
    if (left>=right || top>=bottom) return {reason:'hidden'};
    const x=(left+right)/2, y=(top+bottom)/2, hit=document.elementFromPoint(x,y);
    return hit && (hit===this || this.contains(hit)) ? {x,y} : {reason:'covered'};
  },
  prepareFill() {
    if (this.matches(':disabled') || this.closest('[aria-disabled="true"],[inert]')) return 'disabled';
    if (this.readOnly) return 'readonly';
    if (!this.isContentEditable && this.tagName !== 'TEXTAREA' &&
        !(this.tagName === 'INPUT' && ['text','email','password','search','tel','url'].includes(this.type))) return 'unsupported';
    this.focus();
    if (this.isContentEditable) {
      const range=document.createRange(); range.selectNodeContents(this);
      const selection=getSelection(); selection.removeAllRanges(); selection.addRange(range);
    } else this.select();
    return '';
  },
  select(value) {
    if (this.tagName!=='SELECT' || this.multiple || this.matches(':disabled') || this.closest('[aria-disabled="true"],[inert]')) return false;
    const option=[...this.options].find(o=>o.value===value && !o.disabled && !o.closest('optgroup[disabled]'));
    if (!option) return false;
    this.value=value;
    this.dispatchEvent(new Event('input',{bubbles:true}));
    this.dispatchEvent(new Event('change',{bubbles:true}));
    return true;
  },
  read(limit) {
    const text=this.innerText || '', encoder=new TextEncoder();
    const total=encoder.encode(text).length;
    let bytes=0, clipped='';
    for (const character of text) {
      const size=encoder.encode(character).length;
      if (bytes+size>limit) break;
      clipped+=character; bytes+=size;
    }
    return {text:clipped,truncated:bytes<total,total_bytes:total,returned_bytes:bytes};
  }
})
