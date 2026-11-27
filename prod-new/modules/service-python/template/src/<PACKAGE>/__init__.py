"""<SERVICE>: a units ledger service.

Zones, with the only allowed dependency direction (enforced by
tests/architecture/test_boundaries.py):

    domain    pure decisions: no I/O, no clock, no randomness, no asyncio
    app       use-cases over ports declared here as Protocols
    adapters  inbound (HTTP) and outbound (stores); the shell
    platform  clock, ids, config (the only reader of the environment), observability

The composition root is the package's ``__main__`` module: the one module that sees them
all.
"""
