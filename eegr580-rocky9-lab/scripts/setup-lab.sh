#!/usr/bin/env bash
# setup-lab.sh — one-time lab setup INSIDE the Rocky 9 container, run as the lab user.
#   1. Lab signing identities in ~/.gnupg (rocky9-gnupg volume): one trusted, one rogue.
#   2. Pipeline identity key for labci (status records + evidence manifests).
#   3. Protected mock remote /srv/git/app.git with root-owned pre-receive hook.
#   4. Workspace ~/work/app seeded from the read-only repo mount, policy files
#      generated, signed bootstrap commit pushed to main.
# Idempotent: re-running skips what already exists.
set -euo pipefail
LAB_USER="$(cat /etc/lab/lab-user)"
[[ "$(id -un)" == "$LAB_USER" ]] || { echo "run as $LAB_USER: .\\lab\\run.ps1 -Shell" >&2; exit 1; }
GIT_NAME="${GIT_NAME:-$(getent passwd "$LAB_USER" | cut -d: -f5 | cut -d, -f1)}"; GIT_NAME="${GIT_NAME:-${LAB_USER^}}"
LAB_EMAIL="$LAB_USER@eegr580.lab"
export GNUPGHOME="$HOME/.gnupg" PATH=/opt/scanners/bin:/opt/lab/scripts/bin:$PATH
REMOTE=/srv/git/app.git; WS="$HOME/work/app"; SRC=/workspace-src
TRUSTED_UID="$GIT_NAME (EEGR580 lab) <$LAB_EMAIL>"
ROGUE_UID="Rogue Contributor (EEGR580 lab) <rogue@eegr580.lab>"
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fpr_of() { gpg --with-colons --list-keys "$1" | awk -F: '/^fpr/{print $10; exit}'; }

say "1. Lab signing identities (ed25519, 30-day expiry, unprotected because they are throwaway)"
chmod 700 "$GNUPGHOME"
for uid in "$TRUSTED_UID" "$ROGUE_UID"; do
  email="$(sed -E 's/.*<(.*)>/\1/' <<<"$uid")"
  gpg --batch --list-secret-keys "$email" >/dev/null 2>&1 || \
    gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key "$uid" ed25519 sign 30d
done
TRUSTED_FPR="$(fpr_of "$LAB_EMAIL")"; ROGUE_FPR="$(fpr_of rogue@eegr580.lab)"
echo "trusted: $TRUSTED_FPR"; echo "rogue:   $ROGUE_FPR"
echo "Your personal key stays on Windows (Gpg4win / hardware token). Do not import it here."

say "2. Pipeline identity (labci) key"
sudo -u labci /opt/lab/scripts/bin/lab-ci --init

say "3. Protected mock remote (needs sudo once: hooks and config become root-owned)"
if [[ ! -d "$REMOTE" ]]; then
  git init -q --bare --shared=group -b main "$REMOTE"
  git -C "$REMOTE" config receive.fsckObjects true   # ff-only and no-delete on main are enforced by pre-receive
  sudo chgrp -R lab-git "$REMOTE"
  sudo rm -rf "$REMOTE/hooks" && sudo install -d -o root -g root -m 0755 "$REMOTE/hooks"
  sudo ln -s /opt/lab/scripts/hooks/pre-receive "$REMOTE/hooks/pre-receive"
  sudo chown root:root "$REMOTE/config" && sudo chmod 0644 "$REMOTE/config"
fi

say "4. Workspace and signed bootstrap commit"
if [[ ! -d "$WS/.git" ]]; then
  mkdir -p "$WS"
  rsync -a --exclude .git --exclude 'lab/secrets/' --exclude reports --exclude evidence "$SRC/" "$WS/"
  cd "$WS"
  git init -q -b main
  git config user.name "$GIT_NAME"; git config user.email "$LAB_EMAIL"
  git config user.signingkey "$TRUSTED_FPR"; git config commit.gpgsign true
  git config gpg.format openpgp; git config gpg.program gpg; git config core.hooksPath /opt/lab/scripts/hooks
  # Keyring of KNOWN contributors (both); authorisation is the allow-list (trusted only).
  gpg --armor --export "$TRUSTED_FPR" "$ROGUE_FPR" > .github/security/trusted-signers.asc
  { echo "# Allow-listed commit signers — PRIMARY fingerprint, email, note. Reviewed by CODEOWNERS."
    echo "$TRUSTED_FPR $LAB_EMAIL $GIT_NAME (lab identity, expires in 30 days)"; } \
    > .github/security/allowed-signers.txt
  # Bootstrap policy for the very first push (main does not exist yet).
  sudo install -d -o root -g lab-git -m 0755 /srv/git/.bootstrap-policy/.github/security
  sudo install -m 0644 .github/security/trusted-signers.asc .github/security/allowed-signers.txt \
       /srv/git/.bootstrap-policy/.github/security/
  sudo install -m 0644 .gitleaks.toml /srv/git/.bootstrap-policy/.gitleaks.toml
  sudo install -m 0644 /dev/null /srv/git/.bootstrap-token
  git add -A
  git commit -q -S -m "chore: bootstrap lab repository and signing policy"
  git remote add origin "$REMOTE"
  git push -q origin main
  sudo rm -rf /srv/git/.bootstrap-policy
fi
cd "$WS"; git log --show-signature -1 --format='%H %s' | sed 's/^/  /'
audit-verify
say "Lab ready. Run: demo.sh all   (or: demo.sh a | a2 | b | c | d)"
