# ZOA Lambda was previously optional via count on module.zoa_lambda (integration/stage
# state may still use module.zoa_lambda[0].*). #853 removed count so the module is
# always provisioned; this block renames state addresses without destroy/create in AWS.
moved {
  from = module.zoa_lambda[0]
  to   = module.zoa_lambda
}

# Environments that created disposable authz tables keep them across the rename.
moved {
  from = module.ephemeral_authz_tables
  to   = module.authz_tables
}
