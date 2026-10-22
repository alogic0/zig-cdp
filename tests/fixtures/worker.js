console.log('dedicated startup');
self.onmessage=async e=>{
 const {label,nested}=e.data;
 if(nested){const child=new Worker('/nested-worker.js');child.onmessage=()=>{console.log('parent nested complete');postMessage('nested complete')};child.postMessage(label);return;}
 const r=await fetch('/api/save',{method:'POST',body:label});
 console.log(label,await r.text());postMessage(label);
 setTimeout(()=>{throw new Error('worker exception '+label)},0);
};
