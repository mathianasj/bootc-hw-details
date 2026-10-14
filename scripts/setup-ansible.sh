#!/usr/bin/env bash
# Create a venv and install Ansible deps for the available Python (3.9+).
# On RHEL 9 this installs Ansible 8.x. Prefer: sudo dnf install ansible-core
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

pick_python() {
  local candidate
  for candidate in \
    "${PYTHON:-}" \
    python3.14 \
    python3.13 \
    python3.12 \
    python3.11 \
    python3.10 \
    python3.9 \
    python3 \
    /usr/bin/python3
  do
    [[ -n "${candidate}" ]] || continue
    if command -v "${candidate}" >/dev/null 2>&1 || [[ -x "${candidate}" ]]; then
      if "${candidate}" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
        echo "${candidate}"
        return 0
      fi
    fi
  done
  return 1
}

if ! PY="$(pick_python)"; then
  cat >&2 <<'EOF'
ERROR: Need Python >= 3.9.

On RHEL 9:
  sudo dnf install -y python3 python3-pip python3-venv
  ./scripts/setup-ansible.sh

Or skip pip entirely:
  sudo dnf install -y ansible-core
  ansible-galaxy collection install -r ansible/requirements.yml
EOF
  exit 1
fi

VER="$("${PY}" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
echo "Using ${PY} (${VER})"

if "${PY}" -c 'import sys; raise SystemExit(0 if sys.version_info < (3, 10) else 1)'; then
  echo "Note: Python 3.9 -> Ansible 8.x from requirements.txt"
  echo "      On RHEL you can instead: sudo dnf install -y ansible-core"
fi

"${PY}" -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install -U pip
pip install -r requirements.txt
ansible-galaxy collection install -r ansible/requirements.yml

cat <<EOF

Done. Activate before running the playbook:
  source ${ROOT}/.venv/bin/activate
  cd ansible && ansible-playbook -i inventory.yml playbook.yml ...
EOF
