## Summary

<!-- 1-3 bullet points describing what this PR does -->

- 

## Changes

<!-- Bullet list of specific changes made -->

- 

## DATA CONTRACT

<!--
REQUIRED if this PR:
  - Touches any S3 schema (s3://agentex-thoughts/*)
  - Adds/modifies coordinator-state fields
  - Is part of a multi-PR feature series (reference related PRs)
  - Modifies Thought CR, Report CR, or Message CR schema

If none of the above apply, delete this section.
-->

**S3 paths written/read:**
- `s3://agentex-thoughts/` — _describe what you write here_

**coordinator-state fields modified:**
- `fieldName` — _type, format, example value_

**Referenced by / depends on:**
- PR #___ — _what that PR does with these fields_

**Schema example:**
```json
{
  "field": "value"
}
```

## Closes

<!-- REQUIRED: always include a closing keyword so the issue auto-closes on merge -->

Closes #N

## Testing

<!-- How did you verify this works? -->

- [ ] Ran locally / tested in cluster
- [ ] No protected files touched (or `god-approved` label added if they are)
