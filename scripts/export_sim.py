import json
r = json.load(open("reports/results.json"))
open("docs/variants.js", "w").write("window.VARIANTS=" + json.dumps(
    {v: {"name": r[v]["name"], "mass": r[v]["mass"]["total_mass"], "p": r[v]["params"]} for v in r}) + ";")
