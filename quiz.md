# Quiz — AWS Transit Gateway

5 questions. Try them from memory first, then expand the answers.

---

### 1. You have exactly two VPCs in one region and no inspection requirement. Transit Gateway or VPC peering — and why?

<details>
<summary>Answer</summary>

**VPC peering.** With two VPCs there is exactly one peering connection
and two route entries — simpler and cheaper (no attachment-hour or
per-GB processing fees). Transit Gateway earns its keep at 3+ VPCs,
multiple accounts, hybrid connectivity, or when you need central routing
control and a single inspection choke point. Don't pay for a hub to
connect two spokes.

</details>

### 2. In one sentence each: what does *association* do, and what does *propagation* do?

<details>
<summary>Answer</summary>

- **Association** — decides which TGW route table an attachment's
  *outbound* packets are routed by ("which table do *I* look at?"). Each
  attachment is associated with exactly one table.
- **Propagation** — injects an attachment's CIDRs *into* chosen route
  tables so other attachments learn a return route ("which tables learn
  *my* routes?").

The classic mistake is configuring one and forgetting the other: traffic
leaves the spoke fine (association correct) but the reply has no route
back (propagation missing).

</details>

### 3. Why should a new Transit Gateway be created with `default_route_table_association = "disable"` and `default_route_table_propagation = "disable"`?

<details>
<summary>Answer</summary>

Because the defaults build a **flat network**: every attachment is
auto-associated and auto-propagated into one shared table, so every
spoke can reach every other spoke. For anything beyond a lab you want
**explicit segmentation** — separate tables like `shared`,
`isolated-prod`, `isolated-dev` — so isolation is enforced at the
network layer (a missing route is stronger than a security-group rule
someone might mis-edit later).

</details>

### 4. How do you force all inter-VPC traffic from prod through firewall appliances in an inspection VPC?

<details>
<summary>Answer</summary>

1. Attach the inspection VPC to the TGW.
2. In prod's TGW route table (`isolated-prod`), add a static default
   route `0.0.0.0/0` pointing at the **inspection attachment**.
3. Enable **appliance mode** on the inspection attachment so return
   traffic exits through the same AZ — otherwise the TGW may route
   asymmetrically and stateful firewalls drop the flows.
4. Inside the inspection VPC, use **Gateway Load Balancer endpoints** to
   steer traffic through the firewall fleet, then onward (NAT gateway
   for internet egress).

</details>

### 5. Your TGW bill is climbing. Name the two pricing knobs and one design change that reduces each.

<details>
<summary>Answer</summary>

- **Knob 1: attachment-hours** — every attachment bills per hour (per AZ
  subnet). Reduce it by attaching non-prod spokes in a single AZ instead
  of three, and by deleting stale attachments (old VPNs, abandoned
  test VPCs).
- **Knob 2: data-processing per GB** — every gigabyte crossing the TGW.
  Reduce it by keeping high-volume flows inside one VPC (metrics
  scrapes, log shipping, backups shouldn't hairpin through the hub),
  and by aligning attachment subnets with where traffic actually lives
  to avoid extra cross-AZ charges.

</details>
