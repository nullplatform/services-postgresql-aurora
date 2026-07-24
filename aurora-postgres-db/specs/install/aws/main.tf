################################################################################
# Install — registers the aurora-postgres-db service definition and its
# agent association (notification channel) on a nullplatform account.
################################################################################

locals {
  service_path      = "aurora-postgres-db"
  available_links   = ["connect"]
  available_actions = []
}

module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v4.5.1"

  nrn               = var.nrn
  repository_org    = var.repository_org
  repository_name   = var.repository_name
  repository_branch = var.repository_branch
  repository_token  = var.repository_token
  service_path      = local.service_path
  service_name      = var.service_name
  available_links   = local.available_links
  available_actions = local.available_actions
}

module "service_definition_agent_association" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v4.5.1"

  nrn                          = var.nrn
  repository_service_spec_repo = "${var.repository_org}/${var.repository_name}"
  service_path                 = local.service_path
  service_specification_slug   = module.service_definition.service_specification_slug
  api_key                      = var.np_api_key
  tags_selectors               = var.tags_selectors
}
