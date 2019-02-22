-include project.mk
.PHONY: help
.DEFAULT_GOAL := help

IMAGE_NAME           ?=
GO_MAIN_PATH         ?=
IMAGE_ENABLE         ?= false
IMAGE_BASE           ?= golang:alpine
PORT                 ?= 8000
GO_BUILD_FLAGS       ?= -ldflags "-d -s -w" -tags netgo -installsuffix netgo
PACKAGE_TIMESTAMP    ?=
PUBLISH              ?= false
DOCKER_PUBLISH_URL  ?=
DOCKER_PUBLISH_USER ?=
DOCKER_PUBLISH_PWD  ?=
DOCKER_PUBLISH_TAG  ?=

SERVER            = server
GO_MOD_CACHE      = /go/pkg/mod

GO                := $(shell command -v go 2> /dev/null)
DOCKER            := $(shell command -v docker 2> /dev/null)

.GOMODFILE        = go.mod
.GIT              = .git
.CACHE            = cache

check_defined = \
    $(strip $(foreach 1,$1, \
        $(call __check_defined,$1,$(strip $(value 2)))))
__check_defined = \
    $(if $(value $1),, \
      $(error Undefined $1$(if $2, ($2))))


ifndef PACKAGE_TIMESTAMP
ifeq ($(.GIT),$(wildcard $(.GIT)))
PACKAGE_TIMESTAMP = $(shell git rev-list --max-count=1 --timestamp HEAD | awk '{print $$1}')
endif
endif

$(call check_defined, GO_MAIN_PATH, path to the main.go package required)


ifeq ($(IMAGE_ENABLE), true)
$(call check_defined, DOCKER, please install docker)
$(call check_defined, IMAGE_NAME, no docker image name provided)
#$(call check_defined, PACKAGE_TIMESTAMP, required)
endif

ifeq ($(IMAGE_ENABLE), false)
$(call check_defined, GO, go is required to perform this operation)
endif

ifeq ($(PUBLISH),true)
$(call check_defined, DOCKER_PUBLISH_TAG, no remote tag provided)
$(call check_defined, DOCKER_PUBLISH_URL, docker registry url required)
$(call check_defined, DOCKER_PUBLISH_USER, docker username for registry required)
$(call check_defined, DOCKER_PUBLISH_PWD, docker password for registry required)
endif

ifndef IMAGE_BUILD
define IMAGE_BUILD
FROM $(IMAGE_BASE)
RUN apk add --no-cache git
endef
export IMAGE_BUILD
endif


ifndef IMAGE_PROD
define IMAGE_PROD
$(IMAGE_BUILD)
WORKDIR /src
COPY . .
RUN mkdir -p $(GO_MOD_CACHE)
RUN mv ./cache/* $(GO_MOD_CACHE)
RUN GO111MODULE=on go build $(GO_BUILD_FLAGS) -o $(SERVER) $(GO_MAIN_PATH)
RUN cp $(SERVER) /go/bin

FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /go/bin
COPY --from=0 /go/bin/$(SERVER) .
CMD ["./server"]
endef
export IMAGE_PROD
endif

image-build:
	@echo "$$IMAGE_BUILD" > Dockerfile
	docker build -t $(IMAGE_NAME)-build .


gomod:
ifneq ($(.GOMODFILE),$(wildcard $(.GOMODFILE)))
$(error go.mod is required)
endif

.PHONY: dockerfile
dockerfile:
	@echo "$$IMAGE_PROD" > Dockerfile

ifeq ($(IMAGE_ENABLE), true)
ifneq ($(.CACHE),$(wildcard $(.CACHE)))
	$(error cache missing, try running: make vendor)
endif

.PHONY: vendor
vendor: |image-build
	docker run -w /build -v $(shell pwd):/build -v $(shell pwd)/cache:$(GO_MOD_CACHE) -e GO111MODULE=on $(IMAGE_NAME)-build go mod download


run: |build
	docker run -p$(PORT):$(PORT) $(IMAGE_NAME)

build: |gomod dockerfile
	docker build -t $(IMAGE_NAME) .

test: |gomod
	docker run -w /build -v $(shell pwd):/build -v $(shell pwd)/cache:$(GO_MOD_CACHE) -e GO111MODULE=on $(IMAGE_NAME)-build go test $(GO_BUILD_FLAGS) ./pkg/...

ifeq ($(PUBLISH),true)
publish: ## Publish a container to a docker registry [IMAGE_ENABLE and PUBLISH required]
	@make publish-impl
publish-impl: |build
	@docker login -u $(DOCKER_PUBLISH_USER) -p $(DOCKER_PUBLISH_PWD) $(DOCKER_PUBLISH_URL)
	docker -t $(shell docker images -q $(IMAGE_NAME)) $(DOCKER_PUBLISH_URL)/$(DOCKER_PUBLISH_TAG)
	docker push $(DOCKER_PUBLISH_URL)/$(DOCKER_PUBLISH_TAG)
endif

endif

ifeq ($(IMAGE_ENABLE), false)
run: ## Run the project
	@make run-impl
run-impl: |gomod
	GO111MODULE=on go run $(GO_MAIN_PATH)

build: ## Build the project
	@make build-impl
build-impl: |gomod
	GO111MODULE=on go build $(GO_MAIN_PATH)

test: ## Run tests under pkg directory
	@make test-impl
test-impl: |gomod
	GO111MODULE=on go test ./pkg/...

.PHONY: vendor
vendor: ## Download the dependencies
vendor-impl: |gomod
	GO111MODULE=on go mod download
endif

help: ## Show this help message.
	@echo 'usage: make [target]'
	@echo
	@echo 'targets:'
	@egrep '^(.+)\:\ ##\ (.+)' ${MAKEFILE_LIST} | column -t -c 2 -s ':#'