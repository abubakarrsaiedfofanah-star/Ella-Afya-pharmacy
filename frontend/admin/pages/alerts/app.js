import { supabase } from '../../../shared/js/supabase.js';
import { requireUser, signOut } from '../../../shared/js/auth.js';

const session = await requireUser(['admin']);
if (!session) throw new Error('Unauthorized');

const $ = (selector) => document.querySelector(selector);
const list = $('#list');
const pageSize = 50;
let activities = [];
let hasMore = true;
let loading = false;

const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (character) => ({
	'&': '&amp;',
	'<': '&lt;',
	'>': '&gt;',
	'"': '&quot;',
	"'": '&#39;',
})[character]);

$('#logout').addEventListener('click', (event) => {
	event.preventDefault();
	signOut();
});

const loadOlder = document.createElement('button');
loadOlder.type = 'button';
loadOlder.className = 'btn secondary';
loadOlder.textContent = 'Load older activity';
loadOlder.hidden = true;
list.after(loadOlder);

function renderActivities() {
	list.innerHTML = activities.length
		? activities.map((activity) => `<article class="alert-item ${activity.read_at ? '' : 'is-unread'}"><div><strong>${escapeHtml(activity.title)}</strong><div class="muted">${escapeHtml(activity.message)}</div><small>${new Date(activity.created_at).toLocaleString()} · ${escapeHtml(activity.severity)} · ${escapeHtml(activity.notification_type)}</small></div><div class="portal-tools"><span class="pill">${escapeHtml(activity.entity_type || 'activity')}</span>${activity.read_at ? '' : `<button class="btn secondary" type="button" data-read="${escapeHtml(activity.id)}">Mark read</button>`}</div></article>`).join('')
		: '<div class="muted">No business activity has been recorded yet.</div>';
	loadOlder.hidden = !hasMore;
}

async function loadActivity(append = false) {
	if (loading || document.hidden) return;
	loading = true;

	const cursor = append ? activities.at(-1) : null;
	const { data, error } = await supabase.rpc('admin_activity_feed', {
		p_limit: pageSize,
		p_before_created_at: cursor?.created_at || null,
		p_before_id: cursor?.id || null,
	});

	if (error) {
		$('#msg').textContent = 'Business activity could not be refreshed.';
	} else {
		const results = data || [];
		if (append) {
			activities = [...activities, ...results];
			hasMore = results.length === pageSize;
		} else {
			const previousCount = activities.length;
			const merged = new Map([...activities, ...results].map((activity) => [activity.id, activity]));
			activities = [...merged.values()].sort((a, b) => new Date(b.created_at) - new Date(a.created_at) || b.id.localeCompare(a.id));
			hasMore = results.length === pageSize || previousCount > results.length;
		}
		renderActivities();
		$('#msg').textContent = `${activities.length.toLocaleString()} business events loaded. Updated ${new Date().toLocaleTimeString()}.`;
	}

	loading = false;
}

async function loadSummary() {
	const { data, error } = await supabase.rpc('admin_notification_snapshot');
	if (error) {
		$('#msg').textContent = 'Business activity summary is unavailable.';
		return;
	}

	const summary = data || {};
	$('#low').textContent = summary.low_stock || 0;
	$('#expiring').textContent = summary.expiring_batches || 0;
	$('#expired').textContent = summary.expired_batches || 0;
	$('#approvals').textContent = Number(summary.pending_refunds || 0) + Number(summary.pending_adjustments || 0);
	$('#security').textContent = summary.open_security_alerts || 0;
}

async function refresh() {
	if (document.hidden) return;
	await Promise.all([loadSummary(), loadActivity()]);
}

list.addEventListener('click', async (event) => {
	const button = event.target.closest('[data-read]');
	if (!button) return;
	button.disabled = true;
	const { error } = await supabase.from('operational_notifications')
		.update({ read_at: new Date().toISOString() })
		.eq('id', button.dataset.read);
	if (error) {
		button.disabled = false;
		$('#msg').textContent = 'This activity could not be marked as read.';
		return;
	}
	const item = activities.find((activity) => activity.id === button.dataset.read);
	if (item) item.read_at = new Date().toISOString();
	renderActivities();
});

loadOlder.addEventListener('click', () => loadActivity(true));
$('#generate').addEventListener('click', async () => {
	const { error } = await supabase.rpc('generate_operational_notifications');
	if (error) $('#msg').textContent = error.message;
	else await refresh();
});
$('#reload').addEventListener('click', refresh);
$('#stockCount').addEventListener('click', async () => {
	const notes = prompt('Optional stock-count note:') ?? '';
	const { data, error } = await supabase.rpc('admin_create_stock_count', { p_notes: notes });
	$('#msg').textContent = error ? error.message : `Stock count created: ${data}`;
	if (!error) await refresh();
});

await refresh();
window.setInterval(refresh, 30_000);
document.addEventListener('visibilitychange', () => {
	if (!document.hidden) refresh();
});
