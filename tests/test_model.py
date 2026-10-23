import math
from hypercar.model import evaluate, load_params, mass_breakdown, chassis_fea

def test_fea_matches_analytic():
    r = evaluate("C")
    assert math.isclose(r["fea"]["max_deflection_mm"], r["fea"]["analytic_check_mm"], rel_tol=0.01)

def test_parameter_propagates():
    p = load_params("C"); m1 = mass_breakdown(p)["total_mass"]
    p["Battery_Capacity"] += 20; m2 = mass_breakdown(p)["total_mass"]
    assert m2 - m1 > 80  # 20 kWh at 0.21 kWh/kg ~ 95 kg

def test_physical_bounds():
    for v in "ABCDE":
        r = evaluate(v)
        assert 1.5 < r["performance"]["0-60 mph s"] < 6
        assert 15 < r["braking"]["60-0 mph"]["distance_m"] < 60
        assert 1.0 < r["suspension"]["ride_freq_Hz"] < 3.5
