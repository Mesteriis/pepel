# Security policy

## Reporting a vulnerability

Please report security problems privately through
[GitHub's private vulnerability reporting](https://github.com/Mesteriis/pepel/security/advisories/new),
not in a public issue. Include the version, what you did, what PEPEL did, and whether files were
removed or processes stopped. You will get an answer within a week.

Things that count: PEPEL removing or moving something its rules or protections should keep, acting
without the confirmation it requires, an agent obtaining an action through the local API, or the
API being reachable by another user.

## How PEPEL is built to be safe

See [docs/SECURITY.md](../docs/SECURITY.md): permissions it uses, what it never removes, and how
every action is decided, re-checked and recorded.
