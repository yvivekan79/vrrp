# VRRP & VxLAN Automation System

## 1. Overview

This system provides automated **VRRP-based LAN High Availability** between two CPE nodes (SPOKEs) whose LAN subnets are originally different.

To enable VRRP across these nodes, the system uses:

- A **VxLAN overlay** between WAN IPs of both SPOKEs
- A **shared virtual subnet** (e.g. `192.168.193.0/24`)
- **VRRP VIP** (e.g. `192.168.193.1`) as client gateway
- **keepalived** to implement VRRP master/backup roles
- A **Python REST API** to manage VRRP configuration
- A **shell script (`vrrp.sh`)** that applies the config on each node
- Built-in **connectivity checks** to ensure WAN and peer reachability

Clients connected to the LAN switch use the VIP as default gateway, while failover between CPEs is handled transparently.

---

## 2. Components

### 2.1 Python Web Service

**File:** `/usr/local/bin/vrrp_service.py`

Exposes:

- `POST /vrrp`
- `PUT  /vrrp`
- `GET  /vrrp`
- `DELETE /vrrp`
- `OPTIONS /vrrp` (for CORS/preflight)

Responsibilities:

- Accept VRRP JSON payload
- Store it at `/etc/vrrp/conf.d/conf.json`
- Call `vrrp.sh create` on POST/PUT
- Call `vrrp.sh delete` on DELETE
- Return config + status on GET

If `vrrp.sh create` returns non-zero (including connectivity failures), the API returns **HTTP 500** with the script output.

---

### 2.2 Shell Script

**File:** `/usr/local/sbin/vrrp.sh`  
**Usage:**

```bash
vrrp.sh create
vrrp.sh delete
vrrp.sh status
======================================================================================================================================

