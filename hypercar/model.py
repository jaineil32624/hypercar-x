"""HYPERCAR-X parametric vehicle engineering model.

One master parameter table (params.json) drives every calculation.
Change a parameter -> mass, CG, aero, acceleration, braking, suspension,
brake thermals and chassis FEA all recompute.

All physics is first-order engineering estimation (point-mass longitudinal
dynamics, quarter-car suspension, Euler-Bernoulli beam FEA). It is a concept
study tool, not a substitute for validated CFD/FEA/test data.
"""
from __future__ import annotations
import json, math
from dataclasses import dataclass, field, asdict
from pathlib import Path
import numpy as np

G = 9.81
RHO_AIR = 1.225
MPH = 0.44704

ROOT = Path(__file__).resolve().parent.parent


def load_params(variant: str = "C") -> dict:
    data = json.loads((ROOT / "params.json").read_text())
    p = dict(data["base"])
    p.update(data["variants"][variant]["overrides"])
    p["variant"] = variant
    p["variant_name"] = data["variants"][variant]["name"]
    return p


# ---------------------------------------------------------------- mass
def mass_breakdown(p: dict) -> dict:
    """Component masses (kg) and their CG positions (x from front axle, z from ground)."""
    wb = p["Wheelbase"]
    L, W, H = p["Vehicle_Length"], p["Vehicle_Width"], p["Vehicle_Height"]
    # monocoque: shell area * thickness * CFRP density
    shell_area = 2 * (L * W + L * H * 0.6 + W * H * 0.6) * 0.55
    chassis = shell_area * p["Chassis_Thickness"] * 1600  # CFRP 1600 kg/m3
    battery = p["Battery_Capacity"] / p["Pack_Specific_Energy"]  # kWh / (kWh/kg)
    motors = p["Motor_Count"] * p["Motor_Power"] / p["Motor_Count"] / p["Motor_Specific_Power"]
    wheel_r = p["Wheel_Diameter"] / 2
    wheels = 4 * (8.5 + 22 * wheel_r * p["Wheel_Width"])  # forged rim + tire estimate
    suspension = 4 * (9.0 + 12 * p["Suspension_Travel"])
    brakes = 4 * (2.2 + 18 * (p["Brake_Disc_Diameter"] / 2) ** 2)
    body = 85 * (L * W / (4.8 * 2.04))
    aero = p["Aero_Package_Mass"]
    interior = 38 + 22 * p["Passengers"]
    electronics = 42
    occupants = 80 * p["Passengers"]
    zc = p["Ground_Clearance"]
    items = {
        # name: (mass, x, z, unsprung)
        "Chassis (CFRP tub)": (chassis, 0.48 * wb, zc + 0.30, False),
        "Battery pack": (battery, 0.52 * wb, zc + 0.10, False),
        "Motors + inverters": (motors, 0.62 * wb, zc + 0.22, False),
        "Wheels + tyres": (wheels, 0.5 * wb, wheel_r, True),
        "Suspension": (suspension, 0.5 * wb, wheel_r, True),
        "Brakes": (brakes, 0.5 * wb, wheel_r, True),
        "Body panels": (body, 0.50 * wb, zc + 0.55, False),
        "Aero package": (aero, 0.90 * wb, zc + 0.70, False),
        "Interior": (interior, 0.45 * wb, zc + 0.35, False),
        "Electronics / HV": (electronics, 0.40 * wb, zc + 0.25, False),
        "Occupants": (occupants, 0.42 * wb, zc + 0.38, False),
    }
    m = sum(v[0] for v in items.values())
    x = sum(v[0] * v[1] for v in items.values()) / m
    z = sum(v[0] * v[2] for v in items.values()) / m
    unsprung = sum(v[0] for v in items.values() if v[3])
    # yaw polar moment: treat each item as point mass + tub as slender box
    Izz = sum(v[0] * (v[1] - x) ** 2 for v in items.values()) + chassis * (L ** 2 + W ** 2) / 12
    return {
        "items": {k: round(v[0], 1) for k, v in items.items()},
        "total_mass": m,
        "cg_x_from_front": x,
        "cg_height": z,
        "front_weight_pct": 100 * (1 - x / wb),
        "unsprung_mass": unsprung,
        "sprung_mass": m - unsprung,
        "yaw_inertia": Izz,
    }


# ---------------------------------------------------------------- aero
def aero(p: dict, v: float) -> dict:
    A = p["Frontal_Area"]
    q = 0.5 * RHO_AIR * v ** 2
    drag = q * p["Drag_Coefficient"] * A
    down = q * p["Lift_Coefficient"] * A  # ClA, positive = downforce
    return {"q": q, "drag": drag, "downforce": down}


# ---------------------------------------------------------------- powertrain
def wheel_force_available(p: dict, v: float) -> float:
    """Tractive force limited by motor torque (low speed) and power (high speed)."""
    r = p["Wheel_Diameter"] / 2
    f_torque = p["Motor_Torque"] * p["Gear_Ratio"] * p["Driveline_Eff"] / r
    f_power = p["Motor_Power"] * 1000 * p["Driveline_Eff"] / max(v, 0.1)
    return min(f_torque, f_power)


def top_speed(p: dict, mass: float) -> float:
    r = p["Wheel_Diameter"] / 2
    v_motor = p["Motor_Max_RPM"] * 2 * math.pi / 60 / p["Gear_Ratio"] * r
    # power-limited: P*eta = (CdA q + Crr m g) v
    lo, hi = 1.0, 200.0
    for _ in range(80):
        v = (lo + hi) / 2
        res = aero(p, v)["drag"] + p["Rolling_Resistance"] * mass * G
        if p["Motor_Power"] * 1000 * p["Driveline_Eff"] > res * v:
            lo = v
        else:
            hi = v
    return min(lo, v_motor)


def simulate_launch(p: dict, mb: dict, v_end: float = 100 * MPH, dt: float = 0.002) -> dict:
    """Point-mass launch with traction limit (AWD uses all 4 tyres)."""
    m = mb["total_mass"] * 1.04  # 4% rotational inertia factor
    mu = p["Tire_Mu"]
    drive_frac = 1.0 if p["Motor_Count"] >= 2 else (1 - mb["front_weight_pct"] / 100)
    t = x = v = 0.0
    out = {"t": [], "v": [], "x": []}
    marks = {}
    while t < 60:
        a_d = aero(p, v)
        f_trac_lim = mu * (mb["total_mass"] * G + a_d["downforce"]) * drive_frac
        f = min(wheel_force_available(p, v), f_trac_lim)
        f -= a_d["drag"] + p["Rolling_Resistance"] * mb["total_mass"] * G
        if f <= 0:
            break
        a = f / m
        v += a * dt
        x += v * dt
        t += dt
        if len(out["t"]) == 0 or t - out["t"][-1] > 0.05:
            out["t"].append(t); out["v"].append(v); out["x"].append(x)
        for name, target in (("0-60 mph", 60 * MPH), ("0-100 mph", 100 * MPH), ("0-200 km/h", 200 / 3.6)):
            if name not in marks and v >= target:
                marks[name] = t
        if "quarter_mile" not in marks and x >= 402.336:
            marks["quarter_mile"] = t
            marks["quarter_mile_trap_mph"] = v / MPH
        if "quarter_mile" in marks and v >= v_end:
            break
    marks["trace"] = out
    return marks


def braking(p: dict, mb: dict, v0: float) -> dict:
    """Stopping distance with aero assistance, integrated numerically."""
    m = mb["total_mass"]
    mu = p["Tire_Mu"] * p["Brake_Utilisation"]
    v, x, dt = v0, 0.0, 0.001
    while v > 0:
        a_d = aero(p, v)
        f = mu * (m * G + a_d["downforce"]) + a_d["drag"]
        v -= f / m * dt
        x += max(v, 0) * dt
    energy = 0.5 * m * v0 ** 2
    disc_mass = 4 * 7.8e3 * math.pi * (p["Brake_Disc_Diameter"] / 2) ** 2 * 0.032 * 0.55  # ventilated
    c_disc = 800 if p["Brake_Disc_Material"] == "carbon-ceramic" else 460
    dT = energy * (1 - p["Regen_Fraction"]) / (disc_mass * c_disc)
    return {"distance_m": x, "energy_MJ": energy / 1e6, "disc_temp_rise_C": dT}


def brake_bias(p: dict, mb: dict) -> dict:
    """Ideal front bias at 1.2 g decel from dynamic load transfer."""
    m, h, L = mb["total_mass"], mb["cg_height"], p["Wheelbase"]
    a = 1.2 * G
    front_static = m * G * (1 - mb["cg_x_from_front"] / L)
    dW = m * a * h / L
    front = (front_static + dW) / (m * G)
    return {"ideal_front_bias_pct": 100 * front, "load_transfer_N": dW}


def cornering(p: dict, mb: dict, v: float) -> float:
    m = mb["total_mass"]
    return p["Tire_Mu"] * (m * G + aero(p, v)["downforce"]) / (m * G)


# ---------------------------------------------------------------- suspension
def suspension(p: dict, mb: dict) -> dict:
    ms_corner = mb["sprung_mass"] / 4
    mu_corner = mb["unsprung_mass"] / 4
    k = p["Spring_Rate"] * p["Motion_Ratio"] ** 2  # wheel rate N/m
    f_ride = math.sqrt(k / ms_corner) / (2 * math.pi)
    c_crit = 2 * math.sqrt(k * ms_corner)
    c = p["Damping_Ratio"] * c_crit
    k_tire = 2.6e5
    f_hop = math.sqrt((k + k_tire) / mu_corner) / (2 * math.pi)
    static_defl = ms_corner * G / k
    # roll gradient (deg/g): simple anti-roll split
    T = (p["Track_Width_Front"] + p["Track_Width_Rear"]) / 2
    k_roll = 2 * k * (T / 2) ** 2 * 2 * (1 + p["ARB_Ratio"])  # N·m/rad (both axles)
    roll_grad = math.degrees(mb["sprung_mass"] * G * (mb["cg_height"] - 0.08) / k_roll)
    return {
        "wheel_rate_N_per_mm": k / 1000,
        "ride_freq_Hz": f_ride,
        "wheel_hop_Hz": f_hop,
        "damping_Ns_per_m": c,
        "static_deflection_mm": static_defl * 1000,
        "travel_mm": p["Suspension_Travel"] * 1000,
        "roll_gradient_deg_per_g": roll_grad,
    }


def ackermann(p: dict, steer_deg: float = 30.0) -> dict:
    L, T = p["Wheelbase"], p["Track_Width_Front"]
    di = math.radians(steer_deg)
    R = L / math.tan(di) + T / 2
    do = math.atan(L / (R + T / 2))
    return {"inner_deg": steer_deg, "outer_deg": math.degrees(do), "turn_radius_m": R}


# ---------------------------------------------------------------- chassis FEA
def chassis_fea(p: dict, mb: dict, n: int = 40) -> dict:
    """Euler-Bernoulli beam FEA of the tub as a simply-supported box beam.

    Load case: 3 g vertical bump (sprung mass distributed). Also torsional
    stiffness estimate from Bredt-Batho thin-walled closed section.
    """
    L = p["Wheelbase"]
    E = 70e9  # quasi-isotropic CFRP laminate
    t = p["Chassis_Thickness"]
    b, h = p["Vehicle_Width"] * 0.62, p["Tub_Section_Height"]
    I = (b * h ** 3 - (b - 2 * t) * (h - 2 * t) ** 3) / 12
    le = L / n
    K = np.zeros((2 * (n + 1), 2 * (n + 1)))
    ke = E * I / le ** 3 * np.array([[12, 6 * le, -12, 6 * le], [6 * le, 4 * le ** 2, -6 * le, 2 * le ** 2],
                                     [-12, -6 * le, 12, -6 * le], [6 * le, 2 * le ** 2, -6 * le, 4 * le ** 2]])
    for e in range(n):
        idx = [2 * e, 2 * e + 1, 2 * e + 2, 2 * e + 3]
        K[np.ix_(idx, idx)] += ke
    w = 3 * mb["sprung_mass"] * G / L  # N/m
    F = np.zeros(2 * (n + 1))
    for e in range(n):
        fe = w * np.array([le / 2, le ** 2 / 12, le / 2, -le ** 2 / 12])
        F[[2 * e, 2 * e + 1, 2 * e + 2, 2 * e + 3]] -= fe
    fixed = [0, 2 * n]
    free = [i for i in range(2 * (n + 1)) if i not in fixed]
    u = np.zeros_like(F)
    u[free] = np.linalg.solve(K[np.ix_(free, free)], F[free])
    defl = u[0::2]
    xs = np.linspace(0, L, n + 1)
    # bending moment from curvature via element shape functions
    M = np.array([w * xi * (L - xi) / 2 for xi in xs])
    sigma = M * (h / 2) / I
    sigma_allow = 600e6  # CFRP laminate design allowable
    A_enc = (b - t) * (h - t)
    perim = 2 * ((b - t) + (h - t))
    Gs = 5e9
    J = 4 * A_enc ** 2 * t / perim
    k_tors = Gs * J / L  # N·m/rad
    return {
        "x": xs.tolist(), "deflection_mm": (defl * 1000).tolist(), "stress_MPa": (sigma / 1e6).tolist(),
        "max_deflection_mm": float(abs(defl).max() * 1000),
        "max_stress_MPa": float(sigma.max() / 1e6),
        "factor_of_safety": float(sigma_allow / sigma.max()),
        "torsional_stiffness_Nm_per_deg": k_tors * math.pi / 180,
        "analytic_check_mm": 5 * w * L ** 4 / (384 * E * I) * 1000,
    }


# ---------------------------------------------------------------- energy / reliability
def range_km(p: dict, mb: dict, v_kmh: float = 100) -> float:
    v = v_kmh / 3.6
    f = aero(p, v)["drag"] + p["Rolling_Resistance"] * mb["total_mass"] * G
    wh_per_km = f * 1000 / 3600 / p["Driveline_Eff"] + 12  # + aux
    return p["Battery_Capacity"] * 1000 * 0.92 / wh_per_km


def reliability(p: dict) -> dict:
    # series system, constant failure rates (per 1e6 h) — representative values
    lam = {"Motor": 4.0, "Inverter": 9.0, "Battery/BMS": 7.0, "Suspension": 3.0, "Brakes": 5.0,
           "Steering": 2.0, "ECU/CAN": 3.5}
    lam_tot = sum(lam.values()) * p["Motor_Count"] / 2 ** 0.5 / 1e6
    mtbf = 1 / lam_tot
    return {"component_failure_rates_per_Mh": lam, "MTBF_h": mtbf,
            "R_5000h": math.exp(-lam_tot * 5000)}


# ---------------------------------------------------------------- full run
def evaluate(variant: str = "C") -> dict:
    p = load_params(variant)
    mb = mass_breakdown(p)
    launch = simulate_launch(p, mb)
    vmax = top_speed(p, mb["total_mass"])
    res = {
        "variant": variant, "name": p["variant_name"], "params": p, "mass": mb,
        "performance": {
            "0-60 mph s": launch.get("0-60 mph"), "0-100 mph s": launch.get("0-100 mph"),
            "0-200 km/h s": launch.get("0-200 km/h"),
            "quarter_mile s": launch.get("quarter_mile"), "trap mph": launch.get("quarter_mile_trap_mph"),
            "top_speed_kmh": vmax * 3.6, "top_speed_mph": vmax / MPH,
            "lateral_g_100kmh": cornering(p, mb, 100 / 3.6), "lateral_g_250kmh": cornering(p, mb, 250 / 3.6),
            "range_km_100kmh": range_km(p, mb),
            "power_to_weight_kW_per_t": p["Motor_Power"] / mb["total_mass"] * 1000,
        },
        "aero_250kmh": aero(p, 250 / 3.6),
        "braking": {"60-0 mph": braking(p, mb, 60 * MPH), "100-0 mph": braking(p, mb, 100 * MPH)},
        "brake_bias": brake_bias(p, mb),
        "suspension": suspension(p, mb),
        "steering": ackermann(p),
        "fea": chassis_fea(p, mb),
        "reliability": reliability(p),
        "cost_usd": cost(p, mb),
        "launch_trace": launch["trace"],
    }
    return res


def cost(p: dict, mb: dict) -> float:
    items = mb["items"]
    return round(items["Chassis (CFRP tub)"] * 180 + p["Battery_Capacity"] * 140 + p["Motor_Power"] * 45
                 + items["Body panels"] * 120 + 38000 + (60000 if p["Brake_Disc_Material"] == "carbon-ceramic" else 6000)
                 + p["Autonomy_Level"] * 25000, -3)


if __name__ == "__main__":
    import sys
    r = evaluate(sys.argv[1] if len(sys.argv) > 1 else "C")
    r.pop("launch_trace"); r["fea"] = {k: v for k, v in r["fea"].items() if not isinstance(v, list)}
    print(json.dumps(r, indent=2, default=float))
