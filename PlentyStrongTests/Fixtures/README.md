# Synthetic persistence fixtures

These malformed/version fixtures contain no personal data. Valid store/backup fixtures
are built from the real fixed profile/core by RepositoryTestHarness in each isolated
on-disk test directory. The native CrashHarness constructs its own scoped synthetic
stores; run-crash-proof.py removes only those directories after fresh-process checks.
No binary SwiftData store is committed, because it is OS/schema implementation data.
