# ip_allow.sh

```
██╗██████╗      █████╗ ██╗     ██╗      ██████╗ ██╗    ██╗
██║██╔══██╗    ██╔══██╗██║     ██║     ██╔═══██╗██║    ██║
██║██████╔╝    ███████║██║     ██║     ██║   ██║██║ █╗ ██║
██║██╔═══╝     ██╔══██║██║     ██║     ██║   ██║██║███╗██║
██║██║         ██║  ██║███████╗███████╗╚██████╔╝╚███╔███╔╝
╚═╝╚═╝         ╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝  ╚══╝╚══╝
```

An automated tool for adding IP whitelists to specific ports.
Provides automated operations for **iptables / ip6tables**.

---

## Script Description

In the directory where the script is executed, the following files must exist:

* `ports/xxx/ipv4.txt` and/or `ports/xxx/ipv6.txt`

Where:

* `xxx` is the port number for which the whitelist will be applied
* Each line in `ipv4.txt` contains either:

  * a single IP (e.g. `127.0.0.1`), or
  * a CIDR block (e.g. `192.168.0.0/24`)
* `ipv6.txt` follows the same rules
* Lines starting with `#` are treated as comments and ignored

When the script runs, it will:

* Automatically read `ports/xxx/ipv4.txt` and `ports/xxx/ipv6.txt`
* Set the specified port to **default `DROP`**
* Add each IP/CIDR entry from the files into the **allow (whitelist) rules**

---

## Usage

```bash
bash ipallow.sh -h|--help                     # Show help/version
sudo bash ipallow.sh <port> [port2 ...]       # Apply whitelist for one/more ports
sudo bash ipallow.sh                          # Apply whitelist for all ports under ./ports
sudo bash ipallow.sh show                     # Show counts from current iptables/ip6tables rules
sudo bash ipallow.sh delete [port ...]        # Delete whitelist rules created by this script
```

---

### 1. Show Help

```bash
bash ipallow.sh -h|--help                     # Show help/version
```

---

### 2. Apply Whitelist to Specific / All Ports

#### Apply Whitelist to Specific Ports

```bash
sudo bash ipallow.sh <port> [port2 ...]       # Apply whitelist for one/more ports
```

Example: apply whitelists to ports `443` and `8080`.
Assumes IP data already exists in:

* `./ports/443/ipv4.txt`
* `./ports/443/ipv6.txt`
* `./ports/8080/ipv4.txt`
* `./ports/8080/ipv6.txt`

```
root@simple:~/ip-allow# sudo bash ipallow.sh 443 8080
Port 443 IPv4 whitelist refreshed; chain: IPALLOW_443 (accepted: 196, skipped: 0)
Port 443 IPv6 whitelist refreshed; chain: IPALLOW6_443 (accepted: 90, skipped: 0)
Port 8080 IPv4 whitelist refreshed; chain: IPALLOW_8080 (accepted: 197, skipped: 0)
Port 8080 IPv6 whitelist refreshed; chain: IPALLOW6_8080 (accepted: 90, skipped: 0)
```

---

#### Apply Whitelist to All Ports

```bash
sudo bash ipallow.sh <port>                   # Apply all the whitelist for one/more ports
```

If the `ports/` directory contains `443`, `8080`, and `8443`, this command will apply whitelists for **all three ports**.

---

### 3. Show Whitelist Rules Added by This Script

```bash
sudo bash ipallow.sh show                     # Show counts from current iptables/ip6tables rules
```

The script will read the current iptables/ip6tables rules.

Example output:

```
root@simple:~/ip-allow# sudo bash ipallow.sh show
PORT     IPv4_CNT   IPv6_CNT  
443      196        90        
8080     197        90    
```

---

### 4. Delete Whitelists for Specific / All Ports

#### Delete Whitelist for Specific Ports

```bash
sudo bash ipallow.sh delete [port ...]        # Delete whitelist rules created by this script
```

A confirmation prompt will be shown.

Example:

```
root@simple:~/ip-allow# sudo bash ipallow.sh delete 443
Are you sure you want to clear port 443 IP whitelist? [y/N] y
Deleted port 443: total 292 rules
```

---

#### Delete Whitelist for All Ports

```bash
sudo bash ipallow.sh delete                   # Delete all the whitelist rules created by this script
```

A confirmation prompt will be shown.

Example:

```
root@simple:~/ip-allow# sudo bash ipallow.sh delete
Are you sure you want to clear all port IP whitelists created by this script? [y/N] y
Deleted port 443: total 292 rules
Deleted port 8080: total 293 rules
Deleted whitelists for 2 ports
```

---

## What Is The Meaning of This Script?

CDN providers usually offer **origin server protection**, allowing you to restrict access so that **only CDN origin IPs** can reach your server.
This helps detect or prevent attacks such as **DDoS against the origin server**.

<img width="2169" height="1308" alt="OriginIP" src="https://github.com/user-attachments/assets/ce787855-1b14-4b87-bddc-9b9a1062ff8b" />

This script allows you to **quickly and consistently configure origin IP whitelists** at the firewall level.
