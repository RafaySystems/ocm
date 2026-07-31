SHELL :=/bin/bash

all: build
.PHONY: all

# Include the library makefile
include $(addprefix ./vendor/github.com/openshift/build-machinery-go/make/, \
	golang.mk \
	targets/openshift/deps.mk \
	targets/openshift/images.mk \
	targets/openshift/yaml-patch.mk\
	lib/tmp.mk\
)

# Include the integration/e2e setup makefile.
include ./test/integration-test.mk
include ./test/e2e-test.mk
include ./test/olm-test.mk

OPERATOR_SDK?=$(PERMANENT_TMP_GOPATH)/bin/operator-sdk
OPERATOR_SDK_VERSION?=v1.32.0
operatorsdk_gen_dir:=$(dir $(OPERATOR_SDK))

HELM?=$(PERMANENT_TMP_GOPATH)/bin/helm
HELM_VERSION?=v3.14.0
helm_gen_dir:=$(dir $(HELM))

# RELEASED_CSV_VERSION indicates the last released operator version.
# can find the released operator version from
# https://github.com/k8s-operatorhub/community-operators/tree/main/operators/cluster-manager
# https://github.com/k8s-operatorhub/community-operators/tree/main/operators/klusterlet
RELEASED_CSV_VERSION?=0.14.0
export RELEASED_CSV_VERSION

# CSV_VERSION is used to generate latest CSV manifests
CSV_VERSION?=9.9.9
export CSV_VERSION

OPERATOR_SDK_ARCHOS:=linux_amd64
HELM_ARCHOS:=linux-amd64
ifeq ($(GOHOSTOS),darwin)
	ifeq ($(GOHOSTARCH),amd64)
		OPERATOR_SDK_ARCHOS:=darwin_amd64
		HELM_ARCHOS:=darwin-amd64
	endif
	ifeq ($(GOHOSTARCH),arm64)
		OPERATOR_SDK_ARCHOS:=darwin_arm64
		HELM_ARCHOS:=darwin-arm64
	endif
endif

# Add packages to do unit test
GO_TEST_PACKAGES :=./pkg/...
GO_TEST_FLAGS := -race -coverprofile=coverage.out

IMAGE_REGISTRY?=registry.dev.rafay-edge.net/rafay
IMAGE_TAG?=0.0.1-$(shell date +%Y%m%d%H%M%S)

OPERATOR_IMAGE_NAME ?= $(IMAGE_REGISTRY)/ocm-registration-operator:$(IMAGE_TAG)
# WORK_IMAGE can be set in the env to override calculated value
WORK_IMAGE ?= $(IMAGE_REGISTRY)/ocm-work:$(IMAGE_TAG)
# REGISTRATION_IMAGE can be set in the env to override calculated value
REGISTRATION_IMAGE ?= $(IMAGE_REGISTRY)/ocm-registration:$(IMAGE_TAG)
# PLACEMENT_IMAGE can be set in the env to override calculated value
PLACEMENT_IMAGE ?= $(IMAGE_REGISTRY)/ocm-placement:$(IMAGE_TAG)
# ADDON_MANAGER_IMAGE can be set in the env to override calculated value
ADDON_MANAGER_IMAGE ?= $(IMAGE_REGISTRY)/ocm-addon-manager:$(IMAGE_TAG)

# Docker CLI for amd64 and push targets (override if needed, e.g. podman)
DOCKER ?= docker

# Registration / registration-operator: monorepo (.. + COPY ocm/, sdk-go/) vs ocm-only context (.).
ifeq ($(origin IMAGE_BUILD_CONTEXT),undefined)
ifeq ($(wildcard ../sdk-go/go.mod),)
IMAGE_BUILD_CONTEXT := .
REGISTRATION_DOCKERFILE := ./build/Dockerfile.registration.ocm-root
REGISTRATION_OPERATOR_DOCKERFILE := ./build/Dockerfile.registration-operator.ocm-root
else
IMAGE_BUILD_CONTEXT := ..
REGISTRATION_DOCKERFILE := ./build/Dockerfile.registration
REGISTRATION_OPERATOR_DOCKERFILE := ./build/Dockerfile.registration-operator
endif
else
ifeq ($(IMAGE_BUILD_CONTEXT),..)
REGISTRATION_DOCKERFILE := ./build/Dockerfile.registration
REGISTRATION_OPERATOR_DOCKERFILE := ./build/Dockerfile.registration-operator
else
REGISTRATION_DOCKERFILE := ./build/Dockerfile.registration.ocm-root
REGISTRATION_OPERATOR_DOCKERFILE := ./build/Dockerfile.registration-operator.ocm-root
endif
endif

$(call build-image,registration,$(REGISTRATION_IMAGE),$(REGISTRATION_DOCKERFILE),$(IMAGE_BUILD_CONTEXT))
$(call build-image,work,$(WORK_IMAGE),./build/Dockerfile.work,.)
$(call build-image,placement,$(PLACEMENT_IMAGE),./build/Dockerfile.placement,.)
$(call build-image,registration-operator,$(OPERATOR_IMAGE_NAME),$(REGISTRATION_OPERATOR_DOCKERFILE),$(IMAGE_BUILD_CONTEXT))
$(call build-image,addon-manager,$(ADDON_MANAGER_IMAGE),./build/Dockerfile.addon,.)

# linux/amd64 images (e.g. Apple Silicon → x86_64 cluster). Monorepo Dockerfiles need BuildKit (cache mounts).
#   DOCKER_BUILDKIT=1 make image-registration-amd64 image-registration-operator-amd64
image-registration-amd64:
	$(DOCKER) build --platform=linux/amd64 -t $(REGISTRATION_IMAGE) -f $(REGISTRATION_DOCKERFILE) $(IMAGE_BUILD_CONTEXT)
	echo $(REGISTRATION_IMAGE)
	$(DOCKER) push $(REGISTRATION_IMAGE)
.PHONY: image-registration-amd64

image-work-amd64:
	$(DOCKER) build --platform=linux/amd64 -t $(WORK_IMAGE) -f ./build/Dockerfile.work .
	echo $(WORK_IMAGE)
	$(DOCKER) push $(WORK_IMAGE)
.PHONY: image-work-amd64

image-placement-amd64:
	$(DOCKER) build --platform=linux/amd64 -t $(PLACEMENT_IMAGE) -f ./build/Dockerfile.placement .
	echo $(PLACEMENT_IMAGE)
	$(DOCKER) push $(PLACEMENT_IMAGE)
.PHONY: image-placement-amd64

image-registration-operator-amd64:
	$(DOCKER) build --platform=linux/amd64 -t $(OPERATOR_IMAGE_NAME) -f $(REGISTRATION_OPERATOR_DOCKERFILE) $(IMAGE_BUILD_CONTEXT)
	echo $(OPERATOR_IMAGE_NAME)
	$(DOCKER) push $(OPERATOR_IMAGE_NAME)
.PHONY: image-registration-operator-amd64

image-addon-manager-amd64:
	$(DOCKER) build --platform=linux/amd64 -t $(ADDON_MANAGER_IMAGE) -f ./build/Dockerfile.addon .
	echo $(ADDON_MANAGER_IMAGE)
	$(DOCKER) push $(ADDON_MANAGER_IMAGE)
.PHONY: image-addon-manager-amd64

# All component images for linux/amd64 (enable BuildKit for registration Dockerfiles).
images-amd64: image-registration-amd64 image-work-amd64 image-placement-amd64 image-registration-operator-amd64 image-addon-manager-amd64
.PHONY: images-amd64

push-registration:
	$(DOCKER) push $(REGISTRATION_IMAGE)
.PHONY: push-registration

push-registration-operator:
	$(DOCKER) push $(OPERATOR_IMAGE_NAME)
.PHONY: push-registration-operator

copy-crd: ensure-yaml-patch
	bash -x hack/copy-crds.sh $(YAML_PATCH)

update: copy-crd update-csv

test-unit: envtest-setup

update-csv: ensure-operator-sdk ensure-helm
	bash -x hack/update-csv.sh

verify-crds: ensure-yaml-patch
	bash -x hack/verify-crds.sh $(YAML_PATCH)

.PHONY: lint
lint:
	@bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/open-cluster-management-io/sdk-go/main/ci/lint/run-lint.sh | bash'

install-golang-gci:
	go install github.com/daixiang0/gci@v0.13.7

fmt-imports: install-golang-gci
	gci write --skip-generated -s standard -s default -s "prefix(open-cluster-management.io)" -s localmodule cmd pkg test dependencymagnet

verify-fmt-imports: install-golang-gci
	@output=$$(gci diff --skip-generated -s standard -s default -s "prefix(open-cluster-management.io)" -s localmodule cmd pkg test dependencymagnet); \
	if [ -n "$$output" ]; then \
	    echo "Diff output is not empty: $$output"; \
	    echo "Please run 'make fmt-imports' to format the golang files imports automatically."; \
	    exit 1; \
	else \
	    echo "Diff output is empty"; \
	fi

verify: verify-fmt-imports verify-crds lint

ensure-operator-sdk:
ifeq "" "$(wildcard $(OPERATOR_SDK))"
	$(info Installing operator-sdk into '$(OPERATOR_SDK)')
	mkdir -p '$(operatorsdk_gen_dir)'
	curl -s -f -L https://github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_SDK_VERSION)/operator-sdk_$(OPERATOR_SDK_ARCHOS) -o '$(OPERATOR_SDK)'
	chmod +x '$(OPERATOR_SDK)';
else
	$(info Using existing operator-sdk from "$(OPERATOR_SDK)")
endif

ensure-helm:
ifeq "" "$(wildcard $(HELM))"
	$(info Installing helm into '$(HELM)')
	mkdir -p '$(helm_gen_dir)'
	curl -s -f -L https://get.helm.sh/helm-$(HELM_VERSION)-$(HELM_ARCHOS).tar.gz -o '$(helm_gen_dir)$(HELM_VERSION)-$(HELM_ARCHOS).tar.gz'
	tar -zvxf '$(helm_gen_dir)/$(HELM_VERSION)-$(HELM_ARCHOS).tar.gz' -C $(helm_gen_dir)
	mv $(helm_gen_dir)/$(HELM_ARCHOS)/helm $(HELM)
	rm -rf $(helm_gen_dir)/$(HELM_ARCHOS)
	chmod +x '$(HELM)';
else
	$(info Using existing helm from "$(HELM)")
endif

