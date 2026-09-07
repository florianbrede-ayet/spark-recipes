#!/bin/bash
# ---------------------------------------------------------------------------
# 05-setup-network.sh — cluster fabric configuration for BOTH RoCE rails.
#
# DEFAULT BEHAVIOUR IS TO PRINT THE PLANNED nmcli COMMANDS AND EXIT.
# Nothing is executed without --apply, and --apply additionally requires an
# interactive confirmation, because reconfiguring a rail on a live node drops
# RDMA and can strand a remote session.
#
# ROLE DETECTION
#   This is the one script that must work before the fabric exists, so it
#   identifies the node from MANAGEMENT identity only — the management IP, or
#   an explicitly configured hostname mapping as a fallback. It never infers a
#   role from a fabric address it is about to create. Matching both roles, or
#   neither, is fatal rather than a guess.
#
#   Every other script keeps its full fabric-based identity check. This
#   relaxation is local to network bootstrap and does not weaken them.
#
# WHAT IT CONFIGURES — the audited state, both rails, by default
#   rail A  cx7-port0-a  enp1s0f0np0   / rocep1s0f0    10.0.7.1|.2 /30  metric 101
#   rail B  cx7-port0-b  enP2p1s0f0np0 / roceP2p1s0f0  10.0.7.5|.6 /30  metric 100
#   both: MTU 9000, ipv4.method manual, no gateway, never-default, no DNS,
#         IPv6 disabled, autoconnect on, and on SEPARATE subnets.
#   The management NIC is never touched.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: 05-setup-network.sh [--rail a|b|both] [--apply] [--yes] [--verify]

  --rail <a|b|both>  Which rail(s) to act on. Default: both — the audited node
                     carries both, and configuring only one leaves the cluster
                     in a state this recipe never had.
  --verify           Read-only: check the live state of the selected rail(s)
                     against the audited configuration and exit.
  --apply            Actually run the nmcli commands. Requires confirmation.
  --yes              Skip the interactive confirmation (only with --apply).

Without --apply this prints the exact nmcli command list and changes nothing.
USAGE
}

RAIL="both"
VERIFY_ONLY="false"
while [[ $# -gt 0 ]]; do
    if common_parse_flag "$1"; then shift; continue; fi
    case "$1" in
        --rail) RAIL="${2:-}"; shift ;;
        --verify) VERIFY_ONLY="true" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done
case "$RAIL" in a|b|both) ;; *) die "--rail must be a, b, or both" ;; esac

load_cluster
detect_role_mgmt

want_a() { [[ "$RAIL" == "a" || "$RAIL" == "both" ]]; }
want_b() { [[ "$RAIL" == "b" || "$RAIL" == "both" ]]; }

if [[ "$ROLE" == "primary" ]]; then
    A_ADDR="${PRIMARY_FABRIC_IP}/30"; B_ADDR="${PRIMARY_FABRIC_B_IP}/30"
else
    A_ADDR="${WORKER_FABRIC_IP}/30";  B_ADDR="${WORKER_FABRIC_B_IP}/30"
fi
A_METRIC="${FABRIC_ROUTE_METRIC:-101}"
B_METRIC="${FABRIC_B_ROUTE_METRIC:-100}"

# --- subnet arithmetic ------------------------------------------------------
net_of() {  # <addr/plen> -> network/plen
    local IFS=. a b c d plen ai mask
    plen="${1##*/}"; read -r a b c d <<<"${1%%/*}"
    ai=$(( (a << 24) + (b << 16) + (c << 8) + d ))
    mask=$(( (0xFFFFFFFF << (32 - plen)) & 0xFFFFFFFF ))
    ai=$(( ai & mask ))
    printf '%d.%d.%d.%d/%s' $(( (ai >> 24) & 255 )) $(( (ai >> 16) & 255 )) $(( (ai >> 8) & 255 )) $(( ai & 255 )) "$plen"
}
if [[ "$(net_of "$A_ADDR")" == "$(net_of "$B_ADDR")" ]]; then
    die "rail A (${A_ADDR}) and rail B (${B_ADDR}) resolve to the same subnet $(net_of "$A_ADDR"). Two RoCE rails on one subnet cause ARP flux and non-deterministic NCCL rail selection. Fix config/cluster.env."
fi
ok "rails are on separate subnets: $(net_of "$A_ADDR") and $(net_of "$B_ADDR")"

# --- the audited property set ----------------------------------------------
# One list, used to build the nmcli command AND to verify it afterwards.
nm_props() {   # <iface> <addr/plen> <mtu> <metric>
    printf '%s\n' \
        "connection.interface-name|$1" \
        "ipv4.method|manual" \
        "ipv4.addresses|$2" \
        "ipv4.gateway|" \
        "ipv4.never-default|yes" \
        "ipv4.ignore-auto-dns|yes" \
        "ipv4.dns|" \
        "ipv4.dns-search|" \
        "ipv4.route-metric|$4" \
        "ipv6.method|disabled" \
        "802-3-ethernet.mtu|$3" \
        "connection.autoconnect|yes"
}

plan_rail() {  # <profile> <iface> <addr> <mtu> <metric> <label>
    local profile="$1" iface="$2" addr="$3" mtu="$4" metric="$5" label="$6"
    hdr "Plan: ${label} — profile '${profile}' on ${iface}"
    local args="" kv
    while IFS='|' read -r k v; do args+=" ${k} '${v}'"; done < <(nm_props "$iface" "$addr" "$mtu" "$metric")
    show_cmd "sudo nmcli connection add type ethernet con-name ${profile} ifname ${iface} \\"
    show_cmd "   ${args# }"
    echo
    show_cmd "# if the profile already exists, modify instead of add:"
    show_cmd "sudo nmcli connection modify ${profile} \\"
    show_cmd "   ${args# }"
    echo
    show_cmd "sudo nmcli connection up ${profile}"
}

apply_rail() {  # <profile> <iface> <addr> <mtu> <metric>
    local profile="$1" iface="$2" addr="$3" mtu="$4" metric="$5"
    need_cmd nmcli
    local -a props=()
    while IFS='|' read -r k v; do props+=("$k" "$v"); done < <(nm_props "$iface" "$addr" "$mtu" "$metric")

    if nmcli -g NAME connection show 2>/dev/null | grep -qx "$profile"; then
        run_or_show "modify ${profile}" -- sudo nmcli connection modify "$profile" "${props[@]}"
    else
        run_or_show "add ${profile}" -- sudo nmcli connection add type ethernet \
            con-name "$profile" ifname "$iface" "${props[@]}"
    fi
    run_or_show "bring up ${profile}" -- sudo nmcli connection up "$profile"
}

# --- verification (read-only) ----------------------------------------------
VERIFY_FAILS=0
vfail() { printf '[fail] %s\n' "$*" >&2; VERIFY_FAILS=$((VERIFY_FAILS + 1)); }

verify_rail() {  # <profile> <iface> <addr> <mtu> <metric> <ib> <label>
    local profile="$1" iface="$2" addr="$3" mtu="$4" metric="$5" ib="$6" label="$7"
    hdr "Verify: ${label} — ${profile} on ${iface}"

    if command -v nmcli >/dev/null 2>&1; then
        if nmcli -g NAME connection show 2>/dev/null | grep -qx "$profile"; then
            ok "profile '${profile}' exists"
            local k want got
            while IFS='|' read -r k want; do
                got="$(nmcli -g "$k" connection show "$profile" 2>/dev/null || true)"
                # nmcli renders unset values as "" or "--"; normalise both.
                [[ "$got" == "--" ]] && got=""
                if [[ "$got" == "$want" ]]; then
                    ok "  ${k} = ${got:-<unset>}"
                else
                    vfail "  ${k} = '${got}', expected '${want}'"
                fi
            done < <(nm_props "$iface" "$addr" "$mtu" "$metric")
        else
            vfail "NetworkManager profile '${profile}' does not exist"
        fi
    else
        warn "nmcli not available; profile properties unverified"
    fi

    # Live kernel state, which is what actually carries the job.
    if have_iface "$iface"; then
        local st m a
        st="$(iface_state "$iface")"; m="$(iface_mtu "$iface")"; a="$(iface_ipv4 "$iface")"
        [[ "$st" == "UP" ]]   && ok "  link UP"          || vfail "  link is ${st}, expected UP"
        [[ "$m" == "$mtu" ]]  && ok "  MTU ${m}"          || vfail "  MTU ${m}, expected ${mtu}"
        [[ "$a" == "$addr" ]] && ok "  address ${a}"      || vfail "  address '${a:-none}', expected ${addr}"

        local rt; rt="$(ip -4 route show dev "$iface" 2>/dev/null | grep -m1 'proto kernel' || true)"
        if [[ -n "$rt" ]]; then
            local got_metric; got_metric="$(sed -nE 's/.*metric ([0-9]+).*/\1/p' <<<"$rt")"
            [[ "$got_metric" == "$metric" ]] && ok "  route metric ${got_metric}" \
                || vfail "  route metric '${got_metric:-unset}', expected ${metric}"
        else
            vfail "  no connected route on ${iface}"
        fi

        if ip -4 route show default dev "$iface" 2>/dev/null | grep -q .; then
            vfail "  ${iface} carries a DEFAULT route; a fabric rail must never be the default"
        else
            ok "  no default route via ${iface}"
        fi
    else
        vfail "  interface ${iface} is not present"
    fi

    local rst; rst="$(rdma_state "$ib")"
    case "$rst" in
        ACTIVE)  ok "  RDMA ${ib} ACTIVE" ;;
        unknown) warn "  rdma(8) unavailable; ${ib} unverified" ;;
        *)       vfail "  RDMA ${ib} is '${rst:-missing}', expected ACTIVE" ;;
    esac
}

if [[ "$VERIFY_ONLY" == "true" ]]; then
    want_a && verify_rail "$FABRIC_NM_PROFILE"   "$FABRIC_ETH_IF"   "$A_ADDR" "$FABRIC_MTU"   "$A_METRIC" "$FABRIC_IB_IF"   "rail A (used by the job)"
    want_b && verify_rail "$FABRIC_B_NM_PROFILE" "$FABRIC_B_ETH_IF" "$B_ADDR" "$FABRIC_B_MTU" "$B_METRIC" "$FABRIC_B_IB_IF" "rail B (twin, idle)"
    hdr "Result"
    if [[ $VERIFY_FAILS -eq 0 ]]; then
        ok "selected rail(s) match the audited configuration"
        exit 0
    fi
    die "${VERIFY_FAILS} rail check(s) failed"
fi

dryrun_banner
want_a && plan_rail "$FABRIC_NM_PROFILE"   "$FABRIC_ETH_IF"   "$A_ADDR" "$FABRIC_MTU"   "$A_METRIC" "rail A (used by the job)"
want_b && plan_rail "$FABRIC_B_NM_PROFILE" "$FABRIC_B_ETH_IF" "$B_ADDR" "$FABRIC_B_MTU" "$B_METRIC" "rail B (twin, idle)"

echo
show_cmd "# then verify with:"
show_cmd "scripts/05-setup-network.sh --rail ${RAIL} --verify"

if ! is_apply; then
    echo
    info "plan only. Review the commands above, then re-run with --apply to execute them."
    exit 0
fi

TARGETS=""
want_a && TARGETS="rail A ${A_ADDR} on ${FABRIC_ETH_IF}"
want_b && TARGETS="${TARGETS:+${TARGETS}; }rail B ${B_ADDR} on ${FABRIC_B_ETH_IF}"
confirm "reconfigure ${TARGETS} on the ${ROLE} node. This bounces RDMA and can drop connectivity on those interfaces." "RECONFIGURE"

want_a && apply_rail "$FABRIC_NM_PROFILE"   "$FABRIC_ETH_IF"   "$A_ADDR" "$FABRIC_MTU"   "$A_METRIC"
want_b && apply_rail "$FABRIC_B_NM_PROFILE" "$FABRIC_B_ETH_IF" "$B_ADDR" "$FABRIC_B_MTU" "$B_METRIC"

hdr "Verifying what was just applied"
want_a && verify_rail "$FABRIC_NM_PROFILE"   "$FABRIC_ETH_IF"   "$A_ADDR" "$FABRIC_MTU"   "$A_METRIC" "$FABRIC_IB_IF"   "rail A (used by the job)"
want_b && verify_rail "$FABRIC_B_NM_PROFILE" "$FABRIC_B_ETH_IF" "$B_ADDR" "$FABRIC_B_MTU" "$B_METRIC" "$FABRIC_B_IB_IF" "rail B (twin, idle)"

hdr "Result"
if [[ $VERIFY_FAILS -eq 0 ]]; then
    ok "network configuration applied and verified."
    exit 0
fi
die "configuration was applied but ${VERIFY_FAILS} check(s) still fail — the fabric is not in the audited state."
