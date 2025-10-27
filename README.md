Install StackFood on New VPS

Quick start (Ubuntu 22.04/24.04 root shell):

```bash
curl -fsSL https://raw.githubusercontent.com/$(whoami)/$(basename $(pwd))/$(git rev-parse --abbrev-ref HEAD)/scripts/stackfood-fast-install.sh -o /tmp/stackfood-fast-install.sh || true
# Or if cloned locally:
# cp scripts/stackfood-fast-install.sh /tmp/stackfood-fast-install.sh
sudo bash /tmp/stackfood-fast-install.sh
```

Prerequisites:
- Point DNS A records to your server for `api.hayyaeats.com`, `admin.hayyaeats.com`, `restaurant.hayyaeats.com`
- Upload your licensed StackFood v10 backend zip as `/var/www/stackfood/stackfood-backend.zip`
- Optional Flutter zips (place if building Android quickly):
  - `/var/www/apps/user-app.zip`
  - `/var/www/apps/restaurant-app.zip`
  - `/var/www/apps/delivery-app.zip`

Notes:
- Installer sets weak temporary credentials for speed (DB root: `TempRoot123!`, DB app: `TempDB123!`). Change after installation.
- After install, visit `https://admin.hayyaeats.com` and `https://api.hayyaeats.com`.

Troubleshooting:
- Ensure `stackfood-backend.zip` is present before running; the script exits if missing.
- If snap is unavailable (minimal VPS), Flutter steps are skipped automatically.
- Nginx test or certbot failures usually indicate DNS not fully propagated.

