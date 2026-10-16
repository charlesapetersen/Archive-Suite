"""Checks for difficulty.py's small statistics: python3 ArchiveOCRBench/test_difficulty.py"""
import difficulty as D


def test_auc():
    assert D.auc([3, 4], [1, 2]) == 1.0
    assert D.auc([1], [1]) == 0.5
    assert D.auc([1, 2], [3, 4]) == 0.0


def test_tiers_split_in_thirds():
    t = D.tiers_of({f"p{i}": i for i in range(9)})
    assert [t[f"p{i}"] for i in range(9)] == ["easy"] * 3 + ["middle"] * 3 + ["hard"] * 3


def test_two_way_does_not_credit_skipping_hard_pages():
    # Route b reads exactly as well as a but fails the hard page; answered-only accuracy flatters b, the fit does not.
    pages, routes = ["e1", "e2", "h"], ["a", "b", "c"]
    nes = {r: {"e1": 1.0, "e2": 1.0, "h": 0.6} for r in routes}
    ok = {r: {p: True for p in pages} for r in routes}
    ok["b"]["h"] = False
    mu, ability, _ = D.two_way(nes, ok, routes, pages)
    assert abs(ability["a"] - ability["b"]) < 1e-9
    answered_b = sum(nes["b"][p] for p in pages if ok["b"][p]) / 2
    answered_a = sum(nes["a"].values()) / 3
    assert answered_b > answered_a


if __name__ == "__main__":
    for name, f in list(globals().items()):
        if name.startswith("test_"):
            f()
    print("ok")
