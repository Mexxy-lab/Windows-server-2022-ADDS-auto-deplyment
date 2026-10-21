
# Azure VMs use system-assigned managed identities, configured in compute.tf.
#
# This is the closest basic equivalent to an AWS EC2 instance profile.
# No Azure RBAC role is assigned automatically: grant only the permissions
# that a future bootstrap workflow actually needs.
#
# Do not grant Contributor or Owner at subscription scope just to make
# bootstrap scripts work. Prefer a narrowly scoped role at the resource
# group or individual-resource level when required.
