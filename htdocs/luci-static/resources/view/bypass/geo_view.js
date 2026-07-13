'use strict';
'require view';
'require fs';
'require ui';

// Geo View — query page mirroring passwall2's rule/geoview.htm.
// Two query modes:
//   • Domain/IP Query (lookup): enter a domain or IP → which geo rule lists it belongs to.
//   • GeoIP/Geosite Query (extract): enter geoip:cn / geosite:gfw → extract member domains/IPs.
// Both write into a shared readonly textarea. Calls api.sh geo_view which wraps
// the geoview binary with correct -type / -input / -value|-list flags.

function api(/* action, ...args */) {
	return fs.exec('/usr/share/bypass/api.sh', Array.prototype.slice.call(arguments)).then(function (res) {
		try { return JSON.parse(res.stdout || '{}'); }
		catch (e) { return { code: -1, error: 'bad JSON' }; }
	}).catch(function (e) { return { code: -1, error: String(e) }; });
}

return view.extend({
	render: function () {
		var result = E('textarea', {
			id: 'geoview_textarea',
			class: 'cbi-input-textarea',
			style: 'width:100%;margin-top:10px;font-family:monospace;font-size:12px',
			rows: 25,
			wrap: 'off',
			readonly: 'readonly',
			placeholder: _('Results appear here.')
		});

		function doQuery(btn, action, input) {
			var value = (input.value || '').trim();
			if (!value) {
				ui.addNotification(null, E('p', {}, _('Please enter query content!')));
				return;
			}
			btn.disabled = true;
			var oldLabel = btn.textContent;
			btn.textContent = _('Querying…');
			result.value = '';
			api('geo_view', action, value).then(function (r) {
				btn.disabled = false;
				btn.textContent = oldLabel;
				if (r.code === 0) {
					result.value = r.output || _('No results were found!');
				} else {
					result.value = _('Error: ') + (r.error || r.output || _('unknown'));
				}
			});
		}

		function bindEnter(input, btn, action) {
			input.addEventListener('keydown', function (ev) {
				if (ev.key === 'Enter') { ev.preventDefault(); doQuery(btn, action, input); }
			});
		}

		var lookupInput = E('input', {
			type: 'text',
			id: 'geoview.lookup',
			class: 'cbi-input-text',
			style: 'flex:1;min-width:200px',
			placeholder: _('Enter a domain or IP')
		});
		var lookupBtn = E('button', {
			id: 'lookup-view_btn',
			class: 'cbi-button cbi-button-apply'
		}, _('Query'));
		lookupBtn.addEventListener('click', function () { doQuery(lookupBtn, 'lookup', lookupInput); });
		bindEnter(lookupInput, lookupBtn, 'lookup');

		var extractInput = E('input', {
			type: 'text',
			id: 'geoview.extract',
			class: 'cbi-input-text',
			style: 'flex:1;min-width:200px',
			placeholder: 'geoip:cn / geosite:gfw'
		});
		var extractBtn = E('button', {
			id: 'extract-view_btn',
			class: 'cbi-button cbi-button-apply'
		}, _('Query'));
		extractBtn.addEventListener('click', function () { doQuery(extractBtn, 'extract', extractInput); });
		bindEnter(extractInput, extractBtn, 'extract');

		return E('div', { class: 'cbi-map', style: 'margin-bottom:2rem' }, [
			E('h2', { name: 'content' }, _('Geo View')),
			E('div', { class: 'cbi-section-descr' }, [
				E('ul', { style: 'margin:0;padding-left:1.2em' }, [
					E('li', {}, _('By entering a domain or IP, you can query the Geo rule list they belong to.')),
					E('li', {}, _('By entering a GeoIP or Geosite, you can extract the domains/IPs they contain.')),
					E('li', {}, _('Use the GeoIP/Geosite query function to verify if the entered Geo rules are correct.'))
				])
			]),

			/* Domain/IP Query */
			E('div', { class: 'cbi-section', style: 'margin-top:1rem' }, [
				E('h3', {}, _('Domain/IP Query')),
				E('div', { style: 'font-size:12px;color:#8898aa;margin-bottom:8px' },
					_('Enter a domain or IP to query the Geo rule list they belong to.')),
				E('div', { style: 'display:flex;gap:8px;align-items:center' }, [
					lookupInput, lookupBtn
				]),
				result
			]),

			/* GeoIP/Geosite Query */
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, _('GeoIP/Geosite Query')),
				E('div', { style: 'font-size:12px;color:#8898aa;margin-bottom:8px' },
					_('Enter a GeoIP or Geosite to extract the domains/IPs they contain. Format: geoip:cn or geosite:gfw')),
				E('div', { style: 'display:flex;gap:8px;align-items:center' }, [
					extractInput, extractBtn
				])
			])
		]);
	},

	handleReset: null,
	handleSaveApply: null,
	handleSave: null
});
