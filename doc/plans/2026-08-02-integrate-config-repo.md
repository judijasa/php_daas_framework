# Public Repository with Private Configuration Repository

## Overview

This architecture separates publicly shareable source code from private operational data by using two independent Git repositories:

1. A **public repository** containing the application, scripts, templates, and documentation.
2. A **private repository** containing sensitive operational data and production-specific configuration.

The public repository does not contain information identifying the private repository. Instead, each deployment environment uses a locally configured, untracked file that specifies how or where the private data should be obtained.

---

## Repository Structure

### Public repository

The public repository contains all information that can safely be shared publicly.

Example:

```text
project/
├── application/
├── scripts/
├── config/
│   ├── defaults.yml
│   └── private-data.example.yml
├── fetch-private-data.example.sh
├── README.md
└── .gitignore
```

The public repository may include templates and documentation describing the expected structure of private data, without including the private data itself.

For example:

```text
config/private-data.example.yml
```

might document:

```yaml
machines:
  # Production machines are configured privately.

team:
  # Team-specific configuration is configured privately.
```

---

## Private Repository

The private repository contains production-specific and operational data that should be version-controlled but not publicly disclosed.

Example:

```text
private-data/
├── production/
│   ├── machines.yml
│   ├── team.yml
│   └── configuration.yml
└── README.md
```

Possible contents include:

* Production machine inventories.
* IP addresses and network information.
* Infrastructure configuration.
* Team operational information.
* Production-specific configuration.

Sensitive credentials and passwords should not be stored directly in Git merely because this repository is private. Credentials should use an appropriate secrets-management mechanism.

---

## Local Private Source Configuration

The public repository uses a local, untracked configuration file to specify where private data can be found or how it can be obtained.

For example:

```text
.private-source
```

This file is ignored by Git:

```gitignore
.private-source
```

An example template may be committed to the public repository:

```text
.private-source.example
```

For example:

```ini
PRIVATE_DATA_SOURCE=/path/to/private-data
```

The actual `.private-source` file may contain a local path or another private retrieval mechanism.

For example:

```ini
PRIVATE_DATA_SOURCE=/srv/private-data
```

Alternatively, a deployment-specific mechanism may use the configuration to retrieve or update the private repository.

The actual configuration file must remain untracked.

---

## Injection of Private Data

The public repository should define a stable mechanism for consuming private configuration.

For example:

```text
Public repository:

config/
├── defaults.yml
└── private-data.example.yml
```

Private repository:

```text
production/
└── production.yml
```

The application or deployment process can load configuration in layers:

```text
defaults.yml
    ↓
production.yml
```

Private configuration therefore supplements or overrides public defaults without requiring private data to be copied into the public Git history.

---

## Example Workflow

A production environment contains:

```text
/srv/application/
    ├── public repository checkout
    └── .private-source

/srv/private-data/
    └── private repository checkout
```

The local configuration might contain:

```ini
PRIVATE_DATA_SOURCE=/srv/private-data
```

A deployment script can then:

1. Read `.private-source`.
2. Locate or obtain the private data.
3. Validate the expected structure.
4. Inject, load, or reference the private configuration.
5. Run the application or deployment process.

The public repository remains fully functional without access to the private repository when operating in environments that do not require production-specific data.

---

## Visibility of the Private Repository

Public users can know that private configuration exists and that it is expected to follow a documented interface.

However, the public repository does not need to disclose:

* The name of the private repository.
* Its hosting provider.
* Its URL.
* Its filesystem location.
* The production environment where it is used.

This information can remain inside the untracked local configuration.

The privacy of the repository should not depend on hiding its identity. Access control to the private repository remains the primary security boundary.

---

## Design Principles

### Separate public code from private operational data

The public repository should contain source code and configuration interfaces that are safe to disclose.

The private repository should contain operational information that requires restricted access.

### Version-control private operational data

Information that is not appropriate for a public repository may still benefit from version control when stored in an appropriately access-controlled private repository.

This provides:

* Change history.
* Auditability.
* Collaboration.
* Rollback capability.
* Reproducible production configuration.

### Keep credentials separate

Passwords, private keys, tokens, and similar credentials should not automatically be committed to the private repository.

Private repository access control does not eliminate the risks associated with credentials being copied through Git history, clones, backups, CI systems, or developer machines.

A dedicated secrets-management mechanism should be used where appropriate.

### Use a stable interface

The public repository should define how private configuration is expected to integrate with the application.

For example:

```text
public defaults
    +
private environment configuration
```

This interface should remain relatively stable so that changes to the public application do not unnecessarily require restructuring the private repository.

---

## Advantages

This architecture provides several benefits:

* Public source code remains genuinely public.
* Private operational data can still be version-controlled.
* Public Git history never contains private operational data.
* The private repository can evolve independently.
* The public repository does not need to synchronize with private configuration commits.
* Production-specific configuration has its own history.
* Access to source code and access to operational information can be controlled independently.
* Public users can understand the expected private configuration interface without gaining access to production information.

---

## Security Considerations

The untracked local pointer to the private data source provides information separation, but it should not be treated as the primary security mechanism.

Security should primarily depend on:

* Proper access control for the private repository.
* Restricted access to production systems.
* Appropriate secrets management.
* Secure deployment mechanisms.
* Careful handling of backups and repository clones.

The fact that the public repository does not identify the private repository is useful for reducing unnecessary disclosure of infrastructure information, but repository privacy must ultimately be enforced by authentication and authorization.
