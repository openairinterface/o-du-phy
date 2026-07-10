#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024 OpenAirInterface Software Alliance
#
# DPAA2 / DPDK setup for NXP LX2160A — handles all three scenarios:
#
#   Power cycle  — MC firmware is fully reset; all endpoints are gone.
#                  This script reconnects dpni→dpmac and rebinds.
#   Soft reboot  — MC endpoint survives; only the vfio-fsl-mc binding is lost.
#                  Script rebinds dprc.2.
#   Crash        — VFIO state is stale; dpni MC session may be locked by the
#                  crashed process.  Script unbinds, resets, and rebinds.
#
# Must be run as root before launching nr-softmodem / libxran.
#
# Hardware layout on this board:
#   dprc.1 (IOMMU group 12)  — Linux: dpni.0/eth0 (management, dpmac.17) + dpio.0-15
#   dprc.2 (IOMMU group 13)  — DPDK: dpni.1 (FHI 7.2) + dpio.16-49 + dpbp.1-16
#
# Hugepages are allocated at boot via kernel cmdline (not handled here):
#   default_hugepagesz=1024m hugepagesz=1024m hugepages=9
#
# Usage:
#   ./dpdk_dpaa2.sh [--dprc <dprc.X>] [--dpni <dpni.X>] [--dpmac <dpmac.X>]
#                   [--mac <XX:XX:XX:XX:XX:XX>]
#
# Options:
#   --dprc    <dprc.X>              DPRC to give to DPDK          (default: dprc.2)
#   --dpni    <dpni.X>              DPNI for FHI fronthaul         (default: dpni.1)
#   --dpmac   <dpmac.X>             Physical port endpoint          (default: dpmac.8)
#   --mac     <XX:XX:XX:XX:XX:XX>   MAC address of the FHI port    (default: d0:63:b4:06:b3:f2)

set -euo pipefail

DPRC_FOR_DPDK="dprc.2"
FHI_DPNI="dpni.1"
FHI_DPMAC="dpmac.8"
FHI_MAC="d0:63:b4:06:b3:f2"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dprc)  DPRC_FOR_DPDK="$2"; shift 2 ;;
        --dpni)  FHI_DPNI="$2";      shift 2 ;;
        --dpmac) FHI_DPMAC="$2";     shift 2 ;;
        --mac)   FHI_MAC="$2";       shift 2 ;;
        *)       echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

echo "=== DPAA2 / NXP LX2160A DPDK setup ==="
echo "  DPRC:  ${DPRC_FOR_DPDK}"
echo "  DPNI:  ${FHI_DPNI} → ${FHI_DPMAC}  MAC ${FHI_MAC}"

# ---- hugepages ----------------------------------------------------------------
HP_FREE=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages 2>/dev/null || echo 0)
if [ "$HP_FREE" -eq 0 ]; then
    echo "ERROR: No free 1 GB hugepages." >&2
    echo "  Add to kernel cmdline: default_hugepagesz=1024m hugepagesz=1024m hugepages=9" >&2
    exit 1
fi
echo "1 GB hugepages free: ${HP_FREE}"

# ---- vfio-fsl-mc driver -------------------------------------------------------
if [ ! -d /sys/bus/fsl-mc/drivers/vfio-fsl-mc ]; then
    echo "Loading vfio-fsl-mc module..."
    modprobe vfio-fsl-mc
fi
echo "vfio-fsl-mc driver present"

# ---- VFIO unsafe interrupts (required for fsl-mc platform devices) ------------
VFIO_UNSAFE=/sys/module/vfio_iommu_type1/parameters/allow_unsafe_interrupts
if [ -f "$VFIO_UNSAFE" ]; then
    echo 1 > "$VFIO_UNSAFE"
    echo "allow_unsafe_interrupts enabled"
else
    echo "WARNING: ${VFIO_UNSAFE} not found; VFIO may not work" >&2
fi

# ---- unbind dprc.2 before MC endpoint changes --------------------------------
# dpni objects hold open MC sessions while dprc.2 is VFIO-bound.  restool
# disconnect fails with "Configuration error" (0x6) unless the session is
# cleared first.  Unbind here, before any endpoint surgery.
DPRC_SYSFS="/sys/bus/fsl-mc/devices/${DPRC_FOR_DPDK}"

if [ ! -d "$DPRC_SYSFS" ]; then
    echo "ERROR: ${DPRC_FOR_DPDK} not found in sysfs." >&2
    echo "  Check: ls /sys/bus/fsl-mc/devices/ | grep dprc" >&2
    exit 1
fi

if [ -L "${DPRC_SYSFS}/driver" ]; then
    CURRENT_DRV=$(basename "$(readlink "${DPRC_SYSFS}/driver")")
    if [ "$CURRENT_DRV" != "vfio-fsl-mc" ]; then
        echo "ERROR: ${DPRC_FOR_DPDK} is bound to ${CURRENT_DRV}." >&2
        echo "  Cannot bind root dprc.1 to vfio — that would break Linux networking." >&2
        exit 1
    fi
    echo "${DPRC_FOR_DPDK} already bound — unbinding before MC endpoint changes..."
    echo "${DPRC_FOR_DPDK}" > /sys/bus/fsl-mc/drivers/vfio-fsl-mc/unbind
    sleep 0.5
fi

# ---- MC endpoint setup -------------------------------------------------------
_mc_endpoint_of() {
    local obj="$1"
    local type="${obj%%.*}"
    restool "${type}" info "${obj}" 2>/dev/null \
        | grep -i "endpoint" | head -1 | awk '{print $NF}' || echo ""
}

dpni_endpoint=$(_mc_endpoint_of "${FHI_DPNI}")
if ! echo "$dpni_endpoint" | grep -q "${FHI_DPMAC}"; then
    echo "${FHI_DPNI} not connected to ${FHI_DPMAC} — running MC endpoint setup..."
    # Fully release any Linux driver bound to FHI_DPMAC's current endpoint
    # before changing it.  ip link set down is not enough — fsl_dpaa2_eth
    # keeps the dpni MC session open until the driver is unbound.  Probing
    # a dpni whose MC endpoint changes mid-probe causes kernel instability.
    _cur_ep=$(_mc_endpoint_of "${FHI_DPMAC}")
    if [ -n "$_cur_ep" ] && [ "$_cur_ep" != "${FHI_DPNI}" ]; then
        for _ndev in $(ls "/sys/bus/fsl-mc/devices/${_cur_ep}/net/" 2>/dev/null); do
            echo "  Bringing down ${_ndev} (${_cur_ep} → ${FHI_DPMAC})"
            ip link set "$_ndev" down 2>/dev/null || true
        done
        if [ -L "/sys/bus/fsl-mc/devices/${_cur_ep}/driver" ]; then
            _drv=$(basename "$(readlink "/sys/bus/fsl-mc/devices/${_cur_ep}/driver")")
            echo "  Unbinding ${_drv} from ${_cur_ep} before MC endpoint change..."
            echo "${_cur_ep}" > "/sys/bus/fsl-mc/drivers/${_drv}/unbind" 2>/dev/null || true
            sleep 0.5
        fi
    fi
    restool dprc disconnect dprc.1 --endpoint="${FHI_DPNI}"  2>/dev/null || true
    restool dprc disconnect dprc.1 --endpoint="${FHI_DPMAC}" 2>/dev/null || true
    restool dprc sync 2>/dev/null || true
    restool dprc connect dprc.1 --endpoint1="${FHI_DPNI}" --endpoint2="${FHI_DPMAC}"
    restool dprc sync 2>/dev/null || true
    echo "${FHI_DPNI} → ${FHI_DPMAC} endpoint configured"
else
    echo "${FHI_DPNI} already connected to ${FHI_DPMAC} (MC endpoint intact)"
fi

# MAC address is not persisted in the DPL, so this must run unconditionally —
# not just on the reconnect path — otherwise dpni.1 keeps its MC-assigned
# default MAC instead of the physical dpmac's address that gnb.conf expects.
restool dpni update "${FHI_DPNI}" --mac-addr="${FHI_MAC}"
echo "${FHI_DPNI} MAC set to ${FHI_MAC}"

# ---- reset dpni MC session (crash recovery) -----------------------------------
# While dprc.2 is unbound, reset dpni to clear any stale "opened" state
# left by a previous crashed DPDK run.  Ignore failures — restool dpni reset
# may not exist on all MC firmware versions.
if [ -d "/sys/bus/fsl-mc/devices/${FHI_DPNI}" ]; then
    restool dpni reset "${FHI_DPNI}" 2>/dev/null \
        && echo "${FHI_DPNI} MC session reset OK" \
        || echo "${FHI_DPNI} MC reset not available (harmless)"
fi

# ---- bind DPRC to vfio-fsl-mc ------------------------------------------------
# driver_override must be set before bind — without it the probe returns ENODEV.
echo vfio-fsl-mc > "${DPRC_SYSFS}/driver_override"
echo "${DPRC_FOR_DPDK} -> vfio-fsl-mc (binding)..."
if echo "${DPRC_FOR_DPDK}" > /sys/bus/fsl-mc/drivers/vfio-fsl-mc/bind 2>/dev/null; then
    echo "${DPRC_FOR_DPDK} bound to vfio-fsl-mc OK"
else
    echo "ERROR: Failed to bind ${DPRC_FOR_DPDK} to vfio-fsl-mc" >&2
    echo "  Check dmesg for details" >&2
    exit 1
fi

# ---- summary ------------------------------------------------------------------
VFIO_GROUP=$(basename "$(readlink "${DPRC_SYSFS}/iommu_group")" 2>/dev/null || echo "?")
echo ""
echo "Setup complete."
echo "  DPDK container:    ${DPRC_FOR_DPDK}  →  export DPRC=${DPRC_FOR_DPDK}"
echo "  FHI interface:     ${FHI_DPNI} → ${FHI_DPMAC}  MAC ${FHI_MAC}"
echo "  Management:        dprc.1 / dpni.0 / eth0 = dpmac.17 (unaffected)"
echo "  VFIO group:        /dev/vfio/${VFIO_GROUP}"
echo ""
echo "  gnb conf (fhi_72 block):"
echo "    dpdk_devices = (\"${FHI_DPNI}\");"
echo "    du_addr      = (\"${FHI_MAC}\");"
echo ""
echo "  Run nr-softmodem:"
echo "    export DPRC=${DPRC_FOR_DPDK}"
echo "    ./nr-softmodem -O <gnb.conf>"
echo ""
echo "Devices under vfio-fsl-mc:"
for d in /sys/bus/fsl-mc/devices/*/driver; do
    [ -L "$d" ] || continue
    [ "$(basename "$(readlink "$d")")" = "vfio-fsl-mc" ] || continue
    printf "  %s\n" "$(basename "$(dirname "$d")")"
done
