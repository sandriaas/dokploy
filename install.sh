#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-easyrentbali}"
REPO_NAME="${REPO_NAME:-dokploy}"
REPO_REF="${REPO_REF:-transfer-migration}"
INSTALL_DIR="${INSTALL_DIR:-/opt/dokploy-fork}"
IMAGE_NAME="${IMAGE_NAME:-dokploy-fork}"
IMAGE_TAG="${IMAGE_TAG:-transfer-migration}"
SERVICE_NAME="${SERVICE_NAME:-dokploy}"
PORT="${PORT:-3000}"
DOCKER_VERSION="${DOCKER_VERSION:-28.5.2}"

if [ "$(id -u)" -ne 0 ]; then
	if command -v sudo >/dev/null 2>&1; then
		SUDO="sudo"
	else
		echo "Run this script as root or install sudo." >&2
		exit 1
	fi
else
	SUDO=""
fi

log() {
	printf '%s\n' "$1"
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

service_exists() {
	docker service ls --format '{{.Name}}' | grep -qx "$SERVICE_NAME"
}

ensure_ports_free() {
	if ss -tulnp | grep -q ":80 "; then
		echo "Port 80 is already in use." >&2
		exit 1
	fi
	if ss -tulnp | grep -q ":443 "; then
		echo "Port 443 is already in use." >&2
		exit 1
	fi
	if ss -tulnp | grep -q ":${PORT} "; then
		echo "Port ${PORT} is already in use." >&2
		exit 1
	fi
}

detect_advertise_addr() {
	local ip

	ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
	if [ -n "${ip:-}" ]; then
		printf '%s\n' "$ip"
		return
	fi

	for url in \
		"https://ifconfig.me" \
		"https://api.ipify.org" \
		"https://ipecho.net/plain"
	do
		ip="$(curl -4fsS --max-time 5 "$url" 2>/dev/null || true)"
		if [ -n "${ip:-}" ]; then
			printf '%s\n' "$ip"
			return
		fi
	done

	return 1
}

install_docker() {
	if command_exists docker; then
		return
	fi

	log "Installing Docker..."
	curl -fsSL https://get.docker.com | $SUDO sh -s -- --version "$DOCKER_VERSION"
	$SUDO systemctl enable --now docker >/dev/null 2>&1 || true
}

prepare_source() {
	local tmpdir archive extracted_root env_file
	tmpdir="$(mktemp -d)"
	archive="$tmpdir/source.tar.gz"

	log "Downloading ${REPO_OWNER}/${REPO_NAME}@${REPO_REF}..."
	curl -fsSL "https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_REF}.tar.gz" -o "$archive"
	tar -xzf "$archive" -C "$tmpdir"

	extracted_root="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
	if [ -z "${extracted_root:-}" ]; then
		echo "Failed to extract source archive." >&2
		exit 1
	fi

	env_file="$extracted_root/.env.production"
	printf 'PORT=3000\nNODE_ENV=production\n' > "$env_file"

	printf '%s\n' "$extracted_root"
}

ensure_swarm_and_network() {
	if [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)" != "active" ]; then
		advertise_addr="$(detect_advertise_addr)"
		if [ -z "${advertise_addr:-}" ]; then
			echo "Could not detect an advertise address. Set ADVERTISE_ADDR and retry." >&2
			exit 1
		fi
		log "Initializing Docker Swarm on ${advertise_addr}..."
		$SUDO docker swarm init --advertise-addr "$advertise_addr"
	fi

	if ! $SUDO docker network inspect dokploy-network >/dev/null 2>&1; then
		log "Creating dokploy-network..."
		$SUDO docker network create --driver overlay --attachable dokploy-network >/dev/null
	fi
}

build_image() {
	local source_dir="$1"
	log "Building ${IMAGE_NAME}:${IMAGE_TAG}..."
	$SUDO docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" -f "$source_dir/Dockerfile" "$source_dir"
}

deploy_service() {
	if service_exists; then
		log "Updating ${SERVICE_NAME}..."
		$SUDO docker service update --force --image "${IMAGE_NAME}:${IMAGE_TAG}" "$SERVICE_NAME" >/dev/null
	else
		log "Creating ${SERVICE_NAME}..."
		$SUDO docker service create \
			--name "$SERVICE_NAME" \
			--constraint 'node.role==manager' \
			--network dokploy-network \
			--publish "published=${PORT},target=3000,mode=host" \
			--mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
			--mount type=bind,src=/etc/dokploy,dst=/etc/dokploy \
			--env NODE_ENV=production \
			--env PORT=3000 \
			"${IMAGE_NAME}:${IMAGE_TAG}" >/dev/null
	fi
}

main() {
	install_docker

	if [ "${1:-}" != "update" ] && service_exists; then
		log "Dokploy already exists. Re-run with 'update' to rebuild from your fork."
		exit 0
	fi

	if ! service_exists; then
		ensure_ports_free
	fi

	$SUDO mkdir -p /etc/dokploy/traefik/dynamic
	$SUDO chown -R "$(id -u)":"$(id -g)" /etc/dokploy 2>/dev/null || true

	ensure_swarm_and_network

	source_dir="$(prepare_source)"
	build_image "$source_dir"
	deploy_service

	log "Dokploy fork installed successfully."
	log "Open http://$(hostname -I | awk '{print $1}'):${PORT}"
}

main "$@"
