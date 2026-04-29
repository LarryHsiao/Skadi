---
name: CI workflow defined
scope: project
---

A foundation project has a CI workflow that runs both lint and test on every push or pull/merge request. Without it, broken main branches linger until release.

Detect a CI configuration at the project root:

- GitHub Actions: `.github/workflows/*.yml` or `*.yaml`
- GitLab CI: `.gitlab-ci.yml`
- Bitrise: `bitrise.yml`
- CircleCI: `.circleci/config.yml`
- Jenkins: `Jenkinsfile`
- Travis: `.travis.yml`
- Drone: `.drone.yml`
- Buildkite: `.buildkite/pipeline.yml`

Pass when:
- A CI configuration file exists AND defines a job that runs **both** of the following on push or pull/merge request:
  - **Tests** — e.g. `flutter test`, `npm test`, `vitest run`, `jest`, `pytest`, `go test`, `cargo test`, `rspec`.
  - **Lint / static analysis** — e.g. `flutter analyze`, `dart analyze`, `eslint`, `biome check`, `tsc --noEmit`, `golangci-lint run`, `go vet`, `staticcheck`, `cargo clippy`, `ruff check`, `swiftlint`, `detekt`.

The two steps may live in the same job or separate jobs of the same workflow.

Fail when:
- No CI configuration is found at any of the recognised paths.
- A CI configuration exists but defines no test step.
- A CI configuration exists but defines no lint / static-analysis step.
- A CI workflow runs only on release tags or manual dispatch and is never triggered on push or pull/merge request.

n/a when:
- The project is documentation- or asset-only with no test-bearing code.

On fail, name what was searched and which gate is missing (e.g. ".github/workflows/ci.yml runs `flutter test` but no `flutter analyze` step").
