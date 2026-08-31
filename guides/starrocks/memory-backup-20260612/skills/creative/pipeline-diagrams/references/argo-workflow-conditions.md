# Argo Workflows `when` Condition Patterns

When documenting CI/CD pipelines that use Argo Workflows, these condition patterns appear frequently:

## Tag vs Branch Detection

```yaml
# Branch push → mode=commit
when: "'{{workflow.parameters.git_ref}}' !~ '^refs/tags/'"

# Tag push → mode=tag
when: "'{{workflow.parameters.git_ref}}' =~ '^refs/tags/'"
```

Used in: kpack build workflows (e.g., `luban-ci-kpack-workflow-template.yaml`)

## Sequential vs Parallel Steps

```yaml
# Sequential (build THEN update-gitops)
steps:
  - - name: build-push
      template: build-push
    - name: update-gitops     # runs after build-push completes
      template: git-update
```

Both steps always run, but build-push has conditional execution based on the `when` clause.

## Argo `when` Syntax Reference

- `=~` — regex match
- `!~` — regex not-match
- `==` — equality
- `!=` — inequality
- Values must be quoted with single quotes inside double-quoted strings
