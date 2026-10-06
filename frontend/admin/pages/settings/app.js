import { supabase } from '../../../shared/js/supabase.js';
import { requireUser } from '../../../shared/js/auth.js';

const session = await requireUser(['admin']);
const form = document.querySelector('#form');
const message = document.querySelector('#msg');
const signatureMessage = document.querySelector('#signatureMsg');
const signatureName = document.querySelector('#receiptSignatureName');
const signatureFile = document.querySelector('#receiptSignatureFile');
const signaturePreview = document.querySelector('#receiptSignaturePreview');
const savedSignature = document.querySelector('#savedSignature');
const uploadButton = document.querySelector('#uploadReceiptSignature');
let savedSignaturePath = null;
uploadButton.disabled = true;

async function showSignature(path) {
  savedSignaturePath = path || null;
  if (!savedSignaturePath) {
    savedSignature.hidden = true;
    signaturePreview.removeAttribute('src');
    signatureMessage.textContent = 'No admin receipt signature is saved. Sales cannot be completed until one is uploaded.';
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
  signatureMessage.textContent = 'Admin receipt signature saved in private storage. Upload a new image to replace it.';
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
  const file = signatureFile.files?.[0];
  const signerName = String(signatureName.value || '').trim();
  if (!signerName) {
    signatureMessage.textContent = 'Enter the authorized receipt signer name and save it with the signature.';
    signatureName.focus();
    return;
  }
  if (!file) {
    signatureMessage.textContent = 'Choose a PNG, JPG or WebP signature image first.';
    return;
  }
  const extension = ({ 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp' })[file.type];
  if (!extension || file.size > 1024 * 1024) {
    signatureMessage.textContent = 'Use a PNG, JPG or WebP image no larger than 1 MB.';
    return;
  }

  uploadButton.disabled = true;
  signatureMessage.textContent = 'Saving signature to private storage…';
  const path = `${session.user.id}/${crypto.randomUUID()}.${extension}`;
  const { error: uploadError } = await supabase.storage.from('receipt-signatures').upload(path, file, {
    contentType: file.type,
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

  signatureFile.value = '';
  await showSignature(path);
  uploadButton.disabled = false;
});
