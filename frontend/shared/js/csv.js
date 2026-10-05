export function rowsToCsv(rows){
  if(!Array.isArray(rows)||!rows.length)return '';
  const headers=[...new Set(rows.flatMap(r=>Object.keys(r||{})))];
  const esc=v=>{if(v===null||v===undefined)return '';const s=typeof v==='object'?JSON.stringify(v):String(v);return /[",\n\r]/.test(s)?'"'+s.replace(/"/g,'""')+'"':s};
  return [headers.map(esc).join(','),...rows.map(r=>headers.map(h=>esc(r?.[h])).join(','))].join('\r\n');
}
export function downloadCsv(filename,rows){
  const csv=rowsToCsv(rows); if(!csv){alert('No records available for this export.');return;}
  const blob=new Blob([csv],{type:'text/csv;charset=utf-8;'}); const url=URL.createObjectURL(blob);
  const a=document.createElement('a');a.href=url;a.download=filename;a.click();URL.revokeObjectURL(url);
}
export function dateRange(from,to){return {p_from:from?.value||new Date().toISOString().slice(0,10),p_to:to?.value||new Date().toISOString().slice(0,10)}}
