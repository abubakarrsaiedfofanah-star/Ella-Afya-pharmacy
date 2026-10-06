import {supabase} from '../../../shared/js/supabase.js';
import {requireUser} from '../../../shared/js/auth.js';

const session=await requireUser(['admin']);
if(!session) throw new Error('Unauthorized');

const $=selector=>document.querySelector(selector);
const form=$('#form'),rows=$('#rows'),msg=$('#msg'),search=$('#search'),filter=$('#filter'),catalogMsg=$('#catalogMsg');
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
  const [{data,error},{data:purchasePrices, error:priceError}]=await Promise.all([
    supabase.from('medicines').select('id,name,generic_name,brand,manufacturer,barcode,strength,dosage_form,selling_price,prescription_required,controlled_medicine,min_stock,reorder_level,active,inventory(quantity)').order('name'),
    supabase.from('admin_medicine_purchase_catalog').select('id,purchase_price'),
  ]);
  if(error){msg.textContent=error.message;return false}
  if(priceError)msg.textContent=`Buying prices could not be loaded: ${priceError.message}`;
  const costs=new Map((purchasePrices||[]).map(item=>[item.id,Number(item.purchase_price)]));
  medicines=(data||[]).map(item=>({...item,purchase_price:costs.get(item.id)??null}));render();return true;
}
async function revealCatalogue(){
  search.value='';filter.value='active';
  const loaded=await load();
  document.querySelector('#medicineCatalog')?.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'start'});
  return loaded;
}
function render(){
  const query=search.value.toLowerCase(),mode=filter.value;
  rows.innerHTML=medicines.filter(item=>`${item.name} ${item.generic_name||''} ${item.barcode||''}`.toLowerCase().includes(query)).filter(item=>{
    const quantity=item.inventory?.[0]?.quantity??0;
    if(mode==='active')return item.active;
    if(mode==='inactive')return !item.active;
    if(!item.active&&mode!=='all')return false;
    return mode==='low'?quantity<=item.min_stock:mode==='out'?quantity===0:mode==='rx'?item.prescription_required:true;
  }).map(item=>`<tr data-medicine-row="${escapeHtml(item.id)}"><td><b>${escapeHtml(item.name)}</b><br><small>${escapeHtml(item.generic_name||'')} ${escapeHtml(item.strength||'')}${item.active?'':' · Inactive'}</small></td><td>${escapeHtml(item.barcode||'-')}</td><td>${escapeHtml(item.dosage_form||'-')}</td><td><input class="catalog-price" data-price="buying" type="number" min="0" step="0.01" value="${item.purchase_price??''}" aria-label="Buying price for ${escapeHtml(item.name)}" disabled></td><td><input class="catalog-price" data-price="selling" type="number" min="0" step="0.01" value="${Number(item.selling_price)}" aria-label="Selling price for ${escapeHtml(item.name)}" disabled></td><td>${item.inventory?.[0]?.quantity??0}</td><td>${item.reorder_level}</td><td>${item.prescription_required?'Yes':'No'}</td><td>${item.controlled_medicine?'Yes':'No'}</td><td>${item.active?`<button class="btn secondary" type="button" data-edit-prices="${escapeHtml(item.id)}">Edit prices</button>`:`<button class="btn secondary" type="button" data-restore="${escapeHtml(item.id)}">Restore</button>`}</td></tr>`).join('')||'<tr><td colspan="10">No medicines found.</td></tr>';
  rows.querySelectorAll('[data-edit-prices]').forEach(button=>button.addEventListener('click',()=>{
    const row=button.closest('[data-medicine-row]');
    row.querySelectorAll('[data-price]').forEach(input=>{input.disabled=false});
    button.hidden=true;
    const save=document.createElement('button');save.className='btn';save.type='button';save.textContent='Save';
    const cancel=document.createElement('button');cancel.className='btn secondary';cancel.type='button';cancel.textContent='Cancel';
    button.after(save,cancel);
    cancel.addEventListener('click',render);
    save.addEventListener('click',async()=>{
      const buying=row.querySelector('[data-price="buying"]'),selling=row.querySelector('[data-price="selling"]');
      const purchasePrice=Number(buying.value),sellingPrice=Number(selling.value);
      if(buying.value===''||selling.value===''||!Number.isFinite(purchasePrice)||purchasePrice<0||!Number.isFinite(sellingPrice)||sellingPrice<0){catalogMsg.textContent='Enter valid non-negative buying and selling prices.';return}
      save.disabled=true;catalogMsg.textContent='Saving prices…';
      const {error}=await supabase.from('medicines').update({purchase_price:purchasePrice,selling_price:sellingPrice}).eq('id',row.dataset.medicineRow);
      if(error){catalogMsg.textContent=`Prices could not be saved: ${error.message}`;save.disabled=false;return}
      await load();catalogMsg.textContent='Prices saved.';
    });
  }));
  rows.querySelectorAll('[data-restore]').forEach(button=>button.addEventListener('click',async()=>{
    button.disabled=true;catalogMsg.textContent='Restoring medicine…';
    const {error}=await supabase.from('medicines').update({active:true}).eq('id',button.dataset.restore);
    if(error){catalogMsg.textContent=`Medicine could not be restored: ${error.message}`;button.disabled=false;return}
    await load();catalogMsg.textContent='Medicine restored.';
  }));
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
$('#clearCatalog').addEventListener('click',async()=>{
  const activeCount=medicines.filter(item=>item.active).length;
  if(!activeCount){catalogMsg.textContent='There are no active medicines to clear.';return}
  if(!confirm(`Clear all ${activeCount} active medicines? They will be hidden from Sales and stock will be set to zero. Sales history will be kept.`))return;
  const button=$('#clearCatalog');button.disabled=true;catalogMsg.textContent='Clearing catalogue…';
  const {data,error}=await supabase.rpc('admin_clear_medicine_catalog');
  button.disabled=false;
  if(error){catalogMsg.textContent=`Catalogue could not be cleared: ${error.message}`;return}
  filter.value='active';await load();catalogMsg.textContent=`${Number(data?.archived_medicines||activeCount)} medicines cleared.`;
});

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
  const raw=String(value??'').trim();
  if(!raw||/^(?:-|–|—|n\/?a|null)$/i.test(raw)){if(required)throw new Error(`Row ${rowNumber}: ${label} is required.`);return 0}
  let normalized=raw.replace(/[\s,\u00a0]/g,'').replace(/^(?:KES|KSHS?|USD|EUR|GBP)/i,'').replace(/(?:KES|KSHS?|USD|EUR|GBP)$/i,'').replace(/^[€$£¥₹]/,'').replace(/[€$£¥₹]$/,'').replace(/\/-?=?$/,'');
  const number=Number(normalized);
  const friendlyLabel=label==='purchase_price'?'buying price':label==='selling_price'?'selling price':label.replaceAll('_',' ');
  if(!/^(?:\+?\d+(?:\.\d*)?|\+?\.\d+)$/.test(normalized)||!Number.isFinite(number)||number<0||(integer&&!Number.isInteger(number)))throw new Error(`Row ${rowNumber}: ${friendlyLabel} must be a valid ${integer?'whole':'non-negative'} number.`);
  return number;
}
function validateCsv(text){
  const data=parseCsv(text.replace(/^\uFEFF/,''));
  if(data.length<2)throw new Error('The sheet has a header row but no medicine rows.');
  const aliases={medicine:'name',med:'name',medicine_name:'name',name_of_medicine:'name',name_of_item:'name',medication:'name',medication_name:'name',product:'name',product_name:'name',product_description:'name',product_details:'name',item:'name',item_name:'name',item_description:'name',item_details:'name',drug:'name',drug_name:'name',drug_description:'name',description:'name',particular:'name',particulars:'name',qty:'quantity',stock:'quantity',stock_qty:'quantity',quantity_in_stock:'quantity',opening_stock:'quantity',opening_quantity:'quantity',item_code:'barcode',product_code:'barcode',item_id:'barcode',sku:'barcode',buying_price:'purchase_price',buy_price:'purchase_price',purchase_cost:'purchase_price',cost_price:'purchase_price',unit_cost:'purchase_price',cost:'purchase_price',sale_price:'selling_price',sales_price:'selling_price',sell_price:'selling_price',retail_price:'selling_price',batch_no:'batch_number',batch:'batch_number',expiry:'expiry_date',expirydate:'expiry_date'};
  const known=new Set(['name','generic_name','brand','manufacturer','barcode','strength','dosage_form','unit','quantity','batch_number','expiry_date','purchase_price','selling_price','min_stock','reorder_level','prescription_required','controlled_medicine']);
  const normalize=header=>header.replace(/^\uFEFF/,'').trim().toLowerCase().replace(/[^a-z0-9]+/g,'_').replace(/^_+|_+$/g,'');
  const canonical=header=>{const normalized=normalize(header);return aliases[normalized]||normalized};
  const headerRowIndex=data.slice(0,20).findIndex(row=>row.some(cell=>canonical(cell)==='name'));
  const headerIndex=headerRowIndex<0?0:headerRowIndex;
  const headers=(data[headerIndex]||[]).map((cell,index)=>{const field=canonical(cell);return field&&known.has(field)?field:`__ignored_${index}`});
  const hasNameColumn=headers.includes('name');
  const mapped=headers.filter(header=>!header.startsWith('__ignored_'));
  if(new Set(mapped).size!==mapped.length)throw new Error('The sheet has duplicate medicine columns after normalizing their names.');
  if(data.length-headerIndex>5001)throw new Error('Import up to 5,000 medicines at a time.');
  const seenBarcodes=new Set(),warnings=[];
  if(!hasNameColumn)throw new Error('No medicine-name column found. The sheet is shown below; add a Medicine or Product name column before importing.');
  const items=data.slice(headerIndex+1).map((cells,index)=>{
    const rowNumber=headerIndex+index+2;
    if(!cells.some(cell=>cell.trim()))return null;
    const record=Object.fromEntries(headers.map((header,column)=>header.startsWith('__ignored_')?null:[header,(cells[column]||'').trim()]).filter(Boolean));
    if(!record.name){warnings.push(`Skipped blank-name row ${rowNumber}.`);return null}
    const barcode=record.barcode||null;
    if(barcode){const key=barcode.toLowerCase();if(seenBarcodes.has(key))throw new Error(`Row ${rowNumber}: duplicate barcode ${barcode} in this file.`);seenBarcodes.add(key)}
    const minStock=numberValue(record.min_stock,'min_stock',rowNumber,{integer:true});
    let quantity=numberValue(record.quantity,'quantity',rowNumber,{integer:true});
    const batchNumber=record.batch_number||null,expiryDate=record.expiry_date||null;
    if(quantity>0&&expiryDate&&!validExpiryDate(expiryDate))throw new Error(`Row ${rowNumber}: expiry date must be valid and not passed.`);
    return {name:record.name,generic_name:record.generic_name||null,brand:record.brand||null,manufacturer:record.manufacturer||null,barcode,strength:record.strength||null,dosage_form:record.dosage_form||null,unit:record.unit||'unit',quantity,batch_number:batchNumber,expiry_date:expiryDate,purchase_price:numberValue(record.purchase_price,'purchase_price',rowNumber),selling_price:numberValue(record.selling_price,'selling_price',rowNumber),min_stock:minStock,reorder_level:numberValue(record.reorder_level,'reorder_level',rowNumber,{integer:true}),prescription_required:truthy(record.prescription_required,'prescription_required',rowNumber),controlled_medicine:truthy(record.controlled_medicine,'controlled_medicine',rowNumber)};
  }).filter(Boolean);
  if(!items.length)throw new Error('No medicine rows with a medicine name were found in this sheet.');
  return {items,warnings:warnings.slice(0,8)};
}
function renderPreview(items,warnings=[]){
  const preview=items.slice(0,25);
  csvPreview.innerHTML=`<table class="table"><thead><tr><th>Name</th><th>Generic</th><th>Strength</th><th>Barcode</th><th>Quantity</th><th>Batch</th><th>Expiry</th><th>Buying price</th><th>Selling price</th></tr></thead><tbody>${preview.map(item=>`<tr><td>${escapeHtml(item.name)}</td><td>${escapeHtml(item.generic_name||'-')}</td><td>${escapeHtml(item.strength||'-')}</td><td>${escapeHtml(item.barcode||'-')}</td><td>${item.quantity}</td><td>${escapeHtml(item.batch_number||'-')}</td><td>${escapeHtml(item.expiry_date||'-')}</td><td>${item.purchase_price.toFixed(2)}</td><td>${item.selling_price.toFixed(2)}</td></tr>`).join('')}</tbody></table>`;
  csvPreview.hidden=false;
  const summary=items.length>preview.length?`Previewing ${preview.length} of ${items.length} medicines.`:`${items.length} medicine${items.length===1?'':'s'} ready to import.`;
  csvMsg.textContent=[summary,...warnings].join(' ');
}
function renderSheetPreview(text,errorMessage=''){
  const data=parseCsv(text.replace(/^\uFEFF/,''));
  const nameHeaders=['name','medicine','med','medicine_name','name_of_medicine','name_of_item','medication','medication_name','product','product_name','item','item_name','drug','drug_name','description'];
  const headerIndex=data.slice(0,30).findIndex(row=>row.some(cell=>nameHeaders.includes(normalizeHeader(cell))));
  const start=headerIndex<0?0:headerIndex;
  const columns=[...(data[start]||[])];
  const normalizedHeaders=columns.map(normalizeHeader);
  if(!normalizedHeaders.some(header=>['purchase_price','buying_price','buy_price','cost_price','purchase_cost'].includes(header)))columns.push('Buying price');
  if(!normalizedHeaders.some(header=>['selling_price','sale_price','selling_price','sell_price','retail_price'].includes(header)))columns.push('Selling price');
  const visible=data.slice(start+1);
  if(!visible.length)return;
  const errorRow=Number(errorMessage.match(/Row (\d+)/)?.[1]);
  csvPreview.innerHTML=`<table class="table"><thead><tr><th>Sheet row</th>${columns.map((cell,index)=>`<th>${escapeHtml(cell||`Column ${index+1}`)}</th>`).join('')}</tr></thead><tbody>${visible.map((row,index)=>{const sheetRow=start+index+2;return `<tr${sheetRow===errorRow?' class="csv-error-row"':''}><td>${sheetRow}</td>${columns.map((_,column)=>`<td>${escapeHtml(row[column]||'')}</td>`).join('')}</tr>`}).join('')}</tbody></table>`;
  csvPreview.hidden=false;
}
function normalizeHeader(value){return String(value||'').trim().toLowerCase().replace(/[^a-z0-9]+/g,'_').replace(/^_+|_+$/g,'')}
csvFile.onchange=async()=>{
  csvRows=[];importButton.disabled=true;csvPreview.hidden=true;csvPreview.replaceChildren();
  const file=csvFile.files?.[0];if(!file)return;
  if(file.size>10*1024*1024){csvMsg.textContent='File is too large. Maximum size is 10 MB.';return}
  let csvText='';
  try{
    const extension=file.name.split('.').pop().toLowerCase();
    if(extension==='csv')csvText=await file.text();
    else if(['xlsx','xls'].includes(extension)){
      csvMsg.textContent='Reading Excel workbook…';
      const XLSX=await import('https://esm.sh/xlsx@0.18.5');
      const workbook=XLSX.read(await file.arrayBuffer(),{type:'array',cellDates:true});
      const firstSheet=workbook.SheetNames.map(name=>workbook.Sheets[name]).find(sheet=>sheet?.['!ref']);
      if(!firstSheet)throw new Error('The workbook has no readable worksheets.');
      csvText=XLSX.utils.sheet_to_csv(firstSheet,{dateNF:'yyyy-mm-dd'});
    }else throw new Error('Choose an Excel workbook (.xlsx or .xls) or a CSV file.');
    renderSheetPreview(csvText);
    const parsed=validateCsv(csvText);csvRows=parsed.items;renderPreview(csvRows,parsed.warnings);importButton.disabled=false;
  }
  catch(error){csvMsg.textContent=error.message;if(csvText)renderSheetPreview(csvText,error.message)}
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
  const directInventoryRows=medicineRows.flatMap((item,index)=>csvRows[index].quantity===0||!csvRows[index].batch_number||!csvRows[index].expiry_date?[{medicine_id:item.id,quantity:csvRows[index].quantity}]:[]);
  const {error:zeroStockError}=directInventoryRows.length?await supabase.from('inventory').insert(directInventoryRows):{error:null};
  let stockError=zeroStockError;
  if(!stockError){
    const received=medicineRows.flatMap((item,index)=>csvRows[index].quantity>0&&csvRows[index].batch_number&&csvRows[index].expiry_date?[{medicine_id:item.id,quantity:csvRows[index].quantity,unit_cost:csvRows[index].purchase_price,batch_number:csvRows[index].batch_number,expiry_date:csvRows[index].expiry_date}]:[]);
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
  await revealCatalogue();
  csvMsg.textContent='';
};
$('#downloadTemplate').onclick=()=>{
  const contents='name,generic_name,brand,manufacturer,barcode,strength,dosage_form,unit,quantity,batch_number,expiry_date,purchase_price,selling_price,min_stock,reorder_level,prescription_required,controlled_medicine\nParacetamol,Paracetamol,Example Brand,Example Manufacturer,1234567890123,500mg,Tablet,tablet,100,BATCH-001,2027-12-31,10,15,20,20,no,no\n';
  const url=URL.createObjectURL(new Blob([contents],{type:'text/csv;charset=utf-8'}));
  const link=document.createElement('a');link.href=url;link.download='medicine-import-template.csv';link.click();URL.revokeObjectURL(url);
};
load();
