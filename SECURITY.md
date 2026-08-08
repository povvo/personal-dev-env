# Security

Keep this repository free of credentials, personal identifiers, private service URLs, private keys, user-specific paths, generated inventories, and WSL storage. If sensitive material is committed, rotate the affected credential first, then remove the material from Git history through a separately reviewed recovery process.

Review scripts before running them. The bootstrap installs packages, registers a WSL distribution, enables Docker, and adds the configured Linux user to the Docker group. Docker socket access is root-equivalent. The included services must remain loopback-only or isolated on private container networks.

Do not run package scripts, repository hooks, mise tasks, Dev Containers, Compose files, notebooks, or MCP servers from untrusted incoming repositories before inspection. Use the installed environment's quarantine route.

Report security issues privately to the repository owner through GitHub rather than opening a public issue.
