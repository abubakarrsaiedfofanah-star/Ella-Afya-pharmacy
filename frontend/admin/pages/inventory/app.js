import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';

const session=await requireUser(['admin']);
if(!session) throw new Error('Unauthorized');

const $=selector=>document.querySelector(selector);
const form=$('#form'),rows=$('#rows'),msg=$('#msg'),search=$('#search'),filter=$('#filter');
const csvFile=$('#csvFile'),csvMsg=$('#csvMsg'),csvPreview=$('#csvPreview'),importButton=$('#importCsv');
let medicines=[],csvRows=[];
const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
const localDate=()=>{const date=new Date();return `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`};
function validExpiryDate(value){
  if(!/^\d{4}-\d{2}-\d{2}$/.test(value))return false;
  const [year,month,day]=value.split('-').map(Number),date=new Date(Date.UTC(year,month-1,day));
  return date.getUTCFullYear()===year&&date.getUTCMonth()===month-1&&date.getUTCDate()===day&&value>=localDate();
}

async function load(){
  const {data,error}=await supabase.from('medicines').select('id,name,generic_name,brand,manufacturer,barcode,strength,dosage_form,selling_price,prescription_required,controlled_medicine,min_stock,reorder_level,inventory(quantity)').order('name');
  if(error){msg.textContent=error.message;return false}
  medicines=data||[];render();return true;
}
async function revealCatalogue(){
  search.value='';filter.value='all';
  const loaded=await load();
  document.querySelector('#medicineCatalog')?.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'start'});
  return loaded;
}
function render(){
  const query=search.value.toLowerCase(),mode=filter.value;
  rows.innerHTML=medicines.filter(item=>`${item.name} ${item.generic_name||''} ${item.barcode||''}`.toLowerCase().includes(query)).filter(item=>{
    const quantity=item.inventory?.[0]?.quantity??0;
    return mode==='low'?quantity<=item.min_stock:mode==='out'?quantity===0:mode==='rx'?item.prescription_required:true;
  }).map(item=>`<tr><td><b>${escapeHtml(item.name)}</b><br><small>${escapeHtml(item.generic_name||'')} ${escapeHtml(item.strength||'')}</small></td><td>${escapeHtml(item.barcode||'-')}</td><td>${escapeHtml(item.dosage_form||'-')}</td><td>KSh ${Number(item.selling_price).toLocaleString()}</td><td>${item.inventory?.[0]?.quantity??0}</td><td>${item.reorder_level}</td><td>${item.prescription_required?'Yes':'No'}</td><td>${item.controlled_medicine?'Yes':'No'}</td></tr>`).join('')||'<tr><td colspan="8">No medicines found.</td></tr>';
}
form.onsubmit=async event=>{
  event.preventDefault();const values=Object.fromEntries(new FormData(form));
  const quantity=Number(values.quantity);
  if(!Number.isInteger(quantity)||quantity<0){msg.textContent='Quantity must be a whole number of zero or more.';return}
  if(quantity>0&&(!values.batch_number.trim()||!validExpiryDate(values.expiry_date))){msg.textContent='For opening stock, enter a batch number and a valid expiry date that has not passed.';return}
  const {data,error}=await supabase.from('medicines').insert({name:values.name.trim(),generic_name:values.generic_name||null,brand:values.brand||null,manufacturer:values.manufacturer||null,barcode:values.barcode||null,strength:values.strength||null,dosage_form:values.dosage_form||null,unit:'unit',purchase_price:Number(values.purchase_price),selling_price:Number(values.selling_price),min_stock:Number(values.min_stock||0),reorder_level:Number(values.reorder_level||values.min_stock||0),prescription_required:values.prescription_required==='on',controlled_medicine:values.controlled_medicine==='on'}).select('id').single();
  if(error){msg.textContent=error.message;return}
  const stockResult=quantity>0
    ?await supabase.rpc('receive_stock',{p_supplier_name:'Opening stock',p_invoice_number:'Initial medicine setup',p_items:[{medicine_id:data.id,quantity,unit_cost:Number(values.purchase_price),batch_number:values.batch_number.trim(),expiry_date:values.expiry_date}]})
    :await supabase.from('inventory').insert({medicine_id:data.id,quantity:0});
  const stockError=stockResult.error;
  if(stockError){
    const {error:cleanupError}=await supabase.from('medicines').delete().eq('id',data.id);
    msg.textContent=cleanupError?`Inventory setup failed (${stockError.message}) and medicine cleanup failed (${cleanupError.message}). Contact an administrator.`:`Medicine was not added because inventory setup failed: ${stockError.message}`;
    await load();return;
  }
  msg.textContent='Medicine added.';
  form.reset();await revealCatalogue();
};
search.oninput=render;filter.onchange=render;

function parseCsv(text){
  const firstLine=text.split(/\r?\n/,1)[0]||'';
  let delimiter=',',highestCount=0;
  for(const candidate of [',',';','\t']){
    let count=0,insideQuotes=false;
    for(let index=0;index<firstLine.length;index++){
      const character=firstLine[index];
      if(character==='"'&&firstLine[index+1]==='"'){index++;continue}
      if(character==='"')insideQuotes=!insideQuotes;
      else if(character===candidate&&!insideQuotes)count++;
    }
    if(count>highestCount){highestCount=count;delimiter=candidate}
  }
  const table=[];let row=[],field='',quoted=false;
  for(let i=0;i<text.length;i++){
    const char=text[i];
    if(quoted){if(char==='"'&&text[i+1]==='"'){field+='"';i++}else if(char==='"')quoted=false;else field+=char}
    else if(char==='"'&&field==='')quoted=true;
    else if(char===delimiter){row.push(field);field=''}
    else if(char==='\n'){row.push(field);table.push(row);row=[];field=''}
    else if(char!=='\r')field+=char;
  }
  if(quoted)throw new Error('The CSV has an unclosed quoted field.');
  if(field!==''||row.length){row.push(field);table.push(row)}
  return table;
}
function truthy(value,label,rowNumber){
  if(value===''||value===undefined)return false;
  const normalized=String(value).trim().toLowerCase();
  if(['yes','true','1'].includes(normalized))return true;
  if(['no','false','0'].includes(normalized))return false;
  throw new Error(`Row ${rowNumber}: ${label} must be yes/no, true/false, or 1/0.`);
}
function numberValue(value,label,rowNumber,{integer=false,required=false}={}){
  if((value===undefined||String(value).trim()==='')){if(required)throw new Error(`Row ${rowNumber}: ${label} is required.`);return 0}
  const number=Number(value);
  if(!Number.isFinite(number)||number<0||(integer&&!Number.isInteger(number)))throw new Error(`Row ${rowNumber}: ${label} must be a valid ${integer?'whole':'non-negative'} number.`);
  return number;
}
function validateCsv(text){
  const data=parseCsv(text.replace(/^\uFEFF/,''));
  if(data.length<2)throw new Error('The CSV contains headers but no medicine rows.');
  const aliases={medicine:'name',medicine_name:'name',medication:'name',medication_name:'name',product_name:'name',item_name:'name',drug_name:'name',qty:'quantity',stock:'quantity',quantity_in_stock:'quantity',opening_stock:'quantity',opening_quantity:'quantity',buying_price:'purchase_price',purchase_cost:'purchase_price',cost_price:'purchase_price',unit_cost:'purchase_price',cost:'purchase_price',sale_price:'selling_price',sell_price:'selling_price',retail_price:'selling_price',batch_no:'batch_number',expiry:'expiry_date'};
  const headers=data[0].map(header=>{
    const normalized=header.replace(/^\uFEFF/,'').trim().toLowerCase().replace(/[^a-z0-9]+/g,'_').replace(/^_+|_+$/g,'');
    return aliases[normalized]||normalized;
  });
  if(headers.some(header=>!header))throw new Error('Every CSV column must have a header.');
  if(new Set(headers).size!==headers.length)throw new Error('The CSV has duplicate columns after normalizing their names.');
  if(!headers.includes('name'))throw new Error('Medicine name column not found. Use the header name or medicine_name, or download the CSV template for a sample file.');
  if(data.length>5001)throw new Error('Import up to 5,000 medicines at a time.');
  const seenBarcodes=new Set();
  return data.slice(1).map((cells,index)=>{
    const rowNumber=index+2,record=Object.fromEntries(headers.map((header,column)=>[header,(cells[column]||'').trim()]));
    if(!cells.some(cell=>cell.trim()))return null;
    if(!record.name)throw new Error(`Row ${rowNumber}: medicine name is required.`);
    if(cells.length>headers.length)throw new Error(`Row ${rowNumber}: unexpected extra columns.`);
    const barcode=record.barcode||null;
    if(barcode){const key=barcode.toLowerCase();if(seenBarcodes.has(key))throw new Error(`Row ${rowNumber}: duplicate barcode ${barcode} in this file.`);seenBarcodes.add(key)}
    const minStock=numberValue(record.min_stock,'min_stock',rowNumber,{integer:true});
    const quantity=numberValue(record.quantity,'quantity',rowNumber,{integer:true});
    const batchNumber=record.batch_number||null,expiryDate=record.expiry_date||null;
    if(quantity>0&&(!batchNumber||!expiryDate||!validExpiryDate(expiryDate)))throw new Error(`Row ${rowNumber}: quantity above 0 requires a batch_number and a valid, unexpired expiry_date.`);
    return {name:record.name,generic_name:record.generic_name||null,brand:record.brand||null,manufacturer:record.manufacturer||null,barcode,strength:record.strength||null,dosage_form:record.dosage_form||null,unit:record.unit||'unit',quantity,batch_number:batchNumber,expiry_date:expiryDate,purchase_price:numberValue(record.purchase_price,'purchase_price',rowNumber),selling_price:numberValue(record.selling_price,'selling_price',rowNumber),min_stock:minStock,reorder_level:numberValue(record.reorder_level,'reorder_level',rowNumber,{integer:true}),prescription_required:truthy(record.prescription_required,'prescription_required',rowNumber),controlled_medicine:truthy(record.controlled_medicine,'controlled_medicine',rowNumber)};
  }).filter(Boolean);
}
function renderPreview(items){
  const preview=items.slice(0,25);
  csvPreview.innerHTML=`<table class="table"><thead><tr><th>Name</th><th>Generic</th><th>Strength</th><th>Barcode</th><th>Quantity</th><th>Batch</th><th>Expiry</th><th>Buying price</th><th>Selling price</th></tr></thead><tbody>${preview.map(item=>`<tr><td>${escapeHtml(item.name)}</td><td>${escapeHtml(item.generic_name||'-')}</td><td>${escapeHtml(item.strength||'-')}</td><td>${escapeHtml(item.barcode||'-')}</td><td>${item.quantity}</td><td>${escapeHtml(item.batch_number||'-')}</td><td>${escapeHtml(item.expiry_date||'-')}</td><td>${item.purchase_price.toFixed(2)}</td><td>${item.selling_price.toFixed(2)}</td></tr>`).join('')}</tbody></table>`;
  csvPreview.hidden=false;
  if(items.length>preview.length)csvMsg.textContent=`Previewing ${preview.length} of ${items.length} medicines. Ready to import.`;
  else csvMsg.textContent=`${items.length} medicine${items.length===1?'':'s'} validated. Ready to import.`;
}
csvFile.onchange=async()=>{
  csvRows=[];importButton.disabled=true;csvPreview.hidden=true;csvPreview.replaceChildren();
  const file=csvFile.files?.[0];if(!file)return;
  if(file.size>10*1024*1024){csvMsg.textContent='CSV file is too large. Maximum size is 10 MB.';return}
  try{csvRows=validateCsv(await file.text());if(!csvRows.length)throw new Error('No medicine rows found.');renderPreview(csvRows);importButton.disabled=false}
  catch(error){csvMsg.textContent=error.message}
};
importButton.onclick=async()=>{
  if(!csvRows.length)return;
  importButton.disabled=true;csvMsg.textContent='Importing medicines…';
  const codes=csvRows.map(item=>item.barcode).filter(Boolean);
  if(codes.length){
    const existingCodes=new Set();
    for(let start=0;start<codes.length;start+=200){
      const {data:existing,error}=await supabase.from('medicines').select('barcode').in('barcode',codes.slice(start,start+200));
      if(error){csvMsg.textContent=`Could not check existing barcodes: ${error.message}`;importButton.disabled=false;return}
      for(const item of existing||[])existingCodes.add(String(item.barcode).toLowerCase());
    }
    const duplicates=csvRows.filter(item=>item.barcode&&existingCodes.has(item.barcode.toLowerCase()));
    if(duplicates.length){csvMsg.textContent=`Import stopped: ${duplicates.length} barcode${duplicates.length===1?' is':'s are'} already in the catalogue (${duplicates.slice(0,5).map(item=>item.barcode).join(', ')}). Remove or change them in the CSV, then upload again.`;importButton.disabled=false;return}
  }
  const medicineRows=csvRows.map(({quantity,batch_number,expiry_date,...medicine})=>({...medicine,id:crypto.randomUUID()}));
  const {error}=await supabase.from('medicines').insert(medicineRows);
  if(error){csvMsg.textContent=`Import failed: ${error.message}`;importButton.disabled=false;return}
  const zeroStockRows=medicineRows.filter((_,index)=>csvRows[index].quantity===0).map(item=>({medicine_id:item.id,quantity:0}));
  const {error:zeroStockError}=zeroStockRows.length?await supabase.from('inventory').insert(zeroStockRows):{error:null};
  let stockError=zeroStockError;
  if(!stockError){
    const received=medicineRows.flatMap((item,index)=>csvRows[index].quantity>0?[{medicine_id:item.id,quantity:csvRows[index].quantity,unit_cost:csvRows[index].purchase_price,batch_number:csvRows[index].batch_number,expiry_date:csvRows[index].expiry_date}]:[]);
    if(received.length){const result=await supabase.rpc('receive_stock',{p_supplier_name:'Opening stock',p_invoice_number:'Initial catalogue import',p_items:received});stockError=result.error}
  }
  if(stockError){
    const medicineIds=medicineRows.map(item=>item.id);
    const {error:inventoryCleanupError}=await supabase.from('inventory').delete().in('medicine_id',medicineIds);
    const {error:cleanupError}=inventoryCleanupError?{error:inventoryCleanupError}:await supabase.from('medicines').delete().in('id',medicineIds);
    csvMsg.textContent=cleanupError?`Inventory setup failed (${stockError.message}) and cleanup failed (${cleanupError.message}). Contact an administrator.`:`Import was rolled back because inventory setup failed: ${stockError.message}`;
    importButton.disabled=false;return;
  }
  csvRows=[];csvFile.value='';csvPreview.hidden=true;
  const refreshed=await revealCatalogue();
  csvMsg.textContent=refreshed?`Successfully added ${medicineRows.length} medicines. They now appear in the catalogue below.`:'Import completed, but the catalogue could not refresh. Reload this page to view the imported medicines.';
};
$('#downloadTemplate').onclick=()=>{
  const contents='name,generic_name,brand,manufacturer,barcode,strength,dosage_form,unit,quantity,batch_number,expiry_date,purchase_price,selling_price,min_stock,reorder_level,prescription_required,controlled_medicine\nParacetamol,Paracetamol,Example Brand,Example Manufacturer,1234567890123,500mg,Tablet,tablet,100,BATCH-001,2027-12-31,10,15,20,20,no,no\n';
  const url=URL.createObjectURL(new Blob([contents],{type:'text/csv;charset=utf-8'}));
  const link=document.createElement('a');link.href=url;link.download='medicine-import-template.csv';link.click();URL.revokeObjectURL(url);
};
load();
