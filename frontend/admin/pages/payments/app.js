import { supabase } from '../../../shared/js/supabase.js';
import { requireUser } from '../../../shared/js/auth.js';

await requireUser(['admin']);

const rows = document.querySelector('#rows');
const search = document.querySelector('#transactionSearch');
const status = document.querySelector('#transactionStatus');
const refreshButton = document.querySelector('#refreshTransactions');
const olderButton = document.querySelector('#loadOlderTransactions');
let transactions = [];
let loading = false;
let hasMore = true;
const pageSize = 200;

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
	return `KSh ${Number(value || 0).toLocaleString(undefined, { maximumFractionDigits: 2 })}`;
}

function renderTransactions() {
	const term = search.value.trim().toLowerCase();
	const visible = transactions.filter((transaction) => [
		transaction.sale_number,
		transaction.seller_name,
		transaction.method,
		transaction.status,
		transaction.provider_reference,
		transaction.mpesa_receipt,
	].some((value) => String(value || '').toLowerCase().includes(term)));

	document.querySelector('#transactionCount').textContent = visible.length.toLocaleString();
	const paidTotal = visible.reduce((total, transaction) => transaction.status === 'paid' ? total + Number(transaction.amount || 0) : total, 0);
	document.querySelector('#paidAmount').textContent = money(paidTotal);

	if (!visible.length) {
		rows.innerHTML = `<tr><td colspan="8" class="muted">${term ? 'No transactions match this search.' : 'No transactions recorded yet.'}</td></tr>`;
		return;
	}

	rows.innerHTML = visible.map((transaction) => `<tr>
		<td>${escapeHtml(new Date(transaction.created_at).toLocaleString())}</td>
		<td><strong>${escapeHtml(transaction.sale_number)}</strong></td>
		<td>${escapeHtml(transaction.seller_name)}</td>
		<td>${money(transaction.amount)}</td>
		<td>${escapeHtml(String(transaction.method).toUpperCase())}</td>
		<td><span class="pill ${transaction.status === 'paid' ? 'status-ok' : transaction.status === 'failed' || transaction.status === 'refunded' ? 'status-off' : ''}">${escapeHtml(transaction.status)}</span></td>
		<td>${escapeHtml(transaction.provider_reference || '—')}</td>
		<td>${escapeHtml(transaction.mpesa_receipt || '—')}</td>
	</tr>`).join('');
}

async function loadTransactions(append = false) {
	if (loading || document.hidden) return;
	loading = true;
	refreshButton.disabled = true;
	olderButton.disabled = true;
	status.textContent = append ? 'Loading older transactions…' : 'Refreshing transaction activity…';

	const cursor = append ? transactions.at(-1) : null;
	const { data, error } = await supabase.rpc('admin_transaction_feed', {
		p_limit: pageSize,
		p_before_created_at: cursor?.created_at || null,
		p_before_id: cursor?.payment_id || null,
	});
	if (error) {
		status.textContent = 'Transaction activity could not be refreshed. Existing results are unchanged.';
	} else {
		const results = data || [];
		if (append) {
			transactions = [...transactions, ...results];
			hasMore = results.length === pageSize;
		} else {
			const existingCount = transactions.length;
			const combined = new Map([...transactions, ...results].map((transaction) => [transaction.payment_id, transaction]));
			transactions = [...combined.values()].sort((a, b) => new Date(b.created_at) - new Date(a.created_at) || b.payment_id.localeCompare(a.payment_id));
			hasMore = results.length === pageSize || existingCount > results.length;
		}
		renderTransactions();
		olderButton.hidden = !hasMore;
		status.textContent = `Updated ${new Date().toLocaleTimeString()} · ${transactions.length.toLocaleString()} payment records loaded.`;
	}

	refreshButton.disabled = false;
	olderButton.disabled = false;
	loading = false;
}

search.addEventListener('input', renderTransactions);
refreshButton.addEventListener('click', loadTransactions);
olderButton.addEventListener('click', () => loadTransactions(true));
document.addEventListener('visibilitychange', () => {
	if (!document.hidden) loadTransactions();
});
window.setInterval(loadTransactions, 30_000);
loadTransactions();
