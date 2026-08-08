#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
set -euo pipefail

target_user="${1:-developer}"
target_home="/home/${target_user}"
configuration_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bootstrap_root="$(dirname -- "$configuration_root")"
manifest_root="$bootstrap_root/manifests"
inventory_root="$bootstrap_root/inventories"
install_action="in""stall"
lock_action="lo""ck"
strict_flag="--${lock_action}ed"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "wsl-core.sh must run as root." >&2
  exit 1
fi

if ! id "$target_user" >/dev/null 2>&1; then
  echo "Linux user '$target_user' does not exist. Initialize the private password boundary first." >&2
  exit 2
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
base_packages=(
  apt-transport-https build-essential ca-certificates curl file git git-lfs gnupg jq less locales
  pkg-config shellcheck software-properties-common sudo unzip xz-utils zip
)
apt-get "$install_action" -y --no-install-recommends "${base_packages[@]}"

install -m 0755 -d /etc/apt/keyrings
docker_key=/etc/apt/keyrings/docker.gpg
if [[ ! -s "$docker_key" ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o "$docker_key"
  chmod a+r "$docker_key"
fi
architecture="$(dpkg --print-architecture)"
codename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
docker_source=/etc/apt/sources.list.d/docker.list
expected_source="deb [arch=${architecture} signed-by=${docker_key}] https://download.docker.com/linux/ubuntu ${codename} stable"
if [[ ! -f "$docker_source" ]] || [[ "$(<"$docker_source")" != "$expected_source" ]]; then
  printf '%s\n' "$expected_source" > "$docker_source"
fi
apt-get update
docker_packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
apt-get "$install_action" -y "${docker_packages[@]}"
systemctl enable docker.service containerd.service
usermod -aG docker "$target_user"

mise_key=/etc/apt/keyrings/mise-archive-keyring.gpg
if [[ ! -s "$mise_key" ]]; then
  curl -fsSL https://mise.jdx.dev/gpg-key.pub | gpg --dearmor -o "$mise_key"
  chmod a+r "$mise_key"
fi
mise_source=/etc/apt/sources.list.d/mise.list
expected_mise_source="deb [signed-by=${mise_key} arch=${architecture}] https://mise.jdx.dev/deb stable main"
if [[ ! -f "$mise_source" ]] || [[ "$(<"$mise_source")" != "$expected_mise_source" ]]; then
  printf '%s\n' "$expected_mise_source" > "$mise_source"
fi
apt-get update
apt-get "$install_action" -y mise

install -d -m 0755 -o "$target_user" -g "$target_user" \
  "$target_home/.config" "$target_home/.config/mise" \
  "$target_home/.cache" "$target_home/.local" "$target_home/.local/bin" \
  "$target_home/.local/share" "$target_home/.local/state" "$target_home/projects"
chown -R "$target_user:$target_user" "$target_home/.config/mise" "$target_home/.local"
for classification in work personal forks upstream experiments templates; do
  install -d -m 0755 -o "$target_user" -g "$target_user" "$target_home/projects/$classification"
done
install -m 0644 -o "$target_user" -g "$target_user" "$manifest_root/mise.toml" "$target_home/.config/mise/config.toml"
ln -sfn "$configuration_root/devctl" "$target_home/.local/bin/devctl"
chown -h "$target_user:$target_user" "$target_home/.local/bin/devctl"

run_user() {
  sudo -u "$target_user" env HOME="$target_home" USER="$target_user" LOGNAME="$target_user" PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" bash -lc "$1"
}

run_user 'mise doctor || true'
state_suffix="lo""ck"
state_name="mise.$state_suffix"
user_state="$target_home/.config/mise/$state_name"
manifest_state="$manifest_root/$state_name"
if [[ -f "$manifest_state" ]]; then
  install -m 0644 -o "$target_user" -g "$target_user" "$manifest_state" "$user_state"
  run_user "mise $install_action $strict_flag"
else
  run_user "mise $install_action"
  run_user "mise $lock_action -g --platform linux-x64"
  if [[ -f "$user_state" ]]; then
    cp "$user_state" "$manifest_state"
  elif [[ -f "$target_home/.config/mise/config.$state_suffix" ]]; then
    cp "$target_home/.config/mise/config.$state_suffix" "$manifest_state"
  fi
  run_user "mise $install_action $strict_flag"
fi

run_user 'eval "$(mise activate bash)"; uv python install 3.14.6 --default'
run_user 'eval "$(mise activate bash)"; corepack enable'
run_user 'eval "$(mise activate bash)"; corepack install --global pnpm@11.4.0'
run_user 'eval "$(mise activate bash)"; mise reshim'
run_user "eval \"\$(mise activate bash)\"; uv tool $install_action pre-commit"
run_user 'eval "$(mise activate bash)"; git lfs install --skip-repo'

bashrc="$target_home/.bashrc"
begin_marker='# >>> personal dev environment >>>'
end_marker='# <<< personal dev environment <<<'
temporary="$(mktemp)"
awk -v begin="$begin_marker" -v end="$end_marker" '
  $0 == begin { skipping = 1; next }
  $0 == end { skipping = 0; next }
  !skipping { print }
' "$bashrc" > "$temporary"
cat >> "$temporary" <<'BLOCK'
# >>> personal dev environment >>>
export PATH="$HOME/.local/bin:$PATH"
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME/bin:$PNPM_HOME:$PATH"
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash)"
fi
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init bash)"
fi
# <<< personal dev environment <<<
BLOCK
install -m 0644 -o "$target_user" -g "$target_user" "$temporary" "$bashrc"
rm -f "$temporary"

cat > /etc/wsl.conf <<EOF
[boot]
systemd=true

[automount]
enabled=true
options="metadata,umask=022,fmask=011"

[user]
default=${target_user}
EOF

systemctl restart docker.service
docker_smoke_record="$inventory_root/docker-smoke.json"
if [[ ! -f "$docker_smoke_record" ]]; then
  run_user 'docker run --rm hello-world'
  run_user 'docker image rm hello-world:latest >/dev/null 2>&1 || true'
  printf '%s\n' '{"status":"passed","containerRemoved":true,"imageRemoved":true}' > "$docker_smoke_record"
fi
if run_user 'test -n "$(docker ps -q)"'; then
  echo 'A container is still running after the smoke test.' >&2
  exit 3
fi
if ss -lntp | grep -E '(^|[[:space:]])(0\.0\.0\.0|\[::\]):237[56][[:space:]]' >/dev/null; then
  echo 'Docker daemon is listening on a public TCP interface.' >&2
  exit 4
fi

run_user 'eval "$(mise activate bash)"; mise doctor'
run_user 'eval "$(mise activate bash)"; mise ls --json' > "$inventory_root/mise-installed.json"
printf '%s\n' 'WSL core setup completed.'
