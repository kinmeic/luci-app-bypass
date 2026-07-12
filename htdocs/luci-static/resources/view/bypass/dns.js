'use strict';
'require view';
'require form';

return view.extend({
	render: function () {
		var m = new form.Map('bypass', _('DNS'), _('ChinaDNS-NG split DNS.'));

		var s = m.section(form.NamedSection, 'global_dns', 'global_dns', _('ChinaDNS-NG'));

		var o;

		o = s.option(form.Value, 'domestic_dns', _('Domestic DNS (china-dns)'));
		o.description = _('Resolves domestic domains. "auto" = detect ISP DNS from resolv.conf.');
		o.placeholder = 'auto';

		o = s.option(form.Value, 'remote_dns', _('Remote / Foreign DNS (trust-dns)'));
		o.description = _('Resolves foreign domains; their IPs are routed through the proxy.');
		o.placeholder = '1.1.1.1';

		o = s.option(form.ListValue, 'remote_dns_protocol', _('Remote DNS protocol'));
		o.value('udp', _('UDP'));
		o.value('tcp', _('TCP'));
		o.value('tls', _('TLS (DoT)'));
		o.value('https', _('HTTPS (DoH)'));

		o = s.option(form.ListValue, 'query_strategy', _('Query strategy'));
		o.value('UseIPv4', _('IPv4 only'));
		o.value('UseIPv6', _('IPv6 only'));
		o.value('UseIP', _('IPv4 + IPv6'));

		o = s.option(form.Value, 'chinadns_listen_port', _('ChinaDNS-NG listen port'));
		o.datatype = 'port';
		o.placeholder = '10553';

		return m.render();
	}
});
