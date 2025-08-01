# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# Copyright Contributors to the Open Cluster Management project

PWD := $(shell pwd)
LOCAL_BIN ?= $(PWD)/bin

export PATH := $(LOCAL_BIN):$(PATH)
GOARCH = $(shell go env GOARCH)
GOOS = $(shell go env GOOS)
TESTARGS_DEFAULT := -v
export TESTARGS ?= $(TESTARGS_DEFAULT)

# Get the branch of the PR target or Push in Github Action
ifeq ($(GITHUB_EVENT_NAME), pull_request) # pull request
	BRANCH := $(GITHUB_BASE_REF)
else ifeq ($(GITHUB_EVENT_NAME), push) # push
	BRANCH := $(GITHUB_REF_NAME)
else # Default to main
	BRANCH := main
endif

# Handle KinD configuration
KIND_NAME ?= test-managed
KIND_HUB_NAME ?= test-hub
KIND_CLUSTER_NAME ?= kind-$(KIND-NAME)
KIND_HUB_CLUSTER_NAME ?= kind-$(KIND_HUB_NAME)
KIND_NAMESPACE ?= open-cluster-management-agent-addon
KIND_VERSION ?= latest
MANAGED_CLUSTER_NAME ?= managed
HUB_CLUSTER_NAME ?= hub
HUB_CONFIG ?= $(PWD)/kubeconfig_hub
HUB_CONFIG_INTERNAL ?= $(PWD)/kubeconfig_hub_internal
MANAGED_CONFIG ?= $(PWD)/kubeconfig_managed
deployOnHub ?= false
CONTROLLER_NAME ?= $(shell cat COMPONENT_NAME 2> /dev/null)
# Set the Kind version tag
ifeq ($(KIND_VERSION), minimum)
	KIND_ARGS = --image kindest/node:v1.19.16
	E2E_FILTER = --label-filter="!skip-minimum"
	export DISABLE_GK_SYNC = true
else ifneq ($(KIND_VERSION), latest)
	KIND_ARGS = --image kindest/node:$(KIND_VERSION)
else
	KIND_ARGS =
endif
# Test coverage threshold
export COVERAGE_MIN ?= 69
COVERAGE_E2E_OUT ?= coverage_e2e.out

export OSDK_FORCE_RUN_MODE ?= local

# Image URL to use all building/pushing image targets;
# Use your own docker registry and image name for dev/test by overridding the IMG and REGISTRY environment variable.
IMG ?= $(CONTROLLER_NAME)
VERSION ?= $(shell cat COMPONENT_VERSION 2> /dev/null)
REGISTRY ?= quay.io/open-cluster-management
TAG ?= latest
IMAGE_NAME_AND_VERSION ?= $(REGISTRY)/$(IMG)

include build/common/Makefile.common.mk

############################################################
# clean section
############################################################

.PHONY: clean
clean:
	-rm bin/*
	-rm build/_output/bin/*
	-rm coverage*.out
	-rm report*.json
	-rm kubeconfig_*
	-rm -r vendor/

############################################################
# format section
############################################################

.PHONY: fmt
fmt:

.PHONY: lint
lint:

############################################################
# test section
############################################################

.PHONY: test
test: test-dependencies
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" go test $(TESTARGS) `go list ./... | grep -v test/e2e`

.PHONY: test-coverage
test-coverage: TESTARGS = -json -cover -covermode=atomic -coverprofile=coverage_unit.out
test-coverage: test

.PHONY: test-dependencies
test-dependencies: envtest kubebuilder

############################################################
# build section
############################################################

.PHONY: build
build:
	CGO_ENABLED=1 go build -o build/_output/bin/$(IMG) ./

.PHONY: run
run:
	HUB_CONFIG=$(HUB_CONFIG) MANAGED_CONFIG=$(MANAGED_CONFIG) go run ./main.go --leader-elect=false --cluster-namespace=$(MANAGED_CLUSTER_NAME)

############################################################
# images section
############################################################

.PHONY: build-images
build-images:
	@docker build -t ${IMAGE_NAME_AND_VERSION} -f build/Dockerfile .
	@docker tag ${IMAGE_NAME_AND_VERSION} $(REGISTRY)/$(IMG):$(TAG)

.PHONY: deploy
deploy: generate-operator-yaml
	kubectl apply -f deploy/operator.yaml -n $(KIND_NAMESPACE) --kubeconfig=$(MANAGED_CONFIG)_e2e

############################################################
# Generate manifests
############################################################

.PHONY: manifests
manifests: controller-gen
	$(CONTROLLER_GEN) crd rbac:roleName=governance-policy-framework-addon paths="./..." output:rbac:artifacts:config=deploy/rbac

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: generate-operator-yaml
generate-operator-yaml: kustomize manifests
	$(KUSTOMIZE) build deploy/manager > deploy/operator.yaml

############################################################
# e2e test section
############################################################

.PHONY: kind-bootstrap-cluster
kind-bootstrap-cluster: kind-bootstrap-cluster-dev kind-deploy-controller

.PHONY: kind-bootstrap-cluster-dev
kind-bootstrap-cluster-dev: kind-create-all-clusters install-crds kind-controller-all-kubeconfigs


HOSTED ?= none

.PHONY: kind-deploy-controller-dev
kind-deploy-controller-dev: 
	if [ "$(HOSTED)" = "hosted" ]; then\
		$(MAKE) kind-deploy-controller-dev-addon ;\
	else\
		$(MAKE) kind-deploy-controller-dev-normal ;\
	fi

.PHONY: kind-deploy-controller
kind-deploy-controller: generate-operator-yaml install-resources deploy
	-kubectl create secret -n $(KIND_NAMESPACE) generic hub-kubeconfig --from-file=kubeconfig=$(HUB_CONFIG_INTERNAL) --kubeconfig=$(MANAGED_CONFIG)_e2e

.PHONY: kind-deploy-controller-dev-normal
kind-deploy-controller-dev-normal: kind-deploy-controller
	@echo Pushing image to KinD cluster
	kind load docker-image $(REGISTRY)/$(IMG):$(TAG) --name $(KIND_NAME)
	@echo "Patch deployment image"
	kubectl patch deployment $(IMG) -n $(KIND_NAMESPACE) -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$(IMG)\",\"args\":[\"--hub-cluster-configfile=/var/run/klusterlet/kubeconfig\", \"--cluster-namespace=$(MANAGED_CLUSTER_NAME)\", \"--enable-lease=true\", \"--log-level=2\", \"--disable-spec-sync=$(deployOnHub)\"]}]}}}}" --kubeconfig=$(MANAGED_CONFIG)_e2e
	kubectl patch deployment $(IMG) -n $(KIND_NAMESPACE) -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$(IMG)\",\"imagePullPolicy\":\"Never\"}]}}}}" --kubeconfig=$(MANAGED_CONFIG)_e2e
	kubectl patch deployment $(IMG) -n $(KIND_NAMESPACE) -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$(IMG)\",\"image\":\"$(REGISTRY)/$(IMG):$(TAG)\"}]}}}}" --kubeconfig=$(MANAGED_CONFIG)_e2e
	kubectl rollout status -n $(KIND_NAMESPACE) deployment $(IMG) --timeout=180s --kubeconfig=$(MANAGED_CONFIG)_e2e

.PHONY: kind-create-all-clusters
kind-create-all-clusters:
	CLUSTER_NAME=$(MANAGED_CLUSTER_NAME) $(MAKE) kind-create-cluster
	CLUSTER_NAME=$(HUB_CLUSTER_NAME) KIND_NAME=$(KIND_HUB_NAME) KIND_CLUSTER_NAME=$(KIND_HUB_CLUSTER_NAME) $(MAKE) kind-create-cluster

.PHONY: kind-controller-all-kubeconfigs
kind-controller-all-kubeconfigs:
	CLUSTER_NAME=$(MANAGED_CLUSTER_NAME) $(MAKE) kind-controller-kubeconfig
	CLUSTER_NAME=$(HUB_CLUSTER_NAME) KIND_NAME=$(KIND_HUB_NAME) KIND_CLUSTER_NAME=$(KIND_HUB_CLUSTER_NAME) $(MAKE) kind-controller-kubeconfig
	yq e '.clusters[0].cluster.server = "https://$(KIND_HUB_NAME)-control-plane:6443"' $(HUB_CONFIG) > $(HUB_CONFIG_INTERNAL)

.PHONY: kind-deploy-controller-dev-addon
kind-deploy-controller-dev-addon:
	@echo Hosted mode test
	kind load docker-image $(REGISTRY)/$(IMG):$(TAG) --name $(KIND_NAME)
	kubectl annotate -n $(subst -hosted,,$(KIND_NAMESPACE)) --overwrite managedclusteraddon governance-policy-framework\
		addon.open-cluster-management.io/values='{"global":{"imagePullPolicy": "Never", "imageOverrides":{"governance_policy_framework_addon": "$(REGISTRY)/$(IMG):$(TAG)"}}}'

.PHONY: kind-delete-cluster
kind-delete-cluster:
	kind delete cluster --name $(KIND_HUB_NAME)
	kind delete cluster --name $(KIND_NAME)

.PHONY: install-crds
install-crds:
	@echo installing crds
	kubectl apply -f https://raw.githubusercontent.com/open-cluster-management-io/governance-policy-propagator/$(BRANCH)/deploy/crds/policy.open-cluster-management.io_policies.yaml --kubeconfig=$(HUB_CONFIG)_e2e
	kubectl apply -f https://raw.githubusercontent.com/open-cluster-management-io/governance-policy-propagator/$(BRANCH)/deploy/crds/policy.open-cluster-management.io_policies.yaml --kubeconfig=$(MANAGED_CONFIG)_e2e
	kubectl apply -f https://raw.githubusercontent.com/open-cluster-management-io/config-policy-controller/$(BRANCH)/deploy/crds/policy.open-cluster-management.io_configurationpolicies.yaml --kubeconfig=$(MANAGED_CONFIG)_e2e

.PHONY: install-resources
install-resources:
	@echo creating namespace on hub
	-kubectl create ns $(MANAGED_CLUSTER_NAME) --kubeconfig=$(HUB_CONFIG)_e2e
	@echo creating namespace on managed
	-kubectl create ns $(MANAGED_CLUSTER_NAME) --kubeconfig=$(MANAGED_CONFIG)_e2e
	@echo Deploying roles and service account
	-kubectl create ns $(KIND_NAMESPACE) --kubeconfig=$(MANAGED_CONFIG)_e2e
	-kubectl apply -k deploy/rbac --kubeconfig=$(MANAGED_CONFIG)_e2e
	-kubectl create ns $(KIND_NAMESPACE) --kubeconfig=$(HUB_CONFIG)_e2e
	-kubectl apply -k deploy/hubpermissions --kubeconfig=$(HUB_CONFIG)_e2e
	@if [ "$(KIND_VERSION)" != "minimum" ]; then \
		echo installing Gatekeeper on the managed cluster; \
		curl -L https://raw.githubusercontent.com/stolostron/gatekeeper/release-3.17/deploy/gatekeeper.yaml | sed 's/- --disable-cert-rotation/- --disable-cert-rotation\n        - --audit-interval=10/g' | kubectl apply --kubeconfig=$(MANAGED_CONFIG)_e2e -f -; \
		kubectl -n gatekeeper-system wait --for=condition=Available deployment/gatekeeper-audit --kubeconfig=$(MANAGED_CONFIG)_e2e; \
	fi

.PHONY: e2e-test
e2e-test: e2e-dependencies
	$(GINKGO) -v --fail-fast $(E2E_TEST_ARGS) $(E2E_FILTER) test/e2e

.PHONY: e2e-test-coverage
e2e-test-coverage: E2E_TEST_ARGS = --json-report=report_e2e.json --output-dir=.
e2e-test-coverage: e2e-run-instrumented e2e-test e2e-stop-instrumented

.PHONY: e2e-test-uninistall
e2e-test-uninistall:
	$(GINKGO) -v --fail-fast --json-report=report_e2e_uninstall.json --output-dir=. --label-filter='uninstall' \
	 --covermode=atomic --coverprofile=coverage_e2e_uninstall_trigger.out \
	 --coverpkg=open-cluster-management.io/governance-policy-framework-addon/controllers/uninstall test/e2e

.PHONY: e2e-test-uninstall-coverage
e2e-test-uninstall-coverage: COVERAGE_E2E_OUT = coverage_e2e_uninstall_controller.out
e2e-test-uninstall-coverage: e2e-run-instrumented scale-down-deployment e2e-test-uninistall e2e-stop-instrumented

.PHONY: scale-down-deployment
scale-down-deployment:
	kubectl scale deployment $(IMG) -n $(KIND_NAMESPACE) --replicas=0 --kubeconfig=$(MANAGED_CONFIG)_e2e

.PHONY: e2e-build-instrumented
e2e-build-instrumented:
	go test -covermode=atomic -coverpkg=$(shell cat go.mod | head -1 | cut -d ' ' -f 2)/... -c -tags e2e ./ -o build/_output/bin/$(IMG)-instrumented

.PHONY: e2e-run-instrumented
LOG_REDIRECT ?= &>build/_output/controller.log
e2e-run-instrumented: e2e-build-instrumented
	HUB_CONFIG=$(HUB_CONFIG) MANAGED_CONFIG=$(MANAGED_CONFIG) MANAGED_CLUSTER_NAME=$(MANAGED_CLUSTER_NAME) \
		./build/_output/bin/$(IMG)-instrumented -test.run "^TestRunMain$$" -test.coverprofile=$(COVERAGE_E2E_OUT) 2>&1 \
		| tee ./build/_output/controller.log &

.PHONY: e2e-stop-instrumented
e2e-stop-instrumented:
	ps -ef | grep '$(IMG)' | grep -v grep | awk '{print $$2}' | xargs kill

.PHONY: e2e-debug
e2e-debug:
	@echo local controller log:
	-cat build/_output/controller.log
	@echo pods on hub cluster
	-kubectl get pods -A --kubeconfig=$(HUB_CONFIG)_e2e
	-kubectl get pods -A -o yaml --kubeconfig=$(HUB_CONFIG)_e2e
	@echo pods on managed cluster
	-kubectl get pods -A --kubeconfig=$(MANAGED_CONFIG)_e2e
	-kubectl get pods -A -o yaml --kubeconfig=$(MANAGED_CONFIG)_e2e
	@echo gatekeeper logs on managed cluster
	-kubectl logs -n gatekeeper-system -l control-plane=audit-controller --prefix=true --since=5m --kubeconfig=$(MANAGED_CONFIG)_e2e
	-kubectl logs -n gatekeeper-system -l control-plane=controller-manager --prefix=true --since=5m --kubeconfig=$(MANAGED_CONFIG)_e2e
	@echo remote controller log:
	-kubectl logs $$(kubectl get pods -n $(KIND_NAMESPACE) -o name --kubeconfig=$(MANAGED_CONFIG)_e2e | grep $(IMG)) -n $(KIND_NAMESPACE) --kubeconfig=$(MANAGED_CONFIG)_e2e

############################################################
# test coverage
############################################################
COVERAGE_FILE = coverage.out

.PHONY: coverage-merge
coverage-merge: coverage-dependencies
	@echo Merging the coverage reports into $(COVERAGE_FILE)
	$(GOCOVMERGE) $(PWD)/coverage_* > $(COVERAGE_FILE)

.PHONY: coverage-verify
coverage-verify:
	./build/common/scripts/coverage_calc.sh
