const menu=document.querySelector('.site-menu');
const menuButton=menu?.querySelector('summary');

menu?.querySelectorAll('a').forEach(link=>link.addEventListener('click',()=>{menu.open=false}));
document.addEventListener('click',event=>{
  if(menu?.open&&!menu.contains(event.target))menu.open=false;
});
document.addEventListener('keydown',event=>{
  if(event.key==='Escape'&&menu?.open){menu.open=false;menuButton?.focus()}
});

const filters=[...document.querySelectorAll('[data-service-filter]')];
const serviceCards=[...document.querySelectorAll('[data-service-category]')];
const serviceResults=document.querySelector('#serviceResults');

filters.forEach(button=>button.addEventListener('click',()=>{
  const selected=button.dataset.serviceFilter;
  let visibleCount=0;
  filters.forEach(filter=>filter.setAttribute('aria-pressed',String(filter===button)));
  serviceCards.forEach(card=>{
    const visible=selected==='all'||card.dataset.serviceCategory===selected;
    card.hidden=!visible;
    if(visible)visibleCount+=1;
  });
  if(serviceResults){
    const label=selected==='prescriptions'?'prescription':selected==='payments'?'payment':'medicine';
    serviceResults.textContent=selected==='all'
      ?`Showing all ${visibleCount} services.`
      :`Showing ${visibleCount} ${label} service${visibleCount===1?'':'s'}.`;
  }
}));
