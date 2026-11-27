"""Shared pytest setup: Hypothesis profiles.

``dev`` (default) explores randomly; ``ci`` is derandomised with a fixed example budget so a
red run is reproducible. Select with HYPOTHESIS_PROFILE=ci.
"""

import os

from hypothesis import HealthCheck, settings

settings.register_profile("dev", max_examples=100, deadline=None, database=None)
settings.register_profile(
    "ci",
    max_examples=200,
    derandomize=True,
    deadline=None,
    database=None,
    suppress_health_check=[HealthCheck.too_slow],
)
settings.load_profile(os.environ.get("HYPOTHESIS_PROFILE", "dev"))
