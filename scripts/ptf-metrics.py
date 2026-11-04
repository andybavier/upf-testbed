# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The Linux Foundation
#
# Appended to the UPF's ptf/lib/trex_utils.py by ptf.sh, so that each run
# records the TRex statistics the linerate tests check. The tests import these
# helpers with `from trex_utils import *` after this module has finished
# loading, so they get the wrapped versions. Each call appends one JSON line
# to /tmp/testbed-metrics.jsonl in the PTF container, which is ptf/log on the
# host. Recording never changes what a test sees, and a recording error is
# printed, not raised.


def _testbed_test_id():
    import inspect
    import unittest

    for frame in inspect.stack():
        test = frame.frame.f_locals.get("self")
        if isinstance(test, unittest.TestCase):
            # Matches the classname in PTF's xunit files, e.g. mbr.DlAppMbrConformingTest.
            return f"{type(test).__module__}.{type(test).__name__}"
    return None


def _testbed_record(kind, value):
    import json

    row = {"test": _testbed_test_id(), "kind": kind}
    row.update(value._asdict())
    with open("/tmp/testbed-metrics.jsonl", "a") as out:
        out.write(json.dumps(row, default=float) + "\n")


def _testbed_wrap(kind, func):
    def wrapper(*args, **kwargs):
        value = func(*args, **kwargs)
        try:
            _testbed_record(kind, value)
        except Exception as err:  # noqa: BLE001
            print(f"upf-testbed: could not record {kind} stats: {err}")
        return value

    wrapper.__name__ = func.__name__
    wrapper.__doc__ = func.__doc__
    return wrapper


get_flow_stats = _testbed_wrap("flow", get_flow_stats)  # noqa: F821
get_latency_stats = _testbed_wrap("latency", get_latency_stats)  # noqa: F821
