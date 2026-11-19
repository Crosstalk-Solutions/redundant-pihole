# redundant-pihole

`redundant-pihole.sh` builds a redundant pair of Pi-hole v6 servers, each with its own Unbound
recursive resolver, on a bare Debian 12/13, Ubuntu 22.04+, or Raspberry Pi OS install. The
script works the same on a Raspberry Pi, a virtual machine, or a mini PC.

Each box gets:

- Unbound on `127.0.0.1#5335`, resolving from the root servers with DNSSEC validation.
- Pi-hole v6 using only Unbound upstream, listening on all interfaces, with Pi-hole's own DNSSEC
  turned off (Unbound already validates).
- The shared admin password, which the script confirms by logging in to the Pi-hole API.
- A login message that shows whether the box is the primary or the secondary, whether its
  services are running, and, on the secondary, a reminder not to make changes there.

The primary also gets [nebula-sync](https://github.com/lovelaze/nebula-sync), which copies the
primary's full configuration to the secondary every night. With `--vip`, both boxes also get
keepalived, so clients only need one DNS address that moves to whichever box is healthy.

## Compatible operating systems

Start from a fresh install with no desktop, SSH access, and a user that can run `sudo`.

| OS | Versions | Tested |
|---|---|---|
| Raspberry Pi OS Lite | Bookworm (Debian 12 based), Trixie (Debian 13 based) | In testing on a Raspberry Pi 5 |
| Debian | 12 (Bookworm), 13 (Trixie) | Debian 13 virtual machine and container |
| Ubuntu Server | 22.04, 24.04 and later | Ubuntu 24.04 container |

CPU architectures: `amd64` (most PCs and VMs), `arm64` (64-bit Raspberry Pi OS), `armhf` and
`i386`. On a Raspberry Pi, the 64-bit image is recommended (Pi 3, 4, 5 and Zero 2 W).

The script stops on any OS that isn't Debian-based (Fedora, Rocky, Arch, Alpine and so on).
`--static` also needs NetworkManager, which Raspberry Pi OS uses by default. Debian and Ubuntu
Server usually don't, so on those use a DHCP reservation on your router.

If you install Debian and set a root password in the installer, Debian leaves out `sudo`. Log in,
run `su -`, then `apt install -y sudo curl` and `usermod -aG sudo YOUR-USER`, and log in again.

## Usage

Give each box its final IP address (a DHCP reservation on your router is easiest) and reboot it
before running the script. The primary writes its own address into the sync config, and `--vip`
writes it into keepalived.

Build the secondary first, so the primary's first sync has somewhere to go.

```
# on the secondary
curl -fsSLO https://raw.githubusercontent.com/Crosstalk-Solutions/redundant-pihole/main/redundant-pihole.sh
sudo bash redundant-pihole.sh --role secondary --peer 192.168.1.2

# on the primary
curl -fsSLO https://raw.githubusercontent.com/Crosstalk-Solutions/redundant-pihole/main/redundant-pihole.sh
sudo bash redundant-pihole.sh --role primary --peer 192.168.1.3
```

The script asks for the admin password. Both boxes must use the same one. To run without prompts,
set `PIHOLE_PASSWORD` in the environment and add `-y`.

Common options:

| Option | What it does |
|---|---|
| `--vip 192.168.1.4` | Floats a virtual IP between the pair with keepalived. Use the same value on both boxes. |
| `--local-domain lan --router 192.168.1.1` | Sends lookups for local hostnames to your router, so device names still resolve. |
| `--static 192.168.1.2/24 --gateway 192.168.1.1` | Sets a static IP with NetworkManager. A DHCP reservation on your router is simpler. |
| `--sync-schedule "30 3 * * *"` | Sets when the primary pushes to the secondary. |

Run `bash redundant-pihole.sh --help` for the full list. The script is safe to run again: on a box
that already has Pi-hole, it skips the Pi-hole install and re-applies everything else.

After both boxes are built, set your router's DHCP to hand out both Pi-hole IPs as DNS servers,
or only the virtual IP if you used `--vip`.

Make all changes on the primary. The secondary is overwritten on every sync. Updates do not sync,
so run `sudo pihole -up` on each box, one at a time.

## If your network blocks outbound DNS

Unbound asks the internet's root DNS servers directly, so each Pi-hole needs to reach any address
on port 53. If a firewall rule, DNS lockdown or content filter forces all DNS through your router,
the script stops before configuring Unbound and tells you to exempt the box. Exempt both Pi-hole IPs
(TCP and UDP port 53), then run the script again. If something answers in place of the root servers
(UniFi Content Filtering does this), the script warns instead.

## Testing

`test/Dockerfile` builds a Debian 13 image with systemd, which behaves like a fresh VM for testing.
Swap the `FROM` line for `ubuntu:24.04` to test Ubuntu. Run two containers on a shared Docker network
with `--privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw` and run the script in each.

## License

MIT. See `LICENSE`.
