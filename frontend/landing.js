const menu=document.querySelector('.site-menu');
const menuButton=menu?.querySelector('summary');

menu?.querySelectorAll('a').forEach(link=>link.addEventListener('click',()=>{menu.open=false}));
document.addEventListener('click',event=>{
  if(menu?.open&&!menu.contains(event.target))menu.open=false;
});
document.addEventListener('keydown',event=>{
  if(event.key==='Escape'&&menu?.open){menu.open=false;menuButton?.focus()}
});
