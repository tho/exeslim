default: build-exeslim

build-exeslim: ## Build the exeslim Docker image locally
	@echo "Building exeslim Docker image..."
	docker build -t ghcr.io/tho/exeslim:dev .
	@echo "✓ Image built locally as ghcr.io/tho/exeslim:dev"

build: build-exeslim

run: build-exeslim
	docker run -it \
	  --cap-add=ALL \
	  --security-opt seccomp=unconfined \
	  --security-opt apparmor=unconfined \
	  --cgroupns private \
	  --tmpfs /run \
	  --tmpfs /run/lock \
	  --tmpfs /tmp \
	  --tmpfs /sys/fs/cgroup:rw \
	  ghcr.io/tho/exeslim:dev

run-bash: build-exeslim
	docker run -it \
	  --cap-add=ALL \
	  --security-opt seccomp=unconfined \
	  --security-opt apparmor=unconfined \
	  --cgroupns private \
	  --tmpfs /run \
	  --tmpfs /run/lock \
	  --tmpfs /tmp \
	  --tmpfs /sys/fs/cgroup:rw \
	  ghcr.io/tho/exeslim:dev bash

check: ## Build every image as :dev and run CI's checks on them
	ci/build.sh dev
	ci/check-image.sh dev
	ci/check-shelley.sh dev
