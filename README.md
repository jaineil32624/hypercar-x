# 🏎️ HYPERCAR-X — Parametric Electric Hypercar Engineering Platform

A concept-level vehicle engineering package where **one master parameter table (`params.json`) drives everything**: mass and CG, aerodynamics, launch and braking simulation, suspension tuning, steering geometry, chassis FEA, range, reliability, cost, and a **drivable 3D simulator**.

**▶ Drive it:** open `docs/index.html` (or enable GitHub Pages on `/docs`).

## Five variants from one platform
| Metric | A Urban Performance | B Track Hypercar | C Electric Hypercar | D Off-Road Adventure | E Autonomous Future Edition (2035) |
|---|---|---|---|---|---|
| Mass (kg) | 1238 | 1082 | 1240 | 1462 | 1287 |
| CG height (m) | 0.397 | 0.361 | 0.347 | 0.519 | 0.377 |
| Front weight (%) | 51.8 | 48.4 | 49.0 | 51.4 | 51.0 |
| Power (kW) | 450 | 1250 | 1100 | 620 | 800 |
| 0-60 mph (s) | 2.74 | 1.77 | 2.09 | 3.08 | 2.27 |
| 0-100 mph (s) | 4.88 | 2.74 | 3.40 | 5.24 | 3.73 |
| Quarter mile (s) | 9.86 | 7.30 | 8.02 | 10.08 | 8.60 |
| Top speed (km/h) | 328 | 343 | 343 | 355 | 343 |
| 60-0 mph (m) | 36.2 | 22.8 | 27.6 | 40.0 | 30.1 |
| 100-0 mph (m) | 98.2 | 55.5 | 72.1 | 108.1 | 80.1 |
| Lateral g @250 km/h | 1.12 | 3.29 | 1.89 | 0.95 | 1.59 |
| Downforce @250 km/h (N) | 851 | 11910 | 4821 | 0 | 3403 |
| Range @100 km/h (km) | 633 | 397 | 768 | 516 | 1073 |
| Ride frequency (Hz) | 1.80 | 3.01 | 2.33 | 1.42 | 2.29 |
| Chassis FoS (3 g bump) | 132 | 153 | 132 | 135 | 127 |
| Est. BOM cost (USD) | 156,000 | 244,000 | 243,000 | 175,000 | 282,000 |

![Launch](reports/launch.png)
![FEA](reports/fea_chassis.png)

## What's modelled
| Subsystem | Method |
|---|---|
| Mass & CG | 11-component build-up from parameters (CFRP tub area × thickness, pack kWh ÷ specific energy, …) |
| Aero | Drag = ½ρv²CdA, downforce = ½ρv²ClA |
| Launch | Time-stepped point mass, torque/power limited, traction limited incl. aero load |
| Braking | Numerical integration with aero assist; disc temperature rise from kinetic energy minus regen |
| Suspension | Quarter-car wheel rate, ride & wheel-hop frequency, critical damping, roll gradient |
| Steering | Ackermann inner/outer angles and turn radius |
| Chassis FEA | Euler–Bernoulli beam stiffness-matrix FEA (40 elements) of tub box section, 3 g bump; validated against 5wL⁴/384EI; Bredt–Batho torsional stiffness |
| Reliability | Series-system constant failure rates → MTBF |
| Simulator | Three.js, same parameters; bicycle model with saturating tyres, friction circle, aero drag/downforce, ¼-mile timing |

## Run
```bash
pip install -r requirements.txt
python -m hypercar.model C      # full JSON for one variant
python -m hypercar.report       # all variants → reports/
pytest -q
```
Change any value in `params.json` and rerun — every output and the simulator data update. CI (`.github/workflows/simulate.yml`) reruns tests and simulations on every push.

## Honest limits
First-order engineering estimates for a concept study, not validated CFD/crash/FEA. The chassis FoS is a single bending load case and is deliberately optimistic; real tub design is driven by torsion, crash and joint loads.
