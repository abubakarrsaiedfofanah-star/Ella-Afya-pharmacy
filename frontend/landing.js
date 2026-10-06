const menu=document.querySelector('.site-menu');
const menuButton=menu?.querySelector('summary');

if(menuButton){
  menuButton.setAttribute('aria-expanded',String(menu.open));
  menu.addEventListener('toggle',()=>{
    menuButton.setAttribute('aria-expanded',String(menu.open));
    menuButton.setAttribute('aria-label',menu.open?'Close website menu':'Open website menu');
  });
}
menu?.querySelectorAll('a').forEach(link=>link.addEventListener('click',()=>{menu.open=false}));
document.addEventListener('click',event=>{
  if(menu?.open&&!menu.contains(event.target))menu.open=false;
});
document.addEventListener('keydown',event=>{
  if(event.key==='Escape'&&menu?.open){menu.open=false;menuButton?.focus()}
});

const sectionLinks=[...document.querySelectorAll('.desktop-nav a[href^="#"],.site-menu nav a[href^="#"]')];
const observedSections=new Map();
if('IntersectionObserver' in window){
  const sectionObserver=new IntersectionObserver(entries=>{
    entries.forEach(entry=>{
      if(entry.isIntersecting)observedSections.set(entry.target.id,entry.intersectionRatio);
      else observedSections.delete(entry.target.id);
    });
    const currentId=[...observedSections.entries()].sort((a,b)=>b[1]-a[1])[0]?.[0];
    sectionLinks.forEach(link=>{
      if(link.hash===`#${currentId}`)link.setAttribute('aria-current','location');
      else link.removeAttribute('aria-current');
    });
  },{rootMargin:'-18% 0px -65% 0px',threshold:[0,.15,.35,.6]});
  ['services','steps','faq'].forEach(id=>{
    const section=document.getElementById(id);
    if(section)sectionObserver.observe(section);
  });
}

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

const photoCarousel=document.querySelector('[data-photo-carousel]');
if(photoCarousel){
  const slides=[...photoCarousel.querySelectorAll('[data-photo-slide]')];
  const status=photoCarousel.querySelector('[data-photo-status]');
  let activeSlide=0;
  const showSlide=index=>{
    activeSlide=(index+slides.length)%slides.length;
    slides.forEach((slide,slideIndex)=>{slide.hidden=slideIndex!==activeSlide});
    if(status)status.textContent=`Photo ${activeSlide+1} of ${slides.length}`;
  };
  photoCarousel.querySelector('[data-photo-prev]')?.addEventListener('click',()=>showSlide(activeSlide-1));
  photoCarousel.querySelector('[data-photo-next]')?.addEventListener('click',()=>showSlide(activeSlide+1));
}