CLUSTER_NAME := mlops
REG_NAME     := kind-registry
SCRIPTS      := kind/scripts

.PHONY: registry-up cluster-up cluster-down

# Local registry on localhost:5001 (survives cluster rebuilds)
registry-up:
	@if docker inspect $(REG_NAME) >/dev/null 2>&1; then \
		docker start $(REG_NAME) >/dev/null; \
	else \
		bash $(SCRIPTS)/0-registry.sh; \
	fi

# Create the kind cluster, wire it to the registry, add the registry ConfigMap
cluster-up: registry-up
	@if kind get clusters | grep -qx $(CLUSTER_NAME); then \
		echo "cluster $(CLUSTER_NAME) already exists, skipping create"; \
	else \
		cd $(SCRIPTS) && bash 1-kind-cluster.sh; \
	fi
	bash $(SCRIPTS)/2-kind-docker-network.sh || true
	bash $(SCRIPTS)/3-containerd-network.sh
	kubectl apply -f kind/1-local-registry-cm.yaml

# Delete the cluster. The registry container and its images are kept.
cluster-down:
	kind delete cluster --name $(CLUSTER_NAME)
