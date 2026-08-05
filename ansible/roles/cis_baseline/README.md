# cis_baseline

Applies CIS Level 1 basics to Ubuntu 22.04 or newer.

## What it does, and what it deliberately does not

This role hardens **general purpose Ubuntu hosts**: bastions, self hosted CI
runners, and self managed VMs.

It is **not** applied to the EKS worker nodes. Those run Amazon Linux 2023 from
an AWS supplied AMI, they are not reachable over SSH, and configuration drift on
them is handled by replacing the node rather than by logging in and correcting
it. Trying to run this role against them would be the wrong tool for the job.
See `docs/architecture.md` for the fuller argument.

## Sections

| Task file | Control | Off switch |
|---|---|---|
| `ssh.yml` | Root login off, key only auth, modern ciphers, verbose logging | `cis_manage_ssh` |
| `firewall.yml` | UFW, default deny inbound | `cis_manage_firewall` |
| `auditd.yml` | Kernel audit rules with searchable keys | `cis_manage_auditd` |
| `updates.yml` | Automatic security patching | `cis_manage_updates` |
| `password_policy.yml` | pwquality, faillock, ageing | `cis_manage_password_policy` |

## Usage

```bash
cd ansible
cp inventory/hosts.example.ini inventory/hosts.ini   # edit
ansible-playbook site.yml --check --diff             # dry run first
ansible-playbook site.yml
```

Run a single section with tags:

```bash
ansible-playbook site.yml --tags ssh
```

## The two things most likely to lock you out, and how they are prevented

1. **A bad sshd config.** Every template that touches sshd uses
   `validate: /usr/sbin/sshd -t -f %s`, so the file is syntax checked *before* it
   is moved into place. A typo fails the play instead of breaking the daemon.

2. **Enabling the firewall before allowing SSH.** `firewall.yml` allows the SSH
   port as its first rule, sets the default deny policy afterwards, and asserts
   at the end that the port is present in the active rule set.

## Deliberate deviations from strict CIS

- `max_log_file_action = ROTATE` rather than `halt`. Strict CIS halts the system
  when audit logs cannot be written. That converts a full disk into an outage.
- `-e 2` (immutable audit rules) is commented out. It is correct for a settled
  production host but requires a reboot for every subsequent rule change.
- Automatic reboots after unattended upgrades are off by default. A surprise
  03:00 reboot is its own kind of incident.

Each of these is a judgement call about availability against strictness, not an
oversight, and each is annotated in the file where it appears.

## Requirements

- Ansible 2.15 or newer
- The `community.general` collection, for the `ufw` module:
  `ansible-galaxy collection install community.general`
