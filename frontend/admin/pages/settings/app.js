import { supabase } from '../../../shared/js/supabase.js';
import { requireUser } from '../../../shared/js/auth.js';

const session = await requireUser(['admin']);
const form = document.querySelector('#form');
const message = document.querySelector('#msg');
const signatureMessage = document.querySelector('#signatureMsg');
const signatureName = document.querySelector('#receiptSignatureName');
const signaturePreview = document.querySelector('#receiptSignaturePreview');
const savedSignature = document.querySelector('#savedSignature');
const uploadButton = document.querySelector('#uploadReceiptSignature');
const signatureCanvas = document.querySelector('#signatureCanvas');
const signatureContext = signatureCanvas.getContext('2d');
let signatureDrawn = false;
let savedSignaturePath = null;
uploadButton.disabled = true;

signatureContext.strokeStyle = '#123b34';
signatureContext.lineWidth = 7;
signatureContext.lineCap = 'round';
signatureContext.lineJoin = 'round';
function signaturePoint(event) {
  const bounds = signatureCanvas.getBoundingClientRect();
  return { x: (event.clientX - bounds.left) * signatureCanvas.width / bounds.width, y: (event.clientY - bounds.top) * signatureCanvas.height / bounds.height };
}
signatureCanvas.addEventListener('pointerdown', (event) => {
  event.preventDefault();
  signatureCanvas.setPointerCapture(event.pointerId);
  const point = signaturePoint(event);
  signatureContext.beginPath();
  signatureContext.fillStyle = signatureContext.strokeStyle;
  signatureContext.arc(point.x, point.y, 3.5, 0, Math.PI * 2);
  signatureContext.fill();
  signatureContext.beginPath();
  signatureContext.moveTo(point.x, point.y);
  signatureDrawn = true;
});
signatureCanvas.addEventListener('pointermove', (event) => {
  if (!signatureCanvas.hasPointerCapture(event.pointerId)) return;
  const point = signaturePoint(event);
  signatureContext.lineTo(point.x, point.y);
  signatureContext.stroke();
});
document.querySelector('#clearSignature').addEventListener('click', () => {
  signatureContext.clearRect(0, 0, signatureCanvas.width, signatureCanvas.height);
  signatureDrawn = false;
});

async function showSignature(path) {
  savedSignaturePath = path || null;
  if (!savedSignaturePath) {
    savedSignature.hidden = true;
    signaturePreview.removeAttribute('src');
    signatureMessage.textContent = 'No admin receipt signature is saved.';
    return;
  }
  const { data, error } = await supabase.storage.from('receipt-signatures').createSignedUrl(savedSignaturePath, 300);
  if (error || !data?.signedUrl) {
    savedSignature.hidden = true;
    signatureMessage.textContent = 'The saved signature could not be previewed. Check the private storage policy or upload it again.';
    return;
  }
  signaturePreview.src = data.signedUrl;
  savedSignature.hidden = false;
  signatureMessage.textContent = 'Admin receipt signature saved.';
}

const { data, error } = await supabase.from('pharmacy_settings').select('*').single();
if (error) message.textContent = error.message;
if (data) {
  Object.entries(data).forEach(([key, value]) => {
    if (form.elements[key]) form.elements[key].value = value ?? '';
  });
  signatureName.value = data.receipt_signature_name || '';
  await showSignature(data.receipt_signature_path);
  uploadButton.disabled = false;
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const settings = Object.fromEntries(new FormData(form).entries());
  settings.low_stock_threshold = Number(settings.low_stock_threshold);
  settings.expiry_alert_days = Number(settings.expiry_alert_days);
  settings.updated_by = session.user.id;
  settings.updated_at = new Date().toISOString();

  const { error: saveError } = await supabase.from('pharmacy_settings').update(settings).eq('id', true);
  message.textContent = saveError?.message || 'Settings saved successfully.';
});

uploadButton.addEventListener('click', async () => {
  const signerName = String(signatureName.value || '').trim();
  if (!signerName) {
    signatureMessage.textContent = 'Enter the authorized signer name.';
    signatureName.focus();
    return;
  }
  if (!signatureDrawn) {
    signatureMessage.textContent = 'Draw the signature before saving.';
    return;
  }
  const blob = await new Promise((resolve) => signatureCanvas.toBlob(resolve, 'image/png'));
  if (!blob || blob.size > 1024 * 1024) {
    signatureMessage.textContent = 'Signature image could not be saved.';
    return;
  }

  uploadButton.disabled = true;
  signatureMessage.textContent = 'Saving signature…';
  const path = `${session.user.id}/${crypto.randomUUID()}.png`;
  const { error: uploadError } = await supabase.storage.from('receipt-signatures').upload(path, blob, {
    contentType: 'image/png',
    cacheControl: '31536000',
    upsert: false,
  });
  if (uploadError) {
    signatureMessage.textContent = `Signature upload failed: ${uploadError.message}`;
    uploadButton.disabled = false;
    return;
  }

  const { error: saveError } = await supabase.from('pharmacy_settings').update({
    receipt_signature_path: path,
    receipt_signature_name: signerName,
    receipt_signature_updated_by: session.user.id,
    updated_by: session.user.id,
    updated_at: new Date().toISOString(),
  }).eq('id', true);
  if (saveError) {
    signatureMessage.textContent = `The image uploaded but could not be activated: ${saveError.message}`;
    uploadButton.disabled = false;
    return;
  }

  await showSignature(path);
  uploadButton.disabled = false;
});
