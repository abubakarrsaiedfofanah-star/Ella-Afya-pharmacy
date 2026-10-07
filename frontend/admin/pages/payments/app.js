import { supabase } from '../../../shared/js/supabase.js';
import { requireUser } from '../../../shared/js/auth.js';

await requireUser(['admin']);

const rows = document.querySelector('#rows');
const search = document.querySelector('#transactionSearch');
const status = document.querySelector('#transactionStatus');
const refreshButton = document.querySelector('#refreshTransactions');
const olderButton = document.querySelector('#loadOlderTransactions');
const c2bRows = document.querySelector('#c2bRows');
const c2bStatus = document.querySelector('#c2bStatus');
let transactions = [];
let loading = false;
let hasMore = true;
let c2bLoading = false;
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
		transaction.verified_by_name,
		transaction.verification_source,
	].some((value) => String(value || '').toLowerCase().includes(term)));

	document.querySelector('#transactionCount').textContent = visible.length.toLocaleString();
	const paidTotal = visible.reduce((total, transaction) => transaction.status === 'paid' ? total + Number(transaction.amount || 0) : total, 0);
	document.querySelector('#paidAmount').textContent = money(paidTotal);

	if (!visible.length) {
		rows.innerHTML = `<tr><td colspan="9" class="muted">${term ? 'No transactions match this search.' : 'No transactions recorded yet.'}</td></tr>`;
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
		<td>${transaction.verification_source==='seller_attested'?'Seller reported — not Safaricom verified':escapeHtml(transaction.verified_by_name || '—')}<br><small>${escapeHtml(transaction.verification_source || 'unknown')} · ${transaction.confirmed_at ? escapeHtml(new Date(transaction.confirmed_at).toLocaleString()) : 'not confirmed'}</small></td>
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

async function loadUnmatchedC2b() {
	if (c2bLoading || document.hidden) return;
	c2bLoading = true;
	document.querySelector('#refreshC2b').disabled = true;
	c2bStatus.textContent = 'Refreshing confirmed PayBill payments…';
	const { data, error } = await supabase.from('mpesa_c2b_transactions')
		.select('trans_id,account_reference,amount,phone_number,payer_name,transaction_time,received_at')
		.eq('status', 'unmatched').order('received_at', { ascending: false }).limit(100);
	if (error) {
		c2bStatus.textContent = `PayBill payments could not be loaded: ${error.message}`;
	} else if (!data?.length) {
		c2bRows.innerHTML = '<tr><td colspan="7" class="muted">No unmatched PayBill payments.</td></tr>';
		c2bStatus.textContent = 'Incoming PayBill confirmations will appear here.';
	} else {
		c2bRows.innerHTML = data.map((payment) => `<tr>
			<td>${escapeHtml(new Date(payment.transaction_time || payment.received_at).toLocaleString())}</td>
			<td>${escapeHtml(payment.account_reference)}</td>
			<td>${money(payment.amount)}</td>
			<td><strong>${escapeHtml(payment.trans_id)}</strong></td>
			<td>${escapeHtml([payment.payer_name, payment.phone_number].filter(Boolean).join(' · ') || 'Not provided')}</td>
			<td><label class="visually-hidden" for="sale-${escapeHtml(payment.trans_id)}">Sale number for receipt ${escapeHtml(payment.trans_id)}</label><input id="sale-${escapeHtml(payment.trans_id)}" data-sale-for="${escapeHtml(payment.trans_id)}" placeholder="e.g. SALE-…" autocomplete="off"></td>
			<td><button class="btn" type="button" data-match-c2b="${escapeHtml(payment.trans_id)}">Match payment</button></td>
		</tr>`).join('');
		c2bStatus.textContent = `${data.length} unmatched PayBill payment${data.length === 1 ? '' : 's'} shown (maximum 100).`;
	}
	document.querySelector('#refreshC2b').disabled = false;
	c2bLoading = false;
}

document.querySelector('#refreshC2b').addEventListener('click', loadUnmatchedC2b);
c2bRows.addEventListener('click', async (event) => {
	const button = event.target.closest('[data-match-c2b]');
	if (!button) return;
	const receipt = button.dataset.matchC2b;
	const input = c2bRows.querySelector(`[data-sale-for="${CSS.escape(receipt)}"]`);
	const saleNumber = input?.value.trim();
	if (!saleNumber) { c2bStatus.textContent = 'Enter the sale number to match this payment.'; input?.focus(); return; }
	button.disabled = true;
	c2bStatus.textContent = `Matching receipt ${receipt}…`;
	const { data: remaining, error } = await supabase.rpc('admin_match_mpesa_c2b', { p_trans_id: receipt, p_sale_number: saleNumber });
	if (error) {
		c2bStatus.textContent = `Payment was not matched: ${error.message}`;
		button.disabled = false;
		return;
	}
	c2bStatus.textContent = Number(remaining) <= 0.01 ? `Receipt ${receipt} matched; sale is fully paid.` : `Receipt ${receipt} matched. Sale balance remaining: ${money(remaining)}.`;
	await Promise.all([loadUnmatchedC2b(), loadTransactions()]);
});

search.addEventListener('input', renderTransactions);
refreshButton.addEventListener('click', () => { loadTransactions(); loadUnmatchedC2b(); });
olderButton.addEventListener('click', () => loadTransactions(true));
document.addEventListener('visibilitychange', () => {
	if (!document.hidden) { loadTransactions(); loadUnmatchedC2b(); }
});
window.setInterval(loadTransactions, 30_000);
window.setInterval(loadUnmatchedC2b, 30_000);
loadTransactions();
loadUnmatchedC2b();
