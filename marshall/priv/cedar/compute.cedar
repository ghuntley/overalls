permit(principal is Marshall::User, action == Marshall::Action::"admin_read",
       resource == Marshall::ControlPlane::"marshall");

permit(principal is Marshall::User, action == Marshall::Action::"provision",
       resource == Marshall::ControlPlane::"marshall");

// A current user may change only their own account's self-service settings.
permit(principal is Marshall::User, action == Marshall::Action::"account_self",
       resource is Marshall::User)
when { resource == principal };

permit(principal is Marshall::User,
       action in [Marshall::Action::"admin_accounts",
                  Marshall::Action::"admin_operate", Marshall::Action::"admin_configure",
                  Marshall::Action::"admin_jobs"],
       resource == Marshall::ControlPlane::"marshall")
when { principal.administrator && principal.elevated };

permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write",
                  Marshall::Action::"manage", Marshall::Action::"web"],
       resource is Marshall::VM)
when { principal.administrator && principal.elevated };

// Machine profile capabilities and the owner's account bound every VM role,
// administrator override included: a machine whose owner is deleted or
// deactivated, or whose profile lacks the terminal capability, admits no one;
// only the owner may use a machine whose profile does not permit sharing; and
// web needs a profile with the web capability.
forbid(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write",
                  Marshall::Action::"manage", Marshall::Action::"web"],
       resource is Marshall::VM)
unless { resource.terminal && resource.owner_active };

forbid(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write",
                  Marshall::Action::"manage", Marshall::Action::"web"],
       resource is Marshall::VM)
when { resource.owner != principal && !resource.sharing };

forbid(principal is Marshall::User, action == Marshall::Action::"web",
       resource is Marshall::VM)
unless { resource.web_enabled };

permit(principal == Marshall::System::"compute",
       action == Marshall::Action::"coordinate", resource is Marshall::Internal);

// Library services act only through their own action on the Internal entities
// their resources' `cedar` mappings declare: AshAuthentication's sign-in and
// token reads and writes, and SCIM provisioning while SCIM is enabled.
permit(principal == Marshall::Service::"ash_authentication",
       action == Marshall::Action::"authenticate", resource is Marshall::Internal);

permit(principal == Marshall::Service::"scim",
       action == Marshall::Action::"scim_provision", resource is Marshall::Internal)
when { principal.enabled };

permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write", Marshall::Action::"manage"],
       resource is Marshall::VM)
when { resource.owner == principal || resource.managers.contains(principal) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write"],
       resource is Marshall::VM)
when { resource.operators.contains(principal) };

permit(principal is Marshall::User, action == Marshall::Action::"read",
       resource is Marshall::VM)
when { resource.viewers.contains(principal) };

// A thread whose creator is deleted or deactivated admits no one; grants and
// team roles count only on a sharing machine profile, leaving the creator.
forbid(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write",
                  Marshall::Action::"manage"],
       resource is Marshall::Thread)
unless { resource.owner_active };

forbid(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write",
                  Marshall::Action::"manage"],
       resource is Marshall::Thread)
when { resource.owner != principal && !resource.sharing };

// Thread roles survive machine generations; machine-only grants do not reveal threads.
permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write",
                  Marshall::Action::"manage"],
       resource is Marshall::Thread)
when { resource.owner == principal || resource.managers.contains(principal) ||
       resource.team_admins.contains(principal) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write"],
       resource is Marshall::Thread)
when { resource.operators.contains(principal) || resource.team_members.contains(principal) };

permit(principal is Marshall::User, action == Marshall::Action::"read",
       resource is Marshall::Thread)
when { resource.viewers.contains(principal) };

// Team authority: admins manage team machines; current members may read and use them.
// Team use includes private guest web; web-only grants retain their separate scope.
permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write",
                  Marshall::Action::"manage"],
       resource is Marshall::VM)
when { resource.team_admins.contains(principal) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write"],
       resource is Marshall::VM)
when { resource.team_members.contains(principal) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"team_read", Marshall::Action::"team_manage_members",
                  Marshall::Action::"team_transfer"],
       resource is Marshall::Team)
when { resource.owner == principal || resource.admins.contains(principal) };

permit(principal is Marshall::User, action == Marshall::Action::"team_read",
       resource is Marshall::Team)
when { resource.members.contains(principal) };

// An integration whose user owner is retired, or whose team is archived or
// missing, admits no one, administrators included.
forbid(principal is Marshall::User,
       action in [Marshall::Action::"integration_read", Marshall::Action::"integration_manage"],
       resource is Marshall::Integration)
unless { resource.live };

permit(principal is Marshall::User,
       action in [Marshall::Action::"integration_read", Marshall::Action::"integration_manage"],
       resource is Marshall::Integration)
when { principal.administrator && principal.elevated };

permit(principal is Marshall::User,
       action in [Marshall::Action::"integration_read", Marshall::Action::"integration_manage"],
       resource is Marshall::Integration)
when { resource.owner == principal || resource.managers.contains(principal) };

// Web-only sharing never implies VM metadata, terminal or SSH access.
permit(principal is Marshall::User, action == Marshall::Action::"web",
       resource is Marshall::VM)
when { resource.owner == principal || resource.managers.contains(principal) ||
       resource.operators.contains(principal) || resource.viewers.contains(principal) ||
       resource.web_users.contains(principal) || resource.team_admins.contains(principal) ||
       resource.team_members.contains(principal) };

// Artifacts: the immutable owner and co-owners hold every role; writers publish
// and use all storage; viewers read, keep personal storage and read shared
// storage. Every content action requires an active artifact.
permit(principal is Marshall::User, action == Marshall::Action::"artifact_create",
       resource is Marshall::ControlPlane)
when { principal.active };

permit(principal is Marshall::User,
       action in [Marshall::Action::"artifact_read", Marshall::Action::"artifact_publish",
                  Marshall::Action::"artifact_share", Marshall::Action::"artifact_delete",
                  Marshall::Action::"artifact_storage_personal",
                  Marshall::Action::"artifact_storage_shared_read",
                  Marshall::Action::"artifact_storage_shared_write"],
       resource is Marshall::Artifact)
when { resource.active && (resource.owner == principal || resource.owners.contains(principal)) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"artifact_read", Marshall::Action::"artifact_publish",
                  Marshall::Action::"artifact_storage_personal",
                  Marshall::Action::"artifact_storage_shared_read",
                  Marshall::Action::"artifact_storage_shared_write"],
       resource is Marshall::Artifact)
when { resource.active && resource.writers.contains(principal) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"artifact_read",
                  Marshall::Action::"artifact_storage_personal",
                  Marshall::Action::"artifact_storage_shared_read"],
       resource is Marshall::Artifact)
when { resource.active && resource.viewers.contains(principal) };

// An artifact whose owner is deleted or deactivated admits only moderation.
forbid(principal is Marshall::User,
       action in [Marshall::Action::"artifact_read", Marshall::Action::"artifact_publish",
                  Marshall::Action::"artifact_share", Marshall::Action::"artifact_delete",
                  Marshall::Action::"artifact_storage_personal",
                  Marshall::Action::"artifact_storage_shared_read",
                  Marshall::Action::"artifact_storage_shared_write"],
       resource is Marshall::Artifact)
unless { resource.owner_active };

// Moderation: elevated administrators may delete any active artifact. They are
// not granted content, storage or sharing access by this rule.
permit(principal is Marshall::User, action == Marshall::Action::"artifact_admin_delete",
       resource is Marshall::Artifact)
when { resource.active && principal.administrator && principal.elevated };

// A terminal session is usable by its owner and by users it is currently
// shared with. Sharing never grants machine access: callers also require VM
// authority for the session's machine.
permit(principal is Marshall::User, action == Marshall::Action::"terminal_session_use",
       resource is Marshall::TerminalSession)
when { resource.owner == principal || resource.viewers.contains(principal) };
