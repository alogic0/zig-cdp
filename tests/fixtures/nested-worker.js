console.log('nested startup');
onmessage=async e=>{await fetch('/api/save',{method:'POST'}).then(r=>r.text());console.log('nested evidence '+e.data);postMessage(true);};
