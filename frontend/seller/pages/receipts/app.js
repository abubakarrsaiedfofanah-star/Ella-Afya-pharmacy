import { supabase } from '../../../shared/js/supabase.js';
import { requireUser } from '../../../shared/js/auth.js';

const session = await requireUser(['seller']);
const rows = document.querySelector('#rows');
const message = document.querySelector('#msg');

function escapeHtml(value) {
	return String(value ?? '').replace(/[&<>"']/g, (character) => ({
		'&': '&amp;',
		'<': '&lt;',
		'>': '&gt;',
		'"': '&quot;',
		"'": '&#39;',
	})[character]);
}

function money(value) {
	return `KSh ${Number(value || 0).toLocaleString()}`;
}

async function loadReceipts() {
	rows.innerHTML = '<tr><td colspan="6"><span class="skeleton" aria-label="Loading receipts">&nbsp;</span></td></tr>';
	message.textContent = '';

	const { data, error } = await supabase
		.from('sales')
		.select('id,sale_number,total_amount,status,created_at,customer_name,customer_phone')
		.eq('seller_id', session.user.id)
		.order('created_at', { ascending: false })
		.limit(200);

	if (error) {
		rows.replaceChildren();
		message.textContent = 'Receipts could not be loaded. Please try again.';
		return;
	}

	if (!data?.length) {
		rows.innerHTML = '<tr><td colspan="6" class="muted">No receipts yet.</td></tr>';
		return;
	}

	rows.innerHTML = data.map((sale) => {
		const actions = sale.status === 'paid'
			? `<button class="btn secondary" data-id="${escapeHtml(sale.id)}" data-action="print" type="button">Print</button> <button class="btn secondary" data-id="${escapeHtml(sale.id)}" data-action="refund" type="button">Request refund</button>`
			: sale.status === 'pending_payment'
				? `<button class="btn secondary" data-id="${escapeHtml(sale.id)}" data-action="cancel_sale" type="button">Request cancellation</button>`
				: '';

		const buyer = [sale.customer_name,sale.customer_phone].filter(Boolean).map(escapeHtml).join(' · ') || '—';
		return `<tr><td>${escapeHtml(sale.sale_number)}</td><td>${buyer}</td><td>${money(sale.total_amount)}</td><td>${escapeHtml(sale.status)}</td><td>${escapeHtml(new Date(sale.created_at).toLocaleString())}</td><td class="no-print">${actions}</td></tr>`;
	}).join('');
}

async function printReceipt(id) {
	const printWindow = window.open('', '_blank', 'width=420,height=700');
	if (!printWindow) {
		message.textContent = 'Allow pop-ups to print receipts.';
		return;
	}

	printWindow.document.write('<!doctype html><html lang="en"><head><title>Preparing receipt</title></head><body>Preparing receipt…</body></html>');
	printWindow.document.close();

	try {
		const [{ data: sale, error }, { data: items }, { data: settings }] = await Promise.all([
			supabase.from('sales').select('sale_number,total_amount,created_at,status,customer_name,customer_phone,authorized_signature_path,authorized_signature_name,signature_applied_at').eq('id', id).single(),
			supabase.from('sale_items').select('quantity,total,medicines(name,strength)').eq('sale_id', id),
			supabase.from('pharmacy_settings').select('*').single(),
		]);

		if (error || !sale) {
			printWindow.close();
			message.textContent = 'The receipt could not be loaded.';
			return;
		}
		if (!sale.authorized_signature_path || !sale.authorized_signature_name || !sale.signature_applied_at) {
			printWindow.close();
			message.textContent = 'This older receipt has no saved Admin signature. Ask the Admin before issuing a replacement.';
			return;
		}
		const { data: signature, error: signatureError } = await supabase.storage.from('receipt-signatures').createSignedUrl(sale.authorized_signature_path, 300);
		if (signatureError || !signature?.signedUrl) {
			printWindow.close();
			message.textContent = 'The receipt signature could not be loaded from protected storage.';
			return;
		}

		const itemCount = (items || []).reduce((sum, item) => sum + Number(item.quantity || 0), 0);
		const productCount = (items || []).length;
		const itemRows = (items || []).map((item) => `<div class="line"><span>${escapeHtml(item.medicines?.name || 'Medicine')} ${escapeHtml(item.medicines?.strength || '')} × ${Number(item.quantity || 0)}</span><b>${money(item.total)}</b></div>`).join('') + `<div class="line"><span>Total drugs</span><b>${itemCount} units across ${productCount} medicines</b></div>`;
		const buyer = [sale.customer_name, sale.customer_phone].filter(Boolean).map(escapeHtml).join(' · ');
		const verificationUrl = `${location.origin}/verify/?receipt=${encodeURIComponent(sale.sale_number)}`;
		const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(sale.sale_number)}</title><style>body{font:13px Arial;max-width:360px;margin:20px auto;color:#111}h2{text-align:center;margin:0 0 4px}.center{text-align:center;color:#555}.line{display:flex;justify-content:space-between;gap:12px;border-bottom:1px dashed #bbb;padding:7px 0}.total{font-size:18px;font-weight:800;margin-top:10px}.foot{text-align:center;margin-top:18px;font-size:11px;color:#555}.signature{margin:20px 0 8px;text-align:center;border-top:1px solid #bbb;padding-top:12px}.signature img{display:block;max-width:190px;max-height:76px;object-fit:contain;margin:0 auto 5px}.verify{font-size:10px;overflow-wrap:anywhere;text-align:center}</style></head><body><h2>${escapeHtml(settings?.pharmacy_name || 'Pharmacy')}</h2><div class="center">${escapeHtml(settings?.address || '')}<br>${escapeHtml(settings?.phone || '')}</div><hr><div>Receipt: <b>${escapeHtml(sale.sale_number)}</b><br>${escapeHtml(new Date(sale.created_at).toLocaleString())}${buyer?`<br>Buyer: ${buyer}`:''}</div>${itemRows}<div class="line total"><span>TOTAL</span><span>${money(sale.total_amount)}</span></div><div class="foot">${escapeHtml(settings?.receipt_footer || 'Thank you for choosing our pharmacy.')}</div><div class="signature"><img src="${escapeHtml(signature.signedUrl)}" alt="Authorized administrator signature"><div>Authorized by <b>${escapeHtml(sale.authorized_signature_name)}</b></div></div><div class="verify">Verify receipt: ${escapeHtml(verificationUrl)}</div></body></html>`;

		printWindow.document.open();
		printWindow.document.write(html);
		printWindow.addEventListener('load', () => {
			printWindow.print();
			window.setTimeout(() => printWindow.close(), 500);
		}, { once: true });
		printWindow.document.close();
	} catch {
		printWindow.close();
		message.textContent = 'The receipt could not be prepared for printing.';
	}
}

rows.addEventListener('click', async (event) => {
	const button = event.target.closest('button[data-action]');
	if (!button) return;

	if (button.dataset.action === 'print') {
		await printReceipt(button.dataset.id);
		return;
	}

	const reason = prompt('Reason for this request:');
	if (!reason?.trim()) return;

	button.disabled = true;
	const { error } = await supabase.rpc('request_action', {
		p_action_type: button.dataset.action,
		p_target_id: button.dataset.id,
		p_reason: reason.trim(),
	});

	message.textContent = error ? 'Your request could not be submitted.' : 'Request sent to admin.';
	if (!error) await loadReceipts();
	else button.disabled = false;
});

document.querySelector('#printPage')?.addEventListener('click', () => window.print());
loadReceipts();
