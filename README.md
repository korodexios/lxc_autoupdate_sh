# Proxmox LXC Autoupdater with Interactive Exclusions

A robust and interactive Bash script designed for Proxmox VE (PVE) to safely automate and manage system updates (`apt update && apt dist-upgrade`) across all Debian and Ubuntu-based LXC containers.

It provides a lightweight terminal-based UI to toggle exclusions, automates ZFS/LVM-Thin snapshots, and safely restores container states.

---

## Key Features

- **Interactive Selection (TUI):** Easily toggle container exclusion states in real-time. Supports multi-selection using comma-separated or space-separated lists (e.g., `1,2,5` or `1 2 5`).
- **ANSI Color Terminal:** Modern color-coded terminal states showing at a glance which containers are scheduled for updates (`[ UPDATE ]`) or excluded (`[ EXCLUDED ]`).
- **Automated Snapshots & Rotation:** Automatically takes ZFS or LVM-Thin snapshots before updating. Retains a configurable number of snapshots (default: 5) and rotates out old ones. Safely falls back if storage does not support snapshots.
- **Smart Container Booting:** Boots offline containers, ensures they are updated, and safely shuts them down to restore their original stopped state.
- **Active Network Verification:** Instead of blindly upgrading, it tests TCP connectivity on port 53 (DNS) to ensure the container has fully operational networking.
- **Clean Background Logging:** Suppresses noisy APT upgrade outputs from cluttering the terminal. Detailed logs are piped directly into `lxc_autoupdate.log`.

---

## Visual Interface Preview

```text
=========================================================
⚙️  LXC CONTAINER UPDATE MANAGER
=========================================================
Enter row numbers to toggle status (exclude / include).
Multiple entries are allowed (e.g., 1,2,3,4 or 1 2 3):

  1) ID: 100      pihole                 (running ) [   UPDATE   ]
  2) ID: 101      homeassistant          (running ) [   UPDATE   ]
  3) ID: 102      mariadb-prod           (running ) [  EXCLUDED  ]
  4) ID: 105      test-container         (stopped ) [   UPDATE   ]

=========================================================
 👉 Enter row number(s) (e.g., 1,2,5) to toggle status.
 👉 Enter 's' to SAVE and RUN the updates.
 👉 Enter 'q' to QUIT without saving.
=========================================================
Your choice: 
```

---

## Installation

Log in to your Proxmox VE node via SSH and run the following commands to set up the dedicated script directory:

```bash
# Create a dedicated directory
mkdir -p ~/scripts/lxc-autoupdate
cd ~/scripts/lxc-autoupdate

# Download the script
wget https://raw.githubusercontent.com/korodexios/lxc_autoupdate_sh/main/lxc-autoupgrade.sh

# Make it executable
chmod +x lxc-autoupgrade.sh
```

---

## Usage

Simply navigate to the script directory and run it:

```bash
./lxc-autoupgrade.sh
```

### Pro-Tip: Add a System-Wide Alias
If you want to run this script from anywhere without navigating to its folder, add an alias to your shell profile:

1. Open your `.bashrc` file:
   ```bash
   nano ~/.bashrc
   ```
2. Append this line at the very bottom:
   ```bash
   alias lxc-upgrade='/root/scripts/lxc-autoupdate/lxc-autoupgrade.sh'
   ```
3. Reload your profile:
   ```bash
   source ~/.bashrc
   ```
Now you can start the update manager from any directory by typing:
```bash
lxc-upgrade
```

---

## File Structure

The script keeps everything self-contained within its directory:
- `lxc-autoupgrade.sh` - The main executable script.
- `lxc_exclude.conf` - Generated automatically. Contains the raw list of excluded LXC IDs.
- `lxc_autoupdate.log` - Generated automatically. Contains detailed logs of the APT upgrade outputs.

---

## Configuration

You can open `lxc-autoupgrade.sh` and edit the configuration section at the top of the file:

```bash
# Set to "no" if your storage does not support snapshots
ENABLE_SNAPSHOTS="yes"
MAX_SNAPSHOTS=5

# Remote IP/Port used to test internet access inside containers
TEST_IP="1.1.1.1"
TEST_PORT="53"
```

---

## Troubleshooting

### "Required file not found" or "cannot execute"
If you copied the script code via a Windows environment, the line endings might have changed to Windows-style (CRLF). To fix this, convert them back to Unix-style (LF) using `sed`:

```bash
sed -i -e 's/\r$//' lxc-autoupgrade.sh
```

---

## License

This project is open-source and available under the MIT License. Feel free to clone, modify, and share!
```
