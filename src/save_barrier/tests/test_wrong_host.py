"""Loading the companion in Python must not patch or accept a non-PBZ host."""
import ctypes
import argparse
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--dll", type=Path, required=True)
DLL = parser.parse_args().dll.resolve()
REQUEST = Path(str(DLL) + ".request")
STATUS = Path(str(DLL) + ".status")


def main():
    for path in (REQUEST, STATUS):
        if path.exists():
            path.unlink()
    module = ctypes.CDLL(str(DLL))
    assert not REQUEST.exists() and not STATUS.exists(), "DllMain must perform no file/patch operation"
    for export in ("PBZBarrierArm", "PBZBarrierPrepareRestore", "PBZBarrierDisarm",
                   "PBZBarrierInspect", "PBZBarrierInspectEligibility"):
        function = getattr(module, export)
        function.argtypes = [ctypes.c_void_p]
        function.restype = ctypes.c_int
    REQUEST.write_text("wrong-host-001\t10000", encoding="ascii")
    assert module.PBZBarrierArm(None) == 0
    assert STATUS.read_text(encoding="ascii") == "wrong-host-001\trefused\tpinned PBZ executable name mismatch\n"
    REQUEST.write_text("invalid request\t10000", encoding="ascii")
    module.PBZBarrierArm(None)
    assert STATUS.read_text(encoding="ascii").startswith("invalid\terror\t")
    REQUEST.write_text("wrong-host-002\t10000", encoding="ascii")
    module.PBZBarrierDisarm(None)
    assert STATUS.read_text(encoding="ascii") == "wrong-host-002\tidle\n"
    REQUEST.write_text("wrong-host-inspect\t10000", encoding="ascii")
    module.PBZBarrierInspect(None)
    assert STATUS.read_text(encoding="ascii") == "wrong-host-inspect\trefused\tpinned PBZ executable name mismatch\n"
    REQUEST.write_text("wrong-host-eligibility\t10000", encoding="ascii")
    module.PBZBarrierInspectEligibility(None)
    assert STATUS.read_text(encoding="ascii") == "wrong-host-eligibility\trefused\tpinned PBZ executable name mismatch\n"
    for path in (REQUEST, STATUS):
        path.unlink()
    print("PASS wrong-host Arm refused, malformed request refused, idle Disarm safe, DllMain inert")


if __name__ == "__main__":
    main()
