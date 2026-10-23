"""Run all variants, write reports/results.json, reports/variant_comparison.md and plots."""
import json
from pathlib import Path
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from hypercar.model import evaluate, ROOT, MPH

OUT = ROOT / "reports"; OUT.mkdir(exist_ok=True)
VARIANTS = "ABCDE"
res = {v: evaluate(v) for v in VARIANTS}

rows = [("Mass (kg)", lambda r: f"{r['mass']['total_mass']:.0f}"),
        ("CG height (m)", lambda r: f"{r['mass']['cg_height']:.3f}"),
        ("Front weight (%)", lambda r: f"{r['mass']['front_weight_pct']:.1f}"),
        ("Power (kW)", lambda r: f"{r['params']['Motor_Power']}"),
        ("0-60 mph (s)", lambda r: f"{r['performance']['0-60 mph s']:.2f}"),
        ("0-100 mph (s)", lambda r: f"{r['performance']['0-100 mph s']:.2f}"),
        ("Quarter mile (s)", lambda r: f"{r['performance']['quarter_mile s']:.2f}"),
        ("Top speed (km/h)", lambda r: f"{r['performance']['top_speed_kmh']:.0f}"),
        ("60-0 mph (m)", lambda r: f"{r['braking']['60-0 mph']['distance_m']:.1f}"),
        ("100-0 mph (m)", lambda r: f"{r['braking']['100-0 mph']['distance_m']:.1f}"),
        ("Lateral g @250 km/h", lambda r: f"{r['performance']['lateral_g_250kmh']:.2f}"),
        ("Downforce @250 km/h (N)", lambda r: f"{r['aero_250kmh']['downforce']:.0f}"),
        ("Range @100 km/h (km)", lambda r: f"{r['performance']['range_km_100kmh']:.0f}"),
        ("Ride frequency (Hz)", lambda r: f"{r['suspension']['ride_freq_Hz']:.2f}"),
        ("Chassis FoS (3 g bump)", lambda r: f"{r['fea']['factor_of_safety']:.0f}"),
        ("Est. BOM cost (USD)", lambda r: f"{r['cost_usd']:,.0f}")]
md = ["| Metric | " + " | ".join(f"{v} {res[v]['name']}" for v in VARIANTS) + " |",
      "|---|" + "---|" * len(VARIANTS)]
for name, f in rows:
    md.append(f"| {name} | " + " | ".join(f(res[v]) for v in VARIANTS) + " |")
(OUT / "variant_comparison.md").write_text("\n".join(md) + "\n")

slim = {}
for v, r in res.items():
    r = dict(r); r["fea"] = {k: x for k, x in r["fea"].items()}
    slim[v] = r
(OUT / "results.json").write_text(json.dumps(slim, indent=1, default=float))

plt.style.use("dark_background")
fig, ax = plt.subplots(figsize=(8, 4.5))
for v in VARIANTS:
    t = res[v]["launch_trace"]
    ax.plot(t["t"], [x / MPH for x in t["v"]], label=f"{v} {res[v]['name']}")
ax.set_xlabel("time (s)"); ax.set_ylabel("speed (mph)"); ax.set_title("Launch simulation, traction + power limited")
ax.legend(); ax.grid(alpha=.2); fig.tight_layout(); fig.savefig(OUT / "launch.png", dpi=130)

fig, ax = plt.subplots(2, 1, figsize=(8, 5), sharex=True)
f = res["C"]["fea"]
ax[0].plot(f["x"], f["deflection_mm"], color="#4fd1c5"); ax[0].set_ylabel("deflection (mm)")
ax[1].plot(f["x"], f["stress_MPa"], color="#f6ad55"); ax[1].set_ylabel("bending stress (MPa)")
ax[1].set_xlabel("position along wheelbase (m)"); ax[0].set_title("Chassis beam FEA, variant C, 3 g bump")
fig.tight_layout(); fig.savefig(OUT / "fea_chassis.png", dpi=130)

fig, ax = plt.subplots(figsize=(6, 6))
items = res["C"]["mass"]["items"]
ax.pie(items.values(), labels=items.keys(), autopct="%1.0f%%", textprops={"fontsize": 8})
ax.set_title("Mass breakdown, variant C"); fig.tight_layout(); fig.savefig(OUT / "mass_breakdown.png", dpi=130)
print("\n".join(md))
