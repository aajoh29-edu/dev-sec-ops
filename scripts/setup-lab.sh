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

say "3. Protected mock remote (sudo: hooks and config become root-owned)"
# Every sub-step checks its own result, so a run interrupted half-way can simply be re-run.
[[ -d "$REMOTE" ]] || git init -q --bare --shared=group -b main "$REMOTE"
if [[ -O "$REMOTE/config" ]]; then   # still ours => hardening not applied yet
  git -C "$REMOTE" config receive.fsckObjects true   # ff-only/no-delete on main: enforced by pre-receive
fi
sudo chgrp -R lab-git "$REMOTE"
if [[ "$(stat -c %U "$REMOTE/hooks")" != root || ! -L "$REMOTE/hooks/pre-receive" ]]; then
  sudo rm -rf "$REMOTE/hooks" && sudo install -d -o root -g root -m 0755 "$REMOTE/hooks"
  sudo ln -s /opt/lab/scripts/hooks/pre-receive "$REMOTE/hooks/pre-receive"
fi
sudo chown root:root "$REMOTE/config" && sudo chmod 0644 "$REMOTE/config"
echo "remote: $REMOTE (pre-receive -> $(readlink "$REMOTE/hooks/pre-receive"))"

say "4. Workspace and signed bootstrap commit"
mkdir -p "$WS"
[[ -d "$WS/.git" ]] || git -C "$WS" init -q -b main
if ! git -C "$WS" rev-parse -q --verify HEAD >/dev/null; then
  # No first commit yet (fresh, or an earlier run stopped): (re)copy the project from the repo mount.
  rsync -a --exclude .git --exclude 'lab/secrets/' --exclude /reports --exclude /evidence "$SRC/" "$WS/"
fi
cd "$WS"
git config user.name "$GIT_NAME"; git config user.email "$LAB_EMAIL"
git config user.signingkey "$TRUSTED_FPR"; git config commit.gpgsign true
git config gpg.format openpgp; git config gpg.program gpg; git config core.hooksPath /opt/lab/scripts/hooks
git remote get-url origin >/dev/null 2>&1 || git remote add origin "$REMOTE"

if ! git rev-parse -q --verify HEAD >/dev/null; then
  # Keyring of KNOWN contributors (both); authorisation is the allow-list (trusted only).
  gpg --armor --export "$TRUSTED_FPR" "$ROGUE_FPR" > .github/security/trusted-signers.asc
  { echo "# Allow-listed commit signers — PRIMARY fingerprint, email, note. Reviewed by CODEOWNERS."
    echo "$TRUSTED_FPR $LAB_EMAIL $GIT_NAME (lab identity, expires in 30 days)"; } \
    > .github/security/allowed-signers.txt
  git add -A
  git commit -q -S -m "chore: bootstrap lab repository and signing policy"
fi

if ! git -C "$REMOTE" rev-parse -q --verify refs/heads/main >/dev/null; then
  # First push only: main does not exist yet, so stage a one-time policy from the commit itself.
  sudo install -d -o root -g lab-git -m 0755 /srv/git/.bootstrap-policy/.github/security
  git show HEAD:.github/security/trusted-signers.asc | sudo tee /srv/git/.bootstrap-policy/.github/security/trusted-signers.asc >/dev/null
  git show HEAD:.github/security/allowed-signers.txt | sudo tee /srv/git/.bootstrap-policy/.github/security/allowed-signers.txt >/dev/null
  git show HEAD:.gitleaks.toml | sudo tee /srv/git/.bootstrap-policy/.gitleaks.toml >/dev/null
  sudo chmod -R a+rX /srv/git/.bootstrap-policy
  sudo install -m 0644 /dev/null /srv/git/.bootstrap-token
  git push -q origin main
  sudo rm -rf /srv/git/.bootstrap-policy /srv/git/.bootstrap-token
fi
cd "$WS"; git log --show-signature -1 --format='%H %s' | sed 's/^/  /'
audit-verify
say "Lab ready. Run: demo.sh all   (or: demo.sh a | a2 | b | c | d)"
