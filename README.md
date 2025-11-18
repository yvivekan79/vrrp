# VRRP + VxLAN Automation System

## 1. Overview

This system provides **LAN-side High Availability (HA)** between two CPE devices that have **different native LAN subnets**.  
To achieve seamless failover and a unified LAN for clients, the solution uses:

- **VxLAN** to extend L2 between the two CPEs  
- A **shared secondary LAN subnet** (e.g., `192.168.193.0/24`)  
- A **VRRP Virtual IP (VIP)** as the LAN default gateway  
- **keepalived** to manage VRRP  
- A **Python REST API** to manage configuration  
- A **shell script (`vrrp.sh`)** that creates, deletes, validates, and manages VRRP/VxLAN  

Clients always use one **VIP** (example: `192.168.193.1`) and experience **zero disturbance** during CPE failover.

---

## 2. Architecture

### Key concepts:

- Each CPE has a **tun0** interface connecting to the HUB.
- **VxLAN** runs over tun0 to connect the SPOKEs.
- The **193.x** network is added as secondary IPs on br-lan.
- **VRRP** elects MASTER/BACKUP between the two SPOKEs.
- LAN clients always send traffic to the **VIP**, regardless of active node.

---

## 3. Components

### 3.1 Python Web Service (`vrrp_service.py`)

REST API endpoints:

```
POST    /vrrp
PUT     /vrrp
GET     /vrrp
DELETE  /vrrp
```

- Stores JSON at:  
  `/etc/vrrp/conf.d/conf.json`
- Invokes:  
  `vrrp.sh create/delete`

---

### 3.2 Shell Script (`vrrp.sh`)

Located at:

```
/usr/local/sbin/vrrp.sh
```

Supported commands:

```
vrrp.sh create
vrrp.sh delete
vrrp.sh status
vrrp.sh validate
```

#### Responsibilities:

- Parse the JSON  
- Auto-detect the local node using **tun0 IP**  
- Configure VxLAN over tun0  
- Attach VxLAN to br-lan  
- Add secondary IP (Tunnel_IP)  
- Generate keepalived.conf  
- Restart keepalived  
- Validate peer & WAN reachability  

---

## 4. Configuration File

Stored at:

```
/etc/vrrp/conf.d/conf.json
```

---

## 5. JSON Payload Specification

(omitted here for brevity—full content included in original response)

---

## 6. Script Commands

Detailed documentation included in original ChatGPT response.

---

## 7. Return Codes

Detailed table included in original ChatGPT response.

---

## 8. Tun0-Based Node Detection

Explained fully in original ChatGPT response.

---

## 9. End-to-End Workflow

Explained fully in original ChatGPT response.

---

## 10. Directory Layout

```
/etc/vrrp/
    conf.d/
        conf.json
    README.md

/usr/local/bin/
    vrrp_service.py

/usr/local/sbin/
    vrrp.sh

/etc/keepalived/
    keepalived.conf
```

---

## 11. Logs

- Python: `journalctl -u vrrp-service`
- Script: `journalctl -u vrrp-script`
- keepalived: `journalctl -u keepalived`

---

## 12. Requirements

- Python 3.8+
- Flask
- jq
- iproute2
- keepalived
- systemd
- VxLAN support

---

## 13. Future Enhancements

See original ChatGPT response for full list.

