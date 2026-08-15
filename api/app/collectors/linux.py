"""Collecteur Linux agentless : une seule commande SSH par cycle.

On lit /proc et /sys, on renvoie des sections délimitées, et les compteurs
cumulatifs (cpu, réseau, disque) sont dérivés côté API à partir de l'échantillon
précédent — exactement comme le fait NetData en local.
"""
from __future__ import annotations

import re
import time
from typing import Any

# Une seule commande = un seul aller-retour réseau par hôte et par cycle.
PROBE = r"""
echo '@@uptime'; cat /proc/uptime 2>/dev/null
echo '@@stat'; grep -E '^(cpu[0-9]* |intr |ctxt |procs_running|procs_blocked)' /proc/stat 2>/dev/null
echo '@@mem'; head -60 /proc/meminfo 2>/dev/null
echo '@@load'; cat /proc/loadavg 2>/dev/null
echo '@@net'; cat /proc/net/dev 2>/dev/null
echo '@@diskstats'; cat /proc/diskstats 2>/dev/null
echo '@@df'; df -P -B1 -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2
echo '@@temp'; for z in /sys/class/thermal/thermal_zone*; do [ -r "$z/temp" ] && echo "$(cat $z/type 2>/dev/null) $(cat $z/temp 2>/dev/null)"; done 2>/dev/null
echo '@@hwmon'; for h in /sys/class/hwmon/hwmon*; do n=$(cat $h/name 2>/dev/null); for t in $h/temp*_input; do [ -r "$t" ] && echo "$n $(basename $t) $(cat $t)"; done; done 2>/dev/null
echo '@@fans'; for h in /sys/class/hwmon/hwmon*; do
  n=$(cat $h/name 2>/dev/null)
  for f in $h/fan*_input; do
    [ -r "$f" ] || continue
    b=$(basename $f); b=${b%_input}
    lbl=$(cat $h/${b}_label 2>/dev/null)
    echo "$n|$b|$(cat $f 2>/dev/null)|$lbl"
  done
done 2>/dev/null
echo '@@power'; for h in /sys/class/hwmon/hwmon*; do
  n=$(cat $h/name 2>/dev/null)
  for w in $h/power*_average $h/power*_input; do
    [ -r "$w" ] || continue
    b=$(basename $w)
    echo "$n|${b%_*}|$(cat $w 2>/dev/null)"
  done
done 2>/dev/null
echo '@@ps'; ps -eo pid=,user=,pcpu=,pmem=,rss=,comm= --sort=-pcpu 2>/dev/null | head -12
echo '@@conn'; ss -s 2>/dev/null | head -3
echo '@@gpu'; for c in /sys/class/drm/card*/device; do
  [ -r "$c/gpu_busy_percent" ] || continue
  echo "card $(basename $(dirname $c))"
  echo "busy $(cat $c/gpu_busy_percent 2>/dev/null)"
  echo "vram_used $(cat $c/mem_info_vram_used 2>/dev/null)"
  echo "vram_total $(cat $c/mem_info_vram_total 2>/dev/null)"
  echo "gtt_used $(cat $c/mem_info_gtt_used 2>/dev/null)"
  echo "gtt_total $(cat $c/mem_info_gtt_total 2>/dev/null)"
  echo "sclk $(awk '/\*/{gsub(/Mhz/,"",$2); print $2}' $c/pp_dpm_sclk 2>/dev/null | head -1)"
  echo "mclk $(awk '/\*/{gsub(/Mhz/,"",$2); print $2}' $c/pp_dpm_mclk 2>/dev/null | head -1)"
  for hw in $c/hwmon/hwmon*; do
    echo "temp $(cat $hw/temp1_input 2>/dev/null)"
    echo "power $(cat $hw/power1_average 2>/dev/null || cat $hw/power1_input 2>/dev/null)"
    echo "power_cap $(cat $hw/power1_cap 2>/dev/null)"
    echo "fan $(cat $hw/fan1_input 2>/dev/null)"
  done
  echo "name $(cat $c/../device 2>/dev/null)"
done 2>/dev/null
echo '@@end'
"""

# Infos qui bougent peu : collectées toutes les N minutes seulement.
SLOW_PROBE = r"""
echo '@@os'; cat /etc/os-release 2>/dev/null | head -8
echo '@@kernel'; uname -sr 2>/dev/null
echo '@@hostname'; hostname -f 2>/dev/null || hostname 2>/dev/null
echo '@@cpuinfo'; grep -m1 'model name' /proc/cpuinfo 2>/dev/null; nproc 2>/dev/null
echo '@@virt'; systemd-detect-virt 2>/dev/null || echo none
echo '@@dmi'; for f in sys_vendor product_name product_version product_serial board_name bios_version bios_date chassis_type; do
  [ -r "/sys/class/dmi/id/$f" ] && echo "$f=$(cat /sys/class/dmi/id/$f 2>/dev/null)"
done 2>/dev/null
echo '@@memhw'; awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null
echo '@@disks'; lsblk -dnb -o NAME,SIZE,MODEL,ROTA 2>/dev/null | grep -vE '^(loop|ram|sr|zram)' | head -12
echo '@@macs'; for i in /sys/class/net/*; do
  n=$(basename $i)
  case "$n" in lo|veth*|br-*|docker*|virbr*) continue;; esac
  [ -r "$i/address" ] && echo "$n $(cat $i/address 2>/dev/null)"
done 2>/dev/null
echo '@@updates'; (
  if command -v apt-get >/dev/null 2>&1; then
    apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -c '^Inst '
    apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep '^Inst ' | grep -ci security
  elif command -v dnf >/dev/null 2>&1; then
    dnf -q check-update 2>/dev/null | grep -c '^[a-zA-Z0-9]'; echo 0
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Qu 2>/dev/null | wc -l; echo 0
  else echo 0; echo 0; fi
) 2>/dev/null
echo '@@reboot'; [ -f /var/run/reboot-required ] && echo yes || echo no
echo '@@services'; systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | head -40 | awk '{print $1}'
echo '@@failed'; systemctl list-units --type=service --state=failed --no-legend --no-pager 2>/dev/null | awk '{print $1}'
echo '@@docker'; command -v docker >/dev/null 2>&1 && echo yes || echo no
echo '@@pve'; { [ -d /etc/pve ] && (pveversion 2>/dev/null | head -1 || echo 'pve'); } || echo no
echo '@@sshd'; sshd -T 2>/dev/null | grep -iE '^(permitrootlogin|passwordauthentication|permitemptypasswords|x11forwarding|port|kbdinteractiveauthentication|challengeresponseauthentication) '
echo '@@firewall'; (
  if command -v ufw >/dev/null 2>&1; then echo "ufw $(ufw status 2>/dev/null | head -1 | awk '{print $2}')";
  elif command -v firewall-cmd >/dev/null 2>&1; then echo "firewalld $(firewall-cmd --state 2>/dev/null)";
  elif command -v nft >/dev/null 2>&1 && [ -n "$(nft list ruleset 2>/dev/null)" ]; then echo "nftables active";
  elif command -v iptables >/dev/null 2>&1 && [ "$(iptables -S 2>/dev/null | wc -l)" -gt 3 ]; then echo "iptables active";
  else echo "none inactive"; fi
) 2>/dev/null
echo '@@listen'; ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un | head -40
echo '@@autoupdate'; (
  systemctl is-enabled unattended-upgrades 2>/dev/null \
  || systemctl is-enabled dnf-automatic.timer 2>/dev/null \
  || echo disabled
) | head -1
echo '@@uid0'; awk -F: '($3==0){print $1}' /etc/passwd 2>/dev/null
echo '@@runkernel'; uname -r 2>/dev/null
echo '@@instkernel'; (ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1) 2>/dev/null
echo '@@smart'; command -v smartctl >/dev/null 2>&1 && for d in $(lsblk -dn -o NAME 2>/dev/null | grep -vE '^(loop|ram|sr|zram|dm-)'); do
  echo "$d $(smartctl -H /dev/$d 2>/dev/null | grep -iE 'overall-health|SMART Health' | awk -F: '{print $2}' | tr -d ' ') $(smartctl -A /dev/$d 2>/dev/null | awk '/Temperature_Celsius|Current Drive Temperature|Temperature:/{for(i=1;i<=NF;i++) if($i+0>0 && $i+0<120){print $i; exit}}')"
done 2>/dev/null
echo '@@end'
"""


# --------------------------------------------------------------------- parsing
def split_sections(raw: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    current = "_"
    for line in raw.splitlines():
        if line.startswith("@@"):
            current = line[2:].strip()
            sections[current] = []
        else:
            sections.setdefault(current, []).append(line)
    return sections


def _num(value: str, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


IGNORED_BLOCK = re.compile(r"^(loop|ram|zram|dm-|sr|fd)")
PARTITION = re.compile(r"^(?:nvme\d+n\d+p\d+|mmcblk\d+p\d+|[a-z]+\d+)$")


def _is_whole_disk(name: str) -> bool:
    """Écarte les partitions et les périphériques virtuels de l'IO disque."""
    return not IGNORED_BLOCK.match(name) and not PARTITION.match(name)


class LinuxSampler:
    """Garde l'échantillon précédent d'un hôte pour calculer les taux."""

    def __init__(self) -> None:
        self.prev: dict[str, Any] = {}
        self.prev_ts: float = 0.0

    # ----------------------------------------------------------------- publique
    def parse(self, raw: str) -> dict[str, Any]:
        now = time.time()
        sec = split_sections(raw)
        out: dict[str, Any] = {}
        cur: dict[str, Any] = {}
        dt = now - self.prev_ts if self.prev_ts else 0.0

        self._cpu(sec.get("stat", []), cur, out, dt)
        self._mem(sec.get("mem", []), out)
        self._load(sec.get("load", []), sec.get("uptime", []), out)
        self._net(sec.get("net", []), cur, out, dt)
        self._disk_io(sec.get("diskstats", []), cur, out, dt)
        self._filesystems(sec.get("df", []), out)
        self._temps(sec.get("temp", []), sec.get("hwmon", []), out)
        self._fans(sec.get("fans", []), out)
        self._power(sec.get("power", []), out)
        self._processes(sec.get("ps", []), out)
        self._gpu(sec.get("gpu", []), out)

        self.prev = cur
        self.prev_ts = now
        return out

    # ------------------------------------------------------------------- blocs
    def _cpu(self, lines: list[str], cur: dict, out: dict, dt: float) -> None:
        totals: dict[str, list[float]] = {}
        for line in lines:
            parts = line.split()
            if not parts:
                continue
            if parts[0].startswith("cpu"):
                totals[parts[0]] = [_num(p) for p in parts[1:]]
            elif parts[0] == "procs_running":
                out["procs.running"] = _num(parts[1])
            elif parts[0] == "procs_blocked":
                out["procs.blocked"] = _num(parts[1])
            elif parts[0] == "ctxt":
                cur["ctxt"] = _num(parts[1])
                if dt > 0 and "ctxt" in self.prev:
                    out["cpu.ctxt_per_s"] = max(0.0, (cur["ctxt"] - self.prev["ctxt"]) / dt)
            elif parts[0] == "intr":
                cur["intr"] = _num(parts[1])
                if dt > 0 and "intr" in self.prev:
                    out["cpu.intr_per_s"] = max(0.0, (cur["intr"] - self.prev["intr"]) / dt)

        cur["cpu"] = totals
        prev_totals = self.prev.get("cpu", {})
        cores: list[float] = []
        for key, vals in totals.items():
            prev = prev_totals.get(key)
            if not prev or len(vals) < 8 or len(prev) < 8:
                continue
            delta = [max(0.0, c - p) for c, p in zip(vals, prev)]
            total = sum(delta)
            if total <= 0:
                continue
            idle = delta[3] + delta[4]  # idle + iowait
            usage = 100.0 * (total - idle) / total
            if key == "cpu":
                out["cpu.usage"] = round(usage, 2)
                out["cpu.user"] = round(100.0 * (delta[0] + delta[1]) / total, 2)
                out["cpu.system"] = round(100.0 * delta[2] / total, 2)
                out["cpu.iowait"] = round(100.0 * delta[4] / total, 2)
                out["cpu.steal"] = round(100.0 * (delta[7] if len(delta) > 7 else 0) / total, 2)
                out["cpu.idle"] = round(100.0 * delta[3] / total, 2)
            else:
                cores.append(round(usage, 1))
        if cores:
            out["cpu.cores"] = cores
            out["cpu.count"] = len(cores)

    @staticmethod
    def _mem(lines: list[str], out: dict) -> None:
        info = {}
        for line in lines:
            if ":" not in line:
                continue
            key, _, rest = line.partition(":")
            info[key.strip()] = _num(rest.split()[0]) * 1024 if rest.split() else 0.0
        total = info.get("MemTotal", 0.0)
        available = info.get("MemAvailable", info.get("MemFree", 0.0))
        if total:
            out["mem.total"] = total
            out["mem.available"] = available
            out["mem.used"] = total - available
            out["mem.percent"] = round(100.0 * (total - available) / total, 2)
            out["mem.cached"] = info.get("Cached", 0.0)
            out["mem.buffers"] = info.get("Buffers", 0.0)
            out["mem.free"] = info.get("MemFree", 0.0)
        swap_total = info.get("SwapTotal", 0.0)
        if swap_total:
            out["swap.total"] = swap_total
            out["swap.used"] = swap_total - info.get("SwapFree", 0.0)
            out["swap.percent"] = round(100.0 * out["swap.used"] / swap_total, 2)

    @staticmethod
    def _load(load_lines: list[str], uptime_lines: list[str], out: dict) -> None:
        if load_lines and load_lines[0].strip():
            parts = load_lines[0].split()
            if len(parts) >= 3:
                out["load.1"] = _num(parts[0])
                out["load.5"] = _num(parts[1])
                out["load.15"] = _num(parts[2])
        if uptime_lines and uptime_lines[0].strip():
            out["uptime"] = _num(uptime_lines[0].split()[0])

    def _net(self, lines: list[str], cur: dict, out: dict, dt: float) -> None:
        counters: dict[str, tuple[float, float]] = {}
        for line in lines[2:] if len(lines) > 2 else []:
            if ":" not in line:
                continue
            iface, _, rest = line.partition(":")
            iface = iface.strip()
            if iface == "lo" or iface.startswith(("veth", "br-", "docker", "virbr")):
                continue
            fields = rest.split()
            if len(fields) < 9:
                continue
            counters[iface] = (_num(fields[0]), _num(fields[8]))
        cur["net"] = counters
        prev = self.prev.get("net", {})
        total_rx = total_tx = 0.0
        interfaces = {}
        for iface, (rx, tx) in counters.items():
            if dt <= 0 or iface not in prev:
                continue
            prx, ptx = prev[iface]
            rx_s = max(0.0, (rx - prx) / dt)
            tx_s = max(0.0, (tx - ptx) / dt)
            interfaces[iface] = {"rx": rx_s, "tx": tx_s}
            out[f"net.rx.{iface}"] = rx_s
            out[f"net.tx.{iface}"] = tx_s
            total_rx += rx_s
            total_tx += tx_s
        if interfaces:
            out["net.rx"] = total_rx
            out["net.tx"] = total_tx
            out["net.interfaces"] = interfaces

    def _disk_io(self, lines: list[str], cur: dict, out: dict, dt: float) -> None:
        counters: dict[str, tuple[float, float]] = {}
        for line in lines:
            parts = line.split()
            if len(parts) < 14:
                continue
            name = parts[2]
            if not _is_whole_disk(name):
                continue
            counters[name] = (_num(parts[5]) * 512, _num(parts[9]) * 512)
        cur["disk"] = counters
        prev = self.prev.get("disk", {})
        read_s = write_s = 0.0
        for name, (rd, wr) in counters.items():
            if dt <= 0 or name not in prev:
                continue
            prd, pwr = prev[name]
            r = max(0.0, (rd - prd) / dt)
            w = max(0.0, (wr - pwr) / dt)
            out[f"disk.read.{name}"] = r
            out[f"disk.write.{name}"] = w
            read_s += r
            write_s += w
        if prev:
            out["disk.read"] = read_s
            out["disk.write"] = write_s

    @staticmethod
    def _filesystems(lines: list[str], out: dict) -> None:
        mounts = []
        for line in lines:
            parts = line.split()
            if len(parts) < 6:
                continue
            device, size, used, avail, mount = parts[0], parts[1], parts[2], parts[3], parts[5]
            total = _num(size)
            if total <= 0:
                continue
            usedb = _num(used)
            pct = round(100.0 * usedb / total, 2)
            mounts.append(
                {"device": device, "mount": mount, "total": total, "used": usedb,
                 "available": _num(avail), "percent": pct}
            )
            out[f"disk.percent.{mount}"] = pct
        if mounts:
            out["filesystems"] = sorted(mounts, key=lambda m: -m["total"])
            root = next((m for m in mounts if m["mount"] == "/"), mounts[0])
            out["disk.percent"] = root["percent"]
            out["disk.total"] = sum(m["total"] for m in mounts)
            out["disk.used"] = sum(m["used"] for m in mounts)

    @staticmethod
    def _temps(zones: list[str], hwmon: list[str], out: dict) -> None:
        temps = {}
        for line in zones:
            parts = line.split()
            if len(parts) >= 2:
                value = _num(parts[-1]) / 1000.0
                if 0 < value < 150:
                    temps[parts[0]] = round(value, 1)
        for line in hwmon:
            parts = line.split()
            if len(parts) >= 3:
                value = _num(parts[-1]) / 1000.0
                if 0 < value < 150:
                    temps.setdefault(f"{parts[0]}/{parts[1].replace('_input', '')}", round(value, 1))
        if temps:
            out["temps"] = temps
            candidates = [v for k, v in temps.items() if any(t in k.lower() for t in ("cpu", "k10", "coretemp", "x86_pkg", "tctl"))]
            out["temp.cpu"] = max(candidates) if candidates else max(temps.values())

    @staticmethod
    def _fans(lines: list[str], out: dict) -> None:
        """Ventilateurs des hwmon : carte mère, boîtier, GPU, contrôleurs."""
        fans = {}
        for line in lines:
            parts = line.split("|")
            if len(parts) < 3:
                continue
            chip, slot, raw = parts[0].strip(), parts[1].strip(), parts[2].strip()
            label = parts[3].strip() if len(parts) > 3 and parts[3].strip() else slot
            rpm = _num(raw, -1)
            # 0 tr/min est légitime (ventilateur à l'arrêt), -1 signale une lecture ratée.
            if rpm < 0 or rpm > 30000:
                continue
            name = f"{chip}/{label}" if chip else label
            fans[name] = rpm
        if fans:
            out["fans"] = fans
            out["fan.max"] = max(fans.values())
            out["fan.count"] = float(len(fans))

    @staticmethod
    def _power(lines: list[str], out: dict) -> None:
        """Capteurs de puissance en microwatts."""
        readings = {}
        for line in lines:
            parts = line.split("|")
            if len(parts) < 3:
                continue
            chip, slot, raw = parts[0].strip(), parts[1].strip(), parts[2].strip()
            # amdgpu est déjà couvert par le bloc GPU : on ne compte pas deux fois.
            if chip.startswith(("amdgpu", "nvidia", "i915")):
                continue
            watts = _num(raw, -1) / 1_000_000.0
            if watts <= 0 or watts > 2000:
                continue
            readings[f"{chip}/{slot}" if chip else slot] = round(watts, 2)
        if readings:
            out["power_sensors"] = readings

    @staticmethod
    def _processes(lines: list[str], out: dict) -> None:
        procs = []
        for line in lines:
            parts = line.split(None, 5)
            if len(parts) < 6:
                continue
            procs.append({
                "pid": int(_num(parts[0])),
                "user": parts[1],
                "cpu": _num(parts[2]),
                "mem": _num(parts[3]),
                "rss": _num(parts[4]) * 1024,
                "name": parts[5].strip(),
            })
        if procs:
            out["processes"] = procs

    @staticmethod
    def _gpu(lines: list[str], out: dict) -> None:
        cards: list[dict] = []
        current: dict | None = None
        for line in lines:
            key, _, value = line.strip().partition(" ")
            if key == "card":
                current = {"id": value}
                cards.append(current)
            elif current is not None and value.strip():
                current[key] = value.strip()
        gpus = []
        for card in cards:
            vram_total = _num(card.get("vram_total", "0"))
            vram_used = _num(card.get("vram_used", "0"))
            gtt_total = _num(card.get("gtt_total", "0"))
            gtt_used = _num(card.get("gtt_used", "0"))
            gpu = {
                "id": card.get("id", "card0"),
                "busy": _num(card.get("busy", "0")),
                "vram_used": vram_used,
                "vram_total": vram_total,
                "vram_percent": round(100.0 * vram_used / vram_total, 2) if vram_total else 0.0,
                "gtt_used": gtt_used,
                "gtt_total": gtt_total,
                "temp": _num(card.get("temp", "0")) / 1000.0,
                "power": _num(card.get("power", "0")) / 1_000_000.0,
                "power_cap": _num(card.get("power_cap", "0")) / 1_000_000.0,
                "sclk": _num(card.get("sclk", "0")),
                "mclk": _num(card.get("mclk", "0")),
                "fan": _num(card.get("fan", "0")),
            }
            gpus.append(gpu)
        if gpus:
            out["gpus"] = gpus
            primary = gpus[0]
            out["gpu.busy"] = primary["busy"]
            out["gpu.vram_percent"] = primary["vram_percent"]
            out["gpu.temp"] = primary["temp"]
            out["gpu.power"] = primary["power"]


def parse_slow(raw: str) -> dict[str, Any]:
    sec = split_sections(raw)
    meta: dict[str, Any] = {}

    for line in sec.get("os", []):
        if line.startswith("PRETTY_NAME="):
            meta["os"] = line.split("=", 1)[1].strip().strip('"')
    kernel = sec.get("kernel", [])
    if kernel and kernel[0].strip():
        meta["kernel"] = kernel[0].strip()
    hostname = sec.get("hostname", [])
    if hostname and hostname[0].strip():
        meta["hostname"] = hostname[0].strip()

    cpuinfo = [l for l in sec.get("cpuinfo", []) if l.strip()]
    for line in cpuinfo:
        if "model name" in line:
            meta["cpu_model"] = line.split(":", 1)[1].strip()
        elif line.strip().isdigit():
            meta["cpu_count"] = int(line.strip())

    virt = [l.strip() for l in sec.get("virt", []) if l.strip()]
    if virt:
        meta["virt"] = virt[0]

    updates = [l.strip() for l in sec.get("updates", []) if l.strip().isdigit()]
    if updates:
        meta["updates"] = int(updates[0])
        meta["security_updates"] = int(updates[1]) if len(updates) > 1 else 0

    reboot = [l.strip() for l in sec.get("reboot", []) if l.strip()]
    meta["reboot_required"] = bool(reboot and reboot[0] == "yes")

    running = [l.strip() for l in sec.get("services", []) if l.strip().endswith(".service")]
    meta["services_running"] = running
    failed = [l.strip() for l in sec.get("failed", []) if l.strip().endswith(".service")]
    meta["services_failed"] = failed

    docker = [l.strip() for l in sec.get("docker", []) if l.strip()]
    meta["has_docker"] = bool(docker and docker[0] == "yes")

    # Un hôte Linux qui porte /etc/pve est en réalité un hyperviseur Proxmox :
    # on le signale pour proposer la bascule vers le collecteur dédié.
    pve = [l.strip() for l in sec.get("pve", []) if l.strip()]
    if pve and pve[0] != "no":
        meta["is_pve"] = True
        meta["pve_version"] = pve[0]

    # ---- inventaire matériel -------------------------------------------
    dmi = {}
    for line in sec.get("dmi", []):
        key, _, value = line.strip().partition("=")
        value = value.strip()
        # Les cartes mères non renseignées répondent des placeholders.
        if value and value.lower() not in ("to be filled by o.e.m.", "default string",
                                           "system serial number", "not specified", "none", "o.e.m."):
            dmi[key] = value
    if dmi:
        meta["vendor"] = dmi.get("sys_vendor")
        meta["model"] = dmi.get("product_name")
        meta["serial"] = dmi.get("product_serial")
        meta["board"] = dmi.get("board_name")
        meta["bios"] = dmi.get("bios_version")
        meta["bios_date"] = dmi.get("bios_date")
        meta["chassis"] = CHASSIS.get(dmi.get("chassis_type", ""), None)

    mem = [l.strip() for l in sec.get("memhw", []) if l.strip().isdigit()]
    if mem:
        meta["mem_total"] = int(mem[0]) * 1024

    disks = []
    for line in sec.get("disks", []):
        parts = line.split(None, 3)
        if len(parts) >= 2 and parts[1].isdigit():
            disks.append({
                "name": parts[0],
                "size": int(parts[1]),
                "model": parts[2].strip() if len(parts) > 2 else "",
                "ssd": parts[-1].strip() == "0" if len(parts) > 3 else None,
            })
    if disks:
        meta["disks"] = disks

    macs = {}
    for line in sec.get("macs", []):
        parts = line.split()
        if len(parts) == 2 and parts[1] != "00:00:00:00:00:00":
            macs[parts[0]] = parts[1]
    if macs:
        meta["macs"] = macs

    # ---- posture de sécurité -------------------------------------------
    sshd = {}
    for line in sec.get("sshd", []):
        key, _, value = line.strip().partition(" ")
        if key:
            sshd[key.lower()] = value.strip().lower()
    if sshd:
        meta["sshd"] = sshd

    firewall = [l.strip() for l in sec.get("firewall", []) if l.strip()]
    if firewall:
        tool, _, state = firewall[0].partition(" ")
        meta["firewall"] = {"tool": tool, "active": state.strip() in ("active", "running")}

    ports = [int(p) for p in sec.get("listen", []) if p.strip().isdigit()]
    if ports:
        meta["listening_ports"] = sorted(set(ports))

    auto = [l.strip() for l in sec.get("autoupdate", []) if l.strip()]
    meta["auto_updates"] = bool(auto and auto[0] == "enabled")

    root_accounts = [l.strip() for l in sec.get("uid0", []) if l.strip()]
    if root_accounts:
        meta["uid0_accounts"] = root_accounts

    running = [l.strip() for l in sec.get("runkernel", []) if l.strip()]
    installed = [l.strip() for l in sec.get("instkernel", []) if l.strip()]
    if running and installed:
        meta["kernel_running"] = running[0]
        meta["kernel_installed"] = installed[0]

    smart = []
    for line in sec.get("smart", []):
        parts = line.split()
        if len(parts) >= 2:
            smart.append({
                "device": parts[0],
                "health": parts[1],
                "temp": _num(parts[2]) if len(parts) > 2 else None,
            })
    if smart:
        meta["smart"] = smart
    return meta


# Codes DMI SMBIOS, réduits aux formats qu'on croise dans une infra maison.
CHASSIS = {
    "3": "Desktop", "4": "Low Profile Desktop", "6": "Mini Tower", "7": "Tower",
    "8": "Portable", "9": "Laptop", "10": "Notebook", "13": "All-in-One",
    "17": "Main Server Chassis", "23": "Rack Mount Chassis", "28": "Blade",
    "30": "Tablet", "31": "Convertible", "35": "Mini PC",
}
