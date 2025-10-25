# Contributing to nim-gke

Thank you for considering contributing to nim-gke!

---

## Code of Conduct

Be respectful, constructive, and professional. Focus on what's best for the community.

---

## How to Contribute

### Reporting Issues

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) and include:

- Environment details (GKE version, GPU type, region)
- Steps to reproduce
- Expected vs. actual behavior
- Logs (`kubectl logs`, `kubectl describe`)

### Proposing Changes

1. **Fork** the repository
2. **Create a branch**: `git checkout -b feature/your-feature`
3. **Make changes** following our standards (see below)
4. **Test** your changes (deploy and validate)
5. **Commit** with conventional commits: `feat:`, `fix:`, `docs:`, `chore:`
6. **Push** to your fork
7. **Open a PR** using the [PR template](.github/PULL_REQUEST_TEMPLATE.md)

---

## Development Standards

### Shell Scripts

- Use `#!/bin/bash` shebang
- Enable strict mode: `set -euo pipefail`
- Validate with shellcheck: `shellcheck scripts/*.sh`
- Make scripts idempotent (check before create)
- Use consistent logging: `✅` `❌` `⏳` `⚠️`

Example:
```bash
#!/bin/bash
set -euo pipefail

# Check if resource exists
if gcloud container clusters describe my-cluster &>/dev/null; then
  echo "✅ Cluster exists, skipping creation"
  exit 0
fi

# Create resource
echo "⏳ Creating cluster..."
gcloud container clusters create my-cluster
echo "✅ Cluster created"
```

### YAML Files

- Validate with yamllint: `yamllint charts/*.yaml`
- Use 2-space indentation
- Explicit naming (no `config.yaml`, use `values-production.yaml`)
- Include resource limits and requests

### Documentation

- Information density over word count
- No filler language ("simple", "just", "easy")
- Use technical compound terms (GPU-accelerated, container-native)
- Include operational commands with expected output
- Structure: Deploy → Verify → Operate → Troubleshoot

### Git Commits

Follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation only
- `chore:` Maintenance (dependencies, cleanup)
- `refactor:` Code restructuring
- `test:` Test additions/changes

Examples:
```
feat: add A100 GPU support to deployment script
fix: resolve secret key mismatch in NIM pod
docs: update cost estimates for us-west1
chore: upgrade helm chart to v1.4.0
```

---

## Testing Requirements

Before submitting a PR:

1. **Lint scripts**: `shellcheck scripts/*.sh`
2. **Validate YAML**: `yamllint charts/*.yaml`
3. **Deploy to test cluster**: `./scripts/deploy_nim_gke.sh`
4. **Run integration tests**: `./scripts/test_nim_production.sh`
5. **Verify cleanup**: `./scripts/cleanup.sh`
6. **Check documentation**: All commands tested

---

## Project Structure

```
nim-gke/
├── charts/          # Helm charts and values
├── scripts/         # Operational scripts
├── docs/            # Technical documentation
├── runbooks/        # Operational procedures
├── examples/        # Configuration templates
└── .github/         # CI/CD, templates
```

**Rules**:
- Scripts go in `scripts/` (all `.sh` files)
- Documentation in `docs/` (`.md` files)
- Operational procedures in `runbooks/`
- No files in root except README, LICENSE, .gitignore

---

## Documentation Guidelines

### Architecture Docs

- Explain component interactions
- Include data flow
- Provide design rationale (not just "what" but "why")
- Reference specific files/functions

### Runbooks

- One procedure per section
- Include symptoms, diagnosis, resolution
- Provide exact commands
- Show expected output
- Add escalation paths

### README Updates

- Keep concise (under 400 lines)
- Quick start must be ≤5 commands
- Include cost information
- Link to detailed docs

---

## Pull Request Process

1. **CI must pass**: Shellcheck, yamllint, security scan
2. **Documentation updated**: If adding features or changing behavior
3. **Scripts tested**: Deploy and verify in test cluster
4. **Breaking changes**: Document in PR description
5. **Cost impact**: Note any changes to resource costs

### Review Criteria

We review for:

- **Correctness**: Does it work as intended?
- **Idempotency**: Can it run multiple times safely?
- **Error handling**: Does it fail gracefully?
- **Security**: No secrets, proper validation
- **Cost**: Resource efficiency
- **Documentation**: Clear and complete

---

## Areas for Contribution

### High Priority

- Terraform modules (replace shell scripts)
- Multi-region deployment support
- Prometheus + Grafana dashboards
- ArgoCD integration (GitOps)
- Cost optimization (spot instances)

### Medium Priority

- Additional GPU types (A100, H100)
- Multi-model deployment
- HPA for pod autoscaling
- Network policy examples
- Load testing scripts

### Documentation

- Architecture diagrams (draw.io, Mermaid)
- Video walkthroughs
- Performance tuning guide
- Migration from other platforms

---

## Getting Help

- **Questions**: Open a discussion (not an issue)
- **Bugs**: Use bug report template
- **Features**: Describe use case, not implementation
- **Urgent**: Tag with `priority: high` and provide context

---

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

**Thank you for improving nim-gke!** 🚀

