#!/bin/sh
# Copyright (c) 2026 Eugene Chan
# SPDX-License-Identifier: MIT
#
# nftables transparent-proxy backend for luci-app-bypass.
#
# One table is managed:
#   table inet bypass        - the redirect/tproxy ruleset + the bypass_chn /
#                              bypass_vps sets (the latter filled at runtime by
#                              chinadns-ng via add-tagchn-ip / group-ipset).
#
# Sources utils.sh (via app.sh) for $REDIR_PORT, $TCP_PROXY_WAY, $TCP_REDIR_PORTS,
# $UDP_REDIR_PORTS and cache helpers.

# app.sh sources this file during service start. Firewall reloads and hotplug
# actions execute it directly, so initialize the shared helpers and reload the
# persisted runtime port/config in that case.
if ! type first_type >/dev/null 2>&1; then
	. ${APP_PATH:-/usr/share/bypass}/utils.sh
fi

load_standalone_config() {
	[ -n "$TCP_PROXY_WAY" ] && return 0
	[ "$(config_t_get global enabled 0)" = "1" ] || return 1
	REDIR_PORT=$(get_cache_var ACL_GLOBAL_redir_port)
	[ -n "$REDIR_PORT" ] || return 1
	TCP_PROXY_WAY=$(config_t_get global_forwarding tcp_proxy_way redirect)
	TCP_NO_REDIR_PORTS=$(config_t_get global_forwarding tcp_no_redir_ports disable)
	UDP_NO_REDIR_PORTS=$(config_t_get global_forwarding udp_no_redir_ports disable)
	TCP_REDIR_PORTS=$(config_t_get global_forwarding tcp_redir_ports 1:65535)
	UDP_REDIR_PORTS=$(config_t_get global_forwarding udp_redir_ports 1:65535)
	CLIENT_PROXY=$(config_t_get global client_proxy 1)
}

NFT=$(first_type /usr/sbin/nft nft)
NFT_TABLE=bypass
INCLUDE_FILE=/var/etc/bypass.include

# Port-list "1:65535" / "80,443" / "80-90" -> nft range/set syntax helper.
# Returns empty for "disable" (meaning: do not redirect that protocol).
nft_port_expr() {
	local v=$1
	[ "$v" = "disable" ] && { echo ""; return; }
	echo "$v" | grep -qE '^[0-9]+([:-][0-9]+)?(,[0-9]+([:-][0-9]+)?)*$' || {
		log 0 "Invalid port expression rejected: %s" "$v"
		echo ""
		return 1
	}
	# Convert a:b form and comma list into a nft set of ports/ranges.
	echo "$v" | sed -e 's/:/-/g' -e 's/,/, /g'
}

# Apply a ruleset string via a temp file (atomic).
nft_apply() {
	local ruleset=$1
	local tmp="$TMP_PATH2/nft-ruleset"
	mkdir -p "$TMP_PATH2"
	printf '%s\n' "$ruleset" > "$tmp"
	$NFT -f "$tmp" 2>>"$LOG_FILE"
}

nft_start() {
	load_standalone_config || { log 0 "Bypass is disabled or has no active redirect port; skip firewall rules."; return 0; }
	[ -z "$NFT" ] && { log 0 "nft not found; cannot install nftables rules."; return 1; }
	mkdir -p "$(dirname "$INCLUDE_FILE")"

	# Drop any prior table first. `delete table` errors if the table doesn't
	# exist yet (first run), so ignore its stderr; this makes the (re)install
	# idempotent without relying on `flush table` (which also errors when the
	# table is absent and would abort the whole ruleset load below).
	$NFT delete table inet ${NFT_TABLE} 2>/dev/null

	local tcp_expr udp_expr tcp_no_expr udp_no_expr
	tcp_expr=$(nft_port_expr "$TCP_REDIR_PORTS")
	udp_expr=$(nft_port_expr "$UDP_REDIR_PORTS")
	tcp_no_expr=$(nft_port_expr "$TCP_NO_REDIR_PORTS")
	udp_no_expr=$(nft_port_expr "$UDP_NO_REDIR_PORTS")

	local mode=$TCP_PROXY_WAY
	# naive upstream builds support redir everywhere; tproxy only in builds
	# compiled with it. Treat anything other than tproxy as redirect.
	[ "$mode" = "tproxy" ] || mode=redirect

	# Sets shared with chinadns-ng (filled at runtime). Keep router-local
	# addresses in a set as well so management traffic is never intercepted.
	local sets local_elements="" local_ip
	for local_ip in $(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
		local_elements="${local_elements:+$local_elements, }$local_ip"
	done
	[ -n "$local_elements" ] || local_elements=127.0.0.1
	sets=$(cat <<EOF
table inet ${NFT_TABLE} {
	set bypass_local {
		type ipv4_addr
		elements = { ${local_elements} }
	}
	set bypass_chn {
		type ipv4_addr
		size 65536
		flags interval
	}
	set bypass_chn6 {
		type ipv6_addr
		size 65536
		flags interval
	}
	set bypass_vps {
		type ipv4_addr
		size 1024
	}
	set bypass_vps6 {
		type ipv6_addr
		size 1024
	}
EOF
)

	local wan_accept="" wan_devices="" dev
	for dev in $(ip -o -4 route show default 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1) }' | sort -u); do
		wan_devices="${wan_devices:+$wan_devices, }\"$dev\""
	done
	[ -n "$wan_devices" ] && wan_accept="iifname { ${wan_devices} } accept"
	# BypassCore, not the firewall approximation, owns all live shunt decisions.
	local china_accept=""

	local nat_chain="" mangle_chain=""
	# Redirect mode: NAT PREROUTING REDIRECT for TCP.
	if [ "$CLIENT_PROXY" = "1" ] && [ "$mode" = "redirect" ] && [ -n "$tcp_expr" ]; then
		nat_chain="chain prerouting { type nat hook prerouting priority -100; policy accept;
			ip daddr @bypass_vps accept
			${china_accept}
			ip daddr @bypass_local accept
			${wan_accept}
			iif lo accept
			${tcp_no_expr:+meta l4proto tcp tcp dport { ${tcp_no_expr} } accept}
			meta l4proto tcp tcp dport { ${tcp_expr} } redirect to :${REDIR_PORT}
		}"
	fi
	# TProxy mode: mangle PREROUTING TPROXY for TCP+UDP (needs the local-route setup).
	if [ "$CLIENT_PROXY" = "1" ] && [ "$mode" = "tproxy" ]; then
		[ -n "$tcp_expr" ] && mangle_chain="chain prerouting { type filter hook prerouting priority mangle; policy accept;
			ip daddr @bypass_vps accept
			${china_accept}
			ip daddr @bypass_local accept
			${wan_accept}
			iif lo accept
			${tcp_no_expr:+meta l4proto tcp tcp dport { ${tcp_no_expr} } accept}
			meta l4proto tcp tcp dport { ${tcp_expr} } tproxy ip to 127.0.0.1:${REDIR_PORT} meta mark set meta mark | 0x10000 accept
		}"
		[ -n "$udp_expr" ] && mangle_chain="${mangle_chain}
		chain prerouting_udp { type filter hook prerouting priority mangle; policy accept;
			ip daddr @bypass_vps accept
			${china_accept}
			ip daddr @bypass_local accept
			${wan_accept}
			iif lo accept
			${udp_no_expr:+meta l4proto udp udp dport { ${udp_no_expr} } accept}
			meta l4proto udp udp dport { ${udp_expr} } tproxy ip to 127.0.0.1:${REDIR_PORT} meta mark set meta mark | 0x10000 accept
		}"
		# Preserve mwan3/PBR marks in the low bits and reserve one high bit only.
		while ip rule del priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null; do :; done
		ip rule add priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null || {
			log 0 "Could not install the TPROXY policy rule."
			return 1
		}
		ip route replace local 0.0.0.0/0 dev lo proto 99 table 20100 2>/dev/null || {
			ip rule del priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null
			log 0 "Could not install the TPROXY local route."
			return 1
		}
	fi

	local ruleset="${sets}
	${nat_chain}
	${mangle_chain}
	}"
	nft_apply "$ruleset" || {
		while ip rule del priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null; do :; done
		ip route flush table 20100 proto 99 2>/dev/null
		log 0 "nft ruleset apply failed."
		return 1
	}

	# Pre-populate bypass_vps with every node server IP (literal or resolved),
	# otherwise the transparent OUTPUT rule can proxy the proxy's own tunnel.
	local ip node address
	for node in $(uci -q show "$CONFIG" 2>/dev/null | sed -n 's/^bypass\.\([^.=]*\)=nodes$/\1/p'); do
		address=$(config_n_get "$node" address)
		for ip in $(resolve_all_ipv4 "$address"); do
			[ -n "$ip" ] && $NFT add element inet ${NFT_TABLE} bypass_vps "{ $ip }" 2>/dev/null
		done
	done
	for ip in $(get_wan_ips ip4); do
		$NFT add element inet ${NFT_TABLE} bypass_vps "{ $ip }" 2>/dev/null
	done

	nft_gen_include
	log 0 "nftables ruleset installed (mode=%s, redir_port=%s)." "$mode" "$REDIR_PORT"
}

nft_stop() {
	# Remove tproxy local-route scaffolding if present.
	while ip rule del priority 998 fwmark 0x10000/0x10000 lookup 20100 2>/dev/null; do :; done
	ip route flush table 20100 proto 99 2>/dev/null
	[ -n "$NFT" ] && $NFT delete table inet ${NFT_TABLE} 2>/dev/null
	rm -f "$INCLUDE_FILE" 2>/dev/null
	log 0 "nftables ruleset removed."
}

# Write the fw4 include script so the ruleset survives firewall reloads.
nft_gen_include() {
	mkdir -p "$(dirname "$INCLUDE_FILE")"
	cat <<-EOF > "$INCLUDE_FILE"
		#!/bin/sh
		${APP_PATH}/nftables.sh start
	EOF
	chmod +x "$INCLUDE_FILE" 2>/dev/null
}

# Cheap WAN-IP refresh on hotplug ifupdate (no full restart).
nft_update_wan_sets() {
	[ -z "$NFT" ] && return 0
	# Re-add current WAN IPs to bypass_vps so the router's own egress stays direct.
	local wan
	wan=$(get_wan_ips ip4)
	[ -n "$wan" ] && $NFT add element inet ${NFT_TABLE} bypass_vps "{ $wan }" 2>/dev/null
}

# Dispatch (app.sh sources this file then calls $1, or we dispatch on $1 directly).
case "${1:-start}" in
	start)        nft_start ;;
	stop)         nft_stop ;;
	gen_include)  nft_gen_include ;;
	update_wan_sets) nft_update_wan_sets ;;
esac
