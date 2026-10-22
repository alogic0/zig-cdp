(()=>{const h={
  slot(n) {return n.assignedSlot || (h.scope && [...h.scope.querySelectorAll('slot')].find(s=>s.assignedNodes({flatten:true}).includes(n)));},
  parent(n) {return h.slot(n) || n.parentElement || n.getRootNode()?.host;},
  focused() {const n=this.activeElement || this.ownerDocument.activeElement; return !!n && (n.getRootNode()===this || h.elements(this).includes(n));},
  disabled(n) {for(;n;n=h.parent(n))if(n.matches(':disabled,[aria-disabled="true"],[inert]'))return true;return false;},
  elements(root) {
    const result=[...root.querySelectorAll('*')];
    for(const slot of root.querySelectorAll('slot'))for(const n of slot.assignedElements({flatten:true}))result.push(n,...n.querySelectorAll('*'));
    return [...new Set(result)];
  },
  hit(n,x,y) {
    for(let expected=n;expected;) {
      const root=h.slot(expected)?.getRootNode() || expected.getRootNode();
      const hit=root.elementFromPoint(x,y);
      if(!hit || !(hit===expected || expected.contains(hit)))return false;
      expected=root.host;
    }
    return true;
  },
  query(q) {
    if (q.selector !== null) { const found=[...this.querySelectorAll(q.selector)]; for(const n of h.elements(this))if(n.getRootNode()!==this && n.matches(q.selector))found.push(n); return [...new Set(found)]; }
    const norm = s => (s || '').replace(/\s+/g, ' ').trim();
    const nodes = h.elements(this).filter(n => norm(n.textContent) === norm(q.text));
    return nodes.filter(n => !nodes.some(child => child !== n && n.contains(child)));
  },
  info() {
    const style = getComputedStyle(this);
    return {
      visible: this.isConnected && this.getClientRects().length > 0 && style.display !== 'none' && style.visibility !== 'hidden' && style.visibility !== 'collapse',
      disabled: h.disabled(this),
      readonly: !!this.readOnly
    };
  },
  point(previous) {
    if (h.disabled(this)) return {reason:'disabled'};
    // A stalled compositor can return identical bounds while a CSS geometry
    // animation is running. Reject it even when two wall-clock samples match.
    const geometry = /^(transform|translate|rotate|scale|perspective|offsetPath|offsetDistance|offsetRotate|top|right|bottom|left|width|height|minWidth|maxWidth|minHeight|maxHeight|margin|padding|fontSize|lineHeight|letterSpacing|wordSpacing|flexBasis|gridTemplate)/;
    for (let n=this; n; n=h.parent(n)) {
      for (const animation of n.getAnimations()) {
        if (animation.playState==='running' && animation.effect?.getKeyframes().some(frame=>Object.keys(frame).some(key=>geometry.test(key)))) return {reason:'moving'};
      }
    }
    this.scrollIntoView({block:'center', inline:'center'});
    const r = this.getBoundingClientRect(), style = getComputedStyle(this);
    if (previous?.bounds && ['x','y','width','height'].some(key => Math.abs(previous.bounds[key]-r[key]) > 0.5)) return {reason:'moving'};
    if (!this.isConnected || !r.width || !r.height || style.visibility !== 'visible' || style.display === 'none') return {reason:'hidden'};
    const left=Math.max(0,r.left), right=Math.min(innerWidth,r.right);
    const top=Math.max(0,r.top), bottom=Math.min(innerHeight,r.bottom);
    if (left>=right || top>=bottom) return {reason:'hidden'};
    const x=(left+right)/2, y=(top+bottom)/2;
    return h.hit(this,x,y) ? {x,y,bounds:{x:r.x,y:r.y,width:r.width,height:r.height}} : {reason:'covered'};
  },
  framePoint(point) {
    if (!this.isConnected || !this.offsetWidth || !this.offsetHeight) return {reason:'hidden'};
    for(let n=this;n;n=h.parent(n)) {
      const m=new DOMMatrix(getComputedStyle(n).transform);
      if(!m.is2D || Math.abs(m.b)>0.0001 || Math.abs(m.c)>0.0001 || m.a<=0 || m.d<=0) return {reason:'transform'};
    }
    const r=this.getBoundingClientRect(), sx=r.width/this.offsetWidth, sy=r.height/this.offsetHeight;
    if(point.x<0 || point.y<0 || point.x>=this.clientWidth || point.y>=this.clientHeight) return {reason:'hidden'};
    const x=r.left+(this.clientLeft+point.x)*sx, y=r.top+(this.clientTop+point.y)*sy;
    if(x<0 || y<0 || x>=innerWidth || y>=innerHeight) return {reason:'hidden'};
    return h.hit(this,x,y) ? {x,y} : {reason:'covered'};
  },
  prepareFill() {
    if (h.disabled(this)) return 'disabled';
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
    if (this.tagName!=='SELECT' || this.multiple || h.disabled(this)) return false;
    const option=[...this.options].find(o=>o.value===value && !o.disabled && !o.closest('optgroup[disabled]'));
    if (!option) return false;
    this.value=value;
    this.dispatchEvent(new Event('input',{bubbles:true}));
    this.dispatchEvent(new Event('change',{bubbles:true}));
    return true;
  },
  read(limit) {
    const render=n=>n.nodeType===3?n.textContent:n.tagName==='SLOT'?n.assignedNodes({flatten:true}).map(render).join(' '):getComputedStyle(n).display==='none'?'':(n.innerText||'');
    const text=this.innerText ?? [...this.childNodes].map(render).join('\n'), encoder=new TextEncoder();
    const total=encoder.encode(text).length;
    let bytes=0, clipped='';
    for (const character of text) {
      const size=encoder.encode(character).length;
      if (bytes+size>limit) break;
      clipped+=character; bytes+=size;
    }
    return {text:clipped,truncated:bytes<total,total_bytes:total,returned_bytes:bytes};
  }
};return h})()
