#!/usr/bin/env python3
"""armorder.py <seed> <task> <host> <rep> -> "skill bare" or "bare skill"

Seeded, per (task, host, rep): the arm that runs first is not always the skill
arm, so time-of-day drift (rate limits, model load, cache warmth) cannot line up
with one arm. Deterministic for a given seed, so a run is reproducible.
"""
import random
import sys

sys.dont_write_bytecode = True
seed, task, host, rep = sys.argv[1:5]
order = ["skill", "bare"]
random.Random("%s|%s|%s|%s" % (seed, task, host, rep)).shuffle(order)
print(" ".join(order))
