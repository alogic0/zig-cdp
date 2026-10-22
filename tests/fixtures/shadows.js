(()=>{
 document.body.innerHTML='<input id=sentinel value=unchanged><button>Save</button><section id=host><button slot=extra id=slotted>Slotted</button></section><section id=other></section>';
 const markup='<style>:host{display:block;padding:12px}button,input{margin:5px}</style><label>Name <input id=name></label><button id=save>Save</button><output id=result></output><select id=choice><option value=one>One</option><option value=two>Two</option></select><input id=file type=file hidden><slot name=extra></slot><div id=nested></div><div id=source style="width:70px;height:30px;background:red">Drag</div><div id=destination style="width:70px;height:30px;background:blue;margin-left:120px">Drop</div>';
 window.parts=[];window.trusted=false;window.dropped=false;
 for(const [id,mode] of [['host','closed'],['other','open']]){
   const root=document.querySelector('#'+id).attachShadow({mode});root.innerHTML=markup;parts.push(root);
   root.querySelector('#save').onclick=e=>{trusted=e.isTrusted;root.querySelector('#result').textContent=root.querySelector('#name').value};
   const nested=root.querySelector('#nested').attachShadow({mode:mode==='closed'?'open':'closed'});nested.innerHTML='<button id=deep>Deep</button>';
   nested.querySelector('button').onclick=e=>{trusted=e.isTrusted};
   root.querySelector('#source').onmousedown=()=>window.dragging=true;
   root.querySelector('#destination').onmouseup=e=>window.dropped=window.dragging&&e.isTrusted;
 }
 document.querySelector('#slotted').onclick=e=>window.slottedTrusted=e.isTrusted;
 return true;
})()
