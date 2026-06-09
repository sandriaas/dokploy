#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-ghcr.io/sandriaas/dokploy}"
IMAGE_TAG="${IMAGE_TAG:-transfer-migration}"
SERVICE_NAME="${SERVICE_NAME:-dokploy}"
PORT="${PORT:-3000}"
DOCKER_VERSION="${DOCKER_VERSION:-28.5.2}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-3.6.7}"
TRAEFIK_PORT="${TRAEFIK_PORT:-80}"
TRAEFIK_SSL_PORT="${TRAEFIK_SSL_PORT:-443}"

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
	if ss -tulnp | grep -q ":${TRAEFIK_PORT} "; then
		echo "Port 80 is already in use." >&2
		exit 1
	fi
	if ss -tulnp | grep -q ":${TRAEFIK_SSL_PORT} "; then
		echo "Port 443 is already in use." >&2
		exit 1
	fi
	if ss -tulnp | grep -q ":${PORT} "; then
		echo "Port ${PORT} is already in use." >&2
		exit 1
	fi
}

create_default_traefik_files() {
	$SUDO mkdir -p /etc/dokploy/traefik/dynamic

	if [ ! -f /etc/dokploy/traefik/traefik.yml ]; then
		cat <<EOF | $SUDO tee /etc/dokploy/traefik/traefik.yml >/dev/null
providers:
  swarm:
    exposedByDefault: false
    watch: true
  docker:
    exposedByDefault: false
    watch: true
    network: dokploy-network
  file:
    directory: /etc/dokploy/traefik/dynamic
    watch: true
entryPoints:
  web:
    address: :${TRAEFIK_PORT}
  websecure:
    address: :${TRAEFIK_SSL_PORT}
    http3:
      advertisedPort: ${TRAEFIK_SSL_PORT}
    http:
      tls:
        certResolver: letsencrypt
api:
  insecure: true
certificatesResolvers:
  letsencrypt:
    acme:
      email: test@localhost.com
      storage: /etc/dokploy/traefik/dynamic/acme.json
      httpChallenge:
        entryPoint: web
EOF
	fi

	if [ ! -f /etc/dokploy/traefik/dynamic/middlewares.yml ]; then
		cat <<'EOF' | $SUDO tee /etc/dokploy/traefik/dynamic/middlewares.yml >/dev/null
http:
  middlewares:
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true
EOF
	fi

	if [ ! -f /etc/dokploy/traefik/dynamic/dokploy.yml ]; then
		cat <<EOF | $SUDO tee /etc/dokploy/traefik/dynamic/dokploy.yml >/dev/null
http:
  routers:
    dokploy-router-app:
      rule: Host(\`dokploy.docker.localhost\`) && PathPrefix(\`/\`)
      service: dokploy-service-app
      entryPoints:
        - web
  services:
    dokploy-service-app:
      loadBalancer:
        servers:
          - url: http://dokploy:3000
        passHostHeader: true
EOF
	fi

	if [ ! -f /etc/dokploy/traefik/dynamic/acme.json ]; then
		$SUDO touch /etc/dokploy/traefik/dynamic/acme.json
	fi

	$SUDO chmod 600 /etc/dokploy/traefik/dynamic/acme.json
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

pull_image() {
	log "Pulling ${IMAGE_NAME}:${IMAGE_TAG}..."
	$SUDO docker pull "${IMAGE_NAME}:${IMAGE_TAG}"
}

ensure_internal_services() {
	if ! $SUDO docker service inspect dokploy-postgres >/dev/null 2>&1; then
		log "Creating dokploy-postgres..."
		$SUDO docker service create --detach=true \
			--name dokploy-postgres \
			--constraint 'node.role==manager' \
			--network dokploy-network \
			--mount type=volume,src=dokploy-postgres,dst=/var/lib/postgresql/data \
			--env POSTGRES_USER=dokploy \
			--env POSTGRES_DB=dokploy \
			--env POSTGRES_PASSWORD=amukds4wi9001583845717ad2 \
			postgres:16 >/dev/null
	fi

	if ! $SUDO docker service inspect dokploy-redis >/dev/null 2>&1; then
		log "Creating dokploy-redis..."
		$SUDO docker service create --detach=true \
			--name dokploy-redis \
			--constraint 'node.role==manager' \
			--network dokploy-network \
			--mount type=volume,src=dokploy-redis,dst=/data \
			redis:7 >/dev/null
	fi
}

ensure_traefik_service() {
	create_default_traefik_files

	if $SUDO docker service inspect dokploy-traefik >/dev/null 2>&1; then
		log "Updating dokploy-traefik..."
		$SUDO docker service update --detach=true --force \
			--image "traefik:v${TRAEFIK_VERSION}" \
			dokploy-traefik >/dev/null
		return
	fi

	log "Creating dokploy-traefik..."
	$SUDO docker service create --detach=true \
		--name dokploy-traefik \
		--constraint 'node.role==manager' \
		--network dokploy-network \
		--mount type=bind,src=/etc/dokploy/traefik/traefik.yml,dst=/etc/traefik/traefik.yml \
		--mount type=bind,src=/etc/dokploy/traefik/dynamic,dst=/etc/dokploy/traefik/dynamic \
		--mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
		--publish "published=${TRAEFIK_PORT},target=80,mode=host" \
		--publish "published=${TRAEFIK_SSL_PORT},target=443,mode=host" \
		--publish "published=${TRAEFIK_SSL_PORT},target=443,mode=host,protocol=udp" \
		"traefik:v${TRAEFIK_VERSION}" >/dev/null
}

deploy_service() {
	if service_exists; then
		log "Updating ${SERVICE_NAME}..."
		$SUDO docker service update --detach=true --force --image "${IMAGE_NAME}:${IMAGE_TAG}" "$SERVICE_NAME" >/dev/null
	else
		log "Creating ${SERVICE_NAME}..."
		$SUDO docker service create --detach=true \
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

	if ! service_exists; then
		ensure_ports_free
	fi

	$SUDO mkdir -p /etc/dokploy/traefik/dynamic
	$SUDO chown -R "$(id -u)":"$(id -g)" /etc/dokploy 2>/dev/null || true

	ensure_swarm_and_network
	ensure_internal_services
	ensure_traefik_service

	if [ "${1:-}" != "update" ] && service_exists; then
		log "Dokploy already exists. Re-run with 'update' to pull and apply the latest fork image."
		exit 0
	fi

	pull_image
	deploy_service

	log "Dokploy fork installed successfully."
	log "Open http://$(hostname -I | awk '{print $1}'):${PORT}"
}

main "$@"
