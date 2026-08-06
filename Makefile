SHELL := /bin/bash
.DEFAULT_GOAL := help

RKE2_VERSION ?= v1.36.2+rke2r1
RKE2_ARCH ?= amd64
ARTIFACT_DIR ?= local_artifacts
INVENTORY ?= inventory/hosts.yml
PLAYBOOK ?= playbooks/site.yml
VARS ?= config/cluster.yml
LIMIT ?=
TAGS ?=
SKIP_TAGS ?=
EXTRA_VARS ?=
ANSIBLE_ARGS ?=

RKE2_RELEASE_URL := https://github.com/rancher/rke2/releases/download/$(subst +,%2B,$(RKE2_VERSION))
ROLE_NAME := $(notdir $(CURDIR))
ROLE_PARENT := $(abspath $(CURDIR)/..)
ARTIFACT_DIR_ABS := $(abspath $(ARTIFACT_DIR))

RKE2_ARTIFACTS := \
	sha256sum-$(RKE2_ARCH).txt \
	rke2.linux-$(RKE2_ARCH).tar.gz \
	rke2-images-core.linux-$(RKE2_ARCH).tar.zst \
	rke2-images-cilium.linux-$(RKE2_ARCH).tar.zst

ANSIBLE_COMMON_ARGS = \
	-i $(INVENTORY) \
	$(PLAYBOOK) \
	-e @$(VARS) \
	-e rke2_version=$(RKE2_VERSION) \
	-e rke2_architecture=$(RKE2_ARCH) \
	-e rke2_airgap_mode=true \
	-e rke2_airgap_copy_sourcepath=$(ARTIFACT_DIR_ABS) \
	$(if $(LIMIT),--limit $(LIMIT)) \
	$(if $(TAGS),--tags $(TAGS)) \
	$(if $(SKIP_TAGS),--skip-tags $(SKIP_TAGS)) \
	$(if $(EXTRA_VARS),--extra-vars '$(EXTRA_VARS)') \
	$(ANSIBLE_ARGS)

.PHONY: help prerequisites artifacts verify-artifacts collections syntax ping check dry-run install

help: ## 显示帮助
	@awk 'BEGIN {FS = ":.*## "; printf "用法: make <目标> [参数=value]\n\n目标:\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\n常用参数:\n'
	@printf '  RKE2_VERSION=%s\n' '$(RKE2_VERSION)'
	@printf '  RKE2_ARCH=%s  INVENTORY=%s  VARS=%s\n' '$(RKE2_ARCH)' '$(INVENTORY)' '$(VARS)'
	@printf '  LIMIT=masters  TAGS=tag1,tag2  EXTRA_VARS="key=value"\n'

prerequisites: ## 检查本机所需命令和配置文件
	@command -v curl >/dev/null || { echo '缺少 curl'; exit 1; }
	@command -v sha256sum >/dev/null || { echo '缺少 sha256sum'; exit 1; }
	@command -v ansible-playbook >/dev/null || { echo '缺少 ansible-playbook'; exit 1; }
	@test -f '$(INVENTORY)' || { echo 'Inventory 不存在: $(INVENTORY)'; exit 1; }
	@test -f '$(PLAYBOOK)' || { echo 'Playbook 不存在: $(PLAYBOOK)'; exit 1; }
	@test -f '$(VARS)' || { echo '参数文件不存在: $(VARS)'; exit 1; }

$(ARTIFACT_DIR):
	mkdir -p '$@'

$(ARTIFACT_DIR)/rke2.sh: | $(ARTIFACT_DIR)
	curl --fail --location --retry 3 --output '$@' https://get.rke2.io
	chmod 0755 '$@'

$(ARTIFACT_DIR)/%: | $(ARTIFACT_DIR)
	curl --fail --location --retry 3 --continue-at - --output '$@' '$(RKE2_RELEASE_URL)/$*'

artifacts: $(ARTIFACT_DIR)/rke2.sh $(addprefix $(ARTIFACT_DIR)/,$(RKE2_ARTIFACTS)) ## 下载并校验离线安装文件
	@$(MAKE) --no-print-directory verify-artifacts ARTIFACT_DIR='$(ARTIFACT_DIR)' RKE2_ARCH='$(RKE2_ARCH)'

verify-artifacts: ## 校验已经下载的 RKE2 文件
	@cd '$(ARTIFACT_DIR)' && sha256sum --check --ignore-missing 'sha256sum-$(RKE2_ARCH).txt'
	@for file in $(RKE2_ARTIFACTS); do test -s '$(ARTIFACT_DIR)/'$$file || { echo "文件缺失或为空: $$file"; exit 1; }; done
	@test -s '$(ARTIFACT_DIR)/rke2.sh' || { echo '文件缺失或为空: rke2.sh'; exit 1; }

collections: ## 安装角色依赖的 Ansible Collections
	ansible-galaxy collection install -r requirements.yml

syntax: prerequisites ## 执行 Ansible 语法检查
	ANSIBLE_ROLES_PATH='$(ROLE_PARENT)' RKE2_ROLE_NAME='$(ROLE_NAME)' \
		ansible-playbook --syntax-check $(ANSIBLE_COMMON_ARGS)

ping: prerequisites ## 测试 Ansible 到所有节点的连接
	ansible all -i '$(INVENTORY)' -m ansible.builtin.ping $(if $(LIMIT),--limit '$(LIMIT)')

check: prerequisites artifacts ## 下载构件并按参数执行模拟安装，不修改节点
	ANSIBLE_ROLES_PATH='$(ROLE_PARENT)' RKE2_ROLE_NAME='$(ROLE_NAME)' \
		ansible-playbook --check --diff $(ANSIBLE_COMMON_ARGS)

dry-run: check ## check 的别名

install: prerequisites artifacts ## 下载构件并安装或升级 RKE2 集群
	ANSIBLE_ROLES_PATH='$(ROLE_PARENT)' RKE2_ROLE_NAME='$(ROLE_NAME)' \
		ansible-playbook $(ANSIBLE_COMMON_ARGS)
